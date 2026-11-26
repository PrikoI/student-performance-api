-- Generic assessment tree. Each sibling group has its own 100% scale.
alter table public.assessment_components
  add column if not exists parent_component_id bigint;
create index if not exists assessment_components_parent_idx
  on public.assessment_components(parent_component_id);
alter table public.assessment_components
  drop constraint if exists assessment_components_parent_component_id_student_id_fkey;
alter table public.assessment_components
  add constraint assessment_components_parent_component_id_student_id_fkey
  foreign key(parent_component_id,student_id)
  references public.assessment_components(component_id,student_id);

create or replace function private.validate_assessment_component_weights()
returns trigger language plpgsql set search_path='' as $$
declare total numeric;
begin
  select coalesce(sum(weight_percent),0) into total
  from public.assessment_components
  where performance_id=new.performance_id
    and parent_component_id is not distinct from new.parent_component_id
    and component_id<>coalesce(new.component_id,-1);
  if total+new.weight_percent>100.0001 then
    raise exception 'Weights in one category level cannot exceed 100%%' using errcode='23514';
  end if;
  return new;
end $$;

create or replace function private.validate_assessment_component_weight_total()
returns trigger language plpgsql security definer set search_path='' as $$
declare group_performance integer; group_parent bigint; total numeric;
begin
  for group_performance,group_parent in
    select distinct performance_id,parent_component_id from (
      select new.performance_id,new.parent_component_id where tg_op<>'DELETE'
      union all
      select old.performance_id,old.parent_component_id where tg_op<>'INSERT'
    ) groups
  loop
    select coalesce(sum(weight_percent),0) into total
    from public.assessment_components
    where performance_id=group_performance
      and parent_component_id is not distinct from group_parent;
    if total>100.0001 then
      raise exception 'Weights in one category level cannot exceed 100%%' using errcode='23514';
    end if;
  end loop;
  return null;
end $$;

create or replace function private.validate_assessment_parent()
returns trigger language plpgsql set search_path='' as $$
declare parent_performance integer;
begin
  if new.parent_component_id is null then return new; end if;
  if new.parent_component_id=new.component_id then
    raise exception 'A category cannot contain itself' using errcode='23514';
  end if;
  select performance_id into parent_performance from public.assessment_components
    where component_id=new.parent_component_id and student_id=new.student_id;
  if parent_performance is distinct from new.performance_id then
    raise exception 'Parent category belongs to another subject' using errcode='23514';
  end if;
  if exists (
    with recursive ancestors as (
      select component_id,parent_component_id from public.assessment_components
        where component_id=new.parent_component_id
      union all
      select c.component_id,c.parent_component_id from public.assessment_components c
        join ancestors a on c.component_id=a.parent_component_id
    ) select 1 from ancestors where component_id=new.component_id
  ) then raise exception 'Category cycle is not allowed' using errcode='23514'; end if;
  return new;
end $$;
drop trigger if exists validate_assessment_parent on public.assessment_components;
create trigger validate_assessment_parent before insert or update of parent_component_id,performance_id
on public.assessment_components for each row execute function private.validate_assessment_parent();

create or replace function private.recalculate_performance_grade(p_performance_id integer)
returns void language plpgsql security definer set search_path='' as $$
declare total_weight numeric; leaf_count integer; ready_count integer; percent_score numeric;
        calendar text; scale_name text; scale_min numeric; scale_max numeric; converted numeric;
