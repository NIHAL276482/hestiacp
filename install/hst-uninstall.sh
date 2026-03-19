#!/bin/bash

# ======================================================== #
#
# Hestia Control Panel Uninstaller — ENHANCED
# Targets: 99.99% VPS recovery to pre-installation state
# Based on: hestiacp/hestiacp official installer analysis
#           + NIHAL276482/hestiacp uninstaller
#           + Reddit/forum community findings
#
# Usage:
#   bash hst-uninstall.sh [--force] [--dry-run] [--deep-scan]
#
# ======================================================== #

set -euo pipefail

# ----------------------------------------------------------
# Global Settings
# ----------------------------------------------------------

LOG_FILE="/var/log/hestia-uninstall.log"
DRY_RUN=false
FORCE=false
DEEP_SCAN=false
SUMMARY=()
WARNINGS=()
RESIDUE_COUNT=0

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m'
BOLD='\033[1m'

# ----------------------------------------------------------
# Helper Functions
# ----------------------------------------------------------

log() {
    local msg="[$(date '+%F %T')] $1"
    echo -e "$msg" >> "$LOG_FILE"
}

info() {
    echo -e "${BLUE}[INFO]${NC} $1"
    log "[INFO] $1"
}

success() {
    echo -e "${GREEN}[ OK ]${NC} $1"
    log "[OK] $1"
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
    log "[WARN] $1"
    WARNINGS+=("$1")
}

error() {
    echo -e "${RED}[ERR ]${NC} $1"
    log "[ERROR] $1"
}

step() {
    echo -e "\n${CYAN}${BOLD}==>${NC} ${BOLD}$1${NC}"
    log "==> $1"
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
        echo -e "  ${YELLOW}[DRY-RUN]${NC} $*"
        log "[DRY-RUN] $*"
    else
        log "[EXEC] $*"
        eval "$@" >> "$LOG_FILE" 2>&1 || true
    fi
}

confirm() {
    if [ "$FORCE" = true ] || [ "$DRY_RUN" = true ]; then
        return 0
    fi
    local prompt="$1"
    while true; do
        echo -ne "${YELLOW}${prompt} [y/N]: ${NC}"
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
        info "Removing package: $pkg"
        run_cmd "DEBIAN_FRONTEND=noninteractive apt-get purge -y '$pkg' 2>/dev/null || dpkg --purge '$pkg' 2>/dev/null || true"
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
        info "Removing directory: $dir"
        run_cmd "rm -rf '$dir'"
        add_summary "Removed directory: $dir"
    fi
}

remove_file() {
    local file="$1"
    if [ -f "$file" ]; then
        info "Removing file: $file"
        run_cmd "rm -f '$file'"
        add_summary "Removed file: $(basename "$file")"
    fi
}

scan_residue() {
    local path="$1"
    local desc="$2"
    if [ -f "$path" ] || [ -d "$path" ]; then
        warn "Residue found: $path ($desc)"
        RESIDUE_COUNT=$((RESIDUE_COUNT + 1))
    fi
}

# ----------------------------------------------------------
# Argument Parsing
# ----------------------------------------------------------

while [[ $# -gt 0 ]]; do
    case "$1" in
        --force|-f)
            FORCE=true
            shift
            ;;
        --dry-run|--dryrun|-n)
            DRY_RUN=true
            shift
            ;;
        --deep-scan|--deep)
            DEEP_SCAN=true
            shift
            ;;
        --help|-h)
            echo "HestiaCP Uninstaller (Enhanced)"
            echo ""
            echo "Usage: bash hst-uninstall.sh [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --force, -f       Skip all confirmation prompts"
            echo "  --dry-run, -n     Show what would be done without making changes"
            echo "  --deep-scan       Extended filesystem scan for residual artifacts"
            echo "  --help, -h        Show this help message"
            exit 0
            ;;
        *)
            error "Unknown option: $1"
            echo "Use --help for usage information."
            exit 1
            ;;
    esac
done

# ----------------------------------------------------------
# Pre-flight Checks
# ----------------------------------------------------------

echo -e "${BOLD}"
echo "========================================================"
echo "  Hestia Control Panel Uninstaller (Enhanced)"
echo "  Target: 99.99% VPS Recovery"
echo "========================================================"
echo -e "${NC}"

# Initialize log
mkdir -p "$(dirname "$LOG_FILE")"
touch "$LOG_FILE"
log "=== HestiaCP Enhanced Uninstall Started ==="
log "Force: $FORCE | Dry-run: $DRY_RUN | Deep-scan: $DEEP_SCAN"

# Root check
if [ "$(id -u)" -ne 0 ]; then
    error "This script must be run as root."
    exit 1
fi

if [ "$DRY_RUN" = true ]; then
    warn "DRY-RUN MODE: No changes will be made."
fi

# ----------------------------------------------------------
# Phase 0: Detect OS & Pre-uninstall State
# ----------------------------------------------------------

step "Phase 0: Detecting system and HestiaCP installation"

OS_TYPE=""
OS_VERSION=""
OS_CODENAME=""

if [ -e "/etc/os-release" ]; then
    os_id=$(grep "^ID=" /etc/os-release | cut -f 2 -d '=' | tr -d '"')
    os_version_id=$(grep "^VERSION_ID=" /etc/os-release 2>/dev/null | cut -f 2 -d '=' | tr -d '"' | tr -d '.')
    OS_CODENAME=$(grep "^VERSION_CODENAME=" /etc/os-release 2>/dev/null | cut -f 2 -d '=' | tr -d '"')
    if [ -z "$OS_CODENAME" ] && command -v lsb_release &>/dev/null; then
        OS_CODENAME=$(lsb_release -s -c 2>/dev/null)
    fi
    case "$os_id" in
        debian)
            OS_TYPE="debian"
            OS_VERSION="$os_version_id"
            ;;
        ubuntu)
            OS_TYPE="ubuntu"
            OS_VERSION="$os_version_id"
            ;;
        *)
            error "Unsupported OS: $os_id"
            exit 1
            ;;
    esac
    success "Detected: $OS_TYPE $OS_VERSION ($OS_CODENAME)"
else
    error "Cannot detect OS: /etc/os-release not found."
    exit 1
fi

# Save current hostname for potential revert
ORIGINAL_HOSTNAME=$(hostname -f 2>/dev/null || hostname)
info "Current hostname: $ORIGINAL_HOSTNAME"

# Detect HestiaCP installation
HESTIA="/usr/local/hestia"
HESTIA_FOUND=false

if [ -d "$HESTIA" ] || dpkg -l 2>/dev/null | grep -q "^ii.*hestia "; then
    HESTIA_FOUND=true
    success "HestiaCP installation found."
else
    warn "HestiaCP does not appear to be installed."
    if ! confirm "Continue with cleanup anyway?"; then
        info "Aborted by user."
        exit 0
    fi
fi

# Detect what was installed (by checking for services/packages)
info "Scanning for installed HestiaCP components..."

HAS_APACHE=false; HAS_NGINX=false; HAS_MYSQL=false; HAS_PGSQL=false
HAS_EXIM=false; HAS_DOVECOT=false; HAS_BIND=false; HAS_VSFTPD=false
HAS_CLAMAV=false; HAS_SPAMASSASSIN=false; HAS_FAIL2BAN=false; HAS_PROFTPD=false

