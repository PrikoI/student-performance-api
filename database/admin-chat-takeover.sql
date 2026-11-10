alter table private.ai_chat_sessions add column if not exists control_mode text not null default 'ai';
alter table private.ai_chat_sessions drop constraint if exists ai_chat_sessions_control_mode_check;
alter table private.ai_chat_sessions add constraint ai_chat_sessions_control_mode_check check(control_mode in ('ai','operator'));
alter table private.ai_chat_sessions add column if not exists operator_account_id uuid references public.accounts(account_id) on delete set null;
alter table private.ai_chat_sessions add column if not exists control_updated_at timestamptz not null default now();
alter table private.ai_chat_messages add column if not exists author_type text not null default 'ai';
alter table private.ai_chat_messages drop constraint if exists ai_chat_messages_author_type_check;
alter table private.ai_chat_messages add constraint ai_chat_messages_author_type_check check(author_type in ('user','ai','basic','operator'));

create table if not exists private.ai_chat_operator_audit(
 audit_id bigint generated always as identity primary key,
 session_id bigint references private.ai_chat_sessions(session_id) on delete cascade,
 admin_account_id uuid references public.accounts(account_id) on delete set null,
 event_type text not null check(event_type in ('takeover','release','message')),
 created_at timestamptz not null default now()
);
alter table private.ai_chat_operator_audit enable row level security;
revoke all on private.ai_chat_operator_audit from public,anon,authenticated;

create or replace function private.ai_chat_control_state(p_session_token text,p_session_id bigint) returns jsonb
language plpgsql security definer set search_path='' as $$
declare sid integer; result jsonb;
begin
 sid=private.session_student(p_session_token);
 select jsonb_build_object('session_id',s.session_id,'control_mode',s.control_mode,'updated_at',s.control_updated_at)
 into result from private.ai_chat_sessions s where s.session_id=p_session_id and s.student_id=sid;
 if result is null then raise exception 'Chat not found' using errcode='P0002'; end if;
 return result;
end $$;

