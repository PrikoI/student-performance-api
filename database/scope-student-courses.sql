create or replace function private.get_student_data(p_session_token text)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare
  sid int;
  result jsonb := '{}'::jsonb;
  t text;
  rows jsonb;
begin
  sid = private.session_student(p_session_token);
  foreach t in array array[
    'students','study_programs','academic_years','academic_periods','academic_settings',
    'academic_performance','lesson_attendance','predictions','assessment_components',
    'assessments','assessment_results','actual_results','recommendations','notifications',
    'academic_import_drafts','grading_scales'
  ] loop
    execute format(
      'select coalesce(jsonb_agg(to_jsonb(x)),''[]''::jsonb) from public.%I x where student_id=$1',
      t
    ) into rows using sid;
    result = result || jsonb_build_object(t, rows);
  end loop;

  select coalesce(jsonb_agg(to_jsonb(d)), '[]'::jsonb)
    into rows
    from public.prediction_details d
    join public.predictions p using(prediction_id)
   where p.student_id = sid;
  result = result || jsonb_build_object('prediction_details', rows);

  select coalesce(jsonb_agg(to_jsonb(c)), '[]'::jsonb)
    into rows
    from public.courses c
   where c.owner_student_id = sid
      or exists (
        select 1
          from public.academic_performance ap
         where ap.student_id = sid
           and ap.course_id = c.course_id
      );
  result = result || jsonb_build_object('courses', rows);

  select coalesce(jsonb_agg(to_jsonb(b)), '[]'::jsonb)
    into rows
    from public.grading_bands b
    join public.grading_scales g using(scale_id)
   where g.student_id = sid;
  result = result || jsonb_build_object('grading_bands', rows);
  return result;
end
$function$;