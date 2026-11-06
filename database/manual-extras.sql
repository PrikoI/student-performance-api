
CREATE FUNCTION private.api_save_extra(p_token text,p_entity text,p_data jsonb) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE a public.accounts; result jsonb; scale bigint; bid bigint;
BEGIN
 a=private.api_account(p_token);
 IF p_entity='students' THEN
 IF EXISTS(SELECT 1 FROM jsonb_object_keys(p_data) k WHERE k NOT IN ('full_name','group_name')) THEN RAISE EXCEPTION 'Only full_name and group_name are editable'; END IF;
 UPDATE public.students SET full_name=coalesce(p_data->>'full_name',full_name),group_name=coalesce(p_data->>'group_name',group_name) WHERE student_id=a.student_id RETURNING to_jsonb(students) INTO result;
 ELSIF p_entity='user_preferences' THEN
 IF EXISTS(SELECT 1 FROM jsonb_object_keys(p_data) k WHERE k NOT IN ('language','display_mode','accent_color')) THEN RAISE EXCEPTION 'Unknown preference'; END IF;
 INSERT INTO public.user_preferences(account_id) VALUES(a.account_id) ON CONFLICT DO NOTHING;
 UPDATE public.user_preferences SET language=coalesce(p_data->>'language',language),display_mode=coalesce(p_data->>'display_mode',display_mode),accent_color=coalesce(p_data->>'accent_color',accent_color) WHERE account_id=a.account_id RETURNING to_jsonb(user_preferences) INTO result;
 ELSIF p_entity='grading_bands' THEN
 IF EXISTS(SELECT 1 FROM jsonb_object_keys(p_data) k WHERE k NOT IN ('band_id','scale_id','score_range','letter_grade','grade_points')) THEN RAISE EXCEPTION 'Unknown band field'; END IF;
 scale=(p_data->>'scale_id')::bigint;bid=(p_data->>'band_id')::bigint;
 IF NOT EXISTS(SELECT 1 FROM public.grading_scales WHERE scale_id=scale AND student_id=a.student_id) THEN RAISE EXCEPTION 'Scale not owned'; END IF;
 IF bid IS NULL THEN
 INSERT INTO public.grading_bands(scale_id,score_range,letter_grade,grade_points) VALUES(scale,(p_data->>'score_range')::numrange,p_data->>'letter_grade',(p_data->>'grade_points')::numeric) RETURNING to_jsonb(grading_bands) INTO result;
 ELSE
 UPDATE public.grading_bands b SET score_range=coalesce((p_data->>'score_range')::numrange,b.score_range),letter_grade=coalesce(p_data->>'letter_grade',b.letter_grade),grade_points=coalesce((p_data->>'grade_points')::numeric,b.grade_points) WHERE b.band_id=bid AND b.scale_id=scale RETURNING to_jsonb(b) INTO result;
 END IF;
 ELSIF p_entity='courses' THEN
 UPDATE public.courses SET course_name=p_data->>'course_name' WHERE course_id=(p_data->>'course_id')::int AND owner_student_id=a.student_id RETURNING to_jsonb(courses) INTO result;
 ELSE RAISE EXCEPTION 'Unsupported entity'; END IF;
 IF result IS NULL THEN RAISE EXCEPTION 'Owned record not found'; END IF;
 RETURN result;
END $$;
CREATE FUNCTION public.api_save_extra(p_token text,p_entity text,p_data jsonb) RETURNS jsonb LANGUAGE sql SECURITY INVOKER SET search_path='' AS $$ SELECT private.api_save_extra(p_token,p_entity,p_data); $$;
CREATE FUNCTION private.api_preferences(p_token text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE a public.accounts; result jsonb;
BEGIN
 a=private.api_account(p_token);
 SELECT to_jsonb(p) INTO result FROM public.user_preferences p WHERE account_id=a.account_id;
 RETURN coalesce(result,'{}'::jsonb);
END $$;
CREATE FUNCTION public.api_preferences(p_token text) RETURNS jsonb LANGUAGE sql SECURITY INVOKER SET search_path='' AS $$ SELECT private.api_preferences(p_token); $$;
REVOKE ALL ON FUNCTION public.api_save_extra(text,text,jsonb),private.api_save_extra(text,text,jsonb),public.api_preferences(text),private.api_preferences(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.api_save_extra(text,text,jsonb),private.api_save_extra(text,text,jsonb),public.api_preferences(text),private.api_preferences(text) TO anon,authenticated;

