# TalkNet

Enkel walkie-talkie i nettleseren. Logg inn, opprett en gruppe eller be om å bli med, eller start en direkte samtale med et brukernavn. Hold inne knappen, og snakk. Du kan lytte til flere samtaler samtidig.

## Kom i gang

```bash
npm install
npm start
```

Serveren lytter på `PORT` fra miljøet, ellers port 8080. Åpne adressen i nettleseren og tillat mikrofon. `GET /version` svarer med git-revisjonen fra `RENDER_GIT_COMMIT` og feltet `store` (`postgres`, `json` eller `starting`). `node scripts/relay-check.js --local` oppretter to kontoer, sjekker invitasjon og at lyd bare går til medlemmer. `node scripts/admin-check.js` sjekker `/admin`.

## Lagring på Render

Render sletter gratis disk ved omstart. Opprett en **Render Postgres** (gratis) og sett miljøvariabelen **`DATABASE_URL`** på webtjenesten til databasens **Internal Database URL** (`postgres://…`). Det er den eneste variabelen som må settes. Deploy på nytt manuelt etterpå (auto-deploy-webhooken fyrer ikke). `GET /version` skal da vise `"store":"postgres"`. Tabellene og nye kolonner lages når serveren starter.

`/admin` er panelet for kontoene i **`ADMIN_USERNAMES`** (kommaseparert). Uten variabelen er det `skuyng`. Innlogging bruker samme brukernavn og passord som appen. Økten er en HttpOnly-cookie på `/admin`, og feilede innlogginger stoppes etter åtte forsøk på et kvarter per IP. En utestengt bruker kan ikke logge inn eller koble til.

Ved oppstart kjøres disse endringene av seg selv, også på en database som allerede finnes:

- `users.banned` (boolean, standard false), `users.banned_at`, `users.ban_reason`, `users.warning`
- `reports.status` (standard `open`), `reports.resolved_at`, `reports.resolved_by`, `reports.note`
- tabellen `talk_days` (`day`, `transmissions`, `talk_ms`) for sendinger og taleminutter

`node scripts/admin-check.js` sjekker panelet mot JSON-lageret.

Uten `DATABASE_URL` lagres brukere og grupper i `data/walkie.json`. Den filen forsvinner når Render starter disken på nytt.

Konto: unikt brukernavn, visningsnavn og passord (scrypt på serveren). Økten er et token. Ny konto må godta vilkårene. Den som oppretter en gruppe er admin og kan invitere på brukernavn, godkjenne forespørsler og fjerne medlemmer. Bare medlemmer får tilstedeværelse og lyd. Et valgfritt gruppepassord (scrypt) lar den som kjenner navn og passord bli medlem med en gang. Uten passord brukes invitasjon eller forespørsel. Admin kan endre eller fjerne passordet. Under Direkte kan du be om kontakt med et brukernavn. Den andre godtar eller avslår. En godtatt kanal vises med den andres navn, og begge kan avslutte den. Blokkering stopper forespørselen og lyden. Du kan blokkere en bruker, slik at lyden deres ikke spilles av hos deg, og rapportere en bruker. Slett konto fjerner brukeren, øktene og medlemskapene. `/personvern` og `/vilkar` beskriver lagring og nulltoleranse for krenkende innhold. Tale lagres ikke.

## iPhone

Native app for iOS 26 ligger i [`ios/`](ios/README.md). Den bruker samme grupper og samme PCM-lyd som nettsiden. Standard server i appen er `wss://walkie-bc0z.onrender.com`.
