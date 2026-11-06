
CREATE FUNCTION private.api_account(p_token text) RETURNS public.accounts LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE a public.accounts;
BEGIN
 SELECT x.* INTO a FROM public.accounts x JOIN private.login_sessions s USING(account_id)
 WHERE s.session_hash=encode(extensions.digest(p_token,'sha256'),'hex') AND s.expires_at>now();
 IF a.account_id IS NULL THEN RAISE EXCEPTION 'Invalid session' USING ERRCODE='28000'; END IF;
 RETURN a;
END $$;
CREATE FUNCTION public.api_identity(p_token text) RETURNS jsonb LANGUAGE sql SECURITY INVOKER SET search_path='' AS $$ SELECT to_jsonb(private.api_account(p_token)); $$;
CREATE FUNCTION private.api_table(p_entity text) RETURNS text LANGUAGE plpgsql SET search_path='' AS $$
BEGIN
 IF p_entity NOT IN ('students','study_programs','academic_years','academic_periods','academic_settings','academic_performance','lesson_attendance','assessment_components','assessments','assessment_results','actual_results','notifications','academic_import_drafts','grading_scales','predictions','recommendations') THEN RAISE EXCEPTION 'Unsupported entity'; END IF;
 RETURN p_entity;
END $$;
CREATE FUNCTION private.api_pk(p_entity text) RETURNS text LANGUAGE sql SET search_path='' AS $$
 SELECT a.attname FROM pg_index i JOIN pg_attribute a ON a.attrelid=i.indrelid AND a.attnum=ANY(i.indkey)
 WHERE i.indrelid=to_regclass('public.'||p_entity) AND i.indisprimary LIMIT 1;
$$;
CREATE FUNCTION private.api_update(p_token text,p_entity text,p_id bigint,p_data jsonb) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE pk text;
BEGIN
 PERFORM private.api_table(p_entity); pk=private.api_pk(p_entity);
 RETURN private.save_student_record(p_token,p_entity,p_data||jsonb_build_object(pk,p_id));
END $$;
CREATE FUNCTION private.api_delete(p_token text,p_entity text,p_id bigint) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE a public.accounts; pk text; result jsonb;
BEGIN
 a=private.api_account(p_token); PERFORM private.api_table(p_entity); pk=private.api_pk(p_entity);
 IF p_entity IN ('students','predictions','recommendations') THEN RAISE EXCEPTION 'Deletion not supported for this entity'; END IF;
 EXECUTE format('DELETE FROM public.%I t WHERE %I=$1 AND student_id=$2 RETURNING to_jsonb(t)',p_entity,pk) INTO result USING p_id,a.student_id;
 IF result IS NULL THEN RAISE EXCEPTION 'Record not found for this student'; END IF;
 RETURN result;
END $$;
CREATE FUNCTION private.api_admin_search(p_token text,p_entity text,p_query text,p_student_id int,p_offset int,p_limit int) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE a public.accounts; rows jsonb; total bigint;
BEGIN
 a=private.api_account(p_token);
 IF a.role<>'admin' THEN RAISE EXCEPTION 'Administrator required' USING ERRCODE='42501'; END IF;
 IF p_entity NOT IN ('courses','accounts','prediction_details','grading_bands') THEN PERFORM private.api_table(p_entity); END IF;
 EXECUTE format('SELECT coalesce(jsonb_agg(x),''[]'') FROM (SELECT to_jsonb(t) x FROM public.%I t WHERE ($1 IS NULL OR to_jsonb(t)->>''student_id''=$1::text) AND ($2='''' OR to_jsonb(t)::text ILIKE ''%%''||$2||''%%'') ORDER BY %I LIMIT $3 OFFSET $4) q',p_entity,private.api_pk(p_entity))
 INTO rows USING p_student_id,coalesce(p_query,''),least(100,greatest(1,p_limit)),greatest(0,p_offset);
 EXECUTE format('SELECT count(*) FROM public.%I t WHERE ($1 IS NULL OR to_jsonb(t)->>''student_id''=$1::text) AND ($2='''' OR to_jsonb(t)::text ILIKE ''%%''||$2||''%%'')',p_entity)
 INTO total USING p_student_id,coalesce(p_query,'');
 RETURN jsonb_build_object('total',total,'items',rows);