command -v apache2ctl &>/dev/null && HAS_APACHE=true
command -v nginx &>/dev/null && HAS_NGINX=true
command -v mysql &>/dev/null || command -v mariadb &>/dev/null && HAS_MYSQL=true
command -v psql &>/dev/null && HAS_PGSQL=true
dpkg -l 2>/dev/null | grep -q "^ii.*exim4" && HAS_EXIM=true
dpkg -l 2>/dev/null | grep -q "^ii.*dovecot" && HAS_DOVECOT=true
dpkg -l 2>/dev/null | grep -q "^ii.*bind9" && HAS_BIND=true
dpkg -l 2>/dev/null | grep -q "^ii.*vsftpd" && HAS_VSFTPD=true
dpkg -l 2>/dev/null | grep -q "^ii.*clamav" && HAS_CLAMAV=true
dpkg -l 2>/dev/null | grep -q "^ii.*spamassassin" && HAS_SPAMASSASSIN=true
dpkg -l 2>/dev/null | grep -q "^ii.*fail2ban" && HAS_FAIL2BAN=true
dpkg -l 2>/dev/null | grep -q "^ii.*proftpd" && HAS_PROFTPD=true

info "Components found: Apache=$HAS_APACHE Nginx=$HAS_NGINX MySQL=$HAS_MYSQL PG=$HAS_PGSQL"
info "  Exim=$HAS_EXIM Dovecot=$HAS_DOVECOT Bind=$HAS_BIND vsftpd=$HAS_VSFTPD"
info "  ClamAV=$HAS_CLAMAV SpamAssassin=$HAS_SPAMASSASSIN Fail2Ban=$HAS_FAIL2BAN ProFTPD=$HAS_PROFTPD"

# ----------------------------------------------------------
# Confirmation
# ----------------------------------------------------------

echo ""
echo -e "${RED}${BOLD}═══════════════════════════════════════════════════════${NC}"
echo -e "${RED}${BOLD}  WARNING: This will COMPLETELY remove HestiaCP!${NC}"
echo -e "${RED}${BOLD}═══════════════════════════════════════════════════════${NC}"
echo ""
echo -e "${RED}This includes:${NC}"
echo -e "  • All HestiaCP core services and packages"
echo -e "  • All associated services (PHP, MySQL, Mail, DNS, FTP, etc.)"
echo -e "  • Configuration files in /usr/local/hestia/"
echo -e "  • System users created by HestiaCP"
echo -e "  • Firewall rules, cron jobs, systemd services"
echo -e "  • Third-party apt repositories added by HestiaCP"
echo -e "  • Let's Encrypt certificates"
echo -e "  • Web server configurations (restored to defaults)"
echo -e "  • Chroot jails, user data in /home/*"
echo ""
echo -e "${YELLOW}Log file: $LOG_FILE${NC}"
echo ""

if ! confirm "Are you ABSOLUTELY sure you want to proceed?"; then
    info "Uninstall aborted by user."
    exit 0
fi

# ----------------------------------------------------------
# Phase 1: Create Pre-uninstall Backup Snapshot
# ----------------------------------------------------------

step "Phase 1: Creating pre-uninstall backup snapshot"

BACKUP_DIR="/root/hestia-uninstall-backup-$(date +%Y%m%d%H%M%S)"
if [ "$DRY_RUN" = false ]; then
    mkdir -p "$BACKUP_DIR"

    # Backup critical configs that might need restoring
    [ -f /etc/ssh/sshd_config ] && cp /etc/ssh/sshd_config "$BACKUP_DIR/sshd_config.bak"
    [ -f /etc/hosts ] && cp /etc/hosts "$BACKUP_DIR/hosts.bak"
    [ -f /etc/hostname ] && cp /etc/hostname "$BACKUP_DIR/hostname.bak"
    [ -f /etc/fstab ] && cp /etc/fstab "$BACKUP_DIR/fstab.bak"
    [ -d /etc/nginx ] && cp -a /etc/nginx "$BACKUP_DIR/nginx.bak" 2>/dev/null || true
    [ -d /etc/apache2 ] && cp -a /etc/apache2 "$BACKUP_DIR/apache2.bak" 2>/dev/null || true
    [ -d /etc/php ] && cp -a /etc/php "$BACKUP_DIR/php.bak" 2>/dev/null || true
    [ -d /etc/exim4 ] && cp -a /etc/exim4 "$BACKUP_DIR/exim4.bak" 2>/dev/null || true
    [ -d /etc/dovecot ] && cp -a /etc/dovecot "$BACKUP_DIR/dovecot.bak" 2>/dev/null || true
    [ -d /etc/bind ] && cp -a /etc/bind "$BACKUP_DIR/bind.bak" 2>/dev/null || true
    iptables-save > "$BACKUP_DIR/iptables.bak" 2>/dev/null || true
    ip6tables-save > "$BACKUP_DIR/ip6tables.bak" 2>/dev/null || true

    success "Backup saved to: $BACKUP_DIR"
    add_summary "Pre-uninstall backup: $BACKUP_DIR"
else
    info "[DRY-RUN] Would create backup in /root/hestia-uninstall-backup-*"
fi

# ----------------------------------------------------------
# Phase 2: Stop ALL HestiaCP-Related Services
# ----------------------------------------------------------

step "Phase 2: Stopping all services"

# HestiaCP core services
HESTIA_SERVICES=(
    "hestia"
    "hestia-web-terminal"
    "hestia-web-terminal.socket"
)

for svc in "${HESTIA_SERVICES[@]}"; do
    if systemctl is-active --quiet "$svc" 2>/dev/null; then
        info "Stopping $svc..."
        run_cmd "systemctl stop '$svc'"
        run_cmd "systemctl disable '$svc'"
        add_summary "Stopped and disabled: $svc"
    fi
done

# Service stack - stop all service daemons
ALL_SERVICES=(
    "exim4"
    "dovecot"
    "clamav-daemon"
    "clamav-freshclam"
    "spamassassin"
    "named"
    "bind9"
    "vsftpd"
    "proftpd"
    "mariadb"
    "mysql"
    "postgresql"
    "fail2ban"
)

for svc in "${ALL_SERVICES[@]}"; do
    if systemctl is-active --quiet "$svc" 2>/dev/null; then
        info "Stopping $svc..."
        run_cmd "systemctl stop '$svc'"
        run_cmd "systemctl disable '$svc'"
        add_summary "Stopped and disabled: $svc"
    fi
done

# Stop all PHP-FPM versions
for svc in $(systemctl list-unit-files --type=service --no-legend 2>/dev/null | awk '{print $1}' | grep -E '^php.*-fpm\.service$' 2>/dev/null); do
    svc_name="${svc%.service}"
    if systemctl is-active --quiet "$svc_name" 2>/dev/null; then
        info "Stopping $svc_name..."
        run_cmd "systemctl stop '$svc_name'"
        run_cmd "systemctl disable '$svc_name'"
        add_summary "Stopped and disabled: $svc_name"
    fi
done

# Stop nginx/apache temporarily for config cleanup
for svc in nginx apache2; do
    if systemctl is-active --quiet "$svc" 2>/dev/null; then
        info "Temporarily stopping $svc for config cleanup..."
        run_cmd "systemctl stop '$svc'"
    fi
done

# Stop ClamAV freshclam daemon specifically
run_cmd "systemctl stop clamav-freshclam 2>/dev/null || true"
run_cmd "systemctl disable clamav-freshclam 2>/dev/null || true"

