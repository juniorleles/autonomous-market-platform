# Architecture Review — Fase 2

Revisão técnica em cima do `BLUEPRINT.md` já produzido — sem código, sem
migration, sem alteração de banco, sem tela. Onde uma decisão do blueprint
original muda ou fica mais específica aqui, eu sinalizo explicitamente.

---

## 1. Revisão das Decisões Principais

| Decisão | Classificação | Motivo |
|---|---|---|
| Multi-tenancy banco compartilhado | **APROVADA COM RESSALVAS** | Custo-certa pro perfil de tenant, mas 1 política de RLS esquecida é vazamento total — risco real, não hipotético |
| `tenant_id` em toda tabela | **APROVADA** | Padrão direto, sem ressalva |
| Row Level Security | **APROVADA COM RESSALVAS** | Mecanismo certo, mas é ponto único de falha — precisa de disciplina de teste, não confiança |
| RBAC por papel fixo (sem tabela de permissão) | **APROVADA** | Suficiente pro volume e maturidade do MVP; revisitar só se cliente real pedir granularidade |
| `inventory` + `inventory_movements` | **APROVADA** | Padrão de ledger é o desenho correto pra auditabilidade — sem ressalva na separação em si |
| Monólito modular | **APROVADA** | Certo pro volume descrito |
| Supabase/PostgreSQL | **APROVADA** | RLS nativo do Postgres é o encaixe certo pra essa estratégia |
| Eventos (`domain_events`, outbox leve) | **APROVADA COM RESSALVAS** | O blueprint definiu O QUE persiste, mas não definiu QUEM processa — falta um worker/poller ou assinatura Realtime explícita. Sem isso, `domain_events` vira uma tabela que só cresce, nunca é lida. **Isso precisa ser decidido antes da migration** (ver Blocker) |
| Pagamentos desacoplados (adapter) | **APROVADA** | Sem ressalva na decisão em si — os detalhes de idempotência/concorrência são o foco desta revisão (seções 5, 7, 8) |
| Controle de acesso desacoplado | **APROVADA** | Contrato único continua certo |

---

## 2. Matriz Conceitual de RLS — todas as entidades

`SUPER_ADMIN` nunca aparece como política de RLS permissiva em nenhuma
tabela — ele opera **fora do RLS**, via Edge Function com `service_role`,
sempre. Isso está marcado como "fora do RLS" na coluna, não como um SELECT
liberado.

