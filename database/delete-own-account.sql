CREATE OR REPLACE FUNCTION private.delete_own_account(p_token text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE a public.accounts; target_email text; demo boolean;
BEGIN
  a=private.api_account(p_token);
  SELECT c.email,c.is_demo INTO target_email,demo FROM private.account_credentials c WHERE c.account_id=a.account_id;
  IF a.role='admin' THEN RAISE EXCEPTION 'Administrator account cannot be deleted' USING ERRCODE='42501'; END IF;
  IF COALESCE(demo,false) THEN RAISE EXCEPTION 'Demo accounts cannot be deleted' USING ERRCODE='42501'; END IF;
  DELETE FROM public.assessment_results WHERE student_id=a.student_id;
  DELETE FROM public.assessments WHERE student_id=a.student_id;
  DELETE FROM public.assessment_components WHERE student_id=a.student_id;
  DELETE FROM public.lesson_attendance WHERE student_id=a.student_id;
  DELETE FROM public.actual_results WHERE student_id=a.student_id;
  DELETE FROM public.recommendations WHERE student_id=a.student_id;
  DELETE FROM public.prediction_details d USING public.predictions p WHERE d.prediction_id=p.prediction_id AND p.student_id=a.student_id;
  DELETE FROM public.predictions WHERE student_id=a.student_id;
  DELETE FROM public.notifications WHERE student_id=a.student_id;
  DELETE FROM public.academic_import_drafts WHERE student_id=a.student_id;
  DELETE FROM public.academic_performance WHERE student_id=a.student_id;
  DELETE FROM public.academic_periods WHERE student_id=a.student_id;
  DELETE FROM public.academic_settings WHERE student_id=a.student_id;
  DELETE FROM public.academic_years WHERE student_id=a.student_id;
  DELETE FROM public.study_programs WHERE student_id=a.student_id;
  DELETE FROM public.grading_bands b USING public.grading_scales s WHERE b.scale_id=s.scale_id AND s.student_id=a.student_id;
  DELETE FROM public.grading_scales WHERE student_id=a.student_id;
  DELETE FROM public.courses WHERE owner_student_id=a.student_id;
  DELETE FROM public.accounts WHERE account_id=a.account_id;
  DELETE FROM public.students WHERE student_id=a.student_id;
  RETURN jsonb_build_object('deleted',true,'email',target_email,'student_id',a.student_id);
END $$;
CREATE OR REPLACE FUNCTION public.delete_own_account(p_token text)
RETURNS jsonb LANGUAGE sql SECURITY INVOKER SET search_path='' AS $$ SELECT private.delete_own_account(p_token) $$;
REVOKE ALL ON FUNCTION private.delete_own_account(text),public.delete_own_account(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION private.delete_own_account(text),public.delete_own_account(text) TO anon,authenticated;
