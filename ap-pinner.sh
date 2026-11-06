#!/usr/bin/env bash
# ap-pinner — keep a Wi-Fi client on ONE access point, on OpenWrt networks
#
# THE PROBLEM
# Cheap IoT devices (Shelly, ESP-based switches, IP cameras) do NOT roam. They
# stick to the access point they first associated with, and when that node is
# the busiest or the furthest away, the device appears and disappears in the app.
# Booting it, power-cycling it or deauthenticating it (`iw station del`) only
# moves it temporarily: it re-associates with whichever AP has the strongest
# signal — almost always the one you just kicked it off.
#
# THE FIX
# Deny the client's MAC on every radio of the access points where it must NOT
# live (`macfilter=deny` + `maclist`). The client can then only associate with
# the AP you allow. The rule survives reboots and firmware updates because it
# lives in /etc/config/wireless.
#
# THE COST — read this before running it
# Applying a macfilter requires `wifi reload` on that node: 15-20 seconds in
# which EVERY client of that node drops. On a wireless-uplinked AP this can also
# drop the link you are connected through, which is why the reload is launched
# detached, in the background.
#
# USAGE
#   cp examples/devices.conf mydevices.conf   # edit it
#   ./ap-pinner.sh --config mydevices.conf                 # dry run (default)
#   ./ap-pinner.sh --config mydevices.conf --apply         # apply
#   ./ap-pinner.sh --config mydevices.conf --revert        # remove the filters
#
# Every run backs up /etc/config/wireless on each node to
# /root/wireless.bak.appinner.<date> and never overwrites an older backup.
set -uo pipefail

CONFIG=""; APPLY=0; REVERT=0
while [ $# -gt 0 ]; do
  case "$1" in
    --config) CONFIG="${2:-}"; shift 2;;
    --apply) APPLY=1; shift;;
    --revert) REVERT=1; APPLY=1; shift;;
    -h|--help) sed -n '2,30p' "$0"; exit 0;;
    *) echo "unknown option: $1" >&2; exit 2;;
  esac
done
[ -z "$CONFIG" ] && { echo "missing --config (see examples/devices.conf)" >&2; exit 2; }
[ -f "$CONFIG" ] || { echo "config not found: $CONFIG" >&2; exit 2; }

# shellcheck disable=SC1090
source "$CONFIG"

: "${GATEWAY_HOST:?set GATEWAY_HOST}"
: "${AP_NODES:?set AP_NODES, e.g. \"1=192.168.1.2 2=192.168.1.3\"}"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/id_ed25519}"
SSH_KEY_AP="${SSH_KEY_AP:-$SSH_KEY}"
GATEWAY_PORT="${GATEWAY_PORT:-22}"
GATEWAY_USER="${GATEWAY_USER:-root}"
BASE_PORT="${BASE_PORT:-2202}"        # local forwards are BASE_PORT + index
BACKUP_MARK="${BACKUP_MARK:-appinner}"
SETTLE="${SETTLE:-25}"                # seconds to wait after a wifi reload
RADIOS="${RADIOS:-radio0 radio1 radio2}"
DEVICES="${DEVICES:?set DEVICES, one per line: name|mac|ap_index}"

SSH_OPT="-o StrictHostKeyChecking=accept-new -o BatchMode=yes -o ConnectTimeout=10"
ap() { ssh -n -i "$SSH_KEY_AP" -p "$1" $SSH_OPT "root@127.0.0.1" "$2" 2>/dev/null; }

# --- build index -> ip and index -> local port maps
declare -A IP_OF PORT_OF
BASTION=""
i=1
for pair in $AP_NODES; do
  idx="${pair%%=*}"; ip="${pair#*=}"
  [ "$idx" = "${pair}" ] && { echo "bad AP_NODES entry: $pair" >&2; exit 2; }
  IP_OF[$idx]="$ip"
  PORT_OF[$idx]="$((BASE_PORT + i - 1))"
  BASTION="$BASTION -L $((BASE_PORT + i - 1)):$ip:22"
  i=$((i+1))
done

# --- open the tunnels through the gateway
echo "→ opening tunnels through $GATEWAY_USER@$GATEWAY_HOST:$GATEWAY_PORT"
# shellcheck disable=SC2086
ssh -f -N -i "$SSH_KEY" -p "$GATEWAY_PORT" $SSH_OPT $BASTION "$GATEWAY_USER@$GATEWAY_HOST" || {
  echo "could not open the SSH tunnels (wrong key, host or hop not reachable)" >&2; exit 1; }
sleep 2
trap 'pkill -f "L ${BASE_PORT}:.*:22" 2>/dev/null' EXIT

for idx in "${!IP_OF[@]}"; do
  P="${PORT_OF[$idx]}"
  if [ "$REVERT" = "1" ]; then
    echo "── AP $idx (${IP_OF[$idx]}): restoring backup"
    ap "$P" 'B=$(ls -1t /root/wireless.bak.'"$BACKUP_MARK"'.* 2>/dev/null | head -1)
             if [ -n "$B" ]; then cp "$B" /etc/config/wireless && echo "restored $B"
             else echo "no backup found, nothing to restore"; fi
             (sleep 3; wifi reload) >/dev/null 2>&1 &'
    sleep "$SETTLE"
    continue
  fi

  echo "── AP $idx (${IP_OF[$idx]})"
  [ "$APPLY" = "1" ] && ap "$P" 'F=/root/wireless.bak.'"$BACKUP_MARK"'.$(date +%Y%m%d%H%M); [ -f "$F" ] || cp /etc/config/wireless "$F"'

  wanted_here=0
  while IFS='|' read -r name mac apidx; do
    [ -z "${mac:-}" ] && continue
    case "$name" in \#*) continue;; esac
    mac="$(echo "$mac" | tr 'A-Z' 'a-z' | tr -d ' ')"
    [ "$apidx" = "$idx" ] && { wanted_here=$((wanted_here+1)); continue; }
    if [ "$APPLY" = "1" ]; then
      # idempotent: add the MAC only if it is not already in the list
      for r in $RADIOS; do
        ap "$P" "uci get wireless.default_$r >/dev/null 2>&1 || exit 0
                 uci set wireless.default_$r.macfilter='deny'
                 uci get wireless.default_$r.maclist 2>/dev/null | grep -qi '$mac' || \
                   uci add_list wireless.default_$r.maclist='$mac'"
      done
      ap "$P" 'uci commit wireless'
      echo "   denied $name ($mac)"
    else
      echo "   would deny $name ($mac)"
    fi
  done <<< "$DEVICES"

  # an AP with no allowed device has nothing to change
  if [ "$wanted_here" -gt 0 ] && [ "$APPLY" = "1" ]; then
    ap "$P" '(sleep 3; wifi reload) >/dev/null 2>&1 & echo "   reload started"'
    sleep "$SETTLE"
  elif [ "$wanted_here" -eq 0 ] && [ "$APPLY" = "1" ]; then
    ap "$P" '(sleep 3; wifi reload) >/dev/null 2>&1 & echo "   reload started"'
    sleep "$SETTLE"
  fi
done

echo
echo "done · mode: $([ "$APPLY" = 1 ] && echo APPLIED || echo DRY-RUN)"
[ "$APPLY" = 0 ] && echo "add --apply to write the changes"
