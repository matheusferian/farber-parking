# A2P Campaign: rascunho para revisão (Makers Air Valet)

Status: **RASCUNHO**. Nada foi submetido, pago, comprado ou publicado. Preparado em 2026-10-09.
Os valores dos campos estão em inglês, exatamente como serão digitados no Console da Twilio.

## 0. Conferido no Console (2026-10-09, somente leitura)

| Item | Valor visto |
|---|---|
| Conta | My First Twilio Account (Farber) |
| Brand | **Farber Parking A2P Messaging Bundle** `BNde1df…ec4a` · **Approved** · **Low volume standard** · Private corporation |
| Empresa | Farber Parking LLC · 433 Plaza Real 275, Boca Raton FL 33432 · website **https://farberparking.com** · notificações info@farberparking.com |
| Messaging Service | **AirValet SMS** `MG9f8e…281f` (selecionável; o do FarberOS aparece como já conectado) |
| Taxa mensal da Campaign (tela "Campaign fees") | **Low Volume Mixed: $1.50**, "Only available to Low Volume Brands" · standard (customer care, account notification, mixed etc.): $10 |
| Taxa de vetting | **$15** por Campaign (página oficial de preços; o Console mostra a cobrança no momento do envio) |
| Elegibilidade LVM | O Brand é Low Volume Standard → **elegível**. A própria tela diz que LVM cobre vários use cases (ex.: customer care + notificações), com throughput no nível mínimo, independente do Trust Score |
| Limite T-Mobile (Brand) | 2.000 segmentos/dia no LVM. Uso estimado: ~20 a 120/dia |

## 1. Campaign: campos

**Use case:** Low Volume Mixed

**Sub use cases:** Customer Care · Account Notification

**Campaign description**
> Farber Parking LLC operates the Makers Air Valet service at Fort Lauderdale Executive Airport (FXE) for passengers flying with Makers Air and Ascend. Passengers who agree at vehicle check-in receive transactional text messages about their own parked vehicle: a check-in confirmation with a link to their personal valet details page (ticket number, vehicle, return date and pickup place), questions about their return date and arrival time, pickup instructions when their return flight is confirmed, a delivery confirmation, and replies from our valet staff when the passenger texts us. All messages are signed "Makers Air Valet". No marketing or promotional messages are sent. Recipients can reply STOP to opt out and HELP for help.

**Message flow / How do end-users consent**
> Passengers opt in verbally, in person, at vehicle check-in at our valet stand at Fort Lauderdale Executive Airport. Before checking a consent box in our AirValet check-in system, the attendant reads this script and waits for a clear yes or no: "Can we text you about your vehicle at this number? Makers Air Valet, operated by Farber Parking, will send check-in, return-date, pickup and delivery updates, and reply when you text us. Message frequency varies. Msg & data rates may apply. Reply HELP for help or STOP to opt out. Consent is not a condition of service. Terms and Privacy: airvalet.farberos.com/terms.html." The consent box is never pre-checked and is ticked only after a yes; the valet service is the same without texts. The time, the attendant and the disclosure version are stored with the visit. The first message confirms enrollment and repeats frequency, rates, HELP and STOP. A public reproduction of the opt-in and script is at https://airvalet.farberos.com/sms.html

**Privacy Policy URL:** https://airvalet.farberos.com/privacy.html
**Terms and Conditions URL:** https://airvalet.farberos.com/terms.html

**Sample messages** (variáveis entre colchetes, como pede a Twilio)
1. (confirmação do opt-in / primeiro SMS)
> Makers Air Valet: Your car is checked in. Tap to view your valet details: https://airvalet.farberos.com/p/[token] Questions? Just reply to this text. Msg freq varies. Msg&data rates may apply. Reply HELP for help, STOP to opt out.
2. (data de retorno)
> Makers Air Valet: Hi [First name], can you confirm your return date and arrival time? Just reply to this message. Thank you!
3. (veículo pronto, Hangar 19)
> Makers Air Valet: Welcome back! After clearing U.S. Customs, please stay with your pilots and return to Makers Air at Hangar 19, where your vehicle will be ready and waiting. Please don't exit through the U.S. Customs terminal, as there is no transportation back to Makers Air from there.
4. (veículo pronto, Customs)
> Makers Air Valet: Welcome back! Your vehicle is ready at Customs. An Ascend team member will personally hand you your key when you arrive.
5. (resposta da equipe)
> Makers Air Valet: Hi [First name], no problem, your [Vehicle] will be ready for your [Time] arrival. Reply STOP to opt out.

