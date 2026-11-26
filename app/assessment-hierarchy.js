// Each category level is weighted independently; names and nesting belong to the student.
function hierarchyText(key, fallback, options={}) {
  return tr('assessmentHierarchy.'+key,{defaultValue:fallback,...options});
}
function hierarchyChildren(components,parentId) {
  return components.filter(c => (c.parent_component_id==null?null:Number(c.parent_component_id))===parentId);
}
function hierarchyScore(performanceId) {
  const components=rows('assessment_components').filter(c=>c.performance_id==performanceId);
  const works=rows('assessments'),results=new Map(rows('assessment_results')
    .filter(r=>r.status==='graded'&&r.score!=null).map(r=>[Number(r.assessment_id),r]));
  let gradedWorks=0,totalWorks=0;
  function score(parentId,seen=new Set()) {
    const children=hierarchyChildren(components,parentId);
    let weighted=0,covered=0;
    for(const c of children) {
      if(seen.has(c.component_id))continue;
      const descendants=hierarchyChildren(components,Number(c.component_id));
      let value=null;
      if(descendants.length)value=score(Number(c.component_id),new Set([...seen,c.component_id]));
      else {
        const own=works.filter(w=>Number(w.component_id)===Number(c.component_id));
        totalWorks+=own.length;
        const graded=own.filter(w=>results.has(Number(w.assessment_id))&&Number(w.maximum_score)>0);
        gradedWorks+=graded.length;
        const maximum=graded.reduce((sum,w)=>sum+Number(w.maximum_score),0);
        if(maximum)value=graded.reduce((sum,w)=>sum+Number(results.get(Number(w.assessment_id)).score),0)/maximum*100;
      }
      if(value!=null){const weight=Number(c.weight_percent)||0;weighted+=value*weight;covered+=weight;}
    }
    return covered?weighted/covered:null;
  }
  const value=score(null);
  return {value,gradedWorks,totalWorks,weight:hierarchyChildren(components,null)
    .reduce((sum,c)=>sum+(Number(c.weight_percent)||0),0)};
}
calculatedSubjectGrade=hierarchyScore;

const previousAssessmentView=academicAssessmentsV2;
academicAssessmentsV2=function(){
  const period=selectedAcademicPeriod();
  const performances=rows('academic_performance').filter(p=>p.period_id==period?.period_id);
  const selected=performances.some(p=>p.performance_id==window.assessmentPerformanceId)
    ?window.assessmentPerformanceId:performances[0]?.performance_id;
  window.assessmentPerformanceId=selected;
  const components=rows('assessment_components').filter(c=>c.performance_id==selected);
  if(!components.some(c=>c.parent_component_id!=null)) {
    const html=previousAssessmentView();
    return selected?html.replace(
      `<button class="btn" onclick="openCategoryEditor(${selected})"`,
      `<button class="btn ghost" onclick="openHierarchyEditor(${selected})">${esc(hierarchyText('edit','Category tree'))}</button><button class="btn" onclick="openCategoryEditor(${selected})"`
    ):html;
  }
  const resultByAssessment=new Map(rows('assessment_results').map(r=>[Number(r.assessment_id),r]));
  const subjectButtons=performances.map(p=>`<button class="${p.performance_id==selected?'active':''}" onclick="openSubjectWorkspace(${p.performance_id})"><b>${esc(courseLabel(p.course_id))}</b><small>${esc(localizedPeriodName(p.period_id))}</small></button>`).join('');
  function renderBranch(parentId,depth=0){
    return hierarchyChildren(components,parentId).map(c=>{
      const children=hierarchyChildren(components,Number(c.component_id));
      const works=rows('assessments').filter(w=>Number(w.component_id)===Number(c.component_id));
      const workHtml=works.map(w=>{
        const r=resultByAssessment.get(Number(w.assessment_id));
        const score=r?.status==='graded'&&r.score!=null?`${r.score} / ${w.maximum_score}`:tr('academics.assessment.notGraded');
        return `<div class="work-row"><button class="assessment-item" onclick='openWorkGrade(${JSON.stringify(w)})'><b>${esc(w.title)}</b><span>${esc(score)}</span></button><button class="btn secondary" onclick='openWorkGrade(${JSON.stringify(w)})'>${esc(r?tr('academics.actions.edit'):tr('academics.assessment.addGrade'))}</button></div>`;
      }).join('');
      return `<section class="category-card hierarchy-card" style="--depth:${Math.min(depth,5)}"><div class="category-card-head"><div><h3>${esc(c.name)}</h3><p class="sub">${esc(categoryTypeLabel(c.component_type))} · ${esc(c.weight_percent)}%</p></div>${children.length?'':`<button class="btn ghost" onclick='entityModal("assessments",{component_id:${c.component_id}})'>+ ${esc(tr('academics.assessment.addAssessment'))}</button>`}</div>${workHtml}${children.length?renderBranch(Number(c.component_id),depth+1):''}</section>`;
    }).join('');
  }
  return `<div class="academic-intro card"><div><h2>${esc(tr('academics.assessment.title'))}</h2><p class="sub">${esc(hierarchyText('hint','Weights are calculated inside each parent category.'))}</p></div><div class="actions"><button class="btn secondary" onclick="openAttendanceEditor(${selected})">${esc(tr('academicWorkspace.workspace.editAttendance'))}</button><button class="btn" onclick="openHierarchyEditor(${selected})">${esc(hierarchyText('edit','Category tree'))}</button></div></div><div class="assessment-subject-layout"><aside class="card subject-picker">${subjectButtons}</aside><main class="card"><div class="assessment-list">${renderBranch(null)}</div></main></div>`;
};

