# Blueprint Técnico — Plataforma SaaS de Mercados Autônomos

Documento de arquitetura, sem código, sem telas, sem deploy — conforme pedido.
Ordem seguindo exatamente a seção 21 do briefing.

---

## 1. Resumo Executivo

Monólito modular multi-tenant desde o dia 1, Postgres (Supabase) com
isolamento por tenant_id + Row Level Security, camada de pagamento
abstraída por adapter (nunca acoplada a 1 gateway), controle de acesso
abstraído por um contrato único (/access/verify) que hoje atende
QR/PIN/RFID e amanhã atende reconhecimento facial sem mudar o núcleo,
estoque 100% auditável via ledger de movimentações (nunca UPDATE quantity
direto), e uma camada leve de eventos de domínio (não event sourcing
completo, não fila pesada) que alimenta auditoria, notificações e n8n.

A decisão mais importante do documento inteiro é a de multi-tenancy — porque
é a única que, se errada, não tem conserto barato depois. Ela está detalhada
na seção 4, com risco explícito, não só a confirmação do que você já queria.

---

## 2. Decisões Arquiteturais

| Decisão | Escolha | Motivo |
|---|---|---|
| Multi-tenancy | Banco compartilhado + tenant_id + RLS | Único custo-viável pro perfil de tenant (condomínio, pequeno negócio) — ver seção 4 pra crítica completa |
| Arquitetura geral | Monólito modular | Volume inicial não justifica microsserviços; módulos bem separados permitem extrair depois se precisar |
| Papéis (roles) | 5 papéis fixos, sem tabela de permissões granular no MVP | Uma matriz de permissões configurável é complexidade que ninguém vai usar antes do V2 — ver seção 5 |
| Pagamento | Camada de adapter, 1 provedor implementado no MVP1, 2º provedor no MVP2 pra provar a abstração | Provar a abstração cedo, sem gold-plating adiantado |
| Controle de acesso | Contrato único /access/verify, dispositivo é quem se adapta ao backend, não o contrário | Mesma porta de entrada hoje (QR/PIN/RFID) e amanhã (facial/IoT) |
| Eventos | Tabela de outbox leve (domain_events), não fila/message broker | Sem justificativa pra Kafka/SQS no volume de hoje |
| Estoque | Ledger append-only (inventory_movements), saldo sempre derivado | Requisito explícito seu — sem isso, não é auditável de verdade |
| n8n | Consumidor externo de webhooks, nunca embutido no core | Automação fica fora do caminho crítico de venda/pagamento |
| AWS | Não entra no MVP | Supabase já resolve hospedagem/infra no volume inicial — ver seção 14 |

---

## 3. Arquitetura Geral

```
[React/TS/Vite/Tailwind - Frontend]
              |
   [Supabase Auth + PostgREST + Edge Functions]
              |
   [PostgreSQL - RLS multi-tenant]
              |
   +----------+----------+------------------+
   |          |          |                  |
[Gateways  [Dispositivos [n8n            [Supabase
 de        de acesso     (automacao,      Realtime
 pagamento (QR/PIN/RFID/  notificacao,    (eventos ao
 - adapter  futuro         relatorios)     vivo pro
 layer]     facial/IoT)]                   frontend)]
```

- Frontend fala só com Supabase (Auth + PostgREST via RLS pra leitura/
  escrita simples; Edge Functions pra qualquer operação que precise de
  service_role — pagamento, SUPER_ADMIN, relatório cross-tenant).
- Edge Functions são o único lugar que usa service_role — nunca o
  frontend, nunca um cliente de dispositivo de acesso.
- Dispositivos (leitor de QR/RFID) não falam direto com o banco — falam
  com uma Edge Function específica (/access/verify), que valida e decide.

---

## 4. Arquitetura Multi-Tenant — avaliação crítica da sua preferência

Você pediu avaliação crítica de "banco compartilhado + tenant_id + RLS" —
aqui está, sem só confirmar o que você já queria.

### Comparação das 3 estratégias

| Estratégia | Isolamento | Custo | Complexidade de migração | Adequado pro seu perfil de tenant? |
|---|---|---|---|---|
| Banco separado por tenant | Máximo | Alto (1 banco por condomínio pequeno é desproporcional) | Baixa (cada tenant é independente) | Caro demais pro tenant típico |
| Schema separado por tenant | Alto | Médio | Alta (DDL por tenant, connection pooling complica) | Só valeria pra tenant grande (rede de hotéis) |
| Banco compartilhado + tenant_id + RLS | Depende 100% da disciplina de política | Baixo | Baixa | Certo pro perfil descrito — mas com risco real |

