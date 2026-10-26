-- All changes (including configuration, audit and fixture claims) are rolled back.
-- Explicit fixture numbers do not consume document sequences. No mail is sent.
begin;
select set_config('request.jwt.claim.sub',(select user_id::text from public.app_members where active and role='admin' order by user_id limit 1),true);
do $$
declare d public.picking_documents; ids uuid[]:='{}'; idx int; p text:='__MULTI_FIXED_'||txid_current(); b text:=gen_random_uuid()::text;
begin
 perform set_config('test.multi_before',(select md5(coalesce(jsonb_agg(to_jsonb(x) order by id)::text,'')) from public.picking_documents x),true);
 perform set_config('test.multi_finalize',pg_get_functiondef('public.finalize_picking(uuid,jsonb,text,text)'::regprocedure),true);
 perform set_config('test.multi_project',p,true);
 perform set_config('test.multi_admin',auth.uid()::text,true);
 perform set_config('test.multi_operator',(select user_id::text from public.app_members where active and role='operator' order by user_id limit 1),true);
 perform public.save_project_manager(null,p,'gestor-multi@example.com',true);
 for idx in 1..4 loop
  insert into public.picking_documents(number,owner_id,responsible,project,station,boxes,items) overriding system value
  values(-(txid_current()*100+idx),auth.uid(),'Multi recipient fixture',p,'1',jsonb_build_array(jsonb_build_object('id',b,'name','Caixa 01')),
   jsonb_build_array(jsonb_build_object('id',gen_random_uuid(),'code','BMA0000001','project',p,'station','1','qty',1,'box',b))) returning * into d;
  ids:=array_append(ids,d.id);
 end loop;
 perform set_config('test.multi_ids',to_jsonb(ids)::text,true);
end $$;
set local role authenticated;
do $$
declare config jsonb:='[{"role":"PCP","email":"p1@example.com"},{"role":"PCP","email":"p2@example.com"},{"role":"Almoxarifado","email":"a1@example.com"},{"role":"Almoxarifado","email":"a2@example.com"}]';
 ids uuid[]; s jsonb; again jsonb; saved jsonb; bad jsonb; maximum jsonb; all_ids jsonb; doc public.picking_documents; rejected boolean; claim jsonb; admin text:=auth.uid()::text; idx int;
