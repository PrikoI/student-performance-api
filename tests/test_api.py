import json, os, unittest
from types import SimpleNamespace
from unittest.mock import AsyncMock, patch
from cryptography.fernet import Fernet
from fastapi import HTTPException
from app.main import Calculation, Chat, ExecutePlan, RegistrationStart, administrator, application_page, calculator, chat, execute_plan, limits, used_plans, parse_ai_plan, prepared_action, execute_actions, deterministic_actions, register_start

STUDENT={"token":"test","account_id":"a","student_id":1,"role":"student"}

class APITests(unittest.IsolatedAsyncioTestCase):
 async def asyncSetUp(self):limits.clear();used_plans.clear();os.environ["AI_ENCRYPTION_KEY"]=Fernet.generate_key().decode()
 async def test_application_shell(self):
  html=application_page()
  for marker in ("Академический калькулятор","Режим администратора","FIGMA_ACCENTS","fillWithAI","confirmAIChanges"):self.assertIn(marker,html)
 async def test_admin_role(self):
  with self.assertRaises(HTTPException) as ctx:await administrator(STUDENT)
  self.assertEqual(ctx.exception.status_code,403)
 async def test_registration_shell_has_no_email_codes_or_recovery(self):
  html=application_page()
  self.assertNotIn('id="forgotAuth"',html)
  self.assertNotIn('id="verificationCode"',html)
  self.assertNotIn('/auth/password-reset/start',html)
 async def test_registration_creates_session_immediately(self):
  body=RegistrationStart(email="new@example.com",username="NewUser",password="password123",full_name="New User")
  request=SimpleNamespace(client=SimpleNamespace(host="127.0.0.1"))
  result={"session_token":"token","student_id":99}
  with patch("app.main.auth_secret",return_value="secret"),patch("app.main.rpc",AsyncMock(return_value=result)) as rpc:
   self.assertEqual(await register_start(body,request),result)
   rpc.assert_awaited_once_with("register_without_email_verification",{"p_secret":"secret","p_email":"new@example.com","p_username":"NewUser","p_password":"password123","p_full_name":"New User"})
 async def test_manual_calculation(self):
  r=await calculator(Calculation(calendar="quarter",mode="average",items=[{"grade":80,"credits":1},{"grade":100,"credits":3}]),STUDENT);self.assertEqual(r["average"],95)
 async def test_empty_calculator_fields_are_not_zero(self):
  with self.assertRaises(HTTPException) as ctx:await calculator(Calculation(calendar="semester",items=[{"grade":80,"credits":None}]),STUDENT)
  self.assertIn("empty fields",ctx.exception.detail)
 async def test_course_mode_requires_gpa_scale(self):
  with self.assertRaises(HTTPException):await calculator(Calculation(calendar="semester",mode="course",items=[{"grade":90,"credits":3}]),STUDENT)
 async def test_attendance_counts_excused_lessons(self):
  r=await calculator(Calculation(calendar="trimester",mode="attendance",items=[{"lessons_held":10,"lessons_attended":7,"lessons_excused":2}]),STUDENT)
  self.assertEqual(r["attendance"],90);self.assertEqual(r["physical_attendance"],70);self.assertEqual(r["excused"],2)
 async def test_common_ai_questions_do_not_depend_on_model_plan(self):
  data={"academic_periods":[{"period_id":1,"status":"active"}],"academic_performance":[{"period_id":1,"course_id":1,"credits":5,"current_grade":80}],"courses":[{"course_id":1,"course_name":"Math"}]}
  actions=deterministic_actions("Сколько у меня кредитов?",data)
  self.assertEqual(actions[0]["operation"],"answer");self.assertIn("5 кредитов",actions[0]["text"])
 async def test_ai_plan_accepts_json_and_markdown_wrappers(self):
  exact={"choices":[{"message":{"content":"{\"actions\":[{\"operation\":\"answer\",\"text\":\"ok\"}]}"}}]}
  wrapped={"choices":[{"message":{"content":"Here is the plan:\n```json\n{\"actions\":[{\"operation\":\"answer\",\"text\":\"ok\"}]}\n```"}}]}
  self.assertEqual(parse_ai_plan(exact)["actions"][0]["text"],"ok")
  self.assertEqual(parse_ai_plan(wrapped)["actions"][0]["text"],"ok")
 async def test_write_plan_requires_confirmation(self):
  actions=[{"operation":"write","entity":"academic_performance","data":{"course_id":2,"current_grade":80}},{"operation":"answer","text":"done"}]
  owned={"academic_periods":[{"period_id":1,"status":"active"}],"courses":[{"course_id":2}]}
  with patch("app.main.plan_actions",AsyncMock(return_value=actions)),patch("app.main.all_data",AsyncMock(return_value=owned)),patch("app.main.config",AsyncMock(return_value={})),patch("app.main.save",AsyncMock(return_value={"saved":True})) as save:
   first=await chat(Chat(message="save then explain"),STUDENT);save.assert_not_called();sealed=first["confirmation_token"];done=await execute_plan(ExecutePlan(confirmation_token=sealed),STUDENT);self.assertEqual(len(done["results"]),2);save.assert_awaited_once()
   with self.assertRaises(HTTPException) as ctx:await execute_plan(ExecutePlan(confirmation_token=sealed),STUDENT)
   self.assertEqual(ctx.exception.status_code,409)
 async def test_foreign_plan_rejected(self):
  sealed=Fernet(os.environ["AI_ENCRYPTION_KEY"].encode()).encrypt(json.dumps({"account_id":"another","actions":[]}).encode()).decode()
  with self.assertRaises(HTTPException) as ctx:await execute_plan(ExecutePlan(confirmation_token=sealed),STUDENT)
  self.assertEqual(ctx.exception.status_code,403)
 async def test_prediction_uses_owned_active_period(self):
  data={"academic_periods":[{"period_id":42,"status":"active"}]}
  self.assertEqual(prepared_action({"operation":"predict","period_id":999,"level":"period"},data)["period_id"],42)
 async def test_create_subject_is_validated_and_period_is_resolved(self):
  data={"academic_periods":[{"period_id":7,"status":"active"}],"courses":[]}
  action=prepared_action({"operation":"create_subject","data":{"course_name":"ABOBA","credits":10,"current_grade":95,"attendance":10}},data)
  self.assertEqual(action["data"]["period_id"],7)
  self.assertEqual(action["data"]["course_name"],"ABOBA")
 async def test_cross_account_table_is_rejected(self):
  with self.assertRaises(ValueError):prepared_action({"operation":"read","entity":"accounts"},{})
 async def test_create_subject_requires_valid_credits(self):
  with self.assertRaises(ValueError):prepared_action({"operation":"create_subject","data":{"course_name":"X"}},{"academic_periods":[{"period_id":1,"status":"active"}]})
if __name__=="__main__":unittest.main()

