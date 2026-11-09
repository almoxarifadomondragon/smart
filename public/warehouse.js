import {formatQty,normalizeDestinationCode,pad,totalQty} from './domain.js';
import {physicalBoxLink} from './labels.js';

const esc = value => String(value??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
export const physicalStatus = status => ({available:'Disponível',in_use:'Em utilização',closed:'Fechada'}[status]||'Indisponível');
export const volumeName = box => box ? [box.name,box.physical_box_code].filter(Boolean).join(' · ') : 'Sem caixa';
export function validateInvoice(raw,required=false){
 const value=String(raw??'').trim();
 if((required||value)&&!/^[A-Za-z0-9][A-Za-z0-9 ./_:-]{0,59}$/.test(value))
  throw new Error('Informe uma Nota Fiscal de até 60 caracteres, começando por letra ou número.');
 return value;
}
export function planInvoice(items,selected,raw,{all=false,clear=false}={}){
 const invoice=clear?'':validateInvoice(raw,true), ids=new Set(selected);
 const targets=items.filter(i=>all||ids.has(i.id));
 if(!targets.length)throw new Error('Selecione pelo menos um item deste romaneio.');
 const changed=targets.filter(i=>(i.invoice_number||'')!==invoice);
 const changedIds=new Set(changed.map(i=>i.id));
 return {
  count:changed.length,
  overwrites:changed.filter(i=>i.invoice_number).length,
  items:items.map(i=>changedIds.has(i.id)?{...i,invoice_number:invoice}:i)
 };
}
export function assertPhysicalDestination(box,doc){
 if(normalizeDestinationCode(box.project)!==normalizeDestinationCode(doc.project)||
    normalizeDestinationCode(box.station)!==normalizeDestinationCode(doc.station))
  throw new Error('Esta caixa pertence ao projeto '+box.project+', estação '+box.station+
   '. A separação atual pertence ao projeto '+(doc.project||'não definido')+', estação '+(doc.station||'não definida')+'. Selecione outra caixa.');
 if(box.status==='closed')throw new Error('Esta caixa física está fechada. Selecione outra caixa.');
}
export function bindVolume(doc,volumeId,physical){
 if(!doc.boxes.some(b=>b.id===volumeId))throw new Error('Volume não encontrado.');
 if(physical){
  assertPhysicalDestination(physical,doc);
  if(doc.boxes.some(b=>b.id!==volumeId&&b.physical_box_id===physical.id))
   throw new Error('Esta caixa física já está vinculada a outro volume deste romaneio.');
 }
 return doc.boxes.map(box=>{
  if(box.id!==volumeId)return box;
  const {physical_box_id,physical_box_code,...rest}=box;
  return physical?{...rest,physical_box_id:physical.id,physical_box_code:physical.code}:rest;
 });
}
export function demoPhysicalContents(box,docs){
 const linked=docs.flatMap(doc=>{
  const volume=doc.boxes.find(b=>b.physical_box_id===box.id);
  return volume?[{doc,volume}]:[];
 }).sort((a,b)=>a.doc.number-b.doc.number);
 const items=linked.flatMap(({doc,volume})=>doc.items.filter(i=>i.box===volume.id).map(i=>({
  ...i,item_id:i.id,document_id:doc.id,document_number:doc.number,status:doc.status,
  operator:i.operator||doc.responsible
 })));
 return {
  box:{...box,can_close:box.status!=='closed'},
  documents:linked.map(({doc})=>({id:doc.id,number:doc.number,status:doc.status})),
  items,total_units:totalQty(items)
 };
}
export function invoiceBatchView(count){
 return count?'<section id="invoice-batch" class="invoice-batch"><h3>Aplicar Nota Fiscal</h3><label class="field">Número da NF<input id="batch-invoice" maxlength="60" autocomplete="off"></label><div class="actions"><button type="button" id="invoice-all">Aplicar a todos ('+count+')</button><button type="button" id="invoice-selected">Aplicar aos selecionados (0)</button><button type="button" id="invoice-clear">Limpar NF dos selecionados (0)</button></div><p id="invoice-count" class="muted" aria-live="polite">0 itens selecionados</p></section>':'';
}
export function physicalListView(boxes){
 return boxes.length?boxes.map(b=>'<div class="list-item"><div><strong>'+esc(b.code)+' · '+esc(b.name)+'</strong><p>'+physicalStatus(b.status)+'</p></div><div class="actions"><button type="button" data-action="physical-consult" data-id="'+esc(b.id)+'">Consultar</button><button type="button" data-action="physical-select" data-id="'+esc(b.id)+'">Vincular</button></div></div>').join(''):'<p class="muted">Nenhuma caixa compatível encontrada.</p>';
}
export function physicalContentsView(result,{compact=false}={}){
 const {box,documents,items,total_units}=result;
 const status=s=>s==='confirmed'?'Confirmado':'Em andamento';
 const open=(id,number)=>'<button class="ghost" type="button" data-action="open" data-id="'+esc(id)+'">#'+pad(number)+'</button>';
 const date=value=>{const d=new Date(value);return value&&!Number.isNaN(+d)?d.toLocaleString('pt-BR',{timeZone:'America/Sao_Paulo'}):'—';};
 return '<section class="card physical-contents"><div class="card-head"><div><h2>'+esc(box.code)+' · '+esc(box.name)+'</h2>'+
  '<p>Projeto '+esc(box.project)+' · Estação '+esc(box.station)+' · '+physicalStatus(box.status)+'</p></div>'+
  (compact?'':'<div class="actions"><button data-action="physical-label">Gerar etiqueta permanente</button>'+
  (box.can_close?'<button data-action="physical-close">Fechar caixa</button>':'')+'</div>')+'</div><div class="card-body">'+
  '<p><strong>'+documents.length+'</strong> romaneio(s) · <strong>'+items.length+'</strong> registro(s) BMA · <strong>'+formatQty(total_units)+'</strong> unidades registradas</p>'+
  '<p class="notice">Histórico de materiais registrados e associados à caixa. Estas quantidades não representam o saldo físico atual.</p>'+
  '<div class="actions">'+documents.map(d=>'<span>'+ (compact?'#'+pad(d.number):open(d.id,d.number))+' · '+status(d.status)+'</span>').join('')+'</div>'+
  '<div class="table-wrap"><table><thead><tr><th>BMA</th><th>Qtd.</th><th>Nota Fiscal</th><th>Pedido</th><th>Item do pedido</th><th>Romaneio</th><th>Data/hora da separação</th><th>Almoxarife</th></tr></thead><tbody>'+
  items.map(i=>'<tr><td class="code">'+esc(i.code)+'</td><td>'+formatQty(i.qty)+'</td><td>'+esc(i.invoice_number||'—')+'</td><td>'+esc(i.purchase_order||'—')+'</td><td>'+esc(i.purchase_order_item||'—')+'</td><td>'+
   (compact?'#'+pad(i.document_number):open(i.document_id,i.document_number))+'</td><td>'+esc(date(i.created_at||i.scanned_at))+'</td><td>'+esc(i.operator||'—')+'</td></tr>').join('')+
  '</tbody></table></div>'+(!items.length?'<p class="empty">Nenhum material associado.</p>':'')+'</div></section>';
}
export function physicalLabelView(box,base,qrCode,demo=false){
 const url=physicalBoxLink(base,box.id,demo);
 return {
  url,
  html:'<div class="label-toolbar"><button data-action="label-close">Voltar à consulta</button><p>A4 · Paisagem · Uma etiqueta por folha.</p><button class="primary" data-action="label-print">Imprimir / Salvar PDF</button></div>'+
   '<article class="label-sheet physical-label"><header class="label-brand"><img src="./logo.png" alt="Mondragon Assembly"><span>CAIXA FÍSICA</span></header>'+
   '<div class="label-main"><div><div class="label-field"><small>CÓDIGO PERMANENTE</small><strong class="box-number">'+esc(box.code)+'</strong><span>'+esc(box.name)+'</span></div>'+
   '<div class="label-field"><small>PROJETO</small><strong>'+esc(box.project)+'</strong></div><div class="label-field"><small>ESTAÇÃO</small><strong>'+esc(box.station)+'</strong></div></div>'+
   '<div class="label-qr">'+qrCode(url)+'<p>Consulte os materiais registrados</p><a class="no-print" href="'+esc(url)+'" id="label-open">Abrir consulta da caixa</a></div></div>'+
   '<footer class="label-bottom"><span>Identificação permanente · Consulta com login</span><span class="label-state">'+(demo?'DEMONSTRAÇÃO':'MONDRAGON ASSEMBLY')+'</span></footer></article>'
 };
}
