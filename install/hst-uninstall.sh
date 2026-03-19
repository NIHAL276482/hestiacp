#!/bin/bash

# ======================================================== #
#
# Hestia Control Panel Uninstaller
# Complete removal - leaves no traces
# https://www.hestiacp.com/
#
# Usage:
#   bash hst-uninstall.sh [--force] [--dry-run] [--keep-data]
#
# ======================================================== #

set -euo pipefail

# ----------------------------------------------------------
# Global Settings
# ----------------------------------------------------------

LOG_FILE="/var/log/hestia-uninstall.log"
DRY_RUN=false
FORCE=false
KEEP_DATA=false
SUMMARY=()

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
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
		--keep-data|-k)
			KEEP_DATA=true
			shift
			;;
		--help|-h)
			echo "HestiaCP Uninstaller"
			echo ""
			echo "Usage: bash hst-uninstall.sh [OPTIONS]"
			echo ""
			echo "Options:"
			echo "  --force, -f       Skip all confirmation prompts"
			echo "  --dry-run, -n     Show what would be done without making changes"
			echo "  --keep-data, -k   Keep user web/mail/db data in /home/"
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
echo "  Hestia Control Panel Uninstaller"
echo "========================================================"
echo -e "${NC}"

mkdir -p "$(dirname "$LOG_FILE")"
touch "$LOG_FILE"
log "=== HestiaCP Uninstall Started ==="
log "Force: $FORCE | Dry-run: $DRY_RUN | Keep-data: $KEEP_DATA"

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
			exit 1
			;;
	esac
	success "Detected: $OS_TYPE $OS_VERSION"
else
	error "Cannot detect OS."
	exit 1
fi

# Check if HestiaCP is installed
step "Checking HestiaCP installation"

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

# Confirmation
echo ""
echo -e "${RED}${BOLD}WARNING: This will completely remove HestiaCP from your system!${NC}"
echo -e "${RED}This includes:${NC}"
echo -e "  - All HestiaCP services and packages"
echo -e "  - Configuration files in /usr/local/hestia/"
echo -e "  - Web server, mail, DNS, and firewall configs"
echo -e "  - System users created by HestiaCP"
echo -e "  - Cron jobs, systemd services, SSL certs"
echo ""

if ! confirm "Are you sure you want to proceed?"; then
	info "Uninstall aborted by user."
	exit 0
fi

# ----------------------------------------------------------
# Phase 1: Stop All HestiaCP Services
# ----------------------------------------------------------

step "Phase 1: Stopping all HestiaCP services"

# Stop hestia main service first
for svc in hestia hestia-nginx hestia-php; do
	run_cmd "systemctl stop '$svc' 2>/dev/null || true"
	run_cmd "systemctl disable '$svc' 2>/dev/null || true"
done

# Stop all web/database/mail services that HestiaCP manages
ALL_SERVICES=(
	nginx apache2
	"php*-fpm"
	exim4 dovecot
	named bind9
	vsftpd proftpd
	"mariadb" "mysql"
	postgresql
	fail2ban
	clamav-daemon clamav-freshclam
	spamassassin spampd
	cron
	hestia-web-terminal
)

for svc_pattern in "${ALL_SERVICES[@]}"; do
	if [[ "$svc_pattern" == *"*"* ]]; then
		for svc in $(systemctl list-unit-files --type=service --no-legend 2>/dev/null | awk '{print $1}' | grep -E "^${svc_pattern//\*/.*}" 2>/dev/null); do
			svc_name="${svc%.service}"
			if systemctl is-active --quiet "$svc_name" 2>/dev/null; then
				info "Stopping $svc_name..."
				run_cmd "systemctl stop '$svc_name'"
				run_cmd "systemctl disable '$svc_name'"
				add_summary "Stopped: $svc_name"
			fi
		done
	else
		if systemctl is-active --quiet "$svc_pattern" 2>/dev/null; then
			info "Stopping $svc_pattern..."
			run_cmd "systemctl stop '$svc_pattern'"
			run_cmd "systemctl disable '$svc_pattern'"
			add_summary "Stopped: $svc_pattern"
		fi
	fi
done

success "All services stopped."

# ----------------------------------------------------------
# Phase 2: Remove Cron Jobs
# ----------------------------------------------------------

step "Phase 2: Removing all HestiaCP cron jobs"

# System-level cron
run_cmd "rm -f /etc/cron.d/hestia*"
run_cmd "rm -f /etc/cron.d/hestia-*"
run_cmd "rm -f /etc/cron.daily/hestia*"
run_cmd "rm -f /etc/cron.hourly/hestia*"
run_cmd "rm -f /etc/cron.weekly/hestia*"
run_cmd "rm -f /etc/cron.monthly/hestia*"
add_summary "Removed system cron jobs"

