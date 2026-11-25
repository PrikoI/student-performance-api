import unittest
from unittest.mock import AsyncMock, patch

from app.main import add_next_academic_year, course_delete_info, delete_personal_category_template, application_page


STUDENT = {"token": "session", "student_id": 1, "account_id": "account", "role": "student"}


class RepairedFlowTests(unittest.IsolatedAsyncioTestCase):
    async def test_course_delete_info_uses_owned_rpc(self):
        with patch("app.main.rpc", AsyncMock(return_value={"has_related_data": True})) as rpc:
            result = await course_delete_info(42, STUDENT)
        self.assertTrue(result["has_related_data"])
        rpc.assert_awaited_once_with("course_delete_info", {"p_token": "session", "p_course_id": 42})

    async def test_add_next_year_uses_current_account_session(self):
        with patch("app.main.rpc", AsyncMock(return_value={"year_id": 3, "period_count": 3})) as rpc:
            result = await add_next_academic_year(7, STUDENT)
        self.assertEqual(result["period_count"], 3)
        rpc.assert_awaited_once_with("add_next_academic_year", {"p_token": "session", "p_program_id": 7})

    async def test_personal_template_delete_uses_current_account_session(self):
        with patch("app.main.rpc", AsyncMock(return_value=True)) as rpc:
            result = await delete_personal_category_template(9, STUDENT)
        self.assertEqual(result, {"deleted": True})
        rpc.assert_awaited_once_with("personal_assessment_template_delete", {"p_token": "session", "p_template_id": 9})

    def test_blank_work_grade_is_rejected_before_saving(self):
        html = application_page()
        self.assertIn("if(!raw||!Number.isFinite(score)||score<0)", html)
        self.assertIn("academicWorkspace.workNames.", html)
