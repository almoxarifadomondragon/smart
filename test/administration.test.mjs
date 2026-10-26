import test from 'node:test';
import assert from 'node:assert/strict';
import {normalizeEmails,normalizeProject,settingsView,normalizeFixedRecipients,EFFECTIVE_RECIPIENT_LIMIT} from '../public/administration.js';
import fs from 'node:fs';
import vm from 'node:vm';
import {stripTypeScriptTypes} from 'node:module';
test('projetos: correspondência exata normalizada mantém zeros à esquerda',()=>{
 assert.equal(normalizeProject(' 025024 '),'025024');assert.notEqual(normalizeProject('025024'),normalizeProject('25024'));
 assert.notEqual(normalizeProject('25024'),normalizeProject('250240'));
});
test('destinatários: valida e remove duplicidades sem distinguir maiúsculas',()=>{
 assert.deepEqual(normalizeEmails([' A@EXAMPLE.COM ','a@example.com','b@example.com']),['a@example.com','b@example.com']);
 for(const values of [[''],['a@@example.com'],['x y@example.com'],Array.from({length:31},(_,i)=>`${i}@example.com`)])assert.throws(()=>normalizeEmails(values));
});

test('fixos múltiplos: duas áreas, terceiro, edição e remoção sem duplicatas locais',()=>{
 const initial=[{role:'PCP',email:' P1@EXAMPLE.COM '},{role:'PCP',email:'p2@example.com'},{role:'Almoxarifado',email:'a1@example.com'},{role:'Almoxarifado',email:'a2@example.com'}];
 assert.equal(normalizeFixedRecipients(initial).length,4);
 const third=normalizeFixedRecipients([...initial,{role:'PCP',email:'p3@example.com'}]);assert.equal(third.length,5);assert.equal(third[0].email,'p1@example.com');
 const edited=third.map(r=>r.email==='p2@example.com'?{...r,email:'new@example.com'}:r);assert.ok(normalizeFixedRecipients(edited).some(r=>r.email==='new@example.com'));
 assert.equal(normalizeFixedRecipients(edited.filter(r=>r.email!=='p3@example.com')).length,4);
 for(const bad of [initial.filter(r=>r.role==='PCP'),[...initial,{role:'PCP',email:'p1@example.com'}],initial.map((r,i)=>i? r:{...r,email:'bad'}),initial.map((r,i)=>i? r:{...r,email:''}),[...initial,{role:'Gestor',email:'g@example.com'}]])assert.throws(()=>normalizeFixedRecipients(bad));
 const both=normalizeFixedRecipients([{role:'PCP',email:'same@example.com'},{role:'Almoxarifado',email:' SAME@EXAMPLE.COM '}]);assert.equal(both.length,2);assert.equal(normalizeEmails(both.map(r=>r.email)).length,1);
 const maximum=['PCP','Almoxarifado'].flatMap(role=>Array.from({length:30},(_,i)=>({role,email:`${role.toLowerCase()}${i}@example.com`})));assert.equal(normalizeFixedRecipients(maximum).length,60);
 assert.throws(()=>normalizeFixedRecipients([...maximum,{role:'PCP',email:'overflow@example.com'}]));assert.equal(EFFECTIVE_RECIPIENT_LIMIT,91);
});

