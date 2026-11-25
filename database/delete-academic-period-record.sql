-- Remove one subject from one period, including its grades and attendance.
create or replace function private.delete_academic_period_record(p_token text,p_performance_id bigint)
returns jsonb language plpgsql security definer set search_path='' as $$
declare
  account public.accounts;
  record public.academic_performance;
  component_ids bigint[];
  assessment_ids bigint[];
begin
  account := private.api_account(p_token);
  select * into record from public.academic_performance
    where performance_id=p_performance_id and student_id=account.student_id for update;
  if not found then raise exception 'Subject not found in this period' using errcode='P0001'; end if;
  select coalesce(array_agg(component_id),'{}') into component_ids
    from public.assessment_components where performance_id=record.performance_id and student_id=account.student_id;
  select coalesce(array_agg(assessment_id),'{}') into assessment_ids
    from public.assessments where component_id=any(component_ids) and student_id=account.student_id;
  delete from public.assessment_results where assessment_id=any(assessment_ids) and student_id=account.student_id;
  delete from public.assessments where assessment_id=any(assessment_ids) and student_id=account.student_id;
  delete from public.assessment_components where component_id=any(component_ids) and student_id=account.student_id;
  delete from public.lesson_attendance where performance_id=record.performance_id and student_id=account.student_id;
  delete from public.actual_results where performance_id=record.performance_id and student_id=account.student_id;
  delete from public.academic_performance where performance_id=record.performance_id and student_id=account.student_id;
  return jsonb_build_object('deleted',true,'period_id',record.period_id,'course_id',record.course_id);
end $$;

create or replace function public.delete_academic_period_record(p_token text,p_performance_id bigint)
returns jsonb language sql security invoker set search_path='' as $$
  select private.delete_academic_period_record(p_token,p_performance_id)
$$;
revoke all on function private.delete_academic_period_record(text,bigint) from public,anon,authenticated;
revoke all on function public.delete_academic_period_record(text,bigint) from public;
grant execute on function public.delete_academic_period_record(text,bigint) to anon,authenticated;
