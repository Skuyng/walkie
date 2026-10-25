# Walkie

Enkel walkie-talkie i nettleseren. Logg inn, opprett en gruppe eller be om å bli med, hold inne knappen, og snakk med de andre medlemmene. Du kan lytte til flere grupper samtidig.

## Kom i gang

```bash
npm install
npm start
```

Serveren lytter på `PORT` fra miljøet, ellers port 8080. Åpne adressen i nettleseren og tillat mikrofon. `GET /version` svarer med git-revisjonen fra `RENDER_GIT_COMMIT` og feltet `store` (`postgres`, `json` eller `starting`). `node scripts/relay-check.js --local` oppretter to kontoer, sjekker invitasjon og at lyd bare går til medlemmer.

## Lagring på Render

Render sletter gratis disk ved omstart. Opprett en **Render Postgres** (gratis) og sett miljøvariabelen **`DATABASE_URL`** på webtjenesten til databasens **Internal Database URL** (`postgres://…`). Det er den eneste variabelen som trengs. Deploy på nytt manuelt etterpå (auto-deploy-webhooken fyrer ikke). `GET /version` skal da vise `"store":"postgres"`. Tabellene lages av serveren.

Uten `DATABASE_URL` lagres brukere og grupper i `data/walkie.json`. Den filen forsvinner når Render starter disken på nytt.

Konto: unikt brukernavn, visningsnavn og passord (scrypt på serveren). Økten er et token. Den som oppretter en gruppe er admin og kan invitere på brukernavn, godkjenne forespørsler og fjerne medlemmer. Bare medlemmer får tilstedeværelse og lyd. Gruppepassord er erstattet av medlemskap.

## iPhone

Native app for iOS 26 ligger i [`ios/`](ios/README.md). Den bruker samme grupper og samme PCM-lyd som nettsiden. Standard server i appen er `wss://walkie-bc0z.onrender.com`.
