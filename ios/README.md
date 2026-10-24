# Walkie for iPhone

Walkie er en enkel walkie-talkie. Appen kobler seg til den samme serveren som nettsiden, med navn og kanalkode. Hold den store knappen inne for å snakke, eller trykk volum opp for å starte og stoppe. Du hører de andre i kanalen, også når skjermen er låst.

Standard server er `wss://walkie-bc0z.onrender.com`. Adressen kan endres i appen. Navn, kanalkode og server lagres på telefonen (UserDefaults).

Prosjektet er SwiftUI, iOS 17 eller nyere, og har ingen tredjepartspakker. `Walkie.xcodeproj` er sjekket inn, så du trenger ikke XcodeGen for å bygge.

## Installer på iPhone med gratis Apple-ID

Du trenger en Mac med Xcode 26 og en iPhone med iOS 17 eller nyere. En betalt utviklerkonto trengs ikke.

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
14. Skriv navn og kanalkode, sjekk serveradressen, og trykk **Koble til**. Hold den store knappen inne for å snakke. Volum opp starter og stopper sending mens appen er i forgrunnen.

En gratis profil varer i 7 dager. Når appen slutter å starte, kjør den fra Xcode på nytt. Et personlig team kan bare ha noen få egne apper installert samtidig.

## Slik bruker du den

- **Navn** — vises til de andre (maks 30 tegn).
- **Kanalkode** — felles kode, for eksempel `familie`. Store og små bokstaver er samme kanal (maks 40 tegn).
- **Server** — `wss://walkie-bc0z.onrender.com` som standard. `https://` gjøres om til `wss://`, og `http://` til `ws://`. Tomt felt bruker standardadressen.
- **Hold for å snakke** — lyd sendes bare mens knappen holdes inne.
- **Volum opp** — starter sending første gang og stopper den neste, mens appen er tilkoblet og i forgrunnen. Lydnivået settes tilbake, så knappen kan brukes igjen. Volum ned endrer lydnivået som vanlig. Volumvisningen fra systemet er skjult mens dette er aktivt.
- **Mørk modus** — svart skjerm, lav lysstyrke, og telefonen holder seg våken. Et svakt rødt punkt vises mens du sender. Trykk skjermen for å avslutte. Volum opp virker her også.
- Når noen andre begynner eller slutter å snakke, spilles en kort tone, og navnet vises.

## Lyd og protokoll

Appen snakker samme protokoll som `server.js` og `public/index.html`.

Tekst (JSON):

- til serveren: `{"t":"join","name":"…","room":"…"}`
- til serveren: `{"t":"start"}` og `{"t":"stop"}`
- fra serveren: `{"t":"users","users":["…"]}` til alle i kanalen
- fra serveren: `{"t":"start","name":"…"}` og `{"t":"stop","name":"…"}` til de andre

Lyd er binære websocket-rammer uten filheader: **PCM, 16-bit med fortegn, little-endian, mono, 16 000 Hz**. Nettleseren legger `sample * 32767` i en `Int16Array` og spiller av med `/ 32768`. iPhone gjør det samme, så appen og nettsiden kan være i samme kanal.

Nettleseren plukker nærmeste sample når den nedsampler. iOS bruker `AVAudioConverter` først, og faller tilbake til samme punkt-sampling hvis konverteringen ikke kan kjøre. Formatet i meldingene er det samme.

## Bakgrunn og låst skjerm

`Info.plist` har `UIBackgroundModes` satt til `audio`. Lydøkten er `playAndRecord`, med `defaultToSpeaker` og Bluetooth-headset (`allowBluetoothHFP`, dagens navn på `allowBluetooth`). Økten holdes aktiv mens du er tilkoblet, og `URLSession` bruker utvidet bakgrunns-idle, slik at innkommende tale kan fortsette når skjermen er låst.

Den oransje mikrofonprikken lyser mens du er tilkoblet, fordi appen holder lydøkten i gang for å kunne ta imot tale i bakgrunnen. Du sender ikke lyd før du holder knappen inne, eller veksler sending med volum opp.

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

`project.yml` setter bundle-id `com.skuyng.walkie`, visningsnavn Walkie, iOS 17 og tom `DEVELOPMENT_TEAM`. Språkmodus er Swift 5, slik at Xcode 26 ikke skrur på Swift 6-sjekkene som standard.

## Begrensninger

- To personer med samme navn skilles ikke av serveren.
- Låst skjerm er satt opp med lydmodus og en aktiv `playAndRecord`-økt. Det er ikke prøvd på en fysisk iPhone herfra. iOS kan likevel stanse appen hvis det er lite ledig minne.
- `ws://` mot offentlig nett kan bli stoppet av App Transport Security. Bruk `wss://` mot Render. Lokalt nett er tillatt.
