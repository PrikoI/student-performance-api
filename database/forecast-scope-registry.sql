-- One forecast registry for every horizon.  The anchor period remains in
-- period_id for backwards compatibility; the explicit source/target columns
-- make period, year and whole-program forecasts unambiguous.
alter table public.predictions
  add column if not exists source_period_id integer,
  add column if not exists target_year_id bigint,
  add column if not exists target_program_id bigint;

alter table public.predictions
  drop constraint if exists predictions_source_period_id_fkey,
  add constraint predictions_source_period_id_fkey
    foreign key (source_period_id, student_id)
    references public.academic_periods(period_id, student_id),
  drop constraint if exists predictions_target_year_id_fkey,
  add constraint predictions_target_year_id_fkey
    foreign key (target_year_id, student_id)
    references public.academic_years(year_id, student_id),
  drop constraint if exists predictions_target_program_id_fkey,
  add constraint predictions_target_program_id_fkey
    foreign key (target_program_id, student_id)
    references public.study_programs(program_id, student_id);

update public.predictions p
set source_period_id=coalesce((p.result_snapshot->>'source_period_id')::integer,p.period_id)
where p.source_period_id is null;

update public.predictions p
set target_year_id=ap.year_id
from public.academic_periods ap
where ap.period_id=p.period_id and ap.student_id=p.student_id and p.target_year_id is null;

update public.predictions p
set target_program_id=ay.program_id
from public.academic_years ay
where ay.year_id=p.target_year_id and ay.student_id=p.student_id and p.target_program_id is null;

create or replace function private.capture_prediction_forecast_snapshot()
returns trigger language plpgsql security definer set search_path='' as $$
declare item jsonb; manifest_item jsonb; r public.academic_performance;
 owner_account_id uuid; is_demo boolean; v_source_key text; source_pk bigint;
 v_source_period_id integer; snapshot jsonb; model_pk bigint;
begin
 select a.account_id,c.is_demo into owner_account_id,is_demo
 from public.accounts a join private.account_credentials c on c.account_id=a.account_id
 where a.student_id=new.student_id;
 v_source_key=case when is_demo then 'perfecta-template' else 'perfecta-anonymized' end;
 select d.source_id into source_pk from private.forecast_data_sources d where d.source_key=v_source_key;
 v_source_period_id=coalesce(new.source_period_id,(new.result_snapshot->>'source_period_id')::integer,new.period_id);
 for item in select value from jsonb_array_elements(coalesce(new.result_snapshot->'subjects','[]'::jsonb)) loop
  select * into r from public.academic_performance
  where performance_id=(item->>'performance_id')::integer and student_id=new.student_id and period_id=v_source_period_id;
  if found then
   snapshot=coalesce(item->'normalized_snapshot',jsonb_build_object('schema_version','normalized-academic-v1','current_score_percent',item->'normalized_current_percent'));
   insert into private.forecast_feature_snapshots(prediction_id,student_id,pseudonymous_student_key,performance_id,period_id,course_id,source_id,feature_schema_version,feature_payload)
   values(new.prediction_id,new.student_id,encode(extensions.digest(new.student_id::text||':'||owner_account_id::text,'sha256'),'hex'),r.performance_id,r.period_id,r.course_id,source_pk,coalesce(snapshot->>'schema_version','normalized-academic-v1'),snapshot)
   on conflict(prediction_id,performance_id) do nothing;
  end if;
 end loop;
 for manifest_item in select value from jsonb_array_elements(coalesce(new.model_manifest,'[]'::jsonb)) loop
  select m.model_id into model_pk from private.forecast_model_registry m
  where m.model_key=manifest_item->>'key' and m.model_version=manifest_item->>'version';
  if model_pk is not null then
   insert into private.forecast_prediction_models(prediction_id,model_id,role,effective_weight,details)
   values(new.prediction_id,model_pk,coalesce(manifest_item->>'role','component'),(manifest_item->>'weight')::numeric,manifest_item)
   on conflict(prediction_id,model_id,role) do nothing;
  end if;
 end loop;
 return new;
end $$;

create or replace function private.api_save_prediction(p_token text,p_result jsonb)
returns integer language plpgsql security definer set search_path='' as $$
declare a public.accounts; pid int; target public.academic_periods; source_id int;
 r public.academic_performance; item jsonb; name text; v_program_id bigint;
begin
 a=private.api_account(p_token);
 select * into target from public.academic_periods
 where period_id=(p_result->>'period_id')::int and student_id=a.student_id;
 if not found or target.status<>'active' then raise exception 'Active owned target period required'; end if;
 source_id=coalesce((p_result->>'source_period_id')::int,target.period_id);
 if not exists(select 1 from public.academic_periods where period_id=source_id and student_id=a.student_id)
 then raise exception 'Owned source period required'; end if;
 select ay.program_id into v_program_id from public.academic_years ay
 where ay.year_id=target.year_id and ay.student_id=a.student_id;
 insert into public.predictions(
  student_id,period_id,source_period_id,target_year_id,target_program_id,
  method_version,is_illustrative,predicted_gpa,context_snapshot,forecast_level,
  result_snapshot,normalization_version,model_manifest)
 values(
  a.student_id,target.period_id,source_id,target.year_id,v_program_id,
  p_result->>'method_version',1,(p_result->>'gpa')::numeric,to_jsonb(target)::text,p_result->>'level',
  p_result,p_result->>'normalization_version',coalesce(p_result->'model_manifest','[]'::jsonb))
 returning prediction_id into pid;
 for item in select value from jsonb_array_elements(p_result->'subjects') loop
  select * into r from public.academic_performance
  where performance_id=(item->>'performance_id')::int and student_id=a.student_id and period_id=source_id;
  if not found then raise exception 'Invalid subject'; end if;
  select course_name into name from public.courses where course_id=r.course_id;
  insert into public.prediction_details(
   prediction_id,subject_name_snapshot,course_id,credits_snapshot,current_grade_snapshot,
   attendance_snapshot,assignments_completed_snapshot,assignments_total_snapshot,
   recent_assessment_snapshot,predicted_grade,lessons_planned_snapshot,lessons_held_snapshot,
   lessons_attended_snapshot,lessons_excused_snapshot,explanation)
  values(pid,name,r.course_id,r.credits,r.current_grade,r.attendance,r.assignments_completed,
   r.assignments_total,r.recent_assessment_score,(item->>'grade')::numeric,r.lessons_planned,
   r.lessons_held,r.lessons_attended,r.lessons_excused,p_result->>'assumption');
 end loop;
 return pid;
end $$;

