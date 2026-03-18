#!/bin/bash

# ============================================
# EasyInstall v6.4 HYBRID EDITION — Installer
# ============================================
# Downloads and installs:
#   • easyinstall.sh         (Bash: dependency layer)
#   • easyinstall_config.py  (Python: configuration layer)
#
# One-liner usage (downloads files automatically from GitHub):
#   wget -qO- https://raw.githubusercontent.com/sugandodrai/easyinstall/main/install.sh | bash
#   curl -fsSL https://raw.githubusercontent.com/sugandodrai/easyinstall/main/install.sh | bash
#
# Local usage (all 3 files in same directory):
#   sudo bash install.sh
#
# Custom mirror (if GitHub is blocked):
#   EASYINSTALL_SH_URL=https://your.mirror.com/easyinstall.sh \
#   EASYINSTALL_PY_URL=https://your.mirror.com/easyinstall_config.py \
#   sudo bash install.sh
#
# Flags:
#   --run        Install + immediately start full server setup
#   --no-run     Install files only, skip prompt
#   --reinstall  Remove old files, then reinstall
#   --uninstall  Remove installed files
#   --status     Show status of installed files
#   --help       Show help
#
# Compatible: Debian 11/12  |  Ubuntu 20.04 / 22.04 / 24.04
# Requires  : root
# ============================================

set -eE
trap '_installer_error $LINENO' ERR

# ── Re-entry guard ────────────────────────────────────────────────────────────
# Prevents the installer from running multiple times when piped via
# wget/curl | bash (some CDN/proxy pages accidentally re-execute the script).
if [[ -n "${EASYINSTALL_RUNNING:-}" ]]; then
    exit 0
fi
export EASYINSTALL_RUNNING=1

# ── Colour codes ──────────────────────────────────────────────────────────────
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'
BLUE='\033[0;34m';  PURPLE='\033[0;35m'; CYAN='\033[0;36m'; NC='\033[0m'

# ── Paths & constants ─────────────────────────────────────────────────────────
INSTALLER_VERSION="6.4"
INSTALL_DIR="/usr/local/lib/easyinstall"   # Bash script lives here
LIB_DIR="/usr/local/lib"                   # Python module lives here
BIN_DIR="/usr/local/bin"                   # Wrapper symlinks
LOG_DIR="/var/log/easyinstall"
INSTALL_LOG="$LOG_DIR/installer.log"

# Source-file URLs (override via env if hosting remotely)
# ── Default download URLs — GitHub primary + jsDelivr mirror ─────────────────
# Set EASYINSTALL_SH_URL / EASYINSTALL_PY_URL env vars to use a custom host.
_GITHUB_BASE="https://raw.githubusercontent.com/sugandodrai/easyinstall/main"
_MIRROR_BASE="https://cdn.jsdelivr.net/gh/sugandodrai/easyinstall@main"
EASYINSTALL_SH_URL="${EASYINSTALL_SH_URL:-${_GITHUB_BASE}/easyinstall.sh}"
EASYINSTALL_PY_URL="${EASYINSTALL_PY_URL:-${_GITHUB_BASE}/easyinstall_config.py}"
_MIRROR_SH_URL="${_MIRROR_BASE}/easyinstall.sh"
_MIRROR_PY_URL="${_MIRROR_BASE}/easyinstall_config.py"

# Runtime flags (set by parse_args)
OPT_REINSTALL=false
OPT_NO_RUN=false
OPT_AUTO_RUN=false

