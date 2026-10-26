-- Fixtures com números negativos; não consome a sequência nem persiste alterações.
begin;
select set_config('request.jwt.claim.sub',(select user_id::text from public.app_members where active and role='admin' order by full_name limit 1),true);
do $$
declare d public.picking_documents; ids uuid[]:='{}'; p text:='0DEST-'||txid_current(); s text:='0031133'; box text:=gen_random_uuid()::text; idx integer; entries jsonb;
begin
 perform set_config('test.destination_project',p,true);
 perform set_config('test.destination_before',(select md5(coalesce(jsonb_agg(to_jsonb(x) order by id)::text,'')) from public.picking_documents x where number>=0),true);
 perform set_config('test.audit_max',coalesce((select max(id)::text from smart_private.audit_log),'0'),true);
 perform set_config('test.audit_before',(select md5(coalesce(jsonb_agg(to_jsonb(x) order by id)::text,'')) from smart_private.audit_log x),true);
 if smart_private.destination_code(E'\t 0abc \r\n')<>'0ABC' or smart_private.destination_code('025024')=smart_private.destination_code('25024') then raise exception 'Normalização textual incorreta';end if;
 for idx in 1..10 loop
  entries:=case when idx in (6,7) then jsonb_build_array(jsonb_build_object('id',gen_random_uuid(),'code','BMA0000001','project','LEGADO-DIFERENTE','station',s,'qty',1,'box',box)) else '[]'::jsonb end;
  insert into public.picking_documents(number,owner_id,responsible,project,station,boxes,items,status,confirmed_at,email_recipients)
  overriding system value values(-(txid_current()*100+idx),auth.uid(),'Fixture destino único',case when idx in (2,4,8) then '' else p end,case when idx in (2,3,8) then '' else s end,
   jsonb_build_array(jsonb_build_object('id',box,'name','Caixa 01')),entries,case when idx=7 then 'confirmed' else 'draft' end,case when idx=7 then now() else null end,case when idx=7 then '["legado@example.com"]'::jsonb else null end) returning * into d;
  ids:=array_append(ids,d.id);
 end loop;
 perform set_config('test.destination_ids',to_jsonb(ids)::text,true);
