const url=Deno.env.get('SUPABASE_URL')!;
const key=Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const origin=Deno.env.get('APP_ORIGIN')||'https://almoxarifadomondragon.github.io';
const cors={'Access-Control-Allow-Origin':origin,'Access-Control-Allow-Headers':'authorization, apikey, content-type','Access-Control-Allow-Methods':'POST, OPTIONS'};
const reply=(data:unknown,status=200)=>Response.json(data,{status,headers:cors});
Deno.serve(async(req:Request)=>{
 if(req.method==='OPTIONS')return new Response('ok',{headers:cors});
 if(req.method!=='POST')return reply({message:'Método inválido'},405);
 let requestId:string|undefined,createdId:string|undefined;
 const service={apikey:key,Authorization:`Bearer ${key}`,'Content-Type':'application/json'};
 const internal=async(name:string,body:unknown)=>fetch(url+'/rest/v1/rpc/'+name,{method:'POST',headers:service,body:JSON.stringify(body)});
 try{
  const authorization=req.headers.get('Authorization')||'';
  if(!authorization.startsWith('Bearer '))return reply({message:'Login necessário'},401);
  const auth=await fetch(url+'/auth/v1/user',{headers:{apikey:key,Authorization:authorization}});
  if(!auth.ok)return reply({message:'Sessão inválida ou expirada'},401);
  const user=await auth.json();
  const caller={apikey:key,Authorization:authorization,'Content-Type':'application/json'};
  const membership=await fetch(url+'/rest/v1/app_members?select=role&active=eq.true&user_id=eq.'+user.id,{headers:caller});
  if(!membership.ok||(await membership.json())[0]?.role!=='admin')return reply({message:'Somente administradores ativos podem gerenciar usuários.'},403);
  const body=await req.json();
  const rpc=async(name:string,payload:unknown)=>{
   const r=await fetch(url+'/rest/v1/rpc/'+name,{method:'POST',headers:caller,body:JSON.stringify(payload)});
   const data=await r.json().catch(()=>null);
   if(!r.ok)throw new Error(data?.message||'Operação administrativa recusada.');
   return data;
  };
  if(body.action==='list')return reply({users:await rpc('admin_list_users',{})});
  if(body.action==='update'){
   await rpc('admin_update_member',{p_id:body.id,p_name:body.full_name,p_role:body.role,p_active:body.active});
   return reply({updated:true});
  }
  if(body.action!=='invite')return reply({message:'Ação inválida'},400);
  const prepared=await rpc('prepare_user_invite',{p_email:body.email,p_name:body.full_name,p_role:body.role});
  requestId=prepared.id;
  const invitation=await fetch(url+'/auth/v1/invite?redirect_to='+encodeURIComponent(origin+'/smart/'),{
   method:'POST',headers:service,body:JSON.stringify({email:prepared.email,data:{full_name:prepared.full_name}})
  });
  const identity=await invitation.json();
  if(!invitation.ok){await internal('fail_user_invite',{p_request:requestId,p_auth_id:null});return reply({message:'Supabase Auth não enviou o convite. Verifique duplicidade, SMTP e limites de envio no painel. A solicitação foi registrada para reconciliação.'},409);}
  createdId=identity.id;
  if(!createdId)throw new Error('Auth não retornou a identidade do convite.');
  const linked=await internal('complete_user_invite',{p_request:requestId,p_auth_id:createdId});
  if(!linked.ok){
   // Never delete Auth identities. An orphan has no app_members access; ban new sign-ins too.
   await fetch(url+'/auth/v1/admin/users/'+encodeURIComponent(createdId),{method:'PUT',headers:service,body:JSON.stringify({ban_duration:'876000h'})});
   await internal('fail_user_invite',{p_request:requestId,p_auth_id:createdId});
   return reply({message:'Convite criado no Auth, mas o vínculo não foi confirmado. Acesso bloqueado; solicite reconciliação no Supabase antes de repetir.'},409);
  }
  return reply({invited:true,id:createdId,message:'Convite enviado pelo Supabase Auth. O usuário definirá a própria senha.'});
 }catch(error){
  // A durable pending request and lack of membership keep intermediate failures fail-closed.
  return reply({message:requestId?'Operação incompleta. Confira Auth e a solicitação de convite no Supabase antes de repetir.':(error instanceof Error?error.message:'Falha ao gerenciar usuários.')},409);
 }
});