Veredito: sua preferência está certa pro perfil de tenant que você
descreveu (condomínio, pequeno negócio, escritório — sensíveis a custo,
não a isolamento de nível bancário). Mas "certo" não significa "sem risco" —
o risco não é da estratégia, é da disciplina de execução.

### Como o isolamento funciona

- Toda tabela com dado de tenant tem tenant_id UUID NOT NULL, sem exceção.
- RLS habilitado em toda tabela desde a migration que a cria — não como
  passo separado "depois". Política padrão: tenant_id = (auth.jwt() ->> 'tenant_id')::uuid.
- tenant_id vai embutido no JWT como custom claim, definido no momento
  do login via Auth Hook do Supabase — nunca lido de um campo que o cliente
  possa manipular (ex: nunca tenant_id vindo do body da requisição).

### Como evitar vazamento de dados

- Checklist obrigatório por migration: toda tabela nova precisa de RLS
  habilitado + política de SELECT/INSERT/UPDATE/DELETE na mesma migration
  que cria a tabela — nunca "vou adicionar RLS depois". Uma tabela sem RLS
  habilitado, no Postgres, é visível por qualquer um com a chave anon.
- Teste automatizado obrigatório: pelo menos 1 teste por tabela que tenta
  ler dado de um tenant estando autenticado como outro, e espera 0 linhas.
- Nunca usar service_role no frontend — a chave de serviço ignora RLS
  por completo; se vazar, todo o isolamento multi-tenant vira decorativo.

### Como o SUPER_ADMIN funciona

O SUPER_ADMIN não deveria ser "mais um papel que o RLS trata como
acesso total" — isso amplia demais a superfície de risco. Recomendação:
SUPER_ADMIN opera só através de Edge Functions com service_role,
nunca com uma sessão de usuário comum sujeita a RLS. Toda ação de
SUPER_ADMIN passa por uma função server-side auditada, nunca por uma query
direta liberada por política de RLS.

### Como usuários se vinculam a tenants

- Equipe (TENANT_ADMIN/MANAGER/OPERATOR): profiles.tenant_id
  (1 usuário de equipe pertence a exatamente 1 tenant no MVP — multi-tenant
  por usuário de equipe é complexidade real de V2, mas vale desenhar o
  schema já preparado pra isso).
- Cliente/morador (CUSTOMER): tabela própria, separada de profiles —
  ver seção 7 pra justificativa.

### Como um usuário acessa mais de 1 location

user_locations (tabela de junção: user_id, location_id, role, status) —
o papel (MANAGER/OPERATOR) é por location, não fixo no usuário. Isso
responde de forma limpa o caso "gerente de 2 mercados" sem duplicar
usuário nem forçar 1 papel único artificial.

### Principais riscos, sem suavizar

1. Uma política de RLS esquecida = vazamento total daquela tabela. É o
   risco #1 dessa estratégia — não existe "vazamento parcial" com RLS mal
   configurado, é tudo ou nada.
2. Vazamento de service_role (em log, em código de frontend por
   engano, em variável de ambiente exposta) anula o isolamento inteiro.
3. Noisy neighbor: 1 tenant com volume de venda muito maior que os
   outros pode degradar performance pra todos, já que o banco é compartilhado.
4. Cliente enterprise futuro pode exigir isolamento físico (rede de
   hotéis grande, por política de compliance) — o modelo atual não atende
   isso sem migração real. Não é bloqueio agora, é dívida a prever.

---

## 5. Perfis e Permissões

Os 5 papéis propostos (SUPER_ADMIN, TENANT_ADMIN, MANAGER, OPERATOR,
CUSTOMER) são suficientes pro MVP, com 2 ajustes:

1. Falta um papel de suporte da plataforma (PLATFORM_SUPPORT) —
   diferente de SUPER_ADMIN (controle total), seria leitura cross-tenant
   pra atendimento/troubleshooting, sem poder de alteração. Não é MVP, mas
   vale reservar o nome agora pra não colidir depois.
