# ӾChat — a censorship-free X, discovered on the XNO ledger

**Alpha whitepaper · v0.1**

ӾChat is a Twitter/X-style social app for phones with no company, no server account, and
no removable point of control. Your identity is a cryptographic keypair, your posts are
signed events replicated across interchangeable relays, and the app finds those relays by
**scanning the Nano (XNO) ledger** — so there is no hardcoded server and no directory anyone
can seize. The "Ӿ" is the XNO symbol.

This document describes the architecture and, most importantly, **how anyone can independently
verify the claims** — especially that the network is discovered from the public ledger.

---

## 1. Design goal

A social network is censorship-resistant only if **every** load-bearing component can be
routed around: identity, content, discovery, moderation, funding, and even app distribution.
A single fixed server, a single directory, or an app-store gate is enough to defeat the whole
thing. ӾChat removes each of these single points of failure in turn.

The organizing principle throughout: **the ledger is for settlement, never for transport or
storage.** A billion posts cost zero ledger growth. Nano is touched only to (a) *settle a tip*
and (b) *announce where a relay lives* — both tiny, both optional to any given action.

## 2. Identity — a keypair, not an account

A user **is** a Nano keypair, derived from a 64-character seed the app generates and the user
backs up. There is no email, no password, no server-side account. Because the identity is a
key, it is portable: restore the seed on any device and your posts, follows, and tips return —
they live on the network, not the phone. Handles (`@you.xno`) are cosmetic; the account address
is the real identity, and nobody can rename, suspend, or de-federate a keypair.

## 3. Content — signed off-chain events on plural relays

Posts, likes, reposts, comments, follows, profiles, and polls are **signed events**, not ledger
transactions. Each author publishes a signed, sequence-numbered **head** (`{author, seq, cid,
ts, sig}`) that points to their current content, addressed by hash (CID). Heads are gossiped to
**several independent relays**.

- A relay **verifies nothing and stores signed bytes + ciphertext.** Clients verify every
  signature and bind each head's key to its author (`pub_to_addr(pub) == author`). A malicious
  or buggy relay can therefore only *fail to serve* — it can never forge a post or silently
  alter one.
- Clients read from **all** relays in parallel and keep the highest valid sequence per author,
  so one relay being slow, censoring, or offline changes nothing. (Kill a relay mid-session and
  the feed is intact.)
- Encrypted 1:1 DMs use a separate X25519 keypair derived from the same seed; relays hold only
  ciphertext.

Because authenticity comes from the signature rather than from *where* the bytes came from,
content is host-independent by construction.

## 4. Discovery — self-announcing relays, found by scanning the ledger (no SPOF)

This is the core contribution. The problem: how does a fresh install find *any* relay without a
hardcoded URL or a directory server that can be taken down?

**There is no directory.** Each relay is self-sovereign:

1. A relay owns its own XNO account and **commits its own URL on its own chain** (in a block it
   signs — the account *is* the public key, so "relay X is at URL Y" is guaranteed by the ledger).
2. It **checks in** by sending a dust transaction to a set of **rendezvous accounts** — fixed,
   well-known XNO addresses that are *keyless meeting points*: nobody needs their private key,
   they are only ever read, their check-ins are immutable, and they are **plural** so no single
   one can be seized.

Discovery is then a **scan**: read a rendezvous account's incoming transactions to enumerate the
set of relay accounts, then read each relay's own chain for its URL. Nano has no "list every
relay" query — some rendezvous point is unavoidable — but making it *keyless, plural, and
immutable* means censoring discovery would require censoring the Nano network itself.

Consequences:

- **No relay URL is hardcoded** anywhere — only the rendezvous addresses, which are inert
  meeting points, not controllers.
- Sybil relays are harmless: a fake relay can announce itself, but it can only fail to serve;
  clients use plural relays and verify content signatures regardless.
- After the first scan, the client **persists the relay list** and reconnects directly, re-scanning
  in the background to pick up new relays and drop stale ones.

**How to verify:** pick any rendezvous address from the config, open it in a public Nano block
explorer, and you will see the relay accounts' dust check-ins; open a relay account and you will
see the block whose contents encode that relay's URL. The app is doing exactly this read.

