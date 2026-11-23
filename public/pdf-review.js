// Presentation helpers. The PDF extractor and backend remain the source of truth.
import {validateOrderRow,groupOrderRows} from './pdf-orders.js';
export const rowKey=row=>row.file_id+':'+row.index;
export const selectedRows=rows=>rows.filter(r=>r.selected&&!r.excluded);
export function rowIssues(row){
 const issues=[...validateOrderRow(row)];
 if(row.duplicate_in_batch)issues.push('Linha repetida em outro PDF do lote');
 if(row.conflict)issues.push('Pedido alterado; revisão administrativa necessária');
 if(!Number.isFinite(row.quantity)||row.quantity<=0||row.quantity>row.ordered-row.allocated||Math.abs(row.quantity*100-Math.round(row.quantity*100))>0.00001)issues.push('Quantidade inválida ou superior ao saldo');
 if(((row.warnings||[]).length||['description','project','station'].some(k=>row[k]!==row.original?.[k]))&&String(row.reason||'').trim().length<5)issues.push('Justifique as correções e divergências');
 return [...new Set(issues)];
}
export function rowStatus(row){
 if(row.conflict||row.duplicate_in_batch||validateOrderRow(row).length)return 'pending';
 if(row.allocated>=row.ordered)return 'complete';
 if(rowIssues(row).length)return 'pending';
 return row.allocated>0?'partial':'ready';
}
export function filterReviewRows(rows,filters={},sort='order'){
 const needle=String(filters.search||'').trim().toLocaleLowerCase('pt-BR');
 return rows.filter(r=>!r.excluded&&(!needle||[r.order,r.code,r.description].some(v=>String(v||'').toLocaleLowerCase('pt-BR').includes(needle)))&&
  ['order','project','station'].every(k=>!filters[k]||r[k]===filters[k])&&(!filters.status||rowStatus(r)===filters.status)&&(!filters.selected||r.selected))
  .sort((a,b)=>(sort==='quantity'?Number(a.quantity)-Number(b.quantity):String(a[sort]).localeCompare(String(b[sort]),'pt-BR',{numeric:true}))||a.index-b.index);
}
export function reviewSummary(rows){
 const selected=selectedRows(rows);
 return {selected,groups:groupOrderRows(selected),qty:Math.round(selected.reduce((n,r)=>n+Number(r.quantity||0),0)*100)/100,
  excluded:rows.filter(r=>r.excluded).length,changed:rows.filter(r=>['description','project','station'].some(k=>r[k]!==r.original?.[k])||r.quantity!==Math.max(0,r.ordered-r.allocated)).length,
  pending:selected.filter(r=>rowIssues(r).length).length};
}
