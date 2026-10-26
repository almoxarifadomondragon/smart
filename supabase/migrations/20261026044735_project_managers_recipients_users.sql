-- Incremental; nunca executar schema.sql em um banco já instalado.
begin;
create schema if not exists smart_private;
revoke all on schema smart_private from public;
grant usage on schema smart_private to authenticated, service_role;
alter table public.app_members add column active boolean not null default true;
alter table public.app_members add column updated_at timestamptz not null default now();
alter table public.picking_documents add column recipient_snapshot jsonb;
alter table public.picking_documents add column email_delivery_state text not null default 'pending'
 check(email_delivery_state in ('pending','sending','sent','failed','uncertain'));
update public.picking_documents set email_delivery_state='sent' where email_status='sent';

create table public.project_managers (
 id uuid primary key default gen_random_uuid(),
 project_code text not null check(project_code=upper(btrim(project_code)) and length(project_code) between 1 and 120),
 email text not null check(length(email)<=254 and email=lower(btrim(email)) and email ~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$'),
 active boolean not null default true,
 created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
 created_by uuid not null references auth.users(id), updated_by uuid not null references auth.users(id)
);
create unique index one_active_manager_per_project on public.project_managers(project_code) where active;
create table smart_private.audit_log (
 id bigint generated always as identity primary key, actor_id uuid, action text not null,
 target_id text, details jsonb not null default '{}', created_at timestamptz not null default now()
);
create table smart_private.user_invites (
 id uuid primary key default gen_random_uuid(), email text not null unique,
 full_name text not null, role text not null check(role in ('admin','operator')),
 actor_id uuid not null, auth_id uuid, status text not null default 'pending'
 check(status in ('pending','completed','failed')), created_at timestamptz not null default now(),
 updated_at timestamptz not null default now()
);
create table smart_private.email_attempts (
 token uuid primary key default gen_random_uuid(), document_id uuid not null references public.picking_documents(id),
 actor_id uuid not null, state text not null check(state in ('sending','sent','failed','uncertain')),
 recipients jsonb not null, provider_id text, error_code text,
 created_at timestamptz not null default now(), finished_at timestamptz
);
create unique index one_unresolved_email_attempt on smart_private.email_attempts(document_id) where state in ('sending','uncertain');
alter table public.project_managers enable row level security;
alter table smart_private.audit_log enable row level security;
alter table smart_private.user_invites enable row level security;
alter table smart_private.email_attempts enable row level security;
revoke all on public.project_managers from public,anon,authenticated;
grant select on public.project_managers to authenticated;
revoke all on all tables in schema smart_private from public,anon,authenticated;

create function smart_private.is_member(p_admin boolean default false) returns boolean
language sql stable security definer set search_path='' as $$
 select exists(select 1 from public.app_members where user_id=auth.uid() and active and (not p_admin or role='admin'))
$$;
revoke all on function smart_private.is_member(boolean) from public,anon;
grant execute on function smart_private.is_member(boolean) to authenticated,service_role;
create function smart_private.require_member(p_admin boolean default false) returns void
language plpgsql security definer set search_path='' as $$
begin
 if not smart_private.is_member(p_admin) then raise exception 'Usuário não autorizado ou inativo.' using errcode='42501'; end if;
end $$;
revoke all on function smart_private.require_member(boolean) from public,anon;
grant execute on function smart_private.require_member(boolean) to authenticated;
alter policy member_self on public.app_members using(user_id=auth.uid() and active);
alter policy documents_read on public.picking_documents using((select smart_private.is_member()));
alter policy recipients_read on public.notification_recipients using((select smart_private.is_member()));
create policy managers_read on public.project_managers for select to authenticated using((select smart_private.is_member()));

create function smart_private.guard_members() returns trigger language plpgsql security definer set search_path='' as $$
begin
 perform pg_advisory_xact_lock(73492026);
 if tg_op='DELETE' or (old.role='admin' and old.active and (new.role<>'admin' or not new.active)) then
  if old.role='admin' and old.active and not exists(select 1 from public.app_members where role='admin' and active and user_id<>old.user_id) then
   raise exception 'Mantenha pelo menos um administrador ativo.';
  end if;
 end if;
 if tg_op='DELETE' then return old; end if;
 new.updated_at:=now(); return new;
end $$;
revoke all on function smart_private.guard_members() from public,anon,authenticated;
create trigger guard_last_administrator before update or delete on public.app_members for each row execute function smart_private.guard_members();

create function public.save_project_manager(p_id uuid,p_project text,p_email text,p_active boolean)
returns public.project_managers language plpgsql security definer set search_path='' as $$
declare result public.project_managers;
begin
 perform smart_private.require_member(true);
 if p_active is null then raise exception 'Status obrigatório.'; end if;
 if p_id is null then
  insert into public.project_managers(project_code,email,active,created_by,updated_by)
  values(upper(btrim(p_project)),lower(btrim(p_email)),p_active,auth.uid(),auth.uid()) returning * into result;
 else
  update public.project_managers set project_code=upper(btrim(p_project)),email=lower(btrim(p_email)),active=p_active,updated_by=auth.uid(),updated_at=now()
  where id=p_id returning * into result;
  if not found then raise exception 'Gestor não encontrado.'; end if;
 end if;
 insert into smart_private.audit_log(actor_id,action,target_id,details) values(auth.uid(),'manager.save',result.id::text,to_jsonb(result));
 return result;
end $$;

create or replace function public.set_recipients(p_recipients jsonb) returns void
language plpgsql security definer set search_path='' as $$
begin
 perform smart_private.require_member(true);
 if p_recipients is null or jsonb_typeof(p_recipients)<>'array' or jsonb_array_length(p_recipients)<>2
 or (select count(distinct value->>'role') from jsonb_array_elements(p_recipients) where value->>'role' in ('PCP','Almoxarifado'))<>2
 then raise exception 'Cadastre PCP e Almoxarifado.'; end if;
 insert into public.notification_recipients(role,email) select value->>'role',lower(btrim(value->>'email')) from jsonb_array_elements(p_recipients)
 on conflict(role) do update set email=excluded.email;
 insert into smart_private.audit_log(actor_id,action,details) values(auth.uid(),'recipients.save',p_recipients);
end $$;

create function public.preview_recipients(p_id uuid,p_additional jsonb default '[]',p_exception_reason text default null)
returns jsonb language plpgsql security definer set search_path='' as $$
declare d public.picking_documents; manager public.project_managers; roles jsonb; effective jsonb; reason text:=btrim(coalesce(p_exception_reason,''));
begin
 perform smart_private.require_member();
 select * into d from public.picking_documents where id=p_id;
 if d.id is null or d.owner_id<>auth.uid() then raise exception 'Esta separação pertence a outro usuário.'; end if;
 if d.status='confirmed' then return jsonb_build_object('roles',coalesce(d.recipient_snapshot->'roles','[]'),'emails',d.email_recipients,'frozen',true); end if;
 if p_additional is null or jsonb_typeof(p_additional)<>'array' or jsonb_array_length(p_additional)>30 then raise exception 'Informe até 30 destinatários adicionais.'; end if;
 if exists(select 1 from jsonb_array_elements(p_additional) e where jsonb_typeof(e)<>'string'
 or length(btrim(e#>>'{}'))>254 or btrim(e#>>'{}') !~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$') then raise exception 'E-mail adicional inválido.'; end if;
 if (select count(*) from public.notification_recipients where role in ('PCP','Almoxarifado'))<>2 then raise exception 'Cadastre PCP e Almoxarifado.'; end if;
 select * into manager from public.project_managers where project_code=upper(btrim(d.project)) and active;
 if manager.id is null then
  if not smart_private.is_member(true) or length(reason)<10 or length(reason)>500 then raise exception 'Projeto sem gestor ativo. Cadastre o gestor ou solicite uma exceção explícita ao administrador.'; end if;
 elsif reason<>'' then raise exception 'Exceção desnecessária: projeto possui gestor ativo.';
 end if;
 select jsonb_agg(jsonb_build_object('role',role,'email',lower(btrim(email))) order by role) into roles
 from public.notification_recipients where role in ('PCP','Almoxarifado');
 if manager.id is not null then roles:=roles||jsonb_build_array(jsonb_build_object('role','Gestor','email',manager.email)); end if;
 select roles||coalesce(jsonb_agg(jsonb_build_object('role','Adicional','email',e) order by e),'[]') into roles
 from (select distinct lower(btrim(value)) e from jsonb_array_elements_text(p_additional)) a;
 select jsonb_agg(email order by email) into effective from (select distinct value->>'email' email from jsonb_array_elements(roles)) a;
 return jsonb_build_object('roles',roles,'emails',effective,'project',d.project,'manager_id',manager.id,'exception_reason',nullif(reason,''),'fingerprint',md5(roles::text||d.project||reason));
end $$;

drop function public.finalize_picking(uuid);
create function public.finalize_picking(p_id uuid,p_additional jsonb default '[]',p_exception_reason text default null,p_expected text default null)
returns public.picking_documents language plpgsql security definer set search_path='' as $$
declare doc public.picking_documents; snapshot jsonb;
begin
 perform smart_private.require_member();
 select * into doc from public.picking_documents where id=p_id for update;
 if doc.id is null or doc.owner_id<>auth.uid() then raise exception 'Esta separação pertence a outro usuário.'; end if;
 if doc.status='confirmed' then return doc; end if;
 if trim(doc.project)='' or trim(doc.station)='' or jsonb_array_length(doc.items)=0 then raise exception 'Preencha projeto, estação e itens.'; end if;
 if exists(select 1 from jsonb_array_elements(doc.boxes) b where not exists(select 1 from jsonb_array_elements(doc.items) i where i->>'box'=b->>'id')) then raise exception 'Remova as caixas vazias.'; end if;
 snapshot:=public.preview_recipients(p_id,p_additional,p_exception_reason);
 if p_expected is null or p_expected<>snapshot->>'fingerprint' then raise exception 'Confira novamente os destinatários: o cadastro pode ter mudado.'; end if;
 update public.picking_documents set status='confirmed',confirmed_at=now(),email_recipients=snapshot->'emails',recipient_snapshot=snapshot where id=p_id returning * into doc;
 insert into smart_private.audit_log(actor_id,action,target_id,details) values(auth.uid(),'picking.confirm',p_id::text,snapshot);
 return doc;
end $$;

create function public.admin_list_users() returns jsonb language plpgsql security definer set search_path='' as $$
declare result jsonb;
begin
 perform smart_private.require_member(true);
 select coalesce(jsonb_agg(jsonb_build_object('user_id',m.user_id,'full_name',m.full_name,'email',u.email,'role',m.role,'active',m.active) order by m.full_name),'[]') into result
 from public.app_members m join auth.users u on u.id=m.user_id;
 return result;
end $$;
create function public.admin_update_member(p_id uuid,p_name text,p_role text,p_active boolean) returns void
language plpgsql security definer set search_path='' as $$
begin
 perform pg_advisory_xact_lock(73492026);
 perform smart_private.require_member(true);
 if p_name is null or length(btrim(p_name)) not between 1 and 160 or p_role not in ('admin','operator') or p_active is null then raise exception 'Nome, perfil ou status inválido.'; end if;
 update public.app_members set full_name=btrim(p_name),role=p_role,active=p_active where user_id=p_id;
 if not found then raise exception 'Usuário não encontrado.'; end if;
 insert into smart_private.audit_log(actor_id,action,target_id,details) values(auth.uid(),'member.update',p_id::text,jsonb_build_object('name',btrim(p_name),'role',p_role,'active',p_active));
end $$;
create function public.prepare_user_invite(p_email text,p_name text,p_role text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare r smart_private.user_invites;
begin
 perform smart_private.require_member(true);
 if p_email is null or length(p_email)>254 or btrim(p_email) !~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$'
 or p_name is null or length(btrim(p_name)) not between 1 and 160 or p_role not in ('admin','operator') or p_role is null then raise exception 'Dados do usuário inválidos.'; end if;
 if exists(select 1 from auth.users u join public.app_members m on m.user_id=u.id where lower(u.email)=lower(btrim(p_email))) then raise exception 'Usuário já cadastrado; edite seu perfil.'; end if;
 insert into smart_private.user_invites(email,full_name,role,actor_id) values(lower(btrim(p_email)),btrim(p_name),p_role,auth.uid()) on conflict(email) do nothing;
 select * into r from smart_private.user_invites where email=lower(btrim(p_email)) for update;
 if r.actor_id<>auth.uid() or r.full_name<>btrim(p_name) or r.role<>p_role then raise exception 'Existe um convite pendente com outros dados. Solicite reconciliação ao administrador.'; end if;
 if r.status<>'pending' then raise exception 'Convite já processado. Confira os usuários ou solicite reconciliação.'; end if;
 return to_jsonb(r);
end $$;
create function public.complete_user_invite(p_request uuid,p_auth_id uuid) returns void
language plpgsql security definer set search_path='' as $$
declare r smart_private.user_invites;
begin
 perform pg_advisory_xact_lock(73492026);
 select * into r from smart_private.user_invites where id=p_request for update;
 if r.id is null or r.status<>'pending' then raise exception 'Solicitação inválida ou já processada.'; end if;
 if not exists(select 1 from public.app_members where user_id=r.actor_id and active and role='admin') then raise exception 'Solicitante sem autorização.'; end if;
 if not exists(select 1 from auth.users where id=p_auth_id and lower(email)=r.email) then raise exception 'Identidade não corresponde ao convite.'; end if;
 insert into public.app_members(user_id,full_name,role,active) values(p_auth_id,r.full_name,r.role,true);
 update smart_private.user_invites set status='completed',auth_id=p_auth_id,updated_at=now() where id=r.id;
 insert into smart_private.audit_log(actor_id,action,target_id,details) values(r.actor_id,'member.invite',p_auth_id::text,jsonb_build_object('request_id',r.id,'email',r.email,'role',r.role));
end $$;
create function public.fail_user_invite(p_request uuid,p_auth_id uuid) returns void
language plpgsql security definer set search_path='' as $$
begin
 update smart_private.user_invites set status='failed',auth_id=p_auth_id,updated_at=now() where id=p_request and status='pending';
 if found then insert into smart_private.audit_log(action,target_id,details) values('member.invite_failed',p_request::text,jsonb_build_object('auth_id',p_auth_id)); end if;
end $$;

create function public.claim_manifest_email(p_id uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare d public.picking_documents; a smart_private.email_attempts; token uuid:=gen_random_uuid();
begin
 perform smart_private.require_member();
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
 if jsonb_typeof(d.email_recipients)<>'array' or jsonb_array_length(d.email_recipients)<1 or jsonb_array_length(d.email_recipients)>33
 or exists(select 1 from jsonb_array_elements_text(d.email_recipients) e where e !~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$') then raise exception 'Destinatários não cadastrados'; end if;
 insert into smart_private.email_attempts(token,document_id,actor_id,state,recipients) values(token,p_id,auth.uid(),'sending',d.email_recipients);
 update public.picking_documents set email_delivery_state='sending' where id=p_id;
 return jsonb_build_object('token',token,'document',to_jsonb(d));
end $$;
create function public.finish_manifest_email(p_id uuid,p_token uuid,p_state text,p_provider text default null,p_code text default null) returns void
language plpgsql security definer set search_path='' as $$
begin
 if p_state not in ('sent','failed','uncertain') or p_state is null then raise exception 'Estado inválido'; end if;
 perform 1 from public.picking_documents where id=p_id for update;
 update smart_private.email_attempts set state=p_state,provider_id=left(p_provider,300),error_code=left(p_code,80),finished_at=now()
 where document_id=p_id and token=p_token and state='sending';
 if not found then raise exception 'Tentativa não corresponde ao envio em andamento'; end if;
 update public.picking_documents set email_delivery_state=p_state,email_status=case when p_state='sent' then 'sent' else 'failed' end,email_provider_id=left(p_provider,300) where id=p_id;
end $$;
create function public.resolve_manifest_email(p_id uuid,p_sent boolean,p_note text) returns void
language plpgsql security definer set search_path='' as $$
begin
 perform smart_private.require_member(true);
 if p_note is null or length(btrim(p_note)) not between 10 and 500 or p_sent is null then raise exception 'Registre a conferência no Gmail (10 a 500 caracteres).'; end if;
 perform 1 from public.picking_documents where id=p_id and status='confirmed' for update;
 if not found then raise exception 'Romaneio não encontrado'; end if;
 if exists(select 1 from smart_private.email_attempts where document_id=p_id and state='sending' and created_at>now()-interval '90 seconds') then raise exception 'Aguarde o envio em andamento.'; end if;
 update smart_private.email_attempts set state=case when p_sent then 'sent' else 'failed' end,finished_at=now(),error_code='admin_reconciled' where document_id=p_id and state in ('sending','uncertain');
 if not found then raise exception 'Não há tentativa incerta para reconciliar.'; end if;
 update public.picking_documents set email_status=case when p_sent then 'sent' else 'failed' end,email_delivery_state=case when p_sent then 'sent' else 'failed' end where id=p_id;
 insert into smart_private.audit_log(actor_id,action,target_id,details) values(auth.uid(),'email.reconcile',p_id::text,jsonb_build_object('sent',p_sent,'note',p_note));
end $$;

-- RPCs de usuário com identidade real e RLS; endpoints internos exclusivos do servidor.
revoke all on function public.save_project_manager(uuid,text,text,boolean),public.preview_recipients(uuid,jsonb,text),public.finalize_picking(uuid,jsonb,text,text),public.admin_list_users(),public.admin_update_member(uuid,text,text,boolean),public.prepare_user_invite(text,text,text),public.claim_manifest_email(uuid),public.resolve_manifest_email(uuid,boolean,text) from public,anon;
grant execute on function public.save_project_manager(uuid,text,text,boolean),public.preview_recipients(uuid,jsonb,text),public.finalize_picking(uuid,jsonb,text,text),public.admin_list_users(),public.admin_update_member(uuid,text,text,boolean),public.prepare_user_invite(text,text,text),public.claim_manifest_email(uuid),public.resolve_manifest_email(uuid,boolean,text) to authenticated;
revoke all on function public.complete_user_invite(uuid,uuid),public.fail_user_invite(uuid,uuid),public.finish_manifest_email(uuid,uuid,text,text,text) from public,anon,authenticated;
grant execute on function public.complete_user_invite(uuid,uuid),public.fail_user_invite(uuid,uuid),public.finish_manifest_email(uuid,uuid,text,text,text) to service_role;
-- As funções originais create/save são atualizadas abaixo apenas para exigir membro ativo.

create or replace function public.create_picking(p_project text, p_station text)
returns public.picking_documents language plpgsql security definer set search_path='' as $$
declare result public.picking_documents; operator_name text;
begin
 select full_name into operator_name from public.app_members where user_id=auth.uid() and active;
 if operator_name is null then raise exception 'Usuário não autorizado no almoxarifado.'; end if;
 if length(p_project)>120 or length(p_station)>120 then raise exception 'Projeto ou estação muito longo.'; end if;
 insert into public.picking_documents(owner_id,responsible,project,station,boxes)
 values(auth.uid(),operator_name,trim(p_project),trim(p_station),jsonb_build_array(jsonb_build_object('id',gen_random_uuid(),'name','Caixa 01')))
 returning * into result;
 return result;
end $$;

create or replace function public.save_picking(p_id uuid,p_project text,p_station text,p_boxes jsonb,p_items jsonb)
returns public.picking_documents language plpgsql security definer set search_path='' as $$
declare doc public.picking_documents; item jsonb; previous_item jsonb; normalized jsonb := '[]'; operator_name text;
begin
 select full_name into operator_name from public.app_members where user_id=auth.uid() and active;
 if operator_name is null then raise exception 'Usuário não autorizado.'; end if;
 select * into doc from public.picking_documents where id=p_id for update;
 if doc.id is null or doc.owner_id<>auth.uid() then raise exception 'Esta separação pertence a outro usuário.'; end if;
 if doc.status<>'draft' then raise exception 'Romaneio já confirmado.'; end if;
 if p_project is null or p_station is null or length(p_project)>120 or length(p_station)>120 then raise exception 'Projeto ou estação inválido.'; end if;
 if p_boxes is null or p_items is null or jsonb_typeof(p_boxes)<>'array' or jsonb_typeof(p_items)<>'array' then raise exception 'Formato inválido.'; end if;
 if jsonb_array_length(p_boxes)<1 or jsonb_array_length(p_boxes)>100 or jsonb_array_length(p_items)>5000 then raise exception 'Limite de volumes ou itens excedido.'; end if;
 if exists(select 1 from jsonb_array_elements(p_boxes) b where coalesce(b->>'id','') !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' or coalesce(trim(b->>'name'),'')='' or length(b->>'name')>60)
 or (select count(distinct b->>'id') from jsonb_array_elements(p_boxes) b)<>jsonb_array_length(p_boxes)
 or (select count(distinct b->>'name') from jsonb_array_elements(p_boxes) b)<>jsonb_array_length(p_boxes)
 then raise exception 'Caixas inválidas ou duplicadas.'; end if;
 if (select count(distinct i->>'id') from jsonb_array_elements(p_items) i)<>jsonb_array_length(p_items) then raise exception 'IDs de itens duplicados.'; end if;
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
  normalized := normalized || jsonb_build_array(jsonb_build_object(
   'id',item->>'id','code',item->>'code','project',trim(item->>'project'),'station',trim(item->>'station'),
   'qty',(item->>'qty')::numeric,'box',item->>'box',
   'purchase_order',coalesce(item->>'purchase_order',''),'purchase_order_item',coalesce(item->>'purchase_order_item',''),
   'qr_prefix',coalesce(item->>'qr_prefix',''),
   'scanned_at',coalesce(previous_item->>'scanned_at',now()::text),
   'operator',coalesce(previous_item->>'operator',operator_name)
  ));
 end loop;
 update public.picking_documents set project=trim(p_project),station=trim(p_station),boxes=p_boxes,items=normalized where id=p_id returning * into doc;
 return doc;
end $$;


commit;
