#!/usr/bin/env bash
# GRE tunnel setup - reads /etc/gre-tunnels/tunnels.conf and brings up tunnels for NODE.
# Usage: setup-gre.sh <node_name> [stop]
# VERSION=3.1

set -e
NODE="${1:?Usage: setup-gre.sh <node_name> [stop]}"
CONFIG="${GRE_TUNNELS_CONFIG:-/etc/gre-tunnels/tunnels.conf}"

if [[ "$2" == "stop" || "$2" == "--stop" ]]; then
  for (( i = 1; i <= 64; i++ )); do
    ip link show "gre${i}" &>/dev/null && ip tunnel del "gre${i}" 2>/dev/null || true
  done
  echo "[gre-tunnels@${NODE}] Tunnels stopped."
  exit 0
fi

CONFIG_DIR="$(dirname "$CONFIG")"
log() { echo "[gre-tunnels@${NODE}] $*"; }
err() { echo "[gre-tunnels@${NODE}] ERROR: $*" >&2; exit 1; }

[ -f "$CONFIG" ] || err "Config not found: $CONFIG"

# Parse config into associative arrays (bash 4+)
declare -A IRANS EXTERNALS
declare -a TUNNEL_LIST
section=""
while IFS= read -r line || [ -n "$line" ]; do
  line="${line%%#*}"
  line="${line#"${line%%[![:space:]]*}"}"
  line="${line%"${line##*[![:space:]]}"}"
  [ -z "$line" ] && continue
  if [[ "$line" == [* ]]; then
    section="${line//[\[\]]}"
    continue
  fi
  if [[ "$line" == *=* ]]; then
    key="${line%%=*}"
    key="${key%"${key##*[![:space:]]}"}"
    val="${line#*=}"
    val="${val#"${val%%[![:space:]]*}"}"
    case "$section" in
      irans)   IRANS["$key"]="$val" ;;
      externals) EXTERNALS["$key"]="$val" ;;
    esac
  fi
  if [[ "$section" == tunnels && "$line" == *,* ]]; then
    a="${line%%,*}"
    b="${line#*,}"
    a="${a%"${a##*[![:space:]]}"}"
    b="${b#"${b%%[![:space:]]*}"}"
    TUNNEL_LIST+=( "${a},${b}" )
  fi
done < "$CONFIG"

# Build list of (tunnel_id, iran, external) for this node
declare -a MY_TUNNELS
tid=0
for pair in "${TUNNEL_LIST[@]}"; do
  iran="${pair%,*}"
  ext="${pair#*,}"
  (( tid++ )) || true
  local_ip="" remote_ip="" my_addr="" remote_addr=""
  if [[ "$NODE" == "$iran" ]]; then
    local_ip="${IRANS[$iran]}"
    remote_ip="${EXTERNALS[$ext]}"
    [ -z "$local_ip" ] && err "Iran $iran not in [irans]"
    [ -z "$remote_ip" ] && err "External $ext not in [externals]"
    my_addr="10.10.${tid}.1"
    remote_addr="10.10.${tid}.2"
    MY_TUNNELS+=( "$tid" "$local_ip" "$remote_ip" "$my_addr" "$remote_addr" )
  fi
  if [[ "$NODE" == "$ext" ]]; then
    local_ip="${EXTERNALS[$ext]}"
    remote_ip="${IRANS[$iran]}"
    [ -z "$local_ip" ] && err "External $ext not in [externals]"
    [ -z "$remote_ip" ] && err "Iran $iran not in [irans]"
    my_addr="10.10.${tid}.2"
    remote_addr="10.10.${tid}.1"
    MY_TUNNELS+=( "$tid" "$local_ip" "$remote_ip" "$my_addr" "$remote_addr" )
  fi
done

[ ${#MY_TUNNELS[@]} -eq 0 ] && err "No tunnels defined for node: $NODE"

# ip_forward
sysctl -w net.ipv4.ip_forward=1 2>/dev/null || true
grep -q 'net.ipv4.ip_forward=1' /etc/sysctl.conf 2>/dev/null || echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf

# Teardown old interfaces (gre1..gre64 so we remove stale if config shrank)
count=$((${#MY_TUNNELS[@]} / 5))
for (( i = 1; i <= 64; i++ )); do
  ip link show "gre${i}" &>/dev/null && ip tunnel del "gre${i}" 2>/dev/null || true
done

# Bring up tunnels
idx=0
num=1
while (( idx < ${#MY_TUNNELS[@]} )); do
  tid="${MY_TUNNELS[$((idx))]}"
  local_ip="${MY_TUNNELS[$((idx+1))]}"
  remote_ip="${MY_TUNNELS[$((idx+2))]}"
  my_addr="${MY_TUNNELS[$((idx+3))]}"
  remote_addr="${MY_TUNNELS[$((idx+4))]}"
  iface="gre${num}"
  ip tunnel add "$iface" mode gre local "$local_ip" remote "$remote_ip" ttl 255
  ip link set "$iface" up
  ip addr add "${my_addr}/30" dev "$iface"
  ip route add "${remote_addr}/32" dev "$iface"
  log "Up tunnel${num}: ${my_addr} <-> ${remote_addr} (${remote_ip})"
  (( idx += 5 )) || true
  (( num++ )) || true
done

log "Done. ${count} tunnel(s) up."
