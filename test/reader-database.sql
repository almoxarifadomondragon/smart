begin;
do $$ begin
 if current_setting('mondragon.test_fixture',true) is distinct from 'isolated' then
  raise exception 'Esta suíte exige um banco de testes descartável.';
 end if;
end $$;

insert into auth.users(id,email) values
 ('ac000000-0000-4000-8000-000000000001','reader-role@example.invalid');
select set_config('test.reader_admin',(select user_id::text from public.app_members where role='admin' and active limit 1),true);
select set_config('request.jwt.claim.sub',current_setting('test.reader_admin'),true);
set local role authenticated;
select set_config('test.reader_invite',(public.prepare_user_invite('reader-role@example.invalid','Perfil Leitor','reader')->>'id'),true);
reset role;
set local role service_role;
select public.complete_user_invite(current_setting('test.reader_invite')::uuid,'ac000000-0000-4000-8000-000000000001');
reset role;

set local role authenticated;
select public.admin_update_member('ac000000-0000-4000-8000-000000000001','Perfil Leitor','operator',true);
select set_config('request.jwt.claim.sub','ac000000-0000-4000-8000-000000000001',true);
do $$
declare doc public.picking_documents; box jsonb;
begin
 doc:=public.create_picking('READ-TEST','001');
 box:=public.create_physical_box(doc.id,'ac000000-0000-4000-8000-000000000002','Caixa leitora');
 perform set_config('test.reader_doc',doc.id::text,true);
end $$;
select set_config('request.jwt.claim.sub',current_setting('test.reader_admin'),true);
select public.admin_update_member('ac000000-0000-4000-8000-000000000001','Perfil Leitor','reader',true);
select set_config('request.jwt.claim.sub','ac000000-0000-4000-8000-000000000001',true);
do $$
declare statement text; doc public.picking_documents;
 box uuid:='ac000000-0000-4000-8000-000000000002';
 statements text[];
begin
 select * into strict doc from public.picking_documents where id=current_setting('test.reader_doc')::uuid;
 if doc.owner_id<>auth.uid() or public.get_physical_box(box)->'box'->>'can_close'<>'false'
  or public.search_picking_documents(p_scope=>'all',p_project=>'READ-TEST')->>'total'<>'1'
  or public.search_physical_boxes(p_project=>'READ-TEST')->>'total'<>'1'
 then raise exception 'Consulta do Leitor ou propriedade do rascunho incorreta';end if;

 statements:=array[
  'select public.create_picking(''READ-TEST'',''001'')',
  format('select public.save_picking(%L,''READ-TEST'',''001'',%L::jsonb,''[]'')',doc.id,doc.boxes),
  format('select public.save_picking_versioned(%L,''READ-TEST'',''001'',%L::jsonb,''[]'',0)',doc.id,doc.boxes),
  format('select smart_private.save_picking_impl(%L,''READ-TEST'',''001'',%L::jsonb,''[]'',0)',doc.id,doc.boxes),
  format('select public.finalize_picking(%L)',doc.id),
  format('select public.preview_recipients(%L)',doc.id),
  format('select public.create_physical_box(%L,gen_random_uuid(),''Nova'')',doc.id),
  format('select public.preview_box_delivery(%L)',box),
  format('select public.close_physical_box(%L)',box),
  format('select public.close_physical_box(%L,''fingerprint'',null)',box),
  format('select public.close_physical_box(%L,''fingerprint'',null,null)',box),
  format('select public.claim_manifest_email(%L)',doc.id),
  format('select public.resolve_manifest_email(%L,false,''Justificativa de teste'')',doc.id),
  format('select public.claim_box_delivery_email(%L,%L,null,null)',box,auth.uid()),
  format('select public.reconcile_box_delivery_email(%L,false,''Justificativa de teste'')',box),
  'select public.set_recipients(''[]'')',
  'select public.save_project_manager(null,''READ-TEST'',''test@example.invalid'',true)',
  'select public.admin_list_users()',
  format('select public.admin_update_member(%L,''Leitor'',''admin'',true)',auth.uid()),
  'select public.prepare_user_invite(''bad@example.invalid'',''Usuário'',''reader'')',
  'select public.complete_user_invite(gen_random_uuid(),gen_random_uuid())',
  format('update public.picking_documents set project=''corrompido'' where id=%L',doc.id)
 ];
 foreach statement in array statements loop
  begin
   execute statement;
   raise exception 'Escrita ou operação privilegiada permitida: %',statement;
  exception when insufficient_privilege then null;
  end;
 end loop;
 if (select project from public.picking_documents where id=doc.id)<>'READ-TEST' then
  raise exception 'O rascunho foi alterado';
 end if;
end $$;
reset role;
set local role service_role;
do $$
begin
 begin
  perform public.claim_box_delivery_email('ac000000-0000-4000-8000-000000000002','ac000000-0000-4000-8000-000000000001');
  raise exception 'Edge Function poderia reservar envio em nome de um Leitor';
 exception when insufficient_privilege then null;
 end;
 begin
  perform public.claim_box_delivery_email('ac000000-0000-4000-8000-000000000002','ac000000-0000-4000-8000-000000000001',gen_random_uuid(),gen_random_uuid());
  raise exception 'Edge Function poderia reservar reenvio em nome de um Leitor';
 exception when insufficient_privilege then null;
 end;
end $$;
reset role;
set local role authenticated;
select set_config('request.jwt.claim.sub',current_setting('test.reader_admin'),true);
select public.admin_update_member('ac000000-0000-4000-8000-000000000001','Perfil Leitor','reader',false);
select set_config('request.jwt.claim.sub','ac000000-0000-4000-8000-000000000001',true);
do $$ begin
 if exists(select 1 from public.picking_documents) then raise exception 'RLS permitiu leitura de perfil inativo';end if;
 begin
  perform public.search_physical_boxes();
  raise exception 'Perfil inativo consultou as caixas';
 exception when insufficient_privilege then null;
 end;
end $$;
rollback;
