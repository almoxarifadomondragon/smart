import test from 'node:test';
import assert from 'node:assert/strict';
import {BoxSearch, boxSearchParameters, boxSearchView, searchDemoBoxes} from '../public/box-search.js';

const created='2026-11-16T02:30:00Z';
const boxes=[
 {id:'one',code:'CX-000001',name:'Elétrica <01>',status:'closed',project:'0004567',station:'0001',created_at:created,
  delivery:{closed_at:'2026-11-16T03:30:00Z',closed_by_name:'Ana',email_state:'uncertain'}},
 {id:'two',code:'CX-000002',name:'Histórica',status:'closed',project:'0004567',station:'0001',created_at:created},
 ...Array.from({length:21},(_,i)=>({id:'s'+i,code:'CX-S'+i,name:'Estoque',status:i===0?'in_use':'available',project:'0004567',station:'0001',created_at:created}))
];
const docs=[
 {id:'first',number:31,status:'confirmed',boxes:[{id:'v1',physical_box_id:'one'},{id:'v2',physical_box_id:'s0'},{id:'local'}],
  items:[{box:'v1',code:'BMA0013539',qty:2.5},{box:'v2',code:'BMA0013540',qty:1},{box:'local',code:'BMA0013599',qty:4}]},
 {id:'second',number:32,status:'confirmed',boxes:[{id:'v3',physical_box_id:'one'}],items:[{box:'v3',code:'BMA0013539',qty:3}]}
];

test('Pesquisa por BMA usa o volume vinculado e combina os filtros em São Paulo',()=>{
 const state=new BoxSearch();
 Object.assign(state.filters,{code:'00001',name:'ELÉTRICA',project:'0004567',station:'0001',bma:'bma0013539',
  number:'000031',status:'closed',closer:'ana',period:'custom',dateType:'closed',from:'2026-11-16',to:'2026-11-16'});
 const p=boxSearchParameters(state.filters);
 assert.equal(p.p_project,'0004567');
 assert.equal(p.p_document_number,'31');
 const result=searchDemoBoxes(boxes,docs,p);
 assert.equal(result.total,1);
 assert.equal(result.rows[0].document_count,2);
 assert.equal(result.rows[0].item_count,2);
 assert.equal(result.rows[0].total_units,5.5);
 assert.equal(result.indicators.pending,1);
 assert.equal(searchDemoBoxes(boxes,docs,{...p,p_bma:'BMA0013599'}).total,0);
});

test('Listagem mantém indicadores globais, ordena e identifica caixa histórica sem inventar data',()=>{
 const state=new BoxSearch();
 const first=searchDemoBoxes(boxes,docs,boxSearchParameters(state.filters));
 assert.equal(first.rows.length,20);
 assert.equal(first.rows[0].status,'in_use');
 state.result=searchDemoBoxes(boxes,docs,boxSearchParameters(state.filters,2));
 assert.deepEqual(state.result.indicators,{total:23,available:20,in_use:1,closed:2,pending:1,sending:0});
 const html=boxSearchView(state);
 assert.match(html,/Página 2 de 2/);
 assert.match(html,/Fechamento histórico sem comprovante/);
 assert.match(html,/Elétrica &lt;01&gt;/);
 assert.match(html,/Resultado incerto/);
});

test('Navegação usa filtros aplicados e ignora resultados atrasados',async()=>{
 const state=new BoxSearch();
 state.filters.name='digitação ainda não aplicada';
 state.applied.code='CX-000001';
 let resolveOld;
 const old=state.load(()=>new Promise(resolve=>{resolveOld=resolve;}));
 await state.load(p=>{
  assert.equal(p.p_code,'CX-000001');
  assert.equal(p.p_name,null);
  return searchDemoBoxes(boxes,docs,p);
 });
 resolveOld({total:99,page:9});
 await old;
 assert.equal(state.result.total,1);
 assert.equal(state.page,1);
 assert.equal(state.filters.name,'digitação ainda não aplicada');
});
