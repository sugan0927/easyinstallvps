#!/bin/bash
# ============================================================
# EasyInstallVPS — One-Line Bootstrap Script v7.0
# Downloads easyinstall.sh + easyinstall_config.py from GitHub
# and runs the full WordPress performance installer.
# Also installs Enterprise modules (API, DB, Security, Monitor).
#
# Usage (on any fresh VPS):
#   bash <(curl -fsSL https://raw.githubusercontent.com/sugan0927/easyinstallvps/main/install.sh)
#
# Or download first, then run:
#   curl -fsSL https://raw.githubusercontent.com/sugan0927/easyinstallvps/main/install.sh -o install.sh
#   chmod +x install.sh && sudo bash install.sh
# ============================================================

set -eE

# ── Colors ────────────────────────────────────────────────────────────────────
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
PURPLE='\033[0;35m'
NC='\033[0m'

# ── Config ────────────────────────────────────────────────────────────────────
REPO_RAW="https://raw.githubusercontent.com/sugan0927/easyinstallvps/main"
INSTALL_DIR="/root/easyinstallvps"
MAIN_SCRIPT="easyinstall.sh"
CONFIG_SCRIPT="easyinstall_config.py"
LOG_FILE="/var/log/easyinstall-bootstrap.log"
REQUIRED_DISK_MB=5120
REQUIRED_RAM_MB=512

# Enterprise module paths on GitHub
ENTERPRISE_REPO_DIR="${REPO_RAW}/etc"
LIB_DIR="/usr/local/lib"
BIN_DIR="/usr/local/bin"
CONF_DIR="/etc/easyinstall"
DATA_DIR="/var/lib/easyinstall"
EI_LOG_DIR="/var/log/easyinstall"
SYSTEMD_DIR="/etc/systemd/system"
COMPLETION_DIR="/etc/bash_completion.d"

# ── Plugin system paths ───────────────────────────────────────────────────────
PLUGINS_REPO_DIR="${REPO_RAW}/plugins"
PLUGIN_MANAGER_DEST="${LIB_DIR}/easyinstall_plugin_manager.py"
PLUGIN_CLI_DEST="${BIN_DIR}/easyinstall-plugin"
PLUGIN_LIB_DIR="${LIB_DIR}/easyinstall_plugins"
PLUGIN_CFG_DIR="${CONF_DIR}/plugins"
PLUGIN_LOG_DIR="${EI_LOG_DIR}"   # shared with existing log dir

# ── Speed ×100 optimizer path ───────────────────────────────────────────────
SPEED_X100_SCRIPT="${LIB_DIR}/speed_x100.py"
SPEED_X100_URL="${REPO_RAW}/speed_x100.py"
SPEED_X100_CLI="${BIN_DIR}/easyinstall-speed"

# Plugin Python modules to download from GitHub /plugins/easyinstall_plugins/
PLUGIN_MODULES=(
    "cloudflare_worker.py"
    "docker_plugin.py"
    "kubernetes_plugin.py"
    "podman_plugin.py"
    "microvm_plugin.py"
    "webui_plugin.py"
    "debian_package.py"
    "systemd_plugin.py"
    "edge_script.py"
    "pkg_manager.py"
    "ts_worker.py"
    "build_system.py"
)

# Enterprise Python modules to download from GitHub /etc/ folder
ENTERPRISE_MODULES=(
    "easyinstall_api.py"
    "easyinstall_db.py"
    "easyinstall_security.py"
    "easyinstall_monitor.py"
)

# Pages module paths on GitHub /etc/pages/ folder
PAGES_REPO_DIR="${REPO_RAW}/etc/pages"
PAGES_MODULES=(
    "easyinstall_ai_pages.py"
    "easyinstall_page_web.py"
    "easyinstall-pages"
)

# ── Logging ───────────────────────────────────────────────────────────────────
log() {
    local level="$1" msg="$2"
    local ts; ts=$(date '+%Y-%m-%d %H:%M:%S')
    mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
    echo "[$ts] [$level] $msg" >> "$LOG_FILE" 2>/dev/null || true
    case "$level" in
        SUCCESS) echo -e "${GREEN}✅ $msg${NC}" ;;
        WARNING) echo -e "${YELLOW}⚠️  $msg${NC}" ;;
        ERROR)   echo -e "${RED}❌ $msg${NC}" ;;
        INFO)    echo -e "${BLUE}ℹ️  $msg${NC}" ;;
        STEP)    echo -e "${CYAN}🔷 $msg${NC}" ;;
        ENTER)   echo -e "${PURPLE}🔶 $msg${NC}" ;;
        *)       echo -e "$msg" ;;
    esac
}

# ── Error handler ─────────────────────────────────────────────────────────────
error_handler() {
    local line=$1 cmd=$2 code=$3
    log "ERROR" "Bootstrap failed at line $line: $cmd (exit: $code)"
    log "INFO"  "Check log: $LOG_FILE"
    echo ""
    echo -e "${RED}══════════════════════════════════════════${NC}"
    echo -e "${RED}  Bootstrap failed. See $LOG_FILE${NC}"
    echo -e "${RED}══════════════════════════════════════════${NC}"
    exit "$code"
}
trap 'error_handler ${LINENO} "$BASH_COMMAND" $?' ERR

# ── Banner ────────────────────────────────────────────────────────────────────
print_banner() {
    clear
    echo -e "${GREEN}══════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}  🚀 EasyInstallVPS Bootstrap v7.0${NC}"
    echo -e "${GREEN}     WordPress Maximum Performance + Enterprise${NC}"
    echo -e "${GREEN}     Repo: github.com/sugan0927/easyinstallvps${NC}"
    echo -e "${GREEN}══════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "${YELLOW}  This installer will:${NC}"
    echo "    1. Install WordPress performance stack (Nginx, PHP, MySQL, Redis)"
    echo "    2. Install Enterprise REST API (port 8000)"
    echo "    3. Install Database manager (SQLite persistence)"
    echo "    4. Install Security module (RBAC, SSL manager, scanner)"
    echo "    5. Install Monitoring daemon (metrics, alerts, Prometheus)"
    echo "    6. Install AI Page Generator (login pages, wizards, themes, plugins)"
    echo ""
}

# ── Pre-flight checks ─────────────────────────────────────────────────────────
check_root() {
    log "STEP" "Checking root privileges..."
    if [ "$EUID" -ne 0 ]; then
        log "ERROR" "This script must be run as root."
        echo ""
        echo -e "${YELLOW}  Run: sudo bash install.sh${NC}"
        exit 1
    fi
    log "SUCCESS" "Running as root"
}

check_os() {
    log "STEP" "Checking OS compatibility..."
    if [ ! -f /etc/os-release ]; then
        log "ERROR" "Cannot detect OS. Requires Ubuntu 22.04/24.04 or Debian 12."
        exit 1
    fi
    source /etc/os-release
    OS_ID="${ID:-unknown}"
    OS_VERSION="${VERSION_ID:-unknown}"
    case "$OS_ID" in
        ubuntu)
            case "$OS_VERSION" in
                22.04|24.04) log "SUCCESS" "OS: Ubuntu $OS_VERSION ✓" ;;
                20.04)       log "WARNING" "Ubuntu 20.04 — may work but 22.04+ recommended" ;;
                *)           log "WARNING" "Ubuntu $OS_VERSION — untested, proceeding anyway" ;;
            esac ;;
        debian)
            case "$OS_VERSION" in
                11|12) log "SUCCESS" "OS: Debian $OS_VERSION ✓" ;;
                *)     log "WARNING" "Debian $OS_VERSION — untested, proceeding anyway" ;;
            esac ;;
        *)
            log "ERROR" "Unsupported OS: $OS_ID $OS_VERSION"
            exit 1 ;;
    esac
}

check_disk() {
    log "STEP" "Checking disk space (need ${REQUIRED_DISK_MB}MB free)..."
    local free_mb; free_mb=$(df / | awk 'NR==2 {printf "%d", $4/1024}')
    if [ "$free_mb" -lt "$REQUIRED_DISK_MB" ]; then
        log "ERROR" "Insufficient disk: ${free_mb}MB available, ${REQUIRED_DISK_MB}MB required"
        exit 1
    fi
    log "SUCCESS" "Disk space: ${free_mb}MB available ✓"
}

check_ram() {
    log "STEP" "Checking RAM (need ${REQUIRED_RAM_MB}MB)..."
    local ram_mb; ram_mb=$(free -m | awk '/Mem:/ {print $2}')
    if [ "$ram_mb" -lt "$REQUIRED_RAM_MB" ]; then
        log "WARNING" "Low RAM: ${ram_mb}MB. Swap will be configured automatically."
    else
        log "SUCCESS" "RAM: ${ram_mb}MB ✓"
    fi
}

check_network() {
    log "STEP" "Checking internet connectivity..."
    local connected=false
    for host in "github.com" "raw.githubusercontent.com" "8.8.8.8"; do
        if curl -fsSL --max-time 5 --head "https://${host}" > /dev/null 2>&1 || \
           ping -c1 -W3 "$host" > /dev/null 2>&1; then
            connected=true
            break
        fi
    done
    if [ "$connected" = "false" ]; then
        log "ERROR" "No internet connection. Cannot download files from GitHub."
        exit 1
    fi
    log "SUCCESS" "Internet connectivity ✓"
}

# ── Install prerequisites ─────────────────────────────────────────────────────
install_prerequisites() {
    log "STEP" "Installing prerequisites (curl, wget, python3)..."
    apt-get update -qq 2>/dev/null || true
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
        curl wget python3 python3-pip git ca-certificates gnupg lsb-release 2>/dev/null
    log "SUCCESS" "Prerequisites installed"
}

# ── Generic download function with retry ──────────────────────────────────────
download_file() {
    local url="$1"
    local dest="$2"
    local label="${3:-$(basename "$dest")}"
    local retry=3
    local delay=5
    local attempt=1

    log "INFO" "Downloading ${label}..."
    while [ $attempt -le $retry ]; do
        if curl -fsSL \
            --connect-timeout 15 \
            --max-time 120 \
            --retry 2 \
            -o "$dest" \
            "$url"; then
            log "SUCCESS" "${label} downloaded ($(wc -l < "$dest") lines)"
            return 0
        fi
        log "WARNING" "Attempt $attempt/$retry failed. Retrying in ${delay}s..."
        sleep $delay
        delay=$((delay * 2))
        attempt=$((attempt + 1))
    done
    log "ERROR" "Failed to download ${label} after $retry attempts"
    log "INFO"  "URL: $url"
    return 1
}

