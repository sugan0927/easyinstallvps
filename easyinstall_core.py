#!/usr/bin/env python3
# =============================================================================
# EasyInstall v7.0 — Python Core Engine
# Handles: install, create, delete, heal, update, monitor, redis, ssl, ws, edge
# Compatible: Debian 12 / Ubuntu 22.04 / 24.04  |  RAM 512 MB – 16 GB
# =============================================================================
import sys, os, re, json, time, shutil, socket, subprocess, textwrap, fcntl
from pathlib import Path
from datetime import datetime

# ─── Paths ────────────────────────────────────────────────────────────────────
LIB_DIR     = Path("/usr/local/lib/easyinstall")
LOG_DIR     = Path("/var/log/easyinstall")
STATE_DIR   = Path("/var/lib/easyinstall")
PHP_HELPER  = LIB_DIR / "wp_helper.php"
REDIS_PORTS = STATE_DIR / "used_redis_ports.txt"
SSL_EMAIL   = Path("/root/.ssl-email")
LOCK_FILE   = Path("/var/run/easyinstall.lock")
LOG_FILE    = LOG_DIR / "install.log"
ERR_LOG     = LOG_DIR / "error.log"

VERSION = "7.0"

# ─── Terminal colors ──────────────────────────────────────────────────────────
G="\033[0;32m"; Y="\033[1;33m"; R="\033[0;31m"
B="\033[0;34m"; C="\033[0;36m"; N="\033[0m"; P="\033[0;35m"

def ok(msg):   print(f"{G}✅  {msg}{N}")
def warn(msg): print(f"{Y}⚠️   {msg}{N}")
def err(msg):  print(f"{R}❌  {msg}{N}")
def info(msg): print(f"{B}ℹ️   {msg}{N}")
def step(msg): print(f"{P}🔷  {msg}{N}")
def cyan(msg): print(f"{C}{msg}{N}")

def _log(level, msg):
    LOG_DIR.mkdir(parents=True, exist_ok=True)
    ts = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    with open(LOG_FILE, "a") as f:
        f.write(f"[{ts}] [{level}] {msg}\n")

# ─── Shell helpers ────────────────────────────────────────────────────────────
def run(cmd, check=True, capture=False, timeout=300, env=None):
    """Run shell command. Returns (rc, stdout, stderr)."""
    _log("CMD", cmd[:120])
    r = subprocess.run(
        cmd, shell=True, capture_output=capture,
        timeout=timeout, text=True,
        env={**os.environ, **(env or {})}
    )
    if check and r.returncode != 0:
        e = r.stderr.strip() if capture else ""
        _log("ERR", f"rc={r.returncode} cmd={cmd[:80]} {e}")
        raise RuntimeError(f"Command failed (rc={r.returncode}): {cmd[:80]}")
    return r.returncode, (r.stdout or ""), (r.stderr or "")

def run_ok(cmd, **kw):
    """Run and return True/False."""
    try: run(cmd, check=True, **kw); return True
    except: return False

def cmd_out(cmd):
    """Return stdout of command or ''."""
    try: _, out, _ = run(cmd, capture=True, check=False); return out.strip()
    except: return ""

def svc_active(name):
    return run_ok(f"systemctl is-active --quiet {name} 2>/dev/null")

def svc_restart(name):
    return run_ok(f"systemctl restart {name} 2>/dev/null")

def svc_reload(name):
    return run_ok(f"systemctl reload {name} 2>/dev/null")

