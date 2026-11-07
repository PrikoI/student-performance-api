CREATE OR REPLACE FUNCTION private.setup_academic_program(p_session_token text, p_data jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $$
DECLARE
  sid int; cal text; institution text; program_name text; level text;
  years_count int; periods_count int; start_year int; y int; p int;
  scale_id bigint; settings_id int; program_id bigint; year_id bigint;
  scale_name text; period_label text; result jsonb;
BEGIN
  sid=private.session_student(p_session_token);
  cal=COALESCE(p_data->>'calendar_type','trimester');
  IF cal NOT IN ('trimester','semester','quarter') THEN RAISE EXCEPTION 'Unsupported calendar'; END IF;
  institution=trim(COALESCE(p_data->>'institution_name',''));
  IF institution='' THEN RAISE EXCEPTION 'Institution name is required'; END IF;
  program_name=NULLIF(trim(COALESCE(p_data->>'program_name','')),'');
  level=COALESCE(NULLIF(p_data->>'education_level',''),CASE WHEN cal='quarter' THEN 'school' ELSE 'bachelor' END);
  years_count=COALESCE((p_data->>'duration_years')::int,CASE WHEN cal='quarter' THEN 11 WHEN cal='semester' THEN 4 ELSE 3 END);
  periods_count=COALESCE((p_data->>'periods_per_year')::int,CASE WHEN cal='quarter' THEN 4 WHEN cal='semester' THEN 2 ELSE 3 END);
  start_year=COALESCE((p_data->>'start_year')::int,EXTRACT(YEAR FROM CURRENT_DATE)::int);
  IF years_count<1 OR years_count>20 OR periods_count<1 OR periods_count>12 THEN RAISE EXCEPTION 'Years or periods are outside supported range'; END IF;

  scale_name=CASE WHEN cal='quarter' THEN 'Школа Казахстана: 2–5' ELSE 'Казахстанский вуз: GPA 4.0' END;
  INSERT INTO public.grading_scales(student_id,name,minimum_score,maximum_score)
  VALUES(sid,scale_name,0,100) RETURNING grading_scales.scale_id INTO scale_id;
  IF cal='quarter' THEN
    INSERT INTO public.grading_bands(scale_id,score_range,letter_grade,grade_points) VALUES
      (scale_id,numrange(0,40,'[)'),'2',0),(scale_id,numrange(40,65,'[)'),'3',1),
      (scale_id,numrange(65,85,'[)'),'4',3),(scale_id,numrange(85,101,'[)'),'5',4);
  ELSE
    INSERT INTO public.grading_bands(scale_id,score_range,letter_grade,grade_points) VALUES
      (scale_id,numrange(0,50,'[)'),'F',0),(scale_id,numrange(50,55,'[)'),'D',1),
      (scale_id,numrange(55,60,'[)'),'D+',1.33),(scale_id,numrange(60,65,'[)'),'C-',1.67),
      (scale_id,numrange(65,70,'[)'),'C',2),(scale_id,numrange(70,75,'[)'),'C+',2.33),
      (scale_id,numrange(75,80,'[)'),'B-',2.67),(scale_id,numrange(80,85,'[)'),'B',3),
      (scale_id,numrange(85,90,'[)'),'B+',3.33),(scale_id,numrange(90,95,'[)'),'A-',3.67),
      (scale_id,numrange(95,101,'[)'),'A',4);
  END IF;
  INSERT INTO public.academic_settings(student_id,institution_name,calendar_type,calendar_label,grading_scale,grade_min,grade_max,credit_system,conversion_notes,scale_id)
  VALUES(sid,institution,cal,CASE cal WHEN 'quarter' THEN 'Четверти' WHEN 'semester' THEN 'Семестры' ELSE 'Триместры' END,
    CASE WHEN cal='quarter' THEN 'other' ELSE 'gpa_4' END,0,100,CASE WHEN cal='quarter' THEN 'unknown' ELSE 'ects' END,
    CASE WHEN cal='quarter' THEN 'Проценты переводятся в оценки 2–5' ELSE '1 академический кредит = 30 академическим часам' END,scale_id)
  RETURNING academic_settings.settings_id INTO settings_id;
  INSERT INTO public.study_programs(student_id,institution_name,program_name,education_level,duration_years,calendar_type,suggested_period_count)
  VALUES(sid,institution,program_name,level,years_count,cal,periods_count) RETURNING study_programs.program_id INTO program_id;
  FOR y IN 1..years_count LOOP
    INSERT INTO public.academic_years(student_id,program_id,year_number,year_label,planned_period_count)
    VALUES(sid,program_id,y,CASE WHEN cal='quarter' THEN y||' класс' ELSE y||' курс' END,periods_count)
    RETURNING academic_years.year_id INTO year_id;
    FOR p IN 1..periods_count LOOP
      period_label=CASE WHEN cal='quarter' THEN p||' четверть' WHEN cal='semester' THEN p||' семестр' ELSE p||' триместр' END;
      INSERT INTO public.academic_periods(student_id,settings_id,academic_year,period_name,period_number,year_id,status)
      VALUES(sid,settings_id,(start_year+y-1)||'–'||(start_year+y),period_label,p,year_id,CASE WHEN y=1 AND p=1 THEN 'active' ELSE 'planned' END);
    END LOOP;
  END LOOP;
  SELECT jsonb_build_object('program_id',program_id,'settings_id',settings_id,'scale_id',scale_id,'years',years_count,'periods_per_year',periods_count) INTO result;
  RETURN result;
END $$;

CREATE OR REPLACE FUNCTION public.setup_academic_program(p_session_token text,p_data jsonb)
RETURNS jsonb LANGUAGE sql SECURITY INVOKER SET search_path TO '' AS $$
  SELECT private.setup_academic_program(p_session_token,p_data)
$$;
REVOKE ALL ON FUNCTION public.setup_academic_program(text,jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.setup_academic_program(text,jsonb) TO anon,authenticated;

