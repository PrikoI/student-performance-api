CREATE OR REPLACE FUNCTION private.validate_assessment_component_weight_total()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE pid bigint; total numeric;
BEGIN
  FOR pid IN SELECT DISTINCT x FROM unnest(ARRAY[
    CASE WHEN TG_OP <> 'DELETE' THEN NEW.performance_id END,
    CASE WHEN TG_OP <> 'INSERT' THEN OLD.performance_id END
  ]) AS x WHERE x IS NOT NULL
  LOOP
    SELECT COALESCE(sum(weight_percent),0) INTO total
    FROM public.assessment_components WHERE performance_id=pid;
    IF total > 100 THEN
      RAISE EXCEPTION 'Assessment component weights cannot exceed 100%% (current total: %)', total USING ERRCODE='23514';
    END IF;
  END LOOP;
  RETURN COALESCE(NEW,OLD);
END $$;

DROP TRIGGER IF EXISTS assessment_component_weight_total ON public.assessment_components;
CREATE CONSTRAINT TRIGGER assessment_component_weight_total
AFTER INSERT OR UPDATE OR DELETE ON public.assessment_components
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW EXECUTE FUNCTION private.validate_assessment_component_weight_total();
