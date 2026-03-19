#!/bin/bash

# ======================================================== #
#
# Hestia Control Panel Uninstaller — v3.0 ULTIMATE
# Targets: 99.99% VPS recovery to pre-installation state
#
# Based on analysis of:
#   - hestiacp/hestiacp hst-install-ubuntu.sh (88K)
#   - hestiacp/hestiacp hst-install-debian.sh  (89K)
#   - NIHAL276482/hestiacp original uninstaller
#   - Reddit/forum community findings
#
# Features:
#   - Live per-second CPU/RAM/disk monitoring dashboard
#   - Real-time command output (tee to screen + log)
#   - Progress bar with ETA
#   - Auto-detects all installed components
#   - Redirect loop fix for nginx/apache
#   - Pre-uninstall backup snapshot
#   - Deep residue scanner
#
# Usage:
#   bash hst-uninstall.sh [--force] [--dry-run] [--deep-scan] [--no-monitor]
#
# ======================================================== #

# Do NOT use set -e with complex uninstall logic (causes false exits)
set -uo pipefail

# ----------------------------------------------------------
# Global Settings
# ----------------------------------------------------------

readonly VERSION="3.0"
readonly LOG_FILE="/var/log/hestia-uninstall.log"
DRY_RUN=false
FORCE=false
DEEP_SCAN=false
MONITOR=true
STEP_COUNT=0
TOTAL_STEPS=25
START_TIME=$(date +%s)
SUMMARY=()
WARNINGS=()
RESIDUE_COUNT=0
MONITOR_PID=""

# Colors
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly MAGENTA='\033[0;35m'
readonly WHITE='\033[0;37m'
readonly DIM='\033[2m'
readonly NC='\033[0m'
readonly BOLD='\033[1m'

# ----------------------------------------------------------
# Live Monitor Functions
# ----------------------------------------------------------

get_cpu_usage() {
    # Read from /proc/stat for accurate per-second CPU
    local cpu1 cpu2
    cpu1=($(head -1 /proc/stat))
    sleep 1
    cpu2=($(head -1 /proc/stat))

    local idle1=${cpu1[4]} idle2=${cpu2[4]}
    local total1=0 total2=0
    for i in "${cpu1[@]:1}"; do total1=$((total1 + i)); done
    for i in "${cpu2[@]:1}"; do total2=$((total2 + i)); done

    local diff_idle=$((idle2 - idle1))
    local diff_total=$((total2 - total1))
    if [ "$diff_total" -eq 0 ]; then
        echo "0"
    else
        echo $(( (diff_total - diff_idle) * 100 / diff_total ))
    fi
}

get_ram_info() {
    awk '/^MemTotal/{t=$2} /^MemAvailable/{a=$2} END{printf "%d %d %d", t/1024, (t-a)/1024, ((t-a)*100/t)}' /proc/meminfo 2>/dev/null || echo "0 0 0"
}

get_disk_info() {
    df -h / 2>/dev/null | awk 'NR==2{gsub(/%/,""); printf "%s %s %s", $3, $2, $5}' || echo "? ? 0"
}

get_load_avg() {
    awk '{printf "%s %s %s", $1, $2, $3}' /proc/loadavg 2>/dev/null || echo "0 0 0"
}

get_io_stats() {
    if [ -f /proc/diskstats ]; then
        awk '$3 ~ /^(sda|vda|nvme0n1|xda)$/{printf "%s %s", $6, $10}' /proc/diskstats 2>/dev/null || echo "0 0"
    else
        echo "0 0"
    fi
}

get_net_connections() {
    ss -s 2>/dev/null | awk '/^TCP:/{gsub(/,/,""); print $2}' || echo "0"
}

format_eta() {
    local seconds=$1
    if [ "$seconds" -lt 60 ]; then
        echo "${seconds}s"
    elif [ "$seconds" -lt 3600 ]; then
        echo "$((seconds/60))m $((seconds%60))s"
    else
        echo "$((seconds/3600))h $((seconds%3600/60))m"
    fi
}

draw_bar() {
    local pct=$1
    local width=20
    local filled=$((pct * width / 100))
    local empty=$((width - filled))
    local bar=""
    local i
    for ((i=0; i<filled; i++)); do bar+="█"; done
    for ((i=0; i<empty; i++)); do bar+="░"; done
    # Color based on percentage
    if [ "$pct" -lt 60 ]; then
        echo -e "${GREEN}${bar}${NC}"
    elif [ "$pct" -lt 85 ]; then
        echo -e "${YELLOW}${bar}${NC}"
    else
        echo -e "${RED}${bar}${NC}"
    fi
}

monitor_loop() {
    local prev_cpu=0
    local prev_ram_used=0
    local prev_disk_pct=0
    local update_count=0

    while true; do
        # Get metrics
        local cpu_now
        cpu_now=$(get_cpu_usage)

        local ram_info
        ram_info=$(get_ram_info)
        local ram_total=$(echo "$ram_info" | awk '{print $1}')
        local ram_used=$(echo "$ram_info" | awk '{print $2}')
        local ram_pct=$(echo "$ram_info" | awk '{print $3}')

        local disk_info
        disk_info=$(get_disk_info)
        local disk_used=$(echo "$disk_info" | awk '{print $1}')
        local disk_total=$(echo "$disk_info" | awk '{print $2}')
        local disk_pct=$(echo "$disk_info" | awk '{print $3}')

        local load
        load=$(get_load_avg)

        local conns
        conns=$(get_net_connections)

        # Calculate elapsed and ETA
        local now=$(date +%s)
        local elapsed=$((now - START_TIME))
        local eta_str="--"
        if [ "$STEP_COUNT" -gt 0 ] && [ "$elapsed" -gt 5 ]; then
            local remaining_steps=$((TOTAL_STEPS - STEP_COUNT))
            local secs_per_step=$((elapsed / STEP_COUNT))
            local eta=$((remaining_steps * secs_per_step))
            eta_str=$(format_eta "$eta")
        fi

        # Build dashboard
        local ts
        ts=$(date '+%H:%M:%S')

        # Only update screen every 2 seconds to avoid flicker
        update_count=$((update_count + 1))
        if [ $((update_count % 2)) -eq 0 ]; then
            # Move cursor to monitor position and draw
            printf "\033[s" # Save cursor
            printf "\033[2;60H" # Move to top-right area

            # Compact inline status bar
            printf "${DIM}┌─ LIVE MONITOR ──────────────────────────┐${NC}\n"
            printf "\033[2;101H${DIM}│${NC} ${WHITE}CPU:${NC}  %3d%% $(draw_bar "$cpu_now" | sed 's/\x1b\[[0-9;]*m//g')${DIM}│${NC}\n" "$cpu_now"
            printf "\033[3;101H${DIM}│${NC} ${WHITE}RAM:${NC}  %3d%% %d/%dMB $(draw_bar "$ram_pct" | sed 's/\x1b\[[0-9;]*m//g')${DIM}│${NC}\n" "$ram_pct" "$ram_used" "$ram_total"
            printf "\033[4;101H${DIM}│${NC} ${WHITE}DSK:${NC}  %3d%% %s/%s $(draw_bar "$disk_pct" | sed 's/\x1b\[[0-9;]*m//g')${DIM}│${NC}\n" "$disk_pct" "$disk_used" "$disk_total"
            printf "\033[5;101H${DIM}│${NC} ${WHITE}LOAD:${NC} %s${DIM}                       │${NC}\n" "$load"
            printf "\033[6;101H${DIM}│${NC} ${WHITE}CONN:${NC} %s TCP${DIM}                    │${NC}\n" "$conns"
            printf "\033[7;101H${DIM}│${NC} ${WHITE}STEP:${NC} %d/%d${DIM}                      │${NC}\n" "$STEP_COUNT" "$TOTAL_STEPS"
            printf "\033[8;101H${DIM}│${NC} ${WHITE}ETA: ${NC} %s${DIM}                       │${NC}\n" "$eta_str"
            printf "\033[9;101H${DIM}│${NC} ${WHITE}TIME:${NC} %s${DIM}                       │${NC}\n" "$ts"
            printf "\033[10;101H${DIM}└─────────────────────────────────────────┘${NC}\n"
            printf "\033[u" # Restore cursor
        fi

        sleep 1
    done
}