2. Não crie uma tabela permissions/role_permissions genérica agora.
   O briefing lista roles e permissions como tabelas separadas — isso é
   uma matriz de permissão configurável, complexidade real que ninguém
   vai configurar antes do V2. Recomendação: papel = enum fixo no código,
   permissão por papel decidida em código de aplicação, não em tabela.
   Migra pra tabela de permissão granular só se um cliente real pedir
   "quero dar permissão X sem dar permissão Y" — não antes.

---

## 6. Módulos do Sistema — ajustes na sua lista de 22

| # | Módulo original | Ajuste proposto |
|---|---|---|
| 7+8 | Estoque e Inventário | Fundir em 1 módulo "Estoque" — inventário (contagem física) é uma operação dentro do estoque, não um módulo à parte |
| 4 | Locations/Mercados | Confirma como 1 entidade só |
| 11+12 | Carrinho, Checkout | Manter como sub-fluxos dentro de "Vendas" no código, mas conceitos distintos no modelo de dados |
| 15+16 | Logs, Auditoria | Manter separados — Logs = eventos técnicos/acesso (alto volume, retenção curta); Auditoria = mudança de negócio crítica (baixo volume, retenção longa, nunca apagar) |
| 13 | n8n | Vira parte de "Integrações" (mesmo módulo, não separado) |

Lista final proposta: Autenticação, Tenants, Usuários (equipe), Clientes,
Locations, Produtos, Categorias, Estoque (com inventário embutido), Vendas
(com carrinho/checkout como sub-fluxo), Pagamentos, Controle de Acesso,
Logs, Auditoria, Notificações, Integrações (com n8n embutido), Relatórios,
Configurações, Dashboard, Super Admin — 19 módulos, não 22.

---

## 7. Modelo de Dados

Formato compacto por entidade. Todo campo tenant_id é UUID NOT NULL
REFERENCES tenants(id) exceto onde marcado. Todo created_at/updated_at é
TIMESTAMPTZ NOT NULL DEFAULT now(), toda PK é UUID DEFAULT gen_random_uuid()
salvo indicação contrária.

### tenants
id PK · name · slug UNIQUE · plan · status (trial/active/suspended) ·
billing_email · timestamps. Sem tenant_id — é a própria raiz.

### locations
id PK · tenant_id FK · name · type (condominio/escritorio/academia/hotel/outro)
· address · timezone · opening_hours JSONB · status (active/inactive) ·
timestamps. Índice: (tenant_id, status).

### profiles (equipe — não cliente)
id PK = auth.users.id · tenant_id FK (nulo só pra SUPER_ADMIN) · full_name
· email · phone · platform_role (nulo, exceto super_admin) · tenant_role
(tenant_admin/manager/operator, não-nulo pra não-super-admin) · status ·
timestamps.

### user_locations
id PK · user_id FK profiles · location_id FK · role (manager/operator) ·
status · created_at. Índice único: (user_id, location_id).

### customers (cliente/morador — separado de profiles de propósito)
id PK · tenant_id FK · auth_user_id FK nulo (nem todo cliente loga com
senha) · full_name · email nulo · phone · document nulo · status ·
timestamps. Separado de profiles porque volume, sensibilidade e modelo de
autenticação são diferentes.

### customer_locations
id PK · customer_id FK · location_id FK · status · created_at.

### categories
id PK · tenant_id FK · name · parent_id FK nulo (hierarquia) · status ·
timestamps.

### products
id PK · tenant_id FK · category_id FK · sku · name · description ·
price_cents INTEGER (nunca float pra dinheiro) · currency (BRL padrão) ·
image_url · status (active/inactive/discontinued) · timestamps. Índice:
(tenant_id, sku) único. Decisão pendente: produto a nível de tenant com
preço variável por location, ou catálogo por location — ver seção 22.

### product_barcodes
id PK · product_id FK · barcode · type (ean13/upc/qr) · is_primary boolean
· created_at. Índice único: barcode.

### inventory (saldo atual — sempre DERIVADO, nunca editado direto)
id PK · tenant_id FK · location_id FK · product_id FK · quantity_on_hand
INTEGER · quantity_reserved INTEGER · min_stock_threshold · updated_at.
Índice único: (location_id, product_id).