def wait_svc(name, secs=30):
    for _ in range(secs // 2):
        if svc_active(name): return True
        time.sleep(2)
    return False

# ─── OS Detection ─────────────────────────────────────────────────────────────
def detect_os():
    info_file = Path("/etc/os-release")
    data = {}
    if info_file.exists():
        for line in info_file.read_text().splitlines():
            if "=" in line:
                k, v = line.split("=", 1)
                data[k] = v.strip('"')
    os_id      = data.get("ID", "debian")
    os_version = data.get("VERSION_ID", "12")
    codename   = data.get("VERSION_CODENAME", "")
    if not codename:
        if os_id == "ubuntu":
            codename = cmd_out("lsb_release -sc") or "jammy"
        else:
            dv = cmd_out("cat /etc/debian_version").split(".")[0]
            codename = {"10":"buster","11":"bullseye","12":"bookworm"}.get(dv, "bookworm")
    return os_id, os_version, codename

# ─── RAM-based tuning (core function — unchanged logic) ───────────────────────
def ram_tune():
    total_ram   = int(cmd_out("free -m | awk '/Mem:/{print $2}'") or "512")
    total_cores = int(cmd_out("nproc") or "1")
    step(f"RAM={total_ram}MB  Cores={total_cores}")

    if   total_ram <= 512:
        return dict(php_children=5,  php_start=2,  php_min=1,  php_max=3,
                    php_mem="128M",  php_exec=60,   mysql_buf="64M",  mysql_log="32M",
                    redis_mem="64mb",  nginx_conn=512,  cores=total_cores, ram=total_ram)
    elif total_ram <= 1024:
        return dict(php_children=10, php_start=3,  php_min=2,  php_max=5,
                    php_mem="256M",  php_exec=120,  mysql_buf="128M", mysql_log="64M",
                    redis_mem="128mb", nginx_conn=1024, cores=total_cores, ram=total_ram)
    elif total_ram <= 2048:
        return dict(php_children=20, php_start=5,  php_min=3,  php_max=8,
                    php_mem="256M",  php_exec=180,  mysql_buf="256M", mysql_log="128M",
                    redis_mem="256mb", nginx_conn=2048, cores=total_cores, ram=total_ram)
    elif total_ram <= 4096:
        return dict(php_children=40, php_start=8,  php_min=4,  php_max=12,
                    php_mem="512M",  php_exec=240,  mysql_buf="512M", mysql_log="256M",
                    redis_mem="512mb", nginx_conn=4096, cores=total_cores, ram=total_ram)
    elif total_ram <= 8192:
        return dict(php_children=80, php_start=12, php_min=6,  php_max=18,
                    php_mem="512M",  php_exec=300,  mysql_buf="1G",   mysql_log="512M",
                    redis_mem="1gb",   nginx_conn=8192, cores=total_cores, ram=total_ram)
    else:
        return dict(php_children=160,php_start=20, php_min=10, php_max=30,
                    php_mem="1G",    php_exec=360,  mysql_buf="2G",   mysql_log="1G",
                    redis_mem="2gb",   nginx_conn=16384,cores=total_cores, ram=total_ram)

# ─── PHP version detection ────────────────────────────────────────────────────
def detect_php(preferred="8.4"):
    for v in [preferred, "8.4", "8.3", "8.2", "8.1"]:
        if svc_active(f"php{v}-fpm"): return v
    for v in ["8.4", "8.3", "8.2", "8.1"]:
        if shutil.which(f"php{v}"): return v
    return "8.2"

# ─── Redis port registry ──────────────────────────────────────────────────────
def _used_ports():
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    if not REDIS_PORTS.exists(): REDIS_PORTS.write_text("6379\n")
    return set(int(x) for x in REDIS_PORTS.read_text().splitlines() if x.strip().isdigit())

def _add_port(port):
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    with open(REDIS_PORTS, "a") as f:
        fcntl.flock(f, fcntl.LOCK_EX)
        f.write(f"{port}\n")
        fcntl.flock(f, fcntl.LOCK_UN)

def next_redis_port():
    used = _used_ports()
    port = 6379
    while port in used or run_ok(f"ss -tlnp 2>/dev/null | grep -q ':{port} '"):
        port += 1
        if port > 65000: return 6379
    return port

def ssl_email(domain):
    if SSL_EMAIL.exists() and SSL_EMAIL.stat().st_size > 0:
        return SSL_EMAIL.read_text().strip().splitlines()[0]
    return f"admin@{domain}"

# ─── Socket helpers ───────────────────────────────────────────────────────────
def php_sock(ver): return Path(f"/run/php/php{ver}-fpm.sock")

def fix_sock(ver):
    s = php_sock(ver)
    if s.exists():
        os.chmod(s, 0o660)
        run(f"chown www-data:www-data {s}", check=False)
        return True
    return False

# =============================================================================
# INSTALL — Full Stack
# =============================================================================
def cmd_install(args):
    step("EasyInstall v7.0 — Full Stack Installation")
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    LOG_DIR.mkdir(parents=True, exist_ok=True)

    os_id, os_ver, codename = detect_os()
    ok(f"OS: {os_id} {os_ver} ({codename})")

    # FIX: सबसे पहले Apache2 हटाएं — यह PHP के साथ install होकर port 80 block करता है
    # Nginx से पहले यह करना जरूरी है
    step("Pre-install: Removing Apache2 to free port 80")
    run("systemctl stop apache2 2>/dev/null || true", check=False)
    run("systemctl disable apache2 2>/dev/null || true", check=False)
    run("DEBIAN_FRONTEND=noninteractive apt-get remove -y --purge apache2 apache2-bin apache2-data apache2-utils libapache2-mod-php* 2>/dev/null || true", check=False)
    run("apt-get autoremove -y 2>/dev/null || true", check=False)
    run("rm -rf /etc/apache2 2>/dev/null || true", check=False)
    ok("Apache2 purged — port 80 is free")

    # Apache को apt से block करें ताकि PHP install में वापस न आए
    Path("/etc/apt/preferences.d/block-apache2.pref").write_text(textwrap.dedent("""\
        Package: apache2 apache2-bin apache2-data apache2-utils libapache2-mod-php*
        Pin: release *
        Pin-Priority: -1
    """))
    ok("Apache2 blocked in apt — will not auto-install again")

    T = ram_tune()
    ok(f"Tuning: PHP children={T['php_children']}  MySQL={T['mysql_buf']}  Redis={T['redis_mem']}")

    _setup_swap(T)
    _kernel_tuning()
    _install_nginx(os_id, codename, T)
    _install_php(os_id, codename, T)
    _install_mariadb(T)
    _install_redis(T)
    _install_wpcli()
    _install_certbot()
    _configure_firewall()
    _configure_fail2ban()
    _install_crons()

    ok(f"✨ EasyInstall v{VERSION} installation complete!")
    info("Next: easyinstall create yourdomain.com --ssl")

# ── Swap ──────────────────────────────────────────────────────────────────────
def _setup_swap(T):
    if Path("/swapfile").exists():
        info("Swap already exists — skipping"); return
    ram = T['ram']
    size = "1G" if ram<=512 else "2G" if ram<=1024 else "3G" if ram<=2048 else "4G"
    step(f"Creating {size} swap")
    if not run_ok(f"fallocate -l {size} /swapfile"):
        run(f"dd if=/dev/zero of=/swapfile bs=1M count=4096 status=progress")
    run("chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile")
    fstab = Path("/etc/fstab")
    if "/swapfile" not in fstab.read_text():
        fstab.write_text(fstab.read_text() + "\n/swapfile none swap sw 0 0\n")
    run("sysctl -w vm.swappiness=10 2>/dev/null || true", check=False)
    ok("Swap created")

# ── Kernel tuning (core — unchanged values) ───────────────────────────────────
def _kernel_tuning():
    step("Kernel tuning")
    Path("/etc/sysctl.d/99-wordpress.conf").write_text(textwrap.dedent("""\
        net.core.rmem_max = 134217728
        net.core.wmem_max = 134217728
        net.ipv4.tcp_rmem = 4096 87380 134217728
        net.ipv4.tcp_wmem = 4096 65536 134217728
        net.core.netdev_max_backlog = 5000
        net.ipv4.tcp_congestion_control = bbr
        net.core.default_qdisc = fq
        net.ipv4.tcp_fin_timeout = 10
        net.ipv4.tcp_tw_reuse = 1
        net.ipv4.tcp_max_syn_backlog = 4096
        net.core.somaxconn = 1024
        net.ipv4.tcp_syncookies = 1
        net.ipv4.tcp_max_tw_buckets = 2000000
        net.ipv4.tcp_keepalive_time = 300
        fs.file-max = 2097152
        fs.inotify.max_user_watches = 524288
        vm.swappiness = 10
        vm.vfs_cache_pressure = 50
        vm.dirty_ratio = 30
        vm.dirty_background_ratio = 5
        vm.overcommit_memory = 1
        kernel.pid_max = 65536
    """))
    run("sysctl -p /etc/sysctl.d/99-wordpress.conf 2>/dev/null || true", check=False)
    limits = Path("/etc/security/limits.conf")
    extra = "\n* soft nofile 1048576\n* hard nofile 1048576\nroot soft nofile 1048576\nroot hard nofile 1048576\n"
    if "1048576" not in limits.read_text(): limits.write_text(limits.read_text() + extra)
    ok("Kernel tuned")

# ── Nginx install ─────────────────────────────────────────────────────────────
def _install_nginx(os_id, codename, T):
    step("Installing Nginx (official repo)")

    # FIX: Apache2 को पूरी तरह हटाएं — यह PHP install के साथ आता है और port 80 block करता है
    step("Removing Apache2 if present (conflicts with Nginx on port 80)")
    run("systemctl stop apache2 2>/dev/null || true", check=False)
    run("systemctl disable apache2 2>/dev/null || true", check=False)
    run("apt-get remove -y --purge apache2 apache2-bin apache2-data apache2-utils libapache2-mod-php* 2>/dev/null || true", check=False)
    run("apt-get autoremove -y 2>/dev/null || true", check=False)
    # Apache की कोई भी leftover config हटाएं
    run("rm -rf /etc/apache2 2>/dev/null || true", check=False)
    ok("Apache2 removed — port 80 is now free")

    # FIX: Port 80 पर कोई और process है तो उसे भी बंद करें
    port80_pid = cmd_out("ss -tlnp 2>/dev/null | grep ':80 ' | grep -oP 'pid=\\K[0-9]+'")
    if port80_pid:
        warn(f"Port 80 in use by PID {port80_pid} — killing it")
        run(f"kill -9 {port80_pid} 2>/dev/null || true", check=False)
        import time; time.sleep(2)

    run("apt-get remove -y nginx nginx-common nginx-full nginx-core 2>/dev/null || true", check=False)
    run("curl -fsSL https://nginx.org/keys/nginx_signing.key | gpg --dearmor -o /usr/share/keyrings/nginx-archive-keyring.gpg")
    repo = f"deb [signed-by=/usr/share/keyrings/nginx-archive-keyring.gpg] http://nginx.org/packages/mainline/{os_id} {codename} nginx"
    Path("/etc/apt/sources.list.d/nginx.list").write_text(repo + "\n")
    run("apt-get update -y && apt-get install -y nginx")

    for d in ["/etc/nginx/sites-available", "/etc/nginx/sites-enabled",
              "/etc/nginx/conf.d", "/etc/nginx/ssl",
              "/var/cache/nginx/fastcgi", "/var/log/nginx"]:
        Path(d).mkdir(parents=True, exist_ok=True)

    Path("/etc/nginx/nginx.conf").write_text(textwrap.dedent(f"""\
        user nginx;
        worker_processes auto;
        worker_rlimit_nofile 1048576;
        pid /run/nginx.pid;
        events {{
            worker_connections {T['nginx_conn']};
            use epoll;
            multi_accept on;
        }}
        http {{
            sendfile on; tcp_nopush on; tcp_nodelay on;
            keepalive_timeout 30; keepalive_requests 1000;
            server_tokens off; client_max_body_size 128M;
            include /etc/nginx/mime.types;
            default_type application/octet-stream;
            log_format main '$remote_addr - $remote_user [$time_local] "$request" '
                            '$status $body_bytes_sent "$http_referer" '
                            '"$http_user_agent" rt=$request_time';
            access_log /var/log/nginx/access.log main buffer=32k flush=5s;
            error_log  /var/log/nginx/error.log warn;
            gzip on; gzip_vary on; gzip_comp_level 6; gzip_min_length 1000;
            gzip_types text/plain text/css application/json application/javascript
                       application/xml text/xml image/svg+xml;
            fastcgi_cache_path /var/cache/nginx/fastcgi levels=1:2
                keys_zone=WORDPRESS:256m inactive=60m max_size=2g;
            fastcgi_cache_key "$scheme$request_method$host$request_uri";
            fastcgi_cache_use_stale error timeout updating invalid_header http_500 http_503;
            fastcgi_cache_lock on;
            ssl_protocols TLSv1.2 TLSv1.3;
            ssl_prefer_server_ciphers off;
            ssl_session_cache shared:SSL:50m;
            ssl_session_timeout 1d;
            limit_req_zone $binary_remote_addr zone=login:10m rate=10r/m;
            map $http_cookie $no_cache {{
                default 0;
                ~*wordpress_logged_in 1;
                ~*wp-postpass 1;
            }}
            include /etc/nginx/conf.d/*.conf;
            include /etc/nginx/sites-enabled/*;
        }}
    """))
    run("systemctl enable nginx && systemctl start nginx")
    # FIX: Start के बाद verify करें
    import time as _t; _t.sleep(2)
    if not svc_active("nginx"):
        # एक बार और Apache check करें
        run("systemctl stop apache2 2>/dev/null || true", check=False)
        run("apt-get remove -y --purge apache2 apache2-bin apache2-data 2>/dev/null || true", check=False)
        run("apt-get autoremove -y 2>/dev/null || true", check=False)
        run("systemctl start nginx 2>/dev/null || true", check=False)
        _t.sleep(3)
    if not wait_svc("nginx", 30):
        # Nginx error log देखें
        log_tail = cmd_out("journalctl -u nginx --no-pager -n 20 2>/dev/null")
        warn(f"Nginx may not have started. Check: journalctl -u nginx\n{log_tail}")
    else:
        ok("Nginx installed and running")

# ── PHP install ───────────────────────────────────────────────────────────────
def _install_php(os_id, codename, T):
    step("Installing PHP (Sury/Ondrej repo)")

    # FIX: Apache2 को पहले ही block करें — PHP install के साथ Apache आने से रोकें
    # /etc/apt/preferences.d/ में Apache को pin करके hold करें
    Path("/etc/apt/preferences.d/block-apache2.pref").write_text(textwrap.dedent("""\
        Package: apache2 apache2-bin apache2-data apache2-utils libapache2-mod-php*
        Pin: release *
        Pin-Priority: -1
    """))
    info("Apache2 blocked via apt preferences — will not be auto-installed")

    if os_id == "debian":
        run("apt-get install -y apt-transport-https lsb-release ca-certificates curl wget")
        run("wget -qO- https://packages.sury.org/php/apt.gpg | gpg --dearmor > /etc/apt/trusted.gpg.d/sury-php.gpg")
        Path("/etc/apt/sources.list.d/sury-php.list").write_text(f"deb https://packages.sury.org/php/ {codename} main\n")
    else:
        run("add-apt-repository -y ppa:ondrej/php")
    run("apt-get update -y")

    installed = False
    for ver in ["8.4", "8.3", "8.2"]:
        # FIX: --no-install-recommends से Apache automatically नहीं आएगा
        pkgs = " ".join(f"php{ver}-{e}" for e in [
            "fpm","mysql","curl","gd","mbstring","xml","xmlrpc","zip",
            "soap","intl","bcmath","redis","opcache","readline","apcu","igbinary"
        ])
        if run_ok(f"DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends {pkgs}"):
            installed = True
            info(f"PHP {ver} installed")
            # FIX: Install के बाद Apache फिर से आया हो तो हटाएं
            run("apt-get remove -y --purge apache2 apache2-bin apache2-data 2>/dev/null || true", check=False)
            break

    if not installed:
        raise RuntimeError("PHP installation failed for all versions")

    for ver in ["8.4", "8.3", "8.2"]:
        php_dir = Path(f"/etc/php/{ver}")
        if not php_dir.exists(): continue
        _configure_php(ver, T)

def _configure_php(ver, T):
    pool_conf = Path(f"/etc/php/{ver}/fpm/pool.d/www.conf")
    pool_conf.write_text(textwrap.dedent(f"""\
        [www]
        user = www-data
        group = www-data
        listen = /run/php/php{ver}-fpm.sock
        listen.owner = www-data
        listen.group = www-data
        listen.mode = 0660
        listen.backlog = 65535
        pm = dynamic
        pm.max_children = {T['php_children']}
        pm.start_servers = {T['php_start']}
        pm.min_spare_servers = {T['php_min']}
        pm.max_spare_servers = {T['php_max']}
        pm.max_requests = 10000
        pm.status_path = /status
        request_terminate_timeout = {T['php_exec']}s
        catch_workers_output = yes
        security.limit_extensions = .php .php3 .php4 .php5 .php7
    """))
    # php.ini tweaks
    ini = Path(f"/etc/php/{ver}/fpm/php.ini")
    if ini.exists():
        txt = ini.read_text()
        for pat, rep in [
            (r"memory_limit = .*",         f"memory_limit = {T['php_mem']}"),
            (r"upload_max_filesize = .*",  "upload_max_filesize = 64M"),
            (r"post_max_size = .*",        "post_max_size = 64M"),
            (r"max_execution_time = .*",   f"max_execution_time = {T['php_exec']}"),
            (r";date\.timezone.*",         "date.timezone = UTC"),
            (r";max_input_vars = .*",      "max_input_vars = 5000"),
            (r";realpath_cache_size = .*", "realpath_cache_size = 4096k"),
        ]:
            txt = re.sub(pat, rep, txt)
        ini.write_text(txt)
    # OPcache
    Path(f"/etc/php/{ver}/fpm/conf.d/10-opcache.ini").write_text(textwrap.dedent("""\
        opcache.enable=1
        opcache.memory_consumption=256
        opcache.interned_strings_buffer=16
        opcache.max_accelerated_files=20000
        opcache.revalidate_freq=60
        opcache.fast_shutdown=1
        opcache.enable_cli=1
        opcache.validate_timestamps=0
        opcache.save_comments=1
    """))
    run(f"systemctl enable php{ver}-fpm && systemctl start php{ver}-fpm")
    wait_svc(f"php{ver}-fpm", 20)
    fix_sock(ver)
    ok(f"PHP {ver} configured")

# ── MariaDB install ───────────────────────────────────────────────────────────
def _install_mariadb(T):
    step("Installing MariaDB 11.x")
    run("systemctl stop mariadb mysql 2>/dev/null || true", check=False)
    run("curl -fsSL https://downloads.mariadb.com/MariaDB/mariadb_repo_setup | bash -s -- --mariadb-server-version=mariadb-11.4 --skip-maxscale 2>/dev/null || true", check=False)
    run("apt-get update -y && apt-get install -y mariadb-server mariadb-client")

    Path("/etc/mysql/mariadb.conf.d/99-wordpress.cnf").write_text(textwrap.dedent(f"""\
        [mysqld]
        bind-address            = 127.0.0.1
        max_connections         = 500
        max_allowed_packet      = 256M
        innodb_buffer_pool_size = {T['mysql_buf']}
        innodb_log_file_size    = {T['mysql_log']}
        innodb_flush_method     = O_DIRECT
        innodb_file_per_table   = 1
        innodb_flush_log_at_trx_commit = 2
        innodb_io_capacity      = 2000
        table_open_cache        = 20000
        table_definition_cache  = 20000
        open_files_limit        = 100000
        slow_query_log          = 1
        slow_query_log_file     = /var/log/mysql/slow.log
        long_query_time         = 2
        character-set-server    = utf8mb4
        collation-server        = utf8mb4_unicode_ci
        thread_cache_size       = 256
    """))
    run("systemctl enable mariadb && systemctl start mariadb")
    wait_svc("mariadb", 30)
    # Secure
    run("""mysql -e "DELETE FROM mysql.user WHERE User=''; DROP DATABASE IF EXISTS test; FLUSH PRIVILEGES;" 2>/dev/null || true""", check=False)
    ok("MariaDB installed")

# ── Redis install ─────────────────────────────────────────────────────────────
def _install_redis(T):
    step("Installing Redis 7.x")
    run("curl -fsSL https://packages.redis.io/gpg | gpg --dearmor -o /usr/share/keyrings/redis-archive-keyring.gpg 2>/dev/null || true", check=False)
    _, _, _ = detect_os()
    os_id, os_ver, codename = detect_os()
    Path("/etc/apt/sources.list.d/redis.list").write_text(
        f"deb [signed-by=/usr/share/keyrings/redis-archive-keyring.gpg] https://packages.redis.io/deb {codename} main\n"
    )
    run("apt-get update -y 2>/dev/null || true && apt-get install -y redis-server redis-tools")
    Path("/etc/redis/redis.conf").write_text(textwrap.dedent(f"""\
        bind 127.0.0.1
        port 6379
        daemonize yes
        supervised systemd
        pidfile /var/run/redis/redis-server.pid
        loglevel notice
        logfile /var/log/redis/redis-server.log
        databases 16
        maxmemory {T['redis_mem']}
        maxmemory-policy allkeys-lru
        maxmemory-samples 10
        save ""
        appendonly no
        maxclients 10000
        tcp-backlog 65535
        timeout 0
        tcp-keepalive 300
    """))
    run("systemctl enable redis-server && systemctl start redis-server")
    wait_svc("redis-server", 20)
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    REDIS_PORTS.write_text("6379\n")
    ok("Redis installed")

# ── WP-CLI install ────────────────────────────────────────────────────────────
def _install_wpcli():
    step("Installing WP-CLI")
    run("curl -O https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar")
    run("chmod +x wp-cli.phar && mv wp-cli.phar /usr/local/bin/wp")
    ok("WP-CLI installed")

# ── Certbot install ───────────────────────────────────────────────────────────
def _install_certbot():
    step("Installing Certbot")
    run("apt-get install -y certbot python3-certbot-nginx")
    ok("Certbot installed")

# ── Firewall ──────────────────────────────────────────────────────────────────
def _configure_firewall():
    step("Configuring UFW firewall")
    for cmd in ["ufw --force disable", "ufw --force reset",
                "ufw default deny incoming", "ufw default allow outgoing",
                "ufw allow 22/tcp", "ufw allow 80/tcp", "ufw allow 443/tcp",
                "ufw allow 443/udp", "ufw limit ssh/tcp"]:
        run(f"{cmd} 2>/dev/null || true", check=False)
    run("echo 'y' | ufw enable 2>/dev/null || true", check=False)
    ok("Firewall configured")

# ── Fail2ban ──────────────────────────────────────────────────────────────────
def _configure_fail2ban():
    step("Configuring Fail2ban")
    Path("/etc/fail2ban/jail.local").write_text(textwrap.dedent("""\
        [DEFAULT]
        bantime  = 3600
        findtime = 600
        maxretry = 5
        ignoreip = 127.0.0.1/8 ::1

        [sshd]
        enabled = true
        port    = ssh
        filter  = sshd
        logpath = /var/log/auth.log
        maxretry = 3
        bantime  = 86400

        [nginx-http-auth]
        enabled = true
        filter  = nginx-http-auth
        port    = http,https
        logpath = /var/log/nginx/error.log

        [wordpress]
        enabled = true
        filter  = wordpress
        port    = http,https
        logpath = /var/log/nginx/access.log
        maxretry = 5
    """))
    Path("/etc/fail2ban/filter.d/wordpress.conf").write_text(textwrap.dedent("""\
        [Definition]
        failregex = ^<HOST> .* "POST .*wp-login\\.php.*" 200
                    ^<HOST> .* "POST .*xmlrpc\\.php.*" 200
        ignoreregex =
    """))
    run("systemctl enable fail2ban && systemctl restart fail2ban 2>/dev/null || true", check=False)
    ok("Fail2ban configured")

# ── Cron jobs ─────────────────────────────────────────────────────────────────
def _install_crons():
    Path("/etc/cron.d/easyinstall-selfheal").write_text(textwrap.dedent("""\
        0 3 * * *   root /usr/local/bin/easyinstall self-heal full >> /var/log/easyinstall/selfheal-cron.log 2>&1
        0 4 * * 0   root /usr/local/bin/easyinstall self-update all >> /var/log/easyinstall/selfupdate-cron.log 2>&1
        */15 * * * * root /usr/local/bin/easyinstall self-heal services >> /var/log/easyinstall/selfheal-cron.log 2>&1
    """))
    ok("Cron jobs installed")

# =============================================================================
# CREATE — WordPress site
# =============================================================================
def cmd_create(args):
    domain = args[0]
    domain = re.sub(r"https?://|^www\.|/", "", domain)
    php_ver = "auto"; use_ssl = False
    for a in args[1:]:
        if a.startswith("--php="): php_ver = a.split("=")[1]
        if a == "--ssl": use_ssl = True

    step(f"Creating WordPress site: {domain}")

    # Check existing
    if Path(f"/var/www/html/{domain}").exists():
        err(f"Site already exists: {domain}"); return

    # PHP version
    if php_ver == "auto": php_ver = detect_php()
    if not svc_active(f"php{php_ver}-fpm"):
        svc_restart(f"php{php_ver}-fpm")
        time.sleep(2)
    if not svc_active(f"php{php_ver}-fpm"):
        err(f"PHP {php_ver}-FPM not running"); return

    # Socket check
    sock = php_sock(php_ver)
    if not sock.exists():
        svc_restart(f"php{php_ver}-fpm"); time.sleep(3)
    if not sock.exists():
        err(f"PHP socket missing: {sock}"); return
    fix_sock(php_ver)
    ok(f"PHP {php_ver} socket: {sock}")

    # Redis
    redis_port = next_redis_port()
    _create_site_redis(domain, redis_port)

    # Download WordPress via PHP helper
    wp_path = f"/var/www/html/{domain}"
    Path(wp_path).mkdir(parents=True, exist_ok=True)
    info("Downloading WordPress...")
    run(f"wget -qO- https://wordpress.org/latest.tar.gz | tar xz -C {wp_path} --strip-components=1")
    run(f"chown -R www-data:www-data {wp_path} && chmod -R 755 {wp_path}")

    # DB + wp-config via PHP helper
    run(f"php {PHP_HELPER} create-site {domain} {redis_port} {php_ver}")

    # Nginx config
    _write_nginx_site(domain, php_ver)

    # SSL
    if use_ssl:
        _enable_ssl(domain)

    ok(f"WordPress site ready: {'https' if use_ssl else 'http'}://{domain}/wp-admin/install.php")
    info(f"Credentials: /root/{domain}-credentials.txt")

def _create_site_redis(domain, port):
    slug = domain.replace(".", "-")
    conf_path = f"/etc/redis/redis-{slug}.conf"
    svc_path  = f"/etc/systemd/system/redis-{slug}.service"

    redis_mem = cmd_out("grep '^maxmemory' /etc/redis/redis.conf | awk '{print $2}'") or "128mb"
    Path(conf_path).write_text(textwrap.dedent(f"""\
        port {port}
        daemonize yes
        pidfile /var/run/redis/redis-{slug}.pid
        logfile /var/log/redis/redis-{slug}.log
        dir /var/lib/redis/{slug}
        maxmemory {redis_mem}
        maxmemory-policy allkeys-lru
        appendonly no
        save ""
        bind 127.0.0.1
    """))
    Path(f"/var/lib/redis/{slug}").mkdir(parents=True, exist_ok=True)
    run(f"chown redis:redis /var/lib/redis/{slug}", check=False)
    Path(svc_path).write_text(textwrap.dedent(f"""\
        [Unit]
        Description=Redis for {domain}
        After=network.target
        [Service]
        Type=forking
        ExecStart=/usr/bin/redis-server {conf_path}
        ExecStop=/usr/bin/redis-cli -p {port} shutdown
        User=redis
        Group=redis
        RuntimeDirectory=redis
        RuntimeDirectoryMode=0755
        [Install]
        WantedBy=multi-user.target
    """))
    run("systemctl daemon-reload")
    run(f"systemctl enable redis-{slug} && systemctl start redis-{slug}")
    wait_svc(f"redis-{slug}", 20)
    _add_port(port)
    ok(f"Redis instance: port {port}")

def _write_nginx_site(domain, php_ver):
    sock = f"/run/php/php{php_ver}-fpm.sock"
    conf = textwrap.dedent(f"""\
        server {{
            listen 80;
            listen [::]:80;
            server_name {domain} www.{domain};
            root /var/www/html/{domain};
            index index.php index.html index.htm;

            access_log /var/log/nginx/{domain}.access.log main buffer=32k flush=5s;
            error_log  /var/log/nginx/{domain}.error.log warn;

            set $skip_cache 0;
            if ($request_method = POST)         {{ set $skip_cache 1; }}
            if ($query_string != "")            {{ set $skip_cache 1; }}
            if ($request_uri ~* "/wp-admin/|/xmlrpc.php|wp-.*.php|/feed/|sitemap") {{ set $skip_cache 1; }}
            if ($http_cookie ~* "comment_author|wordpress_[a-f0-9]+|wp-postpass|wordpress_logged_in") {{ set $skip_cache 1; }}

            location / {{
                try_files $uri $uri/ /index.php$is_args$args;
            }}

            location ~ \\.php$ {{
                include fastcgi_params;
                fastcgi_pass unix:{sock};
                fastcgi_index index.php;
                fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
                fastcgi_param PATH_INFO $fastcgi_path_info;
                fastcgi_cache WORDPRESS;
                fastcgi_cache_valid 200 60m;
                fastcgi_cache_bypass $skip_cache;
                fastcgi_no_cache $skip_cache;
                add_header X-Cache $upstream_cache_status;
                fastcgi_buffers 16 16k;
                fastcgi_buffer_size 32k;
                fastcgi_read_timeout 300;
                fastcgi_send_timeout 300;
                fastcgi_connect_timeout 60;
            }}

            location ~ /\\.ht            {{ deny all; }}
            location = /favicon.ico      {{ log_not_found off; access_log off; expires max; }}
            location = /robots.txt       {{ allow all; log_not_found off; access_log off; }}
            location ~* \\.(jpg|jpeg|png|gif|ico|css|js|woff|woff2|ttf|svg|eot|webp)$ {{
                expires max;
                add_header Cache-Control "public, immutable";
                log_not_found off; access_log off;
                try_files $uri @fallback;
            }}
            location @fallback {{ try_files $uri /index.php$args; }}
            location ~ /purge(/.*)? {{
                fastcgi_cache_purge WORDPRESS "$scheme$request_method$host$1";
            }}
        }}
    """)
    avail = Path(f"/etc/nginx/sites-available/{domain}")
    avail.write_text(conf)
    enabled = Path(f"/etc/nginx/sites-enabled/{domain}")
    if not enabled.exists():
        enabled.symlink_to(avail)
    if run_ok("nginx -t 2>/dev/null"):
        svc_reload("nginx")
        ok("Nginx config applied")
    else:
        err("Nginx config invalid — check: nginx -t")

def _enable_ssl(domain):
    email = ssl_email(domain)
    if run_ok(f"certbot --nginx -d {domain} -d www.{domain} --non-interactive --agree-tos --email {email} 2>/dev/null"):
        ok(f"SSL enabled: https://{domain}")
    else:
        warn("SSL failed — site available via HTTP")

# =============================================================================
# DELETE — WordPress site
# =============================================================================
def cmd_delete(args):
    domain = args[0]
    wp_path = Path(f"/var/www/html/{domain}")
    if not wp_path.exists():
        err(f"Site not found: {domain}"); return

    # Backup first
    backup_dir = Path(f"/backups/deleted/{datetime.now().strftime('%Y%m%d-%H%M%S')}")
    backup_dir.mkdir(parents=True, exist_ok=True)
    run(f"tar -czf {backup_dir}/{domain}.tar.gz {wp_path} 2>/dev/null || true", check=False)
    info(f"Backup: {backup_dir}/{domain}.tar.gz")

    # Stop & remove Redis
    slug = domain.replace(".", "-")
    run(f"systemctl stop redis-{slug} 2>/dev/null || true", check=False)
    run(f"systemctl disable redis-{slug} 2>/dev/null || true", check=False)
    for f in [f"/etc/systemd/system/redis-{slug}.service",
              f"/etc/redis/redis-{slug}.conf"]:
        Path(f).unlink(missing_ok=True)
    shutil.rmtree(f"/var/lib/redis/{slug}", ignore_errors=True)
    run("systemctl daemon-reload", check=False)

    # Remove files & nginx
    shutil.rmtree(str(wp_path), ignore_errors=True)
    Path(f"/etc/nginx/sites-available/{domain}").unlink(missing_ok=True)
    Path(f"/etc/nginx/sites-enabled/{domain}").unlink(missing_ok=True)

    # Remove DB via PHP helper
    run(f"php {PHP_HELPER} delete-site {domain}", check=False)

    if run_ok("nginx -t 2>/dev/null"):
        svc_reload("nginx")
    ok(f"Site deleted: {domain}")

# =============================================================================
# LIST
# =============================================================================
def cmd_list(args):
    cyan("══════════════════════════════════════════")
    cyan("  WordPress Sites")
    cyan("══════════════════════════════════════════")
    wp_root = Path("/var/www/html")
    if not wp_root.exists() or not any(wp_root.iterdir()):
        info("No sites installed"); return
    for site in sorted(wp_root.iterdir()):
        if not site.is_dir(): continue
        domain = site.name
        redis_conf = Path(f"/etc/redis/redis-{domain.replace('.', '-')}.conf")
        redis_port = ""
        if redis_conf.exists():
            for ln in redis_conf.read_text().splitlines():
                if ln.startswith("port "): redis_port = ln.split()[1]
        ssl_icon = "🔒" if Path(f"/etc/letsencrypt/live/{domain}").exists() else "🌐"
        php_ver  = cmd_out(f"grep -oP 'php[0-9.]+(?=-fpm)' /etc/nginx/sites-available/{domain} 2>/dev/null | head -1") or "?"
        print(f"  {ssl_icon}  {domain:<35}  PHP {php_ver:<6}  Redis :{redis_port}")

# =============================================================================
# SITE-INFO
# =============================================================================
def cmd_site_info(args):
    domain = args[0]
    wp_path = Path(f"/var/www/html/{domain}")
    if not wp_path.exists(): err(f"Site not found: {domain}"); return
    cyan(f"══════════ {domain} ══════════")
    # Size
    size = cmd_out(f"du -sh {wp_path} 2>/dev/null | cut -f1")
    print(f"  📁  Path   : {wp_path}  ({size})")
    # PHP
    php_ver = cmd_out(f"grep -oP 'php[0-9.]+(?=-fpm)' /etc/nginx/sites-available/{domain} 2>/dev/null | head -1") or "?"
    print(f"  🐘  PHP    : {php_ver}")
    # WP version via PHP helper
    wp_ver = cmd_out(f"php {PHP_HELPER} wp-version {domain} 2>/dev/null") or "?"
    print(f"  🔧  WP     : {wp_ver}")
    # DB
    db_info = cmd_out(f"php {PHP_HELPER} db-size {domain} 2>/dev/null") or "?"
    print(f"  🗄️   DB     : {db_info}")
    # Redis
    redis_conf = f"/etc/redis/redis-{domain.replace('.', '-')}.conf"
    redis_port = cmd_out(f"grep '^port' {redis_conf} 2>/dev/null | awk '{{print $2}}'") or "6379"
    redis_ok = "✅ running" if run_ok(f"redis-cli -p {redis_port} ping 2>/dev/null | grep -q PONG") else "❌ down"
    print(f"  ⚡  Redis  : :{redis_port}  {redis_ok}")
    # SSL
    cert = Path(f"/etc/letsencrypt/live/{domain}/cert.pem")
    if cert.exists():
        exp = cmd_out(f"openssl x509 -enddate -noout -in {cert} 2>/dev/null | cut -d= -f2")
        print(f"  🔒  SSL    : Active  (expires {exp})")
    else:
        print(f"  🌐  SSL    : Not enabled")
    # HTTP
    http = cmd_out(f"curl -s -o /dev/null -w '%{{http_code}}' --max-time 5 -H 'Host:{domain}' http://127.0.0.1/ 2>/dev/null")
    print(f"  🌍  HTTP   : {http}")

# =============================================================================
# UPDATE-SITE
# =============================================================================
def cmd_update_site(args):
    target  = args[0]
    flags   = set(args[1:])
    do_all  = "--all" in flags or len(flags) == 0
    do_core    = do_all or "--core"    in flags
    do_plugins = do_all or "--plugins" in flags
    do_themes  = do_all or "--themes"  in flags
    do_db      = do_all or "--db"      in flags
    do_langs   = do_all or "--langs"   in flags
    do_check   = "--check"   in flags
    do_backup  = "--backup"  in flags

    sites = []
    if target == "all":
        wp_root = Path("/var/www/html")
        sites = [s.name for s in wp_root.iterdir() if s.is_dir() and (s / "wp-config.php").exists()]
    else:
        sites = [target]

    total_ok = 0; total_fail = 0

    for domain in sites:
        wp_path = f"/var/www/html/{domain}"
        if not Path(f"{wp_path}/wp-config.php").exists():
            warn(f"Skipping {domain} — not a WordPress site"); continue

        cyan(f"\n══════ Updating: {domain} ══════")
        wp = f"wp --allow-root --path={wp_path}"

        # Check mode
        if do_check:
            info("=== DRY RUN (--check) ===")
            run(f"sudo -u www-data {wp} core check-update 2>/dev/null || true", check=False)
            run(f"sudo -u www-data {wp} plugin list --update=available --format=table 2>/dev/null || true", check=False)
            run(f"sudo -u www-data {wp} theme  list --update=available --format=table 2>/dev/null || true", check=False)
            continue

        # Backup
        if do_backup:
            bdir = Path(f"/backups/updates/{datetime.now().strftime('%Y%m%d-%H%M%S')}")
            bdir.mkdir(parents=True, exist_ok=True)
            step(f"Backing up {domain}...")
            run(f"php {PHP_HELPER} backup-db {domain} {bdir} 2>/dev/null || true", check=False)
            run(f"tar -czf {bdir}/{domain}-files.tar.gz {wp_path}/wp-content 2>/dev/null || true", check=False)
            ok(f"Backup: {bdir}")

        site_ok = True

        if do_core:
            step("Updating WP core...")
            before = cmd_out(f"sudo -u www-data {wp} core version 2>/dev/null")
            if run_ok(f"sudo -u www-data {wp} core update --quiet 2>/dev/null"):
                after = cmd_out(f"sudo -u www-data {wp} core version 2>/dev/null")
                ok(f"Core: {before} → {after}") if before != after else ok("Core already latest")
            else:
                warn("Core update failed or already latest")

        if do_plugins:
            step("Updating plugins...")
            out = cmd_out(f"sudo -u www-data {wp} plugin update --all --format=table 2>/dev/null")
            ok("Plugins updated") if out else warn("No plugin updates")

        if do_themes:
            step("Updating themes...")
            out = cmd_out(f"sudo -u www-data {wp} theme update --all --format=table 2>/dev/null")
            ok("Themes updated") if out else warn("No theme updates")

        if do_langs:
            step("Updating translations...")
            run(f"sudo -u www-data {wp} language core update --quiet 2>/dev/null || true", check=False)
            run(f"sudo -u www-data {wp} language plugin update --all --quiet 2>/dev/null || true", check=False)
            run(f"sudo -u www-data {wp} language theme  update --all --quiet 2>/dev/null || true", check=False)
            ok("Languages updated")

        if do_db:
            step("Running DB upgrade...")
            if run_ok(f"sudo -u www-data {wp} core update-db --quiet 2>/dev/null"):
                ok("DB upgraded")
            else:
                warn("DB upgrade failed or not needed")

        total_ok += 1
        ok(f"✅ {domain} — done")

    cyan(f"\n══════ Summary: {total_ok} updated, {total_fail} failed ══════")

# =============================================================================
# CLONE
# =============================================================================
def cmd_clone(args):
    src, dst = args[0], args[1]
    src_path = Path(f"/var/www/html/{src}")
    dst_path = Path(f"/var/www/html/{dst}")
    if not src_path.exists(): err(f"Source not found: {src}"); return
    if dst_path.exists(): err(f"Destination exists: {dst}"); return

    step(f"Cloning {src} → {dst}")
    run(f"cp -a {src_path} {dst_path}")
    run(f"chown -R www-data:www-data {dst_path}")

    # Clone DB via PHP helper
    run(f"php {PHP_HELPER} clone-db {src} {dst}")

    # New Redis instance
    redis_port = next_redis_port()
    _create_site_redis(dst, redis_port)

    # Update wp-config
    run(f"php {PHP_HELPER} update-config {dst} {redis_port}")

    # Nginx
    php_ver = cmd_out(f"grep -oP 'php[0-9.]+(?=-fpm)' /etc/nginx/sites-available/{src} 2>/dev/null | head -1") or detect_php()
    _write_nginx_site(dst, php_ver)

    ok(f"Clone complete: http://{dst}")
    info(f"Add DNS for {dst} then run: easyinstall ssl {dst}")

# =============================================================================
# PHP-SWITCH
# =============================================================================
def cmd_php_switch(args):
    domain, new_ver = args[0], args[1]
    conf = Path(f"/etc/nginx/sites-available/{domain}")
    if not conf.exists(): err(f"Nginx config not found: {domain}"); return
    if not svc_active(f"php{new_ver}-fpm"):
        err(f"PHP {new_ver}-FPM not running"); return
    old_ver = cmd_out(f"grep -oP 'php[0-9.]+(?=-fpm)' {conf} 2>/dev/null | head -1") or "?"
    txt = conf.read_text()
    txt = re.sub(r"php[0-9.]+-fpm\.sock", f"php{new_ver}-fpm.sock", txt)
    conf.write_text(txt)
    if run_ok("nginx -t 2>/dev/null"):
        svc_reload("nginx")
        ok(f"{domain}: PHP {old_ver} → {new_ver}")
    else:
        # rollback
        txt = re.sub(r"php[0-9.]+-fpm\.sock", f"php{old_ver}-fpm.sock", txt)
        conf.write_text(txt)
        err("Nginx config invalid — rolled back")

# =============================================================================
# SSL
# =============================================================================
def cmd_ssl(args):
    domain = args[0]
    _enable_ssl(domain)

def cmd_ssl_renew(args):
    step("Renewing all SSL certificates")
    if run_ok("certbot renew --nginx --non-interactive 2>/dev/null"):
        svc_reload("nginx"); ok("SSL renewed")
    else: warn("Some certs may not have renewed")

# =============================================================================
# REDIS commands
# =============================================================================
def cmd_redis_status(args):
    cyan("══════ Redis Instances ══════")
    main_ok = run_ok("redis-cli -p 6379 ping 2>/dev/null | grep -q PONG")
    print(f"  {'✅' if main_ok else '❌'}  Main Redis  :6379")
    for f in sorted(Path("/etc/redis").glob("redis-*.conf")):
        slug = f.stem.replace("redis-", "")
        port = cmd_out(f"grep '^port' {f} | awk '{{print $2}}'") or "?"
        ok_flag = run_ok(f"redis-cli -p {port} ping 2>/dev/null | grep -q PONG") if port != "?" else False
        svc = f"redis-{slug}"
        print(f"  {'✅' if ok_flag else '❌'}  {slug:<30}  :{port}  ({cmd_out(f'systemctl is-active {svc} 2>/dev/null') or 'unknown'})")

def cmd_redis_restart(args):
    domain = args[0] if args else ""
    if domain:
        slug = domain.replace(".", "-")
        svc_restart(f"redis-{slug}")
        ok(f"Redis restarted for {domain}")
    else:
        svc_restart("redis-server"); ok("Main Redis restarted")

def cmd_redis_ports(args):
    cyan("══════ Redis Ports ══════")
    if REDIS_PORTS.exists():
        for p in sorted(set(REDIS_PORTS.read_text().splitlines())):
            if p.strip().isdigit():
                active = run_ok(f"ss -tlnp 2>/dev/null | grep -q ':{p} '")
                print(f"  {'✅' if active else '❌'}  :{p}")

# =============================================================================
# STATUS / HEALTH / MONITOR
# =============================================================================
def cmd_status(args):
    cyan("══════ System Status ══════")
    services = ["nginx", "mariadb", "redis-server", "fail2ban",
                "php8.4-fpm", "php8.3-fpm", "php8.2-fpm"]
    for svc in services:
        active = svc_active(svc)
        print(f"  {'✅' if active else '❌'}  {svc}")
    # Disk
    disk = cmd_out("df -h / | awk 'NR==2{print $3\"/\"$2\" (\"$5\")\"}'")
    print(f"  💾  Disk: {disk}")
    # Mem
    mem = cmd_out("free -h | awk '/Mem:/{print $3\"/\"$2}'")
    print(f"  🧠  RAM:  {mem}")

def cmd_health(args):
    cmd_status(args)
    cyan("\n══════ Sites ══════")
    wp_root = Path("/var/www/html")
    if wp_root.exists():
        for site in sorted(wp_root.iterdir()):
            if not site.is_dir(): continue
            domain = site.name
            http = cmd_out(f"curl -s -o /dev/null -w '%{{http_code}}' --max-time 5 -H 'Host:{domain}' http://127.0.0.1/ 2>/dev/null")
            icon = "✅" if http == "200" else "⚠️ "
            print(f"  {icon}  {domain:<35}  HTTP {http}")

def cmd_monitor(args):
    import time as _t
    try:
        while True:
            os.system("clear")
            cmd_status(args)
            cmd_health(args)
            print(f"\n  Refreshing every 5s… (Ctrl+C to exit)")
            _t.sleep(5)
    except KeyboardInterrupt:
        pass

def cmd_logs(args):
    domain = args[0] if args else None
    if domain:
        log_file = f"/var/log/nginx/{domain}.error.log"
        run(f"tail -50 {log_file} 2>/dev/null || echo 'No log file found'", check=False)
    else:
        run(f"tail -50 {LOG_FILE} 2>/dev/null || echo 'No log file'", check=False)

def cmd_perf(args):
    cmd_status(args)
    cyan("\n══════ Performance ══════")
    load = cmd_out("cat /proc/loadavg | awk '{print $1,$2,$3}'")
    print(f"  📊  Load avg: {load}")
    cpu = cmd_out("top -bn1 | grep 'Cpu(s)' | awk '{print $2}' 2>/dev/null") or "?"
    print(f"  🖥️   CPU:      {cpu}%")

# =============================================================================
# SELF-HEAL (core logic unchanged from original)
# =============================================================================
def cmd_self_heal(args):
    mode = args[0] if args else "full"
    cyan(f"\n══════ Self-Heal: {mode} ══════")

    def _heal_nginx():
        step("Healing Nginx")
        # FIX: Apache2 check — अगर चल रहा है तो बंद करें
        if run_ok("systemctl is-active --quiet apache2 2>/dev/null"):
            warn("Apache2 is running on port 80 — stopping and removing it")
            run("systemctl stop apache2 2>/dev/null || true", check=False)
            run("systemctl disable apache2 2>/dev/null || true", check=False)
            run("apt-get remove -y --purge apache2 apache2-bin apache2-data 2>/dev/null || true", check=False)
            run("apt-get autoremove -y 2>/dev/null || true", check=False)
            ok("Apache2 removed — port 80 freed")

        if not run_ok("nginx -t 2>/dev/null"):
            # Fix socket paths
            running_php = detect_php()
            correct_sock = f"/run/php/php{running_php}-fpm.sock"
            for cf in list(Path("/etc/nginx/sites-enabled").iterdir()) + \
                      list(Path("/etc/nginx/sites-available").iterdir()):
                if not cf.is_file(): continue
                txt = cf.read_text()
                new_txt = re.sub(r"unix:/run/php/php[0-9.]+-fpm\.sock", f"unix:{correct_sock}", txt)
                if new_txt != txt:
                    cf.write_text(new_txt)
                    info(f"Fixed socket in {cf.name}")
        if not run_ok("nginx -t 2>/dev/null"):
            warn("Nginx config still invalid")
        else:
            svc_restart("nginx")
            ok("Nginx healed")

    def _heal_php():
        step("Healing PHP-FPM")
        for ver in ["8.4", "8.3", "8.2"]:
            if not Path(f"/etc/php/{ver}").exists(): continue
            if not svc_active(f"php{ver}-fpm"):
                svc_restart(f"php{ver}-fpm"); time.sleep(2)
            fix_sock(ver)
            if svc_active(f"php{ver}-fpm"): ok(f"PHP {ver} OK")
            else: warn(f"PHP {ver} could not start")

    def _heal_redis():
        step("Healing Redis")
        if not run_ok("redis-cli -p 6379 ping 2>/dev/null | grep -q PONG"):
            svc_restart("redis-server")
        for cf in Path("/etc/redis").glob("redis-*.conf"):
            slug = cf.stem.replace("redis-", "")
            port = cmd_out(f"grep '^port' {cf} | awk '{{print $2}}'")
            if port and not run_ok(f"redis-cli -p {port} ping 2>/dev/null | grep -q PONG"):
                svc_restart(f"redis-{slug}")

    def _heal_mariadb():
        step("Healing MariaDB")
        if not svc_active("mariadb"):
            svc_restart("mariadb"); time.sleep(3)
        if svc_active("mariadb"): ok("MariaDB OK")
        else: warn("MariaDB could not start")

    def _heal_ssl():
        step("Healing SSL")
        cert_dir = Path("/etc/letsencrypt/live")
        if not cert_dir.exists(): return
        for domain_dir in cert_dir.iterdir():
            if domain_dir.name == "README": continue
            cert = domain_dir / "cert.pem"
            if not cert.exists(): continue
            exp = cmd_out(f"openssl x509 -enddate -noout -in {cert} 2>/dev/null | cut -d= -f2")
            if exp:
                try:
                    from datetime import datetime as dt
                    exp_dt = dt.strptime(exp.strip(), "%b %d %H:%M:%S %Y %Z")
                    days = (exp_dt - dt.now()).days
                    if days < 14:
                        info(f"Renewing {domain_dir.name} ({days}d left)")
                        run(f"certbot renew --cert-name {domain_dir.name} --nginx --non-interactive 2>/dev/null || true", check=False)
                except: pass

    def _heal_disk():
        step("Healing disk")
        used = int(cmd_out("df / | awk 'NR==2{gsub(/%/,\"\",$5);print $5}'") or "0")
        if used > 85:
            run("apt-get autoremove -y 2>/dev/null || true", check=False)
            run("apt-get autoclean 2>/dev/null || true", check=False)
            run("journalctl --vacuum-size=100M 2>/dev/null || true", check=False)
            run("find /var/log -name '*.gz' -mtime +7 -delete 2>/dev/null || true", check=False)
            ok("Disk cleaned")

    def _heal_wp():
        step("Healing WordPress permissions")
        for site in Path("/var/www/html").iterdir():
            if not (site / "wp-config.php").exists(): continue
            run(f"find {site} -type d -exec chmod 755 {{}} \\; 2>/dev/null || true", check=False)
            run(f"find {site} -type f -exec chmod 644 {{}} \\; 2>/dev/null || true", check=False)
            run(f"chmod 600 {site}/wp-config.php 2>/dev/null || true", check=False)
            run(f"chown -R www-data:www-data {site} 2>/dev/null || true", check=False)
        ok("WP permissions fixed")

    def _heal_502():
        step("Fixing 502 Bad Gateway")
        # FIX: Apache2 port 80 block कर रहा हो तो हटाएं
        if run_ok("systemctl is-active --quiet apache2 2>/dev/null"):
            warn("Apache2 is running — this causes 502. Removing...")
            run("systemctl stop apache2 2>/dev/null || true", check=False)
            run("systemctl disable apache2 2>/dev/null || true", check=False)
            run("apt-get remove -y --purge apache2 apache2-bin apache2-data libapache2-mod-php* 2>/dev/null || true", check=False)
            run("apt-get autoremove -y 2>/dev/null || true", check=False)
            ok("Apache2 removed — port 80 freed")
        # Port 80 free है तो Nginx start करें
        if not svc_active("nginx"):
            run("systemctl start nginx 2>/dev/null || true", check=False)
        _heal_php()
        running_php = detect_php()
        correct_sock = f"/run/php/php{running_php}-fpm.sock"
        for cf in list(Path("/etc/nginx/sites-enabled").iterdir()) + \
                  list(Path("/etc/nginx/sites-available").iterdir()):
            if not cf.is_file(): continue
            txt = cf.read_text()
            new_txt = re.sub(r"unix:/run/php/php[0-9.]+-fpm\.sock", f"unix:{correct_sock}", txt)
            if new_txt != txt: cf.write_text(new_txt); info(f"Fixed {cf.name}")
        _heal_nginx()
        ok("502 fix applied")

    if   mode in ("services", "quick"):   _heal_nginx(); _heal_php(); _heal_redis(); _heal_mariadb()
    elif mode == "configs":               _heal_nginx(); _heal_php()
    elif mode == "ssl":                   _heal_ssl()
    elif mode == "disk":                  _heal_disk()
    elif mode == "wp":                    _heal_wp()
    elif mode in ("502","nginx-502"):     _heal_502()
    else:  # full
        _heal_nginx(); _heal_php(); _heal_redis(); _heal_mariadb()
        _heal_ssl(); _heal_disk(); _heal_wp()

    ok(f"Self-heal [{mode}] complete")

# =============================================================================
# SELF-UPDATE
# =============================================================================
def cmd_self_update(args):
    mode = args[0] if args else "all"
    cyan(f"\n══════ Self-Update: {mode} ══════")

    def _upd_nginx():
        step("Updating Nginx")
        run("apt-get install -y --only-upgrade nginx 2>/dev/null || true", check=False)
        svc_restart("nginx"); ok("Nginx updated")

    def _upd_php():
        step("Updating PHP")
        run("apt-get install -y --only-upgrade php8.4-fpm php8.3-fpm php8.2-fpm 2>/dev/null || true", check=False)
        for v in ["8.4","8.3","8.2"]:
            if svc_active(f"php{v}-fpm"): svc_restart(f"php{v}-fpm")
        ok("PHP updated")

    def _upd_redis():
        step("Updating Redis")
        run("apt-get install -y --only-upgrade redis-server 2>/dev/null || true", check=False)
        svc_restart("redis-server"); ok("Redis updated")

    def _upd_mariadb():
        step("Updating MariaDB")
        run("apt-get install -y --only-upgrade mariadb-server 2>/dev/null || true", check=False)
        run("mysql_upgrade --silent 2>/dev/null || true", check=False)
        ok("MariaDB updated")

    def _upd_wpcli():
        step("Updating WP-CLI")
        run("wp cli update --yes --allow-root 2>/dev/null || true", check=False)
        ok("WP-CLI updated")

    if   mode == "nginx":   _upd_nginx()
    elif mode == "php":     _upd_php()
    elif mode == "redis":   _upd_redis()
    elif mode == "mariadb": _upd_mariadb()
    elif mode == "wpcli":   _upd_wpcli()
    else:
        run("apt-get update -y 2>/dev/null || true", check=False)
        _upd_nginx(); _upd_php(); _upd_redis(); _upd_mariadb(); _upd_wpcli()
    ok("Self-update complete")

def cmd_self_check(args):
    cyan("══════ Version Status ══════")
    def ver(cmd): return cmd_out(cmd) or "?"
    # FIX: Backslashes cannot appear inside f-string expressions (Python 3.11+)
    # Store command outputs in variables first, then use them in f-strings
    nginx_v   = ver("nginx -v 2>&1 | grep -oP '[0-9]+\\.[0-9]+\\.[0-9]+'")
    php_v     = ver("php --version 2>/dev/null | head -1 | grep -oP '[0-9]+\\.[0-9]+\\.[0-9]+'")
    redis_v   = ver("redis-server --version 2>/dev/null | grep -oP 'v=\\K[0-9.]+'")
    mariadb_v = ver("mysql --version 2>/dev/null | grep -oP 'Distrib \\K[0-9.]+'")
    wpcli_v   = ver("wp --allow-root --version 2>/dev/null")
    certbot_v = ver("certbot --version 2>/dev/null | awk '{print $2}'")
    python_v  = ver("python3 --version 2>/dev/null | awk '{print $2}'")
    print(f"  Nginx   : {nginx_v}")
    print(f"  PHP     : {php_v}")
    print(f"  Redis   : {redis_v}")
    print(f"  MariaDB : {mariadb_v}")
    print(f"  WP-CLI  : {wpcli_v}")
    print(f"  Certbot : {certbot_v}")
    print(f"  Python  : {python_v}")
    # Show active PHP versions
    for v in ["8.4", "8.3", "8.2", "8.1"]:
        if svc_active(f"php{v}-fpm"):
            sock_ok = "✅" if php_sock(v).exists() else "❌"
            print(f"  PHP{v}-FPM : ✅  socket {sock_ok}")

# =============================================================================
# BACKUP
# =============================================================================
def cmd_backup(args):
    domain = args[0] if args else None
    ts = datetime.now().strftime("%Y%m%d-%H%M%S")
    bdir = Path(f"/backups/{ts}"); bdir.mkdir(parents=True, exist_ok=True)
    step(f"Backup → {bdir}")
    if domain:
        run(f"php {PHP_HELPER} backup-db {domain} {bdir} 2>/dev/null || true", check=False)
        run(f"tar -czf {bdir}/{domain}-files.tar.gz /var/www/html/{domain}/wp-content 2>/dev/null || true", check=False)
    else:
        run(f"mysqldump --all-databases 2>/dev/null | gzip > {bdir}/all-databases.sql.gz || true", check=False)
        run(f"tar -czf {bdir}/nginx-conf.tar.gz /etc/nginx 2>/dev/null || true", check=False)
    ok(f"Backup complete: {bdir}")

# =============================================================================
# OPTIMIZE / CLEAN
# =============================================================================
def cmd_optimize(args):
    step("Running optimization")
    run("mysqlcheck --auto-repair --all-databases --silent 2>/dev/null || true", check=False)
    run("php {PHP_HELPER} optimize-tables 2>/dev/null || true", check=False)
    for v in ["8.4","8.3","8.2"]:
        if svc_active(f"php{v}-fpm"): svc_reload(f"php{v}-fpm")
    ok("Optimization complete")

def cmd_clean(args):
    step("Cleaning cache and temp files")
    run("find /tmp -type f -mtime +1 -delete 2>/dev/null || true", check=False)
    run("find /var/log/nginx -name '*.log' -size +100M -exec truncate -s 50M {} \\; 2>/dev/null || true", check=False)
    run("apt-get autoremove -y 2>/dev/null && apt-get autoclean 2>/dev/null || true", check=False)
    run("journalctl --vacuum-time=7d 2>/dev/null || true", check=False)
    ok("Clean complete")

# =============================================================================
# WEBSOCKET
# =============================================================================
def cmd_ws_enable(args):
    domain, port = args[0], (args[1] if len(args) > 1 else "8080")
    conf = Path(f"/etc/nginx/conf.d/websocket-map.conf")
    if not conf.exists():
        conf.write_text("map $http_upgrade $connection_upgrade {\n    default close;\n    websocket upgrade;\n    \"\" close;\n}\n")
    nginx_conf = Path(f"/etc/nginx/sites-available/{domain}")
    if not nginx_conf.exists(): err(f"Nginx config not found: {domain}"); return
    txt = nginx_conf.read_text()
    if "proxy_set_header.*Upgrade" not in txt:
        ws_block = textwrap.dedent(f"""
            location ~ ^/(ws|wss)(/.*)? {{
                proxy_pass         http://127.0.0.1:{port};
                proxy_http_version 1.1;
                proxy_set_header   Upgrade $http_upgrade;
                proxy_set_header   Connection $connection_upgrade;
                proxy_set_header   Host $host;
                proxy_read_timeout 3600s;
                proxy_buffering    off;
            }}
        """)
        txt = txt.rstrip().rstrip("}") + ws_block + "\n}\n"
        nginx_conf.write_text(txt)
    if run_ok("nginx -t 2>/dev/null"): svc_reload("nginx"); ok(f"WebSocket enabled for {domain}")
    else: err("Nginx config invalid after WS enable")

def cmd_ws_disable(args):
    domain = args[0]
    nginx_conf = Path(f"/etc/nginx/sites-available/{domain}")
    if not nginx_conf.exists(): err(f"Config not found"); return
    txt = nginx_conf.read_text()
    txt = re.sub(r"\n\s+location ~ \^\(/ws\|/wss\).*?\}\n", "", txt, flags=re.DOTALL)
    nginx_conf.write_text(txt)
    if run_ok("nginx -t 2>/dev/null"): svc_reload("nginx"); ok("WebSocket disabled")
    else: err("Nginx config invalid")

def cmd_ws_status(args):
    domain = args[0] if args else None
    sites = [domain] if domain else [f.name for f in Path("/etc/nginx/sites-available").iterdir()]
    for s in sites:
        conf = Path(f"/etc/nginx/sites-available/{s}")
        if conf.exists():
            has_ws = "proxy_set_header   Upgrade" in conf.read_text()
            print(f"  {'✅' if has_ws else '❌'}  {s}  WebSocket {'enabled' if has_ws else 'disabled'}")

def cmd_ws_test(args):
    domain = args[0] if args else ""
    info(f"Testing WebSocket for {domain}")
    code = cmd_out(f"curl -s -o /dev/null -w '%{{http_code}}' --max-time 5 -H 'Host:{domain}' -H 'Upgrade: websocket' -H 'Connection: Upgrade' http://127.0.0.1/ws/ 2>/dev/null")
    print(f"  HTTP response: {code}")

# =============================================================================
# HTTP3
# =============================================================================
def cmd_http3_enable(args):
    has_quic = run_ok("nginx -V 2>&1 | grep -qi quic")
    if has_quic:
        Path("/etc/nginx/conf.d/http3-quic.conf").write_text("quic_retry on;\nquic_gso on;\n")
        run("ufw allow 443/udp comment 'HTTP3 QUIC' 2>/dev/null || true", check=False)
        if run_ok("nginx -t 2>/dev/null"): svc_reload("nginx"); ok("HTTP/3 enabled")
        else: err("HTTP/3 config invalid")
    else:
        warn("Nginx binary does not support QUIC — install nginx-quic first")

def cmd_http3_status(args):
    has_quic = run_ok("nginx -V 2>&1 | grep -qi quic")
    print(f"  QUIC binary support: {'✅' if has_quic else '❌'}")
    print(f"  http3-quic.conf:     {'✅' if Path('/etc/nginx/conf.d/http3-quic.conf').exists() else '❌'}")
    udp443 = run_ok("ufw status 2>/dev/null | grep -q '443/udp'")
    print(f"  UDP/443 (firewall):  {'✅' if udp443 else '❌'}")

# =============================================================================
# EDGE
# =============================================================================
def cmd_edge_setup(args):
    step("Setting up Edge Computing layer")
    Path("/etc/nginx/conf.d/edge-computing.conf").write_text(textwrap.dedent("""\
        fastcgi_cache_path /var/cache/nginx/edge levels=1:2
            keys_zone=EDGE_CACHE:64m inactive=10m max_size=512m;
        geo $edge_region {
            default  global;
            10.0.0.0/8 global; 127.0.0.0/8 global;
            1.0.0.0/8 ap; 14.0.0.0/8 ap; 27.0.0.0/8 ap; 58.0.0.0/8 ap; 101.0.0.0/8 ap;
            2.0.0.0/8 eu; 5.0.0.0/8 eu; 37.0.0.0/8 eu; 46.0.0.0/8 eu; 80.0.0.0/8 eu;
            3.0.0.0/8 na; 4.0.0.0/8 na; 24.0.0.0/8 na; 67.0.0.0/8 na;
        }
        geo $edge_purge_allowed {
            default 0; 127.0.0.1 1; 10.0.0.0/8 1; 172.16.0.0/12 1;
        }
    """))
    Path("/var/cache/nginx/edge").mkdir(parents=True, exist_ok=True)
    run("chown -R nginx:nginx /var/cache/nginx/edge 2>/dev/null || chown -R www-data:www-data /var/cache/nginx/edge 2>/dev/null || true", check=False)
    if run_ok("nginx -t 2>/dev/null"): svc_reload("nginx"); ok("Edge layer active")
    else: err("Edge config invalid")

def cmd_edge_status(args):
    conf = Path("/etc/nginx/conf.d/edge-computing.conf")
    print(f"  Edge config: {'✅' if conf.exists() else '❌'}")
    cache = Path("/var/cache/nginx/edge")
    if cache.exists():
        sz = cmd_out(f"du -sh {cache} 2>/dev/null | cut -f1") or "0"
        fc = cmd_out(f"find {cache} -type f 2>/dev/null | wc -l") or "0"
        print(f"  Cache: {sz}  ({fc} files)")

def cmd_edge_purge(args):
    domain = args[0] if args else ""; path = args[1] if len(args)>1 else "/"
    run(f"curl -s -X PURGE -H 'Host:{domain}' http://127.0.0.1/purge{path} 2>/dev/null || true", check=False)
    ok(f"Edge purge: {domain}{path}")

# =============================================================================
# AI
# =============================================================================
def cmd_ai_diagnose(args):
    domain = args[0] if args else None
    info("AI Diagnose — reading logs...")
    log_src = f"/var/log/nginx/{domain}.error.log" if domain else str(ERR_LOG)
    logs = cmd_out(f"tail -50 {log_src} 2>/dev/null") or "No logs found"
    cfg_file = STATE_DIR / "ai.conf"
    if not cfg_file.exists(): warn("No AI API key configured. Run: easyinstall ai-setup"); return
    cfg = json.loads(cfg_file.read_text())
    api_key = cfg.get("key",""); provider = cfg.get("provider","openai")
    import urllib.request
    payload = json.dumps({"model":"gpt-4o-mini","messages":[
        {"role":"system","content":"You are a WordPress server expert. Analyze logs and suggest fixes."},
        {"role":"user","content":f"Server logs:\n{logs}\nDiagnose and provide specific fix commands."}
    ],"max_tokens":500}).encode()
    req = urllib.request.Request("https://api.openai.com/v1/chat/completions",
        data=payload, headers={"Authorization":f"Bearer {api_key}","Content-Type":"application/json"})
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            data = json.loads(resp.read())
            print("\n" + data["choices"][0]["message"]["content"])
    except Exception as e:
        err(f"AI request failed: {e}")

def cmd_ai_setup(args):
    key = input("Enter AI API key: ").strip()
    provider = input("Provider (openai/groq/gemini) [openai]: ").strip() or "openai"
    (STATE_DIR / "ai.conf").write_text(json.dumps({"key":key,"provider":provider}))
    ok("AI configured")

def cmd_ai_optimize(args):
    info("AI Optimize — analyzing system...")
    T = ram_tune()
    tips = [
        f"RAM={T['ram']}MB — PHP children={T['php_children']} is optimal",
        f"MySQL buffer pool {T['mysql_buf']} suits your RAM",
        "Enable Redis object cache in WordPress for 40-60% speed boost",
        "Use Cloudflare CDN to offload static assets",
        "Enable Brotli compression: apt-get install libnginx-mod-brotli",
    ]
    cyan("══ AI Performance Tips ══")
    for tip in tips: print(f"  💡  {tip}")

# =============================================================================
# PAGESPEED
# =============================================================================
def cmd_pagespeed(args):
    if not args: print("Usage: easyinstall pagespeed [optimize|score|report|images] domain.com"); return
    sub = args[0]; domain = args[1] if len(args)>1 else ""
    if sub == "optimize":
        run(f"php {PHP_HELPER} pagespeed-optimize {domain} 2>/dev/null || true", check=False)
        ok(f"PageSpeed optimized: {domain}")
    elif sub == "score":
        url = f"https://pagespeedonline.googleapis.com/pagespeedonline/v5/runPagespeed?url=http://{domain}&strategy=desktop"
        score = cmd_out(f"curl -s '{url}' 2>/dev/null | python3 -c \"import sys,json; d=json.load(sys.stdin); print(int(d['lighthouseResult']['categories']['performance']['score']*100))\" 2>/dev/null") or "?"
        print(f"  PageSpeed score for {domain}: {score}/100")
    elif sub == "images":
        run(f"php {PHP_HELPER} optimize-images {domain} 2>/dev/null || true", check=False)
        ok("Images optimized")
    elif sub == "report":
        run(f"php {PHP_HELPER} pagespeed-report {domain} 2>/dev/null || true", check=False)

# =============================================================================
# FIX-APACHE — Apache conflict को permanently fix करें
# =============================================================================
def cmd_fix_apache(args):
    """Apache2 को हटाकर Nginx को port 80 पर restore करें"""
    cyan("\n══════ Apache2 Conflict Fix ══════")
    step("Stopping and removing Apache2")

    # 1. Apache stop + disable + purge
    run("systemctl stop apache2 2>/dev/null || true", check=False)
    run("systemctl disable apache2 2>/dev/null || true", check=False)
    run("DEBIAN_FRONTEND=noninteractive apt-get remove -y --purge apache2 apache2-bin apache2-data apache2-utils libapache2-mod-php* 2>/dev/null || true", check=False)
    run("apt-get autoremove -y 2>/dev/null || true", check=False)
    run("rm -rf /etc/apache2 2>/dev/null || true", check=False)
    ok("Apache2 purged")

    # 2. Apache को apt से block करें
    Path("/etc/apt/preferences.d/block-apache2.pref").write_text(textwrap.dedent("""\
        Package: apache2 apache2-bin apache2-data apache2-utils libapache2-mod-php*
        Pin: release *
        Pin-Priority: -1
    """))
    ok("Apache2 blocked in apt preferences")

    # 3. Port 80 free है — Nginx start करें
    step("Starting Nginx on port 80")
    if not run_ok("nginx -t 2>/dev/null"):
        warn("Nginx config has errors — run: nginx -t")
    else:
        run("systemctl start nginx 2>/dev/null || true", check=False)
        run("systemctl enable nginx 2>/dev/null || true", check=False)
        import time as _t; _t.sleep(2)
        if svc_active("nginx"):
            ok("Nginx is running on port 80")
        else:
            err("Nginx still not running — check: journalctl -u nginx -n 30")
            return

    # 4. PHP-FPM restart करें
    step("Restarting PHP-FPM")
    for v in ["8.4", "8.3", "8.2"]:
        if Path(f"/etc/php/{v}").exists():
            run(f"systemctl restart php{v}-fpm 2>/dev/null || true", check=False)
            fix_sock(v)
            if svc_active(f"php{v}-fpm"):
                ok(f"PHP {v}-FPM running")

    ok("Apache fix complete — site should be accessible now")
    info("Test: curl -I http://localhost")
    info("If still 502: easyinstall self-heal 502")


# =============================================================================
# MAIN DISPATCH
# =============================================================================
COMMANDS = {
    "install":      cmd_install,
    "create":       cmd_create,
    "delete":       cmd_delete,
    "list":         cmd_list,
    "site-info":    cmd_site_info,
    "update-site":  cmd_update_site,
    "clone":        cmd_clone,
    "php-switch":   cmd_php_switch,
    "ssl":          cmd_ssl,
    "ssl-renew":    cmd_ssl_renew,
    "redis-status": cmd_redis_status,
    "redis-restart":cmd_redis_restart,
    "redis-ports":  cmd_redis_ports,
    "status":       cmd_status,
    "health":       cmd_health,
    "monitor":      cmd_monitor,
    "logs":         cmd_logs,
    "perf":         cmd_perf,
    "self-heal":    cmd_self_heal,
    "self-update":  cmd_self_update,
    "self-check":   cmd_self_check,
    "backup":       cmd_backup,
    "optimize":     cmd_optimize,
    "clean":        cmd_clean,
    "ws-enable":    cmd_ws_enable,
    "ws-disable":   cmd_ws_disable,
    "ws-status":    cmd_ws_status,
    "ws-test":      cmd_ws_test,
    "http3-enable": cmd_http3_enable,
    "http3-status": cmd_http3_status,
    "edge-setup":   cmd_edge_setup,
    "edge-status":  cmd_edge_status,
    "edge-purge":   cmd_edge_purge,
    "ai-diagnose":  cmd_ai_diagnose,
    "ai-setup":     cmd_ai_setup,
    "ai-optimize":  cmd_ai_optimize,
    "pagespeed":    cmd_pagespeed,
    "fix-apache":   cmd_fix_apache,
    "fix-nginx":    cmd_fix_apache,  # alias
}

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: easyinstall <command> [args]"); sys.exit(1)
    cmd  = sys.argv[1]
    args = sys.argv[2:]
    fn   = COMMANDS.get(cmd)
    if fn:
        try:
            fn(args)
        except KeyboardInterrupt:
            print("\nInterrupted")
        except Exception as e:
            err(str(e))
            _log("ERROR", str(e))
            sys.exit(1)
    else:
        err(f"Unknown command: {cmd}")
        print("Run: easyinstall help")
        sys.exit(1)
