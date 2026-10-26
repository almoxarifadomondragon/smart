import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
import {confirmReviewedDocument,confirmationFailure} from '../public/administration.js';

function harness(){
 const calls=[],confirm={disabled:false},page={append(p){this.panel=p;}},panels=[];
 class Panel {
  constructor(){this.controls={};this.inputs=[];panels.push(this);}
  set innerHTML(html){this.html=html;this.inputs=[...html.matchAll(/data-additional="(\d+)"[^>]*value="([^"]*)"/g)].map(m=>({value:m[2]}));this.controls={};}
  querySelector(s){if(s==='[name="exception"]')return null;if(s==='[name="reason"]')return {value:''};return this.controls[s]||=( {} );}
  querySelectorAll(s){if(s==='[data-additional]')return this.inputs;if(s==='[data-remove-additional]')return this.inputs.map((_,i)=>({dataset:{removeAdditional:String(i)}}));return [];}
  get isConnected(){return page.panel===this;}
 }
 const api={previewRecipients:(id,additional,reason)=>new Promise((resolve,reject)=>calls.push({id,additional:[...additional],reason,resolve,reject}))};
 const source=fs.readFileSync(new URL('../public/administration.js',import.meta.url),'utf8').replace("import * as api from './api.js';",'').replaceAll('export ','');
 const context={api,document:{createElement:()=>new Panel(),querySelector:s=>s==='#page'?page:s==='[data-action="confirm"]'?confirm:null},console,structuredClone};
 vm.runInNewContext(source+'\nthis.review=reviewRecipients;this.approval=recipientApproval;',context);
 const doc={id:'race',project:'P'},ctx={demo:false,admin:false,recipients:[],managers:[]};
 const start=options=>context.review(doc,ctx,options);
 return {calls,confirm,page,doc,ctx,start,approval:()=>context.approval(doc)};
}
const tick=()=>new Promise(resolve=>setImmediate(resolve));
const snapshot=(fingerprint,emails=[])=>({fingerprint,emails,roles:[]});

test('conferência demonstração lista todos os fixos, gestor e adicionais sem duplicar entre áreas',async()=>{
 const h=harness();h.ctx.demo=true;h.ctx.recipients=[{role:'PCP',email:'p1@example.com'},{role:'PCP',email:'p2@example.com'},{role:'Almoxarifado',email:'a1@example.com'},{role:'Almoxarifado',email:'a2@example.com'}];h.ctx.managers=[{project_code:'P',active:true,email:'g@example.com'}];
 await h.start();for(const r of h.ctx.recipients)assert.ok(h.page.panel.html.includes(r.email));assert.equal(h.approval().emails.length,5);
 h.page.panel.querySelector('[data-add-recipient]').onclick();h.page.panel.inputs[0].value='extra@example.com';await h.page.panel.querySelector('[data-check-recipients]').onclick();assert.equal(h.approval().emails.length,6);
 h.ctx.recipients.push({role:'Almoxarifado',email:'p1@example.com'});await h.start();assert.equal(h.approval().emails.length,6);
});

test('uma resposta antiga não aprova dados editados durante a conferência',async()=>{
 const h=harness(),initial=h.start();
 h.page.panel.querySelector('[data-add-recipient]').onclick();
 h.page.panel.inputs[0].value='extra@example.com';h.page.panel.oninput();
 const latest=h.page.panel.querySelector('[data-check-recipients]').onclick();
 assert.equal(h.calls.length,2);
 h.calls[0].resolve(snapshot('anterior'));await initial;
 assert.throws(h.approval,/Confira/);assert.equal(h.confirm.disabled,true);
 h.calls[1].resolve(snapshot('atual',['extra@example.com']));await latest;await tick();
 assert.equal(h.approval().fingerprint,'atual');
 assert.deepEqual([...h.approval().additional],['extra@example.com']);
});

test('editar durante uma única requisição invalida a aprovação até conferir novamente',async()=>{
 const h=harness(),initial=h.start();h.page.panel.querySelector('[data-add-recipient]').onclick();
 h.page.panel.inputs[0].value='novo@example.com';h.page.panel.oninput();
 h.calls[0].resolve(snapshot('velho'));await initial;
 assert.throws(h.approval,/Confira/);assert.equal(h.confirm.disabled,true);
});

test('aprovação guarda cópia do payload e ignora resposta fora de ordem',async()=>{
 const h=harness(),initial=h.start();
 const latest=h.page.panel.querySelector('[data-check-recipients]').onclick();
 h.calls[1].resolve(snapshot('mais-recente',['a@example.com']));await latest;
 h.calls[0].resolve(snapshot('antigo'));await initial;
 const approval=h.approval();assert.equal(approval.fingerprint,'mais-recente');assert.equal(approval.reason,null);
 approval.additional.push('intruso@example.com');approval.emails.push('outro@example.com');
 assert.equal(h.approval().additional.length,0);assert.equal(h.approval().emails.length,1);
});

test('divergência exige nova conferência explícita e não reaproveita aprovação',async()=>{
 const h=harness(),initial=h.start();h.calls[0].resolve(snapshot('primeiro'));await initial;
 await h.start({requireApproval:true,message:'Cadastro atualizado. Confira novamente.'});
 assert.equal(h.calls.length,1);assert.throws(h.approval,/Confira/);assert.equal(h.confirm.disabled,true);
 const checked=h.page.panel.querySelector('[data-check-recipients]').onclick();
 h.calls[1].resolve(snapshot('segundo'));await checked;assert.equal(h.approval().fingerprint,'segundo');
});

test('confirmação atualiza documento e interface antes de chamar o envio',async()=>{
 const doc={id:'d',status:'draft'},events=[];
 await confirmReviewedDocument(doc,{fingerprint:'ok'},{finalize:async()=>{events.push('confirmar');return {id:'d',status:'confirmed'};},confirmed:()=>{assert.equal(doc.status,'confirmed');events.push('interface');},send:async d=>{assert.equal(d.status,'confirmed');events.push('enviar');}});
 assert.deepEqual(events,['confirmar','interface','enviar']);
});

test('confirmação rejeitada ou resposta inválida não altera status nem dispara e-mail',async()=>{
 for(const finalize of [async()=>{throw Object.assign(new Error('Cadastro alterado'),{code:'P4091'});},async()=>({id:'d',status:'draft'})]){
  const doc={id:'d',status:'draft'};let effects=0;
  await assert.rejects(()=>confirmReviewedDocument(doc,{}, {finalize,confirmed:()=>effects++,send:()=>effects++}));
  assert.equal(doc.status,'draft');assert.equal(effects,0);
 }
});

test('mensagens distinguem alteração de destinatários, cadastro pendente e falha técnica',()=>{
 assert.equal(confirmationFailure({code:'P4091'}).kind,'changed');
 assert.equal(confirmationFailure({code:'P4221',message:'Gestor ausente'}).kind,'registry');
 assert.equal(confirmationFailure(new Error('Sem rede')).kind,'technical');
});
