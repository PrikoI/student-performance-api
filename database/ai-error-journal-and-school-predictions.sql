-- Private technical error journal. It is not exposed through the Data API.
create table if not exists private.ai_error_logs (
  error_id bigint generated always as identity primary key,
  interaction_id bigint not null references private.ai_interaction_logs(interaction_id) on delete cascade,
  student_id integer not null references public.students(student_id) on delete cascade,
  phase text not null,
  operation text,
  error_code text not null,
  safe_message text not null,
  details jsonb,
  created_at timestamptz not null default now()
);

revoke all on private.ai_error_logs from public, anon, authenticated;
alter table private.ai_error_logs enable row level security;
create index if not exists ai_error_logs_interaction_idx on private.ai_error_logs(interaction_id);
create index if not exists ai_error_logs_student_created_idx on private.ai_error_logs(student_id,created_at desc);

-- Preserve earlier failures in the new structured journal as well.
insert into private.ai_error_logs(interaction_id,student_id,phase,operation,error_code,safe_message,details,created_at)
select l.interaction_id,l.student_id,l.phase,l.action_plan->0->>'operation',
  case when l.outcome ? 'error' then 'request_failure' else 'action_failure' end,
  left(coalesce(l.outcome->>'error',failed.item->>'detail','AI action failed'),500),
  jsonb_build_object('failed_result',failed.item),l.created_at
from private.ai_interaction_logs l
left join lateral (
  select value as item from jsonb_array_elements(coalesce(l.outcome->'results','[]'::jsonb))
  where value->>'status' in ('failed','skipped_after_failure') limit 1
) failed on true
where (l.status='failed' or failed.item is not null)
  and not exists(select 1 from private.ai_error_logs e where e.interaction_id=l.interaction_id);

create or replace function private.log_ai_interaction(p_session_token text, p_payload jsonb)
returns bigint
language plpgsql
security definer
set search_path=''
as $$
declare
  sid integer;
  new_id bigint;
  normalized_status text;
  failed_result jsonb;
  technical_message text;
begin
  sid=private.session_student(p_session_token);
  normalized_status=case when p_payload->>'status' in ('planned','clarification','confirmed','completed','failed') then p_payload->>'status' else 'failed' end;
  select value into failed_result
  from jsonb_array_elements(coalesce(p_payload->'outcome'->'results','[]'::jsonb))
  where value->>'status' in ('failed','skipped_after_failure')
  limit 1;

  insert into private.ai_interaction_logs(student_id,phase,locale,user_message,action_plan,outcome,status)
  values(sid,case when p_payload->>'phase'='execute' then 'execute' else 'plan' end,
    left(coalesce(p_payload->>'locale','ru'),10),nullif(left(coalesce(p_payload->>'user_message',''),6000),''),
    p_payload->'action_plan',p_payload->'outcome',normalized_status)
  returning interaction_id into new_id;

  if normalized_status='failed' or failed_result is not null then
    technical_message=left(coalesce(p_payload->'outcome'->>'error',failed_result->>'detail','AI action failed'),500);
    insert into private.ai_error_logs(interaction_id,student_id,phase,operation,error_code,safe_message,details)
    values(new_id,sid,case when p_payload->>'phase'='execute' then 'execute' else 'plan' end,
      coalesce(failed_result->>'operation',p_payload->'action_plan'->0->>'operation'),
      case when p_payload->'outcome' ? 'error' then 'request_failure' else 'action_failure' end,
      technical_message,jsonb_build_object('failed_result',failed_result));
  end if;
  return new_id;
end $$;

-- School forecasts have a percentage and a converted 2–5 grade, not a GPA.
-- Do not place the percentage into the 0–4 predicted_gpa column.
create or replace function private.api_save_prediction(p_token text, p_result jsonb)
returns integer
language plpgsql
security definer
set search_path=''
as $$
declare a public.accounts; pid int; target public.academic_periods; source_id int; r public.academic_performance; item jsonb; name text;
begin
 a=private.api_account(p_token);
 select * into target from public.academic_periods where period_id=(p_result->>'period_id')::int and student_id=a.student_id;
 if not found or target.status<>'active' then raise exception 'Active owned target period required'; end if;
 source_id=coalesce((p_result->>'source_period_id')::int,target.period_id);
 if not exists(select 1 from public.academic_periods where period_id=source_id and student_id=a.student_id) then raise exception 'Owned source period required'; end if;
 insert into public.predictions(student_id,period_id,method_version,is_illustrative,predicted_gpa,context_snapshot,forecast_level,result_snapshot)
 values(a.student_id,target.period_id,p_result->>'method_version',1,(p_result->>'gpa')::numeric,to_jsonb(target)::text,p_result->>'level',p_result) returning prediction_id into pid;
 for item in select value from jsonb_array_elements(p_result->'subjects') loop
  select * into r from public.academic_performance where performance_id=(item->>'performance_id')::int and student_id=a.student_id and period_id=source_id;
  if not found then raise exception 'Invalid subject'; end if;
  select course_name into name from public.courses where course_id=r.course_id;
  insert into public.prediction_details(prediction_id,subject_name_snapshot,course_id,credits_snapshot,current_grade_snapshot,attendance_snapshot,assignments_completed_snapshot,assignments_total_snapshot,recent_assessment_snapshot,predicted_grade,lessons_planned_snapshot,lessons_held_snapshot,lessons_attended_snapshot,lessons_excused_snapshot,explanation)
  values(pid,name,r.course_id,r.credits,r.current_grade,r.attendance,r.assignments_completed,r.assignments_total,r.recent_assessment_score,(item->>'grade')::numeric,r.lessons_planned,r.lessons_held,r.lessons_attended,r.lessons_excused,p_result->>'assumption');
 end loop;
 return pid;
end $$;
