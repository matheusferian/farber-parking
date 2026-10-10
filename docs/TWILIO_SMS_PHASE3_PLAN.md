# AirValet × Twilio — Fase 3: identidade única, voo de retorno, link do passageiro, custo

Status 2026-10-09: **preparado localmente; nada pago, publicado ou enviado.** Substitui as partes de identidade, templates e Campaign de `TWILIO_SMS_PHASE2_TEMPLATES_OPTIN_CAMPAIGN.md`.

## 1. Identidade: "Makers Air Valet" para todos
- Todos os templates começam com `Makers Air Valet:`, inclusive para passageiros Ascend (teste automatizado garante que "Ascend Valet" nunca aparece como remetente).
- Um único número, um único Messaging Service ("AirValet SMS"), uma única Campaign.
- **Compatibilidade:** o Brand A2P é "Farber Parking". O disclosure, as páginas públicas e a descrição da Campaign dizem "Makers Air Valet (operated by Farber Parking), serving Makers Air and Ascend passengers". O nome que aparece no SMS bate com o que o passageiro aceitou e com o que a operadora revisa, e o Brand continua sendo quem opera. ✓

## 2. Voo de retorno: campos (⚠ substituído pela seção 10)
| Conceito | Já existia? | Decisão |
|---|---|---|
| `departure_operator` | **Sim, implícito**: ticket `A-` = Ascend (`isAscend()`, DECISIONS.md) | Não duplicar. Função SQL `airvalet_departure_operator(ticket)` e TS `departureOperator()` usam a mesma regra |
| `return_operator` | **Não.** `delivery_at_customs` só tem 2 estados (false = Hangar 19 **ou** "não sei"); `not_returning_with_makers_air` = "outro barco", não "Ascend" | **Nova coluna nula** `passengers.return_operator` ∈ {MAKERS, ASCEND}. NULL = não confirmado. Migration só adiciona (sem default, sem reescrever a tabela) |
| `return_location` | Não | **Derivado, nunca gravado**: MAKERS→HANGAR_19, ASCEND→CUSTOMS (`airvalet_return_location()`), sem como divergir |

Dados reais (produção, últimos 120 dias, só leitura): **20** bilhetes Ascend foram entregues no fluxo normal (voltaram pela Makers) e **31** bilhetes Makers foram entregues via Customs (voltaram pela Ascend). Os mistos são reais, por isso a separação é necessária.

## 3. Matriz dos 4 cenários (⚠ substituído pela seção 10)
| # | Saída (ticket) | Volta (return_operator) | Local de retirada | SMS "veículo pronto" (manual) | Página do link | Entrega/gorjeta (preservado) |
|---|---|---|---|---|---|---|
| 1 | Makers | Makers | **Hangar 19** | HANGAR19_WELCOME_BACK: "...return to Makers Air at Hangar 19... don't exit through the U.S. Customs terminal..." | "Makers Air, Hangar 19" + instruções | NORMAL/LOCKBOX → TIP_YES/TIP_NO |
| 2 | Ascend | Ascend | **Customs** | CUSTOMS_WELCOME_ASCEND: "...ready at Customs. An Ascend team member will personally hand you your key..." | "At Customs" | CUSTOMS → Welcome Back → só então gratuity |
| 3 | Ascend | **Makers** | **Hangar 19** | HANGAR19_WELCOME_BACK (nunca Customs) | Hangar 19 | NORMAL → TIP_* |
| 4 | Makers | **Ascend** | **Customs** | CUSTOMS_WELCOME_MAKERS: "...ready at Customs. The key is on the driver's-side tire." (nunca Hangar 19) | Customs | CUSTOMS → gratuity flow |
| — | qualquer | **não confirmado** | **nenhum** | **Bloqueado** (`RETURN_NOT_CONFIRMED`); o botão fica desabilitado com "confirm return flight first" | "Return flight not confirmed yet" + pede data, horário e operador | — |

