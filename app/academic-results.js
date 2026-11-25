function resultText(key){return tr('academicResults.'+key,{defaultValue:key})}

function attachLibrarySubjects(){
  const period=selectedAcademicPeriod();if(!period)return;
  const used=new Set(rows('academic_performance').filter(x=>x.period_id==period.period_id).map(x=>Number(x.course_id)));
  const available=rows('courses').filter(x=>!used.has(Number(x.course_id)));
  modal(tr('academicEntry.attachTitle',{defaultValue:'Add existing subjects'}),
    available.length?`<p class="sub">${esc(tr('academicEntry.attachHint',{defaultValue:'Choose subjects for this period. You can add grades and attendance later.'}))}</p>${available.map(x=>`<label class="inline-check"><input class="attach-course" type="checkbox" value="${x.course_id}"><span data-user-text>${esc(courseLabel(x.course_id))}</span></label>`).join('')}<button class="btn wide" onclick="saveAttachedSubjects(${period.period_id})">${esc(tr('academics.actions.save'))}</button><div id="modalMsg" class="message"></div>`:`<p class="sub">${esc(tr('academicEntry.noAvailable',{defaultValue:'Every subject in your list is already in this period.'}))}</p>`);
}

async function saveAttachedSubjects(periodId){
  const ids=[...document.querySelectorAll('.attach-course:checked')].map(x=>Number(x.value)),msg=$('#modalMsg'),button=$('#modal button.wide');
  if(!ids.length){msg.textContent=tr('academicEntry.selectSubject',{defaultValue:'Choose a subject.'});return}
  if(button)button.disabled=true;
  try{
    await api('/academic/subjects/batch','POST',{data:{subjects:ids.map(id=>({course_name:courseLabel(id),period_id:periodId,entry_method:'manual'}))}},60000);
    closeModal();await refresh();window.academicTab='records';academics();
  }catch(error){msg.textContent=friendlyAcademicError(error.message)}
  finally{if(button?.isConnected)button.disabled=false}
}

function sortedAcademicResults(records){
  const mode=window.gradeSort||'desc';
  return records.slice().sort((a,b)=>{
    if(mode==='name')return courseLabel(a.course_id).localeCompare(courseLabel(b.course_id),state.prefs.language);
    const left=calculatedSubjectGrade(a.performance_id).value??a.current_grade;
    const right=calculatedSubjectGrade(b.performance_id).value??b.current_grade;
    const l=left==null?-Infinity:Number(left),r=right==null?-Infinity:Number(right);
    return mode==='asc'?l-r:r-l;
  });
}

function editAcademicResult(performanceId){
  const record=rows('academic_performance').find(x=>x.performance_id==performanceId);
  if(record)subjectModal(record);
}

async function removeRecord(performanceId){
  const record=rows('academic_performance').find(x=>x.performance_id==performanceId);
  if(!record)return;
  const name=courseLabel(record.course_id);
  if(!confirm(resultText('deleteConfirm').replace('{{name}}',name)))return;
  pendingWrites++;updateRequestProgress();
  try{
    await api(`/academic/records/${performanceId}`,'DELETE');
    await refresh();window.academicTab='records';academics();
  }catch(error){alert(friendlyAcademicError(error.message))}
  finally{pendingWrites=Math.max(0,pendingWrites-1);updateRequestProgress()}
}

function academicRecordsV3(){
  const period=selectedAcademicPeriod();
  const records=sortedAcademicResults(rows('academic_performance').filter(x=>x.period_id==period?.period_id));
  const options=[['desc','high'],['asc','low'],['name','name']].map(([value,key])=>`<option value="${value}" ${window.gradeSort===value?'selected':''}>${esc(resultText(key))}</option>`).join('');
  const toolbar=`<div class="academic-results-toolbar"><span class="pill">${records.length} ${esc(resultText('count'))}</span><label>${esc(resultText('sort'))}<select class="input" onchange="window.gradeSort=this.value;academics()">${options}</select></label><button class="btn secondary" onclick="attachLibrarySubjects()">${esc(tr('academicEntry.attachTitle',{defaultValue:'Add existing subjects'}))}</button><button class="btn" onclick="subjectModal()">+ ${esc(resultText('add'))}</button><button class="btn secondary" onclick="bulkSubjectModal()">${esc(resultText('bulk'))}</button></div>`;
  const rowsHtml=records.map(r=>{
    const grade=calculatedSubjectGrade(r.performance_id),value=grade.value??r.current_grade;
    const attendance=calculatedAttendance(r),unit=localizedValue(r.workload_unit||'credits');
    const lessonCount=`${r.lessons_attended??'—'} / ${r.lessons_held??'—'}`;
    return `<tr><td><button class="link academic-subject-link" onclick="openSubjectWorkspace(${r.performance_id})" data-user-text>${esc(courseLabel(r.course_id))}</button></td><td>${esc(r.workload_value??r.credits??'—')} ${esc(unit)}</td><td><span class="pill">${value==null?'—':Number(value).toFixed(1)+'%'}</span></td><td>${attendance==null?'—':attendance.toFixed(1)+'%'}</td><td>${esc(lessonCount)}</td><td>${grade.gradedWorks}/${grade.totalWorks}</td><td><div class="actions"><button class="btn secondary" onclick="editAcademicResult(${r.performance_id})">${esc(resultText('edit'))}</button><button class="btn ghost" onclick="openAttendanceEditor(${r.performance_id})">${esc(resultText('attendance'))}</button><button class="btn danger" onclick="removeRecord(${r.performance_id})">${esc(resultText('delete'))}</button></div></td></tr>`;
  }).join('');
  return `<div class="card academic-results-card">${toolbar}<div class="table-wrap"><table class="table"><thead><tr><th>${esc(resultText('subject'))}</th><th>${esc(resultText('workload'))}</th><th>${esc(resultText('grade'))}</th><th>${esc(resultText('attendance'))}</th><th>${esc(resultText('lessons'))}</th><th>${esc(resultText('works'))}</th><th>${esc(resultText('actions'))}</th></tr></thead><tbody>${rowsHtml}</tbody></table>${records.length?'':`<div class="empty">${esc(resultText('empty'))}</div>`}</div></div>`;
}

function dashboardSubjectCards(records){
  if(!records.length)return `<div class="empty">${esc(resultText('empty'))}</div>`;
  return `<div class="academic-summary-grid dashboard-subject-grid">${records.map(r=>{
    const grade=calculatedSubjectGrade(r.performance_id),value=grade.value??r.current_grade,attendance=calculatedAttendance(r);
    return `<article class="subject-summary"><div class="subject-summary-head"><div><h3 data-user-text>${esc(courseLabel(r.course_id))}</h3><p class="sub">${esc(r.workload_value??r.credits??'—')} ${esc(localizedValue(r.workload_unit||'credits'))}</p></div><span class="pill">${value==null?'—':Number(value).toFixed(1)+'%'}</span></div><div class="subject-summary-stats"><span>${esc(resultText('works'))}<b>${grade.gradedWorks}/${grade.totalWorks}</b></span><span>${esc(resultText('attendance'))}<b>${attendance==null?'—':attendance.toFixed(1)+'%'}</b></span><span>${esc(resultText('weights'))}<b>${grade.weight}%</b></span></div></article>`;
  }).join('')}</div>`;
}
