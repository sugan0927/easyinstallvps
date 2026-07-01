#!/bin/bash

# ============================================
# EasyInstall WordPress Maximum Performance Installation Script v6.4
# HYBRID EDITION: Bash = Dependencies | Python = Configuration
# Ultra-Optimized WordPress Setup with Advanced Auto-Tuning (10 Phases)
# RAM Auto-Detection: 512MB to 16GB
# Compatible with Debian 12 and Ubuntu 24.04/22.04
#
# ARCHITECTURE:
#   easyinstall.sh         — Bash: all apt installs, system deps, repo setup,
#                            service start/enable, lock/logging, entry point
#   easyinstall_config.py  — Python: all server config file generation,
#                            WordPress setup, Nginx/PHP/MySQL/Redis config,
#                            autotune, firewall rules, monitoring scripts
# ============================================

set -eE
trap 'error_handler ${LINENO} "$BASH_COMMAND" $?' ERR

# ── Color Codes ─────────────────────────────────────────────────────────────
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m'

# ── Global Variables ─────────────────────────────────────────────────────────
SCRIPT_VERSION="6.4"
LOCK_FILE="/var/run/easyinstall.lock"
LOG_FILE="/var/log/easyinstall/install.log"
ERROR_LOG="/var/log/easyinstall/error.log"
STATUS_FILE="/var/lib/easyinstall/install.status"
BACKUP_DIR="/root/easyinstall-backups/$(date +%Y%m%d-%H%M%S)"
USED_REDIS_PORTS_FILE="/var/lib/easyinstall/used_redis_ports.txt"
INSTALL_START_TIME=$(date +%s)
PYTHON_CONFIG_SCRIPT="/usr/local/lib/easyinstall_config.py"

# ============================================
# SECTION 1 — LOGGING  (pure bash, no deps)
# ============================================
log() {
    local level=$1
    local message=$2
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    mkdir -p /var/log/easyinstall /var/lib/easyinstall 2>/dev/null || true
    echo "[$timestamp] [$level] $message" >> "$LOG_FILE"
    case $level in
        "ERROR")   echo -e "${RED}❌ $message${NC}" ;;
        "WARNING") echo -e "${YELLOW}⚠️  $message${NC}" ;;
        "SUCCESS") echo -e "${GREEN}✅ $message${NC}" ;;
        "INFO")    echo -e "${BLUE}ℹ️  $message${NC}" ;;
        "STEP")    echo -e "${PURPLE}🔷 $message${NC}" ;;
        *)         echo -e "$message" ;;
    esac
}

log_error() {
    local line=$1 command=$2 exit_code=$3
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    mkdir -p /var/log/easyinstall 2>/dev/null || true
    echo "[$timestamp] [ERROR] Failed at line $line: $command (exit: $exit_code)" >> "$ERROR_LOG"
    local i=0
    while caller $i >> "$ERROR_LOG" 2>/dev/null; do ((i++)); done
    log "ERROR" "Installation failed at line $line"
    log "INFO"  "Check error log: $ERROR_LOG"
}

error_handler() {
    local line=$1 command=$2 exit_code=$3
    log_error "$line" "$command" "$exit_code"
    if [ -d "$BACKUP_DIR" ] && [ "$(ls -A $BACKUP_DIR 2>/dev/null)" ]; then
        log "WARNING" "Attempting to rollback configuration changes..."
        perform_rollback
    fi
    exit $exit_code
}

update_status() {
    local step=$1 status=$2
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "$timestamp: $step - $status" >> "$STATUS_FILE"
}

# ============================================
# SECTION 2 — SAFE COMMAND EXECUTION
# ============================================
run_cmd() {
    local cmd="$@"
    log "INFO" "Running: $cmd"
    if eval "$cmd"; then
        log "SUCCESS" "Completed: ${cmd:0:60}..."
        return 0
    else
        local exit_code=$?
        log "ERROR" "Failed (code $exit_code): $cmd"
        return $exit_code
    fi
}

run_cmd_retry() {
    local max_attempts=$1 delay=$2
    local command="${@:3}"
    local attempt=1
    while [ $attempt -le $max_attempts ]; do
        log "INFO" "Attempt $attempt/$max_attempts: ${command:0:60}..."
        if eval "$command"; then
            log "SUCCESS" "Succeeded on attempt $attempt"
            return 0
        fi
        if [ $attempt -lt $max_attempts ]; then
            log "WARNING" "Attempt $attempt failed. Retrying in ${delay}s..."
            sleep $delay
            delay=$((delay * 2))
        fi
        attempt=$((attempt + 1))
    done
    log "ERROR" "Failed after $max_attempts attempts: $command"
    return 1
}

# reload_or_restart_service <service> [syntax_check_cmd]
# Reloads a service; if the reload fails, falls back to a full restart and
# logs a warning. If a syntax_check_cmd is supplied it's run first — on
# failure the reload/restart is skipped entirely so a known-bad config never
# gets pushed onto a running service (the previous config stays active).
reload_or_restart_service() {
    local service="$1" syntax_check_cmd="${2:-}"

    if [ -n "$syntax_check_cmd" ]; then
        if ! eval "$syntax_check_cmd" >/dev/null 2>&1; then
            log "ERROR" "$service: config syntax check failed ('$syntax_check_cmd') — skipping reload/restart"
            return 1
        fi
    fi

    if systemctl reload "$service" 2>/dev/null; then
        return 0
    fi

    log "WARNING" "$service: 'systemctl reload' failed — falling back to 'systemctl restart'"
    if systemctl restart "$service" 2>/dev/null; then
        log "SUCCESS" "$service: restarted successfully after reload failure"
        return 0
    fi

    log "ERROR" "$service: both reload and restart failed — service may be down, check manually"
    return 1
}

# ============================================
# SECTION 3 — LOCK FILE MANAGEMENT
# ============================================
check_lock() {
    log "STEP" "Checking for existing installation..."
    if [ -f "$LOCK_FILE" ]; then
        local pid=$(cat "$LOCK_FILE" 2>/dev/null)
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            log "ERROR" "Another installation already running (PID: $pid)"
            exit 1
        else
            log "WARNING" "Removing stale lock file"
            rm -f "$LOCK_FILE"
        fi
    fi
    echo $$ > "$LOCK_FILE"
    log "SUCCESS" "Lock acquired"
    trap 'rm -f "$LOCK_FILE"; log "INFO" "Lock released"' EXIT
}

# ============================================
# SECTION 4 — CONFIGURATION BACKUP & ROLLBACK
# ============================================
backup_config() {
    local files=("$@")
    log "STEP" "Creating configuration backup"
    mkdir -p "$BACKUP_DIR"
    for file in "${files[@]}"; do
        if [ -f "$file" ]; then
            local dest_dir="$BACKUP_DIR$(dirname "$file")"
            mkdir -p "$dest_dir"
            cp -p "$file" "$dest_dir/"
            log "SUCCESS" "Backed up: $file"
        fi
    done
    cat > "$BACKUP_DIR/MANIFEST.txt" <<EOF
EasyInstall Backup
Date: $(date)
Version: $SCRIPT_VERSION
Files:
$(for f in "${files[@]}"; do echo "  - $f"; done)
EOF
    log "SUCCESS" "Backup created at: $BACKUP_DIR"
}

perform_rollback() {
    log "STEP" "Performing configuration rollback"
    [ -d "$BACKUP_DIR" ] || { log "ERROR" "No backup directory found"; return 1; }
    find "$BACKUP_DIR" -type f -not -name "MANIFEST.txt" | while read -r backup_file; do
        local original_file="${backup_file#$BACKUP_DIR}"
        mkdir -p "$(dirname "$original_file")"
        cp -p "$backup_file" "$original_file"
        log "SUCCESS" "Restored: $original_file"
    done
    log "SUCCESS" "Rollback completed"
    for service in nginx php8.3-fpm php8.2-fpm mariadb redis-server; do
        systemctl restart "$service" 2>/dev/null || true
    done
}

