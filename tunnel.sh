#!/usr/bin/env bash
#===============================================================================
#
#   GRE Tunnel Manager - Production-Grade Single-File Script
#   Author: Refactored for simplicity and reliability
#
#   Usage: sudo gretunnel
#          sudo gretunnel [command]
#
#   Commands: menu, status, start, stop, restart, logs, uninstall, version
#
#===============================================================================

set -euo pipefail

#===============================================================================
# GLOBAL VARIABLES
#===============================================================================

readonly VERSION="1.4"
readonly SCRIPT_NAME="$(basename "$0")"

# Resolve script path - handle piped execution (curl | bash) where $0 may be "bash"
_resolve_script_path() {
    local src="${BASH_SOURCE[0]:-$0}"
    [[ -z "$src" || "$src" == "bash" || "$src" == "-bash" ]] && echo "" && return
    if [[ -f "$src" ]]; then
        local res
        res="$(realpath "$src" 2>/dev/null)" || res="$(readlink -f "$src" 2>/dev/null)" || res="$(cd "$(dirname "$src")" 2>/dev/null && pwd)/$(basename "$src")"
        [[ -f "$res" ]] && echo "$res" || echo ""
    else
        echo ""
    fi
}
readonly SCRIPT_PATH="$(_resolve_script_path)"

# Default paths (can be overridden in config)
INSTALL_DIR="/usr/local/bin"
INSTALL_CMD="gretunnel"
CONFIG_DIR="/etc/gre-tunnels"
# URL to fetch script when running via curl|bash (override with GRE_INSTALL_URL env)
INSTALL_SCRIPT_URL="${GRE_INSTALL_URL:-https://raw.githubusercontent.com/AmirKenzo/GRE-Tunnel/refs/heads/main/tunnel.sh}"
CONFIG_FILE="${CONFIG_DIR}/tunnels.conf"
NODE_FILE="${CONFIG_DIR}/node"
PORT_FORWARDS_FILE="${CONFIG_DIR}/port-forwards.conf"
PORT_FORWARD_METHOD_FILE="${CONFIG_DIR}/port-forward-method"
RINETD_CONF="/etc/rinetd.conf"
LOG_FILE="/var/log/gre-tunnels.log"
SERVICE_NAME="gre-tunnels"
PORT_FORWARD_SERVICE_NAME="gre-tunnels-portfw"

# Color codes
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[0;33m'
readonly BLUE='\033[0;34m'
readonly MAGENTA='\033[0;35m'
readonly CYAN='\033[0;36m'
readonly WHITE='\033[0;37m'
readonly BOLD='\033[1m'
readonly NC='\033[0m'

# Box drawing (ASCII for compatibility with all terminals)
readonly BOX_TL="+"
readonly BOX_TR="+"
readonly BOX_BL="+"
readonly BOX_BR="+"
readonly BOX_H="-"
readonly BOX_V=" "
readonly LINE_H="-"
readonly LINE_SEP="-----------------------------------------------------------"

#===============================================================================
# UTILITY FUNCTIONS
#===============================================================================

# Colorize text output
colorize() {
    local color="$1"
    local text="$2"
    local style="${3:-normal}"
    
    local color_code=""
    case "$color" in
        red)     color_code="$RED" ;;
        green)   color_code="$GREEN" ;;
        yellow)  color_code="$YELLOW" ;;
        blue)    color_code="$BLUE" ;;
        magenta) color_code="$MAGENTA" ;;
        cyan)    color_code="$CYAN" ;;
        white)   color_code="$WHITE" ;;
        *)       color_code="$NC" ;;
    esac
    
    local style_code=""
    [[ "$style" == "bold" ]] && style_code="$BOLD"
    
    echo -e "${style_code}${color_code}${text}${NC}"
}

# Log message to file and optionally to stdout
log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp
    timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
    echo "[$timestamp] [$level] $message" >> "$LOG_FILE" 2>/dev/null || true
}

# Print info message
info() {
    colorize cyan "[INFO] $*"
    log "INFO" "$*"
}

# Print success message
success() {
    colorize green "[OK] $*" bold
    log "OK" "$*"
}

# Print warning message
warn() {
    colorize yellow "[WARN] $*"
    log "WARN" "$*"
}

# Print error message
error() {
    colorize red "[ERROR] $*" bold
    log "ERROR" "$*"
}

# Fatal error - print and exit
die() {
    error "$*"
    exit 1
}

# Press Enter to return to menu (prompt to stderr so it always shows)
press_key() {
    echo
    echo -ne "${YELLOW}Press Enter to return to menu...${NC} " >&2
    if [[ -e /dev/tty ]]; then
        read -r _dummy </dev/tty 2>/dev/null || read -r _dummy
    else
        read -r _dummy
    fi
}

# Read input safely (works with piped scripts)
read_input() {
    if [[ -e /dev/tty ]]; then
        read -r "$@" < /dev/tty
    else
        read -r "$@"
    fi
}

# Confirm action
confirm() {
    local prompt="${1:-Are you sure?}"
    local default="${2:-n}"
    local response
    
    if [[ "$default" == "y" ]]; then
        echo -ne "${YELLOW}${prompt} [Y/n]: ${NC}"
    else
        echo -ne "${YELLOW}${prompt} [y/N]: ${NC}"
    fi
    
    read_input response
    response="${response,,}"
    
    if [[ "$default" == "y" ]]; then
        [[ "$response" != "n" ]]
    else
        [[ "$response" == "y" ]]
    fi
}

# Clear screen and show header
clear_screen() {
    clear
    display_header
}

# Trim whitespace from string
trim() {
    local var="$*"
    var="${var#"${var%%[![:space:]]*}"}"
    var="${var%"${var##*[![:space:]]}"}"
    echo -n "$var"
}

#===============================================================================
# SYSTEM CHECKS
#===============================================================================

# Check if running as root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        die "This script must be run as root. Use: sudo $SCRIPT_NAME"
    fi
}

# Check operating system
check_os() {
    if [[ "$(uname)" != "Linux" ]]; then
        die "This script only supports Linux systems."
    fi
}

