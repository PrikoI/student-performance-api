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


if __name__ == "__main__":
    unittest.main()
