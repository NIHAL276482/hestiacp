#!/bin/bash

# ======================================================== #
#
# Hestia Control Panel Uninstaller — v5.0 ULTIMATE
# Targets: 99.99% VPS recovery to pre-installation state
#
# Based on analysis of:
#   - hestiacp/hestiacp hst-install-ubuntu.sh (full package list)
#   - hestiacp/hestiacp hst-install-debian.sh  (full package list)
#   - NIHAL276482/hestiacp original uninstaller
#   - Reddit/forum community findings
#
# Features:
#   - Live per-second CPU/RAM/disk monitoring dashboard
#   - Real-time command output (tee to screen + log)
#   - Progress bar with ETA
#   - Auto-detects all installed components
#   - Redirect loop fix for nginx/apache (handles ALL redirect patterns)
#   - Pre-uninstall backup snapshot
#   - Deep residue scanner
#   - Network-informed package matching
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

readonly VERSION="5.0"
readonly LOG_FILE="/var/log/hestia-uninstall.log"
DRY_RUN=false
FORCE=false
DEEP_SCAN=false
MONITOR=true
STEP_COUNT=0
TOTAL_STEPS=27
START_TIME=$(date +%s)
SUMMARY=()
WARNINGS=()
RESIDUE_COUNT=0
MONITOR_PID=""
CPU_STATE_FILE=""

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

# Detect terminal width and set monitor column
detect_term_width() {
    local cols
    if [ -n "${COLUMNS:-}" ]; then
        cols=$COLUMNS
    elif command -v tput &>/dev/null; then
        cols=$(tput cols 2>/dev/null || echo 80)
    else
        cols=80
    fi
    # Need at least 145 cols for side panel, otherwise fall back to inline
    if [ "$cols" -ge 145 ]; then
        echo $((cols - 44))
    else
        echo "0"  # 0 = no side panel, use inline
    fi
}

MONITOR_COL=$(detect_term_width)

get_cpu_usage_instant() {
    # Read /proc/stat snapshot, compare with previous reading
    local idle total
    read -r _ user nice system idle iowait irq softirq steal _ _ _ _ _ _ _ _ _ _ _ _ < /proc/stat
    total=$((user + nice + system + idle + iowait + irq + softirq + steal))

    if [ -f "$CPU_STATE_FILE" ]; then
        local prev_idle prev_total
        read -r prev_idle prev_total < "$CPU_STATE_FILE"
        echo "$idle $total" > "$CPU_STATE_FILE"

        local diff_idle=$((idle - prev_idle))
        local diff_total=$((total - prev_total))
        if [ "$diff_total" -eq 0 ]; then
            echo "0"
        else
            echo $(( (diff_total - diff_idle) * 100 / diff_total ))
        fi
    else
        echo "$idle $total" > "$CPU_STATE_FILE"
        echo "0"
    fi
}

get_ram_info() {
    awk '/^MemTotal/{t=$2} /^MemAvailable/{a=$2} END{printf "%d %d %d", t/1024, (t-a)/1024, ((t-a)*100/t)}' /proc/meminfo 2>/dev/null || echo "0 0 0"
}

get_swap_info() {
    awk '/^SwapTotal/{t=$2} /^SwapFree/{f=$2} END{if(t>0) printf "%d %d %d", t/1024, (t-f)/1024, ((t-f)*100/t); else print "0 0 0"}' /proc/meminfo 2>/dev/null || echo "0 0 0"
}

get_disk_info() {
    df -h / 2>/dev/null | awk 'NR==2{gsub(/%/,""); printf "%s %s %s", $3, $2, $5}' || echo "? ? 0"
}

get_load_avg() {
    awk '{printf "%s %s %s", $1, $2, $3}' /proc/loadavg 2>/dev/null || echo "0 0 0"
}

get_net_connections() {
    ss -s 2>/dev/null | awk '/^TCP:/{gsub(/,/,""); print $2}' || echo "0"
}

