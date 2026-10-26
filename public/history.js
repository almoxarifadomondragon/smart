import {normalizeDestinationCode,formatQty,pad,totalQty} from './domain.js';
import {ownsPicking} from './picking-access.js';

export const PAGE_SIZE=20;
export const emptyFilters=()=>({number:'',project:'',station:'',bma:'',period:'all',from:'',to:''});
const civilFormat=new Intl.DateTimeFormat('en-CA',{timeZone:'America/Sao_Paulo',year:'numeric',month:'2-digit',day:'2-digit'});
export function saoPauloDate(instant){const p=Object.fromEntries(civilFormat.formatToParts(new Date(instant)).map(x=>[x.type,x.value]));return `${p.year}-${p.month}-${p.day}`;}
const shift=(date,days)=>{const d=new Date(date+'T12:00:00Z');d.setUTCDate(d.getUTCDate()+days);return d.toISOString().slice(0,10);};
export function dateRange(period,from='',to='',now=new Date()){
 const today=saoPauloDate(now),year=today.slice(0,4),month=today.slice(0,7);
 if(period==='all')return {from:null,to:null};
 if(period==='today')return {from:today,to:today};
 if(period==='week'){const day=new Date(today+'T12:00:00Z').getUTCDay();const monday=shift(today,-((day+6)%7));return {from:monday,to:shift(monday,6)};}
 if(period==='month'){const first=month+'-01';const next=new Date(first+'T12:00:00Z');next.setUTCMonth(next.getUTCMonth()+1);return {from:first,to:shift(next.toISOString().slice(0,10),-1)};}
 if(period==='year')return {from:year+'-01-01',to:year+'-12-31'};
 if(period!=='custom')throw new Error('Período inválido.');
 for(const d of [from,to])if(d&&(!/^\d{4}-\d{2}-\d{2}$/.test(d)||!Number.isFinite(Date.parse(d+'T12:00:00Z'))||new Date(d+'T12:00:00Z').toISOString().slice(0,10)!==d))throw new Error('Informe uma data válida.');
 if(from&&to&&from>to)throw new Error('A data inicial deve ser anterior ou igual à data final.');
 return {from:from||null,to:to||null};
}
export function searchParameters(filters,page=1,now=new Date(),scope='confirmed'){
 const number=filters.number.trim(),bma=filters.bma.trim().toUpperCase();
 if(number&&(!/^\d{1,30}$/.test(number)||BigInt(number)>9223372036854775807n))throw new Error('Informe apenas o número completo do romaneio.');
 if(bma&&!/^BMA\d{7}$/.test(bma))throw new Error('Informe o código BMA completo, por exemplo BMA0013617.');
 const project=normalizeDestinationCode(filters.project),station=normalizeDestinationCode(filters.station);
 if(project.length>120||station.length>120)throw new Error('Projeto e estação devem ter até 120 caracteres.');
 const range=dateRange(filters.period,filters.from,filters.to,now);
 return {p_number:number?String(BigInt(number)):null,p_project:project||null,p_station:station||null,p_bma:bma||null,p_from:range.from,p_to:range.to,p_page:page,p_scope:scope};
}
export function documentSummary(d){return {id:d.id,number:d.number,owner_id:d.owner_id,responsible:d.responsible,project:d.project,station:d.station,status:d.status,created_at:d.created_at,confirmed_at:d.confirmed_at,item_count:d.items?.length??d.item_count??0,box_count:d.boxes?.length??d.box_count??0,total_qty:d.items?totalQty(d.items):Number(d.total_qty||0)};}
export function dashboardTotals(docs){return docs.reduce((t,d)=>{const s=documentSummary(d);t[d.status==='draft'?'drafts':'confirmed']++;t.units+=s.total_qty;t.boxes+=s.box_count;return t;},{drafts:0,confirmed:0,units:0,boxes:0});}
export function searchDemo(docs,p){
 const rows=docs.filter(d=>{
  const date=d.confirmed_at?saoPauloDate(d.confirmed_at):null;
  return (p.p_scope==='all'||d.status==='confirmed')&&(!p.p_number||String(d.number)===p.p_number)&&(!p.p_project||normalizeDestinationCode(d.project)===p.p_project)&&(!p.p_station||normalizeDestinationCode(d.station)===p.p_station)&&(!p.p_bma||d.items.some(i=>i.code.trim().toUpperCase()===p.p_bma))&&(!p.p_from||(date&&date>=p.p_from))&&(!p.p_to||(date&&date<=p.p_to));
 }).sort((a,b)=>p.p_scope==='all'?b.number-a.number:(Date.parse(b.confirmed_at||'')||-Infinity)-(Date.parse(a.confirmed_at||'')||-Infinity)||b.number-a.number);
 return {rows:rows.slice((p.p_page-1)*PAGE_SIZE,p.p_page*PAGE_SIZE).map(documentSummary),total:rows.length,page:p.p_page,page_size:PAGE_SIZE};
}