END $$;
CREATE TABLE private.ai_configuration(singleton bool PRIMARY KEY DEFAULT true CHECK(singleton),config jsonb NOT NULL);
ALTER TABLE private.ai_configuration ENABLE ROW LEVEL SECURITY;
CREATE FUNCTION private.api_ai_config(p_token text,p_config jsonb) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE a public.accounts; result jsonb;
BEGIN
 a=private.api_account(p_token);
 IF p_config IS NOT NULL THEN
 IF a.role<>'admin' THEN RAISE EXCEPTION 'Administrator required' USING ERRCODE='42501'; END IF;
 INSERT INTO private.ai_configuration VALUES(true,p_config) ON CONFLICT(singleton) DO UPDATE SET config=excluded.config;
 END IF;
 SELECT config INTO result FROM private.ai_configuration WHERE singleton;
 RETURN result;
END $$;
ALTER TABLE public.predictions ADD COLUMN forecast_level text CHECK(forecast_level IN ('period','year','program')), ADD COLUMN result_snapshot jsonb;
CREATE FUNCTION private.api_save_prediction(p_token text,p_result jsonb) RETURNS int LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE a public.accounts; pid int; period public.academic_periods; r public.academic_performance; item jsonb; name text;
BEGIN
 a=private.api_account(p_token);
 SELECT * INTO period FROM public.academic_periods WHERE period_id=(p_result->>'period_id')::int AND student_id=a.student_id;
 IF NOT FOUND OR period.status<>'active' THEN RAISE EXCEPTION 'Active owned period required'; END IF;
 INSERT INTO public.predictions(student_id,period_id,method_version,is_illustrative,predicted_gpa,context_snapshot,forecast_level,result_snapshot)
 VALUES(a.student_id,period.period_id,p_result->>'method_version',1,(p_result->>'gpa')::numeric,to_jsonb(period)::text,p_result->>'level',p_result) RETURNING prediction_id INTO pid;
 FOR item IN SELECT value FROM jsonb_array_elements(p_result->'subjects') LOOP
 SELECT * INTO r FROM public.academic_performance WHERE performance_id=(item->>'performance_id')::int AND student_id=a.student_id AND period_id=period.period_id;
 IF NOT FOUND THEN RAISE EXCEPTION 'Invalid subject'; END IF;
 SELECT course_name INTO name FROM public.courses WHERE course_id=r.course_id;
 INSERT INTO public.prediction_details(prediction_id,subject_name_snapshot,course_id,credits_snapshot,current_grade_snapshot,attendance_snapshot,assignments_completed_snapshot,assignments_total_snapshot,recent_assessment_snapshot,predicted_grade,lessons_planned_snapshot,lessons_held_snapshot,lessons_attended_snapshot,lessons_excused_snapshot,explanation)
 VALUES(pid,name,r.course_id,r.credits,r.current_grade,r.attendance,r.assignments_completed,r.assignments_total,r.recent_assessment_score,(item->>'grade')::numeric,r.lessons_planned,r.lessons_held,r.lessons_attended,r.lessons_excused,p_result->>'assumption');
 END LOOP; RETURN pid;
END $$;
-- RPC wrappers: public functions don't elevate privileges. Private implementation verifies the session.
CREATE FUNCTION public.api_update(p_token text,p_entity text,p_id bigint,p_data jsonb) RETURNS jsonb LANGUAGE sql SECURITY INVOKER SET search_path='' AS $$ SELECT private.api_update(p_token,p_entity,p_id,p_data); $$;
CREATE FUNCTION public.api_delete(p_token text,p_entity text,p_id bigint) RETURNS jsonb LANGUAGE sql SECURITY INVOKER SET search_path='' AS $$ SELECT private.api_delete(p_token,p_entity,p_id); $$;
CREATE FUNCTION public.api_admin_search(p_token text,p_entity text,p_query text,p_student_id int,p_offset int,p_limit int) RETURNS jsonb LANGUAGE sql SECURITY INVOKER SET search_path='' AS $$ SELECT private.api_admin_search(p_token,p_entity,p_query,p_student_id,p_offset,p_limit); $$;
CREATE FUNCTION public.api_ai_config(p_token text,p_config jsonb) RETURNS jsonb LANGUAGE sql SECURITY INVOKER SET search_path='' AS $$ SELECT private.api_ai_config(p_token,p_config); $$;
CREATE FUNCTION public.api_save_prediction(p_token text,p_result jsonb) RETURNS int LANGUAGE sql SECURITY INVOKER SET search_path='' AS $$ SELECT private.api_save_prediction(p_token,p_result); $$;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA private FROM PUBLIC;
DO $$ DECLARE r record; BEGIN
 FOR r IN SELECT p.oid::regprocedure sig FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname IN ('public','private') AND p.proname IN ('api_identity','api_account','api_update','api_delete','api_admin_search','api_ai_config','api_save_prediction') LOOP
 EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC',r.sig);
 EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO anon,authenticated',r.sig);
 END LOOP;
END $$;
