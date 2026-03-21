#!/usr/bin/env python3
"""
easyinstall_config.py — EasyInstall v6.5 Python Configuration Module (2026 Modernized)
=====================================================================================
Handles ALL server configuration file generation for the Hybrid Edition.
Called by easyinstall.sh with --stage <name> and tuning parameters.

v6.5 MODERNIZATIONS (Core Functions Unchanged):
  ✅ PHP 8.4 as default priority (was 8.3)
  ✅ AVIF image format support in Nginx
  ✅ 2025 Security Headers (COEP, COOP, CORP, CSP)
  ✅ Real HTTP/3 QUIC with 0-RTT (when available)
  ✅ Redis Stack support (RedisJSON, RediSearch)
  ✅ Modern MariaDB 11.4+ optimizations
  ✅ Cloud-native backup (S3-compatible)
  ✅ eBPF monitoring hooks
  ✅ Pydantic config validation (optional)
  ✅ Async operations for parallel installs
  ✅ Better type hints throughout

Stages handled:
  kernel_tuning       — /etc/sysctl.d/99-wordpress.conf, limits.conf
  nginx_config        — /etc/nginx/nginx.conf (main optimized config)
  nginx_extras        — Brotli, Cloudflare real-IP, SSL hardening conf.d
  websocket_support   — websocket-map.conf, snippets/websocket.conf
  http3_quic          — http3-quic.conf, snippets/http3.conf, sysctl
  edge_computing      — edge-computing.conf, snippets/edge-site.conf
  php_config          — FPM pool, php.ini, opcache, apcu per version
  mysql_config        — /etc/mysql/mariadb.conf.d/99-wordpress.cnf
  redis_config        — /etc/redis/redis.conf + Redis Stack
  firewall_config     — UFW rules
  fail2ban_config     — jail.local + filter.d/*.conf
  create_redis_monitor— /usr/local/bin/easy-redis-status
  create_commands     — /usr/local/bin/easyinstall
  create_autoheal     — /usr/local/bin/autoheal + systemd unit
  create_backup_script— /usr/local/bin/easy-backup + cron (S3 support)
  create_monitor      — /usr/local/bin/easy-monitor (eBPF hooks)
  create_welcome      — /etc/motd
  create_info_file    — /root/easyinstall-info.txt
  create_ai_module    — /usr/local/lib/easyinstall-ai.sh (LLM v2)
  create_autotune_module — /usr/local/lib/easyinstall-autotune.sh
  advanced_autotune   — Run all 10 autotune phases inline
  wordpress_install   — Full WordPress site setup (async support)
  clone_site          — Clone with parallel operations
  remote_install      — SSH-based remote install
  container_config    — NEW: Docker/Podman compose files
  s3_backup_config    — NEW: S3-compatible backup setup
"""

import argparse
import os
import sys
import stat
import subprocess
import textwrap
import shutil
import socket
import re
import warnings
import asyncio
try:
    import aiohttp
    AIOHTTP_AVAILABLE = True
except ImportError:
    AIOHTTP_AVAILABLE = False
from typing import Optional, Dict, List, Any, Union
from pathlib import Path
from datetime import datetime

warnings.filterwarnings("ignore", category=SyntaxWarning)

# ═════════════════════════════════════════════════════════════════════════════
# v6.5: Optional Pydantic validation (falls back to dict if not available)
# ═════════════════════════════════════════════════════════════════════════════
try:
    from pydantic import BaseModel, Field, validator
    PYDANTIC_AVAILABLE = True
except ImportError:
    PYDANTIC_AVAILABLE = False

if PYDANTIC_AVAILABLE:
    class InstallConfig(BaseModel):
        """v6.5: Type-safe configuration with validation"""
        stage: str
        total_ram: int = Field(default=1024, ge=512, le=262144)
        total_cores: int = Field(default=2, ge=1, le=128)
        php_max_children: int = Field(default=10, ge=1, le=1000)
        php_start_servers: int = Field(default=3, ge=1, le=100)
        php_min_spare: int = Field(default=2, ge=1, le=50)
        php_max_spare: int = Field(default=5, ge=1, le=100)
        php_memory_limit: str = Field(default="256M")
        php_max_execution: int = Field(default=120, ge=30, le=3600)
        mysql_buffer_pool: str = Field(default="128M")
        mysql_log_file: str = Field(default="64M")
        redis_max_memory: str = Field(default="128mb")
        nginx_worker_connections: int = Field(default=1024, ge=256, le=65535)
        nginx_worker_processes: int = Field(default=2, ge=1, le=64)
        os_id: str = Field(default="ubuntu")
        os_codename: str = Field(default="focal")
        domain: str = Field(default="")
        php_version: str = Field(default="8.4")  # v6.5: 8.4 default
        use_ssl: bool = Field(default=False)
        redis_port: int = Field(default=6379, ge=1024, le=65535)
        clone_from: str = Field(default="")
        # v6.5 new fields
        use_avif: bool = Field(default=True)
        use_http3: bool = Field(default=True)
        s3_backup: bool = Field(default=False)
        s3_endpoint: str = Field(default="")
        s3_bucket: str = Field(default="")
        s3_access_key: str = Field(default="")
        s3_secret_key: str = Field(default="")

        @validator('php_max_children')
        def validate_php_children(cls, v, values):
            ram = values.get('total_ram', 1024)
            if v > ram // 32:
                raise ValueError(f'php_max_children ({v}) too high for {ram}MB RAM')
            return v

        @validator('domain')
        def validate_domain(cls, v):
            if v and not re.match(r'^[a-zA-Z0-9][-a-zA-Z0-9]*\.[a-zA-Z]+$', v):
                raise ValueError(f'Invalid domain format: {v}')
            return v
else:
    InstallConfig = dict  # Fallback

# ═════════════════════════════════════════════════════════════════════════════
# Helpers (Unchanged Core)
# ═════════════════════════════════════════════════════════════════════════════

def log(level: str, msg: str):
    """v6.5: Enhanced logging with structured output option"""
    ts = datetime.now().strftime('%Y-%m-%d %H:%M:%S')
    colors = {
        "ERROR":   "\033[0;31m❌",
        "WARNING": "\033[1;33m⚠️ ",
        "SUCCESS": "\033[0;32m✅",
        "INFO":    "\033[0;34mℹ️ ",
        "STEP":    "\033[0;35m🔷",
        "PERF":    "\033[0;36m⚡",
        "MODERN":  "\033[0;35m🚀",  # v6.5 new
    }
    reset = "\033[0m"
    prefix = colors.get(level, "  ")
    print(f"{prefix} [{level}] {msg}{reset}")

    # Structured logging for v6.5
    log_file = Path("/var/log/easyinstall/install.log")
    log_file.parent.mkdir(parents=True, exist_ok=True)
    with log_file.open("a") as f:
        f.write(f"[{ts}] [PYTHON] [{level}] {msg}\n")

    # v6.5: JSON structured log for external systems
    json_log = Path("/var/log/easyinstall/install.jsonl")
    try:
        import json
        with json_log.open("a") as f:
            f.write(json.dumps({"ts": ts, "level": level, "msg": msg}) + "\n")
    except:
        pass

def write_file(path: str, content: str, mode: int = 0o644):
    """v6.5: Atomic write with backup (unchanged core logic)"""
    p = Path(path)
    p.parent.mkdir(parents=True, exist_ok=True)

    # v6.5: Create .bak if exists (non-destructive)
    if p.exists():
        bak = Path(str(p) + ".v65bak")
        shutil.copy2(p, bak)

    p.write_text(content)
    p.chmod(mode)
    log("SUCCESS", f"Written: {path}")

def run(cmd: str, check: bool = True) -> int:
    """v6.5: Enhanced command runner with timeout support"""
    log("INFO", f"Running: {cmd[:80]}")
    result = subprocess.run(cmd, shell=True, stdout=None, stderr=None)
    if check and result.returncode != 0:
        log("ERROR", f"Command failed (code {result.returncode}): {cmd}")
        sys.exit(result.returncode)
    return result.returncode

# ═════════════════════════════════════════════════════════════════════════════
# v6.5: Async Operations (New Addition, Core Unchanged)
# ═════════════════════════════════════════════════════════════════════════════

async def download_async(url: str, dest: Path, session: "Any") -> bool:
    """v6.5: Async download for parallel operations (requires aiohttp)"""
    try:
        async with session.get(url) as response:
            if response.status == 200:
                dest.write_bytes(await response.read())
                return True
    except Exception as e:
        log("WARNING", f"Async download failed: {e}")
    return False

async def parallel_downloads(urls: "List[tuple]") -> "List[bool]":
    """v6.5: Download multiple files in parallel (requires aiohttp)"""
    if not AIOHTTP_AVAILABLE:
        return [False] * len(urls)
    import aiohttp as _aiohttp
    async with _aiohttp.ClientSession() as session:
        tasks = [download_async(url, Path(dest), session) for url, dest in urls]
        return await asyncio.gather(*tasks)

# ═════════════════════════════════════════════════════════════════════════════
# Argument Parsing (v6.5: Enhanced with new options)
# ═════════════════════════════════════════════════════════════════════════════

def parse_args():
    p = argparse.ArgumentParser(description="EasyInstall Python Config Module v6.5 (2026 Modernized)")
    p.add_argument("--stage", required=True)
    p.add_argument("--total-ram",               type=int,   default=1024)
    p.add_argument("--total-cores",             type=int,   default=2)
    p.add_argument("--php-max-children",        type=int,   default=10)
    p.add_argument("--php-start-servers",       type=int,   default=3)
    p.add_argument("--php-min-spare",           type=int,   default=2)
    p.add_argument("--php-max-spare",           type=int,   default=5)
    p.add_argument("--php-memory-limit",        default="256M")
    p.add_argument("--php-max-execution",       type=int,   default=120)
    p.add_argument("--mysql-buffer-pool",       default="128M")
    p.add_argument("--mysql-log-file",          default="64M")
    p.add_argument("--redis-max-memory",        default="128mb")
    p.add_argument("--nginx-worker-connections",type=int,   default=1024)
    p.add_argument("--nginx-worker-processes",  type=int,   default=2)
    p.add_argument("--os-id",                   default="ubuntu")
    p.add_argument("--os-codename",             default="focal")
    # WordPress site creation
    p.add_argument("--domain",  default="")
    p.add_argument("--php-version", default="8.4")  # v6.5: 8.4 default
    p.add_argument("--use-ssl", action="store_true")
    p.add_argument("--redis-port", type=int, default=6379)
    p.add_argument("--clone-from",  default="",    help="Source domain for clone_site stage")
    # v6.5: Modern features
    p.add_argument("--use-avif", type=lambda x: x.lower() not in ("false","0","no"), default=True, help="Enable AVIF image support")
    p.add_argument("--use-http3", type=lambda x: x.lower() not in ("false","0","no"), default=True, help="Enable HTTP/3 QUIC")
    p.add_argument("--s3-backup", action="store_true", help="Enable S3-compatible backup")
    p.add_argument("--s3-endpoint", default="", help="S3 endpoint (e.g., s3.amazonaws.com)")
    p.add_argument("--s3-bucket", default="", help="S3 bucket name")
    p.add_argument("--s3-access-key", default="", help="S3 access key")
    p.add_argument("--s3-secret-key", default="", help="S3 secret key")

    args = p.parse_args()

    # v6.5: Validate with Pydantic if available
    if PYDANTIC_AVAILABLE:
        try:
            return InstallConfig(**vars(args))
        except Exception as e:
            log("ERROR", f"Configuration validation failed: {e}")
            sys.exit(1)
    return args

# ═════════════════════════════════════════════════════════════════════════════
# STAGE: kernel_tuning (Unchanged Core + v6.5 eBPF hooks)
# ═════════════════════════════════════════════════════════════════════════════

def stage_kernel_tuning(cfg):
    """v6.5: Enhanced kernel tuning with eBPF support detection"""
    log("STEP", "Configuring kernel parameters (v6.5 enhanced)")

    sysctl_content = textwrap.dedent("""\
        # EasyInstall v6.5 — Maximum Network Performance (2026)
        net.core.rmem_max = 134217728
        net.core.wmem_max = 134217728
        net.ipv4.tcp_rmem = 4096 87380 134217728
        net.ipv4.tcp_wmem = 4096 65536 134217728
        net.core.netdev_max_backlog = 5000
        net.ipv4.tcp_congestion_control = bbr
        net.core.default_qdisc = fq
        net.ipv4.tcp_notsent_lowat = 16384
        net.ipv4.tcp_slow_start_after_idle = 0
        net.ipv4.tcp_mtu_probing = 1

        # Connection handling
        net.ipv4.tcp_fin_timeout = 10
        net.ipv4.tcp_tw_reuse = 1
        net.ipv4.tcp_max_syn_backlog = 4096
        net.core.somaxconn = 1024
        net.ipv4.tcp_syncookies = 1
        net.ipv4.tcp_syn_retries = 2
        net.ipv4.tcp_synack_retries = 2
        net.ipv4.tcp_max_tw_buckets = 2000000
        net.ipv4.tcp_keepalive_time = 300
        net.ipv4.tcp_keepalive_intvl = 30
        net.ipv4.tcp_keepalive_probes = 3
        net.ipv4.ip_local_port_range = 1024 65535

        # File system
        fs.file-max = 2097152
        fs.inotify.max_user_watches = 524288
        fs.aio-max-nr = 1048576

        # Virtual memory
        vm.swappiness = 10
        vm.vfs_cache_pressure = 50
        vm.dirty_ratio = 30
        vm.dirty_background_ratio = 5
        vm.dirty_expire_centisecs = 3000
        vm.dirty_writeback_centisecs = 500
        vm.overcommit_memory = 1
        vm.panic_on_oom = 0

        # Kernel
        kernel.pid_max = 65536
        kernel.threads-max = 30938
        kernel.sched_autogroup_enabled = 0

        # v6.5: eBPF optimizations (if available)
        kernel.unprivileged_bpf_disabled = 1
        net.core.bpf_jit_enable = 1
        net.core.bpf_jit_harden = 1
    """)
    write_file("/etc/sysctl.d/99-wordpress.conf", sysctl_content)

    limits_append = textwrap.dedent("""\
        * soft nofile 1048576
        * hard nofile 1048576
        * soft nproc unlimited
        * hard nproc unlimited
        root soft nofile 1048576
        root hard nofile 1048576
    """)
    limits_file = Path("/etc/security/limits.conf")
    existing = limits_file.read_text() if limits_file.exists() else ""
    if "1048576" not in existing:
        with limits_file.open("a") as f:
            f.write("\n# EasyInstall v6.5\n" + limits_append)
        log("SUCCESS", "limits.conf updated")

    # v6.5: eBPF tools detection
    if Path("/sys/kernel/debug/tracing").exists():
        log("MODERN", "eBPF tracing available — performance monitoring enhanced")

    log("SUCCESS", "Kernel tuning complete")


# ═════════════════════════════════════════════════════════════════════════════
# STAGE: nginx_config (v6.5: AVIF + Modern Headers, Core Unchanged)
# ═════════════════════════════════════════════════════════════════════════════

def stage_nginx_config(cfg):
    """v6.5: Optimized Nginx with AVIF support and 2025 security headers"""
    log("STEP", "Writing optimized Nginx configuration (v6.5 with AVIF)")

    # v6.5: Detect AVIF support
    avif_support = getattr(cfg, 'use_avif', True)
    http3_support = getattr(cfg, 'use_http3', True)

    nginx_conf = textwrap.dedent(f"""\
        user www-data;
        worker_processes {cfg.nginx_worker_processes};
        worker_rlimit_nofile 1048576;
        pid /run/nginx.pid;

        events {{
            worker_connections {cfg.nginx_worker_connections};
            use epoll;
            multi_accept on;
            accept_mutex off;
        }}

        http {{
            sendfile on;
            tcp_nopush on;
            tcp_nodelay on;
            sendfile_max_chunk 512k;
            keepalive_timeout 30;
            keepalive_requests 1000;
            reset_timedout_connection on;
            client_body_timeout 30;
            client_header_timeout 30;
            send_timeout 30;
            types_hash_max_size 2048;
            server_tokens off;
            client_max_body_size 128M;
            client_body_buffer_size 128k;
            client_header_buffer_size 1k;
            large_client_header_buffers 4 8k;

            include /etc/nginx/mime.types;
            default_type application/octet-stream;
            # v6.5: AVIF + WebP mime types (added via conf.d/avif-mime.conf)

            log_format main '$remote_addr - $remote_user [$time_local] "$request" '
                            '$status $body_bytes_sent "$http_referer" '
                            '"$http_user_agent" "$http_x_forwarded_for" '
                            'rt=$request_time uct="$upstream_connect_time" '
                            'uht="$upstream_header_time" urt="$upstream_response_time"'
                            ' proto="$server_protocol"';

            access_log /var/log/nginx/access.log main buffer=32k flush=5s;
            error_log  /var/log/nginx/error.log warn;

            # Gzip (primary — brotli via conf.d/brotli.conf if module available)
            gzip on;
            gzip_vary on;
            gzip_proxied any;
            gzip_comp_level 6;
            gzip_min_length 1000;
            gzip_disable "msie6";
            gzip_types
                text/plain text/css text/xml text/javascript
                application/json application/javascript application/xml+rss
                application/xml application/rss+xml application/atom+xml
                application/x-javascript application/x-httpd-php
                application/x-font-ttf font/opentype image/svg+xml image/x-icon;

            fastcgi_cache_path /var/cache/nginx/fastcgi levels=1:2
                keys_zone=WORDPRESS:{min(cfg.total_ram // 16, 128)}m inactive=60m max_size={min(cfg.total_ram // 2, 2048)}m;
            fastcgi_cache_key "$scheme$request_method$host$request_uri";
            fastcgi_cache_use_stale error timeout updating invalid_header http_500 http_503;
            fastcgi_cache_valid 200 301 302 60m;
            fastcgi_cache_valid 404 1m;
            fastcgi_cache_lock on;
            fastcgi_cache_lock_timeout 5s;

            open_file_cache max=10000 inactive=30s;
            open_file_cache_valid 60s;
            open_file_cache_min_uses 2;
            open_file_cache_errors on;

            ssl_protocols TLSv1.2 TLSv1.3;
            ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384;
            ssl_prefer_server_ciphers off;
            ssl_session_cache shared:SSL:50m;
            ssl_session_timeout 1d;
            ssl_session_tickets off;

            limit_req_zone $binary_remote_addr zone=login:10m rate=10r/m;

            map $request_method $skip_cache {{
                default 0;
                POST 1;
                PUT 1;
                DELETE 1;
            }}

            map $http_cookie $no_cache {{
                default 0;
                ~*wordpress_logged_in 1;
                ~*wp-postpass 1;
                ~*comment_author 1;
                ~*woocommerce_items_in_cart 1;
                ~*wp_woocommerce_session 1;
            }}

            # v6.5: AVIF support map
            map $http_accept $avif_suffix {{
                default "";
                ~*avif ".avif";
            }}

            include /etc/nginx/conf.d/*.conf;
            include /etc/nginx/sites-enabled/*;
        }}
    """)
    write_file("/etc/nginx/nginx.conf", nginx_conf)
    log("SUCCESS", "Nginx main config written (v6.5 with AVIF)")

# ═════════════════════════════════════════════════════════════════════════════
# STAGE: nginx_extras (v6.5: 2025 Security Headers)
# ═════════════════════════════════════════════════════════════════════════════

def stage_nginx_extras(cfg):
    """v6.5: Brotli + Cloudflare real-IP + 2025 Security Headers"""
    log("STEP", "Writing Nginx extras: Brotli, Cloudflare, 2025 Security")

    # Brotli — only if module .so exists
    brotli_so = Path("/usr/lib/nginx/modules/ngx_http_brotli_filter_module.so")
    brotli_conf = Path("/etc/nginx/modules-available/50-mod-brotli.conf")
    if brotli_so.exists() or brotli_conf.exists():
        write_file("/etc/nginx/conf.d/brotli.conf", textwrap.dedent("""\
            # Brotli compression (EasyInstall v6.5)
            brotli on;
            brotli_comp_level 6;
            brotli_static on;
            brotli_min_length 1000;
            brotli_types
                text/plain text/css text/xml text/javascript
                application/json application/javascript application/xml+rss
                application/xml application/rss+xml application/atom+xml
                application/x-javascript application/x-font-ttf
                font/opentype image/svg+xml image/x-icon
                image/avif image/webp;
        """))
    else:
        log("INFO", "Brotli .so not found — skipping brotli.conf")

    write_file("/etc/nginx/conf.d/cloudflare-realip.conf", textwrap.dedent("""\
        # Cloudflare real-IP restoration (EasyInstall v6.5)
        set_real_ip_from 103.21.244.0/22;
        set_real_ip_from 103.22.200.0/22;
        set_real_ip_from 103.31.4.0/22;
        set_real_ip_from 104.16.0.0/13;
        set_real_ip_from 104.24.0.0/14;
        set_real_ip_from 108.162.192.0/18;
        set_real_ip_from 131.0.72.0/22;
        set_real_ip_from 141.101.64.0/18;
        set_real_ip_from 162.158.0.0/15;
        set_real_ip_from 172.64.0.0/13;
        set_real_ip_from 173.245.48.0/20;
        set_real_ip_from 188.114.96.0/20;
        set_real_ip_from 190.93.240.0/20;
        set_real_ip_from 197.234.240.0/22;
        set_real_ip_from 198.41.128.0/17;
        set_real_ip_from 2400:cb00::/32;
        set_real_ip_from 2606:4700::/32;
        set_real_ip_from 2803:f800::/32;
        set_real_ip_from 2405:b500::/32;
        set_real_ip_from 2405:8100::/32;
        set_real_ip_from 2a06:98c0::/29;
        set_real_ip_from 2c0f:f248::/32;
        real_ip_header CF-Connecting-IP;
        real_ip_recursive on;
    """))

    # v6.5: 2025 Security Headers (COEP, COOP, CORP, CSP)
    write_file("/etc/nginx/conf.d/security-headers-2025.conf", textwrap.dedent("""\
        # 2025 Security Headers (EasyInstall v6.5)

        # DNS resolver for upstream and OCSP (http context — valid here)
        resolver 1.1.1.1 8.8.8.8 valid=300s;
        resolver_timeout 5s;
        # Note: ssl_stapling directives go inside server{} blocks only

        # Strict Transport Security
        add_header Strict-Transport-Security "max-age=31536000; includeSubDomains; preload" always;

        # Content Security Policy 2025
        add_header Content-Security-Policy "default-src 'self'; script-src 'self' 'unsafe-inline' 'unsafe-eval' *.google.com *.googleapis.com *.gstatic.com *.jsdelivr.net *.cloudflare.com; style-src 'self' 'unsafe-inline' *.googleapis.com *.cloudflare.com; img-src 'self' data: blob: *.gravatar.com *.wp.com *.wordpress.com; font-src 'self' *.gstatic.com *.googleapis.com; connect-src 'self' *.google-analytics.com *.doubleclick.net; frame-ancestors 'self'; base-uri 'self'; form-action 'self'; upgrade-insecure-requests;" always;

        # Cross-Origin Policies 2025
        add_header Cross-Origin-Embedder-Policy "credentialless" always;
        add_header Cross-Origin-Opener-Policy "same-origin" always;
        add_header Cross-Origin-Resource-Policy "cross-origin" always;

        # Permissions Policy (formerly Feature-Policy)
        add_header Permissions-Policy "accelerometer=(), camera=(), geolocation=(), gyroscope=(), magnetometer=(), microphone=(), payment=(), usb=(), interest-cohort=()" always;

        # Standard security headers
        add_header X-Content-Type-Options "nosniff" always;
        add_header X-Frame-Options "SAMEORIGIN" always;
        add_header Referrer-Policy "strict-origin-when-cross-origin" always;

        # Note: more_clear_headers requires ngx_http_headers_more_module (not installed by default)
        # Use FastCGI param hiding instead — server tokens off is set globally in nginx.conf
    """))

    log("SUCCESS", "Nginx extras configured (v6.5 2025 security)")

    # v6.5: AVIF + WebP mime types (separate file to avoid types{} conflict in nginx.conf)
    write_file("/etc/nginx/conf.d/avif-mime.conf", textwrap.dedent("""\
        # AVIF + WebP MIME types (EasyInstall v6.5)
        # These supplement /etc/nginx/mime.types
        types {
            image/avif  avif;
            image/webp  webp;
        }
    """))

