# AirValet Twilio — Etapa 4 EXECUTADA (banco de produção preparado; nada ativado)

Projeto: `sfewtirvqhrpanwhbchd` = MAKERSAIRCARCONTROL (us-west-2, PG 17.6.1.121, ACTIVE_HEALTHY).
APPLY: 2026-10-10 19:59:31Z (≈15:59 ET), uma transação, guard OK, COMMIT. Dry-run em produção 19:59:00Z (revertido).

## 1. Migrations aplicadas (somente estas 3, nesta ordem)
| Arquivo | SHA-256 (16) |
|---|---|
| 20261009_create_airvalet_sms_messages.sql (modelo por DISPOSITIVO) | 4005cd031927bb3c |
| 20261010_create_airvalet_pass_links.sql | ddcac7d1c85af487 |
| 20261011_return_reviews_include_sms.sql | 5e3e1e1abd41a5dc |
Script aplicado: APPLY_guarded.sql daa1d13cf6486d7d (gerado por build_guarded.sh; o builder reproduz byte a byte os scripts anteriores).
Rollbacks prontos (ordem inversa): 141c01c8245ff35a · 3956e17658256ee0 · 8a380d0bb80afce7 — arquivam dados em `airvalet_archive`, nunca apagam.
Histórico `supabase_migrations` não alterado (convenção AirValet, igual ao Return/Pickup).

Criado: 9 tabelas (sms_messages, _status_events, _opt_outs, _consents, _settings, _devices, _enrollments; pass_links, pass_rate), 4 views, 29 funções, 7 policies, 24 índices, 4 sequences, 1 trigger em `passengers` (só escreve em pass_links). Alterado: view `airvalet_return_reviews` (mesmas colunas; origem SMS vazia). Removido do plano: tabela/funções por funcionário (`airvalet_sms_staff`, `_me`, `_set_staff`).

## 2. Banco e dados íntegros
- Catálogo pós vs T0: nenhum objeto pré-existente alterado/removido além da view planejada; todo objeto novo é `airvalet_sms_*`/`airvalet_pass_*`.
- Dados pós vs T1 (19:58:18Z): nenhuma tabela pré-existente mudou (só `aircraft_*`, atualizadas pelo cron de aeronaves). passengers 3.554, activity_log 5.528.
- Snapshot novo antes: catálogo + hash de dados (T1) + export local dos dados (`data_snapshot_20261010T195818Z/`, 6,1 MB, permissão só do dono; `sso_sessions` fora por conter segredos — coberta pelo hash). Backup diário Supabase 2026-10-10 13:04Z COMPLETED (PITR desligado).
- Estado inicial: envio DESLIGADO, test_only = ligado, 0 números de teste, sem cutover, 0 dispositivos, 0 inscrições, 0 mensagens/consentimentos/links. RLS ligado nas 9 tabelas; anon sem acesso a nada novo; authenticated executa só 11 funções planejadas; hash da chave do dispositivo ilegível.

## 3. v46
- App: airvalet.farberos.com SW v46, `SMS_PROVIDER = 'native'`; /pass.html, /a, /p/ = 404; farberos.com/a = 404 (rota não publicada).
- Leituras reais como `authenticated` + perfil Admin (transação READ ONLY): papel ADMIN, TV 3.554, 32 abertos, Needs Review 0, 4 usuários, 17 turnos.
- Réplica idêntica à produção: saídas v46 idênticas antes/depois/após rollback; escritas estilo v46 (telefone → DELIVERED → ARCHIVED) como authenticated OK, 0 links criados; desempenho igual (±ruído).
- Edge Functions: nenhuma nova (send-sms, twilio-*, valet-pass NÃO publicadas). FarberOS origin/main abccf5c inalterado. AirValet main 591ce5d inalterado.

## 4. Controle por dispositivo
- Cada aparelho gera uma chave aleatória (localStorage). O servidor guarda só o SHA-256.
- Aparelho pede autorização (`airvalet_sms_device_request`, login operacional; TV recusada) → fica *pending* → só ADMIN aprova/revoga (`airvalet_sms_device_decide`).
- Todo envio (`airvalet_sms_claim`) e toda inscrição no check-in (`airvalet_sms_record_consent`) exigem dispositivo APROVADO, validado no banco; o navegador não decide.
- Funcionário responsável = nome escolhido na interface (turnos de Clock In), gravado como rótulo de auditoria; não autoriza nada. Sem login individual.

## 5. Tickets antigos x novos
- Ticket só entra no programa Twilio NO CHECK-IN, em aparelho aprovado, com programa ligado, depois do cutover: `id > cutover_after_id` E `created_at ≥ cutover_at` (ambos do servidor), aberto, criado há ≤ 2 h.
- Ticket não inscrito → claim recusa (TICKET_NOT_ELIGIBLE) → app usa SMS do iPhone como hoje. Não existe caminho para migrar ticket antigo.
- Cutover só por ADMIN com a frase `START NEW CHECK-INS`; `STOP NEW CHECK-INS` fecha. Não se move sozinho.

## 6. Testes (locais/réplica) desta versão
Runner local exit 0: 321 checagens SQL, corrida 20→1, teto diário 20→5, integração 8/8; Deno 68/68. Réplica: DRYRUN/APPLY guard OK, suíte SMS 276 OK, rollback → public == T0 (8 tabelas arquivadas, 0 FKs), re-APPLY OK. Sabotagens 8/8 bloqueadas (anon grant, dado alterado, função v46 alterada, execute não planejado, dispositivo aprovado, test_only off, cutover setado, key_hash legível).
