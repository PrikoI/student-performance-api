function calcText(key){return tr('calculatorV2.'+key,{defaultValue:key})}

function calculator(){
  const period=selectedAcademicPeriod();
  const settings=rows('academic_settings').find(x=>x.settings_id==period?.settings_id);
  const year=rows('academic_years').find(x=>x.year_id==period?.year_id);
  const records=rows('academic_performance').filter(x=>x.period_id==period?.period_id);
  const school=(settings?.calendar_type||'trimester')==='quarter';
  if(!['average','attendance'].includes(window.calcMode))window.calcMode='average';
  if(!['single','multiple'].includes(window.calcScope))window.calcScope='multiple';
  const single=window.calcScope==='single',attendance=window.calcMode==='attendance';
  const scope=`<div class="field"><label>${esc(calcText('scope'))}</label><div class="section-tabs"><button class="${single?'active':''}" onclick="window.calcScope='single';calculator()">${esc(calcText('single'))}</button><button class="${single?'':'active'}" onclick="window.calcScope='multiple';calculator()">${esc(calcText('multiple'))}</button></div></div>`;
  const subjectChoice=single&&records.length?`<div class="field"><label>${esc(calcText('chooseSubject'))}</label><select id="calcSavedSubject" class="input" onchange="selectCalcSavedSubject(this.value)"><option value="">—</option>${records.map(x=>`<option value="${x.performance_id}">${esc(courseLabel(x.course_id))}</option>`).join('')}</select></div>`:'';
  const unit=attendance||single||school?'':`<div class="field"><label>${esc(calcText('unit'))}</label><select id="calcWorkloadUnit" class="input"><option value="credits">${esc(calcText('credits'))}</option><option value="academic_hours">${esc(calcText('hours'))}</option></select></div>`;
  const periodLabel=period?`${calcText('period')}: ${year?.year_label||''} · ${localizedPeriodName(period.period_id)}`:calcText('noPeriod');
  const body=`<p class="sub calc-period-label">${esc(periodLabel)}</p><div class="section-tabs"><button class="${attendance?'':'active'}" onclick="window.calcMode='average';calculator()">${esc(calcText('average'))}</button><button class="${attendance?'active':''}" onclick="window.calcMode='attendance';calculator()">${esc(calcText('attendance'))}</button></div><div class="grid"><div class="card span8">${scope}${subjectChoice}${unit}<h3>${esc(single?calcText('subject'):calcText('items'))}</h3><div id="calcRows" class="calc-rows"></div>${single?'':`<button class="btn secondary" style="margin-top:10px" onclick="addCalcRow()">+ ${esc(calcText('add'))}</button>`}<p class="sub">${esc(attendance?calcText('attendanceHint'):school?calcText('schoolHint'):single?calcText('singleHint'):calcText('multipleHint'))}</p><p id="calcMessage" class="message" role="status"></p><button id="calcRun" class="btn wide" onclick="runCalc()">${esc(calcText('calculate'))}</button></div><div id="calcResult" class="card span4 result" role="status" aria-live="polite"><div class="eyebrow">${esc(calcText('result'))}</div><div class="metric">—</div><p>${esc(calcText('empty'))}</p></div></div>`;
  setPage(calcText('title'),calcText('subtitle'),state.me?.role==='admin'?'':`<button class="btn secondary" onclick="loadSavedCalc()">${esc(calcText('saved'))}</button>`,body);
  addCalcRow();
  if($('#calcWorkloadUnit'))$('#calcWorkloadUnit').value=records.find(x=>x.workload_unit)?.workload_unit==='academic_hours'?'academic_hours':'credits';
  applyLanguage();applyDataI18n($('#content'));
}

