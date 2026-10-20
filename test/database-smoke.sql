-- Teste transacional no SQL Editor. Substitua USER_UUID pelo administrador de teste.
-- Os registros são revertidos; a sequência pode reservar um número.
begin;
set local request.jwt.claim.sub = 'USER_UUID';
set local role authenticated;
do $$
declare
 doc public.picking_documents;
 new_box uuid := gen_random_uuid();
 item_id uuid := gen_random_uuid();
 entries jsonb;
 blocked boolean := false;
begin
 doc := public.create_picking('Validação técnica','Estação teste');
 if doc.owner_id <> auth.uid() or doc.responsible <> 'Denys Martinez' then
  raise exception 'Responsável incorreto';
 end if;
 entries := jsonb_build_array(jsonb_build_object('id',item_id,'code','BMA0006765',
  'project','Validação técnica','station','Estação teste','qty',4,'box',doc.boxes->0->>'id'));
 doc := public.save_picking(doc.id,doc.project,doc.station,doc.boxes,entries);
 if doc.items->0->>'operator' <> 'Denys Martinez' or doc.items->0->>'scanned_at' is null then
  raise exception 'Rastreabilidade ausente';
 end if;
 entries := jsonb_set(doc.items,'{0,box}',to_jsonb(new_box::text));
 doc := public.save_picking(doc.id,doc.project,doc.station,
  jsonb_build_array(jsonb_build_object('id',new_box,'name','Caixa remanejada')),entries);
 if doc.items->0->>'box' <> new_box::text or (doc.items->0->>'qty')::int <> 4 then
  raise exception 'Remanejamento inconsistente';
 end if;
 doc := public.finalize_picking(doc.id);
 if doc.status <> 'confirmed' or jsonb_array_length(doc.email_recipients) <> 3 then
  raise exception 'Confirmação incompleta';
 end if;
 begin
  perform public.save_picking(doc.id,doc.project,doc.station,doc.boxes,doc.items);
 exception when others then
  if sqlerrm = 'Romaneio já confirmado.' then blocked := true; else raise; end if;
 end;
 if not blocked then raise exception 'Romaneio confirmado permitiu edição'; end if;
end $$;
select 'PASSOU: criação, registro, remanejamento, confirmação e bloqueio de edição' as resultado;
rollback;
