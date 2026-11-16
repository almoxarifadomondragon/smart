export const ownershipMessage='Esta separação pertence a outro almoxarife. Você pode consultá-la, mas não adicionar ou alterar peças. Para continuar, abra uma separação de sua responsabilidade ou inicie uma nova.';
export const ownsPicking=(doc,userId,demo=false)=>Boolean(doc&&((userId&&doc.owner_id===userId)||(demo&&!doc.owner_id)));
export const ownDraft=(docs,userId,demo=false)=>docs.find(doc=>doc.status==='draft'&&ownsPicking(doc,userId,demo));
export const canOperate = role => ['admin','operator'].includes(role);
export const profileLabel = role => ({admin:'Administrador',operator:'Operador',reader:'Leitor'})[role]||'Usuário';
export function assertEditable(doc,userId,demo=false,role='operator'){
 if(!demo&&!canOperate(role))throw new Error('Perfil Leitor: acesso somente para consulta e exportação.');
 if(!doc)throw new Error('Separação não encontrada ou sem permissão de consulta.');
 if(!ownsPicking(doc,userId,demo))throw new Error(ownershipMessage);
 if(doc.status!=='draft')throw new Error('Este romaneio já foi confirmado. Atualize a consulta; novas alterações não são permitidas.');
 return doc;
}
export function operationMessage(error){
 const message=typeof error==='string'?error:error?.message||'Não foi possível concluir a operação. Tente novamente.';
 return /Esta separação pertence a outro usuário\./i.test(message)?ownershipMessage:message;
}
export function showOperationError(document,message){
 const modal=document.querySelector('#modal');
 if(!modal?.open)return false;
 let alert=modal.querySelector('[data-modal-error]');
 if(!alert){alert=document.createElement('p');alert.dataset.modalError='';alert.className='error';alert.setAttribute('role','alert');alert.setAttribute('style','white-space:pre-line');alert.tabIndex=-1;modal.prepend(alert);}
 alert.textContent=operationMessage(message);alert.focus();alert.scrollIntoView({block:'nearest'});return true;
}
