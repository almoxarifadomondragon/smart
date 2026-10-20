import nodemailer from 'npm:nodemailer@10.0.14';
// The handler validates every JWT with Supabase Auth and enforces document RLS.
const url = Deno.env.get('SUPABASE_URL')!;
const key = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const cors = {'Access-Control-Allow-Origin':Deno.env.get('APP_ORIGIN') || 'https://almoxarifadomondragon.github.io','Access-Control-Allow-Headers':'authorization, apikey, content-type','Access-Control-Allow-Methods':'POST, OPTIONS'};
const escapeHtml = (v: unknown) => String(v??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]!));
const result = (data: unknown,status=200) => Response.json(data,{status,headers:cors});
function gmailTransport() {
 const user=(Deno.env.get('GMAIL_USER')||'').trim();
 const pass=(Deno.env.get('GMAIL_APP_PASSWORD')||'').replace(/\s/g,'');
 if(!/^[A-Z0-9._%+-]+@gmail\.com$/i.test(user)||!pass) return null;
 return {user, transport:nodemailer.createTransport({
  host:'smtp.gmail.com',port:465,secure:true,
  auth:{user,pass},tls:{minVersion:'TLSv1.2',rejectUnauthorized:true},
  connectionTimeout:15000,greetingTimeout:15000,socketTimeout:30000,
  logger:false,debug:false,disableFileAccess:true,disableUrlAccess:true
 })};
}
function gmailError(error: any) {
 if(error?.code==='EAUTH')return 'Gmail recusou a autenticação. Confira GMAIL_USER e a senha de aplicativo em GMAIL_APP_PASSWORD.';
 if(['ETIMEDOUT','ESOCKET','ECONNECTION','EDNS'].includes(error?.code))return 'Não foi possível concluir a conexão segura com smtp.gmail.com:465. Se ocorreu durante o envio, confira Enviados no Gmail antes de tentar novamente.';
 return 'Gmail não confirmou o envio. Confira Enviados no Gmail antes de tentar novamente.';
}
Deno.serve(async req => {
 if(req.method==='OPTIONS') return new Response('ok',{headers:cors});
 if(req.method!=='POST')return result({message:'Método inválido'},405);
 try {
  const authorization=req.headers.get('Authorization')||'';
  if(!authorization.startsWith('Bearer '))return result({message:'Login necessário'},401);
  const auth=await fetch(url+'/auth/v1/user',{headers:{apikey:key,Authorization:authorization}});
  if(!auth.ok)return result({message:'Sessão inválida ou expirada'},401);
  const user=await auth.json();
  const {id,action}=await req.json();
  if(action==='verify') {
   const membership=await fetch(url+'/rest/v1/app_members?select=role&user_id=eq.'+user.id,{headers:{apikey:key,Authorization:authorization}});
   if(!membership.ok)return result({message:'Acesso negado'},403);
   const members=await membership.json();
   if(members[0]?.role!=='admin')return result({message:'Somente administradores podem testar a conexão.'},403);
   const gmail=gmailTransport();
   if(!gmail)return result({message:'Configure GMAIL_USER e GMAIL_APP_PASSWORD nos segredos do Supabase.'},503);
   try {await gmail.transport.verify();return result({verified:true,message:'Conexão com Gmail autenticada. Nenhum e-mail foi enviado.'});}
   catch(error){return result({message:gmailError(error)},502);}
   finally{gmail.transport.close();}
  }
  if(typeof id!=='string'||!/^[0-9a-f-]{36}$/i.test(id))return result({message:'ID inválido'},400);
  // Use caller's JWT for RLS and membership checks, never trust the client payload.
  const response=await fetch(url+`/rest/v1/picking_documents?id=eq.${id}&select=*`,{headers:{apikey:key,Authorization:authorization}});
  if(!response.ok)return result({message:'Acesso negado'},403);
  const [doc]=await response.json();
  if(!doc||doc.owner_id!==user.id)return result({message:'Romaneio não encontrado ou sem permissão'},403);
  if(doc.status!=='confirmed')return result({message:'Confirme o romaneio primeiro'},409);
  if(doc.email_status==='sent')return result({sent:true});
  const gmail=gmailTransport();
  if(!gmail)return result({message:'Configure GMAIL_USER e GMAIL_APP_PASSWORD nos segredos do Supabase.'},503);
  if(!Array.isArray(doc.email_recipients)||doc.email_recipients.length!==3)return result({message:'Destinatários não cadastrados'},409);
  const number=String(doc.number).padStart(6,'0');
  const time=(v:string)=>new Date(v).toLocaleString('pt-BR',{timeZone:'America/Sao_Paulo'});
  const html=`<div style="font-family:Arial,sans-serif;color:#282d36;max-width:900px"><h2 style="color:#cc2631">MONDRAGON ASSEMBLY</h2><h1>Romaneio digital #${number}</h1><p>Projeto: ${escapeHtml(doc.project)}<br>Estação: ${escapeHtml(doc.station)}<br>Responsável: ${escapeHtml(doc.responsible)}<br>Confirmado em: ${time(doc.confirmed_at)}<br>Itens: ${doc.items.length} · Caixas: ${doc.boxes.length}</p>${doc.boxes.map((box:any,index:number)=>`<h3>${escapeHtml(box.name)} · Caixa ${index+1}/${doc.boxes.length}</h3><table border="1" cellpadding="9" cellspacing="0" style="border-collapse:collapse;border-color:#eee"><thead><tr><th>BMA</th><th>Projeto</th><th>Estação</th><th>Qtd.</th><th>Pedido</th><th>Item do pedido</th><th>Leitura</th><th>Almoxarife</th></tr></thead><tbody>${doc.items.filter((item:any)=>item.box===box.id).map((item:any)=>`<tr><td>${escapeHtml(item.code)}</td><td>${escapeHtml(item.project)}</td><td>${escapeHtml(item.station)}</td><td>${Number(item.qty).toLocaleString('pt-BR',{minimumFractionDigits:2,maximumFractionDigits:2})}</td><td>${escapeHtml(item.purchase_order||'—')}</td><td>${escapeHtml(item.purchase_order_item||'—')}</td><td>${time(item.scanned_at)}</td><td>${escapeHtml(item.operator)}</td></tr>`).join('')}</tbody></table>`).join('')}<p style="color:#888;font-size:12px">Registro gerado pelo Almoxarifado Digital Mondragon.</p></div>`;
  let info;
  try {
   info=await gmail.transport.sendMail({from:{name:'Mondragon',address:gmail.user},to:[...new Set(doc.email_recipients)],subject:`Romaneio #${number} — ${doc.project}`,html,messageId:`<romaneio-${id}@gmail.com>`});
  }catch(error){return result({message:gmailError(error)},502);}
  finally{gmail.transport.close();}
  if(info.rejected?.length)return result({message:'Gmail recusou parte dos destinatários. Confira Enviados antes de repetir o envio.'},502);
  const updated=await fetch(url+`/rest/v1/picking_documents?id=eq.${id}`,{method:'PATCH',headers:{apikey:key,Authorization:`Bearer ${key}`,'Content-Type':'application/json'},body:JSON.stringify({email_status:'sent',email_provider_id:info.messageId})});
  if(!updated.ok)return result({message:'E-mail aceito pelo Gmail, mas o status não pôde ser atualizado. Confira Enviados antes de tentar novamente.'},502);
  return result({sent:true});
 }catch{return result({message:'Falha ao processar o envio. Tente novamente.'},500);}
});
