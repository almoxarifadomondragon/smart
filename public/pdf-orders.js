// PDF.js 5.6.205 is served locally. Only text and geometry are read.
export const PDF_LIMITS = Object.freeze({files:25, bytes:20*1024*1024, pages:200, rows:5000});

export function textRows(items) {
 const rows=[];
 for(const item of items.filter(i=>i.str?.trim()).sort((a,b)=>b.transform[5]-a.transform[5]||a.transform[4]-b.transform[4])) {
  const y=item.transform[5];
  let row=rows.find(r=>Math.abs(r.y-y)<3);
  if(!row){row={y,cells:[]};rows.push(row);}
  row.cells.push({text:item.str,x:item.transform[4]});
 }
 return rows.sort((a,b)=>b.y-a.y).map(row=>({...row,cells:row.cells.sort((a,b)=>a.x-b.x),text:row.cells.sort((a,b)=>a.x-b.x).map(c=>c.text).join(' ').replace(/\s+/g,' ').trim()}));
}
const decimal = text => {
 if(/^\d+(?:[.,]\d{1,2})?$/.test(text||''))return Number(text.replace(',','.'));
 if(/^\d{1,3}(?:\.\d{3})+,\d{1,2}$/.test(text||''))return Number(text.replaceAll('.','').replace(',','.'));
 return null;
};
const clean = value => String(value||'').trim();
export function validateOrderRow(row) {
 const errors=[];
 if(!/^(?:VH|EZ)\d{1,20}$/.test(row.order||''))errors.push('Pedido não identificado');
 if(!/^\d{1,20}$/.test(row.line||''))errors.push('Referência L: não identificada');
 if(!/^\d{1,20}$/.test(row.sequence||''))errors.push('Sequencial não identificado');
 if(!/^(?:BMA|BPZ)\d{7}$/.test(row.code||''))errors.push('Código BMA/BPZ inválido');
 for(const key of ['project','station'])if(!/^\d{1,20}$/.test(row[key]||''))errors.push(key==='project'?'Projeto não identificado':'Estação não identificada');
 if(!Number.isFinite(row.ordered)||row.ordered<=0||row.ordered>999999||Math.abs(Math.round(row.ordered*100)-row.ordered*100)>0.00001)errors.push('Quantidade solicitada inválida');
 if(!clean(row.description))errors.push('Descrição não identificada');
 return errors;
}
export function parseOrderPages(pages) {
 const result={order:'',date:'',supplier:'',buyer:'',header_project:'',origin:'MONDRAGON-BRASIL',rows:[],warnings:[]};
 const labels=[];
 for(const [index,items] of pages.entries()) {
  const lines=textRows(items),all=lines.map(l=>l.text).join('\n');
  const order=all.match(/Pedido\s+((?:VH|EZ)\d+)/i)?.[1];
  if(order&&result.order&&order!==result.order)throw Error('O arquivo contém pedidos diferentes. Separe os documentos.');
  result.order ||= order||'';
  result.date ||= all.match(/Data\s+(\d{2}\/\d{2}\/\d{4})/)?.[1]||'';
  const projectLabel=items.find(i=>i.str==='Projeto:');
  result.header_project ||= projectLabel?items.find(i=>/^\d+$/.test(i.str)&&i.transform[4]>projectLabel.transform[4]&&i.transform[4]<180&&Math.abs(i.transform[5]-projectLabel.transform[5])<8)?.str||'':'';
  if(index===0){
   const supplierLine=lines.findIndex(l=>/Fornecedor\s+\d+/.test(l.text));
   result.supplier=lines.slice(0,Math.max(0,supplierLine)).flatMap(l=>l.cells.filter(c=>c.x<290).map(c=>c.text)).join(' ').replace(/^Hoja.*?de\s+\d+\s*/,'').slice(0,500);
   const buyer=lines.findIndex(l=>/Comprador/.test(l.text));
   result.buyer=buyer>=0?lines.slice(buyer+1,buyer+4).flatMap(l=>l.cells.filter(c=>c.x>290).map(c=>c.text)).join(' ').slice(0,250):'';
  }
  // Labels have their own columns. They are cross-checks, never order rows.
  for(const line of lines){
   for(const cell of line.cells){
    if(!/Ord:/.test(cell.text))continue;
    const columnText=line.cells.filter(c=>c.x>=cell.x&&c.x<cell.x+185).map(c=>c.text).join(' ');
    const label=columnText.match(/Ord:\s*((?:VH|EZ)\d+)\s*-\s*L:\s*(\d+)/i);
    if(!label)continue;
    const below=lines.filter(l=>l.y<line.y&&l.y>line.y-65).flatMap(l=>l.cells.filter(c=>c.x>=cell.x&&c.x<cell.x+185).map(c=>c.text)).join(' ');
    labels.push({order:label[1],line:label[2],code:below.match(/Art:\s*((?:BMA|BPZ)\d{7})/i)?.[1],dest:below.match(/Dest:\s*(\d+)\s*-\s*(\d+)/i),qty:decimal(below.match(/QTY:\s*([\d,.]+)/i)?.[1])});
   }
  }
  if(!/Linha do|Linha\s+do/i.test(all)||!/Pedido/.test(all)||!/DESCRI/i.test(all))continue;
  const tableHeader=lines.findIndex(l=>/DESCRI/i.test(l.text));
  const starts=lines.map((line,i)=>({line,i})).filter(({line,i})=>i>tableHeader&&(
   line.cells.some(c=>c.x>60&&c.x<355&&/^(?:BMA|BPZ)\d{7}\s*-/.test(c.text))||
   (line.cells.some(c=>c.x>=32&&c.x<60&&/^\d+$/.test(c.text))&&line.cells.some(c=>c.x>=60&&c.x<355))
  ));
  for(const [position,start] of starts.entries()){
   const codeCell=start.line.cells.find(c=>/^(?:BMA|BPZ)\d{7}\s*-/.test(c.text))||start.line.cells.find(c=>c.x>=60&&c.x<355);
   const block=lines.slice(start.i,starts[position+1]?.i??lines.length);
   const detail=block.find(l=>/L:\s*\d+/.test(l.text));
   const target=detail?.text.match(/L:\s*(\d+)\s*-\s*(\d+)\s*-\s*(\d+)/);
   const prefix=codeCell.text.match(/^((?:BMA|BPZ)\d{7})\s*-\s*(.*)/);
   const descriptionEnd=block.findIndex(l=>/Fab\.|L:\s*\d+/.test(l.text));
   const descriptionCells=block.slice(0,descriptionEnd<0?1:descriptionEnd).flatMap(l=>l.cells.filter(c=>c.x>=codeCell.x&&c.x<355).map(c=>c.text)).join(' ');
   const quantity=start.line.cells.find(c=>c.x>=355&&c.x<398)?.text;
   const row={order:result.order,sequence:start.line.cells.find(c=>c.x<60&&/^\d+$/.test(c.text))?.text||'',line:target?.[1]||detail?.text.match(/L:\s*(\d+)/)?.[1]||'',code:prefix?.[1]||'',description:descriptionCells.replace(/^(?:BMA|BPZ)\d{7}\s*-\s*/,''),ordered:decimal(quantity),project:target?.[2]||'',station:target?.[3]||'',drawing:(result.order.startsWith('EZ')?detail?.cells.filter(c=>c.x<355).map(c=>c.text).join(' ').match(/Plano:\s*(.*?)(?:\s+Rev:|$)/i)?.[1]?.trim():detail?.text.match(/Plano:\s*(\S+)/i)?.[1])||'',revision:detail?.text.match(/Rev:\s*(\S+)/i)?.[1]||'',due:detail?.text.match(/\d{2}\/\d{2}\/\d{4}/)?.[0]||'',page:index+1,warnings:[]};
   const detailQty=decimal(detail?.cells.find(c=>c.x>=355&&c.x<398)?.text);
   if(detailQty!==null&&detailQty!==row.ordered)row.warnings.push('Quantidade da linha difere do detalhamento');
   row.errors=validateOrderRow(row);
   result.rows.push(row);
  }
 }
 if(!result.rows.length)throw Error('Nenhuma tabela de pedido reconhecida. PDF digitalizado requer uma versão com camada de texto.');
 if(result.rows.length>PDF_LIMITS.rows)throw Error('Quantidade de linhas excede o limite.');
 const identities=new Set();
 for(const row of result.rows){
  const key=[row.order,row.line,row.code,row.project,row.station].join('|');
  if(identities.has(key))row.errors.push('Linha lógica repetida na tabela');
  identities.add(key);
  const refs=labels.filter(l=>l.order===row.order&&l.line===row.line);
  if(refs.some(l=>(l.code&&l.code!==row.code)||(l.dest&&(l.dest[1]!==row.project||l.dest[2]!==row.station))||(l.qty!==null&&l.qty!==row.ordered)))row.warnings.push('Divergência entre tabela e etiqueta');
 }
 return result;
}

