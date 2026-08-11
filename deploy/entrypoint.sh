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
echo "http://127.0.0.1:7401" > /tmp/xchat_bootstrap.txt   # node uses its co-located relay
python3 /app/xc_relayd.py 7401 "$STORE_DIR/relay.json" >/tmp/relay.log 2>&1 &
sleep 1
echo "starting ӾChat node on :8790 (relay :7401 store=$STORE_DIR/relay.json ipfs=$IPFS_PATH, RPC=$XC_NANO_RPC)"
exec python3 /app/kt_server.py 8790
