# Roadmap de Fases — Mercados Autônomos

Documento vivo, e o ÚNICO que você precisa ler primeiro pra retomar o
projeto. Os outros documentos de arquitetura (`01_BLUEPRINT.md`,
`02_ARCHITECTURE_REVIEW_V2.md`, `03_ARCHITECTURE_BASELINE_V3.md`) são
referência de DECISÃO já tomada — não precisam ser relidos por completo
pra continuar, só consultados se surgir dúvida específica sobre o porquê
de algo.

---

## PARADO AQUI — leia isto primeiro ao retomar

**Estamos no meio da Fase 1** (não terminada, não travada — só pausada
num ponto conhecido e recuperável).

**Situação exata**: o Cursor rodou os testes pela 1ª vez de verdade e a
suíte inteira falhou no login, antes de qualquer teste de RLS rodar — 2
furos de `GRANT` de tabela (não de política de RLS), diagnosticados pelo
usuário com precisão. Eu escrevi a correção (`migration 0005`), mas
**essa correção nunca foi testada de verdade** — paramos antes do reteste.

**O próximo passo, exatamente, quando retomar**:
```
supabase migration up      # aplica só a 0005 (as 4 anteriores já rodaram)
npm test                    # roda a suíte inteira de novo
```
Ou, se preferir recomeçar do zero: `supabase db reset` (reaplica as 5
migrations + seed do início).

**O prompt completo pro Cursor** (mesmo texto de antes, cole de novo se
precisar): está registrado na conversa, mas o resumo é — rodar
`supabase migration up`, depois `npm test`, reportar resultado de cada um
dos 8 testes de isolamento + os testes de escalada (principalmente o de
`tenant_role`, que nunca chegou a rodar).

---

## Tabela de fases (visão geral)

| Fase | Escopo | Status |
|---|---|---|
| **1** | **Núcleo de Tenancy** (tenants, locations, profiles, user_locations, RLS, Auth Hook, testes de isolamento/escalada) | 🟡 **Em andamento — parado aguardando reteste da migration 0005** |
| 2 | Catálogo (categories, products, product_locations) | Não iniciada |
| 3 | Estoque (inventory, inventory_movements, trigger de saldo, lock de concorrência) | Não iniciada |
| 4 | Carrinho + Checkout (carts, cart_items, idempotência) | Não iniciada |
| 5 | Pagamento (payments, adapter, webhook, idempotência) | Não iniciada |
| 6 | Vendas completas (sales, sale_items, máquina de estado ponta a ponta) | Não iniciada |
| 7 | Acesso — só QR pro MVP1 (access_credentials, access_logs, /access/verify) | Não iniciada |
| 8 | Auditoria básica (audit_logs, infraestrutura mínima) | Não iniciada |
| 9 | Domain events (outbox + poller simples) | Não iniciada |

Cada fase só começa depois que a anterior estiver confirmada com execução
real. Ordem baseada no MVP1 do `03_ARCHITECTURE_BASELINE_V3.md`.

---

## Fase 1 — Status detalhado

**Escopo**: tabelas de fundação, Auth Hook, RLS, testes de isolamento (8
cenários) e escalada de privilégio.

**Arquivos já escritos** (todos em `supabase/migrations/`, `tests/`,
`docs/`):
- `0001_core_tenancy.sql` — tabelas
- `0002_auth_hook_and_helpers.sql` — JWT/tenant context
- `0003_rls_policies.sql` — RLS
- `0004_protect_profile_role_fields.sql` — corrige achado real (auto-escalada de `tenant_role`)
- `0005_fix_grants_and_hook_access.sql` — corrige achado real (GRANT de tabela faltando) — **NUNCA TESTADA**
- `seed.sql`, `tests/setup/seed-users.ts`, `tests/isolation.test.ts`, `tests/escalation.test.ts`

**2 achados reais até agora, ambos já corrigidos em código** (mas o 2º
ainda sem confirmação real):
1. Escrevendo o teste de escalada (antes de rodar): `tenant_role`/
   `platform_role` não protegidos contra auto-escalada — corrigido na
   migration `0004`.
2. Rodando de verdade pela primeira vez (achado pelo usuário, não por
   mim): `custom_access_token_hook` sem `GRANT SELECT` em `profiles`
   (login falhava com 500) + nenhuma das 4 tabelas com `GRANT` pra
   `authenticated`/`service_role` — corrigido na migration `0005`,
   **pendente de reteste**.

**Definição de "Fase 1 completa"**: os 8 testes de isolamento + os testes
de escalada passando de verdade, rodados pelo Cursor contra Supabase
local real — não antes disso.

---

## Ambiente necessário pra retomar

- Supabase CLI + Docker instalados (não estão disponíveis no ambiente onde
  este código foi gerado — a validação até aqui foi só estrutural: SQL com
  parênteses balanceados, TypeScript com sintaxe válida via Node nativo).
- `.env.test` preenchido a partir de `.env.example` (URL + chaves que
  `supabase status` mostra depois de `supabase start`).
