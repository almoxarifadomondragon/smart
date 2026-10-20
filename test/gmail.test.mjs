import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
import {stripTypeScriptTypes} from 'node:module';

const source=stripTypeScriptTypes(fs.readFileSync(new URL('../supabase/functions/send-manifest/index.ts',import.meta.url),'utf8').replace(/^import nodemailer.*\n/,''));
const id='12345678-1234-1234-1234-123456789abc';
async function run(body,options={}) {
 let handler,config,mail,patch,verified=false;
 const env={SUPABASE_URL:'https://test.invalid',SUPABASE_SERVICE_ROLE_KEY:'test',GMAIL_USER:'sender@gmail.com',GMAIL_APP_PASSWORD:'test password',...options.env};
 const doc={id,owner_id:'user',status:'confirmed',email_status:'pending',number:147,project:'<Projeto>',station:'1',responsible:'Teste',confirmed_at:new Date().toISOString(),items:[],boxes:[],email_recipients:['recipient@example.com','recipient@example.com','recipient@example.com'],...options.doc};
 const transport={verify:async()=>{verified=true;if(options.smtpError)throw options.smtpError;},sendMail:async m=>{mail=m;if(options.smtpError)throw options.smtpError;return {messageId:m.messageId,rejected:[]};},close(){}};
 vm.runInNewContext(source,{Deno:{env:{get:k=>env[k]},serve:f=>handler=f},nodemailer:{createTransport:c=>{config=c;return transport;}},Response,fetch:async(url,init)=>{
  if(url.includes('/auth/'))return Response.json({id:'user'});
  if(url.includes('app_members'))return Response.json([{role:options.role||'admin'}]);
  if(init.method==='PATCH'){patch=JSON.parse(init.body);return new Response(null,{status:options.patchFailure?500:204});}
  return Response.json([doc]);
 }});
 const response=await handler(new Request('https://test.invalid',{method:'POST',headers:options.noAuth?{}:{Authorization:'Bearer test'},body:JSON.stringify(body)}));
 return {status:response.status,data:await response.json(),config,mail,patch,verified};
}
test('Gmail: verificação autenticada usa TLS 465 e não envia mensagem',async()=>{
 const r=await run({action:'verify'});assert.equal(r.status,200);assert.equal(r.verified,true);assert.equal(r.mail,undefined);assert.equal(r.config.port,465);assert.equal(r.config.secure,true);assert.equal(r.config.tls.rejectUnauthorized,true);
});
test('Gmail: diagnóstico exige administrador e credenciais',async()=>{
 assert.equal((await run({action:'verify'},{noAuth:true})).status,401);
 assert.equal((await run({action:'verify'},{role:'operator'})).status,403);
 assert.equal((await run({action:'verify'},{env:{GMAIL_APP_PASSWORD:''}})).status,503);
});
test('Gmail: preserva autorização, confirmação e evita reenvio de sent',async()=>{
 assert.equal((await run({id},{doc:{owner_id:'other'}})).status,403);
 assert.equal((await run({id},{doc:{status:'draft'}})).status,409);
 const r=await run({id},{doc:{email_status:'sent'}});assert.equal(r.status,200);assert.equal(r.mail,undefined);
});
test('Gmail: remetente autenticado, destinatários do banco e status após aceite',async()=>{
 const r=await run({id,to:['attacker@example.com']});assert.equal(r.status,200);assert.equal(r.mail.from.address,'sender@gmail.com');assert.deepEqual(Array.from(r.mail.to),['recipient@example.com']);assert.equal(r.patch.email_status,'sent');assert.ok(r.mail.html.includes('&lt;Projeto&gt;'));
});
test('Gmail: falhas não registram sucesso nem expõem resposta secreta',async()=>{
 const r=await run({id},{smtpError:{code:'EAUTH',message:'secret'}});assert.equal(r.status,502);assert.equal(r.patch,undefined);assert.ok(!r.data.message.includes('secret'));
 const uncertain=await run({id},{patchFailure:true});assert.equal(uncertain.status,502);assert.match(uncertain.data.message,/Confira Enviados/);
});
