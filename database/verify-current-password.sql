create or replace function private.verify_own_password(
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
  where account_id=a.account_id;

  if credentials.account_id is null then raise exception 'Account credentials not found'; end if;
  if coalesce(credentials.is_demo,false) then raise exception 'Demo account credentials cannot be changed'; end if;
  if credentials.password_hash <> extensions.crypt(p_current_password,credentials.password_hash) then
    raise exception 'Current password is incorrect';
  end if;
  return jsonb_build_object('valid',true);
end
$function$;

create or replace function public.verify_own_password(
  p_token text,p_current_password text
) returns jsonb
language sql
security invoker
set search_path to ''
as $function$
  select private.verify_own_password(p_token,p_current_password)
$function$;

revoke all on function private.verify_own_password(text,text),
  public.verify_own_password(text,text)
from public;
grant execute on function private.verify_own_password(text,text),
  public.verify_own_password(text,text)
to anon,authenticated;
