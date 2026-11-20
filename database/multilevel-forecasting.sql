-- Multilevel forecasting v1: expose only de-identified, labelled training rows
-- to the application and strengthen assessment integrity.

create or replace function private.api_forecast_reference(p_token text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare a public.accounts; payload jsonb;
begin
 a=private.api_account(p_token);
 insert into private.forecast_local_observations(performance_id,student_id,calendar_type,period_number,normalized_current_percent,actual_final_percent)
 select ap.performance_id,ap.student_id,s.calendar_type,p.period_number,
        private.normalize_forecast_grade(ap.current_grade,s.calendar_type,s.grading_scale,s.grade_min,s.grade_max),
        private.normalize_forecast_grade(ar.final_grade,s.calendar_type,s.grading_scale,s.grade_min,s.grade_max)
 from public.academic_performance ap
 join public.academic_periods p on p.period_id=ap.period_id
 join public.academic_settings s on s.settings_id=p.settings_id
 join public.accounts ac on ac.student_id=ap.student_id
 join private.account_credentials c on c.account_id=ac.account_id and c.is_demo=false
 left join public.actual_results ar on ar.performance_id=ap.performance_id
 where ap.current_grade is not null
 on conflict(performance_id) do update set calendar_type=excluded.calendar_type,period_number=excluded.period_number,
 normalized_current_percent=excluded.normalized_current_percent,actual_final_percent=excluded.actual_final_percent,captured_at=now();

 select jsonb_build_object(
  'datasets',coalesce((select jsonb_agg(jsonb_build_object('slug',d.slug,'title',d.title,'source_url',d.source_url,'doi',d.doi,'license',d.license,'description',d.description,'sample_count',(select count(*) from private.forecast_samples s where s.dataset_id=d.dataset_id))) from private.forecast_datasets d where d.active),'[]'::jsonb),
  'samples',coalesce((select jsonb_agg(jsonb_build_object('subject',s.subject,'stage1',100*s.stage1_score/d.grade_max,'stage2',100*s.stage2_score/d.grade_max,'final',100*s.final_score/d.grade_max,'absences',s.absences)) from private.forecast_samples s join private.forecast_datasets d using(dataset_id) where d.active),'[]'::jsonb),
  'local_samples',coalesce((select jsonb_agg(jsonb_build_object('stage1',normalized_current_percent,'final',actual_final_percent,'calendar',calendar_type)) from private.forecast_local_observations where actual_final_percent is not null),'[]'::jsonb),
  'local_summary',coalesce((select jsonb_agg(row_to_json(x)) from (select calendar_type,count(*) observations,round(avg(normalized_current_percent),2) average_current_percent,count(actual_final_percent) completed_outcomes from private.forecast_local_observations group by calendar_type) x),'[]'::jsonb)
 ) into payload;
 return payload;
end $$;

update private.forecast_model_registry set model_version='v1',lifecycle_status='serving',validation_status='experimental',
 configuration=configuration||'{"min_training_rows":40,"ensemble_weight":0.20,"implementation":"gradient-boosted-stumps"}'::jsonb,updated_at=now()
where model_key in ('gradient-boosting-risk','gradient-boosting-grade');

insert into private.forecast_model_registry(model_key,model_version,task,algorithm,lifecycle_status,validation_status,feature_schema_version,configuration)
values ('personal-baseline','v2','grade_forecast','bounded-evidence-model','serving','experimental','normalized-academic-v1',
'{"signals":["current","recent","personal_history","attendance","completion","period_progress"],"bounded_adjustments":true}'::jsonb)
on conflict(model_key,model_version) do update set configuration=excluded.configuration,lifecycle_status='serving',updated_at=now();

create or replace function private.validate_assessment_component_weights() returns trigger
language plpgsql set search_path='' as $$
declare total numeric;
begin
 select coalesce(sum(weight_percent),0) into total from public.assessment_components
 where performance_id=new.performance_id and component_id<>coalesce(new.component_id,-1);
 if total+new.weight_percent>100 then raise exception 'The total weight of assessment categories cannot exceed 100%%' using errcode='23514'; end if;
 return new;
end $$;
drop trigger if exists validate_assessment_component_weights on public.assessment_components;
create trigger validate_assessment_component_weights before insert or update of weight_percent,performance_id
on public.assessment_components for each row execute function private.validate_assessment_component_weights();

create or replace function private.validate_assessment_result_score() returns trigger
language plpgsql set search_path='' as $$
declare maximum numeric;
begin
 select maximum_score into maximum from public.assessments where assessment_id=new.assessment_id;
 if new.score is not null and (new.score<0 or maximum is null or new.score>maximum) then
  raise exception 'The result must be between 0 and the maximum score' using errcode='23514';
 end if;
 return new;
end $$;
drop trigger if exists validate_assessment_result_score on public.assessment_results;
create trigger validate_assessment_result_score before insert or update of score,assessment_id
on public.assessment_results for each row execute function private.validate_assessment_result_score();

create or replace function private.recalculate_performance_grade(p_performance_id integer) returns void
language plpgsql security definer set search_path='' as $$
declare total_weight numeric; ready_components integer; component_count integer; percent_score numeric;
        calendar text; scale_name text; scale_min numeric; scale_max numeric; converted numeric;
begin
 select count(*),coalesce(sum(weight_percent),0) into component_count,total_weight
 from public.assessment_components where performance_id=p_performance_id;
 if component_count=0 or abs(total_weight-100)>.0001 then return; end if;
 with component_scores as (
  select c.component_id,c.weight_percent,
         sum(r.score)/nullif(sum(a.maximum_score),0)*100 as component_percent
  from public.assessment_components c
  join public.assessments a on a.component_id=c.component_id
  join public.assessment_results r on r.assessment_id=a.assessment_id and r.status='graded' and r.score is not null
  where c.performance_id=p_performance_id
  group by c.component_id,c.weight_percent
 )
 select count(*),sum(component_percent*weight_percent)/100 into ready_components,percent_score from component_scores;
 if ready_components<>component_count or percent_score is null then return; end if;
 select s.calendar_type,s.grading_scale,s.grade_min,s.grade_max into calendar,scale_name,scale_min,scale_max
 from public.academic_performance ap join public.academic_periods p on p.period_id=ap.period_id
 join public.academic_settings s on s.settings_id=p.settings_id where ap.performance_id=p_performance_id;
 converted=case when scale_name='five_point' or calendar='quarter' then
   case when percent_score>=85 then 5 when percent_score>=65 then 4 when percent_score>=40 then 3 else 2 end
  else scale_min+(scale_max-scale_min)*percent_score/100 end;
 update public.academic_performance set current_grade=round(converted,2),updated_at=now()
 where performance_id=p_performance_id;
end $$;

create or replace function private.refresh_grade_from_assessment() returns trigger
language plpgsql security definer set search_path='' as $$
declare pid integer;
begin
 select c.performance_id into pid from public.assessments a join public.assessment_components c using(component_id)
 where a.assessment_id=case when tg_op='DELETE' then old.assessment_id else new.assessment_id end;
 if pid is not null then perform private.recalculate_performance_grade(pid); end if;
 if tg_op='DELETE' then return old; end if;
 return new;
end $$;
drop trigger if exists refresh_grade_from_assessment on public.assessment_results;
create trigger refresh_grade_from_assessment after insert or update or delete on public.assessment_results
for each row execute function private.refresh_grade_from_assessment();

revoke all on function private.validate_assessment_component_weights(),private.validate_assessment_result_score(),private.recalculate_performance_grade(integer),private.refresh_grade_from_assessment() from public,anon,authenticated;
