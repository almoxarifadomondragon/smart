-- Run only in a disposable database.
begin;
do $$ begin
 if current_setting('mondragon.test_fixture',true) is distinct from 'isolated' then
  raise exception 'Esta suíte exige um banco de testes descartável.';
 end if;
end $$;

insert into smart_private.physical_boxes(id,project,station,name,status,created_by,created_at)
select ('abc00000-0000-4000-8000-'||lpad(n::text,12,'0'))::uuid,'0004567',
 case when n=22 then '0002' else '0001' end,
 case n when 1 then 'Elétrica 01' when 2 then 'Caixa histórica' else 'Estoque' end,
 case n when 1 then 'closed' when 2 then 'closed' when 3 then 'in_use' else 'available' end,
 (select user_id from public.app_members where active and role='admin' limit 1),
 '2026-11-16 02:30:00+00'::timestamptz
from generate_series(1,23) n;

insert into smart_private.physical_box_deliveries(physical_box_id,closed_at,closed_by,closed_by_name,snapshot,recipient_snapshot)
select 'abc00000-0000-4000-8000-000000000001','2026-11-16 03:30:00+00',user_id,'Ana do Almoxarifado','{}','{}'
from public.app_members where active and role='admin' limit 1;

insert into public.picking_documents(owner_id,responsible,project,station,status,confirmed_at,boxes,items)
select user_id,'Operador','0004567','0001','confirmed',now(),
 '[{"id":"v1","physical_box_id":"abc00000-0000-4000-8000-000000000001"},{"id":"v2","physical_box_id":"abc00000-0000-4000-8000-000000000003"},{"id":"v3"}]',
 '[{"box":"v1","code":"BMA0013539","qty":2.5},{"box":"v2","code":"BMA0013540","qty":1},{"box":"v3","code":"BMA0013599","qty":10}]'
from public.app_members where active and role='admin' limit 1;
insert into public.picking_documents(owner_id,responsible,project,station,status,confirmed_at,boxes,items)
select user_id,'Operador','0004567','0001','confirmed',now(),
 '[{"id":"v4","physical_box_id":"abc00000-0000-4000-8000-000000000001"}]',
 '[{"box":"v4","code":"BMA0013539","qty":3}]'
from public.app_members where active and role='admin' limit 1;

select set_config('test.box_search_admin',(select user_id::text from public.app_members where active and role='admin' limit 1),true);
insert into auth.users(id,email) values ('abc00000-0000-4000-8000-000000000098','inactive-box-search@example.invalid');
insert into public.app_members(user_id,full_name,role,active)
 values ('abc00000-0000-4000-8000-000000000098','Operador inativo','operator',false);
select set_config('request.jwt.claim.sub',(select user_id::text from public.app_members where active and role='operator' limit 1),true);
set local role authenticated;
do $$
declare r jsonb; manifest text; code text;
begin
 select number::text into manifest from public.picking_documents
 where project='0004567' and boxes @> '[{"id":"v1"}]';
 select b.code into code from jsonb_to_recordset(public.search_physical_boxes(p_name=>'elÉTRICA')->'rows') as b(code text);
 r:=public.search_physical_boxes(p_code=>right(code,4),p_name=>'ELÉTRICA',p_project=>'0004567',p_station=>'0001',
  p_bma=>'bma0013539',p_document_number=>'000'||manifest,p_status=>'closed',p_closed_by=>'ana',
  p_date_type=>'closed',p_from=>'2026-11-16',p_to=>'2026-11-16');
 if r->>'total'<>'1' or r->'rows'->0->>'document_count'<>'2' or r->'rows'->0->>'item_count'<>'2'
  or (r->'rows'->0->>'total_units')::numeric<>5.5 or r->'indicators'->>'pending'<>'1'
 then raise exception 'Filtros combinados ou totais incorretos: %',r; end if;
 if public.search_physical_boxes(p_bma=>'BMA0013599')->>'total'<>'0' then
  raise exception 'BMA de outro volume apareceu na pesquisa';
 end if;
 if public.search_physical_boxes(p_document_number=>manifest)->>'total'<>'2' then
  raise exception 'Pesquisa por romaneio incluiu volume interno ou omitiu vínculo';
 end if;
 r:=public.search_physical_boxes(p_project=>'0004567',p_page=>2);
 if r->>'total'<>'23' or r->>'page'<>'2' or jsonb_array_length(r->'rows')<>3
  or r->'indicators'->>'closed'<>'2' or r->'indicators'->>'available'<>'20'
 then raise exception 'Paginação/contagem incorreta: %',r;end if;
 r:=public.search_physical_boxes(p_project=>'0004567',p_status=>'closed',p_name=>'histórica');
 if r->>'total'<>'1' or r->'rows'->0->>'closed_at' is not null or r->'rows'->0->>'email_state' is not null
 then raise exception 'Caixa histórica ganhou metadados de entrega';end if;
 if public.search_physical_boxes(p_project=>'0004567',p_from=>'2026-11-15',p_to=>'2026-11-15')->>'total'<>'23'
  or public.search_physical_boxes(p_project=>'0004567',p_date_type=>'closed',p_from=>'2026-11-16')->>'total'<>'1'
  or public.search_physical_boxes(p_project=>'4567')->>'total'<>'0'
 then raise exception 'Data em São Paulo ou zeros iniciais incorretos';end if;
 perform set_config('request.jwt.claim.sub',current_setting('test.box_search_admin'),true);
 if public.search_physical_boxes(p_project=>'0004567')->>'total'<>'23' then raise exception 'Administrador sem consulta';end if;
 perform set_config('request.jwt.claim.sub','abc00000-0000-4000-8000-000000000099',true);
 begin
  perform public.search_physical_boxes();
  raise exception 'Usuário sem vínculo acessou as caixas';
 exception when insufficient_privilege then null;
 end;
 perform set_config('request.jwt.claim.sub','abc00000-0000-4000-8000-000000000098',true);
 begin
  perform public.search_physical_boxes();
  raise exception 'Usuário inativo acessou as caixas';
 exception when insufficient_privilege then null;
 end;
end $$;
reset role;
do $$ begin
 if has_function_privilege('anon','public.search_physical_boxes(text,text,text,text,text,text,text,text,text,date,date,integer)','execute') then
  raise exception 'Acesso anônimo à busca';
 end if;
end $$;
rollback;