| Tabela | `tenant_id`? | RLS? | SELECT | INSERT | UPDATE | DELETE |
|---|---|---|---|---|---|---|
| `tenants` | não (é a raiz) | sim | própria linha (tenant do JWT) · SUPER_ADMIN fora do RLS | só SUPER_ADMIN, fora do RLS | só SUPER_ADMIN, fora do RLS | nunca (soft via `status`) |
| `locations` | sim | sim | TENANT_ADMIN vê todas do tenant · MANAGER/OPERATOR/CUSTOMER só as vinculadas (via `user_locations`/`customer_locations`) | TENANT_ADMIN | TENANT_ADMIN (tudo) · MANAGER (só campos operacionais, ex: horário) | nunca (`status=inactive`) |
| `profiles` | sim (nulo só p/ SUPER_ADMIN) | sim | própria linha · TENANT_ADMIN vê todas do tenant | via trigger de signup, não INSERT direto do cliente | própria linha (campos não-sensíveis) · TENANT_ADMIN (papel/status) — **nunca o próprio `tenant_id`**, ver Cenário 4 | nunca (`status=inactive`) |
| `user_locations` | sim (via profile) | sim | TENANT_ADMIN do tenant · próprio usuário (suas linhas) | TENANT_ADMIN | TENANT_ADMIN | TENANT_ADMIN |
| `customers` | sim | sim | própria linha (se `auth_user_id` setado) · equipe do tenant/location | equipe do tenant, ou self-signup do cliente | própria linha (dados básicos) · equipe | TENANT_ADMIN (soft) |
| `customer_locations` | sim | sim | equipe do tenant · próprio cliente | equipe do tenant | equipe do tenant | equipe do tenant |
| `categories` | sim | sim | equipe + cliente (leitura de catálogo) | TENANT_ADMIN/MANAGER | TENANT_ADMIN/MANAGER | TENANT_ADMIN |
| `products` | sim | sim | equipe + cliente (leitura) | TENANT_ADMIN/MANAGER | TENANT_ADMIN/MANAGER | nunca (`status=discontinued`) |
| `product_barcodes` | sim (via product) | sim | equipe do tenant | TENANT_ADMIN/MANAGER | TENANT_ADMIN/MANAGER | TENANT_ADMIN |
| `inventory` | sim | sim | equipe da location + TENANT_ADMIN · **cliente nunca vê saldo bruto**, só "disponível" derivado na camada de produto | **nunca direto** | **nunca direto** — só trigger a partir de `inventory_movements` (ver seção 4) | nunca |
| `inventory_movements` | sim | sim | equipe da location + TENANT_ADMIN | OPERATOR/MANAGER (manual) + sistema (venda/cancelamento) | nunca (append-only) | nunca |
| `carts` | sim | sim | próprio cliente · equipe da location (leitura/suporte) | próprio cliente | próprio cliente, só enquanto `status=open` | próprio cliente (esvaziar) |
| `cart_items` | sim (via cart) | sim | dono do carrinho + equipe da location | dono do carrinho | dono do carrinho, só enquanto cart `open` | dono do carrinho |
| `sales` | sim | sim | próprio cliente (suas vendas) + equipe | sistema, via checkout — nunca INSERT manual do cliente | equipe (só campos administrativos, ex: cancelamento) | nunca (só `status=cancelled`) |
| `sale_items` | sim (via sale) | sim | mesmo dono de `sales` | sistema, junto com `sales` | nunca (imutável) | nunca |
| `payments` | sim | sim | próprio cliente (status do seu pagamento) + equipe | sistema (checkout) | webhook/sistema via `service_role` — **nunca usuário comum** | nunca |
| `access_credentials` | sim | sim | próprio dono + equipe do tenant | equipe do tenant (emissão) | equipe (revogação) — **nunca o próprio dono** | nunca (revogar = `status`) |
| `access_logs` | sim | sim | equipe do tenant/location · cliente vê só seus próprios | sistema, via `/access/verify` (`service_role`) | nunca (append-only) | nunca |
| `audit_logs` | sim | sim | TENANT_ADMIN (leitura) | sistema, nunca manual | nunca (append-only) | nunca |
| `notifications` | sim | sim | destinatário + TENANT_ADMIN | sistema | sistema (`sent`/`failed`) | nunca |
| `integrations` | sim | sim | TENANT_ADMIN | TENANT_ADMIN | TENANT_ADMIN | TENANT_ADMIN |
| `domain_events` | sim (nulo p/ eventos de plataforma) | sim | worker interno (`service_role`) · TENANT_ADMIN pode ver eventos do próprio tenant (opcional, debug) | sistema (trigger na mudança de estado) | sistema (`processed_at`) | nunca |

**Usuário sem tenant**: só existe pra `SUPER_ADMIN` — e por isso ele nunca
usa uma sessão RLS comum, sempre `service_role` server-side.

**Usuário vinculado a múltiplas locations**: toda tabela com `location_id`
precisa de **2 condições na política**, não 1: `tenant_id` bate **E**
existe linha em `user_locations` pra aquele `location_id` com `status=active`.
Esquecer a segunda condição é o erro mais fácil de cometer aqui — deixa
`tenant_id` sozinho bastando, e qualquer um do tenant vê todas as locations,
não só as suas.

---

## 3. Cenários de Isolamento

**Cenário 1 — Tenant A consulta produtos do Tenant B**: a política de
SELECT filtra `tenant_id`. Resultado: **0 linhas, sem erro**. Nunca
diferenciar "não encontrado" de "não autorizado" na mensagem — isso
vazaria a existência do dado de outro tenant.

**Cenário 2 — Tenant A tenta criar produto com `tenant_id` do Tenant B**:
2 camadas de defesa. (a) A aplicação/Edge Function **ignora** qualquer
`tenant_id` vindo do payload do cliente — sempre injeta o valor do JWT
server-side, nunca confia no que foi enviado. (b) Mesmo se a camada (a)
tiver bug, a política de INSERT tem `WITH CHECK (tenant_id = JWT claim)` —
o INSERT falha no banco, não só na aplicação.

