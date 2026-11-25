-- Older template years were created without a planned period count.
-- Use the selected program calendar so year forecasts have a denominator.
update public.academic_years y
set planned_period_count=coalesce(p.suggested_period_count,
  case p.calendar_type when 'quarter' then 4 when 'semester' then 2 else 3 end)
from public.study_programs p
where y.program_id=p.program_id
  and y.student_id=p.student_id
  and y.planned_period_count is null;
