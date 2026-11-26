// Keep the subject library and the selected period in one entry flow.
const previousAcademicCoursesV2=academicCoursesV2;
const previousAcademicGrading=academicGrading;
academicGrading=function(){
  const period=selectedAcademicPeriod();
  const settings=rows('academic_settings').find(x=>x.settings_id==period?.settings_id);
  if(settings?.calendar_type!=='quarter'&&settings?.grading_scale!=='five_point')return previousAcademicGrading();
  const scale=rows('grading_scales').find(x=>x.scale_id==settings.scale_id);
  const bands=rows('grading_bands').filter(x=>x.scale_id==settings.scale_id);
  return `<div class="academic-intro card"><div><h2>${esc(tr('academicEntry.schoolScaleTitle',{defaultValue:'Your grading scale'}))}</h2><p class="sub">${esc(tr('academicEntry.schoolScaleHint',{defaultValue:'This scale is used to show your grades and forecasts.'}))}</p></div></div>`+
    `<div class="card grading-scale-card"><h3>${esc(scale?.name||tr('academicEntry.schoolScaleTitle',{defaultValue:'Your grading scale'}))}</h3><div class="grade-band-list">${bands.map(band=>`<div class="grade-band"><span>${esc(formatScoreRange(band.score_range))}</span><b>${esc(band.letter_grade)}</b></div>`).join('')}</div></div>`;
};
academicCoursesV2=function(){
  return previousAcademicCoursesV2().replaceAll('entityModal("courses",','courseModal(');
};

courseModal=function(course={}){
  const editing=Boolean(course.course_id);
  modal(tr(editing?'academics.actions.edit':'academicResults.add'),
    `<div class="field"><label>${esc(resultText('subject'))}</label><input id="courseNameInput" class="input" maxlength="100" value="${esc(course.course_name||'')}" autocomplete="off"></div>`+
    (!editing&&selectedAcademicPeriod()?`<p class="sub">${esc(tr('academicEntry.addToPeriod',{defaultValue:'The subject will also appear in the selected study period.'}))}</p>`:'')+
    `<button class="btn wide" onclick="saveCourse(${course.course_id||'null'})">${esc(tr('academics.actions.save'))}</button><div id="modalMsg" class="message"></div>`);
};

saveCourse=async function(id){
  const name=$('#courseNameInput')?.value.trim(),msg=$('#modalMsg'),button=$('#modal button.wide');
  if(!name){msg.textContent=tr('academicEntry.nameRequired',{defaultValue:'Enter a subject name.'});return}
  if(button)button.disabled=true;
  try{
    if(id)await api(`/courses/${id}`,'PATCH',{name});
    else{
      const period=selectedAcademicPeriod();
      if(period)await api('/academic/subjects','POST',{data:{course_name:name,period_id:period.period_id,entry_method:'manual'}});
      else await api('/courses','POST',{name});
    }
    closeModal();await refresh();if(state.view==='academics')academics();
  }catch(error){msg.textContent=friendlyAcademicError(error.message)}
  finally{if(button?.isConnected)button.disabled=false}
};

subjectModal=function(record={}){
  const editing=Boolean(record.performance_id),period=record.period_id||selectedAcademicPeriod()?.period_id;
  const used=new Set(rows('academic_performance').filter(row=>row.period_id==period&&row.performance_id!=record.performance_id).map(row=>Number(row.course_id)));
  const choices=rows('courses').filter(course=>editing||!used.has(Number(course.course_id)));
  modal(tr(editing?'academics.actions.edit':'academicResults.add'),
    `<div class="field"><label>${esc(resultText('subject'))}</label><select id="mCourse" class="input"><option value="">${esc(tr('academicEntry.chooseSubject',{defaultValue:'Choose a subject'}))}</option>${choices.map(course=>`<option value="${course.course_id}" ${course.course_id==record.course_id?'selected':''} data-user-text>${esc(courseLabel(course.course_id))}</option>`).join('')}</select></div>`+
    (!editing?`<div class="field"><label>${esc(tr('academicEntry.newSubject',{defaultValue:'Or create a new subject'}))}</label><input id="mNewCourse" class="input" maxlength="100" autocomplete="off"></div>`:'')+
    `<div class="field"><label>${esc(tr('academicEntry.period',{defaultValue:'Study period'}))}</label><select id="mPeriod" class="input">${rows('academic_periods').map(item=>`<option value="${item.period_id}" ${item.period_id==period?'selected':''}>${esc(localizedPeriodName(item.period_id))}</option>`).join('')}</select></div>`+
    (editing?`<div class="field"><label>${esc(tr('academicEntry.workload',{defaultValue:'Study workload (optional)'}))}</label><input id="mWorkload" class="input" type="number" min="0" step="0.5" value="${esc(record.workload_value??record.credits??'')}"></div>`:'')+
    `<button class="btn wide" onclick="saveSubject(${record.performance_id||'null'})">${esc(tr('academics.actions.save'))}</button><div id="modalMsg" class="message"></div>`);
};

saveSubject=async function(id){
  const period=Number($('#mPeriod')?.value),courseId=Number($('#mCourse')?.value),name=$('#mNewCourse')?.value.trim(),msg=$('#modalMsg'),button=$('#modal button.wide');
  if(!period||(!courseId&&!name)){msg.textContent=tr('academicEntry.selectSubject',{defaultValue:'Choose or enter a subject.'});return}
  if(button)button.disabled=true;
  try{
    if(id){
      const raw=$('#mWorkload')?.value.trim();
      if(raw&&(!Number.isFinite(Number(raw))||Number(raw)<=0)){msg.textContent=tr('academicEntry.invalidWorkload',{defaultValue:'Enter a positive workload.'});return}
      const old=rows('academic_performance').find(row=>row.performance_id==id)||{};
      const unit=old.workload_unit||'credits',value=raw?Number(raw):null;
      await api(`/tables/academic_performance/${id}`,'PATCH',{data:{course_id:courseId,period_id:period,workload_value:value,workload_unit:value?unit:null,credits:value&&unit==='credits'?value:null}});
    }else{
      const courseName=name||courseLabel(courseId);
      await api('/academic/subjects','POST',{data:{course_name:courseName,period_id:period,entry_method:'manual'}});
    }
    closeModal();await refresh();if(state.view==='academics')academics();
  }catch(error){msg.textContent=friendlyAcademicError(error.message)}
  finally{if(button?.isConnected)button.disabled=false}
};
