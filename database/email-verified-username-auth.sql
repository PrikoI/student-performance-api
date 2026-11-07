-- Email-verified, case-sensitive username authentication.
-- The live AUTH_INTERNAL_SECRET hash is inserted separately and is never committed.

alter table private.account_credentials add column if not exists username text;
alter table private.account_credentials add column if not exists is_demo boolean not null default false;
alter table private.account_credentials add column if not exists email_verified_at timestamptz;
alter table private.account_credentials add column if not exists password_reset_enabled boolean not null default true;
create unique index if not exists account_credentials_username_exact_key on private.account_credentials(username);

create table if not exists private.auth_service_config(singleton boolean primary key default true check(singleton),secret_hash text not null,created_at timestamptz not null default now());
alter table private.auth_service_config enable row level security;
create table if not exists private.email_challenges(challenge_id uuid primary key default gen_random_uuid(),purpose text not null check(purpose in ('registration','password_reset')),email text not null,username text,full_name text,pending_password_hash text,account_id uuid references public.accounts(account_id) on delete cascade,code_hash text not null,attempts integer not null default 0 check(attempts between 0 and 10),expires_at timestamptz not null,consumed_at timestamptz,created_at timestamptz not null default now());
alter table private.email_challenges enable row level security;
create index if not exists email_challenges_email_created_idx on private.email_challenges(email,created_at desc);
create index if not exists email_challenges_account_idx on private.email_challenges(account_id) where account_id is not null;

CREATE OR REPLACE FUNCTION private.auth_internal_ok(p_secret text)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$ select exists(
  select 1 from private.auth_service_config
  where singleton and secret_hash=encode(extensions.digest(coalesce(p_secret,''),'sha256'),'hex')
) $function$;

