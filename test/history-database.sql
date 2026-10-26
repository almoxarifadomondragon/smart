-- Disposable fixtures; explicit numbers do not advance the identity sequence.
-- Always rolled back. No Auth API, confirmation RPC or mail function is called.
begin;
select set_config('request.jwt.claim.sub',(select user_id::text from public.app_members where active order by user_id limit 1),true);
do $$
declare idx integer; p text:='0HISTORY-'||txid_current(); owner uuid:=auth.uid(); ids uuid[]:='{}'; next_id uuid; inactive uuid:=gen_random_uuid();
begin
 perform set_config('test.history_before',(select md5(coalesce(jsonb_agg(to_jsonb(d) order by id)::text,'')) from public.picking_documents d),true);
 perform set_config('test.history_project',p,true);
 perform set_config('test.history_inactive',inactive::text,true);
 insert into auth.users(id,email) values(inactive,'history-inactive-'||inactive||'@example.invalid');
 insert into public.app_members(user_id,full_name,role,active) values(inactive,'History fixture inactive','operator',false)
 on conflict(user_id) do update set active=false;
 for idx in 1..27 loop
  insert into public.picking_documents(number,owner_id,responsible,project,station,status,created_at,confirmed_at,boxes,items)
  overriding system value values(900000000000+txid_current()*100+idx,owner,'History fixture',case when idx=26 then 'OTHER-'||p else p end,
   case when idx=25 then '31200' else '031200' end,case when idx=27 then 'draft' else 'confirmed' end,'2026-09-01T12:00:00Z',
   case idx when 1 then '2026-09-30T02:59:59.999Z'::timestamptz when 2 then '2026-10-01T02:59:59.999Z'::timestamptz
    when 3 then '2026-10-01T03:00:00Z'::timestamptz when 4 then '2026-10-26T02:59:59.999Z'::timestamptz
    when 27 then null else '2026-10-26T15:00:00Z'::timestamptz end,
   '[{"id":"a","name":"Caixa 01"},{"id":"b","name":"Caixa 02"}]',
   jsonb_build_array(jsonb_build_object('code','BMA0000001','qty',2,'box','a'),jsonb_build_object('code',case when idx=2 then 'bma9999998' else 'BMA9999998' end,'qty',1.5,'box','b')))
  returning id into next_id;
  ids:=array_append(ids,next_id);
 end loop;
 perform set_config('test.history_ids',to_jsonb(ids)::text,true);
