# What we actually leak, and how central we actually are

Audited 2026-08-16 against the running network, not against the README. Everything below was checked
by querying the live relays and reading the storage code, and the numbers are what came back.

The app's headline claim is "relays hold only ciphertext". That is true about message **bodies** and
false about almost everything else, and the difference is where the real work is.

---

## The hole that matters most

```
$ curl 'https://xchat-alpha-node.fly.dev/dm?account=nano_3sec7i8…kk481'
records: 54
{ "to":   "nano_3694nraghrec…ubij",
  "from": "nano_3sec7i8wjr68…kk481",
  "from_pk": "331999de…", "to_pk": "ffd141e2…",
  "ct": "N8/bBPZ6nKytpVlLx6d3K6o0…", "ts": 1786905610 }
```

No key, no signature, no session. **Anybody can enumerate anybody's entire DM metadata** from any
relay: who you talk to, when, how often, in which direction, and how long each message was. The
bodies are sealed. The social graph is a public API.

This is not "the relay operator can see it" — that would already be bad. It is served to strangers.

For most people the graph is more revealing than the text. Knowing that two accounts exchanged
forty messages at 3am is usually worth more than knowing what they said, and it is exactly what
metadata analysis is for.

### Ranked

1. **`/dm?account=` is unauthenticated.** Anyone can pull anyone's graph. Fixable without a wire
   change: make reading a mailbox require a signature from the account that owns it. Costs nothing,
   closes the public part of the hole immediately. **← doing this first**
2. **`from` / `to` are stored in the clear.** Closing 1 leaves the relay operator with the same
   view. The fix is *sealed sender*: the record carries an ephemeral public key and ciphertext, and
   the true sender's identity moves INSIDE the sealed payload. Double-sealed — an outer box under a
   throwaway key so the relay learns nothing, an inner box under the real identity so the recipient
   still knows who wrote it, using crypto we already have. Wire change, so it needs a version.
3. **The node sees every DM in flight.** `/api/dm_send` passes through it with `to` and `from`
   readable, and push made this sharper: a held-open stream keyed by account is a continuous
   presence signal. Noted when it was built; it is the price of same-node delivery and worth
   re-examining once 2 lands.
4. **Identity is money.** Posting, tipping and holding a balance are all the same Nano account, so
   anyone can read the balance and full transaction history of any poster. `channelWallet` already
   derives a separate signing identity from the seed — the same trick would give a social identity
   that is not the wallet.
5. **IP.** Clients talk to a node and to relays directly, with no mixing. The node sees an IP beside
   an account. Link previews already avoid this for third-party sites by having the node fetch;
   nothing does for the node itself.

---

## How decentralised is it, honestly

| | |
|---|---|
| relays announced on chain | 4 |
| ...that are not the author's | **1** (Jiován's, currently down) |
| default endpoint in a fresh install | one host, `xchat-alpha-node.fly.dev` |
| discovery if that host dies | on-chain rendezvous scan → other relays |

The **discovery** is genuinely decentralised: relays announce on the Nano ledger, clients scan for
them, no registry. That part works and is the good bones of this project.

The **deployment** is not. Three of four relays are one person's, the default endpoint is one host,
and the node is a privileged middle layer that every client leans on. If the fly machine went away
today most clients would heal from the ledger onto relays that are also mine.

That is an operator problem more than a code problem — it wants people, not commits — but two code
items help:

- the client should be able to talk to relays **directly** when no node is reachable, rather than
  treating a node as required
- the health probing that landed today should feed endpoint selection, so a client drifts onto
  whatever is actually up instead of retrying a dead default

---

## Not doing

**Red packets, stickers, typing indicators** — parked deliberately. They are the fun half of the
NanChat list and none of them move the two things above. Revisit once a stranger's relay can hold a
conversation without learning who is in it.
