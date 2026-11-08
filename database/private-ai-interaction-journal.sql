create table if not exists private.ai_interaction_logs (
  interaction_id bigint generated always as identity primary key,
  student_id integer not null references public.students(student_id) on delete cascade,
  phase text not null check (phase in ('plan','execute')),
  locale text not null default 'ru',
  user_message text,
  action_plan jsonb,
  outcome jsonb,
  status text not null check (status in ('planned','clarification','confirmed','completed','failed')),
  created_at timestamptz not null default now()
);
alter table private.ai_interaction_logs enable row level security;
revoke all on private.ai_interaction_logs from public, anon, authenticated;

create or replace function private.log_ai_interaction(p_session_token text, p_payload jsonb)
returns bigint
language plpgsql
security definer
set search_path to ''
as $function$
declare
  sid integer;
  new_id bigint;
begin
  sid=private.session_student(p_session_token);
  insert into private.ai_interaction_logs(student_id,phase,locale,user_message,action_plan,outcome,status)
  values(
    sid,
    case when p_payload->>'phase'='execute' then 'execute' else 'plan' end,
    left(coalesce(p_payload->>'locale','ru'),10),
    nullif(left(coalesce(p_payload->>'user_message',''),6000),''),
    p_payload->'action_plan',
    p_payload->'outcome',
    case when p_payload->>'status' in ('planned','clarification','confirmed','completed','failed') then p_payload->>'status' else 'failed' end
  )
  returning interaction_id into new_id;
  return new_id;
end
$function$;

create or replace function public.log_ai_interaction(p_session_token text, p_payload jsonb)
returns bigint
language sql
set search_path to ''
as $function$
  select private.log_ai_interaction(p_session_token,p_payload);
$function$;

revoke all on function public.log_ai_interaction(text,jsonb) from public;
grant execute on function public.log_ai_interaction(text,jsonb) to anon, authenticated;