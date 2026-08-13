-- 0003_rls_policies.sql
-- RLS de todas as 4 tabelas desta fase, seguindo a matriz de
-- ARCHITECTURE_REVIEW_V2.md seção 2. SUPER_ADMIN nunca aparece como policy
-- permissiva — ele opera via service_role (Edge Function), que ignora RLS
-- por completo, por desenho do Postgres/Supabase.

-- =========================================================================
-- tenants
-- =========================================================================
alter table public.tenants enable row level security;

create policy tenants_select_own on public.tenants
  for select
  to authenticated
  using (id = public.jwt_tenant_id());

-- Sem policy de INSERT/UPDATE/DELETE pra `authenticated` — só service_role
-- escreve em tenants (SUPER_ADMIN via Edge Function). Isso não é uma
-- omissão, é a decisão: sem policy = negado por padrão no Postgres.

-- =========================================================================
-- locations
-- =========================================================================
alter table public.locations enable row level security;

create policy locations_select on public.locations
  for select
  to authenticated
  using (
    tenant_id = public.jwt_tenant_id()
    and (
      public.jwt_tenant_role() = 'tenant_admin'
      or public.user_has_location_access(id)
    )
  );

create policy locations_insert on public.locations
  for insert
  to authenticated
  with check (
    tenant_id = public.jwt_tenant_id()
    and public.jwt_tenant_role() = 'tenant_admin'
  );

create policy locations_update on public.locations
  for update
  to authenticated
  using (
    tenant_id = public.jwt_tenant_id()
    and public.jwt_tenant_role() = 'tenant_admin'
  )
  with check (
    tenant_id = public.jwt_tenant_id()
  );

-- Sem policy de DELETE — soft-delete via status (Baseline V3), nunca DELETE físico.
-- MANAGER editar só campos operacionais (ex: horário) fica pra quando esse
-- campo virar algo editável de verdade — RLS a nível de coluna é
-- desnecessário nesta fase, seria over-engineering pra um campo que ainda
-- não tem fluxo de edição nenhum.

-- =========================================================================
-- profiles
-- =========================================================================
alter table public.profiles enable row level security;

create policy profiles_select on public.profiles
  for select
  to authenticated
  using (
    id = auth.uid()
    or (tenant_id = public.jwt_tenant_id() and public.jwt_tenant_role() = 'tenant_admin')
  );

-- Sem policy de INSERT — profiles só nasce via trigger on_auth_user_created
-- (migration 0002), nunca por INSERT direto do cliente.

create policy profiles_update on public.profiles
  for update
  to authenticated
  using (
    id = auth.uid()
    or (tenant_id = public.jwt_tenant_id() and public.jwt_tenant_role() = 'tenant_admin')
  )
  with check (
    -- Impede a escalada do Cenário 4: qualquer linha nova gravada precisa
    -- continuar com o MESMO tenant_id da sessão atual — tentar gravar um
    -- tenant_id diferente viola este WITH CHECK e o UPDATE é rejeitado.
    tenant_id = public.jwt_tenant_id()
  );

-- Sem policy de DELETE — soft-delete via status.

-- =========================================================================
-- user_locations
-- =========================================================================
alter table public.user_locations enable row level security;

create policy user_locations_select on public.user_locations
  for select
  to authenticated
  using (
    user_id = auth.uid()
    or exists (
      select 1 from public.profiles p
      where p.id = user_locations.user_id
        and p.tenant_id = public.jwt_tenant_id()
        and public.jwt_tenant_role() = 'tenant_admin'
    )
  );

create policy user_locations_insert on public.user_locations
  for insert
  to authenticated
  with check (
    public.jwt_tenant_role() = 'tenant_admin'
    and exists (
      select 1 from public.locations l
      where l.id = location_id and l.tenant_id = public.jwt_tenant_id()
    )
    and exists (
      select 1 from public.profiles p
      where p.id = user_id and p.tenant_id = public.jwt_tenant_id()
    )
  );

create policy user_locations_update on public.user_locations
  for update
  to authenticated
  using (
    public.jwt_tenant_role() = 'tenant_admin'
    and exists (
      select 1 from public.locations l
      where l.id = location_id and l.tenant_id = public.jwt_tenant_id()
    )
  );

create policy user_locations_delete on public.user_locations
  for delete
  to authenticated
  using (
    public.jwt_tenant_role() = 'tenant_admin'
    and exists (
      select 1 from public.locations l
      where l.id = location_id and l.tenant_id = public.jwt_tenant_id()
    )
  );