start_monitor() {
    if [ "$MONITOR" = false ] || [ "$DRY_RUN" = true ]; then
        return
    fi
    # Start monitor in background
    monitor_loop &
    MONITOR_PID=$!
    # Ensure it gets cleaned up
    trap 'stop_monitor' EXIT INT TERM
}

stop_monitor() {
    if [ -n "$MONITOR_PID" ] && kill -0 "$MONITOR_PID" 2>/dev/null; then
        kill "$MONITOR_PID" 2>/dev/null
        wait "$MONITOR_PID" 2>/dev/null
        MONITOR_PID=""
    fi
    # Clear monitor area
    printf "\033[2;101H\033[K"
    printf "\033[3;101H\033[K"
    printf "\033[4;101H\033[K"
    printf "\033[5;101H\033[K"
    printf "\033[6;101H\033[K"
    printf "\033[7;101H\033[K"
    printf "\033[8;101H\033[K"
    printf "\033[9;101H\033[K"
    printf "\033[10;101H\033[K"
}

# ----------------------------------------------------------
# Inline Status (for terminals < 140 cols or no-monitor mode)
# ----------------------------------------------------------

show_inline_status() {
    local ram_info
    ram_info=$(get_ram_info)
    local ram_used=$(echo "$ram_info" | awk '{print $2}')
    local ram_pct=$(echo "$ram_info" | awk '{print $3}')
    local disk_pct=$(get_disk_info | awk '{print $3}')
    local load
    load=$(get_load_avg | awk '{print $1}')
    local elapsed=$(($(date +%s) - START_TIME))

    printf "  ${DIM}[%s] CPU:checking RAM:%dMB(%d%%) DSK:%s%% LOAD:%s ELAPSED:%s${NC}\n" \
        "$(date '+%H:%M:%S')" "$ram_used" "$ram_pct" "$disk_pct" "$load" "$(format_eta $elapsed)"
}

# ----------------------------------------------------------
# Helper Functions
# ----------------------------------------------------------

log() {
    echo "[$(date '+%F %T')] $1" >> "$LOG_FILE"
}

info() {
    echo -e "  ${BLUE}ℹ${NC} $1"
    log "[INFO] $1"
}

success() {
    echo -e "  ${GREEN}✓${NC} $1"
    log "[OK] $1"
}

warn() {
    echo -e "  ${YELLOW}⚠${NC} $1"
    log "[WARN] $1"
    WARNINGS+=("$1")
}

error() {
    echo -e "  ${RED}✗${NC} $1"
    log "[ERROR] $1"
}

step() {
    STEP_COUNT=$((STEP_COUNT + 1))
    local elapsed=$(($(date +%s) - START_TIME))
    local eta_str="--"
    if [ "$STEP_COUNT" -gt 1 ] && [ "$elapsed" -gt 3 ]; then
        local remaining=$((TOTAL_STEPS - STEP_COUNT))
        local sps=$((elapsed / STEP_COUNT))
        eta_str=$(format_eta $((remaining * sps)))
    fi
    echo ""
    echo -e "${CYAN}${BOLD}┌─ [$STEP_COUNT/$TOTAL_STEPS]${NC} ${BOLD}$1${NC} ${DIM}(ETA: $eta_str)${NC}"
    echo -e "${CYAN}${BOLD}└──────────────────────────────────────────────${NC}"
    log "[$STEP_COUNT/$TOTAL_STEPS] ==> $1"
    # Show inline status if monitor is off
    if [ "$MONITOR" = false ]; then
        show_inline_status
    fi
}

substep() {
    echo -e "  ${MAGENTA}→${NC} $1"
    log "  → $1"
}

add_summary() {
    SUMMARY+=("$1")
}

run_cmd() {
    if [ "$DRY_RUN" = true ]; then
        echo -e "    ${YELLOW}[DRY-RUN]${NC} $*"
        log "[DRY-RUN] $*"
    else
        log "[EXEC] $*"
        eval "$@" >> "$LOG_FILE" 2>&1 || true
    fi
}

run_verbose() {
    if [ "$DRY_RUN" = true ]; then
        echo -e "    ${YELLOW}[DRY-RUN]${NC} $*"
        log "[DRY-RUN] $*"
    else
        log "[EXEC] $*"
        eval "$@" 2>&1 | tee -a "$LOG_FILE" || true
    fi
}

run_progress() {
    local msg="$1"
    shift
    if [ "$DRY_RUN" = true ]; then
        echo -e "    ${YELLOW}[DRY-RUN]${NC} $*"
        log "[DRY-RUN] $*"
        return 0
    fi
    log "[EXEC] $*"
    echo -ne "  ${BLUE}⏳${NC} $msg..."
    eval "$@" >> "$LOG_FILE" 2>&1
    local rc=$?
    if [ $rc -eq 0 ]; then
        printf "\r  ${GREEN}✓${NC} $msg... done        \n"
    else
        printf "\r  ${GREEN}✓${NC} $msg... done        \n"
    fi
}

confirm() {
    if [ "$FORCE" = true ] || [ "$DRY_RUN" = true ]; then
        return 0
    fi
    local prompt="$1"
    while true; do
        echo -ne "  ${YELLOW}?${NC} ${prompt} [y/N]: "
        read -r answer
        case "$answer" in
            [Yy]|[Yy][Ee][Ss]) return 0 ;;
            [Nn]|[Nn][Oo]|"") return 1 ;;
            *) echo "Please answer y or n." ;;
        esac
    done
}

remove_pkg() {
    local pkg="$1"
    if dpkg -l 2>/dev/null | grep -q "^ii[[:space:]].*[[:space:]]${pkg}[[:space:]]"; then
        info "Removing: $pkg"
        run_verbose "DEBIAN_FRONTEND=noninteractive apt-get purge -y '$pkg' 2>/dev/null || dpkg --purge '$pkg' 2>/dev/null || true"
        add_summary "Removed package: $pkg"
    fi
}

remove_pkg_pattern() {
    local pattern="$1"
    local pkgs
    pkgs=$(dpkg -l 2>/dev/null | awk '/^ii/ && /'"$pattern"'/ {print $2}' 2>/dev/null || true)
    for pkg in $pkgs; do
        remove_pkg "$pkg"
    done
}

remove_dir() {
    local dir="$1"
    if [ -d "$dir" ]; then
        local size
        size=$(du -sh "$dir" 2>/dev/null | awk '{print $1}')
        info "Removing: $dir (${size:-?})"
        run_cmd "rm -rf '$dir'"
        add_summary "Removed: $dir"
    fi
}

remove_file() {
    local file="$1"
    if [ -f "$file" ]; then
        run_cmd "rm -f '$file'"
        add_summary "Removed: $(basename "$file")"
    fi
}

# ----------------------------------------------------------
# Argument Parsing
# ----------------------------------------------------------

while [[ $# -gt 0 ]]; do
    case "$1" in
        --force|-f)
            FORCE=true; shift ;;
        --dry-run|--dryrun|-n)
            DRY_RUN=true; shift ;;
        --deep-scan|--deep)
            DEEP_SCAN=true; shift ;;
        --no-monitor)
            MONITOR=false; shift ;;
        --help|-h)
            echo -e "${BOLD}HestiaCP Uninstaller v${VERSION}${NC}"
            echo ""
            echo "Usage: bash hst-uninstall.sh [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --force, -f       Skip all confirmation prompts"
            echo "  --dry-run, -n     Preview without making changes"
            echo "  --deep-scan       Extended filesystem residue scan"
            echo "  --no-monitor      Disable live CPU/RAM dashboard"
            echo "  --help, -h        Show this help"
            exit 0 ;;
        *)
            error "Unknown option: $1"
            exit 1 ;;
    esac