test('fixos múltiplos: cada endereço tem campo e controles são exclusivos do administrador',()=>{
 const recipients=[{role:'PCP',email:'p1@example.com'},{role:'PCP',email:'p2@example.com'},{role:'Almoxarifado',email:'a1@example.com'},{role:'Almoxarifado',email:'a2@example.com'}];
 const admin=settingsView({admin:true,demo:true,recipients,managers:[]});assert.equal((admin.match(/data-fixed-email=/g)||[]).length,4);assert.equal((admin.match(/data-fixed-add=/g)||[]).length,2);assert.equal((admin.match(/data-fixed-remove=/g)||[]).length,4);
 const operator=settingsView({admin:false,demo:false,recipients,managers:[]});for(const r of recipients)assert.ok(operator.includes(r.email));assert.ok(!operator.includes('data-fixed-add='));assert.ok(!operator.includes('data-fixed-remove='));assert.ok(!operator.includes('Salvar destinatários'));assert.equal((operator.match(/required readonly/g)||[]).length,4);
});
test('usuários e controles administrativos são invisíveis ao operador; entradas são escapadas',()=>{
 const ctx={admin:false,demo:false,recipients:[],managers:[{id:'id',project_code:'<script>',email:'a@example.com',active:true}]};
 const operator=settingsView(ctx);assert.ok(!operator.includes('Usuários do Sistema'));assert.ok(!operator.includes('id="manager-form"'));assert.ok(operator.includes('&lt;script&gt;'));
 const admin=settingsView({...ctx,admin:true});assert.ok(admin.includes('Usuários do Sistema'));assert.ok(admin.includes('id="manager-form"'));
});
const source=stripTypeScriptTypes(fs.readFileSync(new URL('../supabase/functions/manage-users/index.ts',import.meta.url),'utf8'));
async function manage(body,options={}){
 let handler;const calls=[];
 const env={SUPABASE_URL:'https://test.invalid',SUPABASE_SERVICE_ROLE_KEY:'server-key'};
 vm.runInNewContext(source,{Deno:{env:{get:k=>env[k]},serve:f=>handler=f},Response,fetch:async(url,init={})=>{
  calls.push({url,body:init.body?JSON.parse(init.body):null,headers:init.headers});
  if(url.endsWith('/auth/v1/user'))return options.expired?new Response(null,{status:401}):Response.json({id:'actor'});
  if(url.includes('/app_members'))return Response.json(options.inactive?[]:[{role:options.role||'admin'}]);
  if(url.includes('/rpc/prepare_user_invite'))return Response.json({id:'request-id',email:'new@example.com',full_name:'Novo usuário',role:'operator'});
  if(url.includes('/auth/v1/invite?'))return options.authFailure?new Response('{}',{status:422}):Response.json({id:'new-user-id'});
  if(url.includes('/rpc/complete_user_invite'))return new Response(null,{status:options.linkFailure?500:204});
  if(url.includes('/rpc/admin_list_users'))return Response.json([]);
  return new Response(null,{status:204});
 }});
 const response=await handler(new Request('https://test.invalid',{method:'POST',headers:options.noAuth?{}:{Authorization:'Bearer real-session'},body:JSON.stringify(body)}));
 return {status:response.status,data:await response.json(),calls};
}
test('manage-users: exige sessão válida e administrador ativo',async()=>{
 assert.equal((await manage({action:'list'},{noAuth:true})).status,401);
 assert.equal((await manage({action:'list'},{expired:true})).status,401);
 for(const opts of [{role:'operator'},{inactive:true}]){const r=await manage({action:'invite'},opts);assert.equal(r.status,403);assert.ok(!r.calls.some(c=>c.url.includes('/invite?')));}
});
test('manage-users: convite cria identidade e vincula UUID com credencial apenas do servidor',async()=>{
 const r=await manage({action:'invite',email:'new@example.com',full_name:'Novo usuário',role:'operator'});
 assert.equal(r.status,200);const linked=r.calls.find(c=>c.url.includes('/complete_user_invite'));
 assert.deepEqual(linked.body,{p_request:'request-id',p_auth_id:'new-user-id'});
 assert.equal(linked.headers.Authorization,'Bearer server-key');assert.ok(!JSON.stringify(r.data).includes('server-key'));
});
test('manage-users: falha intermediária bloqueia identidade órfã e registra reconciliação, sem excluir Auth',async()=>{
 const r=await manage({action:'invite'},{linkFailure:true});assert.equal(r.status,409);
 assert.ok(r.calls.some(c=>c.url.includes('/admin/users/new-user-id')&&c.body.ban_duration));
 assert.ok(r.calls.some(c=>c.url.includes('/fail_user_invite')));
 const auth=await manage({action:'invite'},{authFailure:true});assert.equal(auth.status,409);assert.ok(!auth.calls.some(c=>c.url.includes('/complete_user_invite')));
});
