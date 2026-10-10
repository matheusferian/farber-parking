# AirValet SMS (Twilio) — Etapa 1: revisão + plano de implantação

Data: 2026-10-10 · Branch `feature/twilio-sms-local` (local, sem commit) sobre `main 591ce5d`.
Campaign `CM690d9065d3024780925b6f652e9afc83` APPROVED · número +1 954-526-9800 REGISTERED.
Produção: AirValet v46, `SMS_PROVIDER='native'`, 0 tabelas/funções SMS. Nada foi alterado em produção nesta etapa.

## 1. Atualização da branch
- Fast-forward `b4264fc → 591ce5d`. Cópias antigas de sms/privacy/terms.html da branch descartadas (as do main são as publicadas).
- Conflito em `vercel-build.sh` resolvido: linha do main intacta + `cp pass.html dist/` separado (Passenger Link).
- Backup completo antes: `~/Dev/airvalet-prod-backups/twilio-branch-20261010-135324/`.

## 2. Paridade v46 (modo native)
Diff contra o main: index.html +377/−8, styles.css +64, service-worker.js v46→v47, vercel.json (+/p/ rewrite e headers), vercel-build.sh +3.
As 8 linhas removidas do index.html são ganchos `isServerSms()`, o `id` no Messages Workspace e o placeholder Twilio substituído.
Customer Copy, Key Copy, Dashboard, TV, Welcome, Welcome Back, Customs e Tip: sem hunks.
Teste no app real em native: inbox oculta, workspace visível, consentimento oculto, sem polling, envio abre o composer do iPhone (`sms:`), 0 erros JS.
Efeito colateral do deploy futuro: v47 mostra o banner de atualização uma vez em todos os aparelhos.

## 3. Testes locais (todos verdes)
| Suite | Resultado |
|---|---|
| Release (Return/Pickup, só 2 migrations) | apply → rollback → re-apply OK, RELEASE_TESTS_PASSED |
| 5 migrations completas | apply → rollback → re-apply OK |
| SQL | 220/220 |
| Concorrência | 20 claims simultâneos → 1 linha |
| Integração DB (service + webhooks assinados) | 6/6 |
| Deno SMS | 56/56 |
| Deno SSO (existente) | 13/13 |
| Node (pickup parity + logout) | 7/7 |
| E2E navegador (app real + telefone simulado, mock) | 28/28, 0 erros JS |
| Native (paridade v46) | OK |

## 4. Revisão — o que precisa de correção antes de qualquer SMS real
### Bloqueadores (Etapa 2)
- **B1 "YES" vira consentimento.** As keywords padrão de opt-in incluem YES; um passageiro respondendo "Yes" à confirmação de retorno gera auto-reply da Twilio e grava consentimento. Corrigir: tirar YES do Advanced Opt-Out do serviço AirValet SMS (Console) e, no código, só tratar START/UNSTOP como reativação.
- **B2 Live sem Auth Token.** A config é considerada completa sem `TWILIO_AUTH_TOKEN`; os webhooks recusariam tudo (403) e STOP/status/respostas sumiriam em silêncio. Exigir token + Messaging Service SID.
- **B3 `send_unknown` nunca se resolve.** Sem SID a linha não é ligada ao callback. Passar `mid` no StatusCallback URL.
- **B4 Risco de SMS duplicado.** O servidor responde `ok:true` para `pending`/`send_unknown` e o cliente gera novo compose id → novo Send pode texto duplo. Corrigir os dois lados.
- **B5 Gorjeta ainda no caminho Twilio.** `TIP_NO` com link e `CUSTOMS_GRATUITY` existem (pendentes de aprovação, a um passo de enviar). Remover — o programa aprovado é só operacional.

