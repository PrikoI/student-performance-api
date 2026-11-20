import unittest
from app.academics import calculate,forecast,grade_points,normalize_grade_percent,normalized_academic_snapshot,personal_baseline_estimate

class AcademicTests(unittest.TestCase):
 def test_improved_baseline_uses_bounded_personal_signals(self):
  snapshot={"current_score_percent":70,"recent_score_percent":80,"attendance_percent":95,
            "assignment_completion_percent":80,"period_progress_percent":50}
  result=personal_baseline_estimate(snapshot,[60,65,68])
  self.assertGreater(result["estimate"],70);self.assertLess(result["estimate"],80)
  self.assertLess(result["lower"],result["estimate"]);self.assertGreater(result["upper"],result["estimate"])
 def test_academic_hours_can_weight_average(self):
  result=calculate([{"grade":80,"workload_value":30,"workload_unit":"academic_hours"},{"grade":100,"workload_value":10,"workload_unit":"academic_hours"}])
  self.assertEqual(result["average"],85);self.assertEqual(result["workload_total"],40);self.assertEqual(result["workload_unit"],"academic_hours")
 def test_mixed_workload_units_are_rejected(self):
  with self.assertRaises(ValueError):calculate([{"grade":80,"workload_value":3,"workload_unit":"credits"},{"grade":90,"workload_value":45,"workload_unit":"academic_hours"}])
 def test_aitu_credit_converts_to_thirty_academic_hours(self):
  result=calculate([{"grade":80,"workload_value":2,"workload_unit":"credits"},{"grade":100,"workload_value":30,"workload_unit":"academic_hours"}],conversions={"credits":30,"academic_hours":1})
  self.assertEqual(result["average"],86.6667);self.assertEqual(result["normalized_workload_total"],90)
 def test_credit_weighted(self):
  self.assertEqual(calculate([{"grade":100,"credits":1},{"grade":50,"credits":3}])["average"],62.5)
 def test_missing_credit_not_silently_accepted(self):
  with self.assertRaises((TypeError,ValueError)):calculate([{"grade":80,"credits":None}])
 def test_gpa_individual_conversion(self):
  bands=[{"score_range":"[0,90)","grade_points":3},{"score_range":"[90,100]","grade_points":4}]
  self.assertEqual(calculate([{"grade":80,"credits":1},{"grade":100,"credits":1}],bands)["gpa"],3.5)
 def test_zero_weight(self):
  with self.assertRaises(ValueError):calculate([{"grade":85,"credits":0}])
 def test_baseline_blends_recent_evidence_without_automatic_bonus(self):
  d=self.data()
  r=forecast(d,1)
  self.assertEqual(r["average"],78.8)
  self.assertTrue(r["is_illustrative"])
 def test_adaptive_forecast_uses_graded_work_and_reports_method(self):
  d=self.data()
  d["assessment_components"]=[{"component_id":1,"performance_id":1,"name":"Quiz","component_type":"quiz","weight_percent":40}]
  d["assessments"]=[{"assessment_id":1,"component_id":1,"maximum_score":100,"due_at":"2026-01-01"},{"assessment_id":2,"component_id":1,"maximum_score":100,"due_at":"2026-02-01"}]
  d["assessment_results"]=[{"assessment_id":1,"status":"graded","score":60},{"assessment_id":2,"status":"graded","score":90}]
  r=forecast(d,1,method="adaptive")
  self.assertEqual(r["method_version"],"adaptive-reference-v2")
  self.assertTrue(any("Adaptive data points" in x for x in r["subjects"][0]["signals"]))
 def test_school_five_point_average_is_not_gpa(self):
  r=calculate([{"grade":5,"workload_value":2,"workload_unit":"lessons"},{"grade":4,"workload_value":1,"workload_unit":"lessons"}])
  self.assertEqual(r["average"],4.6667)
  self.assertIsNone(r["gpa"])
 def test_one_normalized_grade_space_covers_school_and_university(self):
  school={"calendar_type":"quarter","grading_scale":"five_point","grade_min":2,"grade_max":5}
  university={"calendar_type":"semester","grading_scale":"percentage","grade_min":0,"grade_max":100}
  self.assertEqual(normalize_grade_percent(4,school),74.5)
  self.assertEqual(normalize_grade_percent(74.5,university),74.5)
 def test_normalized_snapshot_keeps_raw_context_and_common_features(self):
  record={"current_grade":4,"recent_assessment_score":5,"attendance":80,"assignments_completed":3,"assignments_total":4,"workload_value":24,"workload_unit":"lessons"}
  period={"start_date":"2026-09-01","end_date":"2026-11-01"}
  settings={"calendar_type":"quarter","grading_scale":"five_point","grade_min":2,"grade_max":5}
  snapshot=normalized_academic_snapshot(record,period,settings,"2026-10-01")
  self.assertEqual(snapshot["schema_version"],"normalized-academic-v1")
  self.assertEqual(snapshot["current_score_percent"],74.5);self.assertEqual(snapshot["recent_score_percent"],92.5)
  self.assertEqual(snapshot["raw_current_grade"],4);self.assertEqual(snapshot["assignment_completion_percent"],75)
  self.assertAlmostEqual(snapshot["period_progress_percent"],49.1803,places=4)
 def test_equivalent_quarter_and_semester_results_share_forecast_space(self):
  quarter=self.data();quarter["academic_settings"][0].update(calendar_type="quarter",grading_scale="five_point",grade_min=2,grade_max=5)
  quarter["academic_performance"][0].update(current_grade=4,recent_assessment_score=None,credits=None,workload_value=24,workload_unit="lessons")
  semester=self.data();semester["academic_settings"][0].update(calendar_type="semester")
  semester["academic_performance"][0].update(current_grade=74.5,recent_assessment_score=None,credits=None,workload_value=90,workload_unit="academic_hours")
  self.assertEqual(forecast(quarter,1)["average_percent"],forecast(semester,1)["average_percent"])
 def test_forecast_records_internal_model_manifest(self):
  result=forecast(self.data(),1)
  self.assertEqual(result["normalization_version"],"normalized-academic-v1")
  self.assertEqual(result["model_manifest"][0]["key"],"academic-normalizer")
  self.assertTrue(any(item["role"]=="personal" for item in result["model_manifest"]))
 def test_multilevel_forecast_adds_validated_ml_layers(self):
  d=self.data()
  samples=[]
  for i in range(100):
   stage1=30+i%65;stage2=stage1+(i%7-3);final=.4*stage1+.6*stage2
   samples.append({"stage1":stage1,"stage2":stage2,"final":final,"absences":i%10})
  result=forecast(d,1,reference={"samples":samples,"datasets":[]})
  keys={item["key"] for item in result["model_manifest"]}
  self.assertIn("gradient-boosting-grade",keys);self.assertIn("gradient-boosting-risk",keys)
  self.assertIsNotNone(result["risk_summary"]["average_probability"])
 def test_quarter_adaptive_forecast_uses_school_scale_and_lessons(self):
  d=self.data();d["academic_settings"][0].update(calendar_type="quarter",grading_scale="five_point",grade_min=2,grade_max=5)
  d["academic_performance"][0].update(current_grade=5,credits=None,workload_value=24,workload_unit="lessons")
  d["assessment_components"]=[{"component_id":1,"performance_id":1,"name":"СОР","component_type":"quiz","weight_percent":40}]
  d["assessments"]=[{"assessment_id":1,"component_id":1,"maximum_score":10,"due_at":"2026-01-01"}]
  d["assessment_results"]=[{"assessment_id":1,"status":"graded","score":8}]
  r=forecast(d,1,method="adaptive")
  self.assertEqual(r["effective_method_version"],"adaptive-reference-v2");self.assertEqual(r["workload_unit"],"lessons");self.assertIsNone(r["credits"]);self.assertIn(r["converted_grade"],("4","5"))
 def test_semester_adaptive_forecast_uses_hours_and_differs_from_baseline(self):
  d=self.data();d["academic_settings"][0].update(calendar_type="semester")
  d["academic_performance"][0].update(current_grade=72,credits=None,workload_value=90,workload_unit="academic_hours")
  d["assessment_components"]=[{"component_id":1,"performance_id":1,"name":"Midterm","component_type":"midterm","weight_percent":40}]
  d["assessments"]=[{"assessment_id":1,"component_id":1,"maximum_score":100,"due_at":"2026-01-01"}]
  d["assessment_results"]=[{"assessment_id":1,"status":"graded","score":90}]
  adaptive=forecast(d,1,method="adaptive");baseline=forecast(d,1,method="baseline")
  self.assertEqual(adaptive["effective_method_version"],"adaptive-reference-v2");self.assertEqual(adaptive["workload_unit"],"academic_hours");self.assertNotEqual(adaptive["average_percent"],baseline["average_percent"])
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