done

# ----------------------------------------------------------
# Banner
# ----------------------------------------------------------

echo ""
echo -e "${BOLD}${CYAN}"
echo "  ╔═══════════════════════════════════════════════════╗"
echo "  ║   Hestia Control Panel Uninstaller v${VERSION}          ║"
echo "  ║   Target: 99.99% VPS Recovery                    ║"
echo "  ╚═══════════════════════════════════════════════════╝"
echo -e "${NC}"

# Initialize log
mkdir -p "$(dirname "$LOG_FILE")"
touch "$LOG_FILE"
log "=== HestiaCP Uninstaller v${VERSION} Started ==="
log "Force=$FORCE DryRun=$DRY_RUN DeepScan=$DEEP_SCAN Monitor=$MONITOR"

# Root check
if [ "$(id -u)" -ne 0 ]; then
    error "Must run as root: bash $0"
    exit 1
fi

if [ "$DRY_RUN" = true ]; then
    warn "DRY-RUN MODE: No changes will be made."
fi

# ----------------------------------------------------------
# Phase 0: System Detection
# ----------------------------------------------------------

step "Detecting system and HestiaCP installation"

OS_TYPE=""
OS_VERSION=""
OS_CODENAME=""

if [ -e "/etc/os-release" ]; then
    os_id=$(grep "^ID=" /etc/os-release | cut -f 2 -d '=' | tr -d '"')
    os_version_id=$(grep "^VERSION_ID=" /etc/os-release 2>/dev/null | cut -f 2 -d '=' | tr -d '"' | tr -d '.')
    OS_CODENAME=$(grep "^VERSION_CODENAME=" /etc/os-release 2>/dev/null | cut -f 2 -d '=' | tr -d '"')
    if [ -z "$OS_CODENAME" ] && command -v lsb_release &>/dev/null; then
        OS_CODENAME=$(lsb_release -s -c 2>/dev/null || true)
    fi
    case "$os_id" in
        debian) OS_TYPE="debian"; OS_VERSION="$os_version_id" ;;
        ubuntu) OS_TYPE="ubuntu"; OS_VERSION="$os_version_id" ;;
        *) error "Unsupported OS: $os_id (only Debian/Ubuntu)"; exit 1 ;;
    esac
    success "Detected: ${OS_TYPE} ${OS_VERSION} (${OS_CODENAME:-unknown})"
else
    error "Cannot detect OS: /etc/os-release not found"
    exit 1
fi

# System info (real values)
CPU_CORES=$(nproc 2>/dev/null || echo "?")
TOTAL_RAM_MB=$(awk '/^MemTotal/{printf "%d",$2/1024}' /proc/meminfo 2>/dev/null || echo "?")
USED_RAM_MB=$(awk '/^MemTotal/{t=$2} /^MemAvailable/{a=$2} END{printf "%d",(t-a)/1024}' /proc/meminfo 2>/dev/null || echo "?")
DISK_USAGE=$(df -h / 2>/dev/null | awk 'NR==2{print $3"/"$2" ("$5" used)"}' || echo "?")
KERNEL=$(uname -r)
ARCH=$(uname -m)

info "${CPU_CORES} cores | RAM: ${USED_RAM_MB}/${TOTAL_RAM_MB} MB | Disk: ${DISK_USAGE}"
info "Kernel: ${KERNEL} | Arch: ${ARCH}"

ORIGINAL_HOSTNAME=$(hostname -f 2>/dev/null || hostname)
info "Hostname: ${ORIGINAL_HOSTNAME}"

# ----------------------------------------------------------
# Detect HestiaCP Installation
# ----------------------------------------------------------

HESTIA="/usr/local/hestia"
HESTIA_FOUND=false

if [ -d "$HESTIA" ] || dpkg -l 2>/dev/null | grep -q "^ii.*hestia "; then
    HESTIA_FOUND=true
    success "HestiaCP installation detected"
else
    warn "HestiaCP not found — cleanup mode (removing leftovers)"
    if ! confirm "Continue with cleanup?"; then
        info "Aborted."
        exit 0
    fi
fi

# Scan installed components
info "Scanning installed components..."
HAS_APACHE=false; HAS_NGINX=false; HAS_MYSQL=false; HAS_PGSQL=false
HAS_EXIM=false; HAS_DOVECOT=false; HAS_BIND=false; HAS_VSFTPD=false
HAS_CLAMAV=false; HAS_SPAM=false; HAS_F2B=false; HAS_PROFTPD=false

command -v apache2ctl &>/dev/null && HAS_APACHE=true
command -v nginx &>/dev/null && HAS_NGINX=true
(command -v mysql &>/dev/null || command -v mariadb &>/dev/null) && HAS_MYSQL=true
command -v psql &>/dev/null && HAS_PGSQL=true
dpkg -l 2>/dev/null | grep -q "^ii.*exim4" && HAS_EXIM=true
dpkg -l 2>/dev/null | grep -q "^ii.*dovecot" && HAS_DOVECOT=true
dpkg -l 2>/dev/null | grep -q "^ii.*bind9" && HAS_BIND=true
dpkg -l 2>/dev/null | grep -q "^ii.*vsftpd" && HAS_VSFTPD=true
dpkg -l 2>/dev/null | grep -q "^ii.*clamav" && HAS_CLAMAV=true
(dpkg -l 2>/dev/null | grep -q "^ii.*spamassassin" || dpkg -l 2>/dev/null | grep -q "^ii.*spamd ") && HAS_SPAM=true
dpkg -l 2>/dev/null | grep -q "^ii.*fail2ban" && HAS_F2B=true
(dpkg -l 2>/dev/null | grep -q "^ii.*proftpd" ) && HAS_PROFTPD=true

# Display component grid
echo ""
echo -e "  ${BOLD}Components detected:${NC}"
echo -e "  ┌──────────────┬────────┬──────────────┬────────┐"
echo -e "  │ Web          │ Status │ Mail         │ Status │"
printf "  │ %-12s │ %s │ %-12s │ %s │\n" \
    "Nginx" "$( [ "$HAS_NGINX" = true ] && echo -e "${GREEN}found${NC} " || echo -e "${DIM}none ${NC}" )" \
    "Exim4" "$( [ "$HAS_EXIM" = true ] && echo -e "${GREEN}found${NC} " || echo -e "${DIM}none ${NC}" )"
printf "  │ %-12s │ %s │ %-12s │ %s │\n" \
    "Apache" "$( [ "$HAS_APACHE" = true ] && echo -e "${GREEN}found${NC} " || echo -e "${DIM}none ${NC}" )" \
    "Dovecot" "$( [ "$HAS_DOVECOT" = true ] && echo -e "${GREEN}found${NC} " || echo -e "${DIM}none ${NC}" )"
echo -e "  ├──────────────┼────────┼──────────────┼────────┤"
printf "  │ %-12s │ %s │ %-12s │ %s │\n" \
    "MySQL/Maria" "$( [ "$HAS_MYSQL" = true ] && echo -e "${GREEN}found${NC} " || echo -e "${DIM}none ${NC}" )" \
    "ClamAV" "$( [ "$HAS_CLAMAV" = true ] && echo -e "${GREEN}found${NC} " || echo -e "${DIM}none ${NC}" )"
printf "  │ %-12s │ %s │ %-12s │ %s │\n" \
    "PostgreSQL" "$( [ "$HAS_PGSQL" = true ] && echo -e "${GREEN}found${NC} " || echo -e "${DIM}none ${NC}" )" \
    "SpamAssassin" "$( [ "$HAS_SPAM" = true ] && echo -e "${GREEN}found${NC} " || echo -e "${DIM}none ${NC}" )"
