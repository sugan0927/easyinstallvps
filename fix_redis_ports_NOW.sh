#!/bin/bash
# ============================================================
# fix_redis_ports_NOW.sh
# Run this ONCE on your VPS to fix the duplicate port problem
# that already exists (ez.easyinstall.site and wp-ez-ins-site
# both got port 6380 instead of unique ports).
#
# Usage:
#   bash fix_redis_ports_NOW.sh
# ============================================================
set -e

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

echo -e "${BOLD}${CYAN}══════════════════════════════════════════════${NC}"
echo -e "${BOLD}${GREEN}  EasyInstall — Redis Port Fix Script${NC}"
echo -e "${BOLD}${CYAN}══════════════════════════════════════════════${NC}"
echo ""

# ── Step 1: Write the standalone helper script ──────────────────────────────
echo -e "${YELLOW}Step 1: Writing Redis helper script...${NC}"

cat > /usr/local/lib/easyinstall-redis-helper.py << 'PYEOF'
#!/usr/bin/env python3
"""
easyinstall-redis-helper.py
Standalone Redis port manager for EasyInstall.
Commands:
  alloc    - allocate next free port (>= 6380) and print it
  fix      - fix all duplicate/conflict ports across existing sites
  rebuild  - rebuild used_redis_ports.txt from actual conf files
"""
import os, sys, re, glob, socket, subprocess
from pathlib import Path

PORTS_FILE      = Path("/var/lib/easyinstall/used_redis_ports.txt")
LOCK_FILE       = Path("/var/lib/easyinstall/used_redis_ports.txt.lock")
REDIS_CONF_GLOB = "/etc/redis/redis-*.conf"

GREEN  = "\033[0;32m"
YELLOW = "\033[1;33m"
RED    = "\033[0;31m"
CYAN   = "\033[0;36m"
BOLD   = "\033[1m"
NC     = "\033[0m"

def port_in_conf_files(p):
    for f in glob.glob(REDIS_CONF_GLOB):
        try:
            for line in open(f, errors="ignore"):
                m = re.match(r"^\s*port\s+(\d+)", line)
                if m and int(m.group(1)) == p:
                    return True
        except Exception:
            pass
    return False

def port_listening(p):
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.settimeout(0.15)
        result = s.connect_ex(("127.0.0.1", p))
        s.close()
        return result == 0
    except Exception:
        return False

def read_used_ports():
    used = {6379}
    if PORTS_FILE.exists():
        for tok in PORTS_FILE.read_text().split():
            if tok.strip().isdigit():
                used.add(int(tok.strip()))
    return used

def all_conf_ports():
    result = {}
    for f in sorted(glob.glob(REDIS_CONF_GLOB)):
        for line in open(f, errors="ignore"):
            m = re.match(r"^\s*port\s+(\d+)", line)
            if m:
                result[f] = int(m.group(1))
                break
    return result

def next_free_port(taken_set):
    p = 6380
    while p <= 6500:
        if p not in taken_set and not port_in_conf_files(p) and not port_listening(p):
            return p
        p += 1
    return 6380

def rebuild_ports_file(used_set):
    PORTS_FILE.parent.mkdir(parents=True, exist_ok=True)
    PORTS_FILE.write_text("\n".join(str(p) for p in sorted(used_set)) + "\n")

def cmd_alloc():
    import fcntl
    PORTS_FILE.parent.mkdir(parents=True, exist_ok=True)
    lf = open(LOCK_FILE, "w")
    try:
        fcntl.flock(lf, fcntl.LOCK_EX)
    except Exception:
        pass

    used = read_used_ports()
    for p in all_conf_ports().values():
        used.add(p)

    port = next_free_port(used)

    with open(PORTS_FILE, "a") as pf:
        pf.write(str(port) + "\n")

    try:
        fcntl.flock(lf, fcntl.LOCK_UN)
    except Exception:
        pass
    lf.close()
    print(port)