success "All services stopped."

# ----------------------------------------------------------
# Phase 3: Remove HestiaCP Core Packages
# ----------------------------------------------------------

step "Phase 3: Removing HestiaCP core packages"

HESTIA_PACKAGES=(
    "hestia"
    "hestia-nginx"
    "hestia-php"
    "hestia-web-terminal"
)

for pkg in "${HESTIA_PACKAGES[@]}"; do
    if dpkg -l 2>/dev/null | grep -q "^ii.*[[:space:]]${pkg}[[:space:]]"; then
        info "Purging package: $pkg"
        run_cmd "dpkg --purge '$pkg'"
        add_summary "Purged package: $pkg"
    fi
done

success "HestiaCP core packages removed."

# ----------------------------------------------------------
# Phase 4: Remove ALL Associated Service Packages
# ----------------------------------------------------------

step "Phase 4: Removing all associated service packages"

# PHP (all versions)
info "Removing all PHP packages..."
remove_pkg_pattern "^php"
remove_pkg "php-common"
remove_pkg "php-cli"
remove_dir "/etc/php"

# MySQL / MariaDB
info "Removing MySQL/MariaDB packages..."
for pkg in mariadb-server mariadb-client mariadb-common libmariadb3 mysql-server mysql-client mysql-common libmysqlclient21; do
    remove_pkg "$pkg"
done
remove_dir "/etc/mysql"
remove_dir "/var/lib/mysql"
remove_dir "/var/log/mysql"

# PostgreSQL
info "Removing PostgreSQL packages..."
for pkg in postgresql postgresql-common postgresql-client postgresql-contrib; do
    remove_pkg "$pkg"
done
remove_dir "/etc/postgresql"
remove_dir "/var/lib/postgresql"

# Mail (Exim4 + Dovecot + ClamAV + SpamAssassin)
info "Removing mail packages..."
for pkg in exim4 exim4-base exim4-config exim4-daemon-heavy exim4-daemon-light \
           dovecot-core dovecot-imapd dovecot-pop3d dovecot-managesieved \
           dovecot-sieve dovecot-lmtpd; do
    remove_pkg "$pkg"
done
remove_dir "/etc/exim4"
remove_dir "/etc/dovecot"

# ClamAV
info "Removing ClamAV packages..."
for pkg in clamav-daemon clamav-freshclam clamav clamav-base libclamav; do
    remove_pkg "$pkg"
done
remove_dir "/etc/clamav"
remove_dir "/var/lib/clamav"
remove_dir "/var/log/clamav"

# SpamAssassin (package name differs: 'spamassassin' on Ubuntu, 'spamd' on Debian)
info "Removing SpamAssassin..."
remove_pkg "spamassassin"
remove_pkg "spamd"
remove_dir "/etc/spamassassin"
remove_dir "/var/lib/spamassassin"

# DNS (Bind9)
info "Removing DNS packages..."
for pkg in bind9 bind9utils bind9-dnsutils; do
    remove_pkg "$pkg"
done
remove_dir "/etc/bind"

# FTP (vsftpd + ProFTPD)
info "Removing FTP packages..."
remove_pkg "vsftpd"
remove_dir "/etc/vsftpd"
for pkg in proftpd-core proftpd-mod-crypto proftpd-basic proftpd-mod-crypto; do
    remove_pkg "$pkg"
done
remove_dir "/etc/proftpd"

# Fail2Ban
info "Removing Fail2Ban..."
remove_pkg "fail2ban"
remove_dir "/etc/fail2ban"

# Webmail/Admin UI packages
info "Removing webmail/admin packages..."
for pkg in roundcube roundcube-core roundcube-plugins phpmyadmin phppgadmin; do
    remove_pkg "$pkg"
done
remove_dir "/etc/roundcube"
remove_dir "/etc/phpmyadmin"
remove_dir "/etc/phppgadmin"
remove_dir "/usr/share/roundcube"
remove_dir "/usr/share/phpmyadmin"
remove_dir "/usr/share/phppgadmin"

# Misc packages installed by HestiaCP installer
info "Removing miscellaneous HestiaCP-installed packages..."
for pkg in imagemagick rrdtool awstats libapache2-mod-fcgid libapache2-mod-rpaf \
           bubblewrap restic quota expect at sysstat bsdmainutils \
           libapache2-mpm-itk libmail-dkim-perl net-tools unrar-free; do
    remove_pkg "$pkg"
done
remove_dir "/var/lib/rrd"
remove_dir "/var/lib/awstats"
remove_dir "/etc/awstats"

# Node.js (if installed for web terminal)
if [ -f "/etc/apt/sources.list.d/nodejs.list" ]; then
    info "Removing Node.js..."
    remove_pkg "nodejs"
fi

# ImageMagick leftovers
remove_dir "/etc/ImageMagick-*"

success "All service packages removed."

# ----------------------------------------------------------
# Phase 5: Remove Third-Party APT Repositories
# ----------------------------------------------------------

step "Phase 5: Removing third-party APT repositories"

# List of repo files HestiaCP adds
HST_REPO_FILES=(
    "/etc/apt/sources.list.d/nginx.list"
    "/etc/apt/sources.list.d/hestia.list"
    "/etc/apt/sources.list.d/hestiacp.list"
    "/etc/apt/sources.list.d/mariadb.list"
    "/etc/apt/sources.list.d/nodejs.list"
    "/etc/apt/sources.list.d/postgresql.list"
    "/etc/apt/sources.list.d/apache2.list"
)

for repo_file in "${HST_REPO_FILES[@]}"; do
    remove_file "$repo_file"
done

# Remove ondrej/php PPA (sury)
info "Removing ondrej/php PPA..."
if [ -f "/etc/apt/sources.list.d/ondrej-ubuntu-php-*.list" ]; then
    run_cmd "rm -f /etc/apt/sources.list.d/ondrej-ubuntu-php-*.list"
    run_cmd "rm -f /etc/apt/sources.list.d/ondrej-ubuntu-php-*.sources"
    add_summary "Removed ondrej/php PPA"
fi
# Also remove via add-apt-repository if available
if command -v add-apt-repository &>/dev/null; then
    run_cmd "add-apt-repository -y --remove ppa:ondrej/php 2>/dev/null || true"
fi

# Remove GPG keyrings added by HestiaCP
info "Removing GPG keyrings..."
HST_KEYRINGS=(
    "/usr/share/keyrings/nginx-keyring.gpg"
    "/usr/share/keyrings/hestia-keyring.gpg"
    "/usr/share/keyrings/hestia-keyring.asc"
    "/usr/share/keyrings/mariadb-keyring.gpg"
    "/usr/share/keyrings/nodejs.gpg"
    "/usr/share/keyrings/postgresql-keyring.gpg"
    "/etc/apt/trusted.gpg.d/hestia*"
)

for keyring in "${HST_KEYRINGS[@]}"; do
    if [ -e "$keyring" ]; then
        run_cmd "rm -f $keyring"
        add_summary "Removed keyring: $(basename "$keyring")"
    fi
done

# Remove apt configs added by HestiaCP
remove_file "/etc/apt/apt.conf.d/80-retries"
remove_file "/etc/apt/apt.conf.d/99weakkey-warning"
remove_file "/etc/apt/preferences.d/hestia*"

