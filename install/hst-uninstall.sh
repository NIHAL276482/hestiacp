#!/bin/bash

# ======================================================== #
#
# Hestia Control Panel Uninstaller
# Comprehensive removal script
# https://www.hestiacp.com/
#
# Usage:
#   bash hst-uninstall.sh [--force] [--dry-run]
#
# ======================================================== #

# ----------------------------------------------------------
# Global Settings
# ----------------------------------------------------------

set -euo pipefail

LOG_FILE="/var/log/hestia-uninstall.log"
DRY_RUN=false
FORCE=false
SUMMARY=()

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color
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
}

error() {
	echo -e "${RED}[ERR ]${NC} $1"
	log "[ERROR] $1"
}

step() {
	echo -e "\n${CYAN}${BOLD}==>${NC} ${BOLD}$1${NC}"
	log "==> $1"
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
		--help|-h)
			echo "HestiaCP Uninstaller"
			echo ""
			echo "Usage: bash hst-uninstall.sh [OPTIONS]"
			echo ""
			echo "Options:"
			echo "  --force, -f     Skip all confirmation prompts"
			echo "  --dry-run, -n   Show what would be done without making changes"
			echo "  --help, -h      Show this help message"
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
echo "  Hestia Control Panel Uninstaller"
echo "========================================================"
echo -e "${NC}"

# Initialize log
mkdir -p "$(dirname "$LOG_FILE")"
touch "$LOG_FILE"
log "=== HestiaCP Uninstall Started ==="
log "Force: $FORCE | Dry-run: $DRY_RUN"

# Root check
if [ "$(id -u)" -ne 0 ]; then
	error "This script must be run as root."
	exit 1
fi

if [ "$DRY_RUN" = true ]; then
	warn "DRY-RUN MODE: No changes will be made."
fi

# OS Detection
step "Detecting operating system"

OS_TYPE=""
OS_VERSION=""
if [ -e "/etc/os-release" ]; then
	os_id=$(grep "^ID=" /etc/os-release | cut -f 2 -d '=' | tr -d '"')
	os_version_id=$(grep "^VERSION_ID=" /etc/os-release 2>/dev/null | cut -f 2 -d '=' | tr -d '"' | tr -d '.')
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
			error "This uninstaller supports Debian and Ubuntu only."
			exit 1
			;;
	esac
	success "Detected: $OS_TYPE $OS_VERSION"
else
	error "Cannot detect OS: /etc/os-release not found."
	exit 1
fi

# Check if HestiaCP is installed
step "Checking HestiaCP installation"

HESTIA="/usr/local/hestia"
HESTIA_FOUND=false

if [ -d "$HESTIA" ] || dpkg -l | grep -q "^ii.*hestia "; then
	HESTIA_FOUND=true
	success "HestiaCP installation found."
else
	warn "HestiaCP does not appear to be installed."
	if ! confirm "Continue with cleanup anyway?"; then
		info "Aborted by user."
		exit 0
	fi
fi

# Confirmation
echo ""
echo -e "${RED}${BOLD}WARNING: This will completely remove HestiaCP from your system!${NC}"
echo -e "${RED}This includes:${NC}"
echo -e "  - All HestiaCP services and packages"
echo -e "  - Configuration files in /usr/local/hestia/"
echo -e "  - System users created by HestiaCP"
echo -e "  - Cron jobs, firewall rules, and systemd services"
echo ""

if ! confirm "Are you sure you want to proceed?"; then
	info "Uninstall aborted by user."
	exit 0
fi

# ----------------------------------------------------------
# Phase 1: Stop Services
# ----------------------------------------------------------

step "Phase 1: Stopping services for cleanup"

# Services to STOP AND REMOVE (not nginx/apache - those are kept)
REMOVE_SERVICES=(
	"hestia"
	"hestia-web-terminal"
	"exim4"
	"dovecot"
	"named"
	"bind9"
	"vsftpd"
	"mariadb"
	"mysql"
	"postgresql"
	"fail2ban"
	"php*-fpm"
)

