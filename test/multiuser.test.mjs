import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
import * as access from '../public/picking-access.js';
import * as domain from '../public/domain.js';
import {boxDetails,boxRoute} from '../public/labels.js';
const doc=(id,owner,number)=>({id,owner_id:owner,number,status:'draft',project:'25024',station:'31133',responsible:'Operador '+owner,created_at:'2026-10-26T12:00:00Z',boxes:[{id:'box-'+id,name:'Caixa 01'}],items:[]});
function app(actor,server){
 const calls=[],elements={'#app':{innerHTML:''},'#modal':{open:false,addEventListener(){},querySelector(){return null;}},'#toast':{classList:{add(){},remove(){}}},'#login-form':{},'#email':{value:actor},'#password':{value:'test-only'},'#scan-form':{},'#project':{},'#station':{},'#login-error':{}};
 elements['#login-form'].querySelector=()=>({});elements['#modal'].showModal=function(){this.open=true;};elements['#modal'].close=function(){this.open=false;};
 Object.assign(elements,{'#new-form':{},'#new-project':{value:'25024'},'#new-station':{value:'31133'},'#scan-code':{focus(){}}});
 const api={setSession(){},login:async()=>({user:{id:actor}}),getMembership:async()=>({full_name:'Operador '+actor,role:'operator'}),getManagers:async()=>[],getRecipients:async()=>[],listDocuments:async()=>structuredClone([...server.values()]),getDocument:async id=>{calls.push(id);return structuredClone(server.get(id));},saveDocument:async d=>{access.assertEditable(server.get(d.id),actor);server.set(d.id,structuredClone(d));return structuredClone(d);}};
 api.createDocument=async(project,station)=>{const next=doc('new-'+actor,actor,Math.max(...[...server.values()].map(d=>d.number))+1);Object.assign(next,{project,station});server.set(next.id,structuredClone(next));return next;};
 const context={...access,...domain,boxDetails,boxRoute,api,document:{body:{setAttribute(){},removeAttribute(){}},querySelector:s=>elements[s]||null,addEventListener(){}},window:{addEventListener(){}},location:{hash:''},clearTimeout(){},setTimeout(){},console,structuredClone};
 vm.runInNewContext(fs.readFileSync(new URL('../public/app.js',import.meta.url),'utf8').replace(/^import .*;\r?\n/gm,''),context);
 return {elements,calls,context,run:code=>vm.runInNewContext(code,context),login:()=>elements['#login-form'].onsubmit({preventDefault(){},target:elements['#login-form']})};
}

test('B autentica sem selecionar rascunho de A; seleciona somente rascunho próprio',async()=>{
 const a=doc('a','A',170),b=doc('b','B',171),server=new Map([['a',a]]),client=app('B',server);
 await client.login();assert.equal(client.run('current'),undefined);assert.match(client.elements['#app'].innerHTML,/Iniciar separação/);
 server.set('b',b);await client.login();assert.equal(client.run('current'),'b');assert.ok(client.calls.includes('b'));
 assert.equal(access.ownDraft([a,{...b,status:'confirmed'}],'B'),undefined);
});

test('B consulta A somente para leitura: caixas/peças presentes e nenhuma mutação disponível',async()=>{
 const a=doc('a','A',170);a.items=[{id:'i',code:'BMA0000001',project:a.project,station:a.station,qty:1,box:a.boxes[0].id,scanned_at:a.created_at,operator:'Operador A'}];
 const client=app('B',new Map([['a',a]]));await client.login();await client.run("openDocument('a')");
 const html=client.elements['#app'].innerHTML;
 for(const text of ['Somente leitura','Operador A','BMA0000001','Caixa 01','Voltar às minhas separações'])assert.ok(html.includes(text),text);
 for(const text of ['id="scan-form"','data-action="edit-item"','data-action="delete-item"','data-action="add-box"','data-action="edit-box"','data-action="confirm"','data-action="review"'])assert.ok(!html.includes(text),text);
 await assert.rejects(()=>client.run("editableDocument('a')"),/outro almoxarife/);
});

test('B inicia nova separação independente mesmo com A em andamento',async()=>{
 const a=doc('a','A',170),server=new Map([['a',a]]),client=app('B',server);await client.login();
 client.run("newModal();document.querySelector('#new-form').onsubmit({preventDefault(){}})");
 await new Promise(resolve=>setImmediate(resolve));
 assert.equal(client.run('getDoc().owner_id'),'B');assert.equal(client.run('getDoc().number'),171);assert.notEqual(client.run('current'),'a');assert.deepEqual(server.get('a'),a);
});

test('abrir novamente busca o servidor e confirmação remota bloqueia novas operações',async()=>{
 const b=doc('b','B',171),server=new Map([['b',b]]),client=app('B',server);await client.login();
 server.set('b',{...b,station:'ATUALIZADA'});await client.run("openDocument('b')");assert.equal(client.run('getDoc().station'),'ATUALIZADA');
 const stale=client.run('getDoc()');
 server.set('b',{...b,status:'confirmed',confirmed_at:b.created_at});
 await assert.rejects(()=>client.run("editableDocument('b')"),/já foi confirmado/);
 stale.status='draft'; // rollback local de uma edição rejeitada não deve restaurar cache antigo.
 assert.equal(client.run('getDoc().status'),'confirmed');assert.ok(!client.elements['#app'].innerHTML.includes('id="scan-form"'));
});

test('modal recebe erro acessível e mantém campos preenchidos; erro de propriedade é específico',()=>{
 const entered={code:'BMA0013539',qty:'2,00'},alerts=[];
 const modal={open:true,querySelector:()=>alerts[0]||null,prepend:e=>alerts.unshift(e),entered};
 const document={querySelector:()=>modal,createElement:()=>({dataset:{},setAttribute(k,v){this[k]=v;},focus(){this.focused=true;},scrollIntoView(){}})};
 assert.equal(access.showOperationError(document,'Esta separação pertence a outro usuário.'),true);
 assert.equal(alerts[0].role,'alert');assert.equal(alerts[0].textContent,access.ownershipMessage);assert.equal(alerts[0].focused,true);
 assert.deepEqual(modal.entered,{code:'BMA0013539',qty:'2,00'});
 access.showOperationError(document,'Quantidade inválida.');assert.equal(alerts.length,1);assert.equal(alerts[0].textContent,'Quantidade inválida.');
 modal.open=false;assert.equal(access.showOperationError(document,'Falha'),false);
});

test('A e B trabalham em documentos separados; persistência de B não altera A',async()=>{
 const a=doc('a','A',170),b=doc('b','B',171),server=new Map([['a',a],['b',b]]),A=app('A',server),B=app('B',server);
 await A.login();await B.login();assert.equal(A.run('current'),'a');assert.equal(B.run('current'),'b');
 await B.run("getDoc().items.push({id:'b-item',code:'BMA0000002',qty:1,box:'box-b'});persist(getDoc())");
 assert.equal(server.get('a').items.length,0);assert.equal(server.get('b').items.length,1);
 await A.run("getDoc().items.push({id:'a-item',code:'BMA0000001',qty:1,box:'box-a'});persist(getDoc())");
 assert.equal(server.get('a').items.length,1);assert.equal(server.get('b').items.length,1);
});

