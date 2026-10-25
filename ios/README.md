# Walkie for iPhone

Walkie er en enkel walkie-talkie. Appen kobler seg til den samme serveren som nettsiden. Du oppretter en gruppe (for eksempel Familie eller Jobb) eller blir med på navnet. Hold den store knappen inne for å snakke, eller hold volum opp inne. Du kan lytte til flere grupper samtidig, og velge én gruppe å snakke i. Du hører de andre også når skjermen er låst.

Standard server er `wss://walkie-bc0z.onrender.com`. Adressen kan endres i appen. Navn, grupper og server lagres på telefonen (UserDefaults). Et valgfritt gruppepassord lagres i Keychain, ikke i UserDefaults.

Prosjektet er SwiftUI, iOS 26 eller nyere, og har ingen tredjepartspakker. `Walkie.xcodeproj` er sjekket inn, så du trenger ikke XcodeGen for å bygge.

## Installer på iPhone med gratis Apple-ID

Du trenger en Mac med Xcode 26 og en iPhone med iOS 26 eller nyere. En betalt utviklerkonto trengs ikke.

1. Installer Xcode 26 fra Mac App Store. Åpne Xcode én gang og la det installere ekstra komponenter.
2. Koble iPhone til Mac med kabel. Lås opp telefonen og trykk **Stol på** hvis Mac spør.
3. På iPhone: **Innstillinger → Personvern og sikkerhet → Utviklermodus**. Slå den på og start telefonen på nytt hvis iOS ber om det.
4. På Mac: åpne `ios/Walkie.xcodeproj` (dobbeltklikk filen).
5. Klikk det blå prosjektikonet **Walkie**. Under **TARGETS** velger du **Walkie**, og åpner fanen **Signing & Capabilities**.
6. Kryss av **Automatically manage signing**.
7. **Team** står tomt med vilje (`DEVELOPMENT_TEAM` er tom). Velg **Add an Account…**, logg inn med Apple-ID-en din, og velg teamet **Ditt navn (Personal Team)**.
8. **Bundle Identifier** skal være `com.skuyng.walkie`. Visningsnavnet er **Walkie**. Hvis Xcode sier at identifikatoren er opptatt, endre den til noe unikt, for eksempel `com.skuyng.walkie.dittnavn`.
9. Ikke legg til capabilities. Push Notifications og Push to Talk krever betalt konto og er ikke med i prosjektet.
10. Øverst i vinduet velger du din iPhone som kjøringsmål. Simulatoren kan vise skjermen, men mikrofon, høyttaler og låst skjerm må prøves på telefonen.
11. Trykk **Run** (▶). Første bygging tar litt tid. Telefonen må være ulåst.
12. Hvis appen ikke starter fordi utvikleren ikke er klarert: på iPhone, **Innstillinger → Generelt → VPN og enhetsadministrasjon** (på noen versjoner heter det **Enhetsadministrasjon**). Velg profilen din og trykk **Stol på**.
13. Åpne Walkie og tillat mikrofon når iOS spør.
14. Skriv navn, opprett eller bli med i en gruppe, sjekk serveradressen, og trykk **Koble til**. Hold den store knappen inne for å snakke. Hold volum opp inne for å sende mens appen er i forgrunnen, og slipp for å stoppe.

En gratis profil varer i 7 dager. Når appen slutter å starte, kjør den fra Xcode på nytt. Et personlig team kan bare ha noen få egne apper installert samtidig.

## Slik bruker du den

- **Navn** — vises til de andre (maks 30 tegn).
- **Opprett gruppe** — lager en gruppe med navnet du skriver, for eksempel `Familie`. Store og små bokstaver er samme gruppe (maks 40 tegn). Valgfritt **Passord** låser gruppen. Passordet lagres i Keychain.
- **Bli med i gruppe** — legger deg til en gruppe andre har opprettet, med samme navn og passord hvis gruppen er låst. Feil passord vises som «Feil passord».
- **Lytt** — på per gruppe. Du kan lytte til flere samtidig. Av gjør at du fortsatt ser hvem som er pålogget, men ikke hører lyden.
- **Snakk / Velg** — én gruppe om gangen. Hold-for-å-snakke og volum opp sender bare dit.
- **Pålogget** — grønn prikk ved navnet. Den som snakker utheves.
- **Server** — `wss://walkie-bc0z.onrender.com` som standard. `https://` gjøres om til `wss://`, og `http://` til `ws://`. Tomt felt bruker standardadressen.
- **Hold for å snakke** — lyd sendes bare mens knappen holdes inne.
- **Volum opp** — hold inne for å snakke, og slipp for å stoppe, mens appen er tilkoblet og i forgrunnen. Lydnivået settes tilbake etter at du slipper. Systemets volumvisning skjules i vanlig visning og i mørk modus.
- **Høyttaler** — på som standard. På sender lyden i høyttaleren. Av bruker ørepluggen, med mindre hodetelefoner eller Bluetooth er koblet til. Valget lagres på telefonen.
- **Mørk modus** — svart skjerm, lav lysstyrke, og telefonen holder seg våken. Et svakt rødt punkt vises mens du sender. Trykk skjermen for å avslutte. Volum opp virker her også.
- Når noen andre begynner eller slutter å snakke, spilles en kort tone, og navnet vises.

