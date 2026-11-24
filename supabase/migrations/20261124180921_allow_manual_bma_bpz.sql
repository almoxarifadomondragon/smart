begin;
set local lock_timeout='5s';
select set_config('smart.universal_docs_before',(select md5(coalesce(jsonb_agg(to_jsonb(d) order by id)::text,'[]')) from public.picking_documents d),true);
select set_config('smart.universal_alloc_before',(select md5(coalesce(jsonb_agg(to_jsonb(a) order by id)::text,'[]')) from smart_private.pdf_order_allocations a),true);
-- Inspect expected invariants; do not silently overwrite a different trigger installation.
do $$ begin
 if not exists(select 1 from pg_trigger where tgrelid='public.picking_documents'::regclass and tgfoid='smart_private.guard_pdf_document()'::regprocedure and not tgisinternal and tgenabled='O') then raise exception 'Trigger PDF esperado não encontrado ou inativo.';end if;
 if position('BPZ exige vínculo' in pg_get_functiondef('smart_private.guard_pdf_document()'::regprocedure))=0 then raise exception 'Definição PDF diferente da versão revisada. Inspecione antes de migrar.';end if;
end $$;

create function smart_private.item_duplicate_review(p_document uuid,p_item jsonb) returns jsonb
language plpgsql stable set search_path='' as $$
declare matches jsonb; total bigint; fingerprint text;
begin
 with candidates as (
 select d.id document_id,d.number document_number,i->>'id' item_id,i->>'code' code,i->>'project' project,i->>'station' station,
 coalesce(a.source_order,i->>'source_order',i->>'purchase_order','') purchase_order,coalesce(i->>'source_line',i->>'purchase_order_item','') purchase_order_item,
 i->'qty' qty,case when a.item_id is not null then 'PDF' else coalesce(i->>'source','Legado') end source
 from public.picking_documents d cross join lateral jsonb_array_elements(d.items) i
 left join (select x.item_id,l.order_number source_order from smart_private.pdf_order_allocations x join smart_private.pdf_order_lines l on l.id=x.line_id where x.cancelled_at is null) a on a.item_id::text=i->>'id'
 where d.import_state is distinct from 'cancelled' and i->>'code'=p_item->>'code'
 and smart_private.destination_code(i->>'project')=smart_private.destination_code(p_item->>'project')
 and smart_private.destination_code(i->>'station')=smart_private.destination_code(p_item->>'station')
 and not (d.id=p_document and i->>'id'=p_item->>'id')
 ), summary as (select count(*) n,md5(coalesce(jsonb_agg(to_jsonb(c) order by document_id,item_id)::text,'[]')) digest from candidates c)
 select s.n,md5(jsonb_build_object('document',p_document,'item',p_item->>'id','code',p_item->>'code','project',smart_private.destination_code(p_item->>'project'),'station',smart_private.destination_code(p_item->>'station'),'order',coalesce(p_item->>'purchase_order',''),'line',coalesce(p_item->>'purchase_order_item',''),'qty',p_item->'qty','matches',s.digest)::text),
 (select coalesce(jsonb_agg(to_jsonb(x)),'[]') from (select * from candidates order by document_id,item_id limit 20) x)
 into total,fingerprint,matches from summary s;
 return jsonb_build_object('total',total,'matches',matches,'fingerprint',fingerprint);
end $$;
revoke all on function smart_private.item_duplicate_review(uuid,jsonb) from public,anon,authenticated,service_role;

