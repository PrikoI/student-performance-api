create or replace function private.api_seed_demo_assessments(p_token text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare caller public.accounts; row record; component_pk bigint; assessment_pk bigint;
        normalized numeric; created_performances integer:=0; created_assessments integer:=0; created_results integer:=0;
begin
 caller=private.api_account(p_token);
 if caller.role<>'admin' then raise exception 'Administrator required' using errcode='42501'; end if;
 for row in
  select ap.*,p.status period_status,p.end_date,s.calendar_type,s.grading_scale,s.grade_min,s.grade_max
  from public.academic_performance ap
  join public.academic_periods p on p.period_id=ap.period_id
  join public.academic_settings s on s.settings_id=p.settings_id
  join public.accounts a on a.student_id=ap.student_id
  join private.account_credentials c on c.account_id=a.account_id and c.is_demo=true
  where ap.student_id between 1 and 8 and ap.current_grade is not null
  and not exists(select 1 from public.assessment_components ac where ac.performance_id=ap.performance_id)
 loop
  normalized=private.normalize_forecast_grade(row.current_grade,row.calendar_type,row.grading_scale,row.grade_min,row.grade_max);
  for component_pk in
   insert into public.assessment_components(student_id,performance_id,name,component_type,weight_percent)
   values (row.student_id,row.performance_id,'Assignments','assignment',30),
          (row.student_id,row.performance_id,'Midterm','midterm',30),
          (row.student_id,row.performance_id,'Final','final',40)
   returning component_id
  loop
   insert into public.assessments(student_id,component_id,title,maximum_score,due_at)
   select row.student_id,component_pk,
          case ac.component_type when 'assignment' then 'Course assignments' when 'midterm' then 'Midterm exam' else 'Final exam' end,
          100,coalesce(row.end_date,current_date)::timestamptz
   from public.assessment_components ac where ac.component_id=component_pk
   returning assessment_id into assessment_pk;
   created_assessments=created_assessments+1;
   insert into public.assessment_results(student_id,assessment_id,score,status)
   values(row.student_id,assessment_pk,normalized,'graded');
   created_results=created_results+1;
  end loop;
  update public.academic_performance set assignments_total=3,assignments_completed=3,recent_assessment_score=row.current_grade
  where performance_id=row.performance_id;
  if row.period_status='completed' then
   insert into public.actual_results(student_id,performance_id,final_grade)
   values(row.student_id,row.performance_id,row.current_grade)
   on conflict(student_id,performance_id) do update set final_grade=excluded.final_grade,recorded_at=now();
  end if;
  created_performances=created_performances+1;
 end loop;
 return jsonb_build_object('performances',created_performances,'assessments',created_assessments,'results',created_results);
end $$;
create or replace function public.api_seed_demo_assessments(p_token text) returns jsonb
language sql security invoker set search_path='' as $$ select private.api_seed_demo_assessments(p_token); $$;
revoke all on function private.api_seed_demo_assessments(text),public.api_seed_demo_assessments(text) from public;
grant execute on function private.api_seed_demo_assessments(text),public.api_seed_demo_assessments(text) to anon,authenticated;
