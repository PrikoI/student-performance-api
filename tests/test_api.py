import json, os, unittest
from unittest.mock import AsyncMock, patch
from cryptography.fernet import Fernet
from fastapi import HTTPException
from app.main import Calculation, Chat, ExecutePlan, administrator, application_page, calculator, chat, execute_plan, limits, used_plans, parse_ai_plan

STUDENT={"token":"test","account_id":"a","student_id":1,"role":"student"}

class APITests(unittest.IsolatedAsyncioTestCase):
 async def asyncSetUp(self):limits.clear();used_plans.clear();os.environ["AI_ENCRYPTION_KEY"]=Fernet.generate_key().decode()
 async def test_application_shell(self):
  html=application_page()
  for marker in ("Академический калькулятор","Режим администратора","FIGMA_ACCENTS","fillWithAI","confirmAIChanges"):self.assertIn(marker,html)
 async def test_admin_role(self):
  with self.assertRaises(HTTPException) as ctx:await administrator(STUDENT)
  self.assertEqual(ctx.exception.status_code,403)
 async def test_manual_calculation(self):
  r=await calculator(Calculation(calendar="quarter",mode="average",items=[{"grade":80,"credits":1},{"grade":100,"credits":3}]),STUDENT);self.assertEqual(r["average"],95)
 async def test_empty_calculator_fields_are_not_zero(self):
  with self.assertRaises(HTTPException) as ctx:await calculator(Calculation(calendar="semester",items=[{"grade":80,"credits":None}]),STUDENT)
  self.assertIn("empty fields",ctx.exception.detail)
 async def test_course_mode_requires_gpa_scale(self):
  with self.assertRaises(HTTPException):await calculator(Calculation(calendar="semester",mode="course",items=[{"grade":90,"credits":3}]),STUDENT)
 async def test_ai_plan_accepts_json_and_markdown_wrappers(self):
  exact={"choices":[{"message":{"content":"{\"actions\":[{\"operation\":\"answer\",\"text\":\"ok\"}]}"}}]}
  wrapped={"choices":[{"message":{"content":"Here is the plan:\n```json\n{\"actions\":[{\"operation\":\"answer\",\"text\":\"ok\"}]}\n```"}}]}
  self.assertEqual(parse_ai_plan(exact)["actions"][0]["text"],"ok")
  self.assertEqual(parse_ai_plan(wrapped)["actions"][0]["text"],"ok")
 async def test_write_plan_requires_confirmation(self):
  actions=[{"operation":"write","entity":"academic_performance","data":{"current_grade":80}},{"operation":"answer","text":"done"}]
  with patch("app.main.plan_actions",AsyncMock(return_value=actions)),patch("app.main.all_data",AsyncMock(return_value={})),patch("app.main.config",AsyncMock(return_value={})),patch("app.main.save",AsyncMock(return_value={"saved":True})) as save:
   first=await chat(Chat(message="save then explain"),STUDENT);save.assert_not_called();sealed=first["confirmation_token"];done=await execute_plan(ExecutePlan(confirmation_token=sealed),STUDENT);self.assertEqual(len(done["results"]),2);save.assert_awaited_once()
   with self.assertRaises(HTTPException) as ctx:await execute_plan(ExecutePlan(confirmation_token=sealed),STUDENT)
   self.assertEqual(ctx.exception.status_code,409)
 async def test_foreign_plan_rejected(self):
  sealed=Fernet(os.environ["AI_ENCRYPTION_KEY"].encode()).encrypt(json.dumps({"account_id":"another","actions":[]}).encode()).decode()
  with self.assertRaises(HTTPException) as ctx:await execute_plan(ExecutePlan(confirmation_token=sealed),STUDENT)
  self.assertEqual(ctx.exception.status_code,403)
if __name__=="__main__":unittest.main()

