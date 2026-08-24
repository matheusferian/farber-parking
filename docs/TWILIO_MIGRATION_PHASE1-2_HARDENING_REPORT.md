# AirValet — Fase Hardening: Relatório

**Data:** 2026-08-04
**Escopo:** revisão e hardening da Fase 1/2 (SMS provider abstraction + `mock_twilio`). Nenhuma conexão Twilio real, nenhuma migration, `SMS_PROVIDER = 'native'` continua padrão.
**Backup:** `BKP/2026-08-04 13-51-19/` (index.html, styles.css, utils.js, PROJECT.md, TWILIO_MIGRATION_AUDIT.md), criado antes de qualquer edição desta fase.

---

## 1. Arquivos alterados

| Arquivo | Mudança |
|---|---|
| `index.html` | +165 / −9 linhas — gate real de Customs Gratuity, validação centralizada de telefone, botão TEXT → FREEFORM, painel de demo estático no Debug |
| `styles.css` | +15 linhas — `.cst-send-btn:disabled` + classes `.sms-demo-*` da galeria estática |
| `docs/TWILIO_MIGRATION_AUDIT.md` | R1 marcado como corrigido; addendum da Fase Hardening |
| `docs/TWILIO_MIGRATION_VISUAL_QA_CHECKLIST.md` | Novo — checklist manual para o iPad |
| `docs/TWILIO_MIGRATION_PHASE1-2_HARDENING_REPORT.md` | Novo — este arquivo |

`utils.js` e `PROJECT.md` não foram tocados nesta fase (serão atualizados após a validação manual, se aprovado).

## 2. Linhas/funções principais alteradas

- **`sendCustomsGratuitySms(id)`** — nova guarda no topo: `if(r.customs_welcome_sent!==true){ showMsg('Send the Customs Welcome Back message first.', true); return; }`. Roda antes até do check de telefone, e antes de qualquer chamada a `sendPassengerSms`/`fetch`.
- **`renderCustomsCommModal(r)`** — botão "Send Gratuity" agora recebe `disabled` + `title="Send the Customs Welcome Back message first."` enquanto `customs_welcome_sent!==true`; o subtexto muda para a mesma mensagem, em vermelho.
- **`sendPassengerSms(options)`** — nova validação centralizada no topo (`validatePhoneForSend`), antes de qualquer branch de provider. Telefone inválido/vazio → `{ok:false, status:'invalid_phone', ...}`, `showMsg` com mensagem clara, **nenhum** `window.open` nem modal mock é aberto. O telefone original do passageiro nunca é reescrito — a normalização é só para validar/exibir.
- **`sendGenericTextSms(id)`** (nova) + **`openFreeformComposeModal`/`closeFreeformCompose`/`continueFreeformCompose`** (novas) — substituem o `<a href="sms:...">` genérico. `native`: abre o Messages com corpo vazio, sem texto inventado (idêntico ao comportamento anterior). `mock_twilio`: abre um compose modal (`#freeformComposeOv`) exigindo digitação + clique em "Continue" antes de entrar no modal de simulação já existente, marcado `message_type: 'FREEFORM'`.
- **SMS Demo Gallery** (Debug tab, `<details>`) — markup 100% estático, sem `onclick` para nenhuma função real.

## 3. Novos testes (harness headless, código real interceptando `fetch`/`window.open`)

26 novas asserções (total agora: **84/84 passando**), cobrindo exatamente os 10 casos pedidos:
bloqueio de gratuity antes do WB (nível UI e nível função) · gratuity permitida depois do WB · chamada direta da função não contorna a regra (0 chamadas de rede, flag permanece `false`) · Cancel não altera flags · falha simulada não altera flags, inclusive nos estados intermediários (`queued`/`sent`) · telefone vazio recusado · telefone malformado recusado · FREEFORM em `native` (corpo vazio, 1 chamada a `window.open`) · FREEFORM em `mock_twilio` (compose → simulação, corpo e `messageType` corretos no histórico) · reconfirmação de que a linha de roteamento Customs/Tip-SMS genérico continua byte-idêntica.

## 4. Limitações reais da validação

- `normalizePhoneE164` valida **formato**, não existência real do número — um número de 10 dígitos bem formado mas nunca atribuído a ninguém passa na validação (isso só seria pego por um provedor real, na Fase 4).
- Não há tratamento de ramais/extensões (`ext.`, `x123`) — qualquer sufixo desse tipo altera a contagem de dígitos e o número é rejeitado como inválido. Não há nenhum caso de uso conhecido no app para isso (são celulares de passageiros), mas fica registrado.
- A validação roda **antes** de abrir o provider, mas não impede um número tecnicamente válido e formatado corretamente de ainda assim ser um número errado digitado por engano (não há verificação cruzada com o nome/histórico do passageiro).
- O guard de `sendCustomsGratuitySms` é absoluto: se existir algum registro histórico anterior a esta correção com `customs_gratuity_sent=true` e `customs_welcome_sent=false` (só possível por causa do bug agora corrigido), reabrir/reenviar essa mensagem específica ficará bloqueado até que `customs_welcome_sent` seja marcado manualmente — não identifiquei nenhum registro assim, mas é uma consequência conhecida da correção.
- Continua sendo um bloqueio **client-side**. A revalidação server-side (Edge Function `send-sms`) é Fase 4, não aprovada.

## 5. Instruções de teste manual no iPad

Ver **`docs/TWILIO_MIGRATION_VISUAL_QA_CHECKLIST.md`** — checklist completo com 12 seções (modal em desktop/iPad/iPhone, scroll, teclado virtual, botões, textos longos, sem telefone, status Failed, histórico vazio/cheio, galeria estática). **Nenhum desses itens foi verificado visualmente nesta sessão** — o ambiente só renderiza este arquivo como snapshot estático (sem execução de JS). Só a lógica foi verificada, via o harness headless.

## 6. Rollback

```bash
cp "BKP/2026-08-04 13-51-19/index.html" index.html
cp "BKP/2026-08-04 13-51-19/styles.css" styles.css
cp "BKP/2026-08-04 13-51-19/PROJECT.md" PROJECT.md
cp "BKP/2026-08-04 13-51-19/TWILIO_MIGRATION_AUDIT.md" docs/TWILIO_MIGRATION_AUDIT.md
```
Nenhuma migration foi executada nesta fase — nenhum rollback de banco necessário. Nenhum secret foi adicionado. `SMS_PROVIDER` continua `'native'` por padrão; nenhuma ação é necessária para manter o comportamento atual em produção mesmo sem reverter.

## 7. Confirmações

- ✅ Nenhuma conta/número Twilio real usado.
- ✅ Nenhuma migration executada, nenhum arquivo em `migrations/` tocado.
- ✅ Nenhum secret adicionado.
- ✅ `SMS_PROVIDER = 'native'` permanece o padrão (confirmado por leitura do código e por teste automatizado).
- ✅ Não avancei para Fase 3, Edge Functions ou Twilio real.
