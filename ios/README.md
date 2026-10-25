# TalkNet for iPhone

TalkNet er en enkel walkie-talkie. Appen kobler seg til den samme serveren som nettsiden. Du logger inn med brukernavn og passord, oppretter en gruppe (for eksempel Familie eller Jobb), eller ber om å bli med. Hold den store knappen inne for å snakke, eller hold volum opp inne. Du kan lytte til flere grupper samtidig, og velge én gruppe å snakke i. Du hører de andre også når skjermen er låst.

Standard server er `wss://walkie-bc0z.onrender.com`. Adressen kan endres i appen. Visningsnavn, lytting og server lagres på telefonen (UserDefaults). Innloggingstoken lagres i Keychain, så appen logger inn av seg selv neste gang.

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
8. **Bundle Identifier** skal være `com.skuyng.walkie`. Visningsnavnet er **TalkNet**. Hvis Xcode sier at identifikatoren er opptatt, endre den til noe unikt, for eksempel `com.skuyng.walkie.dittnavn`.
9. Ikke legg til capabilities. Push Notifications og Push to Talk krever betalt konto og er ikke med i prosjektet.
10. Øverst i vinduet velger du din iPhone som kjøringsmål. Simulatoren kan vise skjermen, men mikrofon, høyttaler og låst skjerm må prøves på telefonen.
11. Trykk **Run** (▶). Første bygging tar litt tid. Telefonen må være ulåst.
12. Hvis appen ikke starter fordi utvikleren ikke er klarert: på iPhone, **Innstillinger → Generelt → VPN og enhetsadministrasjon** (på noen versjoner heter det **Enhetsadministrasjon**). Velg profilen din og trykk **Stol på**.
13. Åpne TalkNet. Innloggingsvinduet viser **TalkNet**, brukernavn, passord og **Logg inn**. **Opprett bruker** åpner registrering, der vilkårene må godtas. **Personvern** ligger på innloggingen. Et lagret token hopper over innlogging.
14. Etter innlogging er Talk-knappen midt på skjermen. Tannhjulet åpner **Innstillinger**: Grupper, Kontakter, Konto og Om. Trykk **Koble til** nederst. Tillat mikrofon når iOS spør. Hold den store knappen inne for å snakke. Hold volum opp inne for å sende mens appen er i forgrunnen, og slipp for å stoppe. **Logg ut** går tilbake til innlogging.

En gratis profil varer i 7 dager. Når appen slutter å starte, kjør den fra Xcode på nytt. Et personlig team kan bare ha noen få egne apper installert samtidig.

## Slik bruker du den