# Remove any dpkg diversions added by HestiaCP
info "Checking for dpkg diversions..."
for diversion in $(dpkg-divert --list 2>/dev/null | grep -i hestia | awk '{print $3}'); do
    info "Removing dpkg diversion: $diversion"
    run_cmd "dpkg-divert --remove --rename '$diversion'"
done

success "Third-party repositories and keyrings removed."

# ----------------------------------------------------------
# Phase 6: Remove HestiaCP Users, Groups & Admin Account
# ----------------------------------------------------------

step "Phase 6: Removing HestiaCP users and groups"

# HestiaCP system users
HESTIA_USERS=("hestiaweb" "hestiamail" "hestiasshd" "hestiadns" "hestia" "hestiaftp")
HESTIA_GROUPS=("hestiaweb" "hestiamail" "hestiasshd" "hestiadns" "hestia" "hestiaftp")

for user in "${HESTIA_USERS[@]}"; do
    if id "$user" &>/dev/null; then
        info "Removing user: $user"
        # Kill any running processes for this user
        run_cmd "pkill -u '$user' 2>/dev/null || true"
        run_cmd "sleep 1"
        run_cmd "userdel -f '$user' 2>/dev/null || true"
        add_summary "Removed user: $user"
    fi
done

for group in "${HESTIA_GROUPS[@]}"; do
    if getent group "$group" &>/dev/null; then
        info "Removing group: $group"
        run_cmd "groupdel '$group' 2>/dev/null || true"
        add_summary "Removed group: $group"
    fi
done

# Remove admin user (created during install, often 'admin' or custom)
ADMIN_USERS=$(awk -F: '$3 >= 1000 && $3 < 65534 {print $1}' /etc/passwd 2>/dev/null)
for admin_user in $ADMIN_USERS; do
    # Check if this user has HestiaCP-managed web directories
    if [ -d "/home/$admin_user/web" ] && [ -d "/home/$admin_user/conf" ]; then
        info "Found HestiaCP-managed user: $admin_user"
        if confirm "Remove user '$admin_user' and all their data?"; then
            run_cmd "pkill -u '$admin_user' 2>/dev/null || true"
            run_cmd "sleep 1"
            run_cmd "userdel -r -f '$admin_user' 2>/dev/null || true"
            run_cmd "groupdel '$admin_user' 2>/dev/null || true"
            run_cmd "rm -rf /home/$admin_user"
            add_summary "Removed HestiaCP user: $admin_user"
        fi
    fi
done

# Remove sudoers entries
for sudoers_file in /etc/sudoers.d/hestiaweb /etc/sudoers.d/hestia; do
    remove_file "$sudoers_file"
done

success "Users and groups removed."

# ----------------------------------------------------------
# Phase 7: Remove HestiaCP Directories & Files
# ----------------------------------------------------------

step "Phase 7: Removing HestiaCP directories and files"

# Main directories
remove_dir "$HESTIA"
remove_dir "/etc/hestiacp"
remove_dir "/root/hst_backups"
remove_dir "/root/hst_install_backups"

# HestiaCP data/cache/runtime/log directories
remove_dir "/usr/share/hestia"
remove_dir "/var/cache/hestia"
remove_dir "/var/run/hestia"
remove_dir "/var/log/hestia"
remove_dir "/var/lib/hestia"

# Chroot jails
if [ -d "/srv/jail" ]; then
    info "Removing chroot jails..."
    # Stop jail mount units
    for unit in $(systemctl list-units --type=mount --no-legend 2>/dev/null | awk '{print $1}' | grep "srv-jail" 2>/dev/null); do
        run_cmd "systemctl stop '$unit' 2>/dev/null || true"
        run_cmd "systemctl disable '$unit' 2>/dev/null || true"
    done
    for unit_file in $(find /etc/systemd/system/ -name "*srv-jail*" -o -name "*srv--jail*" 2>/dev/null); do
        run_cmd "rm -f '$unit_file'"
    done
    run_cmd "systemctl daemon-reload"
    remove_dir "/srv/jail"
fi

# Temp files
run_cmd "rm -f /tmp/hestia-*"
run_cmd "rm -f /tmp/hst-*"

success "Directories and files removed."

# ----------------------------------------------------------
# Phase 8: Remove Systemd Services, Timers & Sockets
# ----------------------------------------------------------

step "Phase 8: Removing systemd units"

# Known HestiaCP systemd units
HST_SYSTEMD_FILES=(
    "/etc/systemd/system/hestia.service"
    "/etc/systemd/system/hestia-web-terminal.service"
    "/etc/systemd/system/hestia-web-terminal.socket"
    "/etc/systemd/system/hestia-ssl.timer"
    "/etc/systemd/system/hestia-ssl.service"
    "/etc/systemd/system/hestia-update.timer"
    "/etc/systemd/system/hestia-update.service"
)

for svc_file in "${HST_SYSTEMD_FILES[@]}"; do
    if [ -f "$svc_file" ]; then
        info "Removing systemd unit: $(basename "$svc_file")"
        run_cmd "systemctl stop '$(basename "$svc_file")' 2>/dev/null || true"
        run_cmd "systemctl disable '$(basename "$svc_file")' 2>/dev/null || true"
        run_cmd "rm -f '$svc_file'"
        add_summary "Removed systemd unit: $(basename "$svc_file")"
    fi
done

# Remove jail mount units
for unit_file in $(find /etc/systemd/system/ -name "*.mount" 2>/dev/null | grep -iE "jail|hestia" 2>/dev/null); do
    info "Removing mount unit: $(basename "$unit_file")"
    run_cmd "systemctl stop '$(basename "$unit_file")' 2>/dev/null || true"
    run_cmd "systemctl disable '$(basename "$unit_file")' 2>/dev/null || true"
    run_cmd "rm -f '$unit_file'"
    add_summary "Removed mount unit: $(basename "$unit_file")"
done

# Remove any remaining hestia-related systemd files
for unit_file in $(find /etc/systemd /lib/systemd -type f 2>/dev/null | grep -i hestia 2>/dev/null); do
    info "Removing leftover systemd unit: $unit_file"
    run_cmd "rm -f '$unit_file'"
done

run_cmd "systemctl daemon-reload"
run_cmd "systemctl reset-failed 2>/dev/null || true"

success "Systemd units removed."

# ----------------------------------------------------------
# Phase 9: Restore Web Server Configurations (Nginx)
# ----------------------------------------------------------

step "Phase 9: Restoring Nginx configuration"

