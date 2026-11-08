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

def normalized_weight(item, conversions=None):
    value=float(item_weight(item));unit=item.get("workload_unit","credits")
    factor=(conversions or {}).get(unit)
    return value*(float(factor) if factor is not None else 1)

def weighted(items, conversions=None):
    valid = [(float(x["grade"]), normalized_weight(x, conversions)) for x in items if x.get("grade") is not None]
    if not valid or any(w <= 0 or not math.isfinite(g+w) for g,w in valid):
        raise ValueError("Positive weights and finite grades are required")
    return sum(g*w for g,w in valid)/sum(w for _,w in valid)

def grade_band(grade, bands):
    for b in bands:
        raw=b["score_range"]
        if isinstance(raw, dict):
            lo,hi=raw["lower"],raw["upper"]
            inclusive=raw.get("upper_inclusive",False)
        else:
            m=re.fullmatch(r"([\\[(])([^,]+),([^\\])]+)([\\])])",raw)
            if not m: continue
            lo,hi=float(m[2]),float(m[3]); inclusive=m[4]=="]"
        if float(lo)<=grade and (grade<float(hi) or inclusive and grade==float(hi)):
            return b
    return None

def grade_points(grade, bands):
    band=grade_band(grade,bands)
    return float(band["grade_points"]) if band and band.get("grade_points") is not None else None

def school_grade_percent(value):
    value=float(value)
    return {2:20.0,3:52.0,4:74.5,5:92.5}.get(int(value)) if value.is_integer() and 2<=value<=5 else value

def calculate(items, bands=None, conversions=None):
    units={x.get("workload_unit","credits") for x in items}
    if len(units)>1 and (not conversions or any(u not in conversions for u in units)):
        raise ValueError("Different workload units require conversion factors for every unit")
    score=weighted(items, conversions)
    points=[dict(grade=grade_points(float(x["grade"]), bands or []),credits=normalized_weight(x, conversions)) for x in items]
    gpa=weighted(points) if points and all(x["grade"] is not None for x in points) else None
    total=sum(float(item_weight(x)) for x in items)
    normalized_total=sum(normalized_weight(x, conversions) for x in items)
    band=grade_band(score,bands or [])
    return {"average":round(score,4),"average_percent":round(score,4),"gpa":round(gpa,4) if gpa is not None else None,
            "converted_grade":band.get("letter_grade") if band else None,"converted_points":float(band["grade_points"]) if band and band.get("grade_points") is not None else None,
            "included_items":len(items),"credits":total if units=={"credits"} else None,"workload_total":total if len(units)==1 else None,"workload_unit":next(iter(units)) if len(units)==1 else "mixed",
            "normalized_workload_total":normalized_total if conversions else None,"normalized_workload_unit":"academic_hours" if conversions else None,
            "gpa_note":None if gpa is not None else "No complete matching conversion supplied"}

