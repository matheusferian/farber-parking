# AirValet — Migração de SMS Nativo (`sms:`) para Twilio Programmable Messaging
### Auditoria técnica, arquitetura proposta e plano de implementação

**Status deste documento:** auditoria e proposta arquitetural. Reflete o estado do código em 2026-08-04 (véspera da implementação da Fase 1/2).
**Aprovação recebida:** somente Fase 1 (abstração do provider) e Fase 2 (modo `mock_twilio`) — ver `PROJECT.md` → Development Decisions para o registro da decisão e `docs/TWILIO_MIGRATION_PHASE1-2_IMPLEMENTATION.md` para o relatório de implementação.
**Não autorizado nesta etapa:** conta/números Twilio reais, Edge Functions reais, migrations, alteração de banco de produção, secrets, remoção dos links `sms:`, mensagens automáticas, bulk send real, webhook inbound real.

Projeto analisado: `/Users/matheusferian/Documents/FARBERMAKERS` ("AirValet" / Makers Air Valet / Ascend Valet).
Arquivos lidos integralmente para esta auditoria: `index.html` (8.058 linhas), `styles.css` (1.115 linhas), `utils.js` (94 linhas), `PROJECT.md`, `CLAUDE.md`, e as 8 migrations em `migrations/`.

---

## 1. Resumo do sistema atual

AirValet é uma SPA estática (HTML+CSS+JS, sem build, sem framework) que acessa o Supabase diretamente do navegador com uma chave `anon` pública (`index.html:1048-1053`), autenticada por login Supabase Auth (email/senha, `index.html:4353-4393`), cujo `access_token` é usado como Bearer em todas as chamadas REST.

Toda a comunicação por SMS hoje segue o mesmo padrão:

```js
window.open('sms:' + cleanPhone + '&body=' + encodeURIComponent(smsBody), '_self');
```

Isso abre o app nativo Messages do iOS com o corpo da mensagem pré-preenchido. **O sistema nunca envia nada por conta própria** — o atendente precisa apertar "Send" manualmente. Antes da Fase 1/2, não existia nenhuma integração com um provedor de SMS (Twilio ou outro); não havia tabela de mensagens, não havia webhook, não havia inbox.

O app é usado por atendentes em iPads no pátio (FBO privado), então qualquer mudança neste fluxo tem impacto operacional direto em uma operação ao vivo de entrega de veículos.

---

## 2. Inventário completo dos fluxos de SMS (estado pré-Fase 1)

