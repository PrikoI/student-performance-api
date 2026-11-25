-- Template courses may be shared by several students. A student may remove
-- their own records for such a course, while the shared catalog row remains.
create or replace function private.course_delete_info(p_token text,p_course_id integer)
returns jsonb language plpgsql security definer set search_path to '' as $$
declare account public.accounts; performance_count integer; work_count integer;
  grade_count integer; attendance_count integer; outcome_count integer;
  prediction_count integer;
begin
  account=private.api_account(p_token);
  if not exists (
    select 1 from public.courses c where c.course_id=p_course_id
      and (c.owner_student_id=account.student_id or
        (c.owner_student_id is null and exists (
          select 1 from public.academic_performance p
          where p.course_id=c.course_id and p.student_id=account.student_id)))
  ) then raise exception 'Course not found for this student' using errcode='P0002'; end if;
  select count(*) into performance_count from public.academic_performance
    where student_id=account.student_id and course_id=p_course_id;
  select count(*) into work_count from public.assessments a
    join public.assessment_components c using(component_id)
    join public.academic_performance p using(performance_id)
    where p.student_id=account.student_id and p.course_id=p_course_id;
  select count(*) into grade_count from public.assessment_results r
    join public.assessments a using(assessment_id)
    join public.assessment_components c using(component_id)
    join public.academic_performance p using(performance_id)
    where p.student_id=account.student_id and p.course_id=p_course_id;
  select count(*) into attendance_count from public.lesson_attendance l
    join public.academic_performance p using(performance_id)
    where p.student_id=account.student_id and p.course_id=p_course_id;
  select count(*) into outcome_count from public.actual_results r
    join public.academic_performance p using(performance_id)
    where p.student_id=account.student_id and p.course_id=p_course_id;
  select count(*) into prediction_count from public.prediction_details d
    join public.predictions p using(prediction_id)
    where p.student_id=account.student_id and d.course_id=p_course_id;
  return jsonb_build_object('course_id',p_course_id,
    'performance_records',performance_count,'works',work_count,'grades',grade_count,
    'attendance_records',attendance_count,'outcomes',outcome_count,
    'prediction_details',prediction_count,
    'has_related_data',(performance_count+work_count+grade_count+attendance_count+outcome_count+prediction_count)>0);
end $$;
