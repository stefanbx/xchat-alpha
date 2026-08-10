# Building & contributing to ӾChat

Everything here is source you can build, change, and run. Contributions welcome — the roadmap
items in the whitepaper (hardware-backed seed storage, multi-tenant hosting, richer moderation,
onion routing for network metadata) are all good places to start.

**The one invariant:** the seed lives on the device and nowhere else. Every write is signed in the
app (`app/lib/wallet.dart`) and the node only verifies. If a change would have the node hold, read,
or derive a user key, it is the wrong change — and `test/` will fail it.

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

### Nano crypto, and which side does what

The node **verifies**; the app **signs**. On the node, hashing, address handling and signature
verification are pure Python via [`nanopy`](https://pypi.org/project/nanopy/) (ed25519-blake2b) —
see the crypto section at the top of `xc_common.py`. No native build; it runs anywhere Python runs.
In the app, the same scheme is implemented with `nanodart`, and DM sealing with `pinenacl` (X25519,
wire-compatible with PyNaCl).

Those are two independent implementations of one format, which is a real risk: a mismatch of a
single byte rejects every write and looks like a network outage. So if you touch a canonical message
or the signing scheme, change it on **both** sides and run:

```bash
python3 test/interop_test.py     # app-signed (Dart) → node-verified (Python), all write paths
python3 test/e2e_test.py         # the whole thing, live, including that tampered records are refused
cd app && flutter test           # the wallet on its own
```

## Publishing a release (maintainers)

The update-signing key is a secret and must never enter this repo:

```bash
python3 backend/xc_release.py keygen    # once → ~/.xchat/publisher.key (0600) + the account to pin
# put the printed account in PUBLISHER_PINNED in backend/xc_release.py (or XC_PUBLISHER_ACCOUNT)
python3 backend/xc_release.py publish   # signs + pins the APK to the relays
```

Clients pin the publisher **account** and accept only records signed by it. With nothing pinned,
in-app updates are off — refusing beats trusting whoever answers first.

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
  lib/wallet.dart   the on-device signer: the only place a seed is ever touched
  bin/              the signing harness the tests drive, standing in for a phone
backend/            the node: kt_server.py + xc_*.py helpers (pure Python)
relay/              xc_relayd.py — a relay
test/               interop (Dart↔Python) and end-to-end tests
docs/WHITEPAPER.md  the design, and how to verify discovery on-chain
```

## Ground rules

- Keep the trust model intact: relays verify nothing; **clients verify every signature**.
- The ledger is for settlement and discovery only — never route content or storage through it.
- No component should be a single point of failure. If a change adds one, call it out in the PR.
