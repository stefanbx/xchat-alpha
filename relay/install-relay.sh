#!/bin/sh
# ӾChat relay — one-command installer for people who don't live in a terminal.
#
#   curl -fsSL https://xchat-alpha-node.fly.dev/relay.sh | sh
#
# What it does, in order:
#   1. puts everything under ~/.xchat-relay (nothing else on the machine is touched)
#   2. downloads the relay (two pure-Python files) from the repo
#   3. makes a venv and installs nanopy — without it the relay can't verify signed profiles,
#      reports or pin payments, and it can't hold an account to be paid on
#   4. downloads cloudflared and opens a free quick tunnel, so a laptop behind NAT still gets a
#      real https:// URL other nodes can reach — no router config, no account, no port forward
#   5. registers it to start at login (launchd on macOS, systemd --user on Linux) and starts it
#
# The relay itself binds to 127.0.0.1 only; the tunnel is the sole way in. It stores signed bytes
# other people published — it holds no seed and cannot post or spend as anyone.
#
# A quick tunnel's hostname changes on every restart. That costs the network nothing: the relay
# generates its own keypair and signs "I am at this url now", so peers follow the same relay to its
# new address instead of collecting dead ones.
#
# It does cost you ONE thing: a hostname that changes can't be published on the XNO ledger, so people
# who don't already have your URL can't find you. Announcing needs an address that is both permanent
# and short (the on-chain link holds 32 bytes). Pick whichever suits you:
#
#   --setup-worker                           free Cloudflare workers.dev name, set up for you in one
#                                            command — the node keeps its quick tunnel and the worker
#                                            forwards to it, so the published address never changes
#   --domain relay.example.com               you already route that name to this machine
#   --domain relay.example.com --tunnel-token <token>   Cloudflare named tunnel (token from their
#                                            dashboard: Networks -> Tunnels -> your tunnel)
#
#   sh install-relay.sh --status      what's running, the public URL, and whether you're announced
#   sh install-relay.sh --uninstall   stop it and delete ~/.xchat-relay
set -eu

XC_HOME="${XC_RELAY_HOME:-$HOME/.xchat-relay}"
PORT="${XC_RELAY_PORT:-7401}"
# The settings page. A SEPARATE port from the relay on purpose: the tunnel publishes the relay's port
# to the whole internet, so anything sharing it would be a public, unauthenticated control panel.
ADMIN_PORT="${XC_ADMIN_PORT:-7402}"
# The work server. Not 7500 by default: that port is a common spot for other Nano work daemons, and
# picking up somebody else's DEV-difficulty server would produce instant work that mainnet rejects.
WORKD_PORT="${XC_WORKD_PORT:-7503}"
# The NODE is optional (--with-node). A relay stores and serves other people's signed bytes; a node is
# the API your own app talks to — it reads the ledger, aggregates the feed across relays, and adds the
# proof-of-work that a tip waits on. Running one locally is what makes YOUR tips fast, because the work
# is then done by this machine instead of a public RPC that is frequently down.
NODE_PORT="${XC_NODE_PORT:-8790}"
WITH_NODE="${XC_WITH_NODE:-0}"
# Name of the Cloudflare Worker that fronts this node (see --setup-worker). SHORT on purpose: the
# on-chain link holds 32 bytes of hostname, and the final host is <name>.<account>.workers.dev — so
# every character here is one fewer available to the account subdomain, which the operator can't change.
WORKER_NAME="${XC_WORKER_NAME:-xc}"
# Files the node is made of. Keep in step with backend/*.py — a missing optional helper disables one
# feature, but kt_server.py and xc_common.py are load-bearing and the install aborts without them.
NODE_FILES="kt_server.py xc_announce.py xc_attest.py xc_blobput.py xc_blockproc.py xc_comments.py
xc_common.py xc_dm.py xc_engage.py xc_feed.py xc_follows.py xc_gossip.py xc_heads_seed.py xc_labels.py
xc_media.py xc_notify.py xc_pin.py xc_poll.py xc_post.py xc_profile.py xc_reldir.py xc_release.py
xc_report.py xc_supporter.py xc_workd.py"
SRC="${XC_SRC:-https://raw.githubusercontent.com/stefanbx/xchat-alpha/master}"
# `-` not `:-`: XC_BOOTSTRAP='' explicitly means "peer with nobody" (isolated/test installs), which
# matters because a relay announces itself to its bootstraps the moment it starts.
BOOTSTRAP="${XC_BOOTSTRAP-https://xchat-alpha-node.fly.dev https://xchat-relay-1.fly.dev}"
LABEL=chat.xno.xchat.relay
# Piped through `sh`, $0 is just "sh" — so keep a copy on disk and point the operator at that.
SELF="$XC_HOME/install-relay.sh"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
UNIT="$HOME/.config/systemd/user/xchat-relay.service"
OS=$(uname -s)

c_ok=''; c_warn=''; c_dim=''; c_b=''; c_0=''
if [ -t 1 ]; then c_ok=$(printf '\033[32m'); c_warn=$(printf '\033[33m'); c_dim=$(printf '\033[90m')
                 c_b=$(printf '\033[1m'); c_0=$(printf '\033[0m'); fi
say()  { printf '%s\n' "$*"; }
step() { printf '%s→%s %s\n' "$c_b" "$c_0" "$*"; }
ok()   { printf '%s✓%s %s\n' "$c_ok" "$c_0" "$*"; }
warn() { printf '%s!%s %s\n' "$c_warn" "$c_0" "$*"; }
die()  { printf '\n%s✗ %s%s\n' "$c_warn" "$*" "$c_0" >&2; exit 1; }

fetch() {  # fetch <url> <dest>
    if command -v curl >/dev/null 2>&1; then curl -fsSL --retry 3 -o "$2" "$1"
    elif command -v wget >/dev/null 2>&1; then wget -qO "$2" "$1"
    else die "need curl or wget"; fi
}

# ---------------------------------------------------------------- stop / status / uninstall

stop_service() {
    if [ "$OS" = Darwin ]; then
        launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || launchctl unload "$PLIST" 2>/dev/null || true
    else
        systemctl --user stop xchat-relay 2>/dev/null || true
        systemctl --user disable xchat-relay 2>/dev/null || true
    fi
    # belt and braces: the nohup fallback leaves no service to stop, and the supervisor's children
    # (relay, tunnel, settings page) outlive it if we only stop the parent
    [ -f "$XC_HOME/supervisor.pid" ] && kill "$(cat "$XC_HOME/supervisor.pid")" 2>/dev/null || true
    rm -f "$XC_HOME/supervisor.pid"
    pkill -f "$XC_HOME/run.sh" 2>/dev/null || true
    pkill -f "$XC_HOME/xc_admin.py" 2>/dev/null || true
    pkill -f "$XC_HOME/xc_workd.py" 2>/dev/null || true
    pkill -f "$XC_HOME/node/kt_server.py" 2>/dev/null || true
    [ -f "$XC_HOME/relay.pid" ] && kill "$(cat "$XC_HOME/relay.pid")" 2>/dev/null || true
    rm -f "$XC_HOME/relay.pid"
}