Regras auditadas e preservadas:
- A gratuity da Customs só sai depois do Welcome Back.
- Entrega pela Customs nunca recebe o tip SMS genérico.
- O VEHICLE_READY é **sempre manual**. Não existe envio automático de "veículo pronto".

⚠ Ponto de auditoria (comportamento atual preservado, não alterado): na Customs, o texto da **chave** varia pelo bilhete de **saída** ("Ascend team member hands key" × "key on driver's-side tire"). O local já vem do voo de volta; a forma de entrega da chave segue como hoje. Se a chave deve seguir o voo de volta, é uma linha de código a trocar.

## 4. SMS inicial: três versões (link de 44 caracteres, só caracteres GSM-7)
A versão escolhida no código é a **B**, ainda em PENDING_APPROVAL. O link leva a `pass.html`: página real, só leitura, com nome, veículo, status, data de retorno e retirada **apenas se o retorno estiver confirmado**, mais o botão de ligar para (954) 352-1010, o número impresso hoje no ticket. Não mostra "opções de retorno" porque elas ainda não existem (o Valet Pass completo segue em mockup). Por isso o texto diz "valet details", não "return options".

| Versão | Texto | Caracteres / segmentos | Compliance |
|---|---|---|---|
| **A: curta** | `Makers Air Valet: Your vehicle is checked in! Your valet details are here: https://airvalet.farberos.com/p/Ab3dE6gH9jK2 Reply HELP for help, STOP to opt out.` | 157 / **1** | Parcial: falta "msg freq / msg&data rates" na confirmação de opt-in. Risco de reprovação ou filtragem |
| **B: completa** ✅ | `Makers Air Valet: Your vehicle is checked in! Your valet details are here: <link> Questions? Just reply. Msg freq varies. Msg&data rates may apply. Reply HELP for help, STOP to opt out.` | ~209 / **2** | Completa (marca, frequência, tarifas, HELP, STOP) |
| **C: pessoal** | `Makers Air Valet: Hi Ana, your Escalade is checked in. Your valet details: <link> Questions? Just reply. Msg freq varies. Msg&data rates may apply. HELP for help, STOP to opt out.` | ~200 (varia com nome e carro) / **2** | Completa |

Recomendação: **B**. O segmento a mais custa ~$0,013 por passageiro (≈ $1,90 a $6,35/mês entre 150 e 500 passageiros) e protege a aprovação da Campaign. Uma reprovação custa outro vetting de $15 e dias de espera.

Demais textos (todos com "Makers Air Valet:", só GSM-7, orçamento de segmentos coberto por teste):
- RETURN_CONFIRMATION, quando o retorno não está confirmado (1 seg): "Hi Ana, please reply with your return date, arrival time and whether you're flying back with Makers Air or Ascend. Thank you!" Quando já está confirmado (1 seg): "Hi Ana, can you confirm your return date and arrival time? Just reply to this message. Thank you!"
- VEHICLE_READY: Hangar 19 = 2 seg; Customs = 1 seg.
- TIP_YES e TIP_NO = 1 seg; CUSTOMS_GRATUITY = 2 seg (o link Stripe é longo).

## 5. Comparação de Campaigns (preços vistos na tela da Twilio em 2026-10-09)
| | **Low Volume Mixed** ✅ | Customer Care (standard) |
|---|---|---|
| Mensalidade | **$1,50** | $10,00 |
| Vetting (uma vez) | $15 | $15 |
| Limite | 2.000 segmentos/dia na T-Mobile; throughput menor | maior |
| Nosso pico estimado | ~117 seg/dia com 500 passageiros/mês (6% do limite) | — |
| Brand Farber (Low Volume Standard) | Elegível segundo a documentação da Twilio (LVM vale para Brands Standard e LVS). A tela da Twilio lista LVM a $1,50; a confirmação final é no momento de submeter | Elegível |
| Compliance | Os mesmos requisitos (opt-in, amostras, STOP/HELP). Escolhem-se 2 a 5 sub-use cases: Customer Care + Account Notification | idem |
| Vantagem que justifique $8,50/mês a mais? | — | **Nenhuma no nosso volume** |

