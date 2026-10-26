import test from 'node:test';
import assert from 'node:assert/strict';
import {dateRange,emptyFilters,searchParameters,searchDemo,HistorySearch,historyView,dashboardTotals} from '../public/history.js';
const now=new Date('2026-10-26T02:30:00Z'); // Sunday 25 in São Paulo, Monday in UTC.
const d=(n,options={})=>({id:'d'+n,number:n,project:'026005',station:'031200',status:'confirmed',responsible:'Fixture',created_at:'2026-09-01T12:00:00Z',confirmed_at:'2026-10-26T02:59:59.999Z',boxes:[{id:'a'},{id:'b'}],items:[{code:'BMA0000001',qty:2,box:'a'},{code:'BMA0013617',qty:1.5,box:'b'}],...options});
const docs=[d(165),d(166,{confirmed_at:'2026-10-26T03:00:00Z'}),d(167,{project:'26005'}),d(168,{station:'31200',items:[{code:'BMA0000002',qty:3}]}),d(169,{status:'draft',confirmed_at:null}),d(170,{confirmed_at:'2026-09-30T03:00:00Z'}),d(171,{confirmed_at:'2026-10-01T02:59:59Z'})];
const search=f=>searchDemo(docs,searchParameters({...emptyFilters(),...f},1,now));

