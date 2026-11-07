"""Deterministic calculations and explicitly unvalidated baseline forecasts."""
import math
import re
from datetime import date
from statistics import mean

def item_weight(item):
    if item.get("credits") is not None:return item["credits"]
    if item.get("workload_value") is not None:return item["workload_value"]
    if "credits" in item or "workload_value" in item:raise ValueError("Workload is required")
    return 1

def weighted(items):
    valid = [(float(x["grade"]), float(item_weight(x))) for x in items if x.get("grade") is not None]
    if not valid or any(w <= 0 or not math.isfinite(g+w) for g,w in valid):
        raise ValueError("Positive weights and finite grades are required")
    return sum(g*w for g,w in valid)/sum(w for _,w in valid)

def grade_points(grade, bands):
    for b in bands:
        raw=b["score_range"]
        if isinstance(raw, dict):
            lo,hi=raw["lower"],raw["upper"]
            inclusive=raw.get("upper_inclusive",False)
        else:
            m=re.fullmatch(r"([\[(])([^,]+),([^\])]+)([\])])",raw)
            if not m: continue
            lo,hi=float(m[2]),float(m[3]); inclusive=m[4]=="]"
        if float(lo)<=grade and (grade<float(hi) or inclusive and grade==float(hi)):
            return float(b["grade_points"])
    return None

def calculate(items, bands=None):
    score=weighted(items)
    units={x.get("workload_unit","credits") for x in items}
    if len(units)>1:raise ValueError("Different workload units require explicit conversion")
    points=[dict(grade=grade_points(float(x["grade"]), bands or []),credits=item_weight(x)) for x in items]
    gpa=weighted(points) if points and all(x["grade"] is not None for x in points) else None
    total=sum(float(item_weight(x)) for x in items)
    return {"average":round(score,4),"gpa":round(gpa,4) if gpa is not None else None,
            "included_items":len(items),"credits":total if units=={"credits"} else None,"workload_total":total,"workload_unit":next(iter(units)),
            "gpa_note":None if gpa is not None else "No complete matching GPA conversion supplied"}

