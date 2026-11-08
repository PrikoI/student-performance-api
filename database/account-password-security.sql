-- Password operations for an already authenticated, non-demo account.
create or replace function private.change_own_password(
  p_token text,
  p_current_password text,
  p_new_password text
) returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare
  a public.accounts;
  credentials private.account_credentials%rowtype;
  current_session_hash text;
begin
  a := private.api_account(p_token);
  select * into credentials
  from private.account_credentials
  where account_id=a.account_id
  for update;

  if credentials.account_id is null then raise exception 'Account credentials not found'; end if;
  if coalesce(credentials.is_demo,false) then raise exception 'Demo account password cannot be changed'; end if;
  if credentials.password_hash <> extensions.crypt(p_current_password,credentials.password_hash) then
    raise exception 'Current password is incorrect';
  end if;
  if p_new_password is null or length(p_new_password)<8 or octet_length(p_new_password)>72 then
    raise exception 'New password must contain 8–72 UTF-8 bytes';
  end if;
  if credentials.password_hash = extensions.crypt(p_new_password,credentials.password_hash) then
    raise exception 'New password must be different from the current password';
  end if;

  update private.account_credentials
  set password_hash=extensions.crypt(p_new_password,extensions.gen_salt('bf',10))
  where account_id=a.account_id;

  current_session_hash := encode(extensions.digest(p_token,'sha256'),'hex');
  delete from private.login_sessions
  where account_id=a.account_id and session_hash<>current_session_hash;

  return jsonb_build_object('changed',true,'other_sessions_revoked',true);
end
$function$;

create or replace function public.change_own_password(
  p_token text,p_current_password text,p_new_password text
) returns jsonb
language sql
security invoker
set search_path to ''
as $function$
  select private.change_own_password(p_token,p_current_password,p_new_password)
$function$;

create or replace function private.delete_own_account(
  p_token text,
  p_current_password text
) returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare
  a public.accounts;
  credentials private.account_credentials%rowtype;
begin
  a := private.api_account(p_token);
  select * into credentials
  from private.account_credentials
  where account_id=a.account_id
  for update;

  if a.role='admin' then raise exception 'Administrator account cannot be deleted'; end if;
  if coalesce(credentials.is_demo,false) then raise exception 'Demo accounts cannot be deleted'; end if;
  if credentials.password_hash <> extensions.crypt(p_current_password,credentials.password_hash) then
    raise exception 'Current password is incorrect';
  end if;

  delete from public.assessment_results where student_id=a.student_id;
  delete from public.assessments where student_id=a.student_id;
  delete from public.assessment_components where student_id=a.student_id;
  delete from public.lesson_attendance where student_id=a.student_id;
  delete from public.actual_results where student_id=a.student_id;
  delete from public.recommendations where student_id=a.student_id;
  delete from public.prediction_details d using public.predictions p
    where d.prediction_id=p.prediction_id and p.student_id=a.student_id;
  delete from public.predictions where student_id=a.student_id;
  delete from public.notifications where student_id=a.student_id;
  delete from public.academic_import_drafts where student_id=a.student_id;
  delete from public.academic_performance where student_id=a.student_id;
  delete from public.academic_periods where student_id=a.student_id;
  delete from public.academic_settings where student_id=a.student_id;
  delete from public.academic_years where student_id=a.student_id;
  delete from public.study_programs where student_id=a.student_id;
  delete from public.grading_bands b using public.grading_scales s
    where b.scale_id=s.scale_id and s.student_id=a.student_id;
  delete from public.grading_scales where student_id=a.student_id;
  delete from public.courses where owner_student_id=a.student_id;
  delete from public.accounts where account_id=a.account_id;
  delete from public.students where student_id=a.student_id;

  return jsonb_build_object('deleted',true,'student_id',a.student_id);
end
$function$;

create or replace function public.delete_own_account(
  p_token text,p_current_password text
) returns jsonb
language sql
security invoker
set search_path to ''
as $function$
  select private.delete_own_account(p_token,p_current_password)
$function$;

revoke all on function private.change_own_password(text,text,text),
  public.change_own_password(text,text,text),
  private.delete_own_account(text,text),
  public.delete_own_account(text,text)
from public;
grant execute on function private.change_own_password(text,text,text),
  public.change_own_password(text,text,text),
  private.delete_own_account(text,text),
  public.delete_own_account(text,text)
to anon,authenticated;

drop function if exists public.delete_own_account(text);
drop function if exists private.delete_own_account(text);
