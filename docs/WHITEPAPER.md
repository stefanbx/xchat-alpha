# ӾChat — a censorship-free X, discovered on the XNO ledger

**Alpha whitepaper · v0.2 · app v2.2.1**

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

**Retention — a relay is a cache, not an archive, and MEMORY is the limit, not a clock.** Both the
post pointers (heads) and the media (blobs) are kept until the relay is *full*, then evicted by one
**value score — `tips − reports`** — least-valuable first. Media blobs live **on disk in an embedded
SQLite store** (bounded by disk, and they survive a relay restart instead of vanishing with the
process). A blob's value is the tip total of the post that carries it minus its community reports.
Heads live in RAM under a large author cap; each still carries a long TTL (a ~30-day backstop its
author refreshes while active), but that is *not* the practical limit — the relay holds a post as long
as memory allows and, under pressure, drops the lowest-value heads first. A head's value is the
author's **on-chain reputation, which the relay computes itself from the ledger** (`account_rep` —
balance and chain activity) — **no trusted third party, no pushed hint.** It's Sybil-resistant (a
throwaway account is 0) and it already reflects tips: a tip is on-chain XNO that *raises the creator's
balance*, so a popular creator's reputation rises on its own. So a Sybil head-flood can never push real
content out (a purely recency-based cleanup would keep the freshest spam and evict older real posts).
Availability is therefore **economic, not eternal**: content survives because it is worth keeping, and
**pay-to-pin** (§6) lets anyone pay a relay to protect a specific item from eviction for a span
proportional to the amount. Content nobody values and nobody pins is eventually dropped — the
honest alternative to unbounded storage or a central archive. (Popular content is also *replicated*
to more relays; the weak stays single-copy; nothing is force-kept.)

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

## 5. Moderation — community reports feed one value score

Moderation is **community reports**. A report is a signed record — `report|account|postId|ts`, signed
on-device — fanned out to the relays. The relays store it (verifying nothing); an aggregator verifies
each signature and the key↔author binding and counts **distinct reporters** per post. A viewer sets a
threshold **they choose** (≥10% / ≥50% / ≥90% of a small quorum) and posts above it are hidden — "Show
anyway" always reveals, so per-viewer filtering stays subjective and reversible.

What's new is that reports are a **negative value signal in the same score that governs retention**.
Every stored item is ranked by `score = tips − reports`, and that one number drives *everything*:
eviction (lowest score drops first, so reported-and-untipped goes before anything), **sync between
relays** (highest score replicates first; reported content is not propagated), and the feed. Once a
post crosses a hard **takedown** threshold of distinct, signature-verified reporters, it is dropped
from the feed for everyone and its media is deleted from the relays — a **community-consensus takedown**,
not a per-viewer hide. Paying to pin still protects content from eviction, and every report is signed,
so a single relay cannot suppress content by fabricating reports. This is a deliberate shift from
"nothing is ever deleted": the network now removes what a quorum flags, while individuals keep a
finer, reversible filter on top.

