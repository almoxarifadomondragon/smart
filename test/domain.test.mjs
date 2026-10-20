import test from 'node:test';
import assert from 'node:assert/strict';
import {parseQR,parseCode,parseQuantity,formatQty,totalQty,manifestCsv,validateManifest} from '../public/domain.js';
test('leitura completa JSON e texto rotulado',()=>{
 const expected={code:'BMA0001979',project:'Projeto X',station:'Estação Y',qty:3};
 assert.deepEqual(parseQR('{"BMA":"BMA0001979","projeto":"Projeto X","estacao":"Estação Y","quantidade":3}'),expected);
 assert.deepEqual(parseQR('BMA: BMA0001979; Projeto: Projeto X; Estação: Estação Y; Quantidade: 3'),expected);
});
test('código simples, espaços e leituras inválidas',()=>{
 assert.equal(parseCode(' bma0001979 '),'BMA0001979');
 assert.deepEqual(parseQR('BMA0001979'),{code:'BMA0001979'});
 for(const raw of ['<script>','null','123','{}','BMA123','{"bma":"BMA0001979","qty":-2}','{"bma":"BMA0001979","qty":1.555}']) assert.throws(()=>parseQR(raw));
});
const make=()=>({project:'X',station:'Y',boxes:[{id:'a'}],items:[{code:'BMA0001979',project:'X',station:'Y',qty:1,box:'a'}]});
test('romaneio válido e remanejamento sem perda da quantidade',()=>{
 const doc=make();assert.equal(validateManifest(doc),true);
 doc.boxes=[{id:'b'}];doc.items[0].box='b';assert.equal(validateManifest(doc),true);assert.equal(doc.items[0].qty,1);
});
test('impede confirmação vazia, caixa vazia, item órfão e quantidade inválida',()=>{
 for(const change of [d=>d.items=[],d=>d.project='',d=>d.boxes.push({id:'b'}),d=>d.items[0].box='x',d=>d.items[0].qty=0,d=>d.items[0].qty=1.555,d=>d.items[0].station='']){const doc=make();change(doc);assert.throws(()=>validateManifest(doc));}
});
test('QR real Mondragon com pedido e item do pedido',()=>{
 assert.deepEqual(parseQR('180$BMA0013539$25024$31133$1,00$21117$1\r\n'),{
  code:'BMA0013539',project:'25024',station:'31133',qty:1,purchase_order:'21117',purchase_order_item:'1',qr_prefix:'180'
 });
});
test('decimais e zeros iniciais preservados nos identificadores',()=>{
 const item=parseQR('180$BMA0013539$025024$031133$2,50$021117$01');
 assert.equal(item.qty,2.5);assert.equal(item.project,'025024');assert.equal(item.station,'031133');
 assert.equal(item.purchase_order,'021117');assert.equal(item.purchase_order_item,'01');
 assert.equal(totalQty([{qty:0.1},{qty:0.2}]),0.3);
 assert.equal(parseQuantity(formatQty(1234.5)),1234.5);
 const doc=make();doc.items[0]={...doc.items[0],...item};assert.equal(validateManifest(doc),true);
});
test('recusa QR incompleto e pedido/quantidade inválidos',()=>{
 for(const code of ['180$BMA0013539$25024$31133$1,00$21117','180$BMA0013539$$31133$1,00$21117$1','180$BMA0013539$25024$31133$0,00$21117$1','180$BMA0013539$25024$31133$1,234$21117$1','180$BMA0013539$25024$31133$1,00$21117$X','180$BMA0013539$25024$31133$1,00$21117$1$extra'])assert.throws(()=>parseQR(code));
 for(const qty of ['1,2.3','NaN','Infinity','1e3','-1','1000000',''])assert.throws(()=>parseQuantity(qty));
 const doc=make();doc.items[0].purchase_order='21117';assert.throws(()=>validateManifest(doc));
});
test('CSV preserva campos do QR e neutraliza fórmulas em texto',()=>{
 const doc=make();doc.number=148;doc.boxes[0].name='Caixa 01';
 doc.items[0]={...doc.items[0],...parseQR('180$BMA0013539$25024$31133$1,00$21117$1'),scanned_at:'2026-10-05T12:00:00Z',operator:'=HYPERLINK("teste")'};
 const csv=manifestCsv(doc);
 assert.ok(csv.includes('"Pedido de compras";"Item do pedido";"Prefixo QR"'));
 assert.ok(csv.includes('"000148";"BMA0013539";"25024";"31133";"1,00";"21117";"1";"180";"Caixa 01"'));
 assert.ok(csv.includes('"\'=HYPERLINK(""teste"")"'));
});
