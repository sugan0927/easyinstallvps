#!/bin/bash

# ============================================
# EasyInstall v6.4 HYBRID EDITION — Installer
# ============================================
# Modified to work with one-liner curl pipe installation
# Now automatically downloads all required files from GitHub
# ============================================

set -eE
trap '_installer_error $LINENO' ERR

# ── Colour codes ──────────────────────────────────────────────────────────────
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'
BLUE='\033[0;34m';  PURPLE='\033[0;35m'; CYAN='\033[0;36m'; NC='\033[0m'

# ── Paths & constants ─────────────────────────────────────────────────────────
INSTALLER_VERSION="6.4"
INSTALL_DIR="/usr/local/lib/easyinstall"
LIB_DIR="/usr/local/lib"
BIN_DIR="/usr/local/bin"
LOG_DIR="/var/log/easyinstall"
INSTALL_LOG="$LOG_DIR/installer.log"
TMP_DIR="/tmp/easyinstall-$$"  # Unique temp directory

# Default GitHub repository (using your repo)
GITHUB_RAW="https://raw.githubusercontent.com/sugan0927/easyinstallvps/main"

# Source-file URLs (can be overridden via env)
EASYINSTALL_SH_URL="${EASYINSTALL_SH_URL:-$GITHUB_RAW/easyinstall.sh}"
EASYINSTALL_PY_URL="${EASYINSTALL_PY_URL:-$GITHUB_RAW/easyinstall_config.py}"

# Runtime flags
OPT_REINSTALL=false
OPT_NO_RUN=false
OPT_AUTO_RUN=false

# ── Error trap ────────────────────────────────────────────────────────────────
_installer_error() {
    echo -e "${RED}❌  Installer failed at line $1 — check $INSTALL_LOG${NC}"
    rm -rf "$TMP_DIR" 2>/dev/null || true
    exit 1
}

# ── Logging ───────────────────────────────────────────────────────────────────
log() {
    local level="$1" msg="$2"
    local ts; ts=$(date '+%Y-%m-%d %H:%M:%S')
    mkdir -p "$LOG_DIR" 2>/dev/null || true
    printf '[%s] [%s] %s\n' "$ts" "$level" "$msg" >> "$INSTALL_LOG" 2>/dev/null || true
    case "$level" in
        ERROR)   printf "${RED}❌  %s${NC}\n"     "$msg" ;;
        WARNING) printf "${YELLOW}⚠️   %s${NC}\n"  "$msg" ;;
        SUCCESS) printf "${GREEN}✅  %s${NC}\n"    "$msg" ;;
        INFO)    printf "${BLUE}ℹ️   %s${NC}\n"    "$msg" ;;
        STEP)    printf "${PURPLE}🔷  %s${NC}\n"   "$msg" ;;
        *)       printf "    %s\n"                 "$msg" ;;
    esac
}

# ═══════════════════════════════════════════════════════════════════════════════
# SECTION 1 — PREFLIGHT CHECKS
# ═══════════════════════════════════════════════════════════════════════════════

check_root() {
    log "STEP" "Checking root privileges"
    if [[ "$EUID" -ne 0 ]]; then
        log "ERROR" "This installer must be run as root. Try: sudo bash install.sh"
        exit 1
    fi
    log "SUCCESS" "Running as root"
}

check_os() {
    log "STEP" "Checking OS compatibility"
    local os_id="" os_ver=""
    [[ -f /etc/os-release ]] && { source /etc/os-release; os_id="$ID"; os_ver="$VERSION_ID"; }
    case "$os_id" in
        ubuntu)
            [[ "$os_ver" =~ ^(20\.04|22\.04|24\.04)$ ]] \
                && log "SUCCESS" "OS: Ubuntu $os_ver" \
                || log "WARNING" "Ubuntu $os_ver not officially tested (supported: 20.04/22.04/24.04)"
            ;;
        debian)
            local major="${os_ver%%.*}"
            (( major >= 11 )) \
                && log "SUCCESS" "OS: Debian $os_ver" \
                || { log "ERROR" "Debian $os_ver too old — need Debian 11+"; exit 1; }
            ;;
        *) log "WARNING" "OS '$os_id' not officially supported — proceeding anyway" ;;
    esac
}

