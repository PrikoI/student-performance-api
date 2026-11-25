-- Private forecasting infrastructure. Training inputs and later outcomes are
-- deliberately stored apart to prevent target leakage.

alter table public.predictions add column if not exists normalization_version text;
alter table public.predictions add column if not exists model_manifest jsonb not null default '[]'::jsonb;

create table if not exists private.forecast_data_sources(
  source_id bigserial primary key,
  source_key text not null unique,
  source_class text not null check(source_class in ('local_anonymized','external','template','synthetic')),
  title text not null,
  provenance jsonb not null default '{}'::jsonb,
  active boolean not null default true,
  created_at timestamptz not null default now()
);

create table if not exists private.forecast_model_registry(
  model_id bigserial primary key,
  model_key text not null,
  model_version text not null,
  task text not null check(task in ('normalization','grade_forecast','risk_classification','personal_trend','external_reference','ensemble')),
  algorithm text not null,
  lifecycle_status text not null check(lifecycle_status in ('scaffold','serving','retired')),
  validation_status text not null default 'unvalidated' check(validation_status in ('unvalidated','experimental','validated','rejected')),
  feature_schema_version text,
  artifact_uri text,
  artifact_sha256 text,
  training_data_fingerprint text,
  training_sample_count integer check(training_sample_count is null or training_sample_count>=0),
  trained_at timestamptz,
  configuration jsonb not null default '{}'::jsonb,
  metrics jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(model_key,model_version)
);

create table if not exists private.forecast_model_evaluations(
  evaluation_id bigserial primary key,
  model_id bigint not null references private.forecast_model_registry(model_id) on delete cascade,
  split_strategy text not null,
  cohort jsonb not null default '{}'::jsonb,
  sample_count integer not null check(sample_count>=0),
  metrics jsonb not null,
  notes text,
  evaluated_at timestamptz not null default now()
);

create table if not exists private.forecast_ensemble_weights(
  weight_id bigserial primary key,
  ensemble_model_id bigint not null references private.forecast_model_registry(model_id) on delete cascade,
  component_model_id bigint not null references private.forecast_model_registry(model_id) on delete cascade,
  context_key text not null,
  weight numeric not null check(weight>=0 and weight<=1),
  basis text not null check(basis in ('engineering_initial','research_prior','validation')),
  valid_from timestamptz not null default now(),
  valid_to timestamptz,
  unique(ensemble_model_id,component_model_id,context_key,valid_from),
  check(valid_to is null or valid_to>valid_from)
);

create table if not exists private.forecast_feature_snapshots(
  snapshot_id bigserial primary key,
  prediction_id integer references public.predictions(prediction_id) on delete cascade,
  student_id integer not null references public.students(student_id) on delete cascade,
  pseudonymous_student_key text not null,
  performance_id integer not null references public.academic_performance(performance_id) on delete cascade,
  period_id integer not null references public.academic_periods(period_id) on delete cascade,
  course_id integer references public.courses(course_id) on delete set null,
  source_id bigint not null references private.forecast_data_sources(source_id),
  captured_at timestamptz not null default now(),
  captured_on date not null default current_date,
  feature_schema_version text not null,
  feature_payload jsonb not null check(jsonb_typeof(feature_payload)='object'),
  created_at timestamptz not null default now(),
  unique(prediction_id,performance_id)
);
create index if not exists forecast_feature_snapshots_training_idx on private.forecast_feature_snapshots(feature_schema_version,captured_at);
create index if not exists forecast_feature_snapshots_group_idx on private.forecast_feature_snapshots(pseudonymous_student_key,period_id);

create table if not exists private.forecast_snapshot_outcomes(
  snapshot_id bigint primary key references private.forecast_feature_snapshots(snapshot_id) on delete cascade,
  actual_id bigint not null references public.actual_results(actual_id) on delete cascade,
  actual_grade_raw numeric not null,
  actual_grade_percent numeric not null check(actual_grade_percent between 0 and 100),
  source_recorded_at timestamptz,
  linked_at timestamptz not null default now()
);

create table if not exists private.forecast_prediction_models(
  prediction_id integer not null references public.predictions(prediction_id) on delete cascade,
  model_id bigint not null references private.forecast_model_registry(model_id),
  role text not null,
  effective_weight numeric check(effective_weight is null or effective_weight between 0 and 1),
  details jsonb not null default '{}'::jsonb,
  primary key(prediction_id,model_id,role)
);