# ── Error trap ────────────────────────────────────────────────────────────────
_installer_error() {
    echo -e "${RED}❌  Installer failed at line $1 — check $INSTALL_LOG${NC}"
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
        log "ERROR" "This installer must be run as root.  Try: sudo bash install.sh"
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
    local ok=false
    ping -c1 -W5 8.8.8.8 &>/dev/null && ok=true
    $ok || curl -s --head --max-time 5 https://google.com | grep -q "200" && ok=true
    if $ok; then
        log "SUCCESS" "Network OK"
    else
        log "WARNING" "Network check failed — if this is an offline/local install, this is expected"
        log "WARNING" "Continuing anyway — files can be installed from local directory without internet"
        # Only hard-fail if we actually need to download files (checked later in locate_sources)
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
# SECTION 3 — SOURCE FILE RESOLUTION
# Priority: same dir → /tmp → env-var URL
# ═══════════════════════════════════════════════════════════════════════════════

# ── Download a file, verifying it is not an HTML page ────────────────────────
_fetch() {
    local url="$1" dest="$2"
    if command -v curl &>/dev/null; then
        curl -fsSL --retry 2 --retry-delay 3 --max-time 30 "$url" -o "$dest" 2>/dev/null
    else
        wget -q --tries=2 --timeout=30 "$url" -O "$dest" 2>/dev/null
    fi
    return $?
}

_is_html() {
    # Returns 0 (true) if the file looks like an HTML page, not a shell/python script
    local file="$1"
    [[ ! -f "$file" ]] && return 0            # missing = bad
    [[ ! -s "$file" ]] && return 0            # empty = bad
    local first
    first=$(head -c 200 "$file" | tr '[:upper:]' '[:lower:]')
    # Detect HTML responses: ISP block pages, 404 pages, login walls, etc.
    if echo "$first" | grep -qE '<!doctype html|<html|<head|<meta|<iframe|<body'; then
        return 0   # is HTML — bad
    fi
    return 1       # not HTML — good
}

_download() {
    local name="$1" primary_url="$2" mirror_url="$3" dest="$4"

    # ── Try primary URL ───────────────────────────────────────────────────
    log "INFO" "Downloading ${name} from primary source..."
    if _fetch "$primary_url" "$dest" && ! _is_html "$dest"; then
        log "SUCCESS" "Downloaded ${name}"
        return 0
    fi

    # Primary failed or returned HTML — check if it's an ISP block page
    if [[ -f "$dest" ]] && _is_html "$dest"; then
        local block_ref
        block_ref=$(grep -oE 'src="[^"]*"' "$dest" 2>/dev/null | head -1 | tr -d '"' | sed 's/src=//' || echo "unknown")
        log "WARNING" "Primary URL returned an HTML page (ISP/firewall block detected)"
        [[ "$block_ref" != "unknown" && -n "$block_ref" ]] &&             log "INFO"    "  Block page URL: $block_ref"
        rm -f "$dest"
    else
        log "WARNING" "Primary URL failed — trying mirror..."
    fi

    # ── Try mirror URL ────────────────────────────────────────────────────
    if [[ -n "$mirror_url" ]]; then
        log "INFO" "Downloading ${name} from mirror..."
        if _fetch "$mirror_url" "$dest" && ! _is_html "$dest"; then
            log "SUCCESS" "Downloaded ${name} (mirror)"
            return 0
        fi
        [[ -f "$dest" ]] && _is_html "$dest" && log "WARNING" "Mirror also returned HTML" && rm -f "$dest"
    fi

    # ── Both failed ───────────────────────────────────────────────────────
    log "ERROR" "Could not download ${name} from any source."
    log "INFO"  "Possible causes:"
    log "INFO"  "  • Your ISP or firewall is blocking GitHub/jsDelivr"
    log "INFO"  "  • No internet connectivity"
    log "INFO"  "  • Repository URL has changed"
    log "INFO"  "Manual fix — download on another machine and copy to server:"
    log "INFO"  "  Primary : $primary_url"
    log "INFO"  "  Mirror  : $mirror_url"
    log "INFO"  "  Then run: sudo bash install.sh  (with files in same dir)"
    return 1
}

locate_sources() {
    log "STEP" "Locating source files"
    local self_dir
    self_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

    SH_SOURCE=""
    PY_SOURCE=""

    # Same directory
    [[ -f "$self_dir/easyinstall.sh"        ]] && SH_SOURCE="$self_dir/easyinstall.sh"
    [[ -f "$self_dir/easyinstall_config.py" ]] && PY_SOURCE="$self_dir/easyinstall_config.py"

    # /tmp fallback
    [[ -z "$SH_SOURCE" && -f "/tmp/easyinstall.sh"        ]] && SH_SOURCE="/tmp/easyinstall.sh"
    [[ -z "$PY_SOURCE" && -f "/tmp/easyinstall_config.py" ]] && PY_SOURCE="/tmp/easyinstall_config.py"

    # Download from URL if still missing
    # ── 3. Download from GitHub (primary) with jsDelivr mirror fallback ───
    local tmpdir
    tmpdir=$(mktemp -d /tmp/easyinstall-XXXXXX)
    trap "rm -rf '$tmpdir'" EXIT

    if [[ -z "$SH_SOURCE" ]]; then
        log "STEP" "Downloading easyinstall.sh..."
        if _download "easyinstall.sh" \
                     "$EASYINSTALL_SH_URL" \
                     "$_MIRROR_SH_URL" \
                     "$tmpdir/easyinstall.sh"; then
            SH_SOURCE="$tmpdir/easyinstall.sh"
        fi
    fi

    if [[ -z "$PY_SOURCE" ]]; then
        log "STEP" "Downloading easyinstall_config.py..."
        if _download "easyinstall_config.py" \
                     "$EASYINSTALL_PY_URL" \
                     "$_MIRROR_PY_URL" \
                     "$tmpdir/easyinstall_config.py"; then
            PY_SOURCE="$tmpdir/easyinstall_config.py"
        fi
    fi

    # ── Hard fail if still missing ─────────────────────────────────────────
    if [[ -z "$SH_SOURCE" || ! -f "$SH_SOURCE" ]]; then
        log "ERROR" "easyinstall.sh could not be found or downloaded."
        exit 1
    fi
    if [[ -z "$PY_SOURCE" || ! -f "$PY_SOURCE" ]]; then
        log "ERROR" "easyinstall_config.py could not be found or downloaded."
        exit 1
    fi

    log "SUCCESS" "easyinstall.sh  → $SH_SOURCE"
    log "SUCCESS" "easyinstall_config.py → $PY_SOURCE"
}

# ═══════════════════════════════════════════════════════════════════════════════
# SECTION 4 — VALIDATION
# ═══════════════════════════════════════════════════════════════════════════════

validate_sources() {
    log "STEP" "Validating source files"

    # Bash syntax
    if ! bash -n "$SH_SOURCE" 2>/dev/null; then
        log "ERROR" "easyinstall.sh has syntax errors — aborting"; exit 1
    fi
    log "SUCCESS" "easyinstall.sh   — bash syntax clean"

    # Python syntax (strict)
    if ! python3 -W error::SyntaxWarning -m py_compile "$PY_SOURCE" 2>/dev/null; then
        # Non-strict fallback (warns but still valid on older Python)
        if ! python3 -m py_compile "$PY_SOURCE" 2>/dev/null; then
            log "ERROR" "easyinstall_config.py has syntax errors — aborting"; exit 1
        fi
        log "WARNING" "easyinstall_config.py — minor syntax warnings (non-fatal)"
    else
        log "SUCCESS" "easyinstall_config.py — python syntax clean"
    fi

    # Sanity: key identifiers present
    grep -q "SCRIPT_VERSION" "$SH_SOURCE"          || log "WARNING" "easyinstall.sh may be incomplete"
    grep -q "STAGE_MAP"      "$PY_SOURCE"           || log "WARNING" "easyinstall_config.py may be incomplete"
    grep -q "deploy_python_script" "$SH_SOURCE"     || log "WARNING" "deploy_python_script function not found in easyinstall.sh"
    grep -q "wordpress_install"    "$PY_SOURCE"     || log "WARNING" "wordpress_install stage not found in easyinstall_config.py"

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
        /backups/{daily,weekly,monthly} \
        /etc/nginx/{sites-available,sites-enabled,conf.d,snippets,ssl} \
        /root/easyinstall-backups
    chmod 755 /backups
    log "SUCCESS" "Directories created"
}

install_files() {
    log "STEP" "Installing easyinstall.sh → $INSTALL_DIR/"
    cp "$SH_SOURCE" "$INSTALL_DIR/easyinstall.sh"
    chmod 755 "$INSTALL_DIR/easyinstall.sh"

    log "STEP" "Installing easyinstall_config.py → $LIB_DIR/"
    cp "$PY_SOURCE" "$LIB_DIR/easyinstall_config.py"
    chmod 755 "$LIB_DIR/easyinstall_config.py"

    # Co-locate the Python file next to easyinstall.sh so
    # deploy_python_script() (which uses BASH_SOURCE dir) can find it.
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

    # Convenience alias
    ln -sf "$BIN_DIR/easyinstall-install" "$BIN_DIR/easyinstall-run" 2>/dev/null || true

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

    # 1. Python module responds to unknown stage
    local py_resp
    py_resp=$(python3 "$LIB_DIR/easyinstall_config.py" --stage __nonexistent__ 2>&1 || true)
    if echo "$py_resp" | grep -q "Unknown stage"; then
        log "SUCCESS" "Python module CLI: responds correctly"
    else
        log "WARNING" "Python module CLI: unexpected response (non-fatal)"
    fi

    # 2. Stage count ≥ 23
    local stage_count
    stage_count=$(python3 - << 'PYCHECK' 2>/dev/null || echo "0"
import warnings, importlib.util
warnings.filterwarnings("ignore")
spec = importlib.util.spec_from_file_location("ec", "/usr/local/lib/easyinstall_config.py")
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
print(len(mod.STAGE_MAP))
PYCHECK
    )
    if (( stage_count >= 23 )); then
        log "SUCCESS" "Python stages registered: $stage_count"
    else
        log "WARNING" "Python stage count low: $stage_count (expected ≥23)"
        all_ok=false
    fi

    # 3. Bash function count ≥ 40
    local func_count
    func_count=$(grep -c '^[a-zA-Z_][a-zA-Z0-9_]*() {' \
        "$INSTALL_DIR/easyinstall.sh" 2>/dev/null || echo "0")
    if (( func_count >= 40 )); then
        log "SUCCESS" "Bash functions defined: $func_count"
    else
        log "WARNING" "Bash function count low: $func_count (expected ≥40)"
        all_ok=false
    fi

    # 4. Launcher executable
    if [[ -x "$BIN_DIR/easyinstall-install" ]]; then
        log "SUCCESS" "Launcher is executable: $BIN_DIR/easyinstall-install"
    else
        log "WARNING" "Launcher not executable"; all_ok=false
    fi

    $all_ok \
        && log "SUCCESS" "All smoke tests passed" \
        || log "WARNING" "Some smoke tests flagged warnings — installation may still work"
}

# ═══════════════════════════════════════════════════════════════════════════════
# SECTION 7 — OUTPUT
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
    echo -e "   ${BLUE}or${NC}"
    echo ""
    echo -e "     ${GREEN}sudo bash $INSTALL_DIR/easyinstall.sh${NC}"
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
# SECTION 8 — SPECIAL MODES
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
    rm -f "$INSTALL_DIR/easyinstall.sh"     2>/dev/null || true
    rm -f "$INSTALL_DIR/easyinstall_config.py" 2>/dev/null || true
    rm -f "$BIN_DIR/easyinstall-install"    2>/dev/null || true
    rm -f "$BIN_DIR/easyinstall-run"        2>/dev/null || true
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
        "$LIB_DIR/easyinstall-autotune.sh|AutoTune module (created after full setup)"
        "$LIB_DIR/easyinstall-ai.sh|AI module (created after full setup)"
        "$BIN_DIR/easyinstall|CLI dispatcher (created after full setup)"
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
# SECTION 9 — ARGUMENT PARSER
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

Installs easyinstall.sh and easyinstall_config.py to your server,
then optionally launches the full WordPress server setup.

Options:
  (no args)      Install files, then prompt to run full setup
  --run          Install files AND immediately run full server setup
  --no-run       Install files only — skip the run prompt
  --reinstall    Remove old installed files, then reinstall
  --uninstall    Remove installed files (sites/DBs untouched)
  --status       Show status of all installed files
  --help         Show this help message

Environment variables:
  EASYINSTALL_SH_URL=https://...   URL to fetch easyinstall.sh
  EASYINSTALL_PY_URL=https://...   URL to fetch easyinstall_config.py

File resolution order (for both .sh and .py files):
  1. Same directory as install.sh
  2. /tmp/easyinstall.sh  and  /tmp/easyinstall_config.py
  3. URL specified via environment variable

Examples:
  # All 3 files in same directory:
  sudo bash install.sh

  # Install files only, run later:
  sudo bash install.sh --no-run

  # Install and immediately run full setup:
  sudo bash install.sh --run

  # Download files from remote URLs:
  EASYINSTALL_SH_URL=https://example.com/easyinstall.sh \
  EASYINSTALL_PY_URL=https://example.com/easyinstall_config.py \
  sudo bash install.sh --run
HELP
                exit 0
                ;;
            *) log "WARNING" "Unknown argument: '$arg' (ignored)" ;;
        esac
    done
}

