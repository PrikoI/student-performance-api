import json
import subprocess
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


class AssessmentHierarchyTests(unittest.TestCase):
    def test_browser_grade_matches_nested_database_example(self):
        script = r"""
const fs=require('fs'),vm=require('vm');
const data={
 assessment_components:[
  {component_id:1,performance_id:1,parent_component_id:null,weight_percent:60},
  {component_id:2,performance_id:1,parent_component_id:null,weight_percent:40},
  {component_id:3,performance_id:1,parent_component_id:1,weight_percent:50},
  {component_id:4,performance_id:1,parent_component_id:1,weight_percent:50}],
 assessments:[{assessment_id:2,component_id:2,maximum_score:100},
  {assessment_id:3,component_id:3,maximum_score:100},
  {assessment_id:4,component_id:4,maximum_score:100}],
 assessment_results:[{assessment_id:2,status:'graded',score:95},
  {assessment_id:3,status:'graded',score:70},
  {assessment_id:4,status:'graded',score:90}]};
const context={rows:name=>data[name]||[],academicAssessmentsV2:()=>'',calculatedSubjectGrade:()=>null};
vm.createContext(context);
vm.runInContext(fs.readFileSync(process.argv[1],'utf8'),context);
process.stdout.write(JSON.stringify(context.hierarchyScore(1)));
"""
        result = subprocess.run(
            ["node", "-e", script, str(ROOT / "app" / "assessment-hierarchy.js")],
            capture_output=True, text=True, check=True,
        )
        grade = json.loads(result.stdout)
        self.assertAlmostEqual(grade["value"], 86)
        self.assertEqual((grade["gradedWorks"], grade["totalWorks"], grade["weight"]), (3, 3, 100))

    def test_database_uses_one_transaction_for_hierarchy_and_work_moves(self):
        sql = (ROOT / "database" / "assessment-hierarchy.sql").read_text(encoding="utf-8")
        self.assertIn("create or replace function private.replace_assessment_hierarchy", sql)
        self.assertIn("update public.assessments set component_id=ids[move_index+1]", sql)
        self.assertIn("perform private.recalculate_performance_grade", sql)
        self.assertIn("security definer set search_path=''", sql)


if __name__ == "__main__":
    unittest.main()
