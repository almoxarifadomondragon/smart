-- Homologação transacional no projeto oficial. Não envia e-mails nem cria usuários Auth.
begin;
select set_config('request.jwt.claim.sub',(select user_id::text from public.app_members where role='admin' and active order by full_name limit 1),true);
with legacy as (
 insert into public.picking_documents(owner_id,responsible,project,station,status,confirmed_at,email_recipients)
 values(auth.uid(),'Legado de homologação','LEGADO','1','confirmed',now(),'["pcp-legado@example.com","gestor-legado@example.com","almox-legado@example.com"]') returning id
) select set_config('test.legacy_document',id::text,true) from legacy;
set local role authenticated;
do $$
declare d public.picking_documents; m public.project_managers; snap jsonb; frozen jsonb; claim jsonb; other_claim jsonb;
 rejected boolean; who uuid:=auth.uid(); request jsonb;
begin
 d:=public.finalize_picking(current_setting('test.legacy_document')::uuid);
 if d.recipient_snapshot is not null or d.email_recipients<>'["pcp-legado@example.com","gestor-legado@example.com","almox-legado@example.com"]'::jsonb then raise exception 'Romaneio legado perdeu destinatários';end if;
 if public.preview_recipients(d.id)->>'frozen'<>'true' then raise exception 'Legado não congelado';end if;
 m:=public.save_project_manager(null,' 000TESTE-A ','GESTOR-A@example.com',true);
 if m.project_code<>'000TESTE-A' or m.email<>'gestor-a@example.com' then raise exception 'Normalização de projeto/e-mail incorreta'; end if;
 rejected:=false;
 begin perform public.save_project_manager(null,'000TESTE-A','outro@example.com',true);
 exception when unique_violation then rejected:=true; end;
 if not rejected then raise exception 'Projeto ativo duplicado aceito'; end if;
 perform public.save_project_manager(m.id,m.project_code,'editado@example.com',false);
 perform public.save_project_manager(m.id,m.project_code,'gestor-a@example.com',true);
 perform public.save_project_manager(null,'000TESTE-B','gestor-b@example.com',true);
 d:=public.create_picking('000TESTE-A','31133');
 d:=public.save_picking(d.id,d.project,d.station,d.boxes,jsonb_build_array(jsonb_build_object('id',gen_random_uuid(),'code','BMA0000001','project',d.project,'station',d.station,'qty',1,'box',d.boxes->0->>'id')));
 snap:=public.preview_recipients(d.id,'["ADICIONAL@example.com","adicional@example.com","gestor-a@example.com"]');
 if not (snap->'emails' ? 'gestor-a@example.com') or not (snap->'emails' ? 'adicional@example.com') then raise exception 'Destinatários ausentes'; end if;
 if (select count(*) from jsonb_array_elements_text(snap->'emails') e where e='adicional@example.com')<>1 then raise exception 'E-mail duplicado'; end if;
 rejected:=false;
 begin perform public.preview_recipients(d.id,'["invalido"]'); exception when others then rejected:=true; end;
 if not rejected then raise exception 'E-mail inválido aceito'; end if;
 d:=public.finalize_picking(d.id,'["ADICIONAL@example.com","adicional@example.com","gestor-a@example.com"]',null,snap->>'fingerprint');frozen:=d.email_recipients;
 perform public.save_project_manager(m.id,m.project_code,'gestor-alterado@example.com',true);
 if (select email_recipients from public.picking_documents where id=d.id)<>frozen then raise exception 'Snapshot alterado após cadastro'; end if;
 rejected:=false;
 begin perform public.save_picking(d.id,d.project,d.station,d.boxes,d.items); exception when others then rejected:=true; end;
 if not rejected then raise exception 'Confirmado editável'; end if;
 claim:=public.claim_manifest_email(d.id);
 if claim->>'token' is null then raise exception 'Envio não reservado'; end if;
 other_claim:=public.claim_manifest_email(d.id);
 if other_claim->>'blocked'<>'true' then raise exception 'Envio duplicado permitido'; end if;
 perform set_config('test.email_document',d.id::text,true);perform set_config('test.email_token',claim->>'token',true);
 d:=public.create_picking('000TESTE-B','31133');snap:=public.preview_recipients(d.id);
 if not(snap->'emails' ? 'gestor-b@example.com') or snap->'emails' ? 'gestor-a@example.com' then raise exception 'Gestor do projeto incorreto'; end if;
 d:=public.create_picking('TESTE-SEM-GESTOR','31133');
 rejected:=false;begin perform public.preview_recipients(d.id);exception when others then rejected:=true;end;
 if not rejected then raise exception 'Sem gestor aceito automaticamente'; end if;
 snap:=public.preview_recipients(d.id,'[]','Exceção autorizada para homologação');
 if snap->>'exception_reason' is null then raise exception 'Exceção não auditável'; end if;
 request:=public.prepare_user_invite('nao-enviar-homologacao@example.com','Teste de convite','operator');
 rejected:=false;begin perform public.prepare_user_invite('nao-enviar-homologacao@example.com','Teste de convite','operator');exception when others then rejected:=true;end;
 if not rejected then raise exception 'Convite simultâneo aceito'; end if;