CREATE OR REPLACE FUNCTION private.begin_password_reset(p_secret text, p_identifier text, p_code_hash text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare aid uuid; target_email text; cid uuid;
begin
  if not private.auth_internal_ok(p_secret) then raise exception 'Unauthorized auth service'; end if;
  select c.account_id,c.email into aid,target_email
  from private.account_credentials c
  where ((position('@' in p_identifier)>0 and c.email=lower(btrim(p_identifier)))
     or (position('@' in p_identifier)=0 and c.username=btrim(p_identifier)))
    and not c.is_demo and c.password_reset_enabled
  limit 1;
  if aid is null then return jsonb_build_object('should_send',false); end if;
  delete from private.email_challenges where account_id=aid and purpose='password_reset' and consumed_at is null;
  insert into private.email_challenges(purpose,email,account_id,code_hash,expires_at)
  values('password_reset',target_email,aid,p_code_hash,now()+interval '10 minutes')
  returning challenge_id into cid;
  return jsonb_build_object('should_send',true,'challenge_id',cid,'email',target_email,'expires_in',600);
end $function$;

CREATE OR REPLACE FUNCTION private.begin_registration(p_secret text, p_email text, p_username text, p_password text, p_full_name text, p_code_hash text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare normalized text:=lower(btrim(p_email)); status jsonb; cid uuid;
begin
  if not private.auth_internal_ok(p_secret) then raise exception 'Unauthorized auth service'; end if;
  status=private.username_status(p_username);
  if not coalesce((status->>'valid')::boolean,false) then raise exception '%',status->>'message'; end if;
  if not coalesce((status->>'available')::boolean,false) then raise exception 'Username is already taken'; end if;
  if normalized is null or normalized !~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$' or length(normalized)>100 then raise exception 'Enter a valid email address'; end if;
  if exists(select 1 from private.account_credentials where email=normalized) then raise exception 'An account with this email already exists'; end if;
  if p_password is null or length(p_password)<8 or octet_length(p_password)>72 then raise exception 'Password must contain 8–72 UTF-8 bytes'; end if;
  if nullif(btrim(p_full_name),'') is null or length(btrim(p_full_name))>100 then raise exception 'Enter your name'; end if;
  delete from private.email_challenges where email=normalized and purpose='registration' and consumed_at is null;
  insert into private.email_challenges(purpose,email,username,full_name,pending_password_hash,code_hash,expires_at)
  values('registration',normalized,btrim(p_username),btrim(p_full_name),
         extensions.crypt(p_password,extensions.gen_salt('bf',10)),p_code_hash,now()+interval '10 minutes')
  returning challenge_id into cid;
  return jsonb_build_object('challenge_id',cid,'email',normalized,'expires_in',600);
end $function$;

CREATE OR REPLACE FUNCTION private.complete_password_reset(p_secret text, p_challenge_id uuid, p_code text, p_new_password text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare ch private.email_challenges%rowtype;
begin
  if not private.auth_internal_ok(p_secret) then raise exception 'Unauthorized auth service'; end if;
  select * into ch from private.email_challenges where challenge_id=p_challenge_id for update;
  if ch.challenge_id is null or ch.purpose<>'password_reset' or ch.consumed_at is not null then raise exception 'Verification code is invalid'; end if;
  if ch.expires_at<now() then raise exception 'Verification code has expired'; end if;
  update private.email_challenges set attempts=attempts+1 where challenge_id=p_challenge_id;
  if ch.attempts>=5 or ch.code_hash<>encode(extensions.digest(p_code,'sha256'),'hex') then raise exception 'Verification code is invalid'; end if;
  if p_new_password is null or length(p_new_password)<8 or octet_length(p_new_password)>72 then raise exception 'Password must contain 8–72 UTF-8 bytes'; end if;
  if not exists(select 1 from private.account_credentials where account_id=ch.account_id and not is_demo and password_reset_enabled) then raise exception 'Password reset is unavailable for this account'; end if;
  update private.account_credentials set password_hash=extensions.crypt(p_new_password,extensions.gen_salt('bf',10)) where account_id=ch.account_id;
  delete from private.login_sessions where account_id=ch.account_id;
  update private.email_challenges set consumed_at=now() where challenge_id=p_challenge_id;
  return jsonb_build_object('reset',true);
end $function$;

CREATE OR REPLACE FUNCTION private.login_student(p_email text, p_password text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare aid uuid; sid int; token text; identifier text:=btrim(p_email);
begin
 select c.account_id,a.student_id into aid,sid
 from private.account_credentials c join public.accounts a using(account_id)
 where ((position('@' in identifier)>0 and c.email=lower(identifier))
        or (position('@' in identifier)=0 and c.username=identifier))
   and c.password_hash=extensions.crypt(p_password,c.password_hash);
 if aid is null then raise exception 'Invalid email, username or password' using errcode='28000'; end if;
 token=encode(extensions.gen_random_bytes(32),'hex');
 insert into private.login_sessions values(encode(extensions.digest(token,'sha256'),'hex'),aid,now()+interval '7 days');
 return jsonb_build_object('account_id',aid,'student_id',sid,'session_token',token);
end $function$;

CREATE OR REPLACE FUNCTION private.username_status(p_username text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare candidate text:=btrim(p_username); suggestions jsonb='[]'::jsonb; n int;
begin
  if candidate is null or candidate !~ '^[A-Za-z][A-Za-z0-9_]{2,29}$' then
    return jsonb_build_object('valid',false,'available',false,'suggestions','[]'::jsonb,
      'message','Логин должен содержать 3–30 латинских букв, цифр или символов _. Первый символ — буква.');
  end if;
  if not exists(select 1 from private.account_credentials where username=candidate)
     and not exists(select 1 from private.email_challenges where username=candidate and consumed_at is null and expires_at>now()) then
    return jsonb_build_object('valid',true,'available',true,'suggestions','[]'::jsonb);
  end if;
  for n in 2..999 loop
    exit when jsonb_array_length(suggestions)>=3;
    if length(candidate||n::text)<=30
       and not exists(select 1 from private.account_credentials where username=candidate||n::text)
       and not exists(select 1 from private.email_challenges where username=candidate||n::text and consumed_at is null and expires_at>now()) then
      suggestions=suggestions||jsonb_build_array(candidate||n::text);
    end if;
  end loop;
  return jsonb_build_object('valid',true,'available',false,'suggestions',suggestions,'message','Этот логин уже занят.');
end $function$;

CREATE OR REPLACE FUNCTION private.verify_registration(p_secret text, p_challenge_id uuid, p_code text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare ch private.email_challenges%rowtype; sid int; aid uuid; token text;
begin
  if not private.auth_internal_ok(p_secret) then raise exception 'Unauthorized auth service'; end if;
  select * into ch from private.email_challenges where challenge_id=p_challenge_id for update;
  if ch.challenge_id is null or ch.purpose<>'registration' or ch.consumed_at is not null then raise exception 'Verification code is invalid'; end if;
  if ch.expires_at<now() then raise exception 'Verification code has expired'; end if;
  update private.email_challenges set attempts=attempts+1 where challenge_id=p_challenge_id;
  if ch.attempts>=5 or ch.code_hash<>encode(extensions.digest(p_code,'sha256'),'hex') then raise exception 'Verification code is invalid'; end if;
  if exists(select 1 from private.account_credentials where email=ch.email) then raise exception 'An account with this email already exists'; end if;
  if exists(select 1 from private.account_credentials where username=ch.username) then raise exception 'Username is already taken'; end if;
  insert into public.students(full_name,email) values(ch.full_name,ch.email) returning student_id into sid;
  insert into public.accounts(student_id,display_name) values(sid,ch.full_name) returning account_id into aid;
  insert into private.account_credentials(account_id,email,username,password_hash,email_verified_at,is_demo,password_reset_enabled)
  values(aid,ch.email,ch.username,ch.pending_password_hash,now(),false,true);
  insert into public.user_preferences(account_id) values(aid);
  update private.email_challenges set consumed_at=now() where challenge_id=p_challenge_id;
  token=encode(extensions.gen_random_bytes(32),'hex');
  insert into private.login_sessions values(encode(extensions.digest(token,'sha256'),'hex'),aid,now()+interval '7 days');
  return jsonb_build_object('account_id',aid,'student_id',sid,'session_token',token);
end $function$;

CREATE OR REPLACE FUNCTION public.begin_password_reset(p_secret text, p_identifier text, p_code_hash text)
 RETURNS jsonb
 LANGUAGE sql
 SET search_path TO ''
AS $function$ select private.begin_password_reset(p_secret,p_identifier,p_code_hash) $function$;

CREATE OR REPLACE FUNCTION public.begin_registration(p_secret text, p_email text, p_username text, p_password text, p_full_name text, p_code_hash text)
 RETURNS jsonb
 LANGUAGE sql
 SET search_path TO ''
AS $function$ select private.begin_registration(p_secret,p_email,p_username,p_password,p_full_name,p_code_hash) $function$;

CREATE OR REPLACE FUNCTION public.complete_password_reset(p_secret text, p_challenge_id uuid, p_code text, p_new_password text)
 RETURNS jsonb
 LANGUAGE sql
 SET search_path TO ''
AS $function$ select private.complete_password_reset(p_secret,p_challenge_id,p_code,p_new_password) $function$;

CREATE OR REPLACE FUNCTION public.login_student(p_email text, p_password text)
 RETURNS jsonb
 LANGUAGE sql
 SET search_path TO ''
AS $function$ select private.login_student(p_email,p_password) $function$;

CREATE OR REPLACE FUNCTION public.username_status(p_username text)
 RETURNS jsonb
 LANGUAGE sql
 SET search_path TO ''
AS $function$ select private.username_status(p_username) $function$;

CREATE OR REPLACE FUNCTION public.verify_registration(p_secret text, p_challenge_id uuid, p_code text)
 RETURNS jsonb
 LANGUAGE sql
 SET search_path TO ''
AS $function$ select private.verify_registration(p_secret,p_challenge_id,p_code) $function$;

revoke all on function public.register_student(text,text,text) from public,anon,authenticated;
grant execute on function public.login_student(text,text) to anon,authenticated;
grant execute on function public.username_status(text) to anon,authenticated;
grant execute on function public.begin_registration(text,text,text,text,text,text) to anon;
grant execute on function public.verify_registration(text,uuid,text) to anon;
grant execute on function public.begin_password_reset(text,text,text) to anon;
grant execute on function public.complete_password_reset(text,uuid,text,text) to anon;
