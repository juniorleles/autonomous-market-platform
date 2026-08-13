/**
 * Testes de escalada de privilégio — provar que enviar tenant_id/user_id/
 * role/location_id manipulado no PAYLOAD da requisição não muda nada, porque
 * a autorização real vem do JWT (assinado pelo servidor), nunca do body.
 *
 * Rodar: npx vitest run tests/escalation.test.ts
 */
import { describe, it, expect, beforeAll } from 'vitest';
import { createClient, SupabaseClient } from '@supabase/supabase-js';
import 'dotenv/config';

const SUPABASE_URL = process.env.SUPABASE_URL || 'http://localhost:54321';
const ANON_KEY = process.env.SUPABASE_ANON_KEY!;
const TEST_PASSWORD = 'TesteE2E-2026!';

const TENANT_A = '00000000-0000-0000-0000-00000000000a';
const TENANT_B = '00000000-0000-0000-0000-00000000000b';
const LOCATION_A1 = '10000000-0000-0000-0000-00000000000a';

async function loginAs(email: string): Promise<SupabaseClient> {
  const client = createClient(SUPABASE_URL, ANON_KEY);
  const { error } = await client.auth.signInWithPassword({ email, password: TEST_PASSWORD });
  if (error) throw new Error(`Login falhou pra ${email}: ${error.message}`);
  return client;
}

describe('Tentativas de escalada de privilégio', () => {
  let operatorA1: SupabaseClient;
  let managerA1: SupabaseClient;

  beforeAll(async () => {
    operatorA1 = await loginAs('operator.a1@tenant-a.test');
    managerA1 = await loginAs('manager.a1@tenant-a.test');
  });

  it('OPERATOR não consegue criar location mandando tenant_id de outro tenant no payload', async () => {
    const { error } = await operatorA1.from('locations').insert({
      tenant_id: TENANT_B, // manipulado, tentando escapar do próprio tenant
      name: 'Location via escalada',
      type: 'outro',
    });
    expect(error).not.toBeNull();
  });

  it('OPERATOR não consegue criar location nem dentro do PRÓPRIO tenant (role errado pra essa ação)', async () => {
    const { error } = await operatorA1.from('locations').insert({
      tenant_id: TENANT_A,
      name: 'Location por operador',
      type: 'outro',
    });
    // A policy de INSERT exige tenant_role = 'tenant_admin' — operator não passa,
    // mesmo com tenant_id correto.
    expect(error).not.toBeNull();
  });

  it('MANAGER não consegue se auto-conceder acesso a uma location nova via user_locations', async () => {
    const { data: userData } = await managerA1.auth.getUser();
    const { error } = await managerA1.from('user_locations').insert({
      user_id: userData.user!.id,
      location_id: LOCATION_A1,
      role: 'manager',
    });
    // Policy de INSERT em user_locations exige tenant_role = 'tenant_admin' —
    // MANAGER não pode se autoconceder nem readicionar a si mesmo.
    expect(error).not.toBeNull();
  });

  it('Usuário não consegue elevar o próprio tenant_role mandando "tenant_admin" no payload de UPDATE', async () => {
    const { data: userData } = await operatorA1.auth.getUser();
    const { error } = await operatorA1
      .from('profiles')
      .update({ tenant_role: 'tenant_admin' })
      .eq('id', userData.user!.id)
      .select();
    // Bug real encontrado escrevendo este teste, corrigido na migration
    // 0004 (trigger protect_profile_role_fields) — antes da correção, isso
    // passava sem erro. Agora o trigger BEFORE UPDATE lança exceção.
    expect(error).not.toBeNull();
  });

  it('Requisição sem token (anon) não enxerga nenhuma location de nenhum tenant', async () => {
    const anon = createClient(SUPABASE_URL, ANON_KEY);
    const { data, error } = await anon.from('locations').select('*');
    expect(error).toBeNull();
    expect(data).toHaveLength(0);
  });
});
