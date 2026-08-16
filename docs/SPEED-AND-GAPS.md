# Speed, and the gaps to X

Measured 2026-08-16 on the emulator and the live fly node. Numbers first, because the obvious
suspicions were wrong: startup is already fast, and the feed is already cached.

---

## Baseline

| what | measured | verdict |
|---|---|---|
| cold start → first frame | 398–424 ms | fine |
| launch → posts on screen | **0.2 s** | fine — painted from the local feed cache |
| `/api/feed` warm | 0.21 s | fine |
| `/api/feed` cold / TTL expired | **3.2–7.7 s** | the worst number here |
| `/api/status`, `/api/relaydir` | 0.19 s, 0.27 s | fine |
| DM poll, warm | ~0 ms | fixed in Phase 1 (was 437 ms per poll) |
| frame jank during scroll | **unmeasured** | `dumpsys gfxinfo` reports 0 frames for Flutter/Impeller |

So "the app feels slow" is not about startup. It is about how long NEW content takes to appear, and
what the node burns to produce it.

---

## Speed work, in order

1. **Feed pagination.** `grep` finds no `loadMore`/`hasMore`/pagination anywhere: the feed builds
   every post it has, and `/api/feed` returns all of them. At 33 posts that is invisible; the store
   already tolerates thousands, and every one of them becomes a widget. This is the only item here
   that gets WORSE with success, so it goes first.

2. **`FEED_TTL` is 5 seconds.** The node re-runs a relay fan-out aggregation that often, and a caller
   arriving on a cold cache blocks 3–8 s. Serving stale-while-revalidate is already implemented for
   the warm path; the cold path is the one that hurts, and 5 s is far shorter than the 12 s client
   poll that consumes it. Raising the TTL to match the poll removes most of the work for free.

3. **Time to new content is up to 12 s** (the client poll). Worth revisiting only AFTER 1 and 2 —
   polling faster against an expensive aggregation is the wrong order.

4. **Measure frame jank properly.** `gfxinfo` is blind to Impeller. Needs `--trace-skia` or a
   `SchedulerBinding` frame-timing callback. Until then, any claim about scroll smoothness is a
   guess, and this document should not pretend otherwise.

---

## Gaps to X

Checked by inspection rather than memory. Present already: polls, bookmarks, repost/quote, mute,
block, video, pull-to-refresh, translate, views, follows, profiles, long-form channels, and DMs that
are now ahead of X's in some respects (E2E, reactions, receipts, search).

Missing, in the order they are worth having:

1. **@mentions** — no autocomplete, and a mention is not a link. This is how conversation works on X;
   without it there is no way to pull someone into a thread.
2. **Hashtags** — not parsed, not tappable, not searchable. The other half of discovery.
3. **Link previews** — a URL is bare text. Cheap to add, and it is most of what a timeline looks like.
   *(Turned out not to be cheap: linkifying is, but a preview means somebody fetches a stranger's URL,
   and choosing WHO is the whole design. See the note in `backend/xc_unfurl.py`.)*
4. **Accessibility** — zero `Semantics()` in the app, and no image alt text. This is a correctness
   gap, not a feature gap: a screen reader currently gets very little.
5. **Drafts and edit** — neither exists. Edit is genuinely hard here (a post is a signed head; an
   edit means republishing and saying so honestly), which is exactly why it needs designing rather
   than assuming.

---

## Progress

Done, each verified before the next was started.

| # | item | what actually changed | evidence |
|---|---|---|---|
| S1 | feed pagination | `?limit=`/`?before=`/`more`; client pages at 40 | walked every page: 33 posts, 33 unique, no overlap, each page strictly older |
| S2 | `FEED_TTL` 5 → 12 | aligned to the 12 s client poll | 5 → 2 aggregations in the same 26 s window |
| G1+2 | @mentions, #hashtags | linked and tappable; mention → profile (search fallback), tag → Discover | on device: `@jiovan` and `#nano` linked, `bob@example.com` and `C#` plain; tapping `#nano` found 1 post |
| G3a | links in a body | `body.dart`, one scanner, imported by the tests; tap → system browser | 29 tests; on device the fragment stayed inside the URL, both trailing marks outside, ACTION_VIEW dispatched |
| G3b | link preview cards | node-side unfurl + SSRF guards, card under the post | 54 checks; live: 0.58 s cold / 0.22 s cached, and metadata/localhost/file: all refused on the real host |

**S2 is an operator-cost fix, not a user-latency one.** Nothing got faster on the phone; the node
stopped re-running an aggregation nobody consumed, ~1 s of CPU a time. That matters because operators
run this on laptops — but it is not the thing that makes the app feel quick, and the table should not
be read as if it were.

Two things the preview work deliberately did NOT do, both worth their own entry rather than a
footnote:

- **No preview image.** An `og:image` is a URL on the linked site, so painting it puts every reader's
  IP in that site's logs — the exact leak the node-side fetch exists to prevent. The image has to be
  proxied and size-capped through the node first.
- **The node learns which links a reader loads.** Small next to what it already knows (it served the
  feed those links came from), but not nothing. Serving previews as part of the feed aggregation
  would remove even that.

## Method

Implement one item at a time and VERIFY it before moving on — the pattern that caught the read-receipt
resend, the stale-artifact install, and the ciphertext-keyed cache leak today. A measurement before
and after for anything claiming to be faster; a real device interaction for anything claiming to work.