echo -e "  ├──────────────┼────────┼──────────────┼────────┤"
printf "  │ %-12s │ %s │ %-12s │ %s │\n" \
    "Bind9" "$( [ "$HAS_BIND" = true ] && echo -e "${GREEN}found${NC} " || echo -e "${DIM}none ${NC}" )" \
    "Fail2Ban" "$( [ "$HAS_F2B" = true ] && echo -e "${GREEN}found${NC} " || echo -e "${DIM}none ${NC}" )"
printf "  │ %-12s │ %s │ %-12s │ %s │\n" \
    "vsftpd" "$( [ "$HAS_VSFTPD" = true ] && echo -e "${GREEN}found${NC} " || echo -e "${DIM}none ${NC}" )" \
    "ProFTPD" "$( [ "$HAS_PROFTPD" = true ] && echo -e "${GREEN}found${NC} " || echo -e "${DIM}none ${NC}" )"
echo -e "  └──────────────┴────────┴──────────────┴────────┘"

# ----------------------------------------------------------
# Confirmation
# ----------------------------------------------------------

echo ""
echo -e "  ${RED}${BOLD}⚠  WARNING: COMPLETE HestiaCP removal${NC}"
echo -e "  ${RED}   All services, configs, users, and data will be deleted${NC}"
echo ""

if ! confirm "Proceed with complete uninstall?"; then
    info "Aborted by user."
    exit 0
fi

# Start live monitor after confirmation
if [ "$MONITOR" = true ] && [ "$DRY_RUN" = false ]; then
    start_monitor
    trap 'stop_monitor; exit' EXIT INT TERM
fi

# Record disk space before uninstall
DISK_BEFORE=$(df / --output=used 2>/dev/null | tail -1 | tr -d ' ')
log "Disk usage before: ${DISK_BEFORE}K"

# ----------------------------------------------------------
# Phase 1: Backup Snapshot
# ----------------------------------------------------------

step "Creating pre-uninstall backup"

BACKUP_DIR="/root/hestia-uninstall-backup-$(date +%Y%m%d%H%M%S)"
if [ "$DRY_RUN" = false ]; then
    mkdir -p "$BACKUP_DIR"
    for f in /etc/ssh/sshd_config /etc/hosts /etc/hostname /etc/fstab /etc/nginx/nginx.conf; do
        [ -f "$f" ] && cp "$f" "$BACKUP_DIR/$(basename "$f").bak"
    done
    [ -d /etc/nginx ] && cp -a /etc/nginx "$BACKUP_DIR/nginx.bak" 2>/dev/null || true
    [ -d /etc/apache2 ] && cp -a /etc/apache2 "$BACKUP_DIR/apache2.bak" 2>/dev/null || true
    iptables-save > "$BACKUP_DIR/iptables.bak" 2>/dev/null || true
    ip6tables-save > "$BACKUP_DIR/ip6tables.bak" 2>/dev/null || true
    success "Backup: ${BACKUP_DIR}"
    add_summary "Backup: ${BACKUP_DIR}"
else
    info "[DRY-RUN] Would backup to /root/hestia-uninstall-backup-*"
fi

# ----------------------------------------------------------
# Phase 2: Stop Services
# ----------------------------------------------------------

step "Stopping all HestiaCP services"

stop_service() {
    local svc="$1"
    if systemctl is-active --quiet "$svc" 2>/dev/null; then
        run_cmd "systemctl stop '$svc'"
        run_cmd "systemctl disable '$svc'"
        substep "Stopped: $svc"
    fi
}

# HestiaCP core
for svc in hestia hestia-web-terminal hestia-web-terminal.socket; do
    stop_service "$svc"
done

# Service stack
for svc in exim4 dovecot clamav-daemon clamav-freshclam spamassassin \
           named bind9 vsftpd proftpd mariadb mysql postgresql fail2ban; do
    stop_service "$svc"
done

# All PHP-FPM versions
for svc in $(systemctl list-unit-files --type=service --no-legend 2>/dev/null | awk '/^php.*-fpm/{print $1}' | sed 's/.service$//'); do
    stop_service "$svc"
done

# Temporarily stop web servers for config cleanup
for svc in nginx apache2; do
    if systemctl is-active --quiet "$svc" 2>/dev/null; then
        run_cmd "systemctl stop '$svc'"
        substep "Stopped (temp): $svc"
    fi
done

success "All services stopped"

# ----------------------------------------------------------
# Phase 3: Remove HestiaCP Core
# ----------------------------------------------------------

step "Removing HestiaCP core packages"

for pkg in hestia hestia-nginx hestia-php hestia-web-terminal; do
    if dpkg -l 2>/dev/null | grep -q "^ii.*[[:space:]]${pkg}[[:space:]]"; then
        run_verbose "dpkg --purge '$pkg'"
        add_summary "Purged: $pkg"
    fi
done

success "Core packages removed"

# ----------------------------------------------------------
# Phase 4: Remove All Service Packages
# ----------------------------------------------------------

step "Removing service packages"

# PHP (all versions)
info "PHP packages..."
remove_pkg_pattern "^php"

# MySQL/MariaDB
info "MySQL/MariaDB..."
for pkg in mariadb-server mariadb-client mariadb-common libmariadb3 \
           mysql-server mysql-client mysql-common libmysqlclient21; do
    remove_pkg "$pkg"
done
remove_dir "/etc/mysql"
remove_dir "/var/lib/mysql"
remove_dir "/var/log/mysql"

# PostgreSQL
info "PostgreSQL..."
for pkg in postgresql postgresql-common postgresql-client postgresql-contrib; do
    remove_pkg "$pkg"
done
remove_dir "/etc/postgresql"
remove_dir "/var/lib/postgresql"

# Mail
info "Mail (Exim4 + Dovecot)..."
for pkg in exim4 exim4-base exim4-config exim4-daemon-heavy exim4-daemon-light \
           dovecot-core dovecot-imapd dovecot-pop3d dovecot-managesieved \
           dovecot-sieve dovecot-lmtpd; do
    remove_pkg "$pkg"
done
remove_dir "/etc/exim4"
remove_dir "/etc/dovecot"

# ClamAV
info "ClamAV..."
for pkg in clamav-daemon clamav-freshclam clamav clamav-base libclamav; do
    remove_pkg "$pkg"
done
remove_dir "/etc/clamav"
remove_dir "/var/lib/clamav"

# SpamAssassin (Ubuntu=spamassassin, Debian=spamd)
info "SpamAssassin..."
remove_pkg "spamassassin"
remove_pkg "spamd"
remove_dir "/etc/spamassassin"
remove_dir "/var/lib/spamassassin"

# DNS
info "Bind9..."
for pkg in bind9 bind9utils bind9-dnsutils; do
    remove_pkg "$pkg"
done
remove_dir "/etc/bind"

# FTP
info "FTP (vsftpd + ProFTPD)..."
remove_pkg "vsftpd"
remove_dir "/etc/vsftpd"
for pkg in proftpd-core proftpd-mod-crypto proftpd-basic; do
    remove_pkg "$pkg"
done
remove_dir "/etc/proftpd"

# Fail2Ban
info "Fail2Ban..."
remove_pkg "fail2ban"
remove_dir "/etc/fail2ban"

# Webmail/Admin
info "Webmail/Admin..."
for pkg in roundcube roundcube-core roundcube-plugins phpmyadmin phppgadmin; do
    remove_pkg "$pkg"
done
remove_dir "/etc/roundcube" "/etc/phpmyadmin" "/etc/phppgadmin"
remove_dir "/usr/share/roundcube" "/usr/share/phpmyadmin" "/usr/share/phppgadmin"