## 6. Custo mensal estimado
Base (página oficial de preços): **$0,0083 por segmento** enviado ou recebido.
- Taxas das operadoras por segmento enviado: AT&T $0,0035, T-Mobile $0,0045, Verizon $0,005; média ponderada (30/35/35) ≈ **$0,0044**.
- Recebido: AT&T $0,0035, T-Mobile $0,0025, Verizon $0; média ≈ $0,0019.
- Total ≈ **$0,0127 por segmento enviado** e **$0,0102 por segmento recebido**.

Premissas:
- "2 SMS" = check-in (2 seg) + entrega (1 seg) = 3 segmentos por passageiro.
- "5 SMS" = check-in 2 + pedir data 1 + veículo pronto 2 + entrega 1 + 1 resposta da equipe = 7 segmentos.
- Mais 1 resposta do passageiro.
- Fixo LVM = número $1,15 + Campaign $1,50 = **$2,65/mês**.

| Passageiros/mês | 2 SMS por passageiro | 5 SMS por passageiro |
|---|---|---|
| 150 | **$9,89** | **$17,49** |
| 300 | **$17,12** | **$32,33** |
| 500 | **$26,77** | **$52,12** |

Com Customer Care, some $8,50/mês em cada célula.
- Pagamentos únicos: vetting $15; o Brand já está pago.
- Volume real de referência: jun–set/2026 teve 138 a 332 check-ins por mês.

O que não gera custo extra:
- **Sem retry** de envio. Só 429, quando a Twilio recusou e não criou a mensagem.
- Timeout fica como `send_unknown` e não é reenviado.
- Mensagens que falham podem ter uma taxa de processamento mínima da Twilio (~$0,001).
- Sem IA, sem subconta e sem encurtador pago. O link usa domínio próprio e a abertura é rastreada de graça pela própria página.
- Sem envio automático de "veículo pronto".
- Validity period de 1 h: mensagem presa na fila não sai atrasada.

## 7. Lista exata de alterações
**Prontas no worktree** (`feature/twilio-sms-local`, não commitado; backups em `BKP/2026-10-09 14-12-23`):
- `migrations/20261009_create_airvalet_sms_messages.sql` e rollback: SMS, status, opt-out, consentimento, inbox (views e RPCs).
- `migrations/20261010_add_passenger_return_operator.sql` e rollback: **coluna nova em `passengers`**, só adiciona.
- `migrations/20261010_create_airvalet_pass_links.sql` e rollback: links `/p/<token>` e "link aberto".
- `supabase/functions/_shared/sms/*`; `send-sms`; `twilio-status-callback` e `twilio-inbound` (`--no-verify-jwt`); `valet-pass` (`--no-verify-jwt`).
- `pass.html`, `sms.html`, `privacy.html`, `terms.html` (públicas).
- `vercel.json`: rewrite `/p/:token → /pass.html` e headers `no-store`/`noindex` (diff de 10 linhas).
- `vercel-build.sh`: inclui as 4 páginas na allowlist.
- `tests/sms/*` e `mockups/sms-inbox/*` (fora do deploy).

**Ainda não feitas no `index.html`** (depois da aprovação do mockup, com screenshots, conforme a regra de UI):
1. Check-in: seletor "Returning with" (Makers · Ascend · Not confirmed, padrão Not confirmed), bloco de opt-in e `return_operator` no payload do `saveEntry`.
2. Editar passageiro: seletor `return_operator` (mantém `delivery_at_customs = (ASCEND)` para impressão e TV continuarem iguais) e o rótulo no activity log.
3. `sendPassengerSms` com o provider `twilio` chamando `send-sms`. Botões atuais mapeados: Welcome/Save+Text → CHECK_IN; Welcome Back e Customs Welcome → VEHICLE_READY; Gratuity → CUSTOMS_GRATUITY; Tip → VEHICLE_DELIVERED; Return/Tasks → RETURN_CONFIRMATION; TEXT → inbox.
4. Aba Messages vira o inbox: lista, thread, resposta, Needs review, badge e polling a cada 20 s (sem custo extra).
5. Check-in offline guarda o consentimento junto e envia depois da sincronização.
6. Aumentar a versão do cache do service worker.

