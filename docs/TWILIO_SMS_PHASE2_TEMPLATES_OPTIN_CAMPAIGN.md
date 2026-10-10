# AirValet × Twilio — Fase 2: templates, READY, opt-in, Campaign A2P

Status: **rascunho para aprovação do owner** (2026-10-09). ⚠ Identidade, templates, Campaign e custo foram **substituídos por `TWILIO_SMS_PHASE3_PLAN.md`**. Nada aqui foi submetido, pago, publicado ou enviado.
Arquitetura aprovada: conta Twilio da Farber; FarberOS intocado; AirValet com número próprio, Messaging Service "AirValet SMS", Campaign própria, webhooks próprios, inbox no AirValet.

---

## 1. Auditoria das 13 mensagens atuais (`SMS_MESSAGE_TYPES` em `index.html`)

Hoje **todas** são manuais: o AirValet monta o texto e abre o app Mensagens do iPhone; o atendente aperta Enviar.

| # | Tipo atual | Evento que dispara hoje | Texto atual (resumo fiel) | Ainda faz sentido? | Texto proposto (Twilio) | Opt-in/opt-out no texto? | Auto ou manual (proposta) |
|---|---|---|---|---|---|---|---|
| 1 | WELCOME_CONFIRMED | Check-in → "Save + Review SMS" | "Welcome to Makers Air Valet! Your vehicle has been successfully checked in. Ticket #: X. Please keep this ticket number… If your return date or arrival time changes from {ret}, please reply… Thank you and safe travels! Reminder: After clearing Customs, please return to Hangar 19 with your pilots…" | Sim, é a mensagem principal | **CHECK_IN**: "Makers Air Valet: Welcome! Your vehicle is checked in. Ticket #{ticket}. ⏎ If your return date or arrival time changes from {ret}, reply to this message so your vehicle is ready when you arrive. ⏎ Reminder: after clearing Customs, return to Hangar 19 with your pilots to pick up your vehicle. ⏎ Safe travels! ⏎ Msg freq varies. Msg&data rates may apply. Reply HELP for help, STOP to opt out." | **Sim**: é a 1ª mensagem/confirmação de opt-in | **Automático** ao salvar o check-in com consentimento ("Save + Text"); sem preview no Messages |
| 2 | WELCOME_NO_DATE | Idem, sem data de retorno | Igual + "We currently do not have a return date on file… please reply with your expected return date and arrival time…" | Sim | Variante do CHECK_IN: "We don't have a return date on file yet. Once your plans are set, reply with your return date and arrival time so your vehicle is ready when you arrive." | Sim (mesmo rodapé) | Automático (idem) |
| 3 | WELCOME_NOT_RETURNING | Idem, "não volta com Makers Air" | Igual + "NOTE: You informed us that you will not be returning with Makers Air. If this information changes, please reply…" (sem lembrete H19) | Sim | Variante: "Note: you told us you won't be returning with Makers Air. If that changes, reply to this message." (sem H19) | Sim | Automático (idem) |
| 4 | RETURN_CONFIRMATION | Painel do passageiro com data aproximada | "Hi {NOME COMPLETO EM CAIXA ALTA}, this is Makers Air Valet. We have your {car} parked with us. Can you confirm your return date? Thank you!" | Sim | **RETURN_CONFIRMATION**: "Makers Air Valet: Hi {FirstName}, we have your {car} parked with us. Can you confirm your return date and arrival time? Just reply to this message. Thank you!" | Não precisa (já houve opt-in) | **Manual** (botão); máx. 1×/dia por passageiro |
| 5 | TASK_CONFIRMATION | Aba Tasks → "Send Text" | "Hi! This is Makers Air Valet. We are reaching out to confirm your return date…" | Mesmo propósito do #4 | **Unificar com RETURN_CONFIRMATION** (mesmo texto); o estado "sent" passa a ser persistido (hoje se perde no reload) | Não | Manual |
| 6 | HANGAR19_WELCOME_BACK | Dashboard → botão "Welcome Back" (urgente 30 min antes do ETA) | "Welcome back! After clearing U.S. Customs, please remain with your pilots and return to Makers Air at Hangar 19, where your vehicle will be ready and waiting… Please do not exit through the U.S. Customs terminal… We hope you had a wonderful trip…" | Sim: **é o "vehicle ready"** | **VEHICLE_READY (Hangar 19)**: "Makers Air Valet: Welcome back! After clearing U.S. Customs, please stay with your pilots and return to Makers Air at Hangar 19, where your vehicle will be ready and waiting. Please don't exit through the U.S. Customs terminal, as there is no transportation back to Makers Air from there." | Não | **Manual** (botão continua; timing depende do voo) |
| 7 | CUSTOMS_WELCOME_MAKERS | Modal Customs / Welcome Back com "Delivery at Customs" | "Welcome back! Your vehicle is ready at Customs. The key is located on the driver's-side tire. Thank you for choosing Makers Air Valet." | Sim (⚠ local da chave por SMS: decisão sua) | **VEHICLE_READY (Customs/Makers)**: "Makers Air Valet: Welcome back! Your vehicle is ready at Customs. The key is on the driver's-side tire. Thank you for choosing Makers Air Valet." | Não | Manual |
| 8 | CUSTOMS_WELCOME_ASCEND | Modal Customs (Ascend) | "Welcome back! Your vehicle is ready at Customs. An Ascend team member will personally provide your key upon your arrival. Thank you for choosing Ascend Valet." | Sim | **VEHICLE_READY (Customs/Ascend)**: "Ascend Valet: Welcome back! Your vehicle is ready at Customs. An Ascend team member will personally hand you your key when you arrive." | Não | Manual |
| 9 | CUSTOMS_GRATUITY | Modal Customs / lembrete de 60 s (só depois do Welcome Back) | "Thank you for choosing {brand}. We truly appreciate your business. If we exceeded your expectations, here is our discretionary valet team gratuity link: https://buy.stripe.com/…" | Sim | **CUSTOMS_GRATUITY**: "{Brand}: Thank you for choosing us, we truly appreciate your business. If we exceeded your expectations, here is our optional valet team gratuity link: {link}" | Não | Manual (lembrete continua visual). **Servidor recusa antes do Welcome Back** |
| 10 | TIP_YES | Entrega Normal/Lockbox com gorjeta recebida | "Your vehicle has been delivered successfully. Thank you for choosing {brand}. We truly appreciate your business and your generosity…" | Sim | **VEHICLE_DELIVERED (TIP_YES)**: "{Brand}: Your vehicle has been delivered. Thank you for your generosity, it was our pleasure. We look forward to welcoming you on your next trip!" | Não | **Automático** ao registrar a entrega (hoje já é parte da ação de entregar) |
| 11 | TIP_NO | Entrega Normal/Lockbox sem gorjeta | "Your vehicle has been delivered successfully… If you were happy… leave a gratuity… link" | Sim | **VEHICLE_DELIVERED (TIP_NO)**: "{Brand}: Your vehicle has been delivered. Thank you for choosing us! If you'd like to leave an optional gratuity for the valet team: {link}" | Não | Automático (idem). **Customs nunca recebe** (servidor recusa) |
| 12 | GENERIC | Botão "💬 TEXT" (abre Mensagens vazio) | (sem texto) | Vira conversa | **REPLY** pelo inbox (texto livre do funcionário) | Não | Manual |
| 13 | FREEFORM | Compose livre (modo mock) | (texto digitado) | Vira conversa | **REPLY** (ou CUSTOM_OPERATIONAL, só ADMIN/MANAGER) | Não | Manual |