## 5. Moderation — subjective labels, nothing globally deleted

Moderation is a set of **signed labels** published by labelers (each a keypair) whose weight is
their on-chain stake, decayed if they go inactive and scaled by their accuracy. A client applies
a *reputation-weighted* threshold **it chooses** to hide or flag content. Different viewers can
trust different labelers; nothing is ever deleted from the network — "Show anyway" always reveals.
This is subjective, user-controlled moderation, not global censorship.

## 6. Funding — batched, non-custodial tips

The only value that touches Nano is **tips**, and they are **batched**: the client tallies tips
off-chain and settles the total in one **direct** send per creator — no payment-channel hub (a
chokepoint), no custodian. A tip can be split immutably on-chain between the creator, the relay
that served the media, and whoever reposted it. Everything else — the entire social graph — never
touches the ledger, so the network stays light no matter how busy it gets.

## 7. Self-delivery — updates over the relays, no app-store gate

The app updates **itself** through its own network: a publisher key signs a content-addressed
release record, appended to a per-publisher list on the relays; the APK bytes are pinned to relay
caches. The client keeps the highest *valid* (publisher-signed) version, downloads the bytes,
**re-verifies the SHA-256 on-device**, and hands off to the OS installer. A forged higher version
signed by the wrong key is ignored; a takedown of any relay doesn't stop updates. The one layer
that isn't censorship-free is the OS install gate itself (Android allows it; iOS does not) — and
the app says so honestly.

## 8. Trust roots (there are exactly three, and all are minimal)

1. **Your seed** — your identity. Yours alone; back it up.
2. **The publisher's public key** — authenticates app updates. Only the *public* address is pinned
   in the client (verify-only); the private key is held **offline** by the maintainer and never
   ships, so no one else can sign a release.
3. **The rendezvous addresses** — the discovery bootstrap. *Keyless and plural* — meeting points,
   not controllers. This is the irreducible minimum every peer-to-peer system needs (Bitcoin has
   hardcoded DNS seeds); the design makes it as weak-as-possible rather than pretending it away.

Everything else is derived, signed, replicated, and swappable.

## 9. Threat model — every attack vector we considered, and how it's stopped

We assume **every relay, every node you don't personally run, and the network itself are hostile.**
Here is each vector, its defense, and honest status (✅ done · 🔨 building before public release ·
🗺️ roadmap).

### Keys & identity
- **A node steals your seed.** → **On-device signing**: your seed never leaves your device; nodes
  only relay signed events and read the public ledger. This is the single most important property —
  it's what makes running *any* node safe. 🔨
- **A guessable publisher key lets anyone sign a malicious update.** → The publisher signing key is a
  real, random key held **offline** by the maintainer; only its **public** address ships. (The old
  demo key derived from a source constant is removed.) 🔨
- **A relay's account key is guessable from its public URL** (so it could be impersonated or, if
  funded, drained). → A relay announces from the **operator's own secret key**, never a URL-derived
  one. 🔨
- **Seed at rest on a lost/rooted phone.** → Move seed storage to the OS secure enclave/keystore.
  (Alpha uses app-private storage.) 🗺️

### Content & relays
- **A relay forges posts.** → Every event is **signature-verified**, and each author's head key is
  bound to its account (`pub_to_addr(pub) == author`). Forgeries fail. ✅
- **A relay tampers with content.** → Content is **hash-addressed** (CID); any change breaks the
  hash. ✅
- **A relay reads your DMs.** → Relays hold only **X25519 ciphertext**. ✅
- **A relay censors/withholds content.** → **Plural relays**; clients read from all and keep the
  highest signed sequence. Killing a relay leaves the feed intact. ✅
- **Replay/rollback of old signed content.** → **Monotonic sequence numbers** + head TTL; a lower-seq
  replay is ignored. ✅
- **Sybil relays flood discovery.** → A fake relay can only fail to serve; clients verify content
  signatures and use plural relays. Each announcement costs on-chain dust + PoW. ✅
- **Eclipse (surround a client with only malicious relays).** → Honest relays are announced
  **on-chain and immutably**; an attacker can add fakes but cannot remove or hide honest
  announcements, so a scanning client still finds real relays. ✅