function addCalcRow(v={}){
  const box=$('#calcRows');if(!box)return;
  const single=window.calcScope==='single',attendance=window.calcMode==='attendance';
  const school=academicCalendarForPeriod(selectedAcademicPeriod()?.period_id)==='quarter';
  if(single)box.innerHTML='';
  const name=`<input class="input cName" list="calcCourseSuggestions" aria-label="${esc(calcText('subject'))}" placeholder="${esc(calcText('subject'))}" value="${esc(v.name||'')}">`;
  const fields=attendance?`<input class="input cHeld" type="number" min="1" aria-label="${esc(calcText('held'))}" placeholder="${esc(calcText('held'))}" value="${esc(v.held??'')}"><input class="input cAttended" type="number" min="0" aria-label="${esc(calcText('attended'))}" placeholder="${esc(calcText('attended'))}" value="${esc(v.attended??'')}"><input class="input cExcused" type="number" min="0" aria-label="${esc(calcText('excused'))}" placeholder="${esc(calcText('excused'))}" value="${esc(v.excused??'')}">`:`<input class="input cGrade" type="number" min="0" max="100" step="0.01" aria-label="${esc(calcText('grade'))}" placeholder="${esc(school?calcText('schoolGrade'):calcText('grade'))}" value="${esc(v.grade??'')}">${single||school?'':`<input class="input cCredits" type="number" min="0" step="0.01" aria-label="${esc(calcText('weight'))}" placeholder="${esc(calcText('weight'))}" value="${esc(v.workload??'')}">`}`;
  const remove=single?'':`<button class="icon-btn" onclick="this.parentElement.remove()" aria-label="${esc(calcText('remove'))}">×</button>`;
  const element=document.createElement('div');element.className=`calc-row-v3 ${attendance?'attendance-row':'grade-row'} ${single?'single':''}`;element.innerHTML=name+fields+remove;box.appendChild(element);
  let list=$('#calcCourseSuggestions');if(!list){list=document.createElement('datalist');list.id='calcCourseSuggestions';document.body.appendChild(list)}
  list.innerHTML=rows('courses').map(c=>`<option value="${esc(courseLabel(c.course_id))}"></option>`).join('');
}

function selectCalcSavedSubject(value){
  const record=rows('academic_performance').find(x=>x.performance_id==Number(value));
  const row=$('#calcRows .calc-row-v3');if(!record||!row)return;
  row.querySelector('.cName').value=courseLabel(record.course_id);
  if(window.calcMode==='attendance'){
    row.querySelector('.cHeld').value=record.lessons_held??'';
    row.querySelector('.cAttended').value=record.lessons_attended??'';
    row.querySelector('.cExcused').value=record.lessons_excused??'';
  }else row.querySelector('.cGrade').value=calculatedSubjectGrade(record.performance_id).value??record.current_grade??'';
}

function loadSavedCalc(){
  const period=selectedAcademicPeriod(),all=rows('academic_performance').filter(x=>x.period_id==period?.period_id),msg=$('#calcMessage');
  if(!all.length){msg.textContent=calcText('noSaved');return}
  msg.textContent='';
  if(window.calcScope==='single'){
    const chosen=all.find(x=>x.performance_id==Number($('#calcSavedSubject')?.value))||all[0];
    if($('#calcSavedSubject'))$('#calcSavedSubject').value=chosen.performance_id;
    selectCalcSavedSubject(chosen.performance_id);
    if(window.calcMode==='attendance'&&!(Number(chosen.lessons_held)>0&&chosen.lessons_attended!=null))msg.textContent=calcText('noAttendance');
    return;
  }
  const attendance=window.calcMode==='attendance';
  const gradeOf=x=>calculatedSubjectGrade(x.performance_id).value??x.current_grade;
  const selected=all.filter(x=>attendance?Number(x.lessons_held)>0&&x.lessons_attended!=null:gradeOf(x)!=null);
  if(!selected.length){msg.textContent=calcText(attendance?'noAttendance':'noGrades');return}
  $('#calcRows').innerHTML='';
  for(const x of selected)addCalcRow({name:courseLabel(x.course_id),grade:gradeOf(x),workload:x.workload_value??x.credits,held:x.lessons_held,attended:x.lessons_attended,excused:x.lessons_excused});
  if(selected.length<all.length)msg.textContent=calcText('skippedIncomplete').replace('{{count}}',all.length-selected.length);
}

function showCalcResult(html){
  const box=$('#calcResult');box.innerHTML=html;
  box.scrollIntoView({behavior:matchMedia('(prefers-reduced-motion: reduce)').matches?'instant':'smooth',block:'start'});
}

