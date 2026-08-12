#!/bin/bash
# An independent public ӾChat relay (second host, for SPOF-free discovery).
export BIND_HOST=0.0.0.0
export RELAY_PUBLIC_URL="${RELAY_PUBLIC_URL:-https://xchat-relay-1.fly.dev}"
# Bootstrap TO the node so the two relays peer both ways: announce ourselves to it and pull its /relays.
# The node's public url is a full relay (kt_server proxies every non-/api path to its loopback relay).
NODE_URL="${NODE_URL:-https://xchat-alpha-node.fly.dev}"
mkdir -p /data
echo "starting relay on :7401  public=$RELAY_PUBLIC_URL  bootstrap=$NODE_URL"
exec python3 /app/xc_relayd.py 7401 /data/relay.json "$NODE_URL"