test('histórico: número aceita 165 e 000165; rejeita parcial, decimal e overflow',()=>{
 for(const number of ['165','000165'])assert.deepEqual(search({number}).rows.map(x=>x.number),[165]);
 for(const number of ['16x','1.65','9223372036854775808','-1'])assert.throws(()=>search({number}),/número/);
 assert.equal(search({number:'16'}).total,0);
});
test('histórico: projeto e estação exatos preservam zeros; filtros combinam AND',()=>{
 assert.equal(search({project:' 026005 '}).total,5);assert.equal(search({project:'26005'}).total,1);
 assert.equal(search({station:'031200'}).total,5);assert.equal(search({project:'026005',station:'031200'}).total,4);
 assert.equal(search({project:'026005',station:'031200',bma:'bma0013617'}).total,4);
 assert.equal(search({project:'02600'}).total,0);
});
test('histórico: BMA completo em qualquer caixa/último item e em vários documentos',()=>{
 const r=search({bma:'bma0013617'});assert.equal(r.total,5);assert.ok(r.rows.some(d=>d.number===165));
 assert.throws(()=>search({bma:'BMA00136'}),/completo/);
 assert.equal(search({bma:'BMA9999999'}).total,0);
});
test('histórico: períodos rápidos usam São Paulo, semana começa segunda e mês/ano completos',()=>{
 assert.deepEqual(dateRange('today','','',now),{from:'2026-10-25',to:'2026-10-25'});
 assert.deepEqual(dateRange('week','','',now),{from:'2026-10-19',to:'2026-10-25'});
 assert.deepEqual(dateRange('week','','',new Date('2026-10-26T03:00:00Z')),{from:'2026-10-26',to:'2026-11-01'});
 assert.deepEqual(dateRange('month','','',now),{from:'2026-10-01',to:'2026-10-31'});
 assert.deepEqual(dateRange('year','','',now),{from:'2026-01-01',to:'2026-12-31'});
 assert.deepEqual(dateRange('month','','',new Date('2024-02-15T12:00:00Z')),{from:'2024-02-01',to:'2024-02-29'});
 assert.equal(search({period:'today'}).total,3);assert.equal(search({period:'week'}).total,3);assert.equal(search({period:'month'}).total,4);assert.equal(search({period:'year'}).total,6);
});
test('histórico: intervalo personalizado inclusivo, cruzando mês, baseado em confirmação',()=>{
 assert.equal(search({period:'custom',from:'2026-10-25',to:'2026-10-25'}).total,3);
 assert.equal(search({period:'custom',from:'2026-09-30',to:'2026-10-01'}).total,2);
 assert.equal(search({period:'custom',from:'2026-10-01',to:'2026-10-31',number:'165'}).total,1);
 assert.equal(search({period:'custom',from:'2026-09-01',to:'2026-09-01',number:'165'}).total,0);
 assert.equal(search({period:'custom',from:'',to:'2026-09-30'}).total,2);
 assert.throws(()=>search({period:'custom',from:'2026-10-26',to:'2026-10-25'}),/inicial/);
 assert.throws(()=>search({period:'custom',from:'2026-02-30'}),/válida/);
});
test('histórico: 45 documentos, página de 20, desempate e sumários sem arrays',()=>{
 const data=Array.from({length:45},(_,i)=>d(i+1));const p=searchParameters(emptyFilters());
 const first=searchDemo(data,p),second=searchDemo(data,{...p,p_page:2}),third=searchDemo(data,{...p,p_page:3});
 assert.equal(first.total,45);assert.equal(first.rows.length,20);assert.equal(first.rows[0].number,45);assert.equal(first.rows.at(-1).number,26);
 assert.equal(second.rows[0].number,25);assert.equal(third.rows.length,5);assert.ok(!first.rows.some(x=>'items' in x||'boxes' in x));
 assert.equal(first.rows[0].item_count,2);assert.equal(first.rows[0].total_qty,3.5);assert.equal(first.rows[0].box_count,2);
 assert.deepEqual(dashboardTotals(data),{drafts:0,confirmed:45,boxes:90,units:157.5});
 assert.equal(dashboardTotals(data).confirmed,45);assert.equal(first.rows.length,20);
});
test('histórico: abrir/retornar preserva filtros e página; limpar restaura todo histórico',async()=>{
 const state=new HistorySearch();state.filters.project='026005';state.page=2;
 await state.load(async p=>searchDemo(Array.from({length:30},(_,i)=>d(i+1)),p));
 const before={...state.filters};historyView(state); // Recreating the view must not reset persisted search state.
 assert.deepEqual(state.filters,before);assert.equal(state.page,2);assert.equal(state.result.total,30);
 state.reset();assert.deepEqual(state.filters,emptyFilters());assert.equal(state.page,1);assert.equal(state.result,null);
});
test('histórico: carregamento, zero resultados, erro técnico e autorização visíveis sem dados antigos',async()=>{
 const state=new HistorySearch();let resolve;const pending=state.load(()=>new Promise(r=>{resolve=r;}));
 assert.match(historyView(state),/Consultando romaneios/);resolve({rows:[],total:0});await pending;
 assert.match(historyView(state),/Nenhum documento corresponde/);
 await state.load(async()=>{throw new Error('Failed to fetch');});assert.match(historyView(state),/Não foi possível consultar/);assert.equal(state.result,null);
 await state.load(async()=>{throw Object.assign(new Error('SQL private details'),{code:'42501'});});assert.match(historyView(state),/não tem autorização/);assert.ok(!historyView(state).includes('private details'));
 state.filters.from='2026-10-26';state.filters.to='2026-10-25';state.filters.period='custom';
 await state.load(async()=>{throw new Error('should not call');});assert.match(historyView(state),/data inicial/);
});
test('histórico: requisições fora de ordem e troca de usuário não expõem resultado anterior',async()=>{
 const state=new HistorySearch();let first;const pending=state.load(()=>new Promise(r=>{first=r;}));
 state.filters.project='NEW';await state.load(async()=>({rows:[{number:2}],total:1}));first({rows:[{number:1}],total:1});await pending;
 assert.equal(state.result.rows[0].number,2);
 let late;const beforeLogout=state.load(()=>new Promise(r=>{late=r;}));state.reset();late({rows:[{number:3}],total:1});await beforeLogout;assert.equal(state.result,null);
});
test('histórico: filtros e sumários escapam conteúdo e informam todos os campos',()=>{
 const state=new HistorySearch();state.filters.project='<script>';state.result=search({number:'165'});
 const html=historyView(state);for(const text of ['&lt;script&gt;','000165','026005','031200','Fixture','Confirmação','2 registros BMA','3,5','2 caixas','Confirmado'])assert.ok(html.includes(text),text);
 assert.ok(!html.includes('<script>'));
});
