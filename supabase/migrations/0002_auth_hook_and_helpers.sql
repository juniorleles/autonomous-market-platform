-- 0002_auth_hook_and_helpers.sql
-- Mecanismo de tenant context (Baseline V3, seção 4): tenant_id/platform_role/
-- tenant_role vão embutidos no JWT via Custom Access Token Hook do Supabase —
-- nunca lidos de um campo que o cliente possa manipular.

-- =========================================================================
-- Trigger: cria a linha em public.profiles quando um usuário se cadastra no
-- Supabase Auth. tenant_id/tenant_role/full_name vêm de raw_user_meta_data
-- (passado no momento do signup) — SEED usa isso pra criar os usuários de
-- teste; um fluxo real de convite faria o mesmo.
-- SECURITY DEFINER porque o INSERT em auth.users é feito pelo serviço de
-- Auth, não pelo usuário final — o trigger precisa de privilégio elevado
-- pra gravar em public.profiles nesse momento.
-- =========================================================================
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.profiles (id, tenant_id, full_name, email, platform_role, tenant_role)
  values (
    new.id,
    nullif(new.raw_user_meta_data ->> 'tenant_id', '')::uuid,
    new.raw_user_meta_data ->> 'full_name',
    new.email,
    nullif(new.raw_user_meta_data ->> 'platform_role', ''),
    nullif(new.raw_user_meta_data ->> 'tenant_role', '')
  );
  return new;
end;
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

comment on function public.handle_new_user() is
  'profiles NUNCA nasce de INSERT direto do cliente — só via este trigger, '
  'disparado pelo próprio signup do Supabase Auth.';

-- =========================================================================
-- Custom Access Token Hook — registrado em supabase/config.toml
-- (ver [auth.hook.custom_access_token] na seção de configuração do projeto,
-- não é algo que a migration sozinha ativa).
--
-- Contrato exigido pelo Supabase: recebe {user_id, claims}, devolve o mesmo
-- formato com "claims" ajustado. Só pode ser chamado pelo papel interno
-- supabase_auth_admin — revogado explicitamente de authenticated/anon/public
-- pra não virar uma porta de escrita de claim arbitrária.
-- =========================================================================
create or replace function public.custom_access_token_hook(event jsonb)
returns jsonb
language plpgsql
stable
as $$
declare
  claims jsonb;
  target_user_id uuid;
  profile_row public.profiles%rowtype;
begin
  target_user_id := (event ->> 'user_id')::uuid;
  claims := event -> 'claims';

  select * into profile_row from public.profiles where id = target_user_id;

  if found then
    if profile_row.tenant_id is not null then
      claims := jsonb_set(claims, '{tenant_id}', to_jsonb(profile_row.tenant_id::text));
    end if;
    if profile_row.platform_role is not null then
      claims := jsonb_set(claims, '{platform_role}', to_jsonb(profile_row.platform_role));
    end if;
    if profile_row.tenant_role is not null then
      claims := jsonb_set(claims, '{tenant_role}', to_jsonb(profile_row.tenant_role));
    end if;
  end if;
  -- Não achou em profiles: usuário pode ser um CUSTOMER (tabela fora de
  -- escopo desta fase) — nesse caso o JWT simplesmente não ganha esses
  -- claims. Retomar este hook quando `customers` for implementado.

  event := jsonb_set(event, '{claims}', claims);
  return event;
end;
$$;

grant execute on function public.custom_access_token_hook to supabase_auth_admin;
revoke execute on function public.custom_access_token_hook from authenticated, anon, public;

comment on function public.custom_access_token_hook is
  'Registrar em supabase/config.toml: [auth.hook.custom_access_token] '
  'enabled = true, uri = "pg-functions://postgres/public/custom_access_token_hook". '
  'Sem esse registro no config, a função existe no banco mas o Auth nunca a chama.';

-- =========================================================================
-- Helpers de leitura de claim — usados dentro das políticas de RLS
-- (migration 0003), pra não repetir `auth.jwt() ->> '...'` em toda policy.
-- =========================================================================
create or replace function public.jwt_tenant_id()
returns uuid
language sql
stable
as $$
  select nullif(auth.jwt() ->> 'tenant_id', '')::uuid
$$;

create or replace function public.jwt_platform_role()
returns text
language sql
stable
as $$
  select auth.jwt() ->> 'platform_role'
$$;

create or replace function public.jwt_tenant_role()
returns text
language sql
stable
as $$
  select auth.jwt() ->> 'tenant_role'
$$;

-- =========================================================================
-- Helper de autorização por location — resolve o Cenário 5 da revisão
-- (usuário autorizado na Location A não pode, por tabela de tenant sozinha,
-- acessar a Location B do mesmo tenant sem estar em user_locations).
-- =========================================================================
create or replace function public.user_has_location_access(loc_id uuid)
returns boolean
language sql
stable
as $$
  select exists (
    select 1
    from public.user_locations ul
    where ul.user_id = auth.uid()
      and ul.location_id = loc_id
      and ul.status = 'active'
  )
$$;
