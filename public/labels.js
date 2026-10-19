const uuid=/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
export function boxLink(base,documentId,boxId,demo=false){
 if(!uuid.test(documentId)||!uuid.test(boxId))throw new Error('Identificação da caixa inválida.');
 const url=new URL(base);if(!['http:','https:'].includes(url.protocol))throw new Error('Endereço inválido.');
 url.search='';url.hash=new URLSearchParams({romaneio:documentId,caixa:boxId,...(demo?{demo:'1'}:{})}).toString();
 return url.href;
}
export function boxRoute(hash){
 const params=new URLSearchParams(hash.replace(/^#/,''));
 const documentId=params.get('romaneio'),boxId=params.get('caixa');
 if(!uuid.test(documentId||'')||!uuid.test(boxId||''))return null;
 return {documentId,boxId,demo:params.get('demo')==='1'};
}
export function boxDetails(doc,boxId){
 const index=doc.boxes.findIndex(box=>box.id===boxId);
 if(index<0)throw new Error('Caixa não encontrada.');
 const items=doc.items.filter(item=>item.box===boxId);
 const values=key=>[...new Set(items.map(item=>item[key]).filter(Boolean))].join(' / ')||doc[key]||'Não informado';
 return {box:doc.boxes[index],items,project:values('project'),station:values('station'),number:`${String(index+1).padStart(2,'0')}/${String(doc.boxes.length).padStart(2,'0')}`};
}