ACTION=install
DOMAIN=''
TUNNEL_TOKEN=''
while [ $# -gt 0 ]; do
    case "$1" in
        --status)          ACTION=status ;;
        --stop)            ACTION=stop ;;
        --start)           ACTION=start ;;
        --uninstall)       ACTION=uninstall ;;
        --setup-worker)    ACTION=setup-worker ;;
        --worker-name)     shift; WORKER_NAME="${1:-}"; [ -n "$WORKER_NAME" ] || die "--worker-name needs a value" ;;
        --worker-name=*)   WORKER_NAME="${1#*=}" ;;
        --help|-h)         ACTION=help ;;
        --with-node)       WITH_NODE=1 ;;
        --no-node)         WITH_NODE=0 ;;
        --domain)          shift; DOMAIN="${1:-}"; [ -n "$DOMAIN" ] || die "--domain needs a hostname" ;;
        --domain=*)        DOMAIN="${1#*=}" ;;
        --tunnel-token)    shift; TUNNEL_TOKEN="${1:-}"; [ -n "$TUNNEL_TOKEN" ] || die "--tunnel-token needs a value" ;;
        --tunnel-token=*)  TUNNEL_TOKEN="${1#*=}" ;;
        *) die "unknown option: $1  (try --help)" ;;
    esac
    shift
done

case "$ACTION" in
    status)
        if pgrep -f "$XC_HOME/run.sh" >/dev/null 2>&1; then ok "relay is running"
        else warn "relay is not running"; fi
        [ -f "$XC_HOME/public-url.txt" ] && say "public URL: $(cat "$XC_HOME/public-url.txt")"
        # Whether this node is DISCOVERABLE is the thing an operator most needs to know and the thing
        # that used to be invisible: a failed self-announce only ever wrote a line to selfannounce.log,
        # so a node could serve happily for hours while being unreachable to anyone who didn't already
        # know its URL. Report it plainly, and say exactly what to run.
        say ""
        if [ -f "$XC_HOME/worker.conf" ]; then
            WORKER_URL=''; . "$XC_HOME/worker.conf"
            ok "stable address: ${WORKER_URL:-(worker.conf has no WORKER_URL)}"
        else
            warn "no stable address — this node is NOT announced on the XNO ledger"
            say "  A quick tunnel gets a NEW hostname every restart, so it can't be announced: the"
            say "  on-chain link holds 32 bytes and would go stale on each restart anyway. Others can"
            say "  only reach you if you hand them the current URL by hand."
            say "  Fix it once:  sh $XC_HOME/install-relay.sh --setup-worker"
        fi
        if [ -s "$XC_HOME/operator.seed" ]; then
            ok "operator key present (announces are signed with it)"
        else
            warn "no operator key — self-announce is disabled (see --help)"
        fi
        if [ -s "$XC_HOME/selfannounce.log" ]; then
            say "last announce: $(tail -n 1 "$XC_HOME/selfannounce.log")"
        fi
        say ""
        say "settings:   http://127.0.0.1:$ADMIN_PORT"
        say "logs:       $XC_HOME/relay.log"
        exit 0 ;;
    setup-worker)
        # ONE-TIME: give this node a short, stable, free hostname that survives tunnel churn.
        #
        # Why this exists: the default install uses a Cloudflare QUICK tunnel, which mints a new
        # hostname on every restart (8 different ones in a single day of ordinary use, measured) and
        # whose host routinely exceeds the 32 bytes the on-chain link can hold. Announcing that would
        # be both impossible and wrong. A workers.dev hostname is short, free and permanent; the worker
        # reads the current tunnel from KV, so the address the ledger carries never has to change.
        command -v npx >/dev/null 2>&1 || die "npx not found — install Node.js first (https://nodejs.org), then re-run"
        [ -d "$XC_HOME" ] || die "$XC_HOME not found — install the relay first"
        CFDIR="$XC_HOME/cf-worker"; mkdir -p "$CFDIR/src"
        # Fetch the worker source rather than embedding a copy here: two copies of the same proxy would
        # drift, and the one an operator deploys is the one that must match the repo.
        fetch "$SRC/cf-worker/src/worker.js" "$CFDIR/src/worker.js" \
            || die "could not download the worker source from $SRC/cf-worker/src/worker.js"
        say ""
        say "This opens a browser to sign in to Cloudflare (free account is enough), then creates a KV"
        say "namespace and deploys a tiny worker. Nothing is charged and no card is asked for."
        say ""
        if ! npx --yes wrangler whoami >/dev/null 2>&1; then
            say "Signing in to Cloudflare..."
            npx --yes wrangler login || die "cloudflare login failed — re-run when you can complete it in a browser"
        fi
        ok "signed in to Cloudflare"

        # Reuse an existing namespace when re-run, so this stays idempotent and never orphans one.
        KV_ID=''
        [ -f "$XC_HOME/worker.conf" ] && { KV_NAMESPACE_ID=''; . "$XC_HOME/worker.conf"; KV_ID="$KV_NAMESPACE_ID"; }
        if [ -z "$KV_ID" ]; then
            say "Creating the KV namespace..."
            KV_OUT=$(cd "$CFDIR" && npx --yes wrangler kv namespace create BACKEND_KV 2>&1) || {
                printf '%s\n' "$KV_OUT" >&2; die "could not create the KV namespace (output above)"; }
            # Prefer an explicitly LABELLED id — wrangler renders it as `id = "..."` (toml snippet) or
            # `"id": "..."` (json), and both forms are covered. Falling straight to "first 32-hex run"
            # would be wrong the moment wrangler prints the ACCOUNT id first: those are 32 hex too, and
            # we'd silently bind the worker to a namespace that doesn't exist.
            KV_ID=$(printf '%s' "$KV_OUT" \
                | grep -oE '"?id"?[[:space:]]*[:=][[:space:]]*"?[0-9a-f]{32}' \
                | grep -oE '[0-9a-f]{32}' | head -1)
            [ -n "$KV_ID" ] || KV_ID=$(printf '%s' "$KV_OUT" | grep -oE '[0-9a-f]{32}' | head -1)
            [ -n "$KV_ID" ] || { printf '%s\n' "$KV_OUT" >&2
                die "created the namespace but could not read its id from wrangler's output (above).
Put the id into $CFDIR/wrangler.toml by hand and re-run --setup-worker."; }
        fi
        ok "KV namespace: $KV_ID"

        cat > "$CFDIR/wrangler.toml" <<TOML
name = "$WORKER_NAME"
main = "src/worker.js"
compatibility_date = "2024-09-23"
workers_dev = true

[[kv_namespaces]]
binding = "BACKEND_KV"
id = "$KV_ID"
TOML
        say "Deploying the worker..."
        DEP_OUT=$(cd "$CFDIR" && npx --yes wrangler deploy 2>&1) || {
            printf '%s\n' "$DEP_OUT" >&2; die "worker deploy failed (output above)"; }
        WORKER_URL=$(printf '%s' "$DEP_OUT" | grep -oE 'https://[a-z0-9.-]+\.workers\.dev' | head -1)
        [ -n "$WORKER_URL" ] || { printf '%s\n' "$DEP_OUT" >&2
            die "deployed, but could not read the worker URL from wrangler's output (above)"; }

        # The whole point is an address that FITS on-chain. Check before promising it works: the host
        # is <name>.<account subdomain>.workers.dev and the operator can only shorten the name part.
        HOST=${WORKER_URL#https://}
        LEN=$(printf '%s' "$HOST" | wc -c | tr -d ' ')
        if [ "$LEN" -gt 32 ]; then
            warn "worker deployed at $WORKER_URL"
            die "...but that host is $LEN bytes and the on-chain link holds 32.
Your account subdomain is fixed, so shorten the worker name and re-run, e.g.:
  sh $XC_HOME/install-relay.sh --setup-worker --worker-name x"
        fi
        ok "worker: $WORKER_URL  ($LEN of 32 bytes on-chain)"

        cat > "$XC_HOME/worker.conf" <<CONF
# Cloudflare Worker front for this node (stable short hostname → churning quick tunnel).
WORKER_URL=$WORKER_URL
KV_NAMESPACE_ID=$KV_ID
CONF
        # Point the worker at the tunnel that is live RIGHT NOW, so it works before any restart.
        if [ -s "$XC_HOME/public-url.txt" ]; then
            CUR=$(cat "$XC_HOME/public-url.txt")
            npx --yes wrangler kv key put --remote --namespace-id="$KV_ID" backend "$CUR" >/dev/null 2>&1 \
                && ok "worker now points at $CUR" || warn "could not push the current backend into KV (a restart will do it)"
        fi
        say ""
        ok "Done. Restart so the node announces the worker URL on the ledger:"
        say "  sh $XC_HOME/install-relay.sh --stop && sh $XC_HOME/install-relay.sh --start"
        say "Then check it took:  sh $XC_HOME/install-relay.sh --status"
        exit 0 ;;
    stop)
        stop_service
        ok "relay stopped (it will start again at your next login, or run: xchat start)"
        exit 0 ;;
    start)
        # Re-attach to whatever the installer registered. Falls back to running the supervisor
        # directly, so `xchat start` still works on a box with no service manager.
        if [ "$OS" = Darwin ] && [ -f "$PLIST" ]; then
            launchctl bootstrap "gui/$(id -u)" "$PLIST" 2>/dev/null || launchctl load -w "$PLIST" 2>/dev/null || true
        elif [ -f "$UNIT" ]; then
            systemctl --user start xchat-relay 2>/dev/null || true
        elif [ -f "$XC_HOME/run.sh" ]; then
            nohup /bin/sh "$XC_HOME/run.sh" >>"$XC_HOME/relay.log" 2>&1 &
        else
            die "nothing installed at $XC_HOME — run the installer first"
        fi
        ok "relay starting — check with: xchat status"
        exit 0 ;;
    uninstall)
        step "stopping the relay"
        stop_service
        rm -f "$PLIST" "$UNIT"
        [ "$OS" != Darwin ] && systemctl --user daemon-reload 2>/dev/null || true
        rm -f "$HOME/.local/bin/xchat"                                  # the cli symlink
        rm -rf "$HOME/Applications/ӾChat.app" "$HOME/Applications/ӾChat Relay Settings.app"
        rm -f "$HOME/.local/share/applications/xchat.desktop" \
              "$HOME/.local/share/applications/xchat-relay-settings.desktop" \
              "$HOME/Desktop/xchat.desktop" "$HOME/Desktop/xchat-relay-settings.desktop"
        rm -rf "$XC_HOME"
        ok "removed — relay, settings page, command and shortcuts."
        say "  (a PATH line marked 'added by xchat-relay' may remain in your shell profile)"
        exit 0 ;;
    help)
        # Print the header block up to the first non-comment line. This used to be a hard-coded line
        # range, which silently truncated --help mid-sentence the moment the header grew.
        [ -f "$0" ] && awk 'NR>1 { if (!/^#/) exit; sub(/^# ?/, ""); print }' "$0" \
            || say "see $XC_HOME/install-relay.sh"
        exit 0 ;;