for svc_pattern in "${REMOVE_SERVICES[@]}"; do
	if [[ "$svc_pattern" == *"*"* ]]; then
		for svc in $(systemctl list-unit-files --type=service --no-legend 2>/dev/null | awk '{print $1}' | grep -E "^${svc_pattern//\*/.*}" 2>/dev/null); do
			svc_name="${svc%.service}"
			if systemctl is-active --quiet "$svc_name" 2>/dev/null; then
				info "Stopping $svc_name..."
				run_cmd "systemctl stop '$svc_name'"
				run_cmd "systemctl disable '$svc_name'"
				add_summary "Stopped and disabled: $svc_name"
			fi
		done
	else
		if systemctl is-active --quiet "$svc_pattern" 2>/dev/null; then
			info "Stopping $svc_pattern..."
			run_cmd "systemctl stop '$svc_pattern'"
			run_cmd "systemctl disable '$svc_pattern'"
			add_summary "Stopped and disabled: $svc_pattern"
		fi
	fi
done

# Stop nginx/apache TEMPORARILY for config cleanup (will restart later)
for svc in nginx apache2; do
	if systemctl is-active --quiet "$svc" 2>/dev/null; then
		info "Temporarily stopping $svc for config cleanup..."
		run_cmd "systemctl stop '$svc'"
	fi
done

# Stop HestiaCP cron jobs
info "Removing HestiaCP cron jobs..."
run_cmd "crontab -u hestiaweb -r 2>/dev/null || true"
run_cmd "rm -f /var/spool/cron/crontabs/hestiaweb"
run_cmd "rm -f /etc/cron.d/hestia*"
add_summary "Removed HestiaCP cron jobs"

success "All services stopped."

# ----------------------------------------------------------
# Phase 2: Remove Packages (HestiaCP + Service Packages)
# ----------------------------------------------------------

step "Phase 2: Removing HestiaCP packages"

HESTIA_PACKAGES=(
	"hestia"
	"hestia-nginx"
	"hestia-php"
)

for pkg in "${HESTIA_PACKAGES[@]}"; do
	if dpkg -l 2>/dev/null | grep -q "^ii.*$pkg "; then
		info "Removing package: $pkg"
		run_cmd "dpkg --purge '$pkg'"
		add_summary "Removed package: $pkg"
	fi
done

# Remove HestiaCP apt repository
info "Removing HestiaCP apt repository..."
run_cmd "rm -f /etc/apt/sources.list.d/hestia.list"
run_cmd "rm -f /etc/apt/sources.list.d/hestiacp.list"
run_cmd "rm -f /etc/apt/trusted.gpg.d/hestia*"
run_cmd "rm -f /usr/share/keyrings/hestia*"
add_summary "Removed HestiaCP apt repository and keys"

success "HestiaCP packages removed."

# ----------------------------------------------------------
# Phase 2b: Remove Service Packages (PHP, MySQL, Mail, DNS, FTP)
# ----------------------------------------------------------

step "Phase 2b: Removing service packages"

remove_pkg() {
	local pkg="$1"
	if dpkg -l 2>/dev/null | grep -q "^ii.*[[:space:]]$pkg[[:space:]]"; then
		info "Removing package: $pkg"
		run_cmd "DEBIAN_FRONTEND=noninteractive apt-get purge -y '$pkg' 2>/dev/null || dpkg --purge '$pkg' 2>/dev/null || true"
		add_summary "Removed package: $pkg"
	fi
}

# PHP (all versions)
info "Removing PHP packages..."
PHP_PKGS=$(dpkg -l 2>/dev/null | awk '/^ii/ && /php/ {print $2}' 2>/dev/null || true)
for pkg in $PHP_PKGS; do
	remove_pkg "$pkg"
done
for pkg in php php-common php-cli php-fpm php-json php-mysql php-pgsql php-gd php-mbstring php-xml php-curl php-zip php-intl php-bcmath php-soap php-imagick php-redis php-memcached; do
	remove_pkg "$pkg"
done
run_cmd "rm -rf /etc/php"
add_summary "Removed PHP and /etc/php/"

# MySQL / MariaDB
info "Removing MySQL/MariaDB packages..."
for pkg in mariadb-server mariadb-client mariadb-common mysql-server mysql-client mysql-common libmariadb3 libmysqlclient21; do
	remove_pkg "$pkg"
done
run_cmd "rm -rf /etc/mysql"
run_cmd "rm -rf /var/lib/mysql"
run_cmd "rm -rf /var/log/mysql"
add_summary "Removed MySQL/MariaDB packages and data"