### inventory_movements (ledger append-only — nunca UPDATE, nunca DELETE)
id PK · tenant_id FK · location_id FK · product_id FK · movement_type
(entrada/saida/venda/cancelamento/ajuste/perda/vencido/inventario) ·
quantity_delta INTEGER (positivo ou negativo) · reference_type nulo
(sale/manual/count) · reference_id nulo · reason nulo · performed_by FK
profiles · created_at. Índices: (tenant_id, location_id, product_id,
created_at), (reference_type, reference_id).

### carts
id PK · tenant_id FK · location_id FK · customer_id FK · status
(open/checked_out/abandoned/expired) · expires_at · timestamps.

### cart_items
id PK · cart_id FK · product_id FK · quantity · unit_price_cents
(snapshot no momento de adicionar) · created_at.

### sales (ledger imutável depois de completa)
id PK · tenant_id FK · location_id FK · customer_id FK · cart_id FK nulo ·
status (pending/completed/cancelled/refunded) · subtotal_cents ·
total_cents · payment_id FK nulo · timestamps (created_at, completed_at
nulo, cancelled_at nulo).

### sale_items
id PK · sale_id FK · product_id FK · quantity · unit_price_cents (snapshot,
nunca lê products.price_cents depois) · total_cents.

### payments
id PK · tenant_id FK · sale_id FK · provider · provider_transaction_id ·
status (pending/approved/declined/refunded/expired) · amount_cents ·
currency · idempotency_key UNIQUE · raw_webhook_payload JSONB ·
timestamps. Índice único: (provider, provider_transaction_id) — é essa
constraint que impede venda duplicada de webhook repetido (seção 9).

### access_credentials
id PK · tenant_id FK · subject_type (customer/profile) · subject_id
(polimórfico) · location_id FK · credential_type (qr/pin/rfid/nfc/face_id
futuro) · credential_value_hash (nunca plaintext) · status
(active/revoked) · expires_at nulo · created_at.

### access_logs (append-only)
id PK · tenant_id FK · location_id FK · credential_id FK nulo · event_type
(granted/denied) · device_id · reason nulo · created_at.

### audit_logs (append-only, retenção longa)
id PK · tenant_id FK · actor_id · actor_role · action (ex:
product.price_changed) · entity_type · entity_id · old_value JSONB ·
new_value JSONB · ip_address nulo · created_at. Índices: (tenant_id,
entity_type, entity_id), (tenant_id, created_at).

### notifications
id PK · tenant_id FK · recipient_type (user/customer) · recipient_id ·
channel (email/whatsapp/push/sms) · type · payload JSONB · status
(pending/sent/failed) · sent_at nulo · created_at.

### integrations
id PK · tenant_id FK · type (payment_gateway/n8n_webhook/whatsapp/outro) ·
config JSONB (segredo via Supabase Vault, nunca plaintext) · status ·
timestamps.

### domain_events (outbox — ver seção 12)
id PK · tenant_id FK nulo (alguns eventos são plataforma) · event_type ·
payload JSONB · processed_at nulo · created_at.

---

## 8. Relacionamentos (resumo)

```
tenants 1-N locations
tenants 1-N profiles (equipe)
tenants 1-N customers
profiles N-N locations (via user_locations, com role)
customers N-N locations (via customer_locations)
locations 1-N inventory
products 1-N inventory (por location)
products 1-N inventory_movements (historico)
carts 1-N cart_items
sales 1-N sale_items
sales 1-1 payments
customers 1-N sales
```

---

## 9. Regras de Negócio (mapeadas, incluindo as que faltavam no briefing)

Do briefing, confirmadas:
- Produto não pode ser vendido sem estoque disponível
  (quantity_on_hand - quantity_reserved >= quantity_pedida).
- Estoque só é debitado quando a venda é confirmada (pagamento aprovado),
  nunca no checkout em si.
- Pagamento recusado nunca gera sale.status = completed.
- Venda cancelada gera movimento reverso em inventory_movements (nunca
  edita o saldo direto).
- Usuário só acessa location onde tem user_locations ativo.
- Cliente só vê suas próprias sales (RLS por customer_id).
- Tenant só vê seus próprios dados (RLS por tenant_id).
- SUPER_ADMIN vê a plataforma inteira, via Edge Function com service_role,
  nunca via RLS de usuário comum.
- Mudança crítica gera audit_logs (lista completa na seção 16).