begin
 select array_agg(value::uuid) into ids from jsonb_array_elements_text(current_setting('test.multi_ids')::jsonb);
 perform public.set_recipients(config);
 if (select count(*) from public.notification_recipients where role='PCP')<>2 or (select count(*) from public.notification_recipients where role='Almoxarifado')<>2 then raise exception 'Two addresses per area failed';end if;
 s:=public.preview_recipients(ids[1],'["extra@example.com"]');
 if jsonb_array_length(s->'emails')<>6 or jsonb_array_length(s->'roles')<>6 then raise exception 'Fixed+manager+additional union failed';end if;
 select jsonb_agg(to_jsonb(r) order by id) into all_ids from public.notification_recipients r;
 -- Equivalent order/case/whitespace must not change either identity or approval.
 perform public.set_recipients('[{"role":"Almoxarifado","email":" A2@EXAMPLE.COM "},{"role":"PCP","email":"P2@EXAMPLE.COM"},{"role":"Almoxarifado","email":"a1@example.com"},{"role":"PCP","email":"p1@example.com"}]');
 again:=public.preview_recipients(ids[1],'[" EXTRA@EXAMPLE.COM ","extra@example.com"]','  ');
 if s->>'fingerprint'<>again->>'fingerprint' then raise exception 'Equivalent fingerprint differs';end if;
 if (select jsonb_agg(to_jsonb(r) order by id) from public.notification_recipients r)<>all_ids then raise exception 'Equivalent save rewrote recipients';end if;
 doc:=public.finalize_picking(ids[1],'["extra@example.com"]',null,s->>'fingerprint');
 if doc.status<>'confirmed' or doc.email_recipients<>s->'emails' or doc.recipient_snapshot<>s then raise exception 'Snapshot not frozen';end if;
 saved:=to_jsonb(doc);
 if to_jsonb(public.finalize_picking(ids[1],'[]',null,s->>'fingerprint'))<>saved then raise exception 'Duplicate confirmation changed snapshot';end if;

 config:=config||'[{"role":"PCP","email":"p3@example.com"}]';perform public.set_recipients(config);
 if (select count(*) from public.notification_recipients where role='PCP')<>3 then raise exception 'Third address failed';end if;
 config:=jsonb_set(config,'{1,email}','"edited@example.com"');perform public.set_recipients(config);
 if exists(select 1 from public.notification_recipients where email='p2@example.com') or not exists(select 1 from public.notification_recipients where email='edited@example.com') then raise exception 'Edit failed';end if;
 config:=config-4;perform public.set_recipients(config);
 if exists(select 1 from public.notification_recipients where email='p3@example.com') then raise exception 'Removal failed';end if;
 -- Validate before any mutation: rejected saves retain every configured row.
 select jsonb_agg(to_jsonb(r) order by id) into all_ids from public.notification_recipients r;
 for bad in select value from jsonb_array_elements(jsonb_build_array(
  '[{"role":"PCP","email":"p@example.com"},{"role":"PCP","email":"q@example.com"}]'::jsonb,
  jsonb_set(config,'{0,email}','"bad-email"'),jsonb_set(config,'{0,email}','null'),
  jsonb_set(config,'{0,role}','null'),config||'[{"role":"PCP","email":" P1@EXAMPLE.COM "}]'::jsonb)) loop
  rejected:=false;begin perform public.set_recipients(bad);exception when others then rejected:=true;end;
  if not rejected then raise exception 'Invalid/duplicate/empty area accepted';end if;
  if (select jsonb_agg(to_jsonb(r) order by id) from public.notification_recipients r)<>all_ids then raise exception 'Rejected save mutated configuration';end if;
 end loop;
 -- Cross-area duplicates remain visible by area but appear once in delivery.
 config:=jsonb_set(config,'{2,email}','" P1@EXAMPLE.COM "');perform public.set_recipients(config);
 s:=public.preview_recipients(ids[2],'["extra@example.com","gestor-multi@example.com","p1@example.com"]');
 if jsonb_array_length(s->'emails')<>5 then raise exception 'Cross-origin deduplication failed';end if;
 -- A real change requires new approval, with no status/email side effects.
 config:=jsonb_set(config,'{0,email}','"changed@example.com"');perform public.set_recipients(config);
 rejected:=false;begin perform public.finalize_picking(ids[2],'["extra@example.com","gestor-multi@example.com","p1@example.com"]',null,s->>'fingerprint');exception when sqlstate 'P4091' then rejected:=true;end;
 if not rejected then raise exception 'Changed fixed recipients not blocked';end if;
 select * into doc from public.picking_documents where id=ids[2];
 if doc.status<>'draft' or doc.recipient_snapshot is not null then raise exception 'Rejected confirmation modified document or claimed mail';end if;
 rejected:=false;begin perform public.claim_manifest_email(ids[2]);exception when others then rejected:=true;end;if not rejected then raise exception 'Draft mail claim allowed';end if;
 again:=public.preview_recipients(ids[2],'["extra@example.com"]');
 doc:=public.finalize_picking(ids[2],'["extra@example.com"]',null,again->>'fingerprint');if doc.status<>'confirmed' then raise exception 'New approval failed';end if;
 if (select to_jsonb(d) from public.picking_documents d where id=ids[1])<>saved then raise exception 'Confirmed document recipients changed';end if;
 if public.preview_recipients(ids[1])->'emails'<>saved->'email_recipients' then raise exception 'Frozen preview changed';end if;
 -- Full operational limit: 60 fixed + manager + 30 additional = 91.
 select jsonb_agg(jsonb_build_object('role',r,'email',lower(r)||i||'@example.com')) into maximum from unnest(array['PCP','Almoxarifado']) r cross join generate_series(1,30) i;
 perform public.set_recipients(maximum);
 rejected:=false;begin perform public.set_recipients(maximum||'[{"role":"PCP","email":"overflow@example.com"}]');exception when others then rejected:=true;end;if not rejected then raise exception 'Area limit not enforced';end if;
 select jsonb_agg('additional'||i||'@example.com') into bad from generate_series(1,30) i;
 s:=public.preview_recipients(ids[3],bad);if jsonb_array_length(s->'emails')<>91 then raise exception 'Full recipient limit failed';end if;
 doc:=public.finalize_picking(ids[3],bad,null,s->>'fingerprint');
 claim:=public.claim_manifest_email(ids[3]);if claim->>'token' is null or claim->'document'->'email_recipients'<>s->'emails' then raise exception 'Claim did not use frozen recipients';end if;
 if not (public.claim_manifest_email(ids[3])->>'blocked')::boolean then raise exception 'Duplicate claim allowed';end if;
 -- Operator can read all fixed addresses, but cannot save or write directly.
 perform set_config('request.jwt.claim.sub',current_setting('test.multi_operator'),true);
 if (select count(*) from public.notification_recipients where role in ('PCP','Almoxarifado'))<>60 then raise exception 'Operator read denied';end if;
 rejected:=false;begin perform public.set_recipients(config);exception when insufficient_privilege then rejected:=true;end;if not rejected then raise exception 'Operator RPC write allowed';end if;
 rejected:=false;begin insert into public.notification_recipients(role,email) values('PCP','bypass@example.com');exception when insufficient_privilege then rejected:=true;end;if not rejected then raise exception 'Operator direct insert allowed';end if;
 rejected:=false;begin update public.notification_recipients set email='bypass@example.com' where role='PCP';exception when insufficient_privilege then rejected:=true;end;if not rejected then raise exception 'Operator direct update allowed';end if;
 rejected:=false;begin delete from public.notification_recipients where role='PCP';exception when insufficient_privilege then rejected:=true;end;if not rejected then raise exception 'Operator direct delete allowed';end if;
 perform set_config('request.jwt.claim.sub',admin,true);
