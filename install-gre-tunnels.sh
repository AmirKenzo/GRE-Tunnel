#!/bin/bash
# GRE Tunnels: single installer. Fetches/updates files from BASE_URL, then config menu + set node.
# Run as root. One-liner: curl -sL https://ak6.ir/ak/install-gre-tunnels.sh | sudo bash

set -e
VERSION="3.1"
BASE_URL="${GRE_INSTALL_URL:-https://ak6.ir/ak}"
INSTALLER_BIN="/usr/local/bin/install-gre-tunnels.sh"
CONFIG_DIR="/etc/gre-tunnels"
CONFIG="${CONFIG_DIR}/tunnels.conf"
NODE_FILE="${CONFIG_DIR}/node"
SETUP_SCRIPT="/usr/local/bin/setup-gre.sh"
CLI_SCRIPT="/usr/local/bin/gre-tunnels"
SERVICE_NAME="gre-tunnels@.service"
WORK="/tmp/gre-tunnels-install"

log()  { echo "[gre-install] $*"; }
err()  { echo "[gre-install] ERROR: $*" >&2; exit 1; }
check_root() { [ "$(id -u)" -eq 0 ] || err "Run as root: sudo $0"; }
# When run as curl | bash, stdin is the script; read from terminal
read_input() { if [ -e /dev/tty ]; then read -r "$@" </dev/tty; else read -r "$@"; fi; }

# --- Fetch and install files from BASE_URL ---
fetch_and_install() {
  mkdir -p "$WORK"/etc/gre-tunnels "$WORK"/etc/systemd/system "$WORK/usr-local-bin"
  mkdir -p "$CONFIG_DIR"
  echo "$BASE_URL" > "$CONFIG_DIR/base_url" 2>/dev/null || true

  log "Fetching from $BASE_URL ..."
  curl -sSL -o "$WORK/install-gre-tunnels.sh" "$BASE_URL/install-gre-tunnels.sh" 2>/dev/null || true
  curl -sSL -o "$WORK/usr-local-bin/setup-gre.sh" "$BASE_URL/usr-local-bin/setup-gre.sh" 2>/dev/null || true
  curl -sSL -o "$WORK/usr-local-bin/gre-tunnels"  "$BASE_URL/usr-local-bin/gre-tunnels" 2>/dev/null || true
  curl -sSL -o "$WORK/etc/gre-tunnels/tunnels.conf.example" "$BASE_URL/etc/gre-tunnels/tunnels.conf.example" 2>/dev/null || true
  curl -sSL -o "$WORK/etc/systemd/system/gre-tunnels@.service" "$BASE_URL/etc/systemd/system/gre-tunnels%40.service" 2>/dev/null || true

  for f in "$WORK/usr-local-bin/setup-gre.sh" "$WORK/usr-local-bin/gre-tunnels"; do
    [ -f "$f" ] && sed -i 's/\r$//' "$f" 2>/dev/null || true
  done

  if [ -f "$WORK/usr-local-bin/setup-gre.sh" ]; then
    cp "$WORK/usr-local-bin/setup-gre.sh" "$SETUP_SCRIPT"
    chmod +x "$SETUP_SCRIPT"
    log "Installed $SETUP_SCRIPT"
  else
    err "Could not fetch setup-gre.sh from $BASE_URL"
  fi

  if [ -f "$WORK/usr-local-bin/gre-tunnels" ]; then
    cp "$WORK/usr-local-bin/gre-tunnels" "$CLI_SCRIPT"
    chmod +x "$CLI_SCRIPT"
    log "Installed $CLI_SCRIPT"
  fi

  if [ -f "$WORK/etc/systemd/system/gre-tunnels@.service" ]; then
    cp "$WORK/etc/systemd/system/gre-tunnels@.service" "/etc/systemd/system/$SERVICE_NAME"
    systemctl daemon-reload
    log "Installed systemd $SERVICE_NAME"
  fi

  if [ -f "$WORK/etc/gre-tunnels/tunnels.conf.example" ]; then
    cp "$WORK/etc/gre-tunnels/tunnels.conf.example" "$CONFIG_DIR/tunnels.conf.example"
    if [ ! -f "$CONFIG" ]; then
      cp "$CONFIG_DIR/tunnels.conf.example" "$CONFIG"
      log "Created $CONFIG from example"
    fi
  fi

  if [ -f "$WORK/install-gre-tunnels.sh" ]; then
    sed -i 's/\r$//' "$WORK/install-gre-tunnels.sh" 2>/dev/null || true
    cp "$WORK/install-gre-tunnels.sh" "$INSTALLER_BIN"
    chmod +x "$INSTALLER_BIN"
    log "Installed $INSTALLER_BIN"
  fi

  rm -rf "$WORK"
}