### Importantes (Etapa 2)
- **Ligar por funcionário sem redeploy:** hoje `SMS_PROVIDER` é constante; o Debug deixa ADMIN/IPAD_OPS trocar. Proposta: flag por usuário (`user_profiles.sms_enabled`) lida no login + o mesmo flag checado no `send-sms`; Debug só para ADMIN.
- **Custos:** limite diário global + por funcionário, máx. 3 segmentos em texto livre, bloquear links externos em texto livre, ValidityPeriod 1h, Smart Encoding no serviço, baixar limites por telefone (6/h, 20/dia → 4/h, 10/dia).
- **Concorrência:** mesmo lock por SID em status/resultado; STOP pega o lock do telefone.
- **Passenger Link:** revogar ao trocar o telefone, validade máxima 30 dias, token não legível por todos os papéis (guardar hash), token por POST em vez de query string, remover modo demo do pass.html, headers/CSP também em /pass.html.
- **Consentimento:** gravar também no check-in offline; ação "Registrar consentimento" para passageiros já em estacionamento; desabilitar Send no preview sem consentimento.
- **Rollback das migrations preserva provas de consentimento/opt-out** (arquivar em vez de apagar — exigência A2P).
- **Menores:** ack de Needs Review usar `created_at`; inbox mostrar erro de carga em vez de "vazio"; polling só com a aba Messages aberta; limitar re-envio por `event_ref`; criar link só depois do consentimento; revogar sequences de anon/authenticated; `config.toml` com verify_jwt; job de reconciliação para linhas presas.

### Decisões do dono
- Página do passageiro mostra o número do ticket (só exibição). Risco: um SMS encaminhado basta para apresentar no pickup. Manter? (aprovado antes, só registrando o risco).
- Script verbal diz "Farber Parking"; páginas dizem "Farber Parking LLC". Consistente e aprovado; mudar só se quiser o nome jurídico também no script.

### Confirmado OK
RLS nas 5 tabelas, anon sem acesso a nada; SECURITY DEFINER com search_path vazio e checagem de papel; consentimento por telefone com versão/quem/quando; STOP bloqueia tudo (templates e texto livre) até START; idempotência (chave única + lock por telefone); status só avança; assinatura Twilio com comparação de tempo constante; modo padrão `disabled` se faltar config; logs sem telefone/corpo/segredos; inbox escapa todo HTML; pass.html sem scripts de terceiros, sem referrer, noindex; pré-requisitos em produção presentes (return_operator, pickup_location, return_reviews, pgcrypto em `extensions`).

## 5. Custos
Fixos: número $1,15 + Campaign $1,50 = **$2,65/mês** (já em cobrança).
Variáveis (aproximado, confirmar na tabela de preços Twilio): cada segmento enviado ou recebido ~US$0,008 + taxa de operadora por segmento enviado. O SMS de check-in tem 2 segmentos. Com 150–500 passageiros/mês e 2–5 mensagens por viagem, a ordem de grandeza é **~US$10–40/mês**, limitada pelos caps da Etapa 2.

## 6. Plano de implantação gradual (cada etapa = GO separado)
| Etapa | O que | Quem vê | Rollback |
|---|---|---|---|
| 2 | Correções acima, só local + testes completos de novo | ninguém | descartar branch (backup existe) |
| 3 | Twilio Console, só no serviço AirValet SMS: tirar YES, respostas STOP/HELP/START, Smart Encoding, validade. FarberOS intocado | ninguém | voltar valores anteriores (anotados) |
| 4 | Migrations em produção (aditivas), dry-run com rollback antes, depois apply em transação | ninguém (app v46 não usa) | scripts de rollback (com arquivamento de consentimento) |
| 5 | Edge Functions + secrets com `AIRVALET_SMS_MODE=disabled`; dono cria a API Key e grava os secrets (Claude não vê valores); apontar webhooks do serviço | ninguém | modo `disabled` imediato; remover funções |
| 6 | App v47 em produção com native para todos; /p/ ativo | todos veem banner de atualização, nada muda | promover deploy anterior (591ce5d) na Vercel |
| 7 | Teste real só para o telefone do dono: `allowlist` + flag só no usuário do dono; check-in → SMS → resposta → STOP → START → link | só o dono | modo `disabled` |
| 8 | Canário: 1 aparelho/1 funcionário em `live`, passageiros reais com consentimento; Customer Copy continua imprimindo; 1 semana olhando entrega, 30007, STOP, custo | 1 funcionário | desligar flag do usuário / modo `disabled` |
| 9 | Todos os funcionários | equipe | flag por usuário / `disabled` |
| 10 | Só depois das 8 condições do dono: avaliar retirada da Customer Copy | — | — |

Interruptores em qualquer momento: `AIRVALET_SMS_MODE=disabled` (para tudo na hora, sem deploy) e flag por usuário (tira um funcionário sem afetar os outros).