# ============================================
# SECTION 5 — SYSTEM VALIDATION (BASH)
# ============================================
check_root() {
    log "STEP" "Checking root privileges"
    [ "$EUID" -ne 0 ] && { log "ERROR" "Please run as root"; exit 1; }
    log "SUCCESS" "Running as root"
}

check_network() {
    log "STEP" "Checking network connectivity"
    if ! host -W 5 google.com >/dev/null 2>&1; then
        log "WARNING" "DNS resolution failed, trying alternative"
        nslookup google.com 8.8.8.8 >/dev/null 2>&1 || { log "ERROR" "Network connectivity issue"; return 1; }
    fi
    if ! ping -c 1 -W 5 8.8.8.8 >/dev/null 2>&1; then
        log "WARNING" "Ping failed, checking HTTP"
        curl -s --head https://google.com | head -n 1 | grep -q "200" || { log "ERROR" "No internet connectivity"; return 1; }
    fi
    log "SUCCESS" "Network connectivity OK"
    return 0
}

check_disk_space() {
    local required_mb=${1:-5120}
    log "STEP" "Checking disk space (required: ${required_mb}MB)"
    local available_mb=$(df -m / | awk 'NR==2 {print $4}')
    if [ "$available_mb" -lt "$required_mb" ]; then
        log "ERROR" "Insufficient disk space. Need ${required_mb}MB, have ${available_mb}MB"
        df -h / >> "$LOG_FILE"
        return 1
    fi
    log "SUCCESS" "Disk space OK: ${available_mb}MB available"
    return 0
}

check_memory() {
    log "STEP" "Checking available memory"
    local total_mem=$(free -m | awk '/Mem:/ {print $2}')
    local available_mem=$(free -m | awk '/Mem:/ {print $7}')
    log "INFO" "Total RAM: ${total_mem}MB, Available: ${available_mem}MB"
    [ "$total_mem" -lt 512 ] && log "WARNING" "Low memory system (${total_mem}MB). Performance may be limited."
    return 0
}

check_os_compatibility() {
    log "STEP" "Checking OS compatibility"
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS_ID=$ID; OS_NAME=$NAME; OS_VERSION=$VERSION_ID
    fi
    [[ ! "$OS_ID" =~ ^(debian|ubuntu)$ ]] && { log "ERROR" "Unsupported OS: $OS_NAME"; return 1; }
    if [ "$OS_ID" = "debian" ] && [ "${OS_VERSION%%.*}" -lt 11 ]; then
        log "ERROR" "Debian 11+ required (detected: $OS_VERSION)"; return 1
    fi
    if [ "$OS_ID" = "ubuntu" ] && [[ ! "$OS_VERSION" =~ ^(20.04|22.04|24.04)$ ]]; then
        log "ERROR" "Ubuntu 20.04/22.04/24.04 required (detected: $OS_VERSION)"; return 1
    fi
    log "SUCCESS" "OS compatible: $OS_NAME $OS_VERSION"
    return 0
}

# ============================================
# SECTION 6 — SERVICE HEALTH CHECKS (BASH)
# ============================================
wait_for_service() {
    local service=$1 max_attempts=${2:-30} attempt=1
    log "INFO" "Waiting for $service to start..."
    while [ $attempt -le $max_attempts ]; do
        systemctl is-active --quiet "$service" 2>/dev/null && {
            log "SUCCESS" "$service is running"; return 0; }
        [ $((attempt % 5)) -eq 0 ] && log "INFO" "Still waiting for $service... ($attempt/$max_attempts)"
        sleep 2; attempt=$((attempt + 1))
    done
    log "ERROR" "$service failed to start within timeout"
    journalctl -u "$service" --no-pager -n 50 >> "$ERROR_LOG" 2>/dev/null || true
    systemctl status "$service" --no-pager >> "$ERROR_LOG" 2>/dev/null || true
    return 1
}

test_mysql_connection() {
    local attempt=1
    log "INFO" "Testing MySQL connection..."
    while [ $attempt -le 10 ]; do
        mysql -e "SELECT 1" 2>/dev/null && { log "SUCCESS" "MySQL connection OK"; return 0; }
        sleep 3; attempt=$((attempt + 1))
    done
    log "ERROR" "Cannot connect to MySQL"; return 1
}

test_redis() {
    local port=${1:-6379}
    redis-cli -p "$port" ping 2>/dev/null | grep -q "PONG" && {
        log "SUCCESS" "Redis on port $port is healthy"; return 0; }
    log "WARNING" "Redis on port $port not responding"; return 1
}

validate_nginx_config() {
    nginx -t 2>/dev/null && { log "SUCCESS" "Nginx configuration valid"; return 0; }
    log "ERROR" "Nginx configuration invalid"
    nginx -t 2>&1 | head -20 >> "$ERROR_LOG"
    return 1
}

