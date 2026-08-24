# AirValet — Checklist Manual de QA Visual (Fase Hardening)

**Importante:** este checklist existe porque o ambiente desta sessão só consegue abrir `index.html` como um snapshot estático (o preview do navegador não executa JavaScript para arquivos fora do diretório principal de workspace). **Nenhum teste visual foi realizado por mim** — tudo abaixo foi verificado apenas por um harness Node.js headless (lógica/dados, sem renderização real). Este checklist deve ser executado manualmente, de preferência no iPad real usado em produção, antes de considerar a Fase Hardening visualmente validada.

**Como ativar o modo de teste:** abra o app → aba **Debug** → seção "🧪 SMS Provider (Development / Testing)" → selecione `mock_twilio` no dropdown. Isso não persiste (reseta ao recarregar a página) e não afeta dados reais.

---

## 1. Modal de simulação — desktop (navegador largo, > 1024px)

- [ ] Abra o painel de detalhe de um passageiro qualquer com telefone cadastrado.
- [ ] Clique em "💬 Welcome" (ou qualquer botão de SMS).
- [ ] O modal "🧪 Simulate Twilio Send" deve abrir centralizado, com fundo escurecido atrás.
- [ ] Todos os campos (Template, Message type, Trigger, Phone original, Phone E.164, corpo da mensagem, Status, Timestamp) devem estar legíveis, sem sobreposição.
- [ ] O dropdown "Simulate outcome" deve estar visível e clicável.
- [ ] Os botões "Cancel" e "Simulate Send" devem estar lado a lado, abaixo do conteúdo, sem cortar.

## 2. Largura de iPad (aprox. 768–1024px, retrato e paisagem)

- [ ] Repita o passo 1 no Safari do iPad, em retrato.
- [ ] Repita em paisagem.
- [ ] Confirme que o modal não ultrapassa a largura da tela (sem scroll horizontal).
- [ ] Confirme que o texto da mensagem (`.mock-sms-msgbox`) quebra linha corretamente para mensagens longas (ex.: teste com o template Welcome, que é o mais longo).

## 3. Largura de iPhone (aprox. 375–428px)

- [ ] Repita o passo 1 no Safari do iPhone (ou reduza a janela do navegador para ~375px de largura).
- [ ] O modal deve ancorar na parte inferior da tela (comportamento padrão dos outros modais do app — `.ov`/`.modal`) e ocupar quase toda a largura.
- [ ] Todos os textos devem continuar legíveis, sem cortar palavras no meio.
- [ ] Os botões Cancel/Simulate Send devem continuar tocáveis com o polegar (não espremidos).

## 4. Scroll interno do modal

- [ ] Com uma mensagem de template longo (ex.: Welcome com "not returning"), confirme que, se o conteúdo não couber na tela, o modal inteiro rola (não trava, não corta o rodapé com os botões).
- [ ] A caixa da mensagem (`.mock-sms-msgbox`) tem `max-height:160px` com scroll próprio — confirme que aparece uma barra de rolagem interna quando o texto excede essa altura, sem quebrar o layout do modal.

## 5. Teclado virtual (iPad/iPhone)

- [ ] Vá até o botão "💬 TEXT" genérico no painel de detalhe → deve abrir o modal "💬 Free-form Message" (não o Messages nativo, pois está em `mock_twilio`).
- [ ] Toque no campo de texto (`textarea`) — o teclado virtual deve subir sem cobrir o botão "Continue".
- [ ] Digite um texto de teste e confirme que o modal rola junto com o teclado, se necessário, mantendo o textarea visível.
- [ ] Feche o teclado e confirme que o layout volta ao normal sem espaços em branco residuais.

## 6. Botões Cancel e Send — comportamento e feedback

- [ ] No modal de simulação, clique em "Cancel" — o modal deve fechar imediatamente, sem nenhuma mudança visível no card/flag do passageiro.
- [ ] Reabra, escolha "✅ Success (delivered)" no dropdown, clique "Simulate Send" — os botões devem ficar desabilitados durante a simulação (~0.9s), o status deve progredir visualmente (Queued → Sent → Delivered), e o modal deve fechar sozinho após a confirmação.
- [ ] Repita escolhendo "🚫 Invalid phone" — confirme que aparece o bloco de erro vermelho (`.mock-sms-error`) com o código e a mensagem simulados, e que o status final mostra "Failed" em vermelho.

## 7. Textos longos

- [ ] Use o template Welcome com "not returning" ativado (o mais longo do sistema) e confirme que nenhuma palavra é cortada, nenhum botão é empurrado para fora da tela.
- [ ] No compose Free-form, digite um texto propositalmente longo (300+ caracteres) e confirme que o textarea cresce ou rola sem quebrar o modal.

## 8. Passageiro sem telefone

- [ ] Abra um passageiro sem telefone cadastrado (ou remova temporariamente o telefone de um registro de teste).
- [ ] Confirme que os botões de SMS (Welcome, Welcome Back, TEXT, Gratuity) não aparecem, OU que, se clicados via algum caminho indireto, aparece a mensagem "No phone number on file for [nome]" — sem abrir nenhum modal.

## 9. Status "Failed" — aparência

- [ ] Simule qualquer desfecho de falha (Invalid phone / Network failure / Rejected) e confirme visualmente que o badge de status usa a cor vermelha (`--red`) e o texto "Failed" (ou "Undelivered" no caso específico), consistente com o padrão de erro já usado em outras partes do app (ex.: mensagens de erro do `showMsg`).

## 10. Histórico vazio (aba Debug)

- [ ] Com o navegador limpo (ou após clicar "🗑 Clear Mock Data"), abra a aba Debug e confirme que a tabela "Mock SMS History" mostra a linha "No mock sends yet" centralizada, sem quebrar o layout da tabela.

## 11. Histórico com várias mensagens

- [ ] Simule pelo menos 5 envios diferentes (misture sucesso e falha).
- [ ] Confirme que a tabela cresce corretamente, cada linha mostra Hora/Passageiro/Template/Telefone/Status/SID sem sobreposição, e que a tabela tem scroll horizontal (`.epson-history-wrap{overflow-x:auto}`) se a largura da tela for pequena.

## 12. Galeria de demonstração estática (Debug → "🖼 SMS Demo Gallery")

- [ ] Abra a seção `<details>` "🖼 SMS Demo Gallery" na aba Debug.
- [ ] Confirme que os 3 cartões (modal de envio, estados individuais, conversa completa) renderizam corretamente, com as bolhas de mensagem alinhadas à direita (outbound, fundo azul-marinho) e à esquerda (inbound, fundo claro).
- [ ] Confirme que esta seção é puramente visual — nenhum botão dela deve alterar dados reais (ela não tem nenhum botão interativo, apenas texto estático).

---

**Ao concluir:** marque os itens que passaram e anote quaisquer divergências encontradas. Como nada disso foi validado automaticamente nesta sessão, trate este checklist como a fonte de verdade até que seja executado.
