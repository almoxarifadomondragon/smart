import test from 'node:test';import assert from 'node:assert/strict';import {readFileSync,existsSync} from 'node:fs';import {createHash} from 'node:crypto';
import {parseCode,parseQR,parseQuantity,validateManifest} from '../public/domain.js';import {readOrderPdf} from '../public/pdf-orders.js';import {demoDuplicateReview} from '../public/item-origin.js';
test('BMA/BPZ universais: simples, JSON, texto, scanner estruturado e zero temporário',()=>{
 for(const prefix of ['BMA','BPZ']){
  assert.equal(parseCode('  '+prefix.toLowerCase()+'0001979 '),prefix+'0001979');assert.deepEqual(parseQR(prefix.toLowerCase()+'0001979'),{code:prefix+'0001979'});
  for(const payload of ['180$'+prefix+'0001979$026005$031050$0,00$021338$03',JSON.stringify({[prefix.toLowerCase()]:prefix+'0001979',projeto:'026005',estacao:'031050',quantidade:0,pedido:'021338',item_pedido:'03'}),prefix+': '+prefix+'0001979; Projeto: 026005; Estacao: 031050; Quantidade: 0; Pedido: 021338; Item_pedido: 03']){
   const r=parseQR(payload);assert.equal(r.code,prefix+'0001979');assert.equal(r.qty,0);assert.equal(r.project,'026005');assert.equal(r.station,'031050');assert.equal(r.purchase_order,'021338');assert.equal(r.purchase_order_item,'03');
  }
 }
 for(const value of ['BMA123','BPZ123','ABC0043578','BPZ0043578X'])assert.throws(()=>parseCode(value));assert.throws(()=>parseQuantity(0));
 // Three payloads decoded locally from the actual vector QR symbols on VH21338, page 2.
 for(const [code,station,line] of [['BPZ0043578','31050','1'],['BPZ0043579','31050','2'],['BPZ0043634','31450','3']]){const r=parseQR('180$'+code+'$26005$'+station+'$1,00$21338$'+line);assert.equal(r.code,code);assert.equal(r.station,station);assert.equal(r.purchase_order_item,line);}
});
test('Regressão individual: cada uma das 521 linhas BPZ mantém o hash anterior', {skip:!existsSync('C:/Users/sn1078588/Downloads/VH21338 - BP26005 - MAK.pdf')},async()=>{
 globalThis.DOMMatrix ||= class {};const reference=JSON.parse(readFileSync(new URL('fixtures/pdf-bpz-reference.json',import.meta.url),'utf8'));let count=0;
 for(const f of reference.files){const p=await readOrderPdf(new File([readFileSync('C:/Users/sn1078588/Downloads/'+f.name)],f.name));assert.equal(p.hash,f.pdf_sha256);assert.equal(p.rows.length,f.rows.length);for(const [i,r] of p.rows.entries()){assert.equal(createHash('sha256').update(JSON.stringify(r)).digest('hex'),f.rows[i],f.name+' linha '+(i+1));count++;}}
 assert.equal(count,521);
});
test('PDF sintético BMA: extrator canônico preserva referência L, destino e quantidade',async()=>{
 globalThis.DOMMatrix ||= class {};const p=await readOrderPdf(new File([readFileSync(new URL('fixtures/synthetic-bma-order.pdf',import.meta.url))],'synthetic-bma-order.pdf'));assert.equal(p.order,'VH99900');assert.equal(p.rows.length,1);assert.deepEqual(p.rows[0].errors,[]);assert.equal(p.rows[0].code,'BMA0000001');assert.equal(p.rows[0].ordered,2);assert.equal(p.rows[0].sequence,'1');assert.equal(p.rows[0].line,'3');assert.equal(p.rows[0].project,'26005');assert.equal(p.rows[0].station,'31450');
});
test('Revisão de duplicidade não bloqueia por prefixo, documento ou pedido isoladamente',()=>{
 const item={id:'new',code:'BPZ0043578',project:'26005',station:'31050',qty:2,purchase_order:'21338',purchase_order_item:'1'},d={id:'d',number:1,items:[{...item,id:'pdf',source:'PDF',source_order:'VH21338'}]};
 const r=demoDuplicateReview(d,item,[d]);assert.equal(r.total,1);assert.equal(r.matches[0].source,'PDF');assert.equal(demoDuplicateReview(d,{...item,project:'999'},[d]).total,0);assert.equal(demoDuplicateReview(d,item,[{...d,import_state:'cancelled'}]).total,0);assert.notEqual(demoDuplicateReview(d,{...item,qty:3},[d]).fingerprint,r.fingerprint);
});

test('PDFs BMA reais EZ: pedido, linha, material, quantidade e destino conferidos', {skip:!existsSync('C:/Users/sn1078588/Downloads/EZ21075 - BP26002 - AWALTECH.pdf')||!existsSync('C:/Users/sn1078588/Downloads/EZ21077 - BP24005 - TRIVAX.pdf')},async()=>{
 globalThis.DOMMatrix ||= class {};
 for(const [name,order,code,qty,project,station,drawing] of [['EZ21075 - BP26002 - AWALTECH.pdf','EZ21075','BMA0013502',1,'26002','31132','OMRON_CM-EIP-1'],['EZ21077 - BP24005 - TRIVAX.pdf','EZ21077','BMA0008056',3,'24005','31135',"GEDORE_ADAP. QUAD. SEXT=1_4''X100MM"]]){const p=await readOrderPdf(new File([readFileSync('C:/Users/sn1078588/Downloads/'+name)],name));assert.equal(p.order,order);assert.equal(p.rows.length,1);const r=p.rows[0];assert.deepEqual(r.errors,[]);assert.deepEqual(r.warnings,[]);assert.equal(r.code,code);assert.equal(r.sequence,'1');assert.equal(r.line,'1');assert.equal(r.ordered,qty);assert.equal(r.project,project);assert.equal(r.station,station);assert.equal(r.drawing,drawing);assert.equal(r.revision,'');assert.equal(r.page,1);}
});