check_disk() {
    log "STEP" "Checking disk space"
    local avail; avail=$(df -m / | awk 'NR==2{print $4}')
    (( avail >= 100 )) \
        && log "SUCCESS" "Disk OK: ${avail}MB free" \
        || { log "ERROR" "Need ≥100MB free, only ${avail}MB available"; exit 1; }
}

check_network() {
    log "STEP" "Checking network connectivity"
    if ping -c1 -W5 8.8.8.8 &>/dev/null || curl -s --head --max-time 5 https://google.com | grep -q "200"; then
        log "SUCCESS" "Network OK"
    else
        log "ERROR" "No internet connectivity - cannot download required files"
        exit 1
    fi
}

# ═══════════════════════════════════════════════════════════════════════════════
# SECTION 2 — DEPENDENCY BOOTSTRAP
# ═══════════════════════════════════════════════════════════════════════════════

ensure_python3() {
    log "STEP" "Checking Python 3"
    if ! command -v python3 &>/dev/null; then
        log "INFO" "Python3 not found — installing via apt"
        apt-get update -y -qq 2>/dev/null
        apt-get install -y -qq python3 2>/dev/null
    fi
    local ver; ver=$(python3 --version 2>&1 | awk '{print $2}')
    log "SUCCESS" "Python3: $ver"
}

ensure_downloader() {
    command -v curl &>/dev/null || command -v wget &>/dev/null && return 0
    log "INFO" "No downloader found — installing curl"
    apt-get update -y -qq 2>/dev/null
    apt-get install -y -qq curl 2>/dev/null
    log "SUCCESS" "curl installed"
}

# ═══════════════════════════════════════════════════════════════════════════════
# SECTION 3 — DOWNLOAD REQUIRED FILES
# ═══════════════════════════════════════════════════════════════════════════════

_download_file() {
    local url="$1" dest="$2" name="$3"
    log "INFO" "Downloading $name..."
    
    if command -v curl &>/dev/null; then
        if ! curl -fsSL --retry 3 --retry-delay 2 "$url" -o "$dest"; then
            log "ERROR" "Failed to download $name from $url"
            return 1
        fi
    else
        if ! wget -q --tries=3 --timeout=10 "$url" -O "$dest"; then
            log "ERROR" "Failed to download $name from $url"
            return 1
        fi
    fi
    
    if [[ ! -s "$dest" ]]; then
        log "ERROR" "Downloaded $name is empty"
        return 1
    fi
    
    chmod +x "$dest" 2>/dev/null || true
    log "SUCCESS" "Downloaded $name"
    return 0
}

download_all_files() {
    log "STEP" "Creating temporary directory: $TMP_DIR"
    mkdir -p "$TMP_DIR"
    
    # Download easyinstall.sh
    if ! _download_file "$EASYINSTALL_SH_URL" "$TMP_DIR/easyinstall.sh" "easyinstall.sh"; then
        exit 1
    fi
    
    # Download easyinstall_config.py
    if ! _download_file "$EASYINSTALL_PY_URL" "$TMP_DIR/easyinstall_config.py" "easyinstall_config.py"; then
        exit 1
    fi
    
    # Set source variables
    SH_SOURCE="$TMP_DIR/easyinstall.sh"
    PY_SOURCE="$TMP_DIR/easyinstall_config.py"
    
    log "SUCCESS" "All files downloaded successfully"
}

# ═══════════════════════════════════════════════════════════════════════════════
# SECTION 4 — VALIDATION
# ═══════════════════════════════════════════════════════════════════════════════