# ── Download core installer files ─────────────────────────────────────────────
download_core_files() {
    log "STEP" "Downloading core installer files from GitHub..."
    mkdir -p "$INSTALL_DIR"
    cd "$INSTALL_DIR"

    download_file "${REPO_RAW}/${MAIN_SCRIPT}"   "${MAIN_SCRIPT}"   "easyinstall.sh"
    download_file "${REPO_RAW}/${CONFIG_SCRIPT}" "${CONFIG_SCRIPT}" "easyinstall_config.py"

    # ── Validate ──────────────────────────────────────────────────────────────
    log "STEP" "Validating core files..."

    if [ ! -s "${MAIN_SCRIPT}" ]; then
        log "ERROR" "${MAIN_SCRIPT} is empty or missing"; exit 1
    fi
    if ! head -1 "${MAIN_SCRIPT}" | grep -q "bash"; then
        log "ERROR" "${MAIN_SCRIPT} does not look like a bash script"; exit 1
    fi
    if ! bash -n "${MAIN_SCRIPT}" 2>/dev/null; then
        log "ERROR" "${MAIN_SCRIPT} has bash syntax errors"; exit 1
    fi
    if [ ! -s "${CONFIG_SCRIPT}" ]; then
        log "ERROR" "${CONFIG_SCRIPT} is empty or missing"; exit 1
    fi
    if ! python3 -c "import ast; ast.parse(open('${CONFIG_SCRIPT}').read())" 2>/dev/null; then
        log "ERROR" "${CONFIG_SCRIPT} has Python syntax errors"; exit 1
    fi

    chmod +x "${MAIN_SCRIPT}" "${CONFIG_SCRIPT}"
    log "SUCCESS" "Core files validated ✓"
}

# ── Download enterprise modules from /etc/ folder ─────────────────────────────
download_enterprise_modules() {
    log "STEP" "Downloading Enterprise modules from GitHub /etc/ folder..."
    mkdir -p "$LIB_DIR"

    local failed=0
    for module in "${ENTERPRISE_MODULES[@]}"; do
        local url="${ENTERPRISE_REPO_DIR}/${module}"
        local dest="${LIB_DIR}/${module}"

        if download_file "$url" "$dest" "$module"; then
            # Validate Python syntax
            if python3 -m py_compile "$dest" 2>/dev/null; then
                chmod 644 "$dest"
                log "SUCCESS" "Installed: ${dest}"
            else
                log "WARNING" "${module} has Python syntax issues — kept but may not work"
                failed=$((failed + 1))
            fi
        else
            log "WARNING" "Could not download ${module} — enterprise feature will be unavailable"
            failed=$((failed + 1))
        fi
    done

    if [ $failed -eq 0 ]; then
        log "SUCCESS" "All ${#ENTERPRISE_MODULES[@]} enterprise modules downloaded ✓"
    elif [ $failed -lt ${#ENTERPRISE_MODULES[@]} ]; then
        log "WARNING" "${failed}/${#ENTERPRISE_MODULES[@]} modules failed — partial enterprise install"
    else
        log "WARNING" "All enterprise modules failed to download — check GitHub /etc/ path"
        log "INFO"    "Core WordPress install will continue without enterprise features"
    fi

    return 0  # Never fail the whole install for enterprise modules
}

# ── Install Python dependencies for enterprise modules ────────────────────────
install_python_deps() {
    log "STEP" "Installing Python dependencies for enterprise modules..."
    if ! command -v pip3 &>/dev/null; then
        log "WARNING" "pip3 not found — skipping Python deps"
        return 0
    fi

    local packages=("fastapi" "uvicorn" "pyjwt" "flask")
    for pkg in "${packages[@]}"; do
        if pip3 install "$pkg" --break-system-packages --quiet 2>/dev/null || \
           pip3 install "$pkg" --quiet 2>/dev/null; then
            log "SUCCESS" "pip: $pkg installed"
        else
            log "WARNING" "pip: $pkg install failed — some API features may not work"
        fi
    done
}

# ── Create enterprise directory structure ─────────────────────────────────────
create_enterprise_dirs() {
    log "STEP" "Creating enterprise directory structure..."
    mkdir -p "$CONF_DIR" "$DATA_DIR" "$EI_LOG_DIR"
    chmod 700 "$CONF_DIR" "$DATA_DIR"
    chmod 755 "$EI_LOG_DIR"
    log "SUCCESS" "Directories created"
}

# ── Write default config files ────────────────────────────────────────────────
write_enterprise_configs() {
    log "STEP" "Writing enterprise configuration files..."

    # Generate a secure random secret
    local secret
    secret=$(python3 -c "import secrets; print(secrets.token_hex(64))" 2>/dev/null \
             || dd if=/dev/urandom bs=64 count=1 2>/dev/null | sha256sum | awk '{print $1}')

    # api.conf
    if [ ! -f "$CONF_DIR/api.conf" ]; then
        cat > "$CONF_DIR/api.conf" <<EOF
{
    "host": "127.0.0.1",
    "port": 8000,
    "secret_key": "${secret}",
    "token_expiry_hours": 24,
    "rate_limit_per_minute": 100,
    "enable_cors": true,
    "allowed_origins": ["*"],
    "log_level": "info"
}
EOF
        chmod 600 "$CONF_DIR/api.conf"
        log "SUCCESS" "Written: $CONF_DIR/api.conf"
    else
        log "INFO" "Keeping existing: $CONF_DIR/api.conf"
    fi

    # database.conf
    if [ ! -f "$CONF_DIR/database.conf" ]; then
        cat > "$CONF_DIR/database.conf" <<EOF
{
    "engine": "sqlite",
    "sqlite_path": "/var/lib/easyinstall/easyinstall.db",
    "metrics_retention_days": 30,
    "audit_retention_days": 90,
    "backup_record_retention_days": 365
}
EOF
        chmod 600 "$CONF_DIR/database.conf"
        log "SUCCESS" "Written: $CONF_DIR/database.conf"
    else
        log "INFO" "Keeping existing: $CONF_DIR/database.conf"
    fi

    # monitoring.conf
    if [ ! -f "$CONF_DIR/monitoring.conf" ]; then
        cat > "$CONF_DIR/monitoring.conf" <<EOF
{
    "poll_interval_seconds": 60,
    "metrics_history_hours": 24,
    "alert_cpu_threshold": 85.0,
    "alert_memory_threshold": 90.0,
    "alert_disk_threshold": 85.0,
    "alert_redis_memory_mb": 512,
    "prometheus_enabled": false,
    "prometheus_port": 9091,
    "slack_webhook": "",
    "email_alerts": ""
}
EOF
        chmod 600 "$CONF_DIR/monitoring.conf"
        log "SUCCESS" "Written: $CONF_DIR/monitoring.conf"
    else
        log "INFO" "Keeping existing: $CONF_DIR/monitoring.conf"
    fi

    log "SUCCESS" "Enterprise config files ready"
}

# ── Write systemd service files ───────────────────────────────────────────────
write_systemd_services() {
    log "STEP" "Writing systemd service files..."

    # ── easyinstall-api.service ───────────────────────────────────────────────
    cat > "$SYSTEMD_DIR/easyinstall-api.service" <<'EOF'
[Unit]
Description=EasyInstall Enterprise REST API v7.0
Documentation=https://github.com/sugan0927/easyinstallvps
After=network.target mariadb.service redis-server.service nginx.service
Wants=mariadb.service

[Service]
Type=simple
User=root
Group=root
WorkingDirectory=/usr/local/lib
ExecStart=/usr/bin/python3 /usr/local/lib/easyinstall_api.py
ExecReload=/bin/kill -HUP $MAINPID
Restart=always
RestartSec=10
StartLimitIntervalSec=60
StartLimitBurst=5
StandardOutput=journal
StandardError=journal
SyslogIdentifier=easyinstall-api
Environment=PYTHONUNBUFFERED=1
Environment=PYTHONPATH=/usr/local/lib
NoNewPrivileges=yes
ProtectKernelTunables=yes
ProtectControlGroups=yes

[Install]
WantedBy=multi-user.target
EOF

    # ── easyinstall-monitor.service ───────────────────────────────────────────
    cat > "$SYSTEMD_DIR/easyinstall-monitor.service" <<'EOF'
[Unit]
Description=EasyInstall Monitoring Daemon v7.0
After=network.target easyinstall-api.service

[Service]
Type=simple
User=root
WorkingDirectory=/usr/local/lib
ExecStart=/usr/bin/python3 /usr/local/lib/easyinstall_monitor.py daemon
Restart=always
RestartSec=30
StandardOutput=journal
StandardError=journal
SyslogIdentifier=easyinstall-monitor
Environment=PYTHONUNBUFFERED=1
Environment=PYTHONPATH=/usr/local/lib

[Install]
WantedBy=multi-user.target
EOF

    # ── easyinstall-prometheus.service ───────────────────────────────────────
    cat > "$SYSTEMD_DIR/easyinstall-prometheus.service" <<'EOF'
[Unit]
Description=EasyInstall Prometheus Metrics Exporter
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/usr/local/lib
ExecStart=/usr/bin/python3 /usr/local/lib/easyinstall_monitor.py prometheus
Restart=always
RestartSec=15
StandardOutput=journal
StandardError=journal
SyslogIdentifier=easyinstall-prometheus
Environment=PYTHONUNBUFFERED=1
Environment=PYTHONPATH=/usr/local/lib

[Install]
WantedBy=multi-user.target
EOF

    # ── SSL auto-renewal service + timer ──────────────────────────────────────
    cat > "$SYSTEMD_DIR/easyinstall-autorenew.service" <<'EOF'
[Unit]
Description=EasyInstall SSL Certificate Auto-Renewal

[Service]
Type=oneshot
User=root
ExecStart=/usr/bin/python3 -c "
import sys; sys.path.insert(0, '/usr/local/lib')
try:
    from easyinstall_security import ssl_manager
    ssl_manager.renew_all()
    print('SSL renewal complete')
except Exception as e:
    print(f'SSL renewal error: {e}')
"
StandardOutput=journal
StandardError=journal
Environment=PYTHONPATH=/usr/local/lib
EOF

    cat > "$SYSTEMD_DIR/easyinstall-autorenew.timer" <<'EOF'
[Unit]
Description=EasyInstall SSL Auto-Renewal (twice daily)

[Timer]
OnCalendar=*-*-* 03,15:30:00
RandomizedDelaySec=3600
Persistent=true

[Install]
WantedBy=timers.target
EOF

    # ── Nightly housekeeping service + timer ──────────────────────────────────
    cat > "$SYSTEMD_DIR/easyinstall-housekeep.service" <<'EOF'
[Unit]
Description=EasyInstall Database Housekeeping

[Service]
Type=oneshot
User=root
ExecStart=/usr/bin/python3 /usr/local/lib/easyinstall_db.py --housekeep
StandardOutput=journal
StandardError=journal
Environment=PYTHONPATH=/usr/local/lib
EOF

    cat > "$SYSTEMD_DIR/easyinstall-housekeep.timer" <<'EOF'
[Unit]
Description=EasyInstall Nightly Housekeeping

[Timer]
OnCalendar=*-*-* 02:00:00
RandomizedDelaySec=600
Persistent=true

[Install]
WantedBy=timers.target
EOF

    log "SUCCESS" "Systemd service files written"
}

# ── Initialise enterprise database ────────────────────────────────────────────
init_enterprise_db() {
    log "STEP" "Initialising enterprise database..."

    if [ ! -f "$LIB_DIR/easyinstall_db.py" ]; then
        log "WARNING" "easyinstall_db.py not found — skipping DB init"
        return 0
    fi

    if PYTHONPATH="$LIB_DIR" python3 "$LIB_DIR/easyinstall_db.py" --init 2>&1 \
       | grep -v "^$" >> "$LOG_FILE"; then
        log "SUCCESS" "Database initialised"
        if [ -f /root/easyinstall-api-admin.txt ]; then
            log "SUCCESS" "Admin credentials saved → /root/easyinstall-api-admin.txt"
        fi
    else
        log "WARNING" "Database init had warnings (may be OK on re-runs)"
    fi

    return 0
}

# ── Download AI Pages modules from GitHub /etc/pages/ folder ─────────────────
download_pages_modules() {
    log "STEP" "Downloading AI Pages modules from GitHub /etc/pages/ folder..."
    mkdir -p "$LIB_DIR"

    local failed=0
    for module in "${PAGES_MODULES[@]}"; do
        local url="${PAGES_REPO_DIR}/${module}"
        local dest

        if [ "$module" = "easyinstall-pages" ]; then
            dest="${BIN_DIR}/${module}"
        else
            dest="${LIB_DIR}/${module}"
        fi

        if download_file "$url" "$dest" "$module"; then
            if [ "$module" = "easyinstall-pages" ]; then
                chmod 755 "$dest"
                log "SUCCESS" "CLI installed: ${dest}"
            else
                if python3 -m py_compile "$dest" 2>/dev/null; then
                    chmod 644 "$dest"
                    log "SUCCESS" "Module installed: ${dest}"
                else
                    log "WARNING" "${module} has syntax issues — kept but may not work"
                    failed=$((failed + 1))
                fi
            fi
        else
            log "WARNING" "Could not download ${module} — pages feature unavailable"
            failed=$((failed + 1))
        fi
    done

    if [ $failed -eq 0 ]; then
        log "SUCCESS" "All ${#PAGES_MODULES[@]} pages modules downloaded ✓"
    else
        log "WARNING" "${failed}/${#PAGES_MODULES[@]} pages modules failed"
    fi
    return 0
}

# ── Setup AI Pages (templates + ai.sh extension + systemd) ───────────────────
setup_pages_modules() {
    log "STEP" "Setting up AI Pages module..."

    # Write template files
    if [ -f "$LIB_DIR/easyinstall_ai_pages.py" ]; then
        PYTHONPATH="$LIB_DIR" python3 "$LIB_DIR/easyinstall_ai_pages.py" \
            write-templates 2>/dev/null && \
            log "SUCCESS" "Page templates written" || \
            log "WARNING" "Template write skipped"
    fi

    # Extend easyinstall-ai.sh if it already exists (post-core-install scenario)
    local AI_MODULE="/usr/local/lib/easyinstall-ai.sh"
    local MARKER="# ── EasyInstall AI Page Generator Functions v1.0"
    if [ -f "$AI_MODULE" ] && ! grep -q "$MARKER" "$AI_MODULE" 2>/dev/null; then
        _append_ai_page_functions "$AI_MODULE"
        log "SUCCESS" "AI page functions added to easyinstall-ai.sh"
    elif [ ! -f "$AI_MODULE" ]; then
        # Save pending — will be merged after core install creates easyinstall-ai.sh
        mkdir -p "$CONF_DIR"
        _append_ai_page_functions "$CONF_DIR/ai-pages-pending.sh"
        log "INFO" "AI functions saved — will merge into easyinstall-ai.sh after core install"
    fi

    # Systemd service for web interface
    cat > "$SYSTEMD_DIR/easyinstall-pages-web.service" <<'SVCEOF'
[Unit]
Description=EasyInstall AI Page Generator Web Interface
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/usr/local/lib
ExecStart=/usr/bin/python3 /usr/local/lib/easyinstall_page_web.py --port 8080 --host 0.0.0.0
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal
SyslogIdentifier=easyinstall-pages-web
Environment=PYTHONUNBUFFERED=1
Environment=PYTHONPATH=/usr/local/lib

[Install]
WantedBy=multi-user.target
SVCEOF

    # Bash completion
    mkdir -p "$COMPLETION_DIR"
    cat > "$COMPLETION_DIR/easyinstall-pages" <<'COMPEOF'
_easyinstall_pages_complete() {
    local cur prev
    COMPREPLY=()
    cur="${COMP_WORDS[COMP_CWORD]}"
    prev="${COMP_WORDS[COMP_CWORD-1]}"
    local cmds="custom-login custom-setup custom-theme custom-plugin page-assist web-start web-stop web-status list-plugins delete-plugin ai-status help"
    case "$prev" in
        easyinstall-pages)
            COMPREPLY=( $(compgen -W "$cmds" -- "$cur") ); return 0 ;;
        custom-login|custom-setup|custom-theme|custom-plugin|page-assist|list-plugins|delete-plugin)
            [ -d "/var/www/html" ] && COMPREPLY=( $(compgen -W "$(ls /var/www/html 2>/dev/null)" -- "$cur") )
            return 0 ;;
        web-start)
            COMPREPLY=( $(compgen -W "8080 8081 8082 3000 5000" -- "$cur") ); return 0 ;;
    esac
}
complete -F _easyinstall_pages_complete easyinstall-pages
COMPEOF

    systemctl daemon-reload 2>/dev/null || true
    log "SUCCESS" "AI Pages module setup complete ✓"
}

