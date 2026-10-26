import * as api from './api.js';
export const normalizeProject=value=>String(value||'').trim().toUpperCase();
export function normalizeEmails(values,limit=30){
 const result=[...new Set(values.map(v=>String(v).trim().toLowerCase()))];
 if(result.length>limit||result.some(v=>v.length>254||!/^\S+@[^\s@]+\.[^\s@]+$/.test(v)||v.split('@').length!==2))throw new Error('Confira os e-mails adicionais (máximo de 30).');
 return result;
}
const esc=v=>String(v??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const q=s=>document.querySelector(s);
const field=(label,name,value='',extra='')=>`<label class="field">${label}<input name="${name}" value="${esc(value)}" ${extra}></label>`;
const select=(label,name,options)=>`<label class="field">${label}<select name="${name}">${options}</select></label>`;
export function settingsView({admin,demo,recipients,managers}){
 return `<section class="card" style="max-width:900px"><div class="card-head"><h2>Destinatários fixos</h2></div><form id="fixed-recipients" class="card-body">${demo?'<div class="notice">Demonstração: dados locais, nenhum convite ou e-mail real.</div>':''}${['PCP','Almoxarifado'].map(role=>field(role,role,recipients.find(r=>r.role===role)?.email||'',`type="email" required ${admin?'':'disabled'}`)).join('')}${admin?'<button class="primary">Salvar destinatários</button>':''}${admin&&!demo?'<button type="button" data-action="verify-gmail">Testar conexão com Gmail</button><p id="gmail-result" role="status"></p>':''}</form></section>
 <section class="card" style="max-width:900px"><div class="card-head"><h2>Gestores por Projeto</h2></div><div class="card-body"><div class="table-wrap"><table><thead><tr><th>Projeto</th><th>E-mail do gestor</th><th>Status</th><th></th></tr></thead><tbody>${managers.map(m=>`<tr><td>${esc(m.project_code)}</td><td>${esc(m.email)}</td><td>${m.active?'Ativo':'Inativo'}</td><td>${admin?`<button type="button" data-manager-edit="${m.id}">Editar</button>`:''}</td></tr>`).join('')}</tbody></table></div>${admin?`<h3 style="margin:24px 0 16px">Cadastrar ou editar gestor</h3><form id="manager-form"><input type="hidden" name="id">${field('Projeto','project_code','','required maxlength="120"')}${field('E-mail do gestor','email','','type="email" required maxlength="254"')}${select('Status','active','<option value="true">Ativo</option><option value="false">Inativo</option>')}<button class="primary">Salvar gestor</button> <button type="reset">Novo registro</button></form>`:''}</div></section>
 ${admin?`<section class="card" style="max-width:900px"><div class="card-head"><h2>Usuários do Sistema</h2></div><div class="card-body">${demo?'<p>Administração de identidades indisponível na demonstração.</p>':'<div id="users-list" role="status">Carregando usuários…</div><h3 style="margin:24px 0 16px">Cadastrar ou editar usuário</h3><form id="user-form"><input type="hidden" name="id">'+field('Nome completo','full_name','','required maxlength="160"')+field('E-mail','email','','type="email" required maxlength="254"')+select('Perfil','role','<option value="operator">Operador</option><option value="admin">Administrador</option>')+select('Status','active','<option value="true">Ativo</option><option value="false">Inativo</option>')+'<p>O novo usuário recebe um convite do Supabase Auth para definir a própria senha.</p><button class="primary">Salvar / enviar convite</button> <button type="reset">Novo usuário</button></form>'}</div></section>`:''}`;
}
export function bindSettings(ctx){
 const {admin,demo,recipients,managers,transaction,toast,reload,store}=ctx;
 if(!admin)return;
 const fixed=q('#fixed-recipients');
 fixed.onsubmit=e=>{e.preventDefault();transaction(async()=>{const next=['PCP','Almoxarifado'].map(role=>({role,email:fixed.elements.namedItem(role).value.trim().toLowerCase()}));if(!demo)await api.saveRecipients(next);recipients.splice(0,recipients.length,...next);store();toast('Destinatários fixos salvos.');});};
 const form=q('#manager-form');
 form.onreset=()=>{form.elements.namedItem('id').value='';};
 form.onsubmit=e=>{e.preventDefault();transaction(async()=>{const f=new FormData(form),m={id:f.get('id')||null,project_code:normalizeProject(f.get('project_code')),email:String(f.get('email')).trim().toLowerCase(),active:f.get('active')==='true'};if(managers.some(x=>x.id!==m.id&&x.active&&m.active&&normalizeProject(x.project_code)===m.project_code))throw new Error('Já existe gestor ativo para este projeto.');if(demo){const index=managers.findIndex(x=>x.id===m.id);m.id ||= crypto.randomUUID();if(index<0)managers.push(m);else managers[index]=m;store();}else await api.saveManager(m);await reload();toast('Gestor salvo.');});};
 document.querySelectorAll('[data-manager-edit]').forEach(button=>button.onclick=()=>{const m=managers.find(x=>x.id===button.dataset.managerEdit);for(const key of ['id','project_code','email','active'])form.elements.namedItem(key).value=String(m[key]);form.scrollIntoView({block:'center',behavior:'smooth'});});
 if(demo)return;
 let users=[];
 const loadUsers=async()=>{const result=await api.manageUsers({action:'list'});users=result.users;q('#users-list').innerHTML=`<div class="table-wrap"><table><thead><tr><th>Nome</th><th>E-mail</th><th>Perfil</th><th>Status</th><th></th></tr></thead><tbody>${users.map(u=>`<tr><td>${esc(u.full_name)}</td><td>${esc(u.email)}</td><td>${u.role==='admin'?'Administrador':'Operador'}</td><td>${u.active?'Ativo':'Inativo'}</td><td><button type="button" data-user-edit="${u.user_id}">Editar</button></td></tr>`).join('')}</tbody></table></div>`;q('#users-list').querySelectorAll('[data-user-edit]').forEach(b=>b.onclick=()=>{const u=users.find(x=>x.user_id===b.dataset.userEdit);for(const key of ['full_name','email','role','active'])userForm.elements.namedItem(key).value=String(u[key]);userForm.elements.namedItem('id').value=u.user_id;userForm.elements.namedItem('email').readOnly=true;});};
 const userForm=q('#user-form');
 userForm.onreset=()=>{userForm.elements.namedItem('email').readOnly=false;userForm.elements.namedItem('id').value='';};
 userForm.onsubmit=e=>{e.preventDefault();transaction(async()=>{const f=new FormData(userForm),id=String(f.get('id')||''),active=f.get('active')==='true';if(!id&&!active)throw new Error('Crie o convite como ativo; depois poderá desativar o acesso.');const result=await api.manageUsers({action:id?'update':'invite',id,email:f.get('email'),full_name:f.get('full_name'),role:f.get('role'),active});toast(result.message||'Usuário atualizado.');userForm.reset();await loadUsers();await ctx.refreshMembership();});};
 loadUsers().catch(error=>{if(q('#users-list'))q('#users-list').textContent=error.message;});
}

const drafts=new Map();
export async function reviewRecipients(doc,ctx,options={}){
 const {demo,admin,recipients,managers}=ctx;
 const state=drafts.get(doc.id)||{additional:[],reason:'',approved:null,error:''};drafts.set(doc.id,state);
 state.revision=(state.revision||0)+1;state.approved=null;state.error=options.message||'';
 const panel=document.createElement('section');panel.className='card no-print';panel.id='recipient-review';q('#page').append(panel);
 const read=()=>{state.additional=Array.from(panel.querySelectorAll('[data-additional]')).map(x=>x.value);state.reason=panel.querySelector('[name="exception"]')?.checked?panel.querySelector('[name="reason"]').value.trim():'';};
 const dirty=()=>{state.revision++;state.approved=null;const confirm=q('[data-action="confirm"]');if(confirm)confirm.disabled=true;};
 const draw=()=>{
  const manager=managers.find(m=>m.active&&normalizeProject(m.project_code)===normalizeProject(doc.project));
  panel.innerHTML=`<div class="card-head"><h2>Conferir destinatários</h2></div><div class="card-body"><p>PCP e Almoxarifado são fixos. O gestor é selecionado pelo código exato do projeto.</p><ul>${['PCP','Almoxarifado'].map(role=>`<li>${role}: ${esc(recipients.find(r=>r.role===role)?.email||'Não cadastrado')}</li>`).join('')}<li>Gestor: ${esc(manager?.email||'Projeto sem gestor ativo')}</li></ul>${!manager&&admin?`<label><input name="exception" type="checkbox" style="width:auto" ${state.reason?'checked':''}> Autorizar explicitamente uma exceção sem gestor</label>${field('Justificativa da exceção (10 a 500 caracteres)','reason',state.reason,'minlength="10" maxlength="500"')}`:''}<div>${state.additional.map((email,i)=>`<div class="scan-row" style="margin:10px 0"><input data-additional="${i}" type="email" aria-label="Destinatário adicional ${i+1}" value="${esc(email)}" maxlength="254" required><button type="button" data-remove-additional="${i}">Remover</button></div>`).join('')}</div><button type="button" data-add-recipient>+ Incluir destinatário</button> <button type="button" data-check-recipients>Conferir destinatários</button><p role="status" class="error">${esc(state.error)}</p>${state.approved?`<h3>Lista efetiva de envio</h3><ul>${state.approved.emails.map(e=>`<li>${esc(e)}</li>`).join('')}</ul><p>Esta relação será congelada na confirmação.</p>`:''}</div>`;
  panel.oninput=dirty;panel.onchange=dirty;
  panel.querySelector('[data-add-recipient]').onclick=()=>{read();if(state.additional.length>=30)return;state.additional.push('');dirty();draw();};
  panel.querySelectorAll('[data-remove-additional]').forEach(b=>b.onclick=()=>{read();state.additional.splice(Number(b.dataset.removeAdditional),1);dirty();draw();});
  panel.querySelector('[data-check-recipients]').onclick=()=>check();
 };
 const check=async()=>{
  read();dirty();state.error='';
  const revision=state.revision;
  try{
   state.additional=normalizeEmails(state.additional);
   const additional=[...state.additional],reason=state.reason||null;
   let snapshot;
   if(demo){const manager=managers.find(m=>m.active&&normalizeProject(m.project_code)===normalizeProject(doc.project));if(!manager&&!state.reason)throw new Error('Cadastre um gestor ativo ou autorize explicitamente uma exceção.');if(state.reason.length>0&&state.reason.length<10)throw new Error('Descreva a justificativa com ao menos 10 caracteres.');const fixed=['PCP','Almoxarifado'].map(r=>recipients.find(x=>x.role===r)?.email||'');if(fixed.some(x=>!x))throw new Error('Cadastre PCP e Almoxarifado.');snapshot={emails:normalizeEmails([...fixed,...(manager?[manager.email]:[]),...additional],33),fingerprint:'demo'};}
   else snapshot=await api.previewRecipients(doc.id,additional,reason);
   if(revision!==state.revision||!panel.isConnected)return;
   if(!snapshot?.fingerprint||!Array.isArray(snapshot.emails))throw new Error('Falha técnica ao conferir destinatários. Tente conferir novamente.');
   state.approved={...snapshot,additional,reason};
  }catch(error){if(revision!==state.revision||!panel.isConnected)return;state.error=error.code==='P4221'?'Cadastro de destinatários incompleto: '+error.message:error.message;}
  draw();const confirm=q('[data-action="confirm"]');if(confirm)confirm.disabled=!state.approved;
 };
 dirty();draw();if(!options.requireApproval)await check();
}
export function recipientApproval(doc){const state=drafts.get(doc.id);if(!state?.approved)throw new Error('Confira a lista completa dos destinatários antes de confirmar.');const a=state.approved;return {additional:[...a.additional],reason:a.reason,fingerprint:a.fingerprint,emails:[...a.emails]};}
export function confirmationFailure(error){
 if(error.code==='P4223')return {kind:'destination',message:error.message+' O romaneio continua em rascunho. Regularize os destinos antes de confirmar.'};
 if(error.code==='P4091'||error.message==='Confira novamente os destinatários: o cadastro pode ter mudado.')return {kind:'changed',message:'Os destinatários mudaram desde a conferência. Revise o cadastro atualizado e clique em Conferir destinatários para aprovar novamente. Nada foi confirmado ou enviado.'};
 if(error.code==='P4221')return {kind:'registry',message:'Pendência no cadastro de destinatários: '+error.message+' O romaneio continua em rascunho.'};
 return {kind:'technical',message:'Falha ao confirmar o romaneio: '+error.message+' Confira o estado do documento antes de tentar novamente.'};
}
export async function confirmReviewedDocument(doc,approval,{finalize=api.finalizeDocument,confirmed,send}){
 const result=await finalize(doc.id,approval);
 if(result?.id!==doc.id||result.status!=='confirmed')throw new Error('O servidor não comprovou a confirmação do documento.');
 Object.assign(doc,result);await confirmed();await send(doc);
}
