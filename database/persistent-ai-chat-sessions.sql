create table if not exists private.ai_chat_sessions (
  session_id bigint generated always as identity primary key,
  student_id integer not null references public.students(student_id) on delete cascade,
  title text not null default 'Новый чат' check (char_length(title) between 1 and 120),
  mode text not null default 'ai' check (mode in ('ai','basic')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists private.ai_chat_messages (
  message_id bigint generated always as identity primary key,
  session_id bigint not null references private.ai_chat_sessions(session_id) on delete cascade,
  student_id integer not null references public.students(student_id) on delete cascade,
  role text not null check (role in ('user','assistant')),
  content text not null check (char_length(content) between 1 and 12000),
  mode text not null default 'ai' check (mode in ('ai','basic')),
  created_at timestamptz not null default now()
);

create index if not exists ai_chat_sessions_student_updated_idx on private.ai_chat_sessions(student_id,updated_at desc);
create index if not exists ai_chat_messages_session_created_idx on private.ai_chat_messages(session_id,created_at,message_id);
alter table private.ai_chat_sessions enable row level security;
alter table private.ai_chat_messages enable row level security;
revoke all on private.ai_chat_sessions,private.ai_chat_messages from public,anon,authenticated;

create or replace function private.ai_chat_create(p_session_token text,p_mode text default 'ai') returns jsonb
language plpgsql security definer set search_path='' as $$
declare sid integer; result private.ai_chat_sessions;
begin
  sid=private.session_student(p_session_token);
  if p_mode not in ('ai','basic') then raise exception 'Invalid chat mode' using errcode='22023'; end if;
  insert into private.ai_chat_sessions(student_id,mode) values(sid,p_mode) returning * into result;
  return to_jsonb(result);
end $$;

create or replace function private.ai_chat_list(p_session_token text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare sid integer;
begin
  sid=private.session_student(p_session_token);
  return coalesce((select jsonb_agg(to_jsonb(s) order by s.updated_at desc) from
    (select session_id,title,mode,created_at,updated_at from private.ai_chat_sessions where student_id=sid order by updated_at desc limit 100) s),'[]'::jsonb);
end $$;

create or replace function private.ai_chat_get(p_session_token text,p_session_id bigint) returns jsonb
language plpgsql security definer set search_path='' as $$
declare sid integer; session_row private.ai_chat_sessions;
begin
  sid=private.session_student(p_session_token);
  select * into session_row from private.ai_chat_sessions where session_id=p_session_id and student_id=sid;
  if not found then raise exception 'Chat not found' using errcode='P0002'; end if;
  return jsonb_build_object('session',to_jsonb(session_row),'messages',coalesce((select jsonb_agg(to_jsonb(m) order by m.created_at,m.message_id) from
    (select message_id,role,content,mode,created_at from private.ai_chat_messages where session_id=p_session_id and student_id=sid) m),'[]'::jsonb));
end $$;

create or replace function private.ai_chat_append(p_session_token text,p_session_id bigint,p_role text,p_content text,p_mode text default 'ai') returns jsonb
language plpgsql security definer set search_path='' as $$
declare sid integer; result private.ai_chat_messages; first_message boolean; session_control text;
begin
  sid=private.session_student(p_session_token);
  if p_role not in ('user','assistant') or p_mode not in ('ai','basic') or char_length(trim(p_content)) not between 1 and 12000 then
    raise exception 'Invalid chat message' using errcode='22023';
  end if;
  select control_mode into session_control from private.ai_chat_sessions where session_id=p_session_id and student_id=sid;
  if not found then raise exception 'Chat not found' using errcode='P0002'; end if;
  if p_role='assistant' and session_control='operator' then raise exception 'Operator controls this chat' using errcode='42501'; end if;
  select not exists(select 1 from private.ai_chat_messages where session_id=p_session_id) into first_message;
  insert into private.ai_chat_messages(session_id,student_id,role,content,mode,author_type) values(p_session_id,sid,p_role,trim(p_content),p_mode,case when p_role='user' then 'user' when p_mode='basic' then 'basic' else 'ai' end) returning * into result;
  update private.ai_chat_sessions set updated_at=now(),mode=p_mode,
    title=case when first_message and p_role='user' then left(regexp_replace(trim(p_content),'[[:space:]]+',' ','g'),80) else title end
    where session_id=p_session_id and student_id=sid;
  return to_jsonb(result);
end $$;

create or replace function private.ai_chat_delete(p_session_token text,p_session_id bigint) returns boolean
language plpgsql security definer set search_path='' as $$
declare sid integer; removed bigint;
begin
  sid=private.session_student(p_session_token);
  delete from private.ai_chat_sessions where session_id=p_session_id and student_id=sid returning session_id into removed;
  return removed is not null;
end $$;

create or replace function private.ai_chat_memory(p_session_token text,p_limit integer default 24) returns jsonb
language plpgsql security definer set search_path='' as $$
declare sid integer; safe_limit integer;
begin
  sid=private.session_student(p_session_token);safe_limit=least(greatest(coalesce(p_limit,24),1),40);
  return coalesce((select jsonb_agg(to_jsonb(x) order by x.created_at,x.message_id) from
    (select m.message_id,m.role,left(m.content,2000) content,m.created_at,s.title
     from private.ai_chat_messages m join private.ai_chat_sessions s using(session_id)
     where m.student_id=sid and m.mode='ai' order by m.created_at desc,m.message_id desc limit safe_limit) x),'[]'::jsonb);
end $$;

create or replace function public.ai_chat_create(p_session_token text,p_mode text default 'ai') returns jsonb language sql security definer set search_path='' as $$select private.ai_chat_create(p_session_token,p_mode)$$;
create or replace function public.ai_chat_list(p_session_token text) returns jsonb language sql security definer set search_path='' as $$select private.ai_chat_list(p_session_token)$$;
create or replace function public.ai_chat_get(p_session_token text,p_session_id bigint) returns jsonb language sql security definer set search_path='' as $$select private.ai_chat_get(p_session_token,p_session_id)$$;
create or replace function public.ai_chat_append(p_session_token text,p_session_id bigint,p_role text,p_content text,p_mode text default 'ai') returns jsonb language sql security definer set search_path='' as $$select private.ai_chat_append(p_session_token,p_session_id,p_role,p_content,p_mode)$$;
create or replace function public.ai_chat_delete(p_session_token text,p_session_id bigint) returns boolean language sql security definer set search_path='' as $$select private.ai_chat_delete(p_session_token,p_session_id)$$;
create or replace function public.ai_chat_memory(p_session_token text,p_limit integer default 24) returns jsonb language sql security definer set search_path='' as $$select private.ai_chat_memory(p_session_token,p_limit)$$;
revoke all on function public.ai_chat_create(text,text),public.ai_chat_list(text),public.ai_chat_get(text,bigint),public.ai_chat_append(text,bigint,text,text,text),public.ai_chat_delete(text,bigint) from public;
grant execute on function public.ai_chat_create(text,text),public.ai_chat_list(text),public.ai_chat_get(text,bigint),public.ai_chat_append(text,bigint,text,text,text),public.ai_chat_delete(text,bigint) to anon,authenticated;
revoke all on function public.ai_chat_memory(text,integer) from public;
grant execute on function public.ai_chat_memory(text,integer) to anon,authenticated;