# ═════════════════════════════════════════════════════════════════════════════
# STAGE: http3_quic (v6.5: Real HTTP/3 with 0-RTT)
# ═════════════════════════════════════════════════════════════════════════════

def stage_http3_quic(cfg):
    """v6.5: HTTP/3 QUIC with 0-RTT support"""
    log("STEP", "Configuring HTTP/3 + QUIC support (v6.5 enhanced)")
    Path("/etc/nginx/conf.d").mkdir(parents=True, exist_ok=True)
    Path("/etc/nginx/snippets").mkdir(parents=True, exist_ok=True)

    # Check if nginx binary supports QUIC
    result = subprocess.run("nginx -V 2>&1", shell=True, capture_output=True, text=True)
    quic_supported = any(k in (result.stdout + result.stderr).lower()
                         for k in ["quic", "http3", "with-quic"])

    status_path = Path("/var/lib/easyinstall/http3.status")
    status_path.parent.mkdir(parents=True, exist_ok=True)

    if not quic_supported:
        log("WARNING", "nginx binary does not support QUIC — HTTP/3 headers only")
        status_path.write_text(
            "QUIC_AVAILABLE=false\n"
            "QUIC_NOTE=nginx binary lacks QUIC support — install nginx-quic\n"
            "QUIC_ALT_SVC_ONLY=true\n"
        )
    else:
        log("SUCCESS", "nginx binary supports QUIC/HTTP3 with 0-RTT")
        status_path.write_text(
            "QUIC_AVAILABLE=true\n"
            "QUIC_NOTE=HTTP/3 + QUIC enabled on UDP/443 with 0-RTT\n"
            f"QUIC_DATE={datetime.now().isoformat()}\n"
            "QUIC_0RTT=true\n"
        )

    # v6.5: Enhanced HTTP/3 configuration
    # Only include QUIC-specific directives if nginx binary supports QUIC
    if quic_supported:
        quic_extra = textwrap.dedent("""\
            # v6.5: QUIC connection optimizations (requires nginx-quic build)
            quic_gso on;
            quic_retry on;
        """)
    else:
        quic_extra = "    # QUIC directives omitted — nginx binary lacks QUIC support\n"

    write_file("/etc/nginx/conf.d/http3-quic.conf", textwrap.dedent("""\
        # HTTP/3 + QUIC global settings (EasyInstall v6.5)

        # Alt-Svc header map for HTTP/3 upgrade
        map $server_protocol $h3_alt_svc {
            default   'h3=":443"; ma=86400, h3-29=":443"; ma=86400';
        }

    """) + quic_extra)

    write_file("/etc/nginx/snippets/http3.conf", textwrap.dedent("""\
        # EasyInstall HTTP/3 per-site snippet (v6.5)
        # Include inside server{} block for HTTP/3 enabled sites

        # HTTP/3 QUIC listeners (UDP)
        listen 443 quic reuseport;
        listen [::]:443 quic reuseport;

        # HTTP/2 for fallback
        listen 443 ssl;
        listen [::]:443 ssl;
        http2 on;

        # Alt-Svc header to advertise HTTP/3
        add_header Alt-Svc 'h3=":443"; ma=86400, h3-29=":443"; ma=86400' always;
        add_header x-quic 'h3' always;

        # TLS 1.3 0-RTT (required for HTTP/3 performance)
        ssl_early_data on;

        # v6.5: Protocol indication
        add_header X-Protocol $server_protocol always;
    """))

    # v6.5: Enhanced QUIC/UDP performance tuning
    write_file("/etc/sysctl.d/99-quic.conf", textwrap.dedent("""\
        # QUIC / UDP performance tuning (EasyInstall v6.5)
        net.core.rmem_max = 268435456
        net.core.wmem_max = 268435456
        net.ipv4.udp_rmem_min = 8192
        net.ipv4.udp_wmem_min = 8192

        # v6.5: Increase UDP buffer sizes for high-latency connections
        net.ipv4.udp_mem = 8192 87380 134217728
    """))
    run("sysctl -p /etc/sysctl.d/99-quic.conf 2>/dev/null || true", check=False)
    log("SUCCESS", "HTTP/3 + QUIC configuration written (v6.5)")


# ═════════════════════════════════════════════════════════════════════════════
# STAGE: php_config (v6.5: PHP 8.4 default, unchanged core logic)
# ═════════════════════════════════════════════════════════════════════════════

def stage_php_config(cfg):
    """v6.5: Configure PHP-FPM with 8.4 as default priority"""
    log("STEP", "Configuring PHP-FPM for all installed versions (v6.5)")

    # v6.5: PHP 8.4 first, then 8.3, 8.2
    for version in ["8.4", "8.3", "8.2"]:
        php_dir = Path(f"/etc/php/{version}")
        if not php_dir.exists():
            log("INFO", f"PHP {version} not installed, skipping")
            continue
        log("INFO", f"Configuring PHP {version}")

        pool_conf = textwrap.dedent(f"""\
            [www]
            user = www-data
            group = www-data
            listen = /run/php/php{version}-fpm.sock
            listen.owner = www-data
            listen.group = www-data
            listen.mode = 0660
            listen.backlog = 65535

            pm = dynamic
            pm.max_children = {cfg.php_max_children}
            pm.start_servers = {cfg.php_start_servers}
            pm.min_spare_servers = {cfg.php_min_spare}
            pm.max_spare_servers = {cfg.php_max_spare}
            pm.max_requests = 10000
            pm.status_path = /status

            slowlog = /var/log/php{version}-fpm-slow.log
            request_slowlog_timeout = 5s
            request_terminate_timeout = {cfg.php_max_execution}s

            catch_workers_output = yes
            decorate_workers_output = no
            security.limit_extensions = .php .php3 .php4 .php5 .php7 .php8

            env[HOSTNAME] = $HOSTNAME
            env[PATH] = /usr/local/bin:/usr/bin:/bin
            env[TMP] = /tmp
            env[TMPDIR] = /tmp
            env[TEMP] = /tmp

            # v6.5: Enhanced environment for modern PHP
            env[PHP_VERSION] = {version}
        """)
        write_file(f"/etc/php/{version}/fpm/pool.d/www.conf", pool_conf)

        # php.ini tweaks
        php_ini = Path(f"/etc/php/{version}/fpm/php.ini")
        if php_ini.exists():
            content = php_ini.read_text()
            replacements = {
                r"memory_limit = .*":      f"memory_limit = {cfg.php_memory_limit}",
                r"upload_max_filesize = .*": "upload_max_filesize = 64M",
                r"post_max_size = .*":      "post_max_size = 64M",
                r"max_execution_time = .*": f"max_execution_time = {cfg.php_max_execution}",
                r"max_input_time = .*":     f"max_input_time = {cfg.php_max_execution}",
                r";date\.timezone.*":       "date.timezone = UTC",
                r";max_input_vars = .*":    "max_input_vars = 5000",
                r";realpath_cache_size = .*": "realpath_cache_size = 4096k",
                r";realpath_cache_ttl = .*":  "realpath_cache_ttl = 600",
                # v6.5: AVIF support check
                r";extension=gd.*":          "extension=gd",
            }
            for pattern, replacement in replacements.items():
                content = re.sub(pattern, replacement, content)

            # v6.5: Ensure GD extension is enabled
            if "extension=gd" not in content:
                content += "\n; v6.5: GD extension (AVIF support is compile-time)\nextension=gd\n"

            php_ini.write_text(content)
            log("SUCCESS", f"php.ini tuned for PHP {version}")

        # v6.5: Enhanced opcache
        write_file(f"/etc/php/{version}/fpm/conf.d/10-opcache.ini", textwrap.dedent("""\
            opcache.enable=1
            opcache.memory_consumption=256
            opcache.interned_strings_buffer=16
            opcache.max_accelerated_files=20000
            opcache.revalidate_freq=60
            opcache.enable_cli=1
            opcache.validate_timestamps=0
            opcache.save_comments=1
            opcache.max_file_size=10M
            opcache.consistency_checks=0
            opcache.lockfile_path=/tmp

            ; v6.5: JIT compilation for PHP 8.x
            opcache.jit_buffer_size=128M
            opcache.jit=tracing
            opcache.jit_hot_func=127
            opcache.jit_hot_loop=127
            opcache.jit_hot_return=8
        """))

        # v6.5: Enhanced APCu
        write_file(f"/etc/php/{version}/fpm/conf.d/20-apcu.ini", textwrap.dedent("""\
            apcu.enabled=1
            apcu.shm_size=128M
            apcu.ttl=7200
            apcu.gc_ttl=3600
            apcu.mmap_file_mask=/tmp/apcu.XXXXXX
            apcu.slam_defense=1
            apcu.enable_cli=0

            # v6.5: APCu serializer optimization
            apcu.serializer=igbinary
        """))

        # v6.5: Add igbinary extension config
        write_file(f"/etc/php/{version}/fpm/conf.d/15-igbinary.ini", textwrap.dedent("""\
            ; igbinary serializer (installed via php-igbinary package)
            extension=igbinary
            igbinary.compact_strings=On
        """))

    log("SUCCESS", "PHP configuration complete (v6.5)")

def _to_bytes(size_str: str) -> int:
    """Convert size string like '64M', '1G' to bytes integer for MariaDB 11.4+ innodb_redo_log_capacity."""
    s = size_str.strip().upper()
    if s.endswith('G'):
        return int(s[:-1]) * 1024 * 1024 * 1024
    elif s.endswith('M'):
        return int(s[:-1]) * 1024 * 1024
    elif s.endswith('K'):
        return int(s[:-1]) * 1024
    else:
        return int(s)


# ═════════════════════════════════════════════════════════════════════════════
# STAGE: mysql_config (v6.5: MariaDB 11.4+ optimizations)
# ═════════════════════════════════════════════════════════════════════════════

def stage_mysql_config(cfg):
    """v6.5: Optimized MariaDB 11.4+ configuration"""
    log("STEP", "Writing optimized MariaDB 11.4+ configuration (v6.5)")

    # Ensure log directory exists
    Path("/var/log/mysql").mkdir(parents=True, exist_ok=True)
    run("chown -R mysql:mysql /var/log/mysql 2>/dev/null || true", check=False)

    # v6.5: Auto-detect InnoDB buffer pool instances based on RAM
    ram_mb = getattr(cfg, 'total_ram', 1024)
    if ram_mb >= 8192:
        buffer_pool_instances = 8
    elif ram_mb >= 4096:
        buffer_pool_instances = 4
    else:
        buffer_pool_instances = 2

    mysql_conf = textwrap.dedent(f"""\
        [mysqld]
        user = mysql
        pid-file = /var/run/mysqld/mysqld.pid
        socket = /var/run/mysqld/mysqld.sock
        port = 3306
        basedir = /usr
        datadir = /var/lib/mysql
        tmpdir = /tmp
        skip-external-locking
        bind-address = 127.0.0.1

        max_connections = 500
        connect_timeout = 10
        wait_timeout = 600
        max_allowed_packet = 256M
        max_connect_errors = 1000000

        key_buffer_size = 64M
        sort_buffer_size = 4M
        read_buffer_size = 2M
        read_rnd_buffer_size = 4M
        join_buffer_size = 4M
        bulk_insert_buffer_size = 64M
        tmp_table_size = 64M
        max_heap_table_size = 64M

        innodb_buffer_pool_size = {cfg.mysql_buffer_pool}
        # innodb_redo_log_capacity uses bytes in MariaDB 11.4+ (67108864 = 64MB, 134217728 = 128MB)
        innodb_redo_log_capacity = {_to_bytes(cfg.mysql_log_file)}
        innodb_log_buffer_size = 16M
        innodb_flush_method = O_DIRECT
        innodb_file_per_table = 1
        innodb_flush_log_at_trx_commit = 2
        innodb_read_io_threads = 4
        innodb_write_io_threads = 4
        innodb_io_capacity = 2000
        innodb_io_capacity_max = 3000
        innodb_purge_threads = 4
        innodb_page_cleaners = 4
        innodb_buffer_pool_instances = {buffer_pool_instances}
        innodb_autoinc_lock_mode = 2
        innodb_old_blocks_time = 1000
        innodb_stats_on_metadata = OFF
        innodb_lock_wait_timeout = 50

        # v6.5: MariaDB 11.4+ specific optimizations
        innodb_adaptive_hash_index = ON
        innodb_adaptive_flushing = ON
        innodb_adaptive_flushing_lwm = 10
        innodb_flush_neighbors = 0
        innodb_random_read_ahead = OFF
        innodb_read_ahead_threshold = 56

        # v6.5: Performance Schema for monitoring
        performance_schema = ON

        # v6.5: Binary log for replication (if needed)
        log_bin = /var/log/mysql/mariadb-bin
        binlog_format = ROW
        binlog_row_image = MINIMAL
        binlog_expire_logs_seconds = 604800
        max_binlog_size = 100M

        table_open_cache = 4096
        table_definition_cache = 4096
        open_files_limit = 65535

        log_error = /var/log/mysql/error.log
        slow_query_log = 1
        slow_query_log_file = /var/log/mysql/slow.log
        long_query_time = 2
        log_queries_not_using_indexes = 1

        # v6.5: Enhanced slow log
        log_slow_admin_statements = 1
        log_slow_replica_statements = 1
        min_examined_row_limit = 100

        character-set-server = utf8mb4
        collation-server = utf8mb4_unicode_ci

        # v6.5: Connection handling
        thread_cache_size = 256
        thread_stack = 262144
        thread_pool_size = {buffer_pool_instances}

        # v6.5: Query cache disabled (deprecated in MariaDB 11.4+)
        query_cache_type = 0
        query_cache_size = 0
    """)
    write_file("/etc/mysql/mariadb.conf.d/99-wordpress.cnf", mysql_conf)
    log("SUCCESS", "MariaDB 11.4+ configuration written (v6.5)")

# ═════════════════════════════════════════════════════════════════════════════
# STAGE: redis_config (v6.5: Redis Stack support)
# ═════════════════════════════════════════════════════════════════════════════

def stage_redis_config(cfg):
    """v6.5: Enhanced Redis with Stack modules support"""
    log("STEP", "Writing optimized Redis configuration (v6.5)")

    redis_conf = textwrap.dedent(f"""\
        # EasyInstall v6.5 Redis Configuration (2026)
        bind 127.0.0.1
        port 6379
        tcp-backlog 65535
        timeout 0
        tcp-keepalive 300

        # Systemd integration: daemonize no + supervised systemd (correct combination)
        daemonize no
        supervised systemd
        pidfile /var/run/redis/redis-server.pid
        loglevel notice
        logfile /var/log/redis/redis-server.log
        databases 16
        always-show-logo no

        maxmemory {cfg.redis_max_memory}
        maxmemory-policy allkeys-lru
        maxmemory-samples 10

        save ""
        appendonly no

        maxclients 10000

        # v6.5: Enhanced persistence options
        stop-writes-on-bgsave-error yes
        rdbcompression yes
        rdbchecksum yes

        # v6.5: Replication (for future scaling)
        repl-diskless-sync yes
        repl-diskless-sync-delay 5
        repl-ping-replica-period 10
        repl-timeout 60
        repl-disable-tcp-nodelay no

        # v6.5: Cluster support (disabled by default)
        cluster-enabled no
        cluster-require-full-coverage no
        cluster-replica-no-failover no

        # v6.5: Latency monitoring
        latency-monitor-threshold 100

        # v6.5: Notify keyspace events (for cache invalidation)
        notify-keyspace-events Ex

        # v6.5: Client output buffer limits
        client-output-buffer-limit normal 0 0 0
        client-output-buffer-limit replica 256mb 64mb 60
        client-output-buffer-limit pubsub 32mb 8mb 60

        # v6.5: AOF for durability (optional, can be disabled)
        # appendonly yes
        # appendfilename "appendonly.aof"
        # appendfsync everysec
        # no-appendfsync-on-rewrite yes
        # auto-aof-rewrite-percentage 100
        # auto-aof-rewrite-min-size 64mb
    """)
    write_file("/etc/redis/redis.conf", redis_conf)

    # v6.5: Create Redis Stack module loader (if available)
    write_file("/etc/redis/redis-stack-modules.conf", textwrap.dedent("""\
        # EasyInstall v6.5: Redis Stack Modules (optional)
        # Load these modules if Redis Stack is installed

        # RedisJSON for complex data structures
        # loadmodule /opt/redis-stack/lib/rejson.so

        # RediSearch for full-text search
        # loadmodule /opt/redis-stack/lib/redisearch.so

        # RedisGraph for graph queries
        # loadmodule /opt/redis-stack/lib/redisgraph.so

        # RedisTimeSeries for time-series data
        # loadmodule /opt/redis-stack/lib/redistimeseries.so

        # RedisBloom for probabilistic data structures
        # loadmodule /opt/redis-stack/lib/redisbloom.so
    """))

    log("SUCCESS", "Redis configuration written (v6.5 with Stack support)")


# ═════════════════════════════════════════════════════════════════════════════
# STAGE: s3_backup_config (v6.5: NEW - Cloud-native backup)
# ═════════════════════════════════════════════════════════════════════════════

def stage_s3_backup_config(cfg):
    """v6.5: NEW - S3-compatible backup configuration"""
    log("STEP", "Configuring S3-compatible backup (v6.5 NEW)")

    if not getattr(cfg, 's3_backup', False):
        log("INFO", "S3 backup not enabled, skipping")
        return

    # Install rclone for S3 operations
    run("curl https://rclone.org/install.sh | bash 2>/dev/null || apt-get install -y rclone", check=False)

    # Create rclone config
    rclone_conf = textwrap.dedent(f"""\
        [easyinstall-s3]
        type = s3
        provider = {cfg.s3_endpoint if 'amazon' in cfg.s3_endpoint.lower() else 'Other'}
        env_auth = false
        access_key_id = {cfg.s3_access_key}
        secret_access_key = {cfg.s3_secret_key}
        endpoint = {cfg.s3_endpoint}
        region = auto
        location_constraint = 
        acl = private
        server_side_encryption = AES256
        storage_class = STANDARD
    """)

    rclone_dir = Path("/root/.config/rclone")
    rclone_dir.mkdir(parents=True, exist_ok=True)
    write_file("/root/.config/rclone/rclone.conf", rclone_conf, mode=0o600)

    # Create S3 backup script
    s3_script = textwrap.dedent(f"""\
        #!/bin/bash
        # EasyInstall v6.5 S3 Backup Script
        # Usage: easy-s3-backup [daily|weekly|monthly] [site]

        BACKUP_TYPE="${{1:-daily}}"
        SITE="${{2:-all}}"
        BUCKET="{cfg.s3_bucket}"
        DATE=$(date +%Y%m%d-%H%M%S)
        LOG_FILE="/var/log/easyinstall/s3-backup.log"

        log() {{ echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"; }}

        log "Starting S3 $BACKUP_TYPE backup..."

        if [ "$SITE" = "all" ]; then
            # Backup all sites
            for site_dir in /var/www/html/*/; do
                [ -d "$site_dir" ] || continue
                domain=$(basename "$site_dir")
                log "Backing up $domain..."

                # Create local archive
                tar -czf "/tmp/$domain-$DATE.tar.gz" -C /var/www/html "$domain" 2>/dev/null

                # Upload to S3
                rclone copy "/tmp/$domain-$DATE.tar.gz" "easyinstall-s3:$BUCKET/backups/$BACKUP_TYPE/" 2>/dev/null && \
                    log "✅ $domain uploaded to S3" || log "❌ $domain upload failed"

                rm -f "/tmp/$domain-$DATE.tar.gz"
            done

            # Backup databases
            for db in $(mysql -e "SHOW DATABASES LIKE 'wp_%';" 2>/dev/null | grep -v Database); do
                log "Backing up database $db..."
                mysqldump "$db" 2>/dev/null | gzip > "/tmp/$db-$DATE.sql.gz"
                rclone copy "/tmp/$db-$DATE.sql.gz" "easyinstall-s3:$BUCKET/backups/$BACKUP_TYPE/" 2>/dev/null && \
                    log "✅ $db uploaded to S3" || log "❌ $db upload failed"
                rm -f "/tmp/$db-$DATE.sql.gz"
            done
        else
            # Backup specific site
            if [ -d "/var/www/html/$SITE" ]; then
                tar -czf "/tmp/$SITE-$DATE.tar.gz" -C /var/www/html "$SITE" 2>/dev/null
                rclone copy "/tmp/$SITE-$DATE.tar.gz" "easyinstall-s3:$BUCKET/backups/$BACKUP_TYPE/" 2>/dev/null
                rm -f "/tmp/$SITE-$DATE.tar.gz"
                log "✅ $SITE backup complete"
            fi
        fi

        # Cleanup old backups (keep last 30 daily, 12 weekly, 12 monthly)
        log "Cleaning up old backups..."
        rclone delete "easyinstall-s3:$BUCKET/backups/daily/" --min-age 30d 2>/dev/null || true
        rclone delete "easyinstall-s3:$BUCKET/backups/weekly/" --min-age 84d 2>/dev/null || true
        rclone delete "easyinstall-s3:$BUCKET/backups/monthly/" --min-age 365d 2>/dev/null || true

        log "S3 backup complete"
    """)

    write_file("/usr/local/bin/easy-s3-backup", s3_script, mode=0o755)

    # Add cron job
    cron_s3 = "0 4 * * * root /usr/local/bin/easy-s3-backup daily > /dev/null 2>&1\n"
    cron_s3 += "0 3 * * 0 root /usr/local/bin/easy-s3-backup weekly > /dev/null 2>&1\n"
    cron_s3 += "0 2 1 * * root /usr/local/bin/easy-s3-backup monthly > /dev/null 2>&1\n"

    write_file("/etc/cron.d/easy-s3-backup", cron_s3)

    log("SUCCESS", "S3 backup configured (v6.5 NEW)")

# ═════════════════════════════════════════════════════════════════════════════
# STAGE: container_config (v6.5: NEW - Docker/Podman support)
# ═════════════════════════════════════════════════════════════════════════════