export async function readOrderPdf(file,onProgress=()=>{}) {
 if(!/\.pdf$/i.test(file.name)||file.size>PDF_LIMITS.bytes||file.size<5)throw Error('Selecione um PDF de até 20 MB.');
 const data=new Uint8Array(await file.arrayBuffer());
 if(new TextDecoder().decode(data.slice(0,5))!=='%PDF-')throw Error('A assinatura do arquivo não corresponde a um PDF.');
 const pdfjs=await import('./vendor/pdfjs/pdf.mjs');
 pdfjs.GlobalWorkerOptions.workerSrc=new URL('./vendor/pdfjs/pdf.worker.mjs',import.meta.url).href;
 let pdf,task;
 try{
  task=pdfjs.getDocument({data:data.slice(),isEvalSupported:false,enableXfa:false,stopAtErrors:true});
  pdf=await task.promise;
  if(pdf.numPages>PDF_LIMITS.pages)throw Error('O PDF excede 200 páginas.');
  const pages=[];
  for(let n=1;n<=pdf.numPages;n++){const page=await pdf.getPage(n);pages.push((await page.getTextContent()).items);onProgress(n,pdf.numPages);page.cleanup();}
  const parsed=parseOrderPages(pages);
  return {...parsed,pages:pdf.numPages,hash:Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256',data)),b=>b.toString(16).padStart(2,'0')).join('')};
 }catch(error){
  if(error.name==='PasswordException')throw Error('PDF protegido por senha. Forneça uma cópia desbloqueada.');
  if(error.name==='InvalidPDFException'||error.name==='FormatError')throw Error('PDF corrompido ou inválido. Solicite uma nova cópia do pedido.');
  throw error;
 }
 finally{await task?.destroy();}
}

export function groupOrderRows(rows) {
 const groups=new Map();
 for(const row of rows){const key=row.project+'|'+row.station;const group=groups.get(key)||{project:row.project,station:row.station,rows:[],qty:0};group.rows.push(row);group.qty=Math.round((group.qty+Number(row.quantity??row.ordered))*100)/100;groups.set(key,group);}
 return [...groups.values()].sort((a,b)=>a.project.localeCompare(b.project)||a.station.localeCompare(b.station));
}