create function public.preview_item_duplicates(p_document uuid,p_item jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare d public.picking_documents; candidate jsonb;
begin
 perform smart_private.require_operator();perform pg_advisory_xact_lock(20261123);
 select * into d from public.picking_documents where id=p_document;
 if d.id is null or d.owner_id<>auth.uid() or d.status<>'draft' or d.import_state in ('pending','cancelled') then raise exception 'Separação indisponível para registro operacional.';end if;
 if coalesce(p_item->>'code','') !~* '^(BMA|BPZ)[0-9]{7}$' or coalesce(p_item->>'id','') !~ '^[0-9a-f-]{36}$' then raise exception 'Código ou identidade da peça inválidos.';end if;
 candidate:=p_item||jsonb_build_object('code',upper(btrim(p_item->>'code')),'project',smart_private.destination_code(p_item->>'project'),'station',smart_private.destination_code(p_item->>'station'));
 return smart_private.item_duplicate_review(p_document,candidate);
end $$;
revoke all on function public.preview_item_duplicates(uuid,jsonb) from public,anon,authenticated;
grant execute on function public.preview_item_duplicates(uuid,jsonb) to authenticated;

create or replace function smart_private.guard_pdf_document() returns trigger
language plpgsql security definer set search_path='' as $$
declare a record; item jsonb; previous_item jsonb; normalized jsonb:='[]'; review jsonb; ack jsonb; origin text; old_origin text;
begin
 if old.import_state in ('pending','cancelled') and (new.items is distinct from old.items or new.boxes is distinct from old.boxes or new.status is distinct from old.status)
 and not exists(select 1 from smart_private.pdf_import_batches b join smart_private.pdf_order_allocations x on x.batch_id=b.id where x.document_id=old.id and b.state='review' and b.actor_id=auth.uid()) then raise exception 'Inicie a separação pendente antes de editar ou confirmar.';end if;
 -- Email/status bookkeeping must never rewrite frozen item JSON.
 if new.items is not distinct from old.items and new.boxes is not distinct from old.boxes and new.status is not distinct from old.status then return new;end if;
 if exists(select 1 from jsonb_array_elements(new.items) i group by i->>'id' having count(*)>1) then raise exception 'Identidade de item repetida.';end if;
 -- A regular edit cannot remove, replace or recycle any persisted documentary UUID.
 if exists(select 1 from smart_private.pdf_order_allocations x join jsonb_array_elements(old.items) i on x.item_id::text=i->>'id'
 where x.document_id=old.id and not exists(select 1 from jsonb_array_elements(new.items) n where n->>'id'=x.item_id::text)) then
 raise exception 'Item PDF vinculado não pode ser excluído ou ter o UUID substituído por edição comum. Use o fluxo autorizado de cancelamento documental.';end if;
 for item in select value from jsonb_array_elements(new.items) loop
  if coalesce(item->>'code','') !~ '^(BMA|BPZ)[0-9]{7}$' then raise exception 'Código BMA/BPZ inválido.';end if;
  select value into previous_item from jsonb_array_elements(old.items) i where i->>'id'=item->>'id';
  select x.*,l.order_number,l.original_line,l.code into a from smart_private.pdf_order_allocations x join smart_private.pdf_order_lines l on l.id=x.line_id where x.item_id=(item->>'id')::uuid;
  if found then
   if a.document_id<>new.id or a.cancelled_at is not null then raise exception 'UUID documental não pertence a este registro ativo.';end if;
   if (item ? 'source' and item->>'source' is distinct from 'PDF') or (item ? 'pdf_allocation_id' and item->>'pdf_allocation_id' is distinct from a.id::text) or (item ? 'source_order' and item->>'source_order' is distinct from a.order_number) or (item ? 'source_line' and item->>'source_line' is distinct from a.original_line) then raise exception 'Origem e alocação PDF são imutáveis.';end if;
   if item->>'code' is distinct from a.code or item->>'project' is distinct from (a.corrected->>'project') or item->>'station' is distinct from (a.corrected->>'station') or ((item->>'qty')::numeric<=0 or (item->>'qty')::numeric>a.quantity)
    or item->>'purchase_order' is distinct from substring(a.order_number from 3) or item->>'purchase_order_item' is distinct from a.original_line then raise exception 'O item PDF deve respeitar código, destino, pedido, linha e quantidade reservados. Faça outra importação para o saldo.';end if;
   item:=item||jsonb_build_object('source','PDF','source_order',a.order_number,'source_line',a.original_line,'pdf_allocation_id',a.id,'description',a.corrected->>'description');
  else
   if item->>'source'='PDF' or item ? 'pdf_allocation_id' or item ? 'source_order' or item ? 'source_line' then raise exception 'Origem PDF exige uma alocação documental real validada pelo servidor.';end if;
   old_origin:=previous_item->>'source';origin:=coalesce(item->>'source',old_origin,case when previous_item is null then 'Manual' end);
   if origin is not null and origin not in ('Manual','QR') then raise exception 'Origem operacional inválida.';end if;
   if old_origin is not null and old_origin is distinct from origin then raise exception 'A origem operacional original não pode ser alterada.';end if;
   if origin is not null then item:=item||jsonb_build_object('source',origin);end if;
   if previous_item is null or (previous_item->>'code',previous_item->>'project',previous_item->>'station',previous_item->'qty',previous_item->>'purchase_order',previous_item->>'purchase_order_item') is distinct from
    (item->>'code',item->>'project',item->>'station',item->'qty',item->>'purchase_order',item->>'purchase_order_item') then
    if exists(select 1 from jsonb_array_elements(new.items) n where n->>'id'<>item->>'id' and n->>'code'=item->>'code' and not exists(select 1 from jsonb_array_elements(old.items) o where o->>'id'=n->>'id')) then raise exception 'Registre possíveis duplicidades uma peça por vez, conferindo o alerta.';end if;
    review:=smart_private.item_duplicate_review(new.id,item);ack:=item->'duplicate_ack';
    if (review->>'total')::bigint>0 then
     if ack->>'fingerprint' is distinct from review->>'fingerprint' or length(btrim(coalesce(ack->>'reason',''))) not between 10 and 1000 then raise exception using errcode='P4094',message='Este código já possui registro para o mesmo projeto e estação. Confira os possíveis duplicados e justifique o registro adicional. Havendo vínculo PDF, utilize o saldo documental quando aplicável.';end if;
     item:=item||jsonb_build_object('duplicate_review',review||jsonb_build_object('reason',btrim(ack->>'reason'),'actor',auth.uid(),'at',now()));
    else item:=item-'duplicate_review';end if;
    insert into smart_private.audit_log(actor_id,action,target_id,details) values(auth.uid(),case when previous_item is null then 'picking.item.add' else 'picking.item.edit' end,new.id::text,jsonb_build_object('item',item->>'id','before',previous_item,'after',item-'duplicate_ack','source',origin,'duplicate_review',item->'duplicate_review'));
   elsif previous_item ? 'duplicate_review' then item:=item||jsonb_build_object('duplicate_review',previous_item->'duplicate_review');end if;
   item:=item-'duplicate_ack';
  end if;
  normalized:=normalized||jsonb_build_array(item);
 end loop;
 for previous_item in select value from jsonb_array_elements(old.items) o where not exists(select 1 from jsonb_array_elements(new.items) n where n->>'id'=o->>'id') loop
  insert into smart_private.audit_log(actor_id,action,target_id,details) values(auth.uid(),'picking.item.remove',new.id::text,jsonb_build_object('before',previous_item));
 end loop;
 new.items:=normalized;return new;
end $$;
revoke all on function smart_private.guard_pdf_document() from public,anon,authenticated,service_role;



-- Explicit current implementation, retaining ownership, versions, NF, boxes and destinations.
create or replace function smart_private.save_picking_impl(p_id uuid, p_project text, p_station text, p_boxes jsonb, p_items jsonb, p_revision bigint)
 RETURNS public.picking_documents
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare doc public.picking_documents; item jsonb; previous_item jsonb; normalized jsonb := '[]'; operator_name text; target_project text; target_station text; invoice text; old_bindings jsonb; new_bindings jsonb; invoice_changes jsonb;
begin
 perform smart_private.require_operator();perform pg_advisory_xact_lock(20261123);
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
 item:=item||jsonb_build_object('code',upper(btrim(item->>'code')));
 if coalesce(item->>'id','') !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' or coalesce(item->>'code','') !~ '^(BMA|BPZ)[0-9]{7}$'
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
 ) || (select coalesce(jsonb_object_agg(k,case when item ? k then item->k else previous_item->k end),'{}') from unnest(array['source','source_order','source_line','pdf_allocation_id','duplicate_ack']) k where item ? k or (k<>'duplicate_ack' and previous_item ? k)));
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