# PostgreSQL
info "Removing PostgreSQL packages..."
for pkg in postgresql postgresql-common postgresql-client; do
	remove_pkg "$pkg"
done
run_cmd "rm -rf /etc/postgresql"
run_cmd "rm -rf /var/lib/postgresql"
add_summary "Removed PostgreSQL packages and data"

# Mail (Exim4 + Dovecot)
info "Removing mail packages..."
for pkg in exim4 exim4-base exim4-config exim4-daemon-heavy exim4-daemon-light dovecot-core dovecot-imapd dovecot-pop3d dovecot-managesieved dovecot-sieve dovecot-lmtpd; do
	remove_pkg "$pkg"
done
run_cmd "rm -rf /etc/exim4"
run_cmd "rm -rf /etc/dovecot"
add_summary "Removed Exim4/Dovecot packages and configs"

# DNS (Bind9)
info "Removing DNS packages..."
for pkg in bind9 bind9utils bind9-dnsutils; do
	remove_pkg "$pkg"
done
run_cmd "rm -rf /etc/bind"
add_summary "Removed Bind9 packages and configs"

# FTP (vsftpd)
info "Removing FTP packages..."
remove_pkg "vsftpd"
run_cmd "rm -rf /etc/vsftpd"
add_summary "Removed vsftpd package and config"

# Fail2Ban
info "Removing Fail2Ban packages..."
remove_pkg "fail2ban"
run_cmd "rm -rf /etc/fail2ban"
add_summary "Removed Fail2Ban package and config"

# Webmail/Admin
info "Removing webmail/admin packages..."
for pkg in roundcube roundcube-core roundcube-plugins phpmyadmin phppgadmin; do
	remove_pkg "$pkg"
done
run_cmd "rm -rf /etc/roundcube /etc/phpmyadmin /etc/phppgadmin"
run_cmd "rm -rf /usr/share/roundcube /usr/share/phpmyadmin /usr/share/phppgadmin"
add_summary "Removed roundcube/phpmyadmin/phppgadmin"

success "All service packages removed."

# ----------------------------------------------------------
# Phase 3: Remove Users and Groups
# ----------------------------------------------------------

step "Phase 3: Removing HestiaCP users and groups"

HESTIA_USERS=("hestiaweb" "hestiamail" "hestiasshd" "hestiadns" "hestia" "hestiaftp")
HESTIA_GROUPS=("hestiaweb" "hestiamail" "hestiasshd" "hestiadns" "hestia" "hestiaftp")

for user in "${HESTIA_USERS[@]}"; do
	if id "$user" &>/dev/null; then
		info "Removing user: $user"
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

success "Users and groups removed."

# ----------------------------------------------------------
# Phase 4: Remove HestiaCP Directories
# ----------------------------------------------------------

step "Phase 4: Removing HestiaCP directories and files"

# Main HestiaCP directory
if [ -d "$HESTIA" ]; then
	info "Removing $HESTIA/..."
	run_cmd "rm -rf '$HESTIA'"
	add_summary "Removed: $HESTIA/"
fi

# HestiaCP config directory
if [ -d "/etc/hestiacp" ]; then
	info "Removing /etc/hestiacp/..."
	run_cmd "rm -rf /etc/hestiacp"
	add_summary "Removed: /etc/hestiacp/"
fi

# HestiaCP backup directory
if [ -d "/root/hst_backups" ]; then
	info "Removing /root/hst_backups/..."
	run_cmd "rm -rf /root/hst_backups"
	add_summary "Removed: /root/hst_backups/"
fi

success "Directories removed."

# ----------------------------------------------------------
# Phase 5: Remove Systemd Services
# ----------------------------------------------------------

step "Phase 5: Removing HestiaCP systemd services"

HST_SYSTEMD_FILES=(
	"/etc/systemd/system/hestia.service"
	"/etc/systemd/system/hestia-web-terminal.service"
	"/etc/systemd/system/hestia-web-terminal.socket"
)

for svc_file in "${HST_SYSTEMD_FILES[@]}"; do
	if [ -f "$svc_file" ]; then
		info "Removing systemd unit: $svc_file"
		run_cmd "rm -f '$svc_file'"
		add_summary "Removed systemd unit: $(basename "$svc_file")"
	fi
done

