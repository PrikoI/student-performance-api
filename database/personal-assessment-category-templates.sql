create table if not exists private.personal_assessment_category_templates(
  template_id bigint generated always as identity primary key,
  account_id uuid not null references public.accounts(account_id) on delete cascade,
  name text not null check(char_length(name) between 1 and 100),
  calendar_type text not null check(calendar_type in ('trimester','semester','quarter')),
  categories jsonb not null check(private.valid_assessment_categories(categories)),
  created_at timestamptz not null default now(),
  unique(account_id,name,calendar_type)
);
revoke all on private.personal_assessment_category_templates from public,anon,authenticated;

create or replace function private.personal_assessment_template_list(p_token text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare account public.accounts;
begin
  account=private.api_account(p_token);
  return coalesce((select jsonb_agg(jsonb_build_object('template_id',t.template_id,'name',t.name,'calendar_type',t.calendar_type,'categories',t.categories) order by t.name)
    from private.personal_assessment_category_templates t where t.account_id=account.account_id),'[]'::jsonb);
end $$;

create or replace function private.personal_assessment_template_save(p_token text,p_data jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare account public.accounts; saved private.personal_assessment_category_templates; tid bigint;
begin
  account=private.api_account(p_token);
  if nullif(btrim(p_data->>'name'),'') is null or char_length(btrim(p_data->>'name'))>100 then raise exception 'Template name is required'; end if;
  if (p_data->>'calendar_type') not in ('trimester','semester','quarter') then raise exception 'Unsupported calendar type'; end if;
  if not private.valid_assessment_categories(p_data->'categories') then raise exception using message='Category weights must add up to 100%'; end if;
  tid=nullif(p_data->>'template_id','')::bigint;
  if tid is null then
    insert into private.personal_assessment_category_templates(account_id,name,calendar_type,categories)
    values(account.account_id,btrim(p_data->>'name'),p_data->>'calendar_type',p_data->'categories') returning * into saved;
  else
    update private.personal_assessment_category_templates set name=btrim(p_data->>'name'),calendar_type=p_data->>'calendar_type',categories=p_data->'categories'
    where template_id=tid and account_id=account.account_id returning * into saved;
    if saved.template_id is null then raise exception 'Template not found'; end if;
  end if;
  return jsonb_build_object('template_id',saved.template_id,'name',saved.name,'calendar_type',saved.calendar_type,'categories',saved.categories);
end $$;

create or replace function public.personal_assessment_template_list(p_token text) returns jsonb language sql security invoker set search_path='' as $$select private.personal_assessment_template_list(p_token)$$;
create or replace function public.personal_assessment_template_save(p_token text,p_data jsonb) returns jsonb language sql security invoker set search_path='' as $$select private.personal_assessment_template_save(p_token,p_data)$$;
revoke all on function private.personal_assessment_template_list(text),private.personal_assessment_template_save(text,jsonb) from public,anon,authenticated;
revoke all on function public.personal_assessment_template_list(text),public.personal_assessment_template_save(text,jsonb) from public;
grant execute on function public.personal_assessment_template_list(text),public.personal_assessment_template_save(text,jsonb) to anon,authenticated;
