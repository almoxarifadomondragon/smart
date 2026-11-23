import {readOrderPdf,PDF_LIMITS,groupOrderRows,validateOrderRow} from './pdf-orders.js';
const escape=value=>String(value??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const states=new Map();
const number=value=>Number(value||0).toLocaleString('pt-BR',{maximumFractionDigits:2});
const key=row=>row.file_id+':'+row.index;
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
 const filtered=()=>state.rows.filter(r=>!r.excluded&&['order','code','description','project','station'].every(k=>!state.filters[k]||String(r[k]).toLocaleLowerCase('pt-BR').includes(state.filters[k].toLocaleLowerCase('pt-BR')))).sort((a,b)=>String(a[state.sort]).localeCompare(String(b[state.sort]),'pt-BR',{numeric:true})||a.index-b.index);
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
     file.hash=stored.hash;hashes.add(stored.hash);file.status=stored.rows+' linhas · '+stored.pages+' páginas';
    }catch(error){file.status=error.message;}
   }
   applyPreview(await api.previewPdfImport(state.batch));
  }catch(error){state.error=error.message;}
  finally{state.busy=false;state.progress='';paint();}
 }
 async function confirm(){
  if(state.busy)return;
  try{
   const selection=importSelection(state.rows),groups=groupOrderRows(selectedOrderRows(state.rows));
   const orders=new Set(selectedOrderRows(state.rows).map(r=>r.order));
   if(!await askImport('Conferir importação',`${orders.size} pedidos · ${selection.length} linhas · ${number(selection.reduce((n,r)=>n+r.quantity,0))} peças\n${groups.map(g=>g.project+' / '+g.station+' — '+g.rows.length+' linhas').join('\n')}\nConfirmar e gerar ${groups.length} separações pendentes?`))return;
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
 function paint(){
  if(!root.isConnected){if(state.repaint&&state.repaint!==paint)state.repaint();return;}
  const rows=filtered(),pages=Math.max(1,Math.ceil(rows.length/50));state.page=Math.min(state.page,pages);
  const selected=selectedOrderRows(state.rows),groups=groupOrderRows(selected),selectedQty=selected.reduce((n,r)=>n+Number(r.quantity||0),0);
  const metrics=[['PDFs processados',state.files.filter(f=>f.hash).length],['Pedidos',new Set(state.rows.map(r=>r.order)).size],['Linhas',state.rows.length],['Peças solicitadas',state.rows.reduce((n,r)=>n+Number(r.ordered||0),0)],['Projetos',new Set(selected.map(r=>r.project)).size],['Estações',new Set(selected.map(r=>r.project+'|'+r.station)).size],['Separações previstas',groups.length],['Pendências',state.rows.filter(r=>validateOrderRow(r).length||r.conflict||r.warnings.length).length],['Já importadas',state.rows.filter(r=>r.allocated>0).length],['Selecionadas',selected.length],['Peças selecionadas',selectedQty]];
  const result=state.result;
  root.innerHTML=`<section class="card pdf-import"><div class="card-head"><h2>${readOnly?'Histórico de importações PDF':'Importar pedidos PDF'}</h2></div><div class="card-body">
   ${state.headers?.length?'<details><summary>Cabeçalhos dos pedidos</summary>'+state.headers.map(h=>`<p>${escape(h.name)} · Pedido ${escape(h.order)} · ${escape(h.date)} · Fornecedor ${escape(h.supplier)} · Comprador ${escape(h.buyer)} · Projeto de cabeçalho ${escape(h.header_project||'não informado')}</p>`).join('')+'</details>':''}${state.error?`<p class="error" role="alert">${escape(state.error)}</p>`:''}
   ${!readOnly&&!result?`<div id="pdf-drop" class="pdf-drop"><label class="field">Selecionar pedidos PDF<input id="pdf-files" type="file" accept="application/pdf,.pdf" multiple ${state.busy?'disabled':''}></label><p>Arraste os arquivos aqui · Até 25 PDFs, 20 MB e 200 páginas por arquivo.</p></div>
   <ul>${state.files.map(f=>`<li>${escape(f.name)} — ${escape(f.status)} ${!state.busy&&!f.hash?`<button data-pdf-remove="${f.id}">Remover</button>`:''}</li>`).join('')}</ul>
   <p role="status">${escape(state.progress)}</p>${state.busy?'<progress aria-label="Processamento em andamento"></progress>':''}
   <div class="actions"><button id="pdf-process" ${state.busy||!state.files.length?'disabled':''}>Ler arquivos e conferir</button>${state.batch?`<button id="pdf-cancel" ${state.busy?'disabled':''}>Cancelar lote</button>`:''}</div>`:''}
   ${result?`<h3>Importação realizada · Lote ${escape(state.batch)}</h3><p>${result.length} separações pendentes de início</p>${result.map(d=>`<p><button data-pdf-open="${escape(d.id)}">Separação #${escape(d.number)}</button> · ${escape(d.project)} / ${escape(d.station)} · ${d.items} linhas</p>`).join('')}<button id="pdf-new">Nova importação</button>`:''}
   ${state.rows.length&&!result&&!readOnly?`<div class="pdf-metrics">${metrics.map(([label,value])=>`<p>${label}<strong>${number(value)}</strong></p>`).join('')}</div>
    <form id="pdf-filters"><div class="fields">${[['Pedido','order'],['BPZ','code'],['Descrição','description'],['Projeto','project'],['Estação','station']].map(([label,k])=>input(label,k,state.filters[k])).join('')}<label class="field">Ordenar<select name="sort">${[['order','Pedido'],['code','BPZ'],['description','Descrição'],['project','Projeto'],['station','Estação'],['quantity','Quantidade']].map(([v,l])=>`<option value="${v}" ${state.sort===v?'selected':''}>${l}</option>`).join('')}</select></label></div><button>Pesquisar / ordenar</button><button type="button" id="pdf-clear">Limpar filtros</button></form>
    <div class="actions"><button data-pdf-select="yes" ${state.busy?'disabled':''}>Selecionar resultados válidos</button><button data-pdf-select="no" ${state.busy?'disabled':''}>Desmarcar resultados</button></div>
    <div class="table-wrap"><table><thead><tr><th>Selecionar</th><th>Pedido / sequencial / L:</th><th>BPZ / Descrição</th><th>Projeto</th><th>Estação</th><th>Solicitada</th><th>Anterior</th><th>Saldo</th><th>Importar</th><th>Situação / justificativa</th><th>Origem</th></tr></thead><tbody>${rows.slice((state.page-1)*50,state.page*50).map(r=>`<tr data-pdf-row="${escape(key(r))}"><td><input type="checkbox" data-edit="selected" ${r.selected?'checked':''} aria-label="Selecionar ${r.code} linha ${r.line}" ${state.busy?'disabled':''}><button data-edit="exclude" ${state.busy?'disabled':''}>Excluir da prévia</button></td><td>${escape(r.order)}<br>Seq. ${escape(r.sequence)} · L:${escape(r.line)}</td><td>${escape(r.code)}<input data-edit="description" aria-label="Descrição de ${r.code}" maxlength="500" value="${escape(r.description)}" ${state.busy?'disabled':''}></td><td><input data-edit="project" aria-label="Projeto de ${r.code}" value="${escape(r.project)}" maxlength="20" ${state.busy?'disabled':''}></td><td><input data-edit="station" aria-label="Estação de ${r.code}" value="${escape(r.station)}" maxlength="20" ${state.busy?'disabled':''}></td><td>${number(r.ordered)}</td><td>${number(r.allocated)}</td><td>${number(r.ordered-r.allocated)}</td><td><input data-edit="quantity" aria-label="Quantidade de ${r.code}" type="number" step="0.01" min="0.01" max="${r.ordered-r.allocated}" value="${r.quantity}" ${state.busy?'disabled':''}></td><td>${escape([...validateOrderRow(r),...r.warnings,...(r.duplicate_in_batch?['Linha repetida em outro PDF do lote']:[]),...(r.conflict?['Pedido alterado; revisão administrativa necessária']:[])].join(' · ')||(r.allocated>=r.ordered?'Já importado integralmente':r.allocated?'Importado parcialmente':'Pronto para conferência'))}<input data-edit="reason" aria-label="Justificativa de ${r.code}" maxlength="1000" value="${escape(r.reason)}" placeholder="Justificativa de correção/divergência" ${state.busy?'disabled':''}></td><td><button data-pdf-file="${r.file_id}" data-page="${r.page}">PDF · p. ${r.page}</button><small>${admin&&r.conflict?`<button data-pdf-revision="${r.file_id}" data-index="${r.index}">Revisar alteração do pedido</button>`:''}${escape(r.filename)}<br>${escape(r.drawing)} · Rev. ${escape(r.revision)} · ${escape(r.due)}</small></td></tr>`).join('')}</tbody></table></div>
    <div class="actions"><button id="pdf-prev" ${state.page<=1?'disabled':''}>Anterior</button><span>Página ${state.page} de ${pages} · ${rows.length} linhas</span><button id="pdf-next" ${state.page>=pages?'disabled':''}>Próxima</button><button class="primary" id="pdf-confirm" ${state.busy||!selected.length?'disabled':''}>Confirmar e gerar separações</button></div>`:''}
   </div></section><section class="card"><div class="card-head"><h2>Histórico de importações</h2></div><div class="card-body"><form id="pdf-history-filters"><div class="fields">${[['Pedido','order'],['Usuário','user'],['Projeto','project'],['Estação','station'],['Estado (review, confirmed, cancelled)','status'],['Desde','from','date'],['Até','to','date']].map(([l,k,t])=>input(l,k,state.historyFilters[k],t)).join('')}</div><button>Pesquisar histórico</button></form>
   ${(state.history?.rows||[]).map(b=>`<article class="list-item"><div><strong>Lote ${escape(b.id)}</strong><p>${escape(b.full_name)} · ${new Date(b.created_at).toLocaleString('pt-BR')} · ${escape(b.state)}</p>${(b.files||[]).map(f=>`<button data-pdf-file="${f.id}">${escape(f.order)} · ${escape(f.name)}</button>`).join('')}${(b.result||[]).map(d=>`<p><button data-pdf-open="${d.id}">#${d.number} · ${escape(d.project)} / ${escape(d.station)} · ${d.items} linhas</button></p>`).join('')}</div>${!readOnly&&b.state==='review'&&b.actor_id===userId?`<button data-pdf-resume="${b.id}">Retomar conferência</button>`:''}<button data-pdf-details="${b.id}">Detalhes e auditoria</button>${!readOnly&&b.state!=='cancelled'?`<button data-pdf-cancel="${b.id}">Cancelar lote</button>`:''}</article>`).join('')||'<p>Nenhuma importação encontrada.</p>'}
   <div class="actions"><button id="pdf-history-prev" ${state.historyPage<=1?'disabled':''}>Anterior</button><span>${state.history?.total??0} lotes · Página ${state.historyPage}</span><button id="pdf-history-next" ${state.historyPage*20>=(state.history?.total??0)?'disabled':''}>Próxima</button></div></div></section>`;
  root.querySelector('#pdf-files')?.addEventListener('change',e=>addFiles(e.target.files));
  const drop=root.querySelector('#pdf-drop');
  if(drop){drop.ondragover=e=>e.preventDefault();drop.ondrop=e=>{e.preventDefault();addFiles(e.dataTransfer.files);};}
  root.querySelector('#pdf-process')?.addEventListener('click',process);
  root.querySelector('#pdf-confirm')?.addEventListener('click',confirm);
  root.querySelector('#pdf-cancel')?.addEventListener('click',()=>cancel());
  root.querySelector('#pdf-new')?.addEventListener('click',()=>{state.files=[];state.rows=[];state.headers=[];state.filters={};state.page=1;state.error='';state.batch=null;state.result=null;paint();});
  for(const b of root.querySelectorAll('[data-pdf-remove]'))b.onclick=()=>{state.files=state.files.filter(f=>f.id!==b.dataset.pdfRemove);paint();};
  for(const b of root.querySelectorAll('[data-pdf-file]'))b.onclick=()=>original(b.dataset.pdfFile,b.dataset.page||1);
  for(const b of root.querySelectorAll('[data-pdf-open]'))b.onclick=async()=>{try{await openDocument(b.dataset.pdfOpen);}catch(error){toast(error.message);}};
  for(const b of root.querySelectorAll('[data-pdf-resume]'))b.onclick=()=>resume(b.dataset.pdfResume);
  for(const b of root.querySelectorAll('[data-pdf-details]'))b.onclick=async()=>{try{const data=await api.pdfImportDetails(b.dataset.pdfDetails);const pre=document.createElement('pre');pre.className='pdf-audit';pre.textContent=JSON.stringify(data,null,2);b.parentElement.append(pre);b.disabled=true;}catch(error){toast(error.message);}};
  for(const b of root.querySelectorAll('[data-pdf-revision]'))b.onclick=async()=>{const reason=await askImport('Revisão administrativa','Confirme a revisão do documento original e justifique a alteração de quantidade ou destino.',true);if(!reason)return;try{await api.reviewPdfOrderLine(b.dataset.pdfRevision,Number(b.dataset.index),reason);await process();}catch(error){fail(error);}};
  for(const b of root.querySelectorAll('[data-pdf-cancel]'))b.onclick=()=>cancel(b.dataset.pdfCancel);
  for(const el of root.querySelectorAll('[data-edit]'))el.onchange=()=>{
   if(state.busy)return;
   const row=state.rows.find(r=>key(r)===el.closest('tr').dataset.pdfRow),field=el.dataset.edit;
   if(field==='exclude')row.excluded=true;else row[field]=field==='selected'?el.checked:field==='quantity'?Number(el.value):el.value;
   paint();
  };
  for(const el of root.querySelectorAll('[data-edit="exclude"]'))el.onclick=el.onchange;
  for(const b of root.querySelectorAll('[data-pdf-select]'))b.onclick=()=>{for(const row of filtered())row.selected=b.dataset.pdfSelect==='yes'&&!validateOrderRow(row).length&&!row.conflict&&!row.duplicate_in_batch&&row.ordered>row.allocated;paint();};
  const filters=root.querySelector('#pdf-filters');if(filters)filters.onsubmit=e=>{e.preventDefault();const values=Object.fromEntries(new FormData(filters));state.sort=values.sort;delete values.sort;state.filters=values;state.page=1;paint();};
  root.querySelector('#pdf-clear')?.addEventListener('click',()=>{state.filters={};state.page=1;paint();});
  root.querySelector('#pdf-prev')?.addEventListener('click',()=>{state.page--;paint();});root.querySelector('#pdf-next')?.addEventListener('click',()=>{state.page++;paint();});
  root.querySelector('#pdf-history-filters').onsubmit=e=>{e.preventDefault();state.historyFilters=Object.fromEntries(new FormData(e.target));state.historyPage=1;history();};
  root.querySelector('#pdf-history-prev').onclick=()=>{state.historyPage--;history();};root.querySelector('#pdf-history-next').onclick=()=>{state.historyPage++;history();};
 }
 state.repaint=paint;paint();void history();
}
