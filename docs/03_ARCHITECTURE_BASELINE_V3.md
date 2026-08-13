# Architecture Baseline — Decisões Finais (V3)

Consolidação das decisões aprovadas, com o detalhamento pedido. Ainda sem
código, sem SQL, sem migration, sem tela — como pedido.

---

## 1. Pagamento — confirmado

Modelo A (pagamento obrigatório antes da venda completar) pro MVP1/MVP2,
sem exceção. O domínio de vendas não fica acoplado a essa decisão de um
jeito que impeça adicionar conta a receber depois — a extensibilidade já
está desenhada na própria estrutura de sales.payment_id (opcional em
princípio) e na separação entre "venda completa" (fato de negócio) e
"forma de pagamento" (que pode, no futuro, ser "a prazo" em vez de
"gateway", sem mudar o que sales/sale_items significam).

---

## 2. Catálogo — products + product_locations + inventory

Decisão: os 3 existem, com responsabilidades diferentes — não é
redundância, é separação de 3 preocupações genuinamente distintas.

| Tabela | O que representa | Quem muda | Frequência de mudança |
|---|---|---|---|
| products | Catálogo canônico do tenant — nome, descrição, SKU, base_price_cents, moeda, imagem | TENANT_ADMIN/MANAGER | Baixa |
| product_locations (nova) | Configuração por location: price_override_cents (nulo = usa o preço base), is_available (o produto está listado nesta location?) | TENANT_ADMIN/MANAGER | Média |
| inventory | Saldo operacional — quantidade real disponível nesta location | Sistema (via inventory_movements) | Alta |

Por que não misturar product_locations com inventory: mesma lógica já
aplicada a audit_logs/domain_events/dado de negócio — são preocupações de
natureza diferente. product_locations é configuração (decidida por gente,
muda pouco), inventory é estado operacional (decidido por movimento de
estoque, muda toda hora). Colocar preço/disponibilidade dentro de
inventory forçaria toda consulta de catálogo a tocar a tabela mais quente
do sistema, e forçaria toda venda a competir por lock com quem só quer
saber se um produto está listado.

Resultado prático: um produto pode existir em products (catálogo do
tenant), ter uma linha em product_locations (configurado como disponível
naquela location, com ou sem preço específico), e ainda não ter nenhuma
linha em inventory até a primeira entrada de estoque acontecer — os 3
estados são independentes e isso é intencional, não uma inconsistência.

---

## 3. Sales — nasce no checkout, máquinas de estado completas

### Cart
```
open --checkout iniciado--> checked_out (terminal, converteu em sale)
open --timeout de inatividade--> expired (terminal, libera reserva se houver)
```
2 estados terminais só — não criei "abandoned" separado de "expired": os
dois cenários (cliente sumiu vs. reserva estourou o prazo) têm o mesmo
efeito prático (libera o que estava reservado), então é 1 estado só, com
o motivo guardado num campo interno se for útil pra métrica depois.

