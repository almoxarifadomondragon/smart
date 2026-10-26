begin;

-- Read-only endpoints run as the caller: existing RLS still applies. The
-- explicit membership check also rejects unaffiliated/inactive sessions.
create function public.search_picking_documents(
 p_number text default null, p_project text default null, p_station text default null,
 p_bma text default null, p_from date default null, p_to date default null,
 p_page integer default 1, p_scope text default 'confirmed'
) returns jsonb language plpgsql stable security invoker set search_path='' as $$
declare result jsonb; n bigint; project_code text; station_code text; bma_code text;
begin
 if auth.uid() is null or not exists(select 1 from public.app_members where user_id=auth.uid() and active)
 then raise exception using errcode='42501',message='Usuário não autorizado no almoxarifado.';end if;
 if p_page is null or p_page<1 or p_scope is null or p_scope not in ('confirmed','all')
 or (p_from is not null and not isfinite(p_from)) or (p_to is not null and not isfinite(p_to))
 or p_from>p_to then raise exception using errcode='22023',message='Página ou intervalo de datas inválido.';end if;
 if nullif(btrim(p_number),'') is not null then
  if btrim(p_number) !~ '^[0-9]{1,30}$' or btrim(p_number)::numeric>9223372036854775807
  then raise exception using errcode='22023',message='Número do romaneio inválido.';end if;
  n:=btrim(p_number)::bigint;
 end if;
 -- Same ASCII whitespace/case normalization as destination_code; keep leading zeros.
 project_code:=nullif(translate(btrim(coalesce(p_project,''),E' \t\n\r\f\013'),'abcdefghijklmnopqrstuvwxyz','ABCDEFGHIJKLMNOPQRSTUVWXYZ'),'');
 station_code:=nullif(translate(btrim(coalesce(p_station,''),E' \t\n\r\f\013'),'abcdefghijklmnopqrstuvwxyz','ABCDEFGHIJKLMNOPQRSTUVWXYZ'),'');
 bma_code:=nullif(upper(btrim(coalesce(p_bma,''))),'');
 if length(project_code)>120 or length(station_code)>120 or (bma_code is not null and bma_code !~ '^BMA[0-9]{7}$')
 then raise exception using errcode='22023',message='Informe projeto/estação válidos e o código BMA completo.';end if;
 with filtered as materialized (
  select d.* from public.picking_documents d
  where (p_scope='all' or d.status='confirmed') and (n is null or d.number=n)
   and (project_code is null or translate(btrim(d.project,E' \t\n\r\f\013'),'abcdefghijklmnopqrstuvwxyz','ABCDEFGHIJKLMNOPQRSTUVWXYZ')=project_code)
   and (station_code is null or translate(btrim(d.station,E' \t\n\r\f\013'),'abcdefghijklmnopqrstuvwxyz','ABCDEFGHIJKLMNOPQRSTUVWXYZ')=station_code)
   and (p_from is null or d.confirmed_at >= (p_from::timestamp at time zone 'America/Sao_Paulo'))
   and (p_to is null or d.confirmed_at < ((p_to+1)::timestamp at time zone 'America/Sao_Paulo'))
   and (bma_code is null or exists(select 1 from jsonb_array_elements(d.items) i where upper(btrim(i->>'code'))=bma_code))
 ), page_rows as (
  select id,number,owner_id,responsible,project,station,status,created_at,confirmed_at,
   jsonb_array_length(items) as item_count,jsonb_array_length(boxes) as box_count,
   coalesce((select sum((i->>'qty')::numeric) from jsonb_array_elements(items) i),0) as total_qty
  from filtered order by case when p_scope='all' then number end desc,confirmed_at desc nulls last,number desc
  limit 20 offset (p_page::bigint-1)*20
 )
 select jsonb_build_object('rows',coalesce((select jsonb_agg(to_jsonb(r) order by case when p_scope='all' then number end desc,confirmed_at desc nulls last,number desc) from page_rows r),'[]'::jsonb),
  'total',(select count(*) from filtered),'page',p_page,'page_size',20) into result;
 return result;
end $$;

create function public.get_picking_dashboard() returns jsonb
language plpgsql stable security invoker set search_path='' as $$
declare result jsonb;
begin
 if auth.uid() is null or not exists(select 1 from public.app_members where user_id=auth.uid() and active)
 then raise exception using errcode='42501',message='Usuário não autorizado no almoxarifado.';end if;
 select jsonb_build_object(
  'totals',jsonb_build_object('drafts',count(*) filter(where status='draft'),'confirmed',count(*) filter(where status='confirmed'),
   'boxes',coalesce(sum(jsonb_array_length(boxes)),0),
   'units',coalesce(sum((select sum((i->>'qty')::numeric) from jsonb_array_elements(items) i)),0)),
  'drafts',coalesce(jsonb_agg(jsonb_build_object('id',id,'number',number,'owner_id',owner_id,'responsible',responsible,'project',project,'station',station,
   'status',status,'created_at',created_at,'confirmed_at',confirmed_at,'item_count',jsonb_array_length(items),'box_count',jsonb_array_length(boxes),
   'total_qty',coalesce((select sum((i->>'qty')::numeric) from jsonb_array_elements(items) i),0)) order by number desc) filter(where status='draft'),'[]'::jsonb))
 into result from public.picking_documents;
 return result;
end $$;

revoke all on function public.search_picking_documents(text,text,text,text,date,date,integer,text), public.get_picking_dashboard() from public,anon;
grant execute on function public.search_picking_documents(text,text,text,text,date,date,integer,text), public.get_picking_dashboard() to authenticated;
-- No JSONB index: case-insensitive EXISTS must inspect any array entry; a plain
-- GIN would not accelerate this expression. Reassess using real query plans as
-- volume grows; current table is six documents. No table, RLS or data changes.
notify pgrst,'reload schema';
commit;