Faltando no briefing, que eu adicionaria:
- Item reservado no carrinho (quantity_reserved) expira depois de X
  minutos sem checkout — sem isso, estoque fica "preso" por carrinho
  abandonado.
- Um mesmo provider_transaction_id nunca pode gerar 2 sales — constraint
  de banco, não só lógica de aplicação (seção 9 do briefing, pagamento).
- Produto com status = discontinued não pode ser adicionado a carrinho
  novo, mas continua existindo em vendas antigas (nunca apagar produto
  vendido).

---

## 10. Fluxo de Compra + Máquinas de Estado

```
Cliente -> autenticacao -> autorizacao de acesso (access_credentials valido?)
  -> acesso concedido (access_logs: granted) -> navega no catalogo
  -> adiciona ao carrinho (cart: open, reserva quantity_reserved)
  -> checkout (cart: checked_out) -> cria payment (pending)
  -> gateway processa -> webhook chega
  -> payment: approved -> sale: completed -> inventory_movements (venda, delta negativo)
  -> notificacao de confirmacao -> historico disponivel pro cliente
```

### Carrinho
open -> checked_out (segue pro pagamento)
open -> abandoned (timeout sem atividade)
open -> expired (reserva de estoque expira)

### Venda
pending -> completed (pagamento aprovado)
pending -> cancelled (pagamento recusado/expirado — gera reversão de
estoque se algo já tinha sido reservado)
completed -> refunded (estorno pós-venda)

### Pagamento
pending -> approved (dispara sale: completed)
pending -> declined (dispara sale: cancelled)
pending -> expired (timeout do gateway)
approved -> refunded

### Estoque (implícito via movimentos, não um campo de status único)
disponível -> reservado (carrinho ativo) -> consumido (venda completa) OU
liberado (carrinho abandonado/cancelado)

### Acesso
credencial emitida -> ativa -> (cada tentativa: granted ou denied, sem
mudar o estado da credencial) -> revogada/expirada

---

## 11. APIs (por domínio — responsabilidade, não implementação)

| Domínio | Responsabilidade |
|---|---|
| /auth | Login, registro de cliente, custom claims de tenant no JWT |
| /tenants | CRUD (só SUPER_ADMIN), métricas globais |
| /locations | CRUD por tenant, horário de funcionamento |
| /products, /categories | CRUD de catálogo, associação com barcode |
| /inventory | Consulta de saldo, registro de movimento (nunca edição direta) |
| /carts | Criar/adicionar/remover item, expira automaticamente |
| /sales | Criar a partir de carrinho, consultar histórico |
| /payments | Criar intenção de pagamento, webhook receiver (idempotente) |
| /access | POST /access/verify — único ponto de entrada de dispositivo físico |
| /reports | Agregações por tenant/location, cross-tenant só pra SUPER_ADMIN |

---

## 12. Eventos — o que persiste, o que não

Persistidos em domain_events (alimentam auditoria, notificação, n8n):
SALE_CREATED, SALE_COMPLETED, SALE_CANCELLED, PAYMENT_APPROVED,
PAYMENT_FAILED, STOCK_LOW, ACCESS_DENIED.

Não persistidos como evento genérico (já vivem em tabela própria ou são
só estado de UI): USER_ENTERED_MARKET/USER_EXITED_MARKET (já é
access_logs, não precisa de evento duplicado); PRODUCT_ADDED_TO_CART/
CHECKOUT_STARTED (estado do próprio cart/cart_items).

Por que não fila de mensagem completa (Kafka/SQS) agora: outbox table +
Supabase Realtime já cobre "alguém precisa saber que isso aconteceu, quase
em tempo real" no volume descrito. Fila dedicada só se justifica se o
volume de eventos/segundo exigir processamento paralelo real.

---

## 13. Integração com n8n — pontos de contato

- Saída (app -> n8n): domain_events não-processados disparam webhook HTTP
  pra URL configurada em integrations (por tenant). n8n recebe, decide o
  que fazer (WhatsApp, e-mail, relatório) — o core nunca sabe o que o
  workflow faz depois.
- Entrada (n8n -> app): automação administrativa chama a API normal,
  autenticada por API key de tenant — mesmo modelo de segurança de
  qualquer cliente externo, sem porta especial pro n8n.
- Não implementar workflow nenhum agora — só os 2 pontos de contato
  precisam existir na arquitetura.

