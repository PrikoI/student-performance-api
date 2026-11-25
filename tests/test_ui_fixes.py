import json
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
HTML = (ROOT / "app" / "app.html").read_text(encoding="utf-8")


class RecentUiFixTests(unittest.TestCase):
    def test_switching_period_does_not_force_results_tab(self):
        self.assertIn('onclick="switchAcademicPeriod(${period.period_id})"', HTML)
        self.assertNotIn("switchAcademicPeriod(${period.period_id});window.academicTab='records'", HTML)

    def test_calculator_uses_selected_period_and_supports_one_or_many(self):
        self.assertIn("const period=selectedAcademicPeriod()", HTML)
        self.assertIn("window.calcScope='single'", HTML)
        self.assertIn("window.calcScope='multiple'", HTML)
        self.assertNotIn("id=\"calcCalendar\"", HTML)
        self.assertIn("rows('academic_performance').filter(x=>x.period_id==period?.period_id)", HTML)

    def test_internal_rerender_reapplies_language(self):
        self.assertIn("applyLanguage();applyDataI18n($('#academicSection'))", HTML)
        for lang in ("en", "ru", "kk", "zh", "es"):
            locale = json.loads((ROOT / "app" / "locales" / f"{lang}.json").read_text(encoding="utf-8"))
            self.assertIn("calculatorV2", locale)
            self.assertEqual(set(locale["calculatorV2"]), set(json.loads((ROOT / "app" / "locales" / "en.json").read_text(encoding="utf-8"))["calculatorV2"]))

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


if __name__ == "__main__":
    unittest.main()