create or replace function public.stage_pdf_order(p_actor uuid,p_batch uuid,p_name text,p_hash text,p_path text,p_pages integer,p_parsed jsonb) returns uuid
language plpgsql security definer set search_path='' as $$
declare f uuid;
begin
 if not exists(select 1 from public.app_members where user_id=p_actor and active and role in ('admin','operator')) then raise exception 'Operador não autorizado.'; end if;
 perform 1 from smart_private.pdf_import_batches where id=p_batch and actor_id=p_actor and state='review' for update;
 if not found then raise exception 'Lote indisponível.';end if;
 if p_name is null or length(p_name)>255 or p_path<>p_actor::text||'/'||p_batch::text||'/'||p_hash||'.pdf'
 or jsonb_typeof(p_parsed->'rows') is distinct from 'array' or jsonb_array_length(p_parsed->'rows') not between 1 and 5000
 or coalesce(p_parsed->>'order','') !~ '^(VH|EZ)[0-9]{1,20}$' then raise exception 'Documento inválido.';end if;
 if (select count(*) from smart_private.pdf_import_files where batch_id=p_batch)>=25
 and not exists(select 1 from smart_private.pdf_import_files where batch_id=p_batch and sha256=p_hash) then raise exception 'Limite de 25 arquivos.';end if;
 insert into smart_private.pdf_import_files(batch_id,name,sha256,path,pages,parsed)
 values(p_batch,p_name,p_hash,p_path,p_pages,p_parsed) on conflict(batch_id,sha256) do update set name=smart_private.pdf_import_files.name returning id into f;
 return f;
