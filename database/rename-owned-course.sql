create or replace function private.rename_owned_course(p_token text,p_course_id bigint,p_name text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare
  account public.accounts;
  clean_name text := btrim(coalesce(p_name,''));
begin
  account := private.api_account(p_token);
  if length(clean_name)<1 or length(clean_name)>100 then
    raise exception 'Enter a subject name of up to 100 characters' using errcode='P0001';
  end if;
  update public.courses set course_name=clean_name
    where course_id=p_course_id and owner_student_id=account.student_id;
  if not found then raise exception 'This subject cannot be renamed' using errcode='P0001'; end if;
  return jsonb_build_object('course_id',p_course_id,'course_name',clean_name);
end $$;

create or replace function public.rename_owned_course(p_token text,p_course_id bigint,p_name text)
returns jsonb language sql security invoker set search_path='' as $$
  select private.rename_owned_course(p_token,p_course_id,p_name)
$$;
revoke all on function private.rename_owned_course(text,bigint,text) from public,anon,authenticated;
revoke all on function public.rename_owned_course(text,bigint,text) from public;
grant execute on function public.rename_owned_course(text,bigint,text) to anon,authenticated;
