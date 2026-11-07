-- Atomic, idempotent import used by the AI confirmation flow.
create or replace function private.import_academic_subjects(
  p_session_token text,
  p_setup jsonb,
  p_subjects jsonb
) returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  sid int;
  pid int;
  item jsonb;
  cid int;
  perf_id int;
  saved jsonb;
  results jsonb='[]'::jsonb;
begin
  sid=private.session_student(p_session_token);
  if jsonb_typeof(p_subjects)<>'array' or jsonb_array_length(p_subjects)<1 or jsonb_array_length(p_subjects)>50 then
    raise exception 'Import requires 1-50 subjects';
  end if;

  select period_id into pid
  from public.academic_periods
  where student_id=sid and status='active'
  order by period_id
  limit 1;

  if pid is null then
    if jsonb_typeof(p_setup)<>'object' or nullif(trim(p_setup->>'institution_name'),'') is null then
      raise exception 'Academic setup is required before importing subjects';
    end if;
    perform private.setup_academic_program(p_session_token,p_setup);
    select period_id into pid
    from public.academic_periods
    where student_id=sid and status='active'
    order by period_id desc
    limit 1;
  end if;

  for item in select value from jsonb_array_elements(p_subjects) loop
    if nullif(trim(item->>'course_name'),'') is null then
      raise exception 'Every subject needs a name';
    end if;

    select course_id into cid
    from public.courses
    where lower(trim(course_name))=lower(trim(item->>'course_name'))
      and (owner_student_id is null or owner_student_id=sid)
    order by owner_student_id nulls last
    limit 1;

    if cid is null then
      insert into public.courses(course_name,owner_student_id)
      values(trim(item->>'course_name'),sid)
      returning course_id into cid;
    end if;

    select performance_id into perf_id
    from public.academic_performance
    where student_id=sid and course_id=cid and period_id=pid;

    saved=private.save_student_record(
      p_session_token,
      'academic_performance',
      (item-'course_name')
        || jsonb_build_object('course_id',cid,'period_id',pid)
        || case when perf_id is null then '{}'::jsonb else jsonb_build_object('performance_id',perf_id) end
    );
    results=results||jsonb_build_array(saved);
  end loop;

  return jsonb_build_object('period_id',pid,'imported',jsonb_array_length(results),'records',results);
end
$$;

create or replace function public.import_academic_subjects(
  p_session_token text,
  p_setup jsonb,
  p_subjects jsonb
) returns jsonb
language sql
set search_path=''
as $$ select private.import_academic_subjects(p_session_token,p_setup,p_subjects) $$;

revoke all on function public.import_academic_subjects(text,jsonb,jsonb) from public;
grant execute on function public.import_academic_subjects(text,jsonb,jsonb) to anon, authenticated;