**Message contents**
- Embedded links: **Yes** (link pessoal do passageiro em airvalet.farberos.com)
- Embedded phone numbers: **Yes** ((954) 352-1010 na mensagem de exceção Customs)
- Direct lending / loan: No · Age-gated content: No · Affiliate marketing: No

**Volume estimado:** 150 a 500 passageiros/mês, 2 a 5 mensagens por viagem.

## 2. Palavras-chave e respostas automáticas (Advanced Opt-Out do Messaging Service "AirValet SMS")

| Tipo | Palavras-chave | Resposta |
|---|---|---|
| Opt-out | STOP, STOPALL, UNSUBSCRIBE, CANCEL, END, QUIT, REVOKE, OPTOUT | `Makers Air Valet: You're unsubscribed and will receive no more texts. Reply START to resubscribe.` |
| Opt-in (reativação) | START, UNSTOP | `Makers Air Valet: You're resubscribed to valet updates about your vehicle. Msg freq varies. Msg&data rates may apply. Reply HELP for help, STOP to opt out.` |
| Help | HELP, INFO | `Makers Air Valet (Farber Parking): for help call or text (954) 352-1010 or email info@farberparking.com. Msg freq varies. Msg&data rates may apply. Reply STOP to opt out.` |

Não há adesão por palavra-chave (ninguém entra mandando uma palavra). O opt-in é só no check-in; START serve apenas para reativar.

## 3. URLs que precisam estar públicas antes do envio da Campaign

| URL | Arquivo (branch local) | Hoje |
|---|---|---|
| https://airvalet.farberos.com/sms.html | `sms.html` | 404 (não publicado) |
| https://airvalet.farberos.com/privacy.html | `privacy.html` | 404 |
| https://airvalet.farberos.com/terms.html | `terms.html` | 404 |

Publicar = deploy só desses 3 arquivos estáticos (mais a linha do `vercel-build.sh`). O app (index.html, service worker, fluxo dos funcionários) não muda, nem o `/p/` (link do passageiro). **Requer o seu GO.**
Alternativa: hospedar as 3 páginas no site do Brand (farberparking.com), se vocês controlarem esse site. Combina 100% com o website registrado. O FarberOS já foi aprovado com páginas no domínio farberos, então `airvalet.farberos.com` deve ser aceito.

## 4. Custo

| Item | Valor | Quando |
|---|---|---|
| Vetting da Campaign | **$15** (uma vez) | ao submeter (cobrado mesmo se for reprovada) |
| Low Volume Mixed | **$1.50/mês** | a partir da aprovação |
| Número local 954 | **$1.15/mês** | quando comprar (monitorando estoque) |
| Fixo total | **$2.65/mês** + $15 uma vez | |
| Uso | ~$0.0127 por segmento enviado · ~$0.0102 recebido | só quando houver SMS (fase futura) |

## 5. Decisões pendentes antes de submeter

1. **Hospedagem das 3 páginas:** DECIDIDO (2026-10-10): airvalet.farberos.com.
2. **Gorjeta por SMS:** DECIDIDO (2026-10-10): removida. O programa é só operacional; nenhuma mensagem do número AirValet terá link de gorjeta. Na migração, os templates `VEHICLE_DELIVERED` (TIP_NO) e `CUSTOMS_GRATUITY` do pacote local precisam ficar sem link de gorjeta ou desativados.
3. **Ascend:** a descrição cita passageiros Makers Air **e** Ascend, todos atendidos pela Farber com a assinatura "Makers Air Valet" (decisão de 2026-10-09).
4. **Contato de ajuda:** (954) 352-1010 e info@farberparking.com.

## 6. Texto das páginas (versão final para aprovação)

### sms.html
Makers Air Valet SMS Program

# Makers Air Valet SMS Program

  Operated by Farber Parking, the valet company serving Makers Air and Ascend passengers at Fort Lauderdale Executive Airport (FXE). All messages come from one number and are signed "Makers Air Valet".

### What you'll receive

  Transactional text messages about your own valet visit only:

- Check-in confirmation with a link to your personal valet details page (ticket number, vehicle, return date on file and pickup place).

- Questions about your return date or arrival time.

- Vehicle-ready and pickup instructions when you return (returning with Makers Air: Hangar 19, or Customs when arranged with our team; returning with Ascend: Customs).

- Delivery confirmation.

- Replies from our valet team when you text us.

  We never send marketing or promotional messages through this program.

