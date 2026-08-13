-- 0005_fix_grants_and_hook_access.sql
-- Achado real, diagnosticado pelo usuário rodando os testes pela primeira
-- vez de verdade: 2 furos de PRIVILÉGIO DE TABELA (GRANT), não de política
-- de RLS — camada diferente, mais básica. RLS só entra em ação DEPOIS que
-- o GRANT de tabela já permite a operação; sem o GRANT, o Postgres nega
-- antes mesmo de avaliar qualquer política.

-- =========================================================================
-- FURO 1 — Auth Hook: "permission denied for table profiles"
--
-- supabase_auth_admin (o role que executa custom_access_token_hook) nunca
-- recebeu GRANT SELECT em public.profiles. E mesmo com o GRANT, profiles
-- tem RLS habilitado e nenhuma policy mirava esse role especificamente —
-- ficaria bloqueado de qualquer forma. Corrigido com GRANT (só nas colunas
-- que o hook realmente lê) + 1 policy nova, escopada só pra esse role.
-- =========================================================================
grant select (id, tenant_id, platform_role, tenant_role)
  on public.profiles to supabase_auth_admin;

create policy profiles_select_auth_admin on public.profiles
  for select
  to supabase_auth_admin
  using (true);

comment on policy profiles_select_auth_admin on public.profiles is
  'Só o serviço interno de Auth usa este role — nenhum usuário externo '
  'jamais recebe supabase_auth_admin, então using(true) aqui não expõe '
  'nada pra fora. Sem esta policy, o login inteiro falha (erro 500 no '
  '/token), porque o hook não consegue montar o JWT.';

-- =========================================================================
-- FURO 2 — nenhuma tabela desta fase tinha GRANT de tabela pra
-- `authenticated`/`service_role`. Corrigido com o MÍNIMO necessário por
-- tabela, batendo exatamente com o que cada policy de RLS já permite —
-- não é "grant all" genérico, é grant específico por operação real.
-- =========================================================================

-- tenants: authenticated só lê (nenhuma policy de escrita existe pra esse role)
grant select on public.tenants to authenticated;

-- locations: authenticated lê/cria/atualiza — nunca deleta (soft-delete via status)
grant select, insert, update on public.locations to authenticated;

-- profiles: authenticated lê/atualiza — nunca insere direto (só via trigger de signup), nunca deleta
grant select, update on public.profiles to authenticated;

-- user_locations: authenticated tem as 4 operações (só TENANT_ADMIN passa pela policy, mas o grant de tabela é o mesmo pro role authenticated como um todo)
grant select, insert, update, delete on public.user_locations to authenticated;

-- service_role: acesso completo nas 4 — é o caminho de SUPER_ADMIN (Edge
-- Function) e do nosso próprio script de seed. bypassa RLS por padrão do
-- Supabase, mas isso não dispensa o GRANT de tabela — são camadas diferentes.
grant select, insert, update, delete on public.tenants to service_role;
grant select, insert, update, delete on public.locations to service_role;
grant select, insert, update, delete on public.profiles to service_role;
grant select, insert, update, delete on public.user_locations to service_role;
