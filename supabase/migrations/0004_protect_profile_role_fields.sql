-- 0004_protect_profile_role_fields.sql
-- Achado real, escrito ESCREVENDO o teste de escalada de privilégio
-- (tests/escalation.test.ts): a policy `profiles_update` (migration 0003)
-- protege `tenant_id` no WITH CHECK, mas não protege `tenant_role` nem
-- `platform_role`. Um usuário editando a PRÓPRIA linha (permitido, já que
-- `id = auth.uid()` sempre passa) poderia incluir `tenant_role: 'tenant_admin'`
-- no mesmo payload de UPDATE e a policy deixaria passar — escalada de
-- privilégio real, não hipotética.
--
-- RLS (USING/WITH CHECK) não compara NEW contra OLD de forma direta — o
-- jeito confiável de proteger COLUNA específica contra mudança não
-- autorizada é um trigger BEFORE UPDATE, que tem acesso explícito a OLD e
-- NEW. RLS continua controlando QUAIS linhas são visíveis/editáveis; este
-- trigger complementa controlando QUAIS COLUNAS podem mudar dentro de uma
-- linha já autorizada.

create or replace function public.protect_profile_role_fields()
returns trigger
language plpgsql
as $$
begin
  -- service_role (Edge Function de SUPER_ADMIN) bypassa RLS por completo —
  -- aqui não restringimos, é o caminho legítimo de administração da plataforma.
  if auth.role() = 'service_role' then
    return new;
  end if;

  -- TENANT_ADMIN do mesmo tenant da linha sendo editada pode alterar o
  -- papel de outros usuários — essa é a única exceção pra sessão comum.
  if public.jwt_tenant_role() = 'tenant_admin' and old.tenant_id = public.jwt_tenant_id() then
    return new;
  end if;

  -- Qualquer outro caso (incluindo o próprio usuário editando a própria
  -- linha): tenant_id, tenant_role e platform_role não podem mudar.
  if new.tenant_id is distinct from old.tenant_id
     or new.tenant_role is distinct from old.tenant_role
     or new.platform_role is distinct from old.platform_role then
    raise exception
      'Não é permitido alterar tenant_id/tenant_role/platform_role sem ser tenant_admin do próprio tenant.';
  end if;

  return new;
end;
$$;

create trigger trg_protect_profile_role_fields
  before update on public.profiles
  for each row execute function public.protect_profile_role_fields();

comment on function public.protect_profile_role_fields() is
  'Fecha a lacuna que o teste de escalada de privilégio encontrou '
  '(tests/escalation.test.ts) — RLS sozinho não protege coluna específica '
  'contra mudança dentro de uma linha já autorizada, precisa de trigger.';