Mudanças comuns a todos (motivo):
- **Prefixo da marca** ("Makers Air Valet:" / "Ascend Valet:"): exigência das operadoras de identificar o remetente.
- **Primeiro nome em vez de nome completo em caixa alta**: o banco guarda nome em CAPS.
- **Só caracteres GSM-7** (sem travessão "—" nem aspas curvas): um único caractere fora do GSM-7 troca a codificação para UCS-2 e **triplica o custo** por segmento. Há teste automatizado para isso.
- **Link de gorjeta não fica mais fixo no código**: vem do secret `AIRVALET_GRATUITY_URL`. ⚠ Falta confirmar **de qual conta Stripe** é o link `buy.stripe.com/8x2…` (memória anterior: Stripe do AirValet = Matt Solutions; agora o operador é a Farber Parking).
- Custo aproximado em segmentos: CHECK_IN ~3–4; os demais 1–2.

## 2. "VEHICLE READY": precisa de status novo?

**Não.** O fluxo atual já tem o momento "carro pronto":
- **Makers Air (normal)**: o botão *Welcome Back* do Dashboard fica urgente 30 min antes do ETA do voo de volta (`WELCOME_BACK_REMINDER_MINUTES`) e o texto diz "your vehicle will be ready and waiting" em Hangar 19.
- **Customs (Makers/Ascend)**: o *Customs Welcome Back* diz "Your vehicle is ready at Customs".
- O rastreamento de aeronaves já grava `landed_at` (status LANDED na TV).