# ═══════════════════════════════════════════════════════════════════════════════
# SECTION 10 — MAIN
# ═══════════════════════════════════════════════════════════════════════════════

main() {
    clear 2>/dev/null || true
    echo ""
    echo -e "${GREEN}╔══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║   EasyInstall v${INSTALLER_VERSION} HYBRID — File Installer             ║${NC}"
    echo -e "${GREEN}║   Bash dependency layer + Python configuration layer     ║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════════════════════╝${NC}"
    echo ""

    # Initialise log
    mkdir -p "$LOG_DIR" 2>/dev/null || true
    echo "=== Installer started: $(date) ===" >> "$INSTALL_LOG" 2>/dev/null || true

    # Parse CLI flags FIRST — --help, --status exit early (no root needed)
    parse_args "$@"

    # ── Preflight ─────────────────────────────────────────────────────────
    check_root
    check_os
    check_disk
    check_network
    ensure_python3
    ensure_downloader

    # ── Reinstall: clear old first ────────────────────────────────────────
    [[ "$OPT_REINSTALL" == true ]] && do_reinstall

    # ── Resolve source files ──────────────────────────────────────────────
    locate_sources
    validate_sources

    # ── Install ───────────────────────────────────────────────────────────
    create_directories
    install_files
    install_launcher
    write_version_info
    patch_path

    # ── Clean up the download tmpdir (files already copied) ───────────────
    # The tmpdir trap in locate_sources handles cleanup on EXIT automatically.

    # ── Verify ───────────────────────────────────────────────────────────
    smoke_test

    # ── Summary ───────────────────────────────────────────────────────────
    print_summary

    # ═══════════════════════════════════════════════════════════════════════
    # DECIDE WHETHER TO RUN THE FULL SERVER SETUP
    # ═══════════════════════════════════════════════════════════════════════
    if [[ "$OPT_NO_RUN" == true ]]; then
        log "INFO" "--no-run: skipping server setup (run later with: sudo easyinstall-install)"
        exit 0
    fi

    if [[ "$OPT_AUTO_RUN" == true ]]; then
        echo ""
        log "STEP" "--run flag: launching full WordPress server setup now…"
        echo ""
        exec bash "$INSTALL_DIR/easyinstall.sh"
        # exec replaces this process — nothing below runs if exec succeeds
    fi

    # ── Detect piped stdin (e.g. wget ... | bash) ───────────────────────
    # When stdin is a pipe, `read` gets EOF immediately and the script
    # crashes. Detect this case and skip the interactive prompt entirely.
    PIPED_STDIN=false
    if [[ ! -t 0 ]]; then
        PIPED_STDIN=true
    fi

    # Interactive prompt — only shown when running from a real terminal
    if [[ "$PIPED_STDIN" == true ]]; then
        echo ""
        echo -e "${GREEN}╔══════════════════════════════════════════════════════════╗${NC}"
        echo -e "${GREEN}║  🎉  Installation complete!                               ║${NC}"
        echo -e "${GREEN}╠══════════════════════════════════════════════════════════╣${NC}"
        echo -e "${GREEN}║  Detected: running via pipe (wget/curl | bash)           ║${NC}"
        echo -e "${GREEN}║  Interactive prompt skipped — run setup manually:        ║${NC}"
        echo -e "${GREEN}║                                                            ║${NC}"
        echo -e "${GREEN}║    sudo easyinstall-install                               ║${NC}"
        echo -e "${GREEN}║                                                            ║${NC}"
        echo -e "${GREEN}╚══════════════════════════════════════════════════════════╝${NC}"
        echo ""
        exit 0
    fi

    echo ""
    echo -e "${YELLOW}┌──────────────────────────────────────────────────────────┐${NC}"
    echo -e "${YELLOW}│  Files are installed and ready.                           │${NC}"
    echo -e "${YELLOW}│                                                            │${NC}"
    echo -e "${YELLOW}│  Run the full WordPress server setup now?                 │${NC}"
    echo -e "${YELLOW}│  (Nginx · PHP · MariaDB · Redis · SSL · Auto-tuning)      │${NC}"
    echo -e "${YELLOW}└──────────────────────────────────────────────────────────┘${NC}"
    echo ""
    read -r -p "  Start full server setup now? [Y/n]: " answer </dev/tty
    answer="${answer:-Y}"

    if [[ "$answer" =~ ^[Yy]$ ]]; then
        echo ""
        log "STEP" "Launching full WordPress server setup…"
        echo ""
        exec bash "$INSTALL_DIR/easyinstall.sh" </dev/tty
    else
        echo ""
        log "SUCCESS" "Skipped. Run the server setup any time with:"
        echo ""
        echo -e "     ${GREEN}sudo easyinstall-install${NC}"
        echo ""
    fi
}

main "$@"
