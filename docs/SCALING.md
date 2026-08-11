# ӾChat — relay persistence & scaling

How relay state survives restarts today, how many users one relay can serve, and the path to
high traffic. Written against the alpha node (`backend/`, `relay/xc_relayd.py`, `deploy/`).

## 1. Persistence across restarts — DONE

A relay keeps its whole state in memory and flushes it to a single store file. The problem on a
hosted node was **where** that file lived: `/tmp` is ephemeral on Fly, so every restart or redeploy
wiped the history (posts, media, likes, follows, comments, DMs, poll votes).

Fixed by moving the durable state onto a **persistent Fly volume**:

- `fly.toml` mounts a volume `xchat_data` at `/data`.
- `deploy/entrypoint.sh` puts **both** durable stores on it: the relay state file
  (`/data/relay.json`) **and** the IPFS repo (`IPFS_PATH=/data/ipfs`) — the content-addressed
  bytes a head points at. Without the IPFS repo on the volume, a head survives but its *content*
  is gone and the post renders blank. (A latent bug also surfaced here: several helpers hardcoded
  `IPFS_PATH=/tmp/ipfsB` for `ipfs cat` while `ipfs add` used the configured path — they now all use
  `xc.IPFS_PATH`.)
- Falls back to `/tmp` automatically when no volume is mounted, so the image still runs anywhere.

Verified: post from the app → `fly machine restart` → the post (head **and** content) is still there.

**Caveat — one volume ↔ one machine.** A Fly volume attaches to a single machine, and a second
machine gets its *own* volume with *separate* state. That is fine, even correct, for this design
(relays are meant to be plural and independent — see §3), but it means you don't scale a single
relay by adding machines behind it; you add *more relays*.

## 2. How many users can one relay serve?

Honest estimate for the current alpha relay: **512 MB RAM, 1 shared vCPU, Python
`ThreadingHTTPServer`, whole-state-as-one-JSON-file rewritten every 5 s.**

Bottlenecks, in the order they bite:

1. **The 5 s full-state rewrite (`save()` in `xc_relayd.py`).** It serializes and writes the
   *entire* state every 5 seconds — O(total bytes), and it holds the GIL while encoding, stalling
   every request thread for its duration. Fine at a few MB; painful in the tens of MB; fatal in the
   hundreds.
2. **Everything in RAM (512 MB).** Text state is tiny; **media is the hog** — the relay also caches
   blobs (base64) and, today, those ride *inside* `relay.json`.
3. **`http.server` + GIL.** Simple reads top out around a few hundred req/s on a shared vCPU.

Concrete:

| Workload | Rough ceiling on this one relay |
|---|---|
| **Text only** (posts, follows, likes, comments — media served elsewhere) | **~1,000–10,000 active users.** 10 k users of heads + engagement ≈ 10–50 MB of state; the 5 s dump stays sub-second; reads ~100–300 req/s. |
| **With media in the relay blob cache** | **Falls over fast** — a few hundred media posts (MBs each) blow past 512 MB RAM and make the 5 s dump take *seconds*. |

So as-is this is a **low-thousands-of-users alpha relay for text**, and much less if media rides in
it. It is not yet a high-traffic production relay — but the fixes below are incremental, not a
rewrite.

## 3. The scaling path

The architecture is **already horizontally scalable**: clients read from *plural* relays and verify
every signature themselves, so relays are untrusted and interchangeable. "High traffic" is therefore
two separate jobs — make each relay efficient, and run more relays.

**Per-relay efficiency (do these in order):**

1. **Get media out of `relay.json`.** Media should live only as content-addressed files (the IPFS
   repo on the volume already does exactly this). Drop the base64 blob cache from the JSON store, or
   spill it to `/data/blobs/<cid>` files. This removes bottleneck #1's worst case and most of #2.
2. **Replace the whole-file rewrite with an embedded database — SQLite.** This is the "database"
   high traffic needs. One table per record type (heads, engagement, follows, comments, dms,
   pollvotes, releases), keyed by id; **incremental** writes instead of O(total) every 5 s; WAL mode
   for concurrent reads. SQLite comfortably handles millions of rows and needs no server. Good for a
   single relay into the **~100 k–1 M user** range. (Postgres only when one box genuinely isn't
   enough.)
3. **Front it with a real server.** Swap Python `http.server` for gunicorn/uvicorn (or move the hot
   read paths — `/heads`, `/feed` — behind a small cache). Removes bottleneck #3.

**Fleet scale (the real answer to high traffic):**

4. **Run more relays.** They self-announce on the XNO ledger and are found via keyless rendezvous
   (already built); clients already aggregate across them. Each big relay gets SQLite/Postgres +
   files-or-object-store for media, with a CDN in front of media reads.
5. **Bigger machines / volumes** as needed (Fly volumes resize online; RAM/CPU scale per machine).

No fundamental redesign is required — the identity, content-addressing, and multi-relay verification
are already the hard parts, and they're done. Scaling is (2)+(1) per relay and (4) across relays.

## 4. Status

- [x] Persistent volume; relay state + IPFS repo survive restart/redeploy (verified).
- [x] `ipfs cat`/`add` use one consistent `IPFS_PATH`.
- [ ] Media out of the JSON store → content-addressed files only.
- [ ] SQLite store (incremental writes) replacing the 5 s whole-file rewrite.
- [ ] Production WSGI/ASGI server in front of `xc_relayd`.
- [ ] Documented multi-relay operator guide + media CDN.
