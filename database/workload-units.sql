ALTER TABLE public.academic_performance ADD COLUMN IF NOT EXISTS workload_value numeric CHECK(workload_value>0);
ALTER TABLE public.academic_performance ADD COLUMN IF NOT EXISTS workload_unit text CHECK(workload_unit IN ('credits','academic_hours','lessons'));
UPDATE public.academic_performance SET workload_value=credits,workload_unit='credits' WHERE workload_value IS NULL AND credits IS NOT NULL;