# Check required dependencies
check_dependencies() {
    local missing=()
    local deps=("ip" "systemctl" "awk" "grep" "sed")
    
    for cmd in "${deps[@]}"; do
        if ! command -v "$cmd" &>/dev/null; then
            missing+=("$cmd")
        fi
    done
    
    if [[ ${#missing[@]} -gt 0 ]]; then
        die "Missing dependencies: ${missing[*]}"
    fi
}

# Check if iproute2 supports GRE
check_gre_support() {
    if ! modprobe ip_gre &>/dev/null; then
        warn "GRE module not loaded. Attempting to load..."
        modprobe ip_gre || die "Failed to load GRE kernel module"
    fi
}

# Initialize environment
init_environment() {
    check_root
    check_os
    check_dependencies
    check_gre_support
    
    # Create directories if needed
    mkdir -p "$CONFIG_DIR"
    touch "$LOG_FILE" 2>/dev/null || true
    
    # Load config file if exists
    load_config
}

#===============================================================================
# DISPLAY FUNCTIONS
#===============================================================================

# Display ASCII logo
display_logo() {
    echo -e "${CYAN}"
    cat << 'EOF'
   _____ _____  ______   _______                      _ 
  / ____|  __ \|  ____| |__   __|                    | |
 | |  __| |__) | |__       | |_   _ _ __  _ __   ___| |
 | | |_ |  _  /|  __|      | | | | | '_ \| '_ \ / _ \ |
 | |__| | | \ \| |____     | | |_| | | | | | | |  __/ |
  \_____|_|  \_\______|    |_|\__,_|_| |_|_| |_|\___|_|
EOF
    echo -e "${NC}"
    echo -e "${GREEN}Version: ${YELLOW}v${VERSION}${NC}"
}

# Display header
display_header() {
    display_logo
    echo -e "${YELLOW}${LINE_SEP}${NC}"
}

# Count active (UP) tunnels for current node only
count_active_tunnels_for_node() {
    local node="$1"
    [[ -z "$node" || ! -f "$CONFIG_FILE" ]] && echo "0" && return
    local tunnel_id=0
    local count=0
    while IFS= read -r line; do
        line="${line%%#*}"
        line="$(trim "$line")"
        [[ -z "$line" || "$line" != *","* ]] && continue
        (( tunnel_id++ )) || true
        local iran="${line%%,*}"
        local ext="${line#*,}"
        iran="$(trim "$iran")"
        ext="$(trim "$ext")"
        [[ "$node" != "$iran" && "$node" != "$ext" ]] && continue
        ip link show "gre${tunnel_id}" &>/dev/null && (( count++ )) || true
    done < <(list_tunnels)
    echo "$count"
}

# Display current node and status
display_status_bar() {
    local node_name="Not Set"
    local service_status="${RED}Stopped${NC}"
    local tunnel_count=0
    
    if [[ -f "$NODE_FILE" ]]; then
        node_name="$(cat "$NODE_FILE" 2>/dev/null || echo "Not Set")"
    fi
    
    if systemctl is-active --quiet "${SERVICE_NAME}@${node_name}" 2>/dev/null; then
        service_status="${GREEN}Running${NC}"
        tunnel_count=$(count_active_tunnels_for_node "$node_name")
    fi
    
    echo -e "${CYAN}Node:${NC} ${WHITE}${node_name}${NC}  ${BOX_V}  ${CYAN}Status:${NC} ${service_status}  ${BOX_V}  ${CYAN}Tunnels:${NC} ${WHITE}${tunnel_count}${NC}"
    echo -e "${YELLOW}${LINE_SEP}${NC}"
}

# Strip ANSI escape codes for display length calculation
_strip_ansi() {
    printf '%s' "$1" | sed 's/\x1b\[[0-9;]*m//g'
}

# Display boxed menu
display_menu_box() {
    local title="$1"
    shift
    local options=("$@")
    local width=58
    
    echo
    # Top border
    echo -ne "${CYAN}${BOX_TL}"
    printf '%*s' "$width" | tr ' ' "$BOX_H"
    echo -e "${BOX_TR}${NC}"
    
    # Title
    local title_plain title_len padding
    title_plain=$(_strip_ansi "$title")
    title_len=${#title_plain}
    padding=$(( (width - title_len) / 2 ))
    echo -ne "${CYAN}${BOX_V}${NC}"
    printf '%*s' "$padding" ""
    echo -ne "${YELLOW}${BOLD}${title}${NC}"
    printf '%*s' $(( width - padding - title_len )) ""
    echo -e "${CYAN}${BOX_V}${NC}"
    
    # Separator
    echo -ne "${CYAN}${BOX_V}"
    printf '%*s' "$width" | tr ' ' "$LINE_H"
    echo -e "${BOX_V}${NC}"
    
    # Options (use visible length for padding, not including ANSI codes)
    for opt in "${options[@]}"; do
        local opt_plain opt_len
        opt_plain=$(_strip_ansi "$opt")
        opt_len=${#opt_plain}
        echo -ne "${CYAN}${BOX_V}${NC}  "
        echo -ne "${opt}"
        printf '%*s' $(( width - opt_len - 4 )) ""
        echo -e "${CYAN}${BOX_V}${NC}"
    done
    
    # Bottom border
    echo -ne "${CYAN}${BOX_BL}"
    printf '%*s' "$width" | tr ' ' "$BOX_H"
    echo -e "${BOX_BR}${NC}"
    echo
}

#===============================================================================
# CONFIG FILE MANAGEMENT
#===============================================================================

# Load configuration from file
load_config() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        return 0
    fi
    
    # Source any shell variables from config if present
    # (This allows overriding paths in config)
    while IFS='=' read -r key value; do
        key="$(trim "$key")"
        value="$(trim "$value")"
        [[ -z "$key" || "$key" == \#* || "$key" == \[* ]] && continue
        case "$key" in
            INSTALL_DIR) INSTALL_DIR="$value" ;;
            CONFIG_DIR)  CONFIG_DIR="$value" ;;
            LOG_FILE)    LOG_FILE="$value" ;;
        esac
    done < "$CONFIG_FILE"
}

# Create default config file
create_default_config() {
    if [[ -f "$CONFIG_FILE" ]]; then
        warn "Config file already exists: $CONFIG_FILE"
        return 0
    fi
    
    cat > "$CONFIG_FILE" << 'CONF'
#===============================================================================
# GRE Tunnel Configuration File
#===============================================================================
#
# This file defines all nodes and tunnel connections.
# Edit this file to add/remove servers and tunnels.
#
# Sections:
#   [settings]  - Script settings (optional)
#   [irans]     - Iran server nodes (name=public_ip)
#   [externals] - External server nodes (name=public_ip)
#   [tunnels]   - Tunnel connections (iran_name,external_name)
#
#===============================================================================

[settings]
# Uncomment to override default paths
# INSTALL_DIR=/usr/local/bin
# CONFIG_DIR=/etc/gre-tunnels
# LOG_FILE=/var/log/gre-tunnels.log

[irans]
# Define Iran servers here
# Format: name=public_ip
# Example:
# iran1=1.2.3.4
# iran2=5.6.7.8

[externals]
# Define External servers here
# Format: name=public_ip
# Example:
# germany1=9.10.11.12
# france1=13.14.15.16

[tunnels]
# Define tunnel connections here
# Format: iran_name,external_name
# Each tunnel gets a unique ID (1, 2, 3...)
# Iran side gets IP: 10.10.<id>.1
# External side gets IP: 10.10.<id>.2
# Example:
# iran1,germany1
# iran1,france1
# iran2,germany1

CONF
    
    success "Created default config: $CONFIG_FILE"
}

# Parse config and extract irans (exclude comment lines)
list_irans() {
    [[ ! -f "$CONFIG_FILE" ]] && return
    awk '/^\[irans\]/{s=1;next} /^\[/{s=0} s && /=/ && $0 !~ /^[ \t]*#/ {
        gsub(/^[ \t]+|[ \t]+$/,"")
        sub(/#.*/, ""); gsub(/[ \t]+$/, "")
        sub(/=.*/, "")
        gsub(/^[ \t]+|[ \t]+$/, "")
        if ($0) print
    }' "$CONFIG_FILE" 2>/dev/null
}

# Parse config and extract externals (exclude comment lines)
list_externals() {
    [[ ! -f "$CONFIG_FILE" ]] && return
    awk '/^\[externals\]/{s=1;next} /^\[/{s=0} s && /=/ && $0 !~ /^[ \t]*#/ {
        gsub(/^[ \t]+|[ \t]+$/,"")
        sub(/#.*/, ""); gsub(/[ \t]+$/, "")
        sub(/=.*/, "")
        gsub(/^[ \t]+|[ \t]+$/, "")
        if ($0) print
    }' "$CONFIG_FILE" 2>/dev/null
}

# Parse config and extract tunnels (exclude comment lines)
list_tunnels() {
    [[ ! -f "$CONFIG_FILE" ]] && return
    awk '/^\[tunnels\]/{s=1;next} /^\[/{s=0} s && /,/ && $0 !~ /^[ \t]*#/ {
        gsub(/^[ \t]+|[ \t]+$/,"")
        sub(/#.*/, ""); gsub(/[ \t]+$/, "")
        gsub(/^[ \t]+|[ \t]+$/, "")
        if ($0) print
    }' "$CONFIG_FILE" 2>/dev/null
}

# Get IP for a node name
get_node_ip() {
    local name="$1"
    local ip=""
    
    # Check irans first (skip comment lines)
    ip=$(awk -v n="$name" '
        /^\[irans\]/{s=1;next}
        /^\[/{s=0}
        s && $0 !~ /^[ \t]*#/ && /=/ {
            key=$0; sub(/=.*/, "", key); gsub(/^[ \t]+|[ \t]+$/, "", key)
            if (key == n) {
                gsub(/^[^=]*=/, "")
                sub(/#.*/, ""); gsub(/^[ \t]+|[ \t]+$/, "")
                print
                exit
            }
        }
    ' "$CONFIG_FILE" 2>/dev/null)
    
    if [[ -n "$ip" ]]; then
        echo "$ip"
        return
    fi
    
    # Check externals (skip comment lines)
    ip=$(awk -v n="$name" '
        /^\[externals\]/{s=1;next}
        /^\[/{s=0}
        s && $0 !~ /^[ \t]*#/ && /=/ {
            key=$0; sub(/=.*/, "", key); gsub(/^[ \t]+|[ \t]+$/, "", key)
            if (key == n) {
                gsub(/^[^=]*=/, "")
                sub(/#.*/, ""); gsub(/^[ \t]+|[ \t]+$/, "")
                print
                exit
            }
        }
    ' "$CONFIG_FILE" 2>/dev/null)
    
    echo "$ip"
}

# Check if node is iran type
is_iran_node() {
    local name="$1"
    list_irans | grep -Fxq "$name" 2>/dev/null
}

# Check if node is external type
is_external_node() {
    local name="$1"
    list_externals | grep -Fxq "$name" 2>/dev/null
}

#===============================================================================
# CONFIG EDITING FUNCTIONS
#===============================================================================

# Add iran node
config_add_iran() {
    local name ip
    
    echo
    echo -ne "${CYAN}Iran name (e.g. iran1): ${NC}"
    read_input name
    name="$(trim "$name")"
    [[ -z "$name" ]] && return
    
    if list_irans | grep -Fxq "$name"; then
        error "Iran '$name' already exists"
        return
    fi
    
    echo -ne "${CYAN}Public IP address: ${NC}"
    read_input ip
    ip="$(trim "$ip")"
    [[ -z "$ip" ]] && return
    
    # Validate IP format (basic)
    if ! [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        error "Invalid IP format: $ip"
        return
    fi
    
    # Add to config
    awk -v name="$name" -v ip="$ip" '
        /^\[irans\]/ { print; print name "=" ip; next }
        { print }
    ' "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
    
    success "Added Iran: $name = $ip"
}

# Remove iran node
config_remove_iran() {
    local name
    
    echo
    colorize cyan "Current Iran nodes:" bold
    list_irans | nl -w2 -s") "
    echo
    
    echo -ne "${CYAN}Name or number to remove: ${NC}"
    read_input name
    name="$(trim "$name")"
    [[ -z "$name" ]] && return
    
    # Convert number to name
    if [[ "$name" =~ ^[0-9]+$ ]]; then
        name=$(list_irans | sed -n "${name}p")
    fi
    [[ -z "$name" ]] && return
    
    # Remove from irans and related tunnels
    awk -v n="$name" '
        /^\[irans\]/ { sec="irans" }
        /^\[externals\]/ { sec="externals" }
        /^\[tunnels\]/ { sec="tunnels" }
        /^\[/ && !/^\[irans\]/ && !/^\[externals\]/ && !/^\[tunnels\]/ { sec="" }
        sec=="irans" && index($0, n"=") == 1 { next }
        sec=="tunnels" && index($0, n",") == 1 { next }
        { print }
    ' "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
    
    success "Removed Iran: $name"
}

# Add external node
config_add_external() {
    local name ip
    
    echo
    echo -ne "${CYAN}External name (e.g. germany1): ${NC}"
    read_input name
    name="$(trim "$name")"
    [[ -z "$name" ]] && return
    
    if list_externals | grep -Fxq "$name"; then
        error "External '$name' already exists"
        return
    fi
    
    echo -ne "${CYAN}Public IP address: ${NC}"
    read_input ip
    ip="$(trim "$ip")"
    [[ -z "$ip" ]] && return
    
    if ! [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        error "Invalid IP format: $ip"
        return
    fi
    
    awk -v name="$name" -v ip="$ip" '
        /^\[externals\]/ { print; print name "=" ip; next }
        { print }
    ' "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
    
    success "Added External: $name = $ip"
}

# Remove external node
config_remove_external() {
    local name
    
    echo
    colorize cyan "Current External nodes:" bold
    list_externals | nl -w2 -s") "
    echo
    
    echo -ne "${CYAN}Name or number to remove: ${NC}"
    read_input name
    name="$(trim "$name")"
    [[ -z "$name" ]] && return
    
    if [[ "$name" =~ ^[0-9]+$ ]]; then
        name=$(list_externals | sed -n "${name}p")
    fi
    [[ -z "$name" ]] && return
    
    awk -v n="$name" '
        /^\[irans\]/ { sec="irans" }
        /^\[externals\]/ { sec="externals" }
        /^\[tunnels\]/ { sec="tunnels" }
        /^\[/ && !/^\[irans\]/ && !/^\[externals\]/ && !/^\[tunnels\]/ { sec="" }
        sec=="externals" && index($0, n"=") == 1 { next }
        sec=="tunnels" && $0 ~ "," n "$" { next }
        { print }
    ' "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
    
    success "Removed External: $name"
}

# Add tunnel
config_add_tunnel() {
    local iran_input ext_input iran ext
    
    echo
    colorize cyan "Iran nodes:" bold
    list_irans | nl -w2 -s") "
    echo
    echo -ne "${CYAN}Iran (name or number): ${NC}"
    read_input iran_input
    iran_input="$(trim "$iran_input")"
    
    if [[ "$iran_input" =~ ^[0-9]+$ ]]; then
        iran=$(list_irans | sed -n "${iran_input}p")
    else
        iran="$iran_input"
    fi
    
    if [[ -z "$iran" ]] || ! list_irans | grep -Fxq "$iran"; then
        error "Invalid Iran node: $iran_input"
        return
    fi
    
    echo
    colorize cyan "External nodes:" bold
    list_externals | nl -w2 -s") "
    echo
    echo -ne "${CYAN}External (name or number): ${NC}"
    read_input ext_input
    ext_input="$(trim "$ext_input")"
    
    if [[ "$ext_input" =~ ^[0-9]+$ ]]; then
        ext=$(list_externals | sed -n "${ext_input}p")
    else
        ext="$ext_input"
    fi
    
    if [[ -z "$ext" ]] || ! list_externals | grep -Fxq "$ext"; then
        error "Invalid External node: $ext_input"
        return
    fi
    
    # Check if tunnel already exists
    if grep -q "^[[:space:]]*${iran},${ext}[[:space:]]*$" "$CONFIG_FILE" 2>/dev/null; then
        error "Tunnel already exists: $iran -> $ext"
        return
    fi
    
    awk -v iran="$iran" -v ext="$ext" '
        /^\[tunnels\]/ { print; print iran "," ext; next }
        { print }
    ' "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
    
    success "Added tunnel: $iran -> $ext"
}

# Remove tunnel
config_remove_tunnel() {
    local line_input tunnel
    
    echo
    colorize cyan "Current tunnels:" bold
    list_tunnels | nl -w2 -s") "
    echo
    
    echo -ne "${CYAN}Line number or exact tunnel (iran,external): ${NC}"
    read_input line_input
    line_input="$(trim "$line_input")"
    [[ -z "$line_input" ]] && return
    
    if [[ "$line_input" =~ ^[0-9]+$ ]]; then
        tunnel=$(list_tunnels | sed -n "${line_input}p")
    else
        tunnel="$line_input"
    fi
    
    [[ -z "$tunnel" ]] && return
    
    awk -v t="$tunnel" '
        /^\[tunnels\]/ { sec=1 }
        /^\[/ && !/^\[tunnels\]/ { sec=0 }
        sec { 
            gsub(/^[ \t]+|[ \t]+$/, "")
            if ($0 == t) next
        }
        { print }
    ' "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
    
    success "Removed tunnel: $tunnel"
}

# Show full config
config_show() {
    echo
    colorize cyan "Configuration File: $CONFIG_FILE" bold
    echo -e "${YELLOW}${LINE_SEP}${NC}"
    cat "$CONFIG_FILE"
    echo -e "${YELLOW}${LINE_SEP}${NC}"
}

# Load config from file: submenu (nano edit default OR load from path)
load_config_from_file() {
    echo
    echo -e "${CYAN}Load / edit config:${NC}"
    echo -e "  ${GREEN}1)${NC} Edit default config with nano (${CONFIG_FILE})"
    echo -e "  ${GREEN}2)${NC} Load from file path (replace current config)"
    echo -e "  ${WHITE}0)${NC} Back"
    echo -ne "${CYAN}Choice [0-2]: ${NC}"
    local sub
    read_input sub
    sub="$(trim "$sub")"

    [[ "$sub" == "0" ]] && return

    if [[ "$sub" == "1" ]]; then
        if [[ ! -f "$CONFIG_FILE" ]]; then
            create_default_config
        fi
        if ! command -v nano &>/dev/null; then
            error "nano not found. Install nano or use option 2 with a file path."
            return
        fi
        if [[ ! -e /dev/tty ]]; then
            error "No TTY. Run from an interactive terminal or use option 2 (load from file path)."
            return
        fi
        nano "$CONFIG_FILE" </dev/tty >/dev/tty
        success "Config edited."
        if [[ -f "$NODE_FILE" ]]; then
            local node
            node="$(cat "$NODE_FILE")"
            if confirm "Restart tunnels with new config? [y/N]"; then
                restart_service "$node"
            fi
        fi
        return
    fi

    if [[ "$sub" != "2" ]]; then
        return
    fi

    echo
    echo -ne "${CYAN}Path to config file (will replace ${CONFIG_FILE}): ${NC}"
    local path
    read_input path
    path="${path// /}"
    path="${path/#\~/$HOME}"
    path="$(trim "$path")"

    [[ -z "$path" ]] && return

    if [[ ! -f "$path" ]]; then
        error "File not found: $path"
        return
    fi

    cp "$path" "$CONFIG_FILE"
    success "Config loaded from $path"

    if [[ -f "$NODE_FILE" ]]; then
        local node
        node="$(cat "$NODE_FILE")"
        if confirm "Restart tunnels with new config? [y/N]"; then
            restart_service "$node"
        fi
    fi
}

# Remove all tunnels (stop service, teardown interfaces) - keeps config and script
remove_all_tunnels() {
    echo
    if ! confirm "Stop all tunnels and disable service? Config and script will be kept."; then
        return
    fi
    
    local node=""
    if [[ -f "$NODE_FILE" ]]; then
        node="$(cat "$NODE_FILE")"
        systemctl stop "${SERVICE_NAME}@${node}" 2>/dev/null || true
        systemctl disable "${SERVICE_NAME}@${node}" 2>/dev/null || true
    fi
    
    teardown_tunnels
    rm -f "$NODE_FILE"
    success "All tunnels removed. Config and script preserved."
}

#===============================================================================
# PORT FORWARDING
#===============================================================================
# Config: PORT_FORWARDS_FILE, one line per forward: listen_ip listen_port dest_ip dest_port
# Method: iptables (nat DNAT) or rinetd (apt install rinetd)

pf_get_method() {
    if [[ -f "$PORT_FORWARD_METHOD_FILE" ]]; then
        trim "$(cat "$PORT_FORWARD_METHOD_FILE" 2>/dev/null)"
    else
        echo ""
    fi
}

pf_set_method() {
    local m="$1"
    [[ "$m" != "iptables" && "$m" != "rinetd" ]] && return 1
    mkdir -p "$CONFIG_DIR"
    echo "$m" > "$PORT_FORWARD_METHOD_FILE"
    return 0
}

pf_list_entries() {
    [[ ! -f "$PORT_FORWARDS_FILE" ]] && return
    grep -v '^[[:space:]]*#' "$PORT_FORWARDS_FILE" 2>/dev/null | grep -v '^[[:space:]]*$'
}

# Remove our iptables rules (when switching to rinetd or clearing)
pf_teardown_iptables() {
    local chain="GRE_FWD"
    local fwd_chain="GRE_FWD_FWD"
    local masq_chain="GRE_FWD_MASQ"
    iptables -t nat -D PREROUTING -j "$chain" 2>/dev/null || true
    iptables -t nat -D OUTPUT -j "$chain" 2>/dev/null || true
    iptables -t nat -F "$chain" 2>/dev/null || true
    iptables -t nat -X "$chain" 2>/dev/null || true
    iptables -t nat -D POSTROUTING -j "$masq_chain" 2>/dev/null || true
    iptables -t nat -F "$masq_chain" 2>/dev/null || true
    iptables -t nat -X "$masq_chain" 2>/dev/null || true
    iptables -D FORWARD -j "$fwd_chain" 2>/dev/null || true
    iptables -F "$fwd_chain" 2>/dev/null || true
    iptables -X "$fwd_chain" 2>/dev/null || true
    if command -v netfilter-persistent &>/dev/null; then
        netfilter-persistent save 2>/dev/null || true
    fi
}

pf_apply_iptables() {
    local chain="GRE_FWD"
    local fwd_chain="GRE_FWD_FWD"
    local masq_chain="GRE_FWD_MASQ"
    enable_ip_forward
    systemctl stop rinetd 2>/dev/null || true
    # Create and flush our nat chain
    iptables -t nat -N "$chain" 2>/dev/null || true
    iptables -t nat -F "$chain" 2>/dev/null || true
    iptables -t nat -N "$masq_chain" 2>/dev/null || true
    iptables -t nat -F "$masq_chain" 2>/dev/null || true
    # Create and flush our filter chain for FORWARD
    iptables -N "$fwd_chain" 2>/dev/null || true
    iptables -F "$fwd_chain" 2>/dev/null || true
    while IFS= read -r line; do
        line="$(trim "$line")"
        [[ -z "$line" || "$line" == \#* ]] && continue
        set -- $line
        [[ $# -lt 4 ]] && continue
        local listen_ip="$1" listen_port="$2" dest_ip="$3" dest_port="$4"
        iptables -t nat -A "$chain" -p tcp -d "$listen_ip" --dport "$listen_port" -j DNAT --to-destination "${dest_ip}:${dest_port}"
        iptables -t nat -A "$masq_chain" -p tcp -d "$dest_ip" --dport "$dest_port" -j MASQUERADE
        iptables -A "$fwd_chain" -p tcp -d "$dest_ip" --dport "$dest_port" -j ACCEPT
        iptables -A "$fwd_chain" -p tcp -s "$dest_ip" -j ACCEPT
    done < <(pf_list_entries)
    iptables -t nat -C PREROUTING -j "$chain" 2>/dev/null || iptables -t nat -A PREROUTING -j "$chain"
    iptables -t nat -C OUTPUT -j "$chain" 2>/dev/null || iptables -t nat -A OUTPUT -j "$chain"
    iptables -t nat -C POSTROUTING -j "$masq_chain" 2>/dev/null || iptables -t nat -A POSTROUTING -j "$masq_chain"
    iptables -C FORWARD -j "$fwd_chain" 2>/dev/null || iptables -A FORWARD -j "$fwd_chain"
    if command -v iptables-save &>/dev/null && [[ -d /etc/iptables ]]; then
        iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
    fi
    if command -v netfilter-persistent &>/dev/null; then
        netfilter-persistent save 2>/dev/null || true
    fi
}

pf_apply_rinetd() {
    if ! command -v rinetd &>/dev/null; then
        warn "rinetd not installed. Run: apt install rinetd -y"
        return 1
    fi
    pf_teardown_iptables
    systemctl stop rinetd 2>/dev/null || service rinetd stop 2>/dev/null || true
    # rinetd format: bindaddress bindport connectaddress connectport
    : > "$RINETD_CONF"
    while IFS= read -r line; do
        line="$(trim "$line")"
        [[ -z "$line" || "$line" == \#* ]] && continue
        set -- $line
        [[ $# -lt 4 ]] && continue
        echo "$1 $2 $3 $4" >> "$RINETD_CONF"
    done < <(pf_list_entries)
    systemctl start rinetd 2>/dev/null || service rinetd start 2>/dev/null || true
    systemctl enable rinetd 2>/dev/null || true
}

pf_apply() {
    local method
    method="$(pf_get_method)"
    if [[ -z "$method" ]]; then
        [[ -t 1 ]] && error "Port forward method not set. Choose iptables or rinetd in menu."
        return 0
    fi
    if [[ "$method" == "iptables" ]]; then
        pf_apply_iptables
        [[ -t 1 ]] && success "Port forwards applied (iptables)."
    else
        pf_apply_rinetd
        [[ -t 1 ]] && success "Port forwards applied (rinetd)."
    fi
    return 0
}

pf_add() {
    echo
    echo -ne "${CYAN}Listen IP (e.g. 0.0.0.0): ${NC}"
    read_input listen_ip
    listen_ip="$(trim "$listen_ip")"
    echo -ne "${CYAN}Listen port: ${NC}"
    read_input listen_port
    listen_port="$(trim "$listen_port")"
    echo -ne "${CYAN}Destination IP (e.g. 10.30.31.2): ${NC}"
    read_input dest_ip
    dest_ip="$(trim "$dest_ip")"
    echo -ne "${CYAN}Destination port: ${NC}"
    read_input dest_port
    dest_port="$(trim "$dest_port")"
    [[ -z "$listen_ip" || -z "$listen_port" || -z "$dest_ip" || -z "$dest_port" ]] && { error "All fields required."; return; }
    if ! [[ "$listen_port" =~ ^[0-9]+$ ]] || ! [[ "$dest_port" =~ ^[0-9]+$ ]]; then
        error "Ports must be numbers."
        return
    fi
    mkdir -p "$CONFIG_DIR"
    echo "${listen_ip} ${listen_port} ${dest_ip} ${dest_port}" >> "$PORT_FORWARDS_FILE"
    success "Added: ${listen_ip}:${listen_port} -> ${dest_ip}:${dest_port}"
    pf_apply
}

pf_get_line_number() {
    local n="$1"
    awk '/^[[:space:]]*#/ || /^[[:space:]]*$/ {next} {c++; if (c=='"$n"') {print NR; exit}}' "$PORT_FORWARDS_FILE"
}

pf_delete() {
    [[ ! -f "$PORT_FORWARDS_FILE" ]] || [[ -z "$(pf_list_entries)" ]] && { colorize yellow "No port forwards defined."; return; }
    echo
    pf_show_list
    echo
    echo -ne "${CYAN}Entry number to delete (0 = cancel): ${NC}"
    read_input num
    num="$(trim "$num")"
    [[ "$num" == "0" ]] && return
    if ! [[ "$num" =~ ^[0-9]+$ ]]; then
        error "Invalid number."
        return
    fi
    local line_no
    line_no="$(pf_get_line_number "$num")"
    [[ -z "$line_no" ]] && { error "Entry not found."; return; }
    sed -i "${line_no}d" "$PORT_FORWARDS_FILE"
    success "Removed entry $num."
    pf_apply
}

pf_edit() {
    [[ ! -f "$PORT_FORWARDS_FILE" ]] || [[ -z "$(pf_list_entries)" ]] && { colorize yellow "No port forwards defined."; return; }
    echo
    pf_show_list
    echo
    echo -ne "${CYAN}Entry number to edit (0 = cancel): ${NC}"
    read_input num
    num="$(trim "$num")"
    [[ "$num" == "0" ]] && return
    if ! [[ "$num" =~ ^[0-9]+$ ]]; then
        error "Invalid number."
        return
    fi
    local line_no
    line_no="$(pf_get_line_number "$num")"
    [[ -z "$line_no" ]] && { error "Entry not found."; return; }
    local line
    line="$(sed -n "${line_no}p" "$PORT_FORWARDS_FILE")"
    set -- $line
    local listen_ip="${1:-0.0.0.0}" listen_port="${2:-}" dest_ip="${3:-}" dest_port="${4:-}"
    echo -ne "${CYAN}Listen IP [${listen_ip}]: ${NC}"
    read_input in
    in="$(trim "$in")"
    [[ -n "$in" ]] && listen_ip="$in"
    echo -ne "${CYAN}Listen port [${listen_port}]: ${NC}"
    read_input in
    in="$(trim "$in")"
    [[ -n "$in" ]] && listen_port="$in"
    echo -ne "${CYAN}Destination IP [${dest_ip}]: ${NC}"
    read_input in
    in="$(trim "$in")"
    [[ -n "$in" ]] && dest_ip="$in"
    echo -ne "${CYAN}Destination port [${dest_port}]: ${NC}"
    read_input in
    in="$(trim "$in")"
    [[ -n "$in" ]] && dest_port="$in"
    sed -i "${line_no}s/.*/${listen_ip} ${listen_port} ${dest_ip} ${dest_port}/" "$PORT_FORWARDS_FILE"
    success "Updated entry $num."
    pf_apply
}

pf_show_list() {
    echo -e "${YELLOW}${LINE_SEP}${NC}"
    printf "  ${WHITE}%-4s %-16s %-8s %-16s %-8s${NC}\n" "#" "Listen IP" "Port" "Dest IP" "Port"
    echo -e "  ${LINE_H}${LINE_H}${LINE_H}${LINE_H}${LINE_H}${LINE_H}${LINE_H}${LINE_H}${NC}"
    local n=0
    while IFS= read -r line; do
        line="$(trim "$line")"
        [[ -z "$line" || "$line" == \#* ]] && continue
        (( n++ )) || true
        set -- $line
        [[ $# -lt 4 ]] && continue
        printf "  %-4s %-16s %-8s %-16s %-8s\n" "$n" "$1" "$2" "$3" "$4"
    done < <(pf_list_entries)
    echo -e "${YELLOW}${LINE_SEP}${NC}"
}

create_pf_systemd_service() {
    local svc_path="/etc/systemd/system/${PORT_FORWARD_SERVICE_NAME}.service"
    cat > "$svc_path" << EOF
[Unit]
Description=GRE Tunnel Manager - Restore port forwards
After=network-online.target network.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${INSTALL_DIR}/${INSTALL_CMD} --apply-portfw
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload 2>/dev/null || true
    systemctl enable "${PORT_FORWARD_SERVICE_NAME}" 2>/dev/null || true
}

port_forward_menu() {
    set +e
    while true; do
        clear_screen
        local method
        method="$(pf_get_method)"
        [[ -z "$method" ]] && method="(not set)"
        echo
        colorize cyan "Port forwarding (survives reboot)" bold
        echo -e "  Method: ${WHITE}${method}${NC}"
        [[ "$method" == "rinetd" ]] && echo -e "  ${CYAN}rinetd config:${NC} ${WHITE}${RINETD_CONF}${NC}"
        echo
        local opts=(
            "${GREEN}1)${NC} Set method (iptables or rinetd)"
            "${GREEN}2)${NC} Add forward (listen_ip port dest_ip dest_port)"
            "${CYAN}3)${NC} List forwards"
            "${YELLOW}4)${NC} Edit forward"
            "${YELLOW}5)${NC} Delete forward"
            "${YELLOW}6)${NC} Apply / Reload forwards now"
            "${CYAN}7)${NC} Edit rinetd config with nano (${RINETD_CONF})"
            "${WHITE}0)${NC} Back"
        )
        for o in "${opts[@]}"; do echo -e "  $o"; done
        echo
        echo -ne "${CYAN}Choice [0-7]: ${NC}"
        read_input choice
        choice="$(trim "$choice")"
        case "$choice" in
            1)
                echo
                echo -e "  ${GREEN}1)${NC} iptables (nat table)"
                echo -e "  ${GREEN}2)${NC} rinetd (apt install rinetd -y)"
                echo -ne "${CYAN}Choose [1/2]: ${NC}"
                read_input m
                m="$(trim "$m")"
                if [[ "$m" == "1" ]]; then
                    pf_set_method "iptables"
                    create_pf_systemd_service 2>/dev/null || true
                    success "Method set to iptables."
                    pf_apply
                elif [[ "$m" == "2" ]]; then
                    if ! command -v rinetd &>/dev/null; then
                        info "Installing rinetd..."
                        apt-get update -qq && apt-get install -y rinetd 2>/dev/null || { error "Install rinetd manually: apt install rinetd -y"; press_key; continue; }
                    fi
                    pf_set_method "rinetd"
                    create_pf_systemd_service 2>/dev/null || true
                    success "Method set to rinetd."
                    pf_apply
                else
                    error "Invalid choice."
                fi
                press_key
                ;;
            2) create_pf_systemd_service 2>/dev/null || true; pf_add; press_key ;;
            3) echo; pf_show_list; press_key ;;
            4) pf_edit; press_key ;;
            5) pf_delete; press_key ;;
            6) pf_apply; press_key ;;
            7)
                if [[ "$(pf_get_method)" == "rinetd" ]]; then
                    if [[ -e /dev/tty ]] && command -v nano &>/dev/null; then
                        nano "$RINETD_CONF" </dev/tty >/dev/tty
                        systemctl restart rinetd 2>/dev/null || service rinetd restart 2>/dev/null || true
                        success "Rinetd config saved and service restarted."
                    else
                        info "Config file: $RINETD_CONF (edit manually, then restart rinetd)"
                    fi
                else
                    info "Rinetd config path: $RINETD_CONF (set method to rinetd to edit from menu)"
                fi
                press_key
                ;;
            0) set -e; return ;;
            *) error "Invalid choice"; sleep 1 ;;
        esac
    done
    set -e
}

#===============================================================================
# TUNNEL CORE FUNCTIONS
#===============================================================================

# Enable IP forwarding
enable_ip_forward() {
    sysctl -w net.ipv4.ip_forward=1 &>/dev/null || true
    if ! grep -q '^net.ipv4.ip_forward=1' /etc/sysctl.conf 2>/dev/null; then
        echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
    fi
}

# Teardown all GRE interfaces (any name, discovered via ip link)
teardown_tunnels() {
    local i
    for i in $(ip -o link show type gre 2>/dev/null | awk -F': ' '{print $2}' | cut -d@ -f1); do
        ip tunnel del "$i" 2>/dev/null || true
    done
}

# Setup tunnels for a specific node
setup_tunnels() {
    local node="$1"
    local tunnel_id=0
    local my_tunnels=0
    
    [[ -z "$node" ]] && die "Node name required"
    [[ ! -f "$CONFIG_FILE" ]] && die "Config not found: $CONFIG_FILE"
    
    enable_ip_forward
    
    # Teardown existing tunnels first (idempotent)
    teardown_tunnels
    
    # Parse tunnels and setup
    while IFS= read -r line; do
        line="${line%%#*}"
        line="$(trim "$line")"
        [[ -z "$line" || ! "$line" == *","* ]] && continue
        
        (( tunnel_id++ )) || true
        
        local iran="${line%%,*}"
        local ext="${line#*,}"
        iran="$(trim "$iran")"
        ext="$(trim "$ext")"
        
        local local_ip="" remote_ip="" my_addr="" remote_addr=""
        local iface="gre${tunnel_id}"
        
        if [[ "$node" == "$iran" ]]; then
            local_ip="$(get_node_ip "$iran")"
            remote_ip="$(get_node_ip "$ext")"
            [[ -z "$local_ip" ]] && { error "Iran '$iran' IP not found"; continue; }
            [[ -z "$remote_ip" ]] && { error "External '$ext' IP not found"; continue; }
            my_addr="10.10.${tunnel_id}.1"
            remote_addr="10.10.${tunnel_id}.2"
        elif [[ "$node" == "$ext" ]]; then
            local_ip="$(get_node_ip "$ext")"
            remote_ip="$(get_node_ip "$iran")"
            [[ -z "$local_ip" ]] && { error "External '$ext' IP not found"; continue; }
            [[ -z "$remote_ip" ]] && { error "Iran '$iran' IP not found"; continue; }
            my_addr="10.10.${tunnel_id}.2"
            remote_addr="10.10.${tunnel_id}.1"
        else
            continue
        fi
        
        # Create tunnel interface
        ip tunnel add "$iface" mode gre local "$local_ip" remote "$remote_ip" ttl 255
        ip link set "$iface" up
        ip addr add "${my_addr}/30" dev "$iface"
        ip route add "${remote_addr}/32" dev "$iface" 2>/dev/null || true
        
        (( my_tunnels++ )) || true
        info "Tunnel ${tunnel_id}: ${my_addr} <-> ${remote_addr} (${remote_ip})"
        
    done < <(list_tunnels)
    
    if [[ $my_tunnels -eq 0 ]]; then
        warn "No tunnels defined for node: $node"
        return 1
    fi
    
    success "$my_tunnels tunnel(s) configured for node: $node"
    return 0
}

# Stop tunnels for a node (teardown only; do not call systemctl here to avoid deadlock when invoked from ExecStop)
stop_tunnels() {
    teardown_tunnels
    success "Tunnels stopped"
}

#===============================================================================
# SYSTEMD SERVICE MANAGEMENT
#===============================================================================

# Create systemd service unit (embedded - no external file needed)
create_service_unit() {
    local service_path="/etc/systemd/system/${SERVICE_NAME}@.service"
    
    cat > "$service_path" << EOF
[Unit]
Description=GRE Tunnel Service for %i
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=${INSTALL_DIR}/${INSTALL_CMD} --setup %i
ExecStop=${INSTALL_DIR}/${INSTALL_CMD} --teardown %i
ExecReload=${INSTALL_DIR}/${INSTALL_CMD} --setup %i

[Install]
WantedBy=multi-user.target
EOF
    
    systemctl daemon-reload
    success "Systemd service created"
}

# Enable service for node
enable_service() {
    local node="$1"
    [[ -z "$node" ]] && return 1
    
    systemctl enable "${SERVICE_NAME}@${node}" 2>/dev/null
    success "Service enabled for node: $node"
}

# Disable service for node
disable_service() {
    local node="$1"
    [[ -z "$node" ]] && return 1
    
    systemctl disable "${SERVICE_NAME}@${node}" 2>/dev/null || true
}

# Start service
start_service() {
    local node="$1"
    [[ -z "$node" ]] && return 1
    
    systemctl start "${SERVICE_NAME}@${node}"
    success "Service started for node: $node"
}

# Stop service
stop_service() {
    local node="$1"
    [[ -z "$node" ]] && return 1
    
    systemctl stop "${SERVICE_NAME}@${node}" 2>/dev/null || true
    success "Service stopped for node: $node"
}

# Restart service
restart_service() {
    local node="$1"
    [[ -z "$node" ]] && return 1
    
    systemctl restart "${SERVICE_NAME}@${node}" 2>/dev/null
    success "Service restarted for node: $node"
}

# Get service status
service_status() {
    local node="$1"
    [[ -z "$node" ]] && return 1
    
    systemctl status "${SERVICE_NAME}@${node}" --no-pager
}

#===============================================================================
# INSTALLATION FUNCTIONS
#===============================================================================

# Install the script
install_script() {
    local dest="${INSTALL_DIR}/${INSTALL_CMD}"
    
    echo
    colorize cyan "Installing GRE Tunnel Manager..." bold
    echo
    
    # Create directories
    mkdir -p "$INSTALL_DIR"
    mkdir -p "$CONFIG_DIR"
    
    # Copy or download script (always overwrite to update)
    if [[ -n "$SCRIPT_PATH" && -f "$SCRIPT_PATH" && "$SCRIPT_PATH" != "$dest" ]]; then
        cp "$SCRIPT_PATH" "$dest"
        chmod +x "$dest"
        success "Script installed to: $dest"
    else
        # Running from installed copy or stdin - download from URL to update
        if command -v curl &>/dev/null; then
            info "Updating script from ${INSTALL_SCRIPT_URL} ..."
            if curl -sSLf -o "$dest" "$INSTALL_SCRIPT_URL"; then
                chmod +x "$dest"
                success "Script updated at: $dest"
            else
                error "Download failed. Set GRE_INSTALL_URL to your script URL, or save tunnel.sh and run: bash /path/to/tunnel.sh install"
                return 1
            fi
        else
            error "curl not found. Install curl to update, or copy tunnel.sh manually to $dest"
            return 1
        fi
    fi
    
    # Create config if not exists
    if [[ ! -f "$CONFIG_FILE" ]]; then
        create_default_config
    fi
    
    # Create systemd service
    create_service_unit
    create_pf_systemd_service
    
    echo
    colorize green "Installation complete!" bold
    colorize yellow "Run '${INSTALL_CMD}' to start" bold
}

# Uninstall everything
uninstall_script() {
    echo
    colorize red "Uninstalling GRE Tunnel Manager..." bold
    echo
    
    colorize yellow "This will remove: script, config, tunnels, and all data." bold
    echo
    if ! confirm "Are you sure? This cannot be undone. [y/N]"; then
        info "Uninstall cancelled"
        press_key
        return
    fi
    
    local node=""
    if [[ -f "$NODE_FILE" ]]; then
        node="$(cat "$NODE_FILE")"
    fi
    
    # Stop and disable service
    if [[ -n "$node" ]]; then
        systemctl stop "${SERVICE_NAME}@${node}" 2>/dev/null || true
        systemctl disable "${SERVICE_NAME}@${node}" 2>/dev/null || true
    fi
    
    # Teardown tunnels
    teardown_tunnels
    
    # Remove service files
    rm -f "/etc/systemd/system/${SERVICE_NAME}@.service"
    rm -f "/etc/systemd/system/${PORT_FORWARD_SERVICE_NAME}.service"
    systemctl daemon-reload 2>/dev/null || true
    systemctl disable "${PORT_FORWARD_SERVICE_NAME}" 2>/dev/null || true
    
    # Remove installed script
    rm -f "${INSTALL_DIR}/${INSTALL_CMD}"
    rm -rf "$CONFIG_DIR"
    
    success "Uninstall complete. Script, config, and tunnels removed."
    
    # Self-delete only if we're running from the installed location
    if [[ -n "$SCRIPT_PATH" && -f "$SCRIPT_PATH" && "$SCRIPT_PATH" == "${INSTALL_DIR}/${INSTALL_CMD}" ]]; then
        rm -f "$SCRIPT_PATH"
    fi
    
    exit 0
}

#===============================================================================
# STATUS AND MONITORING
#===============================================================================

# Show tunnel status with IPs
show_tunnel_status() {
    local node=""
    
    if [[ -f "$NODE_FILE" ]]; then
        node="$(cat "$NODE_FILE")"
    else
        echo
        echo -ne "${CYAN}Node name (this server): ${NC}"
        read_input node
        node="$(trim "$node")"
    fi
    
    [[ -z "$node" ]] && return
    
    echo
    colorize cyan "Tunnel Status for Node: $node" bold
    echo -e "${YELLOW}${LINE_SEP}${NC}"
    
    local tunnel_id=0
    local shown=0
    
    while IFS= read -r line; do
        line="${line%%#*}"
        line="$(trim "$line")"
        [[ -z "$line" || ! "$line" == *","* ]] && continue
        
        (( tunnel_id++ )) || true
        
        local iran="${line%%,*}"
        local ext="${line#*,}"
        iran="$(trim "$iran")"
        ext="$(trim "$ext")"
        
        local iran_ip ext_ip
        iran_ip="$(get_node_ip "$iran")"
        ext_ip="$(get_node_ip "$ext")"
        
        # Check if interface exists
        local status_color="$RED"
        local status_text="DOWN"
        if ip link show "gre${tunnel_id}" &>/dev/null; then
            status_color="$GREEN"
            status_text="UP"
        fi
        
        if [[ "$node" == "$iran" ]]; then
            echo -e "  ${WHITE}Tunnel ${tunnel_id}:${NC} ${iran} -> ${ext}"
            echo -e "    Status: ${status_color}${status_text}${NC}"
            echo -e "    Local:  ${CYAN}10.10.${tunnel_id}.1${NC}"
            echo -e "    Remote: ${CYAN}10.10.${tunnel_id}.2${NC} (${ext_ip})"
            (( shown++ )) || true
        elif [[ "$node" == "$ext" ]]; then
            echo -e "  ${WHITE}Tunnel ${tunnel_id}:${NC} ${iran} -> ${ext}"
            echo -e "    Status: ${status_color}${status_text}${NC}"
            echo -e "    Local:  ${CYAN}10.10.${tunnel_id}.2${NC}"
            echo -e "    Remote: ${CYAN}10.10.${tunnel_id}.1${NC} (${iran_ip})"
            (( shown++ )) || true
        fi
        
    done < <(list_tunnels)
    
    if [[ $shown -eq 0 ]]; then
        colorize yellow "No tunnels defined for this node"
    fi
    
    echo -e "${YELLOW}${LINE_SEP}${NC}"
}

# Show only active (UP) tunnels in a clean list: private IP, Iran IP, External IP, tunnel pair
show_active_tunnels_list() {
    local node=""
    if [[ -f "$NODE_FILE" ]]; then
        node="$(cat "$NODE_FILE")"
    else
        echo -ne "${CYAN}Node name (this server): ${NC}"
        read_input node
        node="$(trim "$node")"
    fi
    [[ -z "$node" ]] && return

    echo
    colorize cyan "Active tunnels (UP only) - Node: $node" bold
    echo -e "${YELLOW}${LINE_SEP}${NC}"
    printf "  ${WHITE}%-6s ${CYAN}%-14s ${CYAN}%-14s ${GREEN}%-22s ${MAGENTA}%-22s${NC}  %s\n" "Tunnel" "Private IP" "Remote Priv" "Iran (name IP)" "External (name IP)" "Pair"
    echo -e "  ${LINE_H}${LINE_H}${LINE_H}${LINE_H}${LINE_H}${LINE_H}${LINE_H}${LINE_H}${LINE_H}${LINE_H}${LINE_H}${LINE_H}${LINE_H}${LINE_H}${LINE_H}${LINE_H}${LINE_H}${LINE_H}${LINE_H}${LINE_H}${LINE_H}${LINE_H}${LINE_H}${LINE_H}${LINE_H}${LINE_H}${LINE_H}${LINE_H}${LINE_H}${LINE_H}${LINE_H}${LINE_H}${LINE_H}${LINE_H}${LINE_H}${LINE_H}${LINE_H}${LINE_H}${LINE_H}${LINE_H}${LINE_H}${LINE_H}${NC}"

    local tunnel_id=0
    local count=0
    while IFS= read -r line; do
        line="${line%%#*}"
        line="$(trim "$line")"
        [[ -z "$line" || "$line" != *","* ]] && continue
        (( tunnel_id++ )) || true

        local iran="${line%%,*}"
        local ext="${line#*,}"
        iran="$(trim "$iran")"
        ext="$(trim "$ext")"
        if [[ "$node" != "$iran" && "$node" != "$ext" ]]; then
            continue
        fi

        if ! ip link show "gre${tunnel_id}" &>/dev/null; then
            continue
        fi

        local iran_ip ext_ip my_priv remote_priv
        iran_ip="$(get_node_ip "$iran")"
        ext_ip="$(get_node_ip "$ext")"
        iran_ip="${iran_ip:-?}"
        ext_ip="${ext_ip:-?}"

        if [[ "$node" == "$iran" ]]; then
            my_priv="10.10.${tunnel_id}.1"
            remote_priv="10.10.${tunnel_id}.2"
        else
            my_priv="10.10.${tunnel_id}.2"
            remote_priv="10.10.${tunnel_id}.1"
        fi

        printf "  %-6s %-14s %-14s %-22s %-22s  ${CYAN}%s -> %s${NC}\n" \
            "${tunnel_id}" "$my_priv" "$remote_priv" "${iran} ${iran_ip}" "${ext} ${ext_ip}" "$iran" "$ext"
        (( count++ )) || true
    done < <(list_tunnels)

    if [[ $count -eq 0 ]]; then
        echo -e "  ${YELLOW}(no active tunnels)${NC}"
    fi
    echo -e "${YELLOW}${LINE_SEP}${NC}"
}

# View service logs
view_logs() {
    local node=""
    
    if [[ -f "$NODE_FILE" ]]; then
        node="$(cat "$NODE_FILE")"
    fi
    
    if [[ -z "$node" ]]; then
        error "No node set"
        return
    fi
    
    echo
    colorize cyan "Viewing logs for: ${SERVICE_NAME}@${node}" bold
    colorize yellow "Press Ctrl+C to exit" bold
    echo
    
    journalctl -u "${SERVICE_NAME}@${node}" -f --no-pager
}

# Health check - ping remote endpoints
health_check() {
    local node=""
    
    if [[ -f "$NODE_FILE" ]]; then
        node="$(cat "$NODE_FILE")"
    else
        echo -ne "${CYAN}Node name: ${NC}"
        read_input node
        node="$(trim "$node")"
    fi
    
    [[ -z "$node" ]] && return
    
    echo
    colorize cyan "Health Check for Node: $node" bold
    echo -e "${YELLOW}${LINE_SEP}${NC}"
    
    local tunnel_id=0
    
    while IFS= read -r line; do
        line="${line%%#*}"
        line="$(trim "$line")"
        [[ -z "$line" || ! "$line" == *","* ]] && continue
        
        (( tunnel_id++ )) || true
        
        local iran="${line%%,*}"
        local ext="${line#*,}"
        iran="$(trim "$iran")"
        ext="$(trim "$ext")"
        
        local remote_addr=""
        if [[ "$node" == "$iran" ]]; then
            remote_addr="10.10.${tunnel_id}.2"
        elif [[ "$node" == "$ext" ]]; then
            remote_addr="10.10.${tunnel_id}.1"
        else
            continue
        fi
        
        echo -ne "  Tunnel ${tunnel_id} (${remote_addr}): "
        
        if ping -c 2 -W 2 "$remote_addr" &>/dev/null; then
            colorize green "REACHABLE" bold
        else
            colorize red "UNREACHABLE" bold
        fi
        
    done < <(list_tunnels)
    
    echo -e "${YELLOW}${LINE_SEP}${NC}"
}

#===============================================================================
# MENU FUNCTIONS
#===============================================================================

# Config management submenu
config_menu() {
    while true; do
        clear_screen
        
        local opts=(
            "${GREEN}1)${NC} Add Iran node"
            "${GREEN}2)${NC} Remove Iran node"
            "${GREEN}3)${NC} Add External node"
            "${GREEN}4)${NC} Remove External node"
            "${GREEN}5)${NC} Add tunnel"
            "${GREEN}6)${NC} Remove tunnel"
            "${CYAN}7)${NC} Show full config"
            "${YELLOW}0)${NC} Back to main menu"
        )
        
        display_menu_box "Configuration Management" "${opts[@]}"
        
        echo -ne "${CYAN}Enter choice [0-7]: ${NC}"
        local choice
        read_input choice
        
        case "$choice" in
            1) config_add_iran; press_key ;;
            2) config_remove_iran; press_key ;;
            3) config_add_external; press_key ;;
            4) config_remove_external; press_key ;;
            5) config_add_tunnel; press_key ;;
            6) config_remove_tunnel; press_key ;;
            7) config_show; press_key ;;
            0) return ;;
            *) error "Invalid choice"; sleep 1 ;;
        esac
    done
}

# Set node and start tunnels
set_node_and_start() {
    echo
    colorize cyan "Available nodes in config:" bold
    echo
    
    local all_nodes
    all_nodes=$( { list_irans; list_externals; } )
    echo "$all_nodes" | nl -w2 -s") " | sed 's/^/  /'
    echo
    
    echo -ne "${CYAN}Enter node name or number: ${NC}"
    local node_input node
    read_input node_input
    node_input="$(trim "$node_input")"
    
    [[ -z "$node_input" ]] && return
    
    # Resolve number to name
    if [[ "$node_input" =~ ^[0-9]+$ ]]; then
        node=$(echo "$all_nodes" | sed -n "${node_input}p")
    else
        node="$node_input"
    fi
    
    [[ -z "$node" ]] && { error "Invalid selection"; return; }
    
    # Validate node exists
    if ! is_iran_node "$node" && ! is_external_node "$node"; then
        if ! confirm "Node '$node' not found in config. Continue anyway?"; then
            return
        fi
    fi
    
    # Save node
    echo "$node" > "$NODE_FILE"
    info "Node set to: $node"
    
    # Create service if needed
    if [[ ! -f "/etc/systemd/system/${SERVICE_NAME}@.service" ]]; then
        create_service_unit
    fi
    
    # Enable and start
    enable_service "$node"
    restart_service "$node"
    
    echo
    service_status "$node"
}

# Main menu
main_menu() {
    while true; do
        clear_screen
        display_status_bar
        
        local opts=(
            "${GREEN}1)${NC} Add tunnels & Config management"
            "${GREEN}2)${NC} Set node & Start tunnels"
            "${CYAN}3)${NC} Show tunnel status"
            "${CYAN}4)${NC} Show active tunnels (list)"
            "${CYAN}5)${NC} Health check (ping test)"
            "${CYAN}6)${NC} View logs"
            "${YELLOW}7)${NC} Restart tunnels"
            "${YELLOW}8)${NC} Stop tunnels"
            "${YELLOW}9)${NC} Remove all tunnels (keep config & script)"
            "${MAGENTA}10)${NC} Load config from file"
            "${BLUE}11)${NC} Update and Install script"
            "${RED}12)${NC} Uninstall (remove everything)"
            "${GREEN}13)${NC} Port forwarding"
            "${WHITE}0)${NC} Exit"
        )
        
        display_menu_box "GRE Tunnel Manager v${VERSION}" "${opts[@]}"
        
        echo -ne "${CYAN}Enter choice [0-13]: ${NC}"
        local choice
        read_input choice
        
        case "$choice" in
            1) config_menu ;;
            2) set_node_and_start; press_key ;;
            3) show_tunnel_status; press_key ;;
            4) show_active_tunnels_list; press_key ;;
            5) health_check; press_key ;;
            6) view_logs; press_key ;;
            7)
                if [[ -f "$NODE_FILE" ]]; then
                    local node
                    node="$(cat "$NODE_FILE")"
                    echo
                    info "Restarting tunnels for node: $node ..."
                    restart_service "$node"
                else
                    error "No node set"
                fi
                press_key
                ;;
            8)
                if [[ -f "$NODE_FILE" ]]; then
                    local node
                    node="$(cat "$NODE_FILE")"
                    echo
                    info "Stopping tunnels for node: $node ..."
                    stop_tunnels "$node"
                    systemctl stop "${SERVICE_NAME}@${node}" 2>/dev/null || true
                else
                    echo
                    info "Stopping all tunnel interfaces ..."
                    teardown_tunnels
                    success "Tunnels stopped"
                fi
                press_key
                ;;
            9) remove_all_tunnels; press_key ;;
            10) load_config_from_file; press_key ;;
            11) install_script; press_key ;;
            12) uninstall_script ;;
            13) port_forward_menu ;;
            0)
                colorize green "Goodbye!" bold
                exit 0
                ;;
            *) error "Invalid choice"; sleep 1 ;;
        esac
    done
}

