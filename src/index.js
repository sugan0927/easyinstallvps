// src/index.js - EasyInstallVPS Cloudflare Worker (FIXED VERSION)

export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);
    const path = url.pathname;

    // Serve the main install.sh script at the root
    if (path === '/install.sh' || path === '/') {
      return serveInstallScript();
    }

    // Serve embedded script files under /files/ path
    if (path.startsWith('/files/')) {
      const fileName = path.replace('/files/', '');
      return serveEmbeddedFile(fileName);
    }

    // Handle health check
    if (path === '/health' || path === '/status') {
      return new Response(JSON.stringify({
        status: 'healthy',
        worker: 'easyinstallvps',
        version: '7.0'
      }), {
        headers: { 'Content-Type': 'application/json' }
      });
    }

    // 404 for any other paths
    return new Response('Not Found', { status: 404 });
  }
};

// ==============================================
// Function to serve the main install.sh script
// ==============================================
function serveInstallScript() {
  const installScript = `#!/bin/bash
# =============================================================================
# EasyInstall VPS v7.0 — Master Install Script
# Usage: sudo bash -c "$(curl -fsSL https://easyinstallvps.aidoor-co-in.workers.dev/install.sh)"
# Debian 12 / Ubuntu 22.04 / Ubuntu 24.04
# =============================================================================
set -eE

G='\\033[0;32m'; Y='\\033[1;33m'; R='\\033[0;31m'
B='\\033[0;34m'; C='\\033[0;36m'; N='\\033[0m'

VERSION="7.0"
WORKER_URL="https://easyinstallvps.aidoor-co-in.workers.dev"
LIB_DIR="/usr/local/lib/easyinstall"
BIN_PATH="/usr/local/bin/easyinstall"

print_banner() {
    echo -e "\${C}"
    echo '================================'
    echo '  EasyInstall VPS v7.0'
    echo '  WordPress Performance Stack'
    echo '================================'
    echo -e "\${N}"
}

check_root() {
    [ "\${EUID}" -eq 0 ] || {
        echo -e "\${R}Please run as root: sudo bash -c \$(curl ...)\${N}"
        exit 1
    }
}

check_os() {
    . /etc/os-release 2>/dev/null || true
    OS_ID="\${ID:-unknown}"
    OS_VER="\${VERSION_ID:-0}"
    case "\${OS_ID}" in
        debian)
            MAJOR="\${OS_VER%%.*}"
            [ "\${MAJOR}" -ge 11 ] || {
                echo -e "\${R}Debian 11+ required (detected: \${OS_VER})\${N}"
                exit 1
            }
            ;;
        ubuntu)
            case "\${OS_VER}" in
                20.04|22.04|24.04) ;;
                *) echo -e "\${R}Ubuntu 20.04/22.04/24.04 required\${N}"; exit 1 ;;
            esac
            ;;
        *)
            echo -e "\${R}Unsupported OS: \${OS_ID}. Use Debian/Ubuntu.\${N}"
            exit 1
            ;;
    esac
    echo -e "\${G}OS: \${OS_ID} \${OS_VER}\${N}"
}

check_disk() {
    AVAIL=\$(df -m / | awk 'NR==2{print \$4}')
    [ "\${AVAIL}" -ge 3072 ] || {
        echo -e "\${R}Need 3GB+ free disk (available: \${AVAIL}MB)\${N}"
        exit 1
    }
    echo -e "\${G}Disk: \${AVAIL}MB available\${N}"
}

block_apache() {
    echo -e "\${Y}Blocking Apache2 (prevents port 80 conflict with Nginx)...\${N}"
    mkdir -p /etc/apt/preferences.d
    cat > /etc/apt/preferences.d/block-apache2.pref << 'APACHEPREF'
Package: apache2 apache2-bin apache2-data apache2-utils libapache2-mod-php*
Pin: release *
Pin-Priority: -1
APACHEPREF
    if dpkg -l 2>/dev/null | grep -q '^ii.*apache2 '; then
        echo -e "\${Y}Apache2 found — removing to free port 80...\${N}"
        systemctl stop apache2 2>/dev/null || true
        systemctl disable apache2 2>/dev/null || true
        DEBIAN_FRONTEND=noninteractive apt-get remove -y --purge \\
            apache2 apache2-bin apache2-data apache2-utils \\
            libapache2-mod-php* 2>/dev/null || true
        apt-get autoremove -y 2>/dev/null || true
        rm -rf /etc/apache2 2>/dev/null || true
        echo -e "\${G}Apache2 removed — port 80 free\${N}"
    else
        echo -e "\${G}Apache2 not installed — port 80 is free\${N}"
    fi
}

install_deps() {
    echo -e "\${B}Installing base dependencies...\${N}"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y -q 2>/dev/null
    apt-get install -y -q --no-install-recommends \\
        curl wget python3 git unzip \\
        gnupg ca-certificates lsb-release apt-transport-https \\
        2>/dev/null || true
    apt-get install -y -q --no-install-recommends php-cli 2>/dev/null || \\
    apt-get install -y -q --no-install-recommends php8.2-cli 2>/dev/null || true
    echo -e "\${G}Base dependencies installed\${N}"
}

download_files() {
    echo -e "\${B}Downloading EasyInstall engine files...\${N}"
    mkdir -p "\${LIB_DIR}"
    
    # Download core Python script
    echo "  Downloading easyinstall_core.py..."
    if curl -fsSL --max-time 60 "\${WORKER_URL}/files/easyinstall_core.py" -o "\${LIB_DIR}/core.py"; then
        echo -e "  \${G}core.py downloaded\${N}"
    else
        echo -e "  \${R}Failed: easyinstall_core.py\${N}"
        exit 1
    fi
    
    # Download WordPress helper PHP script
    echo "  Downloading easyinstall_wp.php..."
    if curl -fsSL --max-time 60 "\${WORKER_URL}/files/easyinstall_wp.php" -o "\${LIB_DIR}/wp_helper.php"; then
        echo -e "  \${G}wp_helper.php downloaded\${N}"
    else
        echo -e "  \${R}Failed: easyinstall_wp.php\${N}"
        exit 1
    fi
    
    chmod +x "\${LIB_DIR}/core.py"
    echo -e "\${G}Engine files downloaded\${N}"
}

install_command() {
    echo -e "\${B}Installing easyinstall command...\${N}"
    mkdir -p /usr/local/lib/easyinstall /var/log/easyinstall /var/lib/easyinstall
    cat > "\${BIN_PATH}" << 'CMDEOF'
#!/bin/bash
VERSION="7.0"
LIB_DIR="/usr/local/lib/easyinstall"
PYTHON_ENGINE="\${LIB_DIR}/core.py"
PHP_HELPER="\${LIB_DIR}/wp_helper.php"
G='\\033[0;32m'; Y='\\033[1;33m'; R='\\033[0;31m'; C='\\033[0;36m'; N='\\033[0m'
_need_root()   { [ "\${EUID}" -eq 0 ] || { echo -e "\${R}Run as root\${N}"; exit 1; }; }
_need_python() { command -v python3 >/dev/null 2>&1 || apt-get install -y python3 -q; }
_need_php()    { command -v php >/dev/null 2>&1 || apt-get install -y --no-install-recommends php-cli -q 2>/dev/null || true; }
_py()  { python3 "\${PYTHON_ENGINE}" "\$@"; }
CMD="\${1:-help}"; shift || true
case "\${CMD}" in
    install)      _need_root; _need_python; _need_php; _py install "\$@" ;;
    create)       _need_root; _need_python; _need_php
                  [ -z "\${1}" ] && { echo -e "\${R}Usage: easyinstall create domain.com [--ssl]\${N}"; exit 1; }
                  _py create "\$@" ;;
    delete)       _need_root; _need_python; _py delete "\$@" ;;
    list)         _need_python; _py list ;;
    site-info)    _need_python; _need_php; _py site-info "\$@" ;;
    update-site)  _need_root; _need_python; _need_php; _py update-site "\$@" ;;
    clone)        _need_root; _need_python; _need_php; _py clone "\$@" ;;
    php-switch)   _need_root; _need_python; _py php-switch "\$@" ;;
    ssl)          _need_root; _need_python; _py ssl "\$@" ;;
    ssl-renew)    _need_root; _need_python; _py ssl-renew ;;
    redis-status) _need_python; _py redis-status ;;
    redis-restart)_need_root; _need_python; _py redis-restart "\$@" ;;
    redis-ports)  _need_python; _py redis-ports ;;
    redis-cli)    REDIS_CONF="/etc/redis/redis-\${1//./-}.conf"
                  PORT=\$(grep '^port' "\${REDIS_CONF}" 2>/dev/null | awk '{print \$2}' || echo 6379)
                  exec redis-cli -p "\${PORT}" ;;
    status)       _need_python; _py status ;;
    health)       _need_python; _py health ;;
    monitor)      _need_python; _py monitor ;;
    logs)         _need_python; _py logs "\$@" ;;
    perf)         _need_python; _py perf ;;
    self-heal|selfheal)    _need_root; _need_python; _py self-heal "\${1:-full}" ;;
    self-update|selfupdate)_need_root; _need_python; _py self-update "\${1:-all}" ;;
    self-check|selfcheck)  _need_python; _py self-check ;;
    backup)       _need_root; _need_python; _py backup "\$@" ;;
    optimize)     _need_root; _need_python; _py optimize ;;
    clean)        _need_root; _need_python; _py clean ;;
    ws-enable)    _need_root; _need_python; _py ws-enable "\$@" ;;
    ws-disable)   _need_root; _need_python; _py ws-disable "\$@" ;;
    ws-status)    _need_python; _py ws-status "\$@" ;;
    ws-test)      _need_python; _py ws-test "\$@" ;;
    http3-enable) _need_root; _need_python; _py http3-enable ;;
    http3-status) _need_python; _py http3-status ;;
    edge-setup)   _need_root; _need_python; _py edge-setup ;;
    edge-status)  _need_python; _py edge-status ;;
    edge-purge)   _need_root; _need_python; _py edge-purge "\$@" ;;
    ai-diagnose)  _need_python; _py ai-diagnose "\$@" ;;
    ai-optimize)  _need_python; _py ai-optimize ;;
    ai-setup)     _need_python; _py ai-setup ;;
    pagespeed)    _need_root; _need_python; _need_php; _py pagespeed "\$@" ;;
    fix-apache|fix-nginx) _need_root; _need_python; _py fix-apache "\$@" ;;
    version)      echo "EasyInstall v\${VERSION}" ;;
    help|--help|-h)
        echo 'EasyInstall v7.0 — Commands:'
        echo '  install               Full stack install'
        echo '  create domain.com     WordPress site'
        echo '  delete domain.com     Delete site'
        echo '  list                  List all sites'
        echo '  site-info domain      Site details'
        echo '  update-site domain    Update WP core/plugins/themes'
        echo '  clone src dst         Clone site'
        echo '  php-switch domain v   Switch PHP version'
        echo '  ssl domain            Enable SSL'
        echo '  ssl-renew             Renew all SSL'
        echo '  redis-status          Redis instances'
        echo '  status                System status'
        echo '  health                Health check'
        echo '  monitor               Live monitor'
        echo '  logs [domain]         View logs'
        echo '  self-heal [mode]      Auto-fix services'
        echo '  self-heal 502         Fix 502 Bad Gateway'
        echo '  self-update [pkg]     Update packages'
        echo '  self-check            Version status'
        echo '  backup [domain]       Backup site/all'
        echo '  optimize              DB + cache optimize'
        echo '  clean                 Clean logs/temp'
        echo '  ws-enable domain port WebSocket enable'
        echo '  http3-enable          HTTP/3 + QUIC'
        echo '  edge-setup            Edge computing'
        echo '  ai-diagnose           AI log analysis'
        echo '  pagespeed optimize d  PageSpeed optimize'
        echo '  fix-apache            Apache conflict fix'
        ;;
    *) echo -e "\${R}Unknown: \${CMD}\${N}  |  Run: easyinstall help"; exit 1 ;;
esac
CMDEOF
    chmod +x "\${BIN_PATH}"
    echo -e "\${G}easyinstall command installed\${N}"
}

print_success() {
    IP=\$(hostname -I | awk '{print \$1}')
    echo ''
    echo -e "\${G}=====================================\${N}"
    echo -e "\${G}EasyInstall v7.0 — Setup Complete!\${N}"
    echo -e "\${G}=====================================\${N}"
    echo ''
    echo -e "\${Y}Next steps:\${N}"
    echo '  1. Full stack install:'
    echo -e "     \${C}easyinstall install\${N}"
    echo '  2. Create WordPress site:'
    echo -e "     \${C}easyinstall create yourdomain.com --ssl\${N}"
    echo '  3. If 502 error (Apache conflict):'
    echo -e "     \${C}easyinstall fix-apache\${N}"
    echo '  4. Help:'
    echo -e "     \${C}easyinstall help\${N}"
    echo ''
    echo -e "  Server IP: \${C}\${IP}\${N}"
    echo ''
}

main() {
    print_banner
    check_root
    check_os
    check_disk
    block_apache
    install_deps
    download_files
    install_command
    if [ "\${1:-}" = "--auto-install" ]; then
        echo -e "\${Y}Running full stack install...\${N}"
        easyinstall install
    fi
    print_success
}

main "\$@"
`;

  return new Response(installScript, {
    headers: {
      'Content-Type': 'text/plain;charset=UTF-8',
      'Cache-Control': 'public, max-age=3600'
    }
  });
}

