const URL = 'https://qrcpprvxjgcnlxyushsg.supabase.co';
const KEY = 'sb_publishable_r2eHPLJGxh7BDzq-kb1xSQ_uoWHRevl';
let session;
export const setSession = value => {session=value;};
async function request(path,method='GET',body) {
  if(session?.expires_at && session.expires_at*1000 < Date.now()+60000 && !path.startsWith('/auth/v1/token')) {
    const refreshed = await fetch(URL+'/auth/v1/token?grant_type=refresh_token',{method:'POST',headers:{apikey:KEY,'Content-Type':'application/json'},body:JSON.stringify({refresh_token:session.refresh_token})});
    if(!refreshed.ok) throw new Error('Sua sessão expirou. Saia e entre novamente.');
    session = await refreshed.json();
  }
  const response = await fetch(URL+path,{method,headers:{apikey:KEY,...(session?{Authorization:`Bearer ${session.access_token}`} : {}),'Content-Type':'application/json'},...(body?{body:JSON.stringify(body)}:{})});
  const data = await response.json().catch(()=>null);
  if (!response.ok) {const error=new Error(data?.msg || data?.message || data?.error_description || 'Não foi possível conectar ao Supabase.');error.code=data?.code;error.status=response.status;throw error;}
  return data;
}
export const login = (email,password) => request('/auth/v1/token?grant_type=password','POST',{email,password});
export const logout = () => request('/auth/v1/logout','POST');
export const getDashboard = () => request('/rest/v1/rpc/get_picking_dashboard','POST',{});
export const searchDocuments = parameters => request('/rest/v1/rpc/search_picking_documents','POST',parameters);
export async function getDocument(id){const rows=await request('/rest/v1/picking_documents?select=*&id=eq.'+encodeURIComponent(id));if(!rows?.length)throw new Error('Separação não encontrada ou sem permissão de consulta.');return rows[0];}
export const createDocument = (project,station) => request('/rest/v1/rpc/create_picking','POST',{p_project:project,p_station:station});
export const saveDocument = doc => request('/rest/v1/rpc/save_picking','POST',{p_id:doc.id,p_project:doc.project,p_station:doc.station,p_boxes:doc.boxes,p_items:doc.items});
export const finalizeDocument = (id,approval) => request('/rest/v1/rpc/finalize_picking','POST',{p_id:id,p_additional:approval.additional,p_exception_reason:approval.reason,p_expected:approval.fingerprint});
export const sendManifest = id => request('/functions/v1/send-manifest','POST',{id});
export const verifyGmail = () => request('/functions/v1/send-manifest','POST',{action:'verify'});
export const getRecipients = () => request('/rest/v1/notification_recipients?select=role,email&order=role,email');
export const saveRecipients = recipients => request('/rest/v1/rpc/set_recipients','POST',{p_recipients:recipients});

export async function getMembership(userId) {
 const rows=await request('/rest/v1/app_members?select=user_id,full_name,role&active=eq.true&user_id=eq.'+encodeURIComponent(userId));
 if(!rows?.length)throw new Error('Usuário não autorizado no almoxarifado. Solicite acesso ao administrador.');
 return rows[0];
}
export const getManagers=()=>request('/rest/v1/project_managers?select=*&order=project_code');
export const saveManager=m=>request('/rest/v1/rpc/save_project_manager','POST',{p_id:m.id||null,p_project:m.project_code,p_email:m.email,p_active:m.active});
export const previewRecipients=(id,additional,reason)=>request('/rest/v1/rpc/preview_recipients','POST',{p_id:id,p_additional:additional,p_exception_reason:reason||null});
export const manageUsers=body=>request('/functions/v1/manage-users','POST',body);
export const resolveEmail=(id,sent,note)=>request('/rest/v1/rpc/resolve_manifest_email','POST',{p_id:id,p_sent:sent,p_note:note});
export const authUser=()=>request('/auth/v1/user');
export const setPassword=password=>request('/auth/v1/user','PUT',{password});
export const verifyPasswordLink=(token_hash,type)=>request('/auth/v1/verify','POST',{token_hash,type});