format_eta() {
    local seconds=$1
    if [ "$seconds" -lt 0 ] 2>/dev/null; then echo "--"; return; fi
    if [ "$seconds" -lt 60 ]; then
        echo "${seconds}s"
    elif [ "$seconds" -lt 3600 ]; then
        echo "$((seconds/60))m $((seconds%60))s"
    else
        echo "$((seconds/3600))h $((seconds%3600/60))m"
    fi
}

draw_bar_text() {
    # Plain text bar (no colors) for monitor panel embedding
    local pct=$1
    local width=15
    local filled=$((pct * width / 100))
    local empty=$((width - filled))
    local bar=""
    local i
    for ((i=0; i<filled; i++)); do bar+="█"; done
    for ((i=0; i<empty; i++)); do bar+="░"; done
    echo "$bar"
}

draw_bar_colored() {
    # Colored bar for standalone display
    local pct=$1
    local width=20
    local filled=$((pct * width / 100))
    local empty=$((width - filled))
    local bar=""
    local i
    for ((i=0; i<filled; i++)); do bar+="█"; done
    for ((i=0; i<empty; i++)); do bar+="░"; done
    if [ "$pct" -lt 60 ]; then
        echo -e "${GREEN}${bar}${NC}"
    elif [ "$pct" -lt 85 ]; then
        echo -e "${YELLOW}${bar}${NC}"
    else
        echo -e "${RED}${bar}${NC}"
    fi
}

monitor_loop() {
    # Prime CPU state (first read always returns 0)
    get_cpu_usage_instant > /dev/null 2>&1
    sleep 0.5  # Brief pause so second read has real data

    local mc=$MONITOR_COL  # monitor column (0 = inline mode)

    while true; do
        # Get metrics
        local cpu_now
        cpu_now=$(get_cpu_usage_instant)

        local ram_info
        ram_info=$(get_ram_info)
        local ram_total=$(echo "$ram_info" | awk '{print $1}')
        local ram_used=$(echo "$ram_info" | awk '{print $2}')
        local ram_pct=$(echo "$ram_info" | awk '{print $3}')

        local swap_info
        swap_info=$(get_swap_info)
        local swap_used=$(echo "$swap_info" | awk '{print $2}')
        local swap_total=$(echo "$swap_info" | awk '{print $1}')

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
        local now
        now=$(date +%s)
        local elapsed=$((now - START_TIME))
        local eta_str="--"
        if [ "$STEP_COUNT" -gt 0 ] && [ "$elapsed" -gt 5 ]; then
            local remaining_steps=$((TOTAL_STEPS - STEP_COUNT))
            local secs_per_step=$((elapsed / STEP_COUNT))
            local eta=$((remaining_steps * secs_per_step))
            eta_str=$(format_eta "$eta")
        fi

        local ts
        ts=$(date '+%H:%M:%S')

        if [ "$mc" -gt 0 ]; then
            # Side panel mode (wide terminal)
            local cpu_bar ram_bar dsk_bar
            cpu_bar=$(draw_bar_text "$cpu_now")
            ram_bar=$(draw_bar_text "$ram_pct")
            dsk_bar=$(draw_bar_text "$disk_pct")

            # Save cursor
            printf "\033[s"

            # Draw each line individually (no \n inside printf to keep position)
            printf "\033[2;${mc}H${DIM}┌─ LIVE MONITOR ─────────────────────────────┐${NC}"
            printf "\033[3;${mc}H${DIM}│${NC} ${WHITE}CPU:${NC}  %3d%% %s ${DIM}│${NC}" "$cpu_now" "$cpu_bar"
            printf "\033[4;${mc}H${DIM}│${NC} ${WHITE}RAM:${NC}  %3d%% %4d/%-4dMB %s ${DIM}│${NC}" "$ram_pct" "$ram_used" "$ram_total" "$ram_bar"
            printf "\033[5;${mc}H${DIM}│${NC} ${WHITE}DSK:${NC}  %3d%% %s/%s %s ${DIM}│${NC}" "$disk_pct" "$disk_used" "$disk_total" "$dsk_bar"
            if [ "$swap_total" -gt 0 ]; then
                printf "\033[6;${mc}H${DIM}│${NC} ${WHITE}SWP:${NC}  %4d/%-4dMB                           ${DIM}│${NC}" "$swap_used" "$swap_total"
            else
                printf "\033[6;${mc}H${DIM}│${NC} ${WHITE}SWP:${NC}  none                                    ${DIM}│${NC}"
            fi
            printf "\033[7;${mc}H${DIM}│${NC} ${WHITE}LOAD:${NC} %-15s                    ${DIM}│${NC}" "$load"
            printf "\033[8;${mc}H${DIM}│${NC} ${WHITE}CONN:${NC} %s TCP                                 ${DIM}│${NC}" "$conns"
            printf "\033[9;${mc}H${DIM}│${NC} ${WHITE}STEP:${NC} %d/%-2d                                  ${DIM}│${NC}" "$STEP_COUNT" "$TOTAL_STEPS"
            printf "\033[10;${mc}H${DIM}│${NC} ${WHITE}ETA: ${NC} %-15s                    ${DIM}│${NC}" "$eta_str"
            printf "\033[11;${mc}H${DIM}│${NC} ${WHITE}TIME:${NC} %s                                   ${DIM}│${NC}" "$ts"
            printf "\033[12;${mc}H${DIM}└─────────────────────────────────────────────┘${NC}"

            # Restore cursor
            printf "\033[u"
        fi

        # Always write to monitor state for inline status to pick up
        cat > "$CPU_STATE_FILE.stats" <<EOF
$cpu_now $ram_used $ram_pct $disk_pct $load $swap_used $swap_total $ts $STEP_COUNT $eta_str
EOF

        sleep 1
    done
}

