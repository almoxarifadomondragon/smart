begin;
set local lock_timeout='5s';
select set_config('smart.pdf_before_hash',(select md5(coalesce(jsonb_agg(to_jsonb(d)-'import_state' order by id)::text,'[]')) from public.picking_documents d),true);
alter table public.picking_documents add column import_state text check(import_state in ('pending','active','cancelled'));

create table smart_private.pdf_import_batches (
 id uuid primary key, actor_id uuid not null references auth.users(id), created_at timestamptz not null default now(),
 state text not null default 'review' check(state in ('review','confirmed','cancelled')),
 selection jsonb, result jsonb, confirmed_at timestamptz
);
create table smart_private.pdf_import_files (
 id uuid primary key default gen_random_uuid(), batch_id uuid not null references smart_private.pdf_import_batches,
 name text not null, sha256 text not null check(sha256 ~ '^[a-f0-9]{64}$'), path text not null unique,
 pages integer not null check(pages between 1 and 200), parsed jsonb not null,
 unique(batch_id,sha256)
);
create table smart_private.pdf_order_lines (
 id uuid primary key default gen_random_uuid(), origin text not null, order_number text not null,
 original_line text not null, code text not null, original jsonb not null,
 ordered numeric(8,2) not null check(ordered>0 and ordered<=999999),
 unique(origin,order_number,original_line)
);
create table smart_private.pdf_order_allocations (
 id uuid primary key default gen_random_uuid(), batch_id uuid not null references smart_private.pdf_import_batches,
 file_id uuid not null references smart_private.pdf_import_files, line_id uuid not null references smart_private.pdf_order_lines,
 document_id uuid not null references public.picking_documents, item_id uuid not null unique,
 quantity numeric(8,2) not null check(quantity>0), corrected jsonb not null, reason text not null,
 cancelled_at timestamptz, unique(batch_id,line_id)
);
create index pdf_allocations_line on smart_private.pdf_order_allocations(line_id) where cancelled_at is null;
create index pdf_allocations_document on smart_private.pdf_order_allocations(document_id);
alter table smart_private.pdf_import_batches enable row level security;
alter table smart_private.pdf_import_files enable row level security;
alter table smart_private.pdf_order_lines enable row level security;
alter table smart_private.pdf_order_allocations enable row level security;
revoke all on smart_private.pdf_import_batches,smart_private.pdf_import_files,smart_private.pdf_order_lines,smart_private.pdf_order_allocations from public,anon,authenticated;

insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
values('picking-order-pdfs','picking-order-pdfs',false,20971520,array['application/pdf']);
-- Uploads and downloads are mediated by the authenticated Edge Function.

create function public.begin_pdf_import(p_id uuid) returns uuid
language plpgsql security definer set search_path='' as $$
begin
 perform smart_private.require_operator();
 insert into smart_private.pdf_import_batches(id,actor_id) values(p_id,auth.uid()) on conflict do nothing;
 if not exists(select 1 from smart_private.pdf_import_batches where id=p_id and actor_id=auth.uid() and state='review') then raise exception 'Lote indisponível.'; end if;
 return p_id;
end $$;