---

## 14. Tecnologia — críticas ao stack proposto

- React/TS/Tailwind/Vite: endosso, sem ressalva.
- Supabase/Postgres/Edge Functions: endosso — RLS nativo do Postgres é
  exatamente o mecanismo certo pra essa estratégia de multi-tenancy.
- AWS "quando fizer sentido": recomendo não introduzir no MVP de jeito
  nenhum. Supabase já resolve hospedagem, banco e funções server-side no
  volume inicial — misturar AWS cedo contradiz o próprio objetivo de
  "simples e fácil de manter". Revisitar só se aparecer necessidade
  concreta (ex: processamento pesado de imagem pra reconhecimento facial
  no V3).

---

## 15. Segurança — riscos críticos, sem suavizar

1. RLS mal configurado — risco #1, já detalhado na seção 4.
2. Vazamento de service_role — anula todo o isolamento se exposto em
   frontend, log, ou variável de ambiente incorreta.
3. Webhook de pagamento sem verificação de assinatura — qualquer um
   poderia forjar um "pagamento aprovado" batendo no endpoint diretamente.
   Validação de assinatura do gateway é inegociável.
4. PIN de baixa entropia — PIN de 4-6 dígitos é força bruta trivial sem
   rate limiting agressivo + bloqueio após N tentativas em /access/verify
   especificamente (mais crítico aqui que em login normal, porque controla
   acesso físico).
5. QR estático = credencial compartilhável indefinidamente — recomendo QR
   de curta duração/rotativo, não um código fixo por cliente pra sempre.
6. Fraude física (cliente leva item sem pagar) — problema fundamentalmente
   de hardware/visão computacional, fora do escopo do backend hoje. O
   sistema audita e detecta divergência, não previne fisicamente — seja
   transparente sobre isso com os stakeholders.

---

## 16. Auditoria — o que gera log, o que fica armazenado

Ações que precisam gerar audit_logs (lista do briefing, confirmada, mais 2
adições): criação de produto, alteração de preço, alteração de estoque
manual (ajuste, não venda), cancelamento de venda, alteração de usuário,
alteração de permissão/papel, alteração de configuração de tenant,
abertura/fechamento de mercado, alteração de integração, + revogação de
credencial de acesso, + suspensão de tenant por SUPER_ADMIN.

Cada linha de audit_logs guarda: quem (actor_id + actor_role, nunca só o
nome), o quê (action + entity_type + entity_id), o antes e o depois
(old_value/new_value em JSONB — nunca só "mudou", sempre "de X pra Y"),
quando, e de onde (ip_address, quando disponível).

---

## 17. Estrutura do Projeto

```
src/
  modules/
    auth/
    tenants/
    locations/
    products/
    inventory/
    sales/           (inclui cart, checkout como sub-pastas)
    payments/
      providers/      (1 arquivo adapter por gateway)
    access/
      providers/       (1 arquivo adapter por tipo de credencial)
    customers/
    notifications/
    integrations/
    audit/
    reports/
    super-admin/
  shared/
    types/            (tipos compartilhados entre modulos)
    lib/              (cliente Supabase, helpers puros)
    components/       (UI genérica, sem lógica de domínio)
  hooks/
```

