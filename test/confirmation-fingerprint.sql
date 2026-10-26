-- Fixtures com numeração negativa explícita: não consome sequência nem persiste dados.
begin;
select set_config('request.jwt.claim.sub',(select user_id::text from public.app_members where active and role='admin' order by full_name limit 1),true);
do $$
declare
 baseline jsonb; project text:='__CONFIRM_FIX_'||txid_current(); m public.project_managers;
 d public.picking_documents; again public.picking_documents; preview jsonb; fresh jsonb;
 box text:=gen_random_uuid()::text; ids uuid[]:='{}'; rejected boolean; idx integer;
begin
 select to_jsonb(p) into baseline from public.picking_documents p where number=165;
 m:=public.save_project_manager(null,project,'gestor-fix@example.com',true);
 for idx in 1..5 loop
  insert into public.picking_documents(number,owner_id,responsible,project,station,boxes,items)
  overriding system value
  values(-(txid_current()*100+idx),auth.uid(),'Fixture transacional',case when idx=4 then project||'-EXCECAO' else project end,'1',
   jsonb_build_array(jsonb_build_object('id',box,'name','Caixa 01')),
   jsonb_build_array(jsonb_build_object('id',gen_random_uuid(),'code','BMA0000001','project',case when idx=4 then project||'-EXCECAO' else project end,'station','1','qty',1,'box',box))) returning * into d;
  ids:=array_append(ids,d.id);
 end loop;

 -- Sem adicionais; gestor cadastrado; nulo/vazio e múltiplas leituras são equivalentes.
 preview:=public.preview_recipients(ids[1],'[]',null);
 for idx in 1..10 loop
  if public.preview_recipients(ids[1],'[]','   ')->>'fingerprint' is distinct from preview->>'fingerprint' then raise exception 'Fingerprint não determinístico';end if;
 end loop;
 d:=public.finalize_picking(ids[1],'[]',null,preview->>'fingerprint');
 if d.status<>'confirmed' or not(d.email_recipients ? 'gestor-fix@example.com') then raise exception 'Confirmação sem adicionais falhou';end if;
 again:=public.finalize_picking(d.id,'[]',null,preview->>'fingerprint');
 if to_jsonb(d)<>to_jsonb(again) or (select count(*) from smart_private.audit_log where action='picking.confirm' and target_id=d.id::text)<>1 then raise exception 'Confirmação repetida não idempotente';end if;

 -- Adicionais em outra ordem, caixa e espaços: mesma conferência, sem duplicação.
 preview:=public.preview_recipients(ids[2],'[" B@EXAMPLE.COM ","a@example.com","b@example.com"]');
 fresh:=public.preview_recipients(ids[2],'["a@example.com","b@example.com"]');
 if preview->>'fingerprint'<>fresh->>'fingerprint' then raise exception 'Normalização/ordenação divergente';end if;
 d:=public.finalize_picking(ids[2],'["a@example.com","b@example.com"]',null,preview->>'fingerprint');
 if d.status<>'confirmed' or not(d.email_recipients ?& array['a@example.com','b@example.com','gestor-fix@example.com']) then raise exception 'Confirmação com adicionais falhou';end if;

 -- Alteração real bloqueia; documento e tentativas permanecem intactos.
 preview:=public.preview_recipients(ids[3]);
 perform public.save_project_manager(m.id,project,'gestor-novo@example.com',true);
 rejected:=false;
 begin perform public.finalize_picking(ids[3],'[]',null,preview->>'fingerprint');exception when sqlstate 'P4091' then rejected:=true;end;
 if not rejected then raise exception 'Alteração real não foi bloqueada';end if;
 select * into d from public.picking_documents where id=ids[3];
 if d.status<>'draft' or d.confirmed_at is not null or d.recipient_snapshot is not null or exists(select 1 from smart_private.email_attempts where document_id=d.id) then raise exception 'Rejeição alterou documento ou iniciou envio';end if;
 rejected:=false;
 begin perform public.claim_manifest_email(d.id);exception when others then rejected:=true;end;
 if not rejected or exists(select 1 from smart_private.email_attempts where document_id=d.id) then raise exception 'Envio permitido em rascunho rejeitado';end if;
 fresh:=public.preview_recipients(d.id);
 d:=public.finalize_picking(d.id,'[]',null,fresh->>'fingerprint');
 if d.status<>'confirmed' or not(d.email_recipients ? 'gestor-novo@example.com') then raise exception 'Nova aprovação não confirmou cadastro atualizado';end if;

 -- Exceção administrativa explícita, preservando justificativa normalizada.
 rejected:=false;
 begin perform public.preview_recipients(ids[4]);exception when sqlstate 'P4221' then rejected:=true;end;
 if not rejected then raise exception 'Cadastro pendente não identificado';end if;
 preview:=public.preview_recipients(ids[4],'[]','  Exceção de homologação autorizada  ');
 d:=public.finalize_picking(ids[4],'[]','Exceção de homologação autorizada',preview->>'fingerprint');
 if d.status<>'confirmed' or d.recipient_snapshot->>'exception_reason'<>'Exceção de homologação autorizada' then raise exception 'Exceção válida não confirmada';end if;

 rejected:=false;
 begin perform public.finalize_picking(ids[5],'[]',null,null);exception when sqlstate 'P4092' then rejected:=true;end;
 if not rejected then raise exception 'Aprovação ausente aceita';end if;
 if (select to_jsonb(p) from public.picking_documents p where number=165) is distinct from baseline then raise exception 'Documento operacional 165 alterado';end if;
 if exists(select 1 from smart_private.email_attempts where document_id=any(ids)) then raise exception 'Teste disparou tentativa de e-mail';end if;
end $$;
select 'PASSOU: determinismo, sem/com adicionais, gestor, exceção, repetição, divergência, nova aprovação e rejeição sem envio; 165 preservado' as resultado;
rollback;