-- Cover the relationship columns used by history, labeling and cleanup jobs.
-- These are deliberately narrow indexes; they do not expose model metadata.
create index if not exists predictions_student_period_idx on public.predictions(student_id,period_id);
create index if not exists actual_results_student_performance_idx on public.actual_results(student_id,performance_id);
create index if not exists forecast_local_observations_student_idx on private.forecast_local_observations(student_id);
create index if not exists forecast_model_evaluations_model_idx on private.forecast_model_evaluations(model_id);
create index if not exists forecast_ensemble_weights_ensemble_idx on private.forecast_ensemble_weights(ensemble_model_id);
create index if not exists forecast_ensemble_weights_component_idx on private.forecast_ensemble_weights(component_model_id);
create index if not exists forecast_feature_snapshots_prediction_idx on private.forecast_feature_snapshots(prediction_id);
create index if not exists forecast_feature_snapshots_student_idx on private.forecast_feature_snapshots(student_id);
create index if not exists forecast_feature_snapshots_performance_idx on private.forecast_feature_snapshots(performance_id);
create index if not exists forecast_feature_snapshots_period_idx on private.forecast_feature_snapshots(period_id);
create index if not exists forecast_feature_snapshots_course_idx on private.forecast_feature_snapshots(course_id);
create index if not exists forecast_feature_snapshots_source_idx on private.forecast_feature_snapshots(source_id);
create index if not exists forecast_snapshot_outcomes_actual_idx on private.forecast_snapshot_outcomes(actual_id);
create index if not exists forecast_prediction_models_model_idx on private.forecast_prediction_models(model_id);

alter table private.forecast_data_sources enable row level security;
alter table private.forecast_model_registry enable row level security;
alter table private.forecast_model_evaluations enable row level security;
alter table private.forecast_ensemble_weights enable row level security;
alter table private.forecast_feature_snapshots enable row level security;
alter table private.forecast_snapshot_outcomes enable row level security;
alter table private.forecast_prediction_models enable row level security;

insert into private.forecast_data_sources(source_key,source_class,title,provenance) values
 ('perfecta-anonymized','local_anonymized','Perfecta anonymized academic outcomes','{"contains_personal_identifiers":false}'::jsonb),
 ('perfecta-template','template','Perfecta template accounts','{"training_allowed":false}'::jsonb),
 ('uci-student-performance','external','UCI Student Performance','{"country":"Portugal","transfer_validation_required":true}'::jsonb)
on conflict(source_key) do update set source_class=excluded.source_class,title=excluded.title,provenance=excluded.provenance;

insert into private.forecast_model_registry(model_key,model_version,task,algorithm,lifecycle_status,validation_status,feature_schema_version,configuration) values
 ('academic-normalizer','v1','normalization','deterministic','serving','unvalidated','normalized-academic-v1','{"output_scale":"0-100"}'::jsonb),
 ('personal-baseline','v1','grade_forecast','deterministic','serving','unvalidated','normalized-academic-v1','{"current_weight":0.8,"recent_weight":0.2}'::jsonb),
 ('adaptive-course','v1','personal_trend','deterministic','serving','unvalidated','normalized-academic-v1','{}'::jsonb),
 ('historical-projection','v1','external_reference','linear-nearest-neighbour-blend','serving','unvalidated','normalized-academic-v1','{"external_weight":0.25}'::jsonb),
 ('baseline-reference','v2','ensemble','weighted-blend','serving','unvalidated','normalized-academic-v1','{}'::jsonb),
 ('adaptive-reference','v2','ensemble','weighted-blend','serving','unvalidated','normalized-academic-v1','{}'::jsonb),
 ('gradient-boosting-risk','scaffold-v1','risk_classification','gradient-boosting','scaffold','unvalidated','normalized-academic-v1','{"target":"configured_failure_threshold"}'::jsonb),
 ('gradient-boosting-grade','scaffold-v1','grade_forecast','gradient-boosting','scaffold','unvalidated','normalized-academic-v1','{"target":"actual_grade_percent"}'::jsonb)
on conflict(model_key,model_version) do update set task=excluded.task,algorithm=excluded.algorithm,lifecycle_status=excluded.lifecycle_status,feature_schema_version=excluded.feature_schema_version,configuration=excluded.configuration,updated_at=now();