# Remove jail mount units
for unit_file in $(find /etc/systemd/system/ -name "*.mount" 2>/dev/null | grep -i "jail\|hestia" 2>/dev/null); do
	info "Removing jail mount unit: $unit_file"
	run_cmd "systemctl stop '$(basename "$unit_file")' 2>/dev/null || true"
	run_cmd "systemctl disable '$(basename "$unit_file")' 2>/dev/null || true"
	run_cmd "rm -f '$unit_file'"
	add_summary "Removed mount unit: $(basename "$unit_file")"
done

run_cmd "systemctl daemon-reload"

success "Systemd services removed."

# ----------------------------------------------------------
# Phase 6: Remove Web Server Configs (Deep Cleanup)
# ----------------------------------------------------------

step "Phase 6: Removing web server configurations & restoring defaults"

# --- Nginx ---
if [ -d "/etc/nginx" ]; then
	info "Removing HestiaCP nginx configurations (deep scan)..."

	# Remove all HestiaCP conf.d files (installed by hst-install)
	HST_NGINX_CONFS=(
		"status.conf"
		"0rtt-anti-replay.conf"
		"agents.conf"
		"cloudflare.inc"
		"phpmyadmin.inc"
		"phppgadmin.inc"
		"hestia.conf"
		"unassigned.inc"
	)
	for conf in "${HST_NGINX_CONFS[@]}"; do
		run_cmd "rm -f /etc/nginx/conf.d/$conf"
	done

	# Remove HestiaCP-managed domain configs
	run_cmd "rm -rf /etc/nginx/conf.d/domains"

	# Remove any remaining conf.d files referencing hestia
	for f in /etc/nginx/conf.d/*.conf /etc/nginx/conf.d/*.inc; do
		if [ -f "$f" ] && grep -qi "hestia\|/usr/local/hestia" "$f" 2>/dev/null; then
			info "Removing HestiaCP-referencing nginx conf: $(basename "$f")"
			run_cmd "rm -f '$f'"
		fi
	done

	# Remove HestiaCP nginx cache directories
	run_cmd "rm -rf /var/cache/nginx/micro"
	run_cmd "rm -rf /var/cache/nginx/temp"

	# Remove nginx sites-enabled/default if HestiaCP-managed
	if [ -f "/etc/nginx/sites-enabled/default" ] && grep -qi "hestia\|unassigned" /etc/nginx/sites-enabled/default 2>/dev/null; then
		run_cmd "rm -f /etc/nginx/sites-enabled/default"
	fi
	if [ -f "/etc/nginx/sites-available/default" ] && grep -qi "hestia\|unassigned" /etc/nginx/sites-available/default 2>/dev/null; then
		run_cmd "rm -f /etc/nginx/sites-available/default"
	fi

	# Remove HestiaCP nginx logrotate config
	run_cmd "rm -f /etc/logrotate.d/nginx"

	# Remove HestiaCP-created nginx log directories
	run_cmd "rm -rf /var/log/nginx/domains"

	# Remove HestiaCP SSL directory (causes nginx [emerg] cannot load certificate errors)
	run_cmd "rm -rf /usr/local/hestia/ssl"

	# --- Restore nginx.conf to clean default ---
	NGINX_NEEDS_RESTORE=false
	if [ ! -f "/etc/nginx/nginx.conf" ]; then
		NGINX_NEEDS_RESTORE=true
	elif grep -qi "/usr/local/hestia/ssl/\|fastcgi_cache_path.*microcache\|proxy_cache_path.*cache:10m\|conf\.d/domains\|cloudflare\.inc\|0rtt-anti-replay" /etc/nginx/nginx.conf 2>/dev/null; then
		NGINX_NEEDS_RESTORE=true
	fi

	if [ "$NGINX_NEEDS_RESTORE" = true ]; then
		info "Restoring clean default nginx.conf..."
		if [ "$DRY_RUN" = false ]; then
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
		add_summary "Restored nginx.conf to clean default"
	fi

	# --- Fix broken SSL cert references in any remaining site configs ---
	for f in /etc/nginx/conf.d/*.conf /etc/nginx/conf.d/*.inc /etc/nginx/sites-enabled/* /etc/nginx/sites-available/*; do
		if [ -f "$f" ]; then
			if grep -q "/usr/local/hestia/ssl/" "$f" 2>/dev/null; then
				info "Fixing broken SSL cert in: $(basename "$f")"
				if [ "$DRY_RUN" = false ]; then
					sed -i 's|^\s*ssl_certificate[[:space:]]|# ssl_certificate (disabled - cert removed)|g' "$f"
					sed -i 's|^\s*ssl_certificate_key[[:space:]]|# ssl_certificate_key (disabled - cert removed)|g' "$f"
					sed -i 's|^\s*listen.*443.*ssl|# listen 443 ssl (disabled - cert removed)|g' "$f"
				fi
				add_summary "Fixed broken SSL cert in $(basename "$f")"
			fi
			if grep -q "/usr/local/hestia/" "$f" 2>/dev/null; then
				warn "$(basename "$f") still references /usr/local/hestia/ - review manually"
			fi
		fi
	done

	# Ensure directories exist
	run_cmd "mkdir -p /etc/nginx/conf.d /etc/nginx/sites-available /etc/nginx/sites-enabled"

	add_summary "Removed HestiaCP nginx configs + restored defaults"
fi

# --- Apache ---
if [ -d "/etc/apache2" ]; then
	info "Removing HestiaCP apache configurations (deep scan)..."

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
	run_cmd "rm -rf /etc/apache2/conf.d/domains"

	# Remove HestiaCP sites-enabled/available
	run_cmd "rm -f /etc/apache2/sites-enabled/hestia*"
	run_cmd "rm -f /etc/apache2/sites-available/hestia*"

	# Remove any remaining apache confs referencing hestia
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
				sed -i 's|^\s*SSLCertificateFile|# SSLCertificateFile (disabled - cert removed)|g' "$f"
				sed -i 's|^\s*SSLCertificateKeyFile|# SSLCertificateKeyFile (disabled - cert removed)|g' "$f"
			fi
			add_summary "Fixed broken SSL cert in $(basename "$f")"
		fi
	done

	# Remove apache logrotate
	run_cmd "rm -f /etc/logrotate.d/apache2"

	add_summary "Removed HestiaCP apache configs + fixed broken SSL"
fi

success "Web server configurations cleaned and defaults restored."

# ----------------------------------------------------------
# Phase 7: Remove Mail/DNS/FTP Configs (packages already removed in Phase 2b)
# ----------------------------------------------------------

step "Phase 7: Removing remaining mail/DNS/FTP configs"

# Exim4
if [ -d "/etc/exim4" ]; then
	run_cmd "rm -rf /etc/exim4"
	add_summary "Removed /etc/exim4/"
fi

# Dovecot
if [ -d "/etc/dovecot" ]; then
	run_cmd "rm -rf /etc/dovecot"
	add_summary "Removed /etc/dovecot/"
fi

# Bind9
if [ -d "/etc/bind" ]; then
	run_cmd "rm -rf /etc/bind"
	add_summary "Removed /etc/bind/"
fi

# vsftpd
if [ -d "/etc/vsftpd" ]; then
	run_cmd "rm -rf /etc/vsftpd"
	add_summary "Removed /etc/vsftpd/"
fi

success "Remaining configs removed."

# ----------------------------------------------------------
# Phase 8: Remove Firewall Rules
# ----------------------------------------------------------

step "Phase 11: Removing HestiaCP firewall rules"

# Remove iptables rules added by HestiaCP
if command -v iptables &>/dev/null; then
	info "Cleaning iptables rules (HestiaCP chains)..."
	# Remove hestia-specific chains
	for chain in HESTIA HESTIA_OUTPUT; do
		run_cmd "iptables -F '$chain' 2>/dev/null || true"
		run_cmd "iptables -X '$chain' 2>/dev/null || true"
	done
	# Also clean ip6tables
	if command -v ip6tables &>/dev/null; then
		for chain in HESTIA HESTIA_OUTPUT; do
			run_cmd "ip6tables -F '$chain' 2>/dev/null || true"
			run_cmd "ip6tables -X '$chain' 2>/dev/null || true"
		done
	fi
	add_summary "Removed HestiaCP iptables rules"
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
# Phase 12: Remove Fail2Ban HestiaCP Configs
# ----------------------------------------------------------

step "Phase 12: Removing Fail2Ban HestiaCP configurations"

if [ -d "/etc/fail2ban" ]; then
	# Remove HestiaCP fail2ban action
	if [ -f "/etc/fail2ban/action.d/hestia.conf" ]; then
		if grep -qi "hestia\|HestiaCP" /etc/fail2ban/action.d/hestia.conf 2>/dev/null; then
			info "Removing HestiaCP fail2ban action..."
			run_cmd "rm -f /etc/fail2ban/action.d/hestia.conf"
			add_summary "Removed fail2ban action: hestia.conf"
		fi
	fi

	# Remove HestiaCP fail2ban filter
	if [ -f "/etc/fail2ban/filter.d/hestia.conf" ]; then
		info "Removing HestiaCP fail2ban filter..."
		run_cmd "rm -f /etc/fail2ban/filter.d/hestia.conf"
		add_summary "Removed fail2ban filter: hestia.conf"
	fi

	# Remove HestiaCP jail config if it only contains hestia jails
	if [ -f "/etc/fail2ban/jail.local" ]; then
		if grep -qi "hestia\|action.*=.*hestia" /etc/fail2ban/jail.local 2>/dev/null; then
			info "Removing HestiaCP fail2ban jail.local..."
			run_cmd "rm -f /etc/fail2ban/jail.local"
			add_summary "Removed fail2ban jail.local (HestiaCP-managed)"
		fi
	fi

	# Restart fail2ban if still installed
	if systemctl is-active --quiet fail2ban 2>/dev/null; then
		run_cmd "systemctl restart fail2ban"
	fi
fi

success "Fail2Ban HestiaCP configs removed."

# ----------------------------------------------------------
# Phase 13: Remove Chroot Jails
# ----------------------------------------------------------

step "Phase 13: Removing chroot jails"

if [ -d "/srv/jail" ]; then
	info "Removing chroot jail directory..."
	# Stop any jail-related mount units
	for unit in $(systemctl list-units --type=mount --no-legend 2>/dev/null | awk '{print $1}' | grep "srv-jail" 2>/dev/null); do
		run_cmd "systemctl stop '$unit' 2>/dev/null || true"
		run_cmd "systemctl disable '$unit' 2>/dev/null || true"
	done
	for unit_file in $(find /etc/systemd/system/ -name "*srv-jail*" -o -name "*srv--jail*" 2>/dev/null); do
		run_cmd "rm -f '$unit_file'"
	done
	run_cmd "systemctl daemon-reload"
	run_cmd "rm -rf /srv/jail"
	add_summary "Removed chroot jails"
fi

success "Chroot jails removed."

# ----------------------------------------------------------
# Phase 13: Clean Up MOTD, Login Scripts, Logrotate & Crontab
# ----------------------------------------------------------

step "Phase 13: Cleaning MOTD, login scripts, logrotate & crontab"

# Remove HestiaCP MOTD
if [ -f "/etc/update-motd.d/99-hestia" ]; then
	info "Removing HestiaCP MOTD..."
	run_cmd "rm -f /etc/update-motd.d/99-hestia"
	add_summary "Removed HestiaCP MOTD"
fi

# Remove HestiaCP profile.d scripts
if ls /etc/profile.d/hestia* 1>/dev/null 2>&1; then
	info "Removing HestiaCP profile scripts..."
	run_cmd "rm -f /etc/profile.d/hestia*"
	add_summary "Removed HestiaCP profile scripts"
fi

# Remove HestiaCP bash completion
if [ -f "/etc/bash_completion.d/hestia" ]; then
	run_cmd "rm -f /etc/bash_completion.d/hestia"
fi

# --- Logrotate configs ---
info "Removing HestiaCP logrotate configs..."
HST_LOGROTATE=(
	"/etc/logrotate.d/hestia"
	"/etc/logrotate.d/nginx"
	"/etc/logrotate.d/apache2"
	"/etc/logrotate.d/dovecot"
	"/etc/logrotate.d/roundcube"
)
for lr in "${HST_LOGROTATE[@]}"; do
	if [ -f "$lr" ]; then
		# Only remove if it contains HestiaCP markers
		if grep -qi "hestia\|/usr/local/hestia" "$lr" 2>/dev/null; then
			info "Removing HestiaCP logrotate: $(basename "$lr")"
			run_cmd "rm -f '$lr'"
			add_summary "Removed logrotate: $(basename "$lr")"
		fi
	fi
done

# Remove httpd-prerotate
if [ -f "/etc/logrotate.d/httpd-prerotate/awstats" ]; then
	run_cmd "rm -f /etc/logrotate.d/httpd-prerotate/awstats"
fi

# --- Crontab cleanup ---
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

add_summary "Removed HestiaCP crontab and logrotate entries"

success "MOTD, login scripts, logrotate & crontab cleaned."

# ----------------------------------------------------------
# Phase 14: User Data Cleanup (Optional)
# ----------------------------------------------------------

step "Phase 14: User data cleanup"

if confirm "Remove all user web/mail/DNS data (/home/*)? THIS CANNOT BE UNDONE!"; then
	# List HestiaCP-managed user directories
	if [ -d "/home" ]; then
		for user_home in /home/*/; do
			username=$(basename "$user_home")
			# Skip system users and known non-HestiaCP users
			if [[ "$username" == "hestiaweb" ]] || [[ "$username" == "hestiamail" ]] || [[ "$username" == "hestiasshd" ]]; then
				continue
			fi
			# Check if this user has HestiaCP data
			if [ -d "$user_home/web" ] || [ -d "$user_home/conf" ] || [ -d "$user_home/mail" ]; then
				if confirm "Remove user data for '$username'? ($user_home)"; then
					info "Removing user data: $user_home"
					run_cmd "rm -rf '$user_home'"
					add_summary "Removed user data: $username"
				fi
			fi
		done
	fi

	# Remove HestiaCP user config data
	if [ -d "/usr/local/hestia/data" ]; then
		info "Removing HestiaCP user data store..."
		run_cmd "rm -rf /usr/local/hestia/data"
	fi