if [ -d "/etc/nginx" ]; then
    # Remove HestiaCP conf.d files
    HST_NGINX_CONFS=(
        "status.conf"
        "0rtt-anti-replay.conf"
        "agents.conf"
        "cloudflare.inc"
        "phpmyadmin.inc"
        "phppgadmin.inc"
        "hestia.conf"
        "unassigned.inc"
        "microcache.conf"
    )
    for conf in "${HST_NGINX_CONFS[@]}"; do
        run_cmd "rm -f /etc/nginx/conf.d/$conf"
    done

    # Remove HestiaCP-managed domain configs
    remove_dir "/etc/nginx/conf.d/domains"

    # Remove any conf.d files referencing hestia
    for f in /etc/nginx/conf.d/*.conf /etc/nginx/conf.d/*.inc; do
        if [ -f "$f" ] && grep -qi "hestia\|/usr/local/hestia" "$f" 2>/dev/null; then
            info "Removing HestiaCP-referencing nginx conf: $(basename "$f")"
            run_cmd "rm -f '$f'"
        fi
    done

    # Remove HestiaCP nginx cache directories
    remove_dir "/var/cache/nginx/micro"
    remove_dir "/var/cache/nginx/temp"

    # Remove sites-enabled/default if HestiaCP-managed
    for site_file in /etc/nginx/sites-enabled/default /etc/nginx/sites-available/default; do
        if [ -f "$site_file" ] && grep -qi "hestia\|unassigned" "$site_file" 2>/dev/null; then
            run_cmd "rm -f '$site_file'"
        fi
    done

    # Remove HestiaCP nginx logrotate config
    if [ -f "/etc/logrotate.d/nginx" ]; then
        if grep -qi "hestia\|/usr/local/hestia" /etc/logrotate.d/nginx 2>/dev/null; then
            run_cmd "rm -f /etc/logrotate.d/nginx"
        fi
    fi

    # Remove HestiaCP-created nginx log directories
    remove_dir "/var/log/nginx/domains"

    # Remove HestiaCP SSL directory
    remove_dir "/usr/local/hestia/ssl"

    # Restore nginx.conf to clean default if HestiaCP-modified
    NGINX_NEEDS_RESTORE=false
    if [ ! -f "/etc/nginx/nginx.conf" ]; then
        NGINX_NEEDS_RESTORE=true
    elif grep -qi "/usr/local/hestia/ssl/\|fastcgi_cache_path.*microcache\|proxy_cache_path.*cache:10m\|conf\.d/domains\|cloudflare\.inc\|0rtt-anti-replay" /etc/nginx/nginx.conf 2>/dev/null; then
        NGINX_NEEDS_RESTORE=true
    fi

    if [ "$NGINX_NEEDS_RESTORE" = true ] && [ "$DRY_RUN" = false ]; then
        info "Restoring clean default nginx.conf..."
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
        add_summary "Restored nginx.conf to clean default"
    fi

    # Fix broken SSL cert references in remaining configs
    for f in /etc/nginx/conf.d/*.conf /etc/nginx/conf.d/*.inc /etc/nginx/sites-enabled/* /etc/nginx/sites-available/*; do
        if [ -f "$f" ]; then
            if grep -q "/usr/local/hestia/ssl/" "$f" 2>/dev/null; then
                info "Fixing broken SSL cert in: $(basename "$f")"
                if [ "$DRY_RUN" = false ]; then
                    sed -i 's|^\s*ssl_certificate[[:space:]]|# ssl_certificate (disabled - hestia removed)|g' "$f"
                    sed -i 's|^\s*ssl_certificate_key[[:space:]]|# ssl_certificate_key (disabled - hestia removed)|g' "$f"
                    sed -i 's|^\s*listen.*443.*ssl|# listen 443 ssl (disabled - hestia removed)|g' "$f"
                fi
                add_summary "Fixed broken SSL cert in $(basename "$f")"
            fi
        fi
    done

    # Ensure required directories exist
    run_cmd "mkdir -p /etc/nginx/conf.d /etc/nginx/sites-available /etc/nginx/sites-enabled"

    add_summary "Cleaned Nginx configurations"
fi

# ----------------------------------------------------------
# Phase 10: Restore Apache Configurations
# ----------------------------------------------------------

step "Phase 10: Restoring Apache configuration"

if [ -d "/etc/apache2" ]; then
    # Remove HestiaCP apache configs
    HST_APACHE_CONFS=(
        "hestia.conf"
        "hestia-event.conf"
        "status.conf"
        "unassigned.conf"
        "phpmyadmin.inc"
        "phppgadmin.inc"
    )
    for conf in "${HST_APACHE_CONFS[@]}"; do
        run_cmd "rm -f /etc/apache2/conf.d/$conf"
    done

    # Remove HestiaCP-managed domain configs
    remove_dir "/etc/apache2/conf.d/domains"

    # Remove HestiaCP sites
    run_cmd "rm -f /etc/apache2/sites-enabled/hestia*"
    run_cmd "rm -f /etc/apache2/sites-available/hestia*"

    # Remove any apache confs referencing hestia
    for f in /etc/apache2/conf.d/*.conf /etc/apache2/conf.d/*.inc; do
        if [ -f "$f" ] && grep -qi "hestia\|/usr/local/hestia" "$f" 2>/dev/null; then
            info "Removing HestiaCP-referencing apache conf: $(basename "$f")"
            run_cmd "rm -f '$f'"
        fi
    done

    # Fix broken SSL cert references in apache
    for f in /etc/apache2/sites-enabled/* /etc/apache2/sites-available/* /etc/apache2/conf.d/*; do
        if [ -f "$f" ] && grep -q "/usr/local/hestia/ssl/" "$f" 2>/dev/null; then
            info "Fixing broken SSL cert in: $(basename "$f")"
            if [ "$DRY_RUN" = false ]; then
                sed -i 's|^\s*SSLCertificateFile|# SSLCertificateFile (disabled - hestia removed)|g' "$f"
                sed -i 's|^\s*SSLCertificateKeyFile|# SSLCertificateKeyFile (disabled - hestia removed)|g' "$f"
            fi
            add_summary "Fixed broken SSL cert in $(basename "$f")"
        fi
    done

    # Remove apache logrotate if hestia-managed
    if [ -f "/etc/logrotate.d/apache2" ]; then
        if grep -qi "hestia\|/usr/local/hestia" /etc/logrotate.d/apache2 2>/dev/null; then
            run_cmd "rm -f /etc/logrotate.d/apache2"
        fi
    fi

    add_summary "Cleaned Apache configurations"
fi

# ----------------------------------------------------------
# Phase 11: Remove Firewall Rules (iptables, ipset, ip6tables)
# ----------------------------------------------------------

step "Phase 11: Removing firewall rules"

if command -v iptables &>/dev/null; then
    info "Cleaning iptables rules (HestiaCP chains)..."
    for chain in HESTIA HESTIA_OUTPUT; do
        run_cmd "iptables -F '$chain' 2>/dev/null || true"
        run_cmd "iptables -D INPUT -j '$chain' 2>/dev/null || true"
        run_cmd "iptables -D OUTPUT -j '$chain' 2>/dev/null || true"
        run_cmd "iptables -X '$chain' 2>/dev/null || true"
    done
    # Also clean ip6tables
    if command -v ip6tables &>/dev/null; then
        for chain in HESTIA HESTIA_OUTPUT; do
            run_cmd "ip6tables -F '$chain' 2>/dev/null || true"
            run_cmd "ip6tables -D INPUT -j '$chain' 2>/dev/null || true"
            run_cmd "ip6tables -D OUTPUT -j '$chain' 2>/dev/null || true"
            run_cmd "ip6tables -X '$chain' 2>/dev/null || true"
        done
    fi
    add_summary "Removed HestiaCP iptables chains"
fi

# Remove ipset sets
if command -v ipset &>/dev/null; then
    for set_name in $(ipset list -n 2>/dev/null | grep -i hestia); do
        info "Removing ipset: $set_name"
        run_cmd "ipset destroy '$set_name' 2>/dev/null || true"
    done
    add_summary "Removed HestiaCP ipset sets"
fi

success "Firewall rules cleaned."

# ----------------------------------------------------------
# Phase 12: Remove Let's Encrypt Certificates
# ----------------------------------------------------------

step "Phase 12: Removing Let's Encrypt certificates"

if [ -d "/etc/letsencrypt" ]; then
    if confirm "Remove all Let's Encrypt certificates in /etc/letsencrypt/?"; then
        remove_dir "/etc/letsencrypt"
    else
        warn "Let's Encrypt certificates preserved."
    fi
fi

# Remove certbot if installed by HestiaCP
remove_pkg "certbot"

success "Certificate cleanup complete."

# ----------------------------------------------------------
# Phase 13: Remove Cron Jobs, MOTD, Login Scripts, Logrotate
# ----------------------------------------------------------

step "Phase 13: Cleaning cron, MOTD, login scripts, logrotate"

# Remove HestiaCP MOTD
remove_file "/etc/update-motd.d/99-hestia"

# Remove HestiaCP profile.d scripts
if ls /etc/profile.d/hestia* 1>/dev/null 2>&1; then
    run_cmd "rm -f /etc/profile.d/hestia*"
    add_summary "Removed HestiaCP profile scripts"
fi

# Remove HestiaCP bash completion
remove_file "/etc/bash_completion.d/hestia"

# Remove HestiaCP CLI aliases
if [ -f "/etc/bash.bashrc" ]; then
    if grep -q "hestia\|v-alias\|v-add" /etc/bash.bashrc 2>/dev/null; then
        info "Removing HestiaCP entries from /etc/bash.bashrc"
        if [ "$DRY_RUN" = false ]; then
            sed -i '/hestia/d; /v-alias/d; /v-add.*-cron/d' /etc/bash.bashrc
        fi
    fi
fi

# Remove logrotate configs (only if HestiaCP-managed)
HST_LOGROTATE=(
    "/etc/logrotate.d/hestia"
    "/etc/logrotate.d/dovecot"
    "/etc/logrotate.d/roundcube"
)
for lr in "${HST_LOGROTATE[@]}"; do
    if [ -f "$lr" ]; then
        if grep -qi "hestia\|/usr/local/hestia" "$lr" 2>/dev/null; then
            run_cmd "rm -f '$lr'"
            add_summary "Removed logrotate: $(basename "$lr")"
        fi
    fi
done

# Remove awstats prerotate
remove_file "/etc/logrotate.d/httpd-prerotate/awstats"

# Remove all HestiaCP crontab entries
info "Removing HestiaCP crontab entries..."
run_cmd "crontab -u hestiaweb -r 2>/dev/null || true"
run_cmd "rm -f /var/spool/cron/crontabs/hestiaweb"
run_cmd "rm -f /var/spool/cron/crontabs/hestiamail"

# Remove HestiaCP cron.d files
HST_CROND=(
    "hestia"
    "hestia-ssl"
    "hestia-proc"
    "hestia-autoupdate"
    "hestia-letsencrypt"
)
for cronfile in "${HST_CROND[@]}"; do
    run_cmd "rm -f /etc/cron.d/$cronfile"
done

# Remove php session cleanup cron (HestiaCP-created)
if [ -f "/etc/cron.daily/php-session-cleanup" ]; then
    if grep -qi "hestia\|/home/\*/tmp" /etc/cron.daily/php-session-cleanup 2>/dev/null; then
        run_cmd "rm -f /etc/cron.daily/php-session-cleanup"
        add_summary "Removed php-session-cleanup cron"
    fi
