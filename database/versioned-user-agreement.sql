create table if not exists private.user_agreement_consents (
  consent_id bigint generated always as identity primary key,
  account_id uuid not null references public.accounts(account_id) on delete cascade,
  agreement_version text not null,
  accepted_at timestamptz not null default now(),
  unique(account_id,agreement_version)
);
alter table private.user_agreement_consents enable row level security;
revoke all on private.user_agreement_consents from public, anon, authenticated;

create or replace function private.register_with_agreement(
  p_secret text,p_email text,p_username text,p_password text,p_full_name text,
  p_agreement_version text,p_agreement_accepted boolean
) returns jsonb
language plpgsql security definer set search_path to ''
as $function$
declare result jsonb; aid uuid;
begin
  if coalesce(p_agreement_accepted,false) is not true or p_agreement_version <> '2026-11-08-v1' then
    raise exception 'You must accept the current user agreement';
  end if;
  result=private.register_without_email_verification(p_secret,p_email,p_username,p_password,p_full_name);
  aid=(result->>'account_id')::uuid;
  insert into private.user_agreement_consents(account_id,agreement_version)
  values(aid,p_agreement_version) on conflict do nothing;
  return result||jsonb_build_object('agreement_version',p_agreement_version,'agreement_accepted',true);
end
$function$;

create or replace function public.register_with_agreement(
  p_secret text,p_email text,p_username text,p_password text,p_full_name text,
  p_agreement_version text,p_agreement_accepted boolean
) returns jsonb
language sql set search_path to ''
as $function$
  select private.register_with_agreement(p_secret,p_email,p_username,p_password,p_full_name,p_agreement_version,p_agreement_accepted);
$function$;
revoke all on function public.register_with_agreement(text,text,text,text,text,text,boolean) from public;
grant execute on function public.register_with_agreement(text,text,text,text,text,text,boolean) to anon,authenticated;

create or replace function private.agreement_status(p_token text)
returns jsonb
language plpgsql security definer set search_path to ''
as $function$
declare a public.accounts; demo boolean; accepted timestamptz;
begin
  a=private.api_account(p_token);
  select coalesce(c.is_demo,false) into demo from private.account_credentials c where c.account_id=a.account_id;
  if a.role='admin' or demo then
    return jsonb_build_object('required',false,'exempt',true,'version','2026-11-08-v1');
  end if;
  select consent.accepted_at into accepted from private.user_agreement_consents consent
  where consent.account_id=a.account_id and consent.agreement_version='2026-11-08-v1';
  return jsonb_build_object('required',accepted is null,'exempt',false,'version','2026-11-08-v1','accepted_at',accepted);
end
$function$;

create or replace function public.agreement_status(p_token text)
returns jsonb language sql set search_path to ''
as $function$ select private.agreement_status(p_token); $function$;
revoke all on function public.agreement_status(text) from public;
grant execute on function public.agreement_status(text) to anon,authenticated;

create or replace function private.accept_agreement(p_token text,p_version text)
returns jsonb
language plpgsql security definer set search_path to ''
as $function$
declare a public.accounts; demo boolean; accepted timestamptz;
begin
  a=private.api_account(p_token);
  select coalesce(c.is_demo,false) into demo from private.account_credentials c where c.account_id=a.account_id;
  if a.role='admin' or demo then return jsonb_build_object('accepted',true,'exempt',true); end if;
  if p_version<>'2026-11-08-v1' then raise exception 'Agreement version is outdated'; end if;
  insert into private.user_agreement_consents(account_id,agreement_version)
  values(a.account_id,p_version)
  on conflict(account_id,agreement_version) do update set accepted_at=excluded.accepted_at
  returning accepted_at into accepted;
  return jsonb_build_object('accepted',true,'version',p_version,'accepted_at',accepted);
end
$function$;

create or replace function public.accept_agreement(p_token text,p_version text)
returns jsonb language sql set search_path to ''
as $function$ select private.accept_agreement(p_token,p_version); $function$;
revoke all on function public.accept_agreement(text,text) from public;
grant execute on function public.accept_agreement(text,text) to anon,authenticated;

create or replace function private.agreement_stats(p_token text)
returns jsonb
language plpgsql security definer set search_path to ''
as $function$
declare ignored public.accounts; total bigint;
begin
  ignored=private.api_account(p_token);
  select count(distinct consent.account_id) into total
  from private.user_agreement_consents consent
  join public.accounts account using(account_id)
  join private.account_credentials credentials using(account_id)
  where consent.agreement_version='2026-11-08-v1'
    and account.role<>'admin'
    and coalesce(credentials.is_demo,false)=false;
  return jsonb_build_object('souls_transferred',total,'agreement_version','2026-11-08-v1');
end
$function$;
create or replace function public.agreement_stats(p_token text)
returns jsonb language sql set search_path to ''
as $function$ select private.agreement_stats(p_token); $function$;
revoke all on function public.agreement_stats(text) from public;
grant execute on function public.agreement_stats(text) to anon,authenticated;