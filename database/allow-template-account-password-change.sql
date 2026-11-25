-- Keep the current-password check and session revocation, but allow a
-- signed-in template student to replace the initial sample password.
create or replace function private.change_own_password(
  p_token text, p_current_password text, p_new_password text
) returns jsonb
language plpgsql security definer set search_path to '' as $function$
declare
  a public.accounts;
  credentials private.account_credentials%rowtype;
  current_session_hash text;
begin
  a := private.api_account(p_token);
  select * into credentials from private.account_credentials
  where account_id=a.account_id for update;
  if credentials.account_id is null then raise exception 'Account credentials not found'; end if;
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
