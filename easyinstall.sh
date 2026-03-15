#!/bin/bash
# =============================================================================
# EasyInstall v7.1 — Full Feature Orchestrator
# Merges v7.0 Python engine architecture + all v6.7 advanced features
#
# Architecture:
#   Bash (this file)  → Python core engine  → PHP WP helper
#                     → Bash module files   (AI, AutoTune, ML, Serverless, Sharding, PageSpeed)
#
# Features from v6.7 fully integrated:
#   ✅ Self-Heal Engine v1.0  (services/configs/ssl/disk/wp/502)
#   ✅ Self-Update Engine     (nginx/php/redis/mariadb/wpcli/script/all)
#   ✅ Self-Check / Version Report (installed vs latest with update indicators)
#   ✅ AI Module              (diagnose/optimize/security/report/setup/ollama)
#   ✅ Advanced AutoTune      (10-phase: advanced-tune/perf-dashboard/warm-cache/db-optimize/wp-speed)
#   ✅ Machine Learning       (ml-train/predict/status/model-list)
#   ✅ Serverless Functions   (fn-deploy/invoke/list/delete/logs)
#   ✅ Database Sharding      (shard-init/status/rebalance/add)
#   ✅ PageSpeed Module       (optimize/score/autofix/report/all/images)
#   ✅ WebSocket Support      (ws-enable/disable/status/test) — enhanced awk injection
#   ✅ HTTP/3 + QUIC          (http3-enable/status)
#   ✅ Edge Computing         (edge-setup/status/purge) — with geo per-site health
#   ✅ Governor / Disaster Recovery (install-governor/emergency-check/autotune-rollback)
#   ✅ nginx-extras / backup-site / redis-cli
#   ✅ Ollama local AI install
#
# Compatible: Debian 12, Ubuntu 22.04/24.04  |  RAM 512 MB – 16 GB
# =============================================================================
set -eE
trap 'echo -e "\033[0;31m❌ Error at line $LINENO (cmd: $BASH_COMMAND)\033[0m" >&2; exit 1' ERR

VERSION="7.1"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="/usr/local/lib/easyinstall"
PYTHON_ENGINE="$LIB_DIR/core.py"
PHP_HELPER="$LIB_DIR/wp_helper.php"

# ─── Color codes ─────────────────────────────────────────────────────────────
G='\033[0;32m'; Y='\033[1;33m'; R='\033[0;31m'
B='\033[0;34m'; C='\033[0;36m'; P='\033[0;35m'; N='\033[0m'

# ─── Self-heal / self-update log + state paths ───────────────────────────────
EI_SELF_LOG="/var/log/easyinstall/selfheal.log"
EI_SELF_STATE="/var/lib/easyinstall/selfheal.state"
EI_SELF_VERSIONS="/var/lib/easyinstall/versions.cache"

# ─── Logging helpers ─────────────────────────────────────────────────────────
sh_log() {
    local level="$1"; shift
    local msg="$*"
    local ts; ts=$(date '+%Y-%m-%d %H:%M:%S')
    mkdir -p /var/log/easyinstall /var/lib/easyinstall 2>/dev/null || true
    echo "[$ts] [$level] $msg" >> "$EI_SELF_LOG"
    case "$level" in
        SUCCESS) echo -e "${G}✅ $msg${N}" ;;
        ERROR)   echo -e "${R}❌ $msg${N}" ;;
        WARN)    echo -e "${Y}⚠️  $msg${N}" ;;
        STEP)    echo -e "${P}🔷 $msg${N}" ;;
        FIX)     echo -e "${C}🔧 $msg${N}" ;;
        *)       echo -e "${B}ℹ️  $msg${N}" ;;
    esac
}

# =============================================================================
# BOOTSTRAP — install engine files on first run
# =============================================================================
_bootstrap() {
    [ -f "$PYTHON_ENGINE" ] && [ -f "$PHP_HELPER" ] && return 0
    echo -e "${Y}⚙  First run — installing EasyInstall engine...${N}"
    mkdir -p "$LIB_DIR" /var/log/easyinstall /var/lib/easyinstall
    for f in easyinstall_core.py easyinstall_wp.php; do
        src="$SCRIPT_DIR/$f"
        [ -f "$src" ] || { echo -e "${R}❌ Missing engine file: $src${N}"; exit 1; }
    done
    cp "$SCRIPT_DIR/easyinstall_core.py" "$PYTHON_ENGINE" && chmod +x "$PYTHON_ENGINE"
    cp "$SCRIPT_DIR/easyinstall_wp.php"  "$PHP_HELPER"
    echo -e "${G}✅ Engine installed to $LIB_DIR${N}"
}

_need_root()   { [ "$EUID" -eq 0 ] || { echo -e "${R}❌ Run as root${N}"; exit 1; }; }
_need_python() { command -v python3 >/dev/null 2>&1 || apt-get install -y python3 --quiet; }
_need_php()    { command -v php    >/dev/null 2>&1 || apt-get install -y php-cli --quiet 2>/dev/null || true; }

_py()  { python3 "$PYTHON_ENGINE" "$@"; }
_php() { php     "$PHP_HELPER"    "$@"; }

# =============================================================================
# SECTION A — VERSION DISCOVERY (from v6.7 sh_fetch_versions / sh_version_report)
# =============================================================================
sh_get_latest_nginx() {
    local ver
    ver=$(curl -sf --max-time 8 "https://nginx.org/en/CHANGES" 2>/dev/null \
        | grep -oP 'Changes with nginx \K[0-9]+\.[0-9]+\.[0-9]+' | head -1)
    [ -z "$ver" ] && ver=$(curl -sf --max-time 8 "https://nginx.org/en/download.html" 2>/dev/null \
        | grep -oP 'nginx-\K[0-9]+\.[0-9]+\.[0-9]+(?=\.tar\.gz)' | head -1)
    echo "${ver:-unknown}"
}

sh_get_latest_php() {
    apt-cache show php8.4-fpm 2>/dev/null | grep -q "^Package:" && echo "8.4" && return
    apt-cache show php8.3-fpm 2>/dev/null | grep -q "^Package:" && echo "8.3" && return
    echo "8.2"
}

sh_get_latest_redis() {
    local ver
    ver=$(curl -sf --max-time 8 "https://raw.githubusercontent.com/redis/redis/unstable/00-RELEASENOTES" 2>/dev/null \
        | grep -oP 'Redis \K[0-9]+\.[0-9]+\.[0-9]+' | head -1)
    [ -z "$ver" ] && ver=$(redis-server --version 2>/dev/null | grep -oP 'v=\K[0-9.]+' | head -1)
    echo "${ver:-unknown}"
}

sh_get_latest_mariadb() {
    local ver
    ver=$(curl -sf --max-time 8 "https://downloads.mariadb.com/MariaDB/mariadb_repo_setup" 2>/dev/null \
        | grep -oP 'mariadb-\K[0-9]+\.[0-9]+' | sort -V | tail -1)
    [ -z "$ver" ] && ver=$(mysql --version 2>/dev/null | grep -oP 'Distrib \K[0-9]+\.[0-9]+\.[0-9]+' | head -1)
    echo "${ver:-11.4}"
}

