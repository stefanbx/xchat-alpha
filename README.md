# ӾChat

**A censorship-free X (Twitter), discovered on the XNO ledger.** Your identity is a Nano
keypair, your posts are signed events on interchangeable relays, and the app finds those relays
by **scanning the Nano ledger** — no hardcoded server, no directory anyone can seize, no app-store
gate. The "Ӿ" is the XNO symbol.

> **Alpha.** This is research software. It moves no money on your behalf — you hold your keys.
> Read [`docs/WHITEPAPER.md`](docs/WHITEPAPER.md) for the full design.

---

## What's in here

| Path | What it is |
|------|------------|
| `app/` | The Flutter app (Android/iOS one codebase) — full source, and the on-device signer in `lib/wallet.dart` |
| `backend/` | The node: `kt_server.py` + the helper programs it runs. **Pure Python, any OS** |
| `relay/` | `xc_relayd.py` — a relay. Pure Python, run one yourself |
| `apk/` | Pre-built signed Android APK + checksums |
| `docs/` | Whitepaper |
| `test/` | The interop and end-to-end tests behind the "your seed never leaves" claim |

## The four layers, in one breath

- **Identity** = a Nano keypair (no email, no account). Restore your seed anywhere, your account returns. **The seed never leaves the phone** — the app signs everything locally and no node API will even accept one.
- **Content** = signed events on *plural* relays. Relays verify nothing; clients verify every signature. One relay down doesn't matter.
- **Discovery** = relays self-announce on the XNO ledger; the app finds them by scanning keyless, plural *rendezvous* accounts. No relay URL is hardcoded. (See [Verify discovery](#verify-discovery-yourself).)
- **Settlement** = only tips touch Nano, batched and non-custodial. The whole social graph is off-chain.

## Install the app

Download `apk/xchat-alpha.apk` onto an Android phone and open it (allow "install from this
source" once). **Verify it first:**

```
sha256sum xchat-alpha.apk
# expected: 3ae5ebdabe940a7241dc7c0aca072b4a4207b6ed2f3bdc16ed700dd1f41263ad
```

Signing certificate SHA-256: `3cc918358c69a37a84be1f048dccfc3a7c1edf74f2a0790cb28b5ccacd15f393`
(`apksigner verify --print-certs xchat-alpha.apk`). Android only installs an update over an app
signed by the same certificate, so this fingerprint is what ties every future release to this one.

On first launch, **Create a new wallet** (write down the seed — it *is* your account) or restore
an existing seed — and you're on the network. Out of the box the app connects to a **hosted alpha
node** (`https://xchat-alpha-node.fly.dev`, reading **mainnet** for discovery) so you can try it
immediately; to be fully self-sovereign, **run your own node** (below) and repoint in
**Settings → Connection**. Once updates land in-app, the app re-verifies each release's SHA-256
on-device before installing — no app store in the trust path.

## Run your own node (recommended — this is the decentralized path)

The node holds **no seed and no identity**: it verifies signatures the app made, adds proof-of-work,
relays bytes, and reads the ledger. It's **pure Python and runs on any OS** — no build step.

```bash
cd backend
pip install -r requirements.txt                 # nanopy (Nano crypto) + pynacl (DM encryption)
export XC_NANO_RPC=https://rpc.nano.to          # scan the REAL XNO ledger for relays
python3 kt_server.py 8790                       # serves on 0.0.0.0:8790
```

Then in the app, **Settings → Connection → Endpoint** → `http://<your-node-host>:8790`.
Signature *verification*, block hashing and address handling are done in-process with `nanopy`
(ed25519-blake2b) — nothing to compile, nothing platform-specific. *Signing* happens only in the
app, so pointing at somebody else's node costs you nothing: it cannot post as you or spend for you.

**Host it publicly** — `deploy/` has a `Dockerfile` + `fly.toml` + `entrypoint.sh` that bundle the
node + a relay + IPFS into one image (`fly deploy`). The reference hosted node runs exactly this.

## Run your own relay

A relay is pure Python and stores only signed bytes.

```bash
cd relay
python3 xc_relayd.py 7401 relay-state.json      # binds 0.0.0.0:7401
```

Host it anywhere with a public URL (a small VM, Fly.io, etc.). Then **announce it on the XNO
ledger** so clients discover it by scanning — this is the one on-chain *write*, made from a
funded wallet by you, the relay operator:

```bash
# from a funded wallet you control (a real, tiny Nano transaction):
python3 backend/xc_reldir.py announce https://your-relay.example.com
```

That commits your relay's URL to your account's chain and checks in at the rendezvous accounts.
From then on, any node scanning the ledger finds your relay automatically — no coordination, no
registration server.

## Verify discovery yourself

You don't have to trust us that discovery is on-chain:

1. Open a **rendezvous account** (printed by `python3 backend/xc_reldir.py accts`) in any Nano
   block explorer. You'll see relay accounts' dust check-ins.
2. Open a **relay account** — its latest block encodes that relay's URL.
3. That is exactly the read the node performs in `xc_common.onchain_relays()`. No hidden server.

In the app, tap the **"📡 relays"** strip to see every discovered relay with its live signal
strength and reliability, and the rendezvous it was found through.

## Run the tests

The "your seed never leaves the device" claim is the one worth checking rather than believing, so
it is what the tests are about.

```bash
cd app && flutter test                  # the wallet: derivation, canonical messages, DM sealing
python3 test/interop_test.py            # the app's Dart signatures, verified by the node's Python
python3 test/e2e_test.py                # a real relay + node, driven through the app's own signer
```

`interop_test.py` matters because the app signs with Dart (`nanodart`) and the node verifies with
Python (`nanopy`): if those disagree by one byte, every post is rejected and it looks like a network
fault. `e2e_test.py` checks each write path **twice** — that a correctly signed record is accepted
and reaches the relay, and that a tampered one is refused. (Both need `nanopy`; the e2e run also
needs `dart` on PATH and an `ipfs` daemon.)

## Security & honesty

- **Alpha quality.** Don't put anything you can't afford to lose on it.
- The app **never** sends money on your behalf; tips and any settlement are user-initiated and
  go directly wallet-to-wallet.
- **The node cannot act as you.** It holds no seed; every write is signed on the device and the
  node only verifies, adds proof-of-work, and relays. There is no API that accepts a seed.
- **The seed is stored in the app's private storage, which is not hardware-backed.** A rooted or
  physically compromised phone can read it. Back up the seed; treat the phone as the weak point.
- **In-app updates need a pinned publisher.** The update-signing key lives outside this repo
  (`xc_release.py keygen` → `~/.xchat/publisher.key`, 0600). With no publisher account pinned, the
  app refuses in-app updates rather than trusting an unknown signer.
- Network metadata is not private: no onion routing yet, so treat your IP as visible.
- The only layer that isn't censorship-free is the OS install gate (Android allows sideload/
  self-update; iOS does not) — the app tells you so.

## License

Released for research and experimentation. See [`LICENSE`](LICENSE).