function calcSubjectResults(rows,result,key){
  if(rows.length<2)return '';
  return `<div class="calc-subject-results"><h3>${esc(calcText('bySubject'))}</h3>${rows.map((row,i)=>{
    const name=row.querySelector('.cName').value.trim()||`${calcText('subject')} ${i+1}`;
    const value=Number(result.subject_results?.[i]?.[key]);
    return `<div class="calc-subject-result"><span data-user-text>${esc(name)}</span><b>${Number.isFinite(value)?value.toFixed(1)+'%':'—'}</b></div>`;
  }).join('')}</div>`;
}

async function runCalc(){
  const button=$('#calcRun');if(!button||button.disabled)return;
  button.disabled=true;button.textContent=calcText('calculating');
  try{
    const period=selectedAcademicPeriod(),settings=rows('academic_settings').find(x=>x.settings_id==period?.settings_id);
    const calendar=settings?.calendar_type||'trimester',school=calendar==='quarter',single=window.calcScope==='single';
    const rowsOnPage=[...document.querySelectorAll('#calcRows .calc-row-v3')];
    if(!rowsOnPage.length)throw Error(calcText('needRow'));
    const payload={calendar,mode:window.calcMode,items:[]};
    if(window.calcMode==='attendance'){
      payload.items=rowsOnPage.map(row=>{
        const fields=['.cHeld','.cAttended','.cExcused'].map(selector=>row.querySelector(selector).value);
        const [held,attended,excused]=fields.map((value,i)=>i===2&&value===''?0:Number(value));
        if(fields[0]===''||fields[1]===''||!Number.isInteger(held)||!Number.isInteger(attended)||!Number.isInteger(excused)||held<=0||attended<0||excused<0||attended+excused>held)throw Error(calcText('invalidAttendance'));
        return {lessons_held:held,lessons_attended:attended,lessons_excused:excused};
      });
      const result=await api('/calculate','POST',payload);
      showCalcResult(`<div class="eyebrow">${esc(calcText('attendanceResult'))}</div><div class="metric">${Number(result.attendance).toFixed(1)}%</div><p>${esc(calcText('physical'))}: ${Number(result.physical_attendance).toFixed(1)}%</p>${calcSubjectResults(rowsOnPage,result,'attendance')}`);
      return;
    }
    const unit=$('#calcWorkloadUnit')?.value||'credits';
    payload.items=rowsOnPage.map(row=>{
      const raw=row.querySelector('.cGrade').value,grade=Number(raw);
      if(raw===''||!Number.isFinite(grade)||grade<0||grade>100)throw Error(calcText('invalidGrade'));
      const item={grade};
      if(!school){const weightRaw=row.querySelector('.cCredits')?.value,weight=single?1:Number(weightRaw);
        if(!single&&(weightRaw===''||!Number.isFinite(weight)||weight<=0))throw Error(calcText('invalidWeight'));
        item.workload_value=weight;item.workload_unit=single?'credits':unit;
      }
      return item;
    });
    payload.bands=rows('grading_bands').filter(x=>x.scale_id==settings?.scale_id);
    if(!payload.bands.length)payload.bands=templateBands(calendar);
    const result=await api('/calculate','POST',payload);
    const converted=[result.converted_grade,result.converted_points!=null&&!school?`${Number(result.converted_points).toFixed(2)} / 4.0`:null].filter(Boolean).join(' · ');
    showCalcResult(`<div class="eyebrow">${esc(calcText('result'))}</div><div class="metric">${Number(result.average_percent??result.average).toFixed(1)}%</div>${converted?`<p><b>${esc(calcText('profileScale'))}:</b> ${esc(converted)}</p>`:''}${result.estimated_from_final_grades?`<p>${esc(calcText('approximate'))}</p>`:''}${calcSubjectResults(rowsOnPage,result,'percent')}`);
  }catch(error){showCalcResult(`<div class="eyebrow">${esc(calcText('result'))}</div><p>${esc(error.message)}</p>`)}
  finally{button.disabled=false;button.textContent=calcText('calculate')}
}