else
	warn "User data preserved. Files remain in /home/"
fi
# Phase 17: Restart Services
# ----------------------------------------------------------

step "Phase 17: Restarting and verifying web services"

# Nginx - test config then start
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
			log "[NGINX-ERROR] $line"
			echo -e "  ${RED}$line${NC}"
		done
		add_summary "nginx FAILED to start - fix config manually"
	fi
else
	info "nginx not installed, skipping."
fi

# Apache - test config then start
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
			log "[APACHE-ERROR] $line"
			echo -e "  ${YELLOW}$line${NC}"
		done
		add_summary "Apache failed to start - fix config manually"
	fi
else
	info "Apache not installed, skipping."
fi

# Restart cron
if systemctl list-unit-files cron.service &>/dev/null 2>&1; then
	run_cmd "systemctl restart cron"
fi

success "Web services verified."

# ----------------------------------------------------------
# Phase 18: Deep Residue Scan (catch anything missed)
# ----------------------------------------------------------

step "Phase 18: Deep residue scan"

info "Scanning system for remaining HestiaCP artifacts..."

RESIDUE_FOUND=0

# Scan /etc for HestiaCP references
for f in $(find /etc -type f \( -name "*.conf" -o -name "*.inc" -o -name "*.tpl" -o -name "*.stpl" \) 2>/dev/null); do
	if grep -ql "hestia\|/usr/local/hestia\|HESTIA=" "$f" 2>/dev/null; then
		warn "Residue config: $f"
		RESIDUE_FOUND=$((RESIDUE_FOUND + 1))
	fi