def forecast(data, period_id, level="period"):
    periods={x["period_id"]:x for x in data["academic_periods"]}
    if period_id not in periods: raise ValueError("Period not found")
    period=periods[period_id]
    today=date.today().isoformat()
    if period["status"]!="active" or period.get("start_date") and period["start_date"]>today or period.get("end_date") and period["end_date"]<today:
        raise ValueError("Forecasts are restricted to an active current period")
    settings=next(x for x in data["academic_settings"] if x["settings_id"]==period["settings_id"])
    if settings["grading_scale"] not in ("percent_100","gpa_4"):
        raise ValueError("Numeric grading scale required")
    lo,hi=float(settings["grade_min"]),float(settings["grade_max"])
    records=[x for x in data["academic_performance"] if x["period_id"]==period_id]
    if not records: raise ValueError("No academic records in this period")
    bands=[b for b in data.get("grading_bands",[]) if b["scale_id"]==settings.get("scale_id")]
    actual={x["performance_id"]:x for x in data.get("actual_results",[])}
    estimates=[]
    for r in records:
        if r.get("current_grade") is None: continue
        current=float(r["current_grade"])
        # Conservative baseline: current performance with a small recent-assessment signal.
        recent=r.get("recent_assessment_score")
        estimate=current if recent is None else .8*current+.2*float(recent)
        estimate=max(lo,min(hi,estimate))
        components=[c for c in data.get("assessment_components",[]) if c["performance_id"]==r["performance_id"]]
        component_estimates={}
        for c in components:
            assessments=[a for a in data.get("assessments",[]) if a["component_id"]==c["component_id"]]
            results={a["assessment_id"]:a for a in data.get("assessment_results",[]) if a["status"]=="graded" and a.get("score") is not None}
            scored=[a for a in assessments if a["assessment_id"] in results]
            if scored:
                fraction=sum(float(results[a["assessment_id"]]["score"]) for a in scored)/sum(float(a["maximum_score"]) for a in scored)
                component_estimates[c["component_id"]]=max(lo,min(hi,lo+(hi-lo)*fraction))
        if components:
            total_weight=sum(float(c["weight_percent"]) for c in components)
            if total_weight>100.00001:raise ValueError("Assessment weights exceed 100 percent")
            estimate=(sum(float(c["weight_percent"])*component_estimates.get(c["component_id"],estimate) for c in components)+(100-total_weight)*estimate)/100
        exam=[]
        for c in data.get("assessment_components",[]):
            if c["performance_id"]==r["performance_id"] and c["component_type"] in ("midterm","final"):
                exam.append({"component_id":c["component_id"],"name":c["name"],"estimated_grade":round(component_estimates.get(c["component_id"],estimate),2),
                             "note":"Same baseline on course scale; not an independently validated exam model"})
        signals=[]
        if r.get("attendance") is not None and float(r["attendance"])<75:signals.append("Attendance below illustrative 75% threshold")
        if r.get("assignments_total") and (r.get("assignments_completed") or 0)<r["assignments_total"]:signals.append("There are unfinished assignments")
        estimates.append({"performance_id":r["performance_id"],"course_id":r["course_id"],"grade":estimate,"signals":signals,
                          "credits":r.get("credits"),"workload_value":r.get("workload_value") or r.get("credits"),"workload_unit":r.get("workload_unit") or "credits","current_grade":current,"exams":exam})
    if not estimates: raise ValueError("Numeric current grades required")
    if any(x["workload_value"] is None for x in estimates):
        raise ValueError("Workload is required for every included subject")
    if len({x["workload_unit"] for x in estimates})>1:raise ValueError("Different workload units require explicit conversion")
    selected=[dict(grade=x["grade"],workload_value=x["workload_value"],workload_unit=x["workload_unit"]) for x in estimates]
    coverage={"current_subjects":len(estimates)}
    if level in ("year","program"):
        year=next(x for x in data["academic_years"] if x["year_id"]==period["year_id"])
        year_periods=[p for p in periods.values() if p["year_id"]==year["year_id"]]
        expected=year.get("planned_period_count")
        if not expected: raise ValueError("Set planned_period_count for the academic year")
        completed={p["period_id"] for p in year_periods if p["status"]=="completed"}
        completed_records=[r for r in data["academic_performance"] if r["period_id"] in completed]
        if not completed_records or any(r["performance_id"] not in actual or actual[r["performance_id"]].get("final_grade") is None for r in completed_records):
            raise ValueError("Completed periods need actual final grades for every subject")
        observed=completed|{period_id}
        required=math.ceil(2*expected/3)
        coverage.update(observed_periods=len(observed),required_periods=required,expected_periods=expected)
        if len(observed)<required: raise ValueError("Insufficient periods: need at least two thirds of the year")
        # Never silently mix grading scales across historical periods.
        def historical_item(r):
            p=periods[r["period_id"]]
            s=next(x for x in data["academic_settings"] if x["settings_id"]==p["settings_id"])
            if (s["grade_min"],s["grade_max"],s["scale_id"]) != (settings["grade_min"],settings["grade_max"],settings["scale_id"]):
                raise ValueError("Historical scale differs; explicit conversion required")
            value=r.get("workload_value") or r.get("credits");unit=r.get("workload_unit") or "credits"
            if value is None: raise ValueError("Historical workload required")
            return {"grade":actual[r["performance_id"]]["final_grade"],"workload_value":value,"workload_unit":unit}
        selected += [historical_item(r) for r in completed_records]
        if level=="program":
            program=next(x for x in data["study_programs"] if x["program_id"]==year["program_id"])
            duration=program.get("duration_years")
            if not duration: raise ValueError("Program duration is required")
            years={y["year_id"] for y in data["academic_years"] if y["program_id"]==program["program_id"] and y["year_number"]<year["year_number"]}
            complete_years=[]
            old_records=[]
            for yid in years:
                y=next(y for y in data["academic_years"] if y["year_id"]==yid)
                ps=[p for p in periods.values() if p["year_id"]==yid]
                rs=[r for r in data["academic_performance"] if r["period_id"] in {p["period_id"] for p in ps}]
                if y.get("planned_period_count") and len(ps)==y["planned_period_count"] and all(p["status"]=="completed" for p in ps) and rs and all(r["performance_id"] in actual and actual[r["performance_id"]].get("final_grade") is not None for r in rs):
                    complete_years.append(yid); old_records+=rs
            if len(complete_years)<max(1,math.ceil(float(duration)*2/3)):
                raise ValueError("Insufficient completed years for whole-program forecast")
            selected += [historical_item(r) for r in old_records]
            coverage["completed_years"]=len(complete_years)
    output=calculate(selected,bands)
    return {**output,"level":level,"period_id":period_id,"subjects":estimates,"coverage":coverage,
            "method_version":"conservative-baseline-v1","is_illustrative":True,
            "assumption":"Unobserved future work follows the weighted performance observed so far",
            "limitations":["Not trained or validated on student outcomes","Not a guaranteed result",
                           "Year/program averages assume comparable future subject and credit distribution",
                           "No statistical confidence interval is claimed"]}