- **Brukernavn** — unikt, 3–20 tegn (a–z, 0–9, punktum, bindestrek, understrek).
- **Visningsnavn** — det andre ser (maks 30 tegn).
- **Passord** — minst 4 tegn. Serveren lagrer en scrypt-hash, ikke passordet.
- **Logg ut** — under Konto i Innstillinger. Tokenet slettes fra Keychain, og innloggingsvinduet vises igjen.
- **Vilkår** — må godtas før kontoen opprettes. Personvern åpnes fra innlogging. Personvern og vilkår åpnes fra Opprett bruker og fra Om.
- **Blokker** — ved et annet medlem. Lyden deres spilles ikke av hos deg. Valget lagres på serveren.
- **Rapporter** — ved et annet medlem, etter bekreftelse. Rapporten lagres på serveren.
- **Slett konto** — under Konto i Innstillinger, etter bekreftelse. Brukeren, øktene og medlemskapene slettes. En gruppe du eier alene slettes. Ellers får det eldste andre medlemmet admin.
- **Direkte** — under Kontakter i Innstillinger. Skriv et brukernavn og trykk **Søk bruker**. Den andre godtar eller avslår. Kanalen viser den andres navn og en prikk når de er pålogget. Lytt og snakk som i en gruppe. **Avslutt** fjerner kanalen for begge. En blokkert bruker kan ikke kontaktes, og lyden deres spilles ikke av.
- **Opprett gruppe** — du blir admin. Store og små bokstaver er samme gruppe. Valgfritt **Passord** låser gruppen. Hashen lagres på serveren.
- **Be om å bli med** — uten passord. Admin godkjenner eller avslår. Har du en invitasjon, godtar du den i stedet.
- **Bli med** — når du skriver gruppepassordet, blir du medlem med en gang. Feil passord vises som «Feil passord». En lås vises på grupper som har passord.
- **Lagre passord / Fjern passord** — admin bytter eller fjerner gruppepassordet.
- **Invitér** — admin skriver et brukernavn. Invitasjonen vises hos den andre under Invitasjoner, med Godta og Avslå.
- **Fjern** — admin ser knappen ved andre medlemmer og må bekrefte. Den som blir fjernet får beskjed og hører ikke gruppen lenger. Admin kan ikke fjerne seg selv. Admin sletter gruppen. Medlemmer forlater den.
- **Lytt** — på per gruppe. Du kan lytte til flere samtidig. Av gjør at du fortsatt ser hvem som er pålogget, men ikke hører lyden.
- **Talk / Velg** — én gruppe om gangen. Hold-for-å-snakke og volum opp sender bare dit.
- **Pålogget** — grønn prikk ved navnet. Den som snakker utheves.
- **Server** — `wss://walkie-bc0z.onrender.com` som standard. `https://` gjøres om til `wss://`, og `http://` til `ws://`. Tomt felt bruker standardadressen.
- **Hold for å snakke** — lyd sendes bare mens knappen holdes inne.
- **Volum opp** — hold inne for å snakke, og slipp for å stoppe, mens appen er tilkoblet og i forgrunnen. Lydnivået settes tilbake etter at du slipper. Systemets volumvisning skjules i vanlig visning og i mørk modus.
- **Høyttaler** — på som standard. På sender lyden i høyttaleren. Av bruker ørepluggen, med mindre hodetelefoner eller Bluetooth er koblet til. Valget lagres på telefonen.
- **Mørk modus** — svart skjerm, lav lysstyrke, og telefonen holder seg våken. Et svakt rødt punkt vises mens du sender. Trykk skjermen for å avslutte. Volum opp virker her også.
- Når noen andre begynner å snakke, spilles en kort tone, og navnet pulserer. Når de slipper, hører du en myk synkende tone.
- **Siste melding** — den siste mottatte sendingen i kanalen ligger i minnet. En liten knapp nederst til høyre spiller den av igjen. Den sendes ikke videre.
- **Ikke forstyrr** — i Innstillinger, med fra- og til-tid. Standard er 22:00–07:00, og bryteren er av til du slår den på. I tidsrommet er innkommende lyd dempet. Navnet vises likevel.
- **Tilkobling** — en prikk og tekst vises når linjen er nede eller prøver igjen. Appen kobler til på nytt av seg selv, med lengre pause for hvert forsøk.
- **Hodetelefoner** — avspillingsknappen veksler sending. Bluetooth-headset kan brukes både som samtale (HFP) og som avspilling (A2DP).

## Lyd og protokoll

Appen snakker samme protokoll som `server.js` og `public/index.html`.

Tekst (JSON):

