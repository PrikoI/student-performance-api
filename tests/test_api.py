import json, os, unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import AsyncMock, patch
from cryptography.fernet import Fernet
from fastapi import HTTPException
from app.academics import historical_projection, forecast
from app.main import Calculation, Chat, ExecutePlan, RegistrationStart, CurrentPassword, PasswordChange, Delete, administrator, identity, application_page, application_logo, calculator, chat, execute_plan, limits, used_plans, parse_ai_plan, prepared_action, execute_actions, deterministic_actions, split_explicit_requests, plan_all_requests, register_start, verify_account_password, change_account_password, delete_account, get_avatar, put_avatar, delete_avatar, Avatar, ai_scoped_context, redact_ai_log_text, redact_ai_log_value, public_ai_response, admin_page, admin_assistant, app

STUDENT={"token":"test","account_id":"a","student_id":1,"role":"student"}

class APITests(unittest.IsolatedAsyncioTestCase):
 async def asyncSetUp(self):limits.clear();used_plans.clear();os.environ["AI_ENCRYPTION_KEY"]=Fernet.generate_key().decode()
 async def test_admin_assistant_understands_its_russian_example(self):
  admin={"token":"admin","account_id":"root","student_id":10,"role":"admin"}
  with patch("app.main.admin_read",AsyncMock(return_value={"items":[{"student_id":1}]})) as read:
   result=await admin_assistant(Chat(message="покажи всех студентов",locale="ru"),admin)
   self.assertEqual(result["kind"],"table");self.assertEqual(result["entity"],"students")
   read.assert_awaited_once()
 async def test_next_period_forecast_reads_completed_period_records(self):
  data={"academic_periods":[{"period_id":1,"year_id":1,"settings_id":1,"period_number":1,"status":"completed"},{"period_id":2,"year_id":1,"settings_id":1,"period_number":2,"status":"active"}],"academic_settings":[{"settings_id":1,"calendar_type":"trimester","grading_scale":"percentage","grade_min":0,"grade_max":100,"scale_id":1}],"academic_performance":[{"performance_id":7,"period_id":1,"course_id":3,"current_grade":80,"credits":5,"workload_value":5,"workload_unit":"credits"}],"grading_bands":[],"actual_results":[]}
  result=forecast(data,2,"next_period","baseline",{"samples":[{"stage1":x,"final":x} for x in range(20,100,3)],"datasets":[]})
  self.assertEqual(result["period_id"],2);self.assertEqual(result["source_period_id"],1);self.assertEqual(result["subjects"][0]["performance_id"],7)
 async def test_historical_projection_is_bounded_and_requires_enough_samples(self):
  samples=[{"stage1":x,"final":min(100,x+5)} for x in range(20,100,3)]
  result=historical_projection(70,{"samples":samples})
  self.assertIsNotNone(result);self.assertGreaterEqual(result["estimate"],0);self.assertLessEqual(result["estimate"],100)
  self.assertIsNone(historical_projection(70,{"samples":samples[:5]}))
 async def test_api_settings_has_no_redundant_logout(self):
  html=admin_page()
  self.assertNotIn('id="logout"',html);self.assertIn("Вернуться в Perfecta",html)
 async def test_completed_period_remains_visible_and_admin_uses_course_names(self):
  html=application_page()
  self.assertIn("function displayPeriod()",html)
  self.assertIn("courseNames.get(x.course_id)",html)
 async def test_application_shell(self):
  html=application_page()
  for marker in ("Академический калькулятор","Режим администратора","FIGMA_ACCENTS","fillWithAI","confirmAIChanges","Прогнозирование",'data-colorblind="true"',"boot-brand-logo","Университет — триместры","Школа — четверти"):self.assertIn(marker,html)
 async def test_first_login_uses_supported_device_language_with_english_fallback(self):
  html=application_page()
  for marker in ("navigator.languages","SUPPORTED_LANGUAGES","return'en'","perfecta_language_user_selected","Device language preference was not saved"):self.assertIn(marker,html)
  self.assertIn("if(!localStorage.getItem(LANGUAGE_OVERRIDE_KEY)){state.prefs.language=detectDeviceLanguage()",html)
 async def test_admin_role(self):
  with self.assertRaises(HTTPException) as ctx:await administrator(STUDENT)
  self.assertEqual(ctx.exception.status_code,403)
 async def test_operator_control_pauses_ai_before_reading_academic_data(self):
  body=Chat(message="hello",locale="en",session_id=7)
  with patch("app.main.rpc",AsyncMock(return_value={"control_mode":"operator"})) as rpc_mock,patch("app.main.all_data",AsyncMock()) as data_mock:
   result=await chat(body,STUDENT)
   self.assertEqual(result["status"],"operator_pending");data_mock.assert_not_awaited()
   rpc_mock.assert_awaited_once_with("ai_chat_control_state",{"p_session_token":"test","p_session_id":7})
 async def test_hybrid_chat_admin_ui_and_disclosure_are_present(self):
  html=application_page()
  for marker in ('data-view="admin_chats"','Перехватить управление','/admin/ai/chats','operator_pending'):
   self.assertIn(marker,html)
 async def test_operator_chat_polling_preserves_drafts_and_blocks_races(self):
  html=application_page()
  for marker in ("window.chatRequestInFlight","window.chatSyncInFlight","adminChatSignature","adminChatState.draft","window.adminChatSending","setSelectionRange"):
   self.assertIn(marker,html)
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
  self.assertEqual(deterministic_actions("5+5?",{},"ru")[0]["text"],"5 + 5 = 10")
  self.assertIn("Привет",deterministic_actions("Привет",{},"ru")[0]["text"])
 async def test_ai_reads_latest_completed_period_when_active_period_is_empty(self):
  data={"academic_periods":[{"period_id":1,"period_number":1,"status":"completed","settings_id":1},{"period_id":2,"period_number":2,"status":"active","settings_id":1}],"academic_settings":[{"settings_id":1,"calendar_type":"quarter"}],"academic_performance":[{"period_id":1,"course_id":1,"current_grade":5,"workload_unit":"lessons","workload_value":24}],"courses":[{"course_id":1,"course_name":"Алгебра"}]}
  answer=deterministic_actions("Покажи средний балл",data)[0]["text"]
  self.assertIn("92.5%",answer);self.assertNotIn("Недостаточно",answer)
 async def test_named_subject_question_returns_only_that_subject(self):
  data={"academic_periods":[{"period_id":1,"status":"completed"}],"academic_performance":[{"period_id":1,"course_id":1,"current_grade":10,"credits":5},{"period_id":1,"course_id":2,"current_grade":91,"credits":5}],"courses":[{"course_id":1,"course_name":"Introduction to Programming 1"},{"course_id":2,"course_name":"Information and Communication Technologies"}]}
  self.assertIsNone(deterministic_actions("Что скажешь о моей оценке по программированию?",data))
  answer=deterministic_actions("What is my grade for Programming?",data)[0]["text"]
  self.assertIn("Programming",answer);self.assertIn("10",answer);self.assertNotIn("Technologies",answer)
 async def test_opinion_request_is_not_replaced_with_raw_grade_list(self):
  data={"academic_periods":[{"period_id":1,"status":"completed"}],"academic_performance":[{"period_id":1,"course_id":1,"current_grade":10,"credits":5},{"period_id":1,"course_id":2,"current_grade":91,"credits":5}],"courses":[{"course_id":1,"course_name":"Programming"},{"course_id":2,"course_name":"ICT"}]}
  for message in ("Что скажешь о моих оценках?","Почему это плохо и как исправить?","What do you think about my grades?"):
   with self.subTest(message=message):self.assertIsNone(deterministic_actions(message,data))
 async def test_explicit_compound_request_keeps_every_part(self):
  parts=split_explicit_requests("Предложи способы решения. И ещё, что ты умеешь?")
  self.assertEqual(parts,["Предложи способы решения","что ты умеешь"])
  with patch("app.main.plan_actions",AsyncMock(side_effect=[[{"operation":"answer","text":"advice"}],[{"operation":"answer","text":"capabilities"}]])) as planner:
   actions=await plan_all_requests("Предложи способы решения. И ещё, что ты умеешь?",{}, {},"ru",[])
  self.assertEqual([a["text"] for a in actions],["advice","capabilities"]);self.assertEqual(planner.await_count,2)
 async def test_forecast_chat_has_readable_summary_and_saved_link(self):
  html=application_page()
  for marker in ("function formatForecastAI", "[[prediction:", "chat-prediction-link", "openPrediction('${prediction}')", "Я — искусственный интеллект проекта Perfecta"):
   self.assertIn(marker,html)
 async def test_public_ai_error_hides_technical_detail(self):
  response={"results":[{"index":0,"status":"failed","detail":"constraint 23514 secret internals"}]}
  public=public_ai_response(response,"ru")
  self.assertNotIn("detail",public["results"][0]);self.assertNotIn("23514",json.dumps(public))
  self.assertIn("закрытом журнале",public["results"][0]["message"])
 async def test_bare_number_without_history_is_not_a_prediction(self):
  with patch("app.main.all_data",AsyncMock(return_value={})),patch("app.main.plan_actions",AsyncMock()) as planner,patch("app.main.log_ai_interaction",AsyncMock()):
   result=await chat(Chat(message="67"),STUDENT)
   planner.assert_not_awaited();self.assertEqual(result["results"][0]["operation"],"answer")
   self.assertIn("число",result["results"][0]["result"]["text"])
 async def test_ai_chat_accepts_bounded_current_conversation_history(self):
  body=Chat(message="67",history=[{"role":"assistant","content":"Назовите оценку"}])
  self.assertEqual(body.history[0].role,"assistant")
  html=application_page();self.assertIn("conversation_history",Path("app/main.py").read_text(encoding="utf-8"))
  self.assertIn("slice(0,-2)",html);self.assertIn("history,session_id:state.currentChatId",html)
 async def test_persistent_chat_ui_defaults_to_ai_and_has_sessions(self):
  html=application_page()
  self.assertIn("assistantMode:'ai'",html);self.assertIn("/ai/sessions",html)
  self.assertIn("С ИИ",html);self.assertIn("История чатов пока пуста",html)
 async def test_failed_ai_step_is_logged_as_failed(self):
  response={"results":[{"index":0,"status":"failed","detail":"No academic records"}],"max_actions":5}
  with patch("app.main.all_data",AsyncMock(return_value={})),patch("app.main.deterministic_actions",return_value=[{"operation":"predict"}]),patch("app.main.execute_actions",AsyncMock(return_value=response)),patch("app.main.log_ai_interaction",AsyncMock()) as logger:
   self.assertEqual(await chat(Chat(message="Сделай прогноз"),STUDENT),response)
   self.assertEqual(logger.await_args.args[3],"failed")
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
 async def test_copy_same_quarter_subjects_without_grades_is_atomic_and_safe(self):
  data={"academic_periods":[{"period_id":11,"period_number":1,"status":"completed"},{"period_id":12,"period_number":2,"status":"active"}],"academic_performance":[{"performance_id":1,"period_id":11,"course_id":7,"current_grade":5,"workload_value":24,"workload_unit":"lessons"}],"courses":[{"course_id":7,"course_name":"Математика"}]}
  action=deterministic_actions("Добавь за 2 четверть те же предметы, что и за 1 четверть, но без оценок",data)[0]
  self.assertEqual(action["operation"],"copy_period_subjects")
  prepared=prepared_action(action,data)
  self.assertEqual(prepared["data"]["subjects"],[{"period_id":12,"course_name":"Математика","workload_value":24,"workload_unit":"lessons","credits":None,"entry_method":"ai_assisted"}])
 async def test_copy_period_understands_ordinal_words_and_preserves_every_subject(self):
  subjects=[{"performance_id":i,"period_id":11,"course_id":100+i,"current_grade":5,"workload_value":16+i,"workload_unit":"lessons"} for i in range(11)]
  data={"academic_periods":[{"period_id":11,"period_number":1,"status":"completed"},{"period_id":12,"period_number":2,"status":"active"}],"academic_performance":subjects,"courses":[{"course_id":100+i,"course_name":f"Предмет {i+1}"} for i in range(11)]}
  action=deterministic_actions("Запиши во вторую четверть всё те же предметы, что и за первую четверть, оценки оставь пустыми",data)[0]
  prepared=prepared_action(action,data)
  self.assertEqual(prepared["operation"],"copy_period_subjects");self.assertEqual(len(prepared["data"]["subjects"]),11);self.assertTrue(all("current_grade" not in item for item in prepared["data"]["subjects"]))
 async def test_ai_can_execute_twelve_distinct_non_mutating_steps(self):
  actions=[{"operation":"answer","text":str(i)} for i in range(12)]
  with patch("app.main.all_data",AsyncMock(return_value={})):
   result=await execute_actions(actions,STUDENT,True)
  self.assertEqual(len(result["results"]),12);self.assertEqual(result["max_actions"],12)
 async def test_copy_same_semester_subjects_keeps_hours_and_omits_grades(self):
  data={"academic_periods":[{"period_id":21,"period_number":1,"year_id":4,"status":"completed"},{"period_id":22,"period_number":2,"year_id":4,"status":"active"}],"academic_performance":[{"period_id":21,"course_id":8,"current_grade":88,"workload_value":90,"workload_unit":"academic_hours"}],"courses":[{"course_id":8,"course_name":"Programming"}]}
  action=deterministic_actions("Add the same subjects to semester 2 as in semester 1, no grades",data)[0]
  prepared=prepared_action(action,data)
  self.assertEqual(prepared["operation"],"copy_period_subjects");self.assertEqual(prepared["data"]["subjects"][0]["workload_unit"],"academic_hours");self.assertNotIn("current_grade",prepared["data"]["subjects"][0])
 async def test_copy_period_executes_one_atomic_rpc_after_confirmation(self):
  data={"academic_periods":[{"period_id":11,"period_number":1},{"period_id":12,"period_number":2}],"academic_performance":[{"period_id":11,"course_id":7,"current_grade":4,"workload_value":16,"workload_unit":"lessons"}],"courses":[{"course_id":7,"course_name":"Физика"}]}
  action={"operation":"copy_period_subjects","data":{"source_period_id":11,"target_period_id":12,"include_grades":False}}
  with patch("app.main.all_data",AsyncMock(return_value=data)),patch("app.main.rpc",AsyncMock(return_value={"count":1})) as rpc_mock:
   result=await execute_actions([action],STUDENT,True)
  self.assertEqual(result["results"][0]["status"],"ok");rpc_mock.assert_awaited_once()
  self.assertEqual(rpc_mock.await_args.args[0],"create_subject_records_atomic")
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
 async def test_saved_session_uses_loading_shell_without_login_flash(self):
  html=application_page()
  self.assertIn('id="boot" class="boot"',html)
  self.assertIn('<section id="auth" class="auth hidden">',html)
  self.assertIn("$('#boot').classList.add('hidden');$('#auth').classList.add('hidden')",html)
  self.assertIn("function showAuth(message=''){$('#boot').classList.add('hidden')",html)
 async def test_admin_page_reuses_session_and_back_does_not_logout(self):
  html=admin_page()
  self.assertIn('localStorage.getItem(PERSISTENT_TOKEN_KEY)||sessionStorage.getItem(SESSION_TOKEN_KEY)',html)
  self.assertIn('Вернуться в Perfecta',html)
  self.assertIn('Выйти из аккаунта',html)
  self.assertIn('loadSettings();',html)
  self.assertIn('location.replace("/")',html)
 async def test_avatar_endpoints_scope_reads_and_writes(self):
  student={**STUDENT,"student_id":17}
  image="data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAAB"
  with patch("app.main.rpc",AsyncMock(side_effect=[{"student_id":17,"image_data":None},{"student_id":17,"image_data":image},{"student_id":17,"deleted":True}])) as mocked:
   self.assertIsNone((await get_avatar(17,student))["image_data"])
   self.assertEqual((await put_avatar(Avatar(image_data=image),student))["image_data"],image)
   self.assertTrue((await delete_avatar(student))["deleted"])
  self.assertEqual(mocked.await_args_list[0].args,("api_avatar",{"p_token":"test","p_student_id":17,"p_image_data":None}))
  self.assertEqual(mocked.await_args_list[1].args,("api_avatar",{"p_token":"test","p_student_id":17,"p_image_data":image}))
  self.assertEqual(mocked.await_args_list[2].args,("api_avatar",{"p_token":"test","p_student_id":17,"p_image_data":""}))
 async def test_avatar_ui_is_remote_persistent_and_admin_visible(self):
  html=application_page()
  for marker in ("function avatarMarkup(","/avatar/${state.me.student_id}","api(\'/avatar\',{method:\'PUT\'","api(\'/avatar\',{method:\'DELETE\'","await api(\'/avatar/${studentId}\')","admin-student-avatar"):self.assertIn(marker,html)
  self.assertNotIn("perfecta_avatar_",html)
  self.assertIn("file.size>5*1024*1024",html)
  self.assertTrue(any(getattr(item,"max_length",None)==7100000 for item in Avatar.model_fields["image_data"].metadata))

 async def test_ai_requests_allow_backend_processing_window(self):
  html=application_page()
  self.assertIn("api('/ai/chat','POST',{message,locale:state.prefs.language},105000)",html)
  self.assertIn("api('/ai/execute','POST',{confirmation_token:window.pendingConfirmation},105000)",html)
 async def test_school_forecast_normalizes_five_point_marks_to_percent(self):
  data={"academic_periods":[{"period_id":1,"year_id":1,"settings_id":1,"period_number":1,"status":"active"}],"academic_settings":[{"settings_id":1,"calendar_type":"quarter","grading_scale":"five_point","grade_min":2,"grade_max":5,"scale_id":1}],"academic_performance":[{"performance_id":1,"period_id":1,"course_id":1,"current_grade":5,"workload_unit":"lessons","workload_value":24}],"grading_bands":[],"actual_results":[]}
  result=forecast(data,1,"period","baseline")
  self.assertEqual(result["average_percent"],92.5);self.assertEqual(result["subjects"][0]["normalized_current_percent"],92.5);self.assertEqual(result["workload_unit"],"lessons");self.assertIsNone(result["credits"]);self.assertEqual(result["converted_grade"],"5");self.assertIsNone(result["gpa"])
 async def test_adaptive_forecast_uses_graded_work_and_stays_bounded(self):
  data={"academic_periods":[{"period_id":1,"year_id":1,"settings_id":1,"period_number":1,"status":"active"}],"academic_settings":[{"settings_id":1,"calendar_type":"trimester","grading_scale":"percentage","grade_min":0,"grade_max":100,"scale_id":1}],"academic_performance":[{"performance_id":1,"period_id":1,"course_id":1,"current_grade":70,"credits":5,"workload_value":5,"workload_unit":"credits"}],"grading_bands":[],"actual_results":[],"assessment_components":[{"component_id":1,"performance_id":1,"component_type":"assignment","name":"Assignments","weight_percent":40}],"assessments":[{"assessment_id":1,"component_id":1,"maximum_score":100,"due_at":"2026-01-01"},{"assessment_id":2,"component_id":1,"maximum_score":100,"due_at":"2026-02-01"}],"assessment_results":[{"assessment_id":1,"status":"graded","score":60},{"assessment_id":2,"status":"graded","score":90}]}
  result=forecast(data,1,"period","adaptive")
  baseline=forecast(data,1,"period","baseline")
  self.assertEqual(result["method_version"],"adaptive-reference-v2");self.assertEqual(result["effective_method_version"],"adaptive-reference-v2");self.assertEqual(result["adaptive_subjects"],1);self.assertNotEqual(result["average_percent"],baseline["average_percent"]);self.assertGreaterEqual(result["average_percent"],0);self.assertLessEqual(result["average_percent"],100);self.assertTrue(any("Adaptive data points" in x for x in result["subjects"][0]["signals"]))
 async def test_adaptive_forecast_reports_baseline_fallback_without_graded_work(self):
  data={"academic_periods":[{"period_id":1,"year_id":1,"settings_id":1,"period_number":1,"status":"active"}],"academic_settings":[{"settings_id":1,"calendar_type":"trimester","grading_scale":"percentage","grade_min":0,"grade_max":100,"scale_id":1}],"academic_performance":[{"performance_id":1,"period_id":1,"course_id":1,"current_grade":70,"credits":5,"workload_value":5,"workload_unit":"credits"}],"grading_bands":[],"actual_results":[],"assessment_components":[],"assessments":[],"assessment_results":[]}
  result=forecast(data,1,"period","adaptive")
  self.assertEqual(result["method_version"],"adaptive-reference-v2");self.assertEqual(result["effective_method_version"],"baseline-reference-v2");self.assertEqual(result["adaptive_subjects"],0)
 async def test_next_period_forecast_rejects_missing_completed_source(self):
  data={"academic_periods":[{"period_id":2,"year_id":1,"settings_id":1,"period_number":2,"status":"active"}],"academic_settings":[],"academic_performance":[]}
  with self.assertRaisesRegex(ValueError,"completed previous period"):forecast(data,2,"next_period","baseline")
 async def test_year_forecast_keeps_two_thirds_threshold(self):
  data={"academic_periods":[{"period_id":1,"year_id":1,"settings_id":1,"period_number":1,"status":"completed"},{"period_id":2,"year_id":1,"settings_id":1,"period_number":2,"status":"active"}],"academic_settings":[{"settings_id":1,"calendar_type":"trimester","grading_scale":"percentage","grade_min":0,"grade_max":100,"scale_id":1}],"academic_years":[{"year_id":1,"program_id":1,"planned_period_count":3}],"academic_performance":[{"performance_id":1,"period_id":1,"course_id":1,"current_grade":80,"credits":5,"workload_value":5,"workload_unit":"credits"},{"performance_id":2,"period_id":2,"course_id":1,"current_grade":82,"credits":5,"workload_value":5,"workload_unit":"credits"}],"actual_results":[{"performance_id":1,"final_grade":80}],"grading_bands":[]}
  with self.assertRaisesRegex(ValueError,"two thirds"):forecast(data,2,"year","baseline")
 async def test_forecast_report_is_localized_and_hides_internal_codes(self):
  html=application_page()
  for marker in ("const FORECAST_CONVERSION_LABEL=","function forecastConversion(","const FORECAST_UI=","function forecastLevelLabel(","function forecastMethodLabel(","function forecastSignalLabel(","Forecast horizon","Болжау көкжиегі","预测范围","Horizonte"):self.assertIn(marker,html)
  self.assertIn("coverageBits.join",html);self.assertNotIn("<b>Покрытие:</b> ${esc(JSON.stringify",html)
 async def test_mobile_drawer_is_vertical_and_closable(self):
  html=application_page()
  for marker in ('class="mobile-sidebar-close"','.sidebar .nav{display:grid!important','overflow-y:auto!important','.sidebar .profile{display:flex!important'):self.assertIn(marker,html)
 async def test_admin_academic_rows_use_actual_workload_unit(self):
  html=application_page()
  self.assertIn("function adminAcademicRows(",html)
  self.assertIn("academic_hours:'Академические часы'",html)
  self.assertIn("lessons:'Уроки'",html)
  self.assertNotIn("Кредиты:x.credits",html)
 async def test_forecast_subjects_use_profile_workload_unit(self):
  html=application_page()
  self.assertIn("academic_hours:t.hours,lessons:t.lessons",html)
  self.assertIn("s.workload_value??s.credits",html)
 async def test_forecast_history_uses_compact_expandable_cards(self):
  html=application_page()
  for marker in ("function predictionContext(","function openPrediction(","prediction-history-card","Посмотреть детали","onclick=\"openPrediction("):self.assertIn(marker,html)
 async def test_forecast_modal_renders_directly_in_each_language(self):
  html=application_page()
  for marker in ("const FORECAST_FORM=","function forecastForm()","New forecast","Жаңа болжам","新建预测","Nuevo pronóstico","forecastForm().done"):self.assertIn(marker,html)
 async def test_forecast_and_history_share_one_navigation_section(self):
  html=application_page()
  self.assertNotIn('data-view="history"',html)
  self.assertIn("function predictionHistoryHtml(",html)
  self.assertIn("const FORECAST_PAGE_COPY=",html)
  self.assertNotIn("<h2>Последний прогноз</h2>",html)
  self.assertIn("userDate(p.created_at||p.prediction_date)",html)
 async def test_chat_history_loads_on_navigation_and_uses_wrapped_cards(self):
  html=application_page()
  self.assertIn("go(b.dataset.view)",html)
  self.assertIn("if(v==='assistant'){assistant();loadChatSessions()}",html)
  self.assertIn("const CHAT_COPY=",html)
  self.assertIn("chat-session-title",html)
  self.assertIn("overflow-y:auto;overflow-x:hidden",html)
 async def test_prediction_modal_keeps_close_control_visible(self):
  html=application_page()
  self.assertIn("position:sticky;top:0;z-index:3",html)
 async def test_bootstrap_parallelizes_independent_requests(self):
  html=application_page()
  self.assertIn("const [agreement,savedPrefs]=await Promise.all",html)
  self.assertIn("const [loadedData,avatarResponse]=agreement.required?[{},null]:await Promise.all",html)
  self.assertIn("api('/tables/user_preferences','POST'",html)
  self.assertNotIn("try{await api('/tables/user_preferences'",html)
 async def test_logo_is_shared_cached_asset_not_repeated_base64(self):
  html=application_page()
  self.assertEqual(html.count('/logo.png'),5)
  self.assertNotIn('data:image/png;base64,',html)
  self.assertLess(len(html.encode('utf-8')),500000)
  response=application_logo()
  self.assertEqual(response.media_type,'image/png')
  self.assertIn('max-age=604800',response.headers['cache-control'])
  self.assertTrue(response.path.endswith('logo.png'))
 async def test_security_middleware_keeps_logo_cacheable(self):
  import inspect
  from app.main import guard
  source=inspect.getsource(guard)
  self.assertIn('request.url.path=="/logo.png"',source)
  self.assertIn('max-age=604800',source)
  self.assertIn('else "no-store"',source)
 async def test_bootstrap_opens_shell_before_slow_data_requests(self):
  html=application_page()
  self.assertIn("state.me=await api('/me','GET',undefined,15000)",html)
  self.assertIn("state.data={};state.avatar=null;showAuthenticatedShell();try{",html)
  self.assertIn("const [loadedData,avatarResponse]=await Promise.all",html)
  self.assertIn("Background account loading failed",html)
  self.assertIn("new AbortController()",html)
if __name__=="__main__":unittest.main()