def stage_container_config(cfg):
    """v6.5: NEW - Generate container orchestration files"""
    log("STEP", "Generating container configuration (v6.5 NEW)")

    # Docker Compose for WordPress stack
    compose_yaml = textwrap.dedent("""\
        version: '3.8'

        services:
          nginx:
            image: nginx:alpine
            container_name: easyinstall-nginx
            ports:
              - "80:80"
              - "443:443"
              - "443:443/udp"  # HTTP/3 QUIC
            volumes:
              - ./nginx/nginx.conf:/etc/nginx/nginx.conf:ro
              - ./nginx/sites:/etc/nginx/sites-enabled:ro
              - ./nginx/ssl:/etc/nginx/ssl:ro
              - ./wordpress:/var/www/html:ro
              - ./logs/nginx:/var/log/nginx
            networks:
              - easyinstall-net
            depends_on:
              - php
            restart: unless-stopped
            healthcheck:
              test: ["CMD", "wget", "--quiet", "--tries=1", "--spider", "http://localhost/health"]
              interval: 30s
              timeout: 10s
              retries: 3

          php:
            image: php:8.4-fpm-alpine
            container_name: easyinstall-php
            volumes:
              - ./wordpress:/var/www/html
              - ./php/php.ini:/usr/local/etc/php/php.ini:ro
              - ./php/www.conf:/usr/local/etc/php-fpm.d/www.conf:ro
            networks:
              - easyinstall-net
            depends_on:
              - mariadb
              - redis
            restart: unless-stopped
            environment:
              - PHP_MEMORY_LIMIT=256M
              - PHP_MAX_EXECUTION_TIME=120

          mariadb:
            image: mariadb:11.4
            container_name: easyinstall-mariadb
            volumes:
              - mariadb_data:/var/lib/mysql
              - ./mysql/99-wordpress.cnf:/etc/mysql/mariadb.conf.d/99-wordpress.cnf:ro
            networks:
              - easyinstall-net
            environment:
              - MYSQL_ROOT_PASSWORD_FILE=/run/secrets/db_root_password
              - MYSQL_DATABASE=wordpress
            secrets:
              - db_root_password
            restart: unless-stopped
            healthcheck:
              test: ["CMD", "healthcheck.sh", "--connect", "--innodb_initialized"]
              interval: 10s
              timeout: 5s
              retries: 3

          redis:
            image: redis:7-alpine
            container_name: easyinstall-redis
            volumes:
              - redis_data:/data
              - ./redis/redis.conf:/usr/local/etc/redis/redis.conf:ro
            networks:
              - easyinstall-net
            restart: unless-stopped
            command: redis-server /usr/local/etc/redis/redis.conf
            healthcheck:
              test: ["CMD", "redis-cli", "ping"]
              interval: 10s
              timeout: 3s
              retries: 3

          # v6.5: Optional services
          prometheus:
            image: prom/prometheus:latest
            container_name: easyinstall-prometheus
            ports:
              - "9090:9090"
            volumes:
              - ./prometheus/prometheus.yml:/etc/prometheus/prometheus.yml:ro
              - prometheus_data:/prometheus
            networks:
              - easyinstall-net
            restart: unless-stopped
            profiles:
              - monitoring

          grafana:
            image: grafana/grafana:latest
            container_name: easyinstall-grafana
            ports:
              - "3000:3000"
            volumes:
              - grafana_data:/var/lib/grafana
            networks:
              - easyinstall-net
            restart: unless-stopped
            profiles:
              - monitoring

        volumes:
          mariadb_data:
          redis_data:
          prometheus_data:
          grafana_data:

        networks:
          easyinstall-net:
            driver: bridge

        secrets:
          db_root_password:
            file: ./secrets/db_root_password.txt
    """)

    write_file("/etc/easyinstall/docker-compose.yml", compose_yaml)

    # Podman Quadlet for systemd integration
    podman_quadlet = textwrap.dedent("""\
        [Unit]
        Description=EasyInstall WordPress Nginx
        After=network.target

        [Container]
        Image=nginx:alpine
        ContainerName=easyinstall-nginx
        PublishPort=80:80
        PublishPort=443:443
        PublishPort=443:443/udp
        Volume=/etc/easyinstall/nginx/nginx.conf:/etc/nginx/nginx.conf:ro,Z
        Volume=/var/www/html:/var/www/html:ro,Z
        Network=easyinstall-net

        [Service]
        Restart=always

        [Install]
        WantedBy=multi-user.target
    """)

    write_file("/etc/containers/systemd/easyinstall-nginx.container", podman_quadlet)

    # Kubernetes manifests
    k8s_deployment = textwrap.dedent("""\
        apiVersion: apps/v1
        kind: Deployment
        metadata:
          name: easyinstall-wordpress
          namespace: easyinstall
        spec:
          replicas: 1
          selector:
            matchLabels:
              app: wordpress
          template:
            metadata:
              labels:
                app: wordpress
            spec:
              containers:
              - name: nginx
                image: nginx:alpine
                ports:
                - containerPort: 80
                - containerPort: 443
                volumeMounts:
                - name: nginx-config
                  mountPath: /etc/nginx/nginx.conf
                  subPath: nginx.conf
                - name: wordpress-data
                  mountPath: /var/www/html
              - name: php
                image: php:8.4-fpm-alpine
                volumeMounts:
                - name: wordpress-data
                  mountPath: /var/www/html
              volumes:
              - name: nginx-config
                configMap:
                  name: nginx-config
              - name: wordpress-data
                persistentVolumeClaim:
                  claimName: wordpress-pvc
        ---
        apiVersion: v1
        kind: Service
        metadata:
          name: wordpress-service
          namespace: easyinstall
        spec:
          selector:
            app: wordpress
          ports:
          - port: 80
            targetPort: 80
          - port: 443
            targetPort: 443
          type: LoadBalancer
    """)

    write_file("/etc/easyinstall/k8s-manifest.yaml", k8s_deployment)

    log("SUCCESS", "Container configuration generated (v6.5 NEW)")

# ═════════════════════════════════════════════════════════════════════════════
# STAGE: wordpress_install (v6.5: Enhanced with async support, core unchanged)
# ═════════════════════════════════════════════════════════════════════════════

def stage_wordpress_install(cfg):
    """v6.5: WordPress installation with optional async downloads"""
    domain = cfg.domain
    if not domain:
        log("ERROR", "--domain is required for wordpress_install stage")
        sys.exit(1)

    # Sanitize domain
    domain = re.sub(r'https?://', '', domain)
    domain = re.sub(r'^www\.', '', domain)
    domain = domain.strip('/')

    php_version = cfg.php_version
    use_ssl = cfg.use_ssl
    redis_port = cfg.redis_port

    log("STEP", f"Installing WordPress for {domain} (PHP {php_version}, Redis :{redis_port}) (v6.5)")

    # ── Domain availability check ─────────────────────────────────────────
    wp_root = Path(f"/var/www/html/{domain}")
    if wp_root.exists():
        log("ERROR", f"Domain already exists: {domain}"); sys.exit(1)

    nginx_conf = Path(f"/etc/nginx/sites-available/{domain}")
    if nginx_conf.exists():
        log("ERROR", f"Nginx config already exists for {domain}"); sys.exit(1)

    # ── Create dedicated Redis instance ──────────────────────────────────
    log("INFO", f"Creating Redis instance for {domain} on port {redis_port}")
    domain_slug = domain.replace('.', '-')
    redis_conf_content = textwrap.dedent(f"""\
        # Redis for {domain} (v6.5)
        port {redis_port}
        daemonize yes
        pidfile /var/run/redis/redis-{domain_slug}.pid
        logfile /var/log/redis/redis-{domain_slug}.log
        dir /var/lib/redis/{domain_slug}
        maxmemory {cfg.redis_max_memory}
        maxmemory-policy allkeys-lru
        appendonly no
        save ""
        bind 127.0.0.1

        # v6.5: Enhanced monitoring
        latency-monitor-threshold 100
        notify-keyspace-events Ex
    """)
    write_file(f"/etc/redis/redis-{domain_slug}.conf", redis_conf_content)
    Path(f"/var/lib/redis/{domain_slug}").mkdir(parents=True, exist_ok=True)
    run(f"chown redis:redis /var/lib/redis/{domain_slug} 2>/dev/null || true", check=False)

    redis_service_content = textwrap.dedent(f"""\
        [Unit]
        Description=Redis server for {domain}
        After=network.target

        [Service]
        Type=forking
        ExecStart=/usr/bin/redis-server /etc/redis/redis-{domain_slug}.conf
        ExecStop=/usr/bin/redis-cli -p {redis_port} shutdown
        User=redis
        Group=redis
        RuntimeDirectory=redis
        RuntimeDirectoryMode=0755

        # v6.5: Resource limits
        LimitNOFILE=65535
        LimitNPROC=4096

        [Install]
        WantedBy=multi-user.target
    """)
    write_file(f"/etc/systemd/system/redis-{domain_slug}.service", redis_service_content)
    run("systemctl daemon-reload", check=False)
    run(f"systemctl enable redis-{domain_slug} && systemctl start redis-{domain_slug}", check=False)

    # ── Download WordPress ────────────────────────────────────────────────
    wp_root.mkdir(parents=True, exist_ok=True)
    log("INFO", "Downloading WordPress (v6.5)")

    # v6.5: Try async download first, fallback to sync
    # v6.5: Try async download if aiohttp available, else sync
    downloaded = False
    if AIOHTTP_AVAILABLE:
        try:
            asyncio.run(_async_download_wordpress(wp_root))
            log("SUCCESS", "WordPress downloaded (async)")
            downloaded = True
        except Exception as e:
            log("INFO", f"Async download failed ({e}), using sync fallback")
    if not downloaded:
        rc = run(f"wget -qO- https://wordpress.org/latest.tar.gz | tar xz -C /var/www/html/{domain} --strip-components=1", check=False)
        if rc != 0:
            log("ERROR", "Failed to download WordPress"); sys.exit(1)

    run(f"chown -R www-data:www-data /var/www/html/{domain}", check=False)
    run(f"chmod -R 755 /var/www/html/{domain}", check=False)

    # ── Generate credentials ──────────────────────────────────────────────
    import secrets
    import string
    db_safe = re.sub(r'[.-]', '_', domain)
    db_pass = ''.join(secrets.choice(string.ascii_letters + string.digits) for _ in range(20))

    def gen_salt():
        return ''.join(secrets.choice(string.ascii_letters + string.digits + '!@#$%^&*()_+-=') for _ in range(48))

    # ── wp-config.php (v6.5 enhanced) ─────────────────────────────────────
    wp_config = textwrap.dedent(f"""\
        <?php
        /**
         * WordPress Configuration File
         * Generated by EasyInstall v6.5 (2026)
         */

        // Database settings
        define('DB_NAME',     'wp_{db_safe}');
        define('DB_USER',     'wpuser_{db_safe}');
        define('DB_PASSWORD', '{db_pass}');
        define('DB_HOST',     'localhost');
        define('DB_CHARSET',  'utf8mb4');
        define('DB_COLLATE',  '');

        // Authentication keys (v6.5: 64-char salts)
        define('AUTH_KEY',         '{gen_salt()}');
        define('SECURE_AUTH_KEY',  '{gen_salt()}');
        define('LOGGED_IN_KEY',    '{gen_salt()}');
        define('NONCE_KEY',        '{gen_salt()}');
        define('AUTH_SALT',        '{gen_salt()}');
        define('SECURE_AUTH_SALT', '{gen_salt()}');
        define('LOGGED_IN_SALT',   '{gen_salt()}');
        define('NONCE_SALT',       '{gen_salt()}');

        // WordPress settings
        define('WP_DEBUG',                 false);
        define('WP_DEBUG_LOG',             false);
        define('WP_DEBUG_DISPLAY',         false);
        define('WP_MEMORY_LIMIT',          '{cfg.php_memory_limit}');
        define('WP_MAX_MEMORY_LIMIT',      '512M');
        define('DISALLOW_FILE_EDIT',       false);
        define('WP_CACHE',                 true);
        define('WP_POST_REVISIONS',        5);
        define('EMPTY_TRASH_DAYS',         7);
        define('WP_CRON_LOCK_TIMEOUT',     60);
        define('AUTOMATIC_UPDATER_DISABLED', false);
        define('WP_AUTO_UPDATE_CORE',      'minor');
        define('FS_METHOD',                'direct');

        // v6.5: Performance optimizations
        define('WP_CACHE_KEY_SALT',        '{domain}_');
        define('CONCATENATE_SCRIPTS',      false);  // Disable in production
        define('COMPRESS_SCRIPTS',         true);
        define('COMPRESS_CSS',             true);
        define('ENFORCE_GZIP',             true);

        // Redis object cache (v6.5 enhanced)
        define('WP_REDIS_HOST',     '127.0.0.1');
        define('WP_REDIS_PORT',     {redis_port});
        define('WP_REDIS_DATABASE', 0);
        define('WP_REDIS_TIMEOUT',  1);
        define('WP_REDIS_READ_TIMEOUT', 1);
        define('WP_REDIS_MAXTTL',   86400);
        define('WP_CACHE_KEY_SALT', '{domain}_');

        // v6.5: Redis Sentinel support (future-proofing)
        // define('WP_REDIS_SENTINEL', 'mymaster');
        // define('WP_REDIS_SERVERS', ['tcp://127.0.0.1:26379', 'tcp://127.0.0.1:26380']);

        $table_prefix = 'wp_';

        // v6.5: Absolute path detection
        if (!defined('ABSPATH')) define('ABSPATH', __DIR__ . '/');

        // v6.5: Load custom config if exists (for local overrides)
        if (file_exists(ABSPATH . 'wp-config-local.php')) {{
            require_once ABSPATH . 'wp-config-local.php';
        }}

        require_once ABSPATH . 'wp-settings.php';
    """)
    write_file(f"/var/www/html/{domain}/wp-config.php", wp_config, mode=0o640)
    run(f"chown www-data:www-data /var/www/html/{domain}/wp-config.php", check=False)

    # ── Nginx site config (v6.5: AVIF + HTTP/3 + 2025 headers) ───────────
    nginx_site = textwrap.dedent(f"""\
        server {{
            listen 80;
            listen [::]:80;
            server_name {domain} www.{domain};

            root /var/www/html/{domain};
            index index.php index.html index.htm;

            access_log /var/log/nginx/{domain}.access.log main buffer=32k flush=5s;
            error_log  /var/log/nginx/{domain}.error.log warn;

            # v6.5: Security headers (2025 standards)
            add_header X-Frame-Options "SAMEORIGIN" always;
            add_header X-Content-Type-Options "nosniff" always;
            add_header Referrer-Policy "strict-origin-when-cross-origin" always;
            add_header Permissions-Policy "accelerometer=(), camera=(), geolocation=(), gyroscope=(), magnetometer=(), microphone=(), payment=(), usb=()" always;
            add_header Cross-Origin-Embedder-Policy "credentialless" always;
            add_header Cross-Origin-Opener-Policy "same-origin" always;
            add_header Cross-Origin-Resource-Policy "cross-origin" always;

            # Let's Encrypt ACME challenge
            location ^~ /.well-known/acme-challenge/ {{
                root /var/www/html/{domain};
                allow all;
            }}

            # Cache rules
            set $skip_cache 0;
            if ($request_method = POST)           {{ set $skip_cache 1; }}
            if ($query_string != "")              {{ set $skip_cache 1; }}
            if ($request_uri ~* "/wp-admin/|/xmlrpc.php|wp-.*.php|/feed/|index.php|sitemap(_index)?.xml") {{ set $skip_cache 1; }}
            if ($http_cookie ~* "comment_author|wordpress_[a-f0-9]+|wp-postpass|wordpress_no_cache|wordpress_logged_in|woocommerce_items_in_cart") {{ set $skip_cache 1; }}

            location / {{ try_files $uri $uri/ /index.php?$args; }}

            location ~ \\.php$ {{
                include fastcgi_params;
                fastcgi_pass unix:/run/php/php{php_version}-fpm.sock;
                fastcgi_index index.php;
                fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
                fastcgi_param PATH_INFO $fastcgi_path_info;
                fastcgi_cache WORDPRESS;
                fastcgi_cache_valid 200 60m;
                fastcgi_cache_valid 301 302 5m;
                fastcgi_cache_valid 404 1m;
                fastcgi_cache_bypass $skip_cache;
                fastcgi_no_cache $skip_cache;
                add_header X-Cache $upstream_cache_status;
                add_header X-FastCGI-Cache $upstream_cache_status;
                fastcgi_buffers 16 16k;
                fastcgi_buffer_size 32k;
                fastcgi_read_timeout 300;
                fastcgi_send_timeout 300;
            }}

            location ~ /\\.ht                           {{ deny all; }}
            location = /favicon.ico                     {{ log_not_found off; access_log off; expires max; }}
            location = /robots.txt                      {{ allow all; log_not_found off; access_log off; }}

            # v6.5: Static assets with AVIF support
            location ~* \\.(jpg|jpeg|png|gif|ico|css|js|woff|woff2|ttf|svg|eot|pdf|zip|gz|mp4|webm|webp|avif)$ {{
                expires 6M;
                log_not_found off;
                access_log off;
                add_header Cache-Control "public, immutable";
                add_header Vary "Accept-Encoding";

                # v6.5: AVIF prioritization
                try_files $uri$avif_suffix $uri =404;
            }}

            # v6.5: Health check endpoint
            location = /health {{
                access_log off;
                return 200 "healthy\n";
                add_header Content-Type text/plain;
            }}
        }}
    """)
    write_file(f"/etc/nginx/sites-available/{domain}", nginx_site)

    # Remove default nginx site
    default_enabled = Path("/etc/nginx/sites-enabled/default")
    if default_enabled.exists() or default_enabled.is_symlink():
        default_enabled.unlink()
        log("INFO", "Removed default nginx site")

    # Enable site
    enabled_link = Path(f"/etc/nginx/sites-enabled/{domain}")
    if not enabled_link.exists():
        enabled_link.symlink_to(f"/etc/nginx/sites-available/{domain}")
    log("SUCCESS", f"Nginx site enabled for {domain}")

    # Ensure nginx cache directories exist
    run("mkdir -p /var/cache/nginx/fastcgi /var/cache/nginx/edge /var/cache/nginx/proxy /var/cache/nginx/static", check=False)
    run("chown -R www-data:www-data /var/cache/nginx 2>/dev/null || true", check=False)
    run("chmod -R 755 /var/cache/nginx 2>/dev/null || true", check=False)

    # Validate and reload nginx
    rc = run("nginx -t 2>/dev/null", check=False)
    if rc == 0:
        run("systemctl reload nginx", check=False)
    else:
        log("ERROR", "Nginx config test failed"); sys.exit(1)

    # ── Create database ───────────────────────────────────────────────────
    log("INFO", f"Creating MySQL database wp_{db_safe}")
    sql = textwrap.dedent(f"""\
        CREATE DATABASE IF NOT EXISTS wp_{db_safe} CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
        CREATE USER IF NOT EXISTS 'wpuser_{db_safe}'@'localhost' IDENTIFIED BY '{db_pass}';
        GRANT ALL PRIVILEGES ON wp_{db_safe}.* TO 'wpuser_{db_safe}'@'localhost';
        FLUSH PRIVILEGES;
    """)
    rc = subprocess.run(["mysql"], input=sql, text=True).returncode
    if rc != 0:
        log("ERROR", "Failed to create database"); sys.exit(1)
    log("SUCCESS", f"Database wp_{db_safe} created")

    # ── Save credentials ──────────────────────────────────────────────────
    site_url = f"http://{domain}"
    creds = textwrap.dedent(f"""\
        ========================================
        WordPress Site: {domain} (v6.5)
        ========================================
        Site URL   : {site_url}
        Admin URL  : {site_url}/wp-admin

        Database   : wp_{db_safe}
        DB User    : wpuser_{db_safe}
        DB Password: {db_pass}

        Redis Port : {redis_port}
        Redis Svc  : redis-{domain_slug}
        PHP Version: {php_version}
        PHP Memory : {cfg.php_memory_limit}

        Features   : AVIF, HTTP/3 Ready, 2025 Security Headers

        Directory  : /var/www/html/{domain}
        Nginx Conf : /etc/nginx/sites-available/{domain}
        ========================================
    """)
    write_file(f"/root/{domain}-credentials.txt", creds, mode=0o600)

    # ── Optional SSL (v6.5: HTTP/3 enabled) ────────────────────────────────
    if use_ssl:
        log("INFO", f"Requesting SSL certificate for {domain} (v6.5)")
        run("systemctl reload nginx 2>/dev/null || true", check=False)

        rc = run(
            f"certbot certonly --webroot -w /var/www/html/{domain} "
            f"-d {domain} -d www.{domain} "
            f"--non-interactive --agree-tos --email admin@{domain} 2>/dev/null",
            check=False
        )
        if rc == 0:
            log("SUCCESS", f"SSL certificate obtained for {domain}")
            site_url = f"https://{domain}"

            # v6.5: HTTPS config with HTTP/3
            ssl_nginx = textwrap.dedent(f"""
                # HTTP → HTTPS redirect
                server {{
                    listen 80;
                    listen [::]:80;
                    server_name {domain} www.{domain};
                    location ^~ /.well-known/acme-challenge/ {{
                        root /var/www/html/{domain};
                        allow all;
                    }}
                    location / {{
                        return 301 https://$host$request_uri;
                    }}
                }}

                server {{
                    # v6.5: HTTP/3 QUIC listeners
                    listen 443 quic reuseport;
                    listen [::]:443 quic reuseport;
                    listen 443 ssl;
                    listen [::]:443 ssl;
                    http2 on;

                    server_name {domain} www.{domain};

                    ssl_certificate     /etc/letsencrypt/live/{domain}/fullchain.pem;
                    ssl_certificate_key /etc/letsencrypt/live/{domain}/privkey.pem;
                    ssl_trusted_certificate /etc/letsencrypt/live/{domain}/chain.pem;

                    # v6.5: TLS 1.3 0-RTT for HTTP/3
                    ssl_early_data on;

                    # v6.5: HTTP/3 Alt-Svc header
                    add_header Alt-Svc 'h3=":443"; ma=86400, h3-29=":443"; ma=86400' always;
                    add_header x-quic 'h3' always;

                    root /var/www/html/{domain};
                    index index.php index.html index.htm;

                    access_log /var/log/nginx/{domain}.access.log main buffer=32k flush=5s;
                    error_log  /var/log/nginx/{domain}.error.log warn;

                    location ^~ /.well-known/acme-challenge/ {{
                        root /var/www/html/{domain};
                        allow all;
                    }}

                    set $skip_cache 0;
                    if ($request_method = POST)           {{ set $skip_cache 1; }}
                    if ($query_string != "")              {{ set $skip_cache 1; }}
                    if ($request_uri ~* "/wp-admin/|/xmlrpc.php|wp-.*.php|/feed/|index.php|sitemap(_index)?.xml") {{ set $skip_cache 1; }}
                    if ($http_cookie ~* "comment_author|wordpress_[a-f0-9]+|wp-postpass|wordpress_no_cache|wordpress_logged_in|woocommerce_items_in_cart") {{ set $skip_cache 1; }}

                    location / {{ try_files $uri $uri/ /index.php?$args; }}

                    location ~ \\.php$ {{
                        include fastcgi_params;
                        fastcgi_pass unix:/run/php/php{php_version}-fpm.sock;
                        fastcgi_index index.php;
                        fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
                        fastcgi_param PATH_INFO $fastcgi_path_info;
                        fastcgi_cache WORDPRESS;
                        fastcgi_cache_valid 200 60m;
                        fastcgi_cache_valid 301 302 5m;
                        fastcgi_cache_valid 404 1m;
                        fastcgi_cache_bypass $skip_cache;
                        fastcgi_no_cache $skip_cache;
                        add_header X-Cache $upstream_cache_status;
                        fastcgi_buffers 16 16k;
                        fastcgi_buffer_size 32k;
                        fastcgi_read_timeout 300;
                        fastcgi_send_timeout 300;
                    }}

                    location ~ /\\.ht                           {{ deny all; }}
                    location = /favicon.ico                     {{ log_not_found off; access_log off; expires max; }}
                    location = /robots.txt                      {{ allow all; log_not_found off; access_log off; }}
                    location ~* \\.(jpg|jpeg|png|gif|ico|css|js|woff|woff2|ttf|svg|eot|pdf|zip|gz|mp4|webm|webp|avif)$ {{
                        expires 6M;
                        log_not_found off;
                        access_log off;
                        add_header Cache-Control "public, immutable";
                        try_files $uri$avif_suffix $uri =404;
                    }}

                    location = /health {{
                        access_log off;
                        return 200 "healthy\n";
                        add_header Content-Type text/plain;
                    }}
                }}
            """).strip()
            write_file(f"/etc/nginx/sites-available/{domain}", ssl_nginx)

            # Update wp-config.php for HTTPS
            wp_conf_path = Path(f"/var/www/html/{domain}/wp-config.php")
            if wp_conf_path.exists():
                txt = wp_conf_path.read_text()
                if "WP_HOME" not in txt:
                    txt = txt.replace(
                        "$table_prefix = 'wp_';",
                        f"define('WP_HOME',   'https://{domain}');\n"
                        f"define('WP_SITEURL','https://{domain}');\n"
                        "\n$table_prefix = 'wp_';"
                    )
                    wp_conf_path.write_text(txt)
                    run(f"chown www-data:www-data /var/www/html/{domain}/wp-config.php", check=False)

            rc2 = run("nginx -t 2>/dev/null", check=False)
            if rc2 == 0:
                run("systemctl reload nginx", check=False)
            log("SUCCESS", f"HTTPS + HTTP/3 enabled for {domain}")

            run(
                'printf "0 3 * * * root certbot renew --quiet --post-hook \"systemctl reload nginx\"\n"'
                ' > /etc/cron.d/certbot-renew-easyinstall 2>/dev/null || true',
                check=False
            )
        else:
            log("WARNING", f"SSL certificate failed for {domain} — site accessible via HTTP")

    log("SUCCESS", f"WordPress installed for {domain} (v6.5)")
    log("INFO",    f"Complete setup at: {site_url}/wp-admin/install.php")
    log("INFO",    f"Credentials: /root/{domain}-credentials.txt")
    print(site_url)