Proposta: `VEHICLE_READY` = esses mesmos dois envios, **manuais**. Opcional numa fase futura: quando a aeronave tiver `landed_at` e o Welcome Back ainda não foi enviado, destacar o botão ("Landed X min ago, send Welcome Back"). Isso é **sugestão para o atendente, nunca envio automático**, porque a hora de liberação na Customs varia.

## 3. Opt-in no check-in (mockup: `mockups/sms-inbox/`, telas 3 e 4)

- Novo bloco no formulário "New Entry": checkbox **desmarcada**, "Passenger agreed to receive text updates", com a pergunta que o atendente faz ("Can we text you updates about your vehicle at this number?") e o link "Show disclosure to passenger".
- **Disclosure (versão `airvalet-optin-v1`)**: "By agreeing, you'll receive text messages from Makers Air Valet (operated by Farber Parking) about this valet visit: check-in confirmation, return-date questions, vehicle-ready and delivery updates, and replies from our team. Message frequency varies. Msg & data rates may apply. Reply STOP to opt out, HELP for help. Consent is not a condition of service. Privacy Policy: airvalet.farberos.com/privacy.html · Terms: airvalet.farberos.com/terms.html"
- Sem consentimento: **nada trava**. "Save Only" e "Save + Print" funcionam como hoje; só "Save + Text" fica desabilitado.
- Com consentimento: a RPC `airvalet_sms_record_consent(passenger_id, 'airvalet-optin-v1')` grava telefone (tirado do cadastro), hora, quem registrou e versão do texto. O CHECK_IN sai na sequência e funciona como confirmação de opt-in, porque já leva o rodapé STOP/HELP.
- Tela opcional "virar o iPad" com Sim/Não para o passageiro (tela 4). Também serve de prova visual para a revisão da Campaign.
- Check-in **offline**: o consentimento vai junto no registro offline e é gravado na sincronização. O SMS sai só depois de sincronizar.
- **STOP** (o Advanced Opt-Out da Twilio responde automaticamente) → consentimento revogado no AirValet. O inbox mostra "OPTED OUT" e bloqueia a resposta. **START** reativa.
- **HELP** → resposta automática da Twilio com o contato.
- Respostas automáticas propostas (Advanced Opt-Out do serviço "AirValet SMS"; ainda **não configuradas**, aguardam aprovação):
  - STOP: "Makers Air Valet (Farber Parking): You're unsubscribed and won't receive more texts. Reply START to resubscribe."
  - START: "Makers Air Valet (Farber Parking): You're resubscribed to valet updates. Msg freq varies. Msg&data rates may apply. Reply HELP for help, STOP to opt out."
  - HELP: "Makers Air Valet (Farber Parking): For valet help call (561) 774-0494 or email info@farberparking.com. Msg&data rates may apply. Reply STOP to opt out."