## 7. Secrets necessários (só nomes; valores ficam com o dono)
send-sms: `AIRVALET_SMS_MODE`, `AIRVALET_SMS_TEST_ALLOWLIST`, `AIRVALET_SMS_PUBLIC_FUNCTIONS_URL`, `AIRVALET_PASS_BASE_URL`, `TWILIO_ACCOUNT_SID`, `TWILIO_API_KEY_SID`, `TWILIO_API_KEY_SECRET`, `TWILIO_MESSAGING_SERVICE_SID`, `TWILIO_AUTH_TOKEN` (+ `SUPABASE_*` automáticos). `AIRVALET_GRATUITY_URL` sai com a remoção da gorjeta.
twilio-inbound / twilio-status-callback: `AIRVALET_SMS_PUBLIC_FUNCTIONS_URL`, `TWILIO_AUTH_TOKEN`, `TWILIO_MESSAGING_SERVICE_SID`.
valet-pass: só `SUPABASE_*`.

---

# Etapa 1b — Link curto Makers Air Valet em farberos.com (2026-10-10)

## URL escolhida: `https://farberos.com/a#<token>` — 40 caracteres
| Opção | Tamanho | Decisão |
|---|---|---|
| `https://farberos.com/<token>` | 38 | **Rejeitada.** Exige rota "pega-tudo" na raiz do FarberOS (muda o 404 de qualquer caminho, conflita com rotas futuras); a variante com `#` na raiz é impossível porque `/` redireciona para `/login`. |
| `https://farberos.com/a/<token>` | 40 | Viável, mas o token iria no caminho → aparece em logs da Vercel e no proxy do FarberOS (que registra `path=` e coloca o caminho em `?next=` para usuários logados). |
| **`https://farberos.com/a#<token>`** | **40** | **Escolhida.** Mesmo tamanho; o token fica no fragmento `#`, que o navegador nunca envia a servidor, proxy, log, analytics ou Referer. |
| atual `https://airvalet.farberos.com/p/<17>` | 49 | Fallback sem nenhuma mudança no FarberOS. |

SMS de check-in: 235 → 231 caracteres, continua com 2 segmentos (1 segmento é impossível com link + HELP/STOP/frequência/tarifas).

## Arquitetura
```
SMS → https://farberos.com/a#TOKEN
  GET  farberos.com/a      ──(rewrite FarberOS)──▶ airvalet.farberos.com/pass.html   (página estática, sem token)
  POST farberos.com/a/api  ──(rewrite FarberOS)──▶ Supabase AirValet /functions/v1/valet-pass  { "t": TOKEN }
                                                    └─ airvalet_pass_view(token, hash(IP)) → ok | expired | limited
```
- Mesma origem (farberos.com) para página e API → CSP `connect-src 'self'`, sem CORS.
- O FarberOS só ganha 2 rewrites + headers + exclusão no matcher do proxy. Login, SSO, MFA, gate, APIs, `/g/`, `/sms`, `/privacy`, `/terms` intocados.

## Segurança (requisito → implementação → teste local)
1. ≥96 bits: 17 base62 por rejection sampling (sem viés) = 101 bits. Teste: 200 mints distintos, 62 símbolos uniformes.
2. Sem IDs/nome/telefone: token puramente aleatório; banco guarda só SHA-256. Teste: sem coluna de token em texto.
3. Validação só no servidor: a página não decide nada; envia o fragmento por POST; o SQL decide.
4. Enumeração/outros passageiros/vazamento: resposta idêntica `{"state":"expired"}` para desconhecido, truncado, alterado, ticket, SQLi, XSS, revogado e expirado; resposta só com campos de exibição (sem telefone, ids, sobrenome, localização da chave).
5. Rate limit no servidor: 30 req/10 min por cliente, 8 falhas/10 min por cliente, freio global de 2000 falhas/10 min que nunca bloqueia token válido; IP guardado só como hash com sal.
6. Sem token em logs: fragmento nunca chega ao servidor; SMS log guarda o link mascarado (`*****************`, mesmo tamanho/segmentos); token só sai na chamada à Twilio. Teste: log de acesso, log da função, SMS log e tabela de throttle sem nenhum token. **Exceção inevitável:** o log de mensagens da própria Twilio guarda o corpo enviado (com o link).
7. HTTPS: farberos.com já tem HSTS `max-age=63072000; includeSubDomains; preload`.
8. `Cache-Control: no-store` e `Referrer-Policy: no-referrer` na página, na API e na fonte pass.html (+ noindex, nosniff, X-Frame-Options DENY).
9. Sem terceiros: CSP `default-src 'none'`, script fixado por SHA-256, nenhum script/fonte/imagem externa. Teste no navegador: 0 requisições externas.