end $$;


create or replace function public.confirm_pdf_import(p_id uuid,p_selection jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare b smart_private.pdf_import_batches; f smart_private.pdf_import_files; r jsonb; s jsonb; l smart_private.pdf_order_lines;
 qty numeric; used numeric; d public.picking_documents; target_project text; target_station text; item_id uuid; box_id text;
 groups jsonb:='{}'; output_result jsonb:='[]'; key text; entry jsonb; reason text;
begin
 perform smart_private.require_operator();
 -- Serialize allocation checks across batches, in addition to row locks.
 perform pg_advisory_xact_lock(20261123);
 select * into b from smart_private.pdf_import_batches where id=p_id for update;
 if b.id is null or b.actor_id<>auth.uid() then raise exception 'Lote indisponível.';end if;
 if b.state='confirmed' then
  if b.selection is distinct from p_selection then raise exception 'Lote já confirmado com outra seleção.';end if;
  return b.result;
 end if;
 if b.state<>'review' or jsonb_typeof(p_selection) is distinct from 'array' or jsonb_array_length(p_selection) not between 1 and 5000 then raise exception 'Seleção inválida.';end if;
 for s in select value from jsonb_array_elements(p_selection) loop
  select * into f from smart_private.pdf_import_files where id=(s->>'file_id')::uuid and batch_id=p_id;
  if f.id is null or coalesce(s->>'index','') !~ '^[0-9]{1,5}$' then raise exception 'Arquivo ou índice inválido.';end if;
  r:=f.parsed->'rows'->((s->>'index')::int-1);
  if r is null or r->>'order' !~ '^(VH|EZ)[0-9]{1,20}$' or r->>'line' !~ '^[0-9]{1,20}$' or r->>'code' !~ '^(BMA|BPZ)[0-9]{7}$'
   or coalesce(r->>'ordered','') !~ '^[0-9]{1,6}(\.[0-9]{1,2})?$' or (r->>'ordered')::numeric<=0
   or coalesce(r->>'sequence','') !~ '^[0-9]{1,20}$' then raise exception 'Linha original inválida.';end if;
  target_project:=smart_private.destination_code(s->>'project');target_station:=smart_private.destination_code(s->>'station');
  if coalesce(target_project,'') !~ '^[0-9]{1,20}$' or coalesce(target_station,'') !~ '^[0-9]{1,20}$'
   or length(btrim(coalesce(s->>'description',''))) not between 1 and 500 or coalesce(s->>'quantity','') !~ '^[0-9]{1,6}(\.[0-9]{1,2})?$'
   then raise exception 'Corrija destino, descrição e quantidade.';end if;
  reason:=btrim(coalesce(s->>'reason',''));
  if ((r->>'project',r->>'station',r->>'description') is distinct from (target_project,target_station,btrim(s->>'description')) or jsonb_array_length(coalesce(r->'warnings','[]'))>0)
   and length(reason)<5 then raise exception 'Justifique a correção ou divergência da etiqueta.';end if;
  if length(reason)>1000 then raise exception 'Justificativa muito longa.';end if;
  qty:=(s->>'quantity')::numeric;
  insert into smart_private.pdf_order_lines(origin,order_number,original_line,code,original,ordered)
  values(f.parsed->>'origin',r->>'order',r->>'line',r->>'code',r-'errors'-'warnings'-'page',(r->>'ordered')::numeric) on conflict do nothing;
  select * into l from smart_private.pdf_order_lines where origin=f.parsed->>'origin' and order_number=r->>'order' and original_line=r->>'line' and code=r->>'code' for update;
  if l.id is null or l.original is distinct from (r-'errors'-'warnings'-'page') then raise exception 'Pedido alterado desde a importação anterior. Revisão administrativa necessária.';end if;
  select coalesce(sum(quantity),0) into used from smart_private.pdf_order_allocations where line_id=l.id and cancelled_at is null;
  if qty<=0 or qty+used>l.ordered then raise exception 'Quantidade superior ao saldo importável do pedido %, linha %.',l.order_number,l.original_line;end if;
  key:=target_project||'|'||target_station;
  if not groups ? key then
   select * into d from public.create_picking(target_project,target_station);
   update public.picking_documents set import_state='pending' where id=d.id;
   groups:=groups||jsonb_build_object(key,d.id);
  else select * into d from public.picking_documents where id=(groups->>key)::uuid;end if;
  item_id:=gen_random_uuid();box_id:=d.boxes->0->>'id';
  insert into smart_private.pdf_order_allocations(batch_id,file_id,line_id,document_id,item_id,quantity,corrected,reason)
   values(p_id,f.id,l.id,d.id,item_id,qty,s,reason);
  entry:=jsonb_build_object('id',item_id,'code',l.code,'qty',qty,'project',target_project,'station',target_station,'box',box_id,
   'purchase_order',substring(l.order_number from 3),'purchase_order_item',l.original_line,'invoice_number','','qr_prefix','',
   'scanned_at',now(),'operator',d.responsible,'description',btrim(s->>'description'),'source','PDF','source_order',l.order_number,'source_line',l.original_line);
  update public.picking_documents set items=items||jsonb_build_array(entry) where id=d.id;
  insert into smart_private.audit_log(actor_id,action,target_id,details) values(auth.uid(),'pdf.allocate',l.id::text,jsonb_build_object('batch',p_id,'document',d.id,'item',item_id,'before',r,'after',s,'quantity',qty,'reason',reason));
 end loop;
 select jsonb_agg(jsonb_build_object('id',id,'number',number,'project',project,'station',station,'items',jsonb_array_length(items),'status','pending') order by project,station)
 into output_result from public.picking_documents where id in(select value::text::uuid from jsonb_each_text(groups));
 update smart_private.pdf_import_batches set state='confirmed',selection=p_selection,result=output_result,confirmed_at=now() where id=p_id;
 return output_result;
end $$;


do $$ begin
 if current_setting('smart.universal_docs_before') is distinct from (select md5(coalesce(jsonb_agg(to_jsonb(d) order by id)::text,'[]')) from public.picking_documents d) then raise exception 'Documentos existentes alterados. Migração revertida.';end if;
 if current_setting('smart.universal_alloc_before') is distinct from (select md5(coalesce(jsonb_agg(to_jsonb(a) order by id)::text,'[]')) from smart_private.pdf_order_allocations a) then raise exception 'Alocações existentes alteradas. Migração revertida.';end if;
end $$;
notify pgrst,'reload schema';
commit;
