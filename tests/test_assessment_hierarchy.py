import json
import subprocess
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


class AssessmentHierarchyTests(unittest.TestCase):
    def test_partial_nested_work_is_available_to_forecast(self):
        from app.academics import observed_assessment_percent
        data={"assessment_components":[
            {"component_id":1,"performance_id":7,"parent_component_id":None,"weight_percent":60},
            {"component_id":2,"performance_id":7,"parent_component_id":None,"weight_percent":40},
            {"component_id":3,"performance_id":7,"parent_component_id":1,"weight_percent":50},
            {"component_id":4,"performance_id":7,"parent_component_id":1,"weight_percent":50}],
            "assessments":[{"assessment_id":10,"component_id":3,"maximum_score":100},
                           {"assessment_id":11,"component_id":4,"maximum_score":100},
                           {"assessment_id":12,"component_id":2,"maximum_score":100}],
            "assessment_results":[{"assessment_id":10,"status":"graded","score":70},
                                  {"assessment_id":11,"status":"graded","score":90}]}
        self.assertAlmostEqual(observed_assessment_percent(data,7),80)
        data["assessment_results"].append({"assessment_id":12,"status":"graded","score":95})
        self.assertAlmostEqual(observed_assessment_percent(data,7),86)

    def test_forecast_includes_graded_work_inside_nested_exam(self):
        from app.academics import forecast
        data={"academic_periods":[{"period_id":1,"year_id":1,"settings_id":1,"period_number":1,"status":"active"}],
              "academic_settings":[{"settings_id":1,"calendar_type":"trimester","grading_scale":"percentage","grade_min":0,"grade_max":100,"scale_id":1}],
              "academic_performance":[{"performance_id":7,"period_id":1,"course_id":3,"current_grade":60,"credits":5,"workload_value":5,"workload_unit":"credits"}],
              "grading_bands":[],"actual_results":[],
              "assessment_components":[{"component_id":1,"performance_id":7,"parent_component_id":None,"weight_percent":100,"component_type":"final","name":"Exam"},
                                       {"component_id":2,"performance_id":7,"parent_component_id":1,"weight_percent":100,"component_type":"quiz","name":"Part"}],
              "assessments":[{"assessment_id":10,"component_id":2,"maximum_score":100}],
              "assessment_results":[{"assessment_id":10,"status":"graded","score":90}]}
        result=forecast(data,1,"period","adaptive")
        subject=result["subjects"][0]
        self.assertEqual(subject["exams"][0]["graded_works"],1)
        self.assertEqual(subject["normalized_current_percent"],90)

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
