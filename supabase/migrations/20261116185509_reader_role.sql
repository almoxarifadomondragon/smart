begin;
set local lock_timeout='5s';
alter table public.app_members drop constraint app_members_role_check,
 add constraint app_members_role_check check (role in ('admin','operator','reader'));
alter table smart_private.user_invites drop constraint user_invites_role_check,
 add constraint user_invites_role_check check (role in ('admin','operator','reader'));

create function smart_private.is_operator() returns boolean
language sql stable security definer set search_path='' as $$
 select exists(select 1 from public.app_members where user_id=auth.uid() and active and role in ('admin','operator'))
$$;
create function smart_private.require_operator() returns void
language plpgsql set search_path='' as $$
begin
 if not smart_private.is_operator() then
  raise exception using errcode='42501',message='Operação permitida apenas a administradores e operadores ativos.';
 end if;
end $$;
revoke all on function smart_private.is_operator(),smart_private.require_operator()
 from public,anon,authenticated,service_role;

-- Preserve RPC signatures, ACLs and ownership checks. Legacy saves and
-- closes reach the protected implementation. Read policies are unchanged.

create or replace function public.admin_update_member(p_id uuid,p_name text,p_role text,p_active boolean) returns void
language plpgsql security definer set search_path='' as $$
begin
 perform pg_advisory_xact_lock(73492026);
 perform smart_private.require_member(true);
 if p_name is null or length(btrim(p_name)) not between 1 and 160 or p_role not in ('admin','operator','reader') or p_role is null or p_active is null then raise exception 'Nome, perfil ou status inválido.'; end if;
 update public.app_members set full_name=btrim(p_name),role=p_role,active=p_active where user_id=p_id;
 if not found then raise exception 'Usuário não encontrado.'; end if;
 insert into smart_private.audit_log(actor_id,action,target_id,details) values(auth.uid(),'member.update',p_id::text,jsonb_build_object('name',btrim(p_name),'role',p_role,'active',p_active));
end $$;

