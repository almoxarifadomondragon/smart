begin;
-- Preserve every existing role/email row. IDs are independent of category.
alter table public.notification_recipients add column id uuid not null default gen_random_uuid();
alter table public.notification_recipients add column created_at timestamptz not null default now();
alter table public.notification_recipients drop constraint notification_recipients_pkey;
alter table public.notification_recipients add primary key(id);
create unique index notification_recipients_role_email_normalized on public.notification_recipients(role,lower(btrim(email)));

create or replace function public.set_recipients(p_recipients jsonb) returns void
language plpgsql security definer set search_path='' as $$
declare normalized jsonb;
begin
 perform smart_private.require_member(true);
 if p_recipients is null or jsonb_typeof(p_recipients)<>'array' then raise exception 'Informe os destinatários de PCP e Almoxarifado.';end if;
 if jsonb_array_length(p_recipients)<2 or jsonb_array_length(p_recipients)>60 then raise exception 'Cadastre de 1 a 30 e-mails por área.';end if;
 if exists(select 1 from jsonb_array_elements(p_recipients) e where jsonb_typeof(e)<>'object'
  or jsonb_typeof(e->'role') is distinct from 'string' or coalesce(e->>'role','') not in ('PCP','Almoxarifado')
  or jsonb_typeof(e->'email') is distinct from 'string' or length(btrim(e->>'email'))>254
  or btrim(e->>'email') !~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$') then raise exception 'Área ou e-mail inválido. Confira todos os endereços.';end if;
 if (select count(distinct e->>'role') from jsonb_array_elements(p_recipients) e)<>2
  or exists(select 1 from jsonb_array_elements(p_recipients) e group by e->>'role' having count(*)>30) then raise exception 'Cadastre de 1 a 30 e-mails por área.';end if;
 if exists(select 1 from jsonb_array_elements(p_recipients) e group by e->>'role',lower(btrim(e->>'email')) having count(*)>1) then raise exception 'Há e-mails repetidos na mesma área.';end if;
 select jsonb_agg(jsonb_build_object('role',e->>'role','email',lower(btrim(e->>'email'))) order by (e->>'role') collate "C",lower(btrim(e->>'email')) collate "C") into normalized from jsonb_array_elements(p_recipients) e;
 -- Serialize configuration saves and prevent replacement during confirmation.
 lock table public.notification_recipients in share row exclusive mode;
 delete from public.notification_recipients r where r.role in ('PCP','Almoxarifado') and not exists(
  select 1 from jsonb_array_elements(normalized) e where e->>'role'=r.role and e->>'email'=lower(btrim(r.email)));
 insert into public.notification_recipients(role,email) select e->>'role',e->>'email' from jsonb_array_elements(normalized) e
 on conflict(role,(lower(btrim(email)))) do nothing;
 insert into smart_private.audit_log(actor_id,action,details) values(auth.uid(),'recipients.save',normalized);
end $$;

create or replace function public.preview_recipients(p_id uuid,p_additional jsonb default '[]',p_exception_reason text default null)
returns jsonb language plpgsql security definer set search_path='' as $$
declare d public.picking_documents; manager public.project_managers; roles jsonb; effective jsonb; reason text:=btrim(coalesce(p_exception_reason,''));
begin
 perform smart_private.require_member();
 select * into d from public.picking_documents where id=p_id;
 if d.id is null or d.owner_id<>auth.uid() then raise exception 'Esta separação pertence a outro usuário.';end if;
 if d.status='confirmed' then return jsonb_build_object('roles',coalesce(d.recipient_snapshot->'roles','[]'),'emails',d.email_recipients,'frozen',true);end if;
 if p_additional is null or jsonb_typeof(p_additional)<>'array' or jsonb_array_length(p_additional)>30 then raise exception 'Informe até 30 destinatários adicionais.';end if;
 if exists(select 1 from jsonb_array_elements(p_additional) e where jsonb_typeof(e)<>'string'
  or length(btrim(e#>>'{}'))>254 or btrim(e#>>'{}') !~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$') then raise exception 'E-mail adicional inválido.';end if;
 lock table public.notification_recipients in share mode;
 if (select count(distinct role) from public.notification_recipients where role in ('PCP','Almoxarifado'))<>2
  or exists(select 1 from public.notification_recipients where role in ('PCP','Almoxarifado') group by role having count(*)>30)
  or exists(select 1 from public.notification_recipients where role in ('PCP','Almoxarifado') and (length(btrim(email))>254 or btrim(email) !~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$'))
 then raise exception using errcode='P4221',message='Cadastre de 1 a 30 e-mails válidos no PCP e no Almoxarifado.';end if;
 select * into manager from public.project_managers where project_code=upper(btrim(d.project)) and active;
 if manager.id is null then
  if not smart_private.is_member(true) or length(reason)<10 or length(reason)>500 then raise exception using errcode='P4221',message='Projeto sem gestor ativo. Cadastre o gestor ou solicite uma exceção explícita ao administrador.';end if;
 elsif reason<>'' then raise exception using errcode='P4221',message='Exceção desnecessária: projeto possui gestor ativo.';end if;
 select jsonb_agg(jsonb_build_object('role',role,'email',lower(btrim(email))) order by role collate "C",lower(btrim(email)) collate "C") into roles
 from public.notification_recipients where role in ('PCP','Almoxarifado');
 if manager.id is not null then roles:=roles||jsonb_build_array(jsonb_build_object('role','Gestor','email',lower(btrim(manager.email))));end if;
 select roles||coalesce(jsonb_agg(jsonb_build_object('role','Adicional','email',e) order by e collate "C"),'[]') into roles
 from (select distinct lower(btrim(value)) e from jsonb_array_elements_text(p_additional)) a;
 select jsonb_agg(email order by email collate "C") into effective from (select distinct value->>'email' email from jsonb_array_elements(roles)) a;
 -- IDs, timestamps and insertion order must not affect approval. Keep role
 -- associations, project and exception in the fingerprint to detect real changes.
 return jsonb_build_object('roles',roles,'emails',effective,'project',d.project,'manager_id',manager.id,'exception_reason',nullif(reason,''),
  'fingerprint',md5(jsonb_build_object('roles',roles,'project',d.project,'exception_reason',nullif(reason,''))::text));
end $$;

-- finalize_picking already calls preview_recipients and compares p_expected
-- before any status/snapshot update. Keep that function and its destination
-- validation unchanged. Its transaction holds the SHARE lock until commit.

create or replace function public.claim_manifest_email(p_id uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare d public.picking_documents; a smart_private.email_attempts; token uuid:=gen_random_uuid();
begin
 perform smart_private.require_member();
 select * into d from public.picking_documents where id=p_id for update;
 if d.id is null or d.owner_id<>auth.uid() then raise exception 'Romaneio não encontrado ou sem permissão'; end if;
 if d.status<>'confirmed' then raise exception 'Confirme o romaneio primeiro'; end if;
 if d.email_status='sent' then return jsonb_build_object('sent',true); end if;
 select * into a from smart_private.email_attempts where document_id=p_id and state in ('sending','uncertain') for update;
 if found then
  if a.state='sending' and a.created_at<now()-interval '90 seconds' then
   update smart_private.email_attempts set state='uncertain',error_code='interrupted',finished_at=now() where email_attempts.token=a.token;
   update public.picking_documents set email_delivery_state='uncertain',email_status='failed' where id=p_id;
  end if;
  return jsonb_build_object('blocked',true,'message','Envio em andamento ou com resultado incerto. Confira Enviados e solicite reconciliação ao administrador.');
 end if;
 if jsonb_typeof(d.email_recipients)<>'array' or jsonb_array_length(d.email_recipients)<1 or jsonb_array_length(d.email_recipients)>91
 or exists(select 1 from jsonb_array_elements_text(d.email_recipients) e where e !~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$') then raise exception 'Destinatários não cadastrados'; end if;
 insert into smart_private.email_attempts(token,document_id,actor_id,state,recipients) values(token,p_id,auth.uid(),'sending',d.email_recipients);
 update public.picking_documents set email_delivery_state='sending' where id=p_id;
 return jsonb_build_object('token',token,'document',to_jsonb(d));
end $$;

revoke all on function public.set_recipients(jsonb),public.preview_recipients(uuid,jsonb,text),public.claim_manifest_email(uuid) from public,anon;
grant execute on function public.set_recipients(jsonb),public.preview_recipients(uuid,jsonb,text),public.claim_manifest_email(uuid) to authenticated;
notify pgrst,'reload schema';
commit;