insert into private.forecast_ensemble_weights(ensemble_model_id,component_model_id,context_key,weight,basis)
select e.model_id,c.model_id,'nearest_period',x.weight,'engineering_initial'
from (values ('baseline-reference','personal-baseline',0.75::numeric),('baseline-reference','historical-projection',0.25::numeric),('adaptive-reference','adaptive-course',0.75::numeric),('adaptive-reference','historical-projection',0.25::numeric)) x(ensemble_key,component_key,weight)
join private.forecast_model_registry e on e.model_key=x.ensemble_key and e.model_version='v2'
join private.forecast_model_registry c on c.model_key=x.component_key and c.model_version='v1'
where not exists(select 1 from private.forecast_ensemble_weights w where w.ensemble_model_id=e.model_id and w.component_model_id=c.model_id and w.context_key='nearest_period' and w.valid_to is null);

create or replace function private.normalize_forecast_grade(p_value numeric,p_calendar text,p_scale text,p_min numeric,p_max numeric) returns numeric
language plpgsql immutable set search_path='' as $$
begin
 if p_value is null then return null; end if;
 if p_scale='five_point' or p_calendar='quarter' then
  if p_value=2 then return 20; elsif p_value=3 then return 52; elsif p_value=4 then return 74.5; elsif p_value=5 then return 92.5; end if;
  return greatest(0,least(100,p_value));
 end if;
 if p_max is null or p_min is null or p_max<=p_min then raise exception 'Numeric grading scale required'; end if;
 return greatest(0,least(100,100*(p_value-p_min)/(p_max-p_min)));
end $$;

create or replace function private.link_forecast_outcome() returns trigger language plpgsql security definer set search_path='' as $$
declare calendar text; scale_name text; grade_min numeric; grade_max numeric; normalized numeric;
begin
 select s.calendar_type,s.grading_scale,s.grade_min,s.grade_max into calendar,scale_name,grade_min,grade_max
 from public.academic_performance ap join public.academic_periods p on p.period_id=ap.period_id join public.academic_settings s on s.settings_id=p.settings_id
 where ap.performance_id=new.performance_id and ap.student_id=new.student_id;
 normalized=private.normalize_forecast_grade(new.final_grade,calendar,scale_name,grade_min,grade_max);
 if normalized is null then return new; end if;
 insert into private.forecast_snapshot_outcomes(snapshot_id,actual_id,actual_grade_raw,actual_grade_percent,source_recorded_at,linked_at)
 select fs.snapshot_id,new.actual_id,new.final_grade,normalized,new.recorded_at,now() from private.forecast_feature_snapshots fs
 where fs.performance_id=new.performance_id and fs.student_id=new.student_id
 on conflict(snapshot_id) do update set actual_id=excluded.actual_id,actual_grade_raw=excluded.actual_grade_raw,actual_grade_percent=excluded.actual_grade_percent,source_recorded_at=excluded.source_recorded_at,linked_at=now();
 return new;
end $$;
drop trigger if exists link_forecast_outcome on public.actual_results;
create trigger link_forecast_outcome after insert or update of final_grade on public.actual_results for each row execute function private.link_forecast_outcome();

create or replace view private.forecast_training_rows with (security_invoker=true) as
select fs.snapshot_id,fs.pseudonymous_student_key,fs.period_id,fs.course_id,ds.source_key,ds.source_class,fs.captured_at,fs.feature_schema_version,fs.feature_payload,
       o.actual_grade_percent,o.source_recorded_at
from private.forecast_feature_snapshots fs
join private.forecast_data_sources ds using(source_id)
join private.forecast_snapshot_outcomes o using(snapshot_id)
where ds.active and ds.source_class not in ('template','synthetic');

create or replace function private.api_forecast_infrastructure_status(p_token text) returns jsonb language plpgsql security definer set search_path='' as $$
declare a public.accounts; result jsonb;
begin
 a=private.api_account(p_token);
 if a.role<>'admin' then raise exception 'Administrator required' using errcode='42501'; end if;
 select jsonb_build_object(
  'normalization_version','normalized-academic-v1',
  'snapshots',(select count(*) from private.forecast_feature_snapshots),
  'labeled_snapshots',(select count(*) from private.forecast_snapshot_outcomes),
  'training_rows',(select count(*) from private.forecast_training_rows),
  'sources',coalesce((select jsonb_agg(jsonb_build_object('key',source_key,'class',source_class,'active',active) order by source_key) from private.forecast_data_sources),'[]'::jsonb),
  'models',coalesce((select jsonb_agg(jsonb_build_object('key',model_key,'version',model_version,'task',task,'lifecycle',lifecycle_status,'validation',validation_status,'samples',training_sample_count) order by model_id) from private.forecast_model_registry),'[]'::jsonb)
 ) into result;
 return result;