-- Only the Edge Function supplies canonical extraction and verified file bytes.
create function public.stage_pdf_order(p_actor uuid,p_batch uuid,p_name text,p_hash text,p_path text,p_pages integer,p_parsed jsonb) returns uuid
language plpgsql security definer set search_path='' as $$
declare f uuid;
begin
 if not exists(select 1 from public.app_members where user_id=p_actor and active and role in ('admin','operator')) then raise exception 'Operador não autorizado.'; end if;
 perform 1 from smart_private.pdf_import_batches where id=p_batch and actor_id=p_actor and state='review' for update;
 if not found then raise exception 'Lote indisponível.';end if;
 if p_name is null or length(p_name)>255 or p_path<>p_actor::text||'/'||p_batch::text||'/'||p_hash||'.pdf'
 or jsonb_typeof(p_parsed->'rows') is distinct from 'array' or jsonb_array_length(p_parsed->'rows') not between 1 and 5000
 or coalesce(p_parsed->>'order','') !~ '^VH[0-9]{1,20}$' then raise exception 'Documento inválido.';end if;
 if (select count(*) from smart_private.pdf_import_files where batch_id=p_batch)>=25
 and not exists(select 1 from smart_private.pdf_import_files where batch_id=p_batch and sha256=p_hash) then raise exception 'Limite de 25 arquivos.';end if;
 insert into smart_private.pdf_import_files(batch_id,name,sha256,path,pages,parsed)
 values(p_batch,p_name,p_hash,p_path,p_pages,p_parsed) on conflict(batch_id,sha256) do update set name=smart_private.pdf_import_files.name returning id into f;
 return f;
end $$;

create function public.preview_pdf_import(p_id uuid) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare b smart_private.pdf_import_batches; output jsonb;
begin
 perform smart_private.require_operator();
 select * into b from smart_private.pdf_import_batches where id=p_id;
 if b.id is null or b.actor_id<>auth.uid() then raise exception 'Lote indisponível.';end if;
 select jsonb_build_object('batch',b.id,'state',b.state,'result',b.result,'files',coalesce(jsonb_agg(jsonb_build_object(
 'id',f.id,'name',f.name,'hash',f.sha256,'pages',f.pages,'header',f.parsed-'rows','rows',(
 select coalesce(jsonb_agg(r||jsonb_build_object('index',n,'file_id',f.id,'allocated',coalesce((select sum(a.quantity) from smart_private.pdf_order_allocations a where a.line_id=l.id and a.cancelled_at is null),0),
 'conflict',l.id is not null and l.original is distinct from (r-'errors'-'warnings'-'page')) order by n),'[]')
 from jsonb_array_elements(f.parsed->'rows') with ordinality as src(r,n)
 left join smart_private.pdf_order_lines l on l.origin=f.parsed->>'origin' and l.order_number=r->>'order' and l.original_line=r->>'line'
 )) order by f.name),'[]')) into output from smart_private.pdf_import_files f where f.batch_id=p_id;
 return output;
end $$;

create function public.confirm_pdf_import(p_id uuid,p_selection jsonb) returns jsonb
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
  if r is null or r->>'order' !~ '^VH[0-9]{1,20}$' or r->>'line' !~ '^[0-9]{1,20}$' or r->>'code' !~ '^BPZ[0-9]{7}$'
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

create function public.start_pdf_picking(p_id uuid) returns public.picking_documents
language plpgsql security definer set search_path='' as $$
declare d public.picking_documents; previous_owner uuid;
begin
 perform smart_private.require_operator();
 perform pg_advisory_xact_lock(hashtextextended(auth.uid()::text,20261123));
 select * into d from public.picking_documents where id=p_id for update;
 if d.import_state is distinct from 'pending' or d.status<>'draft' then raise exception 'Separação não está pendente.';end if;
 if d.owner_id<>auth.uid() and not smart_private.is_member(true) then raise exception 'Esta separação pertence a outro usuário.';end if;
 if exists(select 1 from public.picking_documents where owner_id=auth.uid() and status='draft' and coalesce(import_state,'active')='active' and id<>p_id) then raise exception 'Conclua sua separação em andamento antes de iniciar outra.';end if;
 previous_owner:=d.owner_id;
 update public.picking_documents set import_state='active',owner_id=auth.uid(),responsible=(select full_name from public.app_members where user_id=auth.uid()) where id=p_id returning * into d;
 insert into smart_private.audit_log(actor_id,action,target_id,details) values(auth.uid(),'pdf.start',p_id::text,jsonb_build_object('previous_owner',previous_owner,'owner',auth.uid()));
 return d;
end $$;

