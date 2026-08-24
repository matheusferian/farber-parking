# AirValet — Fase 1 + Fase 2: Relatório de Implementação

**Data:** 2026-08-04
**Escopo aprovado:** Fase 1 (abstração do SMS provider) + Fase 2 (modo `mock_twilio`).
**Fora de escopo, não implementado:** conta/números Twilio reais, Edge Functions reais, migrations, alteração de banco de produção, secrets, remoção dos links `sms:`, mensagens automáticas, bulk send real, webhook inbound real.

---

## 1. Backup

Local: `BKP/2026-08-04 13-20-08/`
Arquivos copiados antes de qualquer edição: `index.html`, `styles.css`, `utils.js`, `PROJECT.md`.

## 2. Arquivos modificados

| Arquivo | Natureza da mudança |
|---|---|
| `index.html` | Nova camada de abstração de SMS (`SMS_PROVIDER`, `sendPassengerSms`, modal mock, histórico mock, painel de debug); 8 pontos de envio convertidos para usar a camada central; 2 templates inline extraídos para funções |
| `styles.css` | ~16 linhas novas — classes `.mock-sms-*` para o modal de simulação; nenhuma regra existente alterada |
| `utils.js` | Nova função pura `normalizePhoneE164()`; nada existente alterado |
| `docs/TWILIO_MIGRATION_AUDIT.md` | Novo — cópia completa da auditoria técnica no repositório |
| `docs/TWILIO_MIGRATION_PHASE1-2_IMPLEMENTATION.md` | Novo — este arquivo |
| `PROJECT.md` | Decisão arquitetural + changelog (ver seção final) |

## 3. Funções adicionadas

**`index.html`:**
`SMS_MESSAGE_TYPES`, `sendPassengerSms`, `openMockSmsModal`, `closeMockSmsModal`, `setMockSmsButtonsDisabled`, `mockSmsDelay`, `mockSmsStatusLabel`, `renderMockSmsModal`, `mockSmsSimulateSend`, `loadMockSmsHistory`, `saveMockSmsHistory`, `recordMockSmsHistory`, `clearMockSmsHistory`, `setSmsProviderFromDebug`, `renderMockSmsHistoryPanel`, `welcomeSmsMessageType`, `buildReturnDateConfirmationSms`, `sendReturnDateConfirmationSms`, `buildTaskConfirmationSms`, `sendTaskConfirmationSms`.

**`utils.js`:** `normalizePhoneE164`.

## 4. Funções alteradas (comportamento `native` preservado — apenas o transporte foi centralizado)

`sendWelcomeSms`, `sendWelcomeBackSms` (virou `async`), `sendCustomsWelcomeSms` (virou `async`), `sendCustomsGratuitySms` (virou `async`), `openTipSms`, `saveEntry` (bloco de SMS), `renderTasks` (removida a construção inline do link `sms:`).

Nenhuma função `build*Sms` (que define o **texto** das mensagens) foi alterada — confirmado por teste automatizado byte a byte (seção 7).

## 5. Templates centralizados

| Chave | Função builder | Status |
|---|---|---|
| `WELCOME_CONFIRMED` / `WELCOME_NO_DATE` / `WELCOME_NOT_RETURNING` | `buildWelcomeSms(r)` (já existia, ramificações internas preservadas) | Centralizado via `welcomeSmsMessageType(r)` |
| `RETURN_CONFIRMATION` | `buildReturnDateConfirmationSms(r)` | **Novo — extraído do inline em `index.html` (era o único fora do padrão)** |
| `TASK_CONFIRMATION` | `buildTaskConfirmationSms()` | **Novo — extraído do inline na aba Tasks** |
| `HANGAR19_WELCOME_BACK` | `buildWelcomeBackSms()` (já existia) | Centralizado |
| `CUSTOMS_WELCOME_MAKERS` / `CUSTOMS_WELCOME_ASCEND` | `buildCustomsWelcomeSms(r)` (já existia, branch por `isAscend`) | Centralizado |
| `CUSTOMS_GRATUITY` | `buildCustomsGratuitySms(r)` (já existia) | Centralizado |
| `TIP_YES` / `TIP_NO` | `buildTipSms(r, tipReceived)` (já existia) | Centralizado |
| `GENERIC` | — | **Não centralizado nesta fase — ver seção 6** |

## 6. Pontos `sms:` restantes e justificativa

Um único ponto continua sendo um link `sms:` puro, sem passar por `sendPassengerSms`:

```html
<a href="sms:'+r.phone.replace(/\D/g,'')+'" ...>💬 TEXT</a>
```
(painel de detalhe, botão genérico ao lado de "📞 CALL")

**Justificativa:** este link não carrega nenhum template (`&body=` nunca existiu aqui — abre o Messages em branco, como se o atendente tivesse tocado no ícone do Messages diretamente). Convertê-lo para `sendPassengerSms` exigiria inventar um "template genérico" que não existe hoje, o que seria uma mudança de escopo, não uma extração. Foi deixado como está para minimizar o diff e o risco, conforme a política de mudanças mínimas do `CLAUDE.md`. Fica identificado como candidato à chave `GENERIC` numa fase futura, se aprovado.

## 7. Testes realizados

Como o preview do navegador sandboxed não executa JavaScript para arquivos fora do diretório de workspace principal (`file://.../FARBERMAKERS/index.html` carrega apenas como snapshot estático nesta ferramenta), a verificação foi feita com um harness Node.js headless que:
- carrega o **código real** de `utils.js` + o `<script>` inline de `index.html` (não uma reimplementação);
- intercepta `fetch` e `window.open` no nível do sandbox — **nenhuma chamada chega à rede real, independentemente da URL**, então não havia risco de gravar no Supabase de produção;
- fornece um DOM mínimo (stubs de `document.getElementById`, `classList`, `innerHTML`, etc.) suficiente para exercitar os fluxos reais.