function hierarchyDraftRows() {
  return [...document.querySelectorAll('#hierarchyRows .hierarchy-edit-row')];
}
function hierarchyEditorRow(item={},depth=0) {
  const type=item.component_type||'other';
  return `<div class="hierarchy-edit-row" data-id="${item.component_id||''}" data-depth="${depth}" style="--depth:${depth}"><input class="input hierarchy-name" aria-label="${esc(tr('academics.fields.name'))}" maxlength="100" value="${esc(item.name||'')}"><select class="input hierarchy-type" aria-label="${esc(hierarchyText('type','Type'))}">${['assignment','quiz','midterm','final','exam','coursework','formative','section_summative','quarter_summative','other'].map(t=>`<option value="${t}" ${type===t?'selected':''}>${esc(categoryTypeLabel(t))}</option>`).join('')}</select><input class="input hierarchy-weight" aria-label="${esc(tr('academics.fields.weight'))}" type="number" min="0" max="100" step="0.01" value="${esc(item.weight_percent??'')}"><button class="btn ghost" type="button" onclick="addHierarchyChild(this)">+ ${esc(hierarchyText('child','Subcategory'))}</button><button class="icon-btn" type="button" onclick="removeHierarchyRow(this)" aria-label="${esc(tr('academics.actions.delete'))}">×</button></div>`;
}
function addHierarchyChild(button) {
  const row=button.closest('.hierarchy-edit-row'),depth=Number(row.dataset.depth);
  if(depth>=5)return;
  let after=row;
  while(after.nextElementSibling&&Number(after.nextElementSibling.dataset.depth)>depth)after=after.nextElementSibling;
  after.insertAdjacentHTML('afterend',hierarchyEditorRow({},depth+1));
  updateHierarchyTotals();
}
function removeHierarchyRow(button) {
  const row=button.closest('.hierarchy-edit-row'),depth=Number(row.dataset.depth);
  while(row.nextElementSibling&&Number(row.nextElementSibling.dataset.depth)>depth)row.nextElementSibling.remove();
  row.remove();updateHierarchyTotals();
}
function hierarchyDraft() {
  const stack=[];
  return hierarchyDraftRows().map((row,index)=>{
    const depth=Number(row.dataset.depth);
    stack[depth]=index;
    return {component_id:row.dataset.id?Number(row.dataset.id):null,
      parent_index:depth?stack[depth-1]:null,name:row.querySelector('.hierarchy-name').value.trim(),
      type:row.querySelector('.hierarchy-type').value,weight:Number(row.querySelector('.hierarchy-weight').value)};
  });
}
function updateHierarchyTotals() {
  const nodes=hierarchyDraft(),groups=new Map();
  nodes.forEach(n=>{const key=n.parent_index??-1;groups.set(key,(groups.get(key)||0)+n.weight)});
  const invalid=[...groups.values()].some(total=>!Number.isFinite(total)||Math.abs(total-100)>.001);
  const status=$('#hierarchyTotal');
  if(status){status.textContent=invalid?hierarchyText('weightError','Each level must add up to 100%.'):hierarchyText('weightOk','Each level adds up to 100%.');status.style.color=invalid?'var(--danger)':'var(--accent)'}
  return !invalid;
}
function openHierarchyEditor(performanceId) {
  const components=rows('assessment_components').filter(c=>c.performance_id==performanceId);
  const lines=[];
  function visit(parentId,depth) {
    for(const c of hierarchyChildren(components,parentId)){lines.push(hierarchyEditorRow(c,depth));visit(Number(c.component_id),depth+1)}
  }
  visit(null,0);
  modal(hierarchyText('edit','Category tree'),
    `<p class="sub">${esc(hierarchyText('hint','Weights are calculated inside each parent category.'))}</p><div id="hierarchyRows">${lines.join('')}</div><button class="btn ghost" type="button" onclick="$('#hierarchyRows').insertAdjacentHTML('beforeend',hierarchyEditorRow());updateHierarchyTotals()">+ ${esc(hierarchyText('root','Main category'))}</button><div class="sticky-save"><p id="hierarchyTotal" class="sub"></p><button class="btn wide" onclick="saveHierarchy(${performanceId})">${esc(tr('academics.actions.save'))}</button><div id="modalMsg" class="message"></div></div>`);
  updateHierarchyTotals();
}
async function saveHierarchy(performanceId) {
  const nodes=hierarchyDraft(),msg=$('#modalMsg'),button=$('#modal .btn.wide');
  if(!nodes.length||nodes.some(n=>!n.name||!Number.isFinite(n.weight)||n.weight<0||n.weight>100)||!updateHierarchyTotals()){
    msg.textContent=hierarchyText('weightError','Each level must add up to 100%.');return;
  }
  if(button)button.disabled=true;
  try {
    msg.textContent=tr('common.saving',{defaultValue:'Saving…'});
    await api('/academic/categories/hierarchy','POST',{data:{performance_id:performanceId,nodes}},60000);
    closeModal();await refresh();window.academicTab='assessments';academics();
  } catch(error) {msg.textContent=friendlyAcademicError(error.message)}
  finally {if(button?.isConnected)button.disabled=false}
}
