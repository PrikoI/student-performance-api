-- Apply a complete category scheme in one transaction, including all subjects in a period.
create or replace function private.replace_assessment_categories_batch(
  p_token text, p_performance_id bigint, p_categories jsonb, p_apply_all boolean
) returns jsonb language plpgsql security definer set search_path='' as $$
declare
  account public.accounts;
  source_row public.academic_performance;
  target public.academic_performance;
  category jsonb;
  category_id bigint;
  target_count integer := 0;
begin
  account := private.api_account(p_token);
  select * into source_row from public.academic_performance
    where performance_id=p_performance_id and student_id=account.student_id;
  if not found then raise exception 'Subject not found' using errcode='P0001'; end if;
  if not private.valid_assessment_categories(p_categories) then
    raise exception 'Category names and weights are invalid' using errcode='P0001';
  end if;

  -- Lock the complete target set so concurrent edits cannot interleave.
  for target in select * from public.academic_performance
      where student_id=account.student_id
        and (performance_id=source_row.performance_id or
             (p_apply_all and period_id=source_row.period_id))
      order by performance_id for update
  loop
    target_count := target_count+1;
    if exists (
      select 1 from public.assessment_components c
      join public.assessments a on a.component_id=c.component_id
      where c.performance_id=target.performance_id and c.student_id=account.student_id
        and (target.performance_id<>source_row.performance_id or not exists (
          select 1 from jsonb_array_elements(p_categories) item
          where nullif(item->>'component_id','')::bigint=c.component_id
        ))
    ) then
      raise exception 'A category with saved work cannot be replaced. Edit that subject separately.' using errcode='P0001';
    end if;

    -- The row-level weight check requires free capacity before any increase.
    update public.assessment_components set weight_percent=0
      where performance_id=target.performance_id and student_id=account.student_id;
    if target.performance_id=source_row.performance_id then
      delete from public.assessment_components c
        where c.performance_id=target.performance_id and c.student_id=account.student_id
          and not exists (select 1 from jsonb_array_elements(p_categories) item
            where nullif(item->>'component_id','')::bigint=c.component_id);
    else
      delete from public.assessment_components
        where performance_id=target.performance_id and student_id=account.student_id;
    end if;

    for category in select value from jsonb_array_elements(p_categories) loop
      category_id := case when target.performance_id=source_row.performance_id
        then nullif(category->>'component_id','')::bigint else null end;
      if category_id is not null then
        update public.assessment_components set name=btrim(category->>'name'),
          component_type=category->>'type',weight_percent=(category->>'weight')::numeric
          where component_id=category_id and performance_id=target.performance_id
            and student_id=account.student_id;
        if not found then raise exception 'Category no longer belongs to this subject' using errcode='P0001'; end if;
      else
        insert into public.assessment_components
          (student_id,performance_id,name,component_type,weight_percent)
        values (account.student_id,target.performance_id,btrim(category->>'name'),
          category->>'type',(category->>'weight')::numeric);
      end if;
    end loop;
  end loop;
  return jsonb_build_object('updated_subjects',target_count);
end $$;

create or replace function public.replace_assessment_categories_batch(
  p_token text, p_performance_id bigint, p_categories jsonb, p_apply_all boolean
) returns jsonb language sql security invoker set search_path='' as $$
  select private.replace_assessment_categories_batch(p_token,p_performance_id,p_categories,p_apply_all)
$$;
revoke all on function private.replace_assessment_categories_batch(text,bigint,jsonb,boolean)
  from public,anon,authenticated;
revoke all on function public.replace_assessment_categories_batch(text,bigint,jsonb,boolean) from public;
grant execute on function public.replace_assessment_categories_batch(text,bigint,jsonb,boolean)
  to anon,authenticated;
