import json, os, unittest
from types import SimpleNamespace
from unittest.mock import AsyncMock, patch
from cryptography.fernet import Fernet
from fastapi import HTTPException
from app.main import Calculation, Chat, ExecutePlan, RegistrationStart, CurrentPassword, PasswordChange, Delete, administrator, identity, application_page, calculator, chat, execute_plan, limits, used_plans, parse_ai_plan, prepared_action, execute_actions, deterministic_actions, register_start, verify_account_password, change_account_password, delete_account, ai_scoped_context, redact_ai_log_text, redact_ai_log_value, app

STUDENT={"token":"test","account_id":"a","student_id":1,"role":"student"}

class APITests(unittest.IsolatedAsyncioTestCase):
 async def asyncSetUp(self):limits.clear();used_plans.clear();os.environ["AI_ENCRYPTION_KEY"]=Fernet.generate_key().decode()
 async def test_application_shell(self):
  html=application_page()
  for marker in ("Академический калькулятор","Режим администратора","FIGMA_ACCENTS","fillWithAI","confirmAIChanges"):self.assertIn(marker,html)
 async def test_first_login_uses_supported_device_language_with_english_fallback(self):
  html=application_page()
  for marker in ("navigator.languages","SUPPORTED_LANGUAGES","return'en'","perfecta_language_user_selected","Device language preference was not saved"):self.assertIn(marker,html)
  self.assertIn("if(!localStorage.getItem(LANGUAGE_OVERRIDE_KEY)){state.prefs.language=detectDeviceLanguage()",html)
 async def test_admin_role(self):
  with self.assertRaises(HTTPException) as ctx:await administrator(STUDENT)
  self.assertEqual(ctx.exception.status_code,403)
 async def test_unsigned_account_is_blocked_from_academic_api(self):
  request=SimpleNamespace(url=SimpleNamespace(path="/data"));credentials=SimpleNamespace(credentials="session")
  with patch("app.main.rpc",AsyncMock(side_effect=[{"account_id":"a","role":"student"},{"required":True}])) as rpc:
   with self.assertRaises(HTTPException) as ctx:await identity(request,credentials)
   self.assertEqual(ctx.exception.status_code,451);self.assertEqual(rpc.await_count,2)
 async def test_unsigned_account_can_access_agreement_endpoint(self):
  request=SimpleNamespace(url=SimpleNamespace(path="/agreement/status"));credentials=SimpleNamespace(credentials="session")
  with patch("app.main.rpc",AsyncMock(return_value={"account_id":"a","role":"student"})) as rpc:
   result=await identity(request,credentials)
   self.assertEqual(result["account_id"],"a");rpc.assert_awaited_once_with("api_identity",{"p_token":"session"})
 async def test_registration_shell_has_no_email_codes_or_recovery(self):
  html=application_page()
  self.assertNotIn('id="forgotAuth"',html)
  self.assertNotIn('id="verificationCode"',html)
  self.assertNotIn('/auth/password-reset/start',html)
 async def test_registration_creates_session_immediately(self):
  body=RegistrationStart(email="new@example.com",username="NewUser",password="password123",full_name="New User",agreement_version="2026-11-08-v1",agreement_accepted=True)
  request=SimpleNamespace(client=SimpleNamespace(host="127.0.0.1"))
  result={"session_token":"token","student_id":99}
  with patch("app.main.auth_secret",return_value="secret"),patch("app.main.rpc",AsyncMock(return_value=result)) as rpc:
   self.assertEqual(await register_start(body,request),result)
   rpc.assert_awaited_once_with("register_with_agreement",{"p_secret":"secret","p_email":"new@example.com","p_username":"NewUser","p_password":"password123","p_full_name":"New User","p_agreement_version":"2026-11-08-v1","p_agreement_accepted":True})
 async def test_registration_requires_current_agreement(self):
  body=RegistrationStart(email="new2@example.com",username="NewUser2",password="password123",full_name="New User",agreement_version="old",agreement_accepted=True)
  request=SimpleNamespace(client=SimpleNamespace(host="127.0.0.2"))
  with patch("app.main.rpc",AsyncMock()) as rpc:
   with self.assertRaises(HTTPException) as ctx:await register_start(body,request)
   self.assertEqual(ctx.exception.status_code,422);rpc.assert_not_awaited()
 async def test_agreement_is_present_in_registration_and_about(self):
  html=application_page()
  for marker in ('id="consentField"','id="agreementGate"',"Передача души","/agreement/accept","soulCounter","agreement.required?{}:await api('/data')","await bootstrap()"):self.assertIn(marker,html)
 async def test_password_settings_are_localized_and_email_recovery_is_absent(self):
  html=application_page()
  for marker in ("SECURITY_COPY","/account/password","verifyDeletionPassword","current_password:password"):self.assertIn(marker,html)
  for removed in ('id="forgotAuth"','id="verificationCode"','/auth/password-reset/start'):self.assertNotIn(removed,html)
 async def test_current_password_can_be_verified(self):
  body=CurrentPassword(current_password="old-password")
  with patch("app.main.rpc",AsyncMock(return_value={"valid":True})) as rpc:
   self.assertEqual(await verify_account_password(body,STUDENT),{"valid":True})
   rpc.assert_awaited_once_with("verify_own_password",{"p_token":"test","p_current_password":"old-password"})
 async def test_password_change_passes_current_and_new_password(self):
  body=PasswordChange(current_password="old-password",new_password="new-password")
  with patch("app.main.rpc",AsyncMock(return_value={"changed":True})) as rpc:
   self.assertTrue((await change_account_password(body,STUDENT))["changed"])
   rpc.assert_awaited_once_with("change_own_password",{"p_token":"test","p_current_password":"old-password","p_new_password":"new-password"})
 async def test_short_new_password_is_rejected_before_database(self):
  body=PasswordChange(current_password="old-password",new_password="short")
  with patch("app.main.rpc",AsyncMock()) as rpc:
   with self.assertRaises(HTTPException) as ctx:await change_account_password(body,STUDENT)
   self.assertEqual(ctx.exception.status_code,422);rpc.assert_not_awaited()
 async def test_delete_requires_explicit_confirmation(self):
  with patch("app.main.rpc",AsyncMock()) as rpc:
   with self.assertRaises(HTTPException) as ctx:await delete_account(Delete(current_password="old-password",confirm=False),STUDENT)
   self.assertEqual(ctx.exception.status_code,409);rpc.assert_not_awaited()
 async def test_delete_passes_current_password_to_database(self):
  with patch("app.main.rpc",AsyncMock(return_value={"deleted":True,"student_id":1})) as rpc:
   result=await delete_account(Delete(current_password="old-password",confirm=True),STUDENT)
   self.assertTrue(result["deleted"])
   rpc.assert_awaited_once_with("delete_own_account",{"p_token":"test","p_current_password":"old-password"})
 async def test_admin_cannot_delete_account(self):
  admin={**STUDENT,"role":"admin"}
  with patch("app.main.rpc",AsyncMock()) as rpc:
   with self.assertRaises(HTTPException) as ctx:await delete_account(Delete(current_password="admin-password",confirm=True),admin)
   self.assertEqual(ctx.exception.status_code,403);rpc.assert_not_awaited()
 async def test_manual_calculation(self):
  r=await calculator(Calculation(calendar="semester",mode="average",items=[{"grade":80,"credits":1},{"grade":100,"credits":3}]),STUDENT);self.assertEqual(r["average_percent"],95)
 async def test_school_template_returns_percent_and_converted_mark_without_workload(self):
  bands=[{"score_range":{"lower":0,"upper":40},"letter_grade":"2","grade_points":0},{"score_range":{"lower":40,"upper":65},"letter_grade":"3","grade_points":1},{"score_range":{"lower":65,"upper":85},"letter_grade":"4","grade_points":3},{"score_range":{"lower":85,"upper":101},"letter_grade":"5","grade_points":4}]
  r=await calculator(Calculation(calendar="quarter",mode="average",items=[{"grade":5},{"grade":4}],bands=bands),STUDENT)
  self.assertEqual(r["average_percent"],83.5);self.assertEqual(r["converted_grade"],"4");self.assertTrue(r["estimated_from_final_grades"])
 async def test_ai_log_redacts_email_and_secrets(self):
  clean=redact_ai_log_text("mail me@example.com password: hunter2 token=abc api_key: xyz")
  self.assertNotIn("me@example.com",clean);self.assertNotIn("hunter2",clean);self.assertNotIn("abc",clean);self.assertNotIn("xyz",clean)
  nested=redact_ai_log_value({"actions":[{"email":"person@example.com","data":{"password":"secret","note":"token: abc"}}],"outcome":{"confirmation_token":"sealed","text":"contact other@example.com"}})
  rendered=json.dumps(nested)
  for secret in ("person@example.com","secret","token: abc","sealed","other@example.com"):self.assertNotIn(secret,rendered)
 async def test_ai_chat_route_is_bound_to_chat_handler(self):
  route=next(route for route in app.routes if getattr(route,"path",None)=="/ai/chat")
  self.assertIs(route.endpoint,chat)
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
 async def test_ai_context_contains_only_current_students_courses(self):
  data={"students":[{"student_id":9}],"academic_performance":[{"student_id":9,"course_id":2}],"courses":[{"course_id":1,"course_name":"Calculus","owner_student_id":None},{"course_id":2,"course_name":"Математика","owner_student_id":None},{"course_id":3,"course_name":"Личный предмет","owner_student_id":9},{"course_id":4,"course_name":"Чужой предмет","owner_student_id":10}]}
  names={row["course_name"] for row in ai_scoped_context(data)["courses"]}
  self.assertEqual(names,{"Математика","Личный предмет"})
 async def test_short_school_subject_does_not_leak_template_courses(self):
  data={"academic_periods":[{"period_id":7,"status":"active"}],"courses":[{"course_id":1,"course_name":"Calculus"},{"course_id":2,"course_name":"Foreign Language"}]}
  variants=("Математика, школа, четверть, оценка 5","В школе за 1 четверть по алгебре оценка 4","Предмет Геометрия; школа; четверть; балл 5")
  expected=("Математика","алгебре","Геометрия")
  for message,name in zip(variants,expected):
   with self.subTest(message=message):
    actions=deterministic_actions(message,data)
    self.assertEqual(actions,[{"operation":"create_subject","data":{"course_name":name,"current_grade":float(5 if " 5" in message else 4),**({"period_number":1} if "1 четверть" in message else {})}}])
    rendered=json.dumps(actions,ensure_ascii=False)
    self.assertNotIn("Calculus",rendered);self.assertNotIn("Foreign Language",rendered)
 async def test_short_school_subject_with_lessons_is_ready_for_confirmation(self):
  data={"academic_periods":[{"period_id":7,"status":"active"}]}
  action=deterministic_actions("Математика, школа, 2 четверть, оценка 5, всего 24 урока",data)[0]
  prepared=prepared_action(action,data)
  self.assertEqual(prepared["data"]["course_name"],"Математика")
  self.assertEqual(prepared["data"]["workload_unit"],"lessons");self.assertEqual(prepared["data"]["workload_value"],24)
 async def test_clarification_questions_are_deduplicated(self):
  actions=[{"operation":"clarify","questions":["Сколько уроков?","  сколько   уроков?!","Какая четверть?"],"draft":{"course_name":"Математика"}}]
  with patch("app.main.all_data",AsyncMock(return_value={"academic_periods":[{"period_id":1,"status":"active"}]})):
   result=await execute_actions(actions,STUDENT,False)
  self.assertEqual(result["results"][0]["questions"],["Сколько уроков?","Какая четверть?"])
 async def test_auth_screen_uses_detected_language_before_login(self):
  html=application_page()
  for marker in ("const AUTH_COPY=","function applyAuthLanguage()","document.documentElement.lang=state.prefs.language||detectDeviceLanguage()","applyAuthLanguage();$('#authMessage')"):self.assertIn(marker,html)
  for language in ("ru:","en:","kk:","zh:","es:"):self.assertIn(language,html)
 async def test_remember_me_persists_only_the_session_token(self):
  html=application_page()
  for marker in ('id="rememberMe"',"PERSISTENT_TOKEN_KEY='sp_persistent_token'","localStorage.getItem(PERSISTENT_TOKEN_KEY)||sessionStorage.getItem(SESSION_TOKEN_KEY)","storeSessionToken(d.session_token,$('#rememberMe').checked)","function clearStoredSession(){sessionStorage.removeItem(SESSION_TOKEN_KEY);localStorage.removeItem(PERSISTENT_TOKEN_KEY)}"):self.assertIn(marker,html)
  self.assertNotIn("localStorage.setItem('password'",html)
 async def test_mobile_layout_depends_on_width_not_pointer_type(self):
  html=application_page()
  self.assertIn("@media(max-width:760px){",html)
  self.assertNotIn("(pointer:coarse)",html)
  for marker in (".sidebar.mobile-open","grid-template-columns:1fr!important",".table-wrap{max-width:100%;overflow-x:auto","font-size:16px"):self.assertIn(marker,html)
 async def test_core_i18n_covers_admin_profile_about_and_dynamic_modals(self):
  html=application_page()
  for marker in ("const COMPLETE_TRANSLATIONS=","Student directory, ready-made queries","学生目录、快捷查询","Студенттер каталогы","Directorio de estudiantes","requestAnimationFrame(()=>applyLanguage())"):self.assertIn(marker,html)
  self.assertIn("The session token persists only when",html)
if __name__=="__main__":unittest.main()