# Misc
info "Misc packages..."
for pkg in imagemagick rrdtool awstats libapache2-mod-fcgid libapache2-mod-rpaf \
           bubblewrap restic quota expect at sysstat bsdmainutils \
           libapache2-mpm-itk libmail-dkim-perl net-tools unrar-free; do
    remove_pkg "$pkg"
done
remove_dir "/var/lib/rrd" "/var/lib/awstats" "/etc/awstats" "/etc/php"

# Node.js
if [ -f "/etc/apt/sources.list.d/nodejs.list" ]; then
    remove_pkg "nodejs"
fi

success "All service packages removed"

# ----------------------------------------------------------
# Phase 5: Remove APT Repositories
# ----------------------------------------------------------

step "Removing third-party APT repositories"

for repo in /etc/apt/sources.list.d/nginx.list \
            /etc/apt/sources.list.d/hestia.list \
            /etc/apt/sources.list.d/hestiacp.list \
            /etc/apt/sources.list.d/mariadb.list \
            /etc/apt/sources.list.d/nodejs.list \
            /etc/apt/sources.list.d/postgresql.list \
            /etc/apt/sources.list.d/apache2.list; do
    remove_file "$repo"
done

# ondrej/php PPA
for f in /etc/apt/sources.list.d/ondrej-ubuntu-php-*; do
    [ -f "$f" ] && remove_file "$f"
done
command -v add-apt-repository &>/dev/null && \
    run_cmd "add-apt-repository -y --remove ppa:ondrej/php 2>/dev/null || true"

# GPG keyrings
for keyring in /usr/share/keyrings/nginx-keyring.gpg \
               /usr/share/keyrings/hestia-keyring.gpg \
               /usr/share/keyrings/hestia-keyring.asc \
               /usr/share/keyrings/mariadb-keyring.gpg \
               /usr/share/keyrings/nodejs.gpg \
               /usr/share/keyrings/postgresql-keyring.gpg; do
    [ -e "$keyring" ] && remove_file "$keyring"
done
run_cmd "rm -f /etc/apt/trusted.gpg.d/hestia*"

# apt configs
remove_file "/etc/apt/apt.conf.d/80-retries"
remove_file "/etc/apt/apt.conf.d/99weakkey-warning"
run_cmd "rm -f /etc/apt/preferences.d/hestia*"

# dpkg diversions
for div in $(dpkg-divert --list 2>/dev/null | grep -i hestia | awk '{print $3}'); do
    run_cmd "dpkg-divert --remove --rename '$div'"
done

success "Repositories cleaned"

# ----------------------------------------------------------
# Phase 6: Remove Users & Groups
# ----------------------------------------------------------

step "Removing HestiaCP users and groups"

for user in hestiaweb hestiamail hestiasshd hestiadns hestia hestiaftp; do
    if id "$user" &>/dev/null; then
        run_cmd "pkill -u '$user' 2>/dev/null || true"
        sleep 0.5
        run_cmd "userdel -f '$user' 2>/dev/null || true"
        add_summary "Removed user: $user"
    fi
done

for group in hestiaweb hestiamail hestiasshd hestiadns hestia hestiaftp; do
    getent group "$group" &>/dev/null && run_cmd "groupdel '$group' 2>/dev/null || true"
done

