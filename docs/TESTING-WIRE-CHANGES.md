# Testing a wire change before it hits the network

A wire change is any change to a record shape, a signing preimage, or a protocol the two
independent implementations (the Dart app and the Python node/relay) must agree on. Sealed sender is
the one driving this document.

These are the highest-risk changes we make, for a reason the 2.5.0 DM regression made concrete: a
green test suite that only runs new-code-against-new-code is blind to the two things that actually
break a live network.

## The two failure modes

1. **Version skew.** A 2.5.1 phone and a new phone coexist for weeks. The failure is not "slow" — it
   is "an old install can no longer read a message a new install sent", and once the record is on the
   relays a server redeploy cannot undo it.
2. **Adverse conditions.** Slow and dead relays, gossip races, concurrent load. This is what hid the
   DM-lag bug; `test/dm_push_test.py` now brings its own slow relays, and any new fan-out or
   under-lock code should too.

## The method

**A. Make the change safe by construction, not only tested.** Additive and capability-gated, the way
`XC_DM_STRICT` gated the mailbox-read signature. A client advertises support (e.g. in its signed
`dmkey` record); a sender uses the new format ONLY for recipients who advertise it, old format
otherwise. Old installs then never receive a record they cannot read, and the test only has to prove
the negotiation — not a flag day.

**B. Run the released code against the working tree.** `test/wire_skew_test.py` checks the released
relay out into a git worktree and boots it alongside the working-tree relay, then asserts the two
agree on the wire.

```
python3 test/wire_skew_test.py                         # baseline = HEAD (proves the harness)
XC_BASELINE_REF=<release-commit> python3 test/wire_skew_test.py   # real old-vs-new
```

With no ref set, old == new, so the run proves the harness. Once sealed sender is in the working
tree, set `XC_BASELINE_REF` to the last release and the same assertions become the compatibility
contract between the two formats. The harness has been run against the real 2.4.3 relay (`ac82f8a`)
next to HEAD; both boot and pass, which is how we know the forward-compat property below reaches the
oldest relay likely still in the field.

## What the testbed already established about sealed sender

Found by reading the relay before writing any wire code, and pinned as tests so a change must
reckon with them:

1. **A deployed relay stores a record it does not understand intact** — unknown fields survive. So a
   2.5.1 (and 2.4.3) relay will hold a sealed-sender record without mangling it. Sealed sender does
   not require every relay to update before any client can send.
2. **The relay dedups DMs on `(from, ts)`.** Hide `from` and every sealed record dedups as
   `(None, ts)`; two senders in the same second lose a message. **Sealed sender must carry its own
   message id.**
3. **The mailbox filter is `to == acc OR from == acc`.** The `from == acc` half is how a sender reads
   their OWN sent messages. Hide `from` and the author loses their history unless sealed sender adds a
   sender-side copy.

Conclusion the harness makes unavoidable: **sealed sender is not a pure client change.** Relays must
update to dedup on a message id and to deliver the sender their own copy — and, per (A), the rollout
must be capability-gated so old installs never see the new format.

## What is still not covered

The Dart *client's* handling of an unknown record shape. The relay testbed proves the network carries
the record; it does not prove an old client degrades gracefully when handed one. Because of (A) an
old client should never be handed one — but "should never" is a claim that itself wants a test, at
the Dart level, when sealed sender lands.
