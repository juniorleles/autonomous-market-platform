-- seed.sql
-- Dados MÍNIMOS de desenvolvimento — nada real, tudo sintético.
-- Roda depois das migrations (`supabase db reset` já aplica isso sozinho).
--
-- Usuários de Auth precisam ser criados via `supabase.auth.admin.createUser()`
-- (API), não por INSERT direto em auth.users — o schema de auth.users tem
-- particularidades internas do GoTrue que uma migration SQL pura não deveria
-- tentar replicar manualmente (senha com hash específico, etc.). Por isso
-- este arquivo faz só a parte "de negócio" (tenants/locations), e o
-- script `tests/seed-users.ts` (rodado 1x, fora da migration) cria os
-- usuários de Auth de verdade, passando tenant_id/role em raw_user_meta_data
-- pra o trigger handle_new_user() já criar o profile certo.

insert into public.tenants (id, name, slug, plan, status, billing_email) values
  ('00000000-0000-0000-0000-00000000000a', 'Tenant A — Condomínio Jardins', 'tenant-a', 'starter', 'active', 'admin@tenant-a.example'),
  ('00000000-0000-0000-0000-00000000000b', 'Tenant B — Escritório Central', 'tenant-b', 'starter', 'active', 'admin@tenant-b.example')
on conflict (id) do nothing;

insert into public.locations (id, tenant_id, name, type, status) values
  ('10000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-00000000000a', 'Mercado A1 — Bloco 1', 'condominio', 'active'),
  ('10000000-0000-0000-0000-00000000000b', '00000000-0000-0000-0000-00000000000b', 'Mercado B1 — Recepção', 'escritorio', 'active')
on conflict (id) do nothing;

-- Uma 2ª location no Tenant A, usada especificamente pro Teste 6 (usuário
-- autorizado na Location A1 tentando acessar A2 sem permissão).
insert into public.locations (id, tenant_id, name, type, status) values
  ('10000000-0000-0000-0000-00000000000c', '00000000-0000-0000-0000-00000000000a', 'Mercado A2 — Bloco 2', 'condominio', 'active')
on conflict (id) do nothing;
