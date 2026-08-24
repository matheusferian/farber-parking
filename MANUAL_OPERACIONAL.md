# MANUAL OPERACIONAL DO SISTEMA MAKERS AIR VALET
## Guia Completo de Treinamento para Colaboradores

---

**Data de Geração:** 22 de junho de 2026  
**Versão do Sistema:** Valet Control — Makers Air by Farber Parking  
**Base de Dados:** Supabase (nuvem)  
**Impressora:** Epson ePOS (rede local — IP 10.20.60.142)

---

## SUMÁRIO

1. [Visão Geral do Sistema](#1-visão-geral-do-sistema)
2. [Acesso ao Sistema](#2-acesso-ao-sistema)
3. [Tela Principal — Visão Geral](#3-tela-principal--visão-geral)
4. [Aba: All Passengers (Todos os Passageiros)](#4-aba-all-passengers-todos-os-passageiros)
5. [Aba: Dashboard](#5-aba-dashboard)
6. [Aba: Tasks (Tarefas)](#6-aba-tasks-tarefas)
7. [Aba: Flight List (Lista de Voo)](#7-aba-flight-list-lista-de-voo)
8. [Aba: Report (Relatórios)](#8-aba-report-relatórios)
9. [Aba: Logs (Registro de Atividades)](#9-aba-logs-registro-de-atividades)
10. [Aba: Debug (Diagnóstico)](#10-aba-debug-diagnóstico)
11. [Cadastro de Passageiros](#11-cadastro-de-passageiros)
12. [Explicação de Todos os Campos](#12-explicação-de-todos-os-campos)
13. [Status do Sistema](#13-status-do-sistema)
14. [Processo de Check-in](#14-processo-de-check-in)
15. [Processo de Check-out (Entrega)](#15-processo-de-check-out-entrega)
16. [Tipos de Entrega](#16-tipos-de-entrega)
17. [Avaliação do Passageiro](#17-avaliação-do-passageiro)
18. [Controle de Hangares (Localização)](#18-controle-de-hangares-localização)
19. [Impressões](#19-impressões)
20. [SMS e Comunicação com Passageiros](#20-sms-e-comunicação-com-passageiros)
21. [Ações em Lote (Bulk Actions)](#21-ações-em-lote-bulk-actions)
22. [Arquivamento de Registros](#22-arquivamento-de-registros)
23. [Retorno Antecipado (Early Return)](#23-retorno-antecipado-early-return)
24. [Exportação de Contatos](#24-exportação-de-contatos)
25. [Fluxo Operacional Diário](#25-fluxo-operacional-diário)
26. [Troubleshooting — Resolução de Problemas](#26-troubleshooting--resolução-de-problemas)
27. [Boas Práticas](#27-boas-práticas)
28. [Erros Mais Comuns](#28-erros-mais-comuns)
29. [Glossário](#29-glossário)
30. [Melhorias Futuras Sugeridas](#30-melhorias-futuras-sugeridas)

---

## MATERIAIS ADICIONAIS

- [Guia Rápido (1 página)](#guia-rápido)
- [Checklist de Treinamento](#checklist-de-treinamento)
- [POP — Procedimento Operacional Padrão](#pop--procedimento-operacional-padrão)
- [Fluxograma Operacional](#fluxograma-operacional)

---

---

# 1. VISÃO GERAL DO SISTEMA

## O que é o Sistema?

O **Makers Air Valet** é um sistema de gerenciamento operacional de valet aeronáutico utilizado pela empresa Makers Air, operado pela Farber Parking. O sistema é acessado por um navegador de internet (browser) e funciona como um aplicativo web — não precisa ser instalado.

## Para que serve?

O sistema é a central de controle de toda a operação de valet. Com ele, o colaborador pode:

- Cadastrar passageiros que chegam e entregam seus veículos
- Controlar onde cada veículo está estacionado (qual hangar)
- Acompanhar quais passageiros retornam hoje, amanhã ou em breve
- Marcar a entrega dos veículos quando o passageiro retorna
- Imprimir tickets para o passageiro e para a chave do veículo
- Enviar mensagens de texto (SMS) aos passageiros
- Verificar passageiros de voos que chegam
- Gerar relatórios operacionais mensais

## Objetivo Operacional

O objetivo do sistema é garantir que **nenhum veículo seja perdido, esquecido ou entregue incorretamente**. Ele serve como memória operacional da equipe: registra a chegada, controla a localização e alerta sobre saídas previstas.

## Benefícios para a Operação

- Elimina anotações em papel
- Evita erros de localização de veículos
- Envia alertas automáticos sobre passageiros que deveriam ter saído
- Facilita a comunicação com o passageiro via SMS
- Gera relatórios automáticos para gestão
- Registra todo histórico de ações da equipe

---

# 2. ACESSO AO SISTEMA

## Como Acessar

O sistema é acessado diretamente pelo navegador de internet. Abra o navegador e acesse o endereço fornecido pelo supervisor.

> **Importante:** O sistema não funciona offline. É necessário ter conexão com a internet.

## Tela de Login

Na tela de login, o colaborador verá:

- **Campo Email:** Digite o e-mail fornecido pelo seu supervisor
- **Campo Password (Senha):** Digite a senha fornecida
- **Botão Sign In:** Clique para entrar (ou pressione **Enter** no teclado)

Se o email ou senha estiver incorreto, uma mensagem de erro aparecerá em vermelho abaixo do botão.

## Como Sair (Sign Out)

No canto superior direito da tela, após fazer login, aparece o botão **Sign Out**. Clique nele para sair do sistema com segurança.

> **Dica:** O sistema mantém a sessão ativa. Se você fechar o navegador e reabrir, normalmente não precisará fazer login novamente no mesmo dispositivo.

## Navegadores Compatíveis

O sistema funciona nos seguintes navegadores:
- **Google Chrome** (recomendado)
- **Safari** (iPad e Mac)
- **Microsoft Edge**
- **Mozilla Firefox**

## Utilização em iPad

O sistema é otimizado para uso em **iPad**, que é o dispositivo principal da operação. No iPad:

- A tela se adapta automaticamente
- O zoom está desativado para melhor controle
- O sistema pode ser salvo na tela inicial como ícone (Add to Home Screen)
- O modo de aplicativo web pode ser ativado (apple-mobile-web-app-capable)

## Utilização em Computador

Em computadores desktop ou notebooks, o sistema funciona normalmente pelo navegador. A tela exibirá mais informações simultaneamente por conta do tamanho maior da tela.

## Recomendações Operacionais

- Mantenha o sistema aberto durante todo o turno
- Clique no botão **Refresh** (↻ Atualizar) periodicamente para garantir que os dados estão atualizados
- O indicador **🟢 Synced HH:MM** no topo mostra o horário da última sincronização com o banco de dados
- Nunca compartilhe sua senha com outros colaboradores

---

# 3. TELA PRINCIPAL — VISÃO GERAL

Após fazer login, você verá a tela principal com os seguintes elementos:

## Cabeçalho (Header)

No topo da tela:
- **MAKERS AIR VALET — Valet Operations:** Identificação do sistema
- **Data atual:** Exibida no canto direito (ex: Monday, June 22)
- **🟢 Synced HH:MM:** Indicador de sincronização com o banco de dados
- **↻ Refresh:** Botão para atualizar os dados manualmente
- **Sign Out:** Botão para sair do sistema

## Abas de Navegação

Abaixo do cabeçalho há 7 abas (tabs):

| Aba | Ícone | Função |
|-----|-------|--------|
| **All Passengers** | 👥 | Lista completa de todos os passageiros |
| **Dashboard** | 📊 | Visão do dia: chegadas, saídas e alertas |
| **Tasks** | ✅ | Confirmações pendentes de data de retorno |
| **Flight List** | ✈️ | Verificação de passageiros de voos chegando |
| **Report** | 📈 | Geração de relatórios e PDF |
| **Debug** | 🔧 | Diagnóstico de conexão (uso técnico) |
| **Logs** | 📋 | Histórico de todas as ações realizadas |

## Botão "+ New Entry" (Nova Entrada)

Um botão flutuante (FAB) no canto inferior direito da tela. Clique nele para cadastrar um novo passageiro.

---

# 4. ABA: ALL PASSENGERS (TODOS OS PASSAGEIROS)

Esta é a aba principal do sistema. Exibe todos os passageiros cadastrados em formato de tabela.

## Barra de Estatísticas (Stats Bar)

No topo da aba, uma série de chips coloridos mostra resumos rápidos. Clique em qualquer chip para filtrar a lista:

| Chip | Cor | O que mostra |
|------|-----|--------------|
| **Total** | Azul marinho | Todos os registros no sistema |
| **Pending** | Âmbar/laranja | Veículos ainda em custódia |
| **No Date** | Roxo | Passageiros sem data de retorno definida |
| **Delivered** | Verde | Veículos já entregues |
| **Out Today** | Âmbar | Passageiros que deveriam sair hoje |
| **Out Tomorrow** | Roxo | Passageiros que saem amanhã |
| **Next Sunday** | Laranja escuro | Passageiros com retorno no próximo domingo (aparece quando há registros) |
| **Overdue** | Vermelho | Passageiros com data de retorno vencida (aparece quando há registros) |
| **Archived** | Cinza | Registros arquivados (aparece quando há registros) |

## Barra de Pesquisa (Search)

Campo de busca no topo da lista. Você pode pesquisar por:
- Nome do passageiro
- Número do ticket
- Número de telefone
- Modelo do veículo
- Localização (hangar)

A busca é feita em tempo real enquanto você digita.

## Filtros Rápidos

Botões de filtro abaixo da barra de pesquisa:

| Botão | Função |
|-------|--------|
| **All** | Mostra todos os registros |
| **Pending** | Apenas registros com status PENDING |
| **No Date** | Apenas registros sem data de retorno |
| **Delivered** | Apenas registros entregues |
| **Out Today** | Passageiros que devem sair hoje (não entregues) |
| **Out Tomorrow** | Passageiros que devem sair amanhã |
| **📅 Sunday** | Passageiros com retorno no próximo domingo |
| **Overdue** | Passageiros com data vencida |
| **Frequent** | Passageiros que já utilizaram o serviço mais de uma vez |
| **📦 Archived** | Registros arquivados |

## Tabela de Passageiros

A tabela principal exibe as seguintes colunas (clicáveis para ordenar):

| Coluna | Descrição |
|--------|-----------|
| **☐** (checkbox) | Seleção para ações em lote |
| **Name** | Nome do passageiro (em maiúsculas) |
| **Phone** | Telefone do passageiro |
| **Ticket** | Número do ticket |
| **Car** | Modelo do veículo |
| **Color** | Cor do veículo |
| **Location** | Hangar onde o veículo está estacionado |
| **Arrived** | Data de chegada |
| **Return** | Data de retorno prevista |
| **Status** | Status atual (PENDING, NO DATE, DELIVERED, ARCHIVED) |
| **Action** | Botão de ação rápida (✓ para marcar entregue) |

## Indicadores Visuais na Tabela

- **TODAY:** Etiqueta laranja no nome — passageiro que retorna hoje
- **TMR:** Etiqueta roxa — passageiro que retorna amanhã
- **LATE:** Etiqueta vermelha — passageiro com data vencida
- **~APPROX:** Etiqueta dourada — passageiro com data aproximada (não confirmada)
- **x2, x3...:** Indicador de passageiro frequente (número de visitas)

## Botão de Ação Rápida (✓)

O botão ✓ na coluna Action permite marcar rapidamente o veículo como entregue. Ao clicar, o sistema abrirá a tela de avaliação do passageiro (rating).

---

# 5. ABA: DASHBOARD

O Dashboard é a visão operacional do dia. Ele exibe cartões (cards) organizados por grupos de saída.

## Seções do Dashboard

### 🚗 Arrived Today — Chegaram Hoje
**Objetivo:** Mostra todos os passageiros que fizeram check-in hoje.  
**Quando usar:** Para verificar quem chegou durante o turno.  
**Atenção:** Se um cartão mostrar **🔴 NO HANGAR**, significa que o veículo foi cadastrado sem localização. Isso precisa ser corrigido imediatamente.

---

### 🔔 Leaving Today — Saindo Hoje
**Objetivo:** Passageiros com data de retorno igual a hoje (não entregues).  
**Quando usar:** Prioridade máxima — esses veículos precisam ser preparados para entrega.  
**Funções disponíveis nos cartões:**
- **✓ Deliver:** Marcar entrega normal
- **Customs:** Marcar entrega via Customs
- **🔒 Lockbox:** Marcar entrega via Lockbox
- **🖨 (ícone de impressão):** Imprimir Flight Tag individual
- **Campos de voo:** Inserir número do voo (ex: AA1234) e horário de partida (HH:MM)

O título dessa seção também exibe um botão **🖨 Print All** para imprimir todas as Flight Tags de uma vez.

---

### 📆 Leaving Tomorrow — Saindo Amanhã
**Objetivo:** Passageiros com retorno previsto para amanhã.  
**Quando usar:** No final do turno, para preparação do dia seguinte.  
**Funções:** Mesmas da seção "Leaving Today", incluindo campos de voo e impressão de Flight Tags.

---

### 📅 Returning Sunday — Retornando no Domingo
**Objetivo:** Passageiros cujo retorno cai no próximo domingo.  
**Quando usar:** Para antecipar o planejamento operacional do fim de semana.

---

### ⚠️ Forgot Yesterday — Esquecidos Ontem
**Objetivo:** Alerta crítico! Mostra passageiros cuja data de retorno era ontem e que ainda não foram marcados como entregues.  
**Quando usar:** Todos os dias ao abrir o sistema. Esses registros precisam ser verificados urgentemente.  
**Ação:** Verificar se o passageiro foi entregue e esquecido de marcar, ou se realmente não foi entregue.

> ⚠️ **ATENÇÃO:** Esta seção só aparece quando há registros. Se aparecer, é prioridade máxima resolver antes de qualquer outra atividade.

## Como interagir com os Cartões do Dashboard

Cada cartão exibe:
- Nome do passageiro
- Modelo do veículo e telefone
- Número do ticket
- Localização (hangar)
- Campo de voo (nas seções de saída)
- Botões de entrega

**Clique em qualquer cartão** para abrir o painel completo do passageiro.

---

# 6. ABA: TASKS (TAREFAS)

Esta aba gerencia **confirmações pendentes de data de retorno**.

## Quando um passageiro aparece nas Tasks?

Um passageiro aparece nas Tasks quando foi cadastrado com:
- Status **NO DATE** e uma **data estimada** (marcada como APPROX no campo OBS)
- Ou quando a data de retorno foi inserida com a nota APPROX/ESTIMATED

Isso acontece quando o passageiro não tem certeza de quando voltará — o colaborador registra uma data aproximada para acompanhamento.

## O que fazer nas Tasks?

Para cada passageiro na lista:

1. **Ver o registro:** Clique em "👁 View" para abrir o painel completo
2. **Enviar texto:** Clique em "💬 Send Text" para abrir o SMS com mensagem pré-pronta pedindo confirmação da data
3. **Confirmar a data:** Quando o passageiro responder com a data, selecione a data no campo e clique em "✓ Set Date"
4. **Marcar como confirmado:** Após definir a data, o cartão muda para status CONFIRMADO
5. **Desfazer:** O botão "↺ Undo" reverte uma confirmação feita por engano

## Mensagem Automática de Confirmação

Ao clicar em "Send Text", o sistema abre o aplicativo de mensagens com este texto pré-preenchido:

> *"Hi! This is Makers Air Valet. We are reaching out to confirm your return date so we can update our records. Please let us know when you plan to return. Thank you!"*

## Badge de Notificação

O número em vermelho na aba Tasks indica quantas confirmações estão pendentes. Zero significa que todas as datas foram confirmadas.

---

# 7. ABA: FLIGHT LIST (LISTA DE VOO)

Esta aba permite verificar quais passageiros de um voo chegando têm veículo no valet.

## Quando usar?

Quando a equipe de handling ou operações informa que um voo está chegando e fornece a lista de passageiros. Você verifica se algum deles tem carro estacionado.

## Como usar?

### Passo 1 — Preencher informações do voo (opcional mas recomendado)
- **Tail Number:** Prefixo da aeronave (ex: N624JR)
- **Arrival (ETA):** Horário de chegada previsto (ex: 08:45)
- **Flight Date:** Data do voo

### Passo 2 — Colar a lista de passageiros
No campo de texto grande, cole ou digite os nomes dos passageiros, **um por linha**.

Exemplo:
```
CHRISTOPHER KILLIAN
ASHLEY KILLIAN
NICOLE TARUMIANZ
```

### Passo 3 — Executar a verificação
Clique no botão **✅ CHECK NOW**.

### Passo 4 — Interpretar os resultados

O sistema mostrará dois grupos:
- **✅ FOUND IN VALET (X):** Passageiros que têm veículo no valet. Cada cartão mostra nome, veículo, telefone, ticket e hangar.
- **❌ NOT IN VALET (X):** Passageiros que não têm registro no sistema.

Clique em qualquer cartão de resultado para abrir o painel completo do passageiro e preparar a entrega.

### Reiniciar a busca
Clique em **↻ New Check** para limpar os campos e fazer uma nova verificação.

---

# 8. ABA: REPORT (RELATÓRIOS)

Esta aba permite gerar três tipos de relatório:

---

## 8.1 Relatório de Passageiros (PDF)

### Como gerar?

1. Selecione a **data** desejada no campo de data
2. Escolha o **tipo de relatório** clicando em uma das pills:
   - **All Pending:** Todos os registros não entregues
   - **✈️ Tomorrow:** Passageiros que chegam amanhã
   - **📅 No Date:** Passageiros sem data
   - **🔔 Today:** Passageiros que saem hoje
   - **⚠️ Overdue:** Passageiros com data vencida
3. Veja a pré-visualização na tabela abaixo
4. Clique em **🖨️ Print / Save PDF** para imprimir ou salvar
5. Ou clique em **🔗 Open in New Tab** para abrir em nova aba

### O que o relatório contém?
- Lista de passageiros com: número, nome, telefone, ticket, veículo, localização, data de retorno, status, tipo de entrega e observações.

---

## 8.2 Relatório Operacional Mensal (Operations Report)

Este relatório é voltado para a **gestão e análise** da operação.

### Como gerar?

1. Selecione o **mês** e o **ano** nos campos correspondentes
2. Selecione o **filtro de entrega:**
   - **All Deliveries:** Todas as entregas
   - **Normal Only:** Apenas entregas normais
   - **Customs Only:** Apenas entregas via Customs
   - **Lockbox Only:** Apenas entregas via Lockbox
3. Clique em **📊 Generate Operations PDF**

### O que o relatório contém?

O relatório mensal inclui análise de:
- **Total de Check-ins e Entregas do mês**
- **Dia da semana mais movimentado**
- **Hangar mais ativo**
- **Volume operacional por dia da semana** (média de check-ins e entregas)
- **Top 10 dias mais movimentados**
- **Matriz de utilização dos hangares por dia da semana**
- Dados úteis para **escala de pessoal (staffing)**

---

## 8.3 Exportação de Contatos (.vcf)

Permite exportar os contatos dos passageiros para o iPhone/iPad.

- **📇 Export All Contacts (.vcf):** Exporta todos os contatos únicos
- **🆕 Export New Contacts (.vcf):** Exporta apenas contatos adicionados desde a última exportação

Após exportar, o status "Last contacts export" é atualizado. O botão **↺ Reset Export Date** zera essa marcação.

> **Como usar o .vcf:** Após baixar o arquivo, abra-o no iPad. O sistema pedirá para importar os contatos para o app Contatos.

---

# 9. ABA: LOGS (REGISTRO DE ATIVIDADES)

Esta aba mostra o histórico das últimas 200 ações realizadas no sistema.

## Como acessar?

Clique na aba **Logs** e depois no botão **⟳ Refresh** para carregar os logs.

## O que os logs registram?

| Ação | Descrição |
|------|-----------|
| **CREATED** | Novo passageiro cadastrado |
| **DELIVERED** | Veículo entregue |
| **EDITED** | Informação editada |
| **STATUS** | Status alterado |
| **RETURN DATE** | Data de retorno alterada |
| **ARCHIVED** | Registro arquivado |
| **DELETED** | Registro excluído |
| **EARLY RETURN** | Retorno antecipado registrado |
| **REOPENED** | Registro reaberto de DELIVERED |
| **FLIGHT_NOTE** | Número de voo ou horário de partida salvo |

## Para que serve?

- Auditar ações da equipe
- Verificar quem fez o quê e quando
- Resolver dúvidas sobre movimentações de veículos
- Identificar erros operacionais

Cada log exibe: **Horário · Ação · Nome do Passageiro · Ticket · Localização · Detalhe**

---

# 10. ABA: DEBUG (DIAGNÓSTICO)

Esta aba é de **uso técnico** e destina-se a verificar a conectividade do sistema.

> ⚠️ **Não use esta aba durante a operação normal. Somente em caso de problema técnico.**

## Funções disponíveis

- **▶ Run Connection Test:** Testa a conexão com o banco de dados Supabase
- **📄 Test Append (writes TEST row):** Insere uma linha de teste no banco. Use com cuidado — depois delete o registro "TEST PASSENGER"
- **📦 Archive All Pending Records From 2025:** Arquiva automaticamente todos os registros pendentes do ano de 2025

---

# 11. CADASTRO DE PASSAGEIROS

## Como abrir o formulário de cadastro?

Clique no botão **+ New Entry** (canto inferior direito da tela, botão flutuante azul).

## Preenchimento Passo a Passo

### Passo 1 — Nome Completo (obrigatório)
- Digite o nome completo do passageiro
- O sistema converte automaticamente para maiúsculas
- **Autocomplete:** Ao digitar, o sistema sugere nomes já cadastrados. Se o passageiro já esteve antes, clique no nome sugerido para preencher automaticamente os outros campos.

### Passo 2 — Telefone (obrigatório)
- Digite apenas os números — o sistema formata automaticamente: (XXX) XXX-XXXX
- Ao digitar nome + telefone, o sistema verifica se é um **passageiro frequente** e mostra o histórico de visitas anteriores.

### Passo 3 — Ticket # (obrigatório)
- O sistema sugere automaticamente um número de ticket baseado na data atual (formato: MMDD-N)
- Exemplo: Para 22 de junho, o sistema sugerirá `0622-1`, `0622-2`, etc.
- Você pode alterar o número sugerido se necessário

### Passo 4 — Return Date (Data de Retorno)
- Obrigatório para status PENDING
- Selecione a data pelo calendário
- Se o passageiro **não souber a data**, selecione o status **NO DATE** antes de preencher (o campo de data ficará desativado)

### Passo 5 — Vehicle (Veículo)
- Digite o modelo do veículo
- O sistema oferece sugestões automáticas de veículos comuns (Escalade, Suburban, Tahoe, etc.)
- Novos veículos são salvos automaticamente para sugestões futuras

### Passo 6 — Color (Cor) — Opcional
- Informe a cor do veículo para facilitar a identificação

### Passo 7 — Location (Localização)
- Clique no hangar correspondente:
  - **Hangar 19**
  - **Hangar 18**
  - **Hangar 16**
  - **Hangar 7**
  - **HH**
- O botão selecionado fica destacado

### Passo 8 — Status
- **PENDING:** Veículo em custódia com data de retorno definida (padrão)
- **NO DATE:** Passageiro sem data de retorno
  - Ao selecionar NO DATE, aparece um campo extra: **Estimated Return Date** (Data Estimada), onde você pode inserir uma data aproximada. Isso criará uma tarefa de confirmação na aba Tasks.
- **DELIVERED:** Use apenas se estiver editando um registro já entregue

### Passo 9 — OBS (Observações)
- Campo de texto livre para anotações
- Exemplos: "EARLY RETURN", "DAMAGED", "NEEDS CLEANING"
- O sistema converte automaticamente para maiúsculas

### Passo 10 — Not Returning with Makers Air
- Marque esta caixinha se o passageiro informou que **não voltará** com a Makers Air
- Esta informação aparecerá no ticket impresso como aviso

## Alertas Automáticos no Formulário

### Aviso de Passageiro Frequente
Se o passageiro já esteve antes, aparece uma barra informativa:
> "2 previous visit(s). Last: 0622-1 - Escalade"

### Aviso de Early Return
Se o histórico do passageiro contém a nota "EARLY RETURN", aparece um alerta em amarelo:
> "⚠️ HEADS UP: This passenger had an Early Return before. Confirm the return date carefully."

### Aviso de Ticket Duplicado
Se o ticket informado já existe no sistema, aparece um aviso (mas o sistema permite salvar mesmo assim).

## Botões de Salvamento

| Botão | Função |
|-------|--------|
| **💬 Save + Text** | Salva o registro E abre o SMS de boas-vindas |
| **Save Only** | Salva sem enviar SMS |
| **🖨 Save + Print + Text** | Salva, imprime os 3 tickets (Customer, Key, Dashboard) E envia SMS |
| **Cancel** | Cancela sem salvar |

> **💡 Recomendação:** Use sempre **Save + Print + Text** para garantir que o passageiro receba o SMS e os tickets sejam impressos.

## Save to Contacts (Salvar Contato)

Ao preencher nome e telefone, aparece um link **👤 Save to Contacts** que permite baixar o contato como arquivo .vcf para salvar no iPad.

## Proteção contra saída acidental

Se você começou a preencher o formulário e clicou em "Cancel", o sistema exibe um alerta:
> "⚠️ Unsaved passenger data detected. If you leave now, all entered data will be lost."

Opções: **Keep Editing** (continuar editando) ou **Discard** (descartar).

---

# 12. EXPLICAÇÃO DE TODOS OS CAMPOS

| Campo | Nome em Inglês | Finalidade | Exemplo |
|-------|---------------|------------|---------|
| Nome | Full Name | Nome completo do passageiro | CHRISTOPHER KILLIAN |
| Telefone | Phone | Número de celular do passageiro | (954) 352-1010 |
| Ticket | Ticket # | Número único de identificação do serviço | 0622-1 |
| Data de Retorno | Return Date | Data prevista para o passageiro buscar o veículo | 06/25/2026 |
| Veículo | Vehicle | Modelo/marca do carro | Escalade |
| Cor | Color | Cor do veículo | Black |
| Localização | Location | Hangar onde o veículo está estacionado | HANGAR 19 |
| Status | Status | Situação atual do registro | PENDING |
| Data Estimada | Estimated Return Date | Data aproximada (quando não há certeza) | 06/28/2026 |
| Observações | OBS | Notas gerais sobre o passageiro ou veículo | EARLY RETURN |
| Não Retorna | Not Returning | Indica que o passageiro não voltará com Makers Air | ☑ marcado |
| Número do Voo | Return Flight | Voo de retorno do passageiro | AA1234 |
| Horário de Partida | Departure Time | Horário de partida do voo | 17:30 |
| Data de Chegada | Arrived | Quando o passageiro chegou e fez check-in | Jun 22, 2026 |
| Data de Entrega | Delivered | Quando o veículo foi entregue | Jun 25, 2026 |
| Tipo de Entrega | Delivery Type | Como o veículo foi entregue | NORMAL / CUSTOMS / LOCKBOX |
| Avaliação | Customer Rating | Avaliação do passageiro pela equipe | GREAT / NORMAL / DIFFICULT |
| Arquivado por | Archived By | Nome de quem arquivou o registro | MATHEUS |
| Arquivado em | Archived At | Data e hora do arquivamento | 06/22/2026 11:30 AM |

---

# 13. STATUS DO SISTEMA

O sistema trabalha com 4 status possíveis para cada registro:

---

## 🟡 PENDING

**Significado:** Veículo está em custódia, aguardando o passageiro buscar.  
**Quando usar:** Status padrão. Todo veículo que chega começa como PENDING.  
**Cor na interface:** Âmbar/laranja  
**Condição:** O campo Return Date é obrigatório para este status.

---

## 🟣 NO DATE

**Significado:** Veículo está em custódia, mas o passageiro não tem data de retorno definida.  
**Quando usar:** Quando o passageiro não sabe quando voltará.  
**Cor na interface:** Roxo  
**O que acontece:** O campo Return Date fica desativado. Um campo de **data estimada** aparece (opcional).  
**Atenção:** Registros NO DATE com data estimada aparecerão nas Tasks para confirmação posterior.

---

## 🟢 DELIVERED

**Significado:** Veículo já foi entregue ao passageiro.  
**Quando usar:** Ao finalizar a entrega do veículo.  
**Cor na interface:** Verde  
**O que é registrado:** Data de entrega, tipo de entrega (NORMAL/CUSTOMS/LOCKBOX) e avaliação do passageiro.

---

## 📦 ARCHIVED

**Significado:** Registro arquivado — histórico de serviços passados.  
**Quando usar:** Ao encerrar um período operacional (ex: fim de ano) ou para limpar registros antigos.  
**Cor na interface:** Cinza  
**Importante:** Registros arquivados não aparecem nos filtros normais. Para visualizá-los, use o filtro "📦 Archived".

---

# 14. PROCESSO DE CHECK-IN

O check-in é o momento em que o passageiro chega, entrega as chaves do veículo e este é levado para o hangar.

## Fluxo Completo de Check-in

### 1. Passageiro chega
O colaborador recebe o passageiro e coleta as informações necessárias.

### 2. Abrir formulário de cadastro
Clique no botão **+ New Entry** (canto inferior direito).

### 3. Preencher os dados
- **Nome:** Nome completo do passageiro (em maiúsculas)
- **Telefone:** Celular com DDD
- **Ticket:** Aceite o número sugerido ou insira o número do ticket físico
- **Data de Retorno:** Confirme com o passageiro quando ele pretende voltar
- **Veículo:** Modelo/marca do carro
- **Cor:** Cor do veículo
- **Localização:** Clique no hangar onde o carro vai ficar

> Se o passageiro não souber a data de retorno, selecione **NO DATE** e informe uma data estimada se possível.

### 4. Verificar informações
Confirme com o passageiro:
- Número do ticket (o passageiro deve guardar este número)
- Data de retorno
- Número de telefone (para comunicações futuras)

### 5. Salvar e imprimir
Clique em **🖨 Save + Print + Text** para:
- Salvar o registro no sistema
- Imprimir os 3 tickets automaticamente (Customer Copy, Key Copy, Dashboard Copy)
- Abrir o SMS de boas-vindas para o passageiro

### 6. Entregar ticket ao passageiro
O **Customer Copy** (ticket do passageiro) deve ser entregue ao passageiro. Oriente-o a guardar o número do ticket e a entrar em contato se a data mudar.

### 7. Fixar etiqueta na chave
O **Key Copy** (ticket da chave) fica preso às chaves do veículo.

### 8. Colocar ticket no painel do veículo
O **Dashboard Copy** é colocado dentro do carro, visível no painel.

### 9. Levar o veículo para o hangar
O veículo é levado para o hangar selecionado no sistema.

---

# 15. PROCESSO DE CHECK-OUT (ENTREGA)

O check-out é o momento em que o passageiro volta e busca seu veículo.

## Fluxo Completo de Check-out

### 1. Passageiro solicita o veículo
O passageiro informa seu nome ou número do ticket.

### 2. Localizar o registro
Na aba **All Passengers**, pesquise pelo nome ou ticket do passageiro no campo de busca.  
Ou verifique na aba **Dashboard** → seção "Leaving Today" se o passageiro está na lista.

### 3. Abrir o painel do passageiro
Clique na linha do passageiro na tabela para abrir o painel de detalhes.

### 4. Confirmar identidade
Verifique o modelo e cor do veículo, compare com o ticket físico que o passageiro apresenta.

### 5. Buscar o veículo
O painel mostra o **hangar e localização** do veículo. Vá buscar o veículo.

### 6. Marcar como entregue
Clique em **Mark as Delivered** (no painel do passageiro) ou use o botão **✓** na tabela.  
O sistema abrirá a tela de avaliação do passageiro.

### 7. Selecionar o tipo de entrega
- **✓ Deliver:** Entrega normal (passageiro está presente)
- **Customs:** Entrega via área de Customs
- **🔒 Lockbox:** Chave depositada no Lockbox

### 8. Avaliar o passageiro
Selecione a avaliação:
- 🟢 **Great** — Passageiro excelente
- ⚪ **Normal** — Atendimento padrão
- 🔴 **Difficult** — Passageiro difícil

### 9. Confirmar entrega
O sistema registra automaticamente a data e hora de entrega.

---

# 16. TIPOS DE ENTREGA

## 📋 Normal

**Quando usar:** Entrega padrão diretamente ao passageiro no pátio.  
**Procedimento:**
1. Passageiro chega e apresenta o ticket
2. Equipe busca o veículo no hangar indicado
3. Veículo é trazido ao passageiro
4. Passageiro confere o veículo e assina se necessário
5. Marcar como DELIVERED com tipo "Normal" no sistema

---

## 📦 Customs

**Quando usar:** Quando o passageiro precisa passar pela área de Customs (alfândega) antes de retirar o veículo.  
**Procedimento:**
1. Passageiro chega e está em processo de desembaraço alfandegário
2. Equipe prepara o veículo antecipadamente
3. Veículo aguarda na área de saída
4. Após liberação pelo Customs, passageiro recebe o veículo
5. Marcar como DELIVERED com tipo "Customs" no sistema

**Cuidado:** Nunca entregue o veículo antes da liberação do Customs.

---

## 🔒 Lockbox

**Quando usar:** Quando o passageiro não pode estar presente para receber o veículo pessoalmente.  
**Procedimento:**
1. Passageiro solicita entrega via Lockbox com antecedência
2. Equipe leva o veículo ao local designado
3. A chave é depositada no Lockbox com o número do ticket
4. Passageiro é notificado (geralmente por SMS) com as instruções de acesso
5. Marcar como DELIVERED com tipo "Lockbox" no sistema

**Cuidado:** Confirme o número do Lockbox e as instruções de acesso antes de depositar a chave.

---

# 17. AVALIAÇÃO DO PASSAGEIRO

A avaliação é registrada no momento da entrega e serve para identificar passageiros que precisam de atenção especial.

## Como funciona?

Ao marcar uma entrega (seja pelo botão ✓ na tabela ou "Mark as Delivered" no painel), o sistema abre a tela de avaliação com 3 opções:

| Avaliação | Cor | Significado |
|-----------|-----|-------------|
| 🟢 **Great** | Verde | Passageiro educado, sem problemas |
| ⚪ **Normal** | Cinza | Atendimento padrão, sem destaque |
| 🔴 **Difficult** | Vermelho | Passageiro que causou problemas ou foi exigente |

A avaliação fica registrada no histórico do passageiro e aparece automaticamente nas próximas visitas, permitindo que a equipe se prepare.

> **Dica:** A avaliação DIFFICULT não é enviada ao passageiro — é apenas para uso interno da equipe.

---

# 18. CONTROLE DE HANGARES (LOCALIZAÇÃO)

O controle de hangar garante que nenhum veículo seja perdido.

## Hangares disponíveis

| Código | Nome |
|--------|------|
| HANGAR 19 | Hangar 19 |
| HANGAR 18 | Hangar 18 |
| HANGAR 16 | Hangar 16 |
| HANGAR 7 | Hangar 7 |
| HH | HH (Helicopter Hangar ou designação específica) |

## Como definir a localização no check-in

No formulário de cadastro, clique no botão correspondente ao hangar. O botão selecionado ficará destacado.

## Como mover um veículo de hangar

### Método 1 — Pelo Painel do Passageiro
1. Abra o painel do passageiro (clicando na linha ou no cartão)
2. Role até a seção **"Move Hangar"**
3. Clique no nome do hangar destino
4. O sistema perguntará: *"Hangar location changed. Would you like to print a new key tag?"*
5. Clique **OK** para imprimir uma nova etiqueta de chave com a localização atualizada

### Método 2 — Edição Inline
1. Abra o painel do passageiro
2. Clique na linha "Location ✎"
3. Selecione o novo hangar no menu suspenso
4. Clique em **💾 Save Changes**

### Método 3 — Ação em Lote (mover vários de uma vez)
(Ver seção 21 — Ações em Lote)

## Alerta de "NO HANGAR"

Se um veículo foi cadastrado sem localização, o Dashboard exibirá:
> **🔴 NO HANGAR** no cartão do passageiro

E no título da seção "Arrived Today":
> **🔴 X MISSING HANGARS**

Isso deve ser corrigido imediatamente — um veículo sem localização pode ser perdido.

---

# 19. IMPRESSÕES

O sistema se conecta a uma **impressora Epson ePOS** na rede local (padrão: IP 10.20.60.142) para impressão automática de tickets.

## Tipos de Impressão

### 🧾 Customer Copy (Ticket do Passageiro)

**Finalidade:** Comprovante entregue ao passageiro.  
**Conteúdo:**
- Cabeçalho: MAKERS AIR VALET / by Farber Parking / PARKING CLAIM CHECK
- Número do ticket (em destaque grande)
- Data de retorno
- Nome do passageiro
- Telefone
- Instruções: Tirar foto do ticket, ligar se a data mudar — (954) 352-1010
- Aviso se o passageiro não voltará com Makers Air
- Aviso de isenção de responsabilidade
- "Thank you for flying Makers Air."

**Como imprimir:**  
No painel do passageiro, clique em **🧾 Customer Copy**

---

### 🔑 Key Copy (Ticket da Chave)

**Finalidade:** Etiqueta interna presa às chaves do veículo.  
**Conteúdo:**
- Cabeçalho: MAKERS AIR VALET / KEY COPY / INTERNAL
- Nome do passageiro (em destaque grande)
- Hangar (localização)
- Data de retorno
- Número do ticket
- Telefone
- Modelo e cor do veículo
- Aviso se passageiro não voltará com Makers Air
- Campo OBS (para anotações manuais)

**Como imprimir:**  
No painel do passageiro, clique em **🔑 Key Copy**

> **Dica:** Sempre que mover um veículo de hangar, imprima uma nova Key Copy com a localização atualizada!

---

### 🚗 Dashboard Copy (Ticket do Painel)

**Finalidade:** Etiqueta colocada dentro do veículo, visível no painel.  
**Conteúdo:**
- Número do ticket (em tamanho gigante)
- Data de retorno (ex: THU JUN 25)

**Como imprimir:**  
No painel do passageiro, clique em **🚗 Dashboard**

---

### 🖨 Print All (Imprimir Todos)

**Finalidade:** Imprime os 3 tickets de uma vez (Customer + Key + Dashboard).  
**Como usar:**
- No painel do passageiro: clique em **🖨 Print All**
- No formulário de cadastro: botão **🖨 Save + Print + Text**

---

### ✈️ Flight Tag (Etiqueta de Voo)

**Finalidade:** Etiqueta pequena para identificação durante o processo de entrega por voo. Fica na bolsa/envelope da chave.  
**Conteúdo:**
- Número do voo e horário de partida
- Nome resumido do passageiro
- Número do ticket
- Localização (hangar)

**Como imprimir:**
- **Individual:** No Dashboard, seção "Leaving Today" ou "Leaving Tomorrow", clique no ícone 🖨 no cartão do passageiro. Confirme com "Print flight tag for [Nome]?"
- **Todos de uma vez:** Clique em **🖨 Print All** no título das seções "Leaving Today" ou "Leaving Tomorrow". O sistema imprimirá as tags em ordem de horário de partida.

> **Importante:** As Flight Tags são impressas em ordem crescente de horário de partida (quem sai mais cedo primeiro).

---

## Configuração da Impressora

O endereço IP padrão da impressora é `10.20.60.142`. Se a impressora mudar de IP, o supervisor pode atualizar isso via console do navegador com o comando `setPrinterHost('NOVO.IP.AQUI')`.

---

# 20. SMS E COMUNICAÇÃO COM PASSAGEIROS

O sistema utiliza o aplicativo de mensagens do dispositivo (iPhone/iPad) para enviar SMS. As mensagens são pré-preenchidas automaticamente.

## Welcome SMS (SMS de Boas-Vindas)

Enviado no momento do check-in ao clicar em "Save + Text" ou "Save + Print + Text".

**Conteúdo da mensagem:**

> Welcome to Makers Air Valet!
> 
> Your vehicle has been successfully checked in.
> 
> Ticket #: [NÚMERO DO TICKET]
> 
> Please keep this ticket number for reference.
> 
> If your return date or arrival time changes from [DATA DE RETORNO], please reply to this message so your vehicle will be ready upon arrival.
> 
> Thank you and safe travels!

**Se o passageiro não souber a data de retorno:**
> We currently do not have a return date on file. Once your travel plans are confirmed, please reply to this message with your expected return date and arrival time so your vehicle will be ready upon arrival.

**Se o passageiro informou que não voltará com Makers Air:**
> NOTE: You informed us that you will not be returning with Makers Air. If this information changes, please reply to this message.

---

## Como reenviar o SMS de Boas-Vindas

No painel do passageiro, clique no botão verde **💬 Welcome**.

---

## SMS Direto

No painel do passageiro, clique em **💬 TEXT** para abrir uma mensagem SMS sem texto pré-definido para comunicações gerais.

---

## Ligação Telefônica

No painel do passageiro, clique em **📞 CALL** para ligar diretamente para o passageiro.

---

## SMS de Confirmação de Data (Tasks)

Para passageiros com data aproximada, a mensagem pré-pronta é:
> Hi! This is Makers Air Valet. We are reaching out to confirm your return date so we can update our records. Please let us know when you plan to return. Thank you!

---

## SMS de Confirmação (via painel — passageiro com data aproximada)

No painel do passageiro com data APPROX, aparece um botão especial:
> 💬 **Send Confirmation Text**

A mensagem é:
> Hi [Nome do Passageiro], this is Makers Air Valet. We have your [Modelo do Carro] parked with us. Can you confirm your return date? Thank you!

---

# 21. AÇÕES EM LOTE (BULK ACTIONS)

As ações em lote permitem realizar operações em múltiplos registros ao mesmo tempo.

## Como selecionar múltiplos registros?

1. Na aba **All Passengers**, marque as caixinhas ☐ na coluna da esquerda
2. Ou clique no checkbox no cabeçalho da tabela para selecionar todos os visíveis
3. O contador **"X selected"** aparecerá acima da tabela

## Ações disponíveis em lote

| Botão | Ação |
|-------|------|
| **✓ Delivered** | Marca todos os selecionados como ENTREGUES (tipo Normal) |
| **📅 No Date** | Muda o status de todos os selecionados para NO DATE |
| **🚗 Move Hangar** | Move todos os selecionados para um hangar |
| **📦 Archive Selected** | Arquiva todos os selecionados |
| **✕ Clear** | Desmarca todos |
| **🗑 Delete** | Exclui permanentemente todos os selecionados |

## Como mover vários carros de hangar de uma vez?

1. Selecione os registros desejados
2. Clique em **🚗 Move Hangar**
3. Aparecerá uma barra com os hangares disponíveis
4. Clique no hangar destino
5. Confirme a ação

> ⚠️ **ATENÇÃO:** A ação **Delete** é permanente e não pode ser desfeita. Use com extremo cuidado e somente quando tiver certeza.

---

# 22. ARQUIVAMENTO DE REGISTROS

O arquivamento move registros para o histórico sem excluí-los permanentemente.

## Quando arquivar?

- Ao final de um período operacional (fim de ano)
- Para limpar registros antigos que não estão mais ativos
- Quando o supervisor solicitar

## Como arquivar registros selecionados?

1. Na aba **All Passengers**, selecione os registros desejados
2. Clique em **📦 Archive Selected**
3. O sistema abrirá um modal de confirmação em 3 etapas:
   - **Etapa 1:** Mostra quantos registros serão arquivados
   - **Etapa 2:** Solicita o nome de quem está arquivando (em maiúsculas)
   - **Etapa 3:** Confirmação final antes de executar

## Como arquivar todos os registros pendentes de 2025?

1. Vá para a aba **Debug**
2. Clique em **📦 Archive All Pending Records From 2025**
3. Siga as 3 etapas de confirmação

## Como encontrar registros arquivados?

Na aba **All Passengers**, clique no filtro **📦 Archived** ou no chip "Archived" na barra de estatísticas.

## Informações salvas no arquivamento

- **Archived By:** Nome de quem arquivou
- **Archived At:** Data e hora do arquivamento

Essas informações são visíveis no painel do passageiro arquivado.

---

# 23. RETORNO ANTECIPADO (EARLY RETURN)

O retorno antecipado é quando o passageiro volta **antes** da data de retorno prevista.

## Como registrar?

1. Abra o painel do passageiro
2. Se a data de retorno ainda não chegou (não é hoje nem está vencida), aparecerá o botão:  
   **⚡ Early Return — Arrived Today**
3. Clique no botão
4. Confirme a ação na janela de confirmação
5. O sistema:
   - Atualiza a data de retorno para hoje
   - Marca o status como DELIVERED
   - Adiciona "EARLY RETURN" nas observações (OBS)
   - Registra no Log como "EARLY RETURN"

## Por que isso é importante?

O registro de EARLY RETURN cria um histórico no passageiro. Na próxima visita, o sistema alertará a equipe automaticamente:
> "⚠️ HEADS UP: This passenger had an Early Return before. Confirm the return date carefully."

---

# 24. EXPORTAÇÃO DE CONTATOS

O sistema permite exportar a lista de passageiros como arquivo de contatos (.vcf) para importar no iPhone/iPad.

## Como exportar?

Na aba **Report**, seção "Passenger Contacts Export":

- **📇 Export All Contacts (.vcf):** Exporta todos os contatos únicos com telefone válido
- **🆕 Export New Contacts (.vcf):** Exporta apenas contatos adicionados desde a última exportação

## O que o arquivo .vcf contém?

- Nome do passageiro (FIRST LAST)
- Número de telefone (formato internacional: +1XXXXXXXXXX)

Os contatos são **desduplicados**: se um passageiro tem várias visitas, apenas o registro mais recente é exportado.

## Como importar no iPhone/iPad?

1. Após baixar o arquivo .vcf, abra-o no Files ou Safari
2. O iOS perguntará se deseja importar os contatos
3. Toque em "Import All Contacts"

## Gerenciar a data de exportação

- O sistema lembra automaticamente quando foi feita a última exportação
- O botão **↺ Reset Export Date** zera essa data para que a próxima exportação de "novos contatos" inclua todos novamente

---

# 25. FLUXO OPERACIONAL DIÁRIO

## Início do Turno

### Ao chegar:
1. Acesse o sistema pelo navegador
2. Faça login com email e senha
3. Clique em **↻ Refresh** para garantir dados atualizados
4. Verifique a aba **Dashboard** — procure pela seção **⚠️ Forgot Yesterday** (se aparecer, é prioridade máxima)
5. Verifique a seção **🔔 Leaving Today** — quem sai hoje?
6. Prepare os veículos que sairão hoje
7. Verifique a aba **Tasks** — há confirmações de data pendentes?

---

## Durante o Turno

### A cada chegada de passageiro:
1. Cadastre imediatamente no sistema (+ New Entry)
2. Preencha todos os campos obrigatórios
3. Clique em **🖨 Save + Print + Text**
4. Entregue o Customer Copy ao passageiro
5. Fixe o Key Copy nas chaves
6. Coloque o Dashboard Copy no painel do veículo
7. Leve o veículo para o hangar correto

### A cada entrega de veículo:
1. Localize o passageiro no sistema
2. Confirme a identidade pelo ticket
3. Vá buscar o veículo no hangar indicado
4. Entregue o veículo
5. Marque como DELIVERED no sistema
6. Selecione o tipo de entrega e avaliação

### A cada movimentação de veículo:
1. Atualize o hangar no sistema imediatamente
2. Imprima uma nova Key Copy com a localização atualizada
3. Substitua a etiqueta antiga nas chaves

### Quando receber informação de retorno de passageiro:
1. Abra o painel do passageiro
2. Atualize a data de retorno (campo Return)
3. Salve as alterações

---

## Verificação do Dashboard (fazer periodicamente)

A cada 1-2 horas, verifique:
- **Leaving Today:** Todos os veículos foram entregues ou estão sendo preparados?
- **Forgot Yesterday:** Apareceu algum registro esquecido?
- **NO HANGAR:** Algum veículo sem localização definida?

---

## Fim do Turno

1. Verifique se todos os veículos do dia foram marcados corretamente
2. Verifique os registros "Leaving Today" — algum não foi entregue?
3. Se houver não-entregues com motivo justificado (passageiro adiou), atualize a data de retorno
4. Clique em **↻ Refresh** para garantir que todos os dados estão sincronizados
5. Revise a aba **Tasks** — envie textos de confirmação se houver pendentes
6. Verifique a seção **📆 Leaving Tomorrow** — prepare-se para o dia seguinte

---

## Fechamento Operacional

### Semanalmente:
- Exportar novos contatos (.vcf) e importar no iPad

### Mensalmente:
- Gerar o **Operations Report** (Relatório Operacional Mensal)
- Arquivar registros antigos conforme orientação do supervisor

---

# 26. TROUBLESHOOTING — RESOLUÇÃO DE PROBLEMAS

## Problema: Passageiro não encontrado na busca

**Possíveis causas e soluções:**

| Situação | Solução |
|----------|---------|
| Nome digitado com erro | Tente pesquisar pelo ticket ou telefone |
| Passageiro foi arquivado | Clique no filtro "📦 Archived" |
| Passageiro foi entregue | Clique no filtro "Delivered" |
| Passageiro ainda não foi cadastrado | Cadastre-o com + New Entry |
| Nome grafado diferente | Tente apenas o sobrenome |

---

## Problema: Veículo sem localização (NO HANGAR)

**Causa:** O veículo foi cadastrado sem selecionar um hangar.  
**Solução:**
1. Localize o passageiro no sistema
2. Abra o painel do passageiro
3. Na seção "Move Hangar", clique no hangar correto
4. O sistema perguntará se deseja imprimir nova key tag — responda Sim
5. Substitua a etiqueta nas chaves

---

## Problema: Erro de impressão

**Sintoma:** Mensagem de erro vermelha: "❌ Epson rejeitou a impressão"

**Possíveis causas e soluções:**

| Causa | Solução |
|-------|---------|
| Impressora desligada | Ligue a impressora |
| Impressora sem papel | Reponha o papel |
| IP da impressora mudou | Informe ao supervisor |
| Impressora fora da rede Wi-Fi | Verifique a conexão de rede |
| iPad fora da rede local | Conecte ao Wi-Fi correto |

---

## Problema: Sistema não carrega / erro de conexão

**Sintoma:** Mensagem "Connection error" ou tela branca

**Soluções:**
1. Verifique a conexão Wi-Fi do dispositivo
2. Clique em **↻ Refresh**
3. Feche e reabra o navegador
4. Se persistir, informe ao supervisor

---

## Problema: Campos incompletos ao salvar

**Sintoma:** Mensagem de alerta ao tentar salvar

**Campos obrigatórios e seus alertas:**
- "Name and Ticket required." → Preencha nome e ticket
- "Return Date is required for PENDING status." → Insira data de retorno ou mude o status para NO DATE

---

## Problema: Alerta de ticket duplicado

**Sintoma:** Mensagem amarela: "⚠️ Warning: ticket XXXX already exists, but save is allowed."

**O que fazer:** O sistema permite salvar mesmo com ticket duplicado, mas isso deve ser evitado. Verifique se o passageiro não foi cadastrado em duplicidade e ajuste o número do ticket.

---

## Problema: Data de retorno aparece como OVERDUE (vencida)

**Sintoma:** Etiqueta vermelha "LATE" no nome do passageiro

**O que verificar:**
1. O passageiro realmente deveria ter retornado?
2. Se sim: entre em contato via SMS ou ligação
3. Se houve adiamento: atualize a data de retorno no sistema
4. Se foi entregue e esqueceu de marcar: marque como DELIVERED com a data correta

---

## Problema: Seção "Forgot Yesterday" com registros

**O que fazer:**
1. Identifique cada passageiro na seção
2. Para cada um, verifique se o veículo foi entregue e esqueceu de registrar
3. Se foi entregue: marque como DELIVERED (a data de entrega será registrada como hoje)
4. Se não foi entregue: entre em contato com o passageiro urgentemente e atualize a data

---

## Problema: SMS não enviado

**Causa:** O sistema abre o aplicativo de mensagens — a mensagem precisa ser enviada manualmente.

**Importante:** O sistema NÃO envia SMS automaticamente. Ele apenas pré-preenche a mensagem e abre o aplicativo de mensagens. O colaborador deve confirmar o envio manualmente no app de SMS do dispositivo.

---

# 27. BOAS PRÁTICAS

## Atendimento ao Passageiro
- Sempre cumprimente o passageiro pelo nome após verificar o registro
- Confirme o número de telefone no cadastro — é essencial para comunicação futura
- Explique ao passageiro que ele deve guardar o número do ticket
- Informe o número de contato (954) 352-1010 caso ele precise alterar a data de retorno

## Organização
- Nunca feche o sistema durante o turno
- Clique em Refresh pelo menos uma vez por hora
- Mantenha a tela na aba Dashboard durante períodos de movimento intenso
- Use a aba All Passengers para verificações pontuais

## Controle de Chaves
- SEMPRE imprima o Key Copy e fixe nas chaves antes de levar o carro ao hangar
- NUNCA leve um carro ao hangar sem o ticket nas chaves
- Se mover um carro de hangar, imprima IMEDIATAMENTE uma nova Key Copy
- Substitua a etiqueta antiga pela nova — jamais deixe duas etiquetas nas mesmas chaves

## Controle de Veículos
- NUNCA deixe um veículo no sistema sem localização (hangar)
- Verifique os alertas "🔴 NO HANGAR" no Dashboard todos os dias
- Ao perceber que um carro mudou de posição, atualize o sistema antes de fazer outra tarefa

## Atualização de Informações
- Se o passageiro ligar alterando a data de retorno, atualize o sistema IMEDIATAMENTE
- Documente qualquer anotação relevante no campo OBS
- Se o passageiro informar que não voltará com Makers Air, marque a caixinha correspondente

## Segurança Operacional
- Nunca entregue um veículo sem verificar o ticket e a identidade do passageiro
- Em caso de dúvida sobre a identidade, contate o supervisor
- Nunca delete registros sem autorização expressa do supervisor
- Mantenha sua senha confidencial — não compartilhe com outros

---

# 28. ERROS MAIS COMUNS

| Erro | Causa | Como Evitar |
|------|-------|-------------|
| Veículo perdido no hangar | Não registrou a localização no check-in | Sempre selecione o hangar ao cadastrar |
| Passageiro cadastrado em duplicidade | Não verificou o autocomplete | Sempre confira as sugestões antes de cadastrar um nome novo |
| Ticket entregue ao passageiro errado | Não conferiu o ticket e identidade | Sempre compare o ticket físico com o número no sistema |
| Data de retorno errada | Passageiro informou data incorreta | Confirme a data verbalmente com o passageiro |
| SMS não enviado | Saiu do app sem enviar | Após o sistema abrir o SMS, sempre pressione "Send" |
| Key Copy não trocado após mover veículo | Esqueceu de imprimir nova etiqueta | Imprimir nova Key Copy é o primeiro passo ao mover um carro |
| Registro marcado como DELIVERED incorretamente | Clique acidental | Reabra o registro, edite o status de volta para PENDING |
| Registro deletado por engano | Confirmou exclusão sem perceber | Sempre leia a confirmação antes de confirmar exclusões |
| Passageiro atrasado não notificado | Não verificou seção Forgot Yesterday | Checar essa seção é a PRIMEIRA tarefa do dia |
| Data estimada sem texto APPROX no OBS | Preencheu data estimada mas não apareceu na Tasks | O sistema adiciona "APPROX DATE" automaticamente ao salvar com data estimada |

---

# 29. GLOSSÁRIO

| Termo | Definição |
|-------|-----------|
| **All Passengers** | Aba com a lista completa de todos os passageiros cadastrados |
| **APPROX / Approximate** | Data aproximada, não confirmada pelo passageiro |
| **Archive / Arquivar** | Mover registros para o histórico sem excluí-los |
| **Check-in** | Processo de receber o veículo do passageiro e registrar no sistema |
| **Check-out / Delivery** | Processo de devolver o veículo ao passageiro |
| **Chip** | Indicador visual colorido na barra de estatísticas |
| **Customs** | Área de alfândega do aeroporto; tipo de entrega quando o passageiro passa pelo desembaraço aduaneiro |
| **Dashboard** | Aba de visão operacional do dia com cartões de passageiros |
| **Dashboard Copy** | Ticket pequeno colocado dentro do veículo no painel |
| **DELIVERED** | Status: veículo já entregue ao passageiro |
| **Early Return** | Retorno do passageiro antes da data prevista |
| **Epson ePOS** | Modelo de impressora térmica conectada à rede local |
| **Flight List** | Aba para verificação de passageiros de voos chegando |
| **Flight Tag** | Etiqueta impressa para identificação durante entrega de voos |
| **Frequent** | Passageiro que já utilizou o serviço mais de uma vez |
| **HH** | Código de hangar específico da operação (Helicopter Hangar ou similar) |
| **Hangar** | Local físico onde o veículo fica estacionado durante a estadia |
| **Key Copy** | Ticket interno preso às chaves do veículo |
| **Lockbox** | Cofre para depósito de chaves quando o passageiro não está presente |
| **Log** | Registro cronológico de todas as ações realizadas no sistema |
| **NO DATE** | Status: passageiro sem data de retorno definida |
| **NO HANGAR** | Alerta: veículo cadastrado sem localização definida |
| **OBS** | Campo de observações gerais (abreviação de Observações) |
| **Operations Report** | Relatório mensal de análise operacional |
| **Overdue** | Passageiro com data de retorno vencida (atrasado) |
| **PENDING** | Status padrão: veículo em custódia aguardando retirada |
| **Refresh** | Botão para atualizar os dados do sistema |
| **Report** | Aba para geração de relatórios e exportações |
| **Sign In** | Fazer login no sistema |
| **Sign Out** | Sair do sistema |
| **SMS** | Mensagem de texto enviada ao celular do passageiro |
| **Stats Bar** | Barra de estatísticas com totais por status |
| **Supabase** | Plataforma de banco de dados na nuvem onde os dados são armazenados |
| **Tasks** | Aba com confirmações de data pendentes |
| **Tail Number** | Prefixo de identificação de aeronave (ex: N624JR) |
| **Ticket** | Número único de identificação do serviço de valet |
| **VCF** | Formato de arquivo de contatos (vCard) compatível com iPhone |
| **Valet** | Serviço de estacionamento com entrega e busca do veículo por um manobrista |
| **Welcome SMS** | Mensagem de boas-vindas enviada ao passageiro no check-in |

---

# 30. MELHORIAS FUTURAS SUGERIDAS

> **Nota:** Esta seção lista apenas sugestões identificadas durante a análise. Nenhuma alteração foi realizada no sistema.

1. **Notificações automáticas:** Envio automático de SMS sem necessidade de abrir o app de mensagens manualmente
2. **Assinatura digital:** Passageiro assinar na tela do iPad ao receber o veículo
3. **Foto do veículo:** Registro fotográfico do estado do veículo no check-in e check-out
4. **QR Code no ticket:** Para facilitar a localização rápida do registro no sistema
5. **Integração de voos:** Busca automática de informações do voo pelo prefixo da aeronave
6. **Alertas automáticos:** Notificação no sistema quando um passageiro está prestes a atrasar
7. **Controle de vagas:** Mapa visual dos hangares com indicação de vagas disponíveis e ocupadas
8. **Múltiplos usuários com identificação:** Cada colaborador logado com seu próprio acesso para melhor rastreabilidade nos logs
9. **Relatório de avaliações:** Análise das avaliações de passageiros por período

---
---

# GUIA RÁPIDO

## MAKERS AIR VALET — RESUMO OPERACIONAL

---

### CHECK-IN (Passageiro chegando)
1. **+ New Entry** → preencher: Nome, Telefone, Ticket, Data de Retorno, Veículo, Cor, Hangar
2. Clicar **🖨 Save + Print + Text**
3. Entregar **Customer Copy** ao passageiro
4. Fixar **Key Copy** nas chaves
5. Colocar **Dashboard Copy** no painel do carro
6. Enviar o **SMS** pelo app de mensagens

---

### CHECK-OUT (Passageiro buscando o carro)
1. Pesquisar o passageiro (nome ou ticket) em **All Passengers**
2. Verificar hangar no painel do passageiro
3. Buscar o veículo
4. Clicar **✓ Deliver** → selecionar tipo de entrega → avaliar passageiro

---

### TODOS OS DIAS — VERIFICAR:
- ⚠️ **Forgot Yesterday** (Dashboard) — se aparecer, resolver PRIMEIRO
- 🔔 **Leaving Today** (Dashboard) — preparar veículos
- 🔴 **NO HANGAR** (Dashboard) — corrigir localização

---

### IMPRESSÕES DISPONÍVEIS:
- 🧾 Customer Copy — Para o passageiro
- 🔑 Key Copy — Nas chaves
- 🚗 Dashboard Copy — No painel do carro
- ✈️ Flight Tag — Etiqueta de voo

---

### STATUS:
- 🟡 PENDING — Em custódia com data
- 🟣 NO DATE — Em custódia sem data
- 🟢 DELIVERED — Entregue
- 📦 ARCHIVED — Arquivado

---

### TIPOS DE ENTREGA:
- 📋 Normal — Entrega padrão
- 📦 Customs — Via alfândega
- 🔒 Lockbox — Chave no cofre

---

### HANGARES:
HANGAR 19 · HANGAR 18 · HANGAR 16 · HANGAR 7 · HH

---

### DÚVIDAS? Contate o supervisor.

---
---

# CHECKLIST DE TREINAMENTO

**Nome do colaborador:** ________________________  
**Data de treinamento:** ________________________  
**Supervisor responsável:** ________________________

---

## Módulo 1 — Acesso e Navegação
- [ ] Fez login com email e senha
- [ ] Identificou todas as 7 abas do sistema
- [ ] Encontrou o botão Refresh e entende quando usá-lo
- [ ] Aprendeu a fazer Sign Out

## Módulo 2 — All Passengers
- [ ] Usou a barra de pesquisa
- [ ] Testou os filtros (Pending, No Date, Delivered, etc.)
- [ ] Entendeu as cores e indicadores visuais (TODAY, TMR, LATE, ~APPROX)
- [ ] Ordenou a tabela por colunas

## Módulo 3 — Cadastro de Passageiro (Check-in)
- [ ] Abriu o formulário com + New Entry
- [ ] Preencheu todos os campos obrigatórios
- [ ] Testou o autocomplete de nomes frequentes
- [ ] Selecionou um hangar de localização
- [ ] Salvou com "Save + Print + Text"
- [ ] Entendeu a diferença entre os 3 botões de salvar

## Módulo 4 — Impressões
- [ ] Imprimiu o Customer Copy
- [ ] Imprimiu o Key Copy
- [ ] Imprimiu o Dashboard Copy
- [ ] Imprimiu uma Flight Tag
- [ ] Entende onde colocar cada tipo de ticket

## Módulo 5 — Dashboard
- [ ] Identificou todas as seções do Dashboard
- [ ] Entendeu o alerta "Forgot Yesterday"
- [ ] Sabe o que significa "🔴 NO HANGAR"
- [ ] Usou os botões de entrega (Deliver, Customs, Lockbox)
- [ ] Inseriu número de voo e horário de partida em um cartão

## Módulo 6 — Entrega de Veículo (Check-out)
- [ ] Localizou um passageiro pelo nome
- [ ] Abriu o painel completo do passageiro
- [ ] Marcou como DELIVERED usando o botão ✓
- [ ] Selecionou o tipo de entrega
- [ ] Avaliou o passageiro

## Módulo 7 — Controle de Hangares
- [ ] Moveu um veículo de hangar pelo painel do passageiro
- [ ] Imprimiu nova Key Copy após mudança de hangar
- [ ] Entende como usar o Move Hangar em lote

## Módulo 8 — Comunicação
- [ ] Entendeu como funciona o Welcome SMS
- [ ] Enviou um SMS direto pelo painel do passageiro
- [ ] Sabe o que é o botão "💬 Welcome"

## Módulo 9 — Tasks e Datas Aproximadas
- [ ] Identificou a aba Tasks e seu badge de notificações
- [ ] Entende quando um passageiro aparece nas Tasks
- [ ] Enviou texto de confirmação de data pela aba Tasks
- [ ] Confirmou uma data pelo campo de input nas Tasks

## Módulo 10 — Flight List
- [ ] Usou a aba Flight List com uma lista de nomes
- [ ] Interpretou os resultados (Found / Not Found)
- [ ] Clicou em um resultado para abrir o painel do passageiro

## Módulo 11 — Relatórios
- [ ] Gerou um relatório básico de passageiros
- [ ] Entende as opções de filtro do relatório
- [ ] Conhece o Relatório Operacional Mensal

## Módulo 12 — Situações Especiais
- [ ] Sabe registrar um Early Return
- [ ] Sabe como arquivar registros
- [ ] Sabe o que fazer quando aparece "Forgot Yesterday"
- [ ] Sabe o que fazer quando aparece "NO HANGAR"

## Módulo 13 — Logs
- [ ] Acessou a aba Logs
- [ ] Leu um registro de log e entendeu as informações

---

**Assinatura do Colaborador:** ________________________  
**Assinatura do Supervisor:** ________________________  
**Data de Conclusão:** ________________________

---
---

# POP — PROCEDIMENTO OPERACIONAL PADRÃO

## MAKERS AIR VALET — SISTEMA DE CONTROLE

---

## POP 001 — CHECK-IN DE PASSAGEIRO

**Responsável:** Colaborador de operação  
**Quando executar:** A cada chegada de passageiro

**Procedimento:**

1. Receber o passageiro e coletar: nome completo, telefone e data de retorno
2. Abrir o sistema → clicar em **+ New Entry**
3. Preencher obrigatoriamente: Nome, Telefone, Ticket, Retorno, Veículo, Hangar
4. Clicar em **🖨 Save + Print + Text**
5. Entregar **Customer Copy** ao passageiro orientando a guardar o número
6. Fixar **Key Copy** nas chaves do veículo
7. Colocar **Dashboard Copy** no painel interno do veículo
8. Confirmar envio do SMS de boas-vindas no aplicativo de mensagens
9. Levar o veículo para o hangar registrado

**Verificações críticas:**
- [ ] Hangar selecionado no sistema antes de salvar
- [ ] Três tickets impressos e posicionados corretamente
- [ ] SMS enviado pelo app de mensagens

---

## POP 002 — CHECK-OUT / ENTREGA DE VEÍCULO

**Responsável:** Colaborador de operação  
**Quando executar:** A cada solicitação de entrega de veículo

**Procedimento:**

1. Solicitar nome ou número do ticket ao passageiro
2. Localizar o registro no sistema (All Passengers → busca)
3. Confirmar identidade: verificar modelo, cor e ticket
4. Verificar localização (hangar) no painel do passageiro
5. Buscar o veículo no hangar indicado
6. Trazer o veículo ao passageiro
7. No sistema: clicar **✓** na tabela ou **Mark as Delivered** no painel
8. Selecionar tipo de entrega: Normal / Customs / Lockbox
9. Avaliar o passageiro: Great / Normal / Difficult
10. Confirmar a conclusão da entrega

**Verificações críticas:**
- [ ] Identidade conferida antes de entregar o veículo
- [ ] Status DELIVERED registrado no sistema imediatamente após a entrega

---

## POP 003 — INÍCIO DO TURNO

**Responsável:** Colaborador de operação  
**Quando executar:** No início de cada turno

**Procedimento:**

1. Fazer login no sistema
2. Clicar em **↻ Refresh**
3. Verificar aba **Dashboard** → seção **Forgot Yesterday** (se houver, resolver imediatamente)
4. Verificar seção **Leaving Today** → preparar veículos para entrega
5. Verificar aba **Tasks** → alguma confirmação de data pendente?
6. Confirmar que nenhum veículo está com "🔴 NO HANGAR"

---

## POP 004 — MOVIMENTAÇÃO DE VEÍCULO ENTRE HANGARES

**Responsável:** Colaborador de operação  
**Quando executar:** Sempre que um veículo for movido de hangar

**Procedimento:**

1. Abrir o painel do passageiro no sistema
2. Seção **Move Hangar** → clicar no hangar destino
3. Confirmar a mudança
4. Responder **Sim** quando o sistema perguntar sobre impressão de nova key tag
5. Retirar a Key Copy antiga das chaves
6. Fixar a nova Key Copy nas chaves
7. Verificar que o sistema exibe o hangar correto

**Verificações críticas:**
- [ ] Key Copy antiga removida
- [ ] Nova Key Copy fixada nas chaves antes de mover o veículo

---

## POP 005 — RETORNO ANTECIPADO (EARLY RETURN)

**Responsável:** Colaborador de operação  
**Quando executar:** Quando passageiro retorna antes da data prevista

**Procedimento:**

1. Localizar o passageiro no sistema
2. Abrir o painel do passageiro
3. Clicar no botão roxo **⚡ Early Return — Arrived Today**
4. Confirmar a ação na janela de confirmação
5. Buscar o veículo no hangar indicado e proceder com a entrega normal

**Resultado:** O sistema marcará automaticamente como DELIVERED e adicionará "EARLY RETURN" nas observações.

---
---

# FLUXOGRAMA OPERACIONAL

```
╔══════════════════════════════════════════════════════════════════════╗
║              FLUXO OPERACIONAL — MAKERS AIR VALET                    ║
╚══════════════════════════════════════════════════════════════════════╝

                    ┌─────────────────────────────┐
                    │       INÍCIO DO TURNO        │
                    └─────────────┬───────────────┘
                                  │
                    ┌─────────────▼───────────────┐
                    │   Login → Refresh → Dashboard │
                    └─────────────┬───────────────┘
                                  │
              ┌───────────────────▼───────────────────────┐
              │ Verificar: Forgot Yesterday? NO HANGAR?   │
              │           Tasks pendentes?                │
              └───────────────────┬───────────────────────┘
                                  │
    ╔═════════════════════════════▼═══════════════════════════════╗
    ║                    OPERAÇÃO DO DIA                          ║
    ╠════════════════════╦════════════════════╦═══════════════════╣
    ║                    ║                    ║                   ║
    ▼                    ▼                    ▼                   ▼
┌──────────┐      ┌──────────┐        ┌──────────┐       ┌──────────┐
│ CHEGADA  │      │ SAÍDA    │        │MUDANÇA   │       │TAREFA    │
│ (CHECK-  │      │ (CHECK-  │        │DE HANGAR │       │PENDENTE  │
│  IN)     │      │  OUT)    │        │          │       │          │
└────┬─────┘      └────┬─────┘        └────┬─────┘       └────┬─────┘
     │                 │                   │                   │
     ▼                 ▼                   ▼                   ▼
+New Entry      Buscar passageiro    Abrir painel       Tasks → Send
Preencher →     no sistema →         → Move Hangar      Text →
Save+Print+     Verificar            → Confirmar        Aguardar
Text →          hangar →             → Print            resposta →
3 tickets →     Buscar carro →       nova Key Copy      Set Date
SMS enviado     Mark Delivered →
                Tipo + Rating
     │                 │                   │                   │
     ▼                 ▼                   ▼                   ▼
Status:         Status:             Status:            Task:
PENDING         DELIVERED           PENDING            CONFIRMADA
                                    (loc. nova)
    ╚════════════════════╩════════════════════╩═══════════════════╝
                                  │
                    ┌─────────────▼───────────────┐
                    │         FIM DO TURNO         │
                    ├──────────────────────────────┤
                    │ ✓ Verificar "Leaving Today"  │
                    │ ✓ Atualizar datas vencidas   │
                    │ ✓ Verificar "Tasks"          │
                    │ ✓ Refresh final              │
                    └──────────────────────────────┘

═══════════════════════════════════════════════════════════════════════
                    TIPOS DE ENTREGA
═══════════════════════════════════════════════════════════════════════

     Passageiro                    Sem passageiro
     presente?                     presente?
         │                              │
    ┌────┴────┐                    ┌────▼────┐
    │ Customs? │                   │LOCKBOX  │
    └────┬────┘                   │ depósito│
         │ Sim         Não        │de chave │
         ▼             ▼         └─────────┘
    ┌─────────┐  ┌─────────┐
    │CUSTOMS  │  │NORMAL   │
    │via      │  │entrega  │
    │alfândega│  │direta   │
    └─────────┘  └─────────┘

═══════════════════════════════════════════════════════════════════════
                    STATUS DO REGISTRO
═══════════════════════════════════════════════════════════════════════

  ┌─────────────────────────────────────────────────────────────┐
  │                                                             │
  │  CHEGADA ──► [PENDING] ─────────────────────► [DELIVERED]  │
  │                  │                                          │
  │                  │ (sem data)                               │
  │                  ▼                                          │
  │             [NO DATE] ──► (confirma data) ──► [PENDING]    │
  │                  │                                          │
  │                  │ (fim de período)                         │
  │                  ▼                                          │
  │             [ARCHIVED]                                      │
  └─────────────────────────────────────────────────────────────┘

═══════════════════════════════════════════════════════════════════════
  MAKERS AIR VALET by Farber Parking | Manual Gerado em 22/06/2026
═══════════════════════════════════════════════════════════════════════
```

---

*Fim do Manual Operacional do Sistema Makers Air Valet*  
*Documento gerado em 22 de junho de 2026*  
*Versão: 1.0 — Análise realizada em modo somente leitura (Read Only)*