**Cenário 3 — Tenant A tenta alterar venda do Tenant B**: a política de
UPDATE usa `USING (tenant_id = JWT claim)`. Pro usuário, a linha
**simplesmente não existe** — o UPDATE afeta 0 linhas, sem exceção. A
aplicação precisa checar `rowCount === 0` e tratar como "não encontrado",
nunca como erro de permissão explícito (mesmo motivo do Cenário 1: não
vazar existência).

**Cenário 4 — Usuário tenta alterar o próprio `tenant_id`**: bloqueado em
2 pontos. `profiles.tenant_id` só é setado 1 vez, no Auth Hook de criação
de conta — a aplicação nunca aceita esse campo num PATCH de perfil,
independente do valor. Como defesa adicional, a política de UPDATE tem
`WITH CHECK (tenant_id = JWT claim)`, que rejeitaria qualquer tentativa de
gravar um valor diferente do que já está na sessão.

**Cenário 5 — Usuário autorizado na Location A tenta acessar Location B do
mesmo tenant, sem permissão**: **não é problema de `tenant_id`** (as duas
locations são do mesmo tenant) — é autorização de location, resolvida pela
segunda condição da política (`EXISTS` em `user_locations`) descrita na
seção 2. Esse é o cenário que mais frequentemente é esquecido numa
implementação apressada — vale um teste automatizado dedicado só pra ele,
separado do teste de vazamento entre tenants.

**Cenário 6 — SUPER_ADMIN precisa consultar toda a plataforma**: nunca via
política de RLS "permissiva pra esse papel" — sempre via Edge Function com
`service_role`, que bypassa RLS por completo. Essa função tem sua própria
checagem de autorização (`platform_role = super_admin` no JWT) **antes**
de rodar qualquer query cross-tenant, e **toda consulta cross-tenant desse
tipo deveria gerar 1 linha em `audit_logs`** — acessar dado de vários
tenants de uma vez é, em si, uma ação sensível o suficiente pra auditar.

---

## 4. Estoque

- **`inventory`** = saldo atual (leitura rápida, denormalizado).
- **`inventory_movements`** = histórico completo, append-only, fonte da
  verdade.
- **Quem altera o saldo**: **ninguém, diretamente**. `inventory.quantity_on_hand`
  só muda via **trigger de banco** disparado por `INSERT` em
  `inventory_movements` — a aplicação nunca faz `UPDATE inventory SET
  quantity_on_hand = ...` em lugar nenhum do sistema. Isso garante saldo
  sempre igual à soma dos movimentos, sem possibilidade de deriva.
- **Operações que geram movimento**: venda (delta negativo), cancelamento
  (delta positivo, referenciando a venda original), entrada/saída manual,
  ajuste, perda, vencido, inventário (contagem gera 1 movimento de ajuste
  igual à diferença entre contado e registrado).
- **Cancelamento**: cria um **novo** movimento positivo referenciando a
  venda original (`reference_type='sale'`, `reference_id=sale.id`) — nunca
  edita ou apaga o movimento de venda original. O rastro mostra os dois:
  a saída e a reversão.
- **Estorno**: decisão que precisa ficar **explícita no fluxo**, não
  assumida — estorno financeiro nem sempre significa devolução física do
  produto (ex: reembolso por cortesia). Recomendo: tela/ação de estorno
  sempre pergunta "produto retornado ao estoque? sim/não" — só gera
  movimento de estoque se sim.
- **Evitar saldo negativo**: não é uma `CHECK constraint` simples (isso não
  resolve concorrência) — é validado **dentro da mesma transação** que cria
  a venda: `quantity_on_hand - quantity_reserved >= quantidade_pedida`,
  checado com o lock de linha descrito abaixo.
- **Concorrência**: `SELECT ... FOR UPDATE` na linha específica de
  `inventory` (por `location_id` + `product_id`) — dentro da MESMA
  transação que cria a venda, o item de venda, e o movimento de estoque.
  Isso serializa tentativas concorrentes pro mesmo produto/location:
  quem pega o lock primeiro processa; o segundo, se não sobrar estoque,
  falha com "estoque insuficiente" — nunca os dois processam a mesma
  unidade.
- **Como impedir 2 vendas simultâneas consumirem o mesmo estoque**: é
  exatamente o mecanismo acima — checagem e decremento **na mesma
  transação atômica**, nunca "checa disponibilidade" e "cria venda" como 2
  passos separados (isso é uma race condition clássica, conhecida como
  TOCTOU — time-of-check to time-of-use).

---