| # | Função / local | Linha (`index.html`) | Fluxo | Trigger | Template | Marca sent-flag? | Alteração futura necessária | Risco de regressão |
|---|---|---|---|---|---|---|---|---|
| 1 | `buildWelcomeSms(r)` | 2763–2779 | Welcome (normal / no-date / not-returning — **uma única função com 3 ramificações internas**, não 3 funções separadas) | Check-in ("Save + Text" / "Save + Print + Text") | Branch por `r.ret` (tem data / não tem) e `r.not_returning_with_makers_air`; branch de marca por `isAscend(r)`; para não-Ascend/não-not-returning adiciona lembrete de Hangar 19 | Não | Extrair para `provider.sendMessage({template:'welcome', vars})`; preservar as 3 ramificações internas exatamente como estão | **Alto** — é a função mais central; qualquer refactor errado quebra os 3 sub-fluxos ao mesmo tempo |
| 2 | `sendWelcomeSms(id)` | 2781–2786 | Welcome | Botão "💬 Welcome" no painel de detalhe (linha 3399) | usa `buildWelcomeSms` | Não | Trocar `window.open('sms:...)` pela chamada ao provider | Médio |
| 3 | `saveEntry()` bloco SMS | 3364–3368 | Welcome | "Save + Text" / "Save + Print + Text" no check-in | usa `buildWelcomeSms` (chamado com objeto parcial montado inline, não com `r` completo) | Não | Mesmo ponto de troca; atenção ao objeto parcial (`{ticket, ret, not_returning_with_makers_air, loc}` — não é o registro salvo) | Alto — é o caminho mais usado do app |
| 4 | `buildWelcomeBackSms()` | 2799–2801 | Hangar 19 Welcome Back (Makers Air, não-Customs) | Manual, botão no card do Dashboard | Texto fixo (não varia por Ascend — função nunca é chamada para Ascend) | `welcome_back_sent_at` | Extrair para template `HANGAR19_WELCOME_BACK` | Médio |
| 5 | `welcomeBackButtonHtml(r)` | 2803–2822 | Hangar 19 Welcome Back | Renderização de card | — | — | **Preservar as 2 guardas**: `if(isAscend(r)) return '';` e `if(r.delivery_type==='CUSTOMS') return '';` — são a separação crítica entre este fluxo e o Customs Welcome Back | **Alto** — se essas 2 linhas forem removidas/alteradas, Ascend ou Customs passam a receber a mensagem errada |
| 6 | `sendWelcomeBackSms(id)` | 2824–2851 | Hangar 19 Welcome Back | Botão "Welcome Back" | `buildWelcomeBackSms` | grava `welcome_back_sent_at` (otimista + rollback em erro) | Trocar `sms:` por chamada ao provider; manter update otimista + rollback | Alto |
| 7 | `undoWelcomeBackSms(id)` | 2853–2866 | Hangar 19 Welcome Back | Botão "Undo" | — | limpa `welcome_back_sent_at` | Sem envio de SMS — apenas ajuste de estado. Manter | Baixo |
| 8 | `buildCustomsWelcomeSms(r)` | 2905–2910 | Customs Welcome Back | Painel Customs Communication | Branch por `isAscend(r)` (texto de chave diferente) | Não | Extrair para `CUSTOMS_WELCOME_MAKERS` / `CUSTOMS_WELCOME_ASCEND` | Alto |
| 9 | `buildCustomsGratuitySms(r)` | 2911–2914 | Customs Gratuity | Painel Customs Communication | Branch de marca; contém link Stripe fixo | Não | Extrair para `CUSTOMS_GRATUITY` | **Crítico** — contém o link de pagamento; nunca deve ser reordenado antes do Welcome Back |
| 10 | `isCustomsGratuityReminderDue(r,now)` | linha varia (usa `isCustomsCommEligible` como um dos checks) | Gate do **lembrete automático** de Gratuity | Usado por `getCustomsDueRecords` (lembrete visual a cada 60s) | — | — | Contém `if(r.customs_welcome_sent!==true) return false;` — mas isso só gate o **lembrete automático**, não o botão manual "Send Gratuity" (ver item #13, correção abaixo, achado durante os testes da Fase 1/2) | **Crítico** — ver Risco R1, atualizado |
| 11 | `sendCustomsWelcomeSms(id)` | 3080–3104 | Customs Welcome Back | Botão "Send Welcome Back" no modal | `buildCustomsWelcomeSms` | grava `customs_welcome_sent`/`_at` | Trocar transporte; manter guarda de confirm() para reenvio | Alto |
| 12 | `undoCustomsWelcomeSms(id)` | 3105–3117 | Customs Welcome Back | Botão "Undo" | — | limpa flags | Manter | Baixo |
| 13 | `sendCustomsGratuitySms(id)` | 3120–3147 | Customs Gratuity | Botão "Send Gratuity" (modal ou fila de lembretes) | `buildCustomsGratuitySms` | grava `customs_gratuity_sent`/`_at` | **Correção (achado durante os testes automatizados da Fase 1/2):** ao contrário do que a versão original desta auditoria afirmava, o botão "Send Gratuity" em `renderCustomsCommModal` **é renderizado e fica clicável mesmo quando `customs_welcome_sent` é `false`** — só o texto de apoio abaixo do botão muda ("Reminder will be scheduled after Welcome Back is sent" vs. o horário do lembrete). Não existe hoje **nenhum** bloqueio de UI real impedindo o clique manual antes do Welcome Back — o único gate existente (`isCustomsGratuityReminderDue`) protege apenas o lembrete automático, não o botão manual. Confirmado por leitura direta do código; nenhuma mudança de comportamento foi feita no Fase 1/2 (fora do escopo aprovado) — apenas documentado e comentado no código-fonte | **Crítico, mais severo do que originalmente documentado** — o gap está totalmente aberto hoje, não é uma condição de borda. Uma Edge Function `send-sms` (Fase 4) precisa **revalidar essa regra no servidor**, não confiar no frontend |
| 14 | `undoCustomsGratuitySms(id)` | 3149–3161 | Customs Gratuity | Botão "Undo" | — | limpa flags (inclusive `dismissed`) | Manter | Baixo |
| 15 | `dismissCustomsGratuityReminder(id)` | 3164–3175 | Customs Gratuity | Fila de lembretes ("Dismiss Passenger") | — | grava `customs_gratuity_dismissed` | Deve continuar cancelando qualquer scheduled-send equivalente (Fase 8) | Médio |
| 16 | `undoDeliverToday()` reset Customs flags | 3639–3653 | Customs (reset) | "Undo Deliver" quando `delivery_type==='CUSTOMS'` | — | zera os 5 flags de Customs | Deve também cancelar/remover jobs agendados associados a este passenger_id (Fase 8) | Alto — se esquecido, um SMS agendado pode disparar para um delivery que foi desfeito |
| 17 | Link "💬 TEXT" genérico | 3398 | Genérico | Painel de detalhe, ao lado de "📞 CALL" | Nenhum (`sms:` sem `&body=`, abre Messages vazio) | Não | **Mantido como anchor `sms:` puro na Fase 1/2** — ver justificativa na seção "Pontos `sms:` restantes" do relatório de implementação | Baixo |
| 18 | Link "Send Confirmation Text" | 3438 | Confirmação de data aproximada | Painel de detalhe, quando registro tem data aproximada | Template **inline no HTML** (não usava função `build*Sms` — string montada direto no template literal) | Não | Extraído na Fase 1 para `buildReturnDateConfirmationSms(r)` + `RETURN_CONFIRMATION` | Médio — era o único template fora do padrão `buildXxxSms()` |
| 19 | `buildTipSms(r, tipReceived)` | 3562–3568 | Tip SMS Yes/No | Pós-entrega (Normal/Lockbox) | Branch por `tipReceived` (Yes = sem Stripe link; No = com Stripe link) e por `isAscend(r)` | Não | Extrair para `TIP_YES` / `TIP_NO` | Alto |
| 20 | `openTipSms(id, tipReceived)` | 3569–3578 | Tip SMS | Chamado por `deliverWithTip` | `buildTipSms` | Não | Trocar transporte; manter validação de telefone (`digits.length<10`) | Alto |
| 21 | `deliverWithTip()` — exclusão Customs | 3502–3559, especificamente 3549–3557 | **Roteamento crítico** | Após salvar entrega | — | — | `if(isCustoms){ openCustomsCommModal(...) } else { openTipSms(...) }` — **esta é a linha que impede duplicar o pedido de gratuity em Customs**. Preservada byte a byte na Fase 1/2 | **Crítico** — qualquer regressão aqui duplica a cobrança de gorjeta para entregas Customs |
| 22 | Tasks queue SMS | 5657–5658, 5677 | Confirmação de retorno (Tasks) | Botão "Send Text" na aba Tasks | Template inline (`var smsMsg = 'Hi! This is Makers Air Valet...'`) | `taskStatus[r.id]='sent'` (**em memória, não persistido no banco** — se recarregar a página, o estado "sent" se perde) | Extraído na Fase 1 para `buildTaskConfirmationSms(r)` + `TASK_CONFIRMATION`; limitação de persistência em memória **preservada intencionalmente** (fora de escopo aprovado) | Médio |
| 23 | `getWelcomeBackEta(r)` / urgência | 2789–2797, 2868–2879 | Hangar 19 (auxiliar) | Recalculado a cada 60s (`setInterval`) | — | — | Não envia SMS; usado só para colorir o botão "urgent". Sem impacto na migração | Baixo |
| 24 | Lembrete automático Customs Gratuity | 2967–2996, 3185–3277 | Customs Gratuity (auxiliar) | `setInterval` a cada 60s, `checkCustomsGratuityReminders()` | — | — | É um **lembrete visual para o atendente**, não um envio automático. Migrar para agendamento real via Twilio muda a semântica — requer aprovação explícita (Fase 8) | Alto — mudança de semântica, não só de transporte |

**Padrão de telefone usado em todos os pontos:** `r.phone.replace(/\D/g,'')` — remove tudo que não é dígito, sem normalização E.164 (`+1`), sem validação de tamanho consistente (só o Tip SMS valida `digits.length<10`). A Fase 1 adiciona um normalizador E.164 (`normalizePhoneE164` em `utils.js`) **sem** fazer o modo `native` depender dele, para não alterar o comportamento atual.

---

## 3. Riscos identificados

| ID | Risco | Onde | Severidade |
|---|---|---|---|
| R1 | ~~Regra "Gratuity nunca antes de Welcome Back" não tinha nenhum bloqueio real~~ — **CORRIGIDO na Fase Hardening (2026-08-04).** `sendCustomsGratuitySms` agora recusa programaticamente (`if(r.customs_welcome_sent!==true){ showMsg('Send the Customs Welcome Back message first.', true); return; }`) como primeira linha da função — refusa mesmo se chamada diretamente pelo console, sem passar pela UI. `renderCustomsCommModal` também desabilita o botão "Send Gratuity" (`disabled` + `title`) e mostra a mesma mensagem como subtexto enquanto `customs_welcome_sent!==true`. Coberto por 7 testes automatizados (Level 4, incluindo chamada direta bypassando a UI). Nota: este é ainda um bloqueio **client-side** — a revalidação server-side (Edge Function) continua sendo trabalho da Fase 4, não aprovada | `index.html` — `sendCustomsGratuitySms` (guarda no topo da função), `renderCustomsCommModal` (botão desabilitado) | Mitigado no client; Fase 4 (server-side) continua pendente de aprovação |
| R2 | Exclusão "Customs não recebe Tip SMS genérico" está numa única ramificação de `if/else` (item #21) sem teste automatizado — fácil de quebrar num refactor futuro | `index.html:3549-3557` | Crítico |
| R3 | Detecção de Ascend é 100% baseada no prefixo `A-` do ticket (`isAscend()`, `index.html:2374`) — qualquer normalização futura de formato de ticket quebra silenciosamente branding em todos os templates | `index.html:2374` | Alto |
| R4 | Telefones não são normalizados para E.164 em nenhum ponto de envio real — Twilio rejeitaria números mal formatados quando a Fase 4 for aprovada | Todos os pontos de `sms:` | Alto |
| R5 | `taskStatus` (Tasks queue) é estado em memória, não persistido | `index.html:5638` | Médio |
| R6 | Chave `anon` do Supabase já é pública no frontend (`index.html:1048-1049`) — aceitável pelo modelo RLS do Supabase, mas reforça que credenciais Twilio **não podem seguir o mesmo padrão** | `index.html:1048-1049` | Crítico (regra do usuário) |
| R7 | Lembrete automático de Gratuity é hoje só uma notificação visual — migrar para agendamento real do lado do servidor muda esse comportamento; mudança de semântica que precisa aprovação explícita | `index.html:3185-3277` | Médio |
| R8 | `undoDeliverToday()` zera os flags de Customs mas não cancelaria um SMS *já agendado* sem uma tabela de jobs (Fase 8, não aprovada) | `index.html:3639-3653` | Alto (só relevante após Fase 8) |
| R9 *(identificado durante a Fase 1)* | Os flags `welcome_back_sent_at`, `customs_welcome_sent(_at)`, `customs_gratuity_sent(_at)` são gravados no momento em que o **composer é aberto**, não quando a mensagem é confirmadamente enviada pelo atendente. Ver seção "Semântica dos flags" no relatório de implementação para o detalhamento completo, campo a campo | `index.html:2841-2844`, `3094-3097`, `3134-3139` | Médio — comportamento pré-existente, documentado e preservado no modo `native`; o modo `mock_twilio` já implementa a semântica correta (só grava no sucesso simulado) como demonstração de como isso deve funcionar quando a Fase 4 (Twilio real com status callback) for aprovada |

---

## 4. Arquitetura proposta (Fases 3+, não aprovadas)

```
┌─────────────────────┐        ┌──────────────────────────┐        ┌────────────────────────┐
│   AirValet Frontend  │  JWT   │   Supabase Edge Function  │  API   │  Twilio Programmable    │
│  (index.html no      │──────▶ │        send-sms           │──────▶ │  Messaging               │
│   iPad do atendente)  │  auth  │  (valida sessão + regras  │  key   │                          │
└─────────────────────┘        │   de negócio no servidor) │        └────────────────────────┘
                                └──────────────┬─────────────┘
                                               │ grava
                                               ▼
                                ┌──────────────────────────┐
                                │  sms_messages / sms_      │
                                │  conversations (Postgres) │
                                └──────────────▲─────────────┘
                                               │ grava
                                ┌──────────────┴─────────────┐
                                │ Supabase Edge Function      │
                                │ twilio-status-callback      │◀── Twilio (status: sent/delivered/failed)
                                └──────────────────────────────┘

┌────────────────────────┐   webhook   ┌──────────────────────────┐
│ Passageiro responde SMS │───────────▶ │ twilio-inbound-webhook    │──▶ sms_messages (direction=inbound)
└────────────────────────┘             │ (valida assinatura Twilio)│──▶ sms_conversations (unread_count++)
                                        └──────────────────────────┘
                                                     │
                                                     ▼
                                        ┌──────────────────────────┐
                                        │  Aba "Messages" (Inbox)   │
                                        │  no AirValet frontend     │
                                        └──────────────────────────┘
```

### Edge Functions propostas (Fase 4-8, não aprovadas nesta etapa)

| Function | Responsabilidade | Chamada por |
|---|---|---|
| `send-sms` | Recebe `{passenger_id, template_key, override_body?}`; valida JWT + regra de negócio (ex.: Customs Gratuity só se `customs_welcome_sent=true`); monta corpo pelo template correspondente no servidor; chama Twilio; grava linha em `sms_messages` | Frontend AirValet (autenticado) |
| `twilio-inbound-webhook` | Recebe POST do Twilio quando o passageiro responde; valida assinatura `X-Twilio-Signature`; normaliza telefone; localiza viagem ativa mais recente; trata `STOP`/`START`/`UNSTOP`/`HELP`; grava mensagem inbound | Twilio (público, protegido por assinatura) |
| `twilio-status-callback` | Recebe atualizações de status por `MessageSid` | Twilio (público, protegido por assinatura) |
| `schedule-sms` | Cria um registro em `sms_scheduled_jobs` | Frontend AirValet (autenticado) |
| `cancel-scheduled-sms` | Cancela um job local e/ou chama a API de cancelamento do Twilio | Frontend AirValet (autenticado) |

### Autenticação / autorização do `send-sms` (quando aprovado)

1. Exigir `Authorization: Bearer <supabase JWT>` (Supabase Edge Functions verificam automaticamente).
2. Rejeitar chamadas sem sessão válida.
3. Nunca aceitar Account SID / Auth Token / Messaging Service SID vindos do request — apenas Supabase Secrets, lidos via `Deno.env.get(...)` dentro da function.

---

## 5. Schema proposto (Fase 3, não aprovada — nenhuma migration foi criada ou executada)

```sql
-- PROPOSTA — NÃO EXECUTAR. Requer aprovação explícita antes de rodar em produção.
create table if not exists public.sms_conversations (
  id uuid primary key default gen_random_uuid(),
  passenger_id bigint references public.passengers(id),
  passenger_phone text not null,
  twilio_number text not null,
  last_message_at timestamptz,
  last_message_preview text,
  unread_count integer not null default 0,
  status text not null default 'OPEN' check (status in ('OPEN','ARCHIVED')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
```

```sql
-- PROPOSTA — NÃO EXECUTAR.
create table if not exists public.sms_messages (
  id uuid primary key default gen_random_uuid(),
  conversation_id uuid references public.sms_conversations(id),
  passenger_id bigint references public.passengers(id),
  direction text not null check (direction in ('OUTBOUND','INBOUND')),
  message_type text not null,
  from_number text not null,
  to_number text not null,
  body text not null,
  twilio_message_sid text unique,
  status text not null default 'draft' check (status in
    ('draft','queued','accepted','scheduled','sending','sent','delivered',
     'undelivered','failed','received','cancelled')),
  error_code text,
  error_message text,
  sent_by uuid references auth.users(id),
  scheduled_for timestamptz,
  sent_at timestamptz,
  delivered_at timestamptz,
  failed_at timestamptz,
  read_at timestamptz,
  created_at timestamptz not null default now()
);
```

```sql
-- PROPOSTA — NÃO EXECUTAR.
create table if not exists public.sms_preferences (
  passenger_phone text primary key,
  opted_in boolean not null default true,
  opted_out boolean not null default false,
  opted_out_at timestamptz,
  opt_out_source text,
  last_help_request_at timestamptz
);
```

```sql
-- PROPOSTA — NÃO EXECUTAR.
create table if not exists public.sms_scheduled_jobs (
  id uuid primary key default gen_random_uuid(),
  passenger_id bigint references public.passengers(id),
  template_key text not null,
  body_snapshot text not null,
  scheduled_for timestamptz not null,
  status text not null default 'PENDING' check (status in
    ('PENDING','SENT','CANCELLED','FAILED')),
  cancellation_reason text,
  created_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  sent_at timestamptz,
  cancelled_at timestamptz
);
```

```sql
-- PROPOSTA — NÃO EXECUTAR. Mesmo modelo de RLS de daily_closing_reports.
alter table public.sms_conversations enable row level security;
alter table public.sms_messages enable row level security;
alter table public.sms_preferences enable row level security;
alter table public.sms_scheduled_jobs enable row level security;

create policy "sms_conversations_authenticated" on public.sms_conversations
  for all to authenticated using (true) with check (true);
create policy "sms_messages_select_authenticated" on public.sms_messages
  for select to authenticated using (true);
create policy "sms_scheduled_jobs_authenticated" on public.sms_scheduled_jobs
  for all to authenticated using (true) with check (true);
-- sms_messages: INSERT/UPDATE só via service_role (Edge Functions), nunca
-- direto do frontend.
create policy "sms_preferences_select_authenticated" on public.sms_preferences
  for select to authenticated using (true);
```

**Nunca armazenar `TWILIO_AUTH_TOKEN` em nenhuma tabela** — apenas como Supabase Secret.

---

## 6. Modo de simulação (`mock_twilio`) — implementado na Fase 2

```js
var SMS_PROVIDER = 'native'; // 'native' | 'mock_twilio' | 'twilio'  — default permanece 'native'
```

| Modo | Comportamento |
|---|---|
| `native` | Comportamento atual, preservado — `sms:` + `window.open`, sem mudanças observáveis |
| `mock_twilio` | Não abre Messages, não envia nada, não faz chamada de rede. Abre um modal mostrando destinatário, mensagem, template, passenger ID, ticket, marca, telefone original/E.164, botão "Simulate Send" com seletor de resultado simulado (success/invalid phone/network failure/rejected/undelivered), SID falso `MOCK-SM-...`, timestamp, e histórico local (`airvalet_mock_sms_messages`) |
| `twilio` | Placeholder seguro — lança `Error('Real Twilio provider is not configured.')`. Nenhuma credencial, nenhuma URL de Edge Function, nenhuma chamada real existe no código |

Ver `docs/TWILIO_MIGRATION_PHASE1-2_IMPLEMENTATION.md` para o detalhamento completo da implementação, funções adicionadas e resultado dos testes.

---

## 7. Mockup textual da interface (Fases 6/7, não aprovadas)

**Nova aba "Messages"** (8ª aba, ícone `fa-comments`), com badge de não lidas — **não implementada nesta etapa**; a Fase 2 usa apenas um painel de histórico dentro da aba Debug existente.

```
┌─ Messages ──────────────────────────────────────────────────┐
│ [🔍 Search conversations...]                    [Bulk Send] │
├───────────────────────────────────────────────────────────┤
│ ● John Smith (0714-3)          "Can I return tomorrow?"  2m │
│   Maria Silva (A-0714-1)       "Thank you!"              1h │
│   Unmatched (+1 555 010 1234)  "STOP"                    3h │
└───────────────────────────────────────────────────────────┘
```

**Bulk send** (Fase 7, não aprovada): fluxo obrigatório contagem → lista → template → preview → números inválidos → opt-outs → confirmação final. Sem botão "Send to Everyone".

---

## 8. Plano de implementação por fases

| Fase | Escopo | Arquivos alterados | Banco alterado | Risco | Status |
|---|---|---|---|---|---|
| 1 | Auditoria + abstração de provider | `index.html` | Nenhum | Baixo | **✅ Aprovada e implementada** — ver relatório de implementação |
| 2 | Modo `mock_twilio` completo | `index.html`, `styles.css` | Nenhum (localStorage temporário) | Baixo | **✅ Aprovada e implementada** — ver relatório de implementação |
| 3 | Migrations (`sms_conversations`, `sms_messages`, `sms_preferences`, `sms_scheduled_jobs`, RLS) | `migrations/*.sql` | Sim — aditivo | Médio | Não aprovada |
| 4 | Edge Function `send-sms` | `supabase/functions/send-sms/` | Grava em `sms_messages` | Alto | Não aprovada |
| 5 | `twilio-status-callback` | `supabase/functions/twilio-status-callback/` | Atualiza `sms_messages.status` | Médio | Não aprovada |
| 6 | `twilio-inbound-webhook` + Inbox | `supabase/functions/`, `index.html` | Grava `sms_messages`/`sms_conversations` | Alto | Não aprovada |
| 7 | Bulk send | `index.html` | Leitura em massa | Alto | Não aprovada |
| 8 | Scheduling | `supabase/functions/`, `index.html` | `sms_scheduled_jobs` | Alto | Não aprovada |
| 9 | Opt-out / compliance | Edge Functions + `sms_preferences` | `sms_preferences` | Crítico (legal) | Não aprovada |
| 10 | Testes e rollout gradual | — | — | — | Não aprovada |

---

## 9. Matriz de testes obrigatórios

| Caso | O que valida |
|---|---|
| Makers Air Welcome | `buildWelcomeSms` sem `not_returning`, com `ret` — inclui lembrete Hangar 19 |
| Ascend Welcome | `isAscend(r)=true` — marca "Ascend Valet", sem lembrete Hangar 19 |
| No return date | `buildWelcomeSms` branch `!r.ret` |
| Not returning | `buildWelcomeSms` branch `not_returning_with_makers_air` |
| Tasks confirmation | `buildTaskConfirmationSms` |
| Return date confirmation (approx) | `buildReturnDateConfirmationSms` |
| Hangar 19 Welcome Back | Não disparado para Ascend nem para `delivery_type==='CUSTOMS'` |
| Customs Welcome Back (Makers Air) | Texto "key on driver-side tire" |
| Customs Welcome Back (Ascend) | Texto "Ascend team member will personally provide" |
| Customs Gratuity bloqueada antes do Welcome Back | **Achado (Fase 1/2):** hoje NÃO é bloqueada no client — o botão "Send Gratuity" é sempre clicável; apenas o texto de apoio muda. Teste automatizado confirma esse comportamento atual; bloqueio real fica para a Fase 4 (server-side) |
| Customs Gratuity liberada depois do Welcome Back | flags corretos |
| Tip Yes | Sem link Stripe |
| Tip No | Com link Stripe exato |
| Customs não disparando Tip SMS genérico | `deliverWithTip` roteia corretamente |
| Telefone inválido | `normalizePhoneE164` retorna `valid:false` com motivo, sem crash |
| Telefone internacional | Números com `+` preservados sem inventar código de país |
| Passageiro sem telefone | Guards `if(!r.phone)` preservados |
| Cancel no modal mock | Não altera flags nem timestamps |
| Simulate success | Grava flag/timestamp exatamente como o modo `native` faria |
| Simulate failed/undelivered/invalid_phone/network_failure | Não grava flag como enviado |
| Mock history cleanup | Botão limpa `airvalet_mock_sms_messages` e o array em memória |
| Envio duplicado (reenvio) | `confirm()` de reenvio preservado |
| STOP / HELP / bulk send / webhook inbound / callback Twilio | Fora de escopo desta fase — cobertos apenas na auditoria, sem implementação |

Resultado da execução desta matriz para a Fase 1/2: ver `docs/TWILIO_MIGRATION_PHASE1-2_IMPLEMENTATION.md`.

---

## 10. Regras críticas de negócio (reafirmadas para qualquer fase futura)

1. Separação completa entre Makers Air e Ascend.
2. Detecção de Ascend pelo prefixo `A-` do ticket (`isAscend()`, `index.html:2374`).
3. Fluxo Customs: Welcome Back → Gratuity, sempre nessa ordem.
4. Gratuity do Customs nunca antes do Welcome Back.
5. Entregas Customs nunca recebem o Tip SMS genérico (evita duplicar o pedido de gorjeta).
6. Hangar 19 Welcome Back é um fluxo separado do Customs Welcome Back — nunca confundir.
7. Nenhuma credencial Twilio no frontend, localStorage ou código público.
8. Integração futura usa Supabase Edge Functions para armazenar segredos Twilio.
9. Nenhuma mensagem automática é enviada durante a simulação.
10. Nenhuma migration é executada em produção sem aprovação explícita e separada.

---

## 11. Addendum — Fase Hardening (2026-08-04)

Ver `docs/TWILIO_MIGRATION_PHASE1-2_HARDENING_REPORT.md` para o relatório completo. Resumo do que mudou:

- **R1 corrigido** (client-side) — ver seção 3 acima, entrada R1.
- **Validação centralizada de telefone** — `sendPassengerSms` agora recusa qualquer envio (em qualquer provider, incluindo `native`) se o telefone não passar em `normalizePhoneE164`, antes de abrir qualquer provider. O telefone original salvo no passageiro nunca é reescrito.
- **Botão genérico "TEXT" centralizado** — deixou de ser um `<a href="sms:...">` puro. Agora chama `sendGenericTextSms(id)`: em `native` continua abrindo o Messages com corpo vazio (comportamento idêntico); em `mock_twilio` abre um modal de composição livre (`message_type = FREEFORM`) antes da simulação. **Não há mais nenhum ponto `sms:` fora de `sendPassengerSms`** — a centralização do inventário original (seção 2) está agora completa.
- **Painel de demonstração estático** adicionado à aba Debug (`🖼 SMS Demo Gallery`) — sem chamadas de rede, sem tocar em `data`.
- 26 novas asserções automatizadas (84 no total) cobrindo especificamente o gate de Gratuity, a validação de telefone, FREEFORM nos dois providers, e uma reconfirmação da exclusão Customs/Tip-SMS.
