import {readOrderPdf,PDF_LIMITS,groupOrderRows,validateOrderRow} from './pdf-orders.js';
const escape=value=>String(value??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const states=new Map();
const number=value=>Number(value||0).toLocaleString('pt-BR',{maximumFractionDigits:2});
import {rowKey as key,rowIssues,rowStatus,filterReviewRows,reviewSummary} from './pdf-review.js';
function askImport(title,message,input=false){
 return new Promise(resolve=>{
  const dialog=document.createElement('dialog');
  dialog.setAttribute('aria-label',title);
  dialog.innerHTML=`<form method="dialog"><h2>${escape(title)}</h2><p style="white-space:pre-line">${escape(message)}</p>${input?'<label class="field">Justificativa<input name="reason" required minlength="5" maxlength="1000"></label>':''}<div class="dialog-actions"><button value="cancel" formnovalidate>Voltar</button><button class="primary" value="confirm">Confirmar</button></div></form>`;
  dialog.addEventListener('close',()=>{const value=dialog.returnValue==='confirm'?(input?dialog.querySelector('[name="reason"]').value:'confirm'):null;dialog.remove();resolve(value);},{once:true});
  document.body.append(dialog);dialog.showModal();
 });
}
export function selectedOrderRows(rows){return rows.filter(r=>r.selected&&!r.excluded);}
export function importSelection(rows){
 const selected=selectedOrderRows(rows);
 if(!selected.length)throw Error('Selecione ao menos uma linha.');
 for(const row of selected){
  const errors=validateOrderRow(row);
  if(errors.length||row.conflict||row.duplicate_in_batch)throw Error('Corrija as pendências das linhas selecionadas.');
  if(!Number.isFinite(row.quantity)||row.quantity<=0||row.quantity>row.ordered-row.allocated||Math.abs(row.quantity*100-Math.round(row.quantity*100))>0.00001)throw Error('Quantidade inválida ou superior ao saldo.');
  if((row.warnings.length||['description','project','station'].some(k=>row[k]!==row.original[k]))&&row.reason.trim().length<5)throw Error('Justifique as correções e divergências antes de confirmar.');
 }
 return selected.map(r=>({file_id:r.file_id,index:r.index,quantity:r.quantity,description:r.description,project:r.project,station:r.station,reason:r.reason}));
}

export function mountPdfImports(root,context){
 const {api,userId,readOnly,admin,openDocument,toast}=context;
 let state=states.get(userId);
 if(!state){state={files:[],rows:[],batch:null,busy:false,progress:'',error:'',page:1,filters:{},sort:'order',result:null,history:null,historyPage:1,historyFilters:{}};states.set(userId,state);}
 const fail=error=>{state.error=error.message;paint();};
 state.pageSize ||= 25;state.view ||= 'all';state.step ||= 'review';
 const filtered=()=>filterReviewRows(state.rows,state.filters,state.sort);
 const input=(label,name,value='',type='text')=>`<label class="field">${label}<input name="${name}" type="${type}" value="${escape(value)}"></label>`;
 async function history(){
  const revision=(state.historyRevision||0)+1;state.historyRevision=revision;
  try{const result=await api.pdfImportHistory(state.historyFilters,state.historyPage);if(state.historyRevision===revision){state.history=result;paint();}}
  catch(error){if(state.historyRevision===revision)fail(error);}
 }
 async function original(id,page=1){
  try{
   const data=await api.pdfOrderFile(id),url=new URL(data.url);
   if(url.protocol!=='https:')throw Error('Endereço do PDF inválido.');
   url.hash='page='+page;
   const dialog=document.createElement('dialog');dialog.setAttribute('aria-label','PDF original');
   dialog.innerHTML=`<h2>PDF original</h2><p>Link privado válido por 60 segundos.</p><a href="${escape(url.href)}" target="_blank" rel="noopener noreferrer">Abrir PDF na página ${escape(page)}</a><form method="dialog"><button>Voltar</button></form>`;
   dialog.addEventListener('close',()=>dialog.remove(),{once:true});document.body.append(dialog);dialog.showModal();
  }catch(error){toast(error.message);}
 }
 function addFiles(list){
  if(state.busy)return;
  for(const file of list){
   if(state.files.length>=PDF_LIMITS.files){state.error='Limite de 25 arquivos por lote.';break;}
   if(state.files.some(f=>f.file===file))continue;
   state.files.push({file,name:file.name,status:'Aguardando',id:crypto.randomUUID()});
  }
  paint();
 }
 function applyPreview(preview){
   const previous=new Map(state.rows.map(r=>[key(r),r]));
   state.rows=preview.files.flatMap(f=>f.rows.map(row=>{
    const old=previous.get(key(row)),remaining=Math.max(0,row.ordered-row.allocated);
    return {...row,original:{...row},filename:f.name,selected:!row.errors.length&&!row.conflict&&remaining>0,quantity:remaining,reason:'',...old,allocated:row.allocated,conflict:row.conflict};
   }));
   const seen=new Set();
   for(const row of state.rows){const identity=[row.order,row.line,row.code].join('|');row.duplicate_in_batch=seen.has(identity);if(row.duplicate_in_batch)row.selected=false;seen.add(identity);}
   state.headers=preview.files.map(f=>({name:f.name,...f.header}));
   state.page=1;
 }
 async function resume(id){
  try{state.batch=id;state.result=null;state.error='';const preview=await api.previewPdfImport(id);state.files=preview.files.map(f=>({name:f.name,hash:f.hash,id:f.id,status:f.rows.length+' linhas validadas'}));applyPreview(preview);paint();}catch(error){fail(error);}
 }
 async function process(){
  if(state.busy)return;
  state.busy=true;state.error='';paint();
  try{
   state.batch ||= crypto.randomUUID();
   await api.beginPdfImport(state.batch);
   const hashes=new Set(state.files.filter(f=>f.hash).map(f=>f.hash));
   for(const file of state.files.filter(f=>!f.hash)){
    try{
     file.status='Lendo';paint();
     const parsed=await readOrderPdf(file.file,(page,total)=>{state.progress=file.name+' · página '+page+' de '+total;paint();});
     if(hashes.has(parsed.hash)){file.status='Arquivo duplicado neste lote';continue;}
     file.status='Validando e armazenando no servidor';paint();
     const stored=await api.stagePdfOrder(state.batch,file.file);
     file.id=stored.id;file.hash=stored.hash;hashes.add(stored.hash);file.status=stored.rows+' linhas · '+stored.pages+' páginas';
    }catch(error){file.status=error.message;}
   }
   applyPreview(await api.previewPdfImport(state.batch));
  }catch(error){state.error=error.message;}
  finally{state.busy=false;state.progress='';paint();}
 }
 async function confirm(){
  if(state.busy)return;
  try{
   if(state.step!=='summary')return;
   const selection=importSelection(state.rows),groups=groupOrderRows(selectedOrderRows(state.rows));
   const orders=new Set(selectedOrderRows(state.rows).map(r=>r.order));
   state.busy=true;paint();
   if(!await askImport('Confirmação final',`${orders.size} pedidos · ${selection.length} linhas · ${number(selection.reduce((n,r)=>n+r.quantity,0))} peças\n${groups.map(g=>g.project+' / '+g.station+' — '+g.rows.length+' linhas').join('\n')}\nConfirmar e gerar ${groups.length} separações pendentes?`))return;
   state.busy=true;state.error='';paint();
   state.result=await api.confirmPdfImport(state.batch,selection);
   await history();
  }catch(error){
   // Re-read the durable result after a lost HTTP response, preserving the batch ID.
   try{const saved=await api.previewPdfImport(state.batch);if(saved.state==='confirmed'){state.result=saved.result;return;}}catch{}
   state.error=error.message;
  }finally{state.busy=false;paint();}
 }
 async function cancel(id=state.batch){
  const reason=await askImport('Cancelar lote','Informe a justificativa do cancelamento. Somente separações pendentes podem liberar o saldo reservado.',true);
  if(!reason)return;
  try{await api.cancelPdfImport(id,reason);if(id===state.batch){state.rows=[];state.files=[];state.headers=[];state.batch=null;state.result=null;}await history();}catch(error){fail(error);}
 }
 function editRow(row){
  if(state.busy)return;
  const dialog=document.createElement('dialog');dialog.className='pdf-edit-dialog';dialog.setAttribute('aria-label','Detalhes e edição do item');
  dialog.innerHTML=`<form><h2>Detalhes do item</h2><p><strong>${escape(row.order)} · Seq. ${escape(row.sequence)} · L:${escape(row.line)} · ${escape(row.code)}</strong></p>
   <div class="fields">${input('Descrição','description',row.description)}${input('Projeto','project',row.project)}${input('Estação','station',row.station)}${input('Quantidade a importar','quantity',row.quantity,'number')}</div>
   <p>Solicitada: ${number(row.ordered)} · Anterior: ${number(row.allocated)} · Saldo: ${number(row.ordered-row.allocated)}</p>
   <label class="field">Justificativa de correção ou divergência<input name="reason" maxlength="1000" value="${escape(row.reason)}"></label>
   <details open><summary>Documentação de origem</summary><p>${escape(row.filename)} · Página ${escape(row.page)}<br>Desenho ${escape(row.drawing)} · Revisão ${escape(row.revision)} · Prazo ${escape(row.due)}</p><button type="button" id="pdf-edit-original">Ver PDF</button></details>
   <p class="error" role="alert" id="pdf-edit-error"></p><div class="dialog-actions"><button type="button" id="pdf-edit-cancel">Cancelar</button><button class="primary">Salvar alterações</button></div></form>`;
  const form=dialog.querySelector('form');
  for(const name of ['description','project','station'])form.elements[name].required=true;
  form.elements.description.maxLength=500;form.elements.project.maxLength=20;form.elements.station.maxLength=20;
  Object.assign(form.elements.quantity,{min:'0.01',max:String(row.ordered-row.allocated),step:'0.01',required:true});
  dialog.querySelector('#pdf-edit-original').onclick=()=>original(row.file_id,row.page);
  dialog.querySelector('#pdf-edit-cancel').onclick=()=>dialog.close();
  form.onsubmit=e=>{
   e.preventDefault();const values=Object.fromEntries(new FormData(form)),candidate={...row,...values,quantity:Number(values.quantity)};
   for(const k of ['description','project','station','reason'])candidate[k]=candidate[k].trim();
   const errors=rowIssues(candidate);
   // Conflicts in the original document require the existing administrative flow.
   if(errors.length){dialog.querySelector('#pdf-edit-error').textContent=errors.join(' · ');return;}
   Object.assign(row,{description:candidate.description,project:candidate.project,station:candidate.station,quantity:candidate.quantity,reason:candidate.reason});dialog.close();paint();
  };
  dialog.addEventListener('close',()=>dialog.remove(),{once:true});document.body.append(dialog);dialog.showModal();
 }
 const statusLabels={ready:'Pronto para conferência',pending:'Pendência',partial:'Importado parcialmente',complete:'Já importado integralmente'};
 function rowMarkup(r){
  const disabled=state.busy?'disabled':'',issues=rowIssues(r),status=rowStatus(r);
  return `<tr data-pdf-row="${escape(key(r))}"><td data-label="Selecionar"><input type="checkbox" data-edit="selected" ${r.selected?'checked':''} aria-label="Selecionar ${escape(r.code)} linha ${escape(r.line)}" ${disabled}></td>
   <td data-label="Pedido / Linha"><strong>${escape(r.order)}</strong><small>Seq. ${escape(r.sequence)} · L:${escape(r.line)}</small></td>
   <td data-label="Código / Descrição"><strong>${escape(r.code)}</strong><span class="pdf-description">${escape(r.description)}</span><small class="pdf-row-status ${issues.length?'error':''}">${escape(statusLabels[status])}${issues.length?': '+escape(issues.join(' · ')):''}${r.warnings.length?'<br>'+escape(r.warnings.join(' · ')):''}</small></td>
   <td data-label="Destino"><strong>Projeto ${escape(r.project)}</strong><small>Estação ${escape(r.station)}</small></td>
   <td data-label="Solicitada / Saldo"><span>Solicitada: ${number(r.ordered)}</span><small>Anterior: ${number(r.allocated)}</small><strong>Saldo: ${number(r.ordered-r.allocated)}</strong></td>
   <td data-label="Importar"><input data-edit="quantity" aria-label="Quantidade de ${escape(r.code)} linha ${escape(r.line)}" type="number" step="0.01" min="0.01" max="${r.ordered-r.allocated}" value="${escape(r.quantity)}" ${disabled} ${!Number.isFinite(r.quantity)||r.quantity<=0||r.quantity>r.ordered-r.allocated?'aria-invalid="true"':''}></td>
   <td data-label="Ações"><div class="pdf-row-actions"><button data-edit="details" ${disabled}>Editar</button><button data-pdf-file="${escape(r.file_id)}" data-page="${r.page}" title="${escape(r.filename)} · página ${r.page}">Ver PDF</button><button data-edit="exclude" class="danger" ${disabled}>Excluir</button>${admin&&r.conflict?`<button data-pdf-revision="${escape(r.file_id)}" data-index="${r.index}" ${disabled}>Revisar pedido</button>`:''}</div></td></tr>`;
 }
 function reviewMarkup(rows,pages,selected,groups){
  const option=(label,name,values)=>`<label class="field">${label}<select name="${name}"><option value="">Todos</option>${[...new Set(values)].sort((a,b)=>String(a).localeCompare(String(b),'pt-BR',{numeric:true})).map(v=>`<option value="${escape(v)}" ${state.filters[name]===v?'selected':''}>${escape(v)}</option>`).join('')}</select></label>`;
  const visible=rows.slice((state.page-1)*state.pageSize,state.page*state.pageSize),filteredGroups=groupOrderRows(rows);
  return `<h3>Conferência dos itens</h3><form id="pdf-filters" class="pdf-toolbar"><label class="field pdf-search">Pesquisa<input name="search" value="${escape(state.filters.search||'')}" placeholder="Buscar pedido, BPZ ou descrição..."></label>
   ${option('Projeto','project',state.rows.map(r=>r.project))}${option('Estação','station',state.rows.map(r=>r.station))}${option('Pedido','order',state.rows.map(r=>r.order))}
   <label class="field">Situação<select name="status"><option value="">Todas</option>${Object.entries(statusLabels).map(([v,l])=>`<option value="${v}" ${state.filters.status===v?'selected':''}>${l}</option>`).join('')}</select></label>
   <label class="field">Ordenar<select name="sort">${[['order','Pedido'],['code','BPZ'],['description','Descrição'],['project','Projeto'],['station','Estação'],['quantity','Quantidade']].map(([v,l])=>`<option value="${v}" ${state.sort===v?'selected':''}>${l}</option>`).join('')}</select></label>
   <div class="actions"><button ${state.busy?'disabled':''}>Pesquisar / ordenar</button><button type="button" id="pdf-clear" ${state.busy?'disabled':''}>Limpar filtros</button></div></form>
   <div class="actions pdf-selection"><button data-pdf-select="yes" ${state.busy?'disabled':''}>Selecionar resultados válidos</button><button data-pdf-select="no" ${state.busy?'disabled':''}>Desmarcar resultados</button><button id="pdf-only-selected" aria-pressed="${!!state.filters.selected}">${state.filters.selected?'Mostrar todos':'Visualizar selecionados'}</button></div>
   <p class="pdf-help">Seleção em massa abrange os ${rows.length} resultados filtrados, em todas as páginas. ${selected.length} linhas selecionadas no lote.</p>
   <div class="actions pdf-view"><button data-pdf-view="all" aria-pressed="${state.view==='all'}">Todos os itens</button><button data-pdf-view="groups" aria-pressed="${state.view==='groups'}">Agrupados por projeto/estação</button></div>
   ${state.view==='groups'?`<div class="pdf-groups">${filteredGroups.map(g=>{const chosen=g.rows.filter(r=>r.selected);return `<article><h3>Projeto ${escape(g.project)} · Estação ${escape(g.station)}</h3><p>${g.rows.length} linhas · ${number(g.qty)} peças · ${chosen.length} linhas selecionadas</p><div class="actions"><button data-pdf-group="${escape(g.project+'|'+g.station)}">Conferir itens</button><button data-pdf-group-select="yes" data-group="${escape(g.project+'|'+g.station)}" ${state.busy?'disabled':''}>Selecionar grupo</button><button data-pdf-group-select="no" data-group="${escape(g.project+'|'+g.station)}" ${state.busy?'disabled':''}>Desmarcar grupo</button></div></article>`;}).join('')||'<p>Nenhum grupo corresponde aos filtros.</p>'}</div>`:
   `<div class="pdf-review-table"><table><colgroup><col class="pdf-col-select"><col class="pdf-col-order"><col class="pdf-col-description"><col class="pdf-col-destination"><col class="pdf-col-balance"><col class="pdf-col-quantity"><col class="pdf-col-actions"></colgroup><thead><tr><th>Selecionar</th><th>Pedido / Linha</th><th>Código / Descrição</th><th>Destino</th><th>Solicitada / Saldo</th><th>Importar</th><th>Ações</th></tr></thead><tbody>${visible.map(rowMarkup).join('')||'<tr><td colspan="7">Nenhum item corresponde aos filtros.</td></tr>'}</tbody></table></div>
   <div class="actions pdf-pagination"><button id="pdf-prev" ${state.page<=1?'disabled':''}>Anterior</button><span>Página ${state.page} de ${pages} — Exibindo ${rows.length?(state.page-1)*state.pageSize+1:0} a ${Math.min(state.page*state.pageSize,rows.length)} de ${rows.length} itens${rows.length!==state.rows.filter(r=>!r.excluded).length?' filtrados':''}</span><button id="pdf-next" ${state.page>=pages?'disabled':''}>Próxima</button><label>Itens por página<select id="pdf-page-size">${[25,50,100].map(n=>`<option ${state.pageSize===n?'selected':''}>${n}</option>`).join('')}</select></label></div>`}
   <div class="actions pdf-review-next"><button class="primary" id="pdf-review" ${state.busy||!selected.length?'disabled':''}>Revisar separações</button><span>${groups.length} separações previstas</span></div>`;
 }
 function summaryMarkup(){
  const summary=reviewSummary(state.rows),selected=summary.selected;
  return `<section class="pdf-summary"><h3>Resumo e confirmação</h3><p>Confira os itens selecionados e os destinos antes de gerar as separações.</p>
   <div class="pdf-metrics">${[['PDFs selecionados',new Set(selected.map(r=>r.file_id)).size],['Pedidos',new Set(selected.map(r=>r.order)).size],['Linhas selecionadas',selected.length],['Peças selecionadas',summary.qty],['Projetos',new Set(selected.map(r=>r.project)).size],['Separações previstas',summary.groups.length],['Itens excluídos',summary.excluded],['Itens alterados',summary.changed],['Pendências selecionadas',summary.pending]].map(([l,v])=>`<p>${l}<strong>${number(v)}</strong></p>`).join('')}</div>
   ${summary.pending?'<p class="error" role="alert">Existem pendências impeditivas nos itens selecionados. Volte à conferência para corrigi-las.</p>':''}
   <div class="pdf-summary-table"><table><thead><tr><th>Projeto</th><th>Estação</th><th>Linhas selecionadas</th><th>Peças</th></tr></thead><tbody>${summary.groups.map(g=>`<tr><td>${escape(g.project)}</td><td>${escape(g.station)}</td><td>${g.rows.length}</td><td>${number(g.qty)}</td></tr>`).join('')}</tbody></table></div>
   ${summary.groups.map(g=>`<details><summary>Projeto ${escape(g.project)} · Estação ${escape(g.station)} · ${g.rows.length} linhas</summary><ul class="pdf-summary-items">${g.rows.map(r=>`<li><strong>${escape(r.order)} · L:${escape(r.line)} · ${escape(r.code)}</strong> — ${escape(r.description)} · ${number(r.quantity)} peças</li>`).join('')}</ul></details>`).join('')}
   <div class="actions pdf-review-next"><button id="pdf-back" ${state.busy?'disabled':''}>Voltar à conferência</button><button class="primary" id="pdf-confirm" ${state.busy||!selected.length||summary.pending?'disabled':''}>Confirmar e gerar separações</button></div></section>`;
 }

 function paint(){
  if(!root.isConnected){if(state.repaint&&state.repaint!==paint)state.repaint();return;}
  const rows=filtered(),pages=Math.max(1,Math.ceil(rows.length/state.pageSize));state.page=Math.min(state.page,pages);
  const selected=selectedOrderRows(state.rows),groups=groupOrderRows(selected),selectedQty=selected.reduce((n,r)=>n+Number(r.quantity||0),0);
  const metrics=[['PDFs processados',state.files.filter(f=>f.hash).length],['Pedidos',new Set(state.rows.map(r=>r.order)).size],['Linhas',state.rows.length],['Peças solicitadas',state.rows.reduce((n,r)=>n+Number(r.ordered||0),0)],['Projetos',new Set(selected.map(r=>r.project)).size],['Separações previstas',groups.length],['Pendências',state.rows.filter(r=>!r.excluded&&rowStatus(r)==='pending').length],['Já importadas',state.rows.filter(r=>r.allocated>0).length],['Selecionadas',selected.length],['Peças selecionadas',selectedQty]];
  const result=state.result;
  root.innerHTML=`<section class="card pdf-import"><div class="card-head"><h2>${readOnly?'Histórico de importações PDF':'Importar pedidos PDF'}</h2></div><div class="card-body">
   ${state.headers?.length?'<details><summary>Cabeçalhos dos pedidos</summary>'+state.headers.map(h=>`<p>${escape(h.name)} · Pedido ${escape(h.order)} · ${escape(h.date)} · Fornecedor ${escape(h.supplier)} · Comprador ${escape(h.buyer)} · Projeto de cabeçalho ${escape(h.header_project||'não informado')}</p>`).join('')+'</details>':''}${state.error?`<p class="error" role="alert">${escape(state.error)}</p>`:''}
   ${!readOnly&&!result&&state.step!=='summary'?`<details class="pdf-files-panel" ${state.rows.length?'':'open'}><summary>Arquivos importados (${state.files.filter(f=>f.hash).length}) · ${new Set(state.rows.map(r=>r.order)).size} pedidos · ${state.rows.length} linhas</summary><div id="pdf-drop" class="pdf-drop"><label class="field">Selecionar pedidos PDF<input id="pdf-files" type="file" accept="application/pdf,.pdf" multiple ${state.busy?'disabled':''}></label><p>Arraste os arquivos aqui · Até 25 PDFs, 20 MB e 200 páginas por arquivo.</p></div>
   <ul>${state.files.map(f=>`<li>${escape(f.name)} — ${escape(f.status)} ${!state.busy&&!f.hash?`<button data-pdf-remove="${f.id}">Remover</button>`:''}${f.hash?`<button data-pdf-file="${f.id}">Ver PDF</button>`:''}</li>`).join('')}</ul></details>
   <p role="status">${escape(state.progress)}</p>${state.busy?'<progress aria-label="Processamento em andamento"></progress>':''}
   <div class="actions pdf-process-actions"><button id="pdf-process" ${state.busy||!state.files.length?'disabled':''}>Ler arquivos e conferir</button>${state.batch?`<button id="pdf-cancel" ${state.busy?'disabled':''}>Cancelar lote</button>`:''}</div>`:''}
   ${result?`<h3>Importação realizada · Lote ${escape(state.batch)}</h3><p>${result.length} separações pendentes de início</p>${result.map(d=>`<p><button data-pdf-open="${escape(d.id)}">Separação #${escape(d.number)}</button> · ${escape(d.project)} / ${escape(d.station)} · ${d.items} linhas</p>`).join('')}<button id="pdf-new">Nova importação</button>`:''}
   ${state.rows.length&&!result&&!readOnly?`${state.step==='review'?`<div class="pdf-metrics">${metrics.map(([label,value])=>`<p>${label}<strong>${number(value)}</strong></p>`).join('')}</div>`:''}
    ${state.step==='summary'?summaryMarkup():reviewMarkup(rows,pages,selected,groups)}`:''}
   </div></section><section class="card"><div class="card-head"><h2>Histórico de importações</h2></div><div class="card-body"><form id="pdf-history-filters"><div class="fields">${[['Pedido','order'],['Usuário','user'],['Projeto','project'],['Estação','station'],['Estado (review, confirmed, cancelled)','status'],['Desde','from','date'],['Até','to','date']].map(([l,k,t])=>input(l,k,state.historyFilters[k],t)).join('')}</div><button>Pesquisar histórico</button></form>
   ${admin?'<label class="pdf-archive-toggle"><input id="pdf-show-archived" type="checkbox" '+(state.historyFilters.archived?'checked':'')+'> Incluir testes arquivados</label>':''}${(state.history?.rows||[]).map(b=>`<article class="list-item"><div><strong>Lote ${escape(b.id)}</strong><p>${escape(b.full_name)} · ${new Date(b.created_at).toLocaleString('pt-BR')} · ${escape(b.state)}${b.archived_at?' · Teste arquivado':''}</p>${(b.files||[]).map(f=>`<button data-pdf-file="${f.id}">${escape(f.order)} · ${escape(f.name)}</button>`).join('')}${(b.result||[]).map(d=>`<p><button data-pdf-open="${d.id}">#${d.number} · ${escape(d.project)} / ${escape(d.station)} · ${d.items} linhas</button></p>`).join('')}</div>${!readOnly&&b.state==='review'&&b.actor_id===userId?`<button data-pdf-resume="${b.id}">Retomar conferência</button>`:''}<button data-pdf-details="${b.id}">Detalhes e auditoria</button>${!readOnly&&b.state!=='cancelled'?`<button data-pdf-cancel="${b.id}">Cancelar lote</button>`:''}</article>`).join('')||'<p>Nenhuma importação encontrada.</p>'}
   <div class="actions"><button id="pdf-history-prev" ${state.historyPage<=1?'disabled':''}>Anterior</button><span>${state.history?.total??0} lotes · Página ${state.historyPage}</span><button id="pdf-history-next" ${state.historyPage*20>=(state.history?.total??0)?'disabled':''}>Próxima</button></div></div></section>`;
  root.querySelector('#pdf-files')?.addEventListener('change',e=>addFiles(e.target.files));
  const drop=root.querySelector('#pdf-drop');
  if(drop){drop.ondragover=e=>e.preventDefault();drop.ondrop=e=>{e.preventDefault();addFiles(e.dataTransfer.files);};}
  root.querySelector('#pdf-process')?.addEventListener('click',process);
  root.querySelector('#pdf-confirm')?.addEventListener('click',confirm);
  root.querySelector('#pdf-cancel')?.addEventListener('click',()=>cancel());
  root.querySelector('#pdf-new')?.addEventListener('click',()=>{state.files=[];state.rows=[];state.headers=[];state.filters={};state.page=1;state.error='';state.batch=null;state.result=null;state.step='review';paint();});
  for(const b of root.querySelectorAll('[data-pdf-remove]'))b.onclick=()=>{state.files=state.files.filter(f=>f.id!==b.dataset.pdfRemove);paint();};
  for(const b of root.querySelectorAll('[data-pdf-file]'))b.onclick=()=>original(b.dataset.pdfFile,b.dataset.page||1);
  for(const b of root.querySelectorAll('[data-pdf-open]'))b.onclick=async()=>{try{await openDocument(b.dataset.pdfOpen);}catch(error){toast(error.message);}};
  for(const b of root.querySelectorAll('[data-pdf-resume]'))b.onclick=()=>resume(b.dataset.pdfResume);
  for(const b of root.querySelectorAll('[data-pdf-details]'))b.onclick=async()=>{try{const data=await api.pdfImportDetails(b.dataset.pdfDetails);const pre=document.createElement('pre');pre.className='pdf-audit';pre.textContent=JSON.stringify(data,null,2);b.parentElement.append(pre);b.disabled=true;}catch(error){toast(error.message);}};
  for(const b of root.querySelectorAll('[data-pdf-revision]'))b.onclick=async()=>{const reason=await askImport('Revisão administrativa','Confirme a revisão do documento original e justifique a alteração de quantidade ou destino.',true);if(!reason)return;try{await api.reviewPdfOrderLine(b.dataset.pdfRevision,Number(b.dataset.index),reason);await process();}catch(error){fail(error);}};
  for(const b of root.querySelectorAll('[data-pdf-cancel]'))b.onclick=()=>cancel(b.dataset.pdfCancel);
  for(const el of root.querySelectorAll('[data-edit]')){
   const run=async()=>{
    if(state.busy)return;
    const row=state.rows.find(r=>key(r)===el.closest('[data-pdf-row]').dataset.pdfRow),field=el.dataset.edit;
    if(field==='details'){editRow(row);return;}
    if(field==='exclude'){
     if(!await askImport('Excluir da prévia',row.order+' · L:'+row.line+' · '+row.code+' será removido somente desta prévia. Continuar?'))return;
     row.excluded=true;
    }else row[field]=field==='selected'?el.checked:Number(el.value);
    paint();
   };
   if(el.tagName==='BUTTON')el.onclick=run;else el.onchange=run;
  }
  const selectResults=(value,group=null)=>{
   if(state.busy)return;
   for(const row of filtered())if(!group||row.project+'|'+row.station===group)row.selected=value&&!rowIssues(row).length;
   paint();
  };
  for(const b of root.querySelectorAll('[data-pdf-select]'))b.onclick=()=>selectResults(b.dataset.pdfSelect==='yes');
  for(const b of root.querySelectorAll('[data-pdf-group-select]'))b.onclick=()=>selectResults(b.dataset.pdfGroupSelect==='yes',b.dataset.group);
  for(const b of root.querySelectorAll('[data-pdf-group]'))b.onclick=()=>{const [project,station]=b.dataset.pdfGroup.split('|');state.filters={...state.filters,project,station};state.view='all';state.page=1;paint();};
  for(const b of root.querySelectorAll('[data-pdf-view]'))b.onclick=()=>{state.view=b.dataset.pdfView;paint();};
  root.querySelector('#pdf-only-selected')?.addEventListener('click',()=>{state.filters.selected=!state.filters.selected;state.page=1;paint();});
  const filters=root.querySelector('#pdf-filters');if(filters)filters.onsubmit=e=>{e.preventDefault();if(state.busy)return;const values=Object.fromEntries(new FormData(filters));state.sort=values.sort;delete values.sort;state.filters={...values,selected:state.filters.selected};state.page=1;paint();};
  root.querySelector('#pdf-clear')?.addEventListener('click',()=>{state.filters={};state.page=1;paint();});
  root.querySelector('#pdf-page-size')?.addEventListener('change',e=>{state.pageSize=Number(e.target.value);state.page=1;paint();});
  root.querySelector('#pdf-review')?.addEventListener('click',()=>{state.error='';state.step='summary';paint();root.querySelector('.pdf-summary h3')?.scrollIntoView({block:'start',behavior:'smooth'});});
  root.querySelector('#pdf-back')?.addEventListener('click',()=>{state.step='review';paint();});
  root.querySelector('#pdf-prev')?.addEventListener('click',()=>{state.page--;paint();});root.querySelector('#pdf-next')?.addEventListener('click',()=>{state.page++;paint();});
  root.querySelector('#pdf-show-archived')?.addEventListener('change',e=>{state.historyFilters.archived=e.target.checked;state.historyPage=1;history();});
  root.querySelector('#pdf-history-filters').onsubmit=e=>{e.preventDefault();state.historyFilters={...Object.fromEntries(new FormData(e.target)),archived:state.historyFilters.archived};state.historyPage=1;history();};
  root.querySelector('#pdf-history-prev').onclick=()=>{state.historyPage--;history();};root.querySelector('#pdf-history-next').onclick=()=>{state.historyPage++;history();};
 }
 state.repaint=paint;paint();void history();
}