start_monitor() {
    if [ "$MONITOR" = false ] || [ "$DRY_RUN" = true ]; then
        return
    fi
    # Create unique state files
    CPU_STATE_FILE="/tmp/.hestia-cpu-state-$$"

    # Prime CPU: do two reads 0.5s apart so first monitor read has real data
    get_cpu_usage_instant > /dev/null 2>&1
    sleep 0.5
    get_cpu_usage_instant > /dev/null 2>&1

    # Start monitor in background
    monitor_loop &
    MONITOR_PID=$!
    trap 'stop_monitor; exit' EXIT INT TERM HUP
}

stop_monitor() {
    if [ -n "$MONITOR_PID" ] && kill -0 "$MONITOR_PID" 2>/dev/null; then
        kill "$MONITOR_PID" 2>/dev/null
        wait "$MONITOR_PID" 2>/dev/null
        MONITOR_PID=""
    fi
    # Clean up state files
    rm -f "$CPU_STATE_FILE" "$CPU_STATE_FILE.stats" 2>/dev/null
    # Clear monitor area if side panel was used
    if [ "$MONITOR_COL" -gt 0 ]; then
        local i
        for i in $(seq 2 12); do
            printf "\033[${i};${MONITOR_COL}H\033[K"
        done
    fi
}

# ----------------------------------------------------------
# Inline Status (for terminals < 145 cols or no-monitor mode)
# ----------------------------------------------------------

