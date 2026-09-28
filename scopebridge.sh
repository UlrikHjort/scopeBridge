#!/usr/bin/env bash
# Start scopebridge-server and scopebridge-gui together; stop the server when the GUI
# closes.  Installed by "make install" as "scopebridge".
#
#   ./scopebridge.sh                  find the scope on USB
#   ./scopebridge.sh --usb /dev/usbtmc4
#   ./scopebridge.sh --lan 192.168.1.50
#   ./scopebridge.sh --sim            simulated scope, no hardware needed
#   ./scopebridge.sh --port 5027      server port (default 5026)
#   ./scopebridge.sh --web 8080       also the web interface, http://localhost:8080/
#   ./scopebridge.sh --host raspi     only the GUI, for a server on another
#                               computer (scopebridge-server --listen 0.0.0.0)
#
# If a server is already listening on the port, the GUI just connects
# to it and the script leaves it running.
#
# Options left out come from ~/.scopebridgerc: with [client] host set to
# another computer, only the GUI starts, connected there; otherwise the
# server here takes its [server] settings (source, port, web ...).
# Copyright (C) 2026 By Ulrik Hørlyk Hjort; MIT licence, see LICENSE.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# In the source tree the programs are in bin/; installed (as "scopebridge"),
# next to this script
if [ -x "$HERE/bin/scopebridge-server" ]; then BIN="$HERE/bin"; else BIN="$HERE"; fi
SERVER="$BIN/scopebridge-server"
GUI="$BIN/scopebridge-gui"
PORT=""
HOST=""
WEB=()
SOURCE=()

die() { echo "scopebridge.sh: $*" >&2; exit 1; }

# A setting from ~/.scopebridgerc ($SCOPEBRIDGE_RC instead; empty: none):
# rc SECTION KEY, empty if not set
RC="${SCOPEBRIDGE_RC-$HOME/.scopebridgerc}"
rc() {
    [ -n "$RC" ] && [ -r "$RC" ] || return 0
    awk -v section="$1" -v key="$2" '
        { sub(/#.*/, ""); gsub(/^[ \t]+|[ \t]+$/, "") }
        /^\[.*\]$/ { current = tolower(substr($0, 2, length($0) - 2)); next }
        current == section && index($0, "=") {
            k = tolower(substr($0, 1, index($0, "=") - 1)); gsub(/[ \t]+$/, "", k)
            v = substr($0, index($0, "=") + 1); gsub(/^[ \t]+/, "", v)
            if (k == key) value = v
        }
        END { print value }' "$RC"
}

while [ $# -gt 0 ]; do
    case "$1" in
        --usb|--lan) [ $# -ge 2 ] || die "$1 needs a value"
                     SOURCE=("$1" "$2"); shift 2 ;;
        --sim)       SOURCE=(--sim); shift ;;
        --port)      [ $# -ge 2 ] || die "--port needs a value"
                     PORT="$2"; shift 2 ;;
        --host)      [ $# -ge 2 ] || die "--host needs a value"
                     HOST="$2"; shift 2 ;;
        --web)       [ $# -ge 2 ] || die "--web needs a port"
                     WEB=(--web "$2"); shift 2 ;;
        -h|--help)   sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)           die "unknown argument $1 (try --help)" ;;
    esac
done

# A server on another computer, by --host or by [client] host (unless the
# options ask for a server here): just the GUI
if [ -z "$HOST" ] && [ ${#SOURCE[@]} -eq 0 ]; then
    case "$(rc client host)" in
        ""|127.0.0.1|localhost) ;;
        *) HOST="$(rc client host)" ;;
    esac
fi
if [ -n "$HOST" ]; then
    PORT="${PORT:-$(rc client port)}"
    PORT="${PORT:-5026}"
    [ ${#SOURCE[@]} -eq 0 ] ||
        die "--usb, --lan and --sim start a server here; with --host it runs on $HOST"
    [ -x "$GUI" ] || die "build first: make gui"
    exec "$GUI" --host "$HOST" --port "$PORT"
fi

[ -x "$SERVER" ] && [ -x "$GUI" ] || die "build first: make server gui"

# A server here: the port the options or [server] say. The GUI is told
# 127.0.0.1, or it would follow [client] host elsewhere.
PORT="${PORT:-$(rc server port)}"
PORT="${PORT:-5026}"

listening() { ss -ltnH "sport = :$PORT" 2>/dev/null | grep -q .; }

if listening; then
    echo "scopebridge.sh: a server is already listening on port $PORT; connecting to it"
    exec "$GUI" --host 127.0.0.1 --port "$PORT"
fi

# Find the scope, unless [server] says where it is: the usbtmc device
# whose USB vendor is Rigol (1ab1)
if [ ${#SOURCE[@]} -eq 0 ] && [ -z "$(rc server source)" ]; then
    for dev in /sys/class/usbmisc/usbtmc*; do
        [ -e "$dev" ] || continue
        if [ "$(cat "$dev/device/../idVendor" 2>/dev/null)" = "1ab1" ]; then
            SOURCE=(--usb "/dev/$(basename "$dev")")
            break
        fi
    done
    [ ${#SOURCE[@]} -gt 0 ] ||
        die "no Rigol scope found on USB (is it on and connected?); try --sim or --lan HOST"
fi

LOG="$(mktemp "${TMPDIR:-/tmp}/scopebridge-server.XXXXXX.log")"
"$SERVER" "${SOURCE[@]}" --port "$PORT" "${WEB[@]}" >"$LOG" 2>&1 &
SERVER_PID=$!
trap 'kill "$SERVER_PID" 2>/dev/null || true; wait "$SERVER_PID" 2>/dev/null || true; rm -f "$LOG"' EXIT

# Wait for the server to listen, or to fail
for _ in $(seq 50); do
    grep -q "listening" "$LOG" && break
    kill -0 "$SERVER_PID" 2>/dev/null || { cat "$LOG" >&2; die "the server did not start"; }
    sleep 0.1
done
grep -q "listening" "$LOG" || { cat "$LOG" >&2; die "the server did not start within 5 s"; }
grep "scopebridge-server:" "$LOG"

"$GUI" --host 127.0.0.1 --port "$PORT"
