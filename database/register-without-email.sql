-- Legacy email verification remains in database/email-verified-username-auth.sql.
-- Active registration now creates an account immediately without sending email.
create or replace function private.register_without_email_verification(
  p_secret text,
  p_email text,
  p_username text,
  p_password text,
  p_full_name text
) returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare
  normalized text := lower(btrim(p_email));
  status jsonb;
  sid int;
  aid uuid;
  token text;
begin
  if not private.auth_internal_ok(p_secret) then
    raise exception 'Unauthorized auth service';
  end if;

  status := private.username_status(p_username);
  if not coalesce((status->>'valid')::boolean,false) then
    raise exception '%',status->>'message';
  end if;
  if not coalesce((status->>'available')::boolean,false) then
    raise exception 'Username is already taken';
  end if;
  if normalized is null
     or normalized !~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$'
     or length(normalized)>100 then
    raise exception 'Enter a valid email address';
  end if;
  if exists(select 1 from private.account_credentials where email=normalized) then
    raise exception 'An account with this email already exists';
  end if;
  if p_password is null or length(p_password)<8 or octet_length(p_password)>72 then
    raise exception 'Password must contain 8–72 UTF-8 bytes';
  end if;
  if nullif(btrim(p_full_name),'') is null or length(btrim(p_full_name))>100 then
    raise exception 'Enter your name';
  end if;

  insert into public.students(full_name,email)
  values(btrim(p_full_name),normalized)
  returning student_id into sid;

  insert into public.accounts(student_id,display_name)
  values(sid,btrim(p_full_name))
  returning account_id into aid;

  insert into private.account_credentials(
    account_id,email,username,password_hash,email_verified_at,is_demo,password_reset_enabled
  ) values(
    aid,normalized,btrim(p_username),
    extensions.crypt(p_password,extensions.gen_salt('bf',10)),
    null,false,false
  );

  insert into public.user_preferences(account_id) values(aid);

  token := encode(extensions.gen_random_bytes(32),'hex');
  insert into private.login_sessions
  values(encode(extensions.digest(token,'sha256'),'hex'),aid,now()+interval '7 days');

  return jsonb_build_object(
    'account_id',aid,
    'student_id',sid,
    'session_token',token,
    'email_verified',false
  );
end
$function$;

create or replace function public.register_without_email_verification(
  p_secret text,
  p_email text,
  p_username text,
  p_password text,
  p_full_name text
) returns jsonb
language sql
set search_path to ''
as $function$
  select private.register_without_email_verification(
    p_secret,p_email,p_username,p_password,p_full_name
  )
$function$;

revoke all on function public.register_without_email_verification(text,text,text,text,text)
  from public,authenticated;
grant execute on function public.register_without_email_verification(text,text,text,text,text)
  to anon;