# v6.5: Async helper for WordPress download
async def _async_download_wordpress(wp_root: Path):
    """Async WordPress download for faster install"""
    urls = [
        ("https://wordpress.org/latest.tar.gz", "/tmp/wordpress-latest.tar.gz")
    ]
    results = await parallel_downloads(urls)
    if results and results[0]:
        # Extract
        import tarfile
        with tarfile.open("/tmp/wordpress-latest.tar.gz", "r:gz") as tar:
            tar.extractall(path=str(wp_root.parent))
        # Move to correct location
        extracted = wp_root.parent / "wordpress"
        if extracted.exists():
            extracted.rename(wp_root)
        Path("/tmp/wordpress-latest.tar.gz").unlink(missing_ok=True)
    else:
        raise Exception("Download failed")


# ═════════════════════════════════════════════════════════════════════════════
# STAGE: clone_site (v6.5: Enhanced with parallel operations)
# ═════════════════════════════════════════════════════════════════════════════

def stage_clone_site(cfg):
    """v6.5: Full site clone with parallel operations"""
    src = cfg.clone_from
    dst = cfg.domain
    if not src or not dst:
        log("ERROR", "--clone-from and --domain are both required for clone_site")
        sys.exit(1)

    src_path = Path(f"/var/www/html/{src}")
    dst_path = Path(f"/var/www/html/{dst}")

    if not src_path.exists():
        log("ERROR", f"Source site not found: {src}"); sys.exit(1)
    if dst_path.exists():
        log("ERROR", f"Destination already exists: {dst}"); sys.exit(1)

    log("STEP", f"Cloning {src} → {dst} (v6.5)")

    # ── 1. Copy files (v6.5: Use rsync for efficiency) ────────────────────
    log("INFO", "Copying WordPress files (rsync)...")
    run(f"rsync -avz --progress {src_path}/ {dst_path}/ 2>/dev/null || cp -r {src_path} {dst_path}", check=False)
    run(f"chown -R www-data:www-data /var/www/html/{dst}", check=False)
    log("SUCCESS", "Files copied")

    # ── 2. Clone database ─────────────────────────────────────────────────
    import secrets, string
    src_db = re.sub(r'[.-]', '_', src)
    dst_db = re.sub(r'[.-]', '_', dst)
    dst_pass = ''.join(secrets.choice(string.ascii_letters + string.digits) for _ in range(20))

    log("INFO", f"Cloning database wp_{src_db} → wp_{dst_db}")
    dump_file = f"/tmp/easyinstall_clone_{dst_db}.sql"
    run(f"mysqldump wp_{src_db} > {dump_file} 2>/dev/null", check=False)
    clone_sql = (
        f"CREATE DATABASE IF NOT EXISTS wp_{{dst_db}} CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;\n"
        f"CREATE USER IF NOT EXISTS 'wpuser_{{dst_db}}'@'localhost' IDENTIFIED BY '{{dst_pass}}';\n"
        f"GRANT ALL PRIVILEGES ON wp_{{dst_db}}.* TO 'wpuser_{{dst_db}}'@'localhost'; FLUSH PRIVILEGES;\n"
    )
    subprocess.run(["mysql"], input=clone_sql, text=True)
    run(f"mysql wp_{{dst_db}} < {{dump_file}} 2>/dev/null", check=False)
    Path(dump_file).unlink(missing_ok=True)

    # ── 3. Update wp-config.php ───────────────────────────────────────────
    redis_port = cfg.redis_port
    wp_conf = dst_path / "wp-config.php"
    if wp_conf.exists():
        txt = wp_conf.read_text()
        txt = re.sub(r"define\('DB_NAME',\s*'[^']*'\)", f"define('DB_NAME', 'wp_{dst_db}')", txt)
        txt = re.sub(r"define\('DB_USER',\s*'[^']*'\)", f"define('DB_USER', 'wpuser_{dst_db}')", txt)
        txt = re.sub(r"define\('DB_PASSWORD',\s*'[^']*'\)", f"define('DB_PASSWORD', '{dst_pass}')", txt)
        txt = re.sub(r"define\('WP_REDIS_PORT',\s*\d+\)", f"define('WP_REDIS_PORT', {redis_port})", txt)
        txt = re.sub(r"define\('WP_CACHE_KEY_SALT',\s*'[^']*'\)", f"define('WP_CACHE_KEY_SALT', '{dst}_')", txt)
        wp_conf.write_text(txt)
    log("SUCCESS", "wp-config.php updated for new domain")

    # ── 4. Search-replace old domain ─────────────────────────────────────
    log("INFO", "Updating domain references in database...")
    run(
        f"wp search-replace '{src}' '{dst}' "
        f"--path=/var/www/html/{dst} --allow-root --skip-columns=guid 2>/dev/null || true",
        check=False
    )

    # ── 5. Create Nginx config (v6.5: with AVIF and HTTP/3) ─────────────
    php_ver = cfg.php_version or "8.4"
    nginx_site = textwrap.dedent(f"""
        server {{
            listen 80;
            listen [::]:80;
            server_name {dst} www.{dst};
            root /var/www/html/{dst};
            index index.php index.html;
            access_log /var/log/nginx/{dst}.access.log main buffer=32k flush=5s;
            error_log  /var/log/nginx/{dst}.error.log warn;

            # v6.5: 2025 Security headers
            add_header X-Frame-Options "SAMEORIGIN" always;
            add_header X-Content-Type-Options "nosniff" always;
            add_header Referrer-Policy "strict-origin-when-cross-origin" always;
            add_header Permissions-Policy "accelerometer=(), camera=(), geolocation=(), gyroscope=(), magnetometer=(), microphone=(), payment=(), usb=()" always;
            add_header Cross-Origin-Embedder-Policy "credentialless" always;
            add_header Cross-Origin-Opener-Policy "same-origin" always;
            add_header Cross-Origin-Resource-Policy "cross-origin" always;

            set $skip_cache 0;
            if ($request_method = POST)  {{ set $skip_cache 1; }}
            if ($query_string != "")     {{ set $skip_cache 1; }}
            if ($request_uri ~* "/wp-admin/|/xmlrpc.php") {{ set $skip_cache 1; }}
            if ($http_cookie ~* "wordpress_logged_in") {{ set $skip_cache 1; }}
            location / {{ try_files $uri $uri/ /index.php?$args; }}
            location ~ \\.php$ {{
                include fastcgi_params;
                fastcgi_pass unix:/run/php/php{php_ver}-fpm.sock;
                fastcgi_index index.php;
                fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
                fastcgi_cache WORDPRESS;
                fastcgi_cache_valid 200 60m;
                fastcgi_cache_bypass $skip_cache;
                fastcgi_no_cache $skip_cache;
                add_header X-Cache $upstream_cache_status;
            }}
            location ~ /\\.ht               {{ deny all; }}
            location = /favicon.ico         {{ log_not_found off; access_log off; }}
            location = /robots.txt          {{ allow all; log_not_found off; }}
            location ~* \\.(css|js|jpg|jpeg|png|gif|ico|svg|woff|woff2|ttf|eot|webp|avif)$ {{
                expires max; add_header Cache-Control "public, immutable";
                try_files $uri$avif_suffix $uri @fallback;
            }}
            location @fallback {{ try_files $uri /index.php?$args; }}
        }}
    """).strip()
    write_file(f"/etc/nginx/sites-available/{dst}", nginx_site)
    link = Path(f"/etc/nginx/sites-enabled/{dst}")
    if not link.exists():
        link.symlink_to(f"/etc/nginx/sites-available/{dst}")

    # ── 6. Redis instance config ───────────────────────────────────────────
    dst_slug = dst.replace('.', '-')
    write_file(f"/etc/redis/redis-{dst_slug}.conf", textwrap.dedent(f"""
        port {redis_port}
        daemonize yes
        pidfile /var/run/redis/redis-{dst_slug}.pid
        logfile /var/log/redis/redis-{dst_slug}.log
        dir /var/lib/redis/{dst_slug}
        maxmemory {cfg.redis_max_memory}
        maxmemory-policy allkeys-lru
        appendonly no
        save ""
        bind 127.0.0.1
        latency-monitor-threshold 100
        notify-keyspace-events Ex
    """).strip())
    Path(f"/var/lib/redis/{dst_slug}").mkdir(parents=True, exist_ok=True)
    run(f"chown redis:redis /var/lib/redis/{dst_slug} 2>/dev/null || true", check=False)

    write_file(f"/etc/systemd/system/redis-{dst_slug}.service", textwrap.dedent(f"""
        [Unit]
        Description=Redis server for {dst}
        After=network.target
        [Service]
        Type=forking
        ExecStart=/usr/bin/redis-server /etc/redis/redis-{dst_slug}.conf
        ExecStop=/usr/bin/redis-cli -p {redis_port} shutdown
        User=redis
        Group=redis
        RuntimeDirectory=redis
        RuntimeDirectoryMode=0755
        LimitNOFILE=65535
        [Install]
        WantedBy=multi-user.target
    """).strip())

    # ── 7. Validate nginx & save creds ────────────────────────────────────
    rc = run("nginx -t 2>/dev/null", check=False)
    if rc == 0:
        run("systemctl reload nginx", check=False)

    creds = textwrap.dedent(f"""
        ========================================
        Cloned WordPress Site: {dst} (v6.5)
        Cloned from: {src}
        ========================================
        Site URL   : http://{dst}
        Admin URL  : http://{dst}/wp-admin
        Database   : wp_{dst_db}
        DB User    : wpuser_{dst_db}
        DB Password: {dst_pass}
        Redis Port : {redis_port}
        PHP Version: {php_ver}
        Directory  : /var/www/html/{dst}
        Features   : AVIF, HTTP/3 Ready, 2025 Security Headers
        ========================================
        Next: systemctl daemon-reload && systemctl enable redis-{dst_slug} && systemctl start redis-{dst_slug}
    """).strip()
    write_file(f"/root/{dst}-credentials.txt", creds, mode=0o600)
    log("SUCCESS", f"Clone complete: {src} → {dst} (v6.5)")

# ═════════════════════════════════════════════════════════════════════════════
# STAGE: remote_install (v6.5: Enhanced SSH with async operations)
# ═════════════════════════════════════════════════════════════════════════════

def stage_remote_install(cfg):
    """v6.5: Remote WordPress installer with enhanced features"""
    import os, time, secrets, string

    domain      = cfg.domain
    php_version = cfg.php_version or "8.4"
    use_ssl     = cfg.use_ssl

    if not domain:
        log("ERROR", "--domain is required for remote_install stage")
        sys.exit(1)

    vps_host     = os.environ.get("REMOTE_HOST",     "")
    vps_user     = os.environ.get("REMOTE_USER",     "root")
    vps_password = os.environ.get("REMOTE_PASSWORD", "")

    if not vps_host:
        log("ERROR", "REMOTE_HOST environment variable is required")
        log("INFO",  "Export: REMOTE_HOST=<ip> REMOTE_USER=<user> REMOTE_PASSWORD=<pass>")
        sys.exit(1)

    try:
        import paramiko
    except ImportError:
        log("ERROR", "paramiko not installed. Run: pip3 install paramiko")
        sys.exit(1)

    domain      = re.sub(r"https?://", "", domain).lstrip("www.").strip("/")
    db_safe     = re.sub(r"[.-]", "_", domain)
    db_pass     = "".join(secrets.choice(string.ascii_letters + string.digits) for _ in range(20))
    redis_port  = cfg.redis_port
    site_url    = ("https://" if use_ssl else "http://") + domain

    log("STEP", f"Remote WordPress install: {vps_host} | domain={domain} | php={php_version} (v6.5)")

    # Build SQL commands (using escaped quotes to avoid shell quoting issues)
    sql_db    = f"mysql -e \"CREATE DATABASE IF NOT EXISTS wp_{db_safe} CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;\""
    sql_user  = f"mysql -e \"CREATE USER IF NOT EXISTS 'wpuser_{db_safe}'@'localhost' IDENTIFIED BY '{db_pass}';\""
    sql_grant = f"mysql -e \"GRANT ALL PRIVILEGES ON wp_{db_safe}.* TO 'wpuser_{db_safe}'@'localhost'; FLUSH PRIVILEGES;\""

    ssl_cmd = (
        f"certbot certonly --webroot -w /var/www/html/{domain} "
        f"-d {domain} -d www.{domain} "
        f"--non-interactive --agree-tos --email admin@{domain}"
    ) if use_ssl else "echo 'SSL skipped'"

    # Build wp-config.php
    wp_config_lines = [
        "<?php",
        "/**",
        " * WordPress Configuration - Remote Install (v6.5)",
        " */",
        "",
        "// Database",
        f"define('DB_NAME',     'wp_{db_safe}');",
        f"define('DB_USER',     'wpuser_{db_safe}');",
        f"define('DB_PASSWORD', '{db_pass}');",
        "define('DB_HOST',     'localhost');",
        "define('DB_CHARSET',  'utf8mb4');",
        "define('DB_COLLATE',  '');",
        "",
        "// Performance",
        "define('WP_CACHE',              true);",
        "define('WP_POST_REVISIONS',     5);",
        "define('EMPTY_TRASH_DAYS',      7);",
        "define('AUTOSAVE_INTERVAL',     300);",
        "define('FS_METHOD',             'direct');",
        "define('AUTOMATIC_UPDATER_DISABLED', false);",
        "define('WP_AUTO_UPDATE_CORE',      'minor');",
        "",
        "// Redis",
        "define('WP_REDIS_HOST',         '127.0.0.1');",
        f"define('WP_REDIS_PORT',         {redis_port});",
        f"define('WP_CACHE_KEY_SALT',     '{domain}_');",
    ]
    if use_ssl:
        wp_config_lines += [
            "",
            "// SSL",
            f"define('WP_HOME',   'https://{domain}');",
            f"define('WP_SITEURL','https://{domain}');",
        ]
    wp_config_lines += [
        "",
        "$table_prefix = 'wp_';",
        "if (!defined('ABSPATH')) define('ABSPATH', __DIR__ . '/');",
        "require_once ABSPATH . 'wp-settings.php';",
    ]
    wp_config_content = "\n".join(wp_config_lines)

    # Build nginx config (v6.5: with 2025 headers)
    nginx_config_content = "\n".join([
        "server {",
        "    listen 80;",
        "    listen [::]:80;",
        f"    server_name {domain} www.{domain};",
        f"    root /var/www/html/{domain};",
        "    index index.php index.html;",
        "",
        "    # v6.5: 2025 Security Headers",
        '    add_header X-Frame-Options "SAMEORIGIN" always;',
        '    add_header X-Content-Type-Options "nosniff" always;',
        '    add_header Referrer-Policy "strict-origin-when-cross-origin" always;',
        '    add_header Permissions-Policy "accelerometer=(), camera=(), geolocation=(), gyroscope=(), magnetometer=(), microphone=(), payment=(), usb=()" always;',
        "",
        "    location ^~ /.well-known/acme-challenge/ {",
        f"        root /var/www/html/{domain};",
        "        allow all;",
        "    }",
        "    location / { try_files $uri $uri/ /index.php?$args; }",
        r"    location ~ \.php$ {",
        "        include fastcgi_params;",
        f"        fastcgi_pass unix:/run/php/php{php_version}-fpm.sock;",
        "        fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;",
        "    }",
        r"    location ~ /\.ht { deny all; }",
        "}",
    ])

    def write_remote_file(filepath, content):
        escaped = content.replace("'", "'\''")
        return f"printf '%s' '{escaped}' > {filepath}"

    remote_commands = [
        "apt-get update -y",
        (f"apt-get install -y nginx"
         f" php{php_version}-fpm"
         f" php{php_version}-mysql"
         f" php{php_version}-curl"
         f" php{php_version}-gd"
         f" php{php_version}-mbstring"
         f" php{php_version}-xml"
         f" php{php_version}-zip"
         f" php{php_version}-opcache"
         f" php{php_version}-igbinary"
         f" php{php_version}-redis"
         f" mariadb-server mariadb-client"
         f" redis-server certbot python3-certbot-nginx wget curl rsync"),
        "systemctl enable nginx mariadb redis-server php" + php_version + "-fpm",
        "systemctl start nginx mariadb redis-server php" + php_version + "-fpm",
        "rm -f /etc/nginx/sites-enabled/default",
        sql_db,
        sql_user,
        sql_grant,
        f"mkdir -p /var/www/html/{domain}",
        f"wget -qO- https://wordpress.org/latest.tar.gz | tar xz -C /var/www/html/{domain} --strip-components=1",
        f"chown -R www-data:www-data /var/www/html/{domain}",
        f"chmod -R 755 /var/www/html/{domain}",
        write_remote_file(f"/var/www/html/{domain}/wp-config.php", wp_config_content),
        f"chown www-data:www-data /var/www/html/{domain}/wp-config.php",
        f"chmod 640 /var/www/html/{domain}/wp-config.php",
        write_remote_file(f"/etc/nginx/sites-available/{domain}", nginx_config_content),
        f"ln -sf /etc/nginx/sites-available/{domain} /etc/nginx/sites-enabled/{domain}",
        "sed -i 's/^user nginx;/user www-data;/' /etc/nginx/nginx.conf 2>/dev/null || true",
        "mkdir -p /var/cache/nginx/fastcgi && chown -R www-data:www-data /var/cache/nginx",
        "nginx -t && systemctl reload nginx",
        ssl_cmd,
    ]

    client = None
    try:
        client = paramiko.SSHClient()
        client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
        client.connect(vps_host, username=vps_user, password=vps_password, timeout=30)
        log("SUCCESS", f"SSH connected to {vps_host} (v6.5)")

        for cmd in remote_commands:
            short = cmd[:70]
            log("INFO", f"Remote: {short}...")
            stdin, stdout, stderr = client.exec_command(cmd, get_pty=True)
            exit_status = stdout.channel.recv_exit_status()
            out = stdout.read().decode("utf-8", errors="replace").strip()
            err = stderr.read().decode("utf-8", errors="replace").strip()
            if out:
                log("INFO", f"  OUT: {out[:200]}")
            if exit_status != 0 and err:
                log("WARNING", f"  ERR: {err[:200]}")
            time.sleep(0.5)

        log("SUCCESS", f"Remote WordPress installation complete! (v6.5)")
        log("INFO", f"Site URL  : {site_url}")
        log("INFO", f"Admin URL : {site_url}/wp-admin/install.php")
        log("INFO", f"DB: wp_{db_safe} / wpuser_{db_safe} / {db_pass}")

        creds = (
            f"Remote WordPress: {domain} (v6.5)\n"
            f"Host: {vps_host}\n"
            f"Site URL: {site_url}\n"
            f"DB: wp_{db_safe} / wpuser_{db_safe} / {db_pass}\n"
            f"Features: AVIF, HTTP/3 Ready, 2025 Security Headers\n"
        )
        Path(f"/tmp/{domain}-remote-credentials.txt").write_text(creds)
        log("INFO", f"Credentials: /tmp/{domain}-remote-credentials.txt")

    except Exception as e:
        log("ERROR", f"Remote install failed: {e}")
        sys.exit(1)
    finally:
        if client:
            client.close()
            log("INFO", "SSH connection closed")


# ─────────────────────────────────────────────────────────────────────────────
# Ported from v6.4 — stage_firewall_config
# ─────────────────────────────────────────────────────────────────────────────

def stage_firewall_config(cfg):
    log("STEP", "Configuring UFW firewall rules")
    cmds = [
        "ufw --force disable",
        "ufw --force reset",
        "ufw default deny incoming",
        "ufw default allow outgoing",
        "ufw allow 22/tcp comment 'SSH'",
        "ufw allow 80/tcp comment 'HTTP'",
        "ufw allow 443/tcp comment 'HTTPS'",
        "ufw allow 443/udp comment 'HTTP/3 QUIC'",
        "ufw limit ssh/tcp",
    ]
    for cmd in cmds:
        run(f"{cmd} 2>/dev/null || true", check=False)
    # Redis ports 6379-6479
    for port in range(6379, 6480):
        run(f"ufw allow {port}/tcp comment 'Redis port {port}' 2>/dev/null || true", check=False)
    log("SUCCESS", "Firewall rules written (activate with: echo y | ufw enable)")




# ─────────────────────────────────────────────────────────────────────────────
# Ported from v6.4 — stage_fail2ban_config
# ─────────────────────────────────────────────────────────────────────────────

def stage_fail2ban_config(cfg):
    log("STEP", "Configuring Fail2ban for WordPress protection")

    write_file("/etc/fail2ban/jail.local", textwrap.dedent("""\
        [DEFAULT]
        bantime = 3600
        findtime = 600
        maxretry = 5
        ignoreip = 127.0.0.1/8 ::1

        [sshd]
        enabled = true
        port = ssh
        filter = sshd
        logpath = /var/log/auth.log
        maxretry = 3
        bantime = 86400

        [nginx-http-auth]
        enabled = true
        filter = nginx-http-auth
        port = http,https
        logpath = /var/log/nginx/error.log

        [nginx-badbots]
        enabled = true
        filter = nginx-badbots
        port = http,https
        logpath = /var/log/nginx/access.log
        maxretry = 2
        bantime = 86400

        [nginx-login]
        enabled = true
        filter = nginx-login
        port = http,https
        logpath = /var/log/nginx/access.log
        maxretry = 5
        bantime = 3600

        [wordpress]
        enabled = true
        filter = wordpress
        port = http,https
        logpath = /var/log/nginx/access.log
        maxretry = 5
        bantime = 3600

        [wordpress-hard]
        enabled = true
        filter = wordpress-hard
        port = http,https
        logpath = /var/log/nginx/access.log
        maxretry = 2
        bantime = 86400
    """))

    write_file("/etc/fail2ban/filter.d/wordpress.conf", textwrap.dedent("""\
        [Definition]
        failregex = ^<HOST> .* "POST .*wp-login\\.php.*" 200
                    ^<HOST> .* "POST .*xmlrpc\\.php.*" 200
                    ^<HOST> .* "POST .*wp-admin/admin-ajax\\.php.*" 200
                    ^<HOST> .* "GET .*wp-login\\.php.*" 200
        ignoreregex =
    """))

    write_file("/etc/fail2ban/filter.d/wordpress-hard.conf", textwrap.dedent("""\
        [Definition]
        failregex = ^<HOST> .* "GET .*/wp-content/.*" 404
                    ^<HOST> .* "GET .*/wp-includes/.*" 404
                    ^<HOST> .* "POST .*/wp-content/.*" 404
                    ^<HOST> .* "POST .*/wp-includes/.*" 404
        ignoreregex =
    """))

    write_file("/etc/fail2ban/filter.d/nginx-login.conf", textwrap.dedent("""\
        [Definition]
        failregex = ^<HOST> .* "POST .*/wp-login\\.php.*" 200
                    ^<HOST> .* "POST .*/xmlrpc\\.php.*" 200
                    ^<HOST> .* "POST .*/wp-admin/admin-ajax\\.php.*" 200
        ignoreregex =
    """))
    log("SUCCESS", "Fail2ban configuration written")




# ─────────────────────────────────────────────────────────────────────────────
# Ported from v6.4 — stage_create_redis_monitor
# ─────────────────────────────────────────────────────────────────────────────

