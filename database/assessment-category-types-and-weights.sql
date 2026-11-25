-- Match the saved category model to the editor and permit zero during
-- transactional replacement before the new weights are applied.
alter table public.assessment_components
  drop constraint if exists assessment_components_component_type_check;
alter table public.assessment_components
  add constraint assessment_components_component_type_check
  check (component_type in ('assignment','quiz','midterm','final','exam','coursework','formative','section_summative','quarter_summative','other'));
alter table public.assessment_components
  drop constraint if exists assessment_components_weight_percent_check;
alter table public.assessment_components
  add constraint assessment_components_weight_percent_check
  check (weight_percent >= 0 and weight_percent <= 100);

create or replace function private.valid_assessment_categories(value jsonb)
returns boolean language sql immutable set search_path='' as $$
select jsonb_typeof(value)='array' and jsonb_array_length(value) between 1 and 12
  and not exists(select 1 from jsonb_array_elements(value) item
    where nullif(btrim(item->>'name'),'') is null
      or (item->>'type') not in ('assignment','quiz','midterm','final','exam','coursework','formative','section_summative','quarter_summative','other')
      or coalesce((item->>'weight')::numeric,-1)<0
      or coalesce((item->>'weight')::numeric,101)>100)
  and abs((select coalesce(sum((item->>'weight')::numeric),0)
    from jsonb_array_elements(value) item)-100)<0.001
$$;