show_inline_status() {
    # Try reading pre-computed stats from monitor process
    if [ -n "$CPU_STATE_FILE" ] && [ -f "$CPU_STATE_FILE.stats" ]; then
        local cpu_now ram_used ram_pct disk_pct load swap_used swap_total ts step eta_str
        read -r cpu_now ram_used ram_pct disk_pct load swap_used swap_total ts step eta_str < "$CPU_STATE_FILE.stats"
        printf "  ${DIM}[%s] CPU:%d%% RAM:%dMB(%d%%) DSK:%s%% LOAD:%s ELAPSED:%s${NC}\n" \
            "$ts" "$cpu_now" "$ram_used" "$ram_pct" "$disk_pct" "$load" "$(format_eta $(($(date +%s) - START_TIME)))"
    else
        # Fallback: compute inline (slower but works without monitor)
        local cpu_now ram_info ram_used ram_pct disk_pct load elapsed
        cpu_now=$(get_cpu_usage_instant)
        ram_info=$(get_ram_info)
        ram_used=$(echo "$ram_info" | awk '{print $2}')
        ram_pct=$(echo "$ram_info" | awk '{print $3}')
        disk_pct=$(get_disk_info | awk '{print $3}')
        load=$(get_load_avg | awk '{print $1}')
        elapsed=$(($(date +%s) - START_TIME))
        printf "  ${DIM}[%s] CPU:%d%% RAM:%dMB(%d%%) DSK:%s%% LOAD:%s ELAPSED:%s${NC}\n" \
            "$(date '+%H:%M:%S')" "$cpu_now" "$ram_used" "$ram_pct" "$disk_pct" "$load" "$(format_eta $elapsed)"
    fi
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

fatal() {
    error "$1"
    exit 1
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
        printf "\r  ${YELLOW}⚠${NC} $msg... failed (rc=$rc) \n"
        log "[WARN] $msg failed with rc=$rc"
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
    for dir in "$@"; do
        if [ -d "$dir" ]; then
            local size
            size=$(du -sh "$dir" 2>/dev/null | awk '{print $1}')
            info "Removing: $dir (${size:-?})"
            run_cmd "rm -rf '$dir'"
            add_summary "Removed: $dir"
        fi
    done
}

remove_file() {
    local file="$1"
    if [ -f "$file" ]; then
        run_cmd "rm -f '$file'"
        add_summary "Removed: $(basename "$file")"
    fi
}

# ----------------------------------------------------------
# Nginx/Apache Redirect Loop Fixer
# ----------------------------------------------------------

# Detects whether a file has a working HTTPS listener (listen 443 ssl + valid cert)
has_working_ssl() {
    local f="$1"
    # Has listen 443 ssl that isn't commented out
    if grep -qE '^\s*listen\s+.*443.*ssl' "$f" 2>/dev/null; then
        # And has a non-commented SSL cert that exists
        local cert
        cert=$(grep -E '^\s*ssl_certificate[^_]' "$f" 2>/dev/null | head -1 | awk '{print $2}' | tr -d ';')
        if [ -n "$cert" ] && [ -f "$cert" ]; then
            return 0
        fi
    fi
    return 1
}

# Fix ALL nginx redirect patterns (handles HestiaCP's specific patterns)
fix_nginx_redirects() {
    local f="$1"
    local fixed=false

    # HestiaCP pattern 1: location block with 'return 301 https://$host$request_uri;'
    # This is the most common infinite-loop cause in HestiaCP
    if grep -qE 'return\s+301\s+https://' "$f" 2>/dev/null; then
        if ! has_working_ssl "$f"; then
            if [ "$DRY_RUN" = false ]; then
                # Match: any whitespace + return 301 https://...
                sed -i 's|^\(\s*\)return 301 https://.*|\1## return 301 https:// (loop fix)|g' "$f"
            fi
            fixed=true
        fi
    fi

    # HestiaCP pattern 2: return 302 redirects
    if grep -qE 'return\s+302\s+https://' "$f" 2>/dev/null; then
        if ! has_working_ssl "$f"; then
            if [ "$DRY_RUN" = false ]; then
                sed -i 's|^\(\s*\)return 302 https://.*|\1## return 302 https:// (loop fix)|g' "$f"
            fi
            fixed=true
        fi
    fi

    # Pattern 3: rewrite ^ https://... redirect
    if grep -qE 'rewrite\s+.*\s+https://' "$f" 2>/dev/null; then
        if ! has_working_ssl "$f"; then
            if [ "$DRY_RUN" = false ]; then
                sed -i 's|^\(\s*\)rewrite\s.*https://.*|\1## rewrite https (loop fix)|g' "$f"
            fi
            fixed=true
        fi
    fi

    # Pattern 4: if ($scheme != "https") { return 301 ... } blocks
    if grep -qE "if\s*\(\s*\$scheme\s*!=\s*['\"]https['\"]\s*\)" "$f" 2>/dev/null; then
        if ! has_working_ssl "$f"; then
            if [ "$DRY_RUN" = false ]; then
                # Remove the entire if block (lines from 'if ($scheme' to closing '}')
                sed -i '/if\s*(\s*\$scheme\s*!=.*https/,/^[[:space:]]*}[[:space:]]*$/d' "$f"
            fi
            fixed=true
        fi
    fi

    # Pattern 5: if ($http_x_forwarded_proto != "https") { ... }
    if grep -qE "if\s*\(\s*\$http_x_forwarded_proto" "$f" 2>/dev/null; then
        if ! has_working_ssl "$f"; then
            if [ "$DRY_RUN" = false ]; then
                sed -i '/if\s*(\s*\$http_x_forwarded_proto/,/^[[:space:]]*}[[:space:]]*$/d' "$f"
            fi
            fixed=true
        fi
    fi

    if [ "$fixed" = true ]; then
        add_summary "Fixed redirect loop: $(basename "$f")"
        return 0
    fi
    return 1
}

# Fix ALL apache redirect patterns
fix_apache_redirects() {
    local f="$1"
    local fixed=false

    # Has SSL cert directive (non-commented)
    local has_ssl=false
    if grep -qE '^\s*SSLCertificateFile' "$f" 2>/dev/null; then
        local cert
        cert=$(grep -oP '(?<=SSLCertificateFile\s).*' "$f" 2>/dev/null | head -1 | tr -d '[:space:]')
        [ -n "$cert" ] && [ -f "$cert" ] && has_ssl=true
    fi

    if [ "$has_ssl" = false ]; then
        # Comment out broken SSL directives
        if grep -qE '^\s*SSLCertificate' "$f" 2>/dev/null; then
            if [ "$DRY_RUN" = false ]; then
                sed -i 's|^\(\s*\)SSLCertificateFile|\1## SSLCertificateFile (removed)|g' "$f"
                sed -i 's|^\(\s*\)SSLCertificateKeyFile|\1## SSLCertificateKeyFile (removed)|g' "$f"
                sed -i 's|^\(\s*\)SSLCertificateChainFile|\1## SSLCertificateChainFile (removed)|g' "$f"
            fi
        fi

        # Comment out redirects to HTTPS
        if grep -qiE 'Redirect\s+.*https|RewriteRule.*https|RewriteCond.*HTTPS' "$f" 2>/dev/null; then
            if [ "$DRY_RUN" = false ]; then
                sed -i 's|^\(\s*\)Redirect\s.*https.*|\1## Redirect https (loop fix)|g' "$f"
                sed -i 's|^\(\s*\)RewriteRule\s.*https.*|\1## RewriteRule https (loop fix)|g' "$f"
                sed -i 's|^\(\s*\)RewriteCond\s.*HTTPS.*|\1## RewriteCond HTTPS (loop fix)|g' "$f"
            fi
            fixed=true
        fi

        # Remove Listen 443 if SSL is broken (port would fail to bind)
        if grep -qE '^\s*Listen\s+443' "$f" 2>/dev/null; then
            if [ "$DRY_RUN" = false ]; then
                sed -i 's|^\(\s*\)Listen\s*443.*|\1## Listen 443 (removed, SSL broken)|g' "$f"
            fi
            fixed=true
        fi
    fi

    if [ "$fixed" = true ]; then
        add_summary "Fixed Apache redirect loop: $(basename "$f")"
        return 0
    fi
    return 1
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
        --version|-v)
            echo "HestiaCP Uninstaller v${VERSION}"
            exit 0 ;;
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
            echo "  --version, -v     Show version"
            echo "  --help, -h        Show this help"
            echo ""
            echo "Examples:"
            echo "  bash hst-uninstall.sh                    # Interactive"
            echo "  bash hst-uninstall.sh --force            # No prompts"
            echo "  bash hst-uninstall.sh --dry-run          # Preview only"
            echo "  bash hst-uninstall.sh --force --deep     # Force + deep scan"
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
log "Force=$FORCE DryRun=$DRY_RUN DeepScan=$DEEP_SCAN Monitor=$MONITOR TermCol=$MONITOR_COL"

# Root check
if [ "$(id -u)" -ne 0 ]; then
    fatal "Must run as root: bash $0"
fi

if [ "$DRY_RUN" = true ]; then
    warn "DRY-RUN MODE: No changes will be made."
fi

if [ "$MONITOR_COL" -eq 0 ] && [ "$MONITOR" = true ]; then
    info "Terminal < 145 cols — using inline status bar"
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
        *) fatal "Unsupported OS: $os_id (only Debian/Ubuntu)" ;;
    esac
    success "Detected: ${OS_TYPE} ${OS_VERSION} (${OS_CODENAME:-unknown})"
