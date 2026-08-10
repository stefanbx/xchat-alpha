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
2. **The publisher key** — authenticates app updates. Pinned in the client; its account is public.
3. **The rendezvous addresses** — the discovery bootstrap. *Keyless and plural* — meeting points,
   not controllers. This is the irreducible minimum every peer-to-peer system needs (Bitcoin has
   hardcoded DNS seeds); the design makes it as weak-as-possible rather than pretending it away.

Everything else is derived, signed, replicated, and swappable.

## 9. Architecture at a glance

```
  📱 app (Flutter)  ──►  backend node (Python, run-your-own or hosted)
                              │
                              ├─ reads the XNO ledger ──►  discovers relays (scan rendezvous)
                              └─ talks to ──►  plural relays  (signed events, blob cache)
                                                   ▲
                        tips settle ──►  Nano ledger (batched, direct, non-custodial)
```

The backend is a thin, hostable node: identity, discovery, feed aggregation, and signing. It is
one-identity-per-instance (your seed stays on your node) — **run your own** for full
self-sovereignty, or point at a public node to try it. It reuses the same helper programs whether
run natively or hosted.

## 10. Status & honesty

This is an **alpha**. Known limitations: the reference backend is single-identity-per-instance
(multi-tenant hosting and a fully self-contained app that signs on-device are on the roadmap);
running the backend today needs the native crypto helpers (Keel source included; Linux builds are
a documented next step); moderation labeling is minimal; and mainnet *reads* for discovery are
free, but a relay's one-time on-chain *announcement* is a real (tiny) transaction the relay
operator makes with a funded wallet. See the README for how to run a node, run a relay, announce
it on-chain, and verify discovery yourself.

---

*ӾChat is free software released for research and experimentation. It moves no money on your
behalf; you control your keys and your funds.*