# ============================================
# SECTION 7 — RAM AUTO-DETECT & TUNE (BASH)
# Exported as env vars consumed by Python config
# ============================================
detect_ram_and_tune() {
    log "STEP" "Auto-tuning based on RAM"
    TOTAL_RAM=$(free -m | awk '/Mem:/ {print $2}')
    TOTAL_CORES=$(nproc)

    # ── Defensive fallback ──────────────────────────────────────────────────
    # `free`/`nproc` can occasionally return empty or non-numeric output
    # (containers with restricted /proc, exotic init systems, etc). Under
    # `set -eE` a numeric comparison against an empty/non-numeric value would
    # abort the whole install via the ERR trap, so validate and fall back to
    # a conservative 1GB/2-core tier rather than crashing.
    if ! [[ "$TOTAL_RAM" =~ ^[0-9]+$ ]] || [ "$TOTAL_RAM" -le 0 ]; then
        log "WARNING" "Could not reliably detect total RAM (got: '${TOTAL_RAM}') — defaulting to 1024MB tier"
        TOTAL_RAM=1024
    fi
    if ! [[ "$TOTAL_CORES" =~ ^[0-9]+$ ]] || [ "$TOTAL_CORES" -le 0 ]; then
        log "WARNING" "Could not reliably detect CPU core count (got: '${TOTAL_CORES}') — defaulting to 2 cores"
        TOTAL_CORES=2
    fi

    log "INFO" "Detected ${TOTAL_RAM}MB RAM with ${TOTAL_CORES} cores"

    if   [ "$TOTAL_RAM" -le 512 ];  then
        PHP_MAX_CHILDREN=5;  PHP_START_SERVERS=2;  PHP_MIN_SPARE=1;  PHP_MAX_SPARE=3
        PHP_MEMORY_LIMIT="128M"; PHP_MAX_EXECUTION=60
        MYSQL_BUFFER_POOL="64M"; MYSQL_LOG_FILE="64M"
        REDIS_MAX_MEMORY="64mb"; NGINX_WORKER_CONNECTIONS=512
    elif [ "$TOTAL_RAM" -le 1024 ]; then
        PHP_MAX_CHILDREN=10; PHP_START_SERVERS=3;  PHP_MIN_SPARE=2;  PHP_MAX_SPARE=5
        PHP_MEMORY_LIMIT="128M"; PHP_MAX_EXECUTION=120
        MYSQL_BUFFER_POOL="128M"; MYSQL_LOG_FILE="64M"
        REDIS_MAX_MEMORY="128mb"; NGINX_WORKER_CONNECTIONS=1024
    elif [ "$TOTAL_RAM" -le 2048 ]; then
        PHP_MAX_CHILDREN=20; PHP_START_SERVERS=5;  PHP_MIN_SPARE=3;  PHP_MAX_SPARE=8
        PHP_MEMORY_LIMIT="256M"; PHP_MAX_EXECUTION=180
        MYSQL_BUFFER_POOL="256M"; MYSQL_LOG_FILE="128M"
        REDIS_MAX_MEMORY="256mb"; NGINX_WORKER_CONNECTIONS=2048
    elif [ "$TOTAL_RAM" -le 4096 ]; then
        PHP_MAX_CHILDREN=40; PHP_START_SERVERS=8;  PHP_MIN_SPARE=4;  PHP_MAX_SPARE=12
        PHP_MEMORY_LIMIT="512M"; PHP_MAX_EXECUTION=240
        MYSQL_BUFFER_POOL="512M"; MYSQL_LOG_FILE="256M"
        REDIS_MAX_MEMORY="512mb"; NGINX_WORKER_CONNECTIONS=4096
    elif [ "$TOTAL_RAM" -le 8192 ]; then
        PHP_MAX_CHILDREN=80; PHP_START_SERVERS=12; PHP_MIN_SPARE=6;  PHP_MAX_SPARE=18
        PHP_MEMORY_LIMIT="512M"; PHP_MAX_EXECUTION=300
        MYSQL_BUFFER_POOL="1G"; MYSQL_LOG_FILE="512M"
        REDIS_MAX_MEMORY="1gb"; NGINX_WORKER_CONNECTIONS=8192
    elif [ "$TOTAL_RAM" -le 16384 ]; then
        PHP_MAX_CHILDREN=160; PHP_START_SERVERS=20; PHP_MIN_SPARE=10; PHP_MAX_SPARE=30
        PHP_MEMORY_LIMIT="1G"; PHP_MAX_EXECUTION=360
        MYSQL_BUFFER_POOL="2G"; MYSQL_LOG_FILE="1G"
        REDIS_MAX_MEMORY="2gb"; NGINX_WORKER_CONNECTIONS=16384
    else
        # Final catch-all: anything above our highest named tier (>16GB) OR
        # any value that somehow slipped past the validation above. Conservative
        # defaults here are intentionally generous-but-safe rather than unbounded,
        # so a misdetected/huge value can't blow out memory-sized configs.
        log "WARNING" "RAM (${TOTAL_RAM}MB) exceeds the highest defined tier — using capped high-end defaults"
        PHP_MAX_CHILDREN=200; PHP_START_SERVERS=24; PHP_MIN_SPARE=12; PHP_MAX_SPARE=36
        PHP_MEMORY_LIMIT="1G"; PHP_MAX_EXECUTION=360
        MYSQL_BUFFER_POOL="4G"; MYSQL_LOG_FILE="1G"
        REDIS_MAX_MEMORY="4gb"; NGINX_WORKER_CONNECTIONS=16384
    fi

    NGINX_WORKER_PROCESSES=$TOTAL_CORES

    # Export so Python config script can read them via env
    export TOTAL_RAM TOTAL_CORES
    export PHP_MAX_CHILDREN PHP_START_SERVERS PHP_MIN_SPARE PHP_MAX_SPARE
    export PHP_MEMORY_LIMIT PHP_MAX_EXECUTION
    export MYSQL_BUFFER_POOL MYSQL_LOG_FILE
    export REDIS_MAX_MEMORY NGINX_WORKER_CONNECTIONS NGINX_WORKER_PROCESSES

    log "SUCCESS" "Auto-tuning complete — PHP children: $PHP_MAX_CHILDREN | MySQL: $MYSQL_BUFFER_POOL | Redis: $REDIS_MAX_MEMORY"
}

# ============================================
# SECTION 8 — OS DETECTION (BASH)
# ============================================
detect_os() {
    log "STEP" "Detecting operating system"
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS_ID=$ID; OS_NAME=$NAME; OS_VERSION=$VERSION_ID; OS_CODENAME=$VERSION_CODENAME
    fi
    if [ "$OS_ID" = "debian" ] && [ -f /etc/debian_version ]; then
        DEBIAN_VERSION=$(cut -d. -f1 /etc/debian_version)
        case $DEBIAN_VERSION in
            10) OS_CODENAME="buster"   ;;
            11) OS_CODENAME="bullseye" ;;
            12) OS_CODENAME="bookworm" ;;
            *)  OS_CODENAME="bullseye" ;;
        esac
    fi
    if [ "$OS_ID" = "ubuntu" ] && [ -f /etc/lsb-release ]; then
        . /etc/lsb-release; OS_CODENAME=$DISTRIB_CODENAME
    fi
    [ -z "$OS_CODENAME" ] && OS_CODENAME=$(lsb_release -sc 2>/dev/null || echo "focal")
    export OS_ID OS_NAME OS_VERSION OS_CODENAME
    log "SUCCESS" "Detected: $OS_NAME $OS_VERSION ($OS_CODENAME)"
}

# ============================================
# SECTION 9 — PACKAGE MANAGER & BASE DEPS (BASH)
# ============================================
setup_package_manager() {
    log "STEP" "Setting up package manager and base dependencies"

    run_cmd_retry 3 5 "apt-get update -y"
    run_cmd_retry 2 3 "apt --fix-broken install -y"

    local packages=(
        apt-transport-https ca-certificates curl wget gnupg lsb-release
        software-properties-common ufw fail2ban htop git unzip zip tar
        jq net-tools dnsutils cron rsync nano vim openssl apache2-utils
        systemd dbus python3 python3-pip python3-venv ncdu
    )
    for pkg in "${packages[@]}"; do
        run_cmd_retry 2 3 "apt-get install -y $pkg" || log "WARNING" "Could not install: $pkg"
    done

    if [ "$OS_ID" = "ubuntu" ]; then
        run_cmd_retry 2 3 "apt-get install -y mysql-client-8.0" || \
        run_cmd_retry 2 3 "apt-get install -y mysql-client" || true
    else
        run_cmd_retry 2 3 "apt-get install -y mariadb-client" || \
        run_cmd_retry 2 3 "apt-get install -y mysql-client" || true
    fi
    log "SUCCESS" "Base package setup complete"
}

# ============================================
# SECTION 10 — SWAP SETUP (BASH — filesystem op)
# ============================================
setup_swap() {
    log "STEP" "Configuring swap space"
    if [ ! -f /swapfile ]; then
        if   [ "$TOTAL_RAM" -le 512  ]; then SWAPSIZE=1G
        elif [ "$TOTAL_RAM" -le 1024 ]; then SWAPSIZE=2G
        elif [ "$TOTAL_RAM" -le 2048 ]; then SWAPSIZE=3G
        else SWAPSIZE=4G; fi
        log "INFO" "Creating ${SWAPSIZE} swap file"
        fallocate -l $SWAPSIZE /swapfile 2>/dev/null || \
            dd if=/dev/zero of=/swapfile bs=1M count=4096 status=progress
        chmod 600 /swapfile
        if mkswap /swapfile && swapon /swapfile; then
            echo '/swapfile none swap sw 0 0' >> /etc/fstab
            echo "vm.swappiness=10" >> /etc/sysctl.conf
            sysctl -p >/dev/null 2>&1 || true
            log "SUCCESS" "Swap created: $SWAPSIZE"
        else
            log "ERROR" "Failed to create swap"; rm -f /swapfile
        fi
    else
        log "INFO" "Swap file already exists"
    fi
}