// Independent state for history/overview. A stale or failed query never replaces
// newer results, and navigation keeps the applied filters and current page.
export class HistorySearch {
 constructor(scope='confirmed'){this.scope=scope;this.filters=emptyFilters();this.page=1;this.result=null;this.loading=false;this.error='';this.revision=0;}
 reset(){this.revision++;this.filters=emptyFilters();this.page=1;this.result=null;this.loading=false;this.error='';}
 async load(query,changed=()=>{}){
  const revision=++this.revision;this.loading=true;this.error='';this.result=null;changed();
  let valid=false;
  try{const p=searchParameters(this.filters,this.page,new Date(),this.scope);valid=true;const result=await query(p);if(revision===this.revision)this.result=result;}
  catch(e){if(revision===this.revision)this.error=!valid?e.message:e.code==='42501'||e.status===401||e.status===403?'Sua sessão não tem autorização para consultar romaneios. Entre novamente ou solicite acesso ao administrador.':'Não foi possível consultar os romaneios. Confira a conexão e tente pesquisar novamente.';}
  finally{if(revision===this.revision){this.loading=false;changed();}}
 }
}
const escape=v=>String(v??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const dateText=v=>v?new Date(v).toLocaleString('pt-BR',{timeZone:'America/Sao_Paulo',dateStyle:'short',timeStyle:'short'}):'Não registrada';
export function historyView(state,access={}){
 const f=state.filters,r=state.result,pages=Math.max(1,Math.ceil((r?.total||0)/PAGE_SIZE));
 const input=(label,key,extra='')=>`<label class="field">${label}<input name="${key}" value="${escape(f[key])}" ${extra}></label>`;
 return `<section class="card" id="history-search"><div class="card-head"><h2>${state.scope==='all'?'Todas as separações':'Histórico de romaneios'}</h2><span class="badge gray" aria-live="polite">${state.loading?'Consultando…':r?`${r.total} resultados`:'Pesquisa'}</span></div>
 ${state.scope==='confirmed'?`<form id="history-filters" class="card-body"><div class="history-fields">${input('Número do romaneio','number','inputmode="numeric" placeholder="Ex.: 000165" maxlength="30"')}${input('Projeto','project','maxlength="120"')}${input('Estação','station','maxlength="120"')}${input('Código BMA','bma','placeholder="BMA0013617" maxlength="10"')}<label class="field">Período<select name="period">${[['all','Todo o histórico'],['today','Hoje'],['week','Esta semana'],['month','Este mês'],['year','Este ano'],['custom','Personalizado']].map(([v,t])=>`<option value="${v}" ${f.period===v?'selected':''}>${t}</option>`).join('')}</select></label></div><div class="fields" id="history-dates" ${f.period==='custom'?'':'hidden'}>${input('Data inicial','from','type="date"')}${input('Data final','to','type="date"')}</div><div class="actions"><button class="primary" type="submit">Pesquisar</button><button type="button" data-history="clear">Limpar filtros</button><small>Data de confirmação · Fuso de São Paulo</small></div></form>`:''}
 <div aria-live="polite" aria-busy="${state.loading}">${state.loading?'<div class="empty" role="status">Consultando romaneios…</div>':state.error?`<div class="notice error" role="alert">${escape(state.error)} <button type="button" data-history="retry">Tentar novamente</button></div>`:r?.rows.length?r.rows.map(d=>`<div class="list-item"><div><strong>Separação #${pad(d.number)} · ${escape(d.project||'Projeto a definir')}</strong><p>Estação: ${escape(d.station||'A definir')} · Responsável: ${escape(d.responsible)}</p><p>${d.item_count} registros BMA · ${formatQty(d.total_qty)} unidades · ${d.box_count} caixas</p><small>${d.status==='confirmed'?'Confirmação: '+dateText(d.confirmed_at):'Abertura: '+dateText(d.created_at)}</small>${d.status==='draft'?`<p><span class="badge ${ownsPicking(d,access.userId,access.demo)?'green':'gray'}">${ownsPicking(d,access.userId,access.demo)?'Minha separação':'Separação de outro usuário · Somente consulta'}</span></p>`:''}</div><div class="actions"><span class="badge ${d.status==='confirmed'?'green':''}">${d.status==='confirmed'?'Confirmado':'Em andamento'}</span><button data-action="open" data-id="${escape(d.id)}">${d.status==='draft'&&ownsPicking(d,access.userId,access.demo)?'Continuar':'Consultar'} →</button></div></div>`).join(''):'<div class="empty">Nenhum documento corresponde à pesquisa.</div>'}</div>
 ${r&&!state.loading?`<div class="card-footer"><span>Página ${state.page} de ${pages} · ${r.total} resultados · 20 por página</span><div class="actions"><button data-history="previous" ${state.page<=1?'disabled':''}>Anterior</button><button data-history="next" ${state.page>=pages?'disabled':''}>Próxima</button></div></div>`:''}</section>`;
}
export function bindHistory(root,state,load){
 const form=root.querySelector('#history-filters');
 const capture=()=>{if(form)state.filters=Object.fromEntries(new FormData(form));};
 if(form){form.oninput=capture;form.onchange=()=>{capture();root.querySelector('#history-dates').hidden=state.filters.period!=='custom';};form.onsubmit=e=>{e.preventDefault();capture();state.page=1;load();};}
 for(const b of root.querySelectorAll('[data-history]'))b.onclick=()=>{capture();const action=b.dataset.history;if(action==='clear')state.reset();else if(action==='previous')state.page=Math.max(1,state.page-1);else if(action==='next')state.page++;load();};
}