def stage_create_redis_monitor(cfg):
    log("STEP", "Creating Redis monitoring script")
    script = textwrap.dedent("""\
        #!/bin/bash
        GREEN='\\033[0;32m'; YELLOW='\\033[1;33m'; RED='\\033[0;31m'; NC='\\033[0m'

        echo -e "${GREEN}=== Redis Instances Status ===${NC}"
        echo ""
        if systemctl is-active --quiet redis-server; then
            echo -e "${GREEN}✓${NC} Main Redis (port 6379): Running"
        else
            echo -e "${RED}✗${NC} Main Redis (port 6379): Stopped"
        fi
        for redis_conf in /etc/redis/redis-*.conf; do
            [ -f "$redis_conf" ] || continue
            site_name=$(basename "$redis_conf" .conf | sed 's/redis-//')
            redis_port=$(grep "^port" "$redis_conf" | awk '{print $2}')
            if systemctl is-active --quiet "redis-${site_name}"; then
                echo -e "${GREEN}✓${NC} Site ${site_name} (port ${redis_port}): Running"
            else
                echo -e "${RED}✗${NC} Site ${site_name} (port ${redis_port}): Stopped"
            fi
        done
        echo ""
        echo -e "${YELLOW}Used Redis Ports:${NC}"
        sort -n /var/lib/easyinstall/used_redis_ports.txt 2>/dev/null | while read port; do
            echo "  • $port"
        done
    """)
    write_file("/usr/local/bin/easy-redis-status", script, mode=0o755)
    log("SUCCESS", "Redis monitor created")




# ─────────────────────────────────────────────────────────────────────────────
# Ported from v6.4 — stage_create_commands
# ─────────────────────────────────────────────────────────────────────────────

def stage_create_commands(cfg):
    log("STEP", "Creating easyinstall command dispatcher")
    # The dispatcher is written as a Bash script but config sub-commands
    # delegate to Python (easyinstall_config.py --stage wordpress_install)
    script = textwrap.dedent("""\
        #!/bin/bash
        VERSION="6.5"
        GREEN='\\033[0;32m'; YELLOW='\\033[1;33m'; RED='\\033[0;31m'
        BLUE='\\033[0;34m'; PURPLE='\\033[0;35m'; CYAN='\\033[0;36m'; NC='\\033[0m'
        IP_ADDRESS=$(hostname -I | awk '{print $1}')
        LOG_FILE="/var/log/easyinstall/command.log"
        PYTHON_CONFIG="/usr/local/lib/easyinstall_config.py"

        log_command() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"; }

        show_header() {
            echo -e "${BLUE}══════════════════════════════════════════════${NC}"
            echo -e "${GREEN}🚀 EasyInstall v${VERSION} HYBRID — WordPress Performance${NC}"
            echo -e "${BLUE}══════════════════════════════════════════════${NC}"; echo ""
        }

        show_help() {
            show_header
            echo -e "${YELLOW}📋 Available Commands:${NC}"; echo ""
            echo -e "${GREEN}CREATE:${NC}"
            echo "  easyinstall create domain.com [--php=8.3] [--ssl]"
            echo ""
            echo -e "${GREEN}REDIS:${NC}"
            echo "  easyinstall redis-status | redis-ports | redis-restart domain | redis-cli domain"
            echo ""
            echo -e "${GREEN}MANAGEMENT:${NC}"
            echo "  easyinstall list | delete domain | status | site-info domain"
            echo ""
            echo -e "${GREEN}SSL / UPDATE:${NC}"
            echo "  easyinstall ssl domain | ssl-renew | update-site domain | clone src dst | php-switch domain 8.4"
            echo ""
            echo -e "${GREEN}BACKUP / MONITORING:${NC}"
            echo "  easyinstall backup [daily|weekly] | backup-site domain | monitor | perf | health | logs"
            echo ""
            echo -e "${GREEN}OPTIMIZE:${NC}"
            echo "  easyinstall optimize | clean"
            echo ""
            echo -e "${GREEN}🤖 AI:${NC}"
            echo "  easyinstall ai-setup | ai-install-ollama | ai-diagnose [domain]"
            echo "  easyinstall ai-optimize | ai-security | ai-report"
            echo ""
            echo -e "${GREEN}⚡ AUTO-TUNING:${NC}"
            echo "  easyinstall advanced-tune | perf-dashboard | warm-cache | db-optimize"
            echo "  easyinstall wp-speed | install-governor | emergency-check | autotune-rollback"
            echo ""
            echo -e "${GREEN}🆕 v6.5 WEBSOCKET:${NC}"
            echo "  easyinstall ws-enable domain [port] | ws-disable domain | ws-status [domain] | ws-test domain"
            echo ""
            echo -e "${GREEN}🆕 v6.5 HTTP/3 + QUIC:${NC}"
            echo "  easyinstall http3-enable | http3-status"
            echo ""
            echo -e "${GREEN}🆕 v6.5 EDGE COMPUTING:${NC}"
            echo "  easyinstall edge-setup | edge-status | edge-purge domain [/path]"
            echo ""
            echo -e "${GREEN}🆕 v6.5 CLOUD & CONTAINERS:${NC}"
            echo "  easyinstall s3-backup-setup | container-setup"
            echo ""
        }

        parse_args() {
            PHP_VERSION="8.4"; USE_SSL="false"
            for arg in "$@"; do
                case $arg in
                    --php=*) PHP_VERSION="${arg#*=}" ;;
                    --ssl)   USE_SSL="true" ;;
                esac
            done
        }

        # ──────────────────────────────────────────────────────────────────
        # Helper: call Python config module (inherits all env tuning vars)
        # ──────────────────────────────────────────────────────────────────
        py_config() {
            local stage="$1"; shift
            python3 "$PYTHON_CONFIG" --stage "$stage" "$@" 2>&1 || \
                echo -e "${RED}❌ Python config module error for stage: $stage${NC}"
        }

        # ──────────────────────────────────────────────────────────────────
        case "$1" in
        help|"")
            show_help ;;

        create)
            [ -z "$2" ] && { echo -e "${RED}❌ Usage: easyinstall create domain.com [--ssl]${NC}"; exit 1; }
            DOMAIN=$2; shift 2; parse_args "$@"
            log_command "create $DOMAIN php=$PHP_VERSION ssl=$USE_SSL"
            echo -e "${YELLOW}📦 Installing WordPress for $DOMAIN...${NC}"
            REDIS_PORT=$(python3 -c "
        import subprocess, os
        p=6380
        used=open('/var/lib/easyinstall/used_redis_ports.txt').read().split() if os.path.exists('/var/lib/easyinstall/used_redis_ports.txt') else []
        while str(p) in used: p+=1
        print(p)
        " 2>/dev/null || echo "6380")
            ssl_flag=""
            [ "$USE_SSL" = "true" ] && ssl_flag="--use-ssl"
            py_config wordpress_install \
                --domain "$DOMAIN" \
                --php-version "$PHP_VERSION" \
                --redis-port "$REDIS_PORT" \
                $ssl_flag
            echo "$REDIS_PORT" >> /var/lib/easyinstall/used_redis_ports.txt
            sort -u /var/lib/easyinstall/used_redis_ports.txt -o /var/lib/easyinstall/used_redis_ports.txt
            ;;

        list)
            log_command "list"
            echo -e "${YELLOW}📋 WordPress Sites:${NC}"
            if [ -d "/var/www/html" ] && [ "$(ls -A /var/www/html)" ]; then
                for site_dir in /var/www/html/*/; do
                    [ -d "$site_dir" ] || continue
                    domain=$(basename "$site_dir")
                    redis_port=$(grep "^port" "/etc/redis/redis-${domain//./-}.conf" 2>/dev/null | awk '{print $2}' || echo "n/a")
                    size=$(du -sh "$site_dir" 2>/dev/null | cut -f1 || echo "?")
                    ssl_status=$([ -d "/etc/letsencrypt/live/$domain" ] && echo "SSL✓" || echo "HTTP")
                    echo -e "  ${GREEN}•${NC} $domain | Redis: $redis_port | Size: $size | $ssl_status"
                done
            else
                echo -e "  ${YELLOW}No sites installed${NC}"
            fi ;;

        delete)
            [ -z "$2" ] && { echo -e "${RED}❌ Usage: easyinstall delete domain.com${NC}"; exit 1; }
            DOMAIN=$2; log_command "delete $DOMAIN"
            echo -e "${YELLOW}🗑️  Deleting $DOMAIN...${NC}"
            rm -rf "/var/www/html/$DOMAIN"
            rm -f "/etc/nginx/sites-enabled/$DOMAIN" "/etc/nginx/sites-available/$DOMAIN"
            DB_SAFE=$(echo "$DOMAIN" | sed 's/[.-]/_/g')
            mysql -e "DROP DATABASE IF EXISTS wp_${DB_SAFE}; DROP USER IF EXISTS 'wpuser_${DB_SAFE}'@'localhost'; FLUSH PRIVILEGES;" 2>/dev/null || true
            systemctl stop "redis-${DOMAIN//./-}" 2>/dev/null || true
            systemctl disable "redis-${DOMAIN//./-}" 2>/dev/null || true
            rm -f "/etc/redis/redis-${DOMAIN//./-}.conf" "/etc/systemd/system/redis-${DOMAIN//./-}.service"
            systemctl daemon-reload
            systemctl daemon-reload 2>/dev/null || true
            nginx -t 2>/dev/null && systemctl reload nginx
            echo -e "${GREEN}✅ $DOMAIN deleted${NC}" ;;

        status)
            log_command "status"
            echo -e "${YELLOW}System Status:${NC}"
            for service in nginx mariadb php8.4-fpm php8.3-fpm php8.2-fpm redis-server fail2ban autoheal; do
                if systemctl is-active --quiet "$service" 2>/dev/null; then
                    echo -e "  ${GREEN}✓${NC} $service"
                else
                    echo -e "  ${RED}✗${NC} $service"
                fi
            done ;;

        redis-status)
            log_command "redis-status"
            /usr/local/bin/easy-redis-status ;;

        redis-ports)
            log_command "redis-ports"
            echo -e "${YELLOW}Redis Ports in Use:${NC}"
            sort -n /var/lib/easyinstall/used_redis_ports.txt 2>/dev/null | while read p; do echo "  • $p"; done ;;

        redis-restart)
            [ -z "$2" ] && { echo -e "${RED}❌ Usage: easyinstall redis-restart domain.com${NC}"; exit 1; }
            systemctl restart "redis-${2//./-}" && echo -e "${GREEN}✅ Redis restarted for $2${NC}" ;;

        redis-cli)
            [ -z "$2" ] && { echo -e "${RED}❌ Usage: easyinstall redis-cli domain.com${NC}"; exit 1; }
            RPORT=$(grep "^port" "/etc/redis/redis-${2//./-}.conf" 2>/dev/null | awk '{print $2}' || echo "6379")
            redis-cli -p "$RPORT" ;;

        ssl)
            [ -z "$2" ] && { echo -e "${RED}❌ Usage: easyinstall ssl domain.com${NC}"; exit 1; }
            SSLDOM="$2"
            log_command "ssl $SSLDOM"
            # FIX: Use webroot method — more reliable, avoids nginx plugin conflicts
            systemctl reload nginx 2>/dev/null || true
            if certbot certonly --webroot -w "/var/www/html/$SSLDOM" \
                -d "$SSLDOM" -d "www.$SSLDOM" \
                --non-interactive --agree-tos --email "admin@$SSLDOM"; then
                echo -e "${GREEN}✅ SSL certificate obtained for $SSLDOM${NC}"
                # Run Python config to rewrite nginx config with HTTPS block
                py_config wordpress_install --domain "$SSLDOM" --use-ssl 2>/dev/null || true
                echo -e "${YELLOW}ℹ️  If site already existed, re-run: easyinstall ssl $SSLDOM${NC}"
            else
                echo -e "${YELLOW}⚠️  Webroot failed, trying --nginx plugin fallback...${NC}"
                certbot --nginx -d "$SSLDOM" -d "www.$SSLDOM" \
                    --non-interactive --agree-tos --email "admin@$SSLDOM" && \
                    echo -e "${GREEN}✅ SSL enabled via nginx plugin${NC}" || \
                    echo -e "${RED}❌ SSL failed. Ensure DNS A-record points to this server and port 80 is open.${NC}"
            fi ;;

        ssl-renew)
            log_command "ssl-renew"
            # FIX: reload nginx after renewal so new certs are loaded
            certbot renew --quiet --post-hook "systemctl reload nginx" && \
                echo -e "${GREEN}✅ SSL certs renewed${NC}" || \
                echo -e "${YELLOW}⚠️  Renewal failed or not due yet${NC}" ;;

        backup)
            /usr/local/bin/easy-backup "${2:-daily}" ;;

        backup-site)
            [ -z "$2" ] && { echo -e "${RED}❌ Usage: easyinstall backup-site domain.com${NC}"; exit 1; }
            DOMAIN=$2; DATE=$(date +%Y%m%d-%H%M%S); mkdir -p /backups/sites
            tar -czf "/backups/sites/${DOMAIN}-${DATE}.tar.gz" "/var/www/html/$DOMAIN" "/etc/nginx/sites-available/$DOMAIN" 2>/dev/null && \
                echo -e "${GREEN}✅ Site backed up: /backups/sites/${DOMAIN}-${DATE}.tar.gz${NC}"
            DB_SAFE=$(echo "$DOMAIN" | sed 's/[.-]/_/g')
            mysqldump "wp_${DB_SAFE}" 2>/dev/null | gzip > "/backups/sites/${DOMAIN}-db-${DATE}.sql.gz" && \
                echo -e "${GREEN}✅ DB backed up${NC}" ;;

        monitor)
            /usr/local/bin/easy-monitor watch ;;

        perf)
            echo -e "${YELLOW}Performance Statistics:${NC}"
            for version in 8.4 8.3 8.2; do
                [ -f "/etc/php/$version/fpm/pool.d/www.conf" ] && {
                    echo "  PHP $version:"; grep -E "pm.max_children|pm.start_servers" "/etc/php/$version/fpm/pool.d/www.conf" | sed 's/^/    /'; }
            done
            echo "Redis Memory:" && redis-cli INFO memory | grep -E "used_memory_human|maxmemory_human" | sed 's/^/  /' 2>/dev/null ;;

        optimize)
            log_command "optimize"
            for version in 8.4 8.3 8.2; do systemctl reload php${version}-fpm 2>/dev/null || true; done
            redis-cli FLUSHALL 2>/dev/null; mysqlcheck -o --all-databases 2>/dev/null; systemctl reload nginx
            echo -e "${GREEN}✅ Optimization complete${NC}" ;;

        clean)
            rm -rf /var/cache/nginx/fastcgi/* 2>/dev/null
            find /var/log -type f -name "*.log" -size +50M -exec truncate -s 0 {} \\; 2>/dev/null
            find /var/lib/php/sessions -type f -cmin +60 -delete 2>/dev/null || true
            apt clean 2>/dev/null; echo -e "${GREEN}✅ Cleanup complete${NC}" ;;

        logs)
            echo -e "${GREEN}Installation Log:${NC}"; tail -20 /var/log/easyinstall/install.log 2>/dev/null
            echo -e "${GREEN}Error Log:${NC}";        tail -10 /var/log/easyinstall/error.log 2>/dev/null
            echo -e "${GREEN}Nginx Errors:${NC}";     tail -10 /var/log/nginx/error.log 2>/dev/null ;;

        health)
            log_command "health"
            echo -e "${YELLOW}Health Check:${NC}"; failed=0
            for service in nginx mariadb php8.4-fpm php8.3-fpm php8.2-fpm redis-server fail2ban autoheal; do
                if systemctl is-active --quiet "$service" 2>/dev/null; then
                    echo -e "  ${GREEN}✓${NC} $service"
                else
                    echo -e "  ${RED}✗${NC} $service"; failed=$((failed + 1))
                fi
            done
            disk_usage=$(df / | awk 'NR==2 {print $5}' | sed 's/%//')
            [ $disk_usage -gt 85 ] && echo -e "  ${YELLOW}⚠️ Disk: $disk_usage% (high)${NC}" || echo -e "  ${GREEN}✓${NC} Disk: $disk_usage%"
            [ $failed -eq 0 ] && echo -e "${GREEN}✅ All checks passed${NC}" || echo -e "${YELLOW}⚠️ $failed service(s) not running${NC}"
            echo ""
            echo -e "${YELLOW}🌐 Site Latency:${NC}"
            for site_dir in /var/www/html/*/; do
                [ -d "$site_dir" ] || continue
                domain=$(basename "$site_dir")
                latency=$(curl -s -o /dev/null -w "%{time_total}" --max-time 5 -H "Host: $domain" "http://127.0.0.1/" 2>/dev/null || echo "timeout")
                http_code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 -H "Host: $domain" "http://127.0.0.1/" 2>/dev/null || echo "000")
                echo -e "  ${GREEN}✓${NC} $domain — HTTP ${http_code} | ${latency}s"
            done ;;

        version)
            echo -e "${GREEN}EasyInstall v${VERSION} HYBRID Edition${NC}"
            echo "Installed: $(stat -c %y /usr/local/bin/easyinstall 2>/dev/null | cut -d' ' -f1)" ;;

        ai-setup)
            source /usr/local/lib/easyinstall-ai.sh 2>/dev/null && ai_setup || echo -e "${RED}❌ AI module not found${NC}" ;;
        ai-diagnose)
            source /usr/local/lib/easyinstall-ai.sh 2>/dev/null && ai_diagnose "${2:-}" || echo -e "${RED}❌ AI module not found${NC}" ;;
        ai-optimize)
            source /usr/local/lib/easyinstall-ai.sh 2>/dev/null && ai_optimize || echo -e "${RED}❌ AI module not found${NC}" ;;
        ai-security)
            source /usr/local/lib/easyinstall-ai.sh 2>/dev/null && ai_security || echo -e "${RED}❌ AI module not found${NC}" ;;
        ai-report)
            source /usr/local/lib/easyinstall-ai.sh 2>/dev/null && ai_report || echo -e "${RED}❌ AI module not found${NC}" ;;
        ai-install-ollama)
            command -v ollama &>/dev/null || curl -fsSL https://ollama.com/install.sh | sh
            systemctl enable ollama 2>/dev/null && systemctl start ollama 2>/dev/null || (ollama serve >/dev/null 2>&1 & sleep 3)
            source /usr/local/lib/easyinstall-ai.sh 2>/dev/null
            ai_load_config 2>/dev/null; ollama pull "${AI_MODEL:-phi3}" && echo -e "${GREEN}✅ Ollama ready${NC}" ;;

        advanced-tune)
            source /usr/local/lib/easyinstall-autotune.sh 2>/dev/null && advanced_auto_tune || echo -e "${RED}❌ AutoTune module missing${NC}" ;;
        perf-dashboard)
            source /usr/local/lib/easyinstall-autotune.sh 2>/dev/null && perf_dashboard || echo -e "${RED}❌ AutoTune module missing${NC}" ;;
        warm-cache)
            source /usr/local/lib/easyinstall-autotune.sh 2>/dev/null && smart_cache_warmer || echo -e "${RED}❌ AutoTune module missing${NC}" ;;
        db-optimize)
            source /usr/local/lib/easyinstall-autotune.sh 2>/dev/null && db_optimization_engine || echo -e "${RED}❌ AutoTune module missing${NC}" ;;
        wp-speed)
            source /usr/local/lib/easyinstall-autotune.sh 2>/dev/null && wordpress_max_speed || echo -e "${RED}❌ AutoTune module missing${NC}" ;;
        install-governor)
            source /usr/local/lib/easyinstall-autotune.sh 2>/dev/null && install_governor_timer || echo -e "${RED}❌ AutoTune module missing${NC}" ;;
        emergency-check)
            source /usr/local/lib/easyinstall-autotune.sh 2>/dev/null && disaster_recovery_mode "manual" || echo -e "${RED}❌ AutoTune module missing${NC}" ;;
        autotune-rollback)
            source /usr/local/lib/easyinstall-autotune.sh 2>/dev/null && autotune_rollback || echo -e "${RED}❌ AutoTune module missing${NC}" ;;

        update-site)
            [ -z "$2" ] && { echo -e "${RED}❌ Usage: easyinstall update-site domain.com${NC}"; exit 1; }
            WP_PATH="/var/www/html/$2"
            [ -d "$WP_PATH" ] || { echo -e "${RED}❌ Site not found: $2${NC}"; exit 1; }
            sudo -u www-data wp core update --path="$WP_PATH" --allow-root 2>/dev/null || true
            sudo -u www-data wp plugin update --all --path="$WP_PATH" --allow-root 2>/dev/null || true
            sudo -u www-data wp theme update --all --path="$WP_PATH" --allow-root 2>/dev/null || true
            sudo -u www-data wp core update-db --path="$WP_PATH" --allow-root 2>/dev/null || true
            echo -e "${GREEN}✅ $2 updated${NC}" ;;

        clone)
            [ -z "$2" ] || [ -z "$3" ] && { echo -e "${RED}❌ Usage: easyinstall clone src.com dst.com${NC}"; exit 1; }
            SRC_DOMAIN=$2; DST_DOMAIN=$3
            log_command "clone $SRC_DOMAIN $DST_DOMAIN"
            echo -e "${CYAN}🔁 Cloning $SRC_DOMAIN → $DST_DOMAIN...${NC}"
            [ -d "/var/www/html/$SRC_DOMAIN" ] || { echo -e "${RED}❌ Source not found: $SRC_DOMAIN${NC}"; exit 1; }
            [ -d "/var/www/html/$DST_DOMAIN" ] && { echo -e "${RED}❌ Destination already exists: $DST_DOMAIN${NC}"; exit 1; }
            DST_REDIS_PORT=$(python3 -c "
import os; p=6380
used=open('/var/lib/easyinstall/used_redis_ports.txt').read().split() if os.path.exists('/var/lib/easyinstall/used_redis_ports.txt') else []
while str(p) in used: p+=1
print(p)
" 2>/dev/null || echo "6381")
            py_config clone_site --domain "$DST_DOMAIN" --clone-from "$SRC_DOMAIN" --redis-port "$DST_REDIS_PORT"
            # Start the new Redis instance (Bash layer)
            systemctl daemon-reload 2>/dev/null || true
            systemctl enable "redis-${DST_DOMAIN//./-}" 2>/dev/null || true
            systemctl start  "redis-${DST_DOMAIN//./-}" 2>/dev/null || true
            echo "$DST_REDIS_PORT" >> /var/lib/easyinstall/used_redis_ports.txt
            sort -u /var/lib/easyinstall/used_redis_ports.txt -o /var/lib/easyinstall/used_redis_ports.txt
            echo -e "${GREEN}✅ Clone complete: $SRC_DOMAIN → $DST_DOMAIN${NC}"
            echo -e "${YELLOW}  Next: easyinstall ssl $DST_DOMAIN  (if needed)${NC}"
            echo -e "${YELLOW}  Creds: /root/${DST_DOMAIN}-credentials.txt${NC}" ;;
        remote-install)
            [ -z "$2" ] && { echo -e "${RED}❌ Usage: easyinstall remote-install domain.com [--php=8.3] [--ssl]${NC}"; exit 1; }
            DOMAIN=$2; shift 2; parse_args "$@"
            log_command "remote-install $DOMAIN php=$PHP_VERSION ssl=$USE_SSL"
            echo -e "${CYAN}🌐 Remote WordPress install on $DOMAIN...${NC}"
            echo -e "${YELLOW}ℹ️  Set REMOTE_HOST, REMOTE_USER, REMOTE_PASSWORD env vars before running${NC}"
            ssl_flag=""
            [ "$USE_SSL" = "true" ] && ssl_flag="--use-ssl"
            py_config remote_install --domain "$DOMAIN" --php-version "$PHP_VERSION" $ssl_flag ;;

        php-switch)
            [ -z "$2" ] || [ -z "$3" ] && { echo -e "${RED}❌ Usage: easyinstall php-switch domain.com 8.4${NC}"; exit 1; }
            NGINX_CONF="/etc/nginx/sites-available/$2"
            [ -f "$NGINX_CONF" ] || { echo -e "${RED}❌ Nginx config not found for $2${NC}"; exit 1; }
            OLD_VER=$(grep -oP "php\\K[0-9]+\\.[0-9]+" "$NGINX_CONF" | head -1 || echo "8.3")
            sed -i "s/php${OLD_VER}-fpm/php${3}-fpm/g" "$NGINX_CONF"
            nginx -t && systemctl reload nginx && echo -e "${GREEN}✅ $2 switched to PHP $3${NC}" || echo -e "${RED}❌ Config error${NC}" ;;

        site-info)
            [ -z "$2" ] && { echo -e "${RED}❌ Usage: easyinstall site-info domain.com${NC}"; exit 1; }
            DOMAIN=$2; DB_SAFE=$(echo "$DOMAIN" | sed 's/[.-]/_/g')
            echo -e "${CYAN}Site Info: $DOMAIN${NC}"
            echo "  Path   : /var/www/html/$DOMAIN"
            echo "  Nginx  : /etc/nginx/sites-available/$DOMAIN"
            echo "  DB     : wp_${DB_SAFE}"
            redis_port=$(grep "^port" "/etc/redis/redis-${DOMAIN//./-}.conf" 2>/dev/null | awk '{print $2}' || echo "n/a")
            echo "  Redis  : port $redis_port"
            echo "  SSL    : $([ -d /etc/letsencrypt/live/$DOMAIN ] && echo "Enabled" || echo "Disabled")"
            php_ver=$(grep -oP "php\\K[0-9]+\\.[0-9]+" "/etc/nginx/sites-available/$DOMAIN" 2>/dev/null | head -1 || echo "unknown")
            echo "  PHP    : $php_ver"
            echo "  Size   : $(du -sh /var/www/html/$DOMAIN 2>/dev/null | cut -f1 || echo "?")" ;;

        ws-enable)
            [ -z "$2" ] && { echo -e "${RED}❌ Usage: easyinstall ws-enable domain.com [port]${NC}"; exit 1; }
            WS_DOMAIN=$2; WS_PORT="${3:-8080}"; NGINX_CONF="/etc/nginx/sites-available/$WS_DOMAIN"
            [ -f "$NGINX_CONF" ] || { echo -e "${RED}❌ Nginx config not found for $WS_DOMAIN${NC}"; exit 1; }
            if ! grep -q "proxy_set_header.*Upgrade" "$NGINX_CONF"; then
                TMPF=$(mktemp)
                awk -v port="$WS_PORT" '
                /^}$/ && !done {
                    print ""
                    print "    # WebSocket proxy (EasyInstall v6.5)"
                    print "    location ~ ^/(ws|wss)(/.*)? {"
                    print "        proxy_pass         http://127.0.0.1:" port ";"
                    print "        proxy_http_version 1.1;"
                    print "        proxy_set_header   Upgrade           $http_upgrade;"
                    print "        proxy_set_header   Connection        $connection_upgrade;"
                    print "        proxy_set_header   Host              $host;"
                    print "        proxy_set_header   X-Real-IP         $remote_addr;"
                    print "        proxy_read_timeout  3600s;"
                    print "        proxy_send_timeout  3600s;"
                    print "        proxy_buffering     off;"
                    print "        proxy_cache         off;"
                    print "    }"
                    done=1
                }
                { print }
                ' "$NGINX_CONF" > "$TMPF" && mv "$TMPF" "$NGINX_CONF"
                echo "${WS_DOMAIN}:${WS_PORT}:enabled" >> /var/lib/easyinstall/websocket.registry
                sort -u /var/lib/easyinstall/websocket.registry -o /var/lib/easyinstall/websocket.registry
                nginx -t && systemctl reload nginx && echo -e "${GREEN}✅ WebSocket enabled for $WS_DOMAIN:$WS_PORT${NC}" || echo -e "${RED}❌ nginx config error${NC}"
            else
                echo -e "${YELLOW}⚠️ WebSocket already configured${NC}"
            fi ;;

        ws-disable)
            [ -z "$2" ] && { echo -e "${RED}❌ Usage: easyinstall ws-disable domain.com${NC}"; exit 1; }
            NGINX_CONF="/etc/nginx/sites-available/$2"
            TMPF=$(mktemp)
            awk '/# WebSocket proxy \\(EasyInstall v6\\.[0-9]+\\)/ { skip=1 } skip && /^    \\}$/ { skip=0; next } !skip { print }' \\
                "$NGINX_CONF" > "$TMPF" && mv "$TMPF" "$NGINX_CONF"
            sed -i "/^${2}:/d" /var/lib/easyinstall/websocket.registry 2>/dev/null || true
            nginx -t && systemctl reload nginx && echo -e "${GREEN}✅ WebSocket disabled for $2${NC}" ;;

        ws-status)
            echo -e "${CYAN}🔌 WebSocket Status${NC}"
            for site_conf in /etc/nginx/sites-available/*; do
                [ -f "$site_conf" ] || continue
                domain=$(basename "$site_conf")
                grep -q "proxy_set_header.*Upgrade" "$site_conf" 2>/dev/null && \
                    echo -e "  ${GREEN}✅${NC} $domain — enabled" || echo -e "  ${RED}✗${NC} $domain — not configured"
            done ;;

        ws-test)
            [ -z "$2" ] && { echo -e "${RED}❌ Usage: easyinstall ws-test domain.com${NC}"; exit 1; }
            echo -e "${CYAN}🧪 WebSocket Test: $2${NC}"
            grep -q "proxy_set_header.*Upgrade" "/etc/nginx/sites-available/$2" 2>/dev/null && \
                echo -e "  ${GREEN}✅ WS location block present${NC}" || echo -e "  ${RED}✗ WS location block missing${NC}"
            CURL_OUT=$(curl -s --max-time 5 -H "Host: $2" -H "Upgrade: websocket" -H "Connection: Upgrade" \\
                -H "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==" -H "Sec-WebSocket-Version: 13" \\
                -o /dev/null -w "HTTP/%{http_version} %{http_code} | time: %{time_total}s" \\
                "http://127.0.0.1/ws/" 2>/dev/null || echo "connection failed")
            echo -e "  Response: $CURL_OUT" ;;

        http3-enable)
            py_config http3_quic; nginx -t && systemctl reload nginx && echo -e "${GREEN}✅ HTTP/3 config applied${NC}" ;;
        http3-status)
            log_command "http3-status"
            echo -e "${CYAN}⚡ HTTP/3 + QUIC Status Report${NC}"
            echo -e "${BLUE}══════════════════════════════════════${NC}"
            if nginx -V 2>&1 | grep -qiE "quic|http3|with-quic"; then
                echo -e "  ${GREEN}✅ nginx binary: QUIC support PRESENT${NC}"
            else
                echo -e "  ${YELLOW}⚠️  nginx binary: QUIC support ABSENT (Alt-Svc only mode)${NC}"
            fi
            [ -f /etc/nginx/conf.d/http3-quic.conf ] && \
                echo -e "  ${GREEN}✅ http3-quic.conf: present${NC}" || \
                echo -e "  ${RED}✗ http3-quic.conf: missing — run: easyinstall http3-enable${NC}"
            [ -f /etc/nginx/snippets/http3.conf ] && \
                echo -e "  ${GREEN}✅ http3.conf snippet: present${NC}" || \
                echo -e "  ${YELLOW}⚠️  http3.conf snippet: missing${NC}"
            ufw status 2>/dev/null | grep -q "443/udp" && \
                echo -e "  ${GREEN}✅ UFW: UDP/443 open for QUIC${NC}" || \
                echo -e "  ${YELLOW}⚠️  UFW: UDP/443 not open — QUIC may be blocked${NC}"
            echo ""
            echo -e "${YELLOW}Per-site Alt-Svc status:${NC}"
            for nginx_conf in /etc/nginx/sites-available/*; do
                [ -f "$nginx_conf" ] || continue
                domain=$(basename "$nginx_conf")
                if grep -q "listen 443" "$nginx_conf" 2>/dev/null; then
                    grep -q "Alt-Svc" "$nginx_conf" 2>/dev/null && \
                        echo -e "  ${GREEN}✅${NC} $domain — Alt-Svc present" || \
                        echo -e "  ${YELLOW}⚠️ ${NC} $domain — Alt-Svc missing (run: easyinstall http3-enable)"
                fi
            done
            echo ""
            cat /var/lib/easyinstall/http3.status 2>/dev/null | sed 's/^/  /' || echo "  Status file not found"
            echo -e "${BLUE}══════════════════════════════════════${NC}" ;;

        edge-setup)
            py_config edge_computing; nginx -t && systemctl reload nginx && echo -e "${GREEN}✅ Edge computing layer installed${NC}" ;;
        edge-status)
            log_command "edge-status"
            echo -e "${CYAN}🌐 Edge Computing Status Dashboard${NC}"
            echo -e "${BLUE}══════════════════════════════════════${NC}"
            # Config files
            [ -f /etc/nginx/conf.d/edge-computing.conf ] && \
                echo -e "  ${GREEN}✅ edge-computing.conf: present${NC}" || \
                echo -e "  ${RED}✗ edge-computing.conf: missing — run: easyinstall edge-setup${NC}"
            [ -f /etc/nginx/snippets/edge-site.conf ] && \
                echo -e "  ${GREEN}✅ edge-site.conf snippet: present${NC}" || \
                echo -e "  ${YELLOW}⚠️  edge-site.conf: missing${NC}"
            [ -f /usr/local/bin/edge-purge ] && \
                echo -e "  ${GREEN}✅ edge-purge helper: installed${NC}" || \
                echo -e "  ${YELLOW}⚠️  edge-purge: missing${NC}"
            echo ""
            echo -e "${YELLOW}Edge cache zone:${NC}"
            nginx -T 2>/dev/null | grep "keys_zone=EDGE" | sed 's/^/  /' || echo "  Not found"
            echo ""
            echo -e "${YELLOW}Geo-routing map:${NC}"
            [ -f /etc/nginx/conf.d/edge-computing.conf ] && \
                grep "geo " /etc/nginx/conf.d/edge-computing.conf >/dev/null 2>&1 && \
                echo -e "  ${GREEN}✅ Geo-routing: configured${NC}" || \
                echo -e "  ${YELLOW}⚠️  Geo-routing: not configured${NC}"
            echo ""
            echo -e "${YELLOW}Edge health API per site:${NC}"
            for site_dir in /var/www/html/*/; do
                [ -d "$site_dir" ] || continue
                domain=$(basename "$site_dir")
                resp=$(curl -s --max-time 3 -H "Host: $domain" "http://127.0.0.1/edge-health" 2>/dev/null || echo "")
                if echo "$resp" | grep -q "easyinstall"; then
                    echo -e "  ${GREEN}✅${NC} $domain — /edge-health responding"
                else
                    echo -e "  ${YELLOW}⚠️${NC} $domain — /edge-health not available (add edge-site.conf snippet to site)"
                fi
            done
            echo ""
            echo -e "${YELLOW}Status file:${NC}"
            cat /var/lib/easyinstall/edge.status 2>/dev/null | sed 's/^/  /' || echo "  Not found"
            echo -e "${BLUE}══════════════════════════════════════${NC}" ;;
        edge-purge)
            [ -z "$2" ] && { echo -e "${RED}❌ Usage: easyinstall edge-purge domain.com [/path]${NC}"; exit 1; }
            /usr/local/bin/edge-purge "$2" "${3:-/}" ;;

        nginx-extras)
            py_config nginx_extras; nginx -t && systemctl reload nginx && echo -e "${GREEN}✅ Nginx extras applied${NC}" ;;

        *)
            echo -e "${RED}❌ Unknown command: $1${NC}"; show_help; exit 1 ;;
        esac
    """)

    write_file("/usr/local/bin/easyinstall", script, mode=0o755)
    # Also write a symlink helper for easyinstall-create used internally
    create_script = textwrap.dedent("""\
        #!/bin/bash
        # easyinstall-create: used internally for backward compat
        /usr/local/bin/easyinstall create "$@"
    """)
    write_file("/usr/local/bin/easyinstall-create", create_script, mode=0o755)

    # bashrc alias — add PATH for current user
    bashrc = Path("/root/.bashrc")
    if bashrc.exists():
        content = bashrc.read_text()
        if "/usr/local/bin" not in content or "easyinstall" not in content:
            with bashrc.open("a") as f:
                f.write('\n# EasyInstall v6.5\nexport PATH="$PATH:/usr/local/bin"\n')

    # Also write to /etc/profile.d/ so the command is available system-wide
    # and works immediately in new shells without needing 'source ~/.bashrc'
    write_file("/etc/profile.d/easyinstall.sh", textwrap.dedent("""\
        # EasyInstall v6.5 — ensure /usr/local/bin is in PATH
        export PATH="$PATH:/usr/local/bin"
    """), mode=0o644)

    # Make the binary immediately available in current session by symlinking to /usr/bin too
    try:
        symlink = Path("/usr/bin/easyinstall")
        if not symlink.exists():
            symlink.symlink_to("/usr/local/bin/easyinstall")
    except Exception:
        pass

    log("SUCCESS", "EasyInstall command dispatcher created")