## Validade
- Atendimento aberto (PENDING / NO DATE): ativo.
- Primeiro DELIVERED: `expires_at` = hora real da entrega (`checkout_date`, nunca no futuro) + **3 horas**, gravado **uma única vez**.
- Desfazer entrega, reentregar, editar depois: prazo não muda. Desfazer depois de expirado não ressuscita.
- Depois: "This valet link has expired."
- Revogação imediata: equipe autorizada (ADMIN, MANAGER, IPAD_OPS, IPHONE_OPS) via `airvalet_pass_revoke`; automático ao arquivar ou ao corrigir o telefone; reenvio do check-in gera link novo e mata o anterior.

## Compatibilidade com a Campaign aprovada
- Prefixo "Makers Air Valet:", texto e HELP/STOP iguais; só muda o domínio do link: amostra registrada `https://airvalet.farberos.com/p/[token]` → `https://farberos.com/a#[token]`. Mesmo domínio registrável (farberos.com), domínio próprio (não encurtador público).
- Risco: baixo, não zero (operadoras preferem links coerentes com as amostras). Mitigação: testar entrega na Etapa 7 (telefone do dono) e vigiar erro 30007; se houver filtragem, voltar ao fallback de 49 caracteres sem mudar código (só `AIRVALET_PASS_BASE_URL`).
- Linkificação com `#` no iMessage/Android: confirmar no teste da Etapa 7.

## Patch proposto no FarberOS (NÃO aplicado; exige GO e deploy separados)
`next.config.ts`
```ts
async rewrites() {
  return { beforeFiles: [
    { source: "/a", destination: "https://airvalet.farberos.com/pass.html" },
    { source: "/a/api", destination: "https://sfewtirvqhrpanwhbchd.supabase.co/functions/v1/valet-pass" },
  ] };
},
// em headers(): para "/a" e "/a/api" → Cache-Control no-store, Referrer-Policy no-referrer, X-Robots-Tag noindex
```
`src/proxy.ts` (matcher) — tirar só esses 2 caminhos do proxy de sessão:
```ts
"/((?!_next/static|_next/image|favicon.ico|a$|a/api$|.*\\.(?:svg|png|jpg|jpeg|gif|webp)$).*)"
```
`public/sw.js` — defensivo: `/a` e `/a/api` em `isNeverCachePath`.
Verificar no preview do FarberOS: IP real do cliente chega ao Supabase (x-forwarded-for) para o rate limit por cliente; CSP global do FarberOS + CSP da página convivem (já compatíveis: `script-src 'self' 'unsafe-inline'`, `connect-src 'self'`).

## Testes locais (todos verdes)
- SQL: 246 OK (26 novos de link: entropia, hash, 3h exatas, sem renovação, revogação, throttle, privilégios); release + 5 migrations apply → rollback → re-apply OK; 20 claims concorrentes; integração 6/6 (link mascarado no log, hash no banco).
- Deno: 58/58 (novos: duplicado/bloqueado nunca cria link; atendimento fechado → sem link).
- Segurança HTTP + navegador real: **41/41** (`mockups/valet-pass-v2/security_results.txt`).
- E2E do app: 28/28 em duas execuções limpas (uma execução anterior teve falha transitória de carga do utils.js, não reproduzida).
- Native (paridade v46): OK.
- Mockups: `mockups/valet-pass-v2/1-active-hangar19.png`, `2-delivered-within-3h.png`, `3-expired.png`.

## Plano atualizado
Entre as Etapas 5 e 6 entra a **Etapa 5b — FarberOS**: aplicar o patch acima numa branch, preview Vercel, verificar IP/headers/CSP, depois produção do FarberOS (GO e deploy próprios, rollback = deploy anterior do FarberOS). A Etapa 6 (AirValet v47) já publica `pass.html` com os headers.

---

# Etapa 2 — correções locais (2026-10-10) — CONCLUÍDA (só branch local)