Scripts em `/private/tmp/.../scratchpad/sms-tests/` (fora do projeto — não commitados).

**Cobertura (58 asserções, 58 passaram):**
- Todos os templates (`buildWelcomeSms` nas 4 variações, `buildWelcomeBackSms`, `buildCustomsWelcomeSms` M/A, `buildCustomsGratuitySms` M/A, `buildTipSms` Yes/No, `buildReturnDateConfirmationSms`, `buildTaskConfirmationSms`) comparados byte a byte com o texto original pré-Fase-1.
- `normalizePhoneE164`: EUA 10 dígitos, EUA 11 dígitos com `1`, internacional com `+`, inválidos (curto, vazio, `+1` sozinho sem inventar código de país).
- `sendPassengerSms` modo `native`: exatamente 1 chamada a `window.open`, URL idêntica à construção pré-Fase-1, retorno `{ok:true, status:'composer_opened'}`.
- `sendPassengerSms` modo `mock_twilio`: os 5 desfechos simuláveis (`success`, `invalid_phone`, `network_failure`, `rejected`, `undelivered`) e `Cancel` — cada um resolvendo com `ok` correto e sendo gravado no histórico mock.
- Funções wrapper completas (`sendWelcomeBackSms`, `sendCustomsWelcomeSms`, `sendCustomsGratuitySms`) rodadas ponta a ponta: **flag só é gravado no sucesso simulado**; falha simulada e Cancel **não** gravam `welcome_back_sent_at`/`customs_welcome_sent`/`customs_gratuity_sent`.
- Corpo do `PATCH` (`sbUpdate`, interceptado) inspecionado para confirmar o campo correto sem nunca sair para a rede.
- `isAscend()` continua correto (`A-` prefixo).
- Modo `twilio` lança exatamente `Error('Real Twilio provider is not configured.')`.
- `node --check` em `index.html` (script extraído) e `utils.js` — sintaxe OK.

**Achado durante os testes (corrigido na auditoria):** a versão original de `docs/TWILIO_MIGRATION_AUDIT.md` atribuía incorretamente o bloqueio "Gratuity nunca antes de Welcome Back" à função `isCustomsCommEligible`. Na verdade essa função só controla a janela de ativação do **lembrete automático**; o botão manual "Send Gratuity" em `renderCustomsCommModal` **sempre** é renderizado e clicável, independente de `customs_welcome_sent`. Isso já era verdade **antes** desta migração — não foi introduzido por ela — e não foi alterado nesta fase (fora do escopo aprovado). A auditoria foi corrigida para refletir isso com precisão; ver risco R1 atualizado.

## 8. Resultados

58/58 asserções passaram. Nenhuma regressão detectada nos 24 pontos do inventário original. O único comportamento novo observável é: a aba Debug agora tem um seletor de `SMS_PROVIDER` (default `native`) e um painel de histórico mock — nada disso é visível ou usado no fluxo operacional normal do atendente.

## 9. Limitações

- Testado via harness headless, não em um iPad físico real nem em um navegador com execução JS completa contra o arquivo real (limitação do ambiente desta sessão, não do código). Recomenda-se uma validação manual rápida em navegador real antes de considerar a Fase 1/2 "confirmada em produção", seguindo o mesmo padrão de validação manual já usado em mudanças anteriores deste projeto (ver `PROJECT.md`, tip workflow 2026-07-13).
- `taskStatus` (Tasks queue) continua em memória, não persistido — limitação pré-existente, preservada intencionalmente.
- O link "💬 TEXT" genérico (seção 6) não passa pela nova camada — decisão deliberada, não uma lacuna acidental.
- O gap de "Gratuity sem bloqueio real antes do Welcome Back" (achado corrigido na auditoria) **continua existindo** — não foi corrigido nesta fase por estar fora do escopo aprovado (seria uma mudança de comportamento, não uma abstração de transporte).

## 10. Rollback exato

1. Restaurar os 3 arquivos do backup:
   ```bash
   cp "BKP/2026-08-04 13-20-08/index.html" index.html
   cp "BKP/2026-08-04 13-20-08/styles.css" styles.css
   cp "BKP/2026-08-04 13-20-08/utils.js" utils.js
   ```
2. Nenhuma migration foi executada — nenhum rollback de banco é necessário.
3. Nenhum secret foi adicionado — nenhuma limpeza de configuração é necessária.
4. Alternativa sem restaurar arquivo: `SMS_PROVIDER` já é `'native'` por padrão; não é necessária nenhuma ação para manter o comportamento atual em produção.

## 11. Diff resumido

`index.html`: +403 / -23 linhas (aditivo, concentrado em 1 bloco novo de ~260 linhas + 8 pontos de chamada convertidos).
`styles.css`: +16 linhas (apenas classes novas `.mock-sms-*`).
`utils.js`: +29 linhas (1 função nova).

## 12–14. Confirmações finais

- ✅ **Nenhuma migration foi executada.** Nenhum arquivo em `migrations/` foi criado ou modificado.
- ✅ **Nenhuma mensagem real foi enviada.** Todos os testes usaram `fetch`/`window.open` interceptados; nenhuma chamada de rede real ocorreu durante o desenvolvimento ou os testes.
- ✅ **`SMS_PROVIDER = 'native'` permanece o padrão** — confirmado por leitura do código (`index.html`, bloco SMS PROVIDER CONFIG) e por teste automatizado (`SMS_PROVIDER defaults to native`).