end $$;
set local role authenticated;
do $$
declare ids uuid[]; p text:=current_setting('test.destination_project'); s text:='0031133'; d public.picking_documents; before_doc jsonb; entries jsonb; bad jsonb; x jsonb; snap jsonb; rejected boolean; idx integer; new_box text:=gen_random_uuid()::text;
begin
 select array_agg(value::uuid) into ids from jsonb_array_elements_text(current_setting('test.destination_ids')::jsonb);
 perform public.save_project_manager(null,p,'gestor-destino@example.com',true);
 select * into d from public.picking_documents where id=ids[1];
 entries:=jsonb_build_array(jsonb_build_object('id',gen_random_uuid(),'code','BMA0013539','project',lower(p),'station',s,'qty',1,'box',d.boxes->0->>'id','purchase_order','21117','purchase_order_item','1'));
 d:=public.save_picking(d.id,E' \t'||lower(p)||E'\n',s,d.boxes,entries);
 if d.project<>p or d.items->0->>'project'<>p then raise exception 'Mesmo destino normalizado não aceito';end if;
 before_doc:=to_jsonb(d);
 for idx in 1..3 loop
  bad:=case when idx=1 then jsonb_set(d.items,'{0,station}','"OUTRA"') when idx=2 then jsonb_set(d.items,'{0,project}','"OUTRO"') else jsonb_set(jsonb_set(d.items,'{0,project}','"OUTRO"'),'{0,station}','"OUTRA"') end;
  rejected:=false;begin perform public.save_picking(d.id,d.project,d.station,d.boxes,bad);exception when sqlstate 'P4223' then rejected:=position('Projeto esperado:' in sqlerrm)>0 and position('identificado no QR Code:' in sqlerrm)>0;end;
  if not rejected then raise exception 'Destino divergente aceito (%)',idx;end if;
 end loop;
 if (select to_jsonb(row_doc) from public.picking_documents row_doc where id=d.id)<>before_doc then raise exception 'Rejeição modificou documento';end if;
 for idx in 1..2 loop
  rejected:=false;
  begin perform public.save_picking(d.id,case when idx=1 then 'NOVO' else p end,case when idx=2 then 'NOVA' else s end,d.boxes,jsonb_set(d.items,case when idx=1 then '{0,project}'::text[] else '{0,station}'::text[] end,case when idx=1 then '"NOVO"'::jsonb else '"NOVA"'::jsonb end));exception when sqlstate 'P4224' then rejected:=true;end;
  if not rejected then raise exception 'Cabeçalho e itens reatribuídos juntos';end if;
 end loop;
 entries:=jsonb_set(jsonb_set(d.items,'{0,qty}','2.50'),'{0,box}',to_jsonb(new_box));
 d:=public.save_picking(d.id,p,s,jsonb_build_array(jsonb_build_object('id',new_box,'name','Remanejada')),entries);
 if (d.items->0->>'qty')::numeric<>2.50 or d.items->0->>'purchase_order'<>'21117' or d.items->0->>'scanned_at'<>before_doc->'items'->0->>'scanned_at' then raise exception 'Edição/remanejamento perdeu dados';end if;

 -- Primeira leitura: cabeçalho vazio e cabeçalhos parciais.
 for idx in 2..4 loop
  select * into d from public.picking_documents where id=ids[idx];
  entries:=jsonb_build_array(jsonb_build_object('id',gen_random_uuid(),'code','BMA0000001','project',p,'station',s,'qty',1,'box',d.boxes->0->>'id'));
  if idx=3 then
   rejected:=false;begin perform public.save_picking(d.id,'','',d.boxes,jsonb_set(entries,'{0,project}','"DIFERENTE"'));exception when sqlstate 'P4223' then rejected:=true;end;
   if not rejected then raise exception 'Cabeçalho parcial foi sobrescrito';end if;
  end if;
  d:=public.save_picking(d.id,'','',d.boxes,entries);
  if d.project<>p or d.station<>s then raise exception 'Primeira peça/cabeçalho não atômicos';end if;
 end loop;
 select * into d from public.picking_documents where id=ids[5];
 entries:=jsonb_build_array(jsonb_build_object('id',gen_random_uuid(),'code','BMA0000001','project',p,'station',s,'qty',1,'box',d.boxes->0->>'id'));
 for idx in 1..3 loop
  bad:=case when idx=1 then jsonb_set(entries,'{0,station}','"OUTRA"') when idx=2 then jsonb_set(entries,'{0,project}','"OUTRO"') else jsonb_set(jsonb_set(entries,'{0,project}','"OUTRO"'),'{0,station}','"OUTRA"') end;
  rejected:=false;begin perform public.save_picking(d.id,p,s,d.boxes,bad);exception when sqlstate 'P4223' then rejected:=true;end;
  if not rejected then raise exception 'Primeira leitura incompatível aceita';end if;
 end loop;
 rejected:=false;begin perform public.save_picking(d.id,substring(p from 2),s,d.boxes,jsonb_set(entries,'{0,box}',to_jsonb(d.boxes->0->>'id')));exception when sqlstate 'P4224' then rejected:=true;end;
 if not rejected then raise exception 'Primeiro item alterou referência definida ou perdeu zero';end if;

 -- Rascunho legado não pode incluir nem confirmar; confirmado legado é preservado.
 select * into d from public.picking_documents where id=ids[6];before_doc:=to_jsonb(d);
 rejected:=false;begin perform public.finalize_picking(d.id);exception when sqlstate 'P4223' then rejected:=true;end;
 if not rejected then raise exception 'Legado inconsistente confirmado';end if;
 entries:=jsonb_set(d.items,'{0,project}',to_jsonb(p));x:=jsonb_set(entries->0,'{id}',to_jsonb(gen_random_uuid()::text));
 rejected:=false;begin perform public.save_picking(d.id,p,s,d.boxes,entries||jsonb_build_array(x));exception when sqlstate 'P4223' then rejected:=true;end;
 if not rejected or (select to_jsonb(row_doc) from public.picking_documents row_doc where id=d.id)<>before_doc then raise exception 'Legado recebeu inclusão/alteração silenciosa';end if;
 select * into d from public.picking_documents where id=ids[7];before_doc:=to_jsonb(d);d:=public.finalize_picking(d.id);
 if to_jsonb(d)<>before_doc then raise exception 'Confirmado legado modificado';end if;

 select * into d from public.picking_documents where id=ids[8];
 entries:=jsonb_build_array(jsonb_build_object('id',gen_random_uuid(),'code','BMA0000001','project','','station','','qty',1,'box',d.boxes->0->>'id'));
 rejected:=false;begin perform public.save_picking(d.id,p,s,d.boxes,jsonb_set(jsonb_set(entries,'{0,project}','"DIFERENTE"'),'{0,station}',to_jsonb(s)));exception when sqlstate 'P4223' then rejected:=true;end;
 if not rejected then raise exception 'Cabeçalho e primeira peça divergentes aceitos';end if;
 rejected:=false;begin perform public.save_picking(d.id,'','',d.boxes,entries);exception when sqlstate 'P4223' then rejected:=true;end;
 if not rejected then raise exception 'BMA simples sem referência salvo';end if;

 -- Várias caixas compartilham um destino e mantêm a conferência de destinatários.
 select * into d from public.picking_documents where id=ids[10];
 entries:=jsonb_build_array(jsonb_build_object('id',gen_random_uuid(),'code','BMA0000001','project',p,'station',s,'qty',1,'box',d.boxes->0->>'id'),jsonb_build_object('id',gen_random_uuid(),'code','BMA0000002','project',p,'station',s,'qty',1,'box',new_box));
 d:=public.save_picking(d.id,p,s,d.boxes||jsonb_build_array(jsonb_build_object('id',new_box,'name','Caixa 02')),entries);
 rejected:=false;begin perform public.save_picking(d.id,p,s,d.boxes,jsonb_set(d.items,'{1,station}','"OUTRA"'));exception when sqlstate 'P4223' then rejected:=true;end;
 if not rejected then raise exception 'Caixas aceitaram destinos diferentes';end if;
 snap:=public.preview_recipients(d.id);d:=public.finalize_picking(d.id,'[]',null,snap->>'fingerprint');
 if d.status<>'confirmed' or not(d.email_recipients ? 'gestor-destino@example.com') then raise exception 'Confirmação uniforme/gestor inválidos';end if;

 select * into d from public.picking_documents where id=ids[1];d:=public.save_picking(d.id,'','',d.boxes,'[]');
 d:=public.save_picking(d.id,'NOVO','NOVA',d.boxes,'[]');
 if d.project<>'NOVO' or d.station<>'NOVA' then raise exception 'Não liberou destino após excluir todos os itens';end if;
end $$;
reset role;
do $$ begin
 if (select md5(coalesce(jsonb_agg(to_jsonb(x) order by id)::text,'')) from public.picking_documents x where number>=0)<>current_setting('test.destination_before') then raise exception 'Registros existentes modificados';end if;
 if (select md5(coalesce(jsonb_agg(to_jsonb(x) order by id)::text,'')) from smart_private.audit_log x where id<=current_setting('test.audit_max')::bigint)<>current_setting('test.audit_before') then raise exception 'Auditoria existente modificada';end if;
 if has_function_privilege('anon','public.save_picking(uuid,text,text,jsonb,jsonb)','EXECUTE') or has_function_privilege('anon','public.finalize_picking(uuid,jsonb,text,text)','EXECUTE') then raise exception 'RPC exposta a anon';end if;
end $$;
select 'PASSOU: destino único, cabeçalho vazio/parcial, bloqueios diretos, quantidade/remanejamento, várias caixas, confirmação, exclusão total e legados/auditoria preservados' as resultado;
rollback;

