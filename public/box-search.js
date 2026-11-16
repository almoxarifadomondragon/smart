import {formatQty, totalQty} from './domain.js';
import {PAGE_SIZE, saoPauloDate, searchParameters} from './history.js';
import {demoPhysicalContents, deliveryEmailLabel} from './warehouse.js';

const statuses = {available:'Disponível',in_use:'Em utilização',closed:'Fechada / Entregue'};
const order = {in_use:1,available:2,closed:3};
const empty = () => ({code:'',name:'',project:'',station:'',bma:'',number:'',status:'',closer:'',period:'all',dateType:'created',from:'',to:''});
const escape = value => String(value ?? '').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const dateText = value => new Date(value).toLocaleString('pt-BR',{timeZone:'America/Sao_Paulo',dateStyle:'short',timeStyle:'short'});
const periods = [['all','Todo o período'],['today','Hoje'],['week','Esta semana'],['month','Este mês'],['year','Este ano'],['custom','Personalizado']];

export function boxSearchParameters(filters,page=1,now=new Date()){
 const {p_number,p_scope,...shared}=searchParameters(filters,page,now);
 return {...shared,p_document_number:p_number,p_code:filters.code.trim()||null,p_name:filters.name.trim()||null,
  p_status:filters.status||null,p_closed_by:filters.closer.trim()||null,p_date_type:filters.dateType};
}

export function searchDemoBoxes(boxes,docs,p){
 const rows=[];
 const contains=(value,term)=>!term||String(value??'').toLowerCase().includes(term.toLowerCase());
 for(const box of boxes){
  const delivery=box.delivery;
  const date=p.p_date_type==='closed'?delivery?.closed_at:box.created_at;
  if(!contains(box.code,p.p_code)||!contains(box.name,p.p_name)||!contains(delivery?.closed_by_name,p.p_closed_by)
   ||(p.p_project&&p.p_project!==box.project)||(p.p_station&&p.p_station!==box.station)||(p.p_status&&p.p_status!==box.status)
   ||(p.p_from&&(!date||saoPauloDate(date)<p.p_from))||(p.p_to&&(!date||saoPauloDate(date)>p.p_to)))continue;
  const {documents,items}=demoPhysicalContents(box,docs);
  if((p.p_document_number||p.p_bma)&&!documents.some(doc=>
   (!p.p_document_number||String(doc.number)===p.p_document_number)
   &&(!p.p_bma||items.some(item=>item.document_id===doc.id&&item.code.toUpperCase()===p.p_bma))))continue;
  rows.push({id:box.id,code:box.code,name:box.name,project:box.project,station:box.station,
   status:box.status,created_at:box.created_at,closed_at:delivery?.closed_at,
   closed_by_name:delivery?.closed_by_name,email_state:delivery?.email_state,
   document_count:documents.length,item_count:items.length,total_units:totalQty(items)});
 }
 rows.sort((a,b)=>order[a.status]-order[b.status]
  ||Date.parse(b.closed_at||b.created_at)-Date.parse(a.closed_at||a.created_at)||a.code.localeCompare(b.code));
 const indicators={total:rows.length,available:0,in_use:0,closed:0,pending:0,sending:0};
 for(const row of rows){
  indicators[row.status]++;
  if(row.status==='closed'&&['pending','failed','uncertain'].includes(row.email_state))indicators.pending++;
  if(row.status==='closed'&&row.email_state==='sending')indicators.sending++;
 }
 const page=Math.min(p.p_page,Math.max(1,Math.ceil(rows.length/PAGE_SIZE)));
 return {rows:rows.slice((page-1)*PAGE_SIZE,page*PAGE_SIZE),total:rows.length,page,page_size:PAGE_SIZE,indicators};
}

export class BoxSearch {
 constructor(){this.revision=0;this.reset();}
 reset(){
  this.revision++;
  this.filters=empty();this.applied=empty();this.page=1;this.result=null;this.loading=false;this.error='';
 }
 async load(query,changed=()=>{}){
  const revision=++this.revision;
  this.loading=true;this.error='';this.result=null;changed();
  let parameters;
  try{
   parameters=boxSearchParameters(this.applied,this.page);
   const result=await query(parameters);
   if(revision===this.revision){this.result=result;this.page=result.page;}
  }catch(error){
   if(revision===this.revision)this.error=!parameters?error.message:
    error.code==='42501'||[401,403].includes(error.status)?'Sua sessão não tem autorização para consultar caixas físicas.':'Não foi possível consultar as caixas físicas. Confira a conexão e tente novamente.';
  }finally{
   if(revision===this.revision){this.loading=false;changed();}
  }
 }
}