def cmd_fix():
    confs    = all_conf_ports()
    taken    = {6379}
    seen     = {}
    conflicts = []

    for f, p in confs.items():
        if p in seen or p == 6379:
            conflicts.append(f)
        else:
            seen[p] = f
            taken.add(p)

    if not conflicts:
        print(GREEN + "No port conflicts found — all sites have unique ports." + NC)
        rebuild_ports_file(taken | set(confs.values()))
        sys.exit(0)

    print(YELLOW + "Found " + str(len(conflicts)) + " conflict(s) — reassigning..." + NC)

    for f in conflicts:
        domain_slug = Path(f).stem.replace("redis-", "", 1)
        old_port    = confs[f]
        new_port    = next_free_port(taken)
        taken.add(new_port)

        print("  " + YELLOW + domain_slug + NC +
              ": port " + str(old_port) + " -> " + BOLD + str(new_port) + NC)

        # 1. Stop the service
        subprocess.run(["systemctl", "stop", "redis-" + domain_slug],
                       capture_output=True)

        # 2. Rewrite redis conf
        content = open(f).read()
        content = re.sub(
            r"^(\s*port\s+)\d+",
            lambda m: m.group(1) + str(new_port),
            content, flags=re.MULTILINE
        )
        open(f, "w").write(content)

        # 3. Rewrite systemd service ExecStop
        svc = Path("/etc/systemd/system/redis-" + domain_slug + ".service")
        if svc.exists():
            sc = svc.read_text()
            sc = re.sub(r"-p\s+\d+", "-p " + str(new_port), sc)
            svc.write_text(sc)

        # 4. Find and rewrite wp-config.php
        wp_cfg = None
        dotted = domain_slug.replace("-", ".")
        candidates = [
            Path("/var/www/html/" + domain_slug + "/wp-config.php"),
            Path("/var/www/html/" + dotted + "/wp-config.php"),
        ]
        for site_dir in Path("/var/www/html").iterdir():
            if site_dir.is_dir():
                if site_dir.name.replace(".", "-") == domain_slug:
                    candidates.append(site_dir / "wp-config.php")
        for c in candidates:
            if c.exists():
                wp_cfg = c
                break

        if wp_cfg:
            wc = wp_cfg.read_text()
            wc = re.sub(
                r"define\s*\(\s*'WP_REDIS_PORT'\s*,\s*\d+\s*\)",
                "define('WP_REDIS_PORT', " + str(new_port) + ")",
                wc
            )
            wc = re.sub(
                r"tcp://127\.0\.0\.1:\d+\?database=1",
                "tcp://127.0.0.1:" + str(new_port) + "?database=1",
                wc
            )
            wp_cfg.write_text(wc)
            print("    " + GREEN + "wp-config.php updated" + NC + " (" + str(wp_cfg) + ")")
        else:
            print("    " + YELLOW + "wp-config.php not found for " + domain_slug + NC)

        # 5. Restart service
        subprocess.run(["systemctl", "daemon-reload"], capture_output=True)
        subprocess.run(["systemctl", "enable", "redis-" + domain_slug],
                       capture_output=True)
        r = subprocess.run(["systemctl", "start", "redis-" + domain_slug],
                           capture_output=True)
        ok = r.returncode == 0
        status_str = (GREEN + "started" + NC) if ok else (RED + "failed — check: journalctl -u redis-" + domain_slug + NC)
        print("    Redis service " + status_str + " on :" + str(new_port))

    rebuild_ports_file(taken)
    print("\n" + GREEN + "Port registry rebuilt: " + str(PORTS_FILE) + NC)
    print(GREEN + "Run: easyinstall redis-status  to verify" + NC)

def cmd_rebuild():
    ports = {6379}
    for p in all_conf_ports().values():
        ports.add(p)
    rebuild_ports_file(ports)
    print(GREEN + "Rebuilt " + str(PORTS_FILE) +
          " from conf files (" + str(len(ports)) + " ports)" + NC)

cmd = sys.argv[1] if len(sys.argv) > 1 else "help"
if   cmd == "alloc":   cmd_alloc()
elif cmd == "fix":     cmd_fix()
elif cmd == "rebuild": cmd_rebuild()
else:
    print("Usage: easyinstall-redis-helper.py <alloc|fix|rebuild>")
    sys.exit(1)
PYEOF

chmod 755 /usr/local/lib/easyinstall-redis-helper.py
echo -e "  ${GREEN}✅ Helper script written to /usr/local/lib/easyinstall-redis-helper.py${NC}"