#===============================================================================
# COMMAND LINE INTERFACE
#===============================================================================

# Show usage
show_usage() {
    cat << EOF
GRE Tunnel Manager v${VERSION}

Usage: $SCRIPT_NAME [command]

Commands:
  (no args)     Interactive menu
  menu          Interactive menu
  status        Show service status
  start         Start tunnels
  stop          Stop tunnels
  restart       Restart tunnels
  logs          View service logs
  install       Install script
  uninstall     Uninstall script
  version       Show version
  help          Show this help

Internal commands (used by systemd):
  --setup <node>      Setup tunnels for node
  --teardown <node>   Teardown tunnels for node
  --apply-portfw      Apply port forwards (used at boot)

EOF
}

# Main entry point
main() {
    # Internal commands (called by systemd service)
    case "${1:-}" in
        --setup)
            check_root
            check_gre_support
            load_config
            setup_tunnels "${2:-}"
            exit $?
            ;;
        --teardown)
            check_root
            load_config
            stop_tunnels "${2:-}"
            exit $?
            ;;
        --apply-portfw)
            check_root
            load_config
            pf_apply
            exit 0
            ;;
    esac
    
    # Initialize for interactive use
    init_environment
    
    # Command line interface
    case "${1:-}" in
        status)
            if [[ -f "$NODE_FILE" ]]; then
                service_status "$(cat "$NODE_FILE")"
            else
                error "No node set"
                exit 1
            fi
            ;;
        start)
            if [[ -f "$NODE_FILE" ]]; then
                start_service "$(cat "$NODE_FILE")"
            else
                error "No node set. Run menu to configure."
                exit 1
            fi
            ;;
        stop)
            if [[ -f "$NODE_FILE" ]]; then
                local node
                node="$(cat "$NODE_FILE")"
                stop_tunnels "$node"
                systemctl stop "${SERVICE_NAME}@${node}" 2>/dev/null || true
            else
                teardown_tunnels
            fi
            ;;
        restart)
            if [[ -f "$NODE_FILE" ]]; then
                restart_service "$(cat "$NODE_FILE")"
            else
                error "No node set"
                exit 1
            fi
            ;;
        logs)
            view_logs
            ;;
        install)
            install_script
            ;;
        uninstall)
            uninstall_script
            ;;
        version)
            echo "GRE Tunnel Manager v${VERSION}"
            ;;
        help|--help|-h)
            show_usage
            ;;
        menu|"")
            main_menu
            ;;
        *)
            error "Unknown command: $1"
            show_usage
            exit 1
            ;;
    esac
}

# Run main
main "$@"