## 8. Testes (local; Postgres descartável; sem rede Twilio)
- **SQL:** 91 checks com as 3 migrations (aplicar → rollback reverso → reaplicar). Cobrem: RLS (anon, TV_ONLY, sem perfil), consentimento, REPLY 24 h, opt-out, rate limit, ordem de status, callback órfão, matching de inbound, review, operador de retorno e links (token, reutilização, expiração 3 dias após a entrega, revogação, "link aberto").
- **Concorrência:** 20 claims simultâneos geram 1 linha e 1 envio.
- **Unitários Deno:** 49. Incluem a matriz dos 4 cenários, identidade única, orçamento de segmentos, só GSM-7, assinatura Twilio conferida contra o SDK oficial, timeout/4xx/429/5xx, "nunca lança erro" e logs sem dados sensíveis.
- **Integração:** serviço + SQL + webhooks, 5 etapas.
- **Legado do repositório:** 17 testes (13 Deno + 4 Node), verdes.
- Typecheck e lint limpos. Build (`vercel-build.sh`) OK. Varredura de secrets: nenhum.

## 9. Recomendação: o caminho mais barato e seguro
1. **1 número local** ($1,15/mês) no "AirValet SMS". O FarberOS fica intocado.
2. **Campaign Low Volume Mixed** ($15 uma vez + $1,50/mês) no Brand Farber existente.
3. SMS inicial **versão B**; demais mensagens manuais, exceto check-in e entrega, que fazem parte da ação do atendente.
4. Ordem de execução (cada passo pede seu GO):
   1. Publicar as páginas públicas e `pass.html`.
   2. Comprar o número.
   3. Submeter a Campaign (aceitar os termos de cobrança na tela).
   4. Rodar as migrations em produção.
   5. Gravar os secrets (você digita).
   6. Publicar as 4 Edge Functions com o modo `disabled`.
   7. Frontend.
   8. Primeiro SMS real em `allowlist`, depois da Campaign aprovada.


## 10. Atualização: Returning with editável (MAKERS · ASCEND · OTHER), 2026-10-09

**Modelo**
- **Flying with** = operador de saída. Continua sendo o prefixo do ticket (`A-` = Ascend), registro histórico, nunca muda quando o retorno muda.
- **Returning with** = `passengers.return_operator` ∈ {MAKERS, ASCEND, OTHER}, **editável a viagem inteira**.
  - No check-in recebe por padrão o mesmo valor de Flying with, via trigger só no INSERT. Isso vale também para check-in offline e app em cache antigo.
  - Nada reescreve o valor depois disso. Teste 10: editar até o ticket não mexe no retorno.
- **Local de retirada**, derivado e nunca gravado:
  - MAKERS → Hangar 19
  - ASCEND → Customs
  - **OTHER** → nenhum. Não há instrução automática; a interface destaca "needs manual handling" e o VEHICLE_READY é recusado (`RETURN_OTHER_MANUAL`).
- **Backfill** só dos passageiros em custódia (~33):
  - "Other Boat" → OTHER
  - "Delivery at Customs" → ASCEND
  - os demais → igual a Flying with
  - Entregues e arquivados ficam como estão.
- Na interface, o checkbox antigo "Other Boat" e o "Delivery at Customs" dão lugar a **um único** "Returning with". As flags antigas continuam sincronizadas no salvamento (ASCEND → delivery_at_customs; ASCEND ou OTHER → not_returning) para impressão, TV e Dashboard seguirem iguais.