# --- List entries from config (trim spaces) ---
list_irans()    { awk '/^\[irans\]/{s=1;next} /^\[/{s=0} s&&/=/{gsub(/^[ \t]+|[ \t]+$/,"");sub(/=.*/,"");if($0)print}' "$CONFIG" 2>/dev/null; }
list_externals(){ awk '/^\[externals\]/{s=1;next} /^\[/{s=0} s&&/=/{gsub(/^[ \t]+|[ \t]+$/,"");sub(/=.*/,"");if($0)print}' "$CONFIG" 2>/dev/null; }
list_tunnels()  { awk '/^\[tunnels\]/{s=1;next} /^\[/{s=0} s&&/./{gsub(/^[ \t]+|[ \t]+$/,"");if($0~/,/)print}' "$CONFIG" 2>/dev/null; }


# --- Config: add Iran ---
config_add_iran() {
  local name ip
  read_input -p "Iran name (e.g. iran1): " name
  name="${name// /}"
  [ -z "$name" ] && return
  list_irans | grep -Fxq "$name" && { echo "Already exists: $name"; return; }
  read_input -p "Public IP: " ip
  ip="${ip// /}"
  [ -z "$ip" ] && return
  awk '/^\[irans\]/{s=1;print;next} /^\[externals\]/ && s{print "'"$name"'='"$ip"'";print;s=0;next} s && /^[ \t]*$/{next} {print}' "$CONFIG" > "$CONFIG.tmp" && mv "$CONFIG.tmp" "$CONFIG"
  echo "Added iran $name=$ip"
}