create or replace function private.ai_chat_admin_list(p_token text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare a public.accounts;
begin
 a=private.api_account(p_token);if a.role<>'admin' then raise exception 'Administrator required' using errcode='42501';end if;
 return coalesce((select jsonb_agg(to_jsonb(x) order by x.updated_at desc) from (
  select s.session_id,s.student_id,st.full_name,s.title,s.mode,s.control_mode,s.control_updated_at,s.created_at,s.updated_at,
   (select left(m.content,180) from private.ai_chat_messages m where m.session_id=s.session_id order by m.message_id desc limit 1) last_message
  from private.ai_chat_sessions s join public.students st using(student_id) order by s.updated_at desc limit 200
 ) x),'[]'::jsonb);
end $$;

create or replace function private.ai_chat_admin_get(p_token text,p_session_id bigint) returns jsonb
language plpgsql security definer set search_path='' as $$
declare a public.accounts; session_row jsonb;
begin
 a=private.api_account(p_token);if a.role<>'admin' then raise exception 'Administrator required' using errcode='42501';end if;
 select to_jsonb(x) into session_row from (select s.*,st.full_name from private.ai_chat_sessions s join public.students st using(student_id) where s.session_id=p_session_id) x;
 if session_row is null then raise exception 'Chat not found' using errcode='P0002';end if;
 return jsonb_build_object('session',session_row,'messages',coalesce((select jsonb_agg(to_jsonb(m) order by m.message_id) from
  (select message_id,role,content,mode,author_type,created_at from private.ai_chat_messages where session_id=p_session_id) m),'[]'::jsonb));
end $$;

create or replace function private.ai_chat_admin_control(p_token text,p_session_id bigint,p_control text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare a public.accounts; result private.ai_chat_sessions;
begin
 a=private.api_account(p_token);if a.role<>'admin' then raise exception 'Administrator required' using errcode='42501';end if;
 if p_control not in ('ai','operator') then raise exception 'Invalid control mode' using errcode='22023';end if;
 update private.ai_chat_sessions set control_mode=p_control,operator_account_id=case when p_control='operator' then a.account_id else null end,control_updated_at=now()
 where session_id=p_session_id returning * into result;
 if result.session_id is null then raise exception 'Chat not found' using errcode='P0002';end if;
 insert into private.ai_chat_operator_audit(session_id,admin_account_id,event_type) values(p_session_id,a.account_id,case when p_control='operator' then 'takeover' else 'release' end);
 return to_jsonb(result);
end $$;

create or replace function private.ai_chat_admin_append(p_token text,p_session_id bigint,p_content text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare a public.accounts; s private.ai_chat_sessions; result private.ai_chat_messages;
begin
 a=private.api_account(p_token);if a.role<>'admin' then raise exception 'Administrator required' using errcode='42501';end if;
 if char_length(trim(p_content)) not between 1 and 12000 then raise exception 'Invalid message' using errcode='22023';end if;
 select * into s from private.ai_chat_sessions where session_id=p_session_id for update;
 if s.session_id is null then raise exception 'Chat not found' using errcode='P0002';end if;
 if s.control_mode<>'operator' or s.operator_account_id is distinct from a.account_id then raise exception 'Take over this chat first' using errcode='42501';end if;
 insert into private.ai_chat_messages(session_id,student_id,role,content,mode,author_type) values(p_session_id,s.student_id,'assistant',trim(p_content),'ai','operator') returning * into result;
 update private.ai_chat_sessions set updated_at=now() where session_id=p_session_id;
 insert into private.ai_chat_operator_audit(session_id,admin_account_id,event_type) values(p_session_id,a.account_id,'message');
 return to_jsonb(result);
end $$;

create or replace function public.ai_chat_control_state(p_session_token text,p_session_id bigint) returns jsonb language sql security definer set search_path='' as $$select private.ai_chat_control_state(p_session_token,p_session_id)$$;
create or replace function public.ai_chat_admin_list(p_token text) returns jsonb language sql security definer set search_path='' as $$select private.ai_chat_admin_list(p_token)$$;
create or replace function public.ai_chat_admin_get(p_token text,p_session_id bigint) returns jsonb language sql security definer set search_path='' as $$select private.ai_chat_admin_get(p_token,p_session_id)$$;
create or replace function public.ai_chat_admin_control(p_token text,p_session_id bigint,p_control text) returns jsonb language sql security definer set search_path='' as $$select private.ai_chat_admin_control(p_token,p_session_id,p_control)$$;
create or replace function public.ai_chat_admin_append(p_token text,p_session_id bigint,p_content text) returns jsonb language sql security definer set search_path='' as $$select private.ai_chat_admin_append(p_token,p_session_id,p_content)$$;
revoke all on function public.ai_chat_control_state(text,bigint),public.ai_chat_admin_list(text),public.ai_chat_admin_get(text,bigint),public.ai_chat_admin_control(text,bigint,text),public.ai_chat_admin_append(text,bigint,text) from public;
grant execute on function public.ai_chat_control_state(text,bigint),public.ai_chat_admin_list(text),public.ai_chat_admin_get(text,bigint),public.ai_chat_admin_control(text,bigint,text),public.ai_chat_admin_append(text,bigint,text) to anon,authenticated;

create or replace function private.ai_chat_append(p_session_token text,p_session_id bigint,p_role text,p_content text,p_mode text default 'ai') returns jsonb
language plpgsql security definer set search_path='' as $$
declare sid integer; result private.ai_chat_messages; first_message boolean; session_control text;
begin
 sid=private.session_student(p_session_token);
 if p_role not in ('user','assistant') or p_mode not in ('ai','basic') or char_length(trim(p_content)) not between 1 and 12000 then raise exception 'Invalid chat message' using errcode='22023';end if;
 select control_mode into session_control from private.ai_chat_sessions where session_id=p_session_id and student_id=sid;
 if not found then raise exception 'Chat not found' using errcode='P0002';end if;
 if p_role='assistant' and session_control='operator' then raise exception 'Operator controls this chat' using errcode='42501';end if;
 select not exists(select 1 from private.ai_chat_messages where session_id=p_session_id) into first_message;
 insert into private.ai_chat_messages(session_id,student_id,role,content,mode,author_type) values(p_session_id,sid,p_role,trim(p_content),p_mode,case when p_role='user' then 'user' when p_mode='basic' then 'basic' else 'ai' end) returning * into result;
 update private.ai_chat_sessions set updated_at=now(),mode=p_mode,title=case when first_message and p_role='user' then left(regexp_replace(trim(p_content),'[[:space:]]+',' ','g'),80) else title end where session_id=p_session_id and student_id=sid;
 return to_jsonb(result);
end $$;

