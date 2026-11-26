import json
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
HTML = (ROOT / "app" / "app.html").read_text(encoding="utf-8")
CALCULATOR = (ROOT / "app" / "calculator.js").read_text(encoding="utf-8")
RESULTS = (ROOT / "app" / "academic-results.js").read_text(encoding="utf-8")


class RecentUiFixTests(unittest.TestCase):
    def test_category_rpc_wrapper_can_call_private_function(self):
        sql = (ROOT / "database" / "replace-assessment-categories-batch.sql").read_text(encoding="utf-8")
        wrapper = sql.split("create or replace function public.replace_assessment_categories_batch", 1)[1]
        self.assertIn("security definer set search_path=''", wrapper)
        self.assertIn("grant execute on function public.replace_assessment_categories_batch", wrapper)

    def test_switching_period_does_not_force_results_tab(self):
        self.assertIn('onclick="switchAcademicPeriod(${period.period_id})"', HTML)
        self.assertNotIn("switchAcademicPeriod(${period.period_id});window.academicTab='records'", HTML)

    def test_calculator_uses_selected_period_and_supports_one_or_many(self):
        self.assertIn("const period=selectedAcademicPeriod()", CALCULATOR)
        self.assertIn("window.calcScope='single'", CALCULATOR)
        self.assertIn("window.calcScope='multiple'", CALCULATOR)
        self.assertNotIn("id=\"calcCalendar\"", HTML)
        self.assertIn("rows('academic_performance').filter(x=>x.period_id==period?.period_id)", CALCULATOR)
        self.assertIn("result.subject_results?.[i]", CALCULATOR)
        self.assertIn("records:academicRecordsV3", HTML)
        self.assertIn("dashboardSubjectCards(rs)", HTML)
        self.assertIn("window.gradeSort=this.value;academics()", RESULTS)

    def test_internal_rerender_reapplies_language(self):
        self.assertIn("applyLanguage();applyDataI18n($('#academicSection'))", HTML)
        for lang in ("en", "ru", "kk", "zh", "es"):
            locale = json.loads((ROOT / "app" / "locales" / f"{lang}.json").read_text(encoding="utf-8"))
            self.assertIn("calculatorV2", locale)
            self.assertEqual(set(locale["calculatorV2"]), set(json.loads((ROOT / "app" / "locales" / "en.json").read_text(encoding="utf-8"))["calculatorV2"]))
            self.assertEqual(set(locale["academicResults"]), set(json.loads((ROOT / "app" / "locales" / "en.json").read_text(encoding="utf-8"))["academicResults"]))

    def test_custom_category_name_is_used_for_work_title(self):
        self.assertIn("function defaultWorkTitle(component)", HTML)
        self.assertIn("base=raw&&!standard.has(raw)?raw", HTML)

    def test_mutations_have_visible_progress(self):
        self.assertIn("function updateRequestProgress()", HTML)
        self.assertIn("writing=!['GET','HEAD'].includes", HTML)
        self.assertIn("if(writing){pendingWrites=Math.max(0,pendingWrites-1)", HTML)

    def test_template_password_change_keeps_current_password_check(self):
        sql = (ROOT / "database" / "allow-template-account-password-change.sql").read_text(encoding="utf-8")
        self.assertNotIn("Demo account password cannot be changed", sql)
        self.assertIn("credentials.password_hash <> extensions.crypt(p_current_password", sql)
        self.assertIn("session_hash<>current_session_hash", sql)

    def test_category_changes_use_one_atomic_request(self):
        self.assertIn("await api('/academic/categories/replace'", HTML)
        self.assertNotIn("for(const target of targets){const own=target===performanceId", HTML)
        sql = (ROOT / "database" / "replace-assessment-categories-batch.sql").read_text(encoding="utf-8")
        self.assertIn("private.valid_assessment_categories(p_categories)", sql)
        self.assertIn("student_id=account.student_id", sql)
        self.assertIn("A category with saved work cannot be replaced", sql)

    def test_period_record_deletion_removes_children_in_one_transaction(self):
        sql = (ROOT / "database" / "delete-academic-period-record.sql").read_text(encoding="utf-8")
        self.assertIn("student_id=account.student_id", sql)
        self.assertLess(sql.index("delete from public.assessment_results"), sql.index("delete from public.academic_performance"))
        self.assertIn("/academic/records/${performanceId}", RESULTS)


if __name__ == "__main__":
    unittest.main()