def forecast(data, period_id, level="period", method="baseline"):
    if method not in ("baseline","adaptive"): raise ValueError("Unknown forecast method")
    periods={x["period_id"]:x for x in data["academic_periods"]}
    if period_id not in periods: raise ValueError("Period not found")
    period=periods[period_id]
    today=date.today().isoformat()
    if period["status"]!="active" or period.get("start_date") and period["start_date"]>today or period.get("end_date") and period["end_date"]<today:
        raise ValueError("Forecasts are restricted to an active current period")
    settings=next(x for x in data["academic_settings"] if x["settings_id"]==period["settings_id"])
    if float(settings["grade_max"]) <= float(settings["grade_min"]):
        raise ValueError("Numeric grading scale required")
    school_mode=settings.get("calendar_type")=="quarter" or settings.get("grading_scale")=="five_point"
    lo,hi=float(settings["grade_min"]),float(settings["grade_max"])
    records=[x for x in data["academic_performance"] if x["period_id"]==period_id]
    if not records: raise ValueError("No academic records in this period")
    bands=[b for b in data.get("grading_bands",[]) if b["scale_id"]==settings.get("scale_id")]
    actual={x["performance_id"]:x for x in data.get("actual_results",[])}
    estimates=[]
    for r in records:
        if r.get("current_grade") is None: continue
        raw_current=float(r["current_grade"])
        current=school_grade_percent(raw_current) if school_mode else raw_current
        # Conservative baseline: current performance with a small recent-assessment signal.
        recent=r.get("recent_assessment_score")
        baseline=current if recent is None else .8*current+.2*float(recent)
        estimate=max(lo,min(hi,baseline))
        components=[c for c in data.get("assessment_components",[]) if c["performance_id"]==r["performance_id"]]
        adaptive_signals=[]
        if method=="adaptive":
            component_ids={c["component_id"] for c in components}
            all_assessments=[x for x in data.get("assessments",[]) if x["component_id"] in component_ids]
            result_by_assessment={x["assessment_id"]:x for x in data.get("assessment_results",[]) if x.get("status")=="graded" and x.get("score") is not None}
            observations=[]
            for assessment in sorted(all_assessments,key=lambda x:(str(x.get("due_at") or ""),x["assessment_id"])):
                result=result_by_assessment.get(assessment["assessment_id"])
                maximum=float(assessment["maximum_score"])
                if result and maximum>0:
                    observations.append(max(lo,min(hi,lo+(hi-lo)*float(result["score"])/maximum)))
            if observations:
                observed_mean=sum(observations)/len(observations)
                middle=max(1,len(observations)//2)
                early=sum(observations[:middle])/len(observations[:middle])
                late=sum(observations[middle:])/len(observations[middle:]) if observations[middle:] else early
                trend=late-early
                completion=min(1,len(observations)/max(1,len(all_assessments)))
                confidence=min(.75,.15+.12*len(observations))
                estimate=(1-confidence)*baseline+confidence*observed_mean+.5*trend*(1-completion)
                estimate=max(lo,min(hi,estimate))
                adaptive_signals=[f"Adaptive data points: {len(observations)}",f"Observed work: {round(completion*100)}%",f"Recent trend: {round(trend,2):+}"]
            else:
                adaptive_signals=["Adaptive forecast fell back to the baseline because no graded work is available"]
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
        signals=list(adaptive_signals)
        if r.get("attendance") is not None and float(r["attendance"])<75:signals.append("Attendance below illustrative 75% threshold")
        if r.get("assignments_total") and (r.get("assignments_completed") or 0)<r["assignments_total"]:signals.append("There are unfinished assignments")
        estimates.append({"performance_id":r["performance_id"],"course_id":r["course_id"],"grade":estimate,"signals":signals,
                          "credits":r.get("credits"),"workload_value":r.get("workload_value") or r.get("credits"),"workload_unit":r.get("workload_unit") or "credits","current_grade":raw_current,"normalized_current_percent":current,"exams":exam})
    if not estimates: raise ValueError("Numeric current grades required")
    if not school_mode and any(x["workload_value"] is None for x in estimates):
        raise ValueError("Workload is required for every included subject")
    if not school_mode and len({x["workload_unit"] for x in estimates})>1:raise ValueError("Different workload units require explicit conversion")
    selected=[{"grade":x["grade"]} if school_mode else dict(grade=x["grade"],workload_value=x["workload_value"],workload_unit=x["workload_unit"]) for x in estimates]
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
            if school_mode:return {"grade":actual[r["performance_id"]]["final_grade"]}
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
    selected_units={x.get("workload_unit","credits") for x in selected}
    # Kazakhstan higher-education standard: one academic credit represents
    # 30 academic hours of total student workload. Lessons remain incomparable.
    conversions={"credits":30,"academic_hours":1} if selected_units <= {"credits","academic_hours"} else None
    output=calculate(selected,bands,conversions)
    return {**output,"level":level,"period_id":period_id,"subjects":estimates,"coverage":coverage,
            "method_version":"adaptive-forecast-v1" if method=="adaptive" else "conservative-baseline-v1","is_illustrative":True,
            "assumption":"Unobserved future work follows the weighted performance observed so far",
            "limitations":["Not trained or validated on student outcomes","Not a guaranteed result",
                           "Year/program averages assume comparable future subject and credit distribution",
                           "No statistical confidence interval is claimed"]}