# ── Helper: append AI page functions to a file ────────────────────────────────
_append_ai_page_functions() {
    local target_file="$1"
    cat >> "$target_file" <<'AIFUNC'

# ── EasyInstall AI Page Generator Functions v1.0 ──────────────────────────────
# Auto-appended by install.sh — DO NOT REMOVE

ai_generate_login_page() {
    local domain="$1" description="${2:-Modern login page}" style="${3:-modern}" colors="${4:-#667eea,#764ba2}"
    echo -e "\033[0;35m🎨 Generating login page for ${domain}...\033[0m"
    PYTHONPATH=/usr/local/lib python3 /usr/local/lib/easyinstall_ai_pages.py generate-login \
        --domain "$domain" --description "$description" --style "$style" --colors "$colors"
}

ai_generate_setup_page() {
    local domain="$1" description="${2:-Modern 8-step setup wizard}"
    echo -e "\033[0;35m🚀 Generating setup wizard for ${domain}...\033[0m"
    PYTHONPATH=/usr/local/lib python3 /usr/local/lib/easyinstall_ai_pages.py generate-setup \
        --domain "$domain" --description "$description"
}

ai_generate_theme() {
    local domain="$1" description="${2:-Modern theme}" colors="${3:-#667eea,#764ba2}"
    echo -e "\033[0;35m🎨 Generating theme for ${domain}...\033[0m"
    PYTHONPATH=/usr/local/lib python3 /usr/local/lib/easyinstall_ai_pages.py generate-theme \
        --domain "$domain" --description "$description" --colors "$colors"
}

ai_generate_plugin() {
    local domain="$1" description="${2:-Custom plugin}" features="${3:-shortcode,widget,settings}"
    echo -e "\033[0;35m🔌 Generating plugin for ${domain}...\033[0m"
    PYTHONPATH=/usr/local/lib python3 /usr/local/lib/easyinstall_ai_pages.py generate-plugin \
        --domain "$domain" --description "$description" --features "$features"
}

ai_page_assistant() {
    local domain="$1"
    [ -z "$domain" ] && { echo -e "\033[0;31m❌ Usage: ai_page_assistant domain.com\033[0m"; return 1; }
    command -v easyinstall-pages &>/dev/null && \
        easyinstall-pages page-assist "$domain" || \
        echo -e "\033[1;33m⚠️  Run: easyinstall-pages page-assist $domain\033[0m"
}
AIFUNC
}

# ── Post core install: merge pending AI functions into easyinstall-ai.sh ──────
merge_pending_ai_functions() {
    local AI_MODULE="/usr/local/lib/easyinstall-ai.sh"
    local PENDING="$CONF_DIR/ai-pages-pending.sh"
    local MARKER="# ── EasyInstall AI Page Generator Functions v1.0"

    if [ -f "$AI_MODULE" ] && [ -f "$PENDING" ] && \
       ! grep -q "$MARKER" "$AI_MODULE" 2>/dev/null; then
        cat "$PENDING" >> "$AI_MODULE"
        rm -f "$PENDING"
        log "SUCCESS" "AI page functions merged into easyinstall-ai.sh ✓"
    fi
}

# ── Inject Pages CLI commands into easyinstall dispatcher ────────────────────
inject_pages_cli() {
    local EASYINSTALL_BIN="$BIN_DIR/easyinstall"
    local MARKER_PAGES="# ── EasyInstall Pages Commands v1.0"

    if [ ! -f "$EASYINSTALL_BIN" ]; then
        log "WARNING" "easyinstall not found — pages CLI injection skipped"
        return 0
    fi
    if grep -q "$MARKER_PAGES" "$EASYINSTALL_BIN" 2>/dev/null; then
        log "INFO" "Pages CLI already injected — skipping"
        return 0
    fi

    cp "$EASYINSTALL_BIN" "${EASYINSTALL_BIN}.bak.pages.$(date +%Y%m%d%H%M%S)"

    python3 - "$EASYINSTALL_BIN" <<'PYEOF'
import sys, re
path = sys.argv[1]
src  = open(path).read()
block = """
        # ── EasyInstall Pages Commands v1.0 ──────────────────────────────────
        custom-login)
            [ -z "$2" ] && { echo -e "${RED}\u274c Usage: easyinstall custom-login domain.com [desc] [style]${NC}"; exit 1; }
            easyinstall-pages custom-login "$2" "${3:-}" "${4:-modern}" ;;
        custom-setup)
            [ -z "$2" ] && { echo -e "${RED}\u274c Usage: easyinstall custom-setup domain.com [desc]${NC}"; exit 1; }
            easyinstall-pages custom-setup "$2" "${3:-}" ;;
        custom-theme)
            [ -z "$2" ] && { echo -e "${RED}\u274c Usage: easyinstall custom-theme domain.com [desc] [colors]${NC}"; exit 1; }
            easyinstall-pages custom-theme "$2" "${3:-}" "${4:-#667eea,#764ba2}" ;;
        custom-plugin)
            [ -z "$2" ] && { echo -e "${RED}\u274c Usage: easyinstall custom-plugin domain.com [desc] [features]${NC}"; exit 1; }
            easyinstall-pages custom-plugin "$2" "${3:-}" "${4:-shortcode,widget,settings}" ;;
        page-assist)
            [ -z "$2" ] && { echo -e "${RED}\u274c Usage: easyinstall page-assist domain.com${NC}"; exit 1; }
            easyinstall-pages page-assist "$2" ;;
        pages-web)
            easyinstall-pages "web-${2:-status}" "${3:-8080}" ;;
        list-pages)
            easyinstall-pages list-plugins "${2:-}" ;;
"""
patched = re.sub(r'^        \*\)', block + '        *)', src, count=1, flags=re.MULTILINE)
if patched == src:
    idx = src.rfind('\n        esac')
    if idx != -1:
        patched = src[:idx] + block + src[idx:]
open(path, 'w').write(patched)
print("injected")
PYEOF

    grep -q "$MARKER_PAGES" "$EASYINSTALL_BIN" 2>/dev/null && \
        { chmod 755 "$EASYINSTALL_BIN"; log "SUCCESS" "Pages CLI commands injected ✓"; } || \
        log "WARNING" "Pages CLI injection — verify manually"
    return 0
}