## Lyd og protokoll

Appen snakker samme protokoll som `server.js` og `public/index.html`.

Tekst (JSON):

- til serveren: `{"t":"groups","name":"…","talk":"…","groups":[{"room":"…","password":"…","create":false,"listen":true}]}`
- til serveren, etter `groups`: `{"t":"join","name":"…","room":"…","password":"…"}` slik at en eldre server fortsatt legger deg i én kanal
- til serveren: `{"t":"start","room":"…"}` og `{"t":"stop","room":"…"}`
- fra serveren: `{"t":"users","room":"…","users":["…"],"members":[{"id":"…","name":"…"}],"self":"…"}` bare til dem som har riktig passord. `members` er én rad per tilkobling, så to med samme navn vises begge. `users` er fortsatt navnelisten.
- fra serveren: `{"t":"start","name":"…","room":"…","id":"…"}` og `{"t":"stop","name":"…","room":"…","id":"…"}`
- fra serveren: `{"t":"error","room":"…","error":"Feil passord"}` når passordet er feil

En eldre klient som bare sender `join` uten `groups` blir fortsatt med i én gruppe. Lyd sendes aldri til en socket som ikke er godkjent for gruppen, og bare til dem som lytter.

Lyd er binære websocket-rammer uten filheader: **PCM, 16-bit med fortegn, little-endian, mono, 16 000 Hz**. Nettleseren legger `sample * 32767` i en `Int16Array` og spiller av med `/ 32768`. iPhone gjør det samme, så appen og nettsiden kan være i samme gruppe. Meldingsraten er fortsatt 16 kHz, slik at eldre klienter kan dekode lyden.

Nettleseren plukker nærmeste sample når den nedsampler. iOS bruker `AVAudioConverter` til maskinvarens rate, og faller tilbake til samme punkt-sampling hvis konverteringen ikke kan kjøre. Avspilling venter omtrent 140 ms før den starter, så korte hull ikke blir smell. Formatet i meldingene er det samme.

## Bakgrunn og låst skjerm

`Info.plist` har `UIBackgroundModes` satt til `audio`. Lydøkten er `playAndRecord` med modus `.default` (ikke `.voiceChat`, som demper høyttaleren). Bluetooth-headset bruker `allowBluetoothHFP`. A2DP brukes ikke, fordi det tar lyden vekk fra høyttaleren i en samtaleøkt. **Høyttaler** på legger til `defaultToSpeaker` og tvinger høyttaler etter at lyden er startet. Av lar lyden gå i ørepluggen når det ikke er et hodesett. Økten holdes aktiv mens du er tilkoblet, og `URLSession` bruker utvidet bakgrunns-idle, slik at innkommende tale kan fortsette når skjermen er låst.

Den oransje mikrofonprikken lyser mens du er tilkoblet, fordi appen holder lydøkten i gang for å kunne ta imot tale i bakgrunnen. Du sender ikke lyd før du holder knappen inne, eller holder volum opp inne.

Dette er ikke Apples Push to Talk. Det rammeverket er ikke koblet inn.

## Push to Talk senere

`TalkTransmitter.swift` definerer `ChannelTransmitter`. Knappen bruker `HoldToTalkTransmitter`. En senere klasse kan implementere samme protokoll med `PTChannelManager` og sende de samme `start`- og `stop`-meldingene. Ikke legg til Push to Talk-capability før du har betalt konto. Ellers feiler signeringen med gratis Apple-ID.

## Bygge prosjektet på nytt

Vil du regenerere Xcode-prosjektet:

```bash
brew install xcodegen
cd ios
xcodegen generate
```

`project.yml` setter bundle-id `com.skuyng.walkie`, visningsnavn Walkie, iOS 26 og tom `DEVELOPMENT_TEAM`. Språkmodus er Swift 5, slik at Xcode 26 ikke skrur på Swift 6-sjekkene som standard.

## Begrensninger

- To personer med samme navn skilles ikke av serveren.
- Låst skjerm er satt opp med lydmodus og en aktiv `playAndRecord`-økt. Det er ikke prøvd på en fysisk iPhone herfra. iOS kan likevel stanse appen hvis det er lite ledig minne.
- `ws://` mot offentlig nett kan bli stoppet av App Transport Security. Bruk `wss://` mot Render. Lokalt nett er tillatt.