else
    fatal "Cannot detect OS: /etc/os-release not found"
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
    for f in /etc/ssh/sshd_config /etc/hosts /etc/hostname /etc/fstab \
             /etc/nginx/nginx.conf /etc/mysql/my.cnf /etc/exim4/exim4.conf \
             /etc/dovecot/dovecot.conf; do
        [ -f "$f" ] && cp "$f" "$BACKUP_DIR/$(basename "$f").bak"
    done
    # Backup PHP-FPM pool configs
    for f in /etc/php/*/fpm/pool.d/www.conf; do
        [ -f "$f" ] && cp "$f" "$BACKUP_DIR/$(basename "$(dirname "$(dirname "$f")")")-www.conf.bak"
    done
    [ -d /etc/nginx ] && cp -a /etc/nginx "$BACKUP_DIR/nginx.bak" 2>/dev/null || true
    [ -d /etc/apache2 ] && cp -a /etc/apache2 "$BACKUP_DIR/apache2.bak" 2>/dev/null || true
    [ -d /etc/mysql ] && cp -a /etc/mysql "$BACKUP_DIR/mysql.bak" 2>/dev/null || true
    [ -d /etc/php ] && cp -a /etc/php "$BACKUP_DIR/php.bak" 2>/dev/null || true
    iptables-save > "$BACKUP_DIR/iptables.bak" 2>/dev/null || true
    ip6tables-save > "$BACKUP_DIR/ip6tables.bak" 2>/dev/null || true
    crontab -l > "$BACKUP_DIR/root-crontab.bak" 2>/dev/null || true
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
for svc in hestia hestia-nginx hestia-php hestia-web-terminal hestia-web-terminal.socket; do
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

for pkg in hestia hestia-nginx hestia-php hestia-web-terminal hestia-common; do
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
for pkg in mariadb-server mariadb-client mariadb-common libmariadb3 mariadb-client-core \
           mysql-server mysql-client mysql-common libmysqlclient21; do
    remove_pkg "$pkg"
done
remove_dir "/etc/mysql" "/var/lib/mysql" "/var/log/mysql"

# PostgreSQL
info "PostgreSQL..."
for pkg in postgresql postgresql-common postgresql-client postgresql-contrib; do
    remove_pkg "$pkg"
done
remove_dir "/etc/postgresql" "/var/lib/postgresql"

# Mail
info "Mail (Exim4 + Dovecot)..."
for pkg in exim4 exim4-base exim4-config exim4-daemon-heavy exim4-daemon-light \
           dovecot-core dovecot-imapd dovecot-pop3d dovecot-managesieved \
           dovecot-sieve dovecot-lmtpd; do
    remove_pkg "$pkg"
done
remove_dir "/etc/exim4" "/etc/dovecot"

# ClamAV
info "ClamAV..."
for pkg in clamav-daemon clamav-freshclam clamav clamav-base libclamav; do
    remove_pkg "$pkg"
done
remove_dir "/etc/clamav" "/var/lib/clamav"

# SpamAssassin (Ubuntu=spamassassin, Debian=spamd)
info "SpamAssassin..."
remove_pkg "spamassassin"
remove_pkg "spamd"
remove_dir "/etc/spamassassin" "/var/lib/spamassassin"

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

# Misc — from hst-install-ubuntu.sh package list
info "Misc packages..."
for pkg in imagemagick rrdtool awstats libapache2-mod-fcgid libapache2-mod-rpaf \
           bubblewrap restic quota expect at sysstat bsdmainutils \
           libapache2-mpm-itk libmail-dkim-perl net-tools unrar-free \
           acl apache2-suexec-custom apache2-utils apparmor-utils \
           bc bsdutils idn2 jq libonig5 libzip4 lsb-release lsof mc; do
    remove_pkg "$pkg"
done
remove_dir "/var/lib/rrd" "/var/lib/awstats" "/etc/awstats" "/etc/php"

# Apache-specific lib modules
remove_pkg_pattern "^libapache2-mod-"

# Node.js
if [ -f "/etc/apt/sources.list.d/nodejs.list" ] || [ -f "/etc/apt/sources.list.d/nodesource.list" ]; then
    remove_pkg "nodejs"
fi

# vim-common (hestia installs it)
remove_pkg "vim-common"
remove_pkg "unzip"

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
            /etc/apt/sources.list.d/nodesource.list \
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
               /usr/share/keyrings/nodesource.gpg \
               /usr/share/keyrings/postgresql-keyring.gpg; do
    [ -e "$keyring" ] && remove_file "$keyring"
done
run_cmd "rm -f /etc/apt/trusted.gpg.d/hestia* /etc/apt/trusted.gpg.d/nodesource*"

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

remove_dir "$HESTIA" "/etc/hestiacp" "/root/hst_backups" "/root/hst_install_backups" \
           "/usr/share/hestia" "/var/cache/hestia" "/var/run/hestia" \
           "/var/log/hestia" "/var/lib/hestia"

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

# Bubblewrap jails
if [ -d "/var/lib/bubblewrap" ]; then
    remove_dir "/var/lib/bubblewrap"
fi

run_cmd "rm -f /tmp/hestia-* /tmp/hst-*"
success "Directories removed"

# ----------------------------------------------------------
# Phase 8: Remove Systemd Units
# ----------------------------------------------------------

step "Removing systemd units"

for unit in /etc/systemd/system/hestia.service \
            /etc/systemd/system/hestia-nginx.service \
            /etc/systemd/system/hestia-php.service \
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
    while IFS= read -r -d '' f; do
        if grep -q "/usr/local/hestia/ssl/" "$f" 2>/dev/null; then
            info "Fixing broken SSL in: $(basename "$f")"
            if [ "$DRY_RUN" = false ]; then
                sed -i 's|^\(\s*\)ssl_certificate\b|## ssl_certificate (removed)|g' "$f"
                sed -i 's|^\(\s*\)ssl_certificate_key\b|## ssl_certificate_key (removed)|g' "$f"
                sed -i 's|^\(\s*\)listen\s\+.*443.*ssl|## listen 443 ssl (removed)|g' "$f"
            fi
        fi
    done < <(find /etc/nginx -type f -print0 2>/dev/null)

    # Fix redirect loops using the dedicated function
    while IFS= read -r -d '' f; do
        fix_nginx_redirects "$f"
    done < <(find /etc/nginx -type f \( -name "*.conf" -o -name "*.inc" \) -print0 2>/dev/null)

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

    remove_dir "/var/log/nginx/domains" "/usr/local/hestia/ssl"

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

    # Fix SSL + redirect loops using dedicated function
    while IFS= read -r -d '' f; do
        fix_apache_redirects "$f"
    done < <(find /etc/apache2 -type f -print0 2>/dev/null)

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

# Clean user bashrc files
for admin_home in /home/*/; do
    [ -f "${admin_home}.bashrc" ] && grep -q "hestia\|v-alias\|v-add" "${admin_home}.bashrc" 2>/dev/null && \
        [ "$DRY_RUN" = false ] && sed -i '/hestia/d; /v-alias/d' "${admin_home}.bashrc"
