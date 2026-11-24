import unittest
from app.forecast_models import GradientStumpRegressor,GradientStumpClassifier,multilevel_ml_prediction,training_rows

class ForecastModelTests(unittest.TestCase):
 def reference(self,n=100):
  samples=[]
  for i in range(n):
   stage1=30+(i%65);stage2=max(0,min(100,stage1+((i%7)-3)))
   final=max(0,min(100,.35*stage1+.65*stage2-(i%4)))
   samples.append({"stage1":stage1,"stage2":stage2,"final":final,"absences":i%12})
  return {"samples":samples,"local_samples":[]}
 def test_training_rows_are_normalized(self):
  rows=training_rows(self.reference());self.assertEqual(len(rows),100);self.assertTrue(all(0<=y<=100 for _,y in rows))
 def test_regressor_learns_grade_signal(self):
  rows=training_rows(self.reference());model=GradientStumpRegressor().fit([x for x,_ in rows],[y for _,y in rows])
  self.assertGreater(model.predict_one([90,0,90,80,50]),model.predict_one([40,0,90,80,50]))
 def test_classifier_returns_probability(self):
  rows=training_rows(self.reference());labels=[int(y<60) for _,y in rows]
  model=GradientStumpClassifier().fit([x for x,_ in rows],labels)
  self.assertGreater(model.predict_proba_one([40,0,75,70,50]),model.predict_proba_one([90,0,75,70,50]))
 def test_model_refuses_tiny_sample(self):
  self.assertIsNone(multilevel_ml_prediction({"current_score_percent":70},self.reference(20)))
 def test_model_reports_validation_and_risk(self):
  result=multilevel_ml_prediction({"current_score_percent":55,"recent_score_percent":58,"attendance_percent":70},self.reference())
  self.assertIsNotNone(result);self.assertIn("validation_mae",result);self.assertIsNotNone(result["risk_probability"])

if __name__=="__main__":unittest.main()
