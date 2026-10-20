import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
import {boxLink,boxRoute} from '../public/labels.js';
const read=p=>fs.readFileSync(new URL('../'+p,import.meta.url),'utf8');

test('migração: configuração e recursos relativos apontam para destino oficial',()=>{
 const api=read('public/api.js');
 assert.ok(api.includes('https://qrcpprvxjgcnlxyushsg.supabase.co'));
 assert.ok(api.includes('sb_publishable_r2eHPLJGxh7BDzq-kb1xSQ_uoWHRevl'));
 for(const p of ['public/api.js','public/app.js','public/index.html','public/labels.js']) {
  const text=read(p);assert.ok(!text.includes('skawydzwuroolpybrngl'));assert.ok(!text.includes('engdenysmartinez.github.io'));
  assert.ok(!/\b(?:src|href)=["']\/(?!\/)/.test(text));
 }
 const uuid='11111111-1111-4111-8111-111111111111';
 const url=new URL(boxLink('https://almoxarifadomondragon.github.io/smart/',uuid,uuid));
 assert.equal(url.pathname,'/smart/');assert.equal(boxRoute(url.hash).boxId,uuid);
});

test('migração: login exige vínculo app_members e não usa perfil editável como responsável',async()=>{
 const requests=[];
 const context={fetch:async(url)=>{requests.push(url);return Response.json([]);},Response};
 vm.runInNewContext(read('public/api.js').replaceAll('export ','')+'\nglobalThis.api={getMembership};',context);
 await assert.rejects(context.api.getMembership('user-id'),/Usuário não autorizado/);
 assert.match(requests[0],/app_members\?select=user_id,full_name,role/);
});

test('migração: caixa de rascunho abre sem tentar vincular formulário ausente',()=>{
 const elements={'#login-form':{},'#demo-login':{},'#app':{innerHTML:''},'#modal':{addEventListener(){}},'#toast':{classList:{add(){},remove(){}}}};
 const context={document:{querySelector:key=>elements[key]||null,addEventListener(){}},window:{addEventListener(){}},location:{hash:''},clearTimeout(){},setTimeout(){},console,boxDetails:()=>({number:'01/01',box:{name:'Caixa 01'},items:[],project:'25024',station:'31133'}),totalQty:()=>0,formatQty:()=> '0,00',pad:n=>String(n).padStart(6,'0')};
 vm.runInNewContext(read('public/app.js').replace(/^import .*;\r?\n/gm,''),context);
 vm.runInNewContext("user={id:'operator'};membership={full_name:'Nome autorizado',role:'operator'};docs=[{id:'doc',number:147,status:'draft',boxes:[{id:'box',name:'Caixa 01'}],items:[],responsible:'Nome autorizado'}];current='doc';selectedBox='box';render();",context);
 assert.match(elements['#app'].innerHTML,/Conteúdo desta caixa/);
 assert.match(elements['#app'].innerHTML,/Nome autorizado/);
});