**Mudança no meio da viagem**
- Salvou, toda a lógica futura usa o novo valor na hora: local, botões, página do passageiro (`/p/`, testado ao vivo) e SMS futuros.
- **Nada é enviado automaticamente.**
- Se uma instrução de retirada já tinha saído e ela não bate mais com o retorno atual, o ticket entra em **Needs Review** com "Return changed - passenger may have old instructions". Contam como instrução já enviada:
  - VEHICLE_READY pelo AirValet SMS;
  - Welcome Back antigo enviado pelo iPhone (`welcome_back_sent_at` e `customs_welcome_sent_at`).
- A equipe decide entre duas ações:
  - **"Send updated pickup message"**: a chave de idempotência inclui o local, então a correção sai uma única vez e nunca como duplicata.
  - **"No update needed"**: RPC `airvalet_return_review_ack`, só para ADMIN/MANAGER/OPS.
- Voltar ao retorno original limpa a revisão sozinho. Uma nova mudança depois da revisão abre outra.
- Se nenhuma instrução tinha saído, nada acontece (teste 12).

**Auditoria:** usa o `activity_log` que já existe (field_name/old_value/new_value/changed_by/created_at), escrito pelo mesmo `saveEdits()` dos demais campos. Basta incluir `return_operator: 'Returning with'` em `LOG_FIELD_LABELS`. Nenhuma estrutura nova.

**Testes dos 12 cenários pedidos**
- SQL, 24 checks de cenário: 1 Makers→Makers · 2 Makers→Ascend · 3 Ascend→Ascend · 4 Ascend→Makers · 5 Makers→Other · 6 Ascend→Other · 7 Ascend depois Makers · 8 Makers depois Ascend · 9 Ascend→Other→Makers · 10 valor manual nunca sobrescrito (inclusive editando o ticket) · 11 mudança após instrução → Needs Review, sem mensagem automática, correção liberada, voltar atrás limpa, legado iOS conta · 12 mudança antes de qualquer instrução → sem revisão e sem mensagem.
- Também cobertos no TypeScript (matriz com OTHER, correção pós-mudança) e na integração (envio → mudança → revisão → correção → OTHER recusado).

**Mockups (para aprovação visual)**
- `mockups/sms-inbox/return-change.html`: tela do passageiro com Flying with fixo, Returning with + **Edit**, folha de escolha em 3 opções grandes, banner de revisão, estado "Other" e histórico.
- `index.html` v3: check-in com "Flying with" + "Returning with ▼", a fila Needs Review com o card "Return changed" e a conversa com o aviso.
- Telas em `mockups/sms-inbox/screens/`.

**Alterações extras no `index.html` (frontend, depois da aprovação)**
1. Check-in: "Flying with" (controle atual) + select "Returning with". O padrão acompanha Flying with até a primeira escolha manual.
2. Painel do passageiro: linha "Returning with" com Edit (bottom sheet no iPhone, card no iPad). Salva pelo `saveEdits()` existente, que já registra no activity_log.
3. Remover da interface o checkbox "Other Boat" e o "Delivery at Customs" (as flags passam a ser derivadas no salvamento).
4. Banner e card de Needs Review lendo `airvalet_return_reviews`.

## 11. Regra da chave, exceção Makers→Customs e flags antigas (FINAL, 2026-10-09). Substitui as seções 2, 3 e 10 onde houver conflito

**Auditoria**
- `buildCustomsWelcomeSms()` (`index.html:4537`) decide o texto da chave **só pelo ticket de saída**.
- O caso "chave no pneu" é o de ticket Makers com **"Delivery at Customs"** (`delivery_at_customs`), que é exatamente a exceção operacional Makers→Customs que já existe hoje.
- Nenhum manual documenta o procedimento; só os textos de SMS o codificam.

**Modelo final** (reaproveita o campo existente, mais uma coluna mínima)
- `return_operator` (MAKERS/ASCEND/OTHER) é a fonte de verdade do retorno. A exceção **não** o altera.
- `delivery_at_customs` (existente) é, em retorno MAKERS, a **exceção Customs aprovada**. Quem aprovou e quando fica no `activity_log`, onde o rótulo "Delivery at Customs" já existe.
- `customs_exception_requested_at` (nova, opcional): o passageiro pediu e a equipe ainda não decidiu.
- Pickup efetivo `airvalet_pickup_location()`:
  - MAKERS → Hangar 19, ou Customs se a exceção estiver aprovada
  - ASCEND → Customs (regra)
  - OTHER → manual

