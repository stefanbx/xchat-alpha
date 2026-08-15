#!/bin/bash
mkdir -p /tmp
# /data is a persistent Fly volume (see fly.toml [mounts]); fall back to /tmp if it isn't mounted
# so the image still runs anywhere. BOTH durable stores go on the volume so a restart/redeploy
# KEEPS the history instead of wiping it:
#   - the relay's whole state (heads, engagement, follows, comments, DMs, blobs, releases) in one file
#   - the IPFS repo (the content-addressed post/thread/media bytes a head points at) — without this,
#     a head survives but its content is gone and the post renders blank.
STORE_DIR=/data
if [ -d /data ] && [ -w /data ]; then
    :
else
    # Falling back is right — the image must still run without a volume — but it must NOT be quiet.
    # Both durable stores land in /tmp, so every restart silently discards the whole history: heads,
    # follows, comments, DMs, blobs, releases. That is indistinguishable from "the node lost my posts",
    # and the only prior signal was one word inside the startup line.
    STORE_DIR=/tmp
    echo "WARNING: /data is not a writable mount — falling back to $STORE_DIR"
    echo "WARNING: relay state AND the IPFS repo are now EPHEMERAL; every restart loses all history"
    echo "WARNING: check the [mounts] volume in fly.toml, and whether the volume is full"
fi
mkdir -p "$STORE_DIR"
export IPFS_PATH="$STORE_DIR/ipfs"
mkdir -p "$IPFS_PATH"
rm -f "$IPFS_PATH/repo.lock"        # a hard restart can leave a stale lock that blocks the daemon
# `ipfs init || true` on its own hides the one failure that matters. A repo can exist and still be
# unusable — blocks present, config or blocks/SHARDING missing — and init REFUSES that rather than
# repairing it. The container then starts, serves reads, and fails every post with no signal at all.
# Init only when there is no working repo, then say plainly whether there is one.
ipfs repo stat >/dev/null 2>&1 || ipfs init >/dev/null 2>&1 || true
if ! ipfs repo stat >/dev/null 2>&1; then
    echo "WARNING: no usable IPFS repo at $IPFS_PATH — posting will fail (reads still work)"
    echo "WARNING: if the directory is non-empty but has no config, it is half-built; inspect it"
fi
ipfs config --json Addresses.Gateway '"/ip4/127.0.0.1/tcp/8081"' >/dev/null 2>&1 || true
# --migrate: this repo is fs-repo@15 and kubo v0.43 wants @18. Without the flag kubo asks at a
# prompt, and there is no TTY here — the daemon would abort and every post would fail with the
# only clue buried in /tmp/ipfs.log. Migrations are forward-only and kubo carries them in-binary.
ipfs daemon --offline --migrate >/tmp/ipfs.log 2>&1 &
sleep 5
# Nothing checked that the daemon actually came up; `sleep 5` then exec'ing the node meant a dead
# daemon looked exactly like a healthy start. pgrep is absent in this image, so ask ipfs itself.
if ipfs id >/dev/null 2>&1; then
    echo "ipfs ready at $IPFS_PATH ($(ipfs repo stat 2>/dev/null | awk '/NumObjects/{print $2}') objects)"
else
    echo "WARNING: the IPFS daemon did not come up — posting will fail. Last lines of /tmp/ipfs.log:"
    tail -5 /tmp/ipfs.log 2>/dev/null | sed 's/^/  ipfs: /'
fi

# --- relay mesh wiring (no single point of discovery) ---
# The node's public url IS its relay (kt_server proxies every non-/api path to :7401), so the embedded
# relay advertises that url and PEERS with the independent public relay both ways:
#   - the embedded relay bootstraps to PEER_RELAY (announces itself + pulls its /relays)
#   - the node's own aggregation (xc_feed/xc_post) gets PEER_RELAY straight from XCHAT_BOOTSTRAP, so a
#     momentary on-chain relay-scan miss can't strand the feed on the loopback relay alone.
NODE_PUBLIC_URL="${NODE_PUBLIC_URL:-https://xchat-alpha-node.fly.dev}"
PEER_RELAY="${PEER_RELAY:-https://xchat-relay-1.fly.dev}"
export RELAY_PUBLIC_URL="$NODE_PUBLIC_URL"     # the embedded relay's reachable identity (proxied to :7401)
# Payout account for the embedded relay. XC_DEV=1 preserves the historical DEMO account (key derivable
# from the repo by anyone — not a wallet). Set RELAY_ACCT=nano_... and drop this to be paid for real.
export XC_DEV=1
export XCHAT_BOOTSTRAP="$PEER_RELAY"           # xc_common._bootstrap() always includes the peer relay
echo "http://127.0.0.1:7401" > /tmp/xchat_bootstrap.txt   # node still talks to its co-located relay on loopback
python3 /app/xc_relayd.py 7401 "$STORE_DIR/relay.json" "$PEER_RELAY" >/tmp/relay.log 2>&1 &
sleep 1
# Self-announce this node's /api URL on the XNO ledger (idempotent) so the app can rediscover it from
# an unstoppable source if this host's DNS is ever lost. Needs a one-time-funded operator key in
# XC_RELAY_OPERATOR_SEED (a fly secret); it no-ops when the URL is already announced, and skips cleanly
# when no key is set. Backgrounded + non-fatal so it never delays or blocks serving.
( sleep 25; python3 /app/xc_reldir.py ensure "$NODE_PUBLIC_URL" 2>&1 | sed 's/^/[self-announce] /' || true ) &

echo "starting ӾChat node on :8790 (relay :7401 public=$NODE_PUBLIC_URL peer=$PEER_RELAY store=$STORE_DIR/relay.json ipfs=$IPFS_PATH, RPC=$XC_NANO_RPC)"
exec python3 /app/kt_server.py 8790