**Reputation-weighted, not one-account-one-vote.** Each report counts for its author's **on-chain
reputation** — an *unopened* throwaway account weighs **0**, and an opened account earns weight from
its balance and chain activity (both costly to fake at scale), and **decays** on a ~30-day half-life of
on-chain *inactivity* (read from the account's last-block timestamp) so stale standing fades. That
on-chain reputation is the **pre-trust seed** for a round of **iterative trust propagation**
(pre-trust-anchored EigenTrust): trust flows between reporters who *agree* — who flag the same posts —
and the vector `t = (1−α)·Cᵀ·t + α·p` is iterated to a fixed point. So a modest account whose calls are
corroborated by high-trust accounts is **boosted** above its own pre-trust, while a lone-wolf or
frivolous reporter is discounted. The decisive property is **conservation**: because the agreement
matrix is row-stochastic and the teleport re-anchors to pre-trust, **total trust converges to the total
on-chain reputation** — a Sybil swarm (pre-trust 0) can only *redistribute* real trust by mimicking
trusted reporters, **never manufacture it**, so no number of empty accounts can force a takedown. The
takedown threshold and the shield fraction are over the sum of reporters' propagated trust, and one
score — `tips − weighted_reports` — drives eviction, sync, and takedown alike. Every input is read or
verified from the ledger + the signed report graph — **no trusted party.** ✅ *Residual:* a genuinely
wealthy, *active* adversary is still not priced out (real reputation buys weight); the knobs
(`XC_REP_*`, `XC_TAKEDOWN_WEIGHT`) tune the rest. 🔨

## 6. Funding — tips reward creators, pay-to-pin keeps content alive

Two — and only two — kinds of value touch Nano, and they are **different flows to different parties**:

**Tips** reward the **creator** (to their wallet). They are **batched**: the client tallies tips
off-chain and settles the total in one **direct** send per creator — no payment-channel hub (a
chokepoint), no custodian. A tip can be split immutably on-chain between the creator, the relay that
served the media, and whoever reposted it. (A tip is refused if the wallet can't cover it, so a tally
is never a promise the network can't keep.)

**Pay-to-pin** pays a **relay** to *keep content alive*. A pinner sends a small XNO amount to a
relay's own account; the relay verifies that payment on-chain — a public ledger read, so it never
holds a key or moves funds — and protects that CID from eviction for a duration proportional to the
amount (each payment consumed once). This makes availability a **market**: valued content is paid to
persist; unpaid content evicts (§3). An author can pin their own posts to outlive their activity; a
fan can pin content they want kept. Even without an explicit pin, eviction is value-weighted by tips,
so popular content survives longer for free.

Everything else — the entire social graph — never touches the ledger, so the network stays light no
matter how busy it gets.

**Minimal custody.** The in-app wallet is a *tip float*, not a bank. A safety cap (2 XNO in the
alpha) plus an optional auto-sweep to an external savings address the app cannot spend from bound
how much is ever at risk inside the app; your savings live in your own wallet (see §9).

## 7. Self-delivery — updates verified against public source, with no single key

The app updates **itself** through its own network, and — like everything else here — the trust is
**plural, not vested in one authority.** A single signing key would be a single point of failure
(leak it → everyone gets malware; lose it → updates die), so distribution is designed to not depend
on any one secret:

- **Reproducible builds.** The APK is a *deterministic* function of the public source: the same
  commit builds to byte-identical bytes with the same SHA-256. Anyone can rebuild from the open
  repository and confirm the released binary **is** the published code — so trust rests on the code
  everyone can read, not on a signature. A malicious binary is caught by anyone who rebuilds.
- **Plural attestors (K-of-N), user-chosen — the same model as moderation.** Independent maintainers
  each attest "commit X builds to hash H." The client accepts a release backed by at least *K*
  independent attestations, and the user chooses which attestor set to trust. No single key can push
  an update; losing one attestor doesn't stop updates.
- **On-chain transparency.** Release hashes + attestations are committed to the XNO ledger
  (append-only, public), so serving *different* bytes to different users is publicly detectable — no
  hidden, targeted update.
- **Content-addressed serving over plural relays.** The bytes are pinned to relay caches by hash; the
  client **re-verifies the SHA-256 on-device** before installing. A takedown of any relay doesn't
  stop updates; a hostile relay serving wrong bytes fails the hash check.
- **The human is the final gate.** Installs require an explicit tap; the app surfaces the version,
  commit, and how many attestors agree. The one layer that isn't censorship-free is the OS install
  gate itself (Android allows sideload/self-update; iOS does not) — and the app says so.

**Bootstrapping honesty — what's shipped vs. the target.** The alpha **implements today**: signed,
content-addressed releases; the APK pinned + **auto-replicated** across plural relays; the client
fetching from *any* relay and **re-verifying the SHA-256 on-device** before an explicit-tap install;
and an auto-update check. It uses a **single publisher key** (held outside the repo; the app pins only
the public account). The **reproducible builds** and the **K-of-N attestor quorum** described above are
the *design target*, **not yet shipped** — they are the hardening toward 1.0 (reproducible builds make
the binary trustless relative to the source; a real quorum needs several independent maintainers).
Until then the honest trust root for updates is that single pinned key — see §8 and §11.

### How a release propagates — no single domain, no single pusher

Two things travel separately, which is why there is no central distribution point:

- **The pointer** (a few hundred bytes): a **signed, append-only release record** `{version, cid,
  sha256, size, changelog, sig}`. **Today it lives on the relays** (published to every relay, kept as a
  list so a forged record can't evict the real one — the client keeps the highest *validly signed*
  version). Committing the record (and attestations) **on the XNO ledger** for public, website-free
  tamper-evidence is the roadmap item, not yet shipped.
- **The bytes** (the APK): **content-addressed** by hash and cached on the **relays**, plural and
  interchangeable — and now **auto-replicated + pinned** across the relay set on publish.

The client reads the pointer from the ledger, fetches the bytes from *any* relay that has them, and
checks the hash. It never matters *where* the bytes came from — only that they match the
on-chain-attested hash.

Nobody pushes the release to every relay. The publisher pins it to a handful they can reach; from
there it spreads with the same gossip the content layer uses — **relay-to-relay backfill**,
**supporter/client re-pinning** to relays that lack it, and **lazy pull-and-cache** on first request.
More relays means more redundancy, not more coordination.

And because the build is **reproducible**, the bytes are **regenerable from the public source** by
anyone (`git checkout <commit> && ./reproduce.sh` → the same hash). So the APK is not a precious
artifact that must flow from one origin — it can be mirrored anywhere (relays, IPFS, a git host, a
friend's phone), every copy verifiable by the same hash. **The source repository is the real seed of
distribution**, and git is itself distributed. A git host can vanish, any relay can be down, and the
right code still gets out — while wrong bytes, from anywhere, are rejected by hash.

## 8. Trust roots (there are exactly three, and all are minimal)

1. **Your seed** — your identity. Yours alone; back it up.
2. **The release publisher** — authenticates app updates. **Today this is a single pinned publisher
   key** (held outside the repo; the app pins only its public account); the update is content-addressed
   and its hash re-verified on-device. The *target* — **not yet shipped** — replaces that single key
   with a **reproducible build of the public source** confirmed by a **user-chosen K-of-N quorum** of
   independent attestations logged on-chain, so no single secret is load-bearing. It is deliberately a
   growable anchor, but honesty requires stating that the alpha's update trust rests on that one key.
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
- **A relay serves a malicious APK / a forged release.** → The bytes are **content-addressed** and
  the **SHA-256 is re-checked on-device**; a hostile relay serving wrong bytes fails the hash. ✅
- **A single compromised or lost signing key** (the residual single-point-of-failure). → Distribution
  is designed to **not depend on one secret**: the APK is a **reproducible build of the public source**
  (anyone can rebuild and verify), releases require a **user-chosen K-of-N quorum** of independent
  attestations, and hashes are logged **on-chain** for public auditability. One compromised key can't
  push an update; one lost key doesn't stop them. Honest bootstrap: today the quorum is size-1, but
  the mechanism is plural by design. 🔨
- **Confirming the APK matches the source.** → **Reproducible builds** + published SHA-256 +
  on-chain attestations let anyone confirm the binary *is* the open code — trust in the code, not a
  signer. 🔨 (alpha ships full source + APK SHA-256 + cert fingerprint; reproducibility is the
  hardening step)
- **Silent/forced install.** → Installs require an **explicit user tap**; no background auto-install. ✅
- **Downgrade attack.** → The client keeps the **highest attested** version; an attacker can't forge
  a quorum. ✅
- **A targeted (per-user) malicious update.** → The on-chain transparency log makes serving different
  bytes to different users publicly detectable. 🔨

### Money (tips & settlement)
- **A malicious app *build* steals your funds.** The app holds your key, so if poisoned code ever
  runs it can spend whatever that key controls — **no distribution scheme cures this once it's
  running** (true of every self-custody wallet). Two-sided defense: (1) **verified distribution** keeps
  bad builds off your device in the first place (reproducible builds + confirmations); (2) **minimal
  custody** bounds the damage if one slips through — the app is meant to hold only a small **tip
  float**, enforced by a **safety cap** (2 XNO in the alpha) plus an optional **auto-sweep** that
  forwards anything above the cap to an **external savings address the app holds no key for.** So a
  bad build's ceiling is the small cap, never your savings — real funds stay in your own wallet.
  ✅ (cap + auto-sweep, verified: 4.07 → 2.0 XNO, excess auto-moved out) · 🔨 (prevention side)
- **A node redirects your tip to the attacker.** → **On-device signing**: you sign the exact
  recipient and amount locally; the node cannot alter it. 🔨
- **Over-committing funds you don't have** (tips tallied off-chain, then a pin or a send drains the
  balance, so settlement fails and a creator was never actually paid). → **Cross-path reservation**:
  the un-settled tip tally is subtracted from available balance before a tip is accepted *and* before
  a pay-to-pin or a wallet send — no path can spend XNO another has already claimed. An over-commit is
  refused up front with the reason, not discovered at settle time. ✅ (verified live: with 0.48 XNO
  and 0.01 tallied, a 0.475 send is refused — "0.01 reserved for pending tips")
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

*Can the network go down by spam? — the whole network, no; a single un-hardened relay, partly, today.*

- **Storage exhaustion — flood a relay with media until it falls over.** → **Stopped.** Content blobs
  live in a **byte-capped, value-weighted** on-disk cache (old + untipped evicted first, tipped and
  pay-to-pinned last), so no volume of unpaid media grows a relay without bound, and keeping content
  alive costs XNO (§6), which prices the attack. ✅
- **Metadata / Sybil flood — mint unlimited keypairs and push a head (or a mention, or a DM) each.**
  → **Bounded.** Every mutable table now has a hard ceiling: head **expiries are clamped** (no eternal
  head) and expired heads are **actively pruned** each tick with a hard author cap as a backstop;
  notifications are capped **per-recipient and per distinct-account**; the DM mailbox is a **bounded
  ring** with O(1) dedup; releases stay capped at 24/author; and media blobs are byte-capped on disk.
  So no volume of writes grows a relay's memory without bound — and because clients **verify every
  signature on read**, forged spam is inert junk that can never reach a feed regardless. A per-IP
  write rate-limit adds a coarse CPU throttle, and the redundant per-write state flush was dropped for
  a dirty-flagged 5 s autosave. ✅ (verified: clamp, author cap→429, prune frees slots, notif+DM caps,
  rate-limit→429, reads unthrottled, persistence across restart). *Residual:* writes proxied through a
  shared node share one IP (so the rate-limit is deliberately generous), reads aren't yet throttled,
  and there's no write-time proof-of-work — memory is bounded by the caps, not by write cost. 🔨
- **Why the *network* still doesn't go down.** → Relays **don't sync**, so poisoning one doesn't
  spread; clients read the **union** of relays and drop any that misbehave; and anyone can stand up a
  fresh relay in minutes. The worst case is "one relay gets slow or OOMs and restarts — clients keep
  using the others." Availability is **plural by construction**, not dependent on any single host. ✅
- **Request-rate DoS against a node.** → Read/aggregation load is bounded per node (a short feed
  cache) and scales horizontally by adding nodes and relays; measured capacity and the scaling path
  are in `docs/SCALING.md`. Per-node request rate-limiting is 🗺️.

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
        └─ forwards signed events to ──► plural relays  (cache: byte-cap + value-weighted eviction)
                                              ▲
       tips → creators · pay-to-pin → relays ──► Nano ledger (batched, direct, signed on-device)
```

**Your key never leaves your device.** The app signs every post, event, and tip locally; the node
is a thin relay-and-ledger-reader that only forwards already-signed data and scans the ledger for
discovery — it never sees your seed and cannot sign or spend on your behalf. That is what makes it
safe to run your own node *or* point at anyone's public node: none of them can steal from you,
because none of them ever hold a key. The node is pure Python and runs on any OS.

## 11. Status & honesty

This is an **alpha**.

**Done.** The node is **pure Python** (`nanopy` ed25519-blake2b) and runs on any OS. Relay discovery
is **verified end-to-end against the live mainnet ledger**: a second independent relay was announced
on-chain (operator-signed, URL committed in the block) and a fresh install **discovered it by itself
at first load** — no hardcoded URL. The **money paths are verified live on mainnet**: a real receive
(on-device-signed open block, delegated PoW), a real creator settlement, and **pay-to-pin** (a relay
confirmed a real payment on-chain and protected the content from eviction). The self-update path is
signature + on-device SHA-256 verified. And the two items this section used to list as pending are
now shipped:

- **On-device signing, everywhere.** Every write path — posts and their heads, comments, follows,
  profiles, poll votes, DM keys, and every Nano state block (send, receive, open, change) — is
  signed in the app with the seed, which never leaves the device. There is no API that accepts a
  seed, because the routes that used to take one (`/api/wallet`, `/api/post`, `/api/settle`,
  `/api/send`) are gone. The node verifies signatures, adds proof-of-work, and relays bytes.
- **An offline publisher key.** The update-signing key is generated by `xc_release.py keygen`, held
  outside the repo at `~/.xchat/publisher.key` (0600), and the app pins only the public account. It
  used to be derived from a constant in the source, which meant anyone could sign a release the app
  would accept; with no publisher pinned, in-app updates now refuse to run rather than trust a
  record from a stranger.
- **Bounded, economic availability.** Relays are caches with a byte cap and **value-weighted
  eviction** (old + untipped dropped first), and **pay-to-pin** lets anyone pay a relay to keep a
  specific item — verified on-chain, no key held by the relay. So storage can't grow without bound,
  and content survives because it is valued, not because a host promises to keep it forever. Media
  blobs live in an **on-disk SQLite cache** that survives a relay restart (they used to sit in RAM and
  vanish on redeploy) — verified live: the cache persisted a restart and a real photo posted from the
  app landed in it and served back.
- **Resilient client + self-delivery, hardened.** Posts written **offline queue and auto-send** when
  the signal returns (and survive an app restart); you can **delete your own posts** (the thread is
  re-signed and republished without them); accounts that share the default handle are distinguished by
  a short, **unforgeable account tag** derived from the pubkey. The relays form a **two-way mesh** so
  discovery doesn't hinge on a single on-chain scan, and a published **release auto-replicates + is
  pinned across every relay** so an update reaches the whole set on its own. The app **auto-checks for
  updates on launch** (and periodically) and shows a one-tap banner; the APK is fetched **direct from a
  relay** and its SHA-256 re-verified on-device before install — all verified end-to-end on a device.

**How that claim is tested.** `test/interop_test.py` signs one canonical message per write path with
the *shipped* app wallet (Dart/nanodart) and verifies each with the *shipped* node verifier
(Python/nanopy) — a one-byte disagreement between the two would reject every write, and it would
look like a network fault rather than a crypto one. `test/e2e_test.py` then runs a real relay and a
real node and drives all of it through the app's own signer, checking each path twice: that a valid
record is accepted and lands on the relay, and that a **tampered** one is refused.

**Honest limits.** The seed is stored in the app's private `SharedPreferences`, which is not
hardware-backed — a rooted or physically compromised phone can read it (moving to the platform
keystore is the next step). **Wallet recovery is *only* your seed backup** — a wallet is a random seed,
so if it isn't saved and the app is reinstalled, its funds are unrecoverable (on-chain but unspendable).
Backup is now **mandatory and verified**: creating a wallet requires re-entering the seed characters at
random positions *from your written copy* (the seed is hidden during that check) before you can enter the
app, and an existing wallet is nagged by a persistent banner until it confirms — closing the
accidental-loss footgun. **Receiving XNO is gated on that confirmed backup** too (the receive QR is
withheld and the Receive button locked until the seed is secured), so funds can't land in a wallet you
can't recover. Still pending: moving the seed into the platform keystore. **Update delivery works but isn't production-grade:** the download comes
direct from a relay and is hash-verified, but the hosted node and relays are small single instances
that can get busy, so an in-app update can need a retry or two. Moderation labeling is minimal. Network metadata is **not** private (no
onion routing yet — treat your IP as visible). The node is single-identity-per-instance for the
state it caches, though it no longer holds an identity that can sign. A relay's one-time on-chain
*announcement* is a real (tiny) mainnet transaction the operator makes with a funded wallet. **Relay
anti-spam is now bounded but not maximal**: every table has a hard ceiling (clamped + pruned heads,
capped notifs/DMs, byte-capped blobs) and a per-IP write throttle, so a Sybil flood can no longer grow
a relay's memory without limit (§9) — but there's no write-time proof-of-work yet, reads aren't
throttled, and a shared node counts as one IP for the write limit. See the README for how to run a
node, run a relay, announce it on-chain, and verify discovery yourself.

---

*ӾChat is free software released for research and experimentation. It moves no money on your
behalf; you control your keys and your funds.*