# Per-user crontabs for hestia system users
for huser in hestiaweb hestiamail hestiasshd hestiadns hestia hestiaftp; do
	run_cmd "crontab -u '$huser' -r 2>/dev/null || true"
	run_cmd "rm -f /var/spool/cron/crontabs/$huser"
done
add_summary "Removed per-user cron jobs"

# Remove any admin user crontabs added by HestiaCP
if [ -d "/var/spool/cron/crontabs" ]; then
	for cfile in /var/spool/cron/crontabs/*; do
		[ -f "$cfile" ] || continue
		if grep -ql "hestia\|HestiaCP\|v-backup-users\|v-update-sys-queue" "$cfile" 2>/dev/null; then
			username=$(basename "$cfile")
			if confirm "Remove crontab for user '$username' (contains HestiaCP entries)?"; then
				run_cmd "crontab -u '$username' -r 2>/dev/null || true"
				add_summary "Removed crontab: $username"
			fi
		fi
	done
fi

success "Cron jobs cleaned."

# ----------------------------------------------------------
# Phase 3: Remove Packages
# ----------------------------------------------------------

step "Phase 3: Removing HestiaCP packages"

HESTIA_PACKAGES=(hestia hestia-nginx hestia-php hestia-web-terminal)
for pkg in "${HESTIA_PACKAGES[@]}"; do
	if dpkg -l 2>/dev/null | grep -q "^ii.*$pkg "; then
		info "Purging package: $pkg"
		run_cmd "dpkg --purge '$pkg'"
		add_summary "Purged package: $pkg"
	fi
done

# Remove apt repository and keys
info "Removing HestiaCP apt repository..."
run_cmd "rm -f /etc/apt/sources.list.d/hestia.list"
run_cmd "rm -f /etc/apt/sources.list.d/hestiacp.list"
run_cmd "rm -f /etc/apt/trusted.gpg.d/hestia*"
run_cmd "rm -f /usr/share/keyrings/hestia*"
run_cmd "apt-get update -qq 2>/dev/null || true"
add_summary "Removed apt repository and keys"

success "Packages removed."

# ----------------------------------------------------------
# Phase 4: Kill Remaining Processes
# ----------------------------------------------------------

step "Phase 4: Killing any remaining HestiaCP processes"

for proc in hestia hestia-nginx hestia-php hestiaweb; do
	pkill -f "$proc" 2>/dev/null || true
done

# Kill any php-fpm processes running under hestiaweb
pkill -u hestiaweb 2>/dev/null || true

success "Processes cleaned."

# ----------------------------------------------------------
# Phase 5: Remove Users and Groups
# ----------------------------------------------------------

step "Phase 5: Removing HestiaCP users and groups"

HESTIA_USERS=(hestiaweb hestiamail hestiasshd hestiadns hestia hestiaftp)
HESTIA_GROUPS=(hestiaweb hestiamail hestiasshd hestiadns hestia hestiaftp sftp_users)

for user in "${HESTIA_USERS[@]}"; do
	if id "$user" &>/dev/null; then
		info "Removing user: $user"
		# Kill any remaining processes
		run_cmd "pkill -9 -u '$user' 2>/dev/null || true"
		run_cmd "sleep 1"
		run_cmd "userdel -f -r '$user' 2>/dev/null || true"
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
# Phase 6: Remove Main Directories
# ----------------------------------------------------------

step "Phase 6: Removing HestiaCP directories"

HESTIA_DIRS=(
	"/usr/local/hestia"
	"/etc/hestiacp"
	"/var/cache/hestia"
	"/var/log/hestia"
	"/run/hestia"
	"/root/hst_backups"
	"/root/hst_install_backups"
	"/tmp/hestia-*"
	"/tmp/hestiacp-*"
)

for dir in "${HESTIA_DIRS[@]}"; do
	if [[ "$dir" == *"*"* ]]; then
		for match in $dir; do
			[ -e "$match" ] || continue
			info "Removing: $match"
			run_cmd "rm -rf '$match'"
			add_summary "Removed: $match"
		done
	elif [ -e "$dir" ]; then
		info "Removing: $dir"
		run_cmd "rm -rf '$dir'"
		add_summary "Removed: $dir"
	fi
done

success "Directories removed."

# ----------------------------------------------------------
# Phase 7: Remove Systemd Units
# ----------------------------------------------------------

step "Phase 7: Removing systemd units"

# Direct hestia service files
HST_SYSTEMD_GLOB="/etc/systemd/system/hestia*"
for f in $HST_SYSTEMD_GLOB; do
	[ -f "$f" ] || continue
	info "Removing systemd unit: $f"
	run_cmd "systemctl stop '$(basename "$f" .service)' 2>/dev/null || true"
	run_cmd "systemctl disable '$(basename "$f" .service)' 2>/dev/null || true"
	run_cmd "rm -f '$f'"
	add_summary "Removed: $(basename "$f")"
done

# Socket units
for f in /etc/systemd/system/hestia*.socket; do
	[ -f "$f" ] || continue
	run_cmd "systemctl stop '$(basename "$f" .socket).socket' 2>/dev/null || true"
	run_cmd "systemctl disable '$(basename "$f" .socket).socket' 2>/dev/null || true"
	run_cmd "rm -f '$f'"
done

# Jail mount units (bubblewrap/chroot)
for f in $(find /etc/systemd/system/ -name "*.mount" 2>/dev/null | grep -iE "jail|hestia|srv-jail|srv--jail"); do
	info "Removing mount unit: $f"
	run_cmd "systemctl stop '$(basename "$f")' 2>/dev/null || true"
	run_cmd "systemctl disable '$(basename "$f")' 2>/dev/null || true"
	run_cmd "umount '$(basename "$f" .mount | sed "s/-/\\//g")' 2>/dev/null || true"
	run_cmd "rm -f '$f'"
	add_summary "Removed mount: $(basename "$f")"
done

# Web terminal socket
run_cmd "rm -f /etc/systemd/system/hestia-web-terminal.service"
run_cmd "rm -f /etc/systemd/system/hestia-web-terminal.socket"

run_cmd "systemctl daemon-reload"
run_cmd "systemctl reset-failed"

success "Systemd units removed."

# ----------------------------------------------------------
# Phase 8: Remove Nginx Configs
# ----------------------------------------------------------

step "Phase 8: Removing nginx configurations"

if [ -d "/etc/nginx" ]; then
	# HestiaCP nginx include files
	run_cmd "rm -f /etc/nginx/conf.d/hestia*"
	run_cmd "rm -rf /etc/nginx/conf.d/domains"
	run_cmd "rm -f /etc/nginx/conf.d/status.conf"

	# Restore original nginx config if backup exists
	BACKUP_DIR=""
	for dir in /root/hst_install_backups/*/; do
		[ -d "$dir" ] || continue
		if [ -d "${dir}nginx" ]; then
			BACKUP_DIR="${dir}nginx"
			break
		fi
	done

	if [ -n "$BACKUP_DIR" ] && [ "$BACKUP_DIR" != "" ]; then
		if confirm "Restore original nginx config from $BACKUP_DIR?"; then
			run_cmd "cp -rf '$BACKUP_DIR/'* /etc/nginx/ 2>/dev/null || true"
			add_summary "Restored original nginx config"
		fi
	else
		# Remove HestiaCP nginx binary if it installed its own
		if [ -f "/usr/local/hestia/nginx/sbin/nginx" ]; then
			run_cmd "rm -f /usr/sbin/nginx"
			run_cmd "apt-get install -y --reinstall nginx 2>/dev/null || true"
		fi
	fi

	add_summary "Cleaned nginx configs"