end $$;
set local role authenticated;
do $$
declare p text:=current_setting('test.history_project'); r jsonb; r2 jsonb; d jsonb; n text; rejected boolean; ids uuid[]; totals jsonb;
begin
 select array_agg(value::uuid) into ids from jsonb_array_elements_text(current_setting('test.history_ids')::jsonb);
 select number::text into n from public.picking_documents where id=ids[3];
 r:=public.search_picking_documents(p_number=>'000'||n);
 if (r->>'total')::int<>1 or r->'rows'->0->>'id'<>ids[3]::text then raise exception 'Number/leading zeros failed';end if;
 r:=public.search_picking_documents(p_project=>E' \t'||lower(p)||E'\n');
 if (r->>'total')::int<>25 or jsonb_array_length(r->'rows')<>20 then raise exception 'Project exact/normalization/pagination failed';end if;
 if r->'rows'->0 ? 'items' or r->'rows'->0 ? 'boxes' then raise exception 'Full arrays exposed';end if;
 if (r->'rows'->0->>'item_count')::int<>2 or (r->'rows'->0->>'total_qty')::numeric<>3.5 or (r->'rows'->0->>'box_count')::int<>2 then raise exception 'Incorrect summary totals';end if;
 r2:=public.search_picking_documents(p_project=>p,p_page=>2);
 if jsonb_array_length(r2->'rows')<>5 or r2->'total'<>r->'total' then raise exception 'Second page/count failed';end if;
 if exists(select 1 from jsonb_array_elements(r->'rows') a join jsonb_array_elements(r2->'rows') b on a->>'id'=b->>'id') then raise exception 'Repeated page records';end if;
 -- All records with the same timestamp are ordered by number DESC.
 if r->'rows'->0->>'id'<>ids[25]::text or r2->'rows'->4->>'id'<>ids[1]::text then raise exception 'Non-deterministic date/number order';end if;
 r:=public.search_picking_documents(p_project=>substring(p from 2));if (r->>'total')::int<>0 then raise exception 'Project zeros lost';end if;
 r:=public.search_picking_documents(p_project=>p,p_station=>'031200');if (r->>'total')::int<>24 then raise exception 'AND project/station failed';end if;
 r:=public.search_picking_documents(p_project=>p,p_station=>'31200');if (r->>'total')::int<>1 then raise exception 'Station zeros lost';end if;
 r:=public.search_picking_documents(p_project=>p,p_station=>'031200',p_bma=>'bma9999998');if (r->>'total')::int<>24 then raise exception 'AND+BMA last entry failed';end if;
 r:=public.search_picking_documents(p_bma=>'bma9999998');
 if not exists(select 1 from jsonb_array_elements(r->'rows') i where i->>'id'=ids[26]::text) then raise exception 'BMA across documents/projects failed';end if;
 r:=public.search_picking_documents(p_project=>p,p_from=>'2026-09-30',p_to=>'2026-09-30');
 if (r->>'total')::int<>1 or r->'rows'->0->>'id'<>ids[2]::text then raise exception 'Inclusive São Paulo day/case-insensitive BMA failed';end if;
 r:=public.search_picking_documents(p_project=>p,p_from=>'2026-09-30',p_to=>'2026-10-01');if (r->>'total')::int<>2 then raise exception 'Cross-month range failed';end if;
 r:=public.search_picking_documents(p_project=>p,p_from=>'2026-10-01',p_to=>'2026-10-31');if (r->>'total')::int<>23 then raise exception 'Confirmation date instead of creation failed';end if;
 r:=public.search_picking_documents(p_project=>p,p_from=>'2026-10-25',p_to=>'2026-10-25');if (r->>'total')::int<>1 then raise exception 'Midnight boundary failed';end if;
 r:=public.search_picking_documents(p_project=>p,p_from=>'2026-10-26',p_to=>'2026-10-26');if (r->>'total')::int<>21 then raise exception 'Same-day range failed';end if;
 r:=public.search_picking_documents(p_project=>p,p_from=>'2027-01-01');if (r->>'total')::int<>0 then raise exception 'No results failed';end if;
 rejected:=false;begin perform public.search_picking_documents(p_from=>'2026-10-26',p_to=>'2026-10-25');exception when invalid_parameter_value then rejected:=true;end;if not rejected then raise exception 'Invalid date range accepted';end if;
 rejected:=false;begin perform public.search_picking_documents(p_bma=>'BMA999');exception when invalid_parameter_value then rejected:=true;end;if not rejected then raise exception 'Partial BMA accepted';end if;
 rejected:=false;begin perform public.search_picking_documents(p_number=>'9223372036854775808');exception when invalid_parameter_value then rejected:=true;end;if not rejected then raise exception 'Overflow accepted';end if;
 r:=public.get_picking_dashboard();totals:=r->'totals';
 if (totals->>'confirmed')::int<>(select count(*) from public.picking_documents where status='confirmed')
 or (totals->>'drafts')::int<>(select count(*) from public.picking_documents where status='draft')
 or (totals->>'units')::numeric<>(select sum((i->>'qty')::numeric) from public.picking_documents cross join lateral jsonb_array_elements(items) i)
 or (totals->>'boxes')::int<>(select sum(jsonb_array_length(boxes)) from public.picking_documents)
 then raise exception 'Global overview totals are not global';end if;
 for d in select value from jsonb_array_elements(r->'drafts') loop
  if d ? 'items' or d ? 'boxes' or d->>'status'<>'draft' then raise exception 'Dashboard exposed historical/full arrays';end if;
 end loop;
 r:=public.search_picking_documents(p_project=>p,p_scope=>'all');if (r->>'total')::int<>26 then raise exception 'Overview excludes draft';end if;
 perform set_config('request.jwt.claim.sub',current_setting('test.history_inactive'),true);
 rejected:=false;begin perform public.search_picking_documents();exception when insufficient_privilege then rejected:=true;end;if not rejected then raise exception 'Inactive member allowed';end if;
 rejected:=false;begin perform public.get_picking_dashboard();exception when insufficient_privilege then rejected:=true;end;if not rejected then raise exception 'Inactive dashboard allowed';end if;
 perform set_config('request.jwt.claim.sub',gen_random_uuid()::text,true);
 rejected:=false;begin perform public.search_picking_documents();exception when insufficient_privilege then rejected:=true;end;if not rejected then raise exception 'Unaffiliated user allowed';end if;
 perform set_config('request.jwt.claim.sub','',true);
 rejected:=false;begin perform public.search_picking_documents();exception when insufficient_privilege then rejected:=true;end;if not rejected then raise exception 'Unauthenticated allowed';end if;
end $$;
reset role;
do $$
begin
 if has_function_privilege('anon','public.search_picking_documents(text,text,text,text,date,date,integer,text)','execute')
 or has_function_privilege('anon','public.get_picking_dashboard()','execute') then raise exception 'Anonymous execute allowed';end if;
 if exists(select 1 from pg_proc where oid in ('public.search_picking_documents(text,text,text,text,date,date,integer,text)'::regprocedure,'public.get_picking_dashboard()'::regprocedure) and prosecdef) then raise exception 'Unexpected definer privileges';end if;
 if current_setting('test.history_before')<>(select md5(coalesce(jsonb_agg(to_jsonb(d) order by id)::text,'')) from public.picking_documents d where not id in(select value::uuid from jsonb_array_elements_text(current_setting('test.history_ids')::jsonb))) then raise exception 'Operational records changed';end if;
end $$;
select 'PASS: server filters, pagination, summary, timezone, global totals, inactive/unauthorized/anonymous, RLS; operational records unchanged; rollback' as result;
rollback;
