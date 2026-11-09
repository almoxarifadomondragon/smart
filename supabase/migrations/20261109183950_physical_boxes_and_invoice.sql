-- Additive: no historical picking is updated or associated with a physical box.
begin;
set local lock_timeout = '5s';

alter table public.picking_documents add column revision bigint not null default 0;
create index picking_documents_physical_boxes_idx on public.picking_documents using gin (boxes jsonb_path_ops);

create table smart_private.physical_boxes (
 id uuid primary key,
 serial_number bigint generated always as identity,
 code text generated always as
   ('CX-' || lpad(serial_number::text, greatest(6,length(serial_number::text)), '0')) stored unique,
 project text not null check (length(project) between 1 and 120),
 station text not null check (length(station) between 1 and 120),
 name text not null check (length(name) between 1 and 60),
 status text not null default 'available' check (status in ('available','in_use','closed')),
 created_by uuid not null references auth.users(id),
 created_at timestamptz not null default now(),
 updated_at timestamptz not null default now()
);
alter table smart_private.physical_boxes enable row level security;
revoke all on smart_private.physical_boxes from public, anon, authenticated;
create index physical_boxes_destination_idx on smart_private.physical_boxes(project,station,code) where status <> 'closed';

-- An internal volume holds one physical_box_id. Items still reference the
-- internal volume by ID; the document and its item IDs are the source of truth.
create function smart_private.physical_box_bindings(p_boxes jsonb) returns jsonb
language sql immutable set search_path='' as $$
 select coalesce(jsonb_object_agg(b->>'id',b->>'physical_box_id'),'{}'::jsonb)
 from jsonb_array_elements(p_boxes) b where coalesce(b->>'physical_box_id','')<>''
$$;