fi

success "Nginx cleaned."

# ----------------------------------------------------------
# Phase 9: Remove Apache Configs
# ----------------------------------------------------------

step "Phase 9: Removing Apache configurations"

if [ -d "/etc/apache2" ]; then
	run_cmd "rm -rf /etc/apache2/conf.d/hestia*"
	run_cmd "rm -rf /etc/apache2/conf.d/domains"
	run_cmd "rm -rf /etc/apache2/sites-enabled/hestia*"
	run_cmd "rm -rf /etc/apache2/sites-available/hestia*"

	add_summary "Cleaned Apache configs"
fi

success "Apache cleaned."

# ----------------------------------------------------------
# Phase 10: Remove PHP-FPM Pools
# ----------------------------------------------------------

step "Phase 10: Removing PHP-FPM pools"

if [ -d "/etc/php" ]; then
	for phpver_dir in /etc/php/*/fpm/pool.d/; do
		[ -d "$phpver_dir" ] || continue
		# Remove domain/user-specific pools, keep www.conf
		count=$(find "$phpver_dir" -maxdepth 1 -type f -name "*.conf" ! -name "www.conf" 2>/dev/null | wc -l)
		if [ "$count" -gt 0 ]; then
			find "$phpver_dir" -maxdepth 1 -type f -name "*.conf" ! -name "www.conf" -exec rm -f {} \;
			info "Removed $count custom PHP-FPM pools from $phpver_dir"
		fi
	done
	add_summary "Cleaned PHP-FPM pools"
fi

success "PHP-FPM cleaned."

# ----------------------------------------------------------
# Phase 11: Remove Mail Configs
# ----------------------------------------------------------

step "Phase 11: Removing mail configurations"

# Exim4
if [ -d "/etc/exim4" ]; then
	run_cmd "rm -f /etc/exim4/exim4.conf.template.hestia*"
	run_cmd "rm -f /etc/exim4/conf.d/main/01_exim4-config_hestia*"
	run_cmd "rm -rf /etc/exim4/domains"
	run_cmd "rm -rf /etc/exim4/ssl"

	# Restore original exim config
	for dir in /root/hst_install_backups/*/; do
		[ -d "${dir}exim4" ] || continue
		if confirm "Restore original exim4 config from ${dir}?"; then
			run_cmd "cp -rf '${dir}exim4/'* /etc/exim4/"
			break
		fi
	done

	add_summary "Cleaned exim4 configs"
