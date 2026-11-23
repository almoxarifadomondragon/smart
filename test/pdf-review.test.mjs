import test from 'node:test';
import assert from 'node:assert/strict';
import {filterReviewRows,rowIssues,reviewSummary,rowStatus} from '../public/pdf-review.js';
import {importSelection} from '../public/pdf-import-view.js';
const base={file_id:'file',index:1,order:'VH21338',line:'1',sequence:'1',code:'BPZ0043578',description:'Tampo do alimentador',project:'26005',station:'31050',ordered:10,allocated:2,quantity:8,selected:true,reason:'',warnings:[],errors:[]};
const row=(overrides={})=>{const r={...base,...overrides};return {...r,original:{description:r.description,project:r.project,station:r.station}};};
test('conferência: filtros combinados, pesquisa e ordenação não alteram seleção ou quantidades',()=>{
 const rows=Array.from({length:105},(_,i)=>row({index:i+1,line:String(i+1),selected:i%2===0,station:i<60?'31050':'31450'}));
 const before=structuredClone(rows),filtered=filterReviewRows(rows,{search:'ALIMENTADOR',project:'26005',station:'31450',order:'VH21338',selected:true},'quantity');
 assert.equal(filtered.length,23);assert.deepEqual(rows,before);
 assert.equal(filterReviewRows(rows,{search:'bpz0043578'}).length,105);
 assert.equal(filterReviewRows(rows,{search:'vh21338'}).length,105);
 assert.equal(filterReviewRows(rows,{station:'31450',status:'partial'}).length,45);
 assert.deepEqual(filterReviewRows(rows,{station:'99999'}),[]);
 assert.deepEqual(importSelection(rows),importSelection(before));
});
test('conferência: resumo contém exclusivamente selecionados, excluídos e grupos dinâmicos',()=>{
 const rows=[row(),row({index:2,station:'31450',selected:false}),row({index:3,excluded:true}),row({index:4,project:'25024',station:'31250',quantity:3})];
 rows[0].description='Tampo corrigido';rows[0].reason='Descrição conferida no desenho';
 const summary=reviewSummary(rows);
 assert.equal(summary.selected.length,2);assert.equal(summary.groups.length,2);assert.equal(summary.qty,11);assert.equal(summary.excluded,1);assert.equal(summary.changed,2);assert.equal(summary.pending,0);
 assert.equal(importSelection(rows).length,2);
});
test('conferência: bloqueia excesso, duplicidade, destino inválido e correção sem justificativa',()=>{
 for(const r of [row({quantity:9}),row({quantity:0}),row({quantity:NaN}),row({quantity:1.001}),row({duplicate_in_batch:true}),row({conflict:true}),row({station:''})]){
  assert.ok(rowIssues(r).length);assert.throws(()=>importSelection([r]));
 }
 const corrected=row();corrected.project='25024';assert.ok(rowIssues(corrected).length);corrected.reason='Destino conferido';assert.deepEqual(rowIssues(corrected),[]);
 const warning=row({warnings:['Divergência entre tabela e etiqueta']});assert.ok(rowIssues(warning).length);warning.reason='Tabela conferida no original';assert.deepEqual(rowIssues(warning),[]);assert.equal(importSelection([warning]).length,1);
 assert.equal(rowStatus(row({allocated:10,quantity:0})),'complete');
});