esac

# How this relay gets a public address:
#   quick  — free Cloudflare quick tunnel, new hostname every restart (the zero-config default)
#   named  — your own hostname via a Cloudflare named tunnel token: permanent, one paste to set up
#   direct — you already route https://DOMAIN to this machine (reverse proxy, existing tunnel)
DOMAIN=$(printf '%s' "$DOMAIN" | sed 's#^[a-zA-Z]*://##; s#/*$##')
case "$DOMAIN" in
    *[!a-zA-Z0-9.-]*) die "--domain should be a bare hostname, e.g. relay.example.com (got: $DOMAIN)" ;;
esac
if   [ -n "$DOMAIN" ] && [ -n "$TUNNEL_TOKEN" ]; then MODE=named
elif [ -n "$DOMAIN" ];                          then MODE=direct
else                                                 MODE=quick
fi
PUBLIC_URL=''
[ -n "$DOMAIN" ] && PUBLIC_URL="https://$DOMAIN"

# ---------------------------------------------------------------- preflight

say ''
say "${c_b}ӾChat relay${c_0} ${c_dim}— installing to $XC_HOME${c_0}"
say ''

case "$OS" in
    Darwin|Linux) ;;
    *) die "$OS isn't supported by this installer (macOS and Linux only). On Windows, run the relay in WSL." ;;
esac

PY=$(command -v python3 || true)
[ -n "$PY" ] || {
    if [ "$OS" = Darwin ]; then
        die "Python 3 isn't installed. Run:  xcode-select --install   (then re-run this installer)"
    fi
    die "Python 3 isn't installed. Install it with your package manager, e.g.:
     Debian/Ubuntu:  sudo apt install -y python3 python3-venv
     Fedora:         sudo dnf install -y python3"
}
"$PY" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 8) else 1)' \
    || die "Python 3.8+ is required (found $("$PY" -V 2>&1))"

case "$(uname -m)" in
    x86_64|amd64)  ARCH=amd64 ;;
    arm64|aarch64) ARCH=arm64 ;;
    armv7l|armv6l) ARCH=arm ;;
    *) die "unsupported CPU architecture: $(uname -m)" ;;
esac

# An install over a running relay must not leave the old one holding the port.
stop_service
mkdir -p "$XC_HOME/bin"

# Ports get taken — by another Nano work daemon, a dev server, a second relay. Binding blind means a
# component dies at startup with nothing but a line in a log file, and the supervisor then respawns it
# into the same collision forever; the operator just sees "tips are slow" and has no way to know why.
# So walk up to the first free port and use that.
free_port() {                       # free_port <preferred>  -> echoes a usable port
    p=$1; end=$((p + 20))
    while [ "$p" -lt "$end" ]; do
        if command -v lsof >/dev/null 2>&1; then
            lsof -iTCP:"$p" -sTCP:LISTEN -P >/dev/null 2>&1 || { echo "$p"; return 0; }
        elif command -v nc >/dev/null 2>&1; then
            nc -z 127.0.0.1 "$p" >/dev/null 2>&1 || { echo "$p"; return 0; }
        else
            echo "$p"; return 0
        fi
        p=$((p + 1))
    done
    echo "$1"                       # nothing free in range: keep the preferred one and let it complain
}
NEW_ADMIN=$(free_port "$ADMIN_PORT")
NEW_WORKD=$(free_port "$WORKD_PORT")
[ "$NEW_ADMIN" = "$ADMIN_PORT" ] || warn "port $ADMIN_PORT is in use — settings page moved to $NEW_ADMIN"
[ "$NEW_WORKD" = "$WORKD_PORT" ] || warn "port $WORKD_PORT is in use — work server moved to $NEW_WORKD"
ADMIN_PORT=$NEW_ADMIN
WORKD_PORT=$NEW_WORKD
if [ "$WITH_NODE" = 1 ]; then
    NEW_NODE=$(free_port "$NODE_PORT")
    [ "$NEW_NODE" = "$NODE_PORT" ] || warn "port $NODE_PORT is in use — node moved to $NEW_NODE"
    NODE_PORT=$NEW_NODE
fi

# ---------------------------------------------------------------- the relay itself