validate_sources() {
    log "STEP" "Validating source files"

    # Bash syntax
    if ! bash -n "$SH_SOURCE" 2>/dev/null; then
        log "ERROR" "easyinstall.sh has syntax errors — aborting"
        bash -n "$SH_SOURCE" 2>&1 | head -5 | while read line; do log "ERROR" "  $line"; done
        exit 1
    fi
    log "SUCCESS" "easyinstall.sh — bash syntax clean"

    # Python syntax
    if ! python3 -m py_compile "$PY_SOURCE" 2>/dev/null; then
        log "ERROR" "easyinstall_config.py has syntax errors — aborting"
        python3 -m py_compile "$PY_SOURCE" 2>&1 | head -5 | while read line; do log "ERROR" "  $line"; done
        exit 1
    fi
    log "SUCCESS" "easyinstall_config.py — python syntax clean"

    # Sanity checks
    grep -q "SCRIPT_VERSION" "$SH_SOURCE" || log "WARNING" "easyinstall.sh may be incomplete"
    grep -q "STAGE_MAP" "$PY_SOURCE" || log "WARNING" "easyinstall_config.py may be incomplete"

    log "SUCCESS" "Source file validation complete"
}

# ═══════════════════════════════════════════════════════════════════════════════
# SECTION 5 — INSTALLATION
# ═══════════════════════════════════════════════════════════════════════════════

create_directories() {
    log "STEP" "Creating directory structure"
    mkdir -p \
        "$INSTALL_DIR" \
        "$LOG_DIR" \
        "$BIN_DIR" \
        /var/lib/easyinstall \
        /etc/easyinstall \
        /var/www/html \
        /backups/daily /backups/weekly /backups/monthly \
        /etc/nginx/{sites-available,sites-enabled,conf.d,snippets,ssl} \
        /root/easyinstall-backups
    chmod 755 /backups 2>/dev/null || true
    log "SUCCESS" "Directories created"
}

install_files() {
    log "STEP" "Installing easyinstall.sh → $INSTALL_DIR/"
    cp "$SH_SOURCE" "$INSTALL_DIR/easyinstall.sh"
    chmod 755 "$INSTALL_DIR/easyinstall.sh"

    log "STEP" "Installing easyinstall_config.py → $LIB_DIR/"
    cp "$PY_SOURCE" "$LIB_DIR/easyinstall_config.py"
    chmod 755 "$LIB_DIR/easyinstall_config.py"

    # Co-locate Python file for deploy_python_script()
    cp "$PY_SOURCE" "$INSTALL_DIR/easyinstall_config.py"
    chmod 644 "$INSTALL_DIR/easyinstall_config.py"

    log "SUCCESS" "Both files installed"
}

install_launcher() {
    log "STEP" "Creating launcher: $BIN_DIR/easyinstall-install"

    cat > "$BIN_DIR/easyinstall-install" << 'EOF'
#!/bin/bash
# EasyInstall v6.4 HYBRID — full server setup launcher
exec bash /usr/local/lib/easyinstall/easyinstall.sh "$@"
EOF
    chmod 755 "$BIN_DIR/easyinstall-install"

    # Create convenience aliases
    ln -sf "$BIN_DIR/easyinstall-install" "$BIN_DIR/easyinstall-run" 2>/dev/null || true
    ln -sf "$BIN_DIR/easyinstall-install" "$BIN_DIR/easyinstall" 2>/dev/null || true

    log "SUCCESS" "Launcher ready: easyinstall-install"
}

write_version_info() {
    local sh_lines py_lines sh_md5 py_md5
    sh_lines=$(wc -l < "$INSTALL_DIR/easyinstall.sh")
    py_lines=$(wc -l < "$LIB_DIR/easyinstall_config.py")
    sh_md5=$(md5sum "$INSTALL_DIR/easyinstall.sh" 2>/dev/null | awk '{print $1}' || echo "n/a")
    py_md5=$(md5sum "$LIB_DIR/easyinstall_config.py" 2>/dev/null | awk '{print $1}' || echo "n/a")

    cat > /var/lib/easyinstall/installer.info << EOF
INSTALLER_VERSION=$INSTALLER_VERSION
INSTALL_DATE=$(date '+%Y-%m-%d %H:%M:%S')
INSTALL_USER=$(whoami)
EASYINSTALL_SH=$INSTALL_DIR/easyinstall.sh
EASYINSTALL_SH_LINES=$sh_lines
EASYINSTALL_SH_MD5=$sh_md5
EASYINSTALL_PY=$LIB_DIR/easyinstall_config.py
EASYINSTALL_PY_LINES=$py_lines
EASYINSTALL_PY_MD5=$py_md5
LAUNCHER=$BIN_DIR/easyinstall-install
EOF
    log "SUCCESS" "Version info → /var/lib/easyinstall/installer.info"
}

