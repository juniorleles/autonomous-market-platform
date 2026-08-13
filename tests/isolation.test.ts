/**
 * Testes de isolamento — os 8 cenários exigidos na implementação.
 * Cada teste faz LOGIN de verdade (via supabase-js, senha real) como o
 * usuário certo, pra passar pelo Custom Access Token Hook de propósito —
 * isso testa o caminho completo (Auth Hook + RLS juntos), não uma
 * simulação de claim isolada.
 *
 * Requer: Supabase local rodando (`supabase start`), migrations aplicadas,
 * seed.sql aplicado, e `tests/setup/seed-users.ts` já rodado 1x.
 *
 * Rodar: npx vitest run tests/isolation.test.ts
 */
import { describe, it, expect, beforeAll } from 'vitest';
import { createClient, SupabaseClient } from '@supabase/supabase-js';
import 'dotenv/config';

const SUPABASE_URL = process.env.SUPABASE_URL || 'http://localhost:54321';
const ANON_KEY = process.env.SUPABASE_ANON_KEY!;
const SERVICE_ROLE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY!;
const TEST_PASSWORD = 'TesteE2E-2026!';

const TENANT_A = '00000000-0000-0000-0000-00000000000a';
const TENANT_B = '00000000-0000-0000-0000-00000000000b';
const LOCATION_A1 = '10000000-0000-0000-0000-00000000000a';
const LOCATION_A2 = '10000000-0000-0000-0000-00000000000c';

async function loginAs(email: string): Promise<SupabaseClient> {
  const client = createClient(SUPABASE_URL, ANON_KEY);
  const { error } = await client.auth.signInWithPassword({ email, password: TEST_PASSWORD });
  if (error) throw new Error(`Login falhou pra ${email}: ${error.message}`);
  return client;
}

function serviceRoleClient(): SupabaseClient {
  return createClient(SUPABASE_URL, SERVICE_ROLE_KEY, {
    auth: { autoRefreshToken: false, persistSession: false },
  });
}

describe('Isolamento entre tenants e locations', () => {
  let tenantAdminA: SupabaseClient;
  let tenantAdminB: SupabaseClient;
  let managerA1: SupabaseClient;
  let admin: SupabaseClient;

  beforeAll(async () => {
    tenantAdminA = await loginAs('tenant.admin.a@tenant-a.test');
    tenantAdminB = await loginAs('tenant.admin.b@tenant-b.test');
    managerA1 = await loginAs('manager.a1@tenant-a.test');
    admin = serviceRoleClient();
  });

  it('Teste 1 — Tenant A consulta locations do Tenant B: DENIED (0 linhas, sem erro)', async () => {
    const { data, error } = await tenantAdminA.from('locations').select('*').eq('tenant_id', TENANT_B);
    expect(error).toBeNull();
    expect(data).toHaveLength(0);
  });

  it('Teste 2 — Tenant A tenta INSERT location com tenant_id do Tenant B: DENIED', async () => {
    const { error } = await tenantAdminA.from('locations').insert({
      tenant_id: TENANT_B,
      name: 'Location Forjada',
      type: 'outro',
    });
    expect(error).not.toBeNull(); // rejeitado pelo WITH CHECK da policy de INSERT
  });

  it('Teste 3 — Tenant A tenta UPDATE location do Tenant B: DENIED (0 linhas afetadas)', async () => {
    // Pega o id real de uma location do Tenant B via service_role, só pra
    // ter um alvo válido de tentar atualizar.
    const { data: locB } = await admin.from('locations').select('id').eq('tenant_id', TENANT_B).limit(1).single();
    const { data, error } = await tenantAdminA
      .from('locations')
      .update({ name: 'Nome Alterado Por Invasor' })
      .eq('id', locB!.id)
      .select();
    expect(error).toBeNull();
    expect(data).toHaveLength(0); // RLS trata como se a linha não existisse
  });

  it('Teste 4 — Tenant A tenta DELETE em tabela sem policy de DELETE: DENIED', async () => {
    const { data: locB } = await admin.from('locations').select('id').eq('tenant_id', TENANT_B).limit(1).single();
    const { error } = await tenantAdminA.from('locations').delete().eq('id', locB!.id);
    // Sem policy de DELETE pra locations — Postgres nega por padrão.
    expect(error).not.toBeNull();
  });

  it('Teste 5 — Usuário tenta alterar o próprio tenant_id: DENIED', async () => {
    const { data: userData } = await tenantAdminA.auth.getUser();
    const { data, error } = await tenantAdminA
      .from('profiles')
      .update({ tenant_id: TENANT_B })
      .eq('id', userData.user!.id)
      .select();
    expect(error).not.toBeNull(); // rejeitado pelo WITH CHECK (tenant_id = jwt_tenant_id())
    expect(data ?? []).toHaveLength(0);
  });

  it('Teste 6 — Usuário autorizado na Location A1 tenta acessar Location A2 (mesmo tenant): DENIED', async () => {
    const { data, error } = await managerA1.from('locations').select('*').eq('id', LOCATION_A2);
    expect(error).toBeNull();
    expect(data).toHaveLength(0); // A2 existe, é do mesmo tenant, mas managerA1 não tem user_locations pra ela
  });

  it('Teste 7 — Tenant Admin acessa seus próprios dados: ALLOWED', async () => {
    const { data, error } = await tenantAdminA.from('locations').select('*').eq('tenant_id', TENANT_A);
    expect(error).toBeNull();
    expect(data!.length).toBeGreaterThan(0);
  });

  it('Teste 8 — SUPER_ADMIN acessa dados de tenants diferentes: ALLOWED (via service_role, não sessão RLS comum)', async () => {
    // Achado de desenho, documentado: SUPER_ADMIN autenticado com sessão
    // normal NÃO enxerga nada além do próprio (tenant_id nulo nunca bate
    // com nenhuma policy de tenant_id = jwt_tenant_id()) — isso é
    // INTENCIONAL (Baseline V3: SUPER_ADMIN sempre via service_role /
    // Edge Function, nunca policy de RLS permissiva). O teste real do
    // "SUPER_ADMIN vê tudo" é sobre o client de service_role, não sobre
    // logar como o usuário super_admin.
    const { data, error } = await admin.from('locations').select('*');
    expect(error).toBeNull();
    const tenantIds = new Set(data!.map((l: any) => l.tenant_id));
    expect(tenantIds.has(TENANT_A)).toBe(true);
    expect(tenantIds.has(TENANT_B)).toBe(true);
  });

  it('Teste 8b — SUPER_ADMIN com sessão RLS comum NÃO vê nada de tenant nenhum (documenta a decisão acima)', async () => {
    const superAdmin = await loginAs('super.admin@platform.test');
    const { data, error } = await superAdmin.from('locations').select('*');
    expect(error).toBeNull();
    expect(data).toHaveLength(0); // confirma a decisão arquitetural, não é bug
  });
});