step "downloading the relay"
fetch "$SRC/relay/xc_relayd.py"    "$XC_HOME/xc_relayd.py"
fetch "$SRC/backend/xc_common.py"  "$XC_HOME/xc_common.py"
fetch "$SRC/relay/xc_admin.py"     "$XC_HOME/xc_admin.py"
fetch "$SRC/backend/xc_workd.py"   "$XC_HOME/xc_workd.py"
fetch "$SRC/relay/work/nano_work_cl.c" "$XC_HOME/nano_work_cl.c" 2>/dev/null || true
"$PY" -c "import ast,sys; ast.parse(open(sys.argv[1]).read())" "$XC_HOME/xc_relayd.py" \
    || die "the downloaded relay is not valid Python — the download was truncated or tampered with"
fetch "$SRC/relay/install-relay.sh" "$SELF" && chmod +x "$SELF"   # so --status/--uninstall work later
ok "relay downloaded ($(wc -c < "$XC_HOME/xc_relayd.py" | tr -d ' ') bytes)"

step "setting up Python (nanopy — signature checks + your relay account)"
RELAY_PY="$PY"
if "$PY" -m venv "$XC_HOME/venv" >/dev/null 2>&1; then
    RELAY_PY="$XC_HOME/venv/bin/python3"
    "$XC_HOME/venv/bin/pip" install -q --disable-pip-version-check nanopy >/dev/null 2>&1 \
        || warn "couldn't install nanopy in the venv — trying the system Python"
fi
if ! "$RELAY_PY" -c 'import nanopy' 2>/dev/null; then
    "$PY" -m pip install -q --user nanopy >/dev/null 2>&1 || true
    "$PY" -c 'import nanopy' 2>/dev/null && RELAY_PY="$PY"
fi
if "$RELAY_PY" -c 'import nanopy' 2>/dev/null; then
    ok "nanopy ready"
else
    RELAY_PY="$PY"
    warn "nanopy could not be installed — the relay will still serve bytes, but it can't verify"
    warn "  signed profiles/reports or accept paid pins. Install it later with:  pip3 install nanopy"
fi

# ---------------------------------------------------------------- the tunnel

CF="$XC_HOME/bin/cloudflared"
if [ "$MODE" = direct ]; then
    ok "using https://$DOMAIN — you route it to 127.0.0.1:$PORT yourself, no tunnel installed"
else
    [ "$MODE" = named ] && step "downloading cloudflared (for your named tunnel)" \
                        || step "downloading cloudflared (the free public tunnel)"
    CF_BASE=https://github.com/cloudflare/cloudflared/releases/latest/download
    if [ "$OS" = Darwin ]; then
        fetch "$CF_BASE/cloudflared-darwin-$ARCH.tgz" "$XC_HOME/bin/cf.tgz"
        tar -xzf "$XC_HOME/bin/cf.tgz" -C "$XC_HOME/bin"
        rm -f "$XC_HOME/bin/cf.tgz"
    else
        fetch "$CF_BASE/cloudflared-linux-$ARCH" "$CF"
    fi
    chmod +x "$CF"
    "$CF" --version >/dev/null 2>&1 || die "cloudflared didn't run — download may have failed"
    ok "tunnel ready ($("$CF" --version 2>&1 | head -1))"
fi

# ---------------------------------------------------------------- who gets paid

# The relay's Nano account is what pay-to-pin and tip-splits pay out to. Left unset, xc_relayd
# falls back to a DEMO key derived from a fixed byte — publicly known, so anything sent there is
# anyone's to take. Ask for the operator's own address instead. Piped through `sh` there is no
# stdin to read from, so ask the terminal directly.
# `[ -r /dev/tty ]` is true even where opening it fails (cron, a CI shell, a detached run), and the
# failure prints a raw `sh: /dev/tty: Device not configured` at the reader. Actually open it first.
ACCT="${RELAY_ACCT:-}"
if [ -z "$ACCT" ] && { : < /dev/tty; } 2>/dev/null; then
    say ''
    say "  Your relay can be paid (pinning fees, tip splits). Paste the ӾChat address you want"
    say "  that money to land in — it's in the app under your profile. ${c_dim}Press Enter to skip.${c_0}"
    printf '  nano_… : '
    read -r ACCT < /dev/tty 2>/dev/null || ACCT=''
