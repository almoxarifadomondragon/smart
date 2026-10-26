begin;
alter table smart_private.user_invites drop constraint user_invites_status_check;
alter table smart_private.user_invites add constraint user_invites_status_check check(status in ('pending','dispatching','completed','failed'));
create or replace function public.prepare_user_invite(p_email text,p_name text,p_role text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare r smart_private.user_invites;
begin
 perform smart_private.require_member(true);
 if p_email is null or length(p_email)>254 or btrim(p_email) !~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$'
 or p_name is null or length(btrim(p_name)) not between 1 and 160 or p_role not in ('admin','operator') or p_role is null then raise exception 'Dados do usuário inválidos.'; end if;
 if exists(select 1 from auth.users u join public.app_members m on m.user_id=u.id where lower(u.email)=lower(btrim(p_email))) then raise exception 'Usuário já cadastrado; edite seu perfil.'; end if;
 insert into smart_private.user_invites(email,full_name,role,actor_id) values(lower(btrim(p_email)),btrim(p_name),p_role,auth.uid()) on conflict(email) do nothing;
 select * into r from smart_private.user_invites where email=lower(btrim(p_email)) for update;
 if r.actor_id<>auth.uid() or r.full_name<>btrim(p_name) or r.role<>p_role then raise exception 'Existe um convite pendente com outros dados. Solicite reconciliação ao administrador.'; end if;
 if r.status<>'pending' then raise exception 'Convite já processado. Confira os usuários ou solicite reconciliação.'; end if;
 update smart_private.user_invites set status='dispatching',updated_at=now() where id=r.id;
 return to_jsonb(r);
end $$;
create or replace function public.complete_user_invite(p_request uuid,p_auth_id uuid) returns void
language plpgsql security definer set search_path='' as $$
declare r smart_private.user_invites;
begin
 perform pg_advisory_xact_lock(73492026);
 select * into r from smart_private.user_invites where id=p_request for update;
 if r.id is null or r.status<>'dispatching' then raise exception 'Solicitação inválida ou já processada.'; end if;
 if not exists(select 1 from public.app_members where user_id=r.actor_id and active and role='admin') then raise exception 'Solicitante sem autorização.'; end if;
 if not exists(select 1 from auth.users where id=p_auth_id and lower(email)=r.email) then raise exception 'Identidade não corresponde ao convite.'; end if;
 insert into public.app_members(user_id,full_name,role,active) values(p_auth_id,r.full_name,r.role,true);
 update smart_private.user_invites set status='completed',auth_id=p_auth_id,updated_at=now() where id=r.id;
 insert into smart_private.audit_log(actor_id,action,target_id,details) values(r.actor_id,'member.invite',p_auth_id::text,jsonb_build_object('request_id',r.id,'email',r.email,'role',r.role));
end $$;
create or replace function public.fail_user_invite(p_request uuid,p_auth_id uuid) returns void
language plpgsql security definer set search_path='' as $$
begin
 update smart_private.user_invites set status='failed',auth_id=p_auth_id,updated_at=now() where id=p_request and status in ('pending','dispatching');
 if found then insert into smart_private.audit_log(action,target_id,details) values('member.invite_failed',p_request::text,jsonb_build_object('auth_id',p_auth_id)); end if;
end $$;


commit;
