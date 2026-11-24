import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync,readdirSync} from 'node:fs';
import {randomUUID} from 'node:crypto';
import {PGlite} from '@electric-sql/pglite';
const root=new URL('../',import.meta.url),sql=p=>readFileSync(new URL(p,root),'utf8');
test('PostgreSQL: Elétrica opcional, snapshot imutável, CC, compatibilidade e permissões',async()=>{
 const db=await PGlite.create();
 const admin='bb000000-0000-4000-8000-000000000001',operator='bb000000-0000-4000-8000-000000000002',reader='bb000000-0000-4000-8000-000000000003';
 try{
 await db.exec(`create role anon;create role authenticated;create role service_role bypassrls;create schema auth;create table auth.users(id uuid primary key,email text);
 create function auth.uid() returns uuid language sql stable as $$select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid$$;
 grant usage on schema public,auth to anon,authenticated,service_role;grant execute on function auth.uid() to public;
 create schema storage;create table storage.buckets(id text primary key,name text,public boolean,file_size_limit bigint,allowed_mime_types text[]);
 insert into auth.users values('${admin}','admin@example.invalid'),('${operator}','operator@example.invalid'),('${reader}','reader@example.invalid');`);
 await db.exec(sql('supabase/schema.sql'));
 for(const name of readdirSync(new URL('supabase/migrations/',root)).filter(n=>n.endsWith('.sql')).sort())await db.exec(sql('supabase/migrations/'+name));
 await db.exec(`insert into public.app_members(user_id,full_name,role) values('${admin}','Admin','admin'),('${operator}','Operador','operator'),('${reader}','Leitor','reader');
 insert into public.project_managers(project_code,email,created_by,updated_by) values('26005','manager@example.com','${admin}','${admin}');`);
 const actor=async id=>{await db.exec('reset role');await db.query("select set_config('request.jwt.claim.sub',$1,false)",[id]);await db.exec('set role authenticated');};
 const rpc=async(name,args,types)=>(await db.query(`select to_jsonb(public.${name}(${args.map((_,i)=>'$'+(i+1)+'::'+types[i]).join(',')})) value`,args)).rows[0].value;
 const normal=[{role:'PCP',email:'p@example.com'},{role:'Almoxarifado',email:'a@example.com'}];
 const save=rows=>rpc('set_recipients',[JSON.stringify(rows),true],['jsonb','boolean']);
 const preview=(doc,flag)=>rpc('preview_recipients',[doc.id,'[]',null,flag],['uuid','jsonb','text','boolean']);
 const finalize=(doc,snapshot,flag)=>rpc('finalize_picking',[doc.id,'[]',null,snapshot.fingerprint,flag],['uuid','jsonb','text','text','boolean']);
 const draft=async()=>{
 await actor(operator);let d=await rpc('create_picking',['26005','31050'],['text','text']);
 const physical=await rpc('create_physical_box',[d.id,randomUUID(),'Caixa teste'],['uuid','uuid','text']);
 d.boxes=d.boxes.map(b=>({...b,physical_box_id:physical.id}));
 const items=[{id:randomUUID(),code:'BMA0000001',project:'26005',station:'31050',qty:1,box:d.boxes[0].id}];
 const duplicate=await rpc('preview_item_duplicates',[d.id,JSON.stringify(items[0])],['uuid','jsonb']);if(duplicate.total)items[0].duplicate_ack={fingerprint:duplicate.fingerprint,reason:'Operação independente no teste de Elétrica'};
 d=await rpc('save_picking_versioned',[d.id,d.project,d.station,JSON.stringify(d.boxes),JSON.stringify(items),d.revision],['uuid','text','text','jsonb','jsonb','bigint']);return {d,physical};
 };
 await actor(admin);await save(normal);
 const {d,physical}=await draft();assert.equal(d.material_eletrico,false);
 const plain=await preview(d,false);assert.equal(plain.material_eletrico,false);assert.deepEqual(plain.cc,[]);assert.equal(plain.emails.length,3);
 await assert.rejects(preview(d,true),/Nenhum destinatário da Elétrica/);
 await actor(admin);const configured=[...normal,{role:'Elétrica',email:' E@EXAMPLE.COM '},{role:'Elétrica',email:'P@example.com'}];await save(configured);
 const before=await db.query('select id,role,email from public.notification_recipients order by role,email');
 await assert.rejects(save([...configured,{role:'Elétrica',email:'e@example.com'}]),/repetidos/);
 await assert.rejects(save([...normal,{role:'Elétrica',email:'bad'}]),/válidos/);
 await assert.rejects(save([...normal,...Array.from({length:31},(_,i)=>({role:'Elétrica',email:'e'+i+'@example.com'}))]),/30/);
 assert.deepEqual((await db.query('select id,role,email from public.notification_recipients order by role,email')).rows,before.rows);
 // A legacy settings client must preserve the optional area.
 await rpc('set_recipients',[JSON.stringify(normal)],['jsonb']);assert.equal((await db.query("select count(*)::int n from public.notification_recipients where role='Elétrica'")).rows[0].n,2);
 await actor(operator);await assert.rejects(save(configured),/autorizado/);
 const electric=await preview(d,true);assert.deepEqual(electric.cc,['e@example.com']);assert.deepEqual(electric.to,plain.to);assert.equal(electric.emails.length,4);assert.notEqual(electric.fingerprint,plain.fingerprint);
 assert.equal((await preview(d,false)).fingerprint,plain.fingerprint);
 await actor(admin);await save([...normal,{role:'Elétrica',email:'new@example.com'}]);
 await actor(operator);await assert.rejects(finalize(d,electric,true),/mudaram/);assert.equal((await db.query('select status from public.picking_documents where id=$1',[d.id])).rows[0].status,'draft');
 const approved=await preview(d,true),confirmed=await finalize(d,approved,true);assert.equal(confirmed.material_eletrico,true);assert.deepEqual(confirmed.recipient_snapshot.cc,['new@example.com']);
 assert.equal((await finalize(d,approved,false)).confirmed_at,confirmed.confirmed_at);
 const delivery=await rpc('preview_box_delivery',[physical.id,null],['uuid','text']);assert.ok(!delivery.recipient_snapshot.emails.includes('new@example.com'));
 await actor(admin);await save([...normal,{role:'Elétrica',email:'later@example.com'}]);
 await actor(operator);const frozen=await preview(d,false);assert.deepEqual(frozen.cc,['new@example.com']);assert.equal(frozen.material_eletrico,true);
 const claimed=await rpc('claim_manifest_email',[d.id],['uuid']);assert.deepEqual(claimed.document.recipient_snapshot.cc,['new@example.com']);assert.equal((await rpc('claim_manifest_email',[d.id],['uuid'])).blocked,true);
 await actor(reader);await assert.rejects(preview(d,true),/operadores/);await assert.rejects(finalize(d,approved,true),/operadores/);await assert.rejects(save(normal),/autorizado/);
 await db.exec('reset role;set role anon');await assert.rejects(preview(d,false),/permission denied/);
 const other=await draft();const normalSnapshot=await preview(other.d,false);const ordinary=await finalize(other.d,normalSnapshot,false);assert.equal(ordinary.material_eletrico,false);assert.deepEqual(ordinary.recipient_snapshot.cc,[]);assert.ok(!ordinary.email_recipients.includes('later@example.com'));

 // Exercise the complete legal maximum through configuration, confirmation and reservation.
 await actor(admin);await save(['PCP','Almoxarifado','Elétrica'].flatMap((role,n)=>Array.from({length:30},(_,i)=>({role,email:'area'+n+'-'+i+'@example.com'}))));
 const maximum=await draft(),additional=JSON.stringify(Array.from({length:30},(_,i)=>'extra'+i+'@example.com'));
 const maxSnapshot=await rpc('preview_recipients',[maximum.d.id,additional,null,true],['uuid','jsonb','text','boolean']);assert.equal(maxSnapshot.emails.length,121);assert.equal(maxSnapshot.cc.length,30);
 const maxDoc=await rpc('finalize_picking',[maximum.d.id,additional,null,maxSnapshot.fingerprint,true],['uuid','jsonb','text','text','boolean']);assert.equal(maxDoc.email_recipients.length,121);
 assert.ok((await rpc('claim_manifest_email',[maxDoc.id],['uuid'])).token);
 await db.exec('reset role');assert.ok((await db.query("select details from smart_private.audit_log where action='picking.confirm' and target_id=$1",[d.id])).rows[0].details.material_eletrico);
 }finally{await db.close();}
});