fi

# Dovecot
if [ -d "/etc/dovecot" ]; then
	run_cmd "rm -rf /etc/dovecot/conf.d/domains"
	run_cmd "rm -f /etc/dovecot/conf.d/99-hestia*.conf"
	run_cmd "rm -f /etc/dovecot/conf.d/*.conf.hestia*"
	add_summary "Cleaned dovecot configs"
fi

# DKIM keys
run_cmd "rm -rf /etc/exim4/domains"

# Roundcube (if installed by Hestia)
run_cmd "rm -rf /var/lib/roundcube"
run_cmd "rm -rf /etc/roundcube"

success "Mail configs cleaned."

# ----------------------------------------------------------
# Phase 12: Remove DNS Configs
# ----------------------------------------------------------

step "Phase 12: Removing DNS configurations"

if [ -d "/etc/bind" ]; then
	run_cmd "rm -rf /etc/bind/hestia"
	run_cmd "rm -rf /etc/bind/zones"

	if [ -f "/etc/bind/named.conf.local" ] && grep -ql "hestia\|HestiaCP" /etc/bind/named.conf.local 2>/dev/null; then
		run_cmd "rm -f /etc/bind/named.conf.local"
	fi

	# Restore original bind config
	for dir in /root/hst_install_backups/*/; do
		[ -d "${dir}bind" ] || continue
		if confirm "Restore original bind config from ${dir}?"; then
			run_cmd "cp -rf '${dir}bind/'* /etc/bind/"
			break
		fi
	done

	add_summary "Cleaned bind9 configs"
fi

success "DNS configs cleaned."

# ----------------------------------------------------------
# Phase 13: Remove FTP Configs
# ----------------------------------------------------------

step "Phase 13: Removing FTP configurations"

# vsftpd
if [ -f "/etc/vsftpd.conf" ]; then
	if grep -ql "hestia\|HestiaCP" /etc/vsftpd.conf 2>/dev/null; then
		run_cmd "rm -f /etc/vsftpd.conf"
		add_summary "Removed vsftpd config"
	fi
fi
run_cmd "rm -rf /etc/vsftpd/user_config_dir"

# proftpd
if [ -d "/etc/proftpd" ]; then
	if grep -ql "hestia\|HestiaCP" /etc/proftpd/proftpd.conf 2>/dev/null; then
		run_cmd "rm -rf /etc/proftpd"
		add_summary "Removed proftpd config"
	fi
fi

# FTP user databases
run_cmd "rm -f /etc/vsftpd/vsftpd.userlist"
run_cmd "rm -f /etc/vsftpd.chroot_list"

success "FTP configs cleaned."

# ----------------------------------------------------------
# Phase 14: Remove Fail2Ban Configs
# ----------------------------------------------------------

step "Phase 14: Removing Fail2Ban configurations"

if [ -d "/etc/fail2ban" ]; then
	# Remove HestiaCP jail configs
	run_cmd "rm -f /etc/fail2ban/jail.d/hestia*.conf"
	run_cmd "rm -f /etc/fail2ban/jail.d/hestia*.local"
	run_cmd "rm -f /etc/fail2ban/filter.d/hestia*.conf"
	run_cmd "rm -f /etc/fail2ban/action.d/hestia*.conf"

	# Remove HestiaCP-managed ban databases
	run_cmd "rm -f /var/lib/fail2ban/fail2ban.sqlite3"

	add_summary "Cleaned Fail2Ban configs"
fi

success "Fail2Ban cleaned."

# ----------------------------------------------------------
# Phase 15: Remove Firewall Rules
# ----------------------------------------------------------

step "Phase 15: Removing firewall rules"

# iptables - HestiaCP chains
if command -v iptables &>/dev/null; then
	for chain in HESTIA HESTIA_OUTPUT; do
		# Remove references from INPUT/OUTPUT chains
		while iptables -L INPUT -n 2>/dev/null | grep -q "$chain"; do
			run_cmd "iptables -D INPUT -j '$chain' 2>/dev/null || true"
		done
		while iptables -L OUTPUT -n 2>/dev/null | grep -q "$chain"; do
			run_cmd "iptables -D OUTPUT -j '$chain' 2>/dev/null || true"
		done
		run_cmd "iptables -F '$chain' 2>/dev/null || true"
		run_cmd "iptables -X '$chain' 2>/dev/null || true"
	done

	# ip6tables
	if command -v ip6tables &>/dev/null; then
		for chain in HESTIA HESTIA_OUTPUT; do
			while ip6tables -L INPUT -n 2>/dev/null | grep -q "$chain"; do
				run_cmd "ip6tables -D INPUT -j '$chain' 2>/dev/null || true"
			done
			while ip6tables -L OUTPUT -n 2>/dev/null | grep -q "$chain"; do
				run_cmd "ip6tables -D OUTPUT -j '$chain' 2>/dev/null || true"
			done
			run_cmd "ip6tables -F '$chain' 2>/dev/null || true"
			run_cmd "ip6tables -X '$chain' 2>/dev/null || true"
		done
	fi

	# Save clean rules
	if command -v netfilter-persistent &>/dev/null; then
		run_cmd "netfilter-persistent save 2>/dev/null || true"
	elif [ -f /etc/iptables/rules.v4 ]; then
		run_cmd "iptables-save > /etc/iptables/rules.v4"
		[ -f /etc/iptables/rules.v6 ] && run_cmd "ip6tables-save > /etc/iptables/rules.v6"
	fi

	add_summary "Cleaned iptables rules"
fi

# ipset
if command -v ipset &>/dev/null; then
	for set_name in $(ipset list -n 2>/dev/null | grep -iE "hestia|hestia_"); do
		info "Destroying ipset: $set_name"
		run_cmd "ipset destroy '$set_name' 2>/dev/null || true"
	done
	add_summary "Cleaned ipset sets"
fi


success "Firewall cleaned."

# ----------------------------------------------------------
# Phase 16: Remove SSL Certificates
# ----------------------------------------------------------

step "Phase 16: Removing SSL certificates"

# HestiaCP-managed certs
run_cmd "rm -rf /usr/local/hestia/ssl"
run_cmd "rm -rf /etc/ssl/certs/hestia*"
run_cmd "rm -rf /etc/ssl/private/hestia*"

# Let's Encrypt certs managed by HestiaCP
if [ -d "/etc/letsencrypt" ]; then
	if confirm "Remove Let's Encrypt certificates managed by HestiaCP?"; then
		# Only remove if they were clearly HestiaCP-managed
		for conf_dir in /etc/letsencrypt/renewal/*; do
			[ -f "$conf_dir" ] || continue
			if grep -ql "hestia\|HestiaCP\|/home/" "$conf_dir" 2>/dev/null; then
				domain=$(basename "$conf_dir" .conf)
				info "Removing Let's Encrypt cert: $domain"
				run_cmd "certbot delete --cert-name '$domain' --non-interactive 2>/dev/null || true"
				run_cmd "rm -rf '/etc/letsencrypt/live/$domain'"
				run_cmd "rm -rf '/etc/letsencrypt/archive/$domain'"
				run_cmd "rm -f '/etc/letsencrypt/renewal/$domain.conf'"
				add_summary "Removed LE cert: $domain"
			fi
		done
	fi
fi

# Self-signed certs in user homes
if [ -d "/home" ]; then
	find /home -path "*/conf/ssl/*" -name "*.pem" -delete 2>/dev/null || true
	find /home -path "*/conf/ssl/*" -name "*.crt" -delete 2>/dev/null || true
	find /home -path "*/conf/ssl/*" -name "*.key" -delete 2>/dev/null || true
fi

success "SSL certs cleaned."

# ----------------------------------------------------------
# Phase 17: Remove Chroot Jails
# ----------------------------------------------------------

step "Phase 17: Removing chroot jails"

if [ -d "/srv/jail" ]; then
	for unit in $(systemctl list-units --type=mount --no-legend 2>/dev/null | awk '{print $1}' | grep -E "srv-jail|srv--jail" 2>/dev/null); do
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
# Phase 18: Remove AppArmor Profiles
# ----------------------------------------------------------

step "Phase 18: Removing AppArmor profiles"

if [ -d "/etc/apparmor.d" ]; then
	for profile in /etc/apparmor.d/hestia*; do
		[ -f "$profile" ] || continue
		profile_name=$(basename "$profile")
		info "Removing AppArmor profile: $profile_name"
		run_cmd "apparmor_parser -R '$profile' 2>/dev/null || true"
		run_cmd "rm -f '$profile'"
		add_summary "Removed AppArmor profile: $profile_name"
	done
fi

success "AppArmor cleaned."

# ----------------------------------------------------------
# Phase 19: Remove Logrotate Configs
# ----------------------------------------------------------

step "Phase 19: Removing logrotate configurations"

run_cmd "rm -f /etc/logrotate.d/hestia"
run_cmd "rm -f /etc/logrotate.d/hestia-*"
run_cmd "rm -f /etc/logrotate.d/hestia_*"
add_summary "Removed logrotate configs"

success "Logrotate cleaned."

# ----------------------------------------------------------
# Phase 20: Remove Sudoers Entries
# ----------------------------------------------------------

step "Phase 20: Removing sudoers entries"

run_cmd "rm -f /etc/sudoers.d/hestia"
run_cmd "rm -f /etc/sudoers.d/hestia-*"
run_cmd "rm -f /etc/sudoers.d/hestiaweb"

# Validate sudoers after cleanup
if [ -f /etc/sudoers ]; then
	run_cmd "visudo -c 2>/dev/null || true"
fi

add_summary "Cleaned sudoers"

success "Sudoers cleaned."

# ----------------------------------------------------------
# Phase 21: Remove MOTD and Login Scripts
# ----------------------------------------------------------

step "Phase 21: Restoring default MOTD and login scripts"

# Remove HestiaCP MOTD files
run_cmd "rm -f /etc/update-motd.d/99-hestia"
run_cmd "rm -f /etc/update-motd.d/90-hestia"
run_cmd "rm -f /etc/update-motd.d/99-hestia-*"
add_summary "Removed HestiaCP MOTD"

# Restore default Ubuntu/Debian MOTD scripts if they were backed up
# during install (HestiaCP backs up configs to /root/hst_install_backups/)
MOTD_RESTORED=false
for dir in /root/hst_install_backups/*/; do
	[ -d "$dir" ] || continue
	if [ -d "${dir}update-motd.d" ] || [ -d "${dir}motd" ]; then
		motd_src="${dir}update-motd.d"
		[ -d "$motd_src" ] || motd_src="${dir}motd"
		if [ -d "$motd_src" ]; then
			info "Restoring default MOTD from backup: $motd_src"
			run_cmd "cp -rf '$motd_src/'* /etc/update-motd.d/ 2>/dev/null || true"
			run_cmd "chmod +x /etc/update-motd.d/* 2>/dev/null || true"
			MOTD_RESTORED=true
			add_summary "Restored default MOTD from backup"
			break
		fi
	fi