### App updates — the "push malware to steal Nano" vector
- **A relay serves a malicious APK / a forged release.** → The client accepts a release only if it is
  **signed by the pinned publisher key** AND the downloaded APK's **SHA-256 matches the signed
  record**, re-verified on-device. Wrong bytes → hash mismatch → rejected; forged record → wrong key
  → ignored. ✅ (tested)
- **Silent/forced install.** → Installs require an **explicit user tap**; no background auto-install. ✅
- **Downgrade attack.** → The client keeps the **highest** valid version; an attacker can't sign a
  higher one. ✅
- **Can't confirm the APK matches the source.** → Full source + APK **SHA-256** + signing-cert
  fingerprint are published; **reproducible builds** are the next step. 🗺️

### Money (tips & settlement)
- **A node redirects your tip to the attacker.** → **On-device signing**: you sign the exact
  recipient and amount locally; the node cannot alter it. 🔨
- **Reshare-payment gaming** (reshare after a tip to claim the split). → Attribution is **locked at
  tip time**. ✅
- **Double-spend / balance forgery.** → Handled by Nano mainnet consensus, outside our trust surface. ✅

### Moderation
- **A malicious labeler mass-flags to censor.** → Labels are **reputation-weighted**; the viewer
  chooses the threshold and which labelers to trust; nothing is ever globally deleted ("show anyway"
  always works). ✅
- **Forged labels.** → Labels are signed; forgeries fail verification. ✅

### Client & supply chain
- **Malicious content exploiting the renderer** (crafted media, hostile links). → Text renders as
  text (no markup execution); links aren't auto-opened. Hardening media decoders is 🗺️.
- **A malicious dependency** in the app or node. → Pinned versions; dependency audit + minimal deps
  (the node is stdlib + `nanopy` + `pynacl`). 🗺️

### Network & privacy
- **Relays/nodes see your IP and what you fetch.** → Network-metadata privacy (onion routing) is
  🗺️; the alpha does **not** hide network metadata — treat it as public.

### Denial of service
- **Spam floods relays.** → Signed events tie spam to a key (block/mute it); relay-side rate limits
  and optional proof-of-work on posts are 🗺️.

**The irreducible trust roots stay three:** your seed (on your device), the publisher's *public*
key (pinned, verify-only), and the rendezvous addresses (keyless, plural). Everything else is
derived, signed, replicated, and swappable.

## 10. Architecture at a glance

```
  📱 app (Flutter) — HOLDS your seed, SIGNS locally
        │  (only signed events + read requests leave the phone)
        ▼
   backend node (Python, pure, any OS) ──► reads the XNO ledger ──► discovers relays
        │                                     (scan keyless rendezvous)
        └─ forwards signed events to ──► plural relays  (signed bytes + blob cache)
                                              ▲
                    tips settle ──► Nano ledger (batched, direct, signed on-device)
```

**Your key never leaves your device.** The app signs every post, event, and tip locally; the node
is a thin relay-and-ledger-reader that only forwards already-signed data and scans the ledger for
discovery — it never sees your seed and cannot sign or spend on your behalf. That is what makes it
safe to run your own node *or* point at anyone's public node: none of them can steal from you,
because none of them ever hold a key. The node is pure Python and runs on any OS.

## 11. Status & honesty

This is an **alpha**. **Done:** the node is **pure Python** (`nanopy` ed25519-blake2b) and runs on
any OS; relay discovery is **verified against the live mainnet ledger** (read path); the self-update
path is signature + on-device SHA-256 verified. **Being hardened before public release (🔨):**
**on-device signing** so the node never holds your seed, a real **offline publisher key**, and the
relay announce signed by the operator's own key. **Honest limits:** moderation labeling is minimal;
network metadata is **not** private (no onion routing yet — treat your IP as visible); the node is
single-identity-per-instance (multi-tenant hosting is roadmap); and a relay's one-time on-chain
*announcement* is a real (tiny) mainnet transaction the operator makes with a funded wallet. See the
README to run a node, run a relay, announce it, and verify discovery yourself. See the README for how to run a node, run a relay, announce
it on-chain, and verify discovery yourself.

---

*ӾChat is free software released for research and experimentation. It moves no money on your
behalf; you control your keys and your funds.*