patch_path() {
    local bashrc="/root/.bashrc"
    if [[ -f "$bashrc" ]] && ! grep -q '/usr/local/bin' "$bashrc"; then
        printf '\nexport PATH="$PATH:/usr/local/bin"\n' >> "$bashrc"
        log "INFO" "Added /usr/local/bin to PATH in ~/.bashrc"
    fi
}

# ═══════════════════════════════════════════════════════════════════════════════
# SECTION 6 — SMOKE TESTS
# ═══════════════════════════════════════════════════════════════════════════════

smoke_test() {
    log "STEP" "Running smoke tests"
    local all_ok=true

    # Python module responds to unknown stage
    local py_resp
    py_resp=$(python3 "$LIB_DIR/easyinstall_config.py" --stage __nonexistent__ 2>&1 || true)
    if echo "$py_resp" | grep -q "Unknown stage"; then
        log "SUCCESS" "Python module CLI: responds correctly"
    else
        log "WARNING" "Python module CLI: unexpected response (non-fatal)"
    fi

    # Stage count check
    local stage_count
    stage_count=$(python3 -c "
import warnings, importlib.util
warnings.filterwarnings('ignore')
spec = importlib.util.spec_from_file_location('ec', '/usr/local/lib/easyinstall_config.py')
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
print(len(mod.STAGE_MAP))
" 2>/dev/null || echo "0")
    
    if (( stage_count >= 23 )); then
        log "SUCCESS" "Python stages registered: $stage_count"
    else
        log "WARNING" "Python stage count low: $stage_count (expected ≥23)"
    fi

    # Launcher executable
    if [[ -x "$BIN_DIR/easyinstall-install" ]]; then
        log "SUCCESS" "Launcher is executable: $BIN_DIR/easyinstall-install"
    else
        log "WARNING" "Launcher not executable"
    fi
}

# ═══════════════════════════════════════════════════════════════════════════════
# SECTION 7 — CLEANUP
# ═══════════════════════════════════════════════════════════════════════════════

cleanup() {
    log "STEP" "Cleaning up temporary files"
    rm -rf "$TMP_DIR" 2>/dev/null || true
    log "SUCCESS" "Cleanup completed"
}

# ═══════════════════════════════════════════════════════════════════════════════
# SECTION 8 — OUTPUT
# ═══════════════════════════════════════════════════════════════════════════════

print_summary() {
    local sh_lines py_lines
    sh_lines=$(wc -l < "$INSTALL_DIR/easyinstall.sh")
    py_lines=$(wc -l < "$LIB_DIR/easyinstall_config.py")

    echo ""
    echo -e "${GREEN}╔══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║  ✅  EasyInstall v${INSTALLER_VERSION} HYBRID — Installed Successfully   ║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${YELLOW}📁 Installed files:${NC}"
    echo -e "   ${CYAN}Bash layer  ${NC}  $INSTALL_DIR/easyinstall.sh       ${sh_lines} lines"
    echo -e "   ${CYAN}Python layer${NC}  $LIB_DIR/easyinstall_config.py   ${py_lines} lines"
    echo -e "   ${CYAN}Launcher    ${NC}  $BIN_DIR/easyinstall-install"
    echo -e "   ${CYAN}Log         ${NC}  $INSTALL_LOG"
    echo ""
    echo -e "${YELLOW}🚀 To run the full WordPress server setup:${NC}"
    echo ""
    echo -e "     ${GREEN}sudo easyinstall-install${NC}"
    echo ""
    echo -e "${YELLOW}📋 The full setup installs and configures:${NC}"
    echo -e "   Nginx  ·  PHP 8.4/8.3/8.2  ·  MariaDB 11  ·  Redis 7"
    echo -e "   Certbot  ·  Fail2ban  ·  Auto-tuning (10 phases)  ·  AI module"
    echo -e "   WebSocket support  ·  HTTP/3+QUIC  ·  Edge computing layer"
    echo ""
    echo -e "${YELLOW}⚡ After full setup, manage WordPress sites with:${NC}"
    echo -e "   easyinstall create mysite.com --ssl   # new site"
    echo -e "   easyinstall help                       # all commands"
    echo -e "   easyinstall monitor                    # live dashboard"
    echo ""
    echo -e "${YELLOW}📝 Installer log:${NC} $INSTALL_LOG"
    echo -e "${YELLOW}☕ Support      :${NC} https://paypal.me/sugandodrai"
    echo -e "${GREEN}══════════════════════════════════════════════════════════${NC}"
}

# ═══════════════════════════════════════════════════════════════════════════════
# SECTION 9 — SPECIAL MODES
# ═══════════════════════════════════════════════════════════════════════════════

do_uninstall() {
    echo -e "${YELLOW}⚠️  Uninstalling EasyInstall v${INSTALLER_VERSION} HYBRID…${NC}"
    echo -e "   (WordPress sites, databases, and service configs are NOT touched)"
    echo ""
    read -r -p "   Continue? [y/N]: " confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }

    local removed=0
    for f in \
        "$BIN_DIR/easyinstall-install" \
        "$BIN_DIR/easyinstall-run" \
        "$BIN_DIR/easyinstall" \
        "$LIB_DIR/easyinstall_config.py" \
        /var/lib/easyinstall/installer.info
    do
        rm -f "$f" 2>/dev/null && (( removed++ )) || true
    done
    rm -rf "$INSTALL_DIR" 2>/dev/null && true

    echo -e "${GREEN}✅ Removed $removed file(s) and $INSTALL_DIR/${NC}"
    echo -e "${YELLOW}   Logs kept at $LOG_DIR/${NC}"
    exit 0
}

