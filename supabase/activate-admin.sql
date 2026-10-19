-- Execute após criar a conta no Supabase Auth.
-- Substitua o e-mail abaixo pelo e-mail do administrador aprovado.
-- O script recusa continuar se a conta ainda não existe.
do $$
declare account_id uuid;
begin
 select id into account_id from auth.users where email = 'ADMIN_EMAIL_HERE';
 if account_id is null then raise exception 'Crie o usuário no Supabase Auth primeiro.'; end if;
 insert into public.app_members(user_id,full_name,role)
 values(account_id,'Denys Martinez','admin')
 on conflict(user_id) do update set full_name=excluded.full_name,role=excluded.role;
end $$;