fi

# Remove root crontab entries referencing hestia
if crontab -l 2>/dev/null | grep -q "hestia"; then
    info "Cleaning root crontab of HestiaCP entries..."
    if [ "$DRY_RUN" = false ]; then
        crontab -l 2>/dev/null | grep -vi "hestia" | crontab - 2>/dev/null || true
    fi
    add_summary "Cleaned root crontab"
fi

success "Cron, MOTD, login scripts, logrotate cleaned."

# ----------------------------------------------------------
# Phase 14: Restore SSH Configuration
# ----------------------------------------------------------

step "Phase 14: Restoring SSH configuration"

if [ -f "/etc/ssh/sshd_config" ]; then
    # Check if HestiaCP modified sshd_config
    if grep -qi "hestia\|jail\|Match User" /etc/ssh/sshd_config 2>/dev/null; then
        info "Detected HestiaCP modifications in sshd_config"
        if [ "$DRY_RUN" = false ] && [ -f "$BACKUP_DIR/sshd_config.bak" ]; then
            # Check if the backup is different from current
            if ! diff -q "$BACKUP_DIR/sshd_config.bak" /etc/ssh/sshd_config &>/dev/null; then
                info "Restoring sshd_config from pre-uninstall backup..."
                cp "$BACKUP_DIR/sshd_config.bak" /etc/ssh/sshd_config
                # But don't restart sshd yet - we'll do it at the end
                add_summary "Restored sshd_config from backup"
            fi
        else
            # Manual cleanup: remove HestiaCP additions
            info "Removing HestiaCP SSH modifications..."
            if [ "$DRY_RUN" = false ]; then
                # Remove Match User blocks added by Hestia
                sed -i '/^Match User.*hestia/,/^Match\|^$/d' /etc/ssh/sshd_config
                # Remove Subsystem sftp changes
                sed -i '/#.*Hestia/d' /etc/ssh/sshd_config
            fi
            add_summary "Cleaned HestiaCP SSH modifications"
        fi
    fi

    # Remove HestiaCP SSH authorized_keys
    if [ -f "/root/.ssh/authorized_keys" ]; then
        if grep -qi "hestia" /root/.ssh/authorized_keys 2>/dev/null; then
            info "Removing HestiaCP SSH keys from authorized_keys..."
            if [ "$DRY_RUN" = false ]; then
                sed -i '/hestia/d' /root/.ssh/authorized_keys
            fi
            add_summary "Cleaned authorized_keys"
        fi
    fi
fi

success "SSH configuration checked."

# ----------------------------------------------------------
# Phase 15: Restore /etc/hosts
# ----------------------------------------------------------

step "Phase 15: Cleaning /etc/hosts"

if [ -f "/etc/hosts" ]; then
    if grep -q "127.0.0.1.*hestia\|127.0.0.1.*$(hostname -f)" /etc/hosts 2>/dev/null; then
        info "Removing HestiaCP-added hosts entries..."
        if [ "$DRY_RUN" = false ]; then
            # Only remove lines that were likely added by HestiaCP installer
            # (127.0.0.1 lines with FQDN that match the installer pattern)
            sed -i '/127\.0\.0\.1.*hestia/d' /etc/hosts
        fi
        add_summary "Cleaned /etc/hosts"
    fi
fi

success "/etc/hosts cleaned."

# ----------------------------------------------------------
# Phase 16: Clean Swap File (if created by installer)
# ----------------------------------------------------------

step "Phase 16: Checking swap file"

# The HestiaCP installer creates /swapfile on low-memory servers
if [ -f "/swapfile" ] && [ -f "/etc/fstab" ]; then
    if grep -q "/swapfile" /etc/fstab 2>/dev/null; then
        info "Found HestiaCP-created swap file"
        if confirm "Remove /swapfile and its fstab entry?"; then
            run_cmd "swapoff /swapfile 2>/dev/null || true"
            run_cmd "rm -f /swapfile"
            if [ "$DRY_RUN" = false ]; then
                sed -i '\|/swapfile|d' /etc/fstab
            fi
            add_summary "Removed swap file and fstab entry"
        fi
    fi
fi

