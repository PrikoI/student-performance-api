-- The public RPC wrappers must be able to invoke their private delegates.
-- Keep private EXECUTE revoked from clients. Each delegate checks the
-- session token and verifies course ownership before touching data.
create or replace function public.course_delete_info(p_token text,p_course_id integer)
returns jsonb language sql security definer set search_path to ''
as $$ select private.course_delete_info(p_token,p_course_id) $$;

create or replace function public.delete_owned_course(p_token text,p_course_id integer)
returns jsonb language sql security definer set search_path to ''
as $$ select private.delete_owned_course(p_token,p_course_id) $$;