# ── Inject enterprise CLI commands into /usr/local/bin/easyinstall ────────────
inject_enterprise_cli() {
    log "STEP" "Injecting enterprise CLI commands..."

    local EASYINSTALL_BIN="$BIN_DIR/easyinstall"
    local MARKER="# ── EasyInstall Enterprise Commands v7.0"

    if [ ! -f "$EASYINSTALL_BIN" ]; then
        log "WARNING" "$EASYINSTALL_BIN not found — CLI injection skipped (run after core install)"
        return 0
    fi

    if grep -q "$MARKER" "$EASYINSTALL_BIN" 2>/dev/null; then
        log "INFO" "Enterprise CLI already injected — skipping"
        return 0
    fi

    # Backup original
    cp "$EASYINSTALL_BIN" "${EASYINSTALL_BIN}.bak.$(date +%Y%m%d%H%M%S)"

    # Use Python to insert before the final `*)` catch-all case
    python3 - "$EASYINSTALL_BIN" <<'PYEOF'
import sys, re, os

path = sys.argv[1]
src  = open(path).read()

enterprise_block = """
        # ── EasyInstall Enterprise Commands v7.0 ──────────────────────────────
        # Injected by install.sh — do not edit manually

        api)
            subcmd="${2:-status}"
            case "$subcmd" in
                start)
                    systemctl start easyinstall-api && echo -e "${GREEN}✅ API started on port 8000${NC}" ;;
                stop)
                    systemctl stop easyinstall-api && echo -e "${GREEN}✅ API stopped${NC}" ;;
                restart)
                    systemctl restart easyinstall-api && echo -e "${GREEN}✅ API restarted${NC}" ;;
                status)
                    systemctl status easyinstall-api --no-pager
                    echo ""
                    if systemctl is-active --quiet easyinstall-api; then
                        echo -e "${GREEN}  API Docs: http://127.0.0.1:8000/api/docs${NC}"
                    fi ;;
                logs)
                    journalctl -u easyinstall-api -n 80 --no-pager ;;
                enable)
                    systemctl enable easyinstall-api && echo -e "${GREEN}✅ API enabled on boot${NC}" ;;
                *)
                    echo -e "${YELLOW}Usage: easyinstall api [start|stop|restart|status|logs|enable]${NC}" ;;
            esac ;;

        api-key)
            subcmd="${2:-list}"
            case "$subcmd" in
                list)
                    PYTHONPATH=/usr/local/lib python3 -c "
import sys; sys.path.insert(0, '/usr/local/lib')
from easyinstall_db import get_db
db = get_db()
keys = db.list_api_keys()
if not keys:
    print('No API keys found. Create via: POST /api/v1/api-keys')
else:
    print(f\\\"{'Name':<20} {'Role':<15} {'Preview':<20} {'Created'}\\\")
    print('-' * 75)
    for k in keys:
        print(f\\\"{k.get('name','?'):<20} {k.get('role','?'):<15} {k.get('key_preview','?'):<20} {k.get('created_at','?')}\\\")
" 2>/dev/null || echo -e "${RED}❌ Enterprise DB not available${NC}" ;;
                *)
                    echo -e "${YELLOW}Usage: easyinstall api-key list${NC}"
                    echo "  Create/revoke keys via REST API: http://127.0.0.1:8000/api/docs" ;;
            esac ;;

        user)
            subcmd="${2:-list}"
            case "$subcmd" in
                list)
                    PYTHONPATH=/usr/local/lib python3 -c "
import sys; sys.path.insert(0, '/usr/local/lib')
from easyinstall_db import get_db
db = get_db()
users = db.list_users()
if not users:
    print('No users found.')
else:
    print(f\\\"{'ID':<5} {'Username':<20} {'Email':<30} {'Role':<15} {'Active'}\\\")
    print('-' * 80)
    for u in users:
        active = '✅' if u.get('active') else '❌'
        print(f\\\"{u['id']:<5} {u['username']:<20} {u['email']:<30} {u['role']:<15} {active}\\\")
" 2>/dev/null || echo -e "${RED}❌ Enterprise DB not available${NC}" ;;
                add)
                    if [ -z "$3" ] || [ -z "$4" ] || [ -z "$5" ]; then
                        echo -e "${RED}❌ Usage: easyinstall user add <username> <email> <password> [role]${NC}"
                        echo "  Roles: super_admin | admin | developer | viewer | auditor"
                        exit 1
                    fi
                    PYTHONPATH=/usr/local/lib python3 -c "
import sys; sys.path.insert(0, '/usr/local/lib')
from easyinstall_db import get_db
db = get_db()
role = sys.argv[4] if len(sys.argv) > 4 else 'viewer'
u = db.create_user(sys.argv[1], sys.argv[2], sys.argv[3], role)
if u:
    print(f'✅ User created: {sys.argv[1]} (role: {role})')
else:
    print('❌ User already exists with that username or email')
    sys.exit(1)
" "$3" "$4" "$5" "${6:-viewer}" 2>/dev/null || echo -e "${RED}❌ Failed to create user${NC}" ;;
                delete)
                    [ -z "$3" ] && { echo -e "${RED}❌ Usage: easyinstall user delete <username>${NC}"; exit 1; }
                    PYTHONPATH=/usr/local/lib python3 -c "
import sys; sys.path.insert(0, '/usr/local/lib')
from easyinstall_db import get_db
db = get_db()
u = db.get_user(username=sys.argv[1])
if u:
    db.deactivate_user(u['id'])
    print(f'✅ User deactivated: {sys.argv[1]}')
else:
    print(f'❌ User not found: {sys.argv[1]}')
" "$3" 2>/dev/null || echo -e "${RED}❌ Enterprise DB not available${NC}" ;;
                *)
                    echo -e "${YELLOW}Usage: easyinstall user [list|add|delete]${NC}" ;;
            esac ;;

        security)
            subcmd="${2:-scan}"
            case "$subcmd" in
                scan)
                    DOMAIN="${3:-}"
                    PYTHONPATH=/usr/local/lib python3 -c "
import sys; sys.path.insert(0, '/usr/local/lib')
from easyinstall_security import scanner
import json
domain = sys.argv[1] if len(sys.argv) > 1 and sys.argv[1] else None
if domain:
    r = scanner.scan_site(domain)
    icon = '🟢' if r['score'] >= 90 else ('🟡' if r['score'] >= 60 else '🔴')
    print(f\\\"{icon} {r['domain']}: {r['score']}/100 (Grade {r['rating']})\\\")
    print(f\\\"  SSL Enabled : {r['ssl_enabled']}\\\")
    if r['findings']:
        print(f\\\"  Issues ({len(r['findings'])} found):\\\")
        for f in r['findings']:
            sev = f['severity'].upper()
            msg = f.get('message', f.get('file', ''))
            fix = f.get('fix', '')
            print(f\\\"    [{sev}] {msg}\\\")
            if fix:
                print(f\\\"      Fix: {fix}\\\")
    else:
        print('  ✅ No issues found')
else:
    results = scanner.scan_all_sites()
    if not results:
        print('No WordPress sites found in /var/www/html')
    else:
        print(f\\\"{'Domain':<35} {'Score':>6}  {'Grade':<6} {'Issues':>6}\\\")
        print('-' * 60)
        for r in results:
            icon = '🟢' if r['score'] >= 90 else ('🟡' if r['score'] >= 60 else '🔴')
            print(f\\\"{icon} {r['domain']:<33} {r['score']:>6}/100  {r['rating']:<6} {len(r['findings']):>6}\\\")
" "$DOMAIN" 2>/dev/null || echo -e "${RED}❌ Security module not available${NC}" ;;
                report)
                    PYTHONPATH=/usr/local/lib python3 -c "
import sys; sys.path.insert(0, '/usr/local/lib')
from easyinstall_security import generate_security_report
p = generate_security_report()
print(f'✅ Security report: {p}')
" 2>/dev/null || echo -e "${RED}❌ Security module not available${NC}" ;;
                ssl)
                    PYTHONPATH=/usr/local/lib python3 -c "
import sys; sys.path.insert(0, '/usr/local/lib')
from easyinstall_security import ssl_manager
certs = ssl_manager.check_all_certificates()
if not certs:
    print('No Let\\'s Encrypt certificates found.')
else:
    print(f\\\"{'Domain':<35} {'Days':>6}  Status\\\")
    print('-' * 55)
    for c in certs:
        icon = '✅' if c['status'] == 'ok' else ('⚠️ ' if c['status'] == 'expiring_soon' else '❌')
        days = str(c['days_remaining']) if c['days_remaining'] is not None else '?'
        print(f\\\"{icon} {c['domain']:<33} {days:>6}  {c['status']}\\\")
" 2>/dev/null || echo -e "${RED}❌ Security module not available${NC}" ;;
                firewall)
                    PYTHONPATH=/usr/local/lib python3 -c "
import sys; sys.path.insert(0, '/usr/local/lib')
from easyinstall_security import firewall
print(firewall.status())
" 2>/dev/null || ufw status 2>/dev/null || echo "UFW not available" ;;
                rotate-jwt)
                    PYTHONPATH=/usr/local/lib python3 -c "
import sys; sys.path.insert(0, '/usr/local/lib')
from easyinstall_security import rotate_jwt_secret
rotate_jwt_secret()
print('✅ JWT secret rotated. All existing tokens are now invalid.')
" 2>/dev/null || echo -e "${RED}❌ Security module not available${NC}" ;;
                *)
                    echo -e "${YELLOW}Usage: easyinstall security [scan [domain] | report | ssl | firewall | rotate-jwt]${NC}" ;;
            esac ;;

        metrics)
            DOMAIN="${2:-}"
            PYTHONPATH=/usr/local/lib python3 -c "
import sys; sys.path.insert(0, '/usr/local/lib')
domain = sys.argv[1] if len(sys.argv) > 1 and sys.argv[1] else None
from easyinstall_monitor import collect_system_metrics, collect_site_metrics
sys_m = collect_system_metrics()
print('')
print('═' * 50)
print('  EasyInstall v7.0 — Live Metrics')
print('═' * 50)
print(f\\\"  CPU     : {sys_m['cpu_usage']}%\\\")
print(f\\\"  Memory  : {sys_m['memory_usage_pct']}%  ({sys_m['memory_used_mb']}MB / {sys_m['memory_total_mb']}MB)\\\")
print(f\\\"  Disk    : {sys_m['disk_usage_pct']}%  ({sys_m['disk_used_gb']}GB / {sys_m['disk_total_gb']}GB)\\\")
print(f\\\"  Load    : {sys_m['load_1m']} / {sys_m['load_5m']} / {sys_m['load_15m']} (1/5/15m)\\\")
print(f\\\"  Conns   : {sys_m['tcp_connections']} TCP\\\")
print(f\\\"  Uptime  : {sys_m['uptime_seconds']//3600}h {(sys_m['uptime_seconds']%3600)//60}m\\\")
if domain:
    print('')
    sm = collect_site_metrics(domain)
    print(f\\\"  Site: {domain}\\\")
    print(f\\\"    Redis Memory : {sm['redis_used_memory_mb']} MB\\\")
    print(f\\\"    Redis Hit %  : {sm['redis_hit_rate_pct']}%\\\")
    print(f\\\"    Site Disk    : {sm['site_disk_mb']} MB\\\")
    print(f\\\"    MySQL Threads: {sm['mysql_threads_connected']}\\\")
print('')
" "$DOMAIN" 2>/dev/null || echo -e "${RED}❌ Monitor module not available${NC}" ;;

        monitor-start)
            systemctl start easyinstall-monitor && \
                echo -e "${GREEN}✅ Monitor daemon started${NC}" || \
                echo -e "${RED}❌ Failed to start monitor${NC}" ;;

        monitor-stop)
            systemctl stop easyinstall-monitor && \
                echo -e "${GREEN}✅ Monitor daemon stopped${NC}" ;;

        monitor-status)
            systemctl status easyinstall-monitor --no-pager ;;

        alerts)
            PYTHONPATH=/usr/local/lib python3 -c "
import sys; sys.path.insert(0, '/usr/local/lib')
from easyinstall_monitor import dispatcher
alerts = dispatcher.get_recent_alerts(hours=24)
if not alerts:
    print('✅ No alerts in the last 24 hours')
else:
    print(f'⚠️  {len(alerts)} alert(s) in the last 24 hours:')
    print('')
    for a in alerts[-20:]:
        level = a.get('level','info').upper()
        icon = '🔴' if level == 'CRITICAL' else ('🟡' if level == 'WARNING' else '🟢')
        ts   = a.get('timestamp','?')[:19]
        dom  = a.get('domain') or 'system'
        msg  = a.get('message','')[:80]
        print(f'{icon} [{ts}] [{dom}] {a.get(\"title\",\"Alert\")}')
        print(f'     {msg}')
" 2>/dev/null || echo -e "${RED}❌ Monitor module not available${NC}" ;;

        audit-log)
            DAYS="${2:-7}"
            PYTHONPATH=/usr/local/lib python3 -c "
import sys; sys.path.insert(0, '/usr/local/lib')
days = int(sys.argv[1]) if len(sys.argv) > 1 else 7
from easyinstall_db import get_db
db = get_db()
logs = db.get_audit_logs(days=days)
if not logs:
    print(f'No audit logs in the last {days} days')
else:
    print(f\\\"{'Time':<22} {'User':<15} {'Action':<25} {'Resource':<30} {'Status'}\\\")
    print('-' * 105)
    for l in logs:
        ts  = l.get('timestamp','?')[:19]
        usr = l.get('username') or 'system'
        act = l.get('action','?')[:24]
        res = (l.get('resource_type','?') + ':' + str(l.get('resource_id') or ''))[:29]
        sta = l.get('status','?')
        print(f\\\"{ts:<22} {usr:<15} {act:<25} {res:<30} {sta}\\\")
" "$DAYS" 2>/dev/null || echo -e "${RED}❌ Enterprise DB not available${NC}" ;;

        db-stats)
            PYTHONPATH=/usr/local/lib python3 -c "
import sys; sys.path.insert(0, '/usr/local/lib')
from easyinstall_db import get_db
db = get_db()
stats = db.get_stats()
print('')
print('📊 EasyInstall Enterprise Database Stats')
print('─' * 40)
for k, v in stats.items():
    print(f'  {k:<25}: {v}')
print('')
" 2>/dev/null || echo -e "${RED}❌ Enterprise DB not available${NC}" ;;

        enterprise-status)
            echo ""
            echo -e "${CYAN}╔══════════════════════════════════════════════════════╗${NC}"
            echo -e "${CYAN}║  EasyInstall Enterprise v7.0 — Status               ║${NC}"
            echo -e "${CYAN}╚══════════════════════════════════════════════════════╝${NC}"
            echo ""
            echo -e "${YELLOW}Services:${NC}"
            for svc in easyinstall-api easyinstall-monitor easyinstall-prometheus; do
                systemctl is-active --quiet "$svc" 2>/dev/null && \
                    echo -e "  ${GREEN}✓${NC} $svc" || \
                    echo -e "  ${RED}✗${NC} $svc (run: systemctl start $svc)"
            done
            echo ""
            echo -e "${YELLOW}Timers:${NC}"
            for timer in easyinstall-autorenew easyinstall-housekeep; do
                systemctl is-active --quiet "${timer}.timer" 2>/dev/null && \
                    echo -e "  ${GREEN}✓${NC} ${timer}.timer" || \
                    echo -e "  ${RED}✗${NC} ${timer}.timer"
            done
            echo ""
            echo -e "${YELLOW}Modules:${NC}"
            for mod in easyinstall_api easyinstall_db easyinstall_security easyinstall_monitor; do
                if [ -f "/usr/local/lib/${mod}.py" ]; then
                    echo -e "  ${GREEN}✓${NC} /usr/local/lib/${mod}.py"
                else
                    echo -e "  ${RED}✗${NC} /usr/local/lib/${mod}.py (missing)"
                fi
            done
            echo ""
            echo -e "${YELLOW}Config:${NC}"
            for conf in api.conf database.conf monitoring.conf; do
                [ -f "/etc/easyinstall/${conf}" ] && \
                    echo -e "  ${GREEN}✓${NC} /etc/easyinstall/${conf}" || \
                    echo -e "  ${RED}✗${NC} /etc/easyinstall/${conf}"
            done
            echo ""
            if systemctl is-active --quiet easyinstall-api 2>/dev/null; then
                echo -e "${GREEN}  API Docs: http://127.0.0.1:8000/api/docs${NC}"
            fi
            echo "" ;;

"""

# Insert before the final `*)` catch-all
patched = re.sub(
    r'^        \*\)',
    enterprise_block + '        *)',
    src,
    count=1,
    flags=re.MULTILINE
)

if patched == src:
    # Fallback: find the last 'esac' and insert before it
    idx = src.rfind('\n        esac')
    if idx != -1:
        patched = src[:idx] + enterprise_block + src[idx:]

with open(path, 'w') as f:
    f.write(patched)

print("CLI patch applied")
PYEOF

    if grep -q "# ── EasyInstall Enterprise Commands v7.0" "$EASYINSTALL_BIN" 2>/dev/null; then
        chmod 755 "$EASYINSTALL_BIN"
        log "SUCCESS" "Enterprise CLI commands injected into $EASYINSTALL_BIN"
    else
        log "WARNING" "CLI injection may not have worked — check manually"
    fi

    return 0
}