fi
case "$ACCT" in
    '')            warn "no address set — your relay won't take paid pins (re-run later to set one)" ;;
    nano_*)        [ ${#ACCT} -eq 65 ] || die "that doesn't look like a Nano address (expected 65 characters)" ;;
    *)             die "a Nano address starts with nano_ — got: $ACCT" ;;
esac

# ---------------------------------------------------------------- the node (optional)

if [ "$WITH_NODE" = 1 ]; then
    step "downloading the node (the API your app talks to)"
    mkdir -p "$XC_HOME/node"
    missing=''
    for f in $NODE_FILES; do
        fetch "$SRC/backend/$f" "$XC_HOME/node/$f" 2>/dev/null || missing="$missing $f"
    done
    fetch "$SRC/backend/download.html" "$XC_HOME/node/download.html" 2>/dev/null || true
    for f in kt_server.py xc_common.py; do
        [ -s "$XC_HOME/node/$f" ] || die "could not download $f — the node cannot run without it"
    done
    "$PY" -c "import ast,sys; ast.parse(open(sys.argv[1]).read())" "$XC_HOME/node/kt_server.py" \
        || die "the downloaded node is not valid Python — the download was truncated or tampered with"
    [ -n "$missing" ] && warn "optional node helpers missing:$missing (those features will be off)"
    # pynacl is the node's only extra dependency (DM encryption); nanopy is already installed above.
    if ! "$RELAY_PY" -c 'import nacl' 2>/dev/null; then
        [ -x "$XC_HOME/venv/bin/pip" ] && "$XC_HOME/venv/bin/pip" install -q --disable-pip-version-check pynacl >/dev/null 2>&1 || true
    fi
    "$RELAY_PY" -c 'import nacl' 2>/dev/null && ok "node ready (encrypted DMs enabled)" \
        || warn "node ready, but pynacl is missing — encrypted DMs will be unavailable"
    command -v ipfs >/dev/null 2>&1 \
        || warn "no IPFS on this machine — the node will serve posts and tips fine, but not media bytes"
fi

# ---------------------------------------------------------------- proof-of-work

# A tip only settles once its blocks have PoW, and that is the slow step: free public work RPCs take
# 0.9s–36s and rate-limit, and a CPU takes about a minute a block. A GPU does it in seconds. Building
# this is best-effort — no compiler or no OpenCL just means the work server runs on CPU instead.
step "setting up proof-of-work (this is what makes tips fast)"
WORK_MODE=cpu
if [ -f "$XC_HOME/nano_work_cl.c" ] && command -v cc >/dev/null 2>&1; then
    CL_FLAGS="-lOpenCL"
    [ "$OS" = Darwin ] && CL_FLAGS="-framework OpenCL -Wno-deprecated-declarations"
    if cc -O3 "$XC_HOME/nano_work_cl.c" -o "$XC_HOME/bin/nano_work_cl" $CL_FLAGS >/dev/null 2>&1 \
       && "$XC_HOME/bin/nano_work_cl" 0000000000000000000000000000000000000000000000000000000000000000 \
            0000000000000001 >/dev/null 2>&1; then
        WORK_MODE=gpu
    fi
fi
if [ "$WORK_MODE" = gpu ]; then
    ok "GPU proof-of-work ready — tips settle in seconds"
else
    warn "no GPU proof-of-work here (no OpenCL or no compiler) — falling back to CPU, which is slower"
fi

# ---------------------------------------------------------------- settings file

# From here on the settings page owns these values; the installer only seeds them. Re-running the
# installer must not silently revert a change made in the browser, so an existing config is kept.
if [ ! -f "$XC_HOME/config.json" ]; then
    printf '{\n  "relay_acct": "%s",\n  "bootstrap": "%s"\n}\n' "$ACCT" "$BOOTSTRAP" > "$XC_HOME/config.json"
fi

# ---------------------------------------------------------------- supervisor

step "writing the start script"
cat > "$XC_HOME/run.sh" <<EOF
#!/bin/sh
# Keeps a tunnel + relay pair alive. Written by install-relay.sh — re-run the installer to change.
XC_HOME="$XC_HOME"
PORT=$PORT
PY="$RELAY_PY"
CF="$CF"
BOOTSTRAP="$BOOTSTRAP"
MODE=$MODE
PUBLIC_URL="$PUBLIC_URL"
TUNNEL_TOKEN="$TUNNEL_TOKEN"
ADMIN_PORT=$ADMIN_PORT
WORKD_PORT=$WORKD_PORT
NODE_PORT=$NODE_PORT
WITH_NODE=$WITH_NODE
export XC_WORK_URL="http://127.0.0.1:$WORKD_PORT"   # lets the relay serve /work to the network
export XC_WORK_BIN="$XC_HOME/bin/nano_work_cl"
export RELAY_ACCT="$ACCT"
export BIND_HOST="${XC_BIND:-127.0.0.1}"
KEEP_AWAKE="${KEEP_AWAKE:-1}"
EOF
cat >> "$XC_HOME/run.sh" <<'EOF'
# Ledger RPCs in PREFERENCE order. This export is what every child actually gets, so the order here is
# the one that counts (start_node repeats the same list only so it reads correctly on its own). Keep the
# most reliable endpoint FIRST: xc_common's `_rpc_good` index is per-PROCESS, and helpers are spawned per
# request, so each one re-tries the head of this list. A dead endpoint in front cost ~10.5s on the first
# RPC of EVERY helper (measured) — it reads as random slowness, not as one bad endpoint.
export XC_NANO_RPC="${XC_NANO_RPC:-https://nanoslo.0x.no/proxy,https://rainstorm.city/api,https://rpc.nano.to}"
# The node pins each thread to IPFS to get its CID. xc_common defaults IPFS_PATH to /tmp/ipfsB, which
# macOS wipes on reboot — so the repo silently stops existing and every post falls back to the second
# repo (or fails outright on a machine that has only the one). Point it at a persistent path instead.
# A fresh machine still needs `ipfs init` once; this only stops a working repo from evaporating.
export IPFS_PATH="${IPFS_PATH:-$HOME/.ipfs}"
cd "$XC_HOME"
echo "$$" > "$XC_HOME/supervisor.pid"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

# RUNNING OVERNIGHT. A laptop that goes to sleep stops being a relay, so the relay is launched under a
# sleep inhibitor. The choice of inhibitor matters: macOS `caffeinate -s` prevents idle sleep ONLY
# while the machine is on mains power, which is exactly the wanted behaviour — serve all night when
# plugged in, and never hold a machine awake to flatten someone's battery. Linux gets the equivalent
# via systemd-inhibit. Closing a laptop lid still sleeps it on both (that is a hardware-level policy
# neither tool overrides) — plugged in with the lid open is the case this covers.
on_power() {
    case "$(uname -s)" in
        Darwin) pmset -g ps 2>/dev/null | grep -q "AC Power" ;;
        *) grep -qs 1 /sys/class/power_supply/A*/online 2>/dev/null ;;
    esac
}
awake_prefix() {                    # echoes the command prefix that holds sleep off, or nothing
    # reads KEEP_AWAKE live, not a snapshot — the settings page can flip it between relay restarts
    [ "${KEEP_AWAKE:-1}" = "1" ] || return 0
    if [ "$(uname -s)" = Darwin ] && command -v caffeinate >/dev/null 2>&1; then
        echo "caffeinate -s"        # no-op on battery, by design
    elif command -v systemd-inhibit >/dev/null 2>&1; then
        echo "systemd-inhibit --what=idle:sleep --who=xchat-relay --why=serving --mode=block"
    fi
}

# The settings page, on loopback only. Outlives individual relay restarts — saving a setting works by
# writing config.json and stopping the relay, and this is what has to still be there afterwards.
start_admin() {
    [ -n "$ADMIN_PORT" ] && [ "$ADMIN_PORT" != 0 ] || return 0
    "$PY" "$XC_HOME/xc_admin.py" "$ADMIN_PORT" "http://127.0.0.1:$PORT" \
          "$XC_HOME/config.json" "$XC_HOME" >>"$XC_HOME/admin.log" 2>&1 &
    ADMIN_PID=$!
}
start_workd() {
    [ -n "$WORKD_PORT" ] && [ "$WORKD_PORT" != 0 ] || return 0
    "$PY" "$XC_HOME/xc_workd.py" "$WORKD_PORT" >>"$XC_HOME/work.log" 2>&1 &
    WORKD_PID=$!
}
start_node() {
    # XC_WORK points the node at the local (GPU) work server, which is the whole reason to run a node
    # here: proof-of-work stops being a public-RPC lottery and becomes a couple of seconds on your own
    # machine. XC_WORK_LOCAL=1 keeps the CPU fallback so a tip can never be blocked outright.
    [ "$WITH_NODE" = 1 ] || return 0
    cd "$XC_HOME/node" || return 0
    XC_WORK="http://127.0.0.1:$WORKD_PORT" \
    XC_WORK_LOCAL=1 \
    XC_NANO_RPC="${XC_NANO_RPC:-https://nanoslo.0x.no/proxy,https://rainstorm.city/api,https://rpc.nano.to}" \
    XCHAT_BOOTSTRAP="$(echo "$BOOTSTRAP" | tr ' ' ',')" \
        "$PY" "$XC_HOME/node/kt_server.py" "$NODE_PORT" >>"$XC_HOME/node.log" 2>&1 &
    NODE_PID=$!
    cd "$XC_HOME"
}
# The node pins every thread to IPFS to get its CID, so with no repo at IPFS_PATH each post fails —
# and the operator only finds out from a post that silently does nothing. Create one on first run.
#
# NEVER destructive. If the path exists, is non-empty, but has no config, it is a HALF-BUILT repo
# (this happens: a repo whose blocks/ survived without its config or SHARDING marker) — `ipfs init`
# refuses it anyway, and forcing the issue would mean deleting blocks somebody may still want. Say
# what is wrong and carry on; serving must not depend on this.
ensure_ipfs() {
    if ! command -v ipfs >/dev/null 2>&1; then
        log "ipfs not installed — the node serves fine, but posting (which pins to IPFS) will fail"
        return 0
    fi
    if ipfs repo stat >/dev/null 2>&1; then                       # already a working repo
        return 0
    fi
    if [ -d "$IPFS_PATH" ] && [ -n "$(ls -A "$IPFS_PATH" 2>/dev/null)" ] && [ ! -f "$IPFS_PATH/config" ]; then
        log "IPFS repo at $IPFS_PATH looks half-built (no config) — leaving it untouched;"
        log "  inspect it, then run:  IPFS_PATH=$IPFS_PATH ipfs init"
        return 0
    fi
    if ipfs init >/dev/null 2>&1; then
        log "initialised an IPFS repo at $IPFS_PATH"
    else
        log "could not initialise an IPFS repo at $IPFS_PATH — posting will fail until one exists"
    fi
}
ensure_ipfs