# --- Config: remove Iran ---
config_remove_iran() {
  local name
  echo "Irans:"; list_irans | nl
  read_input -p "Name or number to remove: " name
  name="${name// /}"
  [ -z "$name" ] && return
  [[ "$name" =~ ^[0-9]+$ ]] && name=$(list_irans | sed -n "${name}p")
  [ -z "$name" ] && return
  awk -v n="$name" '
    /^\[irans\]/{sec="irans";print;next}
    /^\[externals\]/{sec="externals";print;next}
    /^\[tunnels\]/{sec="tunnels";print;next}
    /^\[/{sec="";print;next}
    sec=="irans" { t=$0; gsub(/^[ \t]+/,"",t); if(index(t,n"=")==1) next }
    sec=="tunnels" { t=$0; gsub(/^[ \t]+/,"",t); if(index(t,n",")==1) next }
    {print}
  ' "$CONFIG" > "$CONFIG.tmp" && mv "$CONFIG.tmp" "$CONFIG"
  echo "Removed $name"
}

# --- Config: add External ---
config_add_external() {
  local name ip
  read_input -p "External name (e.g. fl, gr1): " name
  name="${name// /}"
  [ -z "$name" ] && return
  list_externals | grep -Fxq "$name" && { echo "Already exists: $name"; return; }
  read_input -p "Public IP: " ip
  ip="${ip// /}"
  [ -z "$ip" ] && return
  awk '/^\[externals\]/{s=1;print;next} /^\[tunnels\]/ && s{print "'"$name"'='"$ip"'";print;s=0;next} s && /^[ \t]*$/{next} {print}' "$CONFIG" > "$CONFIG.tmp" && mv "$CONFIG.tmp" "$CONFIG"
  echo "Added external $name=$ip"
}

# --- Config: remove External ---
config_remove_external() {
  local name
  echo "Externals:"; list_externals | nl
  read_input -p "Name or number to remove: " name
  name="${name// /}"
  [ -z "$name" ] && return
  [[ "$name" =~ ^[0-9]+$ ]] && name=$(list_externals | sed -n "${name}p")
  [ -z "$name" ] && return
  awk -v n="$name" '
    /^\[irans\]/{sec="irans";print;next}
    /^\[externals\]/{sec="externals";print;next}
    /^\[tunnels\]/{sec="tunnels";print;next}
    /^\[/{sec="";print;next}
    sec=="externals" { t=$0; gsub(/^[ \t]+/,"",t); if(index(t,n"=")==1) next }
    sec=="tunnels" { t=$0; gsub(/^[ \t]+/,"",t); if((idx=index(t,","n)) && idx+length(n)==length(t)) next }
    {print}
  ' "$CONFIG" > "$CONFIG.tmp" && mv "$CONFIG.tmp" "$CONFIG"
  echo "Removed $name"
}

# --- Config: add tunnel ---
config_add_tunnel() {
  local raw_iran raw_ext iran ext
  echo "Irans:"; list_irans | nl
  read_input -p "Iran (name or number): " raw_iran
  raw_iran="${raw_iran// /}"
  [[ "$raw_iran" =~ ^[0-9]+$ ]] && iran=$(list_irans | sed -n "${raw_iran}p") || iran="$raw_iran"
  iran="${iran// /}"
  echo "Externals:"; list_externals | nl
  read_input -p "External (name or number): " raw_ext
  raw_ext="${raw_ext// /}"
  [[ "$raw_ext" =~ ^[0-9]+$ ]] && ext=$(list_externals | sed -n "${raw_ext}p") || ext="$raw_ext"
  ext="${ext// /}"
  [ -z "$iran" ] || [ -z "$ext" ] && { echo "Invalid."; return; }
  if ! list_irans | grep -Fxq "$iran"; then echo "Unknown iran: $iran"; return; fi
  if ! list_externals | grep -Fxq "$ext"; then echo "Unknown external: $ext"; return; fi
  if grep -q "^[[:space:]]*${iran},${ext}[[:space:]]*$" "$CONFIG" 2>/dev/null; then echo "Tunnel already exists"; return; fi
  awk '/^\[tunnels\]/{s=1;print;print "'"$iran"','"$ext"'";next} s && /^[ \t]*$/{next} {print}' "$CONFIG" > "$CONFIG.tmp" && mv "$CONFIG.tmp" "$CONFIG"
  echo "Added tunnel $iran -> $ext"
}

# --- Config: remove tunnel ---
config_remove_tunnel() {
  local line to_remove
  echo "Tunnels:"; list_tunnels | nl
  read_input -p "Line number or exact iran,external to remove: " line
  line="${line// /}"
  [ -z "$line" ] && return
  if [[ "$line" =~ ^[0-9]+$ ]]; then
    to_remove=$(list_tunnels | sed -n "${line}p")
    [ -z "$to_remove" ] && { echo "Invalid number."; return; }
  else
    to_remove="$line"
  fi
  awk -v t="$to_remove" '
    /^\[tunnels\]/{sec=1;print;next}
    /^\[/{sec=0;print;next}
    sec { gsub(/^[ \t]+|[ \t]+$/,""); if ($0==t) next; print; next }
    {print}
  ' "$CONFIG" > "$CONFIG.tmp" && mv "$CONFIG.tmp" "$CONFIG"
  echo "Removed tunnel"
}

# --- Config: show ---
config_show() {
  echo "--- $CONFIG ---"
  cat "$CONFIG"
}

# --- Show running tunnels for this node with local IPs ---
show_tunnels_with_ips() {
  local node tid line iran ext iran_ip ext_ip shown
  [ -f "$CONFIG" ] || { echo "No config."; return; }
  if [ -f "$NODE_FILE" ]; then
    node=$(cat "$NODE_FILE")
  else
    read_input -p "Node name (this server): " node
    node="${node// /}"
  fi
  [ -z "$node" ] && return
  echo ""
  echo "Running tunnels for node: $node (local = this server)"
  echo "---------------------------------------------------"
  tid=0
  shown=0
  while IFS= read -r line; do
    line="${line%%#*}"
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [[ "$line" != *","* ]] && continue
    (( tid++ )) || true
    ip link show "gre${tid}" &>/dev/null || continue
    iran="${line%%,*}"; ext="${line#*,}"
    iran="${iran%"${iran##*[![:space:]]}"}"
    ext="${ext#"${ext%%[![:space:]]*}"}"
    iran_ip=$(awk -v n="$iran" '/^\[irans\]/{s=1;next} /^\[/{s=0} s && index($0,n"=")==1{gsub(/^[^=]*=/,"");print;exit}' "$CONFIG")
    ext_ip=$(awk -v n="$ext" '/^\[externals\]/{s=1;next} /^\[/{s=0} s && index($0,n"=")==1{gsub(/^[^=]*=/,"");print;exit}' "$CONFIG")
    if [[ "$node" == "$iran" ]]; then
      echo "  tunnel$tid: $iran -> $ext  |  local 10.10.$tid.1  |  remote 10.10.$tid.2 ($ext_ip)"
    elif [[ "$node" == "$ext" ]]; then
      echo "  tunnel$tid: $iran -> $ext  |  local 10.10.$tid.2  |  remote 10.10.$tid.1 ($iran_ip)"
    fi
    (( shown++ )) || true
  done < <(awk '/^\[tunnels\]/{s=1;next} /^\[/{s=0} s' "$CONFIG")
  [ "$shown" -eq 0 ] 2>/dev/null && echo "  (no tunnels running; start with option 2 or restart)"
  echo ""
}

# --- Config menu ---
config_menu() {
  [ -f "$CONFIG" ] || { err "No $CONFIG (run install first)"; }
  while true; do
    echo ""
    echo "  1) Add Iran"
    echo "  2) Remove Iran"
    echo "  3) Add External"
    echo "  4) Remove External"
    echo "  5) Add tunnel"
    echo "  6) Remove tunnel"
    echo "  7) Show config"
    echo "  8) Show my tunnels (IPs)"
    echo "  0) Back"
    echo ""
    read_input -p "Choice: " c
    case "${c}" in
      0) return ;;
      1) config_add_iran ;;
      2) config_remove_iran ;;
      3) config_add_external ;;
      4) config_remove_external ;;
      5) config_add_tunnel ;;
      6) config_remove_tunnel ;;
      7) config_show ;;
      8) show_tunnels_with_ips ;;
      *) echo "0-8";;
    esac
  done
}