begin
  select coalesce(sum(weight_percent),0) into total_weight from public.assessment_components
    where performance_id=p_performance_id and parent_component_id is null;
  if abs(total_weight-100)>.0001 then return; end if;
  with recursive leaves as (
    select c.component_id,c.parent_component_id,c.weight_percent,
      (select sum(r.score)/nullif(sum(a.maximum_score),0)*100
       from public.assessments a join public.assessment_results r
       on r.assessment_id=a.assessment_id and r.status='graded' and r.score is not null
       where a.component_id=c.component_id) as score
    from public.assessment_components c where c.performance_id=p_performance_id
      and not exists(select 1 from public.assessment_components child
                     where child.parent_component_id=c.component_id)
  ), paths as (
    select component_id,parent_component_id,weight_percent/100 as share,score from leaves
    union all
    select parent.component_id,parent.parent_component_id,
           paths.share*parent.weight_percent/100,paths.score
    from paths join public.assessment_components parent
      on parent.component_id=paths.parent_component_id
  )
  select count(*),count(score),sum(score*share)
  into leaf_count,ready_count,percent_score from paths where parent_component_id is null;
  if leaf_count=0 or ready_count<>leaf_count or percent_score is null then return; end if;
  select s.calendar_type,s.grading_scale,s.grade_min,s.grade_max
  into calendar,scale_name,scale_min,scale_max
  from public.academic_performance ap join public.academic_periods p on p.period_id=ap.period_id
  join public.academic_settings s on s.settings_id=p.settings_id where ap.performance_id=p_performance_id;
  converted=case when scale_name='five_point' or calendar='quarter' then
    case when percent_score>=85 then 5 when percent_score>=65 then 4 when percent_score>=40 then 3 else 2 end
    else scale_min+(scale_max-scale_min)*percent_score/100 end;
  update public.academic_performance set current_grade=round(converted,2),updated_at=now()
    where performance_id=p_performance_id;
end $$;

create or replace function private.replace_assessment_hierarchy(
  p_token text,p_performance_id bigint,p_nodes jsonb
) returns jsonb language plpgsql security definer set search_path='' as $$
declare account public.accounts; node jsonb; node_index integer; parent_index integer;
        ids bigint[]:=array[]::bigint[]; item_id bigint; parent_id bigint;
        existing_id bigint; existing_count integer; group_total numeric;
        depth integer[]:=array[]::integer[]; item_depth integer; move_index integer;