**Regra final da chave:** segue a **operação do retorno** e nenhum SMS diz onde a chave está.
| Situação | Quem cuida da Customs | Texto do SMS (VEHICLE_READY, manual) |
|---|---|---|
| Retorno ASCEND | Ascend (chegada de voo privado) | "...ready at Customs. An Ascend team member will personally hand you your key when you arrive." |
| Retorno MAKERS + exceção aprovada | Equipe do valet | "Welcome back! As arranged, your vehicle will be at Customs. When you arrive, reply here or call (954) 352-1010 for your key." (1 segmento, sem local da chave) |
| Retorno MAKERS (padrão) | — | Texto do Hangar 19, sem chave |
| MAKERS com pedido pendente | — | **Recusado** (`CUSTOMS_REQUEST_PENDING`): nenhuma instrução definitiva |
| OTHER | — | Recusado (`RETURN_OTHER_MANUAL`) |

Um local físico de chave, se ainda existir, fica só no contexto interno (Key Copy impresso / nota interna).

**Matriz final**
| Saída → Volta | Pickup | SMS de "pronto" |
|---|---|---|
| Makers → Makers | Hangar 19 | Hangar 19 |
| Makers → Makers + exceção aprovada | Customs (EXCEPTION) | "As arranged... call for your key" |
| Makers → Ascend | Customs (regra) | Ascend entrega a chave em mãos |
| Ascend → Ascend | Customs (regra) | Ascend entrega a chave em mãos (mesmo texto do caso acima) |
| Ascend → Makers | Hangar 19 (a Customs anterior não é herdada) | Hangar 19 |
| qualquer → Other | manual | nenhum |

**Passageiro:** a página nunca oferece "Hangar 19 ou Customs".
- Pedido pendente: mostra Hangar 19 e uma nota neutra ("our team will confirm; until then your pickup stays at Hangar 19").
- Exceção aprovada: mostra Customs como local confirmado.
- Nenhum template menciona Customs para um retorno Makers sem aprovação (testado).

**Semântica final (corrigida em 2026-10-09):**
- `return_operator`: com quem volta. MAKERS → Hangar 19; ASCEND → Customs, **pela regra do próprio retorno**; OTHER → manual.
- `delivery_at_customs`: **só** a exceção Makers aprovada. Fica sempre false com ASCEND ou OTHER (normalizado pelo trigger, rejeitado pela CHECK).
- `customs_exception_requested_at`: pedido Makers pendente. Só com MAKERS e sem aprovação.

**Trigger:**
- Nunca reescreve `return_operator` num UPDATE.
- Saindo de MAKERS: limpa a exceção e o pedido.
- Entrando em MAKERS: começa no Hangar 19, nunca cria exceção sozinho.
- Aprovar limpa o pedido.
- Salvar ou editar outros campos não apaga a exceção.
- "Other Boat" = OTHER.

Testado nos 8 testes "owner" de `tests/sms/sql_tests.sql`, mais a CHECK com o trigger desligado.

**Frontend:** onde o `index.html` lia `delivery_at_customs` como "vai para a Customs" (impressão "DELIVER TO CUSTOMS", TV, Dashboard), passa a ler o pickup efetivo (`airvalet_pickup_location`).

**Backfill corrigido:** "Delivery at Customs" **não** vira ASCEND; em retorno Makers continua como exceção aprovada.