## 5. Pagamentos

### Ordem de nascimento das entidades

```
Customer (já existe, cadastro prévio ou criado na primeira compra)
  → Cart (criado ao começar a comprar, status=open)
  → Checkout (transição: cart.status → checked_out)
      → nasce Payment (status=pending) NESTE momento
      → nasce Sale (status=pending) TAMBÉM neste momento — recomendado,
        não obrigatório (ver nota abaixo)
  → [gateway processa, webhook chega]
  → Payment: pending → approved (idempotente, ver seção 8)
  → SÓ AQUI: Sale → completed + Sale Items criados (snapshot do cart) +
    Inventory Movement criado (venda, decrementa estoque) — tudo em 1
    transação só
  → Payment: pending → declined → Sale nunca chega a completed (fica
    cancelled, ou nunca existiu, dependendo da escolha abaixo)
```

**Nota importante, que muda uma sutileza do blueprint original**: existem
2 desenhos defensáveis pra quando a `sale` nasce — no checkout (status
`pending`, dá rastro até de compra que falhou) ou só na aprovação do
pagamento (mais simples, mas perde o rastro de tentativa). **Isso é um
blocker** (seção 10) — precisa ser decidido antes da migration, porque
muda se `sales.payment_id` é `NOT NULL` ou não. O que **não é opcional**,
qualquer que seja a escolha: **a baixa de estoque só acontece na transição
pra `approved`/`completed`, nunca antes.**

### Webhook duplicado
`(provider, provider_transaction_id)` UNIQUE em `payments` — o handler faz
UPSERT; se o pagamento já está `approved`, o segundo webhook idêntico é
no-op (checa status atual antes de processar de novo).

### Webhook fora de ordem
Guardar `provider_updated_at` (timestamp que o próprio gateway manda) em
`payments`, e só aplicar uma atualização se `novo.provider_updated_at >
payments.provider_updated_at` — **last-write-wins pelo relógio do
provedor, não pela ordem de chegada na rede.** Sem isso, um "aprovado"
que chega atrasado depois de um "estornado" reverteria o estorno por
engano.

### Timeout
Job agendado (cron via Edge Function) transiciona `payment: pending →
expired` depois de uma janela configurável, libera `quantity_reserved` de
volta, e o carrinho volta pra `open` (ou vira `expired` também).

### Tentativa de pagamento duplicada (cliente clica 2x)
Idempotency key **gerada no cliente** por tentativa de checkout — o
endpoint de checkout, recebendo a mesma chave 2x, devolve o `payment`
já existente em vez de criar um novo.

---

## 6. Fiado / Conta do Cliente — análise dos 3 modelos, sem escolher por você

### Modelo A — Pagamento obrigatório antes da venda
- Banco: nenhuma estrutura extra — é o fluxo já desenhado na seção 5.
- Checkout: simples, linear.
- Financeiro: zero risco de inadimplência pro tenant.
- Operacional: mais atrito pro cliente (processa pagamento toda compra, mesmo pequena).
- Fraude: baixa — produto só libera com pagamento confirmado.
- Complexidade: baixa.
- Impacto no MVP: nenhum, é o padrão.

### Modelo B — Conta do cliente / cobrança posterior
- Banco: precisa de `customer_accounts` (saldo devedor, limite de crédito)
  e `sales.payment_id` vira opcional — mais uma entidade de "fatura"
  (`billing_statements`) que agrupa vendas de um período numa cobrança
  única depois.
- Checkout: venda completa **na hora**, estoque debitado na hora, sem
  esperar pagamento nenhum.
- Financeiro: risco real de inadimplência — o tenant assume risco de
  crédito do cliente. Precisa de limite de crédito por cliente, validado
  no checkout (`saldo_devedor + valor <= limite`).
- Operacional: exige ciclo de cobrança (poderia ser via n8n) e processo de
  bloqueio de inadimplente.
- Fraude: maior — cliente pode consumir além do razoável antes de ser
  bloqueado, ou usar credencial de outro morador pra gastar em nome dele.
- Complexidade: alta — é praticamente um módulo financeiro à parte.
- Impacto no MVP: **não cabe no MVP1**.

### Modelo C — Híbrido configurável por tenant/location
- Banco: flag `locations.payment_mode`, checkout se ramifica conforme
  configuração — soma a complexidade dos 2 modelos anteriores, não
  elimina nenhuma.