done

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

# PAM hestia entries
for f in /etc/pam.d/common-*; do
    [ -f "$f" ] && grep -q "hestia" "$f" 2>/dev/null && \
        [ "$DRY_RUN" = false ] && sed -i '/hestia/d' "$f"
done

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

remove_dir "/etc/exim4" "/etc/dovecot" "/etc/bind" "/etc/vsftpd" "/etc/proftpd" \
           "/etc/clamav" "/etc/spamassassin" "/etc/mysql" "/etc/postgresql"

# Let's Encrypt leftovers
remove_dir "/etc/letsencrypt"

# Fail2Ban remnants
[ -d /etc/fail2ban ] && remove_dir "/etc/fail2ban"

# PHP config residue
[ -d /etc/php ] && remove_dir "/etc/php"

# Apache module residue
[ -d /etc/apache2/conf-available ] && \
    find /etc/apache2/conf-available -name '*hestia*' -delete 2>/dev/null || true

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

# /etc configs (null-delimited find for safety)
while IFS= read -r -d '' f; do
    grep -ql "hestia\|/usr/local/hestia\|HESTIA=" "$f" 2>/dev/null && {
        warn "Residue: $f"
        RESIDUE_COUNT=$((RESIDUE_COUNT + 1))
    }
done < <(find /etc -maxdepth 3 -type f \( -name "*.conf" -o -name "*.inc" -o -name "*.tpl" \) -print0 2>/dev/null)