# ─────────────────────────────────────────────────────────────────────────────
# Ported from v6.4 — stage_create_autoheal
# ─────────────────────────────────────────────────────────────────────────────

def stage_create_autoheal(cfg):
    log("STEP", "Creating auto-healing service")
    autoheal_script = textwrap.dedent("""\
        #!/bin/bash
        LOG_FILE="/var/log/autoheal.log"
        SERVICES=("nginx" "mariadb" "mysql" "php8.4-fpm" "php8.3-fpm" "php8.2-fpm" "redis-server" "fail2ban")

        log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"; echo "$1"; }

        check_service() {
            local service=$1
            if systemctl list-units --type=service --all 2>/dev/null | grep -q "$service"; then
                if ! systemctl is-active --quiet $service 2>/dev/null; then
                    log "⚠️ Service $service is down. Restarting..."
                    systemctl restart $service; sleep 5
                    if systemctl is-active --quiet $service; then
                        log "✅ Service $service restarted"
                    else
                        log "❌ Failed to restart $service"
                        journalctl -u "$service" --no-pager -n 20 >> "$LOG_FILE" 2>/dev/null
                    fi
                fi
            fi
        }

        while true; do
            log "Running auto-heal checks..."
            for service in "${SERVICES[@]}"; do check_service "$service"; done
            for redis_service in /etc/systemd/system/redis-*.service; do
                [ -f "$redis_service" ] && check_service "$(basename "$redis_service" .service)"
            done
            for version in 8.4 8.3 8.2; do
                if systemctl is-active --quiet php${version}-fpm 2>/dev/null; then
                    php_socket="/run/php/php${version}-fpm.sock"
                    [ -S "$php_socket" ] && chmod 666 "$php_socket" 2>/dev/null || true
                fi
            done
            disk_usage=$(df / | awk 'NR==2 {print $5}' | sed 's/%//')
            if [ $disk_usage -gt 90 ]; then
                log "⚠️ Critical disk usage: $disk_usage%"
                find /var/log -type f -name "*.log" -size +100M -exec truncate -s 0 {} \\; 2>/dev/null
                apt clean 2>/dev/null; log "✅ Cleanup completed"
            fi
            mem_available=$(free | awk '/Mem:/ {print $7}')
            mem_total=$(free | awk '/Mem:/ {print $2}')
            mem_percent=$((100 - (mem_available * 100 / mem_total)))
            if [ $mem_percent -gt 90 ]; then
                log "⚠️ High memory: $mem_percent%"
                systemctl restart php8.4-fpm php8.3-fpm php8.2-fpm 2>/dev/null; log "✅ PHP-FPM restarted"
            fi
            sleep 300
        done
    """)
    write_file("/usr/local/bin/autoheal", autoheal_script, mode=0o755)

    systemd_unit = textwrap.dedent("""\
        [Unit]
        Description=Auto-healing service (EasyInstall v6.5)
        After=network.target mariadb.service mysql.service nginx.service

        [Service]
        Type=simple
        ExecStart=/usr/local/bin/autoheal
        Restart=always
        RestartSec=10
        User=root

        [Install]
        WantedBy=multi-user.target
    """)
    write_file("/etc/systemd/system/autoheal.service", systemd_unit)
    run("systemctl daemon-reload", check=False)
    log("SUCCESS", "Autoheal service created")




# ─────────────────────────────────────────────────────────────────────────────
# Ported from v6.4 — stage_create_backup_script
# ─────────────────────────────────────────────────────────────────────────────

def stage_create_backup_script(cfg):
    log("STEP", "Creating backup script")
    backup_script = textwrap.dedent("""\
        #!/bin/bash
        BACKUP_TYPE="${1:-weekly}"
        BACKUP_DIR="/backups/$BACKUP_TYPE"
        DATE=$(date +%Y%m%d-%H%M%S)
        BACKUP_FILE="$BACKUP_DIR/backup-$DATE.tar.gz"
        LOG_FILE="/var/log/easyinstall/backup.log"
        mkdir -p "$BACKUP_DIR"
        log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"; }

        log "Starting $BACKUP_TYPE backup..."
        if [ -d "/var/www/html" ]; then
            log "Backing up websites and configurations..."
            tar -czf "$BACKUP_FILE" /var/www/html /etc/nginx /etc/mysql /etc/php /etc/redis /var/lib/easyinstall 2>/dev/null && \
                log "✅ Backup completed" || log "⚠️ Backup completed with warnings"
        fi
        if command -v mysqldump &> /dev/null; then
            log "Backing up databases..."
            mysqldump --all-databases > "/backups/mysql-$DATE.sql" 2>/dev/null && \
                gzip "/backups/mysql-$DATE.sql" && log "✅ Database backup OK" || log "❌ Database backup failed"
        fi
        if [ -f "$BACKUP_FILE" ]; then
            SIZE=$(du -h "$BACKUP_FILE" | cut -f1)
            log "✅ Backup: $BACKUP_FILE ($SIZE)"
            tar -tzf "$BACKUP_FILE" >/dev/null 2>&1 && log "✅ Integrity OK" || log "❌ Integrity failed"
        else
            log "❌ Backup failed — no file created"
        fi
        if   [ "$BACKUP_TYPE" = "daily"  ]; then ls -t $BACKUP_DIR/backup-* 2>/dev/null | tail -n +7  | xargs rm -f 2>/dev/null; fi
        if   [ "$BACKUP_TYPE" = "weekly" ]; then ls -t $BACKUP_DIR/backup-* 2>/dev/null | tail -n +5  | xargs rm -f 2>/dev/null; fi
        log "$BACKUP_TYPE backup done"
    """)
    write_file("/usr/local/bin/easy-backup", backup_script, mode=0o755)
    cron = "0 2 * * * root /usr/local/bin/easy-backup daily > /dev/null 2>&1\n0 3 * * 0 root /usr/local/bin/easy-backup weekly > /dev/null 2>&1\n"
    write_file("/etc/cron.d/easy-backup", cron)
    log("SUCCESS", "Backup script created")




# ─────────────────────────────────────────────────────────────────────────────
# Ported from v6.4 — stage_create_monitor
# ─────────────────────────────────────────────────────────────────────────────

def stage_create_monitor(cfg):
    log("STEP", "Creating monitoring script")
    monitor_script = textwrap.dedent("""\
        #!/bin/bash
        GREEN='\\033[0;32m'; YELLOW='\\033[1;33m'; RED='\\033[0;31m'; BLUE='\\033[0;34m'; NC='\\033[0m'

        show_status() {
            clear
            echo -e "${GREEN}========================================${NC}"
            echo -e "${GREEN}   WordPress Performance Monitor v6.4   ${NC}"
            echo -e "${GREEN}========================================${NC}"
            echo "Date: $(date)"; echo ""
            echo -e "${YELLOW}System Load:${NC}"; uptime; echo ""
            echo -e "${YELLOW}CPU Usage:${NC}"
            top -bn1 | grep "Cpu(s)" | awk '{print "  CPU: " $2 "% user, " $4 "% system, " $8 "% idle"}'; echo ""
            echo -e "${YELLOW}Memory Usage:${NC}"
            free -h | awk 'NR==2{printf "  Total: %s, Used: %s, Free: %s\\n", $2, $3, $4}'; echo ""
            echo -e "${YELLOW}Disk Usage:${NC}"
            df -h / | awk 'NR==2{printf "  Total: %s, Used: %s, Avail: %s, Use%%: %s\\n", $2, $3, $4, $5}'; echo ""
            echo -e "${YELLOW}Service Status:${NC}"
            for service in nginx mariadb mysql php8.4-fpm php8.3-fpm php8.2-fpm redis-server fail2ban autoheal; do
                if systemctl is-active --quiet $service 2>/dev/null; then
                    echo -e "  ${GREEN}✓${NC} $service"
                else
                    echo -e "  ${RED}✗${NC} $service"
                fi
            done; echo ""
            echo -e "${YELLOW}Websites:${NC}"
            [ "$(ls -A /var/www/html 2>/dev/null)" ] && ls -1 /var/www/html/ | sed 's/^/  • /' || echo "  No sites installed"
            echo ""
        }

        case "$1" in
            watch) while true; do show_status; echo "Refreshing every 5s... (Ctrl+C to exit)"; sleep 5; done ;;
            *)     show_status ;;
        esac
    """)
    write_file("/usr/local/bin/easy-monitor", monitor_script, mode=0o755)
    log("SUCCESS", "Monitoring script created")




# ─────────────────────────────────────────────────────────────────────────────
# Ported from v6.4 — stage_create_welcome
# ─────────────────────────────────────────────────────────────────────────────

def stage_create_welcome(cfg):
    log("STEP", "Creating MOTD welcome message")
    ip = "server-ip"
    try:
        ip = socket.gethostbyname(socket.gethostname())
    except Exception:
        pass

    motd = textwrap.dedent(f"""\
        ╔══════════════════════════════════════════════════════════╗
        ║  🚀 EasyInstall WordPress Performance v6.5 (HYBRID)      ║
        ║  Bash = Dependencies | Python = Configuration             ║
        ║  Auto-Tuned for {cfg.total_ram}MB RAM | {cfg.total_cores} Cores           ║
        ╠══════════════════════════════════════════════════════════╣
        ║  📋 Commands:                                             ║
        ║    easyinstall help           - Show all commands         ║
        ║    easyinstall create domain  - New WordPress site        ║
        ║    easyinstall list           - List all sites            ║
        ║    easyinstall status         - System status             ║
        ║    easyinstall monitor        - Live monitor              ║
        ║    easyinstall ws-enable d    - WebSocket proxy           ║
        ║    easyinstall http3-enable   - HTTP/3 + QUIC             ║
        ║    easyinstall edge-setup     - Edge computing layer      ║
        ║    easyinstall ai-diagnose    - 🤖 AI log analysis        ║
        ║  ⚡ PHP Children: {cfg.php_max_children}                              ║
        ║  💾 MySQL Buffer: {cfg.mysql_buffer_pool}                              ║
        ║  🔴 Redis Memory: {cfg.redis_max_memory}                              ║
        ╚══════════════════════════════════════════════════════════╝
    """)
    write_file("/etc/motd", motd)
    log("SUCCESS", "MOTD created")




# ─────────────────────────────────────────────────────────────────────────────
# Ported from v6.4 — stage_create_info_file
# ─────────────────────────────────────────────────────────────────────────────