create function public.pdf_import_history(p_filters jsonb default '{}',p_page integer default 1) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare output jsonb;
begin
 perform smart_private.require_member(false);
 if p_page is null or p_page<1 then raise exception 'Página inválida.';end if;
 with filtered as (
 select b.id,b.actor_id,b.created_at,b.state,b.result,m.full_name,
  (select coalesce(jsonb_agg(jsonb_build_object('id',f.id,'name',f.name,'order',f.parsed->>'order')),'[]') from smart_private.pdf_import_files f where f.batch_id=b.id) files
 from smart_private.pdf_import_batches b join public.app_members m on m.user_id=b.actor_id
 where (coalesce(p_filters->>'status','')='' or b.state=p_filters->>'status')
 and (coalesce(p_filters->>'user','')='' or m.full_name ilike '%'||(p_filters->>'user')||'%')
 and (coalesce(p_filters->>'from','')='' or b.created_at >= ((p_filters->>'from')::date::timestamp at time zone 'America/Sao_Paulo'))
 and (coalesce(p_filters->>'to','')='' or b.created_at < (((p_filters->>'to')::date+1)::timestamp at time zone 'America/Sao_Paulo'))
 and (coalesce(p_filters->>'order','')='' or exists(select 1 from smart_private.pdf_import_files f where f.batch_id=b.id and f.parsed->>'order' ilike '%'||(p_filters->>'order')||'%'))
 and (coalesce(p_filters->>'project','')='' or exists(select 1 from jsonb_array_elements(b.result) r where r->>'project'=p_filters->>'project'))
 and (coalesce(p_filters->>'station','')='' or exists(select 1 from jsonb_array_elements(b.result) r where r->>'station'=p_filters->>'station'))
 ) select jsonb_build_object('total',(select count(*) from filtered),'rows',(select coalesce(jsonb_agg(to_jsonb(x)),'[]') from (select * from filtered order by created_at desc,id limit 20 offset (p_page::bigint-1)*20) x)) into output;
 return output;
end $$;

create function public.pdf_order_file(p_id uuid) returns text
language plpgsql stable security definer set search_path='' as $$
begin
 perform smart_private.require_member(false);
 return (select f.path from smart_private.pdf_import_files f where f.id=p_id);
end $$;

create function public.cancel_pdf_import(p_id uuid,p_reason text) returns void
language plpgsql security definer set search_path='' as $$
declare b smart_private.pdf_import_batches;
begin
 perform smart_private.require_operator();perform pg_advisory_xact_lock(20261123);
 select * into b from smart_private.pdf_import_batches where id=p_id for update;
 if b.id is null or (b.actor_id<>auth.uid() and not smart_private.is_member(true)) or length(btrim(coalesce(p_reason,'')))<5 then raise exception 'Cancelamento não autorizado ou sem justificativa.';end if;
 if b.state='cancelled' then return;end if;
 perform 1 from public.picking_documents where id in(select document_id from smart_private.pdf_order_allocations where batch_id=p_id) order by id for update;
 if exists(select 1 from public.picking_documents d join smart_private.pdf_order_allocations a on a.document_id=d.id where a.batch_id=p_id and (d.import_state is distinct from 'pending' or d.status<>'draft')) then raise exception 'Somente lotes com todas as separações pendentes podem ser cancelados.';end if;
 update public.picking_documents set import_state='cancelled' where id in(select document_id from smart_private.pdf_order_allocations where batch_id=p_id);
 update smart_private.pdf_order_allocations set cancelled_at=now() where batch_id=p_id;
 update smart_private.pdf_import_batches set state='cancelled' where id=p_id;
 insert into smart_private.audit_log(actor_id,action,target_id,details) values(auth.uid(),'pdf.cancel',p_id::text,jsonb_build_object('reason',p_reason));
end $$;

