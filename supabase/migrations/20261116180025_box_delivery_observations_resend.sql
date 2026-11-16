begin;
set local lock_timeout = '5s';

alter table smart_private.physical_box_deliveries add column observations text check (char_length(observations)<=2000);

alter table smart_private.physical_box_delivery_email_attempts
 add column send_type text check (send_type in ('initial','retry','resend')),
 add column request_id uuid;

create unique index box_delivery_request_once on smart_private.physical_box_delivery_email_attempts(physical_box_id,request_id) where request_id is not null;
create unique index box_delivery_one_unresolved on smart_private.physical_box_delivery_email_attempts(physical_box_id) where state in ('sending','uncertain');
drop index smart_private.box_delivery_no_duplicate_send;

create function public.close_physical_box(p_id uuid,p_expected text,p_reason text,p_observations text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare box smart_private.physical_boxes; review jsonb; delivery smart_private.physical_box_deliveries;
 observations text:=nullif(replace(replace(p_observations,chr(13)||chr(10),chr(10)),chr(13),chr(10)),'');
begin
 perform smart_private.require_member();
 -- Saves take document then box locks. Closing must never lock document rows.
 select * into box from smart_private.physical_boxes where id=p_id for update;
 if not found then raise exception 'Caixa física não encontrada.'; end if;
 if box.status='closed' then
  return smart_private.physical_box_public(box)||jsonb_build_object('delivery',public.get_box_delivery(p_id),'created',false);
 end if;
 review:=public.preview_box_delivery(p_id,p_reason);
 if p_expected is distinct from review->>'fingerprint' then
  raise exception using errcode='P4091',message='A conferência mudou ou está ausente. Confira a caixa novamente.';
 end if;
 if char_length(observations)>2000 or translate(observations,chr(10)||chr(9),'') ~ '[[:cntrl:]]' then
  raise exception 'Observações inválidas. Informe até 2.000 caracteres de texto.';
 end if;
 insert into smart_private.physical_box_deliveries(physical_box_id,closed_at,closed_by,closed_by_name,snapshot,recipient_snapshot,observations)
 values(p_id,clock_timestamp(),auth.uid(),review->>'closed_by_name',review->'snapshot',review->'recipient_snapshot',observations)
 returning * into delivery;
 update smart_private.physical_boxes set status='closed',updated_at=delivery.closed_at where id=p_id returning * into box;
 insert into smart_private.audit_log(actor_id,action,target_id,details)
 values(auth.uid(),'physical_box.close',p_id::text,jsonb_build_object(
  'code',box.code,'project',box.project,'station',box.station,
  'item_count',jsonb_array_length(delivery.snapshot->'items'),'documents',delivery.snapshot->'documents',
  'has_observations',observations is not null,'exception_reason',delivery.recipient_snapshot->'exception_reason'));
 return smart_private.physical_box_public(box)||jsonb_build_object('delivery',public.get_box_delivery(p_id),'created',true);
end $$;



create or replace function public.close_physical_box(p_id uuid,p_expected text,p_reason text default null) returns jsonb
language sql set search_path='' as $$ select public.close_physical_box(p_id,p_expected,p_reason,null) $$;

create or replace function public.get_box_delivery(p_id uuid) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare delivery smart_private.physical_box_deliveries; attempt smart_private.physical_box_delivery_email_attempts;
begin
 perform smart_private.require_member();
 select * into delivery from smart_private.physical_box_deliveries where physical_box_id=p_id;
 if not found then return null; end if;
 select * into attempt from smart_private.physical_box_delivery_email_attempts
 where physical_box_id=p_id order by created_at desc,token desc limit 1;
 return to_jsonb(delivery)||jsonb_build_object(
  'last_attempt_id',attempt.token,'last_attempt_at',attempt.created_at,
  'last_sent_at',(select max(finished_at) from smart_private.physical_box_delivery_email_attempts where physical_box_id=p_id and state='sent'),
  'email_state',case when attempt.state='sending' and attempt.created_at < now()-interval '5 minutes'
    then 'uncertain' else coalesce(attempt.state,'pending') end);
end $$;


create function public.claim_box_delivery_email(p_id uuid,p_actor uuid,p_request uuid,p_expected_attempt uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare
 delivery smart_private.physical_box_deliveries;
 latest smart_private.physical_box_delivery_email_attempts;
 prior_request smart_private.physical_box_delivery_email_attempts;
 kind text;
 is_copy boolean;
begin
 if not exists(select 1 from public.app_members where user_id=p_actor and active) then
  raise exception using errcode='42501',message='Usuário não autorizado ou inativo.';
 end if;
 if (p_request is null) <> (p_expected_attempt is null) then
  raise exception 'Confirmação de reenvio inválida.';
 end if;
 select * into delivery from smart_private.physical_box_deliveries where physical_box_id=p_id for update;
 if not found then raise exception 'Entrega não encontrada.'; end if;
 if p_request is not null then
  select * into prior_request from smart_private.physical_box_delivery_email_attempts
   where physical_box_id=p_id and request_id=p_request;
  if found then
   return jsonb_build_object('state',case when prior_request.state='sending' and prior_request.created_at < now()-interval '5 minutes'
    then 'uncertain' else prior_request.state end);
  end if;
 end if;
 select * into latest from smart_private.physical_box_delivery_email_attempts
  where physical_box_id=p_id order by created_at desc,token desc limit 1;
 if latest.state in ('sending','uncertain') then
  return jsonb_build_object('state',case when latest.state='sending' and latest.created_at < now()-interval '5 minutes'
   then 'uncertain' else latest.state end);
 end if;
 if p_request is not null then
  if latest.token is distinct from p_expected_attempt or latest.state is distinct from 'sent' then
   raise exception using errcode='P4091',message='O envio mudou. Atualize a consulta e confirme novamente.';
  end if;
  kind:='resend';
 elsif latest.state='sent' then
  return jsonb_build_object('state','sent');
 else
  kind:=case when latest.token is null then 'initial' else 'retry' end;
 end if;
 select exists(select 1 from smart_private.physical_box_delivery_email_attempts
  where physical_box_id=p_id and state='sent') into is_copy;
 insert into smart_private.physical_box_delivery_email_attempts(physical_box_id,actor_id,state,send_type,request_id)
 values(p_id,p_actor,'sending',kind,p_request) returning * into latest;
 return jsonb_build_object('state','sending','token',latest.token,'delivery',to_jsonb(delivery),'is_copy',is_copy);
end $$;

create or replace function public.claim_box_delivery_email(p_id uuid,p_actor uuid) returns jsonb
language sql set search_path='' as $$ select public.claim_box_delivery_email(p_id,p_actor,null,null) $$;

revoke all on function public.close_physical_box(uuid,text,text,text),public.claim_box_delivery_email(uuid,uuid,uuid,uuid)
 from public,anon,authenticated,service_role;
grant execute on function public.close_physical_box(uuid,text,text,text) to authenticated;
grant execute on function public.claim_box_delivery_email(uuid,uuid,uuid,uuid) to service_role;
notify pgrst, 'reload schema';
commit;