- til serveren: `{"t":"signup","username":"…","name":"…","password":"…","terms":true}`, `{"t":"login","username":"…","password":"…"}` eller `{"t":"resume","token":"…"}`
- fra serveren: `{"t":"session","token":"…","username":"…","name":"…"}` og deretter `{"t":"inbox","groups":[…],"invites":[…],"requests":[…],"blocked":["…"]}`
- til serveren: `{"t":"subscribe","talk":"…","muted":["…"]}` — `muted` er grupper du er medlem av, men ikke lytter til
- til serveren: `{"t":"createGroup","name":"…","password":"…"}` (passord kan utelates), `{"t":"joinWithPassword","name":"…","password":"…"}`, `{"t":"setPassword","room":"…","password":"…"}` (tomt passord fjerner låsen), `{"t":"invite"}`, `{"t":"inviteReply"}`, `{"t":"requestJoin"}`, `{"t":"requestReply"}`, `{"t":"removeMember"}`, `{"t":"leave"}`, `{"t":"deleteGroup"}`, `{"t":"direct","username":"…"}`, `{"t":"directReply","username":"…","accept":true}`, `{"t":"removeDirect","room":"…"}`, `{"t":"block"}`, `{"t":"unblock"}`, `{"t":"report"}`, `{"t":"deleteAccount"}`
- fra serveren, i `inbox`: `directs` er ventende direkteforespørsler. En godtatt kanal ligger i `groups` med `direct: true` og den andres navn
- fra serveren: `{"t":"reported"}` når rapporten er lagret, og `{"t":"deleted"}` når kontoen er slettet
- fra serveren, i `inbox.groups`: `locked` er sant når gruppen har passord. Hashen sendes ikke ut.
- til serveren: `{"t":"start","room":"…"}` og `{"t":"stop","room":"…"}`
- fra serveren: `{"t":"users","room":"…","users":["…"],"members":[{"id":"…","name":"…"}],"self":"…"}` bare til medlemmer. `members` er én rad per tilkobling, så to med samme navn vises begge. `users` er fortsatt navnelisten.
- fra serveren: `{"t":"start","name":"…","room":"…","id":"…"}` og `{"t":"stop","name":"…","room":"…","id":"…"}`
- fra serveren: `{"t":"error","room":"…","error":"Ikke medlem"}` når du ikke er medlem

Lyd sendes aldri til en socket som ikke er medlem, og bare til dem som lytter. En blokkert avsender høres ikke hos den som blokkerte. Gruppepassord brukes ikke lenger som eneste adgang. Et valgfritt passord kan brukes i tillegg til medlemskap.

Lyd er binære websocket-rammer uten filheader: **PCM, 16-bit med fortegn, little-endian, mono, 16 000 Hz**. Nettleseren legger `sample * 32767` i en `Int16Array` og spiller av med `/ 32768`. iPhone gjør det samme, så appen og nettsiden kan være i samme gruppe. Meldingsraten er fortsatt 16 kHz, slik at eldre klienter kan dekode lyden.

Nettleseren plukker nærmeste sample når den nedsampler. iOS bruker `AVAudioConverter` til maskinvarens rate, og faller tilbake til samme punkt-sampling hvis konverteringen ikke kan kjøre. Avspilling venter omtrent 140 ms før den starter, så korte hull ikke blir smell. Formatet i meldingene er det samme.

## Bakgrunn og låst skjerm

`Info.plist` har `UIBackgroundModes` satt til `audio`. Det trengs for at tale skal kunne spilles av når skjermen er låst. Appen lagrer ikke opptak. Siste melding ligger bare i minnet til appen lukkes eller du logger ut. Lydøkten er `playAndRecord` med modus `.default` (ikke `.voiceChat`, som demper høyttaleren). Motoren skrur på voice processing for ekkokansellering, støyreduksjon og automatisk nivå på mikrofonen. Avspilling jevnes ut i appen. Bluetooth tillater både `allowBluetoothHFP` og `allowBluetoothA2DP`. Et tilkoblet hodesett beholder ruten. **Høyttaler** på legger til `defaultToSpeaker` og tvinger høyttaler bare når ingen ekstern utgang er koblet til. Av lar lyden gå i ørepluggen når det ikke er et hodesett. Økten holdes aktiv mens du er tilkoblet, og `URLSession` bruker utvidet bakgrunns-idle, slik at innkommende tale kan fortsette når skjermen er låst.

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

`project.yml` setter bundle-id `com.skuyng.walkie`, visningsnavn TalkNet, iOS 26 og tom `DEVELOPMENT_TEAM`. Språkmodus er Swift 5, slik at Xcode 26 ikke skrur på Swift 6-sjekkene som standard.

## Begrensninger

- To personer med samme visningsnavn vises som to rader, én per tilkobling.
- Låst skjerm er satt opp med lydmodus og en aktiv `playAndRecord`-økt. Det er ikke prøvd på en fysisk iPhone herfra. iOS kan likevel stanse appen hvis det er lite ledig minne.
- `ws://` mot offentlig nett kan bli stoppet av App Transport Security. Bruk `wss://` mot Render. Lokalt nett er tillatt.
