// Local-only UI acceptance harness. PostgreSQL is disposable and contains test identities.
import http from 'node:http';
import {readFile,readdir} from 'node:fs/promises';
import {Readable} from 'node:stream';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {PGlite} from '@electric-sql/pglite';
import {readOrderPdf} from '../public/pdf-orders.js';
const root=fileURLToPath(new URL('../public/',import.meta.url));
const db=await PGlite.create(),actor='aa000000-0000-4000-8000-000000000002';
globalThis.DOMMatrix ||= class {};
await db.exec(`create role anon;create role authenticated;create role service_role bypassrls;create schema auth;create table auth.users(id uuid primary key,email text);
 create function auth.uid() returns uuid language sql stable as $$select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid$$;
 grant usage on schema public,auth to anon,authenticated,service_role;grant execute on function auth.uid() to public;
 create schema storage;create table storage.buckets(id text primary key,name text,public boolean,file_size_limit bigint,allowed_mime_types text[]);
 insert into auth.users values('${actor}','acceptance@example.invalid');`);
await db.exec(await readFile(new URL('../supabase/schema.sql',import.meta.url),'utf8'));
for(const file of (await readdir(new URL('../supabase/migrations/',import.meta.url))).filter(n=>n.endsWith('.sql')).sort())await db.exec(await readFile(new URL('../supabase/migrations/'+file,import.meta.url),'utf8'));
await db.exec(`insert into public.app_members(user_id,full_name,role) values('${actor}','Operador de teste','admin');`);
const call=async(name,args,types)=>{
 await db.exec('reset role');await db.query("select set_config('request.jwt.claim.sub',$1,false)",[actor]);await db.exec(name==='stage_pdf_order'?'set role service_role':'set role authenticated');
 return (await db.query(`select to_jsonb(public.${name}(${args.map((_,i)=>'$'+(i+1)+'::'+types[i]).join(',')})) as value`,args)).rows[0].value;
};
const methods={begin_pdf_import:['uuid'],preview_pdf_import:['uuid'],confirm_pdf_import:['uuid','jsonb'],pdf_import_history:['jsonb','integer'],pdf_import_details:['uuid'],cancel_pdf_import:['uuid','text'],review_pdf_order_line:['uuid','integer','text']};
let queue=Promise.resolve();
const html=`<!doctype html><html lang="pt-BR"><meta charset="utf-8"><meta name="viewport" content="width=device-width"><link rel="stylesheet" href="/style.css"><title>Teste local · Importar pedidos PDF</title><body style="padding:24px"><h1>Importar pedidos PDF</h1><p>Homologação local · banco descartável · arquivos permanecem neste computador</p><label>Simular largura da área de trabalho <select id="qa-width" onchange="document.getElementById('page').style.width=this.value"><option value="100%">Desktop</option><option value="768px">Tablet 768 px</option><option value="390px">Celular 390 px</option></select></label><main id="page" style="max-width:100%"></main><script type="module">
 import {mountPdfImports} from '/pdf-import-view.js';
 const rpc=async(name,...args)=>{const r=await fetch('/rpc/'+name,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(args)});const v=await r.json();if(!r.ok)throw Error(v.message);return v;};
 const api={beginPdfImport:id=>rpc('begin_pdf_import',id),stagePdfOrder:async(batch,file)=>{const f=new FormData();f.set('batch',batch);f.set('file',file);const r=await fetch('/stage',{method:'POST',body:f});const v=await r.json();if(!r.ok)throw Error(v.message);return v;},previewPdfImport:id=>rpc('preview_pdf_import',id),confirmPdfImport:(id,s)=>rpc('confirm_pdf_import',id,s),pdfImportHistory:(f,p)=>rpc('pdf_import_history',f,p),pdfImportDetails:id=>rpc('pdf_import_details',id),cancelPdfImport:(id,r)=>rpc('cancel_pdf_import',id,r),reviewPdfOrderLine:(f,i,r)=>rpc('review_pdf_order_line',f,i,r),pdfOrderFile:async()=>{throw Error('Download usa o armazenamento privado no ambiente implantado.');}};
 mountPdfImports(document.querySelector('#page'),{api,userId:'${actor}',readOnly:false,admin:true,openDocument:id=>alert('Separação gerada: '+id),toast:alert});
 </script></body></html>`;
http.createServer((req,res)=>{
 queue=queue.then(async()=>{
  try{
   const url=new URL(req.url,'http://127.0.0.1');
   if(url.pathname==='/'&&url.searchParams.has('source')){res.writeHead(200,{'Content-Type':'text/html; charset=utf-8'}).end(await readFile(new URL('../tmp/pdf-edge-deploy.html',import.meta.url),'utf8'));return;}
   if(url.pathname==='/'){res.writeHead(200,{'Content-Type':'text/html; charset=utf-8'}).end(html);return;}
   if(url.pathname==='/stage'){
    const form=await new Response(Readable.toWeb(req),{headers:req.headers}).formData(),file=form.get('file'),batch=form.get('batch');
    const parsed=await readOrderPdf(file);
    const id=await call('stage_pdf_order',[actor,batch,file.name,parsed.hash,actor+'/'+batch+'/'+parsed.hash+'.pdf',parsed.pages,JSON.stringify(parsed)],['uuid','uuid','text','text','text','integer','jsonb']);
    res.writeHead(200,{'Content-Type':'application/json'}).end(JSON.stringify({id,hash:parsed.hash,rows:parsed.rows.length,pages:parsed.pages}));return;
   }
   if(url.pathname.startsWith('/rpc/')){
    const name=url.pathname.slice(5);if(!methods[name])throw Error('RPC inválida');
    const args=await new Response(Readable.toWeb(req)).json();
    const value=await call(name,args.map((v,i)=>methods[name][i]==='jsonb'?JSON.stringify(v):v),methods[name]);
    res.writeHead(200,{'Content-Type':'application/json'}).end(JSON.stringify(value));return;
   }
   const file=path.resolve(root,'.'+decodeURIComponent(url.pathname));if(!file.startsWith(root))throw Error('Caminho inválido');
   const body=await readFile(file),extension=path.extname(file);
   res.writeHead(200,{'Content-Type':['.js','.mjs'].includes(extension)?'text/javascript; charset=utf-8':extension==='.css'?'text/css; charset=utf-8':'application/octet-stream'}).end(body);
  }catch(error){res.writeHead(400,{'Content-Type':'application/json'}).end(JSON.stringify({message:error.message}));}
 }).catch(()=>{res.writeHead(500).end();});
}).listen(4181,'127.0.0.1',()=>console.log('Homologação PDF local: http://127.0.0.1:4181'));
