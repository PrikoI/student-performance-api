import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


class DatabaseMigrationTests(unittest.TestCase):
    def test_attendance_is_derived_from_counts(self):
        sql = (ROOT / "database" / "derive-attendance-from-counts.sql").read_text(encoding="utf-8")
        self.assertIn("new.lessons_attended > new.lessons_held", sql)
        self.assertIn("new.attendance_source='counts'", sql)
        self.assertIn("when new.lessons_held=0 then null", sql)
        self.assertIn("before insert or update", sql.lower())

    def test_course_deletion_is_owned_and_transactional(self):
        sql = (ROOT / "database" / "safe-course-deletion.sql").read_text(encoding="utf-8")
        self.assertIn("owner_student_id=account.student_id", sql)
        order = [
            "delete from public.assessment_results",
            "delete from public.assessments",
            "delete from public.assessment_components",
            "delete from public.academic_performance",
            "delete from public.courses",
        ]
        positions = [sql.lower().index(statement) for statement in order]
        self.assertEqual(positions, sorted(positions))
        self.assertIn("security invoker", sql.lower())
        self.assertIn("revoke all on function private.course_delete_info", sql.lower())

    def test_assessment_template_registry_is_validated_and_admin_managed(self):
        sql = (ROOT / "database" / "assessment-category-template-registry.sql").read_text(encoding="utf-8")
        for fragment in (
            "private.valid_assessment_categories",
            "abs((select coalesce(sum",
            "account.role<>'admin'",
            "is_system=false",
            "public.assessment_template_list",
        ):
            self.assertIn(fragment, sql)

    def test_personal_templates_are_scoped_to_account(self):
        sql = (ROOT / "database" / "personal-assessment-category-templates.sql").read_text(encoding="utf-8")
        self.assertIn("where t.account_id=account.account_id", sql)
        self.assertIn("where template_id=tid and account_id=account.account_id", sql)
        self.assertIn("references public.accounts(account_id) on delete cascade", sql)


if __name__ == "__main__":
    unittest.main()