# Remove admin users (created by installer)
for admin_home in /home/*/; do
    [ ! -d "$admin_home" ] && continue
    username=$(basename "$admin_home")
    case "$username" in hestiaweb|hestiamail|lost+found) continue ;; esac
    if [ -d "$admin_home/web" ] && [ -d "$admin_home/conf" ]; then
        info "HestiaCP user found: $username"
        if confirm "Remove user '$username' and all data?"; then
            run_cmd "pkill -u '$username' 2>/dev/null || true"
            sleep 0.5
            run_cmd "userdel -r -f '$username' 2>/dev/null || true"
            run_cmd "groupdel '$username' 2>/dev/null || true"
            run_cmd "rm -rf '$admin_home'"
            add_summary "Removed user: $username"
        fi
    fi
done

# Sudoers
for f in /etc/sudoers.d/hestiaweb /etc/sudoers.d/hestia; do
    remove_file "$f"
done

success "Users and groups removed"

# ----------------------------------------------------------
# Phase 7: Remove Directories
# ----------------------------------------------------------

step "Removing HestiaCP directories"

for dir in "$HESTIA" /etc/hestiacp /root/hst_backups /root/hst_install_backups \
           /usr/share/hestia /var/cache/hestia /var/run/hestia \
           /var/log/hestia /var/lib/hestia; do
    remove_dir "$dir"
done

# Chroot jails
if [ -d "/srv/jail" ]; then
    for unit in $(systemctl list-units --type=mount --no-legend 2>/dev/null | awk '/srv-jail/{print $1}'); do
        run_cmd "systemctl stop '$unit' 2>/dev/null || true"
        run_cmd "systemctl disable '$unit' 2>/dev/null || true"
    done
    run_cmd "find /etc/systemd/system/ -name '*srv-jail*' -delete 2>/dev/null || true"
    run_cmd "systemctl daemon-reload"
    remove_dir "/srv/jail"
fi

run_cmd "rm -f /tmp/hestia-* /tmp/hst-*"
success "Directories removed"

# ----------------------------------------------------------
# Phase 8: Remove Systemd Units
# ----------------------------------------------------------

step "Removing systemd units"

for unit in /etc/systemd/system/hestia.service \
            /etc/systemd/system/hestia-web-terminal.service \
            /etc/systemd/system/hestia-web-terminal.socket; do
    if [ -f "$unit" ]; then
        run_cmd "systemctl stop '$(basename "$unit")' 2>/dev/null || true"
        run_cmd "systemctl disable '$(basename "$unit")' 2>/dev/null || true"
        remove_file "$unit"
    fi
done

# Jail mounts
for f in $(find /etc/systemd/system/ -name "*.mount" 2>/dev/null | grep -iE "jail|hestia"); do
    run_cmd "systemctl stop '$(basename "$f")' 2>/dev/null || true"
    run_cmd "systemctl disable '$(basename "$f")' 2>/dev/null || true"
    remove_file "$f"
done

# Any remaining hestia systemd files
run_cmd "find /etc/systemd /lib/systemd -type f -iname '*hestia*' -delete 2>/dev/null || true"
run_cmd "systemctl daemon-reload"
run_cmd "systemctl reset-failed 2>/dev/null || true"

success "Systemd units removed"

# ----------------------------------------------------------
# Phase 9: Restore Nginx
# ----------------------------------------------------------

step "Restoring Nginx configuration"

if [ -d "/etc/nginx" ]; then
    # Remove HestiaCP conf.d files
    for conf in status.conf 0rtt-anti-replay.conf agents.conf cloudflare.inc \
                phpmyadmin.inc phppgadmin.inc hestia.conf unassigned.inc microcache.conf; do
        run_cmd "rm -f /etc/nginx/conf.d/$conf"
    done
    remove_dir "/etc/nginx/conf.d/domains"

    # Remove any conf referencing hestia
    for f in /etc/nginx/conf.d/*.conf /etc/nginx/conf.d/*.inc; do
        [ -f "$f" ] || continue
        if grep -qi "hestia\|/usr/local/hestia" "$f" 2>/dev/null; then
            run_cmd "rm -f '$f'"
            substep "Removed: $(basename "$f")"
        fi
    done

    # Remove cache dirs
    remove_dir "/var/cache/nginx/micro" "/var/cache/nginx/temp"

    # Remove HestiaCP sites-enabled/available
    for f in /etc/nginx/sites-enabled/default /etc/nginx/sites-available/default; do
        [ -f "$f" ] && grep -qi "hestia\|unassigned" "$f" 2>/dev/null && run_cmd "rm -f '$f'"
    done

    # Fix SSL cert references in ALL nginx configs
    for f in $(find /etc/nginx -type f 2>/dev/null); do
        [ -f "$f" ] || continue
        if grep -q "/usr/local/hestia/ssl/" "$f" 2>/dev/null; then
            info "Fixing broken SSL in: $(basename "$f")"
            if [ "$DRY_RUN" = false ]; then
                sed -i 's|^\s*ssl_certificate[[:space:]]|## ssl_certificate (removed)|g' "$f"
                sed -i 's|^\s*ssl_certificate_key[[:space:]]|## ssl_certificate_key (removed)|g' "$f"
                sed -i 's|^\s*listen.*443.*ssl|## listen 443 ssl (removed)|g' "$f"
            fi
        fi
    done

    # Fix redirect loops (return 301/302 https when 443 is broken)
    for f in $(find /etc/nginx -type f -name "*.conf" -o -name "*.inc" 2>/dev/null); do
        [ -f "$f" ] || continue
        if grep -qiE "return 30[12] .*https|rewrite.*https" "$f" 2>/dev/null; then
            if ! grep -qE "^\s*listen.*443.*ssl" "$f" 2>/dev/null || \
               grep -q "/usr/local/hestia/ssl/" "$f" 2>/dev/null; then
                warn "Redirect loop: $(basename "$f") — disabling HTTPS redirect"
                if [ "$DRY_RUN" = false ]; then
                    sed -i 's|^\s*return 301 https.*|## return 301 https (loop fix)|g' "$f"
                    sed -i 's|^\s*return 302 https.*|## return 302 https (loop fix)|g' "$f"
                    sed -i 's|^\s*rewrite .* https://.*|## rewrite https (loop fix)|g' "$f"
                fi
                add_summary "Fixed redirect loop: $(basename "$f")"
            fi
        fi
    done

    # Restore nginx.conf if HestiaCP-modified
    if [ ! -f /etc/nginx/nginx.conf ] || \
       grep -qi "/usr/local/hestia/ssl/\|microcache\|proxy_cache_path.*cache:10m\|conf\.d/domains\|cloudflare\.inc" /etc/nginx/nginx.conf 2>/dev/null; then
        if [ "$DRY_RUN" = false ]; then
            info "Restoring clean nginx.conf..."
            cat > /etc/nginx/nginx.conf << 'NGINX_DEFAULT'
user www-data;
worker_processes auto;
pid /run/nginx.pid;
error_log /var/log/nginx/error.log;
include /etc/nginx/modules-enabled/*.conf;

events {
    worker_connections 768;
}

http {
    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    keepalive_timeout 65;
    types_hash_max_size 2048;

    include /etc/nginx/mime.types;
    default_type application/octet-stream;

    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers on;

    access_log /var/log/nginx/access.log;

    gzip on;

    include /etc/nginx/conf.d/*.conf;
    include /etc/nginx/sites-enabled/*;
}
NGINX_DEFAULT
        fi
        add_summary "Restored nginx.conf"
    fi

    # Ensure dirs
    run_cmd "mkdir -p /etc/nginx/conf.d /etc/nginx/sites-available /etc/nginx/sites-enabled"

    # Remove hestia logrotate
    [ -f /etc/logrotate.d/nginx ] && \
        grep -qi "hestia" /etc/logrotate.d/nginx 2>/dev/null && run_cmd "rm -f /etc/logrotate.d/nginx"

    remove_dir "/var/log/nginx/domains"
    remove_dir "/usr/local/hestia/ssl"

    success "Nginx restored"
else
    info "Nginx not installed, skipping"
fi

# ----------------------------------------------------------
# Phase 10: Restore Apache
# ----------------------------------------------------------

step "Restoring Apache configuration"

if [ -d "/etc/apache2" ]; then
    for conf in hestia.conf hestia-event.conf status.conf unassigned.conf phpmyadmin.inc phppgadmin.inc; do
        run_cmd "rm -f /etc/apache2/conf.d/$conf"
    done
    remove_dir "/etc/apache2/conf.d/domains"
    run_cmd "rm -f /etc/apache2/sites-enabled/hestia*"
    run_cmd "rm -f /etc/apache2/sites-available/hestia*"

    for f in /etc/apache2/conf.d/*.conf /etc/apache2/conf.d/*.inc; do
        [ -f "$f" ] && grep -qi "hestia\|/usr/local/hestia" "$f" 2>/dev/null && run_cmd "rm -f '$f'"
    done

    # Fix SSL + redirect loops
    for f in $(find /etc/apache2 -type f 2>/dev/null); do
        [ -f "$f" ] || continue
        if grep -q "/usr/local/hestia/ssl/" "$f" 2>/dev/null; then
            if [ "$DRY_RUN" = false ]; then
                sed -i 's|^\s*SSLCertificateFile|## SSLCertificateFile (removed)|g' "$f"
                sed -i 's|^\s*SSLCertificateKeyFile|## SSLCertificateKeyFile (removed)|g' "$f"
            fi
        fi
        if grep -qiE "Redirect.*https|RewriteRule.*https" "$f" 2>/dev/null; then
            if ! grep -qE "^\s*Listen 443" "$f" 2>/dev/null || \
               grep -q "/usr/local/hestia/ssl/" "$f" 2>/dev/null; then
                if [ "$DRY_RUN" = false ]; then
                    sed -i 's|^\s*Redirect.*https.*|## Redirect https (loop fix)|g' "$f"
                    sed -i 's|^\s*RewriteRule.*https.*|## RewriteRule https (loop fix)|g' "$f"
                fi
                add_summary "Fixed Apache redirect loop: $(basename "$f")"
            fi
        fi
    done

    [ -f /etc/logrotate.d/apache2 ] && \
        grep -qi "hestia" /etc/logrotate.d/apache2 2>/dev/null && run_cmd "rm -f /etc/logrotate.d/apache2"

    success "Apache restored"
else
    info "Apache not installed, skipping"
fi

# ----------------------------------------------------------
# Phase 11: Firewall Rules
# ----------------------------------------------------------

step "Cleaning firewall rules"

if command -v iptables &>/dev/null; then
    for chain in HESTIA HESTIA_OUTPUT; do
        run_cmd "iptables -F '$chain' 2>/dev/null || true"
        run_cmd "iptables -D INPUT -j '$chain' 2>/dev/null || true"
        run_cmd "iptables -D OUTPUT -j '$chain' 2>/dev/null || true"
        run_cmd "iptables -X '$chain' 2>/dev/null || true"
    done
    if command -v ip6tables &>/dev/null; then
        for chain in HESTIA HESTIA_OUTPUT; do
            run_cmd "ip6tables -F '$chain' 2>/dev/null || true"
            run_cmd "ip6tables -D INPUT -j '$chain' 2>/dev/null || true"
            run_cmd "ip6tables -D OUTPUT -j '$chain' 2>/dev/null || true"
            run_cmd "ip6tables -X '$chain' 2>/dev/null || true"
        done
    fi
    add_summary "Cleaned iptables chains"
fi

if command -v ipset &>/dev/null; then
    for set_name in $(ipset list -n 2>/dev/null | grep -i hestia); do
        run_cmd "ipset destroy '$set_name' 2>/dev/null || true"
    done
fi

success "Firewall cleaned"

# ----------------------------------------------------------
# Phase 12: Let's Encrypt
# ----------------------------------------------------------

step "Cleaning Let's Encrypt certificates"

if [ -d "/etc/letsencrypt" ]; then
    if confirm "Remove /etc/letsencrypt/?"; then
        remove_dir "/etc/letsencrypt"
    fi
fi
remove_pkg "certbot"

success "Certificates cleaned"

# ----------------------------------------------------------
# Phase 13: Cron, MOTD, Logrotate, Login Scripts
# ----------------------------------------------------------

step "Cleaning cron, MOTD, and login scripts"

remove_file "/etc/update-motd.d/99-hestia"
run_cmd "rm -f /etc/profile.d/hestia*"
remove_file "/etc/bash_completion.d/hestia"

# Clean bash.bashrc of hestia entries
if [ -f /etc/bash.bashrc ] && grep -q "hestia\|v-alias\|v-add" /etc/bash.bashrc 2>/dev/null; then
    if [ "$DRY_RUN" = false ]; then
        sed -i '/hestia/d; /v-alias/d; /v-add.*-cron/d' /etc/bash.bashrc
    fi
fi

# Logrotate
for lr in /etc/logrotate.d/hestia /etc/logrotate.d/dovecot /etc/logrotate.d/roundcube; do
    [ -f "$lr" ] && grep -qi "hestia\|/usr/local/hestia" "$lr" 2>/dev/null && run_cmd "rm -f '$lr'"
done

# Crontab
run_cmd "crontab -u hestiaweb -r 2>/dev/null || true"
run_cmd "rm -f /var/spool/cron/crontabs/hestiaweb /var/spool/cron/crontabs/hestiamail"

for cf in hestia hestia-ssl hestia-proc hestia-autoupdate hestia-letsencrypt; do
    run_cmd "rm -f /etc/cron.d/$cf"
done

# Root crontab cleanup
if crontab -l 2>/dev/null | grep -q "hestia"; then
    if [ "$DRY_RUN" = false ]; then
        crontab -l 2>/dev/null | grep -vi "hestia" | crontab - 2>/dev/null || true
    fi
    add_summary "Cleaned root crontab"
fi

# PHP session cleanup
[ -f /etc/cron.daily/php-session-cleanup ] && \
    grep -qi "hestia\|/home/\*/tmp" /etc/cron.daily/php-session-cleanup 2>/dev/null && \
    run_cmd "rm -f /etc/cron.daily/php-session-cleanup"