end $$;
reset role;
select public.finish_manifest_email(current_setting('test.email_document')::uuid,current_setting('test.email_token')::uuid,'uncertain',null,'partial_rejection');
set local role authenticated;
do $$
declare r jsonb;
begin
 r:=public.claim_manifest_email(current_setting('test.email_document')::uuid);
 if r->>'blocked'<>'true' then raise exception 'Reenvio parcial/incerto permitido'; end if;
 perform public.resolve_manifest_email(current_setting('test.email_document')::uuid,false,'Conferência simulada dentro de transação de teste');
 r:=public.claim_manifest_email(current_setting('test.email_document')::uuid);
 if r->>'token' is null then raise exception 'Retry reconciliado bloqueado'; end if;
end $$;
reset role;
-- Proteção do último administrador e bloqueio imediato com JWT ainda válido.
update public.app_members set active=false where role='admin' and user_id<>auth.uid();
set local role authenticated;
do $$
declare rejected boolean:=false;
begin
 begin perform public.admin_update_member(auth.uid(),'Último admin','operator',true);exception when others then
  if sqlerrm='Mantenha pelo menos um administrador ativo.' then rejected:=true;else raise;end if;
 end;
 if not rejected then raise exception 'Último administrador removido'; end if;
end $$;
reset role;
-- Acrescentar operador em app_members de uma identidade existente, temporariamente.
select set_config('test.operator_uid',(select user_id::text from public.app_members where user_id<>auth.uid() limit 1),true);
update public.app_members set active=true,role='operator' where user_id=current_setting('test.operator_uid')::uuid;
select set_config('request.jwt.claim.sub',current_setting('test.operator_uid'),true);
set local role authenticated;
do $$
declare rejected boolean:=false;
begin
 begin perform public.save_project_manager(null,'NEGADO','x@example.com',true);exception when insufficient_privilege then rejected:=true;end;
 if not rejected then raise exception 'Operador administrou gestores';end if;
 rejected:=false;begin perform public.admin_list_users();exception when insufficient_privilege then rejected:=true;end;
 if not rejected then raise exception 'Operador listou usuários';end if;
end $$;
reset role;
update public.app_members set active=false where user_id=auth.uid();
set local role authenticated;
do $$
declare rejected boolean:=false;
begin
 if exists(select 1 from public.picking_documents) or exists(select 1 from public.project_managers) then raise exception 'Inativo leu dados'; end if;
 begin perform public.create_picking('NEGADO','1');exception when others then rejected:=true;end;
 if not rejected then raise exception 'Inativo criou separação';end if;
end $$;
reset role;
do $$
begin
 if exists(select 1 from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname in ('public','smart_private') and c.relkind='r' and not c.relrowsecurity) then raise exception 'Tabela sem RLS';end if;
 if exists(select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and has_function_privilege('anon',p.oid,'EXECUTE')) then raise exception 'RPC acessível a anon';end if;
 if has_function_privilege('authenticated','public.complete_user_invite(uuid,uuid)','EXECUTE')
 or has_function_privilege('authenticated','public.finish_manifest_email(uuid,uuid,text,text,text)','EXECUTE') then raise exception 'RPC interna acessível ao frontend';end if;
end $$;
select 'PASSOU: gestores, snapshots, adicionais, bloqueios, concorrência, falha parcial, reconciliação, convites e último admin' as resultado;
rollback;