create function smart_private.check_physical_boxes(p_boxes jsonb,p_project text,p_station text) returns void
language plpgsql set search_path='' as $$
declare target uuid; box smart_private.physical_boxes;
begin
 if exists(select 1 from jsonb_array_elements(p_boxes) b where b ? 'physical_box_id' and
   coalesce(b->>'physical_box_id','') !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')
 then raise exception 'Identificação de caixa física inválida.'; end if;
 if exists(select 1 from jsonb_array_elements(p_boxes) b where b ? 'physical_box_id'
   group by b->>'physical_box_id' having count(*)>1)
 then raise exception 'Uma caixa física só pode ocupar um volume neste romaneio.'; end if;
 -- All saves lock their document first, then physical boxes by UUID order.
 for target in select (b->>'physical_box_id')::uuid from jsonb_array_elements(p_boxes) b
   where b ? 'physical_box_id' order by 1
 loop
  select * into box from smart_private.physical_boxes where id=target for update;
  if not found then raise exception 'Caixa física não encontrada.'; end if;
  if box.project<>p_project or box.station<>p_station then
   raise exception using errcode='P4225',message=format('Esta caixa pertence ao projeto %s, estação %s. A separação atual pertence ao projeto %s, estação %s. Selecione outra caixa.',box.project,box.station,coalesce(nullif(p_project,''),'não definido'),coalesce(nullif(p_station,''),'não definida'));
  end if;
  if box.status='closed' then raise exception using errcode='P4226',message='Esta caixa física está fechada. Selecione outra caixa.'; end if;
 end loop;
end $$;

create function smart_private.physical_box_public(p_box smart_private.physical_boxes) returns jsonb
language sql stable set search_path='' as $$
 select jsonb_build_object('id',p_box.id,'code',p_box.code,'project',p_box.project,
  'station',p_box.station,'name',p_box.name,'status',p_box.status,
  'created_at',p_box.created_at,'updated_at',p_box.updated_at,
  'can_close',p_box.status<>'closed' and (p_box.created_by=auth.uid() or smart_private.is_member(true)))
$$;

create function public.create_physical_box(p_document uuid,p_id uuid,p_name text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare doc public.picking_documents; box smart_private.physical_boxes; requested_name text:=btrim(p_name);
begin
 perform smart_private.require_member();
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

create function public.list_physical_boxes(p_project text,p_station text,p_search text default '') returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare result jsonb; search text:=left(btrim(coalesce(p_search,'')),60);
begin
 perform smart_private.require_member();
 select coalesce(jsonb_agg(smart_private.physical_box_public(b) order by b.code),'[]'::jsonb) into result
 from (select * from smart_private.physical_boxes where status<>'closed'
   and project=smart_private.destination_code(p_project) and station=smart_private.destination_code(p_station)
   and (search='' or strpos(lower(code),lower(search))>0 or strpos(lower(name),lower(search))>0)
   order by code limit 100) b;
 return result;
end $$;

create function public.get_physical_box(p_id uuid) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare box smart_private.physical_boxes; result jsonb;
begin
 perform smart_private.require_member();
 select * into box from smart_private.physical_boxes where id=p_id;
 if not found then raise exception 'Caixa física não encontrada.'; end if;
 with linked as materialized (
  select d.id,d.number,d.status,d.responsible,d.created_at,d.items,b->>'id' as volume_id
  from public.picking_documents d
  cross join lateral jsonb_array_elements(d.boxes) b
  where d.boxes @> jsonb_build_array(jsonb_build_object('physical_box_id',p_id::text))
  and b->>'physical_box_id'=p_id::text
 ), entries as (
  select d.id as document_id,d.number as document_number,d.status,d.responsible,d.created_at,
   i->>'id' as item_id,i->>'code' as code,(i->>'qty')::numeric as qty,
   i->>'invoice_number' as invoice_number,i->>'purchase_order' as purchase_order,
   i->>'purchase_order_item' as purchase_order_item,i->>'scanned_at' as scanned_at,
   coalesce(i->>'operator',d.responsible) as operator
  from linked d cross join lateral jsonb_array_elements(d.items) i where i->>'box'=d.volume_id
 )
 select jsonb_build_object('box',smart_private.physical_box_public(box),
  'documents',(select coalesce(jsonb_agg(jsonb_build_object('id',id,'number',number,'status',status) order by number),'[]') from linked),
  'items',(select coalesce(jsonb_agg(to_jsonb(e) order by document_number,scanned_at,item_id),'[]') from entries e),
  'total_units',(select coalesce(sum(qty),0) from entries)) into result;
 return result;
end $$;

create function public.close_physical_box(p_id uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare box smart_private.physical_boxes;
begin
 perform smart_private.require_member();
 -- Never take a document row lock while holding this physical box lock.
 select * into box from smart_private.physical_boxes where id=p_id for update;
 if not found then raise exception 'Caixa física não encontrada.'; end if;
 if box.created_by<>auth.uid() and not smart_private.is_member(true) then
  raise exception 'Somente quem cadastrou a caixa ou um administrador pode fechá-la.';
 end if;
 if box.status='closed' then return smart_private.physical_box_public(box); end if;
 if exists(select 1 from public.picking_documents where status='draft'
  and boxes @> jsonb_build_array(jsonb_build_object('physical_box_id',p_id::text)))
 then raise exception 'Conclua ou desvincule os rascunhos antes de fechar a caixa.'; end if;
 update smart_private.physical_boxes set status='closed',updated_at=now() where id=p_id returning * into box;
 insert into smart_private.audit_log(actor_id,action,target_id,details)
  values(auth.uid(),'physical_box.close',box.id::text,jsonb_build_object('code',box.code));
 return smart_private.physical_box_public(box);
end $$;

revoke all on function smart_private.physical_box_bindings(jsonb),
 smart_private.check_physical_boxes(jsonb,text,text),
 smart_private.physical_box_public(smart_private.physical_boxes)
 from public,anon,authenticated;
revoke all on function public.create_physical_box(uuid,uuid,text),
 public.list_physical_boxes(text,text,text),public.get_physical_box(uuid),public.close_physical_box(uuid)
 from public,anon,authenticated;
grant execute on function public.create_physical_box(uuid,uuid,text),
 public.list_physical_boxes(text,text,text),public.get_physical_box(uuid),public.close_physical_box(uuid)
 to authenticated;

create function smart_private.save_picking_impl(p_id uuid, p_project text, p_station text, p_boxes jsonb, p_items jsonb, p_revision bigint)
 RETURNS public.picking_documents
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare doc public.picking_documents; item jsonb; previous_item jsonb; normalized jsonb := '[]'; operator_name text; target_project text; target_station text; invoice text; old_bindings jsonb; new_bindings jsonb; invoice_changes jsonb;
begin
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

-- Legacy clients can still save ordinary drafts during rollout, but cannot
-- overwrite newer physical bindings or invoices without a version check.
create or replace function public.save_picking(p_id uuid,p_project text,p_station text,p_boxes jsonb,p_items jsonb)
returns public.picking_documents language sql security definer set search_path='' as $$
 select smart_private.save_picking_impl(p_id,p_project,p_station,p_boxes,p_items,null)
$$;

create function public.save_picking_versioned(p_id uuid,p_project text,p_station text,p_boxes jsonb,p_items jsonb,p_revision bigint)
returns public.picking_documents language plpgsql security definer set search_path='' as $$
begin
 if p_revision is null or p_revision<0 then raise exception 'Versão da separação inválida.'; end if;
 return smart_private.save_picking_impl(p_id,p_project,p_station,p_boxes,p_items,p_revision);
end $$;

revoke all on function smart_private.save_picking_impl(uuid,text,text,jsonb,jsonb,bigint)
 from public,anon,authenticated;
revoke all on function public.save_picking_versioned(uuid,text,text,jsonb,jsonb,bigint)
 from public,anon,authenticated;
grant execute on function public.save_picking_versioned(uuid,text,text,jsonb,jsonb,bigint)
 to authenticated;
commit;