create function public.review_pdf_order_line(p_file uuid,p_index integer,p_reason text) returns void
language plpgsql security definer set search_path='' as $$
declare f smart_private.pdf_import_files; r jsonb; l smart_private.pdf_order_lines; used numeric;
begin
 perform smart_private.require_member(true);perform pg_advisory_xact_lock(20261123);
 if length(btrim(coalesce(p_reason,''))) not between 5 and 1000 then raise exception 'Justifique a revisão administrativa.';end if;
 select * into f from smart_private.pdf_import_files where id=p_file;
 if not exists(select 1 from smart_private.pdf_import_batches where id=f.batch_id and state='review') then raise exception 'Lote indisponível.';end if;
 r:=f.parsed->'rows'->(p_index-1);
 if r is null or coalesce(r->>'ordered','') !~ '^[0-9]{1,6}(\.[0-9]{1,2})?$' or (r->>'ordered')::numeric<=0 then raise exception 'Linha inválida.';end if;
 select * into l from smart_private.pdf_order_lines where origin=f.parsed->>'origin' and order_number=r->>'order' and original_line=r->>'line' for update;
 if not found then raise exception 'Linha sem importação anterior.';end if;
 if l.code is distinct from r->>'code' then raise exception 'A linha alterou o código BPZ. Revise o pedido com o responsável antes de importar.';end if;
 select coalesce(sum(quantity),0) into used from smart_private.pdf_order_allocations where line_id=l.id and cancelled_at is null;
 if (r->>'ordered')::numeric<used then raise exception 'A nova quantidade é inferior à quantidade reservada.';end if;
 update smart_private.pdf_order_lines set original=r-'warnings'-'errors'-'page',ordered=(r->>'ordered')::numeric where id=l.id;
 insert into smart_private.audit_log(actor_id,action,target_id,details) values(auth.uid(),'pdf.revision',l.id::text,jsonb_build_object('before',l.original,'after',r,'reason',p_reason,'file',p_file));
end $$;

create function public.pdf_import_details(p_id uuid) returns jsonb
language plpgsql stable security definer set search_path='' as $$
begin
 perform smart_private.require_member(false);
 return jsonb_build_object('allocations',(select coalesce(jsonb_agg(jsonb_build_object('document',a.document_id,'item',a.item_id,'quantity',a.quantity,'cancelled_at',a.cancelled_at,'order',l.order_number,'line',l.original_line,'code',l.code,'correction',a.corrected,'reason',a.reason)),'[]') from smart_private.pdf_order_allocations a join smart_private.pdf_order_lines l on l.id=a.line_id where a.batch_id=p_id),
 'audit',case when smart_private.is_member(true) then (select coalesce(jsonb_agg(jsonb_build_object('actor',actor_id,'at',created_at,'action',action,'details',details)),'[]') from smart_private.audit_log where action like 'pdf.%' and (details->>'batch'=p_id::text or target_id=p_id::text or target_id in(select line_id::text from smart_private.pdf_order_allocations where batch_id=p_id))) else '[]'::jsonb end);
end $$;

-- Preserve document JSON provenance even when the existing save normalizes items.
create function smart_private.guard_pdf_document() returns trigger
language plpgsql security definer set search_path='' as $$
declare a record; item jsonb; normalized jsonb:='[]';
begin
 if old.import_state in ('pending','cancelled') and (new.items is distinct from old.items or new.boxes is distinct from old.boxes or new.status is distinct from old.status)
 and not exists(select 1 from smart_private.pdf_import_batches b join smart_private.pdf_order_allocations x on x.batch_id=b.id where x.document_id=old.id and b.state='review' and b.actor_id=auth.uid()) then raise exception 'Inicie a separação pendente antes de editar ou confirmar.';end if;
 for item in select value from jsonb_array_elements(new.items) loop
  select x.*,l.order_number,l.original_line,l.code into a from smart_private.pdf_order_allocations x join smart_private.pdf_order_lines l on l.id=x.line_id where x.document_id=new.id and x.item_id=(item->>'id')::uuid;
  if found then
   if item->>'code' is distinct from a.code or item->>'project' is distinct from (a.corrected->>'project') or item->>'station' is distinct from (a.corrected->>'station') or (item->>'qty')::numeric>a.quantity then raise exception 'O item PDF deve respeitar o código, destino e quantidade reservados. Faça outra importação para o saldo.';end if;
   item:=item||jsonb_build_object('source','PDF','source_order',a.order_number,'source_line',a.original_line,'description',a.corrected->>'description');
  elsif item->>'code' like 'BPZ%' then raise exception 'BPZ exige vínculo de importação PDF.';end if;
  normalized:=normalized||jsonb_build_array(item);
 end loop;
 new.items:=normalized;return new;