# ============================================
# SECTION 11 — INSTALL NGINX (BASH: repo + pkg)
# ============================================
install_nginx_packages() {
    log "STEP" "Installing Nginx from official repository"
    run_cmd_retry 2 3 "apt-get remove -y nginx nginx-common nginx-full nginx-core" 2>/dev/null || true
    run_cmd_retry 3 5 "curl -fsSL https://nginx.org/keys/nginx_signing.key | gpg --dearmor -o /usr/share/keyrings/nginx-archive-keyring.gpg"
    if [ "$OS_ID" = "ubuntu" ]; then
        echo "deb [signed-by=/usr/share/keyrings/nginx-archive-keyring.gpg] http://nginx.org/packages/mainline/ubuntu ${OS_CODENAME} nginx" | \
            tee /etc/apt/sources.list.d/nginx.list
    else
        echo "deb [signed-by=/usr/share/keyrings/nginx-archive-keyring.gpg] http://nginx.org/packages/mainline/debian ${OS_CODENAME} nginx" | \
            tee /etc/apt/sources.list.d/nginx.list
    fi
    run_cmd_retry 3 5 "apt-get update -y"
    run_cmd_retry 3 5 "apt-get install -y nginx"

    # Optional: Brotli module
    run_cmd_retry 2 3 "apt-get install -y libnginx-mod-brotli" 2>/dev/null || \
        log "WARNING" "Brotli module not available — gzip remains active"

    # Optional: GeoIP2 module
    run_cmd_retry 2 3 "apt-get install -y libnginx-mod-http-geoip2 mmdb-bin" 2>/dev/null || true

    mkdir -p /etc/nginx/{sites-available,sites-enabled,conf.d,ssl,snippets}
    mkdir -p /var/cache/nginx/{fastcgi,proxy,static,edge}
    mkdir -p /var/log/nginx
    # FIX: Use www-data (matches PHP-FPM socket owner and nginx worker user in config)
    chown -R www-data:www-data /var/cache/nginx 2>/dev/null || true
    chmod -R 755 /var/cache/nginx 2>/dev/null || true
    log "SUCCESS" "Nginx packages installed"
}

# ============================================
# SECTION 12 — INSTALL PHP (BASH: repo + pkgs)
# ============================================
install_php_packages() {
    log "STEP" "Installing PHP from Sury/Ondrej repository"
    if [ "$OS_ID" = "debian" ]; then
        run_cmd_retry 3 5 "apt-get install -y apt-transport-https lsb-release ca-certificates curl wget"
        run_cmd_retry 3 5 "wget -qO- https://packages.sury.org/php/apt.gpg | gpg --dearmor > /etc/apt/trusted.gpg.d/sury-php.gpg"
        echo "deb https://packages.sury.org/php/ ${OS_CODENAME} main" | tee /etc/apt/sources.list.d/sury-php.list
        run_cmd_retry 3 5 "apt-get update -y"
    else
        run_cmd_retry 3 5 "add-apt-repository -y ppa:ondrej/php"
        run_cmd_retry 3 5 "apt-get update -y"
    fi

    # Try PHP 8.4 → 8.3 → 8.2
    PHP_INSTALLED_VERSION=""
    for ver in 8.4 8.3 8.2; do
        local pkgs="php${ver}-fpm php${ver}-mysql php${ver}-curl php${ver}-gd php${ver}-mbstring"
        pkgs="$pkgs php${ver}-xml php${ver}-xmlrpc php${ver}-zip php${ver}-soap php${ver}-intl"
        pkgs="$pkgs php${ver}-bcmath php${ver}-imagick php${ver}-redis php${ver}-opcache"
        pkgs="$pkgs php${ver}-readline php${ver}-apcu php${ver}-memcached php${ver}-igbinary"
        if run_cmd_retry 3 5 "apt-get install -y $pkgs"; then
            PHP_INSTALLED_VERSION=$ver
            log "SUCCESS" "PHP $ver installed"
            # Always also try installing 8.3 and 8.2 as fallback versions
        else
            log "WARNING" "PHP $ver not available"
        fi
    done

    [ -z "$PHP_INSTALLED_VERSION" ] && { log "ERROR" "No PHP version could be installed"; return 1; }
    export PHP_INSTALLED_VERSION
    log "SUCCESS" "PHP installation complete (primary: $PHP_INSTALLED_VERSION)"
}

# ============================================
# SECTION 13 — INSTALL MARIADB (BASH: repo + pkg)
# ============================================
install_mysql_packages() {
    log "STEP" "Installing MariaDB 11.x"
    systemctl stop mysql 2>/dev/null || true
    systemctl stop mariadb 2>/dev/null || true

    log "INFO" "Adding MariaDB 11.x official repository"
    run_cmd_retry 3 5 "curl -fsSL https://downloads.mariadb.com/MariaDB/mariadb_repo_setup | bash -s -- --mariadb-server-version=mariadb-11.4 --skip-maxscale" 2>/dev/null || \
        log "WARNING" "MariaDB 11.x repo failed, falling back to distro default"

    run_cmd_retry 3 5 "apt-get update -y"
    run_cmd_retry 2 3 "apt --fix-broken install -y"
    run_cmd_retry 3 5 "apt-get install -y mariadb-server mariadb-client"
    sleep 5
    systemctl enable mariadb
    systemctl start mariadb
    log "SUCCESS" "MariaDB packages installed"
}

# ============================================
# SECTION 14 — INSTALL WP-CLI (BASH: download)
# ============================================
install_wp_cli() {
    log "STEP" "Installing WP-CLI"
    if run_cmd_retry 3 5 "curl -O https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar"; then
        chmod +x wp-cli.phar
        mv wp-cli.phar /usr/local/bin/wp
        run_cmd_retry 2 3 "curl -O https://raw.githubusercontent.com/wp-cli/wp-cli/v2.8.0/utils/wp-completion.bash"
        mv wp-completion.bash /etc/bash_completion.d/wp-completion.bash 2>/dev/null || true
        /usr/local/bin/wp --info &>/dev/null && log "SUCCESS" "WP-CLI installed" || \
            log "ERROR" "WP-CLI verification failed"
    else
        log "ERROR" "Failed to download WP-CLI"
    fi

    # Weekly self-update cron
    cat > /etc/cron.weekly/easyinstall-wpcli-update <<'WPCLIUPDATE'
#!/bin/bash
/usr/local/bin/wp cli update --yes --allow-root 2>/dev/null && \
    echo "[$(date)] WP-CLI updated" >> /var/log/easyinstall/install.log || true
WPCLIUPDATE
    chmod +x /etc/cron.weekly/easyinstall-wpcli-update
    log "SUCCESS" "WP-CLI weekly auto-update cron installed"
}

# ============================================
# SECTION 15 — INSTALL REDIS (BASH: repo + pkg)
# ============================================
install_redis_packages() {
    log "STEP" "Installing Redis 7.x"

    run_cmd_retry 3 5 "curl -fsSL https://packages.redis.io/gpg | gpg --dearmor -o /usr/share/keyrings/redis-archive-keyring.gpg" 2>/dev/null || true
    echo "deb [signed-by=/usr/share/keyrings/redis-archive-keyring.gpg] https://packages.redis.io/deb ${OS_CODENAME} main" | \
        tee /etc/apt/sources.list.d/redis.list 2>/dev/null || true
    run_cmd_retry 2 3 "apt-get update -y" 2>/dev/null || true
    run_cmd_retry 3 5 "apt-get install -y redis-server redis-tools"
    log "SUCCESS" "Redis packages installed"
}