## Os 5 problemas
1. **"Yes" ≠ consentimento.** Só START/UNSTOP exatos reativam; o rótulo OptOutType=START da Twilio é ignorado quando o texto não é START/UNSTOP. STOP continua generoso. SQL: "Yes" vira mensagem comum, sem linha de consentimento, opt-out mantido. (Pendente Etapa 3: tirar YES das palavras de opt-in no Console, para a Twilio não responder sozinha.)
2. **Live exige Auth Token + assinatura.** allowlist/live só com API key + Messaging Service + Auth Token (32 hex) + URL pública https; senão `disabled`. Webhooks recusam tudo sem Auth Token/URL/SID do serviço (503) e ignoram tráfego de outro serviço ou sem SID. http://localhost só no modo mock (testes locais).
3. **Envios sem confirmação.** StatusCallback leva `?mid=<id>` (coberto pela assinatura); callback tardio adota o SID e resolve. `airvalet_sms_reconcile` (em todo envio e todo carregamento da inbox) marca pendentes >10 min como UNCONFIRMED. Alertas: UNCONFIRMED, UNREACHABLE (30003/5/6), CARRIER_FILTERED (30007), FAILED — painel "Text alerts" na aba Messages com "Passenger got it" / "Not received — allow resend" / "OK", quem/quando registrado.
4. **Sem SMS duplicado.** Servidor só diz `ok` quando a Twilio aceitou; duplicado de pendente/sem confirmação → `UNCONFIRMED`. SQL bloqueia: mesmo tipo (ou mesmo texto de reply) ainda sem confirmação → PREVIOUS_UNCONFIRMED; mesmo template/mesmo texto < 2 min com novo id → DUPLICATE_RECENT (correção de local continua permitida). Reenvio explícito só ADMIN/MANAGER (`resend:<id>`). App mantém o mesmo draft id após timeout/sem confirmação. Locks: mesmo SID (resultado × callback) e mesmo telefone (STOP × envio).
5. **Gorjeta removida.** Sem CUSTOMS_GRATUITY, sem variante TIP_NO com link, sem AIRVALET_GRATUITY_URL. Tip sim/não → mesma confirmação de entrega sem link; gorjeta Customs indisponível no modo servidor (fluxo nativo do iPhone inalterado).

## Adições
- **Ativação por funcionário:** `airvalet_sms_staff` (só ADMIN liga/desliga); `airvalet_sms_me()` no login: só quem está habilitado E com o programa ligado entra no modo servidor; demais ficam no SMS nativo. Exigido também no SQL (não dá para contornar pela função). Número de teste: `AIRVALET_SMS_TEST_ALLOWLIST` no modo allowlist.
- **Interruptor + limites (ADMIN, `airvalet_sms_settings`, começa DESLIGADO):** por telefone 4/h e 10/dia; por funcionário 40/h; total 300 mensagens e 600 segmentos/dia; máx. 3 segmentos por mensagem; texto livre sem links externos (só farberos.com / farberparking.com); ValidityPeriod 1 h na Twilio.
- **Rollback preserva dados:** nenhuma tabela é apagada; mensagens, consentimentos, opt-outs, status, ativações, configurações e auditoria de links vão para o schema privado `airvalet_archive` com carimbo de hora, sem acesso de anon/authenticated. Testado: dados criados antes do rollback aparecem no arquivo; re-apply limpo.
- Menores do review: ack do Needs Review usa `created_at`; inbox mostra "Could not load texts — retrying" em vez de lista vazia; sequences revogadas.

## Testes (todos verdes)
| Suite | Resultado |
|---|---|
| SQL (inclui Etapa 2: 50+ novos) | 292 OK; release + 5 migrations apply → rollback (dados arquivados) → re-apply |
| Concorrência | 20 claims mesma chave → 1; 20 envios contra teto com folga 5 → exatamente 5 |
| Integração DB | 8/8 (novos: timeout → alerta → callback tardio com mid resolve; ativação + interruptor no SQL) |
| Deno | 65/65 |
| Deno SSO / Node | 13/13 · 7/7 |
| E2E app | 28/28 |
| E2E Etapa 2 (app real) | 12/12 em 2 execuções |
| Segurança do link | 41/41 |
| Paridade v46 (native) | OK; Customer Copy / Key Copy sem nenhuma alteração |
Achado de infraestrutura de teste: o servidor local (Python) derrubava conexões em rajadas (backlog 5) → utils.js falhava → erro transitório `CUSTOMS_LOC`. Corrigido no harness (backlog 128): 0/25 falhas.
