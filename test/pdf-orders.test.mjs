import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync,existsSync} from 'node:fs';
import {join} from 'node:path';
import {readOrderPdf,parseOrderPages,groupOrderRows,validateOrderRow,textRows} from '../public/pdf-orders.js';
import {importSelection} from '../public/pdf-import-view.js';
const fixtureDir=process.env.SMART_PDF_FIXTURES||'C:/Users/sn1078588/Downloads';
const names=['21338','21339','21340','21346','21347','21348','21349','21350','21352','21353','21519','21549','21715'].map(n=>'VH'+n+' - BP'+(n==='21715'?'25024':'26005')+' - MAK.pdf');
export async function referenceOrders(){
 globalThis.DOMMatrix ||= class {};
 const orders=[];
 for(const name of names)orders.push(await readOrderPdf(new File([readFileSync(join(fixtureDir,name))],name)));
 return orders;
}
test('13 PDFs reais: 521 linhas, 8 destinos, quantidades, L:, desenhos e etiquetas', {skip:!names.every(n=>existsSync(join(fixtureDir,n)))},async()=>{
 const orders=await referenceOrders(),rows=orders.flatMap(d=>d.rows);
 assert.equal(new Set(orders.map(d=>d.order)).size,13);assert.equal(rows.length,521);
 assert.deepEqual(groupOrderRows(rows).map(g=>[g.project,g.station,g.rows.length]),[['25024','31250',6],['26005','31050',117],['26005','31100',102],['26005','31150',15],['26005','31200',99],['26005','31300',15],['26005','31400',61],['26005','31450',106]]);
 assert.ok(rows.every(r=>r.errors.length===0&&r.warnings.length===0));
 assert.ok(rows.some(r=>r.sequence!==r.line));
 const item=orders[0].rows[2];assert.equal(item.code,'BPZ0043634');assert.equal(item.station,'31450');assert.equal(item.drawing,'BP26005-31450-070');assert.equal(item.revision,'A');assert.equal(item.ordered,1);
 assert.ok(orders.some(d=>d.pages>=20));
});
test('confirmação valida saldo parcial, correção justificada e seleção estável',()=>{
 const source={order:'VH1',sequence:'1',line:'3',code:'BPZ0000001',description:'Base',project:'26005',station:'31450',ordered:100};
 const row={...source,original:{...source},file_id:'file',index:1,quantity:25,allocated:60,selected:true,warnings:[],reason:''};
 assert.equal(importSelection([row])[0].quantity,25);
 assert.throws(()=>importSelection([{...row,quantity:41}]),/saldo/);
 assert.throws(()=>importSelection([{...row,quantity:0}]),/Quantidade/);
 assert.throws(()=>importSelection([{...row,station:'31050'}]),/Justifique/);
 assert.equal(importSelection([{...row,station:'31050',reason:'Correção conferida no desenho'}])[0].station,'31050');
 assert.throws(()=>importSelection([{...row,conflict:true}]),/pendências/);
 assert.throws(()=>importSelection([{...row,excluded:true}]),/Selecione/);
 assert.throws(()=>importSelection([{...row,warnings:['Divergência da etiqueta']}]),/Justifique/);
 assert.ok(validateOrderRow({...source,ordered:-1}).length);
});
test('documentos sem tabela, assinatura falsa e limite de tamanho são rejeitados',async()=>{
 globalThis.DOMMatrix ||= class {};
 assert.throws(()=>parseOrderPages([[]]),/Nenhuma tabela/);
 await assert.rejects(readOrderPdf(new File(['this is not a PDF'],'a.pdf')),/assinatura/);
 await assert.rejects(readOrderPdf(new File(['%PDF-1.7\nconteúdo corrompido\n%%EOF'],'invalid.pdf')),/corrompido/);
 await assert.rejects(readOrderPdf({name:'large.pdf',size:30*1024*1024}),/20 MB/);
 assert.deepEqual(textRows([{str:'B',transform:[1,0,0,1,80,20]},{str:'A',transform:[1,0,0,1,10,21]}]).map(r=>r.text),['A B']);
});
test('linha sem BPZ continua na conferência e quantidade com milhar é reconhecida',()=>{
 const cell=(str,x,y)=>({str,transform:[8,0,0,8,x,y]});
 const parsed=parseOrderPages([[cell('Pedido VH123',40,800),cell('Linha do Pedido DESCRIÇÃO Qtd',40,700),cell('1',49,650),cell('PEÇA SEM CÓDIGO',75,650),cell('1.234,50',375,650),cell('Fab. 01',75,635),cell('L:3 - 26005 - 31450 Plano: BP26005-31450-070 Rev: A',59,620)]]);
 assert.equal(parsed.rows.length,1);assert.equal(parsed.rows[0].ordered,1234.5);assert.equal(parsed.rows[0].line,'3');assert.equal(parsed.rows[0].sequence,'1');
 assert.ok(parsed.rows[0].errors.some(e=>e.includes('BPZ')));
});
