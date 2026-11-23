begin;
set local lock_timeout='5s';
select set_config('smart.electrical_documents_before',(select md5(coalesce(jsonb_agg(to_jsonb(d)-'material_eletrico' order by id)::text,'[]')) from public.picking_documents d),true);
select set_config('smart.electrical_recipients_before',(select md5(coalesce(jsonb_agg(to_jsonb(r) order by id)::text,'[]')) from public.notification_recipients r),true);
alter table public.notification_recipients drop constraint notification_recipients_role_check;
alter table public.notification_recipients add constraint notification_recipients_role_check check(role in ('PCP','Gestor','Almoxarifado','Elétrica'));
alter table public.picking_documents add column material_eletrico boolean not null default false;

-- Preserve the legacy one-argument API: older clients cannot erase Elétrica.
create function public.set_recipients(p_recipients jsonb,p_include_electrical boolean) returns void
language plpgsql security definer set search_path='' as $$
declare electrical jsonb; normal jsonb; before_rows jsonb;
begin
 perform smart_private.require_member(true);
 if p_include_electrical is distinct from true or p_recipients is null or jsonb_typeof(p_recipients)<>'array' then raise exception 'Formato de destinatários inválido.';end if;
 if exists(select 1 from jsonb_array_elements(p_recipients) e where jsonb_typeof(e)<>'object' or coalesce(e->>'role','') not in ('PCP','Almoxarifado','Elétrica') or jsonb_typeof(e->'email') is distinct from 'string') then raise exception 'Área ou e-mail inválido.';end if;
 select coalesce(jsonb_agg(e),'[]') into normal from jsonb_array_elements(p_recipients) e where e->>'role'<>'Elétrica';
 select coalesce(jsonb_agg(jsonb_build_object('role','Elétrica','email',lower(btrim(e->>'email'))) order by lower(btrim(e->>'email')) collate "C"),'[]') into electrical from jsonb_array_elements(p_recipients) e where e->>'role'='Elétrica';
 if jsonb_array_length(electrical)>30 or exists(select 1 from jsonb_array_elements(electrical) e where length(e->>'email')>254 or e->>'email' !~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$') then raise exception 'Elétrica: cadastre até 30 e-mails válidos.';end if;
 if exists(select 1 from jsonb_array_elements(electrical) e group by e->>'email' having count(*)>1) then raise exception 'Elétrica: há e-mails repetidos na mesma área.';end if;
 perform public.set_recipients(normal);
 select coalesce(jsonb_agg(to_jsonb(r) order by email),'[]') into before_rows from public.notification_recipients r where role='Elétrica';
 delete from public.notification_recipients r where r.role='Elétrica' and not exists(select 1 from jsonb_array_elements(electrical) e where e->>'email'=lower(btrim(r.email)));
 insert into public.notification_recipients(role,email) select 'Elétrica',e->>'email' from jsonb_array_elements(electrical) e on conflict(role,(lower(btrim(email)))) do nothing;
 insert into smart_private.audit_log(actor_id,action,details) values(auth.uid(),'recipients.electrical',jsonb_build_object('before',before_rows,'after',electrical));
end $$;

create function public.preview_recipients(p_id uuid,p_additional jsonb,p_exception_reason text,p_material_eletrico boolean)
returns jsonb language plpgsql security definer set search_path='' as $$
declare d public.picking_documents; base jsonb; roles jsonb; electrical jsonb; cc_list jsonb; effective jsonb;
begin
 perform smart_private.require_operator();
 if p_material_eletrico is null then raise exception 'Informe a classificação do romaneio.';end if;
 base:=public.preview_recipients(p_id,p_additional,p_exception_reason);
 select * into d from public.picking_documents where id=p_id;
 if d.status='confirmed' then return coalesce(d.recipient_snapshot,'{}')||jsonb_build_object('emails',d.email_recipients,'material_eletrico',d.material_eletrico,'frozen',true);end if;
 roles:=base->'roles';electrical:='[]';cc_list:='[]';
 if p_material_eletrico then
  if not exists(select 1 from public.notification_recipients where role='Elétrica') then raise exception using errcode='P4221',message='Nenhum destinatário da Elétrica está cadastrado. Cadastre um e-mail em Configurações ou desmarque Material Elétrico para continuar.';end if;
  if (select count(*) from public.notification_recipients where role='Elétrica')>30 or exists(select 1 from public.notification_recipients where role='Elétrica' and (length(btrim(email))>254 or btrim(email) !~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$')) then raise exception using errcode='P4221',message='Confira os destinatários cadastrados na Elétrica.';end if;
  select jsonb_agg(email order by email collate "C") into electrical from (select distinct lower(btrim(email)) email from public.notification_recipients where role='Elétrica') x;
  select coalesce(jsonb_agg(email order by email collate "C"),'[]') into cc_list from jsonb_array_elements_text(electrical) email where not (base->'emails' ? email);
  select roles||coalesce(jsonb_agg(jsonb_build_object('role','Elétrica','email',email) order by email collate "C"),'[]') into roles from jsonb_array_elements_text(electrical) email;
 end if;
 select jsonb_agg(email order by email collate "C") into effective from (select distinct value->>'email' email from jsonb_array_elements(roles)) x;
 return base||jsonb_build_object('roles',roles,'emails',effective,'to',base->'emails','cc',cc_list,'electrical',electrical,'material_eletrico',p_material_eletrico,
 'fingerprint',md5(jsonb_build_object('roles',roles,'project',d.project,'exception_reason',base->'exception_reason','material_eletrico',p_material_eletrico,'to',base->'emails','cc',cc_list)::text));
end $$;

create or replace function public.finalize_picking(p_id uuid, p_additional jsonb, p_exception_reason text, p_expected text, p_material_eletrico boolean)
 RETURNS public.picking_documents
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare doc public.picking_documents; snapshot jsonb;
begin
 perform smart_private.require_operator();
 select * into doc from public.picking_documents where id=p_id for update;
 if doc.id is null or doc.owner_id<>auth.uid() then raise exception 'Esta separação pertence a outro usuário.'; end if;
 if doc.status='confirmed' then return doc; end if;
 if trim(doc.project)='' or trim(doc.station)='' or jsonb_array_length(doc.items)=0 then raise exception 'Preencha projeto, estação e itens.'; end if;
 perform smart_private.assert_uniform_destination(doc.project,doc.station,doc.items);
 if exists(select 1 from jsonb_array_elements(doc.boxes) b where not exists(select 1 from jsonb_array_elements(doc.items) i where i->>'box'=b->>'id')) then raise exception 'Remova as caixas vazias.'; end if;
 snapshot:=public.preview_recipients(p_id,p_additional,p_exception_reason,p_material_eletrico);
 if p_expected is null or btrim(p_expected)='' then raise exception using errcode='P4092', message='Conferência de destinatários ausente. Confira novamente antes de confirmar.'; end if;
 if snapshot->>'fingerprint' is null then raise exception using errcode='P5001', message='Não foi possível calcular a conferência de destinatários.'; end if;
 if p_expected is distinct from snapshot->>'fingerprint' then raise exception using errcode='P4091', message='Os destinatários mudaram desde a conferência. Revise e aprove novamente.'; end if;
 update public.picking_documents set material_eletrico=p_material_eletrico,status='confirmed',confirmed_at=now(),email_recipients=snapshot->'emails',recipient_snapshot=snapshot where id=p_id returning * into doc;
 insert into smart_private.audit_log(actor_id,action,target_id,details) values(auth.uid(),'picking.confirm',p_id::text,snapshot);
 return doc;
end $function$
;


-- Keep the existing reservation, timeout, uncertain-status and reconciliation logic.
do $$ declare body text;begin
 body:=pg_get_functiondef('public.claim_manifest_email(uuid)'::regprocedure);
 if position('>91' in body)=0 then raise exception 'Limite de reserva inesperado. Revisão necessária.';end if;
 execute replace(body,'>91','>121');
end $$;
revoke all on function public.set_recipients(jsonb,boolean),public.preview_recipients(uuid,jsonb,text,boolean),public.finalize_picking(uuid,jsonb,text,text,boolean) from public,anon,authenticated;
grant execute on function public.set_recipients(jsonb,boolean),public.preview_recipients(uuid,jsonb,text,boolean),public.finalize_picking(uuid,jsonb,text,text,boolean) to authenticated;
do $$ begin
 if current_setting('smart.electrical_documents_before') is distinct from (select md5(coalesce(jsonb_agg(to_jsonb(d)-'material_eletrico' order by id)::text,'[]')) from public.picking_documents d) then raise exception 'Documentos existentes alterados. Migração revertida.';end if;
 if current_setting('smart.electrical_recipients_before') is distinct from (select md5(coalesce(jsonb_agg(to_jsonb(r) order by id)::text,'[]')) from public.notification_recipients r) then raise exception 'Destinatários existentes alterados. Migração revertida.';end if;
end $$;
notify pgrst,'reload schema';
commit;