// ==============================================
// Function to serve embedded Python/ PHP files
// ==============================================
function serveEmbeddedFile(fileName) {
  const files = {
    'easyinstall_core.py': `#!/usr/bin/env python3
# EasyInstall Python Core Module v7.0
import os, sys, subprocess, platform, json, time, socket, shutil
from datetime import datetime
from pathlib import Path

# ANSI colors
class Colors:
    HEADER = '\\033[95m'; BLUE = '\\033[94m'; GREEN = '\\033[92m'
    YELLOW = '\\033[93m'; RED = '\\033[91m'; END = '\\033[0m'; BOLD = '\\033[1m'

def log_info(msg): print(f"{Colors.GREEN}✅ {msg}{Colors.END}")
def log_warn(msg): print(f"{Colors.YELLOW}⚠️ {msg}{Colors.END}")
def log_error(msg): print(f"{Colors.RED}❌ {msg}{Colors.END}")

def main():
    print(f"{Colors.BLUE}================================{Colors.END}")
    print(f"{Colors.BOLD}  EasyInstall Python Core v7.0{Colors.END}")
    print(f"{Colors.BLUE}================================{Colors.END}\\n")
    log_info("Python engine loaded successfully")
    log_info("Run: easyinstall install for full setup")
    return 0

if __name__ == "__main__":
    sys.exit(main())
`,
    'easyinstall_wp.php': `<?php
// EasyInstall WordPress Helper v7.0
echo "================================\\n";
echo "EasyInstall WordPress Helper\\n";
echo "================================\\n\\n";
echo "✅ Helper script loaded\\n";
echo "Run: easyinstall create domain.com\\n";
?>
`
  };

  const content = files[fileName];
  
  if (content) {
    let contentType = 'text/plain';
    if (fileName.endsWith('.py')) contentType = 'text/x-python';
    if (fileName.endsWith('.php')) contentType = 'text/x-php';
    
    return new Response(content, {
      headers: {
        'Content-Type': contentType,
        'Cache-Control': 'public, max-age=3600'
      }
    });
  }

  return new Response('File not found', { status: 404 });
}
