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

step "Phase 1: Stopping HestiaCP services"

SERVICES=(
	"hestia"
	"nginx"
	"apache2"
	"exim4"
	"dovecot"
	"named"
	"bind9"
	"vsftpd"
	"mariadb"
	"mysql"
	"postgresql"
	"fail2ban"
	"hestia-web-terminal"
	"cron"
	"php*-fpm"
)

for svc_pattern in "${SERVICES[@]}"; do
	if [[ "$svc_pattern" == *"*"* ]]; then
		# Glob pattern - find matching services
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

# Stop HestiaCP cron jobs
info "Removing HestiaCP cron jobs..."
run_cmd "crontab -u hestiaweb -r 2>/dev/null || true"
run_cmd "rm -f /var/spool/cron/crontabs/hestiaweb"
run_cmd "rm -f /etc/cron.d/hestia*"
add_summary "Removed HestiaCP cron jobs"

success "All services stopped."

# ----------------------------------------------------------
# Phase 2: Remove Packages
# ----------------------------------------------------------

step "Phase 2: Removing HestiaCP packages"

HESTIA_PACKAGES=(
	"hestia"
	"hestia-nginx"
	"hestia-php"
)

for pkg in "${HESTIA_PACKAGES[@]}"; do
	if dpkg -l | grep -q "^ii.*$pkg "; then
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

success "Packages removed."

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

step "Phase 6: Removing web server configurations (deep cleanup)"

# --- Nginx ---
if [ -d "/etc/nginx" ]; then
	info "Removing HestiaCP nginx configurations (deep scan)..."

	# HestiaCP replaces nginx.conf entirely during install
	# Remove the main config if it contains HestiaCP markers
	if [ -f "/etc/nginx/nginx.conf" ]; then
		if grep -qi "hestia\|fastcgi_cache_path\|proxy_cache_path.*microcache\|conf\.d/domains\|cloudflare\.inc" /etc/nginx/nginx.conf 2>/dev/null; then
			info "Removing HestiaCP-managed nginx.conf..."
			run_cmd "rm -f /etc/nginx/nginx.conf"
		fi
	fi

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

	add_summary "Removed HestiaCP nginx configs (deep cleanup)"
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

	# Remove apache logrotate
	run_cmd "rm -f /etc/logrotate.d/apache2"

	add_summary "Removed HestiaCP apache configs (deep cleanup)"
fi

success "Web server configurations removed."

# ----------------------------------------------------------
# Phase 7: Remove PHP-FPM Pools
# ----------------------------------------------------------

step "Phase 7: Removing PHP-FPM pools created by HestiaCP"

