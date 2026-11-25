create or replace function private.derive_academic_attendance()
returns trigger
language plpgsql
security invoker
set search_path to ''
as $$
declare
  effective_attended numeric;
begin
  if new.lessons_held is not null and new.lessons_attended is not null then
    if new.lessons_attended > new.lessons_held then
      raise exception 'Attended lessons cannot exceed lessons held' using errcode='23514';
    end if;
    if coalesce(new.lessons_excused,0) > new.lessons_held-new.lessons_attended then
      effective_attended=new.lessons_held;
    else
      effective_attended=new.lessons_attended+coalesce(new.lessons_excused,0);
    end if;
    new.attendance=case when new.lessons_held=0 then null else round(effective_attended*100/new.lessons_held,2) end;
    new.attendance_source='counts';
  elsif new.attendance is not null then
    new.attendance_source='percentage';
  end if;
  return new;
end
$$;

drop trigger if exists derive_academic_attendance on public.academic_performance;
create trigger derive_academic_attendance
before insert or update of lessons_held,lessons_attended,lessons_excused,attendance
on public.academic_performance
for each row execute function private.derive_academic_attendance();

update public.academic_performance
set attendance=round(
      (lessons_attended+least(coalesce(lessons_excused,0),greatest(lessons_held-lessons_attended,0)))::numeric
      *100/nullif(lessons_held,0),2
    ),
    attendance_source='counts'
where lessons_held is not null
  and lessons_attended is not null
  and lessons_attended<=lessons_held;

revoke all on function private.derive_academic_attendance() from public,anon,authenticated;
