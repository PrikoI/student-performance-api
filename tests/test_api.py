import os,unittest
from unittest.mock import AsyncMock,patch
from fastapi.testclient import TestClient
from cryptography.fernet import Fernet
from app.main import app,identity,administrator,limits,used_plans
class APITests(unittest.TestCase):
 def setUp(self):
  self.c=TestClient(app);limits.clear();used_plans.clear()
  os.environ["AI_ENCRYPTION_KEY"]=Fernet.generate_key().decode()
 def tearDown(self):app.dependency_overrides.clear()
 def as_student(self):
  app.dependency_overrides[identity]=lambda:{"token":"test","account_id":"a","student_id":1,"role":"student"}
 def test_auth_required(self):
  self.assertEqual(self.c.get("/data").status_code,401)
 def test_application_shell(self):
  r=self.c.get("/")
  self.assertEqual(r.status_code,200)
  self.assertIn("Академический калькулятор",r.text)
  self.assertIn("Режим администратора",r.text)
  self.assertIn("Array.isArray(raw)?raw[0]:raw",r.text)
 def test_admin_role(self):
  self.as_student();self.assertEqual(self.c.get("/admin/tables/students").status_code,403)
 def test_manual_calculation(self):
  self.as_student()
  r=self.c.post("/calculate",json={"calendar":"quarter","items":[{"grade":80,"credits":1},{"grade":100,"credits":3}]})
  self.assertEqual(r.json()["average"],95)
 def test_grade_out_of_range(self):
  self.as_student()
  self.assertEqual(self.c.post("/calculate",json={"calendar":"semester","items":[{"grade":101}]}).status_code,422)
 def test_batch_limit(self):
  self.as_student()
  self.assertEqual(self.c.post("/records/batch",json={"records":[{"entity":"x","data":{}}]*101}).status_code,422)
 def test_key_hidden(self):
  self.as_student()
  app.dependency_overrides[administrator]=lambda:{"token":"test","role":"admin"}
  with patch("app.main.config",AsyncMock(return_value={"encrypted_key":"secret","model":"x"})):
   r=self.c.get("/admin/ai")
  self.assertNotIn("secret",r.text);self.assertTrue(r.json()["key_configured"])
 def test_write_plan_requires_confirmation_and_no_replanning(self):
  self.as_student()
  actions=[{"operation":"write","entity":"academic_performance","data":{"current_grade":80}},{"operation":"answer","text":"done"}]
  with patch("app.main.plan_actions",AsyncMock(return_value=actions)),patch("app.main.all_data",AsyncMock(return_value={})),patch("app.main.config",AsyncMock(return_value={})),patch("app.main.save",AsyncMock(return_value={"saved":True})) as save:
   r=self.c.post("/ai/chat",json={"message":"save then explain"})
   save.assert_not_called()
   sealed=r.json()["confirmation_token"]
   r=self.c.post("/ai/execute",json={"confirmation_token":sealed})
   self.assertEqual(len(r.json()["results"]),2)
   save.assert_awaited_once()
   self.assertEqual(self.c.post("/ai/execute",json={"confirmation_token":sealed}).status_code,409)
 def test_foreign_plan_rejected(self):
  self.as_student()
  import json
  sealed=Fernet(os.environ["AI_ENCRYPTION_KEY"].encode()).encrypt(json.dumps({"account_id":"another","actions":[]}).encode()).decode()
  self.assertEqual(self.c.post("/ai/execute",json={"confirmation_token":sealed}).status_code,403)
if __name__=="__main__":unittest.main()