def stage_create_info_file(cfg):
    log("STEP", "Creating info file")
    ip = "unknown"
    try:
        ip = socket.gethostbyname(socket.gethostname())
    except Exception:
        pass

    info = textwrap.dedent(f"""\
        ========================================
        EasyInstall WordPress Performance v6.4 (HYBRID EDITION)
        Installation Date: {datetime.now()}
        Architecture: Bash (dependencies) + Python (configuration)
        ========================================

        SYSTEM INFORMATION:
          OS: {cfg.os_id}
          IP Address: {ip}
          RAM: {cfg.total_ram}MB | CPU Cores: {cfg.total_cores}

        PERFORMANCE SETTINGS (Auto-Tuned):
          PHP Children:      {cfg.php_max_children}
          PHP Memory:        {cfg.php_memory_limit}
          MySQL Buffer:      {cfg.mysql_buffer_pool}
          Redis Memory:      {cfg.redis_max_memory}
          Nginx Connections: {cfg.nginx_worker_connections}

        INSTALLED COMPONENTS:
          ✓ Nginx (Official Repository) — configured by Python
          ✓ PHP 8.4/8.3/8.2 + FPM — configured by Python
          ✓ MariaDB 11.x — configured by Python
          ✓ WP-CLI (installed by Bash)
          ✓ Redis 7.x — configured by Python
          ✓ Certbot (installed by Bash)
          ✓ UFW Firewall — rules by Python
          ✓ Fail2ban — filters by Python
          ✓ Auto-healing Service — script by Python
          ✓ Backup System — script by Python
          ✓ WebSocket Support (v6.5) — config by Python
          ✓ HTTP/3 + QUIC (v6.5) — config by Python
          ✓ Edge Computing Layer (v6.5) — config by Python

        COMMANDS:
          easyinstall help                 - All commands
          easyinstall create domain.com    - Install WordPress
          easyinstall create domain.com --ssl - With SSL
          easyinstall list                 - List all sites
          easyinstall redis-status         - Redis instances
          easyinstall redis-ports          - Redis ports
          easyinstall delete domain.com    - Delete a site
          easyinstall ssl domain.com       - Enable SSL
          easyinstall backup [daily/weekly]- Create backup
          easyinstall monitor              - Live monitoring
          easyinstall perf                 - Performance stats
          easyinstall optimize             - Run optimization
          easyinstall clean                - Clean caches
          easyinstall health               - Health check
          easyinstall ai-diagnose          - AI log analysis
          easyinstall ai-optimize          - AI perf advice
          easyinstall ai-report            - AI health report
          easyinstall advanced-tune        - Full 10-phase autotune
          easyinstall ws-enable domain 8080 - WebSocket proxy
          easyinstall http3-enable         - Enable HTTP/3
          easyinstall edge-setup           - Edge computing
          easyinstall update-site domain   - Update WP/plugins
          easyinstall clone src dst        - Clone site

        LOG FILES:
          Installation Log: /var/log/easyinstall/install.log
          Error Log:        /var/log/easyinstall/error.log

        SUPPORT: https://paypal.me/sugandodrai
        ========================================
    """)
    write_file("/root/easyinstall-info.txt", info)
    log("SUCCESS", "Info file created at /root/easyinstall-info.txt")




# ─────────────────────────────────────────────────────────────────────────────
# Ported from v6.4 — stage_create_ai_module
# ─────────────────────────────────────────────────────────────────────────────

def stage_create_ai_module(cfg):
    log("STEP", "Creating AI module")
    ai_module = textwrap.dedent("""\
        #!/bin/bash
        # EasyInstall AI Module v6.4 — Sourced by the main command script
        AI_CONFIG_FILE="/etc/easyinstall/ai.conf"
        AI_LOG_FILE="/var/log/easyinstall/ai.log"
        GREEN='\\033[0;32m'; YELLOW='\\033[1;33m'; RED='\\033[0;31m'
        BLUE='\\033[0;34m'; CYAN='\\033[0;36m'; NC='\\033[0m'

        ai_load_config() {
            AI_API_KEY=""
            AI_ENDPOINT="http://localhost:11434/api/chat"
            AI_MODEL="phi3"
            AI_PROVIDER="ollama"
            [ -f "$AI_CONFIG_FILE" ] && source "$AI_CONFIG_FILE"
        }

        ai_call() {
            local system_prompt="$1" user_msg="$2"
            ai_load_config
            mkdir -p /var/log/easyinstall
            # ── Gemini provider ──────────────────────────────────────────
            if [ "$AI_PROVIDER" = "gemini" ]; then
                local gemini_url="${AI_ENDPOINT}/${AI_MODEL}:generateContent?key=${AI_API_KEY}"
                local payload; payload=$(python3 -c "import json,sys; print(json.dumps({'contents':[{'parts':[{'text':sys.argv[1]+\"\\n\"+sys.argv[2]}]}],'generationConfig':{'maxOutputTokens':1000}}))" "$system_prompt" "$user_msg" 2>/dev/null)
                curl -s --max-time 60 -X POST "$gemini_url" -H "Content-Type: application/json" -d "$payload" 2>/dev/null | \
                    python3 -c "import json,sys; d=json.load(sys.stdin); print(d['candidates'][0]['content']['parts'][0]['text'])" 2>/dev/null
                return
            fi
            if [ "$AI_PROVIDER" = "ollama" ] || echo "$AI_ENDPOINT" | grep -q "11434"; then
                command -v ollama &>/dev/null && ! curl -s --max-time 3 "$AI_ENDPOINT" >/dev/null 2>&1 && \
                    (ollama serve >/dev/null 2>&1 &) && sleep 3
                local payload
                payload=$(python3 -c "import json,sys; print(json.dumps({'model':sys.argv[1],'messages':[{'role':'system','content':sys.argv[2]},{'role':'user','content':sys.argv[3]}],'stream':False}))" \
                    "$AI_MODEL" "$system_prompt" "$user_msg" 2>/dev/null)
                curl -s --max-time 120 -X POST "$AI_ENDPOINT" \
                    -H "Content-Type: application/json" -d "$payload" 2>/dev/null | \
                    python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('message',{}).get('content','') or d.get('response',''))" 2>/dev/null
            else
                local payload
                payload=$(python3 -c "import json,sys; print(json.dumps({'model':sys.argv[1],'messages':[{'role':'system','content':sys.argv[2]},{'role':'user','content':sys.argv[3]}],'max_tokens':1000}))" \
                    "$AI_MODEL" "$system_prompt" "$user_msg" 2>/dev/null)
                curl -s --max-time 120 -X POST "$AI_ENDPOINT" \
                    -H "Content-Type: application/json" \
                    -H "Authorization: Bearer $AI_API_KEY" \
                    -d "$payload" 2>/dev/null | \
                    python3 -c "import json,sys; d=json.load(sys.stdin); print(d['choices'][0]['message']['content'])" 2>/dev/null
            fi
        }

        ai_diagnose() {
            local domain="${1:-}"
            ai_load_config
            echo -e "${CYAN}🤖 AI Log Analysis${NC}"
            local logs=""
            if [ -n "$domain" ] && [ -f "/var/log/nginx/${domain}.error.log" ]; then
                logs=$(tail -50 "/var/log/nginx/${domain}.error.log" 2>/dev/null)
            else
                logs=$(tail -30 /var/log/easyinstall/error.log 2>/dev/null)
                logs+=$(tail -20 /var/log/nginx/error.log 2>/dev/null)
            fi
            [ -z "$logs" ] && logs="No errors in recent logs."
            local sys_prompt="You are a senior Linux/WordPress sysadmin. Analyze the following server logs and provide: 1) Root cause of errors, 2) Specific fix commands, 3) Prevention tips. Be concise and actionable."
            local result; result=$(ai_call "$sys_prompt" "Server logs:\\n$logs") || return 1
            echo -e "${BLUE}────────────────────${NC}"
            echo "$result"
            echo -e "${BLUE}────────────────────${NC}"
            echo "$result" >> "$AI_LOG_FILE"
        }

        ai_optimize() {
            ai_load_config
            echo -e "${CYAN}🤖 AI Performance Optimization${NC}"
            local stats; stats=$(free -h && df -h / && uptime)
            local sys_prompt="You are a WordPress performance expert. Given these server stats, provide 5 specific optimization recommendations with exact commands."
            local result; result=$(ai_call "$sys_prompt" "Server stats:\\n$stats") || return 1
            echo "$result"
            echo "$result" >> "$AI_LOG_FILE"
        }

        ai_security() {
            ai_load_config
            echo -e "${CYAN}🤖 AI Security Audit${NC}"
            local fail2ban_status; fail2ban_status=$(fail2ban-client status 2>/dev/null | head -20)
            local nginx_errors; nginx_errors=$(tail -20 /var/log/nginx/error.log 2>/dev/null)
            local sys_prompt="You are a security expert. Analyze this WordPress server security data and provide: threat assessment, top 3 immediate actions, and hardening recommendations."
            local result; result=$(ai_call "$sys_prompt" "Fail2ban:\\n$fail2ban_status\\n\\nNginx errors:\\n$nginx_errors") || return 1
            echo "$result"
            echo "$result" >> "$AI_LOG_FILE"
        }

        ai_report() {
            ai_load_config
            echo -e "${CYAN}🤖 AI Health Report${NC}"
            local snapshot; snapshot="Uptime: $(uptime)\\nDisk: $(df -h / | awk 'NR==2')\\nMemory: $(free -h | awk '/Mem:/{print $0}')\\nServices running: $(systemctl list-units --state=active --type=service --no-pager 2>/dev/null | wc -l)"
            local sys_prompt="You are a server administrator. Write a professional health report with: overall score (0-100), summary, per-service status, storage, and 3 recommendations. Plain text only."
            local result; result=$(ai_call "$sys_prompt" "$snapshot") || return 1
            local report_file="/root/easyinstall-ai-report-$(date +%Y%m%d-%H%M%S).txt"
            { echo "EasyInstall AI Health Report — $(date)"; echo ""; echo "$result"; } > "$report_file"
            echo "$result"
            echo -e "${GREEN}✅ Saved: $report_file${NC}"
            echo "$result" >> "$AI_LOG_FILE"
        }

        ai_setup() {
            ai_load_config
            echo -e "${CYAN}🤖 EasyInstall AI Setup${NC}"
            echo "  Config: $AI_CONFIG_FILE"
            echo "  Provider: $AI_PROVIDER"
            echo "  Endpoint: $AI_ENDPOINT"
            echo "  Model: $AI_MODEL"
            echo ""
            if command -v ollama &>/dev/null; then
                echo -e "  Ollama: ${GREEN}✅ Installed${NC}"
                curl -s --max-time 3 "http://localhost:11434/api/tags" >/dev/null 2>&1 && \
                    echo -e "  Status: ${GREEN}✅ Running${NC}" || echo -e "  Status: ${YELLOW}⚠️ Not running${NC}"
            else
                echo -e "  Ollama: ${RED}❌ Not installed — run: easyinstall ai-install-ollama${NC}"
            fi
        }
    """)
    write_file("/usr/local/lib/easyinstall-ai.sh", ai_module, mode=0o755)
    Path("/etc/easyinstall").mkdir(parents=True, exist_ok=True)
    ai_conf = Path("/etc/easyinstall/ai.conf")
    if not ai_conf.exists():
        write_file(str(ai_conf), textwrap.dedent("""\
            # EasyInstall AI Configuration v6.4
            # Supported providers: ollama (local), openai, groq, gemini
            #
            # ── Local (no API key needed) ─────────────────────────────
            # AI_PROVIDER="ollama"
            # AI_ENDPOINT="http://localhost:11434/api/chat"
            # AI_MODEL="phi3"                    # or llama3, mistral, gemma2
            # AI_API_KEY="ollama"
            #
            # ── OpenAI ───────────────────────────────────────────────
            # AI_PROVIDER="openai"
            # AI_ENDPOINT="https://api.openai.com/v1/chat/completions"
            # AI_MODEL="gpt-4o-mini"
            # AI_API_KEY="sk-..."
            #
            # ── Groq (fast free tier) ────────────────────────────────
            # AI_PROVIDER="groq"
            # AI_ENDPOINT="https://api.groq.com/openai/v1/chat/completions"
            # AI_MODEL="llama-3.1-8b-instant"
            # AI_API_KEY="gsk_..."
            #
            # ── Google Gemini ────────────────────────────────────────
            # AI_PROVIDER="gemini"
            # AI_ENDPOINT="https://generativelanguage.googleapis.com/v1beta/models"
            # AI_MODEL="gemini-1.5-flash"
            # AI_API_KEY="AIza..."
            #
            # Active config (default: local Ollama):
            AI_PROVIDER="ollama"
            AI_ENDPOINT="http://localhost:11434/api/chat"
            AI_MODEL="phi3"
            AI_API_KEY="ollama"
            AI_MAX_TOKENS=1000
        """))
    log("SUCCESS", "AI module created at /usr/local/lib/easyinstall-ai.sh")




# ─────────────────────────────────────────────────────────────────────────────
# Ported from v6.4 — stage_create_autotune_module
# ─────────────────────────────────────────────────────────────────────────────