# ============================================
# SECTION 16 — INSTALL CERTBOT (BASH)
# ============================================
install_certbot() {
    log "STEP" "Installing Certbot for SSL"
    run_cmd_retry 3 5 "apt-get install -y certbot python3-certbot-nginx"
    command -v certbot &>/dev/null && log "SUCCESS" "Certbot installed" || \
        log "ERROR" "Certbot installation failed"
}

# ============================================
# SECTION 17 — GET/MARK REDIS PORTS (BASH)
# ============================================
get_next_redis_port() {
    mkdir -p /var/lib/easyinstall
    touch "$USED_REDIS_PORTS_FILE"
    local port=6379 attempt=1
    while [ $attempt -le 100 ]; do
        if ! grep -q "^$port$" "$USED_REDIS_PORTS_FILE" 2>/dev/null; then
            if ! ss -tlnp 2>/dev/null | grep -q ":$port "; then
                echo "$port"; return 0
            fi
        fi
        port=$((port + 1)); attempt=$((attempt + 1))
    done
    log "ERROR" "Could not find available Redis port"; echo "6379"; return 1
}

mark_redis_port_used() {
    local port=$1
    mkdir -p /var/lib/easyinstall
    echo "$port" >> "$USED_REDIS_PORTS_FILE"
    sort -u "$USED_REDIS_PORTS_FILE" -o "$USED_REDIS_PORTS_FILE"
    log "INFO" "Redis port $port marked as used"
}

# ============================================
# SECTION 18 — START/ENABLE SERVICES (BASH)
# ============================================
enable_start_nginx() {
    # FIX: Remove default nginx site before starting to avoid port 80 conflict
    rm -f /etc/nginx/sites-enabled/default 2>/dev/null || true
    systemctl enable nginx
    systemctl start nginx
    wait_for_service "nginx" 30 || return 1
}

enable_start_php() {
    for version in 8.4 8.3 8.2; do
        if [ -d "/etc/php/$version" ]; then
            systemctl enable php$version-fpm 2>/dev/null || true
            systemctl start php$version-fpm 2>/dev/null || true
            wait_for_service "php$version-fpm" 20 || log "WARNING" "PHP $version-FPM may not be fully running"
        fi
    done
}

enable_start_redis() {
    systemctl enable redis-server
    systemctl start redis-server
    wait_for_service "redis-server" 20 && test_redis 6379
    mkdir -p /var/lib/easyinstall
    echo "6379" > "$USED_REDIS_PORTS_FILE"
}

enable_start_mariadb() {
    systemctl enable mariadb
    systemctl start mariadb
    wait_for_service "mariadb" 30 || return 1
    test_mysql_connection || return 1
}

# ============================================
# SECTION 19 — CLEANUP
# ============================================
cleanup_temp_files() {
    log "STEP" "Cleaning up temporary files"
    find /tmp -name "wordpress*.tar.gz" -type f -mmin +60 -delete 2>/dev/null || true
    [ "$1" = "success" ] && apt-get clean && log "INFO" "Package cache cleaned"
    find /var/log/easyinstall -name "*.log" -mtime +30 -delete 2>/dev/null || true
    log "SUCCESS" "Cleanup completed"
}

# ============================================
# SECTION 19b — DETECT ACTIVE PHP VERSION (BASH)
# Finds the highest PHP-FPM version that is running.
# Called by wordpress_install stage to pass correct version.
# ============================================
detect_active_php_version() {
    for ver in 8.4 8.3 8.2; do
        if systemctl is-active --quiet "php${ver}-fpm" 2>/dev/null; then
            echo "$ver"
            return 0
        fi
        # Also check if the socket exists even if service name differs
        if [ -S "/run/php/php${ver}-fpm.sock" ]; then
            echo "$ver"
            return 0
        fi
    done
    echo "8.3"   # safe default
}

# ============================================
# SECTION 19c — PHP SOCKET HEALTH FIX (BASH)
# ============================================
test_php_fpm() {
    local version=$1
    local sock="/run/php/php${version}-fpm.sock"
    if [ ! -S "$sock" ]; then
        log "WARNING" "PHP-FPM $version socket not found at $sock"
        return 1
    fi
    # Fix socket permissions so www-data + nginx can both read it
    chmod 666 "$sock" 2>/dev/null || true
    log "SUCCESS" "PHP-FPM $version socket OK: $sock"
    return 0
}

# ============================================
# SECTION 19d — CREATE PER-SITE REDIS INSTANCE (BASH)
# Bash handles: systemd unit creation, daemon-reload, enable/start.
# Config file is written by Python (wordpress_install stage).
# ============================================
create_site_redis_instance() {
    local domain=$1
    local redis_port=$2
    local domain_slug="${domain//./-}"

    log "INFO" "Starting dedicated Redis instance for $domain on port $redis_port"

    # Config file already written by Python stage; just start the service
    if [ ! -f "/etc/redis/redis-${domain_slug}.conf" ]; then
        log "WARNING" "Redis config for $domain not found — Python stage may not have run yet"
        return 1
    fi

    systemctl daemon-reload
    systemctl enable "redis-${domain_slug}" 2>/dev/null || true
    systemctl start  "redis-${domain_slug}" 2>/dev/null || true

    if wait_for_service "redis-${domain_slug}" 20; then
        mark_redis_port_used "$redis_port"
        log "SUCCESS" "Redis instance started for $domain (port $redis_port)"
        return 0
    else
        log "ERROR" "Redis instance failed to start for $domain"
        return 1
    fi
}

# ============================================
# SECTION 20 — INSTALL OLLAMA (BASH: curl install)
# ============================================
install_ollama() {
    log "STEP" "Installing Ollama for local AI"
    if command -v ollama &>/dev/null; then
        local ver=$(ollama --version 2>/dev/null || echo "installed")
        log "INFO" "Ollama already installed: $ver"
    else
        run_cmd_retry 3 5 "curl -fsSL https://ollama.com/install.sh | sh" || {
            log "ERROR" "Ollama installation failed"; return 1; }
        log "SUCCESS" "Ollama installed"
    fi
    systemctl enable ollama 2>/dev/null || true
    systemctl start ollama 2>/dev/null || true
    sleep 3
    if systemctl is-active --quiet ollama 2>/dev/null; then
        log "SUCCESS" "Ollama service running"
    else
        ollama serve >/dev/null 2>&1 &
        sleep 4
    fi
    # Pick model based on RAM
    local model="llama3"
    [ "${TOTAL_RAM:-0}" -ge 8192 ] && model="llama3.1"
    [ "${TOTAL_RAM:-0}" -lt 4096 ] && model="phi3"
    [ "${TOTAL_RAM:-0}" -lt 2048 ] && model="tinyllama"
    log "INFO" "Pulling Ollama model: $model"
    ollama pull "$model" 2>/dev/null || log "WARNING" "Model pull failed — will retry on first use"
    log "SUCCESS" "Ollama ready with model: $model"
}

# ============================================
# SECTION 21 — PYTHON BRIDGE
# Runs the Python config generator with all
# tuning values exported as environment vars.
# ============================================
run_python_config() {
    local stage="$1"
    shift
    log "STEP" "Running Python config generator: stage=$stage"
    # Extra args (e.g. --domain, --php-version) forwarded as-is after shift
    python3 "$PYTHON_CONFIG_SCRIPT" \
        --stage "$stage" \
        --total-ram "$TOTAL_RAM" \
        --total-cores "$TOTAL_CORES" \
        --php-max-children "$PHP_MAX_CHILDREN" \
        --php-start-servers "$PHP_START_SERVERS" \
        --php-min-spare "$PHP_MIN_SPARE" \
        --php-max-spare "$PHP_MAX_SPARE" \
        --php-memory-limit "$PHP_MEMORY_LIMIT" \
        --php-max-execution "$PHP_MAX_EXECUTION" \
        --mysql-buffer-pool "$MYSQL_BUFFER_POOL" \
        --mysql-log-file "$MYSQL_LOG_FILE" \
        --redis-max-memory "$REDIS_MAX_MEMORY" \
        --nginx-worker-connections "$NGINX_WORKER_CONNECTIONS" \
        --nginx-worker-processes "$NGINX_WORKER_PROCESSES" \
        --os-id "$OS_ID" \
        --os-codename "$OS_CODENAME" \
        "$@" && {
        log "SUCCESS" "Python config stage '$stage' complete"
    } || {
        log "ERROR" "Python config stage '$stage' failed"
        return 1
    }
}

