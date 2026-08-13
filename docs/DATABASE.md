# Banco de Dados — Núcleo de Tenancy

Documento de referência pra esta fase (só `tenants`/`locations`/`profiles`/
`user_locations` — nada de produto/estoque/venda ainda).

## Estrutura das tabelas

| Tabela | Relacionamento | Observação |
|---|---|---|
| `tenants` | raiz | sem `tenant_id` próprio — é a raiz de tudo |
| `locations` | `tenant_id → tenants.id` (CASCADE) | mercado físico de um tenant |
| `profiles` | `id = auth.users.id`, `tenant_id → tenants.id` (CASCADE, nulo só p/ SUPER_ADMIN) | extensão do Supabase Auth, equipe (não cliente) |
| `user_locations` | `user_id → profiles.id`, `location_id → locations.id` (ambos CASCADE) | quais locations um usuário de equipe acessa, com papel por location |

`ON DELETE CASCADE` em todas as FKs de propósito — se um tenant for
**realmente** apagado (purge de compliance, não o fluxo normal), tudo que
depende dele vai junto, em vez de deixar linha órfã. **Fluxo normal de
remoção é `status='inactive'`, nunca `DELETE`.**

## Estratégia de tenant

`tenant_id` nunca é confiado vindo do cliente — vai embutido no JWT via
**Custom Access Token Hook** (`custom_access_token_hook`, migration 0002),
que lê `profiles.tenant_id` no momento do login e grava como claim
assinado. Toda política de RLS lê esse claim (`public.jwt_tenant_id()`),
nunca um campo do payload da requisição.

## Estratégia de RLS

Cada tabela tem política explícita — ver `supabase/migrations/0003_rls_policies.sql`
com o comentário do motivo em cada uma. Resumo:

- **`tenants`**: usuário só vê a própria linha; **nenhuma** política de
  escrita pra `authenticated` — só `service_role` escreve (SUPER_ADMIN via
  Edge Function).
- **`locations`**: TENANT_ADMIN vê/edita tudo do tenant; MANAGER/OPERATOR só
  o que está em `user_locations`.
- **`profiles`**: própria linha + TENANT_ADMIN vê o tenant inteiro. Sem
  INSERT direto — só via trigger de signup.
- **`user_locations`**: só TENANT_ADMIN gerencia quem acessa o quê.

## Roles

5 papéis, sem tabela de permissão granular (decisão do Baseline V3):
`SUPER_ADMIN` (sem tenant, via `service_role`), `TENANT_ADMIN`, `MANAGER`,
`OPERATOR` (os 3 últimos com `tenant_role` em `profiles`, e MANAGER/OPERATOR
também em `user_locations` por location).

## Location access

Deliberadamente **fora do JWT** — consultado ao vivo, a cada requisição,
via `EXISTS` em `user_locations`. Revogar acesso de alguém vale na próxima
requisição, não depois do token expirar.

## Como rodar localmente

```bash
# 1. Subir o Supabase local (precisa do Supabase CLI + Docker instalados —
#    não disponíveis neste ambiente de geração, precisa do seu ambiente real)
supabase start

# 2. Aplicar migrations + seed.sql (supabase db reset já aplica os dois)
supabase db reset

# 3. Instalar dependências de teste
npm install

# 4. Copiar .env.example pra .env.test e preencher com o que `supabase status` mostrar
cp .env.example .env.test

# 5. Criar os usuários de Auth de teste (não dá pra fazer só com SQL)
npm run db:seed:users

# 6. Rodar os testes
npm test
```

## Como rodar só uma parte dos testes

```bash
npm run test:isolation    # os 8 testes de isolamento exigidos
npm run test:escalation   # tentativas de escalada de privilégio
```

## Achados reais do processo, corrigidos nesta fase

**1 — Escrevendo o teste de escalada** (antes de rodar): a política de
`profiles_update` (migration 0003) protegia `tenant_id` contra alteração,
mas **não** `tenant_role`/`platform_role` — um usuário editando a própria
linha poderia se auto-promover a `tenant_admin`. RLS (`USING`/`WITH CHECK`)
não compara `NEW` contra `OLD` de forma direta pra proteger coluna
específica — a correção certa é um trigger `BEFORE UPDATE`
(`protect_profile_role_fields`, migration 0004), que tem acesso explícito
aos dois. RLS continua controlando **quais linhas**; o trigger complementa
controlando **quais colunas** dentro de uma linha já autorizada.

**2 — Rodando de verdade pela primeira vez** (achado pelo usuário, não por
mim): a suíte inteira falhou no login, antes de qualquer teste de RLS
rodar. Causa: 2 furos de **GRANT de tabela** (camada diferente de RLS —
GRANT decide se a operação é sequer avaliada, RLS decide quais linhas
depois disso).
- `custom_access_token_hook` rodava como `supabase_auth_admin`, que nunca
  recebeu `GRANT SELECT` em `public.profiles` — login retornava 500
  ("permission denied for table profiles") antes de montar o JWT.
- Nenhuma das 4 tabelas tinha `GRANT` de tabela pra `authenticated`/
  `service_role` — sem isso, a política de RLS nem chega a ser avaliada.

Corrigido na migration `0005`, com granularidade mínima por tabela (não
`GRANT ALL` genérico) — batendo exatamente com o que cada policy de RLS já
permitia.
