# DM plan

Where direct messages stand, what's wrong with them, and the order to fix it in.

Written 2026-08-16, after a day of using DMs for real support conversations with an operator — which
is where most of the items below came from. Nothing here is aspirational: every problem is either
measured or was hit in actual use.

---

## Where it is today

Shipped and verified in 2.4.0–2.4.3:

- messages poll while a thread is open, so a reply lands without leaving the screen
- optimistic send — the bubble appears immediately, dimmed, with a clock, and reconciles against the
  relay's echo on text + a loose timestamp window
- day separators and clock times; consecutive messages group into blocks
- an emoji picker that ships with the app (the device keyboard's emoji key can be absent)
- reply with the original quoted, carried **inside the sealed plaintext** as `> ` lines
- photo attachments, sealed to the peer on-device — verified against the relay's own blob table:
  the attachment is stored with no file signature while ordinary post media beside it is readable
  PNG/JPEG
- an Android alert when a message arrives, raised **locally** so no relay learns "A messaged B at T"

The design constraint that shapes everything below: **relays hold ciphertext and nothing else.**
Any feature that would need a relay to understand a message is off the table unless it can be done
on-device or inside the sealed payload.

---

## Phase 1 — make it fast (the current complaint)

Response feels laggy, and the cause is structural rather than a slow network.

**Measured:** one account's inbox is 32 ciphertexts / ~20 KB today. `/api/dm_inbox?account=` has no
incremental mode, so every poll downloads *all* of it. Three callers hit it: the chat screen every
**5s**, the home screen's badge refresh every **12s**, and the inbox screen. Each call then runs
`dmOpen` over **every** message — and `dmOpen` constructs a fresh `pnacl.Box`, which recomputes the
X25519 shared secret per message per poll. Results are discarded and recomputed next tick. Cost grows
linearly with history, forever.

1. **Persist decrypted messages on the phone, and decrypt only what is new.** This is the real fix
   and the others are details of it. A thread should load instantly from a local store and the
   network should only ever deliver messages we have not seen. Design notes:
   - store plaintext + `{from, to, ts, peer_pk}` keyed by ciphertext, in the platform secure store —
     NOT plain SharedPreferences. The whole point of the product is that these bytes are secret; a
     local cache that any rooted app can read hands away what the relays never got.
   - a message is immutable once sealed, so the store is append-only. No invalidation problem.
   - bound it, and decide the policy deliberately: dropping oldest is fine for a cache, but if the
     relay has also evicted that ciphertext the message is gone for good. Either keep the store
     unbounded and say so, or make eviction match the relay's retention.
   - clearing the wallet must clear this too, or a reinstall leaks the previous identity's messages.

2. **Cache the Box per peer key.** The shared secret is an X25519 scalar multiplication over
   (our key, their key) and is constant for the life of a conversation. `dmOpen` builds a fresh one
   per message, so a poll over 32 messages does 32 scalar multiplications every 5 seconds.

   **TRAP — hit and reverted on 2026-08-16.** Caching plaintext keyed by *ciphertext alone* breaks
   the security property `wallet_test.dart` asserts: "a DM opens for its recipient and nobody else".
   A cache hit returned the plaintext to ANY caller without checking whose box it was, so a wrong
   peer key got the message instead of `null`. The key must include the peer, or the lookup must
   verify before returning. The test caught it immediately — keep that test in front of this work.

3. **Incremental fetch** — `dm_inbox?since=` so a poll transfers new ciphertext only. With (1) in
   place this is what makes a poll cost approximately nothing.
4. **Decrypt off the UI thread** (`compute`/isolate) once history is large enough to matter.
5. Only then consider the poll interval. It is the wrong dial to turn first.

Success is measured, not felt: time a poll with a 500-message history before and after.

---

## Phase 2 — the gaps that make it feel unfinished

- **Read receipts / delivery state.** Hard part is doing it without telling a relay who read what.
  A read marker can ride inside a sealed message to the peer; it must not become relay metadata.
- **Typing indicator.** Same constraint, and it needs a cheap channel — probably not worth a poll.
- **Reactions.** Sealed, addressed to the peer, rendered on the target message.
- **Edit / unsend.** Honest limits: a relay cannot be made to forget, and the peer already has the
  bytes. This can only ever be "ask the peer's client to hide it", and should say so plainly rather
  than implying deletion.
- **In-conversation search.** Local, over already-decrypted text — free once Phase 1 caches exist.
- **Swipe-to-reply**, and tapping a quote to jump to the original.

---

## Phase 3 — beyond text

- **Attachments beyond photos** — files, and the size/pin-cost question that comes with them.
- **Voice notes.** Recording, a sealed blob, and playback UI.
- **Forwarding**, with the quote format already in place.
- **Camera QR scan** is on the main README roadmap and overlaps here (sharing an address in a DM).

---

## Known non-goals

- **Anything that needs a relay to read a message.** Not a limitation to work around; it is the
  product.
- **Server-side search or history sync.** Same reason.
- **Group DMs** until 1:1 is solid. The key management is a different problem, not a bigger version
  of this one.

---

## Notes worth keeping

- The quote format degrades on purpose: a client that knows nothing about quoting shows a readable
  `> ` block, not markup. Real users are on older builds — the operator we tested with was two
  releases behind for most of the day.
- Parse what people actually type. Before quoting shipped, the peer wrote `>since last night | …` on
  ONE line — a quote with no body. Treating that as a reply renders an empty bubble, so all-quote
  no-body falls back to plain text.
- Notifications stayed local rather than reusing the relay notify queue, which stores `{from, to, ts}`
  in the clear. Less code the other way; it would have published the social graph.