do_reinstall() {
    log "INFO" "Reinstall mode — clearing old installed files"
    rm -f "$LIB_DIR/easyinstall_config.py" 2>/dev/null || true
    rm -f "$INSTALL_DIR/easyinstall.sh" 2>/dev/null || true
    rm -f "$INSTALL_DIR/easyinstall_config.py" 2>/dev/null || true
    rm -f "$BIN_DIR/easyinstall-install" 2>/dev/null || true
    rm -f "$BIN_DIR/easyinstall-run" 2>/dev/null || true
    log "SUCCESS" "Old files cleared — continuing with fresh install"
}

do_status() {
    echo ""
    echo -e "${CYAN}EasyInstall HYBRID — Installed File Status${NC}"
    echo -e "${BLUE}══════════════════════════════════════════${NC}"
    local entries=(
        "$INSTALL_DIR/easyinstall.sh|Bash layer (main installer)"
        "$LIB_DIR/easyinstall_config.py|Python layer (config generator)"
        "$BIN_DIR/easyinstall-install|Server setup launcher"
    )
    for entry in "${entries[@]}"; do
        local path="${entry%%|*}" desc="${entry##*|}"
        if [[ -f "$path" ]]; then
            local lines; lines=$(wc -l < "$path" 2>/dev/null || echo "?")
            printf "  ${GREEN}✅${NC}  %-52s %s lines\n" "$path" "$lines"
            printf "       %s\n" "$desc"
        else
            printf "  ${YELLOW}–${NC}   %-52s\n" "$path"
            printf "       %s\n" "$desc"
        fi
        echo ""
    done
    if [[ -f /var/lib/easyinstall/installer.info ]]; then
        echo -e "${YELLOW}Installer info:${NC}"
        cat /var/lib/easyinstall/installer.info | sed 's/^/  /'
    fi
    exit 0
}

# ═══════════════════════════════════════════════════════════════════════════════
# SECTION 10 — ARGUMENT PARSER
# ═══════════════════════════════════════════════════════════════════════════════

parse_args() {
    for arg in "$@"; do
        case "$arg" in
            --uninstall|-u) do_uninstall ;;
            --reinstall|-r) OPT_REINSTALL=true ;;
            --status|-s)    do_status ;;
            --no-run)       OPT_NO_RUN=true ;;
            --run)          OPT_AUTO_RUN=true ;;
            --help|-h)
                cat << 'HELP'
