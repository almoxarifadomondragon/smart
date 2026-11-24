import {normalizeDestinationCode} from './domain.js';
// Demo-only review mirrors the scope; production decisions and audit are server-owned.
export function demoDuplicateReview(document,item,documents){
 const matches=documents.filter(d=>d.import_state!=='cancelled').flatMap(d=>d.items.filter(i=>
  !(d.id===document.id&&i.id===item.id)&&i.code===item.code&&
  normalizeDestinationCode(i.project)===normalizeDestinationCode(item.project)&&normalizeDestinationCode(i.station)===normalizeDestinationCode(item.station)
 ).map(i=>({document_id:d.id,document_number:d.number,item_id:i.id,code:i.code,project:i.project,station:i.station,
  purchase_order:i.source_order||i.purchase_order||'',purchase_order_item:i.source_line||i.purchase_order_item||'',qty:i.qty,source:i.source||'Legado'})))
 .sort((a,b)=>String(a.document_id).localeCompare(String(b.document_id))||String(a.item_id).localeCompare(String(b.item_id)));
 return {total:matches.length,matches:matches.slice(0,20),fingerprint:JSON.stringify([document.id,item.id,item.code,item.project,item.station,item.purchase_order,item.purchase_order_item,item.qty,matches])};
}
