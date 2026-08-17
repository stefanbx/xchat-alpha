# Anonymity: what an ӾChat account actually reveals

A companion to [PRIVACY-AND-DECENTRALIZATION.md](PRIVACY-AND-DECENTRALIZATION.md). That one is about
what the network can see. This one is about the harder question: **can a specific account be tied to a
specific person**, and what would it take to keep it from being.

Written 2026-08-16. Since then several items have shipped: the funding warning (§1), sealed sender
(§3), and the blind mailbox read that closes the read half of the IP↔account link (§4). Each is marked
where it stands below.

---

## The thing to say first

**The strongest link between an ӾChat account and a real person is not in this app. It is on the Nano
ledger.**

Identity here is a Nano account. That same account signs your posts, receives your tips and holds
your balance — and the ledger is public, permanent, and trivially indexable. So:

- anyone can read the full balance and transaction history of any poster, forever
- if the account was ever funded from a KYC exchange, an exchange withdrawal ties it to a legal name
- if it ever sent to or received from another account of yours, both are now one cluster

No change to this codebase fixes that retroactively. A ledger does not forget. **Any honest
anonymity story starts by saying so**, because a user who believes the app makes them anonymous will
make exactly the funding mistake that undoes it.

The realistic goal is not Tor-grade anonymity. It is **pseudonymity that does not collapse**: an
account that is not trivially linkable to your legal identity, to your other accounts, or to your
social graph.

---

## Threat model, so the rest means something

| adversary | sees today | after the work below |
|---|---|---|
| a curious stranger | *(was: everyone's whole DM graph)* — closed, mailbox reads now need a signature | nothing |
| a relay operator | who talks to whom, when, how often, message sizes | that ciphertext arrived for someone |
| the node your client uses | all of the above, plus your IP, plus continuous presence | IP and presence only |
| a passive network observer | that you use ӾChat, and traffic timing | same |
| anyone at all, via the ledger | balances, tips, funding sources, account clusters | **unchanged — this is the hard one** |

---

## Ranked, hardest problem first

### 1. Identity is money
Posting, tipping and holding a balance are one account. Two directions, and both are worth doing:

- **Separate the social identity from the wallet.** `channelWallet` already derives an independent
  signing identity from the seed (`blake2b(seed || "xchat-channel:" + name)`). The same trick gives a
  *posting* identity whose account has never touched the ledger and whose balance is nothing to read.
  Tips would go to a wallet account the post does not name, which costs the "tip this post" link —
  paying for it with a payment-request indirection is a design question, not a coding one.
- **Say the funding thing out loud, in the app.** A one-time note at wallet creation that funding
  from an exchange links this identity to that exchange's records. Cheap, and it is the single
  highest-value anonymity feature we could ship, because it prevents the mistake rather than
  mitigating it.

### 2. No forward secrecy
DM keys are X25519, derived deterministically from the seed and **never rotated**. So the seed
decrypts every message ever sent to that account — including ciphertext a relay has been holding for
a year. One compromised phone retroactively opens all history that anyone kept.

Signal solves this by ratcheting. A cheaper first step here is **key epochs**: publish a new DM key
periodically, keep the old private keys only as long as the client needs to read its own backlog, and
let old ones become unrecoverable. Less strong than a real ratchet, far simpler, and it turns "all
history forever" into "one window".

### 3. Sealed sender
Covered in the other document; it belongs here too. It is what moves the relay operator's row in the
table above from "who talks to whom" to "ciphertext arrived".

### 4. IP and presence
The node sees an IP beside an account, and push made this continuous rather than periodic — a
held-open stream is a live "this person is awake" beacon. `/api/presence` publishes online status by
design as well.

**Mailbox reads are now blind (implemented).** The sharpest edge here was the signed mailbox read:
`/api/dm_inbox?account=…` names the account it reads, so the node saw `(IP, account)` on every 5s
poll — and that binding was exactly what let an operator re-attach a hidden sender to a sealed message
(sealed sender hides `from`, but if the same IP is known to be account A from its own reads, a sealed
send from that IP is A's). That binding is closed with a one-hop onion. The client seals its read
request — the account plus the ownership proof — to a chosen relay's X25519 read key and hands the
node an opaque blob to forward. The node sees the IP but not the account; the relay sees the account
but only the node's IP. No single operator holds the pair, as long as the client's node and the relay
it seals to are run by different people. The relay's read key is signed by its ledger identity and the
client verifies it against the account it discovered for that relay **off the ledger**, so a
man-in-the-middle node cannot substitute its own key to unwrap the account. Capability-gated (relays
advertise `caps:r1`; clients fall back to the ordinary signed read), so no flag day. Proven end to end
in `test/blind_read_e2e_test.py`; crypto in `app/test/blind_read_test.dart`.

**Still open.** This closes the *read* side only. Sending a DM and fetching a peer's key still reach
the node from the client's IP (items 4-presence and 5-first-contact), and `/api/presence` still
publishes online status. The tractable next steps: make presence **opt-in** rather than automatic, and
let the push stream be declined in favour of polling. Removing IP entirely from every path is a
transport problem (Tor / a mix), which stays a large commitment — the blind read is the structural win
that does not need it.

### 5. First contact leaks intent
To DM someone the client fetches their published DM key from a relay. The relay therefore learns you
are interested in that person *before you have said anything* — and if you never send the message, it
still knows you looked. Fetching a batch of keys, or fetching them through the node without naming
which one you want, both help.

### 6. Traffic analysis
No padding, no cover traffic. Message sizes and timing are visible and correlate well. Padding
ciphertext to size buckets is cheap and worth doing when sealed sender lands, since both touch the
same record.

---

## Order

1. **The funding warning in the app.** Smallest change here, largest real-world effect, and it is the
   only item that prevents a mistake instead of mitigating one.
2. **Sealed sender** — the biggest structural win, already designed in the other document.
3. **Separate posting identity from wallet identity.**
4. **Key epochs** for a bounded compromise window.
5. Presence opt-in; padding; first-contact batching.

## What we will not claim

Until at least 1–3 are done, the app should not describe itself as anonymous. It is
**pseudonymous, with an audit trail on a public ledger**. Saying more than that is the kind of claim
that gets someone hurt, and it costs nothing to be accurate.