### How you opt in

  At vehicle check-in, the valet attendant reads this disclosure to you, word for word, and asks for a clear yes or no:

    “Can we text you about your vehicle at this number? Makers Air Valet, operated by Farber Parking, will send check-in, return-date, pickup and delivery updates, and reply when you text us. Message frequency varies. Msg & data rates may apply. Reply HELP for help or STOP to opt out. Consent is not a condition of service. Terms and Privacy: airvalet.farberos.com/terms.html.”

     Passenger agreed to receive texts from Makers Air Valet about this vehicle

    Only if you say yes does the attendant tick this box in our check-in system. Privacy Policy · Terms

  The box is never pre-checked, and text updates are optional: the valet service is the same without them. Your consent, the time, and the attendant who recorded it are stored with your visit. Your first message confirms the program and repeats how to opt out.

### Frequency and cost

  Message frequency varies with your visit, typically 2 to 5 messages per trip, plus any conversation you start. Message and data rates may apply.

### Opt out and help

  Reply STOP (or CANCEL, END, QUIT, UNSUBSCRIBE, STOPALL, REVOKE, OPTOUT) at any time to stop all messages; you'll get one confirmation and nothing else. Reply START to resubscribe. Reply HELP for help, or call or text the valet team at (954) 352-1010, or email info@farberparking.com.

  Carriers are not liable for delayed or undelivered messages.

### Privacy

  We do not sell, rent or share your mobile number or SMS opt-in data with third parties or affiliates for marketing or promotional purposes. See our Privacy Policy and SMS Terms.

  Farber Parking · Makers Air Valet · Fort Lauderdale, FL · Last updated October 2026

### privacy.html
Makers Air Valet Privacy Policy

# Privacy Policy

  Makers Air Valet (serving Makers Air and Ascend passengers), operated by Farber Parking ("we", "us"). Effective October 2026.

### Information we collect

  To provide valet service we record your name, mobile phone number, ticket number, vehicle description, parking location, travel dates and notes about your visit. If you agree to text updates, we also record that consent (time, method and the staff member who recorded it), the messages we exchange with you, and their delivery status.

### How we use it

  Only to operate your valet visit: check-in, storing and returning your vehicle, contacting you about your return, sending the text updates you agreed to, answering your messages, payments you choose to make, and keeping required business records.

### SMS and mobile information

    We do not sell or share your SMS opt-in data or personal information with third parties for marketing purposes.

    No mobile information will be shared with third parties or affiliates for marketing or promotional purposes.

    Text messaging originator opt-in data and consent are not shared with any third parties. We share phone numbers only with the service providers that deliver our messages (such as our SMS provider) and only to deliver them.

### Service providers

  We use trusted providers to host our systems, store data, send text messages and process optional payments. They may use your information only to provide those services to us.

### Retention and security

  We keep visit and message records for as long as needed for operations, customer service and legal or accounting obligations, then delete or anonymize them. Access is limited to authorized staff and protected by authentication and encryption in transit.

### Your choices

  Reply STOP to any message to stop texts. You may ask us to access, correct or delete your information by contacting us below.

### Contact

  Farber Parking · Makers Air Valet · (954) 352-1010 · info@farberparking.com

  SMS Program · SMS Terms

### terms.html
Makers Air Valet SMS Terms

# SMS Terms

  Makers Air Valet SMS Program (Makers Air and Ascend passengers), operated by Farber Parking. Effective October 2026.

### 1. Program

  Transactional text messages about your own valet visit: check-in confirmation with a link to your personal valet details page, return-date questions, vehicle-ready and pickup instructions, delivery confirmation, and replies from our valet team. No marketing or promotional messages.

### 2. Consent

  You join by saying yes at vehicle check-in after the attendant reads you the program disclosure (reproduced on the SMS Program page). Consent is optional and is not a condition of using the valet service.

### 3. Frequency and cost

  Message frequency varies (typically 2 to 5 per trip, plus conversations you start). Message and data rates may apply.

### 4. Opt out

  Reply STOP to any message to cancel. You'll receive one confirmation and no further messages. Reply START to rejoin.

### 5. Help

  Reply HELP, call or text (954) 352-1010, or email info@farberparking.com.

### 6. Carriers

  Carriers are not liable for delayed or undelivered messages. Supported on major U.S. carriers.

### 7. Privacy

  See our Privacy Policy. We do not share your mobile number or opt-in data with third parties for marketing.

  SMS Program · Privacy Policy
