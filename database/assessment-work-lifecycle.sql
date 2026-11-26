-- Delete a student's work and its grade atomically. The authenticated account is
-- checked before either row is changed.
create or replace function private.api_delete_work(p_token text,p_assessment_id bigint)
returns jsonb language plpgsql security definer set search_path='' as $$
declare owner_id integer; removed jsonb;
begin
  select a.student_id into owner_id from public.assessments a
  where a.assessment_id=p_assessment_id and a.student_id=(private.api_account(p_token)).student_id
  for update;
  if owner_id is null then raise exception 'Work not found' using errcode='P0002'; end if;
  delete from public.assessment_results
  where assessment_id=p_assessment_id and student_id=owner_id;
  delete from private.assessment_work_requests where assessment_id=p_assessment_id;
  delete from public.assessments a
  where a.assessment_id=p_assessment_id and a.student_id=owner_id
  returning to_jsonb(a) into removed;
  return removed;
end $$;
create or replace function public.api_delete_work(p_token text,p_assessment_id bigint)
returns jsonb language sql security invoker set search_path='' as $$
  select private.api_delete_work(p_token,p_assessment_id);
$$;
revoke all on function private.api_delete_work(text,bigint) from public;
revoke all on function public.api_delete_work(text,bigint) from public;
grant execute on function private.api_delete_work(text,bigint) to anon,authenticated;
grant execute on function public.api_delete_work(text,bigint) to anon,authenticated;

-- A request key survives a slow response or a retry. Locking the category also
-- makes automatic numbering reliable across browser tabs and web workers.
create table if not exists private.assessment_work_requests(
  account_id uuid not null,
  request_key uuid not null,
  assessment_id bigint not null,
  primary key(account_id,request_key)
);
alter table private.assessment_work_requests enable row level security;
create or replace function private.api_create_work(p_token text,p_request_key uuid,p_data jsonb,p_auto_title boolean)
returns jsonb language plpgsql security definer set search_path='' as $$
declare account public.accounts; saved_id bigint; category_id bigint; title_base text; next_number integer; result jsonb;
begin
  account=private.api_account(p_token);
  select assessment_id into saved_id from private.assessment_work_requests
    where account_id=account.account_id and request_key=p_request_key;
  if saved_id is not null then
    select to_jsonb(a) into result from public.assessments a
      where a.assessment_id=saved_id and a.student_id=account.student_id;
    return result;
  end if;
  category_id=(p_data->>'component_id')::bigint;
  perform 1 from public.assessment_components c
    where c.component_id=category_id and c.student_id=account.student_id for update;
  if not found then raise exception 'Category not found' using errcode='P0002'; end if;
  select assessment_id into saved_id from private.assessment_work_requests
    where account_id=account.account_id and request_key=p_request_key;
  if saved_id is not null then
    select to_jsonb(a) into result from public.assessments a
      where a.assessment_id=saved_id and a.student_id=account.student_id;
    return result;
  end if;
  if p_auto_title then
    title_base=trim(regexp_replace(p_data->>'title','[[:space:]]+[0-9]+$',''));
    if title_base='' then raise exception 'Work title required'; end if;
    select coalesce(max((regexp_match(a.title,'([0-9]+)$'))[1]::integer),0)+1 into next_number
      from public.assessments a where a.component_id=category_id and a.student_id=account.student_id
      and left(a.title,length(title_base)+1)=title_base||' '
      and substring(a.title from length(title_base)+2) ~ '^[0-9]+$';
    p_data=jsonb_set(p_data,'{title}',to_jsonb(title_base||' '||next_number));
  end if;
  result=private.save_student_record(p_token,'assessments',p_data);
  saved_id=(result->>'assessment_id')::bigint;
  insert into private.assessment_work_requests(account_id,request_key,assessment_id)
    values(account.account_id,p_request_key,saved_id);
  return result;
end $$;
create or replace function public.api_create_work(p_token text,p_request_key uuid,p_data jsonb,p_auto_title boolean)
returns jsonb language sql security invoker set search_path='' as $$
  select private.api_create_work(p_token,p_request_key,p_data,p_auto_title);
$$;
revoke all on function private.api_create_work(text,uuid,jsonb,boolean) from public;
revoke all on function public.api_create_work(text,uuid,jsonb,boolean) from public;
grant execute on function private.api_create_work(text,uuid,jsonb,boolean) to anon,authenticated;
grant execute on function public.api_create_work(text,uuid,jsonb,boolean) to anon,authenticated;

create or replace function private.api_save_work_grade(p_token text,p_assessment_id bigint,p_score numeric)
returns jsonb language plpgsql security definer set search_path='' as $$
declare owner_id integer; maximum numeric; result jsonb;
begin
  owner_id=(private.api_account(p_token)).student_id;
  select a.maximum_score into maximum from public.assessments a
    where a.assessment_id=p_assessment_id and a.student_id=owner_id for update;
  if maximum is null then raise exception 'Work not found' using errcode='P0002'; end if;
  if p_score is null or p_score<0 or p_score>maximum then
    raise exception 'Score is outside this work''s range' using errcode='23514';
  end if;
  insert into public.assessment_results(student_id,assessment_id,score,status)
    values(owner_id,p_assessment_id,p_score,'graded')
    on conflict(assessment_id,student_id) do update
    set score=excluded.score,status='graded',recorded_at=now()
    returning to_jsonb(assessment_results) into result;
  return result;
end $$;
create or replace function public.api_save_work_grade(p_token text,p_assessment_id bigint,p_score numeric)
returns jsonb language sql security invoker set search_path='' as $$
  select private.api_save_work_grade(p_token,p_assessment_id,p_score);
$$;
revoke all on function private.api_save_work_grade(text,bigint,numeric) from public;
revoke all on function public.api_save_work_grade(text,bigint,numeric) from public;
grant execute on function private.api_save_work_grade(text,bigint,numeric) to anon,authenticated;
grant execute on function public.api_save_work_grade(text,bigint,numeric) to anon,authenticated;
