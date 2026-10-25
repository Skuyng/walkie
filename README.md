# Walkie

Enkel walkie-talkie i nettleseren. Opprett en gruppe eller bli med på navnet, hold inne knappen, og snakk med andre i gruppen. Du kan lytte til flere grupper samtidig.

## Kom i gang

```bash
npm install
npm start
```

Serveren lytter på `PORT` fra miljøet, ellers port 8080. Åpne adressen i nettleseren og tillat mikrofon.

## iPhone

Native app for iOS 26 ligger i [`ios/`](ios/README.md). Den bruker samme grupper og samme PCM-lyd som nettsiden. Standard server i appen er `wss://walkie-bc0z.onrender.com`.
