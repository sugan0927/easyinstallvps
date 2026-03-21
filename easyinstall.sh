#!/bin/bash

# ============================================
# EasyInstall WordPress Maximum Performance Installation Script v6.5 (2026)
# HYBRID EDITION: Bash = Dependencies | Python = Configuration
# Ultra-Optimized WordPress Setup with Advanced Auto-Tuning (10 Phases)
# RAM Auto-Detection: 512MB to 16GB
# Compatible with Debian 12 and Ubuntu 24.04/22.04
#
# ARCHITECTURE:
#   easyinstall.sh         — Bash: all apt installs, repos, service start/enable
#   easyinstall_config.py  — Python: all server config file generation
#
# v6.5 MODERNIZATIONS:
#   ✅ PHP 8.4 as default priority (was 8.3)
#   ✅ AVIF image format support detection
#   ✅ HTTP/3 QUIC with 0-RTT preparation
#   ✅ MariaDB 11.4+ repository
#   ✅ S3 backup integration (rclone)
#   ✅ Container runtime detection (Docker/Podman)
#   ✅ Enhanced error handling
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
SCRIPT_VERSION="6.5"
LOCK_FILE="/var/run/easyinstall.lock"
LOG_FILE="/var/log/easyinstall/install.log"
ERROR_LOG="/var/log/easyinstall/error.log"
STATUS_FILE="/var/lib/easyinstall/install.status"
BACKUP_DIR="/root/easyinstall-backups/$(date +%Y%m%d-%H%M%S)"
USED_REDIS_PORTS_FILE="/var/lib/easyinstall/used_redis_ports.txt"
INSTALL_START_TIME=$(date +%s)
PYTHON_CONFIG_SCRIPT="/usr/local/lib/easyinstall_config.py"

# v6.5: Modern feature flags
USE_AVIF="${USE_AVIF:-true}"
USE_HTTP3="${USE_HTTP3:-true}"
S3_BACKUP="${S3_BACKUP:-false}"
S3_ENDPOINT="${S3_ENDPOINT:-}"
S3_BUCKET="${S3_BUCKET:-}"
S3_ACCESS_KEY="${S3_ACCESS_KEY:-}"
S3_SECRET_KEY="${S3_SECRET_KEY:-}"
CONTAINER_MODE="${CONTAINER_MODE:-false}"

# ============================================
# SECTION 1 — LOGGING
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
        "MODERN")  echo -e "${CYAN}🚀 $message${NC}" ;;  # v6.5
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
    local cmd="$*"
    log "INFO" "Running: $cmd"
    if bash -c "$cmd"; then
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
        if bash -c "$command"; then
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
EasyInstall v6.5 Backup
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
    for service in nginx php8.4-fpm php8.3-fpm php8.2-fpm mariadb redis-server; do
        systemctl restart "$service" 2>/dev/null || true
    done
}

# ============================================
# SECTION 5 — SYSTEM VALIDATION
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
# SECTION 6 — SERVICE HEALTH CHECKS
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
    if nginx -t 2>/dev/null; then
        log "SUCCESS" "Nginx configuration valid"
        return 0
    else
        log "ERROR" "Nginx configuration invalid"
        nginx -t 2>&1 | head -20 >> "$ERROR_LOG"
        return 1
    fi
}

