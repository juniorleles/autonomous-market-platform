/**
 * Cria os usuários de Auth de teste — não dá pra fazer isso só com SQL
 * (auth.users tem particularidade interna do GoTrue: hash de senha
 * específico, etc.), então usa a Admin API do supabase-js.
 *
 * tenant_id/platform_role/tenant_role vão em `user_metadata` — é isso que
 * o trigger `handle_new_user()` (migration 0002) lê pra criar a linha
 * certa em `public.profiles` automaticamente.
 *
 * Rodar 1x, depois de `supabase db reset` (que já aplica migrations + seed.sql):
 *   npx tsx tests/setup/seed-users.ts
 *
 * Requer SUPABASE_URL e SUPABASE_SERVICE_ROLE_KEY no ambiente (.env.test) —
 * a service_role key é necessária pra Admin API, nunca use ela no cliente.
 */
import { createClient } from '@supabase/supabase-js';
import 'dotenv/config';

const SUPABASE_URL = process.env.SUPABASE_URL || 'http://localhost:54321';
const SERVICE_ROLE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY;

if (!SERVICE_ROLE_KEY) {
  throw new Error('SUPABASE_SERVICE_ROLE_KEY é obrigatória pra criar usuário via Admin API.');
}

const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, {
  auth: { autoRefreshToken: false, persistSession: false },
});

const TENANT_A = '00000000-0000-0000-0000-00000000000a';
const TENANT_B = '00000000-0000-0000-0000-00000000000b';
const LOCATION_A1 = '10000000-0000-0000-0000-00000000000a';
const LOCATION_A2 = '10000000-0000-0000-0000-00000000000c';
const LOCATION_B1 = '10000000-0000-0000-0000-00000000000b';

// Senha fixa só porque é ambiente de teste local, nunca em produção.
const TEST_PASSWORD = 'TesteE2E-2026!';

// Cada entrada: email, metadata que o trigger handle_new_user() vai ler.
const USERS = [
  { email: 'super.admin@platform.test', metadata: { platform_role: 'super_admin', full_name: 'Super Admin' } },
  { email: 'tenant.admin.a@tenant-a.test', metadata: { tenant_id: TENANT_A, tenant_role: 'tenant_admin', full_name: 'Admin Tenant A' } },
  { email: 'manager.a1@tenant-a.test', metadata: { tenant_id: TENANT_A, tenant_role: 'manager', full_name: 'Manager A1' } },
  { email: 'operator.a1@tenant-a.test', metadata: { tenant_id: TENANT_A, tenant_role: 'operator', full_name: 'Operator A1' } },
  { email: 'tenant.admin.b@tenant-b.test', metadata: { tenant_id: TENANT_B, tenant_role: 'tenant_admin', full_name: 'Admin Tenant B' } },
];

// (email, location_id, role) — populam user_locations depois que os
// usuários (e portanto os profiles, via trigger) já existem.
const USER_LOCATIONS: Array<{ email: string; locationId: string; role: 'manager' | 'operator' }> = [
  { email: 'manager.a1@tenant-a.test', locationId: LOCATION_A1, role: 'manager' },
  { email: 'operator.a1@tenant-a.test', locationId: LOCATION_A1, role: 'operator' },
  // Deliberadamente SEM vincular manager.a1/operator.a1 à LOCATION_A2 —
  // é essa ausência que o Teste 6 (Cenário 5 da revisão) explora.
];

async function main() {
  const createdIds: Record<string, string> = {};

  for (const u of USERS) {
    const { data, error } = await admin.auth.admin.createUser({
      email: u.email,
      password: TEST_PASSWORD,
      email_confirm: true,
      user_metadata: u.metadata,
    });
    if (error) {
      // Idempotência simples: se já existe, segue em frente (não é erro fatal
      // pra rodar o seed 2x em dev).
      console.warn(`[seed-users] ${u.email}: ${error.message}`);
      continue;
    }
    createdIds[u.email] = data.user.id;
    console.log(`[seed-users] criado: ${u.email} (${data.user.id})`);
  }

  for (const ul of USER_LOCATIONS) {
    const userId = createdIds[ul.email];
    if (!userId) {
      console.warn(`[seed-users] pulei user_locations pra ${ul.email} — usuário não foi criado nesta execução.`);
      continue;
    }
    const { error } = await admin.from('user_locations').insert({
      user_id: userId,
      location_id: ul.locationId,
      role: ul.role,
      status: 'active',
    });
    if (error) console.warn(`[seed-users] user_locations pra ${ul.email}: ${error.message}`);
  }

  console.log('\n[seed-users] concluído. Senha de todos os usuários de teste: ' + TEST_PASSWORD);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