Cada módulo é autocontido (seus próprios tipos, suas próprias queries) —
o objetivo declarado por você ("IA consegue trabalhar em módulo sem
destruir o resto") só funciona se módulo não importar profundamente de
dentro de outro módulo, só de shared/.

---

## 18. Estratégia de Testes

- RLS: teste automatizado por tabela, tentando cross-tenant leak (seção 4).
- Regras de negócio críticas: teste unitário puro pra cálculo de estoque,
  cálculo de total de venda, transição de estado de pagamento — sem tocar
  banco, função pura testável isolada.
- Idempotência de webhook: teste específico simulando o mesmo webhook
  chegando 2x, confirmando 1 sale só.
- E2E: fluxo de compra completo (cliente -> acesso -> carrinho ->
  pagamento -> venda) como teste de fumaça antes de cada release.

---

## 19. Escalabilidade

Monólito modular é a escolha certa até a casa de centenas de tenants — não
milhares. Pontos de atenção conforme cresce:

- 10 -> 100 mercados: sem mudança estrutural, só monitorar índice em
  tenant_id em toda tabela quente.
- 100 -> 1.000: considerar réplica de leitura pra relatório/dashboard (não
  deixar consulta agregada pesada competir com venda em tempo real no
  mesmo banco primário).
- 1.000 -> 10.000: reavaliar se "vendas + pagamento" merece extração como
  serviço separado (o monólito MODULAR permite isso sem reescrita, se os
  limites de módulo forem respeitados desde o início). Tenant grande/
  enterprise pode justificar tier de isolamento por schema nesse ponto.

---

## 20. Roadmap

MVP1 (menor sistema operável em 1 mercado real): tenant/location via seed
manual (sem onboarding self-serve ainda) · papéis TENANT_ADMIN/OPERATOR/
CUSTOMER só · produtos + categorias + estoque com ledger de movimentação
desde o primeiro dia (não-negociável) · carrinho + checkout + 1 gateway de
pagamento (PIX) · criação de venda + baixa de estoque · acesso só por QR ·
audit log nas ações mais críticas · sem dashboard além de lista simples de
vendas · sem notificação/n8n ainda.

MVP2: acesso por PIN · papel MANAGER + multi-location por tenant ·
dashboard básico de TENANT_ADMIN (vendas, estoque) · cancelamento/estorno
· notificação simples de estoque baixo · 2º gateway de pagamento (prova a
abstração) · audit log completo (lista da seção 16).

V2: dashboard SUPER_ADMIN completo + suspensão de tenant · pontos de
integração n8n ativos · acesso por RFID/NFC · módulo de relatórios ·
cliente multi-location · matriz de permissão granular, se a necessidade
real aparecer (não antes).

V3: reconhecimento facial (integração com fornecedor externo) · controle
de porta via IoT · fraude/analítica avançada · tier de isolamento por
schema pra tenant enterprise · réplica de leitura/analítica separada.

---

## 21. Riscos Técnicos (consolidado)

1. RLS mal configurado = vazamento total (seção 4) — o maior de todos.
2. service_role exposto = mesma coisa, por outra porta.
3. Webhook de pagamento sem verificação de assinatura = venda forjada.
4. PIN de baixa entropia sem rate limit agressivo = acesso físico
   comprometido.
5. Reserva de carrinho sem expiração = estoque "preso" artificialmente.
6. Fraude física — fora do alcance do backend, seja transparente sobre isso.
7. Tenant enterprise futuro exigindo isolamento que o modelo atual não
   suporta sem migração real.

---

## 22. Decisões Que Ainda Precisam Ser Tomadas

Preciso da sua resposta nessas antes de qualquer implementação:

1. Produto é definido a nível de tenant (catálogo único) com preço podendo
   variar por location, ou cada location tem catálogo independente? Isso
   muda o modelo de products/inventory de forma estrutural.
2. Existe "fiado" (consumo primeiro, cobrança depois — comum em condomínio
   que cobre na taxa condominial)? Se sim, o fluxo "pagamento antes de
   venda ser criada" precisa de uma exceção real, não é detalhe pequeno.
3. Produto tem variante (tamanho/sabor) como o mesmo produto com opções,
   ou cada variante é um SKU/produto separado? Afeta products.
4. Como o tenant paga a plataforma (a cobrança do próprio SaaS, não do
   consumidor final) — não estava no briefing, mas precisa existir uma
   camada de billing do tenant pra você em algum momento.
5. Onboarding: SUPER_ADMIN cria tenant manualmente no início, ou precisa
   de cadastro self-serve já no MVP1?
6. Limite de locations por tenant — ilimitado, ou por plano?

---

## PRÓXIMA ETAPA

Depois de você aprovar (ou corrigir) este blueprint, a primeira
implementação não deveria ser tela nenhuma — deveria ser:

1. As migrations do núcleo de tenancy (tenants, locations, profiles,
   user_locations) com RLS habilitado e testado desde a primeira
   migration, incluindo os testes automatizados de vazamento cross-tenant
   descritos na seção 18.

Motivo de começar exatamente aqui: é a única peça do sistema inteiro onde
um erro não tem correção barata depois — cada módulo posterior (produto,
venda, pagamento) herda a segurança (ou insegurança) dessa fundação. Só
depois de RLS provado funcionando com teste automatizado real — não "parece
que funciona" — faz sentido avançar pro módulo de produtos/estoque.
