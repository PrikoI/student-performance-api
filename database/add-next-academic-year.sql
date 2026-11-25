create or replace function private.add_next_academic_year(p_token text,p_program_id bigint)
returns jsonb language plpgsql security definer set search_path to '' as $$
declare
  account public.accounts;
  program public.study_programs;
  last_year public.academic_years;
  year_id bigint;
  settings_id integer;
  next_number integer;
  period_count integer;
  start_year integer;
  year_label text;
  period_label text;
  n integer;
begin
  account=private.api_account(p_token);
  select * into program from public.study_programs
    where program_id=p_program_id and student_id=account.student_id for update;
  if not found then raise exception 'Program not found' using errcode='P0001'; end if;
  select * into last_year from public.academic_years
    where program_id=p_program_id and student_id=account.student_id
    order by year_number desc limit 1;
  next_number=coalesce(last_year.year_number,0)+1;
  if program.duration_years is not null and next_number>program.duration_years then
    raise exception 'Increase the program duration before adding another year' using errcode='P0001';
  end if;
  period_count=coalesce(last_year.planned_period_count,program.suggested_period_count,
    case program.calendar_type when 'quarter' then 4 when 'semester' then 2 else 3 end);
  if period_count not between 1 and 12 then raise exception 'Invalid number of periods' using errcode='P0001'; end if;
  select p.settings_id into settings_id from public.academic_periods p
    join public.academic_years y on y.year_id=p.year_id
    where y.program_id=p_program_id and p.student_id=account.student_id
    order by y.year_number desc,p.period_number desc limit 1;
  if settings_id is null then
    select s.settings_id into settings_id from public.academic_settings s
      where s.student_id=account.student_id and s.calendar_type=program.calendar_type
      order by s.settings_id desc limit 1;
  end if;
  if settings_id is null then raise exception 'Set up the first study period before adding a year' using errcode='P0001'; end if;
  select coalesce(max((regexp_match(replace(p.academic_year,'–','-'),'^[0-9]{4}'))[1]::integer),
    extract(year from current_date)::integer-1)+1 into start_year
    from public.academic_periods p join public.academic_years y on y.year_id=p.year_id
    where y.program_id=p_program_id and p.student_id=account.student_id;
  year_label=start_year||'-'||(start_year+1);
  insert into public.academic_years(student_id,program_id,year_number,year_label,planned_period_count)
    values(account.student_id,p_program_id,next_number,year_label,period_count)
    returning academic_years.year_id into year_id;
  for n in 1..period_count loop
    period_label=case program.calendar_type when 'quarter' then 'Quarter '||n
      when 'semester' then 'Semester '||n else 'Trimester '||n end;
    insert into public.academic_periods(student_id,settings_id,academic_year,period_name,period_number,year_id,status)
      values(account.student_id,settings_id,year_label,period_label,n,year_id,'planned');
  end loop;
  return jsonb_build_object('year_id',year_id,'year_label',year_label,'period_count',period_count);
end $$;

create or replace function public.add_next_academic_year(p_token text,p_program_id bigint)
returns jsonb language sql security definer set search_path to '' as $$
  select private.add_next_academic_year(p_token,p_program_id)
$$;
revoke all on function private.add_next_academic_year(text,bigint) from public,anon,authenticated;
revoke all on function public.add_next_academic_year(text,bigint) from public;
grant execute on function public.add_next_academic_year(text,bigint) to anon,authenticated;