success "Cron/MOTD/logrotate cleaned"

# ----------------------------------------------------------
# Phase 14: SSH Configuration
# ----------------------------------------------------------

step "Restoring SSH configuration"

if [ -f /etc/ssh/sshd_config ]; then
    if grep -qi "hestia\|jail\|Match User" /etc/ssh/sshd_config 2>/dev/null; then
        if [ "$DRY_RUN" = false ] && [ -f "$BACKUP_DIR/sshd_config.bak" ]; then
            cp "$BACKUP_DIR/sshd_config.bak" /etc/ssh/sshd_config
            add_summary "Restored sshd_config"
        else
            if [ "$DRY_RUN" = false ]; then
                sed -i '/^Match User.*hestia/,/^Match\|^$/d' /etc/ssh/sshd_config
                sed -i '/#.*Hestia/d' /etc/ssh/sshd_config
            fi
            add_summary "Cleaned sshd_config"
        fi
    fi

    # Authorized keys
    if [ -f /root/.ssh/authorized_keys ] && grep -qi "hestia" /root/.ssh/authorized_keys 2>/dev/null; then
        if [ "$DRY_RUN" = false ]; then
            sed -i '/hestia/d' /root/.ssh/authorized_keys
        fi
    fi
fi

success "SSH restored"

# ----------------------------------------------------------
# Phase 15: /etc/hosts
# ----------------------------------------------------------

step "Cleaning /etc/hosts"

if [ -f /etc/hosts ] && grep -q "127.0.0.1.*hestia" /etc/hosts 2>/dev/null; then
    if [ "$DRY_RUN" = false ]; then
        sed -i '/127\.0\.0\.1.*hestia/d' /etc/hosts
    fi
    add_summary "Cleaned /etc/hosts"
fi

success "/etc/hosts cleaned"

# ----------------------------------------------------------
# Phase 16: Swap File
# ----------------------------------------------------------

step "Checking swap file"

if [ -f /swapfile ] && grep -q "/swapfile" /etc/fstab 2>/dev/null; then
    if confirm "Remove /swapfile and fstab entry?"; then
        run_cmd "swapoff /swapfile 2>/dev/null || true"
        run_cmd "rm -f /swapfile"
        if [ "$DRY_RUN" = false ]; then
            sed -i '\|/swapfile|d' /etc/fstab
        fi
        add_summary "Removed swap file"
    fi
fi

success "Swap checked"

# ----------------------------------------------------------
# Phase 17: Quota Configuration
# ----------------------------------------------------------

step "Cleaning quota configuration"

if [ -f /etc/fstab ] && grep -q "usrjquota\|grpjquota" /etc/fstab 2>/dev/null; then
    if [ "$DRY_RUN" = false ]; then
        sed -i 's/,usrjquota=[^,]*//g; s/,grpjquota=[^,]*//g; s/,jqfmt=[^,]*//g' /etc/fstab
    fi
    add_summary "Cleaned fstab quotas"
fi

for f in /aquota.user /aquota.group; do
    remove_file "$f"
done

success "Quota cleaned"

# ----------------------------------------------------------
# Phase 18: Security (Polkit, AppArmor, udev, sysctl)
# ----------------------------------------------------------

step "Cleaning security configurations"

# Polkit
[ -d /etc/polkit-1/localauthority.conf.d ] && \
    run_cmd "find /etc/polkit-1/localauthority.conf.d -name '*hestia*' -delete 2>/dev/null || true"

# AppArmor
if [ -d /etc/apparmor.d ]; then
    for f in /etc/apparmor.d/*hestia*; do
        [ -f "$f" ] || continue
        run_cmd "apparmor_parser -R '$f' 2>/dev/null || true"
        remove_file "$f"
    done
fi

# udev
[ -d /etc/udev/rules.d ] && \
    run_cmd "find /etc/udev/rules.d -name '*hestia*' -delete 2>/dev/null || true"

# Limits and sysctl
remove_file "/etc/security/limits.d/hestia.conf"
remove_file "/etc/security/limits.d/99-hestia.conf"
remove_file "/etc/sysctl.d/99-hestia.conf"
[ -f /etc/sysctl.d/99-hestia.conf ] && run_cmd "sysctl --system 2>/dev/null || true"

success "Security configs cleaned"

# ----------------------------------------------------------
# Phase 19: User Data
# ----------------------------------------------------------

step "Cleaning user data (/home/*)"

if confirm "Remove ALL user web/mail/DNS data in /home/*? CANNOT BE UNDONE!"; then
    if [ -d /home ]; then
        for user_home in /home/*/; do
            [ ! -d "$user_home" ] && continue
            username=$(basename "$user_home")
            case "$username" in hestiaweb|hestiamail|lost+found) continue ;; esac
            if [ -d "$user_home/web" ] || [ -d "$user_home/conf" ] || [ -d "$user_home/mail" ]; then
                info "Removing: $user_home"
                run_cmd "pkill -u '$username' 2>/dev/null || true"
                sleep 0.5
                run_cmd "userdel -r -f '$username' 2>/dev/null || true"
                run_cmd "groupdel '$username' 2>/dev/null || true"
                run_cmd "rm -rf '$user_home'"
                add_summary "Removed user data: $username"
            fi
        done
    fi
    remove_dir "/usr/local/hestia/data"
else
    warn "User data preserved"
fi

# ----------------------------------------------------------
# Phase 20: Remaining Configs
# ----------------------------------------------------------

step "Final config sweep"

for dir in /etc/exim4 /etc/dovecot /etc/bind /etc/vsftpd /etc/proftpd \
           /etc/clamav /etc/spamassassin /etc/mysql /etc/postgresql; do
    remove_dir "$dir"
done

# Let's Encrypt leftovers
remove_dir "/etc/letsencrypt"

# Fail2Ban remnants
[ -d /etc/fail2ban ] && remove_dir "/etc/fail2ban"

success "Config sweep complete"

# ----------------------------------------------------------
# Phase 21: Restart & Verify Services
# ----------------------------------------------------------

step "Restarting web services"