create or replace function public.prepare_user_invite(p_email text,p_name text,p_role text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare r smart_private.user_invites;
begin
 perform smart_private.require_member(true);
 if p_email is null or length(p_email)>254 or btrim(p_email) !~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$'
 or p_name is null or length(btrim(p_name)) not between 1 and 160 or p_role not in ('admin','operator','reader') or p_role is null then raise exception 'Dados do usuário inválidos.'; end if;
 if exists(select 1 from auth.users u join public.app_members m on m.user_id=u.id where lower(u.email)=lower(btrim(p_email))) then raise exception 'Usuário já cadastrado; edite seu perfil.'; end if;
 insert into smart_private.user_invites(email,full_name,role,actor_id) values(lower(btrim(p_email)),btrim(p_name),p_role,auth.uid()) on conflict(email) do nothing;
 select * into r from smart_private.user_invites where email=lower(btrim(p_email)) for update;
 if r.actor_id<>auth.uid() or r.full_name<>btrim(p_name) or r.role<>p_role then raise exception 'Existe um convite pendente com outros dados. Solicite reconciliação ao administrador.'; end if;
 if r.status<>'pending' then raise exception 'Convite já processado. Confira os usuários ou solicite reconciliação.'; end if;
 update smart_private.user_invites set status='dispatching',updated_at=now() where id=r.id;
 return to_jsonb(r);
end $$;

create or replace function public.create_picking(p_project text, p_station text)
returns public.picking_documents language plpgsql security definer set search_path='' as $$
declare result public.picking_documents; operator_name text;
begin
 perform smart_private.require_operator();
 select full_name into operator_name from public.app_members where user_id=auth.uid() and active;
 if operator_name is null then raise exception 'Usuário não autorizado no almoxarifado.'; end if;
 if length(p_project)>120 or length(p_station)>120 then raise exception 'Projeto ou estação muito longo.'; end if;
 insert into public.picking_documents(owner_id,responsible,project,station,boxes)
 values(auth.uid(),operator_name,trim(p_project),trim(p_station),jsonb_build_array(jsonb_build_object('id',gen_random_uuid(),'name','Caixa 01')))
 returning * into result;
 return result;
end $$;

create or replace function smart_private.save_picking_impl(p_id uuid, p_project text, p_station text, p_boxes jsonb, p_items jsonb, p_revision bigint)
 RETURNS public.picking_documents
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare doc public.picking_documents; item jsonb; previous_item jsonb; normalized jsonb := '[]'; operator_name text; target_project text; target_station text; invoice text; old_bindings jsonb; new_bindings jsonb; invoice_changes jsonb;
begin
 perform smart_private.require_operator();
 select full_name into operator_name from public.app_members where user_id=auth.uid() and active;
 if operator_name is null then raise exception 'Usuário não autorizado.'; end if;
 select * into doc from public.picking_documents where id=p_id for update;
 if doc.id is null or doc.owner_id<>auth.uid() then raise exception 'Esta separação pertence a outro usuário.'; end if;
 if doc.status<>'draft' then raise exception 'Romaneio já confirmado.'; end if;
 if p_revision is not null and doc.revision<>p_revision then
  raise exception using errcode='P4093',message='Esta separação foi atualizada em outra aba. Reabra o rascunho e tente novamente.';
 end if;
 if p_project is null or p_station is null or length(p_project)>120 or length(p_station)>120 then raise exception 'Projeto ou estação inválido.'; end if;
 if p_boxes is null or p_items is null or jsonb_typeof(p_boxes)<>'array' or jsonb_typeof(p_items)<>'array' then raise exception 'Formato inválido.'; end if;
 if jsonb_array_length(p_boxes)<1 or jsonb_array_length(p_boxes)>100 or jsonb_array_length(p_items)>5000 then raise exception 'Limite de volumes ou itens excedido.'; end if;
 if exists(select 1 from jsonb_array_elements(p_boxes) b where coalesce(b->>'id','') !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' or coalesce(trim(b->>'name'),'')='' or length(b->>'name')>60)
 or (select count(distinct b->>'id') from jsonb_array_elements(p_boxes) b)<>jsonb_array_length(p_boxes)
 or (select count(distinct b->>'name') from jsonb_array_elements(p_boxes) b)<>jsonb_array_length(p_boxes)
 then raise exception 'Caixas inválidas ou duplicadas.'; end if;
 if (select count(distinct i->>'id') from jsonb_array_elements(p_items) i)<>jsonb_array_length(p_items) then raise exception 'IDs de itens duplicados.'; end if;
 target_project:=smart_private.destination_code(p_project);target_station:=smart_private.destination_code(p_station);
 if jsonb_array_length(p_items)>0 then
  target_project:=coalesce(nullif(target_project,''),nullif(smart_private.destination_code(doc.project),''),smart_private.destination_code(p_items->0->>'project'));
  target_station:=coalesce(nullif(target_station,''),nullif(smart_private.destination_code(doc.station),''),smart_private.destination_code(p_items->0->>'station'));
  if ((jsonb_array_length(doc.items)>0 or smart_private.destination_code(doc.project)<>'') and smart_private.destination_code(doc.project)<>target_project)
   or ((jsonb_array_length(doc.items)>0 or smart_private.destination_code(doc.station)<>'') and smart_private.destination_code(doc.station)<>target_station)
  then raise exception using errcode='P4224',message='Projeto e estação de referência não podem ser alterados ao registrar peças. Antes da primeira peça, salve o destino desejado; após a primeira, remova todas as peças para redefini-lo.';end if;
  if smart_private.destination_mismatch(doc.project,doc.station,doc.items) and exists(select 1 from jsonb_array_elements(p_items) n where not exists(select 1 from jsonb_array_elements(doc.items) o where o->>'id'=n->>'id'))
  then raise exception using errcode='P4223',message='Rascunho com destinos inconsistentes. Novas inclusões estão bloqueadas até a regularização controlada.';end if;
  perform smart_private.assert_uniform_destination(target_project,target_station,p_items);
 end if;
 old_bindings:=smart_private.physical_box_bindings(doc.boxes);
 new_bindings:=smart_private.physical_box_bindings(p_boxes);
 if p_revision is null and (old_bindings<>'{}'::jsonb or new_bindings<>'{}'::jsonb
   or exists(select 1 from jsonb_array_elements(doc.items || p_items) i where coalesce(i->>'invoice_number','')<>'')) then
  raise exception using errcode='P4093',message='Atualize a página para editar separações com caixa física ou Nota Fiscal.';
 end if;
 if old_bindings<>'{}'::jsonb and
    (target_project<>smart_private.destination_code(doc.project) or target_station<>smart_private.destination_code(doc.station)) then
  raise exception 'Desvincule as caixas físicas antes de redefinir o destino.';
 end if;
 perform smart_private.check_physical_boxes(p_boxes,target_project,target_station);
 -- The printable code is immutable and copied from the locked registry, never
 -- trusted from the browser. The UUID remains the only relationship key.
 select jsonb_agg((v.value-'physical_box_code') || case when b.id is not null
    then jsonb_build_object('physical_box_code',b.code) else '{}'::jsonb end order by v.ordinality)
 into p_boxes
 from jsonb_array_elements(p_boxes) with ordinality v
 left join smart_private.physical_boxes b on b.id=(v.value->>'physical_box_id')::uuid;
 for item in select value from jsonb_array_elements(p_items) loop
 if coalesce(item->>'id','') !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' or coalesce(item->>'code','') !~ '^BMA[0-9]{7}$'
 or coalesce(trim(item->>'project'),'')='' or length(item->>'project')>120
 or coalesce(trim(item->>'station'),'')='' or length(item->>'station')>120
 or coalesce(item->>'qty','') !~ '^[0-9]{1,6}(\.[0-9]{1,2})?$' then raise exception 'Dados da peça inválidos.'; end if;
 if (item->>'qty')::numeric<=0 or (item->>'qty')::numeric>999999 then raise exception 'Quantidade inválida.'; end if;
 if coalesce(item->>'purchase_order','')<>'' or coalesce(item->>'purchase_order_item','')<>'' then
 if coalesce(item->>'purchase_order','') !~ '^[0-9]{1,40}$' or coalesce(item->>'purchase_order_item','') !~ '^[0-9]{1,20}$' then raise exception 'Pedido de compras ou item inválido.'; end if;
 end if;
 if length(coalesce(item->>'qr_prefix',''))>80 then raise exception 'Prefixo QR inválido.'; end if;
 if not exists(select 1 from jsonb_array_elements(p_boxes) b where b->>'id'=item->>'box') then raise exception 'Caixa não encontrada.'; end if;
 select value into previous_item from jsonb_array_elements(doc.items) where value->>'id'=item->>'id';
 if item ? 'invoice_number' and jsonb_typeof(item->'invoice_number') is distinct from 'string' then
  raise exception 'Nota Fiscal inválida.';
 end if;
 invoice:=btrim(coalesce(item->>'invoice_number',previous_item->>'invoice_number',''));
 if invoice<>'' and invoice !~ '^[A-Za-z0-9][A-Za-z0-9 ./_:-]{0,59}$' then
  raise exception 'Nota Fiscal inválida: até 60 caracteres, começando por letra ou número.';
 end if;
 normalized := normalized || jsonb_build_array(jsonb_build_object(
 'id',item->>'id','code',item->>'code','project',smart_private.destination_code(item->>'project'),'station',smart_private.destination_code(item->>'station'),
 'qty',(item->>'qty')::numeric,'box',item->>'box',
 'purchase_order',coalesce(item->>'purchase_order',''),'purchase_order_item',coalesce(item->>'purchase_order_item',''),
 'invoice_number',invoice,'qr_prefix',coalesce(item->>'qr_prefix',''),
 'scanned_at',coalesce(previous_item->>'scanned_at',now()::text),
 'operator',coalesce(previous_item->>'operator',operator_name)
 ));
 end loop;
 select jsonb_agg(jsonb_build_object('item_id',n->>'id','before',coalesce(o->>'invoice_number',''),'after',coalesce(n->>'invoice_number','')) order by n->>'id')
 into invoice_changes from jsonb_array_elements(normalized) n
 left join jsonb_array_elements(doc.items) o on o->>'id'=n->>'id'
 where coalesce(n->>'invoice_number','')<>coalesce(o->>'invoice_number','');
 if invoice_changes is not null then
  insert into smart_private.audit_log(actor_id,action,target_id,details)
   values(auth.uid(),'picking.invoice',p_id::text,jsonb_build_object('changes',invoice_changes));
 end if;
 if old_bindings<>new_bindings then
  insert into smart_private.audit_log(actor_id,action,target_id,details)
   values(auth.uid(),'picking.physical_boxes',p_id::text,jsonb_build_object('before',old_bindings,'after',new_bindings));
 end if;
 update smart_private.physical_boxes b set status='in_use',updated_at=now()
 where b.id in (
  select (v->>'physical_box_id')::uuid from jsonb_array_elements(p_boxes) v
   where v ? 'physical_box_id' and exists(select 1 from jsonb_array_elements(normalized) i where i->>'box'=v->>'id'));
 update public.picking_documents set project=target_project,station=target_station,boxes=p_boxes,items=normalized,revision=revision+1
  where id=p_id returning * into doc;
 return doc;
end $function$
;

create or replace function public.save_picking_versioned(p_id uuid,p_project text,p_station text,p_boxes jsonb,p_items jsonb,p_revision bigint)
returns public.picking_documents language plpgsql security definer set search_path='' as $$
begin
 perform smart_private.require_operator();
 if p_revision is null or p_revision<0 then raise exception 'Versão da separação inválida.'; end if;
 return smart_private.save_picking_impl(p_id,p_project,p_station,p_boxes,p_items,p_revision);
end $$;

create or replace function public.finalize_picking(p_id uuid, p_additional jsonb DEFAULT '[]'::jsonb, p_exception_reason text DEFAULT NULL::text, p_expected text DEFAULT NULL::text)
 RETURNS picking_documents
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
 snapshot:=public.preview_recipients(p_id,p_additional,p_exception_reason);
 if p_expected is null or btrim(p_expected)='' then raise exception using errcode='P4092', message='Conferência de destinatários ausente. Confira novamente antes de confirmar.'; end if;
 if snapshot->>'fingerprint' is null then raise exception using errcode='P5001', message='Não foi possível calcular a conferência de destinatários.'; end if;
 if p_expected is distinct from snapshot->>'fingerprint' then raise exception using errcode='P4091', message='Os destinatários mudaram desde a conferência. Revise e aprove novamente.'; end if;
 update public.picking_documents set status='confirmed',confirmed_at=now(),email_recipients=snapshot->'emails',recipient_snapshot=snapshot where id=p_id returning * into doc;
 insert into smart_private.audit_log(actor_id,action,target_id,details) values(auth.uid(),'picking.confirm',p_id::text,snapshot);
 return doc;
end $function$
;

create or replace function public.preview_recipients(p_id uuid,p_additional jsonb default '[]',p_exception_reason text default null)
returns jsonb language plpgsql security definer set search_path='' as $$
declare d public.picking_documents; manager public.project_managers; roles jsonb; effective jsonb; reason text:=btrim(coalesce(p_exception_reason,''));
begin
 perform smart_private.require_operator();
 select * into d from public.picking_documents where id=p_id;
 if d.id is null or d.owner_id<>auth.uid() then raise exception 'Esta separação pertence a outro usuário.';end if;
 if d.status='confirmed' then return jsonb_build_object('roles',coalesce(d.recipient_snapshot->'roles','[]'),'emails',d.email_recipients,'frozen',true);end if;
 if p_additional is null or jsonb_typeof(p_additional)<>'array' or jsonb_array_length(p_additional)>30 then raise exception 'Informe até 30 destinatários adicionais.';end if;
 if exists(select 1 from jsonb_array_elements(p_additional) e where jsonb_typeof(e)<>'string'
  or length(btrim(e#>>'{}'))>254 or btrim(e#>>'{}') !~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$') then raise exception 'E-mail adicional inválido.';end if;
 lock table public.notification_recipients in share mode;
 if (select count(distinct role) from public.notification_recipients where role in ('PCP','Almoxarifado'))<>2
  or exists(select 1 from public.notification_recipients where role in ('PCP','Almoxarifado') group by role having count(*)>30)
  or exists(select 1 from public.notification_recipients where role in ('PCP','Almoxarifado') and (length(btrim(email))>254 or btrim(email) !~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$'))
 then raise exception using errcode='P4221',message='Cadastre de 1 a 30 e-mails válidos no PCP e no Almoxarifado.';end if;
 select * into manager from public.project_managers where project_code=upper(btrim(d.project)) and active;
 if manager.id is null then
  if not smart_private.is_member(true) or length(reason)<10 or length(reason)>500 then raise exception using errcode='P4221',message='Projeto sem gestor ativo. Cadastre o gestor ou solicite uma exceção explícita ao administrador.';end if;
 elsif reason<>'' then raise exception using errcode='P4221',message='Exceção desnecessária: projeto possui gestor ativo.';end if;
 select jsonb_agg(jsonb_build_object('role',role,'email',lower(btrim(email))) order by role collate "C",lower(btrim(email)) collate "C") into roles
 from public.notification_recipients where role in ('PCP','Almoxarifado');
 if manager.id is not null then roles:=roles||jsonb_build_array(jsonb_build_object('role','Gestor','email',lower(btrim(manager.email))));end if;
 select roles||coalesce(jsonb_agg(jsonb_build_object('role','Adicional','email',e) order by e collate "C"),'[]') into roles
 from (select distinct lower(btrim(value)) e from jsonb_array_elements_text(p_additional)) a;
 select jsonb_agg(email order by email collate "C") into effective from (select distinct value->>'email' email from jsonb_array_elements(roles)) a;
 -- IDs, timestamps and insertion order must not affect approval. Keep role
 -- associations, project and exception in the fingerprint to detect real changes.
 return jsonb_build_object('roles',roles,'emails',effective,'project',d.project,'manager_id',manager.id,'exception_reason',nullif(reason,''),
  'fingerprint',md5(jsonb_build_object('roles',roles,'project',d.project,'exception_reason',nullif(reason,''))::text));
end $$;

create or replace function public.claim_manifest_email(p_id uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare d public.picking_documents; a smart_private.email_attempts; token uuid:=gen_random_uuid();
begin
 perform smart_private.require_operator();
 select * into d from public.picking_documents where id=p_id for update;
 if d.id is null or d.owner_id<>auth.uid() then raise exception 'Romaneio não encontrado ou sem permissão'; end if;
 if d.status<>'confirmed' then raise exception 'Confirme o romaneio primeiro'; end if;
 if d.email_status='sent' then return jsonb_build_object('sent',true); end if;
 select * into a from smart_private.email_attempts where document_id=p_id and state in ('sending','uncertain') for update;
 if found then
  if a.state='sending' and a.created_at<now()-interval '90 seconds' then
   update smart_private.email_attempts set state='uncertain',error_code='interrupted',finished_at=now() where email_attempts.token=a.token;
   update public.picking_documents set email_delivery_state='uncertain',email_status='failed' where id=p_id;
  end if;
  return jsonb_build_object('blocked',true,'message','Envio em andamento ou com resultado incerto. Confira Enviados e solicite reconciliação ao administrador.');
 end if;
 if jsonb_typeof(d.email_recipients)<>'array' or jsonb_array_length(d.email_recipients)<1 or jsonb_array_length(d.email_recipients)>91
 or exists(select 1 from jsonb_array_elements_text(d.email_recipients) e where e !~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$') then raise exception 'Destinatários não cadastrados'; end if;
 insert into smart_private.email_attempts(token,document_id,actor_id,state,recipients) values(token,p_id,auth.uid(),'sending',d.email_recipients);
 update public.picking_documents set email_delivery_state='sending' where id=p_id;
 return jsonb_build_object('token',token,'document',to_jsonb(d));
end $$;

create or replace function public.create_physical_box(p_document uuid,p_id uuid,p_name text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare doc public.picking_documents; box smart_private.physical_boxes; requested_name text:=btrim(p_name);
begin
 perform smart_private.require_operator();
 if p_id is null or requested_name is null or length(requested_name) not between 1 and 60 then
  raise exception 'Informe uma identificação de caixa de até 60 caracteres.';
 end if;
 select * into doc from public.picking_documents where id=p_document for update;
 if not found or doc.owner_id<>auth.uid() then raise exception 'Esta separação pertence a outro usuário.'; end if;
 if doc.status<>'draft' then raise exception 'Romaneio já confirmado.'; end if;
 if smart_private.destination_code(doc.project)='' or smart_private.destination_code(doc.station)='' then
  raise exception 'Defina projeto e estação antes de cadastrar uma caixa física.';
 end if;
 -- A repeated request for this ID cannot allocate a second box.
 perform pg_advisory_xact_lock(hashtextextended(p_id::text,472310));
 select * into box from smart_private.physical_boxes where id=p_id;
 if found then
  if box.created_by<>auth.uid() or box.project<>smart_private.destination_code(doc.project)
     or box.station<>smart_private.destination_code(doc.station) or box.name<>requested_name then
   raise exception 'Identificação de caixa já utilizada por outra operação.';
  end if;
 else
  -- An old client could have stored arbitrary extra JSON properties. Never
  -- materialize a new ID already present in an unverified historical volume.
  if exists(select 1 from public.picking_documents
    where boxes @> jsonb_build_array(jsonb_build_object('physical_box_id',p_id::text))) then
   raise exception 'Identificação de caixa já referenciada em outro registro.';
  end if;
  insert into smart_private.physical_boxes(id,project,station,name,created_by)
   values(p_id,smart_private.destination_code(doc.project),smart_private.destination_code(doc.station),requested_name,auth.uid())
   returning * into box;
  insert into smart_private.audit_log(actor_id,action,target_id,details)
   values(auth.uid(),'physical_box.create',box.id::text,jsonb_build_object('code',box.code,'document_id',p_document));
 end if;
 return smart_private.physical_box_public(box);
end $$;

create or replace function smart_private.physical_box_public(p_box smart_private.physical_boxes) returns jsonb
language sql stable set search_path='' as $$
 select jsonb_build_object('id',p_box.id,'code',p_box.code,'project',p_box.project,
  'station',p_box.station,'name',p_box.name,'status',p_box.status,
  'created_at',p_box.created_at,'updated_at',p_box.updated_at,
  'can_close',p_box.status<>'closed' and smart_private.is_operator())
$$;

create or replace function smart_private.box_delivery_review(p_id uuid,p_reason text) returns jsonb
language plpgsql set search_path='' as $$
declare
 contents jsonb; documents jsonb; roles jsonb; emails jsonb;
 manager public.project_managers; member_name text;
 reason text:=btrim(coalesce(p_reason,'')); project text; station text;
begin
 perform smart_private.require_operator();
 contents:=public.get_physical_box(p_id);
 if contents->'box'->>'status'='closed' then raise exception 'Esta caixa já está fechada.'; end if;
 if exists(select 1 from jsonb_array_elements(contents->'documents') d where d->>'status'<>'confirmed') then
  raise exception 'Conclua ou desvincule os rascunhos antes de fechar a caixa.';
 end if;
 if jsonb_array_length(contents->'items')=0 then raise exception 'A caixa precisa ter materiais registrados.'; end if;
 project:=contents->'box'->>'project';
 station:=contents->'box'->>'station';
 if project='' or station='' or project<>smart_private.destination_code(project)
   or station<>smart_private.destination_code(station) then raise exception 'Destino da caixa inválido.'; end if;
 if exists(
  select 1 from jsonb_array_elements(contents->'items') i
   where coalesce(i->>'item_id','')='' or coalesce(i->>'code','')=''
    or coalesce((i->>'qty')::numeric,0)<=0 or i->>'qty' in ('NaN','Infinity','-Infinity')
 ) then raise exception 'A caixa contém registros de materiais inválidos.'; end if;

 select jsonb_agg(jsonb_build_object('id',d.id,'number',d.number,'responsible',d.responsible,
  'confirmed_at',d.confirmed_at,'item_count',totals.item_count,'total_units',totals.total_units,
  'project',d.project,'station',d.station) order by d.number)
 into documents
 from public.picking_documents d
 join jsonb_array_elements(contents->'documents') linked on d.id=(linked->>'id')::uuid
 cross join lateral (
  select count(*) item_count,coalesce(sum((i->>'qty')::numeric),0) total_units
  from jsonb_array_elements(contents->'items') i where i->>'document_id'=d.id::text
 ) totals;
 if exists(select 1 from jsonb_array_elements(documents) d
  where d->>'project' is distinct from project or d->>'station' is distinct from station
   or (d->>'item_count')::int=0 or d->>'confirmed_at' is null)
  or (select count(*) from jsonb_array_elements(documents)) <>
     (select count(distinct d->>'id') from jsonb_array_elements(documents) d)
  or exists(select 1 from jsonb_array_elements(contents->'items') i
     group by i->>'document_id',i->>'item_id' having count(*)>1)
 then raise exception 'Os vínculos com os romaneios estão inconsistentes.'; end if;

 -- Keep the official directory stable while the approval is checked and frozen.
 lock table public.notification_recipients,public.project_managers in share mode;
 select * into manager from public.project_managers where project_code=project and active;
 if manager.id is null then
  if not smart_private.is_member(true) or length(reason) not between 10 and 500 then
   raise exception using errcode='P4221',message='Projeto sem gestor ativo. Cadastre o gestor ou informe uma exceção administrativa justificada.';
  end if;
 elsif reason<>'' then
  raise exception 'O projeto possui gestor ativo. Remova a justificativa de exceção.';
 end if;
 select jsonb_agg(jsonb_build_object('role',r.role,'email',lower(btrim(r.email))) order by r.role,lower(btrim(r.email)))
 into roles from public.notification_recipients r where r.role in ('PCP','Almoxarifado');
 if not exists(select 1 from jsonb_array_elements(roles) r where r->>'role'='PCP')
  or not exists(select 1 from jsonb_array_elements(roles) r where r->>'role'='Almoxarifado')
 then raise exception 'Cadastre os e-mails do PCP e do Almoxarifado.'; end if;
 if manager.id is not null then
  roles:=roles||jsonb_build_array(jsonb_build_object('role','Gestor','email',manager.email));
 end if;
 if exists(select 1 from jsonb_array_elements(roles) r where length(r->>'email')>254
  or r->>'email' !~ '^[A-Za-z0-9.!#$%&''*+/=?^_`{|}~-]+@[A-Za-z0-9-]+([.][A-Za-z0-9-]+)+$')
 then raise exception 'Há um destinatário inválido no cadastro oficial.'; end if;
 select jsonb_agg(email order by email) into emails
 from (select distinct r->>'email' email from jsonb_array_elements(roles) r) members;
 select full_name into strict member_name from public.app_members where user_id=auth.uid() and active;
 return jsonb_build_object(
  'snapshot',jsonb_build_object('box',((contents->'box')-'can_close')||'{"status":"closed"}',
   'documents',documents,'items',contents->'items','total_units',contents->'total_units'),
  'recipient_snapshot',jsonb_build_object('roles',roles,'emails',emails,'manager_id',manager.id,'exception_reason',nullif(reason,'')),
  'closed_by_name',member_name);
end $$;

create or replace function public.close_physical_box(p_id uuid,p_expected text,p_reason text,p_observations text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare box smart_private.physical_boxes; review jsonb; delivery smart_private.physical_box_deliveries;
 observations text:=nullif(replace(replace(p_observations,chr(13)||chr(10),chr(10)),chr(13),chr(10)),'');
begin
 perform smart_private.require_operator();
 -- Saves take document then box locks. Closing must never lock document rows.
 select * into box from smart_private.physical_boxes where id=p_id for update;
 if not found then raise exception 'Caixa física não encontrada.'; end if;
 if box.status='closed' then
  return smart_private.physical_box_public(box)||jsonb_build_object('delivery',public.get_box_delivery(p_id),'created',false);
 end if;
 review:=public.preview_box_delivery(p_id,p_reason);
 if p_expected is distinct from review->>'fingerprint' then
  raise exception using errcode='P4091',message='A conferência mudou ou está ausente. Confira a caixa novamente.';
 end if;
 if char_length(observations)>2000 or translate(observations,chr(10)||chr(9),'') ~ '[[:cntrl:]]' then
  raise exception 'Observações inválidas. Informe até 2.000 caracteres de texto.';
 end if;
 insert into smart_private.physical_box_deliveries(physical_box_id,closed_at,closed_by,closed_by_name,snapshot,recipient_snapshot,observations)
 values(p_id,clock_timestamp(),auth.uid(),review->>'closed_by_name',review->'snapshot',review->'recipient_snapshot',observations)
 returning * into delivery;
 update smart_private.physical_boxes set status='closed',updated_at=delivery.closed_at where id=p_id returning * into box;
 insert into smart_private.audit_log(actor_id,action,target_id,details)
 values(auth.uid(),'physical_box.close',p_id::text,jsonb_build_object(
  'code',box.code,'project',box.project,'station',box.station,
  'item_count',jsonb_array_length(delivery.snapshot->'items'),'documents',delivery.snapshot->'documents',
  'has_observations',observations is not null,'exception_reason',delivery.recipient_snapshot->'exception_reason'));
 return smart_private.physical_box_public(box)||jsonb_build_object('delivery',public.get_box_delivery(p_id),'created',true);
end $$;

create or replace function public.claim_box_delivery_email(p_id uuid,p_actor uuid,p_request uuid,p_expected_attempt uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare
 delivery smart_private.physical_box_deliveries;
 latest smart_private.physical_box_delivery_email_attempts;
 prior_request smart_private.physical_box_delivery_email_attempts;
 kind text;
 is_copy boolean;
begin
 if not exists(select 1 from public.app_members where user_id=p_actor and active and role in ('admin','operator')) then
  raise exception using errcode='42501',message='Usuário não autorizado ou inativo.';
 end if;
 if (p_request is null) <> (p_expected_attempt is null) then
  raise exception 'Confirmação de reenvio inválida.';
 end if;
 select * into delivery from smart_private.physical_box_deliveries where physical_box_id=p_id for update;
 if not found then raise exception 'Entrega não encontrada.'; end if;
 if p_request is not null then
  select * into prior_request from smart_private.physical_box_delivery_email_attempts
   where physical_box_id=p_id and request_id=p_request;
  if found then
   return jsonb_build_object('state',case when prior_request.state='sending' and prior_request.created_at < now()-interval '5 minutes'
    then 'uncertain' else prior_request.state end);
  end if;
 end if;
 select * into latest from smart_private.physical_box_delivery_email_attempts
  where physical_box_id=p_id order by created_at desc,token desc limit 1;
 if latest.state in ('sending','uncertain') then
  return jsonb_build_object('state',case when latest.state='sending' and latest.created_at < now()-interval '5 minutes'
   then 'uncertain' else latest.state end);
 end if;
 if p_request is not null then
  if latest.token is distinct from p_expected_attempt or latest.state is distinct from 'sent' then
   raise exception using errcode='P4091',message='O envio mudou. Atualize a consulta e confirme novamente.';
  end if;
  kind:='resend';
 elsif latest.state='sent' then
  return jsonb_build_object('state','sent');
 else
  kind:=case when latest.token is null then 'initial' else 'retry' end;
 end if;
 select exists(select 1 from smart_private.physical_box_delivery_email_attempts
  where physical_box_id=p_id and state='sent') into is_copy;
 insert into smart_private.physical_box_delivery_email_attempts(physical_box_id,actor_id,state,send_type,request_id)
 values(p_id,p_actor,'sending',kind,p_request) returning * into latest;
 return jsonb_build_object('state','sending','token',latest.token,'delivery',to_jsonb(delivery),'is_copy',is_copy);
end $$;

notify pgrst,'reload schema';
commit;