# ============================================
# SECTION 22 — INSTALLATION TESTS
# ============================================
test_installation() {
    log "STEP" "Testing installation"
    local failed=0

    systemctl is-active --quiet nginx && {
        log "SUCCESS" "Nginx test passed"
        validate_nginx_config || failed=$((failed + 1))
    } || { log "ERROR" "Nginx test failed"; failed=$((failed + 1)); }

    systemctl is-active --quiet mariadb && {
        log "SUCCESS" "MariaDB test passed"
        test_mysql_connection || failed=$((failed + 1))
    } || { log "ERROR" "MariaDB test failed"; failed=$((failed + 1)); }

    wp --info &>/dev/null && log "SUCCESS" "WP-CLI test passed" || {
        log "ERROR" "WP-CLI test failed"; failed=$((failed + 1)); }

    redis-cli ping &>/dev/null && {
        log "SUCCESS" "Redis test passed"
        test_redis 6379 || failed=$((failed + 1))
    } || { log "ERROR" "Redis test failed"; failed=$((failed + 1)); }

    local php_found=0
    for version in 8.4 8.3 8.2; do
        systemctl is-active --quiet php${version}-fpm 2>/dev/null && {
            log "SUCCESS" "PHP ${version}-FPM test passed"; php_found=1; }
    done
    [ $php_found -eq 0 ] && { log "ERROR" "No PHP-FPM found"; failed=$((failed + 1)); }

    systemctl is-active --quiet autoheal && log "SUCCESS" "Autoheal test passed" || \
        log "WARNING" "Autoheal test failed (non-critical)"
    systemctl is-active --quiet fail2ban && log "SUCCESS" "Fail2ban test passed" || \
        log "WARNING" "Fail2ban test failed (non-critical)"

    [ $failed -eq 0 ] && log "SUCCESS" "All critical tests passed!" || \
        log "WARNING" "$failed critical test(s) failed. Check logs."
    return $failed
}

# ============================================
# SECTION 23 — AUTOHEAL SERVICE START
# ============================================
start_autoheal() {
    systemctl daemon-reload
    systemctl enable autoheal 2>/dev/null || true
    systemctl start autoheal 2>/dev/null || true
    wait_for_service "autoheal" 10 && log "SUCCESS" "Autoheal service running" || \
        log "WARNING" "Autoheal may not be running"
}

start_fail2ban() {
    systemctl enable fail2ban
    systemctl restart fail2ban
    wait_for_service "fail2ban" 20 && log "SUCCESS" "Fail2ban running" || \
        log "WARNING" "Fail2ban may not be running"
}

# ============================================
# SECTION 24 — MAIN INSTALLATION FLOW
# ============================================
phase_preflight() {
    clear
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}🚀 EasyInstall WordPress Performance v6.4 (HYBRID EDITION)${NC}"
    echo -e "${GREEN}   Bash = Dependencies | Python = Configuration${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo ""
    echo -e "${YELLOW}Architecture:${NC}"
    echo -e "   • ${CYAN}Bash layer${NC}  → apt installs, repos, service start/enable, lock files"
    echo -e "   • ${CYAN}Python layer${NC} → all config file generation, tuning, WP setup, monitoring"
    echo ""

    check_root
    check_lock

    # Create directories first
    mkdir -p /var/log/easyinstall /var/lib/easyinstall /var/www/html
    mkdir -p /etc/nginx/{sites-available,sites-enabled,ssl,conf.d,snippets}
    mkdir -p /backups/{daily,weekly,monthly}
    mkdir -p /etc/letsencrypt
    touch "$LOG_FILE" "$ERROR_LOG" "$STATUS_FILE"

    check_os_compatibility || exit 1
    check_network || exit 1
    check_disk_space 5120 || exit 1
    check_memory

    update_status "START" "Installation started"

    # ── Backup existing configs ──────────────────────────────────────────
    backup_config \
        "/etc/nginx/nginx.conf" \
        "/etc/mysql/mariadb.conf.d/99-wordpress.cnf" \
        "/etc/php/8.3/fpm/php.ini" \
        "/etc/php/8.2/fpm/php.ini" \
        "/etc/redis/redis.conf" \
        "/etc/fail2ban/jail.local"
}

# ── PHASE A: Bash — detect & tune ───────────────────────────────────
phase_detect_and_tune() {
    detect_ram_and_tune
    update_status "DETECT" "RAM detection complete"

    detect_os
    update_status "OS" "OS detection complete"
}

# ── PHASE B: Bash — install all packages ───────────────────────────
phase_base_packages() {
    setup_package_manager
    update_status "PACKAGES" "Package manager setup complete"

    setup_swap
    update_status "SWAP" "Swap setup complete"
}

# ── PHASE C: Python — kernel tuning (writes sysctl files) ──────────
phase_kernel_tuning() {
    # Deploy the Python config script now (it was placed by the installer)
    deploy_python_script
    run_python_config "kernel_tuning"
    sysctl -p /etc/sysctl.d/99-wordpress.conf 2>/dev/null || true
    update_status "KERNEL" "Kernel tuning complete"
}

# ── PHASE D/E/F: Bash+Python — Nginx (packages, core config, extras) ─
phase_nginx() {
    install_nginx_packages
    update_status "NGINX_PKGS" "Nginx packages installed"

    run_python_config "nginx_config"
    enable_start_nginx
    update_status "NGINX" "Nginx configured and running"

    # Nginx extras (Brotli, CF, SSL, WS, HTTP3, Edge) — enhancements on top
    # of the already-working core nginx_config above; a failure here
    # shouldn't sink the entire install.
    run_python_config "nginx_extras"      || log "WARNING" "nginx_extras stage failed — continuing without it"
    run_python_config "websocket_support" || log "WARNING" "websocket_support stage failed — continuing without it"
    run_python_config "http3_quic"        || log "WARNING" "http3_quic stage failed — continuing without it"
    run_python_config "edge_computing"    || log "WARNING" "edge_computing stage failed — continuing without it"
    reload_or_restart_service "nginx" "nginx -t"
    update_status "NGINX_EXTRAS" "Nginx extras complete"
}

# ── PHASE G/H: Bash+Python — PHP ─────────────────────────────────────
phase_php() {
    install_php_packages
    update_status "PHP_PKGS" "PHP packages installed"

    run_python_config "php_config"
    enable_start_php
    update_status "PHP" "PHP configured and running"
}