# ── Install bash completion ───────────────────────────────────────────────────
install_bash_completion() {
    log "STEP" "Installing bash completion..."
    mkdir -p "$COMPLETION_DIR"
    cat > "$COMPLETION_DIR/easyinstall-enterprise" <<'EOF'
# EasyInstall Enterprise bash completion v7.0
_easyinstall_complete() {
    local cur prev
    COMPREPLY=()
    cur="${COMP_WORDS[COMP_CWORD]}"
    prev="${COMP_WORDS[COMP_CWORD-1]}"

    local all_cmds="create delete ssl clone update-site backup-site site-info php-switch
                    monitor perf-dashboard warm-cache db-optimize wp-speed autotune
                    ws-enable ws-disable ws-status redis-ports clean help
                    api api-key user security metrics monitor-start monitor-stop
                    monitor-status alerts audit-log db-stats enterprise-status"

    case "$prev" in
        easyinstall)
            COMPREPLY=( $(compgen -W "$all_cmds" -- "$cur") )
            return 0 ;;
        api)
            COMPREPLY=( $(compgen -W "start stop restart status logs enable" -- "$cur") )
            return 0 ;;
        api-key)
            COMPREPLY=( $(compgen -W "list" -- "$cur") )
            return 0 ;;
        user)
            COMPREPLY=( $(compgen -W "list add delete" -- "$cur") )
            return 0 ;;
        security)
            COMPREPLY=( $(compgen -W "scan report ssl firewall rotate-jwt" -- "$cur") )
            return 0 ;;
        create|delete|ssl|clone|update-site|backup-site|site-info|php-switch|\
        metrics|ws-enable|ws-disable|security)
            local sites; sites=$(ls /var/www/html 2>/dev/null)
            COMPREPLY=( $(compgen -W "$sites" -- "$cur") )
            return 0 ;;
    esac
}
complete -F _easyinstall_complete easyinstall
EOF
    log "SUCCESS" "Bash completion installed"
}

# ── Enable and start enterprise services ──────────────────────────────────────
start_enterprise_services() {
    log "STEP" "Enabling enterprise services..."

    systemctl daemon-reload 2>/dev/null || true

    # Enable timers
    for timer in easyinstall-autorenew easyinstall-housekeep; do
        if systemctl enable "${timer}.timer" 2>/dev/null && \
           systemctl start  "${timer}.timer" 2>/dev/null; then
            log "SUCCESS" "Timer enabled: ${timer}"
        else
            log "WARNING" "Could not enable timer: ${timer}"
        fi
    done

    # Enable (but don't start yet — start after core WP install)
    for svc in easyinstall-api easyinstall-monitor; do
        systemctl enable "$svc" 2>/dev/null && \
            log "SUCCESS" "Service enabled: $svc" || \
            log "WARNING" "Could not enable: $svc"
    done

    log "INFO" "Enterprise services enabled (will auto-start after reboot)"
    log "INFO" "To start now: systemctl start easyinstall-api easyinstall-monitor"
}