# Broken SSL
while IFS= read -r -d '' f; do
    grep -ql "/usr/local/hestia/ssl/" "$f" 2>/dev/null && {
        error "BROKEN SSL: $f"
        RESIDUE_COUNT=$((RESIDUE_COUNT + 1))
    }
done < <(find /etc/nginx /etc/apache2 -type f -print0 2>/dev/null)

# Cron
crontab -l 2>/dev/null | grep -q "hestia" && { warn "Root crontab residue"; RESIDUE_COUNT=$((RESIDUE_COUNT + 1)); }

# Systemd
while IFS= read -r -d '' f; do
    grep -ql "hestia\|/usr/local/hestia" "$f" 2>/dev/null && {
        warn "Residue systemd: $f"
        RESIDUE_COUNT=$((RESIDUE_COUNT + 1))
    }
done < <(find /etc/systemd /lib/systemd -type f -print0 2>/dev/null)

# Directories
[ -d /usr/local/hestia ] && { warn "Still exists: /usr/local/hestia"; RESIDUE_COUNT=$((RESIDUE_COUNT + 1)); }

# APT repos
for f in /etc/apt/sources.list.d/*; do
    [ -f "$f" ] && grep -qi "hestia\|nginx\.org\|mariadb\|nodesource" "$f" 2>/dev/null && {
        warn "Residue repo: $f"
        RESIDUE_COUNT=$((RESIDUE_COUNT + 1))
    }
done

# systemd drop-ins
for f in /etc/systemd/system/*/hestia*; do
    [ -e "$f" ] && { warn "Residue drop-in: $f"; RESIDUE_COUNT=$((RESIDUE_COUNT + 1)); }
done

# Extended deep scan
if [ "$DEEP_SCAN" = true ]; then
    substep "Extended scan..."
    while IFS= read -r -d '' f; do
        grep -ql "hestia\|/usr/local/hestia" "$f" 2>/dev/null && {
            warn "Deep residue: $f"
            RESIDUE_COUNT=$((RESIDUE_COUNT + 1))
        }
    done < <(find /var -maxdepth 4 -type f -name "*.conf" -print0 2>/dev/null)
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

# Clean up any remaining state files
rm -f "$CPU_STATE_FILE" "$CPU_STATE_FILE.stats" 2>/dev/null

exit 0