# Secure the MariaDB root account — generates a strong random password and
# stores it in /root/.my.cnf instead of leaving root passwordless.
# Split out from phase_mariadb() so the password-generation/verification
# logic reads as a single, self-contained unit.
#
# SECURITY FIX: previously this set the root password to an EMPTY string,
# which (depending on MariaDB version) can downgrade root auth from the
# OS-level `unix_socket`/`auth_socket` plugin to `mysql_native_password`
# with no password at all — meaning ANY local process/user could connect
# as root with zero credentials. Instead we generate a strong random
# password, apply it, and store it in /root/.my.cnf (mode 600) so every
# subsequent `mysql ...` invocation in this script — and in
# easyinstall_config.py, which calls bare `mysql -e` — transparently
# authenticates via that file without any code changes.
secure_mariadb_root() {
    log "STEP" "Securing MariaDB root account"
    MYSQL_ROOT_PASSWORD="$(tr -dc 'A-Za-z0-9' < /dev/urandom 2>/dev/null | head -c 32)"
    if [ -z "$MYSQL_ROOT_PASSWORD" ]; then
        # /dev/urandom should always be available on Linux, but fall back
        # to openssl just in case something is exotically restricted.
        MYSQL_ROOT_PASSWORD="$(openssl rand -hex 16 2>/dev/null)"
    fi
    if [ -z "$MYSQL_ROOT_PASSWORD" ]; then
        log "ERROR" "Could not generate a random MySQL root password — aborting MariaDB hardening"
        return 1
    fi

    # Apply via the existing passwordless/socket auth (still active at this point)
    mysql <<SECURE_SQL
ALTER USER 'root'@'localhost' IDENTIFIED BY '${MYSQL_ROOT_PASSWORD}';
DELETE FROM mysql.user WHERE User='';
DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');
DROP DATABASE IF EXISTS test;
DELETE FROM mysql.db WHERE Db='test' OR Db='test\_%';
FLUSH PRIVILEGES;
SECURE_SQL

    # Persist credentials for every future `mysql` invocation run as root
    # (both in this script and in easyinstall_config.py's bare `mysql -e` calls).
    umask 077
    cat > /root/.my.cnf <<MYCNF
[client]
user=root
password=${MYSQL_ROOT_PASSWORD}
MYCNF
    chmod 600 /root/.my.cnf
    umask 022

    # Verify the new credentials actually work before moving on
    if mysql -e "SELECT 1" >/dev/null 2>&1; then
        log "SUCCESS" "MySQL secured — root password generated and stored in /root/.my.cnf (chmod 600)"
        log "INFO"    "MariaDB root credentials: /root/.my.cnf — keep this file safe, it is required for future admin access"
    else
        log "ERROR" "MySQL root password was changed but verification login failed — check /root/.my.cnf"
        return 1
    fi
}

# ── PHASE I/J: Bash+Python — MariaDB ─────────────────────────────────
phase_mariadb() {
    install_mysql_packages
    enable_start_mariadb
    update_status "MYSQL_PKGS" "MariaDB installed"

    run_python_config "mysql_config"
    systemctl restart mariadb
    test_mysql_connection

    secure_mariadb_root
    update_status "MYSQL" "MySQL configured"
}

# ── PHASE K: Bash — install WP-CLI ─────────────────────────────────
phase_wpcli() {
    install_wp_cli
    update_status "WPCLI" "WP-CLI installed"
}

# ── PHASE L/M: Bash+Python — Redis ───────────────────────────────────
phase_redis() {
    install_redis_packages
    update_status "REDIS_PKGS" "Redis packages installed"

    run_python_config "redis_config"
    enable_start_redis
    update_status "REDIS" "Redis configured and running"
}

# ── PHASE N: Bash — install Certbot ────────────────────────────────
phase_certbot() {
    install_certbot
    update_status "CERTBOT" "Certbot installed"
}

# ── PHASE O: Python — configure Firewall ───────────────────────────
phase_firewall() {
    run_python_config "firewall_config"
    echo "y" | ufw enable 2>/dev/null || true
    update_status "FIREWALL" "Firewall configured"
}

# ── PHASE P: Python — configure Fail2ban ───────────────────────────
phase_fail2ban() {
    # Security hardening, not core to WordPress serving — don't abort the
    # whole install over it, but do make noise so the operator follows up.
    run_python_config "fail2ban_config" || log "WARNING" "fail2ban_config stage failed — server will run without fail2ban hardening"
    start_fail2ban
    update_status "FAIL2BAN" "Fail2ban configured"
}

# ── PHASE Q: Python — create monitoring & utility scripts ──────────
phase_monitoring_scripts() {
    # `create_commands` writes /usr/local/bin/easyinstall — the ENTIRE CLI
    # the operator uses afterwards (create, clone, ssl, redis-status, etc).
    # Treating it the same as the cosmetic scripts below was a mistake: a
    # silent failure here leaves a "successful" install with no usable
    # interface and only a buried WARNING line to explain why. Retry it a
    # few times and abort loudly if it still doesn't produce a working binary.
    run_python_config "create_redis_monitor"   || log "WARNING" "create_redis_monitor failed — skipping"

    local _cc_ok=0
    for _attempt in 1 2 3; do
        if run_python_config "create_commands" && [ -x /usr/local/bin/easyinstall ]; then
            _cc_ok=1
            break
        fi
        log "WARNING" "create_commands attempt $_attempt/3 did not produce a working /usr/local/bin/easyinstall — retrying"
        sleep 2
    done
    if [ "$_cc_ok" -ne 1 ]; then
        log "ERROR" "Failed to create /usr/local/bin/easyinstall after 3 attempts."
        log "ERROR" "Run manually to see the real error: python3 /usr/local/lib/easyinstall_config.py --stage create_commands"
        log "ERROR" "Then verify with: ls -la /usr/local/bin/easyinstall && echo \$PATH"
        return 1
    fi

    run_python_config "create_autoheal"        || log "WARNING" "create_autoheal failed — skipping"
    run_python_config "create_backup_script"   || log "WARNING" "create_backup_script failed — skipping"
    run_python_config "create_monitor"         || log "WARNING" "create_monitor failed — skipping"
    run_python_config "create_welcome"         || log "WARNING" "create_welcome failed — skipping"
    run_python_config "create_info_file"       || log "WARNING" "create_info_file failed — skipping"
    run_python_config "create_ai_module"       || log "WARNING" "create_ai_module failed — skipping"
    run_python_config "create_autotune_module" || log "WARNING" "create_autotune_module failed — skipping"
    start_autoheal

    # ── Detect and export active PHP version for site creation ───────────
    ACTIVE_PHP_VERSION=$(detect_active_php_version)
    export ACTIVE_PHP_VERSION
    log "INFO" "Active PHP-FPM version: $ACTIVE_PHP_VERSION"
    # Fix sockets for all active PHP-FPM versions
    for _v in 8.4 8.3 8.2; do test_php_fpm "$_v" 2>/dev/null || true; done

    update_status "SCRIPTS" "Utility scripts created"
}

# ── PHASE R: Python — advanced auto-tuning (all 10 phases) ─────────
phase_advanced_autotune() {
    # Post-install performance tuning on top of an already-working stack —
    # if it fails, the site still works, just without the extra tuning.
    log "STEP" "Running Advanced Auto-Tuning (10 phases)..."
    run_python_config "advanced_autotune" || log "WARNING" "advanced_autotune stage failed — core install remains intact, tuning skipped"
    update_status "AUTOTUNE" "Advanced auto-tuning complete"
}

# ── PHASE S: Bash — install Ollama local AI ─────────────────────────
phase_ollama() {
    install_ollama
    update_status "OLLAMA" "Ollama local AI installed"
}

# ── PHASE T: Governor + cron timers ────────────────────────────────
phase_governor_cron() {
    if [ -f /usr/local/lib/easyinstall-autotune.sh ]; then
        source /usr/local/lib/easyinstall-autotune.sh 2>/dev/null && {
            install_governor_timer 2>/dev/null || true
            _install_cache_warmer_cron 2>/dev/null || true
            _install_db_optimizer_cron 2>/dev/null || true
        } || log "WARNING" "Failed to source easyinstall-autotune.sh — governor/cron timers not installed"
    else
        log "WARNING" "/usr/local/lib/easyinstall-autotune.sh not found — skipping governor/cron timer setup"
    fi
    update_status "AUTOTUNE_SERVICES" "Governor + cron jobs installed"
}

