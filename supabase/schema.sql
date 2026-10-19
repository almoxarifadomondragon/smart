-- Execute uma vez no SQL Editor do projeto Supabase.
begin;
create table public.app_members (
 user_id uuid primary key references auth.users(id),
 full_name text not null check(length(trim(full_name)) > 0),
 role text not null default 'operator' check(role in ('operator','admin'))
);
create table public.picking_documents (
 id uuid primary key default gen_random_uuid(),
 number bigint generated always as identity (start with 147) unique,
 owner_id uuid not null references auth.users(id),
 responsible text not null,
 project text not null default '', station text not null default '',
 status text not null default 'draft' check(status in ('draft','confirmed')),
 boxes jsonb not null default '[]', items jsonb not null default '[]',
 created_at timestamptz not null default now(), confirmed_at timestamptz,
 email_status text not null default 'pending' check(email_status in ('pending','sent','failed')),
 email_recipients jsonb, email_provider_id text,
 check(jsonb_typeof(boxes)='array' and jsonb_typeof(items)='array')
);
create table public.notification_recipients (
 role text primary key check(role in ('PCP','Gestor','Almoxarifado')),
 email text not null check(email ~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$')
);
alter table public.app_members enable row level security;
alter table public.picking_documents enable row level security;
alter table public.notification_recipients enable row level security;
create policy member_self on public.app_members for select to authenticated using(user_id=auth.uid());
create policy documents_read on public.picking_documents for select to authenticated using(
 exists(select 1 from public.app_members where user_id=auth.uid())
);
create policy recipients_read on public.notification_recipients for select to authenticated using(
 exists(select 1 from public.app_members where user_id=auth.uid())
);
revoke all on public.app_members, public.picking_documents, public.notification_recipients from anon, authenticated;
grant select on public.app_members, public.picking_documents, public.notification_recipients to authenticated;
grant all on public.picking_documents, public.notification_recipients to service_role;

create function public.create_picking(p_project text, p_station text)
returns public.picking_documents language plpgsql security definer set search_path='' as $$
declare result public.picking_documents; operator_name text;
begin
 select full_name into operator_name from public.app_members where user_id=auth.uid();
 if operator_name is null then raise exception 'Usuário não autorizado no almoxarifado.'; end if;
 if length(p_project)>120 or length(p_station)>120 then raise exception 'Projeto ou estação muito longo.'; end if;
 insert into public.picking_documents(owner_id,responsible,project,station,boxes)
 values(auth.uid(),operator_name,trim(p_project),trim(p_station),jsonb_build_array(jsonb_build_object('id',gen_random_uuid(),'name','Caixa 01')))
 returning * into result;
 return result;
end $$;

create function public.save_picking(p_id uuid,p_project text,p_station text,p_boxes jsonb,p_items jsonb)
returns public.picking_documents language plpgsql security definer set search_path='' as $$
declare doc public.picking_documents; item jsonb; previous_item jsonb; normalized jsonb := '[]'; operator_name text;
begin
 select full_name into operator_name from public.app_members where user_id=auth.uid();
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

create function public.finalize_picking(p_id uuid)
returns public.picking_documents language plpgsql security definer set search_path='' as $$
declare doc public.picking_documents;
begin
 if not exists(select 1 from public.app_members where user_id=auth.uid()) then raise exception 'Usuário não autorizado.'; end if;
 select * into doc from public.picking_documents where id=p_id for update;
 if doc.id is null or doc.owner_id<>auth.uid() then raise exception 'Esta separação pertence a outro usuário.'; end if;
 if doc.status='confirmed' then return doc; end if;
 if trim(doc.project)='' or trim(doc.station)='' or jsonb_array_length(doc.items)=0 then raise exception 'Preencha projeto, estação e itens.'; end if;
 if exists(select 1 from jsonb_array_elements(doc.boxes) b where not exists(select 1 from jsonb_array_elements(doc.items) i where i->>'box'=b->>'id')) then raise exception 'Remova as caixas vazias.'; end if;
 if (select count(*) from public.notification_recipients)<>3 then raise exception 'Cadastre os e-mails de PCP, gestor e almoxarifado antes de confirmar.'; end if;
 update public.picking_documents set status='confirmed',confirmed_at=now(),email_recipients=(select jsonb_agg(email order by role) from public.notification_recipients) where id=p_id returning * into doc;
 return doc;
end $$;

create function public.set_recipients(p_recipients jsonb)
returns void language plpgsql security definer set search_path='' as $$
begin
 if not exists(select 1 from public.app_members where user_id=auth.uid() and role='admin') then raise exception 'Somente administradores podem cadastrar destinatários.'; end if;
 if jsonb_typeof(p_recipients)<>'array' or jsonb_array_length(p_recipients)<>3 then raise exception 'Cadastre as três áreas.'; end if;
 if (select count(distinct value->>'role') from jsonb_array_elements(p_recipients))<>3 then raise exception 'Áreas duplicadas.'; end if;
 insert into public.notification_recipients(role,email)
 select value->>'role',trim(value->>'email') from jsonb_array_elements(p_recipients)
 on conflict(role) do update set email=excluded.email;
end $$;
revoke all on function public.create_picking(text,text), public.save_picking(uuid,text,text,jsonb,jsonb), public.finalize_picking(uuid), public.set_recipients(jsonb) from public,anon;
grant execute on function public.create_picking(text,text), public.save_picking(uuid,text,text,jsonb,jsonb), public.finalize_picking(uuid), public.set_recipients(jsonb) to authenticated;
commit;

-- Após criar os usuários em Authentication > Users, autorize-os explicitamente:
-- insert into public.app_members(user_id,full_name,role)
-- values ('UUID-DO-USUARIO','Gabriela','admin');