- Checkout: 2 fluxos coexistindo, mais lógica condicional, mais superfície
  de teste.
- Financeiro/operacional/fraude: herda os riscos do Modelo B onde ativado.
- Complexidade: a maior dos 3 — não é "meio-termo simples", é os 2
  sistemas inteiros mais 1 variável de configuração pra errar.
- Impacto no MVP: também não cabe no MVP1.

### Recomendação, sem implementar
**Modelo A pro MVP1 e MVP2, sem exceção.** É o único que não introduz
risco financeiro real antes de você ter volume e processo de cobrança
maduros. O Modelo C é provavelmente o destino de longo prazo — "condomínio
cobrando fiado na taxa condominial" é um caso de uso real e valioso — mas
deveria entrar como **V2 ou V3**, depois do núcleo transacional (Modelo A)
validado e estável em produção. Implementar fiado cedo é assumir risco
financeiro antes de ter processo de inadimplência maduro pra sustentar.

---

## 7. Concorrência

- **Estoque**: já detalhado na seção 4 — `SELECT ... FOR UPDATE` na linha
  específica, dentro da transação de venda.
- **Pagamentos**: `UNIQUE (provider, provider_transaction_id)` como defesa
  primária + lock de linha (`FOR UPDATE`) na linha específica de `payments`
  durante o processamento de webhook, serializando entregas concorrentes
  do mesmo evento.
- **Checkout**: idempotency key do cliente (seção 5) evita duplo-clique; a
  transição `cart.status → checked_out` é um `UPDATE ... WHERE status =
  'open'` — se 2 requisições competem pelo mesmo carrinho, só 1 afeta
  linha; a outra recebe 0 linhas afetadas e trata como "carrinho já
  processado".
- **Cancelamentos**: mesmo padrão — `UPDATE sales SET status='cancelled'
  WHERE status='completed'`. 2 tentativas concorrentes de cancelar a
  mesma venda: só 1 sucede.
- **Acesso simultâneo**: não é criticidade financeira (é acesso físico),
  mas se a credencial for de uso único (QR de visitante, por exemplo), o
  mesmo padrão de `UPDATE ... WHERE status='active'` se aplica —
  `access_logs` grava toda tentativa, sem lock nenhum (é só apêndice).

---

## 8. Idempotência — onde é obrigatória

| Onde | Mecanismo | Obrigatória? |
|---|---|---|
| Checkout | Idempotency key gerada pelo cliente | Sim |
| Criação de pagamento | Mesma key propagada ao registro de payment | Sim |
| Webhooks | `UNIQUE(provider, provider_transaction_id)` + timestamp do provedor | **Sim, a mais crítica de todas** |
| Criação de venda | Guardada por `payments.sale_id IS NULL` dentro da transação | Sim |
| Baixa de estoque | `UNIQUE` (ou checagem) em `inventory_movements` por `(reference_type, reference_id, movement_type)` — impede 2 movimentos de venda pra mesma venda | Sim |
| Eventos (`domain_events`) | Checagem/constraint por `(event_type, entity_id)` quando fizer sentido | Recomendado, menos crítico que pagamento/estoque |
| Integração n8n | Entrega com ID único, mas **n8n deve tolerar duplicata** (semântica "at-least-once", padrão de webhook) — não tente garantir exactly-once ponta a ponta, é praticamente impossível | Documentar a expectativa, não garantir na rede |

---

## 9. Auditoria — 3 conceitos que não podem se misturar

- **Business data** (`sales`, `inventory`, `payments`, `products`...): o
  estado operacional atual — "o que é verdade agora", mutável dentro de
  transições bem definidas.
- **Audit data** (`audit_logs`): histórico de **quem mudou o quê
  administrativo/crítico e quando** — foco em **responsabilização**
  (accountability), append-only, retenção longa.
- **Event data** (`domain_events`): sinal de que algo aconteceu, pra
  **processamento posterior** (notificação, n8n, tempo real na UI) — foco
  em **reação**, não em responsabilização, retenção curta (pode ser
  purgado depois de processado).

