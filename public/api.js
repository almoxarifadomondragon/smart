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
  if (!response.ok) throw new Error(data?.msg || data?.message || data?.error_description || 'Não foi possível conectar ao Supabase.');
  return data;
}
export const login = (email,password) => request('/auth/v1/token?grant_type=password','POST',{email,password});
export const logout = () => request('/auth/v1/logout','POST');
export const listDocuments = () => request('/rest/v1/picking_documents?select=*&order=number.desc');
export const createDocument = (project,station) => request('/rest/v1/rpc/create_picking','POST',{p_project:project,p_station:station});
export const saveDocument = doc => request('/rest/v1/rpc/save_picking','POST',{p_id:doc.id,p_project:doc.project,p_station:doc.station,p_boxes:doc.boxes,p_items:doc.items});
export const finalizeDocument = id => request('/rest/v1/rpc/finalize_picking','POST',{p_id:id});
export const sendManifest = id => request('/functions/v1/send-manifest','POST',{id});
export const verifyGmail = () => request('/functions/v1/send-manifest','POST',{action:'verify'});
export const getRecipients = () => request('/rest/v1/notification_recipients?select=role,email&order=role');
export const saveRecipients = recipients => request('/rest/v1/rpc/set_recipients','POST',{p_recipients:recipients});

export async function getMembership(userId) {
 const rows=await request('/rest/v1/app_members?select=user_id,full_name,role&user_id=eq.'+encodeURIComponent(userId));
 if(!rows?.length)throw new Error('Usuário não autorizado no almoxarifado. Solicite acesso ao administrador.');
 return rows[0];
}
