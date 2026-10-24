# Walkie

Enkel walkie-talkie i nettleseren. Skriv navn og kanalkode, hold inne knappen, og snakk med andre på samme kanal.

## Kom i gang

```bash
npm install
npm start
```

Serveren lytter på `PORT` fra miljøet, ellers port 8080. Åpne adressen i nettleseren og tillat mikrofon.

## iPhone

Native app for iOS 17 ligger i [`ios/`](ios/README.md). Den bruker samme kanal og samme PCM-lyd som nettsiden. Standard server i appen er `wss://walkie-bc0z.onrender.com`.