- Páginas públicas (prontas no worktree, **não publicadas**): `sms.html` (programa + reprodução do opt-in), `privacy.html` (com o texto padrão CTIA de não compartilhamento), `terms.html`. Precisam estar **no ar antes de submeter a Campaign**, porque o revisor abre os links. Isso exige deploy (pede seu GO).

## 4. Inbox (mockup: `mockups/sms-inbox/`, telas 1 e 2)

Fica na aba "Messages" que já existe e hoje está desativada ("Inbound & Replies — Coming with Twilio integration").
- **Lista de conversas por passageiro** (`passenger_id`): nome, ticket, última mensagem, horário, badge de não lidas, tags (ASCEND, OPTED OUT). Badge total no menu lateral.
- **Thread**: histórico inbound/outbound, horário, tipo (CHECK-IN, VEHICLE READY, Reply…), funcionário que enviou (`sent_by_name`), status em tempo real (Queued → Sent → Delivered / Failed com código), e nota de falha sem afetar o ticket.
- **Resposta**: campo com contador de caracteres e segmentos, respostas rápidas, botão "Send". **Proteção contra duplicidade**: o botão trava no primeiro toque e cada mensagem tem um compose id (`reply:<uuid>`) que o servidor deduplica (testado).
- **STOP**: barra vermelha e composer bloqueado.
- **Needs review**: inbound `ambiguous` (telefone compartilhado por 2+ passageiros ativos) ou `unmatched`, com botões "Link to" só para passageiros cujo telefone é o do remetente (o banco recusa o resto).
- "Read": marca como lida ao abrir a conversa (`airvalet_sms_mark_read`).
- Identidade interna = `passenger_id`; o ticket aparece só como rótulo.

## 5. Draft da nova A2P Campaign (Brand existente "Farber Parking", LVS, Approved)

| Campo | Valor proposto |
|---|---|
| Messaging Service | **AirValet SMS** (`MG9f8e…281f`), criado em 2026-10-09, sem senders |
| Use case | **Customer Care** (mesmo tipo do FarberOS; standard, $10/mês). Alternativa: "Low Volume Mixed" ($1,50/mês, até 2.000 segmentos/dia na T-Mobile) |
| Campaign description | "Farber Parking operates the valet service for Makers Air and Ascend private-aviation passengers at Fort Lauderdale Executive Airport (FXE) using its AirValet operations system. We send transactional customer-care SMS to passengers who opt in at vehicle check-in: check-in confirmation with ticket number, questions about return date and arrival time, vehicle-ready and pickup instructions when they return, delivery confirmation with an optional valet-team gratuity link, and two-way replies from our valet staff to questions the passenger texts us. No marketing or promotional content. Recipients can reply STOP to opt out and HELP for help." |
| Sample 1 | "Makers Air Valet: Welcome! Your vehicle is checked in. Ticket #0714-3. If your return date or arrival time changes from 10/15, reply to this message so your vehicle is ready when you arrive. Safe travels! Msg freq varies. Msg&data rates may apply. Reply HELP for help, STOP to opt out." |
| Sample 2 | "Makers Air Valet: Hi Ana, we have your Escalade parked with us. Can you confirm your return date and arrival time? Just reply to this message. Thank you!" |
| Sample 3 | "Makers Air Valet: Welcome back! After clearing U.S. Customs, please stay with your pilots and return to Makers Air at Hangar 19, where your vehicle will be ready and waiting." |
| Sample 4 | "Ascend Valet: Welcome back! Your vehicle is ready at Customs. An Ascend team member will personally hand you your key when you arrive." |
| Sample 5 | "Makers Air Valet: Your vehicle has been delivered. Thank you for choosing us! If you'd like to leave an optional gratuity for the valet team: https://… (link final a confirmar)" |
| Message contents | Embedded links: **sim** (gratuity, Stripe). Phone numbers: não. Age-gated: não. Direct lending: não. Affiliate marketing: não |
| How do end-users consent | "Passengers opt in verbally in person at vehicle check-in. The attendant asks whether we may text updates about the vehicle, shows the disclosure on the AirValet iPad, and ticks an unchecked consent box only if the passenger agrees. The disclosure names Makers Air Valet (operated by Farber Parking), the message types, says frequency varies, msg & data rates may apply, Reply STOP to opt out and HELP for help, that consent is not a condition of service, and links the Privacy Policy and Terms. Consent (time, staff member, disclosure version) is stored server-side; the first message confirms enrollment with STOP/HELP language. Public reproduction of the opt-in: https://airvalet.farberos.com/sms.html · Privacy: https://airvalet.farberos.com/privacy.html · Terms: https://airvalet.farberos.com/terms.html" |
| Opt-in keywords / message | Não há opt-in por keyword (só START para reativar) |
| Opt-out / Help | Advanced Opt-Out com os textos da seção 3 |
| Volume esperado | ~10–40 passageiros/dia × 2–5 mensagens + conversas (muito abaixo de 2.000/dia) |