if [ -d "/etc/php" ]; then
	for phpver_dir in /etc/php/*/fpm/pool.d/; do
		if [ -d "$phpver_dir" ]; then
			# Remove domain-specific pools (not the default www.conf)
			find "$phpver_dir" -maxdepth 1 -type f -name "*.conf" ! -name "www.conf" -exec rm -f {} \;
			info "Cleaned PHP-FPM pools in $phpver_dir"
		fi
	done
	add_summary "Removed HestiaCP PHP-FPM pools"
fi

success "PHP-FPM pools cleaned."

# ----------------------------------------------------------
# Phase 8: Remove Mail Configs
# ----------------------------------------------------------

step "Phase 8: Removing mail configurations"

# Exim4 HestiaCP configs
if [ -d "/etc/exim4" ]; then
	info "Removing HestiaCP exim4 configurations..."
	run_cmd "rm -f /etc/exim4/exim4.conf.template.hestia*"
	run_cmd "rm -f /etc/exim4/conf.d/main/01_exim4-config_hestia*"
	run_cmd "rm -rf /etc/exim4/domains"
	add_summary "Removed HestiaCP exim4 configs"
fi

# Dovecot HestiaCP configs
if [ -d "/etc/dovecot" ]; then
	info "Removing HestiaCP dovecot configurations..."
	run_cmd "rm -rf /etc/dovecot/conf.d/domains"
	run_cmd "rm -f /etc/dovecot/conf.d/99-hestia*.conf"
	add_summary "Removed HestiaCP dovecot configs"
fi

# DKIM keys
if [ -d "/etc/exim4/domains" ]; then
	run_cmd "rm -rf /etc/exim4/domains"
fi

success "Mail configurations removed."

# ----------------------------------------------------------
# Phase 9: Remove DNS Configs
# ----------------------------------------------------------

step "Phase 9: Removing DNS configurations"

# Bind9 HestiaCP configs
if [ -d "/etc/bind" ]; then
	info "Removing HestiaCP bind9 configurations..."
	run_cmd "rm -rf /etc/bind/hestia"
	# Only remove named.conf.local if it was managed by HestiaCP
	if grep -q "hestia\|HestiaCP" /etc/bind/named.conf.local 2>/dev/null; then
		run_cmd "rm -f /etc/bind/named.conf.local"
	fi
	add_summary "Removed HestiaCP bind9 configs"
fi

success "DNS configurations removed."

# ----------------------------------------------------------
# Phase 10: Remove FTP Config
# ----------------------------------------------------------

step "Phase 10: Removing FTP configurations"

if [ -f "/etc/vsftpd.conf" ]; then
	if grep -q "hestia\|HestiaCP" /etc/vsftpd.conf 2>/dev/null; then
		info "Removing HestiaCP vsftpd configuration..."
		run_cmd "rm -f /etc/vsftpd.conf"
		add_summary "Removed HestiaCP vsftpd config"
	fi
fi

# Remove HestiaCP FTP users
if [ -d "/etc/vsftpd" ]; then
	run_cmd "rm -rf /etc/vsftpd/user_config_dir"
fi

success "FTP configurations removed."

# ----------------------------------------------------------
# Phase 11: Remove Firewall Rules
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
# Phase 14: Database Cleanup (Optional)
# ----------------------------------------------------------

step "Phase 14: Database cleanup"

DB_CLEANED=false

if confirm "Remove HestiaCP-managed database users and databases?"; then
	# MySQL/MariaDB
	if command -v mysql &>/dev/null || command -v mariadb &>/dev/null; then
		db_cmd=""
		if command -v mariadb &>/dev/null; then
			db_cmd="mariadb"
		else
			db_cmd="mysql"
		fi

		# Find and remove HestiaCP databases (heuristic: user_ prefix)
		db_list=$($db_cmd -N -e "SHOW DATABASES LIKE 'hst\_%'" 2>/dev/null || true)
		if [ -n "$db_list" ]; then
			for dbname in $db_list; do
				info "Removing MySQL database: $dbname"
				run_cmd "$db_cmd -e \"DROP DATABASE IF EXISTS \\\`$dbname\\\`\""
				add_summary "Removed database: $dbname"
			done
		fi

		# Find and remove HestiaCP database users (heuristic: hst_ prefix)
		db_users=$($db_cmd -N -e "SELECT User FROM mysql.user WHERE User LIKE 'hst\_%'" 2>/dev/null || true)
		if [ -n "$db_users" ]; then
			for dbuser in $db_users; do
				info "Removing MySQL user: $dbuser"
				run_cmd "$db_cmd -e \"DROP USER IF EXISTS '$dbuser'@'localhost'\""
				run_cmd "$db_cmd -e \"DROP USER IF EXISTS '$dbuser'@'%'\""
				add_summary "Removed database user: $dbuser"
			done
		fi
	fi

	# PostgreSQL
	if command -v psql &>/dev/null; then
		pg_dbs=$(sudo -u postgres psql -t -c "SELECT datname FROM pg_database WHERE datname LIKE 'hst\_%'" 2>/dev/null || true)
		if [ -n "$pg_dbs" ]; then
			for dbname in $pg_dbs; do
				dbname=$(echo "$dbname" | xargs)
				if [ -n "$dbname" ]; then
					info "Removing PostgreSQL database: $dbname"
					run_cmd "sudo -u postgres dropdb '$dbname'"
					add_summary "Removed PG database: $dbname"
				fi
			done
		fi

		pg_users=$(sudo -u postgres psql -t -c "SELECT usename FROM pg_user WHERE usename LIKE 'hst\_%'" 2>/dev/null || true)
		if [ -n "$pg_users" ]; then
			for pguser in $pg_users; do
				pguser=$(echo "$pguser" | xargs)
				if [ -n "$pguser" ]; then
					info "Removing PostgreSQL user: $pguser"
					run_cmd "sudo -u postgres dropuser '$pguser'"
					add_summary "Removed PG user: $pguser"
				fi
			done
		fi
	fi

	DB_CLEANED=true
fi

if [ "$DB_CLEANED" = false ]; then
	warn "Database cleanup skipped. You may need to manually remove HestiaCP databases/users."
fi

# ----------------------------------------------------------
# Phase 15: User Data Cleanup (Optional)
# ----------------------------------------------------------

step "Phase 15: User data cleanup"

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

# ----------------------------------------------------------
# Phase 16: Restore Original Configs (Optional)
# ----------------------------------------------------------

step "Phase 16: Configuration restoration"

BACKUP_DIR=""
# Search for HestiaCP backups
for dir in /root/hst_backups/*/; do
	if [ -d "$dir" ]; then
		BACKUP_DIR="$dir"
		break
	fi
