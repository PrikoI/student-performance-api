create or replace function private.course_delete_info(p_token text,p_course_id integer)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $$
declare
  account public.accounts;
  performance_count integer;
  work_count integer;
  grade_count integer;
  attendance_count integer;
  outcome_count integer;
  prediction_count integer;
begin
  account=private.api_account(p_token);
  if not exists(select 1 from public.courses where course_id=p_course_id and owner_student_id=account.student_id) then
    raise exception 'Course not found for this student' using errcode='P0002';
  end if;
  select count(*) into performance_count from public.academic_performance where student_id=account.student_id and course_id=p_course_id;
  select count(*) into work_count
  from public.assessments a join public.assessment_components c using(component_id)
  join public.academic_performance p using(performance_id)
  where p.student_id=account.student_id and p.course_id=p_course_id;
  select count(*) into grade_count
  from public.assessment_results r join public.assessments a using(assessment_id)
  join public.assessment_components c using(component_id)
  join public.academic_performance p using(performance_id)
  where p.student_id=account.student_id and p.course_id=p_course_id;
  select count(*) into attendance_count from public.lesson_attendance l join public.academic_performance p using(performance_id) where p.student_id=account.student_id and p.course_id=p_course_id;
  select count(*) into outcome_count from public.actual_results r join public.academic_performance p using(performance_id) where p.student_id=account.student_id and p.course_id=p_course_id;
  select count(*) into prediction_count from public.prediction_details d join public.predictions p using(prediction_id) where p.student_id=account.student_id and d.course_id=p_course_id;
  return jsonb_build_object(
    'course_id',p_course_id,
    'performance_records',performance_count,
    'works',work_count,
    'grades',grade_count,
    'attendance_records',attendance_count,
    'outcomes',outcome_count,
    'prediction_details',prediction_count,
    'has_related_data',(performance_count+work_count+grade_count+attendance_count+outcome_count+prediction_count)>0
  );
end
$$;

create or replace function private.delete_owned_course(p_token text,p_course_id integer)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $$
declare
  account public.accounts;
  info jsonb;
  performance_ids integer[];
  component_ids bigint[];
  assessment_ids bigint[];
begin
  account=private.api_account(p_token);
  info=private.course_delete_info(p_token,p_course_id);
  select coalesce(array_agg(performance_id),'{}') into performance_ids from public.academic_performance where student_id=account.student_id and course_id=p_course_id;
  select coalesce(array_agg(component_id),'{}') into component_ids from public.assessment_components where student_id=account.student_id and performance_id=any(performance_ids);
  select coalesce(array_agg(assessment_id),'{}') into assessment_ids from public.assessments where student_id=account.student_id and component_id=any(component_ids);
  delete from public.assessment_results where student_id=account.student_id and assessment_id=any(assessment_ids);
  delete from public.assessments where student_id=account.student_id and assessment_id=any(assessment_ids);
  delete from public.assessment_components where student_id=account.student_id and component_id=any(component_ids);
  delete from public.lesson_attendance where student_id=account.student_id and performance_id=any(performance_ids);
  delete from public.actual_results where student_id=account.student_id and performance_id=any(performance_ids);
  delete from public.recommendations where student_id=account.student_id and course_id=p_course_id;
  delete from public.prediction_details d using public.predictions p where d.prediction_id=p.prediction_id and p.student_id=account.student_id and d.course_id=p_course_id;
  delete from public.academic_performance where student_id=account.student_id and performance_id=any(performance_ids);
  delete from public.courses where course_id=p_course_id and owner_student_id=account.student_id;
  return info||jsonb_build_object('deleted',true);
end
$$;

create or replace function public.course_delete_info(p_token text,p_course_id integer)
returns jsonb language sql security invoker set search_path to ''
as $$ select private.course_delete_info(p_token,p_course_id) $$;
create or replace function public.delete_owned_course(p_token text,p_course_id integer)
returns jsonb language sql security invoker set search_path to ''
as $$ select private.delete_owned_course(p_token,p_course_id) $$;

revoke all on function private.course_delete_info(text,integer),private.delete_owned_course(text,integer),public.course_delete_info(text,integer),public.delete_owned_course(text,integer) from public;
grant execute on function public.course_delete_info(text,integer),public.delete_owned_course(text,integer) to anon,authenticated;