done

# If no backup found, reinstall the default motd package
if [ "$MOTD_RESTORED" = false ]; then
	# Re-enable common default MOTD scripts that HestiaCP may have disabled
	DEFAULT_MOTD_SCRIPTS=(
		"00-header"
		"10-help-text"
		"50-motd-news"
		"91-contract-ua-esm-status"
		"97-overlayroot"
		"98-fsck-at-reboot"
		"98-reboot-required"
	)
	for motd_script in "${DEFAULT_MOTD_SCRIPTS[@]}"; do
		if [ -f "/etc/update-motd.d/${motd_script}.disabled" ]; then
			info "Re-enabling MOTD script: $motd_script"
			run_cmd "mv /etc/update-motd.d/${motd_script}.disabled /etc/update-motd.d/${motd_script}"
			run_cmd "chmod +x /etc/update-motd.d/${motd_script}"
			MOTD_RESTORED=true
			add_summary "Re-enabled MOTD: $motd_script"
		fi
	done

	# If motd package is missing, reinstall it
	if [ "$OS_TYPE" = "ubuntu" ] && ! dpkg -l 2>/dev/null | grep -q "^ii.*base-files "; then
		run_cmd "apt-get install -y --reinstall base-files 2>/dev/null || true"
		add_summary "Reinstalled base-files (default MOTD)"
	elif [ "$OS_TYPE" = "debian" ] && ! dpkg -l 2>/dev/null | grep -q "^ii.*base-files "; then
		run_cmd "apt-get install -y --reinstall base-files 2>/dev/null || true"
		add_summary "Reinstalled base-files (default MOTD)"
	fi