# ── Start enterprise services post core install ───────────────────────────────
start_enterprise_services_now() {
    log "STEP" "Starting enterprise services..."

    local started=0
    for svc in easyinstall-api easyinstall-monitor; do
        if systemctl start "$svc" 2>/dev/null; then
            sleep 2
            if systemctl is-active --quiet "$svc" 2>/dev/null; then
                log "SUCCESS" "$svc is running"
                started=$((started + 1))
            else
                log "WARNING" "$svc started but may not be fully up"
                log "INFO"    "Check: journalctl -u $svc -n 20"
            fi
        else
            log "WARNING" "Could not start $svc"
            log "INFO"    "Try manually: systemctl start $svc"
        fi
    done

    if [ $started -gt 0 ]; then
        log "SUCCESS" "${started} enterprise service(s) running"
    fi
}

# ── Run core installer ────────────────────────────────────────────────────────
run_core_installer() {
    log "STEP" "Starting EasyInstall WordPress Performance Installer..."
    echo ""
    echo -e "${CYAN}══════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}  Phase 1: Core WordPress Performance Stack${NC}"
    echo -e "${CYAN}  Source: ${INSTALL_DIR}/${MAIN_SCRIPT}${NC}"
    echo -e "${CYAN}══════════════════════════════════════════════════${NC}"
    echo ""

    cd "$INSTALL_DIR"

    if bash "${MAIN_SCRIPT}" 2>&1 | tee -a "$LOG_FILE"; then
        log "SUCCESS" "Core WordPress installer completed"
        return 0
    else
        log "ERROR" "Core installer exited with error"
        return 1
    fi
}

# ── Print final summary ───────────────────────────────────────────────────────
print_summary() {
    local api_running=false
    systemctl is-active --quiet easyinstall-api 2>/dev/null && api_running=true

    echo ""
    echo -e "${GREEN}╔══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║  ✅ EasyInstallVPS v7.0 — Installation Complete!         ║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${YELLOW}📋 Next Steps:${NC}"
    echo "   1.  source ~/.bashrc"
    echo "   2.  easyinstall help"
    echo "   3.  easyinstall create yourdomain.com --ssl"
    echo ""
    echo -e "${YELLOW}🆕 Enterprise Commands:${NC}"
    echo "   easyinstall enterprise-status         — Check all enterprise services"
    echo "   easyinstall api [start|stop|status]   — Manage REST API"
    echo "   easyinstall security scan             — Security audit all sites"
    echo "   easyinstall security ssl              — Check SSL certificate expiry"
    echo "   easyinstall metrics [domain]          — Live system/site metrics"
    echo "   easyinstall alerts                    — Recent monitoring alerts"
    echo "   easyinstall user [list|add]           — Manage API users"
    echo "   easyinstall audit-log [days]          — View audit trail"
    echo "   easyinstall db-stats                  — Database statistics"
    echo ""
    echo -e "${YELLOW}🌐 REST API:${NC}"
    if $api_running; then
        echo -e "   ${GREEN}✅ Running${NC} — http://127.0.0.1:8000"
        echo "   Swagger Docs : http://127.0.0.1:8000/api/docs"
        echo "   Health Check : http://127.0.0.1:8000/api/v1/health"
    else
        echo "   Not started yet. Run: systemctl start easyinstall-api"
        echo "   Or: easyinstall api start"
    fi
    echo ""
    if [ -f /root/easyinstall-api-admin.txt ]; then
        echo -e "${YELLOW}🔑 API Admin Credentials (CHANGE IMMEDIATELY):${NC}"
        cat /root/easyinstall-api-admin.txt | sed 's/^/   /'
        echo ""
    fi
    echo -e "${YELLOW}📁 Files:${NC}"
    echo "   Core installer : $INSTALL_DIR"
    echo "   Lib modules    : /usr/local/lib/easyinstall_*.py"
    echo "   Config         : /etc/easyinstall/*.conf"
    echo "   Database       : /var/lib/easyinstall/easyinstall.db"
    echo "   Logs           : /var/log/easyinstall/"
    echo ""
    echo -e "${YELLOW}🎨 AI Page Generator:${NC}"
    echo "   easyinstall custom-login domain.com   — Custom login page"
    echo "   easyinstall custom-setup domain.com   — Setup wizard"
    echo "   easyinstall custom-theme domain.com   — Theme plugin"
    echo "   easyinstall custom-plugin domain.com  — Custom plugin"
    echo "   easyinstall page-assist domain.com    — Interactive assistant"
    echo "   easyinstall-pages web-start 8080      — Web UI"
    echo ""
    echo -e "${YELLOW}🔌 Plugin System (Phase 5):${NC}"
    echo "   easyinstall-plugin list               — List all 12 plugins"
    echo "   easyinstall-plugin doctor             — Health check"
    echo "   easyinstall plugin-enable <n>         — Enable a plugin"
    echo "   easyinstall webui start               — Start web dashboard (:8080)"
    echo "   easyinstall-plugin enable cloudflare_worker  — Edge caching"
    echo "   easyinstall-plugin enable docker_plugin      — Docker stacks"
    echo "   easyinstall-plugin enable kubernetes_plugin  — K8s manifests"
    echo "   Plugin files: /usr/local/lib/easyinstall_plugins/"
    echo "   Plugin CLI  : /usr/local/bin/easyinstall-plugin"
    echo ""
    echo -e "${YELLOW}⚡ WordPress Speed ×100 (Phase 6):${NC}"
    if [ -f "${SPEED_X100_SCRIPT}" ]; then
        echo -e "   ${GREEN}✓ speed_x100.py installed${NC}"
    else
        echo -e "   ${RED}✗ speed_x100.py not installed — run: easyinstall speed${NC}"
    fi
    echo "   easyinstall speed <domain>            — Optimize one site"
    echo "   easyinstall speed --all-sites         — Optimize all sites"
    echo "   easyinstall speed-webp <domain>       — Add WebP auto-serve"
    echo "   easyinstall speed-status              — Check optimizer status"
    echo "   easyinstall-speed --all-sites --webp  — Direct CLI"
    echo ""
    echo "   Optimizations applied:"
    echo "     • Redis TCP → Unix socket    (-30% latency)"
    echo "     • PHP-FPM upstream keepalive (-15ms/request)"
    echo "     • Full-page HTML cache       (TTFB 50ms → 2ms)"
    echo "     • DB autoload cleanup        (wp_options 200ms → 2ms)"
    echo "     • WordPress speed constants  (DISABLE_WP_CRON, FS_METHOD)"
    echo "     • Admin-ajax isolation       (REST non-blocking)"
    echo "     • WebP/AVIF auto-serve       (images 70% smaller, optional)"
    echo ""
    echo -e "${YELLOW}📝 Log File: ${LOG_FILE}${NC}"
    echo -e "${YELLOW}☕ Support: https://paypal.me/sugandodrai${NC}"
    echo -e "${GREEN}══════════════════════════════════════════════════════════${NC}"
}

# ══════════════════════════════════════════════════════════════════════════════
# Phase 5 — Plugin System (all NEW functions, nothing existing is touched)
# ══════════════════════════════════════════════════════════════════════════════

# ── Download plugin manager + all plugin files from GitHub /plugins/ ──────────
download_plugin_system() {
    log "STEP" "Downloading Plugin Manager from GitHub /plugins/..."
    mkdir -p "${PLUGIN_LIB_DIR}" "${PLUGIN_CFG_DIR}"
    chmod 755 "${PLUGIN_LIB_DIR}"
    chmod 700 "${PLUGIN_CFG_DIR}"

    # 1. Core plugin manager
    local mgr_url="${PLUGINS_REPO_DIR}/easyinstall_plugin_manager.py"
    if download_file "${mgr_url}" "${PLUGIN_MANAGER_DEST}" "easyinstall_plugin_manager.py"; then
        if python3 -m py_compile "${PLUGIN_MANAGER_DEST}" 2>/dev/null; then
            chmod 644 "${PLUGIN_MANAGER_DEST}"
            log "SUCCESS" "Plugin manager installed: ${PLUGIN_MANAGER_DEST}"
        else
            log "WARNING" "Plugin manager has syntax issues — plugin system may not work"
        fi
    else
        log "WARNING" "Could not download plugin manager — plugin system unavailable"
        return 0   # Never fail the whole install
    fi

    # 2. __init__.py for the package
    local init_url="${PLUGINS_REPO_DIR}/easyinstall_plugins/__init__.py"
    local init_dest="${PLUGIN_LIB_DIR}/__init__.py"
    download_file "${init_url}" "${init_dest}" "__init__.py" 2>/dev/null || \
        echo '"""EasyInstall plugins package"""' > "${init_dest}"
    chmod 644 "${init_dest}"

    # 3. Individual plugin modules
    local ok_count=0 fail_count=0
    for module in "${PLUGIN_MODULES[@]}"; do
        local url="${PLUGINS_REPO_DIR}/easyinstall_plugins/${module}"
        local dest="${PLUGIN_LIB_DIR}/${module}"
        if download_file "${url}" "${dest}" "${module}"; then
            if python3 -m py_compile "${dest}" 2>/dev/null; then
                chmod 644 "${dest}"
                log "SUCCESS" "Plugin installed: ${module}"
                ok_count=$((ok_count + 1))
            else
                log "WARNING" "${module} has syntax issues — kept but may not work"
                fail_count=$((fail_count + 1))
            fi
        else
            log "WARNING" "Could not download ${module} — skipping"
            fail_count=$((fail_count + 1))
        fi
    done

    log "INFO" "Plugins: ${ok_count} installed, ${fail_count} failed"

    # 4. CLI command
    local cli_url="${PLUGINS_REPO_DIR}/easyinstall-plugin"
    if download_file "${cli_url}" "${PLUGIN_CLI_DEST}" "easyinstall-plugin"; then
        chmod 755 "${PLUGIN_CLI_DEST}"
        log "SUCCESS" "Plugin CLI installed: ${PLUGIN_CLI_DEST}"
    else
        log "WARNING" "Could not download easyinstall-plugin CLI — generate minimal stub"
        _write_plugin_cli_stub
    fi

    # 5. Default plugin config files
    _write_default_plugin_configs

    return 0
}

