import nodemailer from 'npm:nodemailer@10.0.14';

const url = Deno.env.get('SUPABASE_URL')!;
const key = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const origin = 'https://almoxarifadomondragon.github.io';
const cors = {
 'Access-Control-Allow-Origin': Deno.env.get('APP_ORIGIN') || origin,
 'Access-Control-Allow-Headers': 'authorization, apikey, content-type',
 'Access-Control-Allow-Methods': 'POST, OPTIONS'
};
const respond = (data: unknown, status = 200) => Response.json(data, {status, headers: cors});
const escape = (value: unknown) => String(value ?? '—').replace(/[&<>"']/g,
 char => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[char]!));
const date = (value: string) => value ? new Date(value).toLocaleString('pt-BR', {timeZone:'America/Sao_Paulo'}) : '—';
const number = (value: number) => Number(value).toLocaleString('pt-BR', {maximumFractionDigits: 6});
const manifest = (value: number) => '#' + String(value).padStart(6, '0');
const table = (headers: string[], rows: unknown[][]) =>
 '<table cellpadding="7" border="1" style="border-collapse:collapse;border-color:#ddd"><thead><tr>' +
 headers.map(header => '<th>' + escape(header) + '</th>').join('') + '</tr></thead><tbody>' +
 rows.map(row => '<tr>' + row.map(value => '<td>' + escape(value) + '</td>').join('') + '</tr>').join('') +
 '</tbody></table>';

async function rpc(name: string, body: object) {
 return fetch(url + '/rest/v1/rpc/' + name, {
  method: 'POST',
  headers: {apikey:key, Authorization:'Bearer '+key, 'Content-Type':'application/json'},
  body: JSON.stringify(body)
 });
}

