begin;
set local lock_timeout = '5s';

create table smart_private.physical_box_deliveries (
 physical_box_id uuid primary key references smart_private.physical_boxes(id),
 closed_at timestamptz not null,
 closed_by uuid not null,
 closed_by_name text not null,
 snapshot jsonb not null,
 recipient_snapshot jsonb not null
);
create table smart_private.physical_box_delivery_email_attempts (
 token uuid primary key default gen_random_uuid(),
 physical_box_id uuid not null references smart_private.physical_box_deliveries(physical_box_id),
 actor_id uuid not null,
 state text not null check (state in ('sending','sent','failed','uncertain')),
 created_at timestamptz not null default clock_timestamp(),
 finished_at timestamptz,
 provider_id text,
 error_code text
);
create index box_delivery_attempt_history on smart_private.physical_box_delivery_email_attempts(physical_box_id,created_at desc,token);
create unique index box_delivery_no_duplicate_send
 on smart_private.physical_box_delivery_email_attempts(physical_box_id) where state in ('sending','uncertain','sent');
alter table smart_private.physical_box_deliveries enable row level security;
alter table smart_private.physical_box_delivery_email_attempts enable row level security;
revoke all on smart_private.physical_box_deliveries,smart_private.physical_box_delivery_email_attempts from public,anon,authenticated,service_role;

create function smart_private.prevent_delivery_change() returns trigger
language plpgsql set search_path='' as $$
begin
 raise exception 'O comprovante de entrega é imutável.';
end $$;
create trigger immutable_box_delivery before update or delete on smart_private.physical_box_deliveries
 for each row execute function smart_private.prevent_delivery_change();

create or replace function smart_private.physical_box_public(p_box smart_private.physical_boxes) returns jsonb
language sql stable set search_path='' as $$
 select jsonb_build_object('id',p_box.id,'code',p_box.code,'project',p_box.project,
  'station',p_box.station,'name',p_box.name,'status',p_box.status,
  'created_at',p_box.created_at,'updated_at',p_box.updated_at,
  'can_close',p_box.status<>'closed' and smart_private.is_member())
$$;

create function smart_private.box_delivery_review(p_id uuid,p_reason text) returns jsonb
language plpgsql set search_path='' as $$
declare
 contents jsonb; documents jsonb; roles jsonb; emails jsonb;
 manager public.project_managers; member_name text;
 reason text:=btrim(coalesce(p_reason,'')); project text; station text;
begin
 perform smart_private.require_member();
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

create function public.preview_box_delivery(p_id uuid,p_reason text default null) returns jsonb
language plpgsql security definer set search_path='' as $$
declare review jsonb;
begin
 review:=smart_private.box_delivery_review(p_id,p_reason);
 return review||jsonb_build_object('fingerprint',encode(sha256(convert_to(review::text,'UTF8')),'hex'));
end $$;

create function public.get_box_delivery(p_id uuid) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare delivery smart_private.physical_box_deliveries; attempt smart_private.physical_box_delivery_email_attempts;
begin
 perform smart_private.require_member();
 select * into delivery from smart_private.physical_box_deliveries where physical_box_id=p_id;
 if not found then return null; end if;
 select * into attempt from smart_private.physical_box_delivery_email_attempts
 where physical_box_id=p_id order by created_at desc,token desc limit 1;
 return to_jsonb(delivery)||jsonb_build_object(
  'email_state',case when attempt.state='sending' and attempt.created_at < now()-interval '5 minutes'
    then 'uncertain' else coalesce(attempt.state,'pending') end);
end $$;

create function public.close_physical_box(p_id uuid,p_expected text,p_reason text default null) returns jsonb
language plpgsql security definer set search_path='' as $$
declare box smart_private.physical_boxes; review jsonb; delivery smart_private.physical_box_deliveries;
begin
 perform smart_private.require_member();
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
 insert into smart_private.physical_box_deliveries(physical_box_id,closed_at,closed_by,closed_by_name,snapshot,recipient_snapshot)
 values(p_id,clock_timestamp(),auth.uid(),review->>'closed_by_name',review->'snapshot',review->'recipient_snapshot')
 returning * into delivery;
 update smart_private.physical_boxes set status='closed',updated_at=delivery.closed_at where id=p_id returning * into box;
 insert into smart_private.audit_log(actor_id,action,target_id,details)
 values(auth.uid(),'physical_box.close',p_id::text,jsonb_build_object(
  'code',box.code,'project',box.project,'station',box.station,
  'item_count',jsonb_array_length(delivery.snapshot->'items'),'documents',delivery.snapshot->'documents',
  'exception_reason',delivery.recipient_snapshot->'exception_reason'));
 return smart_private.physical_box_public(box)||jsonb_build_object('delivery',public.get_box_delivery(p_id),'created',true);