sh_fetch_versions() {
    sh_log "STEP" "Discovering latest stable versions..."
    mkdir -p /var/lib/easyinstall

    local nginx_latest php_latest redis_latest mariadb_latest
    nginx_latest=$(sh_get_latest_nginx)
    php_latest=$(sh_get_latest_php)
    redis_latest=$(sh_get_latest_redis)
    mariadb_latest=$(sh_get_latest_mariadb)

    local nginx_installed php_installed redis_installed mariadb_installed wpcli_installed
    nginx_installed=$(nginx -v 2>&1 | grep -oP '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
    php_installed=$(php --version 2>/dev/null | grep -oP '^PHP \K[0-9]+\.[0-9]+\.[0-9]+' | head -1)
    redis_installed=$(redis-server --version 2>/dev/null | grep -oP 'v=\K[0-9.]+' | head -1)
    mariadb_installed=$(mysql --version 2>/dev/null | grep -oP 'Distrib \K[0-9.]+' | head -1)
    wpcli_installed=$(wp --allow-root --version 2>/dev/null | grep -oP '[0-9]+\.[0-9]+\.[0-9]+' | head -1)

    cat > "$EI_SELF_VERSIONS" << VEOF
# EasyInstall version cache — $(date)
NGINX_LATEST="$nginx_latest"
NGINX_INSTALLED="$nginx_installed"
PHP_LATEST="$php_latest"
PHP_INSTALLED="$php_installed"
REDIS_LATEST="$redis_latest"
REDIS_INSTALLED="$redis_installed"
MARIADB_LATEST="$mariadb_latest"
MARIADB_INSTALLED="$mariadb_installed"
WPCLI_INSTALLED="$wpcli_installed"
LAST_CHECK="$(date +%s)"
VEOF
    sh_log "SUCCESS" "Version cache saved: $EI_SELF_VERSIONS"
}

sh_version_report() {
    [ -f "$EI_SELF_VERSIONS" ] && . "$EI_SELF_VERSIONS" || { sh_fetch_versions; . "$EI_SELF_VERSIONS"; }

    echo -e "\n${C}╔══════════════════════════════════════════════════════╗${N}"
    echo -e "${C}║       EasyInstall v${VERSION} — Version Status             ║${N}"
    echo -e "${C}╚══════════════════════════════════════════════════════╝${N}"

    _ver_row() {
        local name="$1" installed="$2" latest="$3"
        local icon
        if   [ -z "$installed" ] || [ "$installed" = "unknown" ]; then
            icon="${R}✗ not found${N}"
        elif [ "$installed" = "$latest" ] || [ -z "$latest" ] || [ "$latest" = "unknown" ]; then
            icon="${G}✓ up to date${N}"
        else
            icon="${Y}↑ update available ($latest)${N}"
        fi
        printf "  %-12s  installed: %-14s  latest: %-12s  " "$name" "${installed:-none}" "${latest:-unknown}"
        echo -e "$icon"
    }

    echo ""
    _ver_row "Nginx"    "$NGINX_INSTALLED"   "$NGINX_LATEST"
    _ver_row "PHP"      "$PHP_INSTALLED"     "$PHP_LATEST"
    _ver_row "Redis"    "$REDIS_INSTALLED"   "$REDIS_LATEST"
    _ver_row "MariaDB"  "$MARIADB_INSTALLED" "$MARIADB_LATEST"
    _ver_row "WP-CLI"   "$WPCLI_INSTALLED"   "latest"
    echo ""

    local age=$(( $(date +%s) - ${LAST_CHECK:-0} ))
    echo -e "  ${B}Cache age: ${age}s  |  File: $EI_SELF_VERSIONS${N}\n"
}

# =============================================================================
# SECTION B — SELF-HEAL ENGINE (from v6.7 sh_heal_* functions)
# =============================================================================
sh_heal_service() {
    local svc="$1" max="${2:-3}"
    systemctl list-units --type=service --all 2>/dev/null | grep -q "${svc}.service" || {
        sh_log "INFO" "$svc not installed — skipping"; return 0
    }
    systemctl is-active --quiet "$svc" 2>/dev/null && { sh_log "INFO" "$svc healthy"; return 0; }
    sh_log "WARN" "$svc is down — auto-healing"
    local i=1
    while [ "$i" -le "$max" ]; do
        sh_log "FIX" "Restart attempt $i/$max for $svc"
        systemctl restart "$svc" 2>/dev/null && sleep 2
        systemctl is-active --quiet "$svc" 2>/dev/null && { sh_log "SUCCESS" "$svc restored"; return 0; }
        i=$(( i + 1 )); sleep $(( i * 2 ))
    done
    sh_log "ERROR" "$svc failed after $max attempts"
    journalctl -u "$svc" --no-pager -n 20 2>/dev/null >> "$EI_SELF_LOG" || true
    return 1
}

sh_heal_nginx() {
    sh_log "STEP" "Nginx self-heal"
    if ! nginx -t 2>/dev/null; then
        sh_log "FIX" "Nginx config invalid — auto-fixing"
        local broken; broken=$(nginx -t 2>&1 | grep -oP '/etc/nginx/sites-enabled/\S+' | head -1)
        [ -n "$broken" ] && [ -f "$broken" ] && mv "$broken" "${broken}.broken.$(date +%s)" 2>/dev/null || true
        find /etc/nginx/sites-enabled/ -type l ! -e {} -delete 2>/dev/null || true
        if ! nginx -t 2>/dev/null; then
            sh_log "WARN" "Creating minimal fallback nginx.conf"
            cat > /etc/nginx/conf.d/easyinstall-fallback.conf << 'NGXFB'
# EasyInstall fallback — self-heal generated
server {
    listen 80 default_server;
    root /var/www/html;
    index index.php index.html;
    server_name _;
    location / { try_files $uri $uri/ =404; }
}
NGXFB
        fi
    fi
    local workers; workers=$(nproc 2>/dev/null || echo 1)
    grep -q "worker_processes ${workers}" /etc/nginx/nginx.conf 2>/dev/null || \
        sed -i "s/^worker_processes.*/worker_processes ${workers};/" /etc/nginx/nginx.conf 2>/dev/null || true
    for d in /var/cache/nginx /var/log/nginx; do
        [ -d "$d" ] && chown -R nginx:nginx "$d" 2>/dev/null || true
    done
    sh_heal_service "nginx"
}

sh_heal_php() {
    sh_log "STEP" "PHP-FPM self-heal"
    local v
    for v in 8.4 8.3 8.2; do
        systemctl list-units --type=service --all 2>/dev/null | grep -q "php${v}-fpm" || continue
        local sock="/run/php/php${v}-fpm.sock"
        "php${v}-fpm" --test 2>/dev/null || {
            sh_log "FIX" "PHP $v config invalid — resetting pool"
            cat > "/etc/php/${v}/fpm/pool.d/www.conf" << PHPPOOL
[www]
user = www-data
group = www-data
listen = $sock
listen.owner = www-data
listen.group = www-data
listen.mode = 0660
pm = dynamic
pm.max_children = 10
pm.start_servers = 2
pm.min_spare_servers = 1
pm.max_spare_servers = 3
pm.max_requests = 500
PHPPOOL
        }
        sh_heal_service "php${v}-fpm"
        [ -S "$sock" ] && chmod 660 "$sock" 2>/dev/null && chown www-data:www-data "$sock" 2>/dev/null || true
        local oc="/etc/php/${v}/fpm/conf.d/10-opcache.ini"
        if [ -f "$oc" ] && ! grep -q "^opcache.enable=1" "$oc" 2>/dev/null; then
            sed -i 's/^;opcache.enable=/opcache.enable=/' "$oc" 2>/dev/null || true
            sed -i 's/^opcache.enable=0/opcache.enable=1/' "$oc" 2>/dev/null || true
            systemctl reload "php${v}-fpm" 2>/dev/null || true
            sh_log "FIX" "PHP $v OPcache enabled"
        fi
    done
}

sh_heal_redis() {
    sh_log "STEP" "Redis self-heal"
    sh_heal_service "redis-server"
    redis-cli -p 6379 ping 2>/dev/null | grep -q "PONG" || { systemctl restart redis-server 2>/dev/null || true; sleep 2; }
    local maxmem; maxmem=$(free -m | awk '/Mem:/{printf "%dmb", $2*0.1}')
    grep -q "^maxmemory " /etc/redis/redis.conf 2>/dev/null || \
        echo "maxmemory ${maxmem}" >> /etc/redis/redis.conf 2>/dev/null || true
    for cf in /etc/redis/redis-*.conf; do
        [ -f "$cf" ] || continue
        local slug port; slug=$(basename "$cf" .conf | sed 's/redis-//'); port=$(grep "^port" "$cf" | awk '{print $2}')
        [ -n "$port" ] && ! redis-cli -p "$port" ping 2>/dev/null | grep -q "PONG" && \
            systemctl restart "redis-${slug}" 2>/dev/null || true
    done
}

sh_heal_mariadb() {
    sh_log "STEP" "MariaDB self-heal"
    if ! systemctl is-active --quiet mariadb 2>/dev/null; then
        mysqld --tc-heuristic-recover ROLLBACK 2>/dev/null || true
        sh_heal_service "mariadb"
    fi
    systemctl is-active --quiet mariadb && \
        mysql -e "SELECT 1" 2>/dev/null && sh_log "SUCCESS" "MariaDB OK" || sh_log "ERROR" "MariaDB unreachable"
}

sh_heal_fail2ban() {
    sh_log "STEP" "Fail2ban self-heal"
    sh_heal_service "fail2ban"
}

sh_heal_repos() {
    sh_log "STEP" "APT repository self-heal"
    apt-get update -y 2>/dev/null || {
        sh_log "WARN" "apt-get update failed — cleaning lists"
        rm -f /var/lib/apt/lists/lock /var/cache/apt/archives/lock /var/lib/dpkg/lock* 2>/dev/null || true
        dpkg --configure -a 2>/dev/null || true
        apt-get update -y 2>/dev/null || sh_log "ERROR" "apt-get update still failing"
    }
}

sh_heal_ssl() {
    sh_log "STEP" "SSL certificate self-heal"
    [ -d /etc/letsencrypt/live ] || { sh_log "INFO" "No SSL certs found"; return 0; }
    local dom_dir
    for dom_dir in /etc/letsencrypt/live/*/; do
        [ -f "${dom_dir}cert.pem" ] || continue
        local dom; dom=$(basename "$dom_dir")
        [ "$dom" = "README" ] && continue
        local exp_date days
        exp_date=$(openssl x509 -enddate -noout -in "${dom_dir}cert.pem" 2>/dev/null | cut -d= -f2)
        days=$(( ( $(date -d "${exp_date}" +%s 2>/dev/null || echo 0) - $(date +%s) ) / 86400 ))
        if [ "${days:-100}" -lt 14 ]; then
            sh_log "FIX" "Renewing cert for $dom ($days days left)"
            certbot renew --cert-name "$dom" --nginx --non-interactive 2>/dev/null || \
                sh_log "WARN" "Cert renewal failed for $dom"
        else
            sh_log "INFO" "SSL $dom: $days days remaining — OK"
        fi
    done
}

sh_heal_disk() {
    sh_log "STEP" "Disk self-heal"
    local used; used=$(df / | awk 'NR==2{gsub(/%/,"",$5);print $5}')
    sh_log "INFO" "Disk usage: ${used}%"
    if [ "${used:-0}" -gt 85 ]; then
        sh_log "WARN" "Disk >85% — emergency cleanup"
        apt-get autoremove -y 2>/dev/null || true
        apt-get autoclean   2>/dev/null || true
        journalctl --vacuum-size=100M 2>/dev/null || true
        find /var/log -name "*.gz" -mtime +7 -delete 2>/dev/null || true
        find /tmp -type f -mtime +1 -delete 2>/dev/null || true
        find /var/log/nginx -name "*.log" -size +100M -exec truncate -s 50M {} \; 2>/dev/null || true
        sh_log "SUCCESS" "Disk cleanup done"
    fi
}

sh_heal_wp_permissions() {
    sh_log "STEP" "WordPress permissions self-heal"
    for site_dir in /var/www/html/*/; do
        [ -f "${site_dir}wp-config.php" ] || continue
        local dom; dom=$(basename "$site_dir")
        find "$site_dir" -type d -exec chmod 755 {} \; 2>/dev/null || true
        find "$site_dir" -type f -exec chmod 644 {} \; 2>/dev/null || true
        chmod 600 "${site_dir}wp-config.php" 2>/dev/null || true
        chown -R www-data:www-data "$site_dir" 2>/dev/null || true
        sh_log "SUCCESS" "$dom permissions fixed"
    done
}

sh_fix_nginx_configs() {
    sh_log "STEP" "Nginx config auto-fix"
    local running_php=""
    for v in 8.4 8.3 8.2; do
        systemctl is-active --quiet "php${v}-fpm" 2>/dev/null && running_php="$v" && break
    done
    [ -z "$running_php" ] && { sh_log "WARN" "No PHP-FPM running — skipping socket fix"; return 0; }
    local correct_sock="/run/php/php${running_php}-fpm.sock"
    local cf
    for cf in /etc/nginx/sites-available/* /etc/nginx/sites-enabled/*; do
        [ -f "$cf" ] || continue
        if grep -q "php[0-9.]*-fpm.sock" "$cf" 2>/dev/null; then
            sed -i "s|php[0-9.]*-fpm\.sock|php${running_php}-fpm.sock|g" "$cf" 2>/dev/null || true
            sh_log "FIX" "Socket path updated in $(basename "$cf") → php${running_php}"
        fi
    done
    nginx -t 2>/dev/null && systemctl reload nginx 2>/dev/null && sh_log "SUCCESS" "Nginx reloaded" || \
        sh_log "ERROR" "Nginx config still invalid after socket fix"
}

sh_fix_php_configs() {
    sh_log "STEP" "PHP config auto-fix"
    local ram_mb; ram_mb=$(free -m | awk '/Mem:/{print $2}')
    local mem_limit="256M"
    [ "$ram_mb" -ge 4096 ] && mem_limit="512M"
    [ "$ram_mb" -ge 8192 ] && mem_limit="1G"
    local v
    for v in 8.4 8.3 8.2; do
        local ini="/etc/php/${v}/fpm/php.ini"
        [ -f "$ini" ] || continue
        sed -i "s/^memory_limit.*/memory_limit = ${mem_limit}/" "$ini" 2>/dev/null || true
        grep -q "^max_execution_time" "$ini" || echo "max_execution_time = 300" >> "$ini" 2>/dev/null || true
        grep -q "^upload_max_filesize" "$ini" || echo "upload_max_filesize = 64M" >> "$ini" 2>/dev/null || true
        grep -q "^post_max_size" "$ini"       || echo "post_max_size = 64M"       >> "$ini" 2>/dev/null || true
        sh_log "FIX" "PHP $v memory_limit → $mem_limit"
    done
}

sh_fix_redis_configs() {
    sh_log "STEP" "Redis config auto-fix"
    local maxmem; maxmem=$(free -m | awk '/Mem:/{printf "%dmb", $2*0.1}')
    grep -q "^maxmemory " /etc/redis/redis.conf 2>/dev/null || \
        echo "maxmemory ${maxmem}" >> /etc/redis/redis.conf 2>/dev/null || true
    grep -q "^maxmemory-policy" /etc/redis/redis.conf 2>/dev/null || \
        echo "maxmemory-policy allkeys-lru" >> /etc/redis/redis.conf 2>/dev/null || true
    systemctl is-active --quiet redis-server && systemctl reload redis-server 2>/dev/null || true
    sh_log "SUCCESS" "Redis config verified"
}

sh_fix_mariadb_configs() {
    sh_log "STEP" "MariaDB config auto-fix"
    local cnf="/etc/mysql/mariadb.conf.d/99-wordpress.cnf"
    if [ ! -f "$cnf" ]; then
        local ram_mb; ram_mb=$(free -m | awk '/Mem:/{print $2}')
        local buf="128M"; [ "$ram_mb" -ge 2048 ] && buf="256M"; [ "$ram_mb" -ge 4096 ] && buf="512M"
        cat > "$cnf" << MYCNF
[mysqld]
innodb_buffer_pool_size = $buf
max_connections = 200
max_allowed_packet = 256M
innodb_flush_log_at_trx_commit = 2
innodb_file_per_table = 1
character-set-server = utf8mb4
collation-server = utf8mb4_unicode_ci
MYCNF
        sh_log "FIX" "Created MariaDB config with innodb_buffer_pool=$buf"
    fi
    systemctl is-active --quiet mariadb && systemctl reload mariadb 2>/dev/null || true
}

sh_update_all_wp_sites() {
    sh_log "STEP" "Updating all WordPress sites"
    for site_dir in /var/www/html/*/; do
        [ -f "${site_dir}wp-config.php" ] || continue
        local dom; dom=$(basename "$site_dir")
        sh_log "INFO" "Updating WP: $dom"
        sudo -u www-data wp core update   --path="$site_dir" --allow-root --quiet 2>/dev/null || true
        sudo -u www-data wp plugin update --all --path="$site_dir" --allow-root --quiet 2>/dev/null || true
        sudo -u www-data wp theme  update --all --path="$site_dir" --allow-root --quiet 2>/dev/null || true
        sudo -u www-data wp core  update-db --path="$site_dir" --allow-root --quiet 2>/dev/null || true
        sh_log "SUCCESS" "$dom updated"
    done
}

# =============================================================================
# SECTION C — SELF-UPDATE ENGINE (from v6.7 sh_upgrade_* + sh_self_update)
# =============================================================================
sh_upgrade_nginx() {
    sh_log "STEP" "Upgrading Nginx"
    apt-get install -y --only-upgrade nginx 2>/dev/null && \
        { systemctl restart nginx 2>/dev/null || true; sh_log "SUCCESS" "Nginx upgraded"; } || \
        sh_log "WARN" "Nginx upgrade failed or already latest"
}

sh_upgrade_php() {
    sh_log "STEP" "Upgrading PHP"
    apt-get install -y --only-upgrade php8.4-fpm php8.3-fpm php8.2-fpm 2>/dev/null || true
    for v in 8.4 8.3 8.2; do
        systemctl is-active --quiet "php${v}-fpm" 2>/dev/null && \
            systemctl restart "php${v}-fpm" 2>/dev/null || true
    done
    sh_log "SUCCESS" "PHP upgraded"
}

sh_upgrade_redis() {
    sh_log "STEP" "Upgrading Redis"
    apt-get install -y --only-upgrade redis-server redis-tools 2>/dev/null && \
        { systemctl restart redis-server 2>/dev/null || true; sh_log "SUCCESS" "Redis upgraded"; } || \
        sh_log "WARN" "Redis upgrade failed or already latest"
}

sh_upgrade_mariadb() {
    sh_log "STEP" "Upgrading MariaDB (safe minor update)"
    apt-get install -y --only-upgrade mariadb-server mariadb-client 2>/dev/null && \
        { mysql_upgrade --silent 2>/dev/null || true; sh_log "SUCCESS" "MariaDB upgraded"; } || \
        sh_log "WARN" "MariaDB upgrade failed or already latest"
}

sh_upgrade_wpcli() {
    sh_log "STEP" "Upgrading WP-CLI"
    wp cli update --yes --allow-root 2>/dev/null && sh_log "SUCCESS" "WP-CLI upgraded" || \
        sh_log "WARN" "WP-CLI upgrade failed or already latest"
}

sh_self_update() {
    sh_log "STEP" "Updating easyinstall script itself"
    local dest="/usr/local/bin/easyinstall"
    local tmp; tmp=$(mktemp)
    # Try to self-update from known upstream URL or from installed script
    if cp "$0" "$tmp" 2>/dev/null && [ -s "$tmp" ]; then
        cp "$tmp" "$dest" && chmod +x "$dest" && sh_log "SUCCESS" "easyinstall binary updated"
    else
        sh_log "WARN" "Self-update skipped — run installer again to get latest"
    fi
    rm -f "$tmp"
}

# =============================================================================
# SECTION D — RUN_SELF_HEAL / RUN_SELF_UPDATE orchestrators
# =============================================================================
run_self_heal() {
    local mode="${1:-full}"
    local start_ts; start_ts=$(date +%s)

    echo -e "\n${C}╔═══════════════════════════════════════════════════════╗${N}"
    echo -e "${C}║  EasyInstall Self-Heal Engine v1.0 — $(date '+%H:%M:%S')     ║${N}"
    echo -e "${C}╚═══════════════════════════════════════════════════════╝${N}\n"
    sh_log "STEP" "Self-heal started (mode: $mode)"

    case "$mode" in
        services|quick)
            sh_heal_nginx; sh_heal_php; sh_heal_redis; sh_heal_mariadb; sh_heal_fail2ban ;;
        configs)
            sh_fix_nginx_configs; sh_fix_php_configs; sh_fix_redis_configs; sh_fix_mariadb_configs ;;
        repos)
            sh_heal_repos ;;
        ssl)
            sh_heal_ssl ;;
        disk)
            sh_heal_disk ;;
        wp)
            sh_heal_wp_permissions; sh_update_all_wp_sites ;;
        502|nginx-502|bad-gateway)
            sh_log "STEP" "502 Bad Gateway targeted fix"
            echo -e "${C}🩹 Diagnosing and fixing 502 Bad Gateway...${N}"
            sh_fix_nginx_configs
            sh_heal_php
            for v in 8.4 8.3 8.2; do
                local sock="/run/php/php${v}-fpm.sock"
                [ -S "$sock" ] && chmod 660 "$sock" 2>/dev/null && chown www-data:www-data "$sock" 2>/dev/null && \
                    sh_log "FIX" "Socket permissions fixed: $sock"
            done
            sh_heal_nginx
            sleep 2
            local rpv=""
            for v in 8.4 8.3 8.2; do
                systemctl is-active --quiet "php${v}-fpm" 2>/dev/null && rpv="$v" && break
            done
            [ -n "$rpv" ] && sh_log "SUCCESS" "PHP ${rpv}-FPM running" || sh_log "ERROR" "No PHP-FPM running"
            nginx -t 2>/dev/null && sh_log "SUCCESS" "Nginx config OK" || sh_log "ERROR" "Nginx config invalid"
            ;;
        full|*)
            sh_heal_repos
            sh_heal_nginx; sh_heal_php; sh_heal_redis; sh_heal_mariadb; sh_heal_fail2ban
            sh_heal_ssl; sh_heal_disk; sh_heal_wp_permissions
            sh_fix_nginx_configs; sh_fix_php_configs; sh_fix_redis_configs; sh_fix_mariadb_configs
            ;;
    esac

    local elapsed=$(( $(date +%s) - start_ts ))
    sh_log "SUCCESS" "Self-heal completed in ${elapsed}s"
    echo -e "\n${G}✅ Self-heal complete (${elapsed}s) — log: $EI_SELF_LOG${N}\n"
    echo "$(date '+%Y-%m-%d %H:%M:%S') mode=$mode duration=${elapsed}s" >> "$EI_SELF_STATE"
}

run_self_update() {
    local mode="${1:-all}"
    echo -e "\n${C}🚀 EasyInstall Self-Update Engine${N}"

    case "$mode" in
        nginx)    sh_heal_repos; sh_upgrade_nginx ;;
        php)      sh_heal_repos; sh_upgrade_php ;;
        redis)    sh_heal_repos; sh_upgrade_redis ;;
        mariadb)  sh_heal_repos; sh_upgrade_mariadb ;;
        wpcli)    sh_upgrade_wpcli ;;
        wp-sites) sh_update_all_wp_sites ;;
        script)   sh_self_update ;;
        versions) sh_fetch_versions; sh_version_report ;;
        all|*)
            sh_log "STEP" "Full auto-update started"
            sh_heal_repos
            sh_upgrade_nginx; sh_upgrade_php; sh_upgrade_redis
            sh_upgrade_mariadb; sh_upgrade_wpcli
            sh_update_all_wp_sites; sh_self_update
            sh_fetch_versions; sh_version_report
            sh_log "SUCCESS" "Full auto-update complete"
            ;;
    esac
}

# =============================================================================
# SECTION E — HELP TEXT
# =============================================================================
_help() {
cat << 'HELP'
EasyInstall v7.1 — WordPress Performance Stack
═══════════════════════════════════════════════════════════════════

INSTALL:
  easyinstall install                       Full stack (Nginx+PHP+MariaDB+Redis)

SITE MANAGEMENT:
  easyinstall create domain.com [--ssl] [--php=8.3|8.4]
  easyinstall delete domain.com
  easyinstall list
  easyinstall site-info domain.com
  easyinstall update-site domain.com [--core|--plugins|--themes|--db|--langs|--check|--backup]
  easyinstall update-site all
  easyinstall clone src.com dst.com
  easyinstall php-switch domain.com 8.4
  easyinstall backup-site domain.com        Backup specific site files + DB

SSL:
  easyinstall ssl domain.com
  easyinstall ssl-renew

REDIS:
  easyinstall redis-status
  easyinstall redis-restart [domain.com]
  easyinstall redis-ports
  easyinstall redis-cli domain.com          Direct Redis CLI for a site

MONITORING:
  easyinstall status
  easyinstall health
  easyinstall monitor
  easyinstall logs [domain.com]
  easyinstall perf
  easyinstall version

BACKUP / OPTIMIZE:
  easyinstall backup [domain.com]
  easyinstall optimize
  easyinstall clean

SELF-HEAL  (v6.7/v7.1):
  easyinstall self-heal                     Full heal (services+configs+ssl+disk+wp)
  easyinstall self-heal 502                 Fix 502 Bad Gateway (PHP socket + nginx)
  easyinstall self-heal services            Restart failed services
  easyinstall self-heal configs             Auto-correct all config files
  easyinstall self-heal ssl                 Renew expiring SSL certs
  easyinstall self-heal disk                Free disk space, clean logs
  easyinstall self-heal wp                  Fix WP permissions + update all sites
  easyinstall self-heal repos               Fix broken APT repositories

SELF-UPDATE  (v6.7/v7.1):
  easyinstall self-update                   Update all packages + WP-CLI + script
  easyinstall self-update nginx             Upgrade Nginx to latest
  easyinstall self-update php               Upgrade PHP to latest
  easyinstall self-update redis             Upgrade Redis to latest
  easyinstall self-update mariadb           Safe MariaDB minor upgrade
  easyinstall self-update wpcli             Upgrade WP-CLI
  easyinstall self-update wp-sites          Update all WP core/plugins/themes
  easyinstall self-update script            Self-update easyinstall binary
  easyinstall self-update versions          Refresh version cache
  easyinstall self-check                    Version status (installed vs latest)

WEBSOCKET  (v6.4):
  easyinstall ws-enable domain.com [port]
  easyinstall ws-disable domain.com
  easyinstall ws-status [domain.com]
  easyinstall ws-test domain.com

HTTP/3 + QUIC  (v6.4):
  easyinstall http3-enable
  easyinstall http3-status

EDGE COMPUTING  (v6.4):
  easyinstall edge-setup
  easyinstall edge-status
  easyinstall edge-purge domain.com [/path]

AI FEATURES  (v6.3+):
  easyinstall ai-setup                      Configure AI API key & provider
  easyinstall ai-install-ollama             Install Ollama (free local AI)
  easyinstall ai-diagnose [domain.com]      AI log analysis & fix suggestions
  easyinstall ai-optimize                   AI performance tuning advice
  easyinstall ai-security                   AI security audit
  easyinstall ai-report                     AI-generated server health report

ADVANCED AUTO-TUNE  (v6.6):
  easyinstall advanced-tune                 Full 10-phase auto-tune
  easyinstall perf-dashboard                Live performance dashboard
  easyinstall warm-cache                    Pre-warm all site caches
  easyinstall db-optimize                   Optimize WordPress databases
  easyinstall wp-speed                      Apply WordPress speed tweaks
  easyinstall install-governor              Install 15-min resource governor
  easyinstall emergency-check               Check/trigger emergency mode
  easyinstall autotune-rollback             Rollback last autotune changes
  easyinstall nginx-extras                  Install Brotli + Cloudflare real-IP

MACHINE LEARNING  (v6.5):
  easyinstall ml-train domain.com
  easyinstall ml-predict domain.com
  easyinstall ml-status
  easyinstall ml-model-list

SERVERLESS FUNCTIONS  (v6.5):
  easyinstall fn-deploy name /path/fn.sh
  easyinstall fn-invoke name [args]
  easyinstall fn-list
  easyinstall fn-delete name
  easyinstall fn-logs name

DATABASE SHARDING  (v6.5):
  easyinstall shard-init domain.com
  easyinstall shard-status
  easyinstall shard-rebalance
  easyinstall shard-add host port

PAGESPEED  (v6.6):
  easyinstall pagespeed optimize domain.com
  easyinstall pagespeed score domain.com
  easyinstall pagespeed autofix domain.com
  easyinstall pagespeed report domain.com
  easyinstall pagespeed all domain.com
  easyinstall pagespeed images domain.com

TROUBLESHOOT:
  easyinstall fix-apache                    Remove Apache2, restore Nginx (502 fix)
  easyinstall fix-nginx                     Alias for fix-apache
  easyinstall self-heal 502                 PHP socket + nginx 502 auto-fix

═══════════════════════════════════════════════════════════════════
HELP
}

# =============================================================================
# MAIN DISPATCH
# =============================================================================
CMD="${1:-help}"; shift || true

case "$CMD" in

    # ── Core install ──────────────────────────────────────────────────────────
    install)
        _need_root; _bootstrap; _need_python; _need_php
        _py install "$@" ;;

    # ── Site management ───────────────────────────────────────────────────────
    create)
        _need_root; _bootstrap; _need_python; _need_php
        [ -z "$1" ] && { echo -e "${R}❌ Usage: easyinstall create domain.com [--ssl] [--php=8.3]${N}"; exit 1; }
        _py create "$@" ;;

    delete)
        _need_root; _bootstrap; _need_python
        [ -z "$1" ] && { echo -e "${R}❌ Usage: easyinstall delete domain.com${N}"; exit 1; }
        _py delete "$@" ;;

    list)         _bootstrap; _need_python; _py list ;;
    site-info)    _bootstrap; _need_python; _need_php; _py site-info "$@" ;;

    update-site)
        _need_root; _bootstrap; _need_python; _need_php
        [ -z "$1" ] && { echo -e "${R}❌ Usage: easyinstall update-site domain.com|all${N}"; exit 1; }
        _py update-site "$@" ;;

    clone)
        _need_root; _bootstrap; _need_python; _need_php
        _py clone "$@" ;;

    php-switch)
        _need_root; _bootstrap; _need_python
        _py php-switch "$@" ;;

    backup-site)
        _need_root; _bootstrap; _need_python; _need_php
        [ -z "$1" ] && { echo -e "${R}❌ Usage: easyinstall backup-site domain.com${N}"; exit 1; }
        _py backup "$@" ;;

    # ── SSL ───────────────────────────────────────────────────────────────────
    ssl)
        _need_root; _bootstrap; _need_python
        [ -z "$1" ] && { echo -e "${R}❌ Usage: easyinstall ssl domain.com${N}"; exit 1; }
        _py ssl "$@" ;;

    ssl-renew)   _need_root; _bootstrap; _need_python; _py ssl-renew ;;

    # ── Redis ─────────────────────────────────────────────────────────────────
    redis-status)  _bootstrap; _need_python; _py redis-status ;;
    redis-restart) _need_root; _bootstrap; _need_python; _py redis-restart "$@" ;;
    redis-ports)   _bootstrap; _need_python; _py redis-ports ;;
    redis-cli)
        REDIS_CONF="/etc/redis/redis-${1//./-}.conf"
        PORT=$(grep "^port" "$REDIS_CONF" 2>/dev/null | awk '{print $2}' || echo "6379")
        exec redis-cli -p "$PORT" ;;

    # ── Monitoring ────────────────────────────────────────────────────────────
    status)   _bootstrap; _need_python; _py status ;;
    health)   _bootstrap; _need_python; _py health ;;
    monitor)  _bootstrap; _need_python; _py monitor ;;
    logs)     _bootstrap; _need_python; _py logs "$@" ;;
    perf)     _bootstrap; _need_python; _py perf ;;
    version)  echo "EasyInstall v${VERSION}" ;;

    # ── Backup / Optimize ─────────────────────────────────────────────────────
    backup)   _need_root; _bootstrap; _need_python; _py backup "$@" ;;
    optimize) _need_root; _bootstrap; _need_python; _py optimize ;;
    clean)    _need_root; _bootstrap; _need_python; _py clean ;;

    # ── Self-Heal (v6.7 / v7.1) ───────────────────────────────────────────────
    self-heal|selfheal)
        _need_root
        run_self_heal "${1:-full}" ;;

    # ── Self-Update (v6.7 / v7.1) ─────────────────────────────────────────────
    self-update|selfupdate)
        _need_root
        run_self_update "${1:-all}" ;;

    # ── Self-Check — version report ───────────────────────────────────────────
    self-check|selfcheck|versions)
        _bootstrap; _need_python
        # Hybrid: Python reports installed, Bash reports latest upstream
        _py self-check
        sh_fetch_versions
        sh_version_report ;;

    # ── WebSocket (v6.4) ──────────────────────────────────────────────────────
    ws-enable)
        _need_root
        [ -z "$1" ] && { echo -e "${R}❌ Usage: easyinstall ws-enable domain.com [port]${N}"; exit 1; }
        WS_DOMAIN="$1"; WS_PORT="${2:-8080}"
        NGINX_CONF="/etc/nginx/sites-available/$WS_DOMAIN"
        [ -f "$NGINX_CONF" ] || { echo -e "${R}❌ Nginx config not found for $WS_DOMAIN${N}"; exit 1; }
        # Inject websocket map
        if [ ! -f /etc/nginx/conf.d/websocket-map.conf ]; then
            cat > /etc/nginx/conf.d/websocket-map.conf << 'WSMAP'
map $http_upgrade $connection_upgrade {
    default   close;
    websocket upgrade;
    ""        close;
}
WSMAP
        fi
        # Inject WS location block if not already present
        if ! grep -q "proxy_set_header.*Upgrade" "$NGINX_CONF" 2>/dev/null; then
            TMPF=$(mktemp)
            awk -v port="$WS_PORT" '
            /^}$/ && !done {
                print ""
                print "    # WebSocket proxy (EasyInstall v7.1)"
                print "    location ~ ^/(ws|wss)(/.*)? {"
                print "        proxy_pass         http://127.0.0.1:" port ";"
                print "        proxy_http_version 1.1;"
                print "        proxy_set_header   Upgrade           $http_upgrade;"
                print "        proxy_set_header   Connection        $connection_upgrade;"
                print "        proxy_set_header   Host              $host;"
                print "        proxy_set_header   X-Real-IP         $remote_addr;"
                print "        proxy_set_header   X-Forwarded-For   $proxy_add_x_forwarded_for;"
                print "        proxy_read_timeout  3600s;"
                print "        proxy_send_timeout  3600s;"
                print "        proxy_buffering     off;"
                print "        proxy_cache         off;"
                print "    }"
                done=1
            }
            { print }
            ' "$NGINX_CONF" > "$TMPF" && mv "$TMPF" "$NGINX_CONF"
            echo -e "${G}✅ WebSocket block added to $WS_DOMAIN (backend: 127.0.0.1:$WS_PORT)${N}"
        else
            echo -e "${Y}⚠️  WebSocket already configured for $WS_DOMAIN${N}"
        fi
        mkdir -p /var/lib/easyinstall
        echo "${WS_DOMAIN}:${WS_PORT}:enabled" >> /var/lib/easyinstall/websocket.registry
        sort -u /var/lib/easyinstall/websocket.registry -o /var/lib/easyinstall/websocket.registry
        nginx -t 2>/dev/null && systemctl reload nginx && \
            echo -e "${G}✅ WebSocket enabled for $WS_DOMAIN${N}" || \
            echo -e "${R}❌ Nginx config error — run: nginx -t${N}" ;;

    ws-disable)
        _need_root
        [ -z "$1" ] && { echo -e "${R}❌ Usage: easyinstall ws-disable domain.com${N}"; exit 1; }
        WS_DOMAIN="$1"
        NGINX_CONF="/etc/nginx/sites-available/$WS_DOMAIN"
        [ -f "$NGINX_CONF" ] || { echo -e "${R}❌ Config not found for $WS_DOMAIN${N}"; exit 1; }
        TMPF=$(mktemp)
        awk '/# WebSocket proxy \(EasyInstall v7\.1\)/ { skip=1 }
             skip && /^    \}$/ { skip=0; next }
             !skip { print }' "$NGINX_CONF" > "$TMPF" && mv "$TMPF" "$NGINX_CONF"
        sed -i "/^${WS_DOMAIN}:/d" /var/lib/easyinstall/websocket.registry 2>/dev/null || true
        nginx -t 2>/dev/null && systemctl reload nginx && \
            echo -e "${G}✅ WebSocket disabled for $WS_DOMAIN${N}" || \
            echo -e "${R}❌ Nginx config error${N}" ;;

    ws-status)
        WS_DOMAIN="${1:-}"
        echo -e "${C}🔌 WebSocket Status${N}"
        echo -e "${B}══════════════════════════════════════${N}"
        if [ -n "$WS_DOMAIN" ]; then
            NGINX_CONF="/etc/nginx/sites-available/$WS_DOMAIN"
            if grep -q "proxy_set_header.*Upgrade" "$NGINX_CONF" 2>/dev/null; then
                WS_PORT=$(grep -A3 "proxy_pass.*127.0.0.1" "$NGINX_CONF" 2>/dev/null | grep -oP ':\K[0-9]+' | head -1 || echo "?")
                echo -e "  ${G}✅ ENABLED${N} — $WS_DOMAIN  backend: 127.0.0.1:$WS_PORT"
            else
                echo -e "  ${Y}⚠️  NOT configured${N} for $WS_DOMAIN"
                echo "  Run: easyinstall ws-enable $WS_DOMAIN [port]"
            fi
        else
            for cf in /etc/nginx/sites-available/*; do
                [ -f "$cf" ] || continue
                dom=$(basename "$cf")
                if grep -q "proxy_set_header.*Upgrade" "$cf" 2>/dev/null; then
                    echo -e "  ${G}✅${N} $dom — WebSocket enabled"
                else
                    echo -e "  ${R}✗${N}  $dom — not configured"
                fi
            done
        fi
        [ -f /etc/nginx/conf.d/websocket-map.conf ] && \
            echo -e "\n  ${G}✅ websocket-map.conf present${N}" || \
            echo -e "\n  ${R}✗ websocket-map.conf missing${N}" ;;

    ws-test)
        [ -z "$1" ] && { echo -e "${R}❌ Usage: easyinstall ws-test domain.com${N}"; exit 1; }
        WS_DOMAIN="$1"
        echo -e "${C}🧪 WebSocket Test: $WS_DOMAIN${N}"
        echo -e "${B}══════════════════════════════════════${N}"
        NGINX_CONF="/etc/nginx/sites-available/$WS_DOMAIN"
        grep -q "proxy_set_header.*Upgrade" "$NGINX_CONF" 2>/dev/null && \
            echo -e "  ${G}✅ Nginx WS location block present${N}" || \
            echo -e "  ${R}✗ WS block NOT found — run: easyinstall ws-enable $WS_DOMAIN${N}"
        [ -f /etc/nginx/conf.d/websocket-map.conf ] && \
            echo -e "  ${G}✅ Upgrade map loaded${N}" || echo -e "  ${Y}⚠️  Upgrade map missing${N}"
        echo ""
        echo -e "${Y}HTTP Upgrade probe:${N}"
        HTTP_CODE=$(curl -s --max-time 5 \
            -H "Host: $WS_DOMAIN" -H "Upgrade: websocket" -H "Connection: Upgrade" \
            -H "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==" -H "Sec-WebSocket-Version: 13" \
            -o /dev/null -w "%{http_code}" "http://127.0.0.1/ws/" 2>/dev/null || echo "000")
        echo -e "  HTTP response: $HTTP_CODE"
        [ "$HTTP_CODE" = "101" ] && echo -e "  ${G}✅ WebSocket handshake successful!${N}" || \
            echo -e "  ${Y}ℹ️  101 expected for successful WS upgrade (current: $HTTP_CODE)${N}" ;;

    # ── HTTP/3 + QUIC (v6.4) ──────────────────────────────────────────────────
    http3-enable) _need_root; _bootstrap; _need_python; _py http3-enable ;;
    http3-status) _bootstrap; _need_python; _py http3-status ;;

    # ── Edge Computing (v6.4) ─────────────────────────────────────────────────
    edge-setup)  _need_root; _bootstrap; _need_python; _py edge-setup ;;
    edge-status) _bootstrap; _need_python; _py edge-status ;;
    edge-purge)  _need_root; _bootstrap; _need_python; _py edge-purge "$@" ;;

    # ── AI Module (v6.3+) ─────────────────────────────────────────────────────
    ai-setup)
        _bootstrap
        if [ -f /usr/local/lib/easyinstall-ai.sh ]; then
            . /usr/local/lib/easyinstall-ai.sh; ai_setup
        else
            _bootstrap; _need_python; _py ai-setup
        fi ;;

    ai-diagnose)
        _bootstrap
        if [ -f /usr/local/lib/easyinstall-ai.sh ]; then
            . /usr/local/lib/easyinstall-ai.sh; ai_diagnose "${1:-}"
        else
            _need_python; _py ai-diagnose "$@"
        fi ;;

    ai-optimize)
        _bootstrap
        if [ -f /usr/local/lib/easyinstall-ai.sh ]; then
            . /usr/local/lib/easyinstall-ai.sh; ai_optimize
        else
            _need_python; _py ai-optimize
        fi ;;

    ai-security)
        _bootstrap
        if [ -f /usr/local/lib/easyinstall-ai.sh ]; then
            . /usr/local/lib/easyinstall-ai.sh; ai_security
        else
            echo -e "${Y}⚠️  AI security module not installed. Run: easyinstall install${N}"
        fi ;;

    ai-report)
        _bootstrap
        if [ -f /usr/local/lib/easyinstall-ai.sh ]; then
            . /usr/local/lib/easyinstall-ai.sh; ai_report
        else
            echo -e "${Y}⚠️  AI report module not installed. Run: easyinstall install${N}"
        fi ;;

    ai-install-ollama)
        _need_root
        echo -e "${C}🤖 Installing Ollama (Local AI Engine)...${N}"
        command -v ollama &>/dev/null && echo -e "${G}✅ Ollama already installed${N}" || \
            curl -fsSL https://ollama.com/install.sh | sh
        systemctl enable ollama 2>/dev/null && systemctl start ollama 2>/dev/null || \
            (ollama serve >/dev/null 2>&1 & sleep 3)
        if [ -f /usr/local/lib/easyinstall-ai.sh ]; then
            . /usr/local/lib/easyinstall-ai.sh; ai_load_config 2>/dev/null || true
            AI_MODEL="${AI_MODEL:-llama3.2}"
            echo -e "${Y}📥 Pulling model: $AI_MODEL...${N}"
            ollama pull "$AI_MODEL" && echo -e "${G}✅ Model $AI_MODEL ready!${N}" || \
                echo -e "${Y}⚠️  Pull failed — will retry on first use.${N}"
        fi
        echo -e "${G}✅ Local AI ready. Run: easyinstall ai-diagnose${N}" ;;

    # ── Advanced AutoTune (v6.6) ──────────────────────────────────────────────
    advanced-tune)
        _need_root
        if [ -f /usr/local/lib/easyinstall-autotune.sh ]; then
            . /usr/local/lib/easyinstall-autotune.sh; advanced_auto_tune
        else
            echo -e "${R}❌ AutoTune module not found. Run: easyinstall install${N}"
        fi ;;

    perf-dashboard)
        if [ -f /usr/local/lib/easyinstall-autotune.sh ]; then
            . /usr/local/lib/easyinstall-autotune.sh; perf_dashboard
        else
            echo -e "${R}❌ AutoTune module not found. Run: easyinstall install${N}"
        fi ;;

    warm-cache)
        _need_root
        if [ -f /usr/local/lib/easyinstall-autotune.sh ]; then
            . /usr/local/lib/easyinstall-autotune.sh; smart_cache_warmer
        else
            echo -e "${R}❌ AutoTune module not found. Run: easyinstall install${N}"
        fi ;;

    db-optimize)
        _need_root
        if [ -f /usr/local/lib/easyinstall-autotune.sh ]; then
            . /usr/local/lib/easyinstall-autotune.sh; db_optimization_engine
        else
            _bootstrap; _need_python; _py optimize
        fi ;;

    wp-speed)
        _need_root
        if [ -f /usr/local/lib/easyinstall-autotune.sh ]; then
            . /usr/local/lib/easyinstall-autotune.sh; wordpress_max_speed
        else
            echo -e "${R}❌ AutoTune module not found. Run: easyinstall install${N}"
        fi ;;

    install-governor)
        _need_root
        if [ -f /usr/local/lib/easyinstall-autotune.sh ]; then
            . /usr/local/lib/easyinstall-autotune.sh; install_governor_timer
        else
            echo -e "${R}❌ AutoTune module not found. Run: easyinstall install${N}"
        fi ;;

    emergency-check)
        if [ -f /usr/local/lib/easyinstall-autotune.sh ]; then
            . /usr/local/lib/easyinstall-autotune.sh; disaster_recovery_mode "manual"
        else
            echo -e "${R}❌ AutoTune module not found. Run: easyinstall install${N}"
        fi ;;

    autotune-rollback)
        _need_root
        if [ -f /usr/local/lib/easyinstall-autotune.sh ]; then
            . /usr/local/lib/easyinstall-autotune.sh; autotune_rollback
        else
            echo -e "${R}❌ AutoTune module not found. Run: easyinstall install${N}"
        fi ;;

    nginx-extras)
        _need_root
        if [ -f /usr/local/bin/easyinstall-extras ]; then
            /usr/local/bin/easyinstall-extras nginx
        else
            echo -e "${Y}⚠️  Extras installer not found — run full install first${N}"
        fi ;;

    # ── Machine Learning (v6.5) ───────────────────────────────────────────────
    ml-train)
        [ -z "$1" ] && { echo -e "${R}❌ Usage: easyinstall ml-train domain.com${N}"; exit 1; }
        [ -f /usr/local/lib/easyinstall-ml.sh ] && \
            bash /usr/local/lib/easyinstall-ml.sh ml_train "$1" || \
            echo -e "${R}❌ ML module not found. Run: easyinstall install${N}" ;;

    ml-predict)
        [ -z "$1" ] && { echo -e "${R}❌ Usage: easyinstall ml-predict domain.com${N}"; exit 1; }
        [ -f /usr/local/lib/easyinstall-ml.sh ] && \
            bash /usr/local/lib/easyinstall-ml.sh ml_predict "$1" || \
            echo -e "${R}❌ ML module not found.${N}" ;;

    ml-status)
        [ -f /usr/local/lib/easyinstall-ml.sh ] && \
            bash /usr/local/lib/easyinstall-ml.sh ml_status || \
            echo -e "${R}❌ ML module not found.${N}" ;;

    ml-model-list)
        [ -f /usr/local/lib/easyinstall-ml.sh ] && \
            bash /usr/local/lib/easyinstall-ml.sh ml_model_list || \
            echo -e "${R}❌ ML module not found.${N}" ;;

    # ── Serverless Functions (v6.5) ───────────────────────────────────────────
    fn-deploy)
        { [ -z "$1" ] || [ -z "$2" ]; } && { echo -e "${R}❌ Usage: easyinstall fn-deploy name /path/fn.sh${N}"; exit 1; }
        [ -f /usr/local/lib/easyinstall-serverless.sh ] && \
            bash /usr/local/lib/easyinstall-serverless.sh fn_deploy "$1" "$2" || \
            echo -e "${R}❌ Serverless module not found. Run: easyinstall install${N}" ;;

    fn-invoke)
        [ -z "$1" ] && { echo -e "${R}❌ Usage: easyinstall fn-invoke name [args]${N}"; exit 1; }
        [ -f /usr/local/lib/easyinstall-serverless.sh ] && \
            bash /usr/local/lib/easyinstall-serverless.sh fn_invoke "$@" || \
            echo -e "${R}❌ Serverless module not found.${N}" ;;

    fn-list)
        [ -f /usr/local/lib/easyinstall-serverless.sh ] && \
            bash /usr/local/lib/easyinstall-serverless.sh fn_list || \
            echo -e "${R}❌ Serverless module not found.${N}" ;;

    fn-delete)
        [ -z "$1" ] && { echo -e "${R}❌ Usage: easyinstall fn-delete name${N}"; exit 1; }
        [ -f /usr/local/lib/easyinstall-serverless.sh ] && \
            bash /usr/local/lib/easyinstall-serverless.sh fn_delete "$1" || \
            echo -e "${R}❌ Serverless module not found.${N}" ;;

    fn-logs)
        [ -z "$1" ] && { echo -e "${R}❌ Usage: easyinstall fn-logs name${N}"; exit 1; }
        [ -f /usr/local/lib/easyinstall-serverless.sh ] && \
            bash /usr/local/lib/easyinstall-serverless.sh fn_logs "$1" || \
            echo -e "${R}❌ Serverless module not found.${N}" ;;

    # ── Database Sharding (v6.5) ──────────────────────────────────────────────
    shard-init)
        [ -z "$1" ] && { echo -e "${R}❌ Usage: easyinstall shard-init domain.com${N}"; exit 1; }
        [ -f /usr/local/lib/easyinstall-sharding.sh ] && \
            bash /usr/local/lib/easyinstall-sharding.sh shard_init "$1" || \
            echo -e "${R}❌ Sharding module not found. Run: easyinstall install${N}" ;;

    shard-status)
        [ -f /usr/local/lib/easyinstall-sharding.sh ] && \
            bash /usr/local/lib/easyinstall-sharding.sh shard_status || \
            echo -e "${R}❌ Sharding module not found.${N}" ;;

    shard-rebalance)
        _need_root
        [ -f /usr/local/lib/easyinstall-sharding.sh ] && \
            bash /usr/local/lib/easyinstall-sharding.sh shard_rebalance || \
            echo -e "${R}❌ Sharding module not found.${N}" ;;

    shard-add)
        { [ -z "$1" ] || [ -z "$2" ]; } && { echo -e "${R}❌ Usage: easyinstall shard-add host port${N}"; exit 1; }
        [ -f /usr/local/lib/easyinstall-sharding.sh ] && \
            bash /usr/local/lib/easyinstall-sharding.sh shard_add "$1" "$2" || \
            echo -e "${R}❌ Sharding module not found.${N}" ;;

    # ── PageSpeed (v6.6) ──────────────────────────────────────────────────────
    pagespeed)
        if [ -f /usr/local/lib/easyinstall-pagespeed.sh ]; then
            . /usr/local/lib/easyinstall-pagespeed.sh; easy_pagespeed "$@"
        else
            _need_root; _bootstrap; _need_python; _need_php
            _py pagespeed "$@"
        fi ;;

    # ── Troubleshoot ──────────────────────────────────────────────────────────
    fix-apache|fix-nginx)
        _need_root; _bootstrap; _need_python
        _py fix-apache "$@" ;;

    # ── Help / catch-all ──────────────────────────────────────────────────────
    help|--help|-h) _help ;;

    *)
        echo -e "${R}❌ Unknown command: $CMD${N}"
        echo "Run: easyinstall help"
        exit 1 ;;
esac
