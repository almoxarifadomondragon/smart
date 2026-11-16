import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
import {stripTypeScriptTypes} from 'node:module';
import {deliveryReceiptView,deliveryStatusView} from '../public/warehouse.js';

const source=stripTypeScriptTypes(fs.readFileSync(new URL('../supabase/functions/send-box-delivery/index.ts',import.meta.url),'utf8')
 .replace(/^import nodemailer.*\r?\n/,''));
const id='12345678-1234-1234-1234-123456789abc';
const time='2026-11-16T14:00:00Z';
const snapshot={
 box:{id,code:'CX-000015',name:'<Caixa>',project:'0001',station:'02',status:'closed'},
 documents:[{number:31,responsible:'Operadora',confirmed_at:time,item_count:1,total_units:2},
  {number:38,responsible:'Operador',confirmed_at:time,item_count:1,total_units:3}],
 items:[{code:'BMA0013539',qty:2,invoice_number:'00023/A',scanned_at:time,document_number:31,operator:'Operadora'},
  {code:'BMA0013539',qty:3,invoice_number:'00024/B',scanned_at:time,document_number:38,operator:'Operador'}],
 total_units:5
};
const delivery={closed_at:time,closed_by_name:'Operador <teste>',snapshot,
 recipient_snapshot:{emails:['pcp@example.invalid','almox@example.invalid','gestor@example.invalid']}};

async function invoke({body={id},authorization='Bearer session',active=true,claim,code,rejected=[],finishStatus=204}={}){
 let handler,mail,finish;
 const env={SUPABASE_URL:'https://test.invalid',SUPABASE_SERVICE_ROLE_KEY:'service-key',
  GMAIL_USER:'sender@gmail.com',GMAIL_APP_PASSWORD:'app password'};
 vm.runInNewContext(source,{
  Deno:{env:{get:key=>env[key]},serve:fn=>handler=fn},Response,
  nodemailer:{createTransport:()=>({close(){},sendMail:async message=>{
   mail=message;
   if(code)throw {code};
   return {accepted:delivery.recipient_snapshot.emails.filter(email=>!rejected.includes(email)),rejected,messageId:message.messageId};
  }})},
  fetch:async (url,init)=>{
   if(url.endsWith('/user')){
    assert.equal(init.headers.Authorization,authorization);
    return Response.json({id:'verified-user'});
   }
   assert.equal(init.headers.Authorization,'Bearer service-key');
   const payload=JSON.parse(init.body);
   if(url.endsWith('/claim_box_delivery_email')){
    assert.deepEqual(payload,{p_id:id,p_actor:'verified-user'});
    return active?Response.json(claim??{token:'reservation',delivery}):Response.json({code:'42501'},{status:403});
   }
   assert.ok(url.endsWith('/finish_box_delivery_email'));
   assert.equal(payload.p_token,'reservation');
   finish=payload;
   return new Response(null,{status:finishStatus});
  }
 });
 const result=await handler(new Request('https://test.invalid',{method:'POST',headers:{Authorization:authorization},body:JSON.stringify(body)}));
 return {status:result.status,data:await result.json(),mail,finish};
}

test('Entrega envia a cópia congelada e mantém as duas origens do mesmo BMA',async()=>{
 const {data,mail,finish}=await invoke();
 assert.equal(data.state,'sent');
 assert.equal(finish.p_state,'sent');
 assert.deepEqual(Array.from(mail.to, recipient=>recipient.address),delivery.recipient_snapshot.emails);
 assert.match(mail.subject,/CX-000015 \| Projeto 0001/);
 assert.equal((mail.html.match(/BMA0013539/g)||[]).length,2);
 for(const value of ['00023/A','00024/B','#000031','#000038','&lt;Caixa&gt;','#caixa_fisica='+id])assert.ok(mail.html.includes(value));
});

test('Entrega rejeita conteúdo do cliente e bloqueia chamadas sem autorização ou reserva',async()=>{
 assert.equal((await invoke({authorization:''})).status,401);
 assert.equal((await invoke({body:{id,to:['intruso@example.invalid']}})).status,400);
 assert.equal((await invoke({active:false})).status,403);
 for(const state of ['sending','uncertain','sent']){
  const result=await invoke({claim:{state}});
  assert.equal(result.data.state,state);
  assert.equal(result.mail,undefined);
 }
});

test('Falha de autenticação é recuperável, timeout e envio parcial exigem reconciliação',async()=>{
 assert.equal((await invoke({code:'EAUTH'})).finish.p_state,'failed');
 assert.equal((await invoke({code:'ETIMEDOUT'})).finish.p_state,'uncertain');
 assert.equal((await invoke({rejected:['gestor@example.invalid']})).finish.p_state,'uncertain');
 const unrecorded=await invoke({finishStatus:503});
 assert.equal(unrecorded.status,500);
 assert.notEqual(unrecorded.data.state,'sent');
});

test('Comprovante mantém origem e NF; histórico antigo e envio incerto têm ações distintas',()=>{
 const receipt=deliveryReceiptView(delivery);
 assert.match(receipt,/Comprovante de entrega à Produção/);
 for(const value of ['#000031','#000038','00023/A','00024/B','Operador &lt;teste&gt;'])assert.ok(receipt.includes(value));
 assert.doesNotMatch(receipt,/data-action|Histórico de materiais/);
 const uncertain={...delivery,email_state:'uncertain'};
 assert.doesNotMatch(deliveryStatusView(uncertain),/physical-send|physical-reconcile/);
 assert.match(deliveryStatusView(uncertain,{admin:true}),/physical-reconcile/);
 assert.match(deliveryStatusView(null),/histórico não possui comprovante/);
});
