import {createClient} from 'https://esm.sh/@supabase/supabase-js@2.49.8';
// Canonical BMA/BPZ extractor shared with the browser, using pinned local PDF.js.
import {readOrderPdf,PDF_LIMITS} from '../../../public/pdf-orders.js';

const cors={'Access-Control-Allow-Origin':'https://almoxarifadomondragon.github.io','Access-Control-Allow-Headers':'authorization,apikey,content-type','Access-Control-Allow-Methods':'POST,OPTIONS'};
const reply=(data:unknown,status=200)=>new Response(JSON.stringify(data),{status,headers:{...cors,'Content-Type':'application/json'}});
// Text extraction never renders a page or executes PDF actions.
if(!('DOMMatrix' in globalThis))Object.assign(globalThis,{DOMMatrix:class {}});
Object.assign(globalThis,{pdfjsWorker:await import('../../../public/vendor/pdfjs/pdf.worker.mjs')});

Deno.serve(async req=>{
 if(req.method==='OPTIONS')return new Response(null,{headers:cors});
 if(req.method!=='POST')return reply({message:'Método não permitido.'},405);
 try{
  const url=Deno.env.get('SUPABASE_URL')!,key=Deno.env.get('SUPABASE_ANON_KEY')!;
  const auth=req.headers.get('Authorization')||'';
  const client=createClient(url,key,{global:{headers:{Authorization:auth}},auth:{persistSession:false}});
  const {data:{user},error:authError}=await client.auth.getUser();
  if(authError||!user)return reply({message:'Sessão inválida.'},401);
  const {data:member}=await client.from('app_members').select('role,active').eq('user_id',user.id).single();
  if(!member?.active)return reply({message:'Usuário não autorizado.'},403);
  const service=createClient(url,Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,{auth:{persistSession:false}});
  if(req.headers.get('Content-Type')?.includes('application/json')){
   const {file_id}=await req.json();
   const {data:path,error}=await client.rpc('pdf_order_file',{p_id:file_id});
   if(error||!path)return reply({message:'Arquivo indisponível.'},404);
   const {data,error:signError}=await service.storage.from('picking-order-pdfs').createSignedUrl(path,60);
   if(signError)throw Error('Não foi possível abrir o PDF.');
   return reply({url:data.signedUrl});
  }
  if(!['admin','operator'].includes(member.role))return reply({message:'Perfil Leitor: somente consulta.'},403);
  if(Number(req.headers.get('Content-Length'))>PDF_LIMITS.bytes+65536)return reply({message:'Arquivo muito grande.'},413);
  const reader=req.body?.getReader(),chunks:ArrayBuffer[]=[];
  let size=0;
  if(!reader)return reply({message:'Arquivo ausente.'},400);
  while(true){
   const {done,value}=await reader.read();if(done)break;
   size+=value.length;
   if(size>PDF_LIMITS.bytes+65536){await reader.cancel();return reply({message:'Arquivo muito grande.'},413);}
   chunks.push(new Uint8Array(value).buffer);
  }
  const form=await new Response(new Blob(chunks),{headers:{'Content-Type':req.headers.get('Content-Type')||''}}).formData();
  const file=form.get('file'),batch=form.get('batch');
  if(!(file instanceof File)||typeof batch!=='string'||!/^[a-f0-9-]{36}$/i.test(batch))return reply({message:'Informe um arquivo e lote válidos.'},400);
  const {error:batchError}=await client.rpc('begin_pdf_import',{p_id:batch});
  if(batchError)throw Error(batchError.message);
  const parsed=await readOrderPdf(file);
  const path=user.id+'/'+batch+'/'+parsed.hash+'.pdf';
  const {error:uploadError}=await service.storage.from('picking-order-pdfs').upload(path,file,{contentType:'application/pdf',upsert:false});
  if(uploadError&&!/already exists|duplicate/i.test(uploadError.message))throw Error('Falha ao armazenar o PDF privado. Tente novamente.');
  const {data:id,error:stageError}=await service.rpc('stage_pdf_order',{p_actor:user.id,p_batch:batch,p_name:file.name,p_hash:parsed.hash,p_path:path,p_pages:parsed.pages,p_parsed:parsed});
  if(stageError)throw Error(stageError.message);
  return reply({id,hash:parsed.hash,rows:parsed.rows.length,pages:parsed.pages});
 }catch(error){return reply({message:error instanceof Error?error.message:'Falha na leitura do pedido.'},400);}
});