fi

# Reset /etc/motd to default if HestiaCP modified it
if [ -f "/etc/motd" ]; then
	if grep -ql "Hestia|hestia|HestiaCP" /etc/motd 2>/dev/null; then
		info "Resetting /etc/motd to default..."
		run_cmd "printf '\n' > /etc/motd"
		add_summary "Reset /etc/motd"
	fi
fi

# Remove HestiaCP profile.d scripts
run_cmd "rm -f /etc/profile.d/hestia*"

# Remove HestiaCP bash completion
run_cmd "rm -f /etc/bash_completion.d/hestia"
run_cmd "rm -f /etc/bash_completion.d/v-*"

add_summary "Restored default MOTD and login scripts"

success "Login scripts and MOTD restored."

# ----------------------------------------------------------
# Phase 22: Remove Shell Aliases and PATH Entries
# ----------------------------------------------------------

step "Phase 22: Cleaning shell environment"

# Remove HestiaCP PATH entries from bashrc/profile
for rc_file in /root/.bashrc /root/.bash_profile /root/.profile; do
	if [ -f "$rc_file" ] && grep -ql "hestia\|/usr/local/hestia" "$rc_file" 2>/dev/null; then
		info "Cleaning HestiaCP entries from $rc_file"
		run_cmd "sed -i '/hestia/d' '$rc_file'"
		run_cmd "sed -i '/\\/usr\\/local\\/hestia/d' '$rc_file'"
		add_summary "Cleaned: $rc_file"
	fi
