begin;

create function public.search_physical_boxes(
 p_code text default null, p_name text default null,
 p_project text default null, p_station text default null,
 p_bma text default null, p_document_number text default null,
 p_status text default null, p_closed_by text default null,
 p_date_type text default 'created', p_from date default null,
 p_to date default null, p_page integer default 1
) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare
 result jsonb;
 box_code text:=nullif(lower(btrim(p_code)),'');
 box_name text:=nullif(lower(btrim(p_name)),'');
 project_code text:=nullif(smart_private.destination_code(p_project),'');
 station_code text:=nullif(smart_private.destination_code(p_station),'');
 closer text:=nullif(lower(btrim(p_closed_by)),'');
 bma text:=nullif(upper(btrim(p_bma)),'');
 manifest text:=nullif(btrim(p_document_number),'');
 manifest_number bigint;
 date_from timestamptz;
 date_until timestamptz;
begin
 perform smart_private.require_member();
 if p_page is null or p_page<1 or p_date_type is null or p_date_type not in ('created','closed')
  or (p_status is not null and p_status not in ('available','in_use','closed'))
  or length(box_code)>60 or length(box_name)>60 or length(closer)>120
  or length(project_code)>120 or length(station_code)>120
  or (bma is not null and bma !~ '^BMA[0-9]{7}$')
  or (p_from is not null and not isfinite(p_from)) or (p_to is not null and not isfinite(p_to))
  or p_from>p_to then
  raise exception using errcode='22023',message='Filtros, página ou período inválidos.';
 end if;
 if manifest is not null then
  if manifest !~ '^[0-9]{1,30}$' then
   raise exception using errcode='22023',message='Número do romaneio inválido.';
  end if;
  if manifest::numeric>9223372036854775807 then
   raise exception using errcode='22023',message='Número do romaneio inválido.';
  end if;
  manifest_number:=manifest::bigint;
 end if;
 date_from:=p_from::timestamp at time zone 'America/Sao_Paulo';
 date_until:=(p_to::timestamp+interval '1 day') at time zone 'America/Sao_Paulo';

 with filtered as materialized (
  select b.id,b.code,b.name,b.project,b.station,b.status,b.created_at,
   d.closed_at,d.closed_by_name,
   case when d.physical_box_id is null then null
    when latest.state='sending' and latest.created_at<now()-interval '5 minutes' then 'uncertain'
    else coalesce(latest.state,'pending')
   end as email_state,
   case b.status when 'in_use' then 1 when 'available' then 2 else 3 end as status_order,
   coalesce(d.closed_at,b.created_at) as recent_at
  from smart_private.physical_boxes b
  left join smart_private.physical_box_deliveries d on d.physical_box_id=b.id
  left join lateral (
   select a.state,a.created_at from smart_private.physical_box_delivery_email_attempts a
   where a.physical_box_id=d.physical_box_id order by a.created_at desc,a.token desc limit 1
  ) latest on true
  where (box_code is null or strpos(lower(b.code),box_code)>0)
   and (box_name is null or strpos(lower(b.name),box_name)>0)
   and (project_code is null or b.project=project_code)
   and (station_code is null or b.station=station_code)
   and (p_status is null or b.status=p_status)
   and (closer is null or strpos(lower(d.closed_by_name),closer)>0)
   and (date_from is null or case when p_date_type='closed' then d.closed_at else b.created_at end >= date_from)
   and (date_until is null or case when p_date_type='closed' then d.closed_at else b.created_at end < date_until)
   and ((bma is null and manifest_number is null) or exists (
    select 1 from public.picking_documents doc
    where doc.boxes @> jsonb_build_array(jsonb_build_object('physical_box_id',b.id::text))
     and (manifest_number is null or doc.number=manifest_number)
     and (bma is null or exists (
      select 1 from jsonb_array_elements(doc.boxes) v
      join lateral jsonb_array_elements(doc.items) i on i->>'box'=v->>'id'
      where v->>'physical_box_id'=b.id::text and upper(btrim(i->>'code'))=bma
     ))
   ))
 ), stats as (
  select count(*) as total,count(*) filter(where status='available') as available,
   count(*) filter(where status='in_use') as in_use,count(*) filter(where status='closed') as closed,
   count(*) filter(where status='closed' and email_state in ('pending','failed','uncertain')) as pending,
   count(*) filter(where status='closed' and email_state='sending') as sending
  from filtered
 ), bounds as (
  select least(p_page::bigint,greatest(1,(stats.total+19)/20)) as page from stats
 ), page_boxes as materialized (
  select * from filtered order by status_order,recent_at desc,code
  limit 20 offset ((select page from bounds)-1)*20
 ), page_totals as (
  select b.id,count(distinct doc.id) as document_count,count(i.value) as item_count,
   coalesce(sum((i.value->>'qty')::numeric),0) as total_units
  from page_boxes b
  join public.picking_documents doc on doc.boxes @> jsonb_build_array(jsonb_build_object('physical_box_id',b.id::text))
  join lateral jsonb_array_elements(doc.boxes) v on v->>'physical_box_id'=b.id::text
  left join lateral jsonb_array_elements(doc.items) i on i->>'box'=v->>'id'
  group by b.id
 ), page_rows as (
  select b.*,coalesce(t.document_count,0) as document_count,
   coalesce(t.item_count,0) as item_count,coalesce(t.total_units,0) as total_units
  from page_boxes b left join page_totals t using(id)
 )
 select jsonb_build_object('rows',coalesce((
  select jsonb_agg(to_jsonb(r)-'status_order'-'recent_at' order by r.status_order,r.recent_at desc,r.code)
  from page_rows r
 ),'[]'::jsonb),'total',stats.total,'page',bounds.page,'page_size',20,'indicators',to_jsonb(stats))
 into result from stats cross join bounds;
 return result;
end $$;

revoke all on function public.search_physical_boxes(text,text,text,text,text,text,text,text,text,date,date,integer)
 from public,anon,authenticated,service_role;
grant execute on function public.search_physical_boxes(text,text,text,text,text,text,text,text,text,date,date,integer)
 to authenticated;
notify pgrst,'reload schema';
commit;