begin
  account:=private.api_account(p_token);
  if not exists(select 1 from public.academic_performance
                where performance_id=p_performance_id and student_id=account.student_id) then
    raise exception 'Subject not found' using errcode='P0001'; end if;
  if jsonb_typeof(p_nodes)<>'array' or jsonb_array_length(p_nodes) not between 1 and 60 then
    raise exception 'Add 1 to 60 categories' using errcode='P0001'; end if;
  select count(distinct (item->>'component_id')::bigint) into existing_count
  from jsonb_array_elements(p_nodes) item where nullif(item->>'component_id','') is not null;
  if existing_count<>(select count(*) from jsonb_array_elements(p_nodes) item
                       where nullif(item->>'component_id','') is not null) then
    raise exception 'Duplicate category' using errcode='P0001'; end if;
  for node_index in 0..jsonb_array_length(p_nodes)-1 loop
    node:=p_nodes->node_index;
    if nullif(btrim(node->>'name'),'') is null or length(node->>'name')>100
       or coalesce(node->>'type','') not in
          ('assignment','quiz','midterm','final','exam','coursework','formative',
           'section_summative','quarter_summative','other')
       or (node->>'weight')::numeric not between 0 and 100 then
      raise exception 'Invalid category name, type or weight' using errcode='P0001'; end if;
    parent_index:=nullif(node->>'parent_index','')::integer;
    if parent_index is not null and (parent_index<0 or parent_index>=node_index) then
      raise exception 'Parent must appear before its children' using errcode='P0001'; end if;
    item_depth:=case when parent_index is null then 1 else depth[parent_index+1]+1 end;
    if item_depth>6 then raise exception 'Category tree is too deep' using errcode='P0001'; end if;
    depth:=array_append(depth,item_depth);
  end loop;
  for parent_index in -1..jsonb_array_length(p_nodes)-1 loop
    select coalesce(sum((item->>'weight')::numeric),0) into group_total
    from jsonb_array_elements(p_nodes) item
    where coalesce((item->>'parent_index')::integer,-1)=parent_index;
    if (parent_index=-1 or exists(select 1 from jsonb_array_elements(p_nodes) item
                                  where (item->>'parent_index')::integer=parent_index))
       and abs(group_total-100)>.0001 then
      raise exception 'Each category level must total 100%%' using errcode='P0001'; end if;
  end loop;
  perform 1 from public.academic_performance where performance_id=p_performance_id for update;
  if exists(
    select 1 from public.assessment_components c join public.assessments a using(component_id)
    where c.performance_id=p_performance_id and c.student_id=account.student_id
      and not exists(select 1 from jsonb_array_elements(p_nodes) item
                     where nullif(item->>'component_id','')::bigint=c.component_id)
  ) then raise exception 'Remove saved work before deleting its category' using errcode='P0001'; end if;
  update public.assessment_components set weight_percent=0,parent_component_id=null
    where performance_id=p_performance_id and student_id=account.student_id;
  for node_index in 0..jsonb_array_length(p_nodes)-1 loop
    node:=p_nodes->node_index;
    existing_id:=nullif(node->>'component_id','')::bigint;
    parent_index:=nullif(node->>'parent_index','')::integer;
    parent_id:=case when parent_index is null then null else ids[parent_index+1] end;
    if existing_id is not null then
      update public.assessment_components set name=btrim(node->>'name'),
        component_type=node->>'type',parent_component_id=parent_id
      where component_id=existing_id and performance_id=p_performance_id
        and student_id=account.student_id;
      if not found then raise exception 'Category no longer belongs to this subject' using errcode='P0001'; end if;
      item_id:=existing_id;
    else
      insert into public.assessment_components
        (student_id,performance_id,name,component_type,weight_percent,parent_component_id)
      values(account.student_id,p_performance_id,btrim(node->>'name'),node->>'type',0,parent_id)
      returning component_id into item_id;
    end if;
    ids:=array_append(ids,item_id);
  end loop;
  for node_index in 0..jsonb_array_length(p_nodes)-1 loop
    move_index:=nullif(p_nodes->node_index->>'move_to_index','')::integer;
    if move_index is not null then
      if move_index<=node_index or move_index>=array_length(ids,1)
         or (p_nodes->move_index->>'parent_index')::integer<>node_index then
        raise exception 'Choose a direct subcategory for existing work' using errcode='P0001';
      end if;
      update public.assessments set component_id=ids[move_index+1]
      where component_id=ids[node_index+1] and student_id=account.student_id;
    end if;
  end loop;
  if exists(select 1 from public.assessment_components c join public.assessments a using(component_id)
            where c.component_id=any(ids) and exists(
              select 1 from public.assessment_components child where child.parent_component_id=c.component_id)) then
    raise exception 'Move saved work to a child before nesting its category' using errcode='P0001'; end if;
  delete from public.assessment_components
    where performance_id=p_performance_id and student_id=account.student_id
      and not (component_id=any(ids));
  for node_index in 0..jsonb_array_length(p_nodes)-1 loop
    update public.assessment_components set weight_percent=(p_nodes->node_index->>'weight')::numeric
    where component_id=ids[node_index+1];
  end loop;
  perform private.recalculate_performance_grade(p_performance_id::integer);
  return jsonb_build_object('saved_categories',array_length(ids,1));
end $$;
create or replace function public.replace_assessment_hierarchy(
  p_token text,p_performance_id bigint,p_nodes jsonb
) returns jsonb language sql security definer set search_path='' as $$
  select private.replace_assessment_hierarchy(p_token,p_performance_id,p_nodes)
$$;
revoke all on function private.replace_assessment_hierarchy(text,bigint,jsonb) from public,anon,authenticated;
revoke all on function public.replace_assessment_hierarchy(text,bigint,jsonb) from public;
grant execute on function public.replace_assessment_hierarchy(text,bigint,jsonb) to anon,authenticated;