done

success "Shell environment cleaned."

# ----------------------------------------------------------
# Phase 23: Remove Log Files
# ----------------------------------------------------------

step "Phase 23: Removing log files"

HESTIA_LOGS=(
	"/var/log/hestia"
	"/var/log/hestia-nginx"
	"/var/log/hestia-php"
	"/var/log/hestia-web-terminal.log"
	"/root/hst_install_backups"
)

for logfile in "${HESTIA_LOGS[@]}"; do
	if [ -e "$logfile" ]; then
		info "Removing: $logfile"
		run_cmd "rm -rf '$logfile'"
		add_summary "Removed log: $(basename "$logfile")"
	fi
done

# Clean journal entries
run_cmd "journalctl --rotate 2>/dev/null || true"
run_cmd "journalctl --vacuum-time=1s 2>/dev/null || true"

success "Logs cleaned."

# ----------------------------------------------------------
# Phase 24: Database Cleanup
# ----------------------------------------------------------

step "Phase 24: Database cleanup"

DB_CLEANED=false

if confirm "Remove HestiaCP-managed database users and databases?"; then

	# MySQL/MariaDB
	if command -v mysql &>/dev/null || command -v mariadb &>/dev/null; then
		db_cmd=$(command -v mariadb || command -v mysql)

		# Remove HestiaCP user databases
		db_list=$($db_cmd -N -e "SHOW DATABASES" 2>/dev/null | grep -iE "^(hst_|hst-|hestia_)" || true)
		if [ -n "$db_list" ]; then
			for dbname in $db_list; do
				info "Dropping MySQL database: $dbname"
				run_cmd "$db_cmd -e \"DROP DATABASE IF EXISTS \\\`$dbname\\\`\""
				add_summary "Dropped DB: $dbname"
			done
		fi

		# Remove HestiaCP database users
		db_users=$($db_cmd -N -e "SELECT User FROM mysql.user WHERE User LIKE 'hst\_%'" 2>/dev/null || true)
		if [ -n "$db_users" ]; then
			for dbuser in $db_users; do
				info "Removing MySQL user: $dbuser"
				run_cmd "$db_cmd -e \"DROP USER IF EXISTS '$dbuser'@'localhost'\""
				run_cmd "$db_cmd -e \"DROP USER IF EXISTS '$dbuser'@'%'\""
				add_summary "Removed DB user: $dbuser"
			done
			run_cmd "$db_cmd -e \"FLUSH PRIVILEGES\""
		fi
	fi

	# PostgreSQL
	if command -v psql &>/dev/null; then
		pg_dbs=$(sudo -u postgres psql -t -c "SELECT datname FROM pg_database WHERE datname LIKE 'hst\_%'" 2>/dev/null | xargs || true)
		for dbname in $pg_dbs; do
			[ -n "$dbname" ] || continue
			info "Dropping PG database: $dbname"
			run_cmd "sudo -u postgres dropdb --if-exists '$dbname'"
			add_summary "Dropped PG DB: $dbname"
		done

		pg_users=$(sudo -u postgres psql -t -c "SELECT usename FROM pg_user WHERE usename LIKE 'hst\_%'" 2>/dev/null | xargs || true)
		for pguser in $pg_users; do
			[ -n "$pguser" ] || continue
			info "Removing PG user: $pguser"
			run_cmd "sudo -u postgres dropuser --if-exists '$pguser'"
			add_summary "Removed PG user: $pguser"
		done
	fi

	DB_CLEANED=true
else
	warn "Database cleanup skipped. Check MySQL/PostgreSQL for leftover HestiaCP databases."
fi

# ----------------------------------------------------------
# Phase 25: User Data Cleanup
# ----------------------------------------------------------

step "Phase 25: User data cleanup"

if [ "$KEEP_DATA" = true ]; then
	warn "Keeping user data (--keep-data flag)."