Pontos que **você precisa confirmar** antes de submeter:
1. A Ascend Valet também é operada pela Farber Parking (a Campaign cita as duas marcas).
2. Telefone e e-mail de HELP: uso os da Farber, (561) 774-0494 e info@farberparking.com, ou um contato do valet da Makers Air?
3. O link de gorjeta (conta Stripe correta).
4. Mandar o local da chave por SMS na Customs ("driver's-side tire").
5. Use case: Customer Care ($10/mês, aprovado) ou Low Volume Mixed ($1,50/mês).

## 6. Número

- Local 10DLC, SMS+MMS. **Preço visto no console em 2026-10-09: $1,15/mês.**
- Preferência por código de área do sul da Flórida (954/754/305/786). A busca por "954" no console novo não retornou estoque. Na compra eu repito a busca e mostro as opções antes.
- Depois de comprar: adicionar como sender **somente** do "AirValet SMS". O inbound vai pelo webhook do serviço (já configurado). Nada muda no número/serviço do FarberOS.

## 7. Estado na Twilio (2026-10-09)

| Recurso | Estado |
|---|---|
| FarberOS: número +1 561-560-38xx, serviço MG4022…66d0, Campaign CMa222…, Brand | **Inalterados** (reverificado: inbound "defer to sender", callback vazio, validity 36000, 1 sender) |
| **AirValet SMS** `MG9f8e2914abd018e27cad5d4881c3281f` | **Criado** (grátis). Use case "Engage in a discussion". Inbound "Send a webhook" → `https://sfewtirvqhrpanwhbchd.supabase.co/functions/v1/twilio-inbound` (POST). Status callback → `…/functions/v1/twilio-status-callback`. Validity period 3600 s (mensagem operacional atrasada mais de 1 h não sai). **Sem número, sem Campaign.** As funções ainda não estão publicadas; sem sender, nada chama esses URLs |
| Reversão | Excluir o serviço "AirValet SMS" (vazio) |

## 8. O que falta e exige seu GO (última etapa, nesta ordem)

1. **Deploy** das páginas `sms.html`, `privacy.html`, `terms.html` (só estáticas; o app não muda).
2. **Comprar o número** (mostro número e preço final na tela antes de clicar).
3. **Submeter a Campaign** no "AirValet SMS" (mostro o valor da tela antes de clicar; esperado $15 de vetting + $10/mês). A aprovação da operadora leva dias.
4. **Migration em produção** (`20261009_create_airvalet_sms_messages.sql`; aditiva, com rollback).
5. **Secrets em produção**: você digita os valores via `supabase secrets set` (eu não digito chaves): API Key restrita (criada na hora), Auth Token, Messaging Service SID, `AIRVALET_SMS_MODE=disabled`.
6. **Deploy das 3 Edge Functions** (`send-sms`; `twilio-status-callback` e `twilio-inbound` com `--no-verify-jwt`).
7. **Frontend** (inbox + opt-in no `index.html`), depois da sua aprovação do mockup, com screenshots e um commit separado.
8. **Primeiro SMS real**: modo `allowlist` com um número seu, depois que a Campaign for aprovada.
