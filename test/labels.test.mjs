import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
import {boxLink,boxRoute,boxDetails} from '../public/labels.js';
const docId='11111111-1111-4111-8111-111111111111',boxId='22222222-2222-4222-8222-222222222222';
test('etiqueta: link preserva documento e caixa e remove query anterior',()=>{
 const link=boxLink('http://localhost:4173/?old=1#old',docId,boxId,true);
 assert.deepEqual(boxRoute(new URL(link).hash),{documentId:docId,boxId,demo:true});
 assert.equal(new URL(link).search,'');assert.equal(boxRoute('#caixa=invalid'),null);
 assert.throws(()=>boxLink('javascript:alert(1)',docId,boxId));
});
test('etiqueta: separa conteúdo por caixa e identifica projetos mistos',()=>{
 const doc={project:'Fallback',station:'0',boxes:[{id:'other'},{id:boxId,name:'Caixa B'}],items:[{box:'other',project:'ERRADO'},{box:boxId,project:'25024',station:'31133'},{box:boxId,project:'25025',station:'31133'}]};
 const data=boxDetails(doc,boxId);assert.equal(data.number,'02/02');assert.equal(data.items.length,2);assert.equal(data.project,'25024 / 25025');assert.equal(data.station,'31133');assert.throws(()=>boxDetails(doc,'missing'));
});
test('etiqueta: biblioteca QR local gera SVG escalável com margem',()=>{
 const context={};vm.runInNewContext(fs.readFileSync(new URL('../public/qrcode.js',import.meta.url),'utf8'),context);
 const qr=context.qrcode(0,'M');qr.addData(boxLink('http://localhost:4173/',docId,boxId));qr.make();
 assert.ok(qr.getModuleCount()>21);const svg=qr.createSvgTag({cellSize:4,margin:16,scalable:true});assert.match(svg,/<svg/);assert.match(svg,/viewBox=/);assert.ok(!svg.includes('<script'));
});
