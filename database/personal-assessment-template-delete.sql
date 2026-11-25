create or replace function private.personal_assessment_template_delete(p_token text,p_template_id bigint)
returns boolean language plpgsql security definer set search_path='' as $$
declare account public.accounts; affected integer;
begin
  account=private.api_account(p_token);
  delete from private.personal_assessment_category_templates
    where template_id=p_template_id and account_id=account.account_id;
  get diagnostics affected=row_count;
  return affected=1;
end $$;

create or replace function public.personal_assessment_template_delete(p_token text,p_template_id bigint)
returns boolean language sql security definer set search_path='' as $$
  select private.personal_assessment_template_delete(p_token,p_template_id)
$$;
revoke all on function private.personal_assessment_template_delete(text,bigint) from public,anon,authenticated;
revoke all on function public.personal_assessment_template_delete(text,bigint) from public;
grant execute on function public.personal_assessment_template_delete(text,bigint) to anon,authenticated;