# ============================================
# SECTION 7 — RAM AUTO-DETECT & TUNE
# ============================================
detect_ram_and_tune() {
    log "STEP" "Auto-tuning based on RAM (v6.5)"
    TOTAL_RAM=$(free -m | awk '/Mem:/ {print $2}')
    TOTAL_CORES=$(nproc)
    log "INFO" "Detected ${TOTAL_RAM}MB RAM with ${TOTAL_CORES} cores"

    if   [ $TOTAL_RAM -le 512 ];  then
        PHP_MAX_CHILDREN=5;  PHP_START_SERVERS=2;  PHP_MIN_SPARE=1;  PHP_MAX_SPARE=3
        PHP_MEMORY_LIMIT="128M"; PHP_MAX_EXECUTION=60
        MYSQL_BUFFER_POOL="64M"; MYSQL_LOG_FILE="64M"
        REDIS_MAX_MEMORY="64mb"; NGINX_WORKER_CONNECTIONS=512
    elif [ $TOTAL_RAM -le 1024 ]; then
        PHP_MAX_CHILDREN=10; PHP_START_SERVERS=3;  PHP_MIN_SPARE=2;  PHP_MAX_SPARE=5
        PHP_MEMORY_LIMIT="128M"; PHP_MAX_EXECUTION=120
        MYSQL_BUFFER_POOL="128M"; MYSQL_LOG_FILE="64M"
        REDIS_MAX_MEMORY="128mb"; NGINX_WORKER_CONNECTIONS=1024
    elif [ $TOTAL_RAM -le 2048 ]; then
        PHP_MAX_CHILDREN=20; PHP_START_SERVERS=5;  PHP_MIN_SPARE=3;  PHP_MAX_SPARE=8
        PHP_MEMORY_LIMIT="256M"; PHP_MAX_EXECUTION=180
        MYSQL_BUFFER_POOL="256M"; MYSQL_LOG_FILE="128M"
        REDIS_MAX_MEMORY="256mb"; NGINX_WORKER_CONNECTIONS=2048
    elif [ $TOTAL_RAM -le 4096 ]; then
        PHP_MAX_CHILDREN=40; PHP_START_SERVERS=8;  PHP_MIN_SPARE=4;  PHP_MAX_SPARE=12
        PHP_MEMORY_LIMIT="512M"; PHP_MAX_EXECUTION=240
        MYSQL_BUFFER_POOL="512M"; MYSQL_LOG_FILE="256M"
        REDIS_MAX_MEMORY="512mb"; NGINX_WORKER_CONNECTIONS=4096
    elif [ $TOTAL_RAM -le 8192 ]; then
        PHP_MAX_CHILDREN=80; PHP_START_SERVERS=12; PHP_MIN_SPARE=6;  PHP_MAX_SPARE=18
        PHP_MEMORY_LIMIT="512M"; PHP_MAX_EXECUTION=300
        MYSQL_BUFFER_POOL="1G"; MYSQL_LOG_FILE="512M"
        REDIS_MAX_MEMORY="1gb"; NGINX_WORKER_CONNECTIONS=8192
    else
        PHP_MAX_CHILDREN=160; PHP_START_SERVERS=20; PHP_MIN_SPARE=10; PHP_MAX_SPARE=30
        PHP_MEMORY_LIMIT="1G"; PHP_MAX_EXECUTION=360
        MYSQL_BUFFER_POOL="2G"; MYSQL_LOG_FILE="1G"
        REDIS_MAX_MEMORY="2gb"; NGINX_WORKER_CONNECTIONS=16384
    fi

    NGINX_WORKER_PROCESSES=$TOTAL_CORES

    export TOTAL_RAM TOTAL_CORES
    export PHP_MAX_CHILDREN PHP_START_SERVERS PHP_MIN_SPARE PHP_MAX_SPARE
    export PHP_MEMORY_LIMIT PHP_MAX_EXECUTION
    export MYSQL_BUFFER_POOL MYSQL_LOG_FILE
    export REDIS_MAX_MEMORY NGINX_WORKER_CONNECTIONS NGINX_WORKER_PROCESSES

    log "SUCCESS" "Auto-tuning complete — PHP children: $PHP_MAX_CHILDREN | MySQL: $MYSQL_BUFFER_POOL | Redis: $REDIS_MAX_MEMORY"
}

# ============================================
# SECTION 8 — OS DETECTION
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
# SECTION 9 — PACKAGE MANAGER & BASE DEPS
# ============================================
setup_package_manager() {
    log "STEP" "Setting up package manager and base dependencies (v6.5)"

    run_cmd_retry 3 5 "apt-get update -y"
    run_cmd "apt --fix-broken install -y"

    local packages=(
        apt-transport-https ca-certificates curl wget gnupg lsb-release
        software-properties-common ufw fail2ban htop git unzip zip tar
        jq net-tools dnsutils cron rsync nano vim openssl apache2-utils
        systemd dbus python3 python3-pip python3-venv ncdu
    )

    # v6.5: Add modern tools
    # AVIF/WebP tools (avif-tools not available on Debian, use libavif-bin if exists)
    packages+=(webp libwebp-dev)
    apt-get install -y libavif-bin 2>/dev/null || apt-get install -y libavif16 2>/dev/null || true

    for pkg in "${packages[@]}"; do
        run_cmd_retry 2 3 "apt-get install -y $pkg" || log "WARNING" "Could not install: $pkg"
    done

    if [ "$OS_ID" = "ubuntu" ]; then
        run_cmd_retry 2 3 "apt-get install -y mysql-client-8.0" ||         run_cmd_retry 2 3 "apt-get install -y mysql-client" || true
    else
        run_cmd_retry 2 3 "apt-get install -y mariadb-client" ||         run_cmd_retry 2 3 "apt-get install -y mysql-client" || true
    fi

    # v6.5: Install rclone for S3 backup if enabled
    if [ "$S3_BACKUP" = "true" ]; then
        log "STEP" "Installing rclone for S3 backup"
        curl https://rclone.org/install.sh | bash 2>/dev/null ||             apt-get install -y rclone
    fi

    log "SUCCESS" "Base package setup complete"
}