ADMIN_PID=''
WORKD_PID=''
NODE_PID=''
start_admin
start_workd
start_node

while : ; do
    # Re-read settings every time round: this is how the settings page applies a change — it writes
    # config.json, stops the relay, and the values below are picked up on the way back up.
    if [ -f "$XC_HOME/config.json" ]; then
        eval "$("$PY" - "$XC_HOME/config.json" <<'PYCFG' 2>/dev/null || true
import json, shlex, sys
try:
    c = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
print('export RELAY_ACCT=%s' % shlex.quote(str(c.get('relay_acct') or '')))
if c.get('blob_cap_mb'):
    print('export XC_BLOB_CAP_MB=%s' % shlex.quote(str(c['blob_cap_mb'])))
if c.get('bootstrap'):
    print('BOOTSTRAP=%s' % shlex.quote(' '.join(str(c['bootstrap']).split())))
if c.get('blob_replicas'):
    print('export XC_BLOB_REPLICAS=%s' % shlex.quote(str(c['blob_replicas'])))
# open federation is ON unless the operator explicitly set it to false
print('export XC_OPEN_ANNOUNCE=%s' % ('0' if c.get('open_announce') is False else '1'))
print('KEEP_AWAKE=%s' % ('0' if c.get('keep_awake') is False else '1'))
PYCFG
)"
    fi
    CF_PID=''
    URL="$PUBLIC_URL"                      # named/direct: the address is yours and never changes

    if [ "$MODE" = quick ]; then
        # A quick tunnel mints a NEW hostname every run, so the relay can only start once the URL
        # exists. The relay's identity is its own keypair, not this hostname, so peers recognise it
        # across the change and replace the old address rather than accumulating dead ones.
        : > "$XC_HOME/tunnel.log"
        # Expose the NODE (kt_server) when one is running: it serves /api AND proxies every other path to
        # the relay, so tunnelling 8790 gives a full node (the app needs /api). Relay-only installs tunnel
        # the relay port.
        TUNNEL_PORT="$PORT"; [ "$WITH_NODE" = 1 ] && TUNNEL_PORT="$NODE_PORT"
        "$CF" tunnel --no-autoupdate --url "http://127.0.0.1:$TUNNEL_PORT" >>"$XC_HOME/tunnel.log" 2>&1 &
        CF_PID=$!
        URL=''; i=0
        while [ $i -lt 60 ]; do
            URL=$(grep -oh 'https://[a-z0-9][a-z0-9-]*\.trycloudflare\.com' "$XC_HOME/tunnel.log" 2>/dev/null | head -1)
            [ -n "$URL" ] && break
            kill -0 $CF_PID 2>/dev/null || break
            sleep 1; i=$((i + 1))
        done
        if [ -z "$URL" ]; then
            log "tunnel did not come up; retrying in 15s"
            kill $CF_PID 2>/dev/null || true; wait $CF_PID 2>/dev/null || true
            sleep 15; continue
        fi
    elif [ "$MODE" = named ]; then
        : > "$XC_HOME/tunnel.log"
        "$CF" tunnel --no-autoupdate run --token "$TUNNEL_TOKEN" >>"$XC_HOME/tunnel.log" 2>&1 &
        CF_PID=$!
        sleep 5                            # let it register before the relay announces the hostname
    fi

    echo "$URL" > "$XC_HOME/public-url.txt"
    log "public url: $URL (mode=$MODE)"

    # Optional Cloudflare Worker front: a stable, short workers.dev url that reverse-proxies to this node.
    # It fixes two things for a home node — a quick tunnel's hostname is too long for the 32-byte on-chain
    # announce AND it churns every restart. Drop a worker.conf next to this file (WORKER_URL + KV_NAMESPACE_ID)
    # and the node keeps the worker's KV pointed at the current tunnel url, then announces the FIXED worker
    # url on-chain. Without worker.conf we announce the tunnel url directly (only works for hosts <=32 bytes).
    ANNOUNCE_URL="$URL"
    if [ -f "$XC_HOME/worker.conf" ]; then
        . "$XC_HOME/worker.conf"
        ANNOUNCE_URL="${WORKER_URL:-$URL}"
        if [ -n "$KV_NAMESPACE_ID" ]; then
            ( sleep 8
              PATH="/opt/homebrew/bin:/usr/local/bin:$PATH:/usr/bin:/bin"   # find node/npx in a service env
              command -v npx >/dev/null 2>&1 &&
                npx wrangler kv key put --remote --namespace-id="$KV_NAMESPACE_ID" backend "$URL" \
                  >>"$XC_HOME/kv-update.log" 2>&1
            ) &
        fi
    fi
    # Register the node on the XNO ledger so the app can rediscover it from an unstoppable source.
    # Idempotent (xc_reldir ensure re-commits only when the announced url changed); needs a one-time-funded
    # operator seed in operator.seed. Backgrounded + non-fatal: it never blocks serving.
    if [ "$WITH_NODE" = 1 ] && [ -s "$XC_HOME/operator.seed" ]; then
        ( sleep 25
          XC_RELAY_OPERATOR_SEED="$(cat "$XC_HOME/operator.seed")" NODE_PUBLIC_URL="$ANNOUNCE_URL" \
            "$PY" "$XC_HOME/node/xc_reldir.py" ensure "$ANNOUNCE_URL" >>"$XC_HOME/selfannounce.log" 2>&1
        ) &
    fi
    AWAKE=$(awake_prefix)
    on_power && log "on mains power — will stay awake to serve" || log "on battery — will sleep normally"
    RELAY_PUBLIC_URL="$URL" $AWAKE "$PY" "$XC_HOME/xc_relayd.py" "$PORT" "$XC_HOME/relay-state.json" $BOOTSTRAP &
    RELAY_PID=$!
    echo "$RELAY_PID" > "$XC_HOME/relay.pid"       # the settings page stops exactly this pid, not a pattern
    log "relay started (pid $RELAY_PID) on $BIND_HOST:$PORT"

    # If either half dies the pair is useless — the URL would point at nothing, or the relay would
    # keep advertising a hostname that no longer routes. Take both down and rebuild together.
    while kill -0 $RELAY_PID 2>/dev/null && { [ -z "$CF_PID" ] || kill -0 $CF_PID 2>/dev/null; }; do
        sleep 5
        [ -n "$ADMIN_PID" ] && ! kill -0 $ADMIN_PID 2>/dev/null && start_admin   # keep the page alive
        [ -n "$WORKD_PID" ] && ! kill -0 $WORKD_PID 2>/dev/null && start_workd   # and the work server
        [ -n "$NODE_PID" ] && ! kill -0 $NODE_PID 2>/dev/null && start_node      # and the node
        # keep the log from growing without bound on a long-lived install
        if [ "$(wc -c < "$XC_HOME/relay.log" 2>/dev/null || echo 0)" -gt 20000000 ]; then
            tail -c 2000000 "$XC_HOME/relay.log" > "$XC_HOME/relay.log.tmp" 2>/dev/null &&
                mv "$XC_HOME/relay.log.tmp" "$XC_HOME/relay.log"
        fi
    done
    log "tunnel or relay exited — restarting both"
    kill $CF_PID $RELAY_PID 2>/dev/null || true
    wait $CF_PID $RELAY_PID 2>/dev/null || true
    rm -f "$XC_HOME/public-url.txt"
    sleep 5
done

EOF
chmod +x "$XC_HOME/run.sh"

# ---------------------------------------------------------------- cli + shortcuts

