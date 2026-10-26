-- Não modifica registros existentes; helpers privados e RPCs preservam Auth, propriedade e RLS.
begin;
create or replace function smart_private.destination_code(p_value text) returns text
language sql immutable parallel safe set search_path='' as $$
 select translate(btrim(coalesce(p_value,''),chr(32)||chr(9)||chr(10)||chr(13)||chr(12)||chr(11)), 'abcdefghijklmnopqrstuvwxyz','ABCDEFGHIJKLMNOPQRSTUVWXYZ')
$$;
create or replace function smart_private.destination_mismatch(p_project text,p_station text,p_items jsonb) returns boolean
language sql immutable parallel safe set search_path='' as $$
 select exists(select 1 from jsonb_array_elements(p_items) i where smart_private.destination_code(p_project)='' or smart_private.destination_code(p_station)=''
 or smart_private.destination_code(i->>'project')<>smart_private.destination_code(p_project) or smart_private.destination_code(i->>'station')<>smart_private.destination_code(p_station))
$$;
create or replace function smart_private.assert_uniform_destination(p_project text,p_station text,p_items jsonb) returns void
language plpgsql immutable set search_path='' as $$
declare item jsonb;
begin
 select i into item from jsonb_array_elements(p_items) i where smart_private.destination_code(p_project)='' or smart_private.destination_code(p_station)=''
 or smart_private.destination_code(i->>'project')<>smart_private.destination_code(p_project) or smart_private.destination_code(i->>'station')<>smart_private.destination_code(p_station) limit 1;
 if found then raise exception using errcode='P4223',message=format(E'Peça não pertence a esta separação.\nProjeto esperado: %s\nEstação esperada: %s\nProjeto identificado no QR Code: %s\nEstação identificada no QR Code: %s',coalesce(nullif(smart_private.destination_code(p_project),''),'Não definido'),coalesce(nullif(smart_private.destination_code(p_station),''),'Não definida'),coalesce(nullif(smart_private.destination_code(item->>'project'),''),'Não informado'),coalesce(nullif(smart_private.destination_code(item->>'station'),''),'Não informada'));end if;
end $$;
revoke all on function smart_private.destination_code(text),smart_private.destination_mismatch(text,text,jsonb),smart_private.assert_uniform_destination(text,text,jsonb) from public;

CREATE OR REPLACE FUNCTION public.save_picking(p_id uuid, p_project text, p_station text, p_boxes jsonb, p_items jsonb)
 RETURNS picking_documents
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare doc public.picking_documents; item jsonb; previous_item jsonb; normalized jsonb := '[]'; operator_name text; target_project text; target_station text;
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
 'id',item->>'id','code',item->>'code','project',smart_private.destination_code(item->>'project'),'station',smart_private.destination_code(item->>'station'),
 'qty',(item->>'qty')::numeric,'box',item->>'box',
 'purchase_order',coalesce(item->>'purchase_order',''),'purchase_order_item',coalesce(item->>'purchase_order_item',''),
 'qr_prefix',coalesce(item->>'qr_prefix',''),
 'scanned_at',coalesce(previous_item->>'scanned_at',now()::text),
 'operator',coalesce(previous_item->>'operator',operator_name)
 ));
 end loop;
 update public.picking_documents set project=target_project,station=target_station,boxes=p_boxes,items=normalized where id=p_id returning * into doc;
 return doc;
end $function$
;

CREATE OR REPLACE FUNCTION public.finalize_picking(p_id uuid, p_additional jsonb DEFAULT '[]'::jsonb, p_exception_reason text DEFAULT NULL::text, p_expected text DEFAULT NULL::text)
 RETURNS picking_documents
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare doc public.picking_documents; snapshot jsonb;
begin
 perform smart_private.require_member();
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
commit;