Deno.serve(async req => {
 if (req.method === 'OPTIONS') return new Response('ok', {headers:cors});
 if (req.method !== 'POST') return respond({message:'Método inválido.'},405);
 try {
  const authorization = req.headers.get('Authorization') || '';
  if (!authorization.startsWith('Bearer ')) return respond({message:'Login necessário.'},401);
  const auth = await fetch(url+'/auth/v1/user', {headers:{apikey:key,Authorization:authorization}});
  if (!auth.ok) return respond({message:'Sessão inválida ou expirada.'},401);
  const user = await auth.json();
  const body = await req.json().catch(() => null);
  const id = body?.id;
  const uuid = /^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i;
  const validId = (value: unknown) => typeof value === 'string' && uuid.test(value);
  const resend = body && Object.keys(body).length === 3 && validId(body.requestId) && validId(body.expectedAttempt);
  if (!validId(id) || (!resend && Object.keys(body).length !== 1)) {
   return respond({message:'Informe o ID da caixa e, para reenvio, a confirmação da tentativa anterior.'},400);
  }
  const claimResponse = await rpc('claim_box_delivery_email',{p_id:id,p_actor:user.id,
   ...(resend?{p_request:body.requestId,p_expected_attempt:body.expectedAttempt}:{})});
  if (!claimResponse.ok) {
   const error = await claimResponse.json().catch(() => ({}));
   return respond({message:error.code==='P4091'?'O envio mudou. Atualize a consulta e confirme novamente.':'Entrega indisponível ou usuário sem permissão.'},error.code==='42501'?403:409);
  }
  const claim = await claimResponse.json();
  if (!claim.token) return respond({state:claim.state});

  const finish = async (state: string, provider: string|null, code: string|null) => {
   const response = await rpc('finish_box_delivery_email',{
    p_id:id,p_token:claim.token,p_state:state,p_provider:provider,p_code:code
   });
   if (!response.ok) throw new Error('Falha ao registrar resultado SMTP.');
  };
  const sender = (Deno.env.get('GMAIL_USER') || '').trim();
  const pass = (Deno.env.get('GMAIL_APP_PASSWORD') || '').replace(/\s/g,'');
  if (!/^[A-Z0-9._%+-]+@gmail\.com$/i.test(sender) || !pass) {
   await finish('failed',null,'missing_configuration');
   return respond({state:'failed',message:'O Gmail não está configurado.'},503);
  }
  const {snapshot,recipient_snapshot,closed_at,closed_by_name,observations} = claim.delivery;
  const {box,documents,items,total_units} = snapshot;
  const documentsTable = table(['Romaneio','Responsável','Confirmação','Registros BMA','Unidades'],
   documents.map((doc: any) => [manifest(doc.number),doc.responsible,date(doc.confirmed_at),doc.item_count,number(doc.total_units)]));
  const itemsTable = table(['BMA','Qtd.','Nota Fiscal','Pedido','Item do pedido','Romaneio','Leitura','Almoxarife'],
   items.map((item: any) => [item.code,number(item.qty),item.invoice_number||'—',item.purchase_order||'—',
    item.purchase_order_item||'—',manifest(item.document_number),date(item.scanned_at),item.operator]));
  const link = origin + '/smart/#caixa_fisica=' + encodeURIComponent(id);
  const copyNotice = claim.is_copy ? '<p>Este e-mail é uma nova cópia do comprovante de entrega registrado anteriormente.</p>' : '';
  const notes = observations ? '<h2>Observações da entrega</h2><p style="white-space:pre-wrap">'+escape(observations).replace(/\n/g,'<br>')+'</p>' : '';
  const html = '<div style="font-family:Arial,sans-serif;color:#282d36">' +
   '<img width="180" src="'+origin+'/smart/logo.png" alt="Mondragon Assembly">' +
   '<h1 style="color:#cc2631">Confirmação de entrega de caixa à Produção</h1>' + copyNotice +
   '<p>'+escape(box.code)+' · '+escape(box.name)+'<br>Projeto '+escape(box.project)+' · Estação '+escape(box.station)+
   '<br>Entrega declarada por '+escape(closed_by_name)+'<br>Data/hora original da entrega: '+escape(date(closed_at))+'</p>' +
   '<h2>Romaneios vinculados ('+documents.length+')</h2>'+documentsTable+
   '<h2>Materiais</h2>'+itemsTable+'<p>'+items.length+' registros BMA · '+number(total_units)+' unidades</p>'+
   notes+'<p><a href="'+escape(link)+'">Consultar caixa física '+escape(box.code)+'</a></p></div>';
  const transport = nodemailer.createTransport({
   host:'smtp.gmail.com',port:465,secure:true,auth:{user:sender,pass},
   tls:{minVersion:'TLSv1.2',rejectUnauthorized:true},
   connectionTimeout:15000,greetingTimeout:15000,socketTimeout:30000,
   logger:false,debug:false,disableFileAccess:true,disableUrlAccess:true
  });
  let info;
  try {
   info = await transport.sendMail({
    from:{name:'Mondragon',address:sender},
    to:recipient_snapshot.emails.map((address: string) => ({address,name:''})),
    subject:'MONDRAGON | '+(claim.is_copy?'REENVIO DO COMPROVANTE DE ENTREGA':'CAIXA ENTREGUE À PRODUÇÃO')+' | '+box.code+' | Projeto '+box.project+' | Estação '+box.station,
    html,messageId:'<caixa-entrega-'+id+'-'+claim.token+'@gmail.com>'
   });
  } catch (error) {
   const rejectedAuth = (error as {code?:string})?.code === 'EAUTH';
   const state = rejectedAuth ? 'failed' : 'uncertain';
   await finish(state,null,rejectedAuth?'auth_rejected':'smtp_uncertain');
   return respond({state,message:rejectedAuth?'Gmail recusou a autenticação.':'Gmail não confirmou o resultado. Confira a pasta Enviados.'},502);
  } finally {
   transport.close();
  }
  if (info.accepted?.length !== recipient_snapshot.emails.length || info.rejected?.length || info.pending?.length) {
   await finish('uncertain',info.messageId,'smtp_partial');
   return respond({state:'uncertain',message:'Gmail retornou aceitação parcial ou incerta. Confira a pasta Enviados.'},502);
  }
  await finish('sent',info.messageId,null);
  return respond({state:'sent'});
 } catch {
  return respond({message:'Resultado indisponível. Consulte o estado da notificação antes de repetir.'},500);
 }
});
