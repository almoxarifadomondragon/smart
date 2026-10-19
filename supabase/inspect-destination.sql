-- Somente leitura. Executar exclusivamente no projeto qrcpprvxjgcnlxyushsg.
-- Se houver objetos existentes, comparar antes de executar schema.sql.
select table_schema,table_name from information_schema.tables
where table_schema='public' order by table_name;
select n.nspname as schema_name,p.proname,pg_get_function_identity_arguments(p.oid) as arguments,
 p.prosecdef as security_definer,p.proconfig,p.proacl
from pg_proc p join pg_namespace n on n.oid=p.pronamespace
where n.nspname='public' order by p.proname;
select schemaname,tablename,policyname,roles,cmd,qual,with_check
from pg_policies where schemaname='public' order by tablename,policyname;
select c.relname,c.relrowsecurity from pg_class c join pg_namespace n on n.oid=c.relnamespace
where n.nspname='public' and c.relkind='r';
