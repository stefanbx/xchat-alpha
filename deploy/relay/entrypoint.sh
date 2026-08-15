#!/bin/bash
# An independent public ӾChat relay (second host, for SPOF-free discovery).
export BIND_HOST=0.0.0.0
# The relay's payout account (pay-to-pin + the 10% media tip split). XC_DEV=1 keeps the historical
# behaviour — a DEMO account derived from a fixed byte, whose key anyone can derive from the repo, so
# treat anything it receives as unowned. Replace both lines with your own address to actually be paid:
#   export RELAY_ACCT=nano_...
export XC_DEV=1
export RELAY_PUBLIC_URL="${RELAY_PUBLIC_URL:-https://xchat-relay-1.fly.dev}"
# Bootstrap TO the node so the two relays peer both ways: announce ourselves to it and pull its /relays.
# The node's public url is a full relay (kt_server proxies every non-/api path to its loopback relay).
NODE_URL="${NODE_URL:-https://xchat-alpha-node.fly.dev}"
mkdir -p /data
echo "starting relay on :7401  public=$RELAY_PUBLIC_URL  bootstrap=$NODE_URL"
exec python3 /app/xc_relayd.py 7401 /data/relay.json "$NODE_URL"
