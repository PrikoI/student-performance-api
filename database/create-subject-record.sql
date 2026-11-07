CREATE OR REPLACE FUNCTION private.create_subject_record(p_session_token text,p_data jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE sid int; cid int; name text; result jsonb;
BEGIN
 sid=private.session_student(p_session_token);
 name=nullif(btrim(p_data->>'course_name'),'');
 IF name IS NULL OR length(name)>100 THEN RAISE EXCEPTION 'Valid course name required' USING ERRCODE='22023'; END IF;
 SELECT c.course_id INTO cid FROM public.courses c
 WHERE lower(btrim(c.course_name))=lower(name) AND (c.owner_student_id IS NULL OR c.owner_student_id=sid)
 ORDER BY c.owner_student_id NULLS LAST LIMIT 1;
 IF cid IS NULL THEN
   INSERT INTO public.courses(course_name,owner_student_id) VALUES(name,sid) RETURNING course_id INTO cid;
 END IF;
 result=private.save_student_record(p_session_token,'academic_performance',(p_data-'course_name')||jsonb_build_object('course_id',cid));
 RETURN result;
END $$;
CREATE OR REPLACE FUNCTION public.create_subject_record(p_session_token text,p_data jsonb) RETURNS jsonb
LANGUAGE sql SECURITY INVOKER SET search_path='' AS $$ SELECT private.create_subject_record(p_session_token,p_data); $$;
REVOKE ALL ON FUNCTION private.create_subject_record(text,jsonb),public.create_subject_record(text,jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.create_subject_record(text,jsonb) TO anon,authenticated;