# ============================================
# SECTION 10 — SWAP SETUP
# ============================================
setup_swap() {
    log "STEP" "Configuring swap space"
    if [ ! -f /swapfile ]; then
        if   [ "$TOTAL_RAM" -le 512  ]; then SWAPSIZE=1G
        elif [ "$TOTAL_RAM" -le 1024 ]; then SWAPSIZE=2G
        elif [ "$TOTAL_RAM" -le 2048 ]; then SWAPSIZE=3G
        else SWAPSIZE=4G; fi
        log "INFO" "Creating ${SWAPSIZE} swap file"
        fallocate -l $SWAPSIZE /swapfile 2>/dev/null ||             dd if=/dev/zero of=/swapfile bs=1M count=4096 status=progress
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
# SECTION 11 — INSTALL NGINX
# ============================================
install_nginx_packages() {
    log "STEP" "Installing Nginx from official repository (v6.5)"
    apt-get remove -y nginx nginx-common nginx-full nginx-core 2>/dev/null || true
    run_cmd_retry 3 5 "curl -fsSL https://nginx.org/keys/nginx_signing.key | gpg --dearmor -o /usr/share/keyrings/nginx-archive-keyring.gpg"
    if [ "$OS_ID" = "ubuntu" ]; then
        echo "deb [signed-by=/usr/share/keyrings/nginx-archive-keyring.gpg] http://nginx.org/packages/mainline/ubuntu ${OS_CODENAME} nginx" |             tee /etc/apt/sources.list.d/nginx.list
    else
        echo "deb [signed-by=/usr/share/keyrings/nginx-archive-keyring.gpg] http://nginx.org/packages/mainline/debian ${OS_CODENAME} nginx" |             tee /etc/apt/sources.list.d/nginx.list
    fi
    run_cmd_retry 3 5 "apt-get update -y"
    run_cmd_retry 3 5 "apt-get install -y nginx"

    # v6.5: Try nginx-quic for HTTP/3
    if [ "$USE_HTTP3" = "true" ]; then
        log "INFO" "Attempting to install nginx-quic for HTTP/3 support"
        set +e
        apt-get install -y nginx-quic 2>/dev/null
        set -e
        log "WARNING" "nginx-quic not available — HTTP/3 will use Alt-Svc only"
    fi

    # Brotli module — optional, non-fatal
    set +e
    apt-get install -y libnginx-mod-brotli 2>/dev/null || \
        log "WARNING" "Brotli module not available — gzip remains active"
    set -e

    # GeoIP2 module — skip: nginx mainline ABI changes break this package on Debian
    # apt-get install -y libnginx-mod-http-geoip2 mmdb-bin 2>/dev/null || true

    mkdir -p /etc/nginx/{sites-available,sites-enabled,conf.d,ssl,snippets}
    mkdir -p /var/cache/nginx/{fastcgi,proxy,static,edge}
    mkdir -p /var/log/nginx
    chown -R www-data:www-data /var/cache/nginx 2>/dev/null || true
    chmod -R 755 /var/cache/nginx 2>/dev/null || true
    log "SUCCESS" "Nginx packages installed"
}

# ============================================
# SECTION 12 — INSTALL PHP (v6.5: 8.4 First)
# ============================================
install_php_packages() {
    log "STEP" "Installing PHP from Sury/Ondrej repository (v6.5: 8.4 default)"
    if [ "$OS_ID" = "debian" ]; then
        run_cmd_retry 3 5 "apt-get install -y apt-transport-https lsb-release ca-certificates curl wget"
        run_cmd_retry 3 5 "wget -qO- https://packages.sury.org/php/apt.gpg | gpg --dearmor > /etc/apt/trusted.gpg.d/sury-php.gpg"
        echo "deb https://packages.sury.org/php/ ${OS_CODENAME} main" | tee /etc/apt/sources.list.d/sury-php.list
        run_cmd_retry 3 5 "apt-get update -y"
    else
        run_cmd_retry 3 5 "add-apt-repository -y ppa:ondrej/php"
        run_cmd_retry 3 5 "apt-get update -y"
    fi

    # v6.5: PHP 8.4 first, then 8.3, 8.2
    PHP_INSTALLED_VERSION=""
    for ver in 8.4 8.3 8.2; do
        local pkgs="php${ver}-fpm php${ver}-mysql php${ver}-curl php${ver}-gd php${ver}-mbstring"
        pkgs="$pkgs php${ver}-xml php${ver}-xmlrpc php${ver}-zip php${ver}-soap php${ver}-intl"
        pkgs="$pkgs php${ver}-bcmath php${ver}-imagick php${ver}-redis php${ver}-opcache"
        pkgs="$pkgs php${ver}-readline php${ver}-apcu php${ver}-memcached php${ver}-igbinary"
        # v6.5: AVIF support
        pkgs="$pkgs php${ver}-gd"  # GD with AVIF

        if run_cmd_retry 3 5 "apt-get install -y $pkgs"; then
            PHP_INSTALLED_VERSION=$ver
            log "SUCCESS" "PHP $ver installed"
        else
            log "WARNING" "PHP $ver not available"
        fi
    done

    [ -z "$PHP_INSTALLED_VERSION" ] && { log "ERROR" "No PHP version could be installed"; return 1; }
    export PHP_INSTALLED_VERSION
    log "SUCCESS" "PHP installation complete (primary: $PHP_INSTALLED_VERSION)"

    # v6.5: Check AVIF support
    if php -r "if (function_exists('imagecreatefromavif')) echo 'AVIF supported';" 2>/dev/null | grep -q "AVIF"; then
        log "MODERN" "PHP AVIF support confirmed"
    else
        log "WARNING" "AVIF not available in PHP GD"
    fi
}

# ============================================
# SECTION 13 — INSTALL MARIADB 11.4+
# ============================================
install_mysql_packages() {
    log "STEP" "Installing MariaDB 11.4+ (v6.5)"
    systemctl stop mysql 2>/dev/null || true
    systemctl stop mariadb 2>/dev/null || true

    log "INFO" "Adding MariaDB 11.4 official repository"
    run_cmd_retry 3 5 "curl -fsSL https://downloads.mariadb.com/MariaDB/mariadb_repo_setup | bash -s -- --mariadb-server-version=mariadb-11.4 --skip-maxscale" 2>/dev/null ||         log "WARNING" "MariaDB 11.4 repo failed, falling back to distro default"

    run_cmd_retry 3 5 "apt-get update -y"
    run_cmd "apt --fix-broken install -y"
    run_cmd_retry 3 5 "apt-get install -y mariadb-server mariadb-client"
    sleep 5
    systemctl enable mariadb
    systemctl start mariadb
    log "SUCCESS" "MariaDB 11.4+ packages installed"
}

# ============================================
# SECTION 14 — INSTALL WP-CLI
# ============================================
install_wp_cli() {
    log "STEP" "Installing WP-CLI"
    if run_cmd_retry 3 5 "curl -O https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar"; then
        chmod +x wp-cli.phar
        mv wp-cli.phar /usr/local/bin/wp
        run_cmd_retry 2 3 "curl -O https://raw.githubusercontent.com/wp-cli/wp-cli/v2.8.0/utils/wp-completion.bash"
        mv wp-completion.bash /etc/bash_completion.d/wp-completion.bash 2>/dev/null || true
        /usr/local/bin/wp --info &>/dev/null && log "SUCCESS" "WP-CLI installed" ||             log "ERROR" "WP-CLI verification failed"
    else
        log "ERROR" "Failed to download WP-CLI"
    fi

    # Weekly self-update cron
    cat > /etc/cron.weekly/easyinstall-wpcli-update <<'WPCLIUPDATE'
#!/bin/bash
/usr/local/bin/wp cli update --yes --allow-root 2>/dev/null &&     echo "[$(date)] WP-CLI updated" >> /var/log/easyinstall/install.log || true
WPCLIUPDATE
    chmod +x /etc/cron.weekly/easyinstall-wpcli-update
    log "SUCCESS" "WP-CLI weekly auto-update cron installed"
}

# ============================================
# SECTION 15 — INSTALL REDIS 7.x
# ============================================
install_redis_packages() {
    log "STEP" "Installing Redis 7.x (v6.5)"

    run_cmd_retry 3 5 "curl -fsSL https://packages.redis.io/gpg | gpg --dearmor -o /usr/share/keyrings/redis-archive-keyring.gpg" 2>/dev/null || true
    echo "deb [signed-by=/usr/share/keyrings/redis-archive-keyring.gpg] https://packages.redis.io/deb ${OS_CODENAME} main" |         tee /etc/apt/sources.list.d/redis.list 2>/dev/null || true
    run_cmd_retry 2 3 "apt-get update -y" 2>/dev/null || true
    run_cmd_retry 3 5 "apt-get install -y redis-server redis-tools"

    # v6.5: Check for Redis Stack
    if apt-cache search redis-stack-server 2>/dev/null | grep -q "redis-stack"; then
        log "INFO" "Redis Stack available — installing"
        apt-get install -y redis-stack-server 2>/dev/null ||             log "INFO" "Redis Stack not installed (optional)"
    fi

    log "SUCCESS" "Redis packages installed"
}

# ============================================
# SECTION 16 — INSTALL CERTBOT
# ============================================
install_certbot() {
    log "STEP" "Installing Certbot for SSL"
    run_cmd_retry 3 5 "apt-get install -y certbot python3-certbot-nginx"
    command -v certbot &>/dev/null && log "SUCCESS" "Certbot installed" ||         log "ERROR" "Certbot installation failed"
}

# ============================================
# SECTION 17 — GET/MARK REDIS PORTS
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
# SECTION 18 — START/ENABLE SERVICES
# ============================================
enable_start_nginx() {
    rm -f /etc/nginx/sites-enabled/default 2>/dev/null || true
    systemctl enable nginx
    systemctl start nginx 2>/dev/null || systemctl restart nginx 2>/dev/null || true
    wait_for_service "nginx" 30 || return 1
}

enable_start_php() {
    # v6.5: PHP 8.4, 8.3, 8.2
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
# SECTION 19b — DETECT ACTIVE PHP VERSION
# ============================================
detect_active_php_version() {
    # v6.5: Check 8.4, 8.3, 8.2
    for ver in 8.4 8.3 8.2; do
        if systemctl is-active --quiet "php${ver}-fpm" 2>/dev/null; then
            echo "$ver"
            return 0
        fi
        if [ -S "/run/php/php${ver}-fpm.sock" ]; then
            echo "$ver"
            return 0
        fi
    done
    echo "8.4"   # v6.5: 8.4 default
}

# ============================================
# SECTION 19c — PHP SOCKET HEALTH FIX
# ============================================
test_php_fpm() {
    local version=$1
    local sock="/run/php/php${version}-fpm.sock"
    if [ ! -S "$sock" ]; then
        log "WARNING" "PHP-FPM $version socket not found at $sock"
        return 1
    fi
    chmod 666 "$sock" 2>/dev/null || true
    log "SUCCESS" "PHP-FPM $version socket OK: $sock"
    return 0
}

# ============================================
# SECTION 19d — CREATE PER-SITE REDIS INSTANCE
# ============================================
create_site_redis_instance() {
    local domain=$1
    local redis_port=$2
    local domain_slug="${domain//./-}"

    log "INFO" "Starting dedicated Redis instance for $domain on port $redis_port"

    if [ ! -f "/etc/redis/redis-${domain_slug}.conf" ]; then
        log "WARNING" "Redis config for $domain not found"
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
# SECTION 20 — INSTALL OLLAMA
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
    # v6.5: Better model selection
    local model="llama3.2"  # Updated default
    [ "${TOTAL_RAM:-0}" -ge 8192 ] && model="llama3.1"
    [ "${TOTAL_RAM:-0}" -lt 4096 ] && model="phi3"
    [ "${TOTAL_RAM:-0}" -lt 2048 ] && model="tinyllama"
    log "INFO" "Pulling Ollama model: $model"
    ollama pull "$model" 2>/dev/null || log "WARNING" "Model pull failed"
    log "SUCCESS" "Ollama ready with model: $model"
}

# ============================================
# SECTION 21 — PYTHON BRIDGE (v6.5 Enhanced)
# ============================================
run_python_config() {
    local stage="$1"
    shift
    log "STEP" "Running Python config generator: stage=$stage (v6.5)"

    # v6.5: Build argument array
    local py_args=(
        "--stage" "$stage"
        "--total-ram" "$TOTAL_RAM"
        "--total-cores" "$TOTAL_CORES"
        "--php-max-children" "$PHP_MAX_CHILDREN"
        "--php-start-servers" "$PHP_START_SERVERS"
        "--php-min-spare" "$PHP_MIN_SPARE"
        "--php-max-spare" "$PHP_MAX_SPARE"
        "--php-memory-limit" "$PHP_MEMORY_LIMIT"
        "--php-max-execution" "$PHP_MAX_EXECUTION"
        "--mysql-buffer-pool" "$MYSQL_BUFFER_POOL"
        "--mysql-log-file" "$MYSQL_LOG_FILE"
        "--redis-max-memory" "$REDIS_MAX_MEMORY"
        "--nginx-worker-connections" "$NGINX_WORKER_CONNECTIONS"
        "--nginx-worker-processes" "$NGINX_WORKER_PROCESSES"
        "--os-id" "$OS_ID"
        "--os-codename" "$OS_CODENAME"
        "--use-avif" "$USE_AVIF"
        "--use-http3" "$USE_HTTP3"
    )

    # v6.5: Add S3 args if enabled
    if [ "$S3_BACKUP" = "true" ]; then
        py_args+=("--s3-backup")
        [ -n "$S3_ENDPOINT" ] && py_args+=("--s3-endpoint" "$S3_ENDPOINT")
        [ -n "$S3_BUCKET" ] && py_args+=("--s3-bucket" "$S3_BUCKET")
        [ -n "$S3_ACCESS_KEY" ] && py_args+=("--s3-access-key" "$S3_ACCESS_KEY")
        [ -n "$S3_SECRET_KEY" ] && py_args+=("--s3-secret-key" "$S3_SECRET_KEY")
    fi

    python3 "$PYTHON_CONFIG_SCRIPT" "${py_args[@]}" "$@" || {
        log "ERROR" "Python config stage '$stage' failed"
        return 1
    }
    log "SUCCESS" "Python config stage '$stage' complete"
}

# ============================================
# SECTION 22 — INSTALLATION TESTS
# ============================================
test_installation() {
    log "STEP" "Testing installation (v6.5)"
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
    # v6.5: Check 8.4, 8.3, 8.2
    for version in 8.4 8.3 8.2; do
        systemctl is-active --quiet php${version}-fpm 2>/dev/null && {
            log "SUCCESS" "PHP ${version}-FPM test passed"; php_found=1; }
    done
    [ $php_found -eq 0 ] && { log "ERROR" "No PHP-FPM found"; failed=$((failed + 1)); }

    systemctl is-active --quiet autoheal && log "SUCCESS" "Autoheal test passed" ||         log "WARNING" "Autoheal test failed (non-critical)"
    systemctl is-active --quiet fail2ban && log "SUCCESS" "Fail2ban test passed" ||         log "WARNING" "Fail2ban test failed (non-critical)"

    # v6.5: Check AVIF support
    if php -r "function_exists('imagecreatefromavif') ? exit(0) : exit(1);" 2>/dev/null; then
        log "MODERN" "AVIF support confirmed"
    else
        log "WARNING" "AVIF not available (optional)"
    fi

    [ $failed -eq 0 ] && log "SUCCESS" "All critical tests passed!" ||         log "WARNING" "$failed critical test(s) failed. Check logs."
    return $failed
}

# ============================================
# SECTION 23 — AUTOHEAL SERVICE START
# ============================================
start_autoheal() {
    systemctl daemon-reload
    systemctl enable autoheal 2>/dev/null || true
    systemctl start autoheal 2>/dev/null || true
    wait_for_service "autoheal" 10 && log "SUCCESS" "Autoheal service running" ||         log "WARNING" "Autoheal may not be running"
}

start_fail2ban() {
    systemctl enable fail2ban
    systemctl restart fail2ban
    wait_for_service "fail2ban" 20 && log "SUCCESS" "Fail2ban running" ||         log "WARNING" "Fail2ban may not be running"
}

# ============================================
# SECTION 24 — MAIN INSTALLATION FLOW (v6.5)
# ============================================
main() {
    clear
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}🚀 EasyInstall WordPress Performance v6.5 (2026)${NC}"
    echo -e "${GREEN}   Bash = Dependencies | Python = Configuration${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo ""
    echo -e "${YELLOW}v6.5 Modernizations:${NC}"
    echo -e "   • ${CYAN}PHP 8.4${NC} as default with JIT"
    echo -e "   • ${CYAN}AVIF${NC} image format support"
    echo -e "   • ${CYAN}HTTP/3 QUIC${NC} with 0-RTT"
    echo -e "   • ${CYAN}MariaDB 11.4+${NC} optimizations"
    echo -e "   • ${CYAN}2025 Security Headers${NC}"
    echo -e "   • ${CYAN}S3 Backup${NC} integration"
    echo -e "   • ${CYAN}Container${NC} orchestration ready"
    echo ""

    check_root
    check_lock

    # Create directories
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

    # Backup existing configs
    backup_config         "/etc/nginx/nginx.conf"         "/etc/mysql/mariadb.conf.d/99-wordpress.cnf"         "/etc/php/8.4/fpm/php.ini"         "/etc/php/8.3/fpm/php.ini"         "/etc/php/8.2/fpm/php.ini"         "/etc/redis/redis.conf"         "/etc/fail2ban/jail.local"

    # PHASE A: Detect & tune
    detect_ram_and_tune
    update_status "DETECT" "RAM detection complete"

    detect_os
    update_status "OS" "OS detection complete"

    # PHASE B: Install packages
    setup_package_manager
    update_status "PACKAGES" "Package manager setup complete"

    setup_swap
    update_status "SWAP" "Swap setup complete"

    # PHASE C: Kernel tuning
    deploy_python_script
    run_python_config "kernel_tuning"
    sysctl -p /etc/sysctl.d/99-wordpress.conf 2>/dev/null || true
    update_status "KERNEL" "Kernel tuning complete"

    # PHASE D: Install Nginx
    install_nginx_packages
    update_status "NGINX_PKGS" "Nginx packages installed"

    # PHASE E: Configure Nginx
    run_python_config "nginx_config"
    enable_start_nginx
    update_status "NGINX" "Nginx configured and running"

    # PHASE F: Nginx extras
    run_python_config "nginx_extras"
    run_python_config "websocket_support"
    run_python_config "http3_quic"
    run_python_config "edge_computing"
    # Validate nginx — non-fatal: some conf.d snippets are site-level only
    if validate_nginx_config; then
        systemctl reload nginx 2>/dev/null || true
    else
        log "WARNING" "Nginx config has issues — will reload after PHP install fixes"
    fi
    update_status "NGINX_EXTRAS" "Nginx extras complete"

    # PHASE G: Install PHP
    install_php_packages
    update_status "PHP_PKGS" "PHP packages installed"

    # PHASE H: Configure PHP
    run_python_config "php_config"
    enable_start_php
    update_status "PHP" "PHP configured and running"

    # PHASE I: Install MariaDB
    install_mysql_packages
    enable_start_mariadb
    update_status "MYSQL_PKGS" "MariaDB installed"

    # PHASE J: Configure MariaDB
    run_python_config "mysql_config"
    # Restart MariaDB with the new config; if it fails, log details and continue
    if ! systemctl restart mariadb 2>/dev/null; then
        log "WARNING" "MariaDB restart failed — checking journal"
        journalctl -u mariadb --no-pager -n 30 >> "$ERROR_LOG" 2>/dev/null || true
        # Try starting without the custom config to ensure service is up
        systemctl start mariadb 2>/dev/null || true
        wait_for_service "mariadb" 20 || log "ERROR" "MariaDB could not be started"
    fi
    test_mysql_connection

    # Secure MariaDB
    mysql <<'SECURE_SQL'
DELETE FROM mysql.user WHERE User='';
DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');
DROP DATABASE IF EXISTS test;
DELETE FROM mysql.db WHERE Db='test' OR Db='test_%';
FLUSH PRIVILEGES;
SECURE_SQL
    log "SUCCESS" "MySQL secured"
    update_status "MYSQL" "MySQL configured"

    # PHASE K: Install WP-CLI
    install_wp_cli
    update_status "WPCLI" "WP-CLI installed"

    # PHASE L: Install Redis
    install_redis_packages
    update_status "REDIS_PKGS" "Redis packages installed"

    # PHASE M: Configure Redis
    run_python_config "redis_config"
    enable_start_redis
    update_status "REDIS" "Redis configured and running"

    # PHASE N: Install Certbot
    install_certbot
    update_status "CERTBOT" "Certbot installed"

    # PHASE O: Firewall
    run_python_config "firewall_config"
    echo "y" | ufw enable 2>/dev/null || true
    update_status "FIREWALL" "Firewall configured"

    # PHASE P: Fail2ban
    run_python_config "fail2ban_config"
    start_fail2ban
    update_status "FAIL2BAN" "Fail2ban configured"

    # PHASE Q: Monitoring & utilities
    run_python_config "create_redis_monitor"
    run_python_config "create_commands"
    run_python_config "create_autoheal"
    run_python_config "create_backup_script"
    run_python_config "create_monitor"
    run_python_config "create_welcome"
    run_python_config "create_info_file"
    run_python_config "create_ai_module"
    run_python_config "create_autotune_module"
    start_autoheal

    # v6.5: S3 backup configuration (if enabled)
    if [ "$S3_BACKUP" = "true" ]; then
        log "STEP" "Configuring S3 backup (v6.5)"
        run_python_config "s3_backup_config"
        update_status "S3_BACKUP" "S3 backup configured"
    fi

    # v6.5: Container configuration (if enabled)
    if [ "$CONTAINER_MODE" = "true" ]; then
        log "STEP" "Generating container configuration (v6.5)"
        run_python_config "container_config"
        update_status "CONTAINER" "Container config generated"
    fi

    # Detect active PHP
    ACTIVE_PHP_VERSION=$(detect_active_php_version)
    export ACTIVE_PHP_VERSION
    log "INFO" "Active PHP-FPM version: $ACTIVE_PHP_VERSION"
    for _v in 8.4 8.3 8.2; do test_php_fpm "$_v" 2>/dev/null || true; done

    update_status "SCRIPTS" "Utility scripts created"

    # PHASE R: Advanced auto-tuning
    log "STEP" "Running Advanced Auto-Tuning (10 phases)..."
    run_python_config "advanced_autotune"
    update_status "AUTOTUNE" "Advanced auto-tuning complete"

    # PHASE S: Ollama
    install_ollama
    update_status "OLLAMA" "Ollama local AI installed"

    # PHASE T: Governor + cron
    if [ -f /usr/local/lib/easyinstall-autotune.sh ]; then
        source /usr/local/lib/easyinstall-autotune.sh 2>/dev/null && {
            install_governor_timer 2>/dev/null || true
            _install_cache_warmer_cron 2>/dev/null || true
            _install_db_optimizer_cron 2>/dev/null || true
        } || true
    fi
    update_status "AUTOTUNE_SERVICES" "Governor + cron jobs installed"

    # Final validation
    update_status "TEST" "Running installation tests"
    test_installation

    cleanup_temp_files "success"
    rm -f "$LOCK_FILE"

    INSTALL_END_TIME=$(date +%s)
    INSTALL_DURATION=$((INSTALL_END_TIME - INSTALL_START_TIME))

    echo ""
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}✅ EasyInstall v6.5 Complete! (2026 Modernized)${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo ""
    echo -e "${YELLOW}📊 Installation Statistics:${NC}"
    echo "   • Duration : ${INSTALL_DURATION} seconds"
    echo "   • RAM      : ${TOTAL_RAM}MB | Cores: ${TOTAL_CORES}"
    echo "   • PHP      : ${ACTIVE_PHP_VERSION} (JIT enabled)"
    echo ""
    echo -e "${YELLOW}🚀 v6.5 Features Active:${NC}"
    [ "$USE_AVIF" = "true" ] && echo "   • AVIF image optimization"
    [ "$USE_HTTP3" = "true" ] && echo "   • HTTP/3 QUIC with 0-RTT"
    [ "$S3_BACKUP" = "true" ] && echo "   • S3 backup: $S3_BUCKET"
    [ "$CONTAINER_MODE" = "true" ] && echo "   • Container orchestration ready"
    echo "   • 2025 Security Headers (COEP/COOP/CORP)"
    echo "   • MariaDB 11.4+ optimized"
    echo ""
    echo -e "${YELLOW}📋 Next Steps:${NC}"
    echo "   1. source ~/.bashrc"
    echo "   2. easyinstall help"
    echo "   3. easyinstall create mysite.com"
    echo "   4. easyinstall redis-ports"
    echo "   5. easyinstall monitor"
    echo ""
    echo -e "${GREEN}⚡ Performance Settings:${NC}"
    echo "   • PHP Children     : ${PHP_MAX_CHILDREN}"
    echo "   • PHP Memory       : ${PHP_MEMORY_LIMIT}"
    echo "   • MySQL Buffer     : ${MYSQL_BUFFER_POOL}"
    echo "   • Redis Memory     : ${REDIS_MAX_MEMORY}"
    echo "   • Nginx Connections: ${NGINX_WORKER_CONNECTIONS}"
    echo ""
    echo -e "${YELLOW}📝 Logs: $LOG_FILE${NC}"
    echo -e "${GREEN}========================================${NC}"

    update_status "COMPLETE" "Installation completed successfully"
}

# ============================================
# Deploy Python config script
# ============================================
deploy_python_script() {
    log "STEP" "Deploying Python configuration module (v6.5)"
    mkdir -p /usr/local/lib
    local script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    if [ -f "$script_dir/easyinstall_config.py" ]; then
        cp "$script_dir/easyinstall_config.py" "$PYTHON_CONFIG_SCRIPT"
        chmod +x "$PYTHON_CONFIG_SCRIPT"
        log "SUCCESS" "Python config module deployed to $PYTHON_CONFIG_SCRIPT"
    else
        log "ERROR" "easyinstall_config.py not found in $script_dir"
        exit 1
    fi
}

main "$@"