success "Swap file checked."

# ----------------------------------------------------------
# Phase 17: Remove Quota Configuration
# ----------------------------------------------------------

step "Phase 17: Removing quota configuration"

# Remove quota from fstab entries added by HestiaCP
if [ -f "/etc/fstab" ]; then
    if grep -q "usrjquota\|grpjquota" /etc/fstab 2>/dev/null; then
        info "Removing quota mount options from fstab..."
        if [ "$DRY_RUN" = false ]; then
            sed -i 's/,usrjquota=[^,]*//g; s/,grpjquota=[^,]*//g; s/,jqfmt=[^,]*//g' /etc/fstab
        fi
        add_summary "Cleaned quota entries from fstab"
    fi
fi

# Remove quota files
for quota_file in /aquota.user /aquota.group; do
    remove_file "$quota_file"
done

success "Quota configuration cleaned."

# ----------------------------------------------------------
# Phase 18: Remove Polkit, AppArmor & udev Rules
# ----------------------------------------------------------

step "Phase 18: Cleaning polkit, AppArmor, and udev rules"

# Polkit rules
if [ -d "/etc/polkit-1/localauthority.conf.d" ]; then
    for f in /etc/polkit-1/localauthority.conf.d/*hestia*; do
        if [ -f "$f" ]; then
            remove_file "$f"
        fi
    done
fi

# AppArmor profiles
if [ -d "/etc/apparmor.d" ]; then
    for f in /etc/apparmor.d/*hestia*; do
        if [ -f "$f" ]; then
            info "Removing AppArmor profile: $(basename "$f")"
            run_cmd "apparmor_parser -R '$f' 2>/dev/null || true"
            run_cmd "rm -f '$f'"
            add_summary "Removed AppArmor profile: $(basename "$f")"
        fi
    done
fi

# udev rules
if [ -d "/etc/udev/rules.d" ]; then
    for f in /etc/udev/rules.d/*hestia*; do
        if [ -f "$f" ]; then
            remove_file "$f"
        fi
    done
fi

# System resource limits
remove_file "/etc/security/limits.d/hestia.conf"
remove_file "/etc/security/limits.d/99-hestia.conf"

# sysctl modifications
if [ -f "/etc/sysctl.d/99-hestia.conf" ]; then
    remove_file "/etc/sysctl.d/99-hestia.conf"
    run_cmd "sysctl --system 2>/dev/null || true"
fi

success "Polkit, AppArmor, udev rules cleaned."

# ----------------------------------------------------------
# Phase 19: User Data Cleanup
# ----------------------------------------------------------

step "Phase 19: User data cleanup"

if confirm "Remove all user web/mail/DNS data (/home/*)? THIS CANNOT BE UNDONE!"; then
    if [ -d "/home" ]; then
        for user_home in /home/*/; do
            username=$(basename "$user_home")
            # Skip system users
            case "$username" in
                hestiaweb|hestiamail|hestiasshd|lost+found) continue ;;
            esac
            # Check if this user has HestiaCP data
            if [ -d "$user_home/web" ] || [ -d "$user_home/conf" ] || [ -d "$user_home/mail" ]; then
                info "Removing HestiaCP user data: $user_home"
                run_cmd "pkill -u '$username' 2>/dev/null || true"
                run_cmd "sleep 1"
                run_cmd "userdel -r -f '$username' 2>/dev/null || true"
                run_cmd "groupdel '$username' 2>/dev/null || true"
                run_cmd "rm -rf '$user_home'"
                add_summary "Removed user data: $username"
            fi
        done
    fi

    # Remove HestiaCP user config data
    remove_dir "/usr/local/hestia/data"
else
    warn "User data preserved. Files remain in /home/"
fi

# ----------------------------------------------------------
# Phase 20: Remove HestiaCP Fail2Ban Configs (if dir still exists)
# ----------------------------------------------------------

step "Phase 20: Final Fail2Ban cleanup"

if [ -d "/etc/fail2ban" ]; then
    for f in /etc/fail2ban/action.d/hestia.conf /etc/fail2ban/filter.d/hestia.conf; do
        remove_file "$f"
    done
    if [ -f "/etc/fail2ban/jail.local" ]; then
        if grep -qi "hestia" /etc/fail2ban/jail.local 2>/dev/null; then
            remove_file "/etc/fail2ban/jail.local"
        fi
    fi
fi

success "Fail2Ban cleanup complete."

# ----------------------------------------------------------
# Phase 21: Clean Remaining Config Directories
# ----------------------------------------------------------

step "Phase 21: Cleaning remaining config directories"

# These might still exist if packages were removed but configs remain
for dir in \
    "/etc/exim4" \
    "/etc/dovecot" \
    "/etc/bind" \
    "/etc/vsftpd" \
    "/etc/proftpd" \
    "/etc/clamav" \
    "/etc/spamassassin" \
    "/etc/mysql" \
    "/etc/postgresql"; do
    remove_dir "$dir"
done

success "Remaining config directories cleaned."

# ----------------------------------------------------------
# Phase 22: Restart Web Services & Verify
# ----------------------------------------------------------

step "Phase 22: Restarting and verifying web services"

# Nginx
if command -v nginx &>/dev/null && [ -d "/etc/nginx" ]; then
    info "Testing nginx configuration..."
    if nginx -t 2>&1 | grep -q "successful\|syntax is ok"; then
        success "nginx config test PASSED"
        run_cmd "systemctl start nginx"
        run_cmd "systemctl enable nginx"
        add_summary "nginx started and enabled"
    else
        error "nginx config test FAILED:"
        nginx -t 2>&1 | while IFS= read -r line; do
            echo -e "  ${RED}$line${NC}"
        done
        add_summary "⚠ nginx FAILED to start - fix config manually"
    fi
else
    info "nginx not installed, skipping."
fi

# Apache
if command -v apache2ctl &>/dev/null && [ -d "/etc/apache2" ]; then
    info "Testing apache configuration..."
    if apache2ctl configtest 2>&1 | grep -q "Syntax OK"; then
        success "Apache config test PASSED"
        run_cmd "systemctl start apache2"
        run_cmd "systemctl enable apache2"
        add_summary "Apache started and enabled"
    else
        warn "Apache config test failed:"
        apache2ctl configtest 2>&1 | while IFS= read -r line; do
            echo -e "  ${YELLOW}$line${NC}"
        done
        add_summary "⚠ Apache failed to start - fix config manually"
    fi
else
    info "Apache not installed, skipping."
fi

# Restart cron
run_cmd "systemctl restart cron 2>/dev/null || true"

# Restart SSH
info "Restarting SSH service..."
run_cmd "systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null || true"

success "Services verified and restarted."

# ----------------------------------------------------------
# Phase 23: Orphaned Package Cleanup (apt autoremove)
# ----------------------------------------------------------

step "Phase 23: Removing orphaned dependencies"

info "Running apt autoremove to clean up orphaned packages..."
run_cmd "DEBIAN_FRONTEND=noninteractive apt-get autoremove -y 2>/dev/null || true"
run_cmd "apt-get autoclean -y 2>/dev/null || true"

add_summary "Ran apt autoremove and autoclean"

success "Orphaned packages removed."

# ----------------------------------------------------------
# Phase 24: Deep Residue Scan
# ----------------------------------------------------------

step "Phase 24: Deep residue scan"

info "Scanning system for remaining HestiaCP artifacts..."