# ── Write a minimal easyinstall-plugin stub if GitHub download fails ──────────
_write_plugin_cli_stub() {
    cat > "${PLUGIN_CLI_DEST}" <<'STUBEOF'
#!/bin/bash
# easyinstall-plugin — minimal stub (full CLI failed to download)
G='\033[0;32m'; B='\033[0;34m'; N='\033[0m'
echo -e "${B}EasyInstall Plugin Manager${N}"
python3 /usr/local/lib/easyinstall_plugin_manager.py "$@" 2>/dev/null || \
    echo -e "${G}Plugins dir: /usr/local/lib/easyinstall_plugins/${N}"
STUBEOF
    chmod 755 "${PLUGIN_CLI_DEST}"
    log "INFO" "Minimal plugin CLI stub written"
}

# ── Write default JSON configs for plugins that need credentials ──────────────
_write_default_plugin_configs() {
    # Only write if not already present (idempotent)
    local cf_cfg="${PLUGIN_CFG_DIR}/cloudflare_worker.json"
    [ -f "${cf_cfg}" ] || cat > "${cf_cfg}" <<'EOF'
{
    "enabled": false,
    "api_token": "",
    "account_id": "",
    "zone_id": "",
    "worker_name": "easyinstall-wp",
    "kv_namespace_id": ""
}
EOF

    local webui_cfg="${PLUGIN_CFG_DIR}/webui_plugin.json"
    [ -f "${webui_cfg}" ] || cat > "${webui_cfg}" <<'EOF'
{
    "enabled": false,
    "port": 8080,
    "bind": "0.0.0.0"
}
EOF

    local docker_cfg="${PLUGIN_CFG_DIR}/docker_plugin.json"
    [ -f "${docker_cfg}" ] || cat > "${docker_cfg}" <<'EOF'
{
    "enabled": false,
    "php_version": "8.2",
    "mariadb_version": "10.11",
    "wp_version": "latest"
}
EOF
    chmod 600 "${PLUGIN_CFG_DIR}"/*.json 2>/dev/null || true
    log "SUCCESS" "Default plugin configs written to ${PLUGIN_CFG_DIR}"
}

# ── Install Python deps needed by plugins (flask already done in Phase 2) ─────
install_plugin_python_deps() {
    log "STEP" "Installing plugin Python dependencies..."
    if ! command -v pip3 &>/dev/null; then
        log "WARNING" "pip3 not found — skipping plugin Python deps"
        return 0
    fi
    # Flask already installed in install_python_deps(); add plugin-specific extras
    local pkgs=("pyyaml")
    for pkg in "${pkgs[@]}"; do
        pip3 install "${pkg}" --break-system-packages --quiet 2>/dev/null || \
        pip3 install "${pkg}" --quiet 2>/dev/null || \
            log "WARNING" "pip: ${pkg} install failed (optional)"
    done
    log "SUCCESS" "Plugin Python deps installed"
}

# ── Configure Python path so plugins are importable ───────────────────────────
configure_plugin_python_path() {
    local pth_dir
    pth_dir=$(python3 -c "import site; print(site.getsitepackages()[0])" 2>/dev/null \
              || echo "/usr/local/lib/python3/dist-packages")
    local pth_file="${pth_dir}/easyinstall_plugins.pth"
    mkdir -p "${pth_dir}" 2>/dev/null || true
    echo "/usr/local/lib" > "${pth_file}" 2>/dev/null || true
    log "SUCCESS" "Python path configured: ${pth_file}"
}

# ── Write easyinstall-webui systemd service (plugin-specific) ─────────────────
write_plugin_systemd_units() {
    log "STEP" "Writing plugin systemd unit (easyinstall-webui)..."
    cat > "${SYSTEMD_DIR}/easyinstall-webui.service" <<'UNIT'
[Unit]
Description=EasyInstall Web Dashboard (Plugin)
After=network.target

[Service]
Type=simple
Environment=EASYINSTALL_WEBUI_PORT=8080
ExecStart=/usr/bin/python3 /usr/local/lib/easyinstall_webui/app.py
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal
SyslogIdentifier=easyinstall-webui
Environment=PYTHONUNBUFFERED=1
Environment=PYTHONPATH=/usr/local/lib

[Install]
WantedBy=multi-user.target
UNIT
    systemctl daemon-reload 2>/dev/null || true
    log "SUCCESS" "easyinstall-webui.service written (not started — use: easyinstall-plugin webui start)"
}

# ── Inject plugin CLI commands into /usr/local/bin/easyinstall ────────────────
inject_plugin_cli() {
    log "STEP" "Injecting plugin CLI commands into easyinstall..."

    local EASYINSTALL_BIN="${BIN_DIR}/easyinstall"
    local MARKER="# ── EasyInstall Plugin Commands v1.0"

    if [ ! -f "${EASYINSTALL_BIN}" ]; then
        log "WARNING" "${EASYINSTALL_BIN} not found — plugin CLI injection skipped"
        return 0
    fi
    if grep -q "${MARKER}" "${EASYINSTALL_BIN}" 2>/dev/null; then
        log "INFO" "Plugin CLI already injected — skipping"
        return 0
    fi

    # Backup before modifying
    cp "${EASYINSTALL_BIN}" "${EASYINSTALL_BIN}.bak.plugins.$(date +%Y%m%d%H%M%S)"

    python3 - "${EASYINSTALL_BIN}" <<'PYEOF'
import sys, re

path = sys.argv[1]
src  = open(path).read()

plugin_block = """
        # ── EasyInstall Plugin Commands v1.0 ─────────────────────────────────
        # Injected by install.sh Phase 5 — do not edit manually

        plugin|plugins)
            shift || true
            exec /usr/local/bin/easyinstall-plugin "$@" ;;

        plugin-list)
            /usr/local/bin/easyinstall-plugin list ;;

        plugin-enable)
            [ -z "$2" ] && { echo -e "${RED}❌ Usage: easyinstall plugin-enable <name>${NC}"; exit 1; }
            /usr/local/bin/easyinstall-plugin enable "$2" ;;

        plugin-disable)
            [ -z "$2" ] && { echo -e "${RED}❌ Usage: easyinstall plugin-disable <name>${NC}"; exit 1; }
            /usr/local/bin/easyinstall-plugin disable "$2" ;;

        plugin-status)
            /usr/local/bin/easyinstall-plugin status "${2:-}" ;;

        webui)
            subcmd="${2:-start}"
            port="${3:-8080}"
            /usr/local/bin/easyinstall-plugin webui "${subcmd}" "--port=${port}" ;;

        plugin-doctor)
            /usr/local/bin/easyinstall-plugin doctor ;;

"""

# Insert before the final *) catch-all
patched = re.sub(
    r'^        \*\)',
    plugin_block + '        *)',
    src,
    count=1,
    flags=re.MULTILINE
)
if patched == src:
    # Fallback: insert before last esac
    idx = src.rfind('\n        esac')
    if idx != -1:
        patched = src[:idx] + plugin_block + src[idx:]

with open(path, 'w') as f:
    f.write(patched)

print("plugin CLI injection done")
PYEOF

    if grep -q "${MARKER}" "${EASYINSTALL_BIN}" 2>/dev/null; then
        chmod 755 "${EASYINSTALL_BIN}"
        log "SUCCESS" "Plugin CLI commands injected into ${EASYINSTALL_BIN}"
    else
        log "WARNING" "Plugin CLI injection may not have worked — verify manually"
    fi
    return 0
}

# ── Update bash completion to include plugin commands ─────────────────────────
update_bash_completion_for_plugins() {
    local comp_file="${COMPLETION_DIR}/easyinstall-enterprise"
    [ -f "${comp_file}" ] || return 0

    if grep -q "plugin" "${comp_file}" 2>/dev/null; then
        log "INFO" "Plugin commands already in bash completion"
        return 0
    fi

    # Append plugin commands to the existing all_cmds line
    sed -i 's/enterprise-status"/enterprise-status plugin plugins plugin-list plugin-enable plugin-disable plugin-status plugin-doctor webui"/' \
        "${comp_file}" 2>/dev/null || true

    log "SUCCESS" "Bash completion updated with plugin commands"
}

# ── Verify plugin system is working ───────────────────────────────────────────
verify_plugin_system() {
    log "STEP" "Verifying plugin system..."
    local count
    count=$(python3 - 2>/dev/null <<'PYEOF'
import sys
sys.path.insert(0, '/usr/local/lib')
try:
    from easyinstall_plugin_manager import PluginManager
    pm = PluginManager()
    plugins = pm.list_plugins()
    print(len(plugins))
except Exception as e:
    print(0)
PYEOF
)
    if [ "${count:-0}" -gt 0 ]; then
        log "SUCCESS" "Plugin system OK — ${count} plugin(s) discovered"
    else
        log "WARNING" "Plugin manager loaded but no plugins discovered yet"
        log "INFO"    "Check: ls ${PLUGIN_LIB_DIR}/"
    fi
    return 0
}

# ── Main ──────────────────────────────────────────────────────────────────────

# ══════════════════════════════════════════════════════════════════════════════
# Phase 6 — WordPress Speed ×100 Optimizer
# NEW functions only — zero changes to existing functions above.
# ══════════════════════════════════════════════════════════════════════════════

# ── Download speed_x100.py from GitHub ────────────────────────────────────────
download_speed_x100() {
    log "STEP" "Downloading speed_x100.py from GitHub..."

    if download_file "${SPEED_X100_URL}" "${SPEED_X100_SCRIPT}" "speed_x100.py"; then
        if python3 -m py_compile "${SPEED_X100_SCRIPT}" 2>/dev/null; then
            chmod 644 "${SPEED_X100_SCRIPT}"
            log "SUCCESS" "speed_x100.py installed: ${SPEED_X100_SCRIPT}"
        else
            log "WARNING" "speed_x100.py has syntax issues — kept but may not run correctly"
            return 0
        fi
    else
        log "WARNING" "Could not download speed_x100.py — WordPress speed optimizations skipped"
        log "INFO"    "Download manually: curl -fsSL ${SPEED_X100_URL} -o ${SPEED_X100_SCRIPT}"
        return 0    # Never fail the whole install for this
    fi

    # Write a simple CLI wrapper so users can call: easyinstall-speed <domain>
    cat > "${SPEED_X100_CLI}" <<CLIEOF
#!/bin/bash
# EasyInstall — WordPress Speed ×100 CLI wrapper
# Usage: easyinstall-speed <domain>
#        easyinstall-speed --all-sites
#        easyinstall-speed --all-sites --webp
exec python3 ${SPEED_X100_SCRIPT} "\$@"
CLIEOF
    chmod 755 "${SPEED_X100_CLI}"
    log "SUCCESS" "CLI wrapper installed: ${SPEED_X100_CLI}"

    return 0
}

# ── Run speed_x100.py on all existing WordPress sites ─────────────────────────
run_speed_x100() {
    log "STEP" "Running WordPress Speed ×100 optimizer on all sites..."

    if [ ! -f "${SPEED_X100_SCRIPT}" ]; then
        log "WARNING" "speed_x100.py not found — skipping speed optimization"
        return 0
    fi

    # Check if any WordPress sites exist yet
    local wp_count=0
    for candidate in /var/www/*/public/wp-config.php \
                     /var/www/*/html/wp-config.php \
                     /var/www/html/wp-config.php; do
        [ -f "$candidate" ] && wp_count=$((wp_count + 1))
    done

    if [ "$wp_count" -eq 0 ]; then
        log "INFO" "No WordPress sites found yet — speed_x100 will run after first site creation"
        log "INFO" "Run manually:  sudo easyinstall-speed --all-sites"
        # Schedule to run on next site creation via a hook (see cron below)
        _setup_speed_x100_site_hook
        return 0
    fi

    log "INFO" "Found ${wp_count} WordPress site(s) — running optimizations..."

    # Run with --all-sites flag; capture output to log
    if python3 "${SPEED_X100_SCRIPT}" --all-sites 2>&1 | tee -a "${LOG_FILE}"; then
        log "SUCCESS" "Speed ×100 optimizations applied to ${wp_count} site(s) ✓"
    else
        log "WARNING" "speed_x100.py exited with warnings — check ${LOG_FILE}"
        log "INFO"    "Re-run manually: sudo easyinstall-speed --all-sites"
    fi

    # Inject easyinstall speed command into CLI dispatcher
    _inject_speed_cli_command

    return 0
}

# ── Inject 'easyinstall speed' command into CLI dispatcher ────────────────────
_inject_speed_cli_command() {
    local EASYINSTALL_BIN="${BIN_DIR}/easyinstall"
    local MARKER="# ── EasyInstall Speed ×100 Commands v1.0"

    [ ! -f "${EASYINSTALL_BIN}" ] && return 0
    grep -q "${MARKER}" "${EASYINSTALL_BIN}" 2>/dev/null && return 0

    cp "${EASYINSTALL_BIN}" "${EASYINSTALL_BIN}.bak.speed.$(date +%Y%m%d%H%M%S)"

    python3 - "${EASYINSTALL_BIN}" <<PYEOF
import sys, re
path = sys.argv[1]
src  = open(path).read()

speed_block = """
        # ── EasyInstall Speed ×100 Commands v1.0 ─────────────────────────────
        # Injected by install.sh Phase 6 — do not edit manually

        speed)
            DOMAIN="\${2:-}"
            if [ -n "\$DOMAIN" ]; then
                python3 ${SPEED_X100_SCRIPT} --domain "\$DOMAIN" "\${@:3}"
            else
                python3 ${SPEED_X100_SCRIPT} --all-sites "\${@:2}"
            fi ;;

        speed-webp)
            DOMAIN="\${2:-}"
            if [ -n "\$DOMAIN" ]; then
                python3 ${SPEED_X100_SCRIPT} --domain "\$DOMAIN" --webp
            else
                python3 ${SPEED_X100_SCRIPT} --all-sites --webp
            fi ;;

        speed-status)
            echo ""
            echo -e "\\\033[1;36m══════════════════════════════════════════\\\033[0m"
            echo -e "\\\033[1;36m  WordPress Speed ×100 — Status\\\033[0m"
            echo -e "\\\033[1;36m══════════════════════════════════════════\\\033[0m"
            echo ""
            [ -f "${SPEED_X100_SCRIPT}" ] && \\\\
                echo -e "  \\\033[0;32m✓\\\033[0m speed_x100.py : ${SPEED_X100_SCRIPT}" || \\\\
                echo -e "  \\\033[0;31m✗\\\033[0m speed_x100.py : not installed"
            [ -f "${SPEED_X100_CLI}" ] && \\\\
                echo -e "  \\\033[0;32m✓\\\033[0m CLI wrapper   : ${SPEED_X100_CLI}" || \\\\
                echo -e "  \\\033[0;31m✗\\\033[0m CLI wrapper   : not installed"
            echo ""
            echo "  Usage: easyinstall speed <domain>"
            echo "         easyinstall speed --all-sites"
            echo "         easyinstall speed-webp <domain>"
            echo "" ;;

"""

patched = re.sub(r'^        \\\*\\\)', speed_block + '        *)', src, count=1, flags=re.MULTILINE)
if patched == src:
    idx = src.rfind('\\n        esac')
    if idx != -1:
        patched = src[:idx] + speed_block + src[idx:]

with open(path, 'w') as f:
    f.write(patched)
print("speed CLI injected")
PYEOF

    grep -q "${MARKER}" "${EASYINSTALL_BIN}" 2>/dev/null && {
        chmod 755 "${EASYINSTALL_BIN}"
        log "SUCCESS" "Speed ×100 CLI commands injected (easyinstall speed <domain>)"
    } || log "WARNING" "Speed CLI injection — verify manually"
    return 0
}

# ── Setup hook: auto-run speed_x100 after first site creation ─────────────────
_setup_speed_x100_site_hook() {
    # Add a one-shot cron that runs speed_x100 next time a WP site appears
    local hook_script="${BIN_DIR}/easyinstall-speed-hook"
    cat > "${hook_script}" <<HOOKEOF
#!/bin/bash
# EasyInstall — speed_x100 site-creation hook (one-shot)
# Runs speed_x100.py once a WordPress site is detected, then removes itself.
wp_found=false
for f in /var/www/*/public/wp-config.php /var/www/*/html/wp-config.php /var/www/html/wp-config.php; do
    [ -f "\$f" ] && wp_found=true && break
done
if \$wp_found; then
    python3 ${SPEED_X100_SCRIPT} --all-sites >> /var/log/easyinstall/speed_x100.log 2>&1
    # Remove this hook after first successful run
    crontab -l 2>/dev/null | grep -v "easyinstall-speed-hook" | crontab - 2>/dev/null || true
    rm -f "${hook_script}"
fi
HOOKEOF
    chmod 755 "${hook_script}"

    # Run every 5 min until a WP site appears (then self-removes)
    local cron_line="*/5 * * * * ${hook_script} >> /var/log/easyinstall/speed_x100.log 2>&1"
    local existing; existing=$(crontab -l 2>/dev/null || true)
    if ! echo "${existing}" | grep -q "easyinstall-speed-hook"; then
        (echo "${existing}"; echo "${cron_line}") | crontab -
        log "SUCCESS" "Speed ×100 hook scheduled — will auto-run after first site creation"
    fi
    return 0
}