# --- Set this server's node and start ---
set_node_and_start() {
  [ -f "$CONFIG" ] || err "No $CONFIG. Run config menu first or create from example."
  echo ""
  echo "Nodes in config:"
  { list_irans; list_externals; } | sort -u
  echo ""
  read_input -p "This server node name: " NODE
  NODE="${NODE// /}"
  [ -z "$NODE" ] && { echo "Cancelled"; return; }
  if ! { list_irans; list_externals; } | grep -Fxq "$NODE"; then
    read_input -p "Node '$NODE' not in config. Continue? [y/N]: " y
    [[ "${y,,}" != "y" ]] && return
  fi
  echo "$NODE" > "$NODE_FILE"
  log "This server is node: $NODE"
  systemctl enable "gre-tunnels@${NODE}"
  systemctl restart "gre-tunnels@${NODE}"
  log "Started gre-tunnels@${NODE}"
  systemctl status "gre-tunnels@${NODE}" --no-pager || true
}

# --- Main ---
main() {
  check_root
  echo "=============================================="
  echo "  GRE Tunnels Installer  v${VERSION}"
  echo "=============================================="

  if [[ "$1" != "--menu-only" ]]; then
    fetch_and_install
    [ -x "$CLI_SCRIPT" ] && exec "$CLI_SCRIPT"
  fi

  while true; do
    echo ""
    echo "  1) Manage config (add/remove Iran, External, tunnels)"
    echo "  2) Set this server's node and start service"
    echo "  0) Exit"
    echo ""
    read_input -p "Choice: " c
    case "${c}" in
      0) log "Done. Run: gre-tunnels"; exit 0 ;;
      1) config_menu ;;
      2) set_node_and_start ;;
      *) echo "0-2";;
    esac
  done
}

main "$@"
