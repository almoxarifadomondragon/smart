import test from 'node:test';
import assert from 'node:assert/strict';
import {manifestCsv,parseQR,resolveItemDestination} from '../public/domain.js';
import {physicalBoxLink,physicalBoxRoute,boxRoute} from '../public/labels.js';
import {bindVolume,demoPhysicalContents,physicalContentsView,physicalLabelView,planInvoice,validateInvoice} from '../public/warehouse.js';

const origin='https://almoxarifadomondragon.github.io/smart/';
const physical={id:'11111111-1111-4111-8111-111111111111',code:'CX-000001',project:'0026005',station:'031200',name:'Volume <A>',status:'available'};
const makeDoc=(id,number,qty,invoice='')=>({
 id,number,project:physical.project,station:physical.station,responsible:'Operador',
 status:'confirmed',created_at:'2026-11-09T18:00:00Z',boxes:[{id:'vol-'+id,name:'Caixa 01',physical_box_id:physical.id}],
 items:[{id:'i-'+id,code:'BMA0013539',project:physical.project,station:physical.station,qty,invoice_number:invoice,box:'vol-'+id,
  purchase_order:'0021117',purchase_order_item:'01',scanned_at:'2026-11-09T18:00:00Z',operator:'Operador'}]
});

test('primeira leitura resolve destino e BMA simples reutiliza o destino sem exigir NF no QR',()=>{
 const empty={project:'',station:'',items:[]};
 const structured=parseQR('180$BMA0013539$0026005$031200$1,00$21117$1');
 assert.deepEqual(resolveItemDestination(empty,structured),{project:'0026005',station:'031200'});
 const simple=parseQR('BMA0013539');
 assert.deepEqual(resolveItemDestination(empty,simple,{allowMissing:true}),{project:'',station:''});
 assert.throws(()=>resolveItemDestination(empty,simple),/projeto e a estação/);
 assert.deepEqual(resolveItemDestination(physical,simple),{project:physical.project,station:physical.station});
 assert.throws(()=>resolveItemDestination(physical,{...structured,station:'31200'}),/não pertence/);
 assert.equal(structured.invoice_number,undefined);
});

test('NF selecionada, em lote e limpeza explícita não alteram o documento original',()=>{
 const items=[{id:'1',invoice_number:'0001/A'},{id:'2'},{id:'3',invoice_number:'002'}];
 const selection=planInvoice(items,['1','id-de-outro-romaneio'],' 0007-B ');
 assert.equal(selection.overwrites,1);
 assert.equal(selection.count,1);
 assert.deepEqual(selection.items.map(i=>i.invoice_number),['0007-B',undefined,'002']);
 assert.equal(items[0].invoice_number,'0001/A');
 const all=planInvoice(items,[],'0007-B',{all:true});
 assert.equal(all.overwrites,2);assert.equal(all.count,3);
 const cleared=planInvoice(items,['1','2'],'ignorado',{clear:true});
 assert.equal(cleared.count,1);assert.equal(cleared.items[0].invoice_number,'');
 assert.throws(()=>planInvoice(items,[],'0007-B'),/Selecione/);
 assert.throws(()=>planInvoice(items,['1'],' '),/Nota Fiscal/);
 for(const value of ['=SUM(A1)','<html>','-123','A'.repeat(61)])assert.throws(()=>validateInvoice(value),/Nota Fiscal/);
 assert.equal(validateInvoice('000020/AB-1'),'000020/AB-1');
 assert.equal(validateInvoice(''),'');
});

test('vínculo por UUID respeita projeto, estação e status sem reescrever itens',()=>{
 const doc=makeDoc('a',1,2,'0001');
 const volumes=bindVolume(doc,doc.boxes[0].id,physical);
 assert.equal(volumes[0].physical_box_code,physical.code);
 assert.equal(doc.boxes[0].physical_box_code,undefined);
 assert.equal(doc.items[0].invoice_number,'0001');
 for(const different of [{project:'26005'},{station:'31200'}])
  assert.throws(()=>bindVolume(doc,doc.boxes[0].id,{...physical,...different}),/Selecione outra caixa/);
 assert.throws(()=>bindVolume(doc,doc.boxes[0].id,{...physical,status:'closed'}),/fechada/);
 assert.equal(bindVolume(doc,doc.boxes[0].id,null)[0].physical_box_id,undefined);
});

test('etiqueta permanente mantém URL; consulta preserva ocorrências e origem',()=>{
 const a=makeDoc('a',1,2,'0001'),b=makeDoc('b',8,3);
 const qrUrls=[];
 const label=(box)=>physicalLabelView(box,origin+'?param=1#anterior',url=>{qrUrls.push(url);return '<svg></svg>';});
 const first=label(physical);
 const contents=demoPhysicalContents({...physical,status:'in_use'},[b,a]);
 const second=label(contents.box);
 assert.equal(first.url,second.url);
 assert.equal(qrUrls[0],qrUrls[1]);assert.deepEqual(physicalBoxRoute(new URL(first.url).hash),{id:physical.id,demo:false});
 assert.equal(boxRoute(new URL(first.url).hash),null);assert.equal(new URL(first.url).search,'');
 assert.equal(physicalBoxLink(origin,physical.id),first.url);
 assert.match(first.html,/Volume &lt;A&gt;/);
 assert.deepEqual(contents.items.map(i=>[i.code,i.document_number,i.qty]),[['BMA0013539',1,2],['BMA0013539',8,3]]);
 assert.equal(contents.total_units,5);
 assert.match(physicalContentsView(contents),/não representam o saldo físico atual/);
 assert.match(physicalContentsView(contents),/Nota Fiscal/);
 assert.match(physicalContentsView(contents),/0001/);
 assert.match(manifestCsv(a),/"Nota Fiscal"/);
 assert.match(manifestCsv(a),/"0001"$/);
});
