import test from 'node:test';
import assert from 'node:assert/strict';
import {normalizeDestinationCode as norm,resolveItemDestination,destinationIssues,validateDestinationSave,validateManifest,parseQR} from '../public/domain.js';
const doc=()=>({project:'025024',station:'031133',boxes:[{id:'b1'},{id:'b2'}],items:[]});
const item=(project='025024',station='031133',box='b1')=>({id:box,code:'BMA0013539',project,station,qty:1,box});
test('normalização textual é exata, não numérica, e preserva zeros',()=>{
 assert.equal(norm('\t 0abc \r\n'),'0ABC');assert.notEqual(norm('025024'),norm('25024'));assert.notEqual(norm('25024'),norm('250240'));
 assert.equal(norm(null),'');assert.equal(norm('A\u00a0'),'A\u00a0');
});
test('destino igual aceita; projeto, estação ou ambos diferentes rejeitam com valores esperados/lidos',()=>{
 assert.deepEqual(resolveItemDestination(doc(),item()),{project:'025024',station:'031133'});
 for(const i of [item('25024'),item('025024','31133'),item('outro','outra')])assert.throws(()=>resolveItemDestination(doc(),i),e=>e.message.includes('Peça não pertence a esta separação.')&&e.message.includes('Projeto esperado: 025024')&&e.message.includes('Estação esperada: 031133')&&e.message.includes('identificado no QR Code'));
});
test('primeiro QR define cabeçalho vazio e respeita cabeçalho parcial sem sobrescrever',()=>{
 const qr=parseQR('180$BMA0013539$025024$031133$1,00$21117$1');
 for(const header of [{project:'',station:''},{project:'025024',station:''},{project:'',station:'031133'}])assert.deepEqual(resolveItemDestination({...doc(),...header},qr),{project:'025024',station:'031133'});
 assert.throws(()=>resolveItemDestination({...doc(),station:''},item('OUTRO','1')),/Peça não pertence/);
});
test('BMA simples herda referência ou exige os campos faltantes na primeira inclusão',()=>{
 const simple=parseQR('BMA0013539');assert.deepEqual(resolveItemDestination(doc(),simple),{project:'025024',station:'031133'});
 assert.throws(()=>resolveItemDestination({...doc(),project:'',station:''},simple),/Preencha/);
 assert.deepEqual(resolveItemDestination({...doc(),project:'',station:''},simple,{allowMissing:true}),{project:'',station:''});
});
test('bloqueia mudar cabeçalho e reescrever todos os itens juntos; zerar itens permite redefinir',()=>{
 const previous={...doc(),items:[item()]};
 for(const key of ['project','station']){const next=structuredClone(previous);next[key]='NOVO';next.items[0][key]='NOVO';assert.throws(()=>validateDestinationSave(previous,next),/não podem ser alterados/);}
 assert.equal(validateDestinationSave(previous,{...doc(),project:'NOVO',station:'NOVA',items:[]}),true);
 assert.throws(()=>validateDestinationSave(doc(),{...doc(),project:'NOVO',items:[item('NOVO')]}),/não podem ser alterados/);
});
test('quantidade, pedido e remanejamento permanecem permitidos em todas as caixas',()=>{
 const previous={...doc(),items:[item()]},next=structuredClone(previous);Object.assign(next.items[0],{qty:2,purchase_order:'21117',purchase_order_item:'1',box:'b2'});
 assert.equal(validateDestinationSave(previous,next),true);
 next.items.push({...item('025024','031133','b1'),id:'outro'});assert.equal(validateManifest(next),true);
 next.items[1].station='OUTRA';assert.throws(()=>validateManifest(next),/Peça não pertence/);
});
test('rascunho legado inconsistente é sinalizado, não pode incluir ou confirmar e não é reescrito',()=>{
 const previous={...doc(),items:[item('DIFERENTE')]},before=JSON.stringify(previous);
 assert.equal(destinationIssues(previous).length,1);assert.throws(()=>validateManifest(previous),/Peça não pertence/);
 const next={...doc(),items:[item(),{...item(),id:'novo'}]};assert.throws(()=>validateDestinationSave(previous,next),/regularização/);
 assert.equal(JSON.stringify(previous),before);
});