end $$;
create trigger guard_pdf_document before update on public.picking_documents for each row execute function smart_private.guard_pdf_document();

-- Extend the existing save and search implementations, keeping all other checks.
do $$ declare body text; begin
 body:=pg_get_functiondef('smart_private.save_picking_impl(uuid,text,text,jsonb,jsonb,bigint)'::regprocedure);
 if position('^BMA[0-9]{7}$' in body)=0 then raise exception 'Validação de código inesperada; revise a migração.';end if;
 execute replace(body,'^BMA[0-9]{7}$','^(BMA|BPZ)[0-9]{7}$');
 body:=pg_get_functiondef('public.search_picking_documents(text,text,text,text,date,date,integer,text)'::regprocedure);
 body:=replace(body,'^BMA[0-9]{7}$','^(BMA|BPZ)[0-9]{7}$');
 execute replace(body,'project,station,status,created_at','project,station,status,import_state,created_at');
 body:=pg_get_functiondef('public.get_picking_dashboard()'::regprocedure);
 body:=replace(body,'''status'',status,''created_at''','''status'',status,''import_state'',import_state,''created_at''');
 execute replace(body,'from public.picking_documents;','from public.picking_documents where import_state is distinct from ''cancelled'';');
 body:=pg_get_functiondef('public.create_physical_box(uuid,uuid,text)'::regprocedure);
 execute replace(body,'if doc.status<>''draft'' then','if doc.import_state in (''pending'',''cancelled'') then raise exception ''Inicie a separação pendente antes de criar caixas físicas.'';end if; if doc.status<>''draft'' then');
end $$;
revoke all on function smart_private.guard_pdf_document() from public,anon,authenticated;
revoke all on function public.begin_pdf_import(uuid),public.stage_pdf_order(uuid,uuid,text,text,text,integer,jsonb),public.preview_pdf_import(uuid),public.confirm_pdf_import(uuid,jsonb),public.start_pdf_picking(uuid),public.pdf_import_history(jsonb,integer),public.pdf_order_file(uuid),public.cancel_pdf_import(uuid,text) from public,anon,authenticated;
grant execute on function public.begin_pdf_import(uuid),public.preview_pdf_import(uuid),public.confirm_pdf_import(uuid,jsonb),public.start_pdf_picking(uuid),public.pdf_import_history(jsonb,integer),public.pdf_order_file(uuid),public.cancel_pdf_import(uuid,text) to authenticated;
grant execute on function public.stage_pdf_order(uuid,uuid,text,text,text,integer,jsonb) to service_role;
revoke all on function public.review_pdf_order_line(uuid,integer,text),public.pdf_import_details(uuid) from public,anon,authenticated;
grant execute on function public.review_pdf_order_line(uuid,integer,text),public.pdf_import_details(uuid) to authenticated;
do $$ begin
 if current_setting('smart.pdf_before_hash') is distinct from (select md5(coalesce(jsonb_agg(to_jsonb(d)-'import_state' order by id)::text,'[]')) from public.picking_documents d)
 then raise exception 'Os documentos existentes mudaram durante a migração. Transação revertida.';end if;
end $$;
notify pgrst,'reload schema';
commit;
