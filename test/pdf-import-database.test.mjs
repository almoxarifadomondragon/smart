import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync,readdirSync,existsSync} from 'node:fs';
import {randomUUID} from 'node:crypto';
import {PGlite} from '@electric-sql/pglite';
import {readOrderPdf} from '../public/pdf-orders.js';
const root=new URL('../',import.meta.url);
const sql=p=>readFileSync(new URL(p,root),'utf8');
const admin='aa000000-0000-4000-8000-000000000001';
const operator='aa000000-0000-4000-8000-000000000002';
const reader='aa000000-0000-4000-8000-000000000003';
test('PostgreSQL: transação, saldo entre lotes, idempotência, RLS, início e fluxo normal',async t=>{
 const db=await PGlite.create();
 try{
  await db.exec(`create role anon;create role authenticated;create role service_role bypassrls;create schema auth;
   create table auth.users(id uuid primary key,email text);create function auth.uid() returns uuid language sql stable as $$select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid$$;
   grant usage on schema public,auth to anon,authenticated,service_role;grant execute on function auth.uid() to public;
   create schema storage;create table storage.buckets(id text primary key,name text,public boolean,file_size_limit bigint,allowed_mime_types text[]);
   insert into auth.users values('${admin}','admin@example.invalid'),('${operator}','operator@example.invalid'),('${reader}','reader@example.invalid');`);
  await db.exec(sql('supabase/schema.sql'));
  for(const file of readdirSync(new URL('supabase/migrations/',root)).filter(n=>n.endsWith('.sql')).sort())await db.exec(sql('supabase/migrations/'+file));
  await db.exec(`insert into public.app_members(user_id,full_name,role) values('${admin}','Administrador','admin'),('${operator}','Operador','operator'),('${reader}','Leitor','reader');`);
  const actor=async id=>{await db.exec('reset role');await db.query("select set_config('request.jwt.claim.sub',$1,false)",[id]);await db.exec('set role authenticated');};
  const rpc=async(name,args,types)=> (await db.query(`select to_jsonb(public.${name}(${args.map((_,i)=>'$'+(i+1)+'::'+types[i]).join(',')})) as value`,args)).rows[0].value;
  const row={order:'VH1',line:'3',sequence:'1',code:'BPZ0000001',project:'26005',station:'31450',description:'Base',ordered:100,page:1,drawing:'BP26005-31450-001',revision:'A',due:'01/12/2026',warnings:[],errors:[]};
  const stage=async(batch,rows=[row],hash='a'.repeat(64))=>{
   await actor(operator);await rpc('begin_pdf_import',[batch],['uuid']);
   await db.exec('reset role;set role service_role');
   const file=await rpc('stage_pdf_order',[operator,batch,'pedido.pdf',hash,operator+'/'+batch+'/'+hash+'.pdf',200,JSON.stringify({origin:'MONDRAGON-BRASIL',order:rows[0].order,rows})],['uuid','uuid','text','text','text','integer','jsonb']);
   await actor(operator);return file;
  };
  const selection=(file,quantity,index=1)=>({file_id:file,index,quantity,project:row.project,station:row.station,description:row.description,reason:''});
  const batch=randomUUID(),file=await stage(batch),chosen=[selection(file,60)];
  const first=await rpc('confirm_pdf_import',[batch,JSON.stringify(chosen)],['uuid','jsonb']);
  assert.equal(first.length,1);assert.equal(first[0].status,'pending');
  assert.deepEqual(await rpc('confirm_pdf_import',[batch,JSON.stringify(chosen)],['uuid','jsonb']),first);
  await assert.rejects(rpc('confirm_pdf_import',[batch,JSON.stringify([selection(file,61)])],['uuid','jsonb']),/outra seleção/);
  let doc=(await db.query('select * from public.picking_documents where id=$1',[first[0].id])).rows[0];
  assert.equal(doc.items[0].source_order,'VH1');assert.equal(doc.items[0].qty,60);
  await assert.rejects(rpc('save_picking_versioned',[doc.id,doc.project,doc.station,JSON.stringify(doc.boxes),JSON.stringify(doc.items),doc.revision],['uuid','text','text','jsonb','jsonb','bigint']),/Inicie/);
  const batch2=randomUUID(),file2=await stage(batch2);
  const preview=await rpc('preview_pdf_import',[batch2],['uuid']);assert.equal(preview.files[0].rows[0].allocated,60);
  await assert.rejects(rpc('confirm_pdf_import',[batch2,JSON.stringify([selection(file2,41)])],['uuid','jsonb']),/saldo importável/);
  assert.equal((await db.query('select count(*)::int n from public.picking_documents')).rows[0].n,1);
  const second=await rpc('confirm_pdf_import',[batch2,JSON.stringify([selection(file2,25)])],['uuid','jsonb']);
  const started=await rpc('start_pdf_picking',[first[0].id],['uuid']);assert.equal(started.import_state,'active');
  await assert.rejects(rpc('start_pdf_picking',[second[0].id],['uuid']),/Conclua/);
  doc=await rpc('save_picking_versioned',[started.id,started.project,started.station,JSON.stringify(started.boxes),JSON.stringify(started.items),started.revision],['uuid','text','text','jsonb','jsonb','bigint']);
  assert.equal(doc.items[0].source_order,'VH1');
  await assert.rejects(rpc('save_picking_versioned',[doc.id,doc.project,doc.station,JSON.stringify(doc.boxes),JSON.stringify([{...doc.items[0],qty:61}]),doc.revision],['uuid','text','text','jsonb','jsonb','bigint']),/reservados/);
  await rpc('cancel_pdf_import',[batch2,'Cancelamento conferido'],['uuid','text']);
  assert.equal((await rpc('preview_pdf_import',[batch2],['uuid'])).files[0].rows[0].allocated,60);
  await assert.rejects(rpc('cancel_pdf_import',[batch,'Já iniciada'],['uuid','text']),/pendentes/);
  await actor(reader);
  assert.equal((await rpc('pdf_import_history',[{},1],['jsonb','integer'])).total,2);
  await assert.rejects(rpc('begin_pdf_import',[randomUUID()],['uuid']),/operadores/);
  await assert.rejects(rpc('confirm_pdf_import',[batch,JSON.stringify(chosen)],['uuid','jsonb']),/operadores/);
  await assert.rejects(db.query('select * from smart_private.pdf_order_lines'),/permission denied/);
  await db.exec('reset role;set role anon');
  await assert.rejects(rpc('pdf_import_history',[{},1],['jsonb','integer']),/permission denied/);
  await actor(operator);
  const changed=randomUUID(),changedFile=await stage(changed,[{...row,ordered:110}]);
  assert.equal((await rpc('preview_pdf_import',[changed],['uuid'])).files[0].rows[0].conflict,true);
  await assert.rejects(rpc('confirm_pdf_import',[changed,JSON.stringify([selection(changedFile,10)])],['uuid','jsonb']),/alterado/);
  await assert.rejects(rpc('review_pdf_order_line',[changedFile,1,'Revisão administrativa'],['uuid','integer','text']),/administrador|autorizado/);
  await actor(admin);await rpc('review_pdf_order_line',[changedFile,1,'Revisão documental aprovada'],['uuid','integer','text']);
  await actor(operator);assert.equal((await rpc('preview_pdf_import',[changed],['uuid'])).files[0].rows[0].conflict,false);

  // Exercise the normal physical-box, invoice, manifest and receipt RPCs on the imported item.
  await db.exec('reset role');
  await db.exec(`insert into public.notification_recipients(role,email) values('PCP','pcp@example.invalid'),('Almoxarifado','warehouse@example.invalid');
   insert into public.project_managers(project_code,email,active,created_by,updated_by) values('26005','manager@example.invalid',true,'${admin}','${admin}');`);
  await actor(operator);
  const physical=await rpc('create_physical_box',[doc.id,randomUUID(),'Caixa PDF teste'],['uuid','uuid','text']);
  const boxes=doc.boxes.map(b=>({...b,physical_box_id:physical.id,physical_box_code:physical.code}));
  doc=await rpc('save_picking_versioned',[doc.id,doc.project,doc.station,JSON.stringify(boxes),JSON.stringify(doc.items.map(i=>({...i,invoice_number:'NF-123'}))),doc.revision],['uuid','text','text','jsonb','jsonb','bigint']);
  const recipients=await rpc('preview_recipients',[doc.id,'[]',null],['uuid','jsonb','text']);
  const manifest=await rpc('finalize_picking',[doc.id,'[]',null,recipients.fingerprint],['uuid','jsonb','text','text']);
  assert.equal(manifest.status,'confirmed');assert.equal(manifest.items[0].invoice_number,'NF-123');assert.equal(manifest.items[0].code,'BPZ0000001');
  const review=await rpc('preview_box_delivery',[physical.id,null],['uuid','text']);
  const closed=await rpc('close_physical_box',[physical.id,review.fingerprint,null,'Entrega em teste isolado'],['uuid','text','text','text']);
  assert.equal(closed.status,'closed');assert.equal(closed.delivery.snapshot.items[0].code,'BPZ0000001');
  assert.equal(closed.delivery.snapshot.items[0].purchase_order,'1');
  assert.equal(closed.delivery.snapshot.items[0].source_order,'VH1');
  const lookup=await rpc('search_physical_boxes',[null,null,null,null,'BPZ0000001',null,null,null,'created',null,null,1],['text','text','text','text','text','text','text','text','text','date','date','integer']);
  assert.equal(lookup.total,1);
  const details=await rpc('pdf_import_details',[batch],['uuid']);assert.equal(details.allocations[0].order,'VH1');
  await actor(admin);assert.ok((await rpc('pdf_import_details',[batch],['uuid'])).audit.length>0);

  // Commit the complete reference lot only inside this disposable PostgreSQL.
  const fixtureDir=process.env.SMART_PDF_FIXTURES||'C:/Users/sn1078588/Downloads';
  const fixtureNames=['21338','21339','21340','21346','21347','21348','21349','21350','21352','21353','21519','21549','21715'].map(n=>'VH'+n+' - BP'+(n==='21715'?'25024':'26005')+' - MAK.pdf');
  await t.test('521 linhas reais geram oito separações', {skip:!fixtureNames.every(n=>existsSync(fixtureDir+'/'+n))},async()=>{
  globalThis.DOMMatrix ||= class {};
  const allBatch=randomUUID(),all=[];
  for(const n of ['21338','21339','21340','21346','21347','21348','21349','21350','21352','21353','21519','21549','21715']){
   const name='VH'+n+' - BP'+(n==='21715'?'25024':'26005')+' - MAK.pdf';
   const parsed=await readOrderPdf(new File([readFileSync(fixtureDir+'/'+name)],name));
   const staged=await stage(allBatch,parsed.rows,parsed.hash);
   all.push(...parsed.rows.map((r,i)=>({file_id:staged,index:i+1,quantity:r.ordered,project:r.project,station:r.station,description:r.description,reason:''})));
  }
  const generated=await rpc('confirm_pdf_import',[allBatch,JSON.stringify(all)],['uuid','jsonb']);
  assert.equal(generated.length,8);assert.equal(generated.reduce((n,d)=>n+d.items,0),521);
  assert.deepEqual(generated.map(g=>[g.project,g.station,g.items]),[['25024','31250',6],['26005','31050',117],['26005','31100',102],['26005','31150',15],['26005','31200',99],['26005','31300',15],['26005','31400',61],['26005','31450',106]]);
  await assert.rejects(rpc('confirm_pdf_import',[randomUUID(),JSON.stringify(all)],['uuid','jsonb']),/indisponível/);
  });
 }finally{await db.close();}
});