Usage: sudo bash install.sh [OPTIONS]

Installs easyinstall.sh and easyinstall_config.py to your server.

Options:
  (no args)      Install files, then prompt to run full setup
  --run          Install files AND immediately run full server setup
  --no-run       Install files only — skip the run prompt
  --reinstall    Remove old installed files, then reinstall
  --uninstall    Remove installed files (sites/DBs untouched)
  --status       Show status of all installed files
  --help         Show this help message

Examples:
  # One-liner installation (from your Cloudflare Worker):
  curl -fsSL https://YOUR_WORKER.workers.dev/install.sh | sudo bash

  # Install and immediately run full setup:
  curl -fsSL https://YOUR_WORKER.workers.dev/install.sh | sudo bash -s -- --run
HELP
                exit 0
                ;;
            *) log "WARNING" "Unknown argument: '$arg' (ignored)" ;;
        esac
    done
}

# ═══════════════════════════════════════════════════════════════════════════════
# SECTION 11 — MAIN
# ═══════════════════════════════════════════════════════════════════════════════

main() {
    clear 2>/dev/null || true
    echo ""
    echo -e "${GREEN}╔══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║   EasyInstall v${INSTALLER_VERSION} HYBRID — File Installer             ║${NC}"
    echo -e "${GREEN}║   One-liner installation from GitHub                     ║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════════════════════╝${NC}"
    echo ""

    # Initialise log
    mkdir -p "$LOG_DIR" 2>/dev/null || true
    echo "=== Installer started: $(date) ===" >> "$INSTALL_LOG" 2>/dev/null || true

    # Parse CLI flags
    parse_args "$@"

    # Preflight checks
    check_root
    check_os
    check_disk
    check_network
    ensure_python3
    ensure_downloader

    # Reinstall mode
    [[ "$OPT_REINSTALL" == true ]] && do_reinstall

    # DOWNLOAD FILES FROM GITHUB
    download_all_files

    # Validate downloaded files
    validate_sources

    # Install files
    create_directories
    install_files
    install_launcher
    write_version_info
    patch_path

    # Clean up temp files
    cleanup

    # Smoke tests
    smoke_test

    # Summary
    print_summary

    # ═══════════════════════════════════════════════════════════
    # DECIDE WHETHER TO RUN THE FULL SERVER SETUP
    # ═══════════════════════════════════════════════════════════
    if [[ "$OPT_NO_RUN" == true ]]; then
        log "INFO" "--no-run: skipping server setup (run later with: sudo easyinstall-install)"
        exit 0
    fi

    if [[ "$OPT_AUTO_RUN" == true ]]; then
        echo ""
        log "STEP" "--run flag: launching full WordPress server setup now…"
        echo ""
        # Don't use exec - just call it normally
        bash "$INSTALL_DIR/easyinstall.sh"
        exit $?
    fi

    # Interactive prompt
    echo ""
    echo -e "${YELLOW}┌──────────────────────────────────────────────────────────┐${NC}"
    echo -e "${YELLOW}│  Files are installed and ready.                           │${NC}"
    echo -e "${YELLOW}│                                                            │${NC}"
    echo -e "${YELLOW}│  Run the full WordPress server setup now?                 │${NC}"
    echo -e "${YELLOW}└──────────────────────────────────────────────────────────┘${NC}"
    echo ""
    read -r -p "  Start full server setup now? [Y/n]: " answer
    answer="${answer:-Y}"

    if [[ "$answer" =~ ^[Yy]$ ]]; then
        echo ""
        log "STEP" "Launching full WordPress server setup…"
        echo ""
        # Don't use exec - just call it normally
        bash "$INSTALL_DIR/easyinstall.sh"
    else
        echo ""
        log "SUCCESS" "Skipped. Run the server setup any time with:"
        echo ""
        echo -e "     ${GREEN}sudo easyinstall-install${NC}"
        echo ""
    fi
}

# Run main function
main "$@"