done

# Scan for BROKEN SSL cert references (the main nginx [emerg] issue)
for f in $(find /etc/nginx /etc/apache2 -type f 2>/dev/null); do
	if grep -ql "/usr/local/hestia/ssl/" "$f" 2>/dev/null; then
		error "BROKEN SSL CERT REFERENCE: $f"
		RESIDUE_FOUND=$((RESIDUE_FOUND + 1))
	fi
done

# Scan for leftover HestiaCP cron jobs
if crontab -l 2>/dev/null | grep -q "hestia"; then
	warn "Residue crontab: root crontab contains hestia entries"
	RESIDUE_FOUND=$((RESIDUE_FOUND + 1))
fi

# Scan for leftover HestiaCP systemd units
for unit in $(find /etc/systemd /lib/systemd /run/systemd -type f -name "*.service" -o -name "*.timer" -o -name "*.socket" -o -name "*.mount" 2>/dev/null); do
	if grep -ql "hestia\|/usr/local/hestia" "$unit" 2>/dev/null; then
		warn "Residue systemd unit: $unit"
		RESIDUE_FOUND=$((RESIDUE_FOUND + 1))
	fi
done

# Scan for leftover HestiaCP in /usr/local
if [ -d "/usr/local/hestia" ]; then
	warn "Residue directory: /usr/local/hestia still exists"
	RESIDUE_FOUND=$((RESIDUE_FOUND + 1))
