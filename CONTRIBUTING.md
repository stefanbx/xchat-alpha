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
pip install -r requirements.txt             # nanopy + pynacl
export XC_NANO_RPC=https://rpc.nano.to      # scan the real XNO ledger for relays
python3 kt_server.py 8790
```

`kt_server.py` is a small threaded HTTP server. Each `/api/*` route reuses one of the helper
programs alongside it (`xc_feed.py`, `xc_post.py`, `xc_reldir.py`, …) — so the logic is plain,
readable Python you can audit and extend. State is namespaced per instance via the `XC_NS` env
var (defaults to the port).

### Nano crypto

All key derivation, message/block signing, and verification is **pure Python** via
[`nanopy`](https://pypi.org/project/nanopy/) (ed25519-blake2b) — see the crypto section at the top
of `xc_common.py`. No native build, no platform-specific binaries; the node runs anywhere Python
runs. Encrypted DMs use `pynacl` (X25519). If you extend the signing, keep it byte-compatible with
Nano's scheme so existing signed content keeps verifying.

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
backend/            the node: kt_server.py + xc_*.py helpers (pure Python)
relay/              xc_relayd.py — a relay
docs/WHITEPAPER.md  the design, and how to verify discovery on-chain
```

## Ground rules

- Keep the trust model intact: relays verify nothing; **clients verify every signature**.
- The ledger is for settlement and discovery only — never route content or storage through it.
- No component should be a single point of failure. If a change adds one, call it out in the PR.
