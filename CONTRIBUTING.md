# Building & contributing to ӾChat

Everything here is source you can build, change, and run. Contributions welcome — the roadmap
items in the whitepaper (Linux node builds, on-device signing, multi-tenant hosting, richer
moderation) are all good places to start.

## Build the app (Flutter)

```bash
cd app
flutter pub get
flutter run                      # on a connected device/emulator
# or a release APK:
flutter build apk --release --target-platform android-arm64
```

Requires the Flutter SDK (stable) and, for Android, a JDK 17 + Android SDK. The app talks to a
node over HTTP — set the address in **Settings → Connection**.

## Run the node (backend)

```bash
cd backend
export XC_NANO_RPC=https://rpc.nano.to      # scan the real XNO ledger for relays
python3 kt_server.py 8790
```

`kt_server.py` is a small threaded HTTP server. Each `/api/*` route reuses one of the helper
programs alongside it (`xc_feed.py`, `xc_post.py`, `xc_reldir.py`, …) — so the logic is plain,
readable Python you can audit and extend. State is namespaced per instance via the `XC_NS` env
var (defaults to the port).

### The native crypto helpers

Nano key derivation and block/message signing run through four small native programs, built from
the Keel sources in `backend/crypto-src/` (`derivekey.kl`, `xc_sign.kl`, `kt_block.kl`,
`nano_sign.kl`, …). The prebuilt binaries the helpers call (`/tmp/derivekey`, `/tmp/xc_sign`,
`/tmp/ktblock`, `/tmp/xc_verify`) are currently **macOS/arm64**. To run the node on Linux/Windows,
rebuild them for your platform — Keel transpiles to Go, which cross-compiles anywhere:

```bash
keel --go backend/crypto-src/derivekey.kl > derivekey.go && GOOS=linux go build -o derivekey derivekey.go
# …same for xc_sign.kl, kt_block.kl, xc_verify.kl; place the binaries where the helpers expect them
```

Porting these (or replacing them with a pure-Python Nano crypto lib) is the top roadmap item —
it's what lets any host run a node. PRs very welcome.

## Run a relay

```bash
cd relay
python3 xc_relayd.py 7401 relay-state.json
```

Pure Python, no native deps. Store only holds signed bytes + ciphertext. Host it with a public
URL and announce it on-chain (see the README) so nodes discover it by scanning the ledger.

## Layout

```
app/                Flutter app (Dart) — one codebase, Android + iOS
backend/            the node: kt_server.py + xc_*.py helpers
backend/crypto-src/ Keel source for the native Nano-crypto helpers
relay/              xc_relayd.py — a relay
docs/WHITEPAPER.md  the design, and how to verify discovery on-chain
```

## Ground rules

- Keep the trust model intact: relays verify nothing; **clients verify every signature**.
- The ledger is for settlement and discovery only — never route content or storage through it.
- No component should be a single point of failure. If a change adds one, call it out in the PR.