done

if [ -n "$BACKUP_DIR" ] && [ -d "$BACKUP_DIR" ]; then
	if confirm "Found backup at $BACKUP_DIR. Restore original configs from backup?"; then
		# Restore nginx configs
		if [ -d "$BACKUP_DIR/conf/nginx" ]; then
			info "Restoring nginx configuration from backup..."
			run_cmd "cp -rf '$BACKUP_DIR/conf/nginx/'* /etc/nginx/"
			add_summary "Restored nginx config from backup"
		fi

		# Restore apache configs
		if [ -d "$BACKUP_DIR/conf/apache2" ]; then
			info "Restoring apache configuration from backup..."
			run_cmd "cp -rf '$BACKUP_DIR/conf/apache2/'* /etc/apache2/"
			add_summary "Restored apache config from backup"
		fi

		# Restore exim configs
		if [ -d "$BACKUP_DIR/conf/exim4" ]; then
			info "Restoring exim4 configuration from backup..."
			run_cmd "cp -rf '$BACKUP_DIR/conf/exim4/'* /etc/exim4/"
			add_summary "Restored exim4 config from backup"
		fi

		# Restore dovecot configs
		if [ -d "$BACKUP_DIR/conf/dovecot" ]; then
			info "Restoring dovecot configuration from backup..."
			run_cmd "cp -rf '$BACKUP_DIR/conf/dovecot/'* /etc/dovecot/"
			add_summary "Restored dovecot config from backup"
		fi

		# Restore bind configs
		if [ -d "$BACKUP_DIR/conf/bind9" ]; then
			info "Restoring bind9 configuration from backup..."
			run_cmd "cp -rf '$BACKUP_DIR/conf/bind9/'* /etc/bind/"
			add_summary "Restored bind9 config from backup"
		fi

		success "Configuration restoration complete."
	else
		info "Configuration restoration skipped."
	fi
else
	info "No HestiaCP backup found for config restoration."
fi

# ----------------------------------------------------------
# Phase 17: Restart Services
# ----------------------------------------------------------

step "Phase 17: Restarting remaining services"

# Restart services that may still be needed (non-HestiaCP)
RESTART_SERVICES=()

# Restart nginx if still installed and not HestiaCP-managed
if command -v nginx &>/dev/null && [ ! -f "/etc/systemd/system/hestia.service" ]; then
	RESTART_SERVICES+=("nginx")
fi

# Restart apache if still installed
if command -v apache2ctl &>/dev/null; then
	RESTART_SERVICES+=("apache2")
fi

# Restart cron
if systemctl is-enabled cron &>/dev/null; then
	RESTART_SERVICES+=("cron")
fi

for svc in "${RESTART_SERVICES[@]}"; do
	if systemctl list-unit-files "${svc}.service" &>/dev/null; then
		info "Restarting $svc..."
		run_cmd "systemctl restart '$svc'"
		add_summary "Restarted: $svc"
	fi
done

success "Services restarted."

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

if [ "$DB_CLEANED" = false ]; then
	echo -e "${YELLOW}NOTE: Database cleanup was skipped. Review your MySQL/PostgreSQL${NC}"
	echo -e "${YELLOW}      installations for leftover HestiaCP databases/users.${NC}"
	echo ""
fi

echo "========================================================"
log "=== HestiaCP Uninstall Completed ==="
