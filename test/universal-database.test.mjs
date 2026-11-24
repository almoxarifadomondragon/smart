import test from 'node:test';import assert from 'node:assert/strict';import {readFileSync,readdirSync,existsSync} from 'node:fs';import {randomUUID} from 'node:crypto';import {PGlite} from '@electric-sql/pglite';import {readOrderPdf} from '../public/pdf-orders.js';
const root=new URL('../',import.meta.url),sql=p=>readFileSync(new URL(p,root),'utf8');
test('PostgreSQL universal: BMA/BPZ, origens, vínculos, ataques e duplicidade conferida',async()=>{
 const db=await PGlite.create(),admin='cc000000-0000-4000-8000-000000000001',operator='cc000000-0000-4000-8000-000000000002',reader='cc000000-0000-4000-8000-000000000003',inactive='cc000000-0000-4000-8000-000000000004';
 try{
 await db.exec(`create role anon;create role authenticated;create role service_role bypassrls;create schema auth;create table auth.users(id uuid primary key,email text);create function auth.uid() returns uuid language sql stable as $$select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid$$;grant usage on schema public,auth to anon,authenticated,service_role;grant execute on function auth.uid() to public;create schema storage;create table storage.buckets(id text primary key,name text,public boolean,file_size_limit bigint,allowed_mime_types text[]);insert into auth.users values('${admin}','a@example.invalid'),('${operator}','o@example.invalid'),('${reader}','r@example.invalid'),('${inactive}','i@example.invalid');`);
 await db.exec(sql('supabase/schema.sql'));for(const file of readdirSync(new URL('supabase/migrations/',root)).filter(n=>n.endsWith('.sql')).sort())await db.exec(sql('supabase/migrations/'+file));
 await db.exec(`insert into public.app_members(user_id,full_name,role,active) values('${admin}','Admin','admin',true),('${operator}','Operador','operator',true),('${reader}','Leitor','reader',true),('${inactive}','Inativo','operator',false);insert into public.notification_recipients(role,email) values('PCP','p@example.invalid'),('Almoxarifado','a@example.invalid');insert into public.project_managers(project_code,email,created_by,updated_by) values('26005','g@example.invalid','${admin}','${admin}');`);
 const actor=async id=>{await db.exec('reset role');await db.query("select set_config('request.jwt.claim.sub',$1,false)",[id]);await db.exec('set role authenticated');};
 const rpc=async(n,args,types)=>(await db.query(`select to_jsonb(public.${n}(${args.map((_,i)=>'$'+(i+1)+'::'+types[i]).join(',')})) v`,args)).rows[0].v;
 const create=async()=>rpc('create_picking',['26005','31450'],['text','text']);
 const save=(d,items)=>rpc('save_picking_versioned',[d.id,d.project,d.station,JSON.stringify(d.boxes),JSON.stringify(items),d.revision],['uuid','text','text','jsonb','jsonb','bigint']);
 const preview=(d,item)=>rpc('preview_item_duplicates',[d.id,JSON.stringify(item)],['uuid','jsonb']);
 const close=async d=>{const snap=await rpc('preview_recipients',[d.id,'[]',null,false],['uuid','jsonb','text','boolean']);return rpc('finalize_picking',[d.id,'[]',null,snap.fingerprint,false],['uuid','jsonb','text','text','boolean']);};
 const make=(d,code,source)=>({id:randomUUID(),code,source,project:d.project,station:d.station,qty:1,box:d.boxes[0].id,purchase_order:'21338',purchase_order_item:'3'});
 await actor(operator);let manual=await create();
 for(const [code,source] of [[' bma0001979 ','Manual'],['bpz0043578','Manual'],['BMA0000856','QR'],['BPZ0043634','QR']]){manual=await save(manual,[...manual.items,make(manual,code,source)]);assert.equal(manual.items.at(-1).code,code.trim().toUpperCase());assert.equal(manual.items.at(-1).source,source);}
 await assert.rejects(save(manual,[...manual.items,make(manual,'ABC0043578','Manual')]),/inválid/);
 await assert.rejects(save(manual,[...manual.items,{...make(manual,'BPZ0000009','QR'),qty:0}]),/Quantidade/);
 await assert.rejects(save(manual,[...manual.items,make(manual,'BPZ0000009','PDF')]),/alocação documental/);
 await assert.rejects(save(manual,[...manual.items,{...make(manual,'BMA0000009','Manual'),pdf_allocation_id:randomUUID()}]),/alocação documental/);
 const repeated=make(manual,'BPZ0043578','Manual');await assert.rejects(save(manual,[...manual.items,repeated]),/possíveis duplicados/);
 const warning=await preview(manual,repeated);assert.equal(warning.total,1);repeated.duplicate_ack={fingerprint:warning.fingerprint,reason:'Conferido registro adicional legítimo de outro pedido'};manual=await save(manual,[...manual.items,repeated]);assert.ok(manual.items.at(-1).duplicate_review);assert.equal(manual.items.at(-1).duplicate_ack,undefined);
 manual=await save(manual,manual.items.map((i,n)=>n?i:{...i,invoice_number:'NF-001'}));assert.equal(manual.items[0].source,'Manual');manual=await close(manual);
 const files=[];
 for(const prefix of ['BMA','BPZ']){
  globalThis.DOMMatrix ||= class {};const parsed=await readOrderPdf(new File([readFileSync(new URL('fixtures/synthetic-bma-order.pdf',import.meta.url))],'synthetic.pdf'));parsed.order=prefix==='BMA'?'VH99900':'VH99901';parsed.rows=parsed.rows.map(r=>({...r,order:parsed.order,code:prefix+'0000001'}));
  const batch=randomUUID();await rpc('begin_pdf_import',[batch],['uuid']);await db.exec('reset role;set role service_role');
  const f=await rpc('stage_pdf_order',[operator,batch,'synthetic.pdf',parsed.hash,operator+'/'+batch+'/'+parsed.hash+'.pdf',parsed.pages,JSON.stringify(parsed)],['uuid','uuid','text','text','text','integer','jsonb']);await actor(operator);
  const chosen=[{file_id:f,index:1,quantity:2,project:'26005',station:'31450',description:parsed.rows[0].description,reason:''}];const result=await rpc('confirm_pdf_import',[batch,JSON.stringify(chosen)],['uuid','jsonb']);assert.deepEqual(await rpc('confirm_pdf_import',[batch,JSON.stringify(chosen)],['uuid','jsonb']),result);
  let d=(await db.query('select * from public.picking_documents where id=$1',[result[0].id])).rows[0];assert.equal(d.items[0].source,'PDF');assert.ok(d.items[0].pdf_allocation_id);await assert.rejects(save(d,d.items),/Inicie/);files.push({batch,f,d});
 }
 const bma=files[0],bpz=files[1];let imported=await rpc('start_pdf_picking',[bma.d.id],['uuid']);const original=structuredClone(imported.items[0]);
 for(const change of [{code:'BMA0000002'},{source:'Manual'},{source:'QR'},{pdf_allocation_id:randomUUID()},{source_order:'VH1'},{source_line:'99'},{purchase_order:'1'},{purchase_order_item:'99'},{qty:3},{project:'999'},{station:'999'},{id:randomUUID()}])await assert.rejects(save(imported,[{...original,...change}]),/PDF|destino|peça|UUID|reserva/i);
 await assert.rejects(save(imported,[]),/excluído|UUID/);await assert.rejects(save(imported,[original,original]),/duplicad|repetida/);
 const {source,source_order,source_line,pdf_allocation_id,...omitted}=original;imported=await save(imported,[omitted]);assert.equal(imported.items[0].source,'PDF');assert.equal(imported.items[0].pdf_allocation_id,original.pdf_allocation_id);
 let other=await create();await assert.rejects(save(other,[{...make(other,'BMA0000001','Manual'),id:original.id}]),/UUID documental/);
 const extra=make(imported,'BMA0000001','Manual');extra.qty=1;extra.purchase_order='99900';extra.purchase_order_item='3';await assert.rejects(save(imported,[...imported.items,extra]),/possíveis duplicados/);
 const review=await preview(imported,extra);assert.ok(review.matches.some(m=>m.source==='PDF'));extra.duplicate_ack={fingerprint:review.fingerprint,reason:'Conferido material adicional independente sem alterar reserva PDF'};
 imported=await save(imported,[...imported.items,extra]);assert.equal(imported.items[1].source,'Manual');assert.equal(imported.items[1].pdf_allocation_id,undefined);
 assert.equal((await rpc('preview_pdf_import',[bma.batch],['uuid'])).files[0].rows[0].allocated,2);
 const changed={...imported.items[1],qty:2,duplicate_ack:extra.duplicate_ack};await assert.rejects(save(imported,[imported.items[0],changed]),/possíveis duplicados/);
 imported=await close(imported);assert.equal(imported.status,'confirmed');
 await rpc('cancel_pdf_import',[bpz.batch,'Cancelamento documental autorizado no teste'],['uuid','text']);assert.equal((await rpc('preview_pdf_import',[bpz.batch],['uuid'])).state,'cancelled');
 assert.equal((await db.query('select import_state from public.picking_documents where id=$1',[bpz.d.id])).rows[0].import_state,'cancelled');

 other=await save(other,[make(other,'BMA0000099','Manual')]);await close(other);
 // Real BMA orders use EZ instead of VH; canonical staging and allocations must accept them too.
 for(const name of ['EZ21075 - BP26002 - AWALTECH.pdf','EZ21077 - BP24005 - TRIVAX.pdf']){
  if(!existsSync('C:/Users/sn1078588/Downloads/'+name))continue;
  await actor(operator);const parsed=await readOrderPdf(new File([readFileSync('C:/Users/sn1078588/Downloads/'+name)],name));const row=parsed.rows[0],batch=randomUUID();
  await rpc('begin_pdf_import',[batch],['uuid']);await db.exec('reset role;set role service_role');
  const file=await rpc('stage_pdf_order',[operator,batch,name,parsed.hash,operator+'/'+batch+'/'+parsed.hash+'.pdf',parsed.pages,JSON.stringify(parsed)],['uuid','uuid','text','text','text','integer','jsonb']);
  await actor(operator);const selection=JSON.stringify([{file_id:file,index:1,quantity:row.ordered,project:row.project,station:row.station,description:row.description,reason:''}]);const result=await rpc('confirm_pdf_import',[batch,selection],['uuid','jsonb']);assert.deepEqual(await rpc('confirm_pdf_import',[batch,selection],['uuid','jsonb']),result);
  let d=await rpc('start_pdf_picking',[result[0].id],['uuid']);assert.equal(d.items[0].source_order,parsed.order);assert.equal(d.items[0].purchase_order,parsed.order.slice(2));assert.equal(d.items[0].code,row.code);assert.equal(d.items[0].qty,row.ordered);assert.ok(d.items[0].pdf_allocation_id);
  d=await save(d,d.items);assert.equal(d.items[0].source_order,parsed.order);assert.equal((await rpc('preview_pdf_import',[batch],['uuid'])).files[0].rows[0].allocated,row.ordered);await db.exec('reset role');await db.query("insert into public.project_managers(project_code,email,created_by,updated_by) values($1,'g@example.invalid',$2,$2) on conflict do nothing",[row.project,admin]);await actor(operator);await close(d);
 }
 await actor(reader);await assert.rejects(preview(other,make(other,'BPZ0043578','QR')),/operadores/);await assert.rejects(save(other,[]),/operadores/);
 await actor(inactive);await assert.rejects(preview(other,make(other,'BMA0001979','Manual')),/operadores/);
 await actor(admin);await assert.rejects(preview(other,make(other,'BMA0001979','Manual')),/indisponível/);
 await db.exec('reset role;set role anon');await assert.rejects(preview(other,make(other,'BMA0001979','Manual')),/permission denied/);
 await db.exec('reset role');const audit=(await db.query("select details from smart_private.audit_log where action='picking.item.add' and details->'duplicate_review' is not null")).rows;assert.ok(audit.some(r=>r.details.source==='Manual'&&r.details.duplicate_review?.reason));
 }finally{await db.close();}
});
