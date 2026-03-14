#!/bin/bash
# =============================================================================
# EasyInstall v7.0 — Hybrid Orchestrator (Bash Entry-Point)
# Delegates all logic to Python engine + PHP WP helper
# Debian 12 / Ubuntu 22.04 / 24.04  |  RAM: 512 MB – 16 GB
# =============================================================================
set -eE
trap 'echo -e "\033[0;31m❌ Error at line $LINENO\033[0m" >&2; exit 1' ERR

VERSION="7.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="/usr/local/lib/easyinstall"
PYTHON_ENGINE="$LIB_DIR/core.py"
PHP_HELPER="$LIB_DIR/wp_helper.php"

G='\033[0;32m'; Y='\033[1;33m'; R='\033[0;31m'; B='\033[0;34m'; C='\033[0;36m'; N='\033[0m'

# ─── Bootstrap: copy engine files on first run ───────────────────────────────
_bootstrap() {
    [ -f "$PYTHON_ENGINE" ] && [ -f "$PHP_HELPER" ] && return 0
    echo -e "${Y}⚙  First run — installing EasyInstall engine...${N}"
    mkdir -p "$LIB_DIR" /var/log/easyinstall /var/lib/easyinstall
    for f in easyinstall_core.py easyinstall_wp.php; do
        src="$SCRIPT_DIR/$f"
        [ -f "$src" ] || { echo -e "${R}❌ Missing: $src${N}"; exit 1; }
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

_help() {
cat << 'HELP'
EasyInstall v7.0 — WordPress Performance Stack
═══════════════════════════════════════════════
INSTALL:
  easyinstall install                    Full stack (Nginx+PHP+MariaDB+Redis)

SITE MANAGEMENT:
  easyinstall create domain.com [--ssl] [--php=8.3]
  easyinstall delete domain.com
  easyinstall list
  easyinstall site-info domain.com
  easyinstall update-site domain.com [--core|--plugins|--themes|--db|--langs|--check|--backup]
  easyinstall update-site all
  easyinstall clone src.com dst.com
  easyinstall php-switch domain.com 8.4

SSL:
  easyinstall ssl domain.com
  easyinstall ssl-renew

REDIS:
  easyinstall redis-status
  easyinstall redis-restart domain.com
  easyinstall redis-ports
  easyinstall redis-cli domain.com

MONITORING:
  easyinstall status
  easyinstall health
  easyinstall monitor
  easyinstall logs [domain.com]

SELF-HEAL & UPDATE:
  easyinstall self-heal [full|services|configs|ssl|disk|wp|502]
  easyinstall self-update [all|nginx|php|redis|mariadb|wpcli|script]
  easyinstall self-check

BACKUP:
  easyinstall backup [domain.com]

OPTIMIZE:
  easyinstall optimize
  easyinstall clean

WEBSOCKET / HTTP3 / EDGE:
  easyinstall ws-enable domain.com [port]
  easyinstall ws-disable domain.com
  easyinstall http3-enable
  easyinstall edge-setup

AI:
  easyinstall ai-diagnose [domain.com]
  easyinstall ai-optimize
  easyinstall ai-setup

PAGESPEED:
  easyinstall pagespeed [optimize|score|report|images] domain.com
═══════════════════════════════════════════════
HELP
}

# ─── Main dispatch ────────────────────────────────────────────────────────────
CMD="${1:-help}"; shift || true

case "$CMD" in
    install)
        _need_root; _bootstrap; _need_python; _need_php
        _py install "$@" ;;

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

    ssl)
        _need_root; _bootstrap; _need_python
        [ -z "$1" ] && { echo -e "${R}❌ Usage: easyinstall ssl domain.com${N}"; exit 1; }
        _py ssl "$@" ;;

    ssl-renew)    _need_root; _bootstrap; _need_python; _py ssl-renew ;;

    redis-status)  _bootstrap; _need_python; _py redis-status ;;
    redis-restart) _need_root; _bootstrap; _need_python; _py redis-restart "$@" ;;
    redis-ports)   _bootstrap; _need_python; _py redis-ports ;;
    redis-cli)
        REDIS_CONF="/etc/redis/redis-${1//./-}.conf"
        PORT=$(grep "^port" "$REDIS_CONF" 2>/dev/null | awk '{print $2}' || echo "6379")
        exec redis-cli -p "$PORT" ;;

    status)   _bootstrap; _need_python; _py status ;;
    health)   _bootstrap; _need_python; _py health ;;
    monitor)  _bootstrap; _need_python; _py monitor ;;
    logs)     _bootstrap; _need_python; _py logs "$@" ;;
    perf)     _bootstrap; _need_python; _py perf ;;
    version)  echo "EasyInstall v${VERSION}" ;;

    self-heal|selfheal)
        _need_root; _bootstrap; _need_python
        _py self-heal "${1:-full}" ;;

    self-update|selfupdate)
        _need_root; _bootstrap; _need_python
        _py self-update "${1:-all}" ;;

    self-check|selfcheck|versions)
        _bootstrap; _need_python; _py self-check ;;

    http3-enable) _need_root; _bootstrap; _need_python; _py http3-enable ;;
    http3-status) _bootstrap; _need_python; _py http3-status ;;

    version) _bootstrap; _need_python; _py self-check ;;

    backup)  _need_root; _bootstrap; _need_python; _py backup "$@" ;;
    optimize) _need_root; _bootstrap; _need_python; _py optimize ;;
    clean)    _need_root; _bootstrap; _need_python; _py clean ;;

    ws-enable)    _need_root; _bootstrap; _need_python; _py ws-enable "$@" ;;
    ws-disable)   _need_root; _bootstrap; _need_python; _py ws-disable "$@" ;;
    ws-status)    _bootstrap; _need_python; _py ws-status "$@" ;;
    ws-test)      _bootstrap; _need_python; _py ws-test "$@" ;;
    http3-enable) _need_root; _bootstrap; _need_python; _py http3-enable ;;
    http3-status) _bootstrap; _need_python; _py http3-status ;;
    edge-setup)   _need_root; _bootstrap; _need_python; _py edge-setup ;;
    edge-status)  _bootstrap; _need_python; _py edge-status ;;
    edge-purge)   _need_root; _bootstrap; _need_python; _py edge-purge "$@" ;;

    ai-diagnose) _bootstrap; _need_python; _py ai-diagnose "$@" ;;
    ai-optimize) _bootstrap; _need_python; _py ai-optimize ;;
    ai-setup)    _bootstrap; _need_python; _py ai-setup ;;

    pagespeed) _need_root; _bootstrap; _need_python; _need_php; _py pagespeed "$@" ;;

    help|--help|-h) _help ;;
    *)
        echo -e "${R}❌ Unknown command: $CMD${N}"
        echo "Run: easyinstall help"; exit 1 ;;
esac