fi

# Scan for HestiaCP sudoers entries
if [ -f "/etc/sudoers.d/hestiaweb" ]; then
	warn "Residue sudoers: /etc/sudoers.d/hestiaweb"
	run_cmd "rm -f /etc/sudoers.d/hestiaweb"
	add_summary "Removed sudoers: hestiaweb"
fi

if [ -f "/etc/sudoers.d/hestia" ]; then
	warn "Residue sudoers: /etc/sudoers.d/hestia"
	run_cmd "rm -f /etc/sudoers.d/hestia"
	add_summary "Removed sudoers: hestia"
fi

# Scan for HestiaCP polkit rules
if [ -d "/etc/polkit-1/localauthority.conf.d" ]; then
	for f in /etc/polkit-1/localauthority.conf.d/*hestia*; do
		if [ -f "$f" ]; then
			warn "Residue polkit: $f"
			run_cmd "rm -f '$f'"
		fi
	done
fi

# Scan for HestiaCP AppArmor profiles
if [ -d "/etc/apparmor.d" ]; then
	for f in /etc/apparmor.d/*hestia*; do
		if [ -f "$f" ]; then
			warn "Residue AppArmor: $f"
			run_cmd "rm -f '$f'"
		fi
	done
fi

# Scan /usr/share for HestiaCP leftovers
if [ -d "/usr/share/hestia" ]; then
	warn "Residue directory: /usr/share/hestia"
	run_cmd "rm -rf /usr/share/hestia"
	add_summary "Removed: /usr/share/hestia/"
fi

# Scan /var for HestiaCP leftovers
if [ -d "/var/cache/hestia" ]; then
	run_cmd "rm -rf /var/cache/hestia"
	add_summary "Removed: /var/cache/hestia/"
fi

if [ -d "/var/run/hestia" ]; then
	run_cmd "rm -rf /var/run/hestia"
	add_summary "Removed: /var/run/hestia/"
fi

if [ -d "/var/log/hestia" ]; then
	run_cmd "rm -rf /var/log/hestia"
	add_summary "Removed: /var/log/hestia/"
fi

# Remove HestiaCP apt preferences if any
run_cmd "rm -f /etc/apt/preferences.d/hestia*"

# Remove any HestiaCP dpkg diversions
for diversion in $(dpkg-divert --list 2>/dev/null | grep -i hestia | awk '{print $3}'); do
	info "Removing dpkg diversion: $diversion"
	run_cmd "dpkg-divert --remove --rename '$diversion'"
done

if [ "$RESIDUE_FOUND" -eq 0 ]; then
	success "No remaining HestiaCP residue found."
else
	warn "Found $RESIDUE_FOUND potential residue item(s). Review the log for details."
fi

# Reload systemd one final time
run_cmd "systemctl daemon-reload"

success "Deep residue scan complete."

# ----------------------------------------------------------
# Cleanup
# ----------------------------------------------------------

step "Cleaning up"

# Remove this uninstaller script itself if it's in the HestiaCP directory
if [ -f "$HESTIA/install/hst-uninstall.sh" ]; then
	run_cmd "rm -f '$HESTIA/install/hst-uninstall.sh'"
fi

# Remove any remaining HestiaCP-related temp files
run_cmd "rm -f /tmp/hestia-*"

success "Cleanup complete."

# ----------------------------------------------------------
# Summary
# ----------------------------------------------------------

echo ""
echo "========================================================"
echo -e "${BOLD}${GREEN}  HestiaCP Uninstall Complete${NC}"
echo "========================================================"
echo ""

if [ "$DRY_RUN" = true ]; then
	echo -e "${YELLOW}  DRY-RUN MODE: No changes were actually made.${NC}"
	echo ""
fi

echo -e "${BOLD}Summary of actions:${NC}"
if [ ${#SUMMARY[@]} -eq 0 ]; then
	echo "  No actions were taken."
else
	for item in "${SUMMARY[@]}"; do
		echo -e "  ${GREEN}✓${NC} $item"
	done
fi

echo ""
echo -e "Full log: ${CYAN}$LOG_FILE${NC}"
echo ""

echo "========================================================"
log "=== HestiaCP Uninstall Completed ==="
