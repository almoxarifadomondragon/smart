-- Apenas substitui as duas funções; não altera documentos ou cadastros.
begin;
create or replace function public.preview_recipients(p_id uuid,p_additional jsonb default '[]',p_exception_reason text default null)
returns jsonb language plpgsql security definer set search_path='' as $$
declare d public.picking_documents; manager public.project_managers; roles jsonb; effective jsonb; reason text:=btrim(coalesce(p_exception_reason,''));
begin
 perform smart_private.require_member();
 select * into d from public.picking_documents where id=p_id;
 if d.id is null or d.owner_id<>auth.uid() then raise exception 'Esta separação pertence a outro usuário.'; end if;
 if d.status='confirmed' then return jsonb_build_object('roles',coalesce(d.recipient_snapshot->'roles','[]'),'emails',d.email_recipients,'frozen',true); end if;
 if p_additional is null or jsonb_typeof(p_additional)<>'array' or jsonb_array_length(p_additional)>30 then raise exception 'Informe até 30 destinatários adicionais.'; end if;
 if exists(select 1 from jsonb_array_elements(p_additional) e where jsonb_typeof(e)<>'string'
 or length(btrim(e#>>'{}'))>254 or btrim(e#>>'{}') !~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$') then raise exception 'E-mail adicional inválido.'; end if;
 if (select count(*) from public.notification_recipients where role in ('PCP','Almoxarifado'))<>2 then raise exception using errcode='P4221', message='Cadastre PCP e Almoxarifado.'; end if;
 select * into manager from public.project_managers where project_code=upper(btrim(d.project)) and active;
 if manager.id is null then
  if not smart_private.is_member(true) or length(reason)<10 or length(reason)>500 then raise exception using errcode='P4221', message='Projeto sem gestor ativo. Cadastre o gestor ou solicite uma exceção explícita ao administrador.'; end if;
 elsif reason<>'' then raise exception using errcode='P4221', message='Exceção desnecessária: projeto possui gestor ativo.';
 end if;
 select jsonb_agg(jsonb_build_object('role',role,'email',lower(btrim(email))) order by role) into roles
 from public.notification_recipients where role in ('PCP','Almoxarifado');
 if manager.id is not null then roles:=roles||jsonb_build_array(jsonb_build_object('role','Gestor','email',manager.email)); end if;
 select roles||coalesce(jsonb_agg(jsonb_build_object('role','Adicional','email',e) order by e),'[]') into roles
 from (select distinct lower(btrim(value)) e from jsonb_array_elements_text(p_additional)) a;
 select jsonb_agg(email order by email) into effective from (select distinct value->>'email' email from jsonb_array_elements(roles)) a;
 return jsonb_build_object('roles',roles,'emails',effective,'project',d.project,'manager_id',manager.id,'exception_reason',nullif(reason,''),'fingerprint',md5(roles::text||d.project||reason));
end $$;

create or replace function public.finalize_picking(p_id uuid,p_additional jsonb default '[]',p_exception_reason text default null,p_expected text default null)
returns public.picking_documents language plpgsql security definer set search_path='' as $$
declare doc public.picking_documents; snapshot jsonb;
begin
 perform smart_private.require_member();
 select * into doc from public.picking_documents where id=p_id for update;
 if doc.id is null or doc.owner_id<>auth.uid() then raise exception 'Esta separação pertence a outro usuário.'; end if;
 if doc.status='confirmed' then return doc; end if;
 if trim(doc.project)='' or trim(doc.station)='' or jsonb_array_length(doc.items)=0 then raise exception 'Preencha projeto, estação e itens.'; end if;
 if exists(select 1 from jsonb_array_elements(doc.boxes) b where not exists(select 1 from jsonb_array_elements(doc.items) i where i->>'box'=b->>'id')) then raise exception 'Remova as caixas vazias.'; end if;
 snapshot:=public.preview_recipients(p_id,p_additional,p_exception_reason);
 if p_expected is null or btrim(p_expected)='' then raise exception using errcode='P4092', message='Conferência de destinatários ausente. Confira novamente antes de confirmar.'; end if;
 if snapshot->>'fingerprint' is null then raise exception using errcode='P5001', message='Não foi possível calcular a conferência de destinatários.'; end if;
 if p_expected is distinct from snapshot->>'fingerprint' then raise exception using errcode='P4091', message='Os destinatários mudaram desde a conferência. Revise e aprove novamente.'; end if;
 update public.picking_documents set status='confirmed',confirmed_at=now(),email_recipients=snapshot->'emails',recipient_snapshot=snapshot where id=p_id returning * into doc;
 insert into smart_private.audit_log(actor_id,action,target_id,details) values(auth.uid(),'picking.confirm',p_id::text,snapshot);
 return doc;
end $$;

commit;
