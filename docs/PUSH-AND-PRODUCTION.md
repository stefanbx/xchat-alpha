# Push delivery, and the road to production

Written 2026-08-16, after reading [NanChat](https://github.com/yxse/NanChat) — the other Nano
wallet-and-chat app — and measuring where we actually stand against it.

---

## What NanChat is, and what it is not

Real, active, good. TypeScript, Capacitor + Tauri, iOS/Android/desktop, 15 locales, last commit
2026-08-03. Worth taking seriously.

Two facts decide how we may use it:

**It is GPL-3.0. We are MIT.** Copying their code — any of it — makes ӾChat GPL-3.0 permanently. That
is not a formality; it changes what everyone downstream may do with this project. So: read it,
understand it, reimplement. Ideas are not copyrightable, expression is. **Do not paste.**

**Their server is closed.** `.env.exemple` reads `VITE_PUBLIC_BACKEND=https://api.nanchat.com`,
messages ride socket.io, and there is no server source in the repository. The clients are open; the
service is one company's. NanChat is not self-hostable.

That is the whole difference, and it cuts both ways. They can be fast because a central server can
push. We cannot be shut off because there isn't one. **The goal is their latency without their
server** — not to admire the gap and call it principled.

---

## Why ours feels like a mailbox

| | NanChat | ӾChat today |
|---|---|---|
| new message arrives | server pushes over a socket, sub-second | client polls: 5 s in a thread, 12 s for the badge |
| cost of being idle | one open socket | a request every 5–12 s, forever, per client |
| who must be up | api.nanchat.com | any one of N relays |

The polling interval IS the product. A chat where a reply might take twelve seconds to appear is not
a chat, and no amount of feature work fixes that impression.

---

## The design

The thing that makes push tractable here: **`/api/dm_send` already goes through the node.** The app
seals the ciphertext and posts it to a node, which relays it onward. So the node sees every message
in flight that is sent through it, and it knows the recipient — `to` is right there in the record.

Three paths, in the order they matter:

**1. Same-node fast path — sub-second, zero extra traffic.**
Both parties talking to the same node (which is the beta reality, and the common case for any node
with a community on it). `dm_send` wakes any live subscriber for `to` the moment it accepts the
record. No polling at all.

**2. Cross-node path — the node polls on the client's behalf.**
Different nodes, so the sender's node cannot reach the recipient's subscriber. The recipient's node
polls the relays for accounts that currently have a stream open and notifies on change. Strictly
better than today even so: ONE poller per node instead of one per client, and the client's own
polling stops.

**3. Relay push — later.**
Relays gossip to each other and hold the ciphertext; a relay could notify subscribed nodes directly
and collapse path 2 to sub-second too. It needs every relay updated, so it is stage two, not stage
one. Path 1 gets most of the benefit for a fraction of the risk.

### Transport: SSE, not WebSocket

- One direction is all we need. The client never pushes over this channel; it still POSTs to send.
- It is plain HTTP, so it survives the Cloudflare quick tunnels and workers.dev fronts our operators
  actually run. A websocket upgrade through a churning tunnel is one more thing to be silently
  broken.
- Reconnect and event IDs are in the protocol, and `EventSource` semantics are well understood.

The stream carries **a nudge, never content**: `{"ts": …}` meaning "there is something for you, go
and fetch". The ciphertext continues to travel by the existing `/api/dm_inbox` path. That keeps one
code path for decryption, keeps the store and the gossip-overlap logic exactly as they are, and means
a bug in the stream can delay a message but can never corrupt or leak one.

### What this costs in privacy, stated plainly

A held-open stream keyed by account is a **strong presence signal**: the node learns that this
account is online, continuously, for as long as the app is open. Polling already told it that every
12 seconds, so this is a change of degree rather than of kind — but it is a real change, and the
honest framing is that the node operator can see who is online. Relays still see only ciphertext.

### Battery

An idle SSE connection is cheaper than a request every 5 s, but only if it is actually idle and
actually closed when the app is not in front of the user. The client must drop the stream on pause
and reopen on resume, and reconnect with backoff rather than in a tight loop — the same discipline
the tunnel watchdog needed.

---

## Measured, after building it

| | before | after |
|---|---|---|
| DM delivery, same node | 5 s (thread) / 12 s (badge) | **928 ms**, over the internet to the live fly node |
| pollers for N clients on a node | N | 1 (only while someone has a stream open) |
| sockets held while the app is backgrounded | — | **0** — verified on the emulator: 1 established while foregrounded, 0 after HOME, 1 again on resume |

The 928 ms is the honest end-to-end number and it includes the sender's round trip, because the nudge
is sent only *after* the relay push returns. Nudging earlier would shave a few hundred milliseconds
and let the recipient fetch a message that had not been stored yet — finding nothing, and concluding
there was nothing.

24 checks in `test/dm_push_test.py`, run against a real node in isolation. Two failures during
development were worth the trouble: the keep-alive interval was hardcoded to 5 s next to a
configurable `DM_PING` that therefore did nothing, and because the ping is the only way the server
learns a client has gone, that same number silently governed how long a dead stream held a slot
against the cap.

## Order of work

1. ~~**Push delivery**~~ — done for DMs (stage 1 and 2 of the three paths below). Stage 3, relay-side
   push, is still open, as is extending the stream to feed and notification events.
2. **Group chats.** They have groups, join requests, shared accounts. We have none.
3. **Red packets.** A pot of XNO to a group, split or first-come. Nano-native, and tipping already
   exists here.
4. **i18n.** 15 locales against our zero. Table stakes for "production", and cheap if done before the
   strings multiply.
5. Typing indicators, stickers, in-chat payment requests, Ledger hardware support, Nault address-book
   import.

Still open from [SPEED-AND-GAPS.md](SPEED-AND-GAPS.md): author-written alt text, accessibility beyond
the feed surfaces, drafts and edit, and frame-jank measurement that Impeller does not hide.
