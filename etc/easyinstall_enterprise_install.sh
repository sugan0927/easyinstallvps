#!/bin/bash
# ============================================================
# EasyInstall Enterprise — Module Installer
# Installs all enterprise add-on modules, systemd services,
# and configuration files without touching easyinstall.sh or
# easyinstall_config.py.
#
# Usage:
#   bash /path/to/easyinstall_enterprise_install.sh
#
# What it does:
#   1. Copies Python modules to /usr/local/lib/
#   2. Writes systemd service units
#   3. Writes default config files to /etc/easyinstall/
#   4. Installs Python dependencies
#   5. Initialises the SQLite database
#   6. Injects new CLI commands into /usr/local/bin/easyinstall
#      (appended as a new case block — original code untouched)
#   7. Installs bash completion
#   8. Sets up a nightly housekeeping cron job
# ============================================================

set -eE
trap 'echo "❌ Failed at line $LINENO"; exit 1' ERR

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'
CYAN='\033[0;36m'; NC='\033[0m'

log_step()    { echo -e "${CYAN}🔷 $1${NC}"; }
log_ok()      { echo -e "${GREEN}✅ $1${NC}"; }
log_warn()    { echo -e "${YELLOW}⚠️  $1${NC}"; }
log_err()     { echo -e "${RED}❌ $1${NC}"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="/usr/local/lib"
BIN_DIR="/usr/local/bin"
CONF_DIR="/etc/easyinstall"
DATA_DIR="/var/lib/easyinstall"
LOG_DIR="/var/log/easyinstall"
SYSTEMD_DIR="/etc/systemd/system"
COMPLETION_DIR="/etc/bash_completion.d"

# ── 1. Directories ────────────────────────────────────────────────────────────
log_step "Creating directories"
mkdir -p "$CONF_DIR" "$DATA_DIR" "$LOG_DIR"
chmod 700 "$CONF_DIR" "$DATA_DIR"
log_ok "Directories ready"

# ── 2. Copy Python modules ────────────────────────────────────────────────────
log_step "Installing Python modules"
for module in easyinstall_api.py easyinstall_db.py easyinstall_security.py easyinstall_monitor.py; do
    if [ -f "$SCRIPT_DIR/$module" ]; then
        cp "$SCRIPT_DIR/$module" "$LIB_DIR/$module"
        chmod 644 "$LIB_DIR/$module"
        log_ok "Installed: $LIB_DIR/$module"
    else
        log_warn "Module not found in script dir: $module (skipped)"
    fi
done

# ── 3. Python dependencies ────────────────────────────────────────────────────
log_step "Installing Python dependencies"
if command -v pip3 &>/dev/null; then
    pip3 install fastapi uvicorn pyjwt --break-system-packages --quiet 2>/dev/null || \
        pip3 install fastapi uvicorn pyjwt --quiet 2>/dev/null || \
        log_warn "pip3 install failed — install manually: pip3 install fastapi uvicorn pyjwt"
    log_ok "Python dependencies installed"
else
    log_warn "pip3 not found — install manually: pip3 install fastapi uvicorn pyjwt"
fi

# ── 4. Write default configuration files ─────────────────────────────────────
log_step "Writing default configuration files"

# api.conf
if [ ! -f "$CONF_DIR/api.conf" ]; then
    SECRET=$(python3 -c "import secrets; print(secrets.token_hex(64))" 2>/dev/null || date | sha256sum | cut -c1-64)
    cat > "$CONF_DIR/api.conf" <<EOF
{
    "host": "127.0.0.1",
    "port": 8000,
    "secret_key": "${SECRET}",
    "token_expiry_hours": 24,
    "rate_limit_per_minute": 100,
    "enable_cors": true,
    "allowed_origins": ["*"],
    "log_level": "info"
}
EOF
    chmod 600 "$CONF_DIR/api.conf"
    log_ok "Written: $CONF_DIR/api.conf (with new random secret)"
else
    log_warn "Skipped (already exists): $CONF_DIR/api.conf"
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
    log_ok "Written: $CONF_DIR/database.conf"
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
    log_ok "Written: $CONF_DIR/monitoring.conf"
fi

# ── 5. Initialise database ────────────────────────────────────────────────────
log_step "Initialising database"
python3 "$LIB_DIR/easyinstall_db.py" --init 2>&1 | grep -v "^$" || true
log_ok "Database initialised"

# ── 6. Systemd service files ──────────────────────────────────────────────────
log_step "Writing systemd service files"

# easyinstall-api.service
cat > "$SYSTEMD_DIR/easyinstall-api.service" <<'EOF'
[Unit]
Description=EasyInstall Enterprise REST API
Documentation=https://github.com/your-org/easyinstall
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
StandardOutput=journal
StandardError=journal
Environment=PYTHONUNBUFFERED=1
Environment=PYTHONPATH=/usr/local/lib

# Harden the service
NoNewPrivileges=yes
ProtectKernelTunables=yes
ProtectControlGroups=yes
RestrictRealtime=yes

[Install]
WantedBy=multi-user.target
EOF
log_ok "Written: $SYSTEMD_DIR/easyinstall-api.service"

# easyinstall-monitor.service
cat > "$SYSTEMD_DIR/easyinstall-monitor.service" <<'EOF'
[Unit]
Description=EasyInstall Enterprise Monitoring Daemon
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
Environment=PYTHONUNBUFFERED=1
Environment=PYTHONPATH=/usr/local/lib

[Install]
WantedBy=multi-user.target
EOF
log_ok "Written: $SYSTEMD_DIR/easyinstall-monitor.service"

# easyinstall-prometheus.service
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
Environment=PYTHONUNBUFFERED=1
Environment=PYTHONPATH=/usr/local/lib

[Install]
WantedBy=multi-user.target
EOF
log_ok "Written: $SYSTEMD_DIR/easyinstall-prometheus.service"

# easyinstall-autorenew.service + timer
cat > "$SYSTEMD_DIR/easyinstall-autorenew.service" <<'EOF'
[Unit]
Description=EasyInstall SSL Certificate Auto-Renewal

[Service]
Type=oneshot
User=root
ExecStart=/usr/bin/python3 -c "
import sys; sys.path.insert(0, '/usr/local/lib')
from easyinstall_security import ssl_manager
ssl_manager.renew_all()
"
StandardOutput=journal
StandardError=journal
Environment=PYTHONPATH=/usr/local/lib
EOF

cat > "$SYSTEMD_DIR/easyinstall-autorenew.timer" <<'EOF'
[Unit]
Description=EasyInstall SSL Auto-Renewal Timer (twice daily)

[Timer]
OnCalendar=*-*-* 03,15:30:00
RandomizedDelaySec=3600
Persistent=true

[Install]
WantedBy=timers.target
EOF
log_ok "Written: easyinstall-autorenew.{service,timer}"

# easyinstall-housekeep.service + timer
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
Description=EasyInstall Housekeeping Timer (nightly)

[Timer]
OnCalendar=*-*-* 02:00:00
RandomizedDelaySec=600
Persistent=true

[Install]
WantedBy=timers.target
EOF
log_ok "Written: easyinstall-housekeep.{service,timer}"

# ── 7. Reload systemd & enable services ──────────────────────────────────────
log_step "Enabling systemd services"
systemctl daemon-reload

for svc in easyinstall-api easyinstall-monitor; do
    systemctl enable "$svc" 2>/dev/null || true
    log_ok "Enabled: $svc"
done

for timer in easyinstall-autorenew easyinstall-housekeep; do
    systemctl enable "${timer}.timer" 2>/dev/null || true
    systemctl start  "${timer}.timer" 2>/dev/null || true
    log_ok "Enabled timer: ${timer}"
done

# ── 8. Inject enterprise CLI commands ────────────────────────────────────────
log_step "Injecting enterprise CLI commands into /usr/local/bin/easyinstall"

EASYINSTALL_BIN="$BIN_DIR/easyinstall"
ENTERPRISE_MARKER="# ── EasyInstall Enterprise Commands (v7.0) ──"

if grep -q "$ENTERPRISE_MARKER" "$EASYINSTALL_BIN" 2>/dev/null; then
    log_warn "Enterprise CLI commands already injected — skipping"
else
    # We append a new case block just before the final `*)` catch-all.
    # sed finds the `*)` default case and inserts our block before it.
    TMPFILE=$(mktemp)
    python3 - "$EASYINSTALL_BIN" "$TMPFILE" <<'PYEOF'
import sys, re

src  = open(sys.argv[1]).read()
dest = sys.argv[2]

enterprise_block = r"""
        # ── EasyInstall Enterprise Commands (v7.0) ──
        # These commands are injected by easyinstall_enterprise_install.sh
        # DO NOT modify this block manually — re-run the installer to update.

        api)
            subcmd="${2:-status}"
            case "$subcmd" in
                start)   systemctl start  easyinstall-api && echo -e "${GREEN}✅ API started${NC}" ;;
                stop)    systemctl stop   easyinstall-api && echo -e "${GREEN}✅ API stopped${NC}" ;;
                restart) systemctl restart easyinstall-api && echo -e "${GREEN}✅ API restarted${NC}" ;;
                status)  systemctl status easyinstall-api --no-pager ;;
                logs)    journalctl -u easyinstall-api -n 50 --no-pager ;;
                *) echo -e "${RED}❌ Usage: easyinstall api [start|stop|restart|status|logs]${NC}" ;;
            esac ;;

        api-key)
            subcmd="${2:-list}"
            case "$subcmd" in
                list)   python3 -c "
import sys; sys.path.insert(0, '/usr/local/lib')
from easyinstall_db import get_db
db = get_db()
keys = db.list_api_keys()
print(f\"{'Name':<20} {'Role':<15} {'Created':<25}\")
for k in keys:
    print(f\"{k.get('name','?'):<20} {k.get('role','?'):<15} {k.get('created_at','?'):<25}\")
" ;;
                *) echo -e "${YELLOW}Usage: easyinstall api-key [list]${NC}"
                   echo "  To create keys, use the REST API: POST /api/v1/api-keys" ;;
            esac ;;

        user)
            subcmd="${2:-list}"
            case "$subcmd" in
                list)
                    python3 -c "
import sys; sys.path.insert(0, '/usr/local/lib')
from easyinstall_db import get_db
db = get_db()
users = db.list_users()
print(f\"{'ID':<5} {'Username':<20} {'Email':<30} {'Role':<15} {'Active':<8}\")
print('-' * 80)
for u in users:
    active = '✅' if u.get('active') else '❌'
    print(f\"{u['id']:<5} {u['username']:<20} {u['email']:<30} {u['role']:<15} {active}\")
" ;;
                add)
                    [ -z "$3" ] || [ -z "$4" ] || [ -z "$5" ] && {
                        echo -e "${RED}❌ Usage: easyinstall user add <username> <email> <password> [role]${NC}"
                        exit 1
                    }
                    python3 -c "
import sys; sys.path.insert(0, '/usr/local/lib')
from easyinstall_db import get_db
db = get_db()
role = sys.argv[4] if len(sys.argv) > 4 else 'viewer'
u = db.create_user(sys.argv[1], sys.argv[2], sys.argv[3], role)
if u:
    print(f'✅ User created: {sys.argv[1]} (role: {role})')
else:
    print('❌ User already exists')
    sys.exit(1)
" "$3" "$4" "$5" "${6:-viewer}" ;;
                *) echo -e "${YELLOW}Usage: easyinstall user [list|add]${NC}" ;;
            esac ;;

        security)
            subcmd="${2:-scan}"
            case "$subcmd" in
                scan)
                    domain="${3:-}"
                    if [ -n "$domain" ]; then
                        python3 -c "
import sys, json; sys.path.insert(0, '/usr/local/lib')
from easyinstall_security import scanner
import json
r = scanner.scan_site(sys.argv[1])
icon = '🟢' if r['score'] >= 90 else ('🟡' if r['score'] >= 60 else '🔴')
print(f\"{icon} {r['domain']}: {r['score']}/100 (Grade {r['rating']})\")
for f in r['findings']:
    print(f\"  [{f['severity'].upper()}] {f.get('message', f.get('file', ''))}\")
    print(f\"    Fix: {f.get('fix', '')}\")
" "$domain"
                    else
                        python3 -c "
import sys; sys.path.insert(0, '/usr/local/lib')
from easyinstall_security import scanner
for r in scanner.scan_all_sites():
    icon = '🟢' if r['score'] >= 90 else ('🟡' if r['score'] >= 60 else '🔴')
    print(f\"{icon} {r['domain']:<35} Score: {r['score']}/100  Grade: {r['rating']}  Issues: {len(r['findings'])}\")
"
                    fi ;;
                report)
                    python3 -c "
import sys; sys.path.insert(0, '/usr/local/lib')
from easyinstall_security import generate_security_report
p = generate_security_report()
print(f'✅ Security report: {p}')
" ;;
                ssl)
                    python3 -c "
import sys; sys.path.insert(0, '/usr/local/lib')
from easyinstall_security import ssl_manager
certs = ssl_manager.check_all_certificates()
for c in certs:
    icon = '✅' if c['status'] == 'ok' else ('⚠️ ' if c['status'] == 'expiring_soon' else '❌')
    print(f\"{icon} {c['domain']}: {c['days_remaining']} days ({c['status']})\")
" ;;
                firewall)
                    python3 -c "
import sys; sys.path.insert(0, '/usr/local/lib')
from easyinstall_security import firewall
print(firewall.status())
" ;;
                *) echo -e "${YELLOW}Usage: easyinstall security [scan [domain]|report|ssl|firewall]${NC}" ;;
            esac ;;

        metrics)
            domain="${2:-}"
            if [ -n "$domain" ]; then
                python3 -c "
import sys, json; sys.path.insert(0, '/usr/local/lib')
from easyinstall_monitor import collect_system_metrics, collect_site_metrics
sm = collect_site_metrics(sys.argv[1])
sys_m = collect_system_metrics()
print(f\"📊 Metrics for {sys.argv[1]}\")
print(f\"  CPU          : {sys_m['cpu_usage']}%\")
print(f\"  Memory       : {sys_m['memory_usage_pct']}%\")
print(f\"  Disk         : {sys_m['disk_usage_pct']}%\")
print(f\"  Redis Memory : {sm['redis_used_memory_mb']} MB\")
print(f\"  Redis Hit%   : {sm['redis_hit_rate_pct']}%\")
print(f\"  Site Disk    : {sm['site_disk_mb']} MB\")
print(f\"  MySQL Threads: {sm['mysql_threads_connected']}\")
" "$domain"
            else
                python3 "$LIB_DIR/easyinstall_monitor.py"
            fi ;;

        audit-log)
            days="${2:-7}"
            python3 -c "
import sys; sys.path.insert(0, '/usr/local/lib')
from easyinstall_db import get_db
db = get_db()
logs = db.get_audit_logs(days=int(sys.argv[1]))
print(f\"{'Time':<25} {'User':<15} {'Action':<25} {'Resource':<30} {'Status':<10}\")
print('-' * 110)
for l in logs:
    print(f\"{l['timestamp'][:24]:<25} {(l['username'] or 'system'):<15} {l['action']:<25} {(l['resource_type']+':'+str(l.get('resource_id') or '')):<30} {l['status']:<10}\")
" "$days" ;;

        db-stats)
            python3 -c "
import sys; sys.path.insert(0, '/usr/local/lib')
from easyinstall_db import get_db
import json
db = get_db()
stats = db.get_stats()
print('📊 EasyInstall Database Stats')
for k, v in stats.items():
    print(f'  {k:<25}: {v}')
" ;;

"""

# Insert the enterprise block before the final `*)` catch-all in the case statement
# We look for the pattern `        *)` at the start of a line
patched = re.sub(
    r'^        \*\)',
    enterprise_block + '        *)',
    src,
    count=1,
    flags=re.MULTILINE
)

if patched == src:
    # Fallback: append before last `esac`
    patched = re.sub(r'\besac\b(?!.*\besac\b)', enterprise_block + 'esac', src, flags=re.DOTALL)

open(dest, 'w').write(patched)
PYEOF

    if [ -s "$TMPFILE" ]; then
        cp "$EASYINSTALL_BIN" "${EASYINSTALL_BIN}.bak.$(date +%Y%m%d%H%M%S)"
        mv "$TMPFILE" "$EASYINSTALL_BIN"
        chmod 755 "$EASYINSTALL_BIN"
        log_ok "Enterprise CLI commands injected into $EASYINSTALL_BIN"
    else
        log_warn "Patching failed — enterprise commands not injected into CLI"
        rm -f "$TMPFILE"
    fi
fi

# ── 9. Bash completion ────────────────────────────────────────────────────────
log_step "Installing bash completion"
cat > "$COMPLETION_DIR/easyinstall-enterprise" <<'EOF'
# EasyInstall Enterprise bash completion
_easyinstall_enterprise() {
    local cur prev words
    COMPREPLY=()
    cur="${COMP_WORDS[COMP_CWORD]}"
    prev="${COMP_WORDS[COMP_CWORD-1]}"

    local base_cmds="create delete ssl clone update-site backup-site site-info php-switch
                     monitor perf-dashboard warm-cache db-optimize wp-speed autotune
                     ws-enable ws-disable ws-status redis-ports clean help
                     api api-key user security metrics audit-log db-stats"

    case "$prev" in
        easyinstall)
            COMPREPLY=( $(compgen -W "$base_cmds" -- "$cur") )
            return 0 ;;
        api)
            COMPREPLY=( $(compgen -W "start stop restart status logs" -- "$cur") )
            return 0 ;;
        api-key)
            COMPREPLY=( $(compgen -W "list create revoke" -- "$cur") )
            return 0 ;;
        user)
            COMPREPLY=( $(compgen -W "list add delete role" -- "$cur") )
            return 0 ;;
        security)
            COMPREPLY=( $(compgen -W "scan report ssl firewall" -- "$cur") )
            return 0 ;;
        create|delete|ssl|clone|update-site|backup-site|site-info|php-switch|metrics|ws-enable|ws-disable)
            # Complete with existing sites
            local sites
            sites=$(ls /var/www/html 2>/dev/null | xargs)
            COMPREPLY=( $(compgen -W "$sites" -- "$cur") )
            return 0 ;;
    esac
}
complete -F _easyinstall_enterprise easyinstall
EOF
log_ok "Bash completion installed at $COMPLETION_DIR/easyinstall-enterprise"