# ── Step 2: Show current state ───────────────────────────────────────────────
echo ""
echo -e "${YELLOW}Step 2: Current Redis port state:${NC}"
echo -e "  ${CYAN}Redis conf files:${NC}"
for f in /etc/redis/redis-*.conf; do
    [ -f "$f" ] || continue
    port=$(grep -E "^\s*port\s+" "$f" 2>/dev/null | awk '{print $2}' | head -1)
    slug=$(basename "$f" .conf | sed 's/^redis-//')
    echo "    $(basename $f) → port $port"
done

echo ""
echo -e "  ${CYAN}used_redis_ports.txt:${NC}"
cat /var/lib/easyinstall/used_redis_ports.txt 2>/dev/null | while read p; do
    echo "    • $p"
done || echo "    (file not found)"

# ── Step 3: Run fix ──────────────────────────────────────────────────────────
echo ""
echo -e "${YELLOW}Step 3: Running port conflict fix...${NC}"
python3 /usr/local/lib/easyinstall-redis-helper.py fix

# ── Step 4: Rebuild ports registry ──────────────────────────────────────────
echo ""
echo -e "${YELLOW}Step 4: Rebuilding ports registry...${NC}"
python3 /usr/local/lib/easyinstall-redis-helper.py rebuild

# ── Step 5: Verify all Redis instances running ───────────────────────────────
echo ""
echo -e "${YELLOW}Step 5: Verifying all Redis instances...${NC}"
ALL_OK=true
for f in /etc/redis/redis-*.conf; do
    [ -f "$f" ] || continue
    slug=$(basename "$f" .conf | sed 's/^redis-//')
    port=$(grep -E "^\s*port\s+" "$f" 2>/dev/null | awk '{print $2}' | head -1)
    if systemctl is-active --quiet "redis-$slug" 2>/dev/null; then
        echo -e "  ${GREEN}✓${NC} redis-$slug running on port $port"
    else
        echo -e "  ${RED}✗${NC} redis-$slug STOPPED on port $port"
        echo -e "    Trying to start..."
        systemctl start "redis-$slug" 2>/dev/null && \
            echo -e "    ${GREEN}✓ Started${NC}" || \
            echo -e "    ${RED}✗ Failed — check: journalctl -u redis-$slug -n 20${NC}"
        ALL_OK=false
    fi
done

# ── Step 6: Flush object cache for affected sites ────────────────────────────
echo ""
echo -e "${YELLOW}Step 6: Flushing Redis caches (fresh start after port change)...${NC}"
for f in /etc/redis/redis-*.conf; do
    [ -f "$f" ] || continue
    port=$(grep -E "^\s*port\s+" "$f" 2>/dev/null | awk '{print $2}' | head -1)
    slug=$(basename "$f" .conf | sed 's/^redis-//')
    if redis-cli -p "$port" PING 2>/dev/null | grep -q PONG; then
        redis-cli -p "$port" FLUSHALL 2>/dev/null
        echo -e "  ${GREEN}✓${NC} Flushed cache for $slug (port $port)"
    fi
done

# ── Step 7: Final status ─────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}${CYAN}══════════════════════════════════════════════${NC}"
echo -e "${BOLD}${GREEN}Final Redis Status:${NC}"
echo -e "${BOLD}${CYAN}══════════════════════════════════════════════${NC}"
/usr/local/bin/easy-redis-status 2>/dev/null || \
    easyinstall redis-status 2>/dev/null || \
    echo -e "  Run: ${CYAN}easyinstall redis-status${NC}"

echo ""
if $ALL_OK; then
    echo -e "${BOLD}${GREEN}✅ All done! All Redis instances have unique ports and are running.${NC}"
else
    echo -e "${YELLOW}⚠ Some instances may need manual attention.${NC}"
    echo -e "${YELLOW}  Check: journalctl -u redis-<site-name> -n 30${NC}"
fi
echo ""
echo -e "${CYAN}Next steps:${NC}"
echo "  1. easyinstall redis-status          — verify all ports unique"
echo "  2. Visit each WordPress site to confirm Redis cache is working"
echo "  3. Upload the new easyinstall_config.py — future installs get correct ports"
echo ""
