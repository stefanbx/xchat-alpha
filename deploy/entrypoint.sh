#!/bin/bash
mkdir -p /tmp
# /data is a persistent Fly volume (see fly.toml [mounts]); fall back to /tmp if it isn't mounted
# so the image still runs anywhere. BOTH durable stores go on the volume so a restart/redeploy
# KEEPS the history instead of wiping it:
#   - the relay's whole state (heads, engagement, follows, comments, DMs, blobs, releases) in one file
#   - the IPFS repo (the content-addressed post/thread/media bytes a head points at) — without this,
#     a head survives but its content is gone and the post renders blank.
STORE_DIR=/data; [ -d /data ] && [ -w /data ] || STORE_DIR=/tmp
mkdir -p "$STORE_DIR"
export IPFS_PATH="$STORE_DIR/ipfs"
mkdir -p "$IPFS_PATH"
rm -f "$IPFS_PATH/repo.lock"        # a hard restart can leave a stale lock that blocks the daemon
ipfs init >/dev/null 2>&1 || true
ipfs config --json Addresses.Gateway '"/ip4/127.0.0.1/tcp/8081"' >/dev/null 2>&1 || true
ipfs daemon --offline >/tmp/ipfs.log 2>&1 &
sleep 5

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
echo "starting ӾChat node on :8790 (relay :7401 public=$NODE_PUBLIC_URL peer=$PEER_RELAY store=$STORE_DIR/relay.json ipfs=$IPFS_PATH, RPC=$XC_NANO_RPC)"
exec python3 /app/kt_server.py 8790
