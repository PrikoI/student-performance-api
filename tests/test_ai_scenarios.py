import unittest
from pathlib import Path

from app.main import ChatTurn, filter_planned_actions, merge_chat_history, split_explicit_requests


class AIScenarioTests(unittest.TestCase):
    def test_operator_reply_is_memory_of_assistant(self):
        stored = [{"message_id": 1, "role": "user", "content": "старый вопрос"}]
        current = {"messages": [
            {"message_id": 2, "role": "assistant", "content": "Нет, мне лень"},
            {"message_id": 3, "role": "user", "content": "почему ты это сказал?"},
        ]}
        turns = merge_chat_history(stored, current, [], "почему ты это сказал?")
        self.assertEqual([turn.content for turn in turns], ["старый вопрос", "Нет, мне лень"])
        self.assertEqual(turns[-1].role, "assistant")

    def test_active_session_deduplicates_cross_chat_memory(self):
        stored = [{"message_id": 7, "role": "assistant", "content": "один ответ"}]
        current = {"messages": [
            {"message_id": 7, "role": "assistant", "content": "один ответ"},
            {"message_id": 8, "role": "user", "content": "прочитай выше"},
        ]}
        turns = merge_chat_history(stored, current, [], "прочитай выше")
        self.assertEqual([turn.content for turn in turns], ["один ответ"])

    def test_client_history_is_used_when_session_read_fails(self):
        client = [ChatTurn(role="assistant", content="прошлый ответ оператора")]
        turns = merge_chat_history([], {}, client, "что ты имел в виду?")
        self.assertEqual(turns[0].content, "прошлый ответ оператора")

    def test_provider_forecast_is_rejected_without_forecast_intent(self):
        actions = filter_planned_actions([{"operation": "predict", "level": "period"}], "что это значит?", [], "ru")
        self.assertEqual(actions[0]["operation"], "answer")

    def test_explicit_forecast_is_preserved(self):
        actions = filter_planned_actions([{"operation": "predict", "level": "next_period"}], "Сделай прогноз", [], "ru")
        self.assertEqual(actions, [{"operation": "predict", "level": "next_period"}])

    def test_multiple_requests_remain_separate(self):
        parts = split_explicit_requests("Покажи средний балл, а ещё объясни прошлое сообщение")
        self.assertEqual(parts, ["Покажи средний балл", "объясни прошлое сообщение"])

    def test_referential_forecast_can_use_immediate_context(self):
        history = [ChatTurn(role="user", content="Сделай прогноз на следующий период")]
        actions = filter_planned_actions([{"operation": "predict", "level": "next_period"}], "повтори это", history, "ru")
        self.assertEqual(actions[0]["operation"], "predict")

    def test_frontend_has_safe_forecast_fallback_and_error_persistence(self):
        html = Path("app/app.html").read_text(encoding="utf-8")
        self.assertIn("function safeFormatAI", html)
        self.assertIn("AI response formatting failed", html)
        self.assertIn("AI error message was not persisted", html)

    def test_prompt_treats_operator_text_as_own_reply_but_not_instruction(self):
        source = Path("app/main.py").read_text(encoding="utf-8")
        self.assertIn("Treat every assistant turn in conversation_history", source)
        self.assertIn("including replies written by a human operator", source)
        self.assertIn("Continue naturally from the full visible context", source)

    def test_contextual_reply_is_decided_by_model_not_a_canned_function(self):
        source = Path("app/main.py").read_text(encoding="utf-8")
        self.assertNotIn("def conversational_repair_action", source)
        self.assertNotIn("repair=conversational_repair_action", source)
        self.assertNotIn("planned=deterministic_actions(part", source)
        self.assertNotIn("local=deterministic_actions(body.message", source)
        self.assertIn("You are Perfecta's conversational AI assistant", source)
        self.assertIn("Continue naturally from the full visible context", source)
        self.assertIn("Treat every assistant turn in conversation_history", source)

    def test_operator_control_has_logout_release_and_expiring_lease(self):
        source = Path("app/main.py").read_text(encoding="utf-8")
        sql = Path("database/admin-chat-takeover.sql").read_text(encoding="utf-8")
        self.assertIn('rpc("ai_chat_admin_release_all"', source)
        self.assertIn("now()-interval '30 minutes'", sql)
        self.assertIn("control_updated_at=now()", sql)
        self.assertIn("private.ai_chat_admin_release_all", sql)


if __name__ == "__main__":
    unittest.main()

