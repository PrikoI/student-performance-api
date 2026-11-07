import unittest
from app.academics import calculate,forecast,grade_points

class AcademicTests(unittest.TestCase):
 def test_academic_hours_can_weight_average(self):
  result=calculate([{"grade":80,"workload_value":30,"workload_unit":"academic_hours"},{"grade":100,"workload_value":10,"workload_unit":"academic_hours"}])
  self.assertEqual(result["average"],85);self.assertEqual(result["workload_total"],40);self.assertEqual(result["workload_unit"],"academic_hours")
 def test_mixed_workload_units_are_rejected(self):
  with self.assertRaises(ValueError):calculate([{"grade":80,"workload_value":3,"workload_unit":"credits"},{"grade":90,"workload_value":45,"workload_unit":"academic_hours"}])
 def test_credit_weighted(self):
  self.assertEqual(calculate([{"grade":100,"credits":1},{"grade":50,"credits":3}])["average"],62.5)
 def test_missing_credit_not_silently_accepted(self):
  with self.assertRaises((TypeError,ValueError)):calculate([{"grade":80,"credits":None}])
 def test_gpa_individual_conversion(self):
  bands=[{"score_range":"[0,90)","grade_points":3},{"score_range":"[90,100]","grade_points":4}]
  self.assertEqual(calculate([{"grade":80,"credits":1},{"grade":100,"credits":1}],bands)["gpa"],3.5)
 def test_zero_weight(self):
  with self.assertRaises(ValueError):calculate([{"grade":85,"credits":0}])
 def test_baseline_not_automatic_bonus(self):
  d=self.data()
  r=forecast(d,1)
  self.assertEqual(r["average"],78)
  self.assertTrue(r["is_illustrative"])
 def test_year_requires_context(self):
  with self.assertRaises(ValueError):forecast(self.data(),1,"year")
 def test_future_and_closed_periods(self):
  for change in [{"status":"completed"},{"start_date":"2099-01-01"}]:
   d=self.data();d["academic_periods"][0].update(change)
   with self.assertRaises(ValueError):forecast(d,1)
 def test_gpa_gap_returns_none(self):
  self.assertIsNone(grade_points(70,[{"score_range":"[80,100]","grade_points":4}]))
 def data(self):
  return {"academic_periods":[{"period_id":1,"status":"active","settings_id":1,"year_id":1}],
   "academic_settings":[{"settings_id":1,"grading_scale":"percent_100","grade_min":0,"grade_max":100,"scale_id":1}],
   "academic_performance":[{"performance_id":1,"course_id":1,"period_id":1,"credits":5,"current_grade":80,"recent_assessment_score":70}],
   "academic_years":[{"year_id":1}],"grading_bands":[]}

if __name__=="__main__":unittest.main()


