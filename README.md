# Veil

A macOS app that gives your Mac, and your phone through it, a fast private connection to your own VPS on networks
where ordinary VPNs keep stalling. A guided setup takes you from a fresh Ubuntu/Debian server to a working connection:
you paste one command on the server and Veil does the rest.

- macOS 13+, Apple silicon and Intel
- Local proxies: SOCKS5 `127.0.0.1:10808` and `10809`, HTTP `10810`, optional Wi-Fi sharing for a phone on `10811`
- Downloads: [Releases](https://github.com/g3ntrix/veil/releases)
- Made by [g3ntrix](https://github.com/g3ntrix)

## Features

- Setup wizard with live checks that turn green on their own, a one-paste server install, and help for cloud firewalls
- Connection test that shows exactly where a problem is, with a fix for each failure
- Several servers, change a server's IP without touching the VPS, new keys, export and import
- System proxy toggle, phone sharing with a QR code, menu bar item, launch at login

The app generates all passwords and the certificate itself and keeps them in your Keychain, so the server install is a
single command that can be run again at any time.

## Layout

| Path | What |
|---|---|
| `Sources/Veil/App` | App entry, branding, app state, views |
| `Sources/Veil/Shared` | Models, secrets, Xray config, engine, connection tester, server script, proxy helper, UI components |
| `Server/` | `install.sh`, `check.sh` and the server gate, embedded into the install command |
| `Helpers/relayd` | Go helper used by the engine |
| `scripts/` | Build, DMG, release and leak-check scripts |

## Build

Requires Xcode 15+ (Swift 5.9) and Go 1.26+.

```
./scripts/fetch-xray-vendor.sh   # universal Xray into vendor/
./scripts/build-app.sh           # dist/Veil.app (universal, ad-hoc signed)
./scripts/make-dmg.sh            # dist/Veil-<version>.dmg
./scripts/build-release.sh       # builds, writes notes with SHA-256, asks before uploading
```

Tests: `swift test` and `cd Helpers/relayd && go test ./...`. The version lives in `VERSION`.

Run `./scripts/check-secrets.sh` before committing or releasing. Put your own server IPs, one per line, in
`.private/leak-needles.txt` (untracked) so they can never end up in the repo.

## Known limits

- The server side serves one client at a time (one Mac; a phone goes through the Mac).
- Releases are ad-hoc signed and not notarized. See `docs/FIRST-LAUNCH.txt`.

## Buy me a coffee

USDT (BEP20) `0x71F41696c60C4693305e67eE3Baa650a4E3dA796` · TON `UQCriHkMUa6h9oN059tyC23T13OsQhGGM3hUS2S4IYRBZgvx` ·
TRX `TFrCzU7bDey9WSh3fhqCBqhaiMzr8VhcUV`

## License

GPL-3.0. See `LICENSE`. The bundled Xray core is MPL-2.0 ([source](https://github.com/XTLS/Xray-core)).
