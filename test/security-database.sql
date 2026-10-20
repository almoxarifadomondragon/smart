-- Apenas destino de homologação. Papéis temporários revertidos ao final.
-- Requer as duas contas autorizadas; não simula login real com senha.
begin;
update public.app_members set role='operator'
where user_id=(select id from auth.users where email='denys.martinez@sp.senai.br');
select set_config('request.jwt.claim.sub',(select id::text from auth.users where email='denys.martinez@sp.senai.br'),true);
select set_config('test.other_uid',(select id::text from auth.users where email='almoxarifado.br@mondragon-assembly.com'),true);
set local role authenticated;
do $$
declare d public.picking_documents; owner_uid text:=auth.uid()::text; rejected boolean;
begin
 if not exists(select 1 from public.app_members where role='operator') then raise exception 'Operador de teste ausente'; end if;
 d:=public.create_picking('25024','31133');
 rejected:=false;
 begin
  perform public.set_recipients('[{"role":"PCP","email":"nao-enviar@example.com"},{"role":"Gestor","email":"nao-enviar@example.com"},{"role":"Almoxarifado","email":"nao-enviar@example.com"}]');
 exception when others then
  if sqlerrm='Somente administradores podem cadastrar destinatários.' then rejected:=true; else raise; end if;
 end;
 if not rejected then raise exception 'Operador alterou destinatários'; end if;
 rejected:=false;
 begin
  update public.picking_documents set responsible='FORJADO' where id=d.id;
 exception when insufficient_privilege then rejected:=true;
 end;
 if not rejected then raise exception 'Escrita direta permitida'; end if;
 perform set_config('request.jwt.claim.sub',current_setting('test.other_uid'),true);
 if not exists(select 1 from public.picking_documents where id=d.id) then raise exception 'Consulta de equipe negada'; end if;
 rejected:=false;
 begin
  perform public.save_picking(d.id,d.project,d.station,d.boxes,d.items);
 exception when others then
  if sqlerrm='Esta separação pertence a outro usuário.' then rejected:=true; else raise; end if;
 end;
 if not rejected then raise exception 'Outro usuário editou rascunho'; end if;
 perform set_config('request.jwt.claim.sub','11111111-1111-4111-8111-111111111111',true);
 if exists(select 1 from public.picking_documents) or exists(select 1 from public.app_members)
 or exists(select 1 from public.notification_recipients) then raise exception 'Usuário sem vínculo leu dados'; end if;
 rejected:=false;
 begin
  perform public.create_picking('X','Y');
 exception when others then
  if sqlerrm='Usuário não autorizado no almoxarifado.' then rejected:=true; else raise; end if;
 end;
 if not rejected then raise exception 'Usuário sem vínculo criou documento'; end if;
 perform set_config('request.jwt.claim.sub',owner_uid,true);
end $$;
reset role;
do $$
declare f record;
begin
 if has_table_privilege('anon','public.picking_documents','SELECT') then raise exception 'Anon acessa documentos'; end if;
 for f in select p.oid,p.proname,p.prosecdef,p.proconfig from pg_proc p join pg_namespace n on n.oid=p.pronamespace
 where n.nspname='public' and p.proname in ('create_picking','save_picking','finalize_picking','set_recipients') loop
  if not f.prosecdef or not ('search_path=""'=any(f.proconfig)) then raise exception 'search_path inseguro: %',f.proname; end if;
  if has_function_privilege('anon',f.oid,'EXECUTE') then raise exception 'Anon executa RPC: %',f.proname; end if;
 end loop;
end $$;
select 'PASSOU: operador, RLS, propriedade, escrita direta, usuário sem vínculo e EXECUTE' as resultado;
rollback;
