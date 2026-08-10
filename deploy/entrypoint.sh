#!/bin/bash
export IPFS_PATH=/tmp/ipfsB
mkdir -p /tmp
ipfs init >/dev/null 2>&1 || true
ipfs config --json Addresses.Gateway '"/ip4/127.0.0.1/tcp/8081"' >/dev/null 2>&1 || true
ipfs daemon --offline >/tmp/ipfs.log 2>&1 &
sleep 5
echo "http://127.0.0.1:7401" > /tmp/xchat_bootstrap.txt   # node uses its co-located relay
python3 /app/xc_relayd.py 7401 /tmp/relay.json >/tmp/relay.log 2>&1 &
sleep 1
echo "starting ӾChat node on :8790 (relay :7401, ipfs offline, RPC=$XC_NANO_RPC)"
exec python3 /app/kt_server.py 8790