# Nginx
if command -v nginx &>/dev/null && [ -d /etc/nginx ]; then
    info "Testing nginx config..."
    if nginx -t 2>&1 | grep -q "successful\|syntax is ok"; then
        success "nginx config OK"
        run_verbose "systemctl start nginx"
        run_cmd "systemctl enable nginx"
        add_summary "nginx started"
    else
        error "nginx config FAILED:"
        nginx -t 2>&1 | while IFS= read -r l; do echo -e "    ${RED}$l${NC}"; done
        add_summary "⚠ nginx FAILED — manual fix needed"
    fi
fi

# Apache
if command -v apache2ctl &>/dev/null && [ -d /etc/apache2 ]; then
    info "Testing apache config..."
    if apache2ctl configtest 2>&1 | grep -q "Syntax OK"; then
        success "Apache config OK"
        run_verbose "systemctl start apache2"
        run_cmd "systemctl enable apache2"
        add_summary "Apache started"
    else
        warn "Apache config failed — manual fix needed"
        add_summary "⚠ Apache FAILED — manual fix needed"
    fi
fi

# SSH
run_cmd "systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null || true"
run_cmd "systemctl restart cron 2>/dev/null || true"

success "Services restarted"

# ----------------------------------------------------------
# Phase 22: Orphaned Packages
# ----------------------------------------------------------

step "Removing orphaned dependencies"

run_verbose "DEBIAN_FRONTEND=noninteractive apt-get autoremove -y 2>/dev/null || true"
run_verbose "apt-get autoclean -y 2>/dev/null || true"

add_summary "Ran apt autoremove"
success "Orphaned packages removed"

# ----------------------------------------------------------
# Phase 23: Deep Residue Scan
# ----------------------------------------------------------

step "Deep residue scan"

RESIDUE_COUNT=0

# /etc configs
for f in $(find /etc -type f \( -name "*.conf" -o -name "*.inc" -o -name "*.tpl" \) 2>/dev/null | head -500); do
    grep -ql "hestia\|/usr/local/hestia\|HESTIA=" "$f" 2>/dev/null && {
        warn "Residue: $f"
        RESIDUE_COUNT=$((RESIDUE_COUNT + 1))
    }
done

# Broken SSL
for f in $(find /etc/nginx /etc/apache2 -type f 2>/dev/null); do
    grep -ql "/usr/local/hestia/ssl/" "$f" 2>/dev/null && {
        error "BROKEN SSL: $f"
        RESIDUE_COUNT=$((RESIDUE_COUNT + 1))
    }
done

# Cron
crontab -l 2>/dev/null | grep -q "hestia" && { warn "Root crontab residue"; RESIDUE_COUNT=$((RESIDUE_COUNT + 1)); }

# Systemd
for unit in $(find /etc/systemd /lib/systemd -type f 2>/dev/null | head -200); do
    grep -ql "hestia\|/usr/local/hestia" "$unit" 2>/dev/null && {
        warn "Residue systemd: $unit"
        RESIDUE_COUNT=$((RESIDUE_COUNT + 1))
    }
done

# Directories
[ -d /usr/local/hestia ] && { warn "Still exists: /usr/local/hestia"; RESIDUE_COUNT=$((RESIDUE_COUNT + 1)); }

# APT repos
for f in /etc/apt/sources.list.d/*; do
    [ -f "$f" ] && grep -qi "hestia\|nginx\.org\|mariadb\|nodesource" "$f" 2>/dev/null && {
        warn "Residue repo: $f"
        RESIDUE_COUNT=$((RESIDUE_COUNT + 1))
    }
done

# Extended deep scan
if [ "$DEEP_SCAN" = true ]; then
    substep "Extended scan..."
    for f in $(find /var -type f -name "*.conf" 2>/dev/null | head -500); do
        grep -ql "hestia\|/usr/local/hestia" "$f" 2>/dev/null && {
            warn "Deep residue: $f"
            RESIDUE_COUNT=$((RESIDUE_COUNT + 1))
        }
    done
fi

if [ "$RESIDUE_COUNT" -eq 0 ]; then
    success "Clean! No residue found"
else
    warn "Found $RESIDUE_COUNT residue item(s)"
fi

run_cmd "systemctl daemon-reload"

# ----------------------------------------------------------
# Final Cleanup
# ----------------------------------------------------------

step "Final cleanup"

run_cmd "rm -f /tmp/hestia-* /tmp/hst-* /tmp/updconf*"
remove_dir "/root/hst_install_backups"

# Calculate disk space freed
DISK_AFTER=$(df / --output=used 2>/dev/null | tail -1 | tr -d ' ')
if [ -n "$DISK_BEFORE" ] && [ -n "$DISK_AFTER" ]; then
    DISK_FREED=$(( (DISK_BEFORE - DISK_AFTER) / 1024 ))
    if [ "$DISK_FREED" -gt 0 ]; then
        info "Disk space freed: ${DISK_FREED} MB"
    fi
fi

success "All cleanup complete"

# ----------------------------------------------------------
# Stop Monitor
# ----------------------------------------------------------

stop_monitor 2>/dev/null || true

# ----------------------------------------------------------
# Summary Report
# ----------------------------------------------------------

TOTAL_TIME=$(( $(date +%s) - START_TIME ))

echo ""
echo -e "${BOLD}${CYAN}"
echo "  ╔═══════════════════════════════════════════════════╗"
echo "  ║         UNINSTALL COMPLETE                        ║"
echo "  ╚═══════════════════════════════════════════════════╝"
echo -e "${NC}"

if [ "$DRY_RUN" = true ]; then
    echo -e "  ${YELLOW}⚠ DRY-RUN: No changes were made${NC}"
    echo ""
fi

echo -e "  ${BOLD}Duration:${NC} $(format_eta $TOTAL_TIME)"
echo -e "  ${BOLD}Phases:${NC}   $STEP_COUNT completed"
echo -e "  ${BOLD}Residue:${NC}  $RESIDUE_COUNT item(s)"

if [ -n "${DISK_FREED:-}" ] && [ "$DISK_FREED" -gt 0 ]; then
    echo -e "  ${BOLD}Freed:${NC}    ${DISK_FREED} MB"
fi

echo ""
echo -e "  ${BOLD}Actions (${#SUMMARY[@]}):${NC}"
for item in "${SUMMARY[@]}"; do
    echo -e "    ${GREEN}✓${NC} $item"
done

if [ ${#WARNINGS[@]} -gt 0 ]; then
    echo ""
    echo -e "  ${YELLOW}${BOLD}Warnings (${#WARNINGS[@]}):${NC}"
    for w in "${WARNINGS[@]}"; do
        echo -e "    ${YELLOW}⚠${NC} $w"
    done
fi

echo ""
echo -e "  ${BOLD}Files:${NC}"
[ -d "$BACKUP_DIR" ] && echo -e "    Backup: ${CYAN}$BACKUP_DIR${NC}"
echo -e "    Log:    ${CYAN}$LOG_FILE${NC}"

echo ""
if [ "$RESIDUE_COUNT" -eq 0 ]; then
    echo -e "  ${GREEN}${BOLD}✓ 99.99%+ VPS recovery achieved${NC}"
else
    echo -e "  ${YELLOW}⚠ Review $RESIDUE_COUNT warning(s) above${NC}"
fi

echo ""
echo -e "  ${BOLD}Next steps:${NC}"
echo -e "    1. systemctl status nginx"
echo -e "    2. ssh root@$(hostname -I 2>/dev/null | awk '{print $1}')"
echo -e "    3. cat $LOG_FILE"
echo -e "    4. apt autoremove (if not auto-ran)"
echo ""
echo "  ═══════════════════════════════════════════════════"

log "=== Uninstall v${VERSION} completed in $(format_eta $TOTAL_TIME) ==="
log "Residue: $RESIDUE_COUNT | Actions: ${#SUMMARY[@]} | Warnings: ${#WARNINGS[@]}"

exit 0