**Por que não misturar**: retenção diferente (auditoria é permanente,
evento pode ser descartado depois de consumido), consumidor diferente
(auditoria é revisão humana/compliance, evento é sistema automatizado),
padrão de escrita diferente (dado de negócio muda via CRUD normal,
auditoria é sempre disparada POR uma mudança de negócio, evento é
disparado por uma TRANSIÇÃO DE ESTADO específica — um subconjunto, não
tudo). Misturar numa tabela genérica de "logs" deixaria consulta lenta
(padrões de acesso diferentes competindo pelo mesmo índice), política de
retenção impossível de aplicar seletivamente, e confundiria "o que mudou"
com "por que estou avisando alguém sobre isso".

---

## BLOCKERS BEFORE MIGRATIONS

Só decisões que realmente impedem migration segura — nada cosmético.

### 1. Modelo de pagamento (A/B/C — fiado)
- **Por que bloqueia**: muda estruturalmente o schema de `sales`/`payments`
  (se B ou C: `payment_id` opcional, nova entidade `customer_accounts`).
- **Alternativas**: A (recomendado pro MVP), B, C.
- **Impacto de decidir tarde**: migration destrutiva numa tabela já com
  dado de produção.

### 2. Catálogo por tenant ou por location
- **Por que bloqueia**: define se `products` precisa de `location_id`
  além de `tenant_id`.
- **Alternativas**: catálogo único por tenant (recomendado, mais simples),
  ou catálogo por location.
- **Impacto de decidir tarde**: migration de dado real, não só de schema.

### 3. `sales` nasce no checkout ou só na aprovação do pagamento
- **Por que bloqueia**: define se `sales.payment_id` é `NOT NULL`, e se
  existe `status='pending'` em `sales`.
- **Alternativas**: ambas defensáveis (seção 5) — mas precisa ser
  escolhida antes, não descoberta na prática.
- **Impacto de decidir tarde**: quebra qualquer query que assuma 1 dos 2
  comportamentos.

### 4. Auth Hook do Supabase pro `tenant_id` no JWT
- **Por que bloqueia**: **toda política de RLS depende de `auth.jwt()->>'tenant_id'`
  existir de verdade** — sem isso configurado primeiro, nenhuma política
  funciona, e não dá pra testar RLS de verdade sem essa peça.
- **Alternativas**: custom claim via Auth Hook (recomendado, rápido) vs.
  tabela de lookup consultada a cada política (mais lento, mais uma fonte
  de verdade pra manter sincronizada).
- **Impacto de decidir tarde**: a fase de migration inteira trava sem isso.

### 5. Estorno reverte estoque automaticamente ou não
- **Por que bloqueia**: afeta se `inventory_movements` precisa de um
  `movement_type='estorno'` distinto de `cancelamento`.
- **Alternativas**: sempre reverte (simples, errado pra devolução
  parcial), nunca reverte automático (exige ação manual sempre), flag
  explícita no momento do refund (recomendado).
- **Impacto de decidir tarde**: o mais fraco dos 5, mas ainda afeta schema.

**Não incluídos como blocker, de propósito** (cosméticos/adiáveis): nome
exato de enum, se `PLATFORM_SUPPORT` existe agora ou depois, limite de
locations por plano, onboarding self-serve — mudança de configuração ou
lógica de aplicação depois, não migration destrutiva.

---

## Architecture Baseline v2

Arquitetura considerada estável o suficiente pra começar migration, **assim
que os 5 blockers acima forem decididos por você**:

- Multi-tenancy: banco compartilhado + `tenant_id` + RLS, com Auth Hook
  configurado **antes** de qualquer política.
- RLS: toda tabela nasce com política na mesma migration que a cria; tabela
  com `location_id` sempre tem a condição dupla (tenant + `user_locations`).
- Estoque: `inventory` (saldo derivado, nunca editado direto) +
  `inventory_movements` (ledger append-only) + trigger de recálculo + lock
  de linha na transação de venda.
- Pagamento: adapter de gateway, idempotência por
  `(provider, provider_transaction_id)`, ordenação por timestamp do
  provedor (não por chegada), baixa de estoque só na aprovação.
- Fiado: fora do MVP, Modelo A confirmado como único caminho até V2.
- Auditoria: 3 tabelas conceitualmente separadas (`audit_logs` vs
  `domain_events` vs dado de negócio), nunca misturadas.
- SUPER_ADMIN: sempre `service_role` via Edge Function, nunca política de
  RLS permissiva.

Ainda sem código, ainda sem migration — como pedido. Assim que os 5
blockers tiverem resposta sua, essa versão vira a base real da primeira
migration.