# ── 10. Start the API ─────────────────────────────────────────────────────────
log_step "Starting EasyInstall API"
if systemctl start easyinstall-api 2>/dev/null; then
    sleep 2
    if systemctl is-active --quiet easyinstall-api; then
        log_ok "API is running on http://127.0.0.1:8000"
        log_ok "API docs: http://127.0.0.1:8000/api/docs"
    else
        log_warn "API service started but may not be fully up — check: journalctl -u easyinstall-api -n 30"
    fi
else
    log_warn "Could not start API automatically — run: systemctl start easyinstall-api"
fi

# ── 11. Summary ───────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║  ✅ EasyInstall Enterprise Modules Installed (v7.0)  ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${YELLOW}📁 Installed Files:${NC}"
echo "   /usr/local/lib/easyinstall_api.py       — REST API"
echo "   /usr/local/lib/easyinstall_db.py        — Database manager"
echo "   /usr/local/lib/easyinstall_security.py  — Security module"
echo "   /usr/local/lib/easyinstall_monitor.py   — Monitoring daemon"
echo ""
echo -e "${YELLOW}🔧 Systemd Services:${NC}"
echo "   easyinstall-api.service       — REST API (port 8000)"
echo "   easyinstall-monitor.service   — Metrics + alerting daemon"
echo "   easyinstall-prometheus.service— Prometheus exporter (port 9091)"
echo "   easyinstall-autorenew.timer   — SSL auto-renewal (twice daily)"
echo "   easyinstall-housekeep.timer   — DB housekeeping (nightly)"
echo ""
echo -e "${YELLOW}🆕 New CLI Commands:${NC}"
echo "   easyinstall api [start|stop|restart|status|logs]"
echo "   easyinstall api-key [list]"
echo "   easyinstall user [list|add]"
echo "   easyinstall security [scan [domain]|report|ssl|firewall]"
echo "   easyinstall metrics [domain]"
echo "   easyinstall audit-log [days]"
echo "   easyinstall db-stats"
echo ""
echo -e "${YELLOW}🔑 Admin Credentials:${NC}"
if [ -f /root/easyinstall-api-admin.txt ]; then
    cat /root/easyinstall-api-admin.txt
    echo "   Change password immediately after first login!"
fi
echo ""
echo -e "${YELLOW}📖 API Documentation:${NC}"
echo "   http://127.0.0.1:8000/api/docs    (Swagger UI)"
echo "   http://127.0.0.1:8000/api/redoc   (ReDoc)"
echo ""
echo -e "${YELLOW}🔑 Config Files:${NC}"
echo "   /etc/easyinstall/api.conf"
echo "   /etc/easyinstall/database.conf"
echo "   /etc/easyinstall/monitoring.conf"
echo ""
echo -e "${GREEN}Source ~/.bashrc to enable tab completion, then try:${NC}"
echo "   easyinstall api status"
echo "   easyinstall security scan"
echo "   easyinstall metrics"
echo ""
