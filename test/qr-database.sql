-- Teste transacional da leitura QR. Substitua USER_UUID pelo administrador de teste.
-- Reverte os registros ao terminar; pode reservar um número da sequência.
begin;
set local request.jwt.claim.sub = 'USER_UUID';
set local role authenticated;
do $$
declare doc public.picking_documents; entries jsonb; moved_box uuid := gen_random_uuid(); blocked boolean := false;
begin
 doc := public.create_picking('25024','31133');
 entries := jsonb_build_array(jsonb_build_object('id',gen_random_uuid(),'code','BMA0013539',
 'project','25024','station','31133','qty',1,'box',doc.boxes->0->>'id',
 'purchase_order','21117','purchase_order_item','1','qr_prefix','180'));
 doc := public.save_picking(doc.id,doc.project,doc.station,doc.boxes,entries);
 if doc.items->0->>'purchase_order'<>'21117' or doc.items->0->>'purchase_order_item'<>'1'
 or doc.items->0->>'qr_prefix'<>'180' then raise exception 'Dados do pedido foram perdidos'; end if;
 entries := jsonb_set(jsonb_set(doc.items,'{0,qty}','2.50'::jsonb),'{0,box}',to_jsonb(moved_box::text));
 doc := public.save_picking(doc.id,doc.project,doc.station,
 jsonb_build_array(jsonb_build_object('id',moved_box,'name','Caixa remanejada')),entries);
 if (doc.items->0->>'qty')::numeric<>2.50 or doc.items->0->>'purchase_order'<>'21117'
 or doc.items->0->>'purchase_order_item'<>'1' then raise exception 'Edição ou remanejamento perdeu dados'; end if;
 begin
  perform public.save_picking(doc.id,doc.project,doc.station,doc.boxes,jsonb_set(doc.items,'{0,purchase_order_item}','""'));
 exception when others then
  if sqlerrm = 'Pedido de compras ou item inválido.' then blocked := true; else raise; end if;
 end;
 if not blocked then raise exception 'Pedido incompleto foi aceito'; end if;
 doc := public.finalize_picking(doc.id);
 if doc.status<>'confirmed' or doc.items->0->>'purchase_order'<>'21117' then raise exception 'Romaneio inconsistente'; end if;
end $$;
select 'PASSOU: QR completo, quantidade decimal, pedido, remanejamento e confirmação' as resultado;
rollback;