step "adding the 'xchat' command and shortcuts"
# With a local node the app should point at YOUR node, not the hosted one: same-origin, and its
# tips get the GPU work server instead of a public RPC.
if [ "$WITH_NODE" = 1 ]; then
    APP_URL="${XC_APP_URL:-http://127.0.0.1:$NODE_PORT/chat}"
else
    APP_URL="${XC_APP_URL:-https://xchat-alpha-node.fly.dev/chat}"
fi
ADMIN_URL="http://127.0.0.1:$ADMIN_PORT"

cat > "$XC_HOME/bin/xchat" <<EOF
#!/bin/sh
# The ӾChat relay control command. Written by install-relay.sh.
XC_HOME="$XC_HOME"
SELF="$SELF"
ADMIN_URL="$ADMIN_URL"
APP_URL="$APP_URL"
PORT=$PORT
WORKD_PORT=$WORKD_PORT
NODE_PORT=$NODE_PORT
WITH_NODE=$WITH_NODE
# The subcommands that delegate back to the installer (status/stop/start/uninstall) must be told WHICH
# install they are acting on — without this it falls back to the default ~/.xchat-relay and cheerfully
# reports on, or stops, the wrong relay on a machine that has more than one.
export XC_RELAY_HOME="$XC_HOME"
export XC_RELAY_PORT=$PORT
export XC_ADMIN_PORT=$ADMIN_PORT
EOF
cat >> "$XC_HOME/bin/xchat" <<'EOF'
open_url() {                       # whichever opener this desktop has
    if command -v open >/dev/null 2>&1; then open "$1"
    elif command -v xdg-open >/dev/null 2>&1; then xdg-open "$1"
    else echo "open this in your browser: $1"; fi
}
case "${1:-help}" in
    status)   sh "$SELF" --status ;;
    url)      cat "$XC_HOME/public-url.txt" 2>/dev/null || echo "(no public url yet)" ;;
    logs)     tail -f "$XC_HOME/relay.log" ;;
    settings) open_url "$ADMIN_URL" ;;
    app)      open_url "$APP_URL" ;;
    earnings) curl -fsS "$ADMIN_URL/api/state" 2>/dev/null \
                | python3 -c 'import sys,json; d=json.load(sys.stdin); e=d.get("earnings") or {}; \
print("payout :", d.get("payout") or "(none set)"); \
print("balance:", e.get("balance_xno"), "XNO"); \
print("paid   :", e.get("received"), "payments")' 2>/dev/null || echo "settings page not running" ;;
    storage)  curl -fsS "http://127.0.0.1:$PORT/cache" 2>/dev/null \
                | python3 -c 'import sys,json; d=json.load(sys.stdin); \
print("stored :", d["blobs"], "files,", round(d["bytes"]/1048576,1), "MB of", round(d["cap"]/1048576), "MB"); \
print("my share:", d.get("shard"), "· extra copies:", d.get("opportunistic"), \
"· target replicas:", d.get("replicas"))' 2>/dev/null || echo "relay not responding" ;;
    node)     if [ "$WITH_NODE" = 1 ]; then
                  curl -fsS "http://127.0.0.1:$NODE_PORT/api/status" 2>/dev/null \
                    | python3 -c 'import sys,json; d=json.load(sys.stdin); \
print("node   : online, ledger height", d.get("height"))' 2>/dev/null || echo "node not responding"
                  echo "address: http://127.0.0.1:$NODE_PORT   (from your phone: http://$(ipconfig getifaddr en0 2>/dev/null || hostname):$NODE_PORT)"
              else echo "no node installed — re-run the installer with --with-node"; fi ;;
    work)     curl -fsS "http://127.0.0.1:$WORKD_PORT/status" 2>/dev/null \
                | python3 -c 'import sys,json; d=json.load(sys.stdin); \
print("source :", "GPU" if d.get("gpu_bin") else "CPU"); \
print("solved :", d.get("gpu",0)+d.get("cpu",0), "blocks ·", d.get("cached",0), "served from cache"); \
print("average:", d.get("avg_s"), "seconds a block")' 2>/dev/null || echo "work server not running" ;;
    stop)     sh "$SELF" --stop ;;
    start)    sh "$SELF" --start ;;
    restart)  sh "$SELF" --stop && sh "$SELF" --start ;;
    uninstall) sh "$SELF" --uninstall ;;
    *)
        echo "ӾChat relay"
        echo "  xchat status     is it running, and on what address"
        echo "  xchat app        open ӾChat in your browser"
        echo "  xchat settings   open the settings page for your relay"
        echo "  xchat earnings   what your relay has been paid"
        echo "  xchat storage    how much of your disk it is using"
        echo "  xchat work       proof-of-work stats (what makes tips fast)"
        echo "  xchat node       your local node: is it up, and its address"
        echo "  xchat url        your relay's public address"
        echo "  xchat logs       follow the log (ctrl-C to stop)"
        echo "  xchat stop | start | restart | uninstall"
        ;;
esac
EOF
chmod +x "$XC_HOME/bin/xchat"

# Put it somewhere the shell will find. ~/.local/bin is the conventional per-user spot; if it isn't on
# PATH we add it once, marked, so re-running the installer can't stack duplicate lines in a dotfile.
BINDIR="$HOME/.local/bin"
mkdir -p "$BINDIR"
ln -sf "$XC_HOME/bin/xchat" "$BINDIR/xchat"
case ":$PATH:" in
    *":$BINDIR:"*) ok "'xchat' command installed" ;;
    *)
        for rc in "$HOME/.zshrc" "$HOME/.bashrc"; do
            [ -f "$rc" ] || continue
            grep -q 'added by xchat-relay' "$rc" 2>/dev/null && continue
            printf '\nexport PATH="$HOME/.local/bin:$PATH"   # added by xchat-relay\n' >> "$rc"
        done
        ok "'xchat' command installed (open a NEW terminal window to use it)"
        ;;
esac

# Clickable shortcuts, because "run a relay" shouldn't mean "live in a terminal".
if [ "$OS" = Darwin ]; then
    make_app() {                    # $1 = name, $2 = url, $3 = destination dir
        b="$3/$1.app/Contents"
        mkdir -p "$b/MacOS"
        printf '#!/bin/sh\nopen "%s"\n' "$2" > "$b/MacOS/run"
        chmod +x "$b/MacOS/run"
        cat > "$b/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>$1</string>
  <key>CFBundleExecutable</key><string>run</string>
  <key>CFBundleIdentifier</key><string>chat.xno.shortcut.$(echo "$1" | tr -dc '[:alnum:]')</string>
  <key>CFBundleVersion</key><string>1.0</string>
  <key>LSUIElement</key><true/>
</dict></plist>
PLIST
    }
    mkdir -p "$HOME/Applications"
    make_app "ӾChat" "$APP_URL" "$HOME/Applications"
    make_app "ӾChat Relay Settings" "$ADMIN_URL" "$HOME/Applications"
    ok "shortcuts added to your Applications folder (search Spotlight for 'ӾChat')"
else
    APPS="$HOME/.local/share/applications"
    mkdir -p "$APPS"
    make_desktop() {                # $1 = name, $2 = url, $3 = filename
        cat > "$APPS/$3.desktop" <<DESK
[Desktop Entry]
Type=Application
Name=$1
Exec=xdg-open $2
Icon=internet-web-browser
Terminal=false
Categories=Network;
DESK
        chmod +x "$APPS/$3.desktop"
        [ -d "$HOME/Desktop" ] && cp "$APPS/$3.desktop" "$HOME/Desktop/" 2>/dev/null || true
    }
    make_desktop "ӾChat" "$APP_URL" "xchat"
    make_desktop "ӾChat Relay Settings" "$ADMIN_URL" "xchat-relay-settings"
    command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database "$APPS" 2>/dev/null || true
    ok "shortcuts added to your applications menu"