end $$;
create or replace function public.api_forecast_infrastructure_status(p_token text) returns jsonb language sql security invoker set search_path='' as $$ select private.api_forecast_infrastructure_status(p_token); $$;

create or replace function private.set_prediction_forecast_metadata() returns trigger language plpgsql set search_path='' as $$
begin
 new.normalization_version=coalesce(new.result_snapshot->>'normalization_version',new.normalization_version,'normalized-academic-v1');
 new.model_manifest=coalesce(new.result_snapshot->'model_manifest',new.model_manifest,'[]'::jsonb);
 return new;
end $$;
drop trigger if exists set_prediction_forecast_metadata on public.predictions;
create trigger set_prediction_forecast_metadata before insert on public.predictions for each row execute function private.set_prediction_forecast_metadata();

create or replace function private.capture_prediction_forecast_snapshot() returns trigger language plpgsql security definer set search_path='' as $$
declare item jsonb; manifest_item jsonb; r public.academic_performance; owner_account_id uuid; is_demo boolean; source_key text; source_pk bigint; source_period_id integer; snapshot jsonb; model_pk bigint;
begin
 select a.account_id,c.is_demo into owner_account_id,is_demo
 from public.accounts a
 join private.account_credentials c on c.account_id=a.account_id
 where a.student_id=new.student_id;
 source_key=case when is_demo then 'perfecta-template' else 'perfecta-anonymized' end;
 select d.source_id into source_pk from private.forecast_data_sources d where d.source_key=source_key;
 source_period_id=coalesce((new.result_snapshot->>'source_period_id')::integer,new.period_id);
 for item in select value from jsonb_array_elements(coalesce(new.result_snapshot->'subjects','[]'::jsonb)) loop
  select * into r from public.academic_performance where performance_id=(item->>'performance_id')::integer and student_id=new.student_id and period_id=source_period_id;
  if found then
   snapshot=coalesce(item->'normalized_snapshot',jsonb_build_object('schema_version','normalized-academic-v1','current_score_percent',item->'normalized_current_percent'));
   insert into private.forecast_feature_snapshots(prediction_id,student_id,pseudonymous_student_key,performance_id,period_id,course_id,source_id,feature_schema_version,feature_payload)
   values(new.prediction_id,new.student_id,encode(extensions.digest(new.student_id::text||':'||owner_account_id::text,'sha256'),'hex'),r.performance_id,r.period_id,r.course_id,source_pk,coalesce(snapshot->>'schema_version','normalized-academic-v1'),snapshot)
   on conflict(prediction_id,performance_id) do nothing;
  end if;
 end loop;
 for manifest_item in select value from jsonb_array_elements(coalesce(new.model_manifest,'[]'::jsonb)) loop
  select m.model_id into model_pk from private.forecast_model_registry m where m.model_key=manifest_item->>'key' and m.model_version=manifest_item->>'version';
  if model_pk is not null then
   insert into private.forecast_prediction_models(prediction_id,model_id,role,effective_weight,details)
   values(new.prediction_id,model_pk,coalesce(manifest_item->>'role','component'),(manifest_item->>'weight')::numeric,manifest_item)
   on conflict(prediction_id,model_id,role) do nothing;
  end if;
 end loop;
 return new;
end $$;
drop trigger if exists capture_prediction_forecast_snapshot on public.predictions;
create trigger capture_prediction_forecast_snapshot after insert on public.predictions for each row execute function private.capture_prediction_forecast_snapshot();

revoke all on table private.forecast_data_sources,private.forecast_model_registry,private.forecast_model_evaluations,private.forecast_ensemble_weights,private.forecast_feature_snapshots,private.forecast_snapshot_outcomes,private.forecast_prediction_models from public,anon,authenticated;
revoke all on function private.normalize_forecast_grade(numeric,text,text,numeric,numeric),private.link_forecast_outcome(),private.api_forecast_infrastructure_status(text) from public;
revoke all on function private.set_prediction_forecast_metadata(),private.capture_prediction_forecast_snapshot() from public;
revoke all on function public.api_forecast_infrastructure_status(text) from public;
grant execute on function public.api_forecast_infrastructure_status(text) to anon,authenticated;
grant execute on function private.api_forecast_infrastructure_status(text) to anon,authenticated;
