-- 0001_core_tenancy.sql
-- Fundação de multi-tenancy — Architecture Baseline V3.
-- Escopo desta migration: SOMENTE tenants, locations, profiles, user_locations.
-- Nada de produtos/estoque/vendas/pagamentos — fora de escopo desta fase.

create extension if not exists pgcrypto;

-- Função utilitária reaproveitada em toda tabela com updated_at.
create or replace function public.set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

-- =========================================================================
-- tenants — a raiz. Não tem tenant_id (é a própria raiz).
-- =========================================================================
create table public.tenants (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  slug text not null unique,
  plan text not null default 'starter',
  status text not null default 'trial' check (status in ('trial', 'active', 'suspended')),
  billing_email text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create trigger trg_tenants_updated_at
  before update on public.tenants
  for each row execute function public.set_updated_at();

comment on table public.tenants is
  'Empresa/operação dentro da plataforma. Nunca DELETE físico — soft-delete via status.';

-- =========================================================================
-- locations — unidade física/mercado de um tenant.
-- =========================================================================
create table public.locations (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete cascade on update cascade,
  name text not null,
  type text not null check (type in ('condominio', 'escritorio', 'academia', 'hotel', 'outro')),
  address text,
  timezone text not null default 'America/Sao_Paulo',
  opening_hours jsonb,
  status text not null default 'active' check (status in ('active', 'inactive')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index idx_locations_tenant on public.locations(tenant_id, status);

create trigger trg_locations_updated_at
  before update on public.locations
  for each row execute function public.set_updated_at();

comment on table public.locations is
  'Mercado físico pertencente a um tenant. FK CASCADE — se o tenant for '
  'de fato apagado (purge de compliance, não fluxo normal), as locations '
  'vão junto. Fluxo normal de "remoção" é status=inactive, nunca DELETE.';

-- =========================================================================
-- profiles — extensão de auth.users, 1:1. Equipe (não cliente).
-- Campo tenant_id nulo SÓ pra SUPER_ADMIN — reforçado pela constraint abaixo.
-- =========================================================================
create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  tenant_id uuid references public.tenants(id) on delete cascade on update cascade,
  full_name text,
  email text,
  phone text,
  platform_role text check (platform_role in ('super_admin')),
  tenant_role text check (tenant_role in ('tenant_admin', 'manager', 'operator')),
  status text not null default 'active' check (status in ('active', 'inactive')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint profiles_role_consistency check (
    (platform_role = 'super_admin' and tenant_id is null and tenant_role is null)
    or
    (platform_role is null and tenant_id is not null and tenant_role is not null)
  )
);

create index idx_profiles_tenant on public.profiles(tenant_id);

create trigger trg_profiles_updated_at
  before update on public.profiles
  for each row execute function public.set_updated_at();

comment on table public.profiles is
  'Perfil de EQUIPE (super_admin/tenant_admin/manager/operator) — cliente '
  'final vive numa tabela separada (customers), fora de escopo desta fase. '
  'A constraint profiles_role_consistency impede o estado inválido de '
  '"super_admin com tenant_id preenchido" ou "staff de tenant sem tenant_id".';

-- =========================================================================
-- user_locations — quais locations um usuário de equipe pode acessar.
-- =========================================================================
create table public.user_locations (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  location_id uuid not null references public.locations(id) on delete cascade,
  role text not null check (role in ('manager', 'operator')),
  status text not null default 'active' check (status in ('active', 'inactive')),
  created_at timestamptz not null default now(),
  unique (user_id, location_id)
);

create index idx_user_locations_user on public.user_locations(user_id, status);
create index idx_user_locations_location on public.user_locations(location_id, status);

comment on table public.user_locations is
  'Papel de MANAGER/OPERATOR é POR LOCATION, não fixo no usuário — '
  'resolve "1 gerente cuidando de 2 mercados" sem duplicar usuário.';