### Sale
```
pending --pagamento aprovado--> completed
pending --pagamento recusado/expirado--> cancelled
completed --acao de estorno--> refunded
```
4 estados, 3 transições. completed nunca volta pra cancelled — uma vez
completa, o único caminho pra desfazer é refunded (com a decisão explícita
de estoque da seção 5). Isso evita 2 conceitos diferentes ("cancelar uma
venda completa" vs. "estornar") competindo pelo mesmo significado.

### Payment
```
pending --gateway aprova--> approved   (dispara sale: completed)
pending --gateway recusa--> declined   (dispara sale: cancelled)
pending --timeout--> expired           (dispara sale: cancelled)
approved --acao de estorno--> refunded (dispara sale: refunded)
```
Duplicidade: uma 2ª tentativa de criar payment pra o mesmo checkout (mesma
idempotency key) nunca cria um novo registro — devolve o existente
(seção 8 detalha a chave exata).

---

## 4. Tenant no JWT — modelo definitivo

Claims no JWT (definidos server-side no Auth Hook, nunca aceitos do
cliente):
- sub — user_id (padrão)
- tenant_id — obtido de profiles.tenant_id ou customers.tenant_id (o hook
  checa as duas tabelas, dependendo de qual bate com o usuário autenticando)
- platform_role — só presente (e só super_admin) pra SUPER_ADMIN; ausente
  pra todo o resto
- tenant_role — tenant_admin/manager/operator; ausente pra cliente puro
  (que não tem linha em profiles)

Location access — deliberadamente FORA do JWT: user_locations/
customer_locations são consultados em tempo real, a cada requisição, via
EXISTS na política de RLS — não embutidos no token.

Por quê: acesso a location muda com frequência real (equipe é realocada,
cliente muda de morada) — se estivesse no JWT, revogar acesso só valeria
depois do token expirar/renovar. Consultando ao vivo, revogar acesso vale
na próxima requisição, não depois de um ciclo de token. Custo: 1 EXISTS a
mais por query nas tabelas com location_id — aceitável no volume descrito,
e a troca (segurança > latência marginal) é a certa pra esse domínio.

---

## 5. Refund — refund_inventory explícito

Confirmado: nunca inferido automaticamente. A ação de estorno sempre
carrega refund_inventory: true/false, decidido no momento por quem
estorna (MANAGER/TENANT_ADMIN).

- true: cria novo movimento em inventory_movements
  (movement_type='estorno', delta positivo, reference_type='sale',
  reference_id=sale.id) — nunca edita ou apaga o movimento de venda original.
- false: sale.status -> refunded, payment atualizado, nenhum movimento de
  estoque criado — o saldo continua refletindo que o produto saiu
  fisicamente, mesmo com o dinheiro devolvido.

Simplificação assumida pro MVP, registrada explicitamente: estorno é
tratado como valor total da venda — estorno parcial fica fora de escopo
por ora. Se isso não bater com a expectativa real, é uma correção pequena
de escopo, não uma mudança estrutural.

---

## 6. Domain Events — consumidor definido, sem infraestrutura pesada

1. Quem grava: código de aplicação (Edge Function), na mesma transação da
   mudança de estado que originou o evento — não é trigger de banco
   (diferente do saldo de inventory, que É trigger). Motivo da diferença:
   saldo é recálculo simples e mecânico; evento frequentemente precisa de
   contexto mais rico (dado de cliente pra notificação, por exemplo) que
   é mais natural montar em código de aplicação do que reconstruir dentro
   de um trigger.
2. Quem processa: uma Edge Function agendada (cron, a cada 30-60s) que
   busca domain_events com status='pending', processa em ordem de
   criação, e marca o resultado. Não é fila de mensagem, não é
   Kafka/RabbitMQ — é uma tabela pequena com um poller simples, o
   suficiente pro volume do MVP. Migrar pra push em tempo real (Supabase
   Realtime) fica como melhoria futura, só se latência de 30-60s virar
   reclamação real.
3. Como são marcados como processados: status='processed',
   processed_at=now() — só depois que a ação de downstream (webhook,
   notificação) confirma sucesso, nunca antes ("fire and forget" perderia
   evento silenciosamente se a chamada falhasse).
4. Falhas: evento que falha fica status='pending' (ou incrementa
   retry_count), tentado de novo no próximo ciclo. Depois de N tentativas
   (ex: 5), marca status='failed' — sai do ciclo de retry automático, mas
   fica visível pra investigação manual, com last_error guardado.
5. Evitar processamento duplicado: o poller "reivindica" o evento antes de
   processar — UPDATE domain_events SET status='processing' WHERE id=X
   AND status='pending' (mesmo padrão de guarda atômica usado em
   carrinho/venda/estoque). Com 1 instância de poller no MVP isso é baixo
   risco, mas correto desde já custa pouco.
6. Integração futura com n8n: o poller, ao identificar um evento que
   deveria disparar webhook (config em integrations, por tenant + tipo de
   evento), faz POST pra URL registrada. n8n é só mais um "assinante" que
   o poller notifica — nenhum caminho de código especial pra ele, mesmo
   mecanismo de qualquer outra notificação.
7. Eventos necessários no MVP: gravar desde o MVP1 é barato (1 INSERT
   junto da transição de estado) — recomendo começar a gravar já. O que
   fica pra MVP2 é o consumo ativo (o poller rodando de verdade,
   n8n/notificação conectados) — MVP1 pode operar com a tabela crescendo
   sem consumidor, por pouco tempo, sem problema real dado o volume. Não
   builda o poller antes de ter algo real pra ele processar.

---

## 7. Concorrência — mecanismo definitivo (sem SQL, passo a passo)

Cenário: estoque=1, Cliente A e Cliente B tentam comprar ao mesmo tempo.

Decisão de desenho que precisa ficar explícita: a reserva
(quantity_reserved) acontece no checkout, não em "adicionar ao carrinho"
— adicionar ao carrinho é uma ação de UI sem garantia de estoque; a
garantia real só nasce quando o checkout começa. Isso evita carrinho
parado travando estoque por tempo indefinido.

Sequência, dentro de 1 transação atômica:

1. Inicia transação.
2. Trava a linha específica de inventory (aquela location + aquele
   produto) — nenhuma outra transação consegue ler/escrever essa mesma
   linha até essa transação terminar.
3. Valida: quantity_on_hand - quantity_reserved >= quantidade pedida. Se
   falhar -> desfaz a transação inteira, devolve "estoque insuficiente"
   pra quem pediu.
4. Se validar: cria sale (pending), sale_items, payment (pending), e
   incrementa quantity_reserved (incremento direto, não via
   inventory_movements — reserva é uma retenção temporária, não um fato
   permanente de estoque; só vira movimento de verdade se a venda
   completar).
5. Confirma a transação — a partir daqui, a trava é liberada.

O que acontece com o segundo cliente: a tentativa dele espera o passo 2
até a transação do primeiro terminar (trava de linha). Quando a trava
libera, ele lê o estado já atualizado (com a reserva do primeiro já
contada) — a validação do passo 3 falha pra ele, porque não sobra mais
nada disponível. Não existe cenário onde os dois passam.

Quando o pagamento é aprovado depois: nova transação, mesma trava de
linha, decrementa quantity_reserved e cria inventory_movements (venda,
delta negativo) — que via trigger reduz quantity_on_hand. Se o pagamento
for recusado/expirar: nova transação, mesma trava, só decrementa
quantity_reserved (libera a reserva) — nenhum movimento de estoque
criado, porque nada foi consumido de verdade.

Rollback: qualquer falha nos passos 1-4 desfaz a transação inteira —
nunca existe um estado intermediário salvo (venda criada sem reserva, ou
reserva feita sem venda). Tudo ou nada.

---

## 8. Idempotência — chave exata e onde fica

| Ponto | Chave de idempotência | Onde fica armazenada |
|---|---|---|
| Checkout | UUID gerado pelo cliente por tentativa de checkout | sales.idempotency_key (UNIQUE) |
| Criação de payment | Mesma chave do checkout (reaproveitada, não gerada de novo) | payments.idempotency_key (UNIQUE) |
| Webhook de payment | (provider, provider_transaction_id) — gerada pelo provedor | Colunas em payments, UNIQUE composta |
| Conclusão da sale | Checagem de estado (sale.status != 'completed') + trava de linha na própria sales, não uma chave separada | Estado da própria linha |
| Refund | UUID gerado por quem estorna, por ação de estorno | payments.refund_idempotency_key (UNIQUE, nula até haver estorno) |
| Inventory movement | Chave natural: (reference_type, reference_id, movement_type) | Constraint UNIQUE composta em inventory_movements |
| Domain events | (event_type, entity_id) — quando só faz sentido 1 instância daquela transição | Constraint UNIQUE composta (ou checagem antes do INSERT) em domain_events |

---

## REMAINING BLOCKERS

**NO REMAINING ARCHITECTURAL BLOCKERS.**

Os 5 blockers da revisão anterior (modelo de pagamento, catálogo por
tenant/location, nascimento de sales, Auth Hook, estorno) têm decisão
registrada. Nenhuma pergunta nova surgiu no aprofundamento de hoje que
impeça migration segura.

2 escolhas de desenho que fiz e registro com transparência (não são
blockers — são detalhes que decidi pra poder continuar, sinalizados pra
você discordar se fizer sentido, sem exigir mais uma rodada de revisão):
1. Reserva de estoque (quantity_reserved) é contador direto, não passa
   pelo ledger de inventory_movements — só vira movimento permanente
   quando a venda completa de verdade.
2. Estorno parcial fica fora do MVP — tratado como valor total por
   enquanto.

---

## ARCHITECTURE BASELINE V3

Referência oficial pra implementação, consolidando as 3 rodadas de revisão:

- Multi-tenancy: banco compartilhado + tenant_id + RLS, Auth Hook
  configurado antes de qualquer política.
- Catálogo: products (tenant) + product_locations (configuração por
  location) + inventory (saldo operacional) — 3 preocupações separadas,
  de propósito.
- Vendas: sale nasce pending no checkout, só completa na aprovação do
  pagamento — 4 estados, 3 transições, sem caminho de volta de completed
  pra cancelled (só refunded).
- Estoque: inventory (derivado, nunca editado direto) +
  inventory_movements (ledger append-only) + reserva como contador
  transitório, não ledger.
- Concorrência: trava de linha (FOR UPDATE) + transação atômica no
  momento do checkout — validação e reserva no mesmo passo, nunca separados.
- Pagamento: adapter de gateway, idempotência por
  (provider, provider_transaction_id) + ordenação por timestamp do
  provedor, nunca por ordem de chegada.
- Fiado: fora do MVP1/MVP2, Modelo A confirmado, domínio desenhado pra
  não precisar reestruturação quando (se) crédito entrar depois.
- Eventos: outbox simples (domain_events), poller agendado, sem fila de
  mensagem — gravação começa cedo (MVP1), consumo ativo começa quando
  notificação/n8n entrarem (MVP2).
- Auditoria: 3 conceitos sempre separados — dado de negócio, log de
  auditoria, evento de domínio.
- SUPER_ADMIN: sempre service_role via Edge Function, nunca política de
  RLS permissiva.

Ainda sem código, sem SQL, sem migration, sem componente, sem tela — como
pedido. Parando aqui, aguardando a próxima etapa ser solicitada
separadamente.
