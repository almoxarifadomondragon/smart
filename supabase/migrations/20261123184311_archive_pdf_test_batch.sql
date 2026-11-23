begin;
set local lock_timeout='5s';
-- Reversible archive only. Original files, documents, reservations and audit stay intact.
alter table smart_private.pdf_import_batches add column if not exists archived_at timestamptz;
alter table smart_private.pdf_import_batches add column if not exists archive_reason text;
create or replace function public.pdf_import_history(p_filters jsonb default '{}',p_page integer default 1) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare output jsonb;
begin
 perform smart_private.require_member(false);
 if p_page is null or p_page<1 then raise exception 'Página inválida.';end if;
 with filtered as (
 select b.id,b.actor_id,b.created_at,b.state,b.result,b.archived_at,m.full_name,
  (select coalesce(jsonb_agg(jsonb_build_object('id',f.id,'name',f.name,'order',f.parsed->>'order')),'[]') from smart_private.pdf_import_files f where f.batch_id=b.id) files
 from smart_private.pdf_import_batches b join public.app_members m on m.user_id=b.actor_id
 where (b.archived_at is null or (p_filters->>'archived'='true' and smart_private.is_member(true)))
 and (coalesce(p_filters->>'status','')='' or b.state=p_filters->>'status')
 and (coalesce(p_filters->>'user','')='' or m.full_name ilike '%'||(p_filters->>'user')||'%')
 and (coalesce(p_filters->>'from','')='' or b.created_at >= ((p_filters->>'from')::date::timestamp at time zone 'America/Sao_Paulo'))
 and (coalesce(p_filters->>'to','')='' or b.created_at < (((p_filters->>'to')::date+1)::timestamp at time zone 'America/Sao_Paulo'))
 and (coalesce(p_filters->>'order','')='' or exists(select 1 from smart_private.pdf_import_files f where f.batch_id=b.id and f.parsed->>'order' ilike '%'||(p_filters->>'order')||'%'))
 and (coalesce(p_filters->>'project','')='' or exists(select 1 from jsonb_array_elements(b.result) r where r->>'project'=p_filters->>'project'))
 and (coalesce(p_filters->>'station','')='' or exists(select 1 from jsonb_array_elements(b.result) r where r->>'station'=p_filters->>'station'))
 ) select jsonb_build_object('total',(select count(*) from filtered),'rows',(select coalesce(jsonb_agg(to_jsonb(x)),'[]') from (select * from filtered order by created_at desc,id limit 20 offset (p_page::bigint-1)*20) x)) into output;
 return output;
end $$;


-- Archive only the named test batch after checking its actual cancellation and links.
do $$
declare b smart_private.pdf_import_batches; before_hash text;
begin
 perform pg_advisory_xact_lock(20261123);
 select * into b from smart_private.pdf_import_batches where id='0e837525-6131-405c-ad33-f9baa5d120c2' for update;
 if not found then return; end if;
 if b.state<>'cancelled' then raise exception 'O lote de teste não está cancelado. Nenhuma limpeza aplicada.';end if;
 if b.archived_at is not null then return;end if;
 -- This test had no confirmed import. Any allocation requires a new dependency review.
 if exists(select 1 from smart_private.pdf_order_allocations where batch_id=b.id) or coalesce(jsonb_array_length(b.result),0)>0 then
  raise exception 'Lote possui vínculos de separação. Preservado para revisão operacional.';
 end if;
 select md5(coalesce(jsonb_agg(to_jsonb(d) order by d.id)::text,'[]')) into before_hash from public.picking_documents d;
 update smart_private.pdf_import_batches set archived_at=now(),archive_reason='Teste cancelado de Amarildo em 23/11/2026 13:22:25. Arquivamento solicitado pelo usuário; PDFs e auditoria preservados.' where id=b.id;
 insert into smart_private.audit_log(actor_id,action,target_id,details) values(auth.uid(),'pdf.archive_test',b.id::text,
  jsonb_build_object('batch',b.id,'method','archive','requested_by','user','executed_via','deployment migration','original_actor',b.actor_id,'original_created_at',b.created_at,'previous_state',b.state,'files_preserved',(select count(*) from smart_private.pdf_import_files where batch_id=b.id),'allocations',0,'reason','Limpeza do teste cancelado identificado pelo usuário. Nenhum arquivo ou documento excluído.'));
 if before_hash is distinct from (select md5(coalesce(jsonb_agg(to_jsonb(d) order by d.id)::text,'[]')) from public.picking_documents d) then raise exception 'Documentos operacionais alterados. Arquivamento revertido.';end if;
end $$;
notify pgrst,'reload schema';
commit;
