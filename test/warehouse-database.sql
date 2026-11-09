-- Execute only in an isolated disposable database, never against Supabase.
begin;
do $$ begin
 if current_setting('mondragon.test_fixture',true) is distinct from 'isolated' then
  raise exception 'Esta suíte só pode rodar no banco local descartável.';
 end if;
end $$;
select set_config('request.jwt.claim.sub',(select user_id::text from public.app_members where active and role='admin' limit 1),true);
select set_config('test.warehouse_operator',(select user_id::text from public.app_members where active and role='operator' limit 1),true);
set local role authenticated;
do $$
declare
 admin uuid:=auth.uid(); operator_id uuid:=current_setting('test.warehouse_operator')::uuid;
 p text:='00026005-WAREHOUSE'; s text:='031200';
 a public.picking_documents; b public.picking_documents; other public.picking_documents;
 first_item jsonb; second_item jsonb; boxes jsonb; stale bigint; snapshot jsonb;
 original jsonb; result jsonb; physical uuid:=gen_random_uuid(); code text; rejected boolean;
begin
 if admin is null or operator_id is null then raise exception 'Fixture sem duas identidades'; end if;
 perform public.save_project_manager(null,p,'warehouse-manager@example.invalid',true);
 a:=public.create_picking('','');
 if a.number is null or a.owner_id<>admin or a.project<>'' or a.station<>'' or a.items<>'[]' then raise exception 'Abertura vazia inválida'; end if;
 first_item:=jsonb_build_object('id',gen_random_uuid(),'code','BMA0013539','project',lower(p),'station',s,'qty',2,
  'box',a.boxes->0->>'id','purchase_order','0021117','purchase_order_item','1','invoice_number','00023/A');
 rejected:=false;
 begin perform public.save_picking_versioned(a.id,'','',a.boxes,jsonb_build_array(first_item||'{"invoice_number":"<script>"}'),a.revision);
 exception when others then if sqlerrm like 'Nota Fiscal inválida%' then rejected:=true;else raise;end if;end;
 if not rejected or (select project<>'' or station<>'' or items<>'[]' from public.picking_documents where id=a.id) then
  raise exception 'Falha de NF não reverteu a primeira leitura';
 end if;
 a:=public.save_picking_versioned(a.id,'','',a.boxes,jsonb_build_array(first_item),a.revision);
 if a.project<>p or a.station<>s or a.items->0->>'invoice_number'<>'00023/A' or a.revision<>1 then
  raise exception 'Primeira peça e destino não foram persistidos juntos';
 end if;
 result:=public.create_physical_box(a.id,physical,'Volume de homologação local');
 code:=result->>'code';
 if code !~ '^CX-[0-9]{6,}$' or result->>'status'<>'available' or public.create_physical_box(a.id,physical,'Volume de homologação local')->>'code'<>code then
  raise exception 'Código e criação idempotente da caixa inválidos';
 end if;
 boxes:=jsonb_set(a.boxes,'{0,physical_box_id}',to_jsonb(physical::text))||'[]'::jsonb;
 boxes:=jsonb_set(boxes,'{0,physical_box_code}','"FORJADO"');
 stale:=a.revision;
 a:=public.save_picking_versioned(a.id,p,s,boxes,a.items,a.revision);
 if a.boxes->0->>'physical_box_code'<>code then raise exception 'Código físico do cliente não foi descartado';end if;
 rejected:=false;
 begin perform public.save_picking_versioned(a.id,p,s,boxes,a.items,stale);
 exception when sqlstate 'P4093' then rejected:=true;end;
 if not rejected then raise exception 'Repetição com versão antiga foi aceita';end if;
 rejected:=false;
 begin perform public.save_picking(a.id,p,s,a.boxes,a.items);
 exception when sqlstate 'P4093' then rejected:=true;end;
 if not rejected then raise exception 'Cliente antigo pode sobrescrever a caixa/NF';end if;
 rejected:=false;
 begin perform public.close_physical_box(physical);
 exception when others then if sqlerrm like 'Conclua ou desvincule%' then rejected:=true;else raise;end if;end;
 if not rejected then raise exception 'Fechamento aceito com rascunho aberto';end if;
 -- Existing fingerprint and immutable confirmation remain the only confirmation path.
 snapshot:=public.preview_recipients(a.id);
 a:=public.finalize_picking(a.id,'[]',null,snapshot->>'fingerprint');
 original:=to_jsonb(a);
 perform set_config('request.jwt.claim.sub',operator_id::text,true);
 b:=public.create_picking('','');
 second_item:=jsonb_build_object('id',gen_random_uuid(),'code','BMA0013539','project',p,'station',s,'qty',3,
  'box',b.boxes->0->>'id','purchase_order','0021117','purchase_order_item','2');
 b:=public.save_picking_versioned(b.id,'','',b.boxes,jsonb_build_array(second_item),b.revision);
 if b.items->0->>'invoice_number'<>'' then raise exception 'NF opcional não permaneceu vazia';end if;
 boxes:=jsonb_set(b.boxes,'{0,physical_box_id}',to_jsonb(physical::text));
 b:=public.save_picking_versioned(b.id,p,s,boxes,jsonb_set(b.items,'{0,invoice_number}','"00000-SEG"'),b.revision);
 b:=public.save_picking_versioned(b.id,p,s,b.boxes,jsonb_set(b.items,'{0,invoice_number}','""'),b.revision);
 if b.items->0->>'invoice_number'<>'' then raise exception 'Limpeza explícita não persistiu';end if;
 snapshot:=public.preview_recipients(b.id);
 b:=public.finalize_picking(b.id,'[]',null,snapshot->>'fingerprint');
 result:=public.get_physical_box(physical);
 if jsonb_array_length(result->'documents')<>2 or jsonb_array_length(result->'items')<>2 or (result->>'total_units')::numeric<>5
   or result->'box'->>'code'<>code or result->'box'->>'status'<>'in_use'
   or result->'items'->0->>'invoice_number'<>'00023/A'
   or result->'items'->0->>'document_id'<>a.id::text or result->'items'->1->>'document_id'<>b.id::text then
  raise exception 'Consulta agregada perdeu itens, NF, quantidade ou origem';
 end if;
 if original<>(select to_jsonb(d) from public.picking_documents d where d.id=a.id) then raise exception 'Romaneio confirmado anterior foi alterado';end if;
 if jsonb_array_length(public.list_physical_boxes(lower(p),s))<>1 or public.list_physical_boxes(p,'31200')<>'[]' then
  raise exception 'Seleção por destino exato incorreta';
 end if;
 other:=public.create_picking('OUTRO',s);
 rejected:=false;
 begin perform public.save_picking_versioned(other.id,other.project,other.station,
  jsonb_set(other.boxes,'{0,physical_box_id}',to_jsonb(physical::text)),'[]',other.revision);
 exception when sqlstate 'P4225' then rejected:=true;end;
 if not rejected then raise exception 'Aceitou projeto diferente';end if;
 other:=public.create_picking(p,'31200');
 rejected:=false;
 begin perform public.save_picking_versioned(other.id,other.project,other.station,
  jsonb_set(other.boxes,'{0,physical_box_id}',to_jsonb(physical::text)),'[]',other.revision);
 exception when sqlstate 'P4225' then rejected:=true;end;
 if not rejected then raise exception 'Aceitou estação diferente';end if;
 rejected:=false;
 begin perform public.save_picking_versioned(a.id,p,s,a.boxes,a.items,a.revision);
 exception when others then if sqlerrm like '%outro usuário%' then rejected:=true;else raise;end if;end;
 if not rejected then raise exception 'Outro operador conseguiu modificar o romaneio';end if;
 perform set_config('request.jwt.claim.sub',admin::text,true);
 if public.close_physical_box(physical)->>'status'<>'closed' then raise exception 'Fechamento não persistiu';end if;
 other:=public.create_picking(p,s);
 rejected:=false;
 begin perform public.save_picking_versioned(other.id,p,s,jsonb_set(other.boxes,'{0,physical_box_id}',to_jsonb(physical::text)),'[]',other.revision);
 exception when sqlstate 'P4226' then rejected:=true;end;
 if not rejected or public.list_physical_boxes(p,s)<>'[]' then raise exception 'Caixa fechada voltou a aceitar vínculos';end if;
 result:=public.get_physical_box(physical);
 if result->'box'->>'id'<>physical::text or jsonb_array_length(result->'items')<>2 then raise exception 'Fechamento perdeu histórico';end if;
 if has_table_privilege('authenticated','smart_private.physical_boxes','SELECT')
   or has_function_privilege('anon','public.get_physical_box(uuid)','EXECUTE')
   or has_function_privilege('anon','public.save_picking_versioned(uuid,text,text,jsonb,jsonb,bigint)','EXECUTE') then
  raise exception 'Privilégio indevido';
 end if;
 perform set_config('request.jwt.claim.sub','11111111-1111-4111-8111-111111111111',true);
 rejected:=false;
 begin perform public.get_physical_box(physical); exception when insufficient_privilege then rejected:=true;end;
 if not rejected then raise exception 'QR permitiu consulta sem vínculo ativo';end if;
end $$;
reset role;
do $$ begin
 if (select count(*) from smart_private.audit_log where action='picking.invoice')<>3 or
    (select count(*) from smart_private.audit_log where action='physical_box.create')<>1 then
  raise exception 'Auditoria de NF ou criação idempotente incorreta';
 end if;
end $$;
rollback;