end $$;
reset role;
do $$
begin
 if exists(select 1 from smart_private.email_attempts where document_id in(select value::uuid from jsonb_array_elements_text(current_setting('test.multi_ids')::jsonb) with ordinality t(value,n) where n<>3)) then raise exception 'Unexpected fixture mail claim';end if;
 if (select count(*) from smart_private.email_attempts where document_id=(current_setting('test.multi_ids')::jsonb->>2)::uuid)<>1 then raise exception 'Duplicate fixture mail claims';end if;
 if not exists(select 1 from smart_private.audit_log where actor_id=current_setting('test.multi_admin')::uuid and action='recipients.save' and case when jsonb_typeof(details)='array' then jsonb_array_length(details) else 0 end=60) then raise exception 'Audit missing';end if;
 if current_setting('test.multi_before')<>(select md5(coalesce(jsonb_agg(to_jsonb(d) order by id)::text,'')) from public.picking_documents d where not id in(select value::uuid from jsonb_array_elements_text(current_setting('test.multi_ids')::jsonb))) then raise exception 'Operational documents changed';end if;
 if current_setting('test.multi_finalize')<>pg_get_functiondef('public.finalize_picking(uuid,jsonb,text,text)'::regprocedure) then raise exception 'Finalize/destination validation changed';end if;
 if has_function_privilege('anon','public.set_recipients(jsonb)','execute') or not (select relrowsecurity from pg_class where oid='public.notification_recipients'::regclass) then raise exception 'RLS/anonymous access weakened';end if;
end $$;
select 'PASS: multiple fixed recipients, CRUD/validation, canonical fingerprint, frozen snapshot, changed recipients blocked, 91 recipients, claim dedup, operator security, operational documents unchanged; rollback' as result;
rollback;
