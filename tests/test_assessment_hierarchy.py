import json
import subprocess
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


class AssessmentHierarchyTests(unittest.TestCase):
    def test_dashboard_average_uses_the_same_computed_grades_as_results(self):
        import re
        html=(ROOT / "app" / "app.html").read_text(encoding="utf-8")
        source=re.search(r"function weighted\(rs\)\{[^\n]+",html).group(0)
        script=f"""
const calculatedSubjectGrade=id=>({{1:{{value:90}},2:{{value:80}}}}[id]||{{value:null}});
const rows=name=>name==='academic_settings'?[{{settings_id:1,calendar_type:'trimester'}}]:[];
const displayPeriod=()=>({{settings_id:1}});
const schoolPercent=x=>x*20;
{source}
process.stdout.write(String(weighted([
  {{performance_id:1,current_grade:40,credits:5}},
  {{performance_id:2,current_grade:50,credits:2}}
])));
"""
        result=subprocess.run(["node","-e",script],capture_output=True,text=True,check=True)
        self.assertAlmostEqual(float(result.stdout),(90*5+80*2)/7)

    def test_dashboard_finds_grade_band_from_postgres_range(self):
        import re
        html=(ROOT / "app" / "app.html").read_text(encoding="utf-8")
        source=re.search(r"function profileBand\(percent,[^\n]+",html).group(0)
        script=f"""
const rows=name=>name==='academic_settings'?[{{settings_id:1,scale_id:4}}]:
 name==='grading_bands'?[{{scale_id:4,score_range:'[80,85)',letter_grade:'B'}}]:[];
const displayPeriod=()=>({{settings_id:1}});
{source}
process.stdout.write(profileBand(84)?.letter_grade||'none');
"""
        result=subprocess.run(["node","-e",script],capture_output=True,text=True,check=True)
        self.assertEqual(result.stdout,"B")

    def test_intermediate_result_marks_incomplete_branches(self):
        script=r"""
const fs=require('fs'),vm=require('vm');
const data={assessment_components:[
 {component_id:1,performance_id:1,parent_component_id:null,weight_percent:60},
 {component_id:2,performance_id:1,parent_component_id:null,weight_percent:40},
 {component_id:3,performance_id:1,parent_component_id:1,weight_percent:50},
 {component_id:4,performance_id:1,parent_component_id:1,weight_percent:50}],
 assessments:[{assessment_id:10,component_id:3,maximum_score:100},
              {assessment_id:11,component_id:4,maximum_score:100},
              {assessment_id:12,component_id:2,maximum_score:100}],
 assessment_results:[{assessment_id:10,status:'graded',score:76}]};
const context={rows:name=>data[name]||[],academicAssessmentsV2:()=>'',calculatedSubjectGrade:()=>null,
 tr:(key,options)=>options?.defaultValue||key,esc:x=>String(x)};
vm.createContext(context);vm.runInContext(fs.readFileSync(process.argv[1],'utf8'),context);
const b=context.hierarchyBreakdown(1);
process.stdout.write(JSON.stringify({midterm:b.categories.get(1),empty:b.categories.get(4),root:b.root,
 markup:context.categoryResultMarkup(1,b)}));
"""
        result=subprocess.run(["node","-e",script,str(ROOT / "app" / "assessment-hierarchy.js")],
                              capture_output=True,text=True,check=True)
        output=json.loads(result.stdout)
        self.assertEqual(output["midterm"]["value"],76)
        self.assertFalse(output["midterm"]["complete"])
        self.assertEqual((output["midterm"]["gradedWorks"],output["midterm"]["totalWorks"]),(1,2))
        self.assertIsNone(output["empty"]["value"])
        self.assertIn("76%",output["markup"])

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