# ── Final validation + summary banner ───────────────────────────────
phase_finalize() {
    update_status "TEST" "Running installation tests"
    test_installation

    # ── Verify the operator's actual interface to everything else works ────
    # This is the #1 thing the operator will try right after install
    # ("easyinstall help") — confirm it's really there and on PATH instead
    # of letting a buried log line be the only sign something's wrong.
    if [ ! -x /usr/local/bin/easyinstall ]; then
        log "ERROR" "/usr/local/bin/easyinstall is missing or not executable after install!"
        log "ERROR" "Fix with: python3 /usr/local/lib/easyinstall_config.py --stage create_commands"
    elif ! command -v easyinstall >/dev/null 2>&1; then
        log "WARNING" "/usr/local/bin/easyinstall exists but isn't on PATH for this shell."
        log "WARNING" "Run: hash -r   (or open a new shell) — /usr/local/bin should already be in \$PATH"
    else
        log "SUCCESS" "easyinstall CLI verified: $(command -v easyinstall)"
    fi

    cleanup_temp_files "success"
    rm -f "$LOCK_FILE"

    INSTALL_END_TIME=$(date +%s)
    INSTALL_DURATION=$((INSTALL_END_TIME - INSTALL_START_TIME))

    echo ""
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}✅ EasyInstall v6.4 HYBRID EDITION Complete!${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo ""
    echo -e "${YELLOW}📊 Installation Statistics:${NC}"
    echo "   • Duration : ${INSTALL_DURATION} seconds"
    echo "   • RAM      : ${TOTAL_RAM}MB | Cores: ${TOTAL_CORES}"
    echo ""
    echo -e "${YELLOW}📋 Next Steps:${NC}"
    echo "   1.  source ~/.bashrc"
    echo "   2.  easyinstall help"
    echo "   3.  easyinstall create mysite.com"
    echo "   4.  easyinstall redis-ports"
    echo "   5.  easyinstall monitor"
    echo "   6.  easyinstall perf-dashboard"
    echo "   7.  easyinstall warm-cache"
    echo "   8.  [NEW] easyinstall update-site domain.com"
    echo "   9.  [NEW] easyinstall clone src.com dst.com"
    echo "   10. [v6.4] easyinstall ws-enable domain.com 8080"
    echo "   11. [v6.4] easyinstall http3-enable"
    echo "   12. [v6.4] easyinstall edge-setup"
    echo ""
    echo -e "${GREEN}⚡ Performance Settings:${NC}"
    echo "   • PHP Children     : ${PHP_MAX_CHILDREN}"
    echo "   • PHP Memory       : ${PHP_MEMORY_LIMIT}"
    echo "   • MySQL Buffer     : ${MYSQL_BUFFER_POOL}"
    echo "   • Redis Memory     : ${REDIS_MAX_MEMORY}"
    echo "   • Nginx Connections: ${NGINX_WORKER_CONNECTIONS}"
    echo ""
    echo -e "${YELLOW}📝 Logs: $LOG_FILE${NC}"
    echo -e "${YELLOW}☕ Support: https://paypal.me/sugandodrai${NC}"
    echo -e "${GREEN}========================================${NC}"

    update_status "COMPLETE" "Installation completed successfully"
}

main() {
    phase_preflight
    phase_detect_and_tune
    phase_base_packages
    phase_kernel_tuning
    phase_nginx
    phase_php
    phase_mariadb
    phase_wpcli
    phase_redis
    phase_certbot
    phase_firewall
    phase_fail2ban
    phase_monitoring_scripts
    phase_advanced_autotune
    phase_ollama
    phase_governor_cron
    phase_finalize
}

# ============================================
# Deploy Python config script
# (embeds easyinstall_config.py alongside this script)
# ============================================
# Trusted fallback location to download easyinstall_config.py from if it
# cannot be found locally (e.g. script was run via `curl | bash`, or invoked
# through a symlink so its companion file isn't actually next to it).
# Override by exporting EASYINSTALL_PY_URL before running this script.
EASYINSTALL_PY_URL="${EASYINSTALL_PY_URL:-https://raw.githubusercontent.com/easyinstall/easyinstall/main/easyinstall_config.py}"

deploy_python_script() {
    log "STEP" "Deploying Python configuration module"
    mkdir -p /usr/local/lib

    # ── Resolve our own real location, following symlinks ───────────────────
    # `dirname "${BASH_SOURCE[0]}"` is wrong if this script was invoked via a
    # symlink (e.g. /usr/local/bin/easyinstall -> /opt/easyinstall/install.sh):
    # it returns the symlink's directory, not the real script's directory, so
    # the co-located easyinstall_config.py is never found. readlink -f fixes that.
    local self_path
    if command -v readlink >/dev/null 2>&1 && self_path="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null)"; then
        : # resolved real path
    else
        self_path="${BASH_SOURCE[0]}"
    fi
    local script_dir="$(cd "$(dirname "$self_path")" 2>/dev/null && pwd)"

    # ── Search candidate locations, in order of preference ───────────────────
    local candidates=(
        "$script_dir/easyinstall_config.py"
        "$(pwd)/easyinstall_config.py"
        "/usr/local/lib/easyinstall_config.py"
        "/tmp/easyinstall_config.py"
    )

    local found=""
    for candidate in "${candidates[@]}"; do
        if [ -n "$candidate" ] && [ -f "$candidate" ]; then
            found="$candidate"
            break
        fi
    done

    if [ -n "$found" ]; then
        # Avoid a no-op copy onto itself if it's already at the target path
        if [ "$(cd "$(dirname "$found")" && pwd)/$(basename "$found")" != "$PYTHON_CONFIG_SCRIPT" ]; then
            cp "$found" "$PYTHON_CONFIG_SCRIPT"
        fi
        chmod +x "$PYTHON_CONFIG_SCRIPT"
        log "SUCCESS" "Python config module deployed to $PYTHON_CONFIG_SCRIPT (source: $found)"
        return 0
    fi

    # ── Not found locally (typical of `curl ... | bash` one-liners) ─────────
    # Fall back to downloading the trusted copy. This requires
    # EASYINSTALL_PY_URL to point at a real, version-matched release asset —
    # set it explicitly if you're not running from the official installer.
    log "WARNING" "easyinstall_config.py not found alongside this script — attempting download from trusted source"
    if run_cmd_retry 3 5 "curl -fsSL '$EASYINSTALL_PY_URL' -o '$PYTHON_CONFIG_SCRIPT'" || \
       run_cmd_retry 3 5 "wget -q '$EASYINSTALL_PY_URL' -O '$PYTHON_CONFIG_SCRIPT'"; then
        if [ -s "$PYTHON_CONFIG_SCRIPT" ] && head -c 64 "$PYTHON_CONFIG_SCRIPT" | grep -q "python"; then
            chmod +x "$PYTHON_CONFIG_SCRIPT"
            log "SUCCESS" "Python config module downloaded to $PYTHON_CONFIG_SCRIPT"
            return 0
        fi
        log "ERROR" "Downloaded file does not look like a valid Python script — aborting"
    fi

    log "ERROR" "easyinstall_config.py not found in $script_dir (or any fallback location) and download failed."
    log "ERROR" "Place easyinstall_config.py next to easyinstall.sh, or set EASYINSTALL_PY_URL to a reachable copy."
    exit 1
}

main "$@"