fi

# ---------------------------------------------------------------- start at login

step "registering it to start at login"
STARTED=''
if [ "$OS" = Darwin ]; then
    mkdir -p "$HOME/Library/LaunchAgents"
    cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array><string>/bin/sh</string><string>$XC_HOME/run.sh</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>$XC_HOME/relay.log</string>
  <key>StandardErrorPath</key><string>$XC_HOME/relay.log</string>
</dict></plist>
EOF
    if launchctl bootstrap "gui/$(id -u)" "$PLIST" 2>/dev/null || launchctl load -w "$PLIST" 2>/dev/null
    then STARTED=launchd
    fi
else
    if command -v systemctl >/dev/null 2>&1 && systemctl --user show-environment >/dev/null 2>&1; then
        mkdir -p "$(dirname "$UNIT")"
        cat > "$UNIT" <<EOF
[Unit]
Description=ӾChat relay
After=network-online.target

[Service]
ExecStart=/bin/sh $XC_HOME/run.sh
Restart=always
RestartSec=10
StandardOutput=append:$XC_HOME/relay.log
StandardError=append:$XC_HOME/relay.log

[Install]
WantedBy=default.target
EOF
        systemctl --user daemon-reload
        # without lingering, the relay stops the moment the operator logs out
        loginctl enable-linger "$(id -un)" >/dev/null 2>&1 || \
            warn "couldn't enable lingering — the relay will stop when you log out"
        systemctl --user enable --now xchat-relay >/dev/null 2>&1 && STARTED=systemd
    fi
    if [ -z "$STARTED" ]; then
        warn "no systemd user session here — starting it in the background instead"
        warn "  (it will NOT come back after a reboot; re-run this installer to restart it)"
        nohup /bin/sh "$XC_HOME/run.sh" >>"$XC_HOME/relay.log" 2>&1 &
        STARTED=nohup
    fi
fi
[ -n "$STARTED" ] || die "couldn't start the relay — see $XC_HOME/relay.log"
ok "registered ($STARTED)"

# ---------------------------------------------------------------- wait for it to be live

[ "$MODE" = quick ] && step "opening your public tunnel" || step "starting your relay on https://$DOMAIN"
URL=''; i=0
while [ $i -lt 60 ]; do
    [ -f "$XC_HOME/public-url.txt" ] && URL=$(cat "$XC_HOME/public-url.txt") && [ -n "$URL" ] && break
    sleep 1; i=$((i + 1))
done

say ''
if [ -n "$URL" ]; then
    # A just-minted tunnel hostname can take a few seconds to resolve — and a resolver that already
    # negative-cached it takes longer still. Retry before calling it a failure.
    HEADS=''; i=0
    while [ $i -lt 6 ]; do
        HEADS=$(curl -fsS --max-time 10 "$URL/heads" 2>/dev/null || true)
        [ -n "$HEADS" ] && break
        sleep 5; i=$((i + 1))
    done
    say "${c_ok}${c_b}Your relay is live.${c_0}"
    say ''
    say "  ${c_b}$URL${c_0}"
    if [ -n "$HEADS" ]; then
        ok "reachable from the internet — it answered a request on that address"
    elif [ "$MODE" = direct ]; then
        warn "nothing answered on $URL yet — check that it routes to 127.0.0.1:$PORT on this machine"
    else
        warn "the tunnel is up but hasn't answered yet; give it a minute, then: sh ${SELF} --status"
    fi
else
    warn "the relay is installed and starting, but it has no public address yet."
    say "  Check again in a minute:  sh ${SELF} --status"
fi

say ''
say "${c_b}Settings and earnings:${c_0}  http://127.0.0.1:$ADMIN_PORT"
say "${c_dim}Open that in your browser to set your payout address, storage cap and peers, and to see${c_0}"
say "${c_dim}what your relay has been paid. Only this computer can reach it — it isn't on the internet.${c_0}"
say ''
say "${c_b}In your browser${c_0}"
say "  ӾChat app      $APP_URL"
say "  Relay settings $ADMIN_URL"
say "${c_dim}  Both are also shortcuts you can click — search for 'ӾChat'.${c_0}"
say ''
say "${c_b}In a terminal${c_0} ${c_dim}(type 'xchat' for the full list)${c_0}"
say "${c_dim}  xchat status     is it running, and where${c_0}"
say "${c_dim}  xchat earnings   what it has been paid${c_0}"
say "${c_dim}  xchat storage    how much disk it is using${c_0}"
say "${c_dim}  xchat app        open ӾChat${c_0}"
say "${c_dim}  xchat settings   open the settings page${c_0}"
say "${c_dim}  xchat stop | start | restart | logs | uninstall${c_0}"
say ''
if [ "$OS" = Darwin ]; then
    say "${c_dim}It starts when you log in, and stays awake to serve while plugged in (it won't hold${c_0}"
    say "${c_dim}the machine awake on battery). Closing the lid still sleeps the laptop.${c_0}"
else
    say "${c_dim}It starts when you log in, and holds off idle sleep while plugged in.${c_0}"
fi
say ''

# Your relay's identity is a keypair it generated for itself, not its hostname — so a changing
# address costs the network nothing: peers replace the old entry instead of stacking up dead ones.
if [ -f "$XC_HOME/relay-state.json.id" ] && [ -n "$RELAY_PY" ]; then
    ID=$("$RELAY_PY" - "$XC_HOME/relay-state.json.id" <<'PYEOF' 2>/dev/null || true
import sys
try:
    sys.path.insert(0, __import__('os').path.dirname(sys.argv[1]))
    import xc_common as xc
    print(xc.derive(open(sys.argv[1]).read().strip())[0])
except Exception:
    pass
PYEOF
)
    [ -n "$ID" ] && say "${c_dim}Relay identity (stable across restarts and address changes):${c_0}" \
                 && say "${c_dim}  $ID${c_0}" && say ''
fi

if [ "$MODE" = quick ]; then
    say "${c_dim}The address changes each restart. That's fine — your relay's identity doesn't, so peers${c_0}"
    say "${c_dim}follow it to the new address. Want a permanent one? Re-run with --domain your.host and,${c_0}"
    say "${c_dim}if it's a Cloudflare tunnel, --tunnel-token <token from the Cloudflare dashboard>.${c_0}"
elif [ ${#DOMAIN} -le 32 ]; then
    # On-chain announce is the strongest form of discovery (no bootstrap needed at all), but it costs
    # a real transaction from a funded account, so it stays the operator's own deliberate step — this
    # installer never asks for a seed.
    say "${c_dim}Your address is permanent, so you can also announce it ON-CHAIN — then nodes find you by${c_0}"
    say "${c_dim}scanning the ledger, with no bootstrap at all. From a repo checkout, with a funded key:${c_0}"
    say "${c_dim}  XC_RELAY_OPERATOR_SEED=<64-hex seed> python3 backend/xc_reldir.py announce-mainnet https://$DOMAIN${c_0}"
else
    say "${c_dim}Your address is permanent. It's ${#DOMAIN} characters, though, and an on-chain announce packs${c_0}"
    say "${c_dim}the host into a 32-byte block link — a shorter hostname would let you announce on-chain too.${c_0}"
fi
say ''
