# Walkie

Enkel walkie-talkie i nettleseren. Logg inn, opprett en gruppe eller be om å bli med, eller start en direkte samtale med et brukernavn. Hold inne knappen, og snakk. Du kan lytte til flere samtaler samtidig.

## Kom i gang

```bash
npm install
npm start
```

Serveren lytter på `PORT` fra miljøet, ellers port 8080. Åpne adressen i nettleseren og tillat mikrofon. `GET /version` svarer med git-revisjonen fra `RENDER_GIT_COMMIT` og feltet `store` (`postgres`, `json` eller `starting`). `node scripts/relay-check.js --local` oppretter to kontoer, sjekker invitasjon og at lyd bare går til medlemmer.

## Lagring på Render

Render sletter gratis disk ved omstart. Opprett en **Render Postgres** (gratis) og sett miljøvariabelen **`DATABASE_URL`** på webtjenesten til databasens **Internal Database URL** (`postgres://…`). Det er den eneste variabelen som trengs. Deploy på nytt manuelt etterpå (auto-deploy-webhooken fyrer ikke). `GET /version` skal da vise `"store":"postgres"`. Tabellene lages av serveren.

Uten `DATABASE_URL` lagres brukere og grupper i `data/walkie.json`. Den filen forsvinner når Render starter disken på nytt.

Konto: unikt brukernavn, visningsnavn og passord (scrypt på serveren). Økten er et token. Ny konto må godta vilkårene. Den som oppretter en gruppe er admin og kan invitere på brukernavn, godkjenne forespørsler og fjerne medlemmer. Bare medlemmer får tilstedeværelse og lyd. Et valgfritt gruppepassord (scrypt) lar den som kjenner navn og passord bli medlem med en gang. Uten passord brukes invitasjon eller forespørsel. Admin kan endre eller fjerne passordet. Under Direkte kan du be om kontakt med et brukernavn. Den andre godtar eller avslår. En godtatt kanal vises med den andres navn, og begge kan avslutte den. Blokkering stopper forespørselen og lyden. Du kan blokkere en bruker, slik at lyden deres ikke spilles av hos deg, og rapportere en bruker. Slett konto fjerner brukeren, øktene og medlemskapene. `/personvern` og `/vilkar` beskriver lagring og nulltoleranse for krenkende innhold. Tale lagres ikke.

## iPhone

Native app for iOS 26 ligger i [`ios/`](ios/README.md). Den bruker samme grupper og samme PCM-lyd som nettsiden. Standard server i appen er `wss://walkie-bc0z.onrender.com`.