end $$;

-- Retain the old route for closed historical boxes, with the same approval guard for open boxes.
create or replace function public.close_physical_box(p_id uuid) returns jsonb
language sql set search_path='' as $$
 select public.close_physical_box(p_id,null,null)
$$;

create function public.claim_box_delivery_email(p_id uuid,p_actor uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare delivery smart_private.physical_box_deliveries; attempt smart_private.physical_box_delivery_email_attempts;
begin
 if not exists(select 1 from public.app_members where user_id=p_actor and active) then
  raise exception using errcode='42501',message='Usuário não autorizado ou inativo.';
 end if;
 select * into delivery from smart_private.physical_box_deliveries where physical_box_id=p_id for update;
 if not found then raise exception 'Entrega não encontrada.'; end if;
 select * into attempt from smart_private.physical_box_delivery_email_attempts
 where physical_box_id=p_id order by created_at desc,token desc limit 1;
 if attempt.state in ('sending','uncertain','sent') then
  return jsonb_build_object('state',case when attempt.state='sending' and attempt.created_at < now()-interval '5 minutes'
   then 'uncertain' else attempt.state end);
 end if;
 insert into smart_private.physical_box_delivery_email_attempts(physical_box_id,actor_id,state)
 values(p_id,p_actor,'sending') returning * into attempt;
 return jsonb_build_object('state','sending','token',attempt.token,'delivery',to_jsonb(delivery));
end $$;

create function public.finish_box_delivery_email(p_id uuid,p_token uuid,p_state text,p_provider text,p_code text) returns void
language plpgsql security definer set search_path='' as $$
begin
 if p_state is null or p_state not in ('sent','failed','uncertain') then raise exception 'Estado inválido.'; end if;
 perform 1 from smart_private.physical_box_deliveries where physical_box_id=p_id for update;
 update smart_private.physical_box_delivery_email_attempts
 set state=p_state,finished_at=clock_timestamp(),provider_id=left(p_provider,254),error_code=left(p_code,80)
 where physical_box_id=p_id and token=p_token and state='sending';
 if not found then raise exception 'Reserva de envio não encontrada.'; end if;
end $$;

create function public.reconcile_box_delivery_email(p_id uuid,p_sent boolean,p_note text) returns void
language plpgsql security definer set search_path='' as $$
begin
 perform smart_private.require_member(true);
 if p_sent is null or coalesce(length(btrim(p_note)),0) not between 10 and 500 then
  raise exception 'Informe o resultado da conferência do Gmail e uma justificativa de 10 a 500 caracteres.';
 end if;
 perform 1 from smart_private.physical_box_deliveries where physical_box_id=p_id for update;
 update smart_private.physical_box_delivery_email_attempts
 set state=case when p_sent then 'sent' else 'failed' end,finished_at=clock_timestamp(),error_code='admin_reconciled'
 where physical_box_id=p_id and
  (state='uncertain' or (state='sending' and created_at<now()-interval '5 minutes'));
 if not found then raise exception 'Não há tentativa incerta para reconciliar.'; end if;
 insert into smart_private.audit_log(actor_id,action,target_id,details)
 values(auth.uid(),'physical_box.email_reconcile',p_id::text,jsonb_build_object('sent',p_sent,'note',btrim(p_note)));
end $$;

revoke all on function smart_private.prevent_delivery_change(),smart_private.box_delivery_review(uuid,text)
 from public,anon,authenticated,service_role;
revoke all on function public.preview_box_delivery(uuid,text),public.close_physical_box(uuid,text,text),
 public.get_box_delivery(uuid),public.reconcile_box_delivery_email(uuid,boolean,text) from public,anon,authenticated,service_role;
grant execute on function public.preview_box_delivery(uuid,text),public.close_physical_box(uuid,text,text),
 public.get_box_delivery(uuid),public.reconcile_box_delivery_email(uuid,boolean,text) to authenticated;
revoke all on function public.claim_box_delivery_email(uuid,uuid),public.finish_box_delivery_email(uuid,uuid,text,text,text)
 from public,anon,authenticated,service_role;
grant execute on function public.claim_box_delivery_email(uuid,uuid),public.finish_box_delivery_email(uuid,uuid,text,text,text)
 to service_role;
commit;