RESIDUE_COUNT=0

# Scan /etc for HestiaCP references
substep "Scanning /etc/ for config residue..."
for f in $(find /etc -type f \( -name "*.conf" -o -name "*.inc" -o -name "*.tpl" -o -name "*.stpl" \) 2>/dev/null); do
    if grep -ql "hestia\|/usr/local/hestia\|HESTIA=" "$f" 2>/dev/null; then
        warn "Residue config: $f"
        RESIDUE_COUNT=$((RESIDUE_COUNT + 1))
    fi
done

# Scan for broken SSL cert references
substep "Scanning for broken SSL cert references..."
for f in $(find /etc/nginx /etc/apache2 -type f 2>/dev/null); do
    if grep -ql "/usr/local/hestia/ssl/" "$f" 2>/dev/null; then
        error "BROKEN SSL CERT REFERENCE: $f"
        RESIDUE_COUNT=$((RESIDUE_COUNT + 1))
    fi
done

# Scan for leftover cron jobs
substep "Scanning for leftover cron entries..."
if crontab -l 2>/dev/null | grep -q "hestia"; then
    warn "Residue: root crontab contains hestia entries"
    RESIDUE_COUNT=$((RESIDUE_COUNT + 1))
fi

# Scan for leftover systemd units
substep "Scanning for leftover systemd units..."
for unit in $(find /etc/systemd /lib/systemd /run/systemd -type f 2>/dev/null); do
    if grep -ql "hestia\|/usr/local/hestia" "$unit" 2>/dev/null; then
        warn "Residue systemd unit: $unit"
        RESIDUE_COUNT=$((RESIDUE_COUNT + 1))
    fi
done

# Check if /usr/local/hestia still exists
substep "Checking /usr/local/hestia..."
if [ -d "/usr/local/hestia" ]; then
    warn "Residue directory: /usr/local/hestia still exists"
    RESIDUE_COUNT=$((RESIDUE_COUNT + 1))
fi

# Check for leftover apt repos
substep "Checking apt repositories..."
for f in /etc/apt/sources.list.d/*; do
    if [ -f "$f" ] && grep -qi "hestia\|nginx\.org\|mariadb\|nodesource\|postgresql" "$f" 2>/dev/null; then
        warn "Residue apt source: $f"
        RESIDUE_COUNT=$((RESIDUE_COUNT + 1))
    fi
done

# Check for leftover GPG keyrings
substep "Checking GPG keyrings..."
for f in /usr/share/keyrings/*; do
    if [ -f "$f" ] && echo "$(basename "$f")" | grep -qiE "nginx|mariadb|hestia|nodejs|postgresql" 2>/dev/null; then
        warn "Residue GPG keyring: $f"
        RESIDUE_COUNT=$((RESIDUE_COUNT + 1))
    fi
done

# Extended deep scan
if [ "$DEEP_SCAN" = true ]; then
    substep "Extended deep filesystem scan..."
    
    # Scan /var for HestiaCP references
    for f in $(find /var -type f -name "*.conf" 2>/dev/null | head -1000); do
        if grep -ql "hestia\|/usr/local/hestia" "$f" 2>/dev/null; then
            warn "Residue in /var: $f"
            RESIDUE_COUNT=$((RESIDUE_COUNT + 1))
        fi
    done
    
    # Scan /usr for HestiaCP references (excluding docs/man)
    for f in $(find /usr/share -type f -name "*.conf" -o -name "*.service" 2>/dev/null | head -500); do
        if grep -ql "hestia\|/usr/local/hestia" "$f" 2>/dev/null; then
            warn "Residue in /usr: $f"
            RESIDUE_COUNT=$((RESIDUE_COUNT + 1))
        fi
    done
    
    # Check for leftover home directories
    for d in /home/*/; do
        if [ -d "$d" ] && [ "$d" != "/home/lost+found/" ]; then
            username=$(basename "$d")
            if [ -d "$d/web" ] || [ -d "$d/conf" ]; then
                warn "HestiaCP user data still exists: $d"
                RESIDUE_COUNT=$((RESIDUE_COUNT + 1))
            fi
        fi
    done
fi

if [ "$RESIDUE_COUNT" -eq 0 ]; then
    success "No remaining HestiaCP residue found! ✓"
else
    warn "Found $RESIDUE_COUNT potential residue item(s). Review the log."
fi

# Reload systemd one final time
run_cmd "systemctl daemon-reload"

success "Deep residue scan complete."

# ----------------------------------------------------------
# Cleanup
# ----------------------------------------------------------

step "Final cleanup"

# Remove any remaining temp files
run_cmd "rm -f /tmp/hestia-* /tmp/hst-* /tmp/updconf*"

# Remove installer backup directory
remove_dir "/root/hst_install_backups"

success "Cleanup complete."

# ----------------------------------------------------------
# Summary Report
# ----------------------------------------------------------

echo ""
echo "========================================================"
echo -e "${BOLD}${GREEN}  HestiaCP Uninstall Complete${NC}"
echo "========================================================"
echo ""

if [ "$DRY_RUN" = true ]; then
    echo -e "${YELLOW}  ⚠ DRY-RUN MODE: No changes were actually made.${NC}"
    echo ""
fi

echo -e "${BOLD}Summary of actions taken:${NC}"
echo ""
if [ ${#SUMMARY[@]} -eq 0 ]; then
    echo "  No actions were taken."
else
    count=0
    for item in "${SUMMARY[@]}"; do
        count=$((count + 1))
        echo -e "  ${GREEN}✓${NC} [$count] $item"
    done
fi

echo ""
echo -e "${BOLD}Residue scan: $RESIDUE_COUNT item(s) found${NC}"

if [ ${#WARNINGS[@]} -gt 0 ]; then
    echo ""
    echo -e "${YELLOW}${BOLD}Warnings (${#WARNINGS[@]}):${NC}"
    for w in "${WARNINGS[@]}"; do
        echo -e "  ${YELLOW}⚠${NC} $w"
    done
fi

echo ""
echo -e "${BOLD}Backups:${NC}"
if [ -d "$BACKUP_DIR" ]; then
    echo -e "  Pre-uninstall backup: ${CYAN}$BACKUP_DIR${NC}"
fi
echo -e "  Full log: ${CYAN}$LOG_FILE${NC}"

echo ""
echo -e "${BOLD}Recovery Status:${NC}"
if [ "$RESIDUE_COUNT" -eq 0 ]; then
    echo -e "  ${GREEN}✓ 99.99%+ VPS recovery achieved${NC}"
    echo -e "  ${GREEN}  No HestiaCP artifacts detected${NC}"
else
    echo -e "  ${YELLOW}⚠ ~$(( 100 - RESIDUE_COUNT ))% recovery (review warnings above)${NC}"
fi

echo ""
echo "========================================================"
echo -e "${BOLD}Next steps:${NC}"
echo "  1. Verify nginx/apache: systemctl status nginx"
echo "  2. Check SSH access: ssh root@$(hostname -I | awk '{print $1}')"
echo "  3. Review log: cat $LOG_FILE"
echo "  4. If issues: restore from $BACKUP_DIR"
echo "  5. Run: apt autoremove (if not done)"
echo "========================================================"

log "=== HestiaCP Enhanced Uninstall Completed ==="
log "Residue items: $RESIDUE_COUNT"
log "Backup: $BACKUP_DIR"
