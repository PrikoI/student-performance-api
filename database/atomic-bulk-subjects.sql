CREATE OR REPLACE FUNCTION private.create_subject_records_atomic(p_session_token text, p_subjects jsonb)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE item jsonb; saved jsonb; results jsonb := '[]'::jsonb; subject_count integer;
BEGIN
  PERFORM private.session_student(p_session_token);
  IF jsonb_typeof(p_subjects) <> 'array' THEN
    RAISE EXCEPTION 'Subjects must be an array' USING ERRCODE='22023';
  END IF;
  subject_count := jsonb_array_length(p_subjects);
  IF subject_count < 1 OR subject_count > 50 THEN
    RAISE EXCEPTION 'Add between 1 and 50 subjects' USING ERRCODE='22023';
  END IF;
  FOR item IN SELECT value FROM jsonb_array_elements(p_subjects)
  LOOP
    saved := private.create_subject_record(p_session_token, item);
    results := results || jsonb_build_array(saved);
  END LOOP;
  RETURN jsonb_build_object('count', subject_count, 'items', results);
END $$;

CREATE OR REPLACE FUNCTION public.create_subject_records_atomic(p_session_token text, p_subjects jsonb)
RETURNS jsonb
LANGUAGE sql SECURITY INVOKER SET search_path='' AS $$
  SELECT private.create_subject_records_atomic(p_session_token, p_subjects)
$$;

REVOKE ALL ON FUNCTION private.create_subject_records_atomic(text,jsonb), public.create_subject_records_atomic(text,jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.create_subject_records_atomic(text,jsonb) TO anon, authenticated;