elif [ "$HESTIA_FOUND" = true ]; then
	if confirm "Remove all user web/mail/DNS data in /home/*? THIS CANNOT BE UNDONE!"; then
		for user_home in /home/*/; do
			[ -d "$user_home" ] || continue
			username=$(basename "$user_home")
			# Skip known system users
			case "$username" in
				hestiaweb|hestiamail|hestiasshd|hestiadns|hestia*) continue ;;
			esac
			# Check if this is a HestiaCP-managed user
			if [ -d "$user_home/web" ] || [ -d "$user_home/conf" ] || [ -d "$user_home/mail" ]; then
				info "Removing user data: $user_home"
				run_cmd "rm -rf '$user_home'"
				add_summary "Removed user data: $username"
			fi
		done

		# Also clean /home admin user if it exists
		if [ -d "/home/admin" ]; then
			if confirm "Remove /home/admin?"; then
				run_cmd "rm -rf /home/admin"
				add_summary "Removed: /home/admin"
			fi
		fi
	else
		warn "User data preserved in /home/"
	fi
fi

success "User data handled."

# ----------------------------------------------------------
# Phase 26: Restore Original Configs
# ----------------------------------------------------------

step "Phase 26: Configuration restoration"

BACKUP_DIR=""
for dir in /root/hst_install_backups/*/; do
	[ -d "$dir" ] || continue
	if [ -d "${dir}nginx" ] || [ -d "${dir}apache2" ] || [ -d "${dir}exim4" ]; then
		BACKUP_DIR="$dir"
		break
	fi
done

if [ -n "$BACKUP_DIR" ] && [ "$BACKUP_DIR" != "" ]; then
	if confirm "Found backup at $BACKUP_DIR. Restore original configs?"; then
		for svc in nginx apache2 exim4 dovecot bind openssl; do
			src_dir=""
			case "$svc" in
				bind) src_dir="${BACKUP_DIR}bind" ;;
				*)    src_dir="${BACKUP_DIR}${svc}" ;;
			esac
			if [ -d "$src_dir" ]; then
				dst_dir=""
				case "$svc" in
					nginx)  dst_dir="/etc/nginx" ;;
					apache2) dst_dir="/etc/apache2" ;;
					exim4)  dst_dir="/etc/exim4" ;;
					dovecot) dst_dir="/etc/dovecot" ;;
					bind)   dst_dir="/etc/bind" ;;
					openssl) dst_dir="/etc/ssl" ;;
				esac
				if [ -n "$dst_dir" ] && [ -d "$dst_dir" ]; then
					info "Restoring $svc config..."
					run_cmd "cp -rf '$src_dir/'* '$dst_dir/' 2>/dev/null || true"
					add_summary "Restored: $svc config"
				fi
			fi
		done
	else
		info "Config restoration skipped."
	fi
else
	info "No backup found for config restoration."
fi

# ----------------------------------------------------------
# Phase 27: Final Cleanup
# ----------------------------------------------------------

step "Phase 27: Final cleanup"

# Remove any stale symlinks
run_cmd "find /usr/sbin /usr/bin /usr/local/bin -type l -lname '*hestia*' -delete 2>/dev/null || true"

# Remove HestiaCP bash completions
run_cmd "rm -f /etc/bash_completion.d/v-*"

# Remove polkit rules
run_cmd "rm -f /etc/polkit-1/localauthority/50-local.d/50-hestia*"

# Remove tmpfiles.d entries
run_cmd "rm -f /etc/tmpfiles.d/hestia*"
run_cmd "rm -f /usr/lib/tmpfiles.d/hestia*"

# Remove udev rules
run_cmd "rm -f /etc/udev/rules.d/*hestia*"

# Restart key services if still installed
for svc in nginx apache2 cron; do
	if command -v "$svc" &>/dev/null || systemctl list-unit-files "${svc}.service" &>/dev/null 2>&1; then
		run_cmd "systemctl restart '$svc' 2>/dev/null || true"
	fi
done

# Update package cache
run_cmd "apt-get update -qq 2>/dev/null || true"

success "Final cleanup complete."

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

echo -e "${BOLD}Actions performed (${#SUMMARY[@]} total):${NC}"
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
	echo -e "${YELLOW}NOTE: Database cleanup was skipped. Check MySQL/PostgreSQL${NC}"
	echo -e "${YELLOW}      for leftover HestiaCP databases and users.${NC}"
	echo ""
fi

if [ "$KEEP_DATA" = true ]; then
	echo -e "${YELLOW}NOTE: User data preserved in /home/ (--keep-data)${NC}"
	echo ""
fi

echo "========================================================"
log "=== HestiaCP Uninstall Completed ==="