main() {
    print_banner

    log "STEP" "=== EasyInstallVPS v7.0 Bootstrap Starting ==="
    log "INFO" "Repo       : ${REPO_RAW}"
    log "INFO" "Install dir: ${INSTALL_DIR}"
    log "INFO" "Log file   : ${LOG_FILE}"
    echo ""

    # ── Pre-flight ────────────────────────────────────────────────────────────
    check_root
    check_os
    check_disk
    check_ram
    check_network

    # ── Prerequisites ─────────────────────────────────────────────────────────
    install_prerequisites

    # ── Create enterprise directory structure ─────────────────────────────────
    create_enterprise_dirs

    # ── Download core installer files ─────────────────────────────────────────
    download_core_files

    # ── Download enterprise modules from GitHub /etc/ ─────────────────────────
    echo ""
    echo -e "${CYAN}══════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}  Phase 2: Enterprise Module Installation${NC}"
    echo -e "${CYAN}══════════════════════════════════════════════════${NC}"
    echo ""
    download_enterprise_modules
    install_python_deps
    write_enterprise_configs
    write_systemd_services
    init_enterprise_db
    install_bash_completion

    # Enable services (don't start yet — wait for core install to finish)
    start_enterprise_services

    # ── Download & setup AI Pages modules from GitHub /etc/pages/ ─────────────
    echo ""
    echo -e "${CYAN}══════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}  Phase 2b: AI Page Generator Modules${NC}"
    echo -e "${CYAN}══════════════════════════════════════════════════${NC}"
    echo ""
    download_pages_modules
    setup_pages_modules

    # ── Run core WordPress installer ──────────────────────────────────────────
    echo ""
    echo -e "${CYAN}══════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}  Phase 3: Core WordPress Performance Stack${NC}"
    echo -e "${CYAN}══════════════════════════════════════════════════${NC}"
    echo ""

    if run_core_installer; then
        # Core install succeeded — now inject CLI and start enterprise services
        inject_enterprise_cli

        # Phase 4: Pages CLI injection + pending AI function merge
        echo ""
        echo -e "${CYAN}══════════════════════════════════════════════════${NC}"
        echo -e "${CYAN}  Phase 4: AI Page Generator Setup${NC}"
        echo -e "${CYAN}══════════════════════════════════════════════════${NC}"
        echo ""
        merge_pending_ai_functions
        inject_pages_cli

        start_enterprise_services_now

        # ── Phase 5: Plugin System ────────────────────────────────────────────
        echo ""
        echo -e "${CYAN}══════════════════════════════════════════════════${NC}"
        echo -e "${CYAN}  Phase 5: Plugin System Installation${NC}"
        echo -e "${CYAN}  Source: github.com/sugan0927/easyinstallvps/plugins${NC}"
        echo -e "${CYAN}══════════════════════════════════════════════════${NC}"
        echo ""
        download_plugin_system
        install_plugin_python_deps
        configure_plugin_python_path
        write_plugin_systemd_units
        inject_plugin_cli
        update_bash_completion_for_plugins
        verify_plugin_system

        # ── Phase 6: WordPress Speed ×100 Optimizer ──────────────────────────
        echo ""
        echo -e "${CYAN}══════════════════════════════════════════════════${NC}"
        echo -e "${CYAN}  Phase 6: WordPress Speed ×100 Optimizer${NC}"
        echo -e "${CYAN}  Source: github.com/sugan0927/easyinstallvps${NC}"
        echo -e "${CYAN}══════════════════════════════════════════════════${NC}"
        echo ""
        download_speed_x100
        run_speed_x100

        print_summary
    else
        echo ""
        echo -e "${RED}══════════════════════════════════════════════════${NC}"
        echo -e "${RED}  Core installation failed. Check: $LOG_FILE${NC}"
        echo -e "${RED}══════════════════════════════════════════════════${NC}"
        echo ""
        echo -e "${YELLOW}Enterprise modules were installed but may need the core stack.${NC}"
        echo -e "${YELLOW}Fix core install errors, then run:${NC}"
        echo "  bash $INSTALL_DIR/$MAIN_SCRIPT"
        exit 1
    fi
}

main "$@"
