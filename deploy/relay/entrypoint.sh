#!/bin/bash
# An independent public ӾChat relay (second host, for SPOF-free discovery).
export BIND_HOST=0.0.0.0
export RELAY_PUBLIC_URL="${RELAY_PUBLIC_URL:-https://xchat-relay-1.fly.dev}"
mkdir -p /data
echo "starting relay on :7401  public=$RELAY_PUBLIC_URL"
exec python3 /app/xc_relayd.py 7401 /data/relay.json
