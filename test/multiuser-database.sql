-- Dois usuários Auth reais, role authenticated e fixtures descartadas por rollback.
-- Números negativos explícitos evitam consumir a sequência operacional (#000170 etc.).
begin;
do $$
declare a uuid; b uuid; d public.picking_documents; ids uuid[]:='{}'; idx integer;
begin
 select m.user_id into a from public.app_members m join auth.users u on u.id=m.user_id where m.active order by m.role,m.full_name limit 1;
 select m.user_id into b from public.app_members m join auth.users u on u.id=m.user_id where m.active and m.user_id<>a order by m.role desc,m.full_name limit 1;
 if a is null or b is null then raise exception 'Teste exige dois usuários autorizados distintos';end if;
 perform set_config('test.actor_a',a::text,true);perform set_config('test.actor_b',b::text,true);
 perform set_config('test.operational_before',(select md5(coalesce(jsonb_agg(to_jsonb(p) order by id)::text,'')) from public.picking_documents p where number>=0),true);
 for idx in 1..2 loop
  insert into public.picking_documents(number,owner_id,responsible,project,station,boxes)
  overriding system value values(-(txid_current()*100+idx),case when idx=1 then a else b end,'Fixture multiusuário','__MULTIUSER_TEST__','1',jsonb_build_array(jsonb_build_object('id',gen_random_uuid(),'name','Caixa 01'))) returning * into d;
  ids:=array_append(ids,d.id);
 end loop;
 perform set_config('test.doc_a',ids[1]::text,true);perform set_config('test.doc_b',ids[2]::text,true);
end $$;
select set_config('request.jwt.claim.sub',current_setting('test.actor_b'),true);
set local role authenticated;
do $$
declare a public.picking_documents; b public.picking_documents; before_a jsonb; rejected boolean;
begin
 select * into a from public.picking_documents where id=current_setting('test.doc_a')::uuid;
 select * into b from public.picking_documents where id=current_setting('test.doc_b')::uuid;
 if a.id is null or b.id is null or a.id=b.id or a.number=b.number or a.owner_id=b.owner_id then raise exception 'Consulta/isolamento inicial incorreto';end if;
 before_a:=to_jsonb(a);
 rejected:=false;
 begin perform public.save_picking(a.id,a.project,a.station,a.boxes,'[]');exception when others then if sqlerrm='Esta separação pertence a outro usuário.' then rejected:=true;else raise;end if;end;
 if not rejected then raise exception 'B alterou documento de A por RPC';end if;
 rejected:=false;
 begin perform public.finalize_picking(a.id);exception when others then if sqlerrm='Esta separação pertence a outro usuário.' then rejected:=true;else raise;end if;end;
 if not rejected then raise exception 'B confirmou documento de A';end if;
 rejected:=false;
 begin update public.picking_documents set owner_id=auth.uid() where id=a.id;exception when insufficient_privilege then rejected:=true;end;
 if not rejected and (select owner_id from public.picking_documents where id=a.id)<>a.owner_id then raise exception 'B assumiu propriedade por API de tabela';end if;
 begin update public.picking_documents set station='ALTERACAO_INDEVIDA' where id=a.id;exception when insufficient_privilege then null;end;
 b:=public.save_picking(b.id,b.project,b.station,b.boxes,jsonb_build_array(jsonb_build_object('id',gen_random_uuid(),'code','BMA0013539','project',b.project,'station',b.station,'qty',1,'box',b.boxes->0->>'id','purchase_order','21117','purchase_order_item','1','qr_prefix','180')));
 if b.owner_id<>auth.uid() or jsonb_array_length(b.items)<>1 then raise exception 'B não registrou QR na própria separação';end if;
 if (select to_jsonb(p) from public.picking_documents p where id=a.id)<>before_a then raise exception 'Documento de A sofreu alteração';end if;
end $$;
select set_config('request.jwt.claim.sub',current_setting('test.actor_a'),true);
do $$
declare a public.picking_documents; b public.picking_documents; before_b jsonb;
begin
 select * into a from public.picking_documents where id=current_setting('test.doc_a')::uuid;
 select * into b from public.picking_documents where id=current_setting('test.doc_b')::uuid;before_b:=to_jsonb(b);
 a:=public.save_picking(a.id,a.project,a.station,a.boxes,jsonb_build_array(jsonb_build_object('id',gen_random_uuid(),'code','BMA0000001','project',a.project,'station',a.station,'qty',2,'box',a.boxes->0->>'id')));
 if jsonb_array_length(a.items)<>1 or a.owner_id<>auth.uid() then raise exception 'A não continuou trabalhando';end if;
 if (select to_jsonb(p) from public.picking_documents p where id=b.id)<>before_b then raise exception 'Documento de B sofreu alteração';end if;
end $$;
reset role;
do $$ begin
 if (select md5(coalesce(jsonb_agg(to_jsonb(p) order by id)::text,'')) from public.picking_documents p where number>=0)<>current_setting('test.operational_before') then raise exception 'Registros operacionais alterados';end if;
 if exists(select 1 from smart_private.email_attempts where document_id in (current_setting('test.doc_a')::uuid,current_setting('test.doc_b')::uuid)) then raise exception 'Teste iniciou envio';end if;
end $$;
select 'PASSOU: dois usuários Auth distintos, consulta compartilhada, propriedade exclusiva, QR próprio, bloqueio de RPC/tabela e registros operacionais preservados' as resultado;
rollback;