function boxRow(box){
 const closure=box.status==='closed'?(box.closed_at?
  '<p>Entrega: '+escape(dateText(box.closed_at))+' · '+escape(box.closed_by_name)+'</p>'+
  (box.email_state?'<p>E-mail: '+escape(deliveryEmailLabel(box.email_state))+'</p>':''):
  '<p>Fechamento histórico sem comprovante. Data de entrega não registrada.</p>'):'';
 return `<div class="list-item box-search-row"><div><strong>${escape(box.code)} · ${escape(box.name)}</strong>
  <p>Projeto ${escape(box.project)} · Estação ${escape(box.station)}</p>
  <p>${box.document_count} romaneio(s) · ${box.item_count} registros BMA · ${formatQty(box.total_units)} unidades</p>
  <p>Criação: ${escape(dateText(box.created_at))}</p>${closure}</div>
  <div class="actions"><span class="badge ${box.status==='closed'?'green':'gray'}">${statuses[box.status]}</span>
  <button type="button" data-action="physical-view" data-id="${escape(box.id)}">Consultar caixa →</button></div></div>`;
}

export function boxSearchView(state){
 const {filters:f,result:r}=state;
 const pages=Math.max(1,Math.ceil((r?.total||0)/PAGE_SIZE));
 const input=(label,key,extra='')=>`<label class="field">${label}<input name="${key}" value="${escape(f[key])}" ${extra}></label>`;
 const select=(label,key,options)=>`<label class="field">${label}<select name="${key}">${options.map(([v,t])=>
  `<option value="${v}" ${v===f[key]?'selected':''}>${t}</option>`).join('')}</select></label>`;
 const stats=[['total','Total de caixas físicas'],['available','Disponíveis'],['in_use','Em utilização'],
  ['closed','Fechadas / Entregues'],['pending','Notificações pendentes']];
 return `<section class="stats box-search-stats" aria-label="Indicadores das caixas filtradas">${stats.map(([key,label])=>
  `<div class="stat"><label>${label}</label><strong>${r?Number(r.indicators[key]).toLocaleString('pt-BR'):'—'}</strong>
  ${key==='pending'&&r?`<small>${r.indicators.sending} em envio</small>`:''}</div>`).join('')}</section>
 <section class="card" id="box-search"><div class="card-head"><h2>Pesquisar caixas físicas</h2>
 <span class="badge gray" aria-live="polite">${state.loading?'Consultando…':r?`${r.total} resultados`:'Pesquisa'}</span></div>
 <form id="box-search-filters" class="card-body"><div class="history-fields">
 ${input('Código da caixa','code','maxlength="60" placeholder="CX-000015"')}
 ${input('Nome da caixa','name','maxlength="60"')}
 ${input('Projeto','project','maxlength="120"')}${input('Estação','station','maxlength="120"')}
 ${input('BMA','bma','maxlength="10" placeholder="BMA0013539"')}
 ${input('Número do romaneio','number','maxlength="30" inputmode="numeric"')}
 ${select('Status','status',[['','Todas'],...Object.entries(statuses)])}
 ${input('Responsável pelo fechamento','closer','maxlength="120"')}
 ${select('Período','period',periods)}
 ${select('Referência do período','dateType',[['created','Data de criação'],['closed','Data de fechamento/entrega']])}</div>
 <div class="fields" id="box-search-dates" ${f.period==='custom'?'':'hidden'}>
 ${input('Data inicial','from','type="date"')}${input('Data final','to','type="date"')}</div>
 <div class="actions"><button class="primary" type="submit">Pesquisar</button>
 <button type="button" data-box-search="clear">Limpar filtros</button><small>Fuso de São Paulo</small></div></form>
 <div aria-live="polite" aria-busy="${state.loading}">${state.loading?'<div class="empty" role="status">Consultando caixas…</div>':
  state.error?`<div class="notice error" role="alert">${escape(state.error)} <button type="button" data-box-search="retry">Tentar novamente</button></div>`:
  r?.rows.length?r.rows.map(boxRow).join(''):'<div class="empty">Nenhuma caixa física corresponde à pesquisa.</div>'}</div>
 ${r?`<div class="card-footer"><span>Página ${r.page} de ${pages} · ${r.total} resultados · ${PAGE_SIZE} por página</span><div class="actions">
 <button type="button" data-box-search="previous" ${r.page<=1?'disabled':''}>Anterior</button>
 <button type="button" data-box-search="next" ${r.page>=pages?'disabled':''}>Próxima</button></div></div>`:''}</section>`;
}

export function bindBoxSearch(root,state,load){
 const form=root.querySelector('#box-search-filters');
 const capture=()=>{state.filters=Object.fromEntries(new FormData(form));};
 form.oninput=capture;
 form.onchange=()=>{capture();root.querySelector('#box-search-dates').hidden=state.filters.period!=='custom';};
 form.onsubmit=event=>{event.preventDefault();capture();state.applied={...state.filters};state.page=1;load();};
 for(const button of root.querySelectorAll('[data-box-search]'))button.onclick=()=>{
  if(button.dataset.boxSearch==='clear')state.reset();
  else if(button.dataset.boxSearch==='previous')state.page--;
  else if(button.dataset.boxSearch==='next')state.page++;
  load();
 };
}