**`index.html` (frontend, depois da aprovação):**
1. Na linha "Pickup" do passageiro: "Hangar 19 (Default) + [Customs exception…]", com as opções "Passenger asked, decide later" / "Approve Customs exception". Quando aprovado, mostra "Customs EXCEPTION · Approved by X" + [Back to Hangar 19]. Grava pelo `saveEdits()`, que já registra a auditoria.
2. `buildCustomsWelcomeSms` e o demo em 919 sem o texto do pneu.
3. O checkbox "Delivery at Customs" sai do check-in; a exceção é decidida no painel do passageiro.

## 12. Integração no `index.html` (2026-10-09, local, NÃO publicado)

**Regra central no cliente:** `utils.js` (`departureOperator`, `returnOperator`, `pickupLocation`, `isCustomsException`, `isCustomsRequestPending`), espelho de `airvalet_pickup_location()`. Um teste de paridade (`tests/pickup-parity.test.mjs`) cobre 13 combinações.

**Pontos migrados para a regra central:**
- ticket do cliente
- Key Copy: "DELIVER TO CUSTOMS", "MAKERS EXCEPTION - APPROVED", "CUSTOMS REQUESTED - PENDING", "RETURNING WITH: OTHER"
- Dashboard: Quick H19 / MOVE TO CUSTOMS; sem lembrete de H19 para Other
- SMS de Welcome com o lembrete do Hangar 19 só quando o pickup é H19
- botão, envio e **Undo** do Welcome Back, por retorno Makers
- Customs Welcome pelo retorno, sem local de chave
- remetente único "Makers Air Valet" em Welcome, Tip e Gratuity
- relatório PDF
- TV: "Delivery to Customs", MOVE TO CUSTOMS/H19, Welcome Back, Other
- indicadores "Other Boat" (= Returning with Other)

**UI:**
- Check-in: "Flying with" (Makers Air / Ascend) e "Returning with" (Makers Air / Ascend / Other). O padrão segue o Flying with só até a primeira escolha manual. Os checkboxes "Other Boat" e "Delivery at Customs" saíram da tela.
- Painel do passageiro:
  - Flying with (do ticket);
  - Returning with ✎ (Save Changes, com auditoria);
  - Pickup "Hangar 19 · Default" com [Customs requested] [Approve Customs exception];
  - "Customs requested — Pending" com [Approve] [Keep Hangar 19];
  - "Customs · Exception approved" com [Back to Hangar 19];
  - "Customs · Ascend return";
  - "Manual — Other".
- Needs Review: banner no painel, lista na aba Messages e badge na aba, com as ações [Send updated pickup message] / [No update needed]. Nada é enviado automaticamente.

**Migration extra:** `20261010_tv_mode_rpc_return_operator.sql` (+ rollback idêntico à produção). O RPC da TV passa a devolver `return_operator` e `customs_exception_requested_at`.

**Ordem obrigatória de deploy:** migrations ANTES do frontend. O app novo grava `return_operator`; com o banco antigo, o check-in falharia. O app antigo continua funcionando contra o banco novo (testado).

**Observação (comportamento já existente, não alterado):** na TV, o lembrete MOVE TO CUSTOMS/H19 só aparece quando o carro **não** está no Hangar 19 (`tvNeedsH19Move`). Um carro já no H19 cujo retorno virou Customs não recebe lembrete de levar para a Customs. Decisão do owner.

## 13. MOVE centralizado (TV + Dashboard), 2026-10-09, local

`requiredMove(r)` em `utils.js` = localização atual (campo `loc` existente) × `pickupLocation(r)`. Resultado: MOVE_TO_HANGAR_19, MOVE_TO_CUSTOMS ou nada. Other → nada; pedido pendente → alvo Hangar 19; entregue, arquivado ou offline → nada.

Sem campo novo: `CUSTOMS` passa a ser um valor válido de `loc` (Move Hangar, edição de local, contagem). Relatórios e o painel de hangares da TV não mudaram.

TV (badge), Dashboard ("→ H19" / "→ Customs") e o lote "All H19" só renderizam `requiredMove`. O lote não move mais para o H19 carros que vão para a Customs ou com retorno Other.

8 cenários verificados no teste de regra do cliente e no app real (TV + Dashboard).