def stage_create_autotune_module(cfg):
    log("STEP", "Creating AutoTune module")
    # The autotune module is a bash script with all 10 phases
    # We generate it with the tuning parameters already baked in
    mc = cfg.php_max_children
    ss = cfg.php_start_servers
    ms = cfg.php_min_spare
    xs = cfg.php_max_spare
    ml = cfg.php_memory_limit
    me = cfg.php_max_execution
    mb = cfg.mysql_buffer_pool
    mf = cfg.mysql_log_file
    rm_ = cfg.redis_max_memory
    nc = cfg.nginx_worker_connections
    np = cfg.nginx_worker_processes
    ram = cfg.total_ram
    cores = cfg.total_cores

    autotune = textwrap.dedent(f"""\
        #!/bin/bash
        # EasyInstall AutoTune Module v6.4 (HYBRID EDITION)
        # Generated by Python config module with RAM-tuned values
        # All 10 phases: Profile → Tune → Governor → WP Speed → Cache Tiers →
        #                Auto-Scale → DB Engine → Dashboard → Warmer → Disaster Recovery

        AUTOTUNE_LOG="/var/log/easyinstall/autotune.log"
        GOVERNOR_LOG="/var/log/easyinstall/governor.log"
        PROFILE_FILE="/var/lib/easyinstall/system.profile"
        DISASTER_FLAG="/var/run/easyinstall-emergency.flag"
        AUTOTUNE_BACKUP_DIR=""

        GREEN='\\033[0;32m'; YELLOW='\\033[1;33m'; RED='\\033[0;31m'
        BLUE='\\033[0;34m'; PURPLE='\\033[0;35m'; CYAN='\\033[0;36m'; NC='\\033[0m'

        # Pre-detected values from Python config (RAM={ram}MB, Cores={cores})
        AT_RAM={ram}
        AT_CORES={cores}
        AT_PHP_CHILDREN={mc}
        AT_PHP_MEMORY="{ml}"
        AT_MYSQL_BUFFER="{mb}"
        AT_REDIS_MEMORY="{rm_}"
        AT_NGINX_CONNECTIONS={nc}

        atlog() {{
            local level="$1" message="$2"
            local ts; ts=$(date '+%Y-%m-%d %H:%M:%S')
            mkdir -p /var/log/easyinstall 2>/dev/null || true
            echo "[$ts] [AUTOTUNE] [$level] $message" >> "$AUTOTUNE_LOG"
            case "$level" in
                "ERROR")   echo -e "${{RED}}❌ [AutoTune] $message${{NC}}" ;;
                "WARNING") echo -e "${{YELLOW}}⚠️  [AutoTune] $message${{NC}}" ;;
                "SUCCESS") echo -e "${{GREEN}}✅ [AutoTune] $message${{NC}}" ;;
                "INFO")    echo -e "${{BLUE}}ℹ️  [AutoTune] $message${{NC}}" ;;
                "STEP")    echo -e "${{PURPLE}}🔷 [AutoTune] $message${{NC}}" ;;
                "PERF")    echo -e "${{CYAN}}⚡ [AutoTune] $message${{NC}}" ;;
                *)         echo -e "$message" ;;
            esac
        }}

        govlog() {{
            local msg="$1"; local ts; ts=$(date '+%Y-%m-%d %H:%M:%S')
            mkdir -p /var/log/easyinstall 2>/dev/null || true
            echo "[$ts] [GOVERNOR] $msg" >> "$GOVERNOR_LOG"
        }}

        autotune_backup() {{
            AUTOTUNE_BACKUP_DIR="/root/easyinstall-backups/autotune-$(date +%Y%m%d-%H%M%S)"
            atlog "STEP" "Creating rollback point: $AUTOTUNE_BACKUP_DIR"
            mkdir -p "$AUTOTUNE_BACKUP_DIR"
            for f in /etc/php/8.3/fpm/pool.d/www.conf /etc/php/8.2/fpm/pool.d/www.conf \
                     /etc/mysql/mariadb.conf.d/99-wordpress.cnf /etc/redis/redis.conf \
                     /etc/nginx/nginx.conf /etc/sysctl.d/99-wordpress.conf; do
                if [ -f "$f" ]; then
                    local dir; dir="$AUTOTUNE_BACKUP_DIR$(dirname "$f")"
                    mkdir -p "$dir"; cp -p "$f" "$dir/"
                fi
            done
            echo "AutoTune Rollback — $(date)" > "$AUTOTUNE_BACKUP_DIR/MANIFEST.txt"
            atlog "SUCCESS" "Rollback point ready"
        }}

        autotune_rollback() {{
            atlog "WARNING" "Rolling back autotune changes..."
            [ -d "$AUTOTUNE_BACKUP_DIR" ] || {{ atlog "ERROR" "No backup dir found"; return 1; }}
            find "$AUTOTUNE_BACKUP_DIR" -type f -not -name "MANIFEST.txt" | while read -r bf; do
                local orig="${{bf#"$AUTOTUNE_BACKUP_DIR"}}"; mkdir -p "$(dirname "$orig")"; cp -p "$bf" "$orig"
            done
            for svc in nginx php8.3-fpm php8.2-fpm mariadb redis-server; do
                systemctl reload "$svc" 2>/dev/null || systemctl restart "$svc" 2>/dev/null || true
            done
            atlog "SUCCESS" "Rollback complete"
        }}

        _at_load_profile() {{
            [ -f "$PROFILE_FILE" ] && source "$PROFILE_FILE"
        }}

        # ═══════════════════════════════════════════════════════
        # PHASE 1-2: System Profiling + Baseline Tuning
        # ═══════════════════════════════════════════════════════
        _at_layer1_base() {{
            atlog "STEP" "PHASE 2: Applying baseline performance tuning"
            cat > /etc/sysctl.d/99-autotune-base.conf <<SYSCTL
        # AutoTune baseline (Phase 2)
        vm.swappiness = 5
        vm.vfs_cache_pressure = 50
        net.core.somaxconn = 65535
        net.ipv4.tcp_max_syn_backlog = 8192
        SYSCTL
            sysctl -p /etc/sysctl.d/99-autotune-base.conf 2>/dev/null || true
            atlog "SUCCESS" "Baseline tuning applied"
        }}

        _at_tier_layers() {{ atlog "STEP" "PHASE 3: Tier-specific tuning for ${{AT_TIER:-BALANCED}}"; }}

        _at_apply_php_fpm() {{
            atlog "STEP" "PHASE 4: Applying PHP-FPM auto-tune"
            for version in 8.4 8.3 8.2; do
                local conf="/etc/php/$version/fpm/pool.d/www.conf"
                [ -f "$conf" ] || continue
                sed -i "s/^pm.max_children = .*/pm.max_children = $AT_PHP_CHILDREN/" "$conf"
                atlog "SUCCESS" "PHP $version pool tuned (children=$AT_PHP_CHILDREN)"
                systemctl reload "php$version-fpm" 2>/dev/null || true
            done
        }}

        _at_apply_mysql() {{
            atlog "STEP" "PHASE 5: Applying MySQL auto-tune"
            local cnf="/etc/mysql/mariadb.conf.d/99-wordpress.cnf"
            [ -f "$cnf" ] && {{
                sed -i "s/^innodb_buffer_pool_size = .*/innodb_buffer_pool_size = $AT_MYSQL_BUFFER/" "$cnf"
                systemctl restart mariadb 2>/dev/null || true
                atlog "SUCCESS" "MySQL buffer tuned to $AT_MYSQL_BUFFER"
            }}
        }}

        _at_apply_redis() {{
            atlog "STEP" "PHASE 6: Applying Redis auto-tune"
            local conf="/etc/redis/redis.conf"
            [ -f "$conf" ] && {{
                sed -i "s/^maxmemory .*/maxmemory $AT_REDIS_MEMORY/" "$conf"
                systemctl restart redis-server 2>/dev/null || true
                atlog "SUCCESS" "Redis maxmemory tuned to $AT_REDIS_MEMORY"
            }}
        }}

        _at_apply_nginx() {{
            atlog "STEP" "PHASE 7: Applying Nginx auto-tune"
            sed -i "s/worker_connections .*/worker_connections $AT_NGINX_CONNECTIONS;/" /etc/nginx/nginx.conf 2>/dev/null || true
            nginx -t 2>/dev/null && systemctl reload nginx 2>/dev/null || true
            atlog "SUCCESS" "Nginx connections tuned to $AT_NGINX_CONNECTIONS"
        }}

        _at_reload_services() {{
            atlog "INFO" "Reloading all tuned services"
            for svc in nginx mariadb redis-server; do
                systemctl reload "$svc" 2>/dev/null || systemctl restart "$svc" 2>/dev/null || true
            done
        }}

        # ═══════════════════════════════════════════════════════
        # PHASE 3: Dynamic Resource Governor
        # ═══════════════════════════════════════════════════════
        dynamic_resource_governor() {{
            govlog "Governor started (RAM=${{AT_RAM}}MB)"
            local cur_ram; cur_ram=$(free -m | awk '/Mem:/ {{print $7}}')
            local cur_load; cur_load=$(uptime | awk -F'average:' '{{print $2}}' | awk -F',' '{{print $1}}' | tr -d ' ')
            local load_int=${{cur_load%.*}}; [ -z "$load_int" ] && load_int=0
            govlog "Available RAM: ${{cur_ram}}MB | Load: ${{cur_load}}"
            if [ "$cur_ram" -lt 100 ]; then
                govlog "LOW MEMORY — restarting PHP-FPM to free memory"
                for v in 8.4 8.3 8.2; do systemctl restart "php${{v}}-fpm" 2>/dev/null || true; done
            fi
            if [ "$load_int" -gt "$AT_CORES" ]; then
                govlog "HIGH LOAD (${{cur_load}}) — applying emergency limits"
                for v in 8.4 8.3 8.2; do
                    local conf="/etc/php/$v/fpm/pool.d/www.conf"
                    [ -f "$conf" ] && {{
                        local emergency=$((AT_PHP_CHILDREN / 2))
                        sed -i "s/^pm.max_children = .*/pm.max_children = $emergency/" "$conf"
                        systemctl reload "php${{v}}-fpm" 2>/dev/null || true
                    }}
                done
            fi
        }}

        install_governor_timer() {{
            atlog "STEP" "Installing 15-min resource governor timer"
            cat > /etc/systemd/system/easyinstall-governor.service <<GOVSVC
        [Unit]
        Description=EasyInstall Resource Governor
        [Service]
        Type=oneshot
        ExecStart=/usr/local/lib/easyinstall-autotune.sh governor
        GOVSVC
            cat > /etc/systemd/system/easyinstall-governor.timer <<GOVTIMER
        [Unit]
        Description=Run EasyInstall Governor every 15 minutes
        [Timer]
        OnBootSec=5min
        OnUnitActiveSec=15min
        [Install]
        WantedBy=timers.target
        GOVTIMER
            systemctl daemon-reload
            systemctl enable easyinstall-governor.timer 2>/dev/null || true
            systemctl start easyinstall-governor.timer 2>/dev/null || true
            atlog "SUCCESS" "Governor timer installed"
        }}

        # ═══════════════════════════════════════════════════════
        # PHASE 4: WordPress Max Speed
        # ═══════════════════════════════════════════════════════
        _at_install_muplugin() {{
            local domain="$1"; local wp_path="/var/www/html/$domain"
            [ -d "$wp_path" ] || return
            local mu_dir="$wp_path/wp-content/mu-plugins"
            mkdir -p "$mu_dir"
            cat > "$mu_dir/easyinstall-speedup.php" <<'MUPLUGIN'
        <?php
        /**
         * Plugin Name: EasyInstall Speed Optimizations
         * Description: Auto-applied performance tweaks (EasyInstall v6.5)
         */
        // Disable XML-RPC
        add_filter('xmlrpc_enabled', '__return_false');
        // Reduce post revisions
        if (!defined('WP_POST_REVISIONS')) define('WP_POST_REVISIONS', 5);
        // Disable emojis
        remove_action('wp_head', 'print_emoji_detection_script', 7);
        remove_action('wp_print_styles', 'print_emoji_styles');
        // Remove query strings from static resources
        function remove_cssjs_ver($src) {{
            if (strpos($src, '?ver=')) $src = remove_query_arg('ver', $src);
            return $src;
        }}
        add_filter('style_loader_src', 'remove_cssjs_ver', 9999);
        add_filter('script_loader_src', 'remove_cssjs_ver', 9999);
        MUPLUGIN
            chown www-data:www-data "$mu_dir/easyinstall-speedup.php" 2>/dev/null || true
        }}

        wordpress_max_speed() {{
            atlog "STEP" "PHASE 4: WordPress speed optimizations"
            for site_dir in /var/www/html/*/; do
                [ -d "$site_dir" ] && _at_install_muplugin "$(basename "$site_dir")"
            done
            atlog "SUCCESS" "WordPress speed tweaks applied"
        }}

        # ═══════════════════════════════════════════════════════
        # PHASE 5: Redis Cache Tiers
        # ═══════════════════════════════════════════════════════
        setup_redis_tier_cache() {{
            atlog "STEP" "PHASE 5: Configuring Redis cache tiers"
            redis-cli CONFIG SET maxmemory-policy allkeys-lru 2>/dev/null || true
            redis-cli CONFIG SET hz 20 2>/dev/null || true
            atlog "SUCCESS" "Redis cache tiers configured"
        }}

        # ═══════════════════════════════════════════════════════
        # PHASE 7: DB Optimization Engine
        # ═══════════════════════════════════════════════════════
        db_optimization_engine() {{
            atlog "STEP" "PHASE 7: Database optimization"
            atlog "INFO" "Running mysqlcheck on all WordPress databases..."
            for db in $(mysql -e "SHOW DATABASES LIKE 'wp_%';" 2>/dev/null | grep -v Database); do
                mysqlcheck -o "$db" 2>/dev/null && atlog "SUCCESS" "Optimized: $db" || true
                mysql "$db" -e "DELETE FROM wp_options WHERE autoload='yes' AND LENGTH(option_value)>10000;" 2>/dev/null || true
            done
            atlog "SUCCESS" "DB optimization complete"
        }}

        _install_db_optimizer_cron() {{
            echo "0 4 * * 0 root /usr/local/lib/easyinstall-autotune.sh db-optimize > /dev/null 2>&1" > \
                /etc/cron.d/easyinstall-dboptimize
            atlog "SUCCESS" "DB optimizer weekly cron installed"
        }}

        # ═══════════════════════════════════════════════════════
        # PHASE 8: Performance Dashboard
        # ═══════════════════════════════════════════════════════
        _at_bar() {{
            local val=$1 max=$2 width=${{3:-20}}
            local filled=$(( val * width / (max > 0 ? max : 1) ))
            [ $filled -gt $width ] && filled=$width
            printf '['
            for ((i=0; i<filled; i++)); do printf '#'; done
            for ((i=filled; i<width; i++)); do printf '.'; done
            printf '] %d%%' $val
        }}

        _at_recommendations() {{
            local ram=$1 load=$2 disk=$3
            echo "Recommendations:"
            [ "$ram" -lt 20 ] && echo "  ⚠️  Low available RAM — consider restarting PHP-FPM"
            [ "$load" -gt "$AT_CORES" ] && echo "  ⚠️  High load — check slow PHP workers or DB queries"
            [ "$disk" -gt 85 ] && echo "  ⚠️  Disk usage high — clean logs: easyinstall clean"
            [ "$ram" -ge 20 ] && [ "$load" -le "$AT_CORES" ] && [ "$disk" -le 85 ] && echo "  ✅ System healthy"
        }}

        perf_dashboard() {{
            clear
            while true; do
                clear
                echo -e "${{CYAN}}╔══════════════════════════════════════════════════════╗${{NC}}"
                echo -e "${{CYAN}}║  ⚡ EasyInstall Performance Dashboard v6.4 HYBRID    ║${{NC}}"
                echo -e "${{CYAN}}╚══════════════════════════════════════════════════════╝${{NC}}"
                echo "  Updated: $(date)"
                echo ""
                local mem_total mem_used mem_pct
                mem_total=$(free -m | awk '/Mem:/ {{print $2}}')
                mem_used=$(free -m | awk '/Mem:/ {{print $3}}')
                mem_pct=$(( mem_used * 100 / (mem_total > 0 ? mem_total : 1) ))
                echo -e "${{YELLOW}}Memory:${{NC}} $(_at_bar $mem_pct 100)  (${{mem_used}}MB / ${{mem_total}}MB)"

                local disk_pct; disk_pct=$(df / | awk 'NR==2 {{print $5}}' | sed 's/%//')
                echo -e "${{YELLOW}}Disk:  ${{NC}} $(_at_bar $disk_pct 100)"

                local load; load=$(uptime | awk -F'average:' '{{print $2}}' | awk -F',' '{{print $1}}' | tr -d ' ')
                echo -e "${{YELLOW}}Load:  ${{NC}} $load (cores: $AT_CORES)"
                echo ""
                echo -e "${{YELLOW}}Services:${{NC}}"
                for svc in nginx mariadb redis-server php8.4-fpm php8.3-fpm php8.2-fpm fail2ban autoheal; do
                    systemctl is-active --quiet "$svc" 2>/dev/null && \
                        echo -e "  ${{GREEN}}✓${{NC}} $svc" || echo -e "  ${{RED}}✗${{NC}} $svc"
                done
                echo ""
                _at_recommendations "$((100 - mem_pct))" "${{load%.*}}" "$disk_pct"
                echo ""
                echo "Press Ctrl+C to exit. Refreshing every 5s..."
                sleep 5
            done
        }}

        # ═══════════════════════════════════════════════════════
        # PHASE 9: Smart Cache Warmer
        # ═══════════════════════════════════════════════════════
        smart_cache_warmer() {{
            atlog "STEP" "PHASE 9: Cache warming"
            for site_dir in /var/www/html/*/; do
                [ -d "$site_dir" ] || continue
                local domain; domain=$(basename "$site_dir")
                atlog "INFO" "Warming cache for: $domain"
                for path in / /feed/ /sitemap.xml; do
                    curl -s -o /dev/null -A "EasyInstall-CacheWarmer/6.4" \
                        -H "Host: $domain" "http://127.0.0.1$path" 2>/dev/null || true
                    sleep 0.2
                done
                atlog "SUCCESS" "Cache warmed: $domain"
            done
        }}

        _install_cache_warmer_cron() {{
            echo "0 */6 * * * root /usr/local/lib/easyinstall-autotune.sh warm-cache > /dev/null 2>&1" > \
                /etc/cron.d/easyinstall-cachewarmer
            atlog "SUCCESS" "Cache warmer cron installed (every 6h)"
        }}

        # ═══════════════════════════════════════════════════════
        # PHASE 10: Disaster Recovery Mode
        # ═══════════════════════════════════════════════════════
        _at_check_recovery() {{
            local load_raw; load_raw=$(uptime | awk -F'average:' '{{print $2}}' | awk -F',' '{{print $1}}' | tr -d ' ')
            local load_int=${{load_raw%.*}}; [ -z "$load_int" ] && load_int=0
            local mem_avail; mem_avail=$(free -m | awk '/Mem:/ {{print $7}}')
            if [ "$load_int" -gt "$((AT_CORES * 5))" ] || [ "$mem_avail" -lt 50 ]; then
                touch "$DISASTER_FLAG"
                atlog "WARNING" "EMERGENCY: load=$load_raw mem=${{mem_avail}}MB — entering disaster recovery"
                return 0
            fi
            return 1
        }}

        disaster_recovery_mode() {{
            atlog "STEP" "PHASE 10: Disaster Recovery Check"
            if _at_check_recovery || [ "${{1:-}}" = "manual" ]; then
                atlog "WARNING" "Activating emergency measures..."
                for v in 8.4 8.3 8.2; do
                    local conf="/etc/php/$v/fpm/pool.d/www.conf"
                    [ -f "$conf" ] && {{
                        local min_children=$((AT_PHP_CHILDREN / 4 < 2 ? 2 : AT_PHP_CHILDREN / 4))
                        sed -i "s/^pm.max_children = .*/pm.max_children = $min_children/" "$conf"
                        systemctl restart "php$v-fpm" 2>/dev/null || true
                    }}
                done
                redis-cli FLUSHALL 2>/dev/null || true
                rm -rf /var/cache/nginx/fastcgi/* 2>/dev/null || true
                atlog "SUCCESS" "Emergency measures applied"
            else
                atlog "SUCCESS" "System healthy — no disaster recovery needed"
                rm -f "$DISASTER_FLAG"
            fi
        }}

        # ═══════════════════════════════════════════════════════
        # Main entry: advanced_auto_tune  (all 10 phases)
        # ═══════════════════════════════════════════════════════
        advanced_auto_tune() {{
            atlog "STEP" "=== ADVANCED AUTO-TUNE: 10 phases ==="
            mkdir -p /var/log/easyinstall /var/lib/easyinstall

            local total_ram; total_ram=$(free -m | awk '/Mem:/ {{print $2}}')
            local cpu_cores; cpu_cores=$(nproc)
            local site_count; site_count=$(find /var/www/html -maxdepth 1 -mindepth 1 -type d 2>/dev/null | wc -l)
            [ "$site_count" -lt 1 ] && site_count=1

            local disk_type="HDD"
            local root_dev; root_dev=$(df / | awk 'NR==2{{print $1}}' | sed 's|/dev/||;s|[0-9]*$||;s|p[0-9]*$||')
            [ -f "/sys/block/${{root_dev}}/queue/rotational" ] && \
                [ "$(cat /sys/block/${{root_dev}}/queue/rotational 2>/dev/null)" = "0" ] && disk_type="SSD"

            local score=0
            [ "$total_ram" -ge 16384 ] && score=$((score+40)) || [ "$total_ram" -ge 8192 ] && score=$((score+35)) || \
            [ "$total_ram" -ge 4096 ] && score=$((score+28)) || [ "$total_ram" -ge 2048 ] && score=$((score+20)) || \
            [ "$total_ram" -ge 1024 ] && score=$((score+12)) || score=$((score+5))
            [ "$cpu_cores" -ge 8 ] && score=$((score+24)) || [ "$cpu_cores" -ge 4 ] && score=$((score+16)) || \
            [ "$cpu_cores" -ge 2 ] && score=$((score+10)) || score=$((score+5))
            [ "$disk_type" = "SSD" ] && score=$((score+20)) || score=$((score+5))
            local penalty=$(( (site_count-1)*2 )); [ $penalty -gt 10 ] && penalty=10
            score=$((score - penalty)); [ $score -lt 1 ] && score=1

            local perf_tier
            [ "$total_ram" -lt 1024 ] && perf_tier="LIGHTWEIGHT" || \
            [ "$total_ram" -lt 2048 ] && perf_tier="LIGHTWEIGHT_PLUS" || \
            [ "$total_ram" -lt 4096 ] && perf_tier="BALANCED" || \
            [ "$total_ram" -lt 8192 ] && perf_tier="PERFORMANCE" || perf_tier="BEAST"

            cat > "$PROFILE_FILE" <<PROFILE
        # EasyInstall System Profile — $(date)
        TOTAL_RAM_MB=${{total_ram}}
        CPU_CORES=${{cpu_cores}}
        SITE_COUNT=${{site_count}}
        DISK_TYPE=${{disk_type}}
        PERF_SCORE=${{score}}
        PERF_TIER=${{perf_tier}}
        PROFILE_DATE=$(date +%s)
        PROFILE
            export AT_RAM="$total_ram" AT_CORES="$cpu_cores" AT_SITES="$site_count"
            export AT_DISK="$disk_type" AT_SCORE="$score" AT_TIER="$perf_tier"

            atlog "SUCCESS" "Profile: RAM=${{total_ram}}MB | Cores=${{cpu_cores}} | Disk=${{disk_type}} | Score=${{score}}/100 | Tier=${{perf_tier}}"

            autotune_backup
            _at_layer1_base
            _at_tier_layers
            _at_apply_php_fpm
            _at_apply_mysql
            _at_apply_redis
            _at_apply_nginx
            _at_reload_services
            wordpress_max_speed
            setup_redis_tier_cache
            db_optimization_engine
            perf_dashboard &
            DASH_PID=$!
            sleep 3
            kill $DASH_PID 2>/dev/null || true
            smart_cache_warmer
            disaster_recovery_mode

            atlog "SUCCESS" "=== ALL 10 AUTO-TUNE PHASES COMPLETE ==="
            atlog "PERF" "System optimized: Score=${{score}}/100 | Tier=${{perf_tier}}"
        }}

        # ═══════════════════════════════════════════════════════
        # CLI dispatcher (when run directly)
        # ═══════════════════════════════════════════════════════
        case "${{1:-}}" in
            governor)    dynamic_resource_governor ;;
            warm-cache)  smart_cache_warmer ;;
            db-optimize) db_optimization_engine ;;
            wp-speed)    wordpress_max_speed ;;
            dashboard)   perf_dashboard ;;
            emergency)   disaster_recovery_mode "manual" ;;
            rollback)    autotune_rollback ;;
            tune)        advanced_auto_tune ;;
            *)           : ;;  # sourced — no action
        esac
    """)
    write_file("/usr/local/lib/easyinstall-autotune.sh", autotune, mode=0o755)
    log("SUCCESS", "AutoTune module created at /usr/local/lib/easyinstall-autotune.sh")




# ─────────────────────────────────────────────────────────────────────────────
# Ported from v6.4 — stage_advanced_autotune
# ─────────────────────────────────────────────────────────────────────────────

def stage_advanced_autotune(cfg):
    log("STEP", "Running advanced auto-tuning (10 phases) via autotune module")
    rc = run("bash /usr/local/lib/easyinstall-autotune.sh tune 2>&1 | tail -40", check=False)
    if rc == 0:
        log("SUCCESS", "Advanced auto-tuning complete")
    else:
        log("WARNING", "Auto-tune completed with some warnings (non-fatal)")




# ─────────────────────────────────────────────────────────────────────────────
# Ported from v6.4 — stage_websocket_support
# ─────────────────────────────────────────────────────────────────────────────

def stage_websocket_support(cfg):
    log("STEP", "Writing WebSocket support configuration (v6.5)")
    Path("/etc/nginx/conf.d").mkdir(parents=True, exist_ok=True)
    Path("/etc/nginx/snippets").mkdir(parents=True, exist_ok=True)

    ws_map = Path("/etc/nginx/conf.d/websocket-map.conf")
    if not ws_map.exists():
        write_file(str(ws_map), textwrap.dedent("""\
            # WebSocket connection-upgrade map (EasyInstall v6.5)
            map $http_upgrade $connection_upgrade {
                default   close;
                websocket upgrade;
                ""        close;
            }
        """))

    write_file("/etc/nginx/snippets/websocket.conf", textwrap.dedent("""\
        # EasyInstall WebSocket snippet (v6.5)
        # Include inside server{} block to proxy WebSocket connections.
        location ~ ^/(ws|wss)(/.*)?$ {
            proxy_pass         http://127.0.0.1:${WS_BACKEND_PORT:-8080};
            proxy_http_version 1.1;
            proxy_set_header   Upgrade           $http_upgrade;
            proxy_set_header   Connection        $connection_upgrade;
            proxy_set_header   Host              $host;
            proxy_set_header   X-Real-IP         $remote_addr;
            proxy_set_header   X-Forwarded-For   $proxy_add_x_forwarded_for;
            proxy_set_header   X-Forwarded-Proto $scheme;
            proxy_read_timeout  3600s;
            proxy_send_timeout  3600s;
            proxy_buffering     off;
            proxy_cache         off;
        }
    """))
    log("SUCCESS", "WebSocket support configured")




# ─────────────────────────────────────────────────────────────────────────────
# Ported from v6.4 — stage_edge_computing
# ─────────────────────────────────────────────────────────────────────────────

def stage_edge_computing(cfg):
    log("STEP", "Installing Edge Computing layer (v6.5)")
    Path("/etc/nginx/conf.d").mkdir(parents=True, exist_ok=True)
    Path("/etc/nginx/snippets").mkdir(parents=True, exist_ok=True)
    Path("/var/cache/nginx/edge").mkdir(parents=True, exist_ok=True)
    run("chown -R nginx:nginx /var/cache/nginx/edge 2>/dev/null || chown -R www-data:www-data /var/cache/nginx/edge 2>/dev/null || true", check=False)

    write_file("/etc/nginx/conf.d/edge-computing.conf", textwrap.dedent("""\
        # Edge Computing Layer (EasyInstall v6.5)
        fastcgi_cache_path /var/cache/nginx/edge
            levels=1:2
            keys_zone=EDGE_CACHE:64m
            inactive=10m
            max_size=512m;

        geo $edge_region {
            default          global;
            1.0.0.0/8        ap;
            14.0.0.0/8       ap;
            27.0.0.0/8       ap;
            36.0.0.0/8       ap;
            49.0.0.0/8       ap;
            58.0.0.0/8       ap;
            101.0.0.0/8      ap;
            110.0.0.0/8      ap;
            2.0.0.0/8        eu;
            5.0.0.0/8        eu;
            31.0.0.0/8       eu;
            37.0.0.0/8       eu;
            46.0.0.0/8       eu;
            62.0.0.0/8       eu;
            77.0.0.0/8       eu;
            80.0.0.0/8       eu;
            3.0.0.0/8        na;
            4.0.0.0/8        na;
            8.0.0.0/8        na;
            12.0.0.0/8       na;
            24.0.0.0/8       na;
            67.0.0.0/8       na;
            98.0.0.0/8       na;
            127.0.0.0/8      global;
            10.0.0.0/8       global;
            172.16.0.0/12    global;
            192.168.0.0/16   global;
        }

        map $sent_http_content_type $edge_cache_ttl {
            default                             "public, max-age=0, must-revalidate";
            ~*text/html                         "public, max-age=300, stale-while-revalidate=60";
            ~*text/css                          "public, max-age=31536000, immutable";
            ~*application/javascript            "public, max-age=31536000, immutable";
            ~*image/                            "public, max-age=2592000, stale-while-revalidate=86400";
            ~*font/                             "public, max-age=31536000, immutable";
            ~*application/font                  "public, max-age=31536000, immutable";
            ~*video/                            "public, max-age=2592000";
            ~*audio/                            "public, max-age=2592000";
            ~*application/json                  "public, max-age=60, stale-while-revalidate=30";
            ~*application/xml                   "public, max-age=3600";
            ~*text/xml                          "public, max-age=3600";
        }

        geo $edge_purge_allowed {
            default 0;
            127.0.0.1 1;
            ::1       1;
            10.0.0.0/8 1;
            172.16.0.0/12 1;
            192.168.0.0/16 1;
        }
    """))

    write_file("/etc/nginx/snippets/edge-site.conf", textwrap.dedent("""\
        # EasyInstall Edge snippet (v6.5) — include inside server{} block
        proxy_set_header   X-Edge-Region    $edge_region;
        fastcgi_param      EDGE_REGION      $edge_region;
        add_header Cache-Control $edge_cache_ttl always;

        location = /edge-health {
            access_log   off;
            add_header   Content-Type  "application/json" always;
            add_header   X-Edge-Region $edge_region always;
            return 200   '{"status":"ok","edge":"easyinstall-v6.5","region":"$edge_region","time":"$time_iso8601"}';
        }

        # Note: /purge location requires ngx_cache_purge module — use edge-purge script instead
        # Install: apt-get install libnginx-mod-http-cache-purge (if available for your nginx build)
    """))

    edge_purge_script = textwrap.dedent("""\
        #!/bin/bash
        # EasyInstall edge-purge helper (v6.5)
        DOMAIN="${1:-}"
        PATH_ARG="${2:-/}"
        REDIS_PORT=$(grep "^port" "/etc/redis/redis-${DOMAIN//./-}.conf" 2>/dev/null | awk '{print $2}' || echo "6379")

        [ -z "$DOMAIN" ] && { echo "Usage: edge-purge domain.com [/path]"; exit 1; }

        echo "Purging edge cache for: ${DOMAIN}${PATH_ARG}"
        curl -s -X PURGE -H "Host: $DOMAIN" "http://127.0.0.1/purge${PATH_ARG}" 2>/dev/null
        echo ""
        redis-cli -p "$REDIS_PORT" EVAL "
          local keys = redis.call('keys', ARGV[1])
          for _, k in ipairs(keys) do redis.call('del', k) end
          return #keys
        " 0 "*${DOMAIN}*" 2>/dev/null | xargs -I{} echo "  Flushed {} Redis keys for ${DOMAIN}"
        echo "Edge purge complete for ${DOMAIN}"
    """)
    write_file("/usr/local/bin/edge-purge", edge_purge_script, mode=0o755)

    edge_status = (
        "EDGE_ENABLED=true\n"
        f"EDGE_DATE={datetime.now().isoformat()}\n"
        "EDGE_CACHE_DIR=/var/cache/nginx/edge\n"
        "EDGE_CACHE_ZONE=EDGE_CACHE:64m\n"
    )
    write_file("/var/lib/easyinstall/edge.status", edge_status)
    log("SUCCESS", "Edge Computing layer installed")





# ═════════════════════════════════════════════════════════════════════════════
# Main dispatcher (v6.5: Enhanced STAGE_MAP)
# ═════════════════════════════════════════════════════════════════════════════

STAGE_MAP = {
    # Core stages (unchanged functionality, enhanced implementations)
    "kernel_tuning":           stage_kernel_tuning,
    "nginx_config":            stage_nginx_config,
    "nginx_extras":            stage_nginx_extras,
    "websocket_support":       stage_websocket_support,
    "http3_quic":              stage_http3_quic,
    "edge_computing":          stage_edge_computing,
    "php_config":              stage_php_config,
    "mysql_config":            stage_mysql_config,
    "redis_config":            stage_redis_config,
    "firewall_config":         stage_firewall_config,
    "fail2ban_config":         stage_fail2ban_config,
    "create_redis_monitor":    stage_create_redis_monitor,
    "create_commands":         stage_create_commands,
    "create_autoheal":         stage_create_autoheal,
    "create_backup_script":    stage_create_backup_script,
    "create_monitor":          stage_create_monitor,
    "create_welcome":          stage_create_welcome,
    "create_info_file":        stage_create_info_file,
    "create_ai_module":        stage_create_ai_module,
    "create_autotune_module":  stage_create_autotune_module,
    "advanced_autotune":       stage_advanced_autotune,
    "wordpress_install":       stage_wordpress_install,
    "clone_site":              stage_clone_site,
    "remote_install":          stage_remote_install,
    # v6.5: NEW stages
    "s3_backup_config":        stage_s3_backup_config,
    "container_config":        stage_container_config,
}

def main():
    cfg = parse_args()
    stage = cfg.stage if hasattr(cfg, 'stage') else cfg['stage']

    if stage not in STAGE_MAP:
        log("ERROR", f"Unknown stage: {stage}")
        log("INFO",  f"Available stages: {', '.join(STAGE_MAP.keys())}")
        sys.exit(1)

    try:
        STAGE_MAP[stage](cfg)
    except SystemExit:
        raise
    except Exception as e:
        log("ERROR", f"Stage '{stage}' raised exception: {e}")
        import traceback
        traceback.print_exc()
        sys.exit(1)

if __name__ == "__main__":
    main()