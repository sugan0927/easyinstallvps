#!/usr/bin/env python3
"""
EasyInstall Enterprise REST API — v7.0
=======================================
FastAPI-based REST API for programmatic WordPress site management.
Integrates with the existing easyinstall command dispatcher via subprocess.

Deploy to: /usr/local/lib/easyinstall_api.py
Start:     systemctl start easyinstall-api
Docs:      http://127.0.0.1:8000/api/docs
"""

import os
import re
import json
import secrets
import logging
import subprocess
from datetime import datetime, timedelta
from pathlib import Path
from typing import Optional, List, Dict, Any

# ── Logging ───────────────────────────────────────────────────────────────────

LOG_DIR = Path("/var/log/easyinstall")
LOG_DIR.mkdir(parents=True, exist_ok=True)

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s — %(message)s",
    handlers=[
        logging.FileHandler(LOG_DIR / "api.log"),
        logging.StreamHandler(),
    ],
)
logger = logging.getLogger("easyinstall.api")

# ── Configuration ─────────────────────────────────────────────────────────────

CONFIG_DIR = Path("/etc/easyinstall")
CONFIG_DIR.mkdir(parents=True, exist_ok=True)

_DEFAULT_CONFIG: Dict[str, Any] = {
    "host": "127.0.0.1",
    "port": 8000,
    "secret_key": "CHANGE_THIS_BEFORE_PRODUCTION",
    "token_expiry_hours": 24,
    "rate_limit_per_minute": 100,
    "enable_cors": True,
    "allowed_origins": ["*"],
    "log_level": "info",
}

def _load_config() -> Dict[str, Any]:
    cfg = dict(_DEFAULT_CONFIG)
    conf_file = CONFIG_DIR / "api.conf"
    if conf_file.exists():
        try:
            cfg.update(json.loads(conf_file.read_text()))
        except Exception as exc:
            logger.warning("Failed to parse api.conf: %s — using defaults", exc)
    return cfg

API_CFG = _load_config()

# ── Lazy FastAPI imports (installed via: pip install fastapi uvicorn pyjwt) ───

try:
    import jwt
    from fastapi import FastAPI, HTTPException, Depends, BackgroundTasks, WebSocket
    from fastapi.middleware.cors import CORSMiddleware
    from fastapi.security import HTTPBearer, HTTPAuthorizationCredentials
    from pydantic import BaseModel, Field, field_validator
    import uvicorn
    _FASTAPI_AVAILABLE = True
except ImportError:
    _FASTAPI_AVAILABLE = False
    logger.error(
        "FastAPI/uvicorn/pyjwt not installed. "
        "Run: pip install fastapi uvicorn pyjwt --break-system-packages"
    )

# ── Helper utilities ──────────────────────────────────────────────────────────

def _run_easyinstall(args: List[str], timeout: int = 300) -> Dict[str, Any]:
    """Invoke the easyinstall CLI and return structured result."""
    cmd = ["/usr/local/bin/easyinstall"] + args
    logger.info("CLI: %s", " ".join(cmd))
    try:
        proc = subprocess.run(
            cmd, capture_output=True, text=True, timeout=timeout,
            env={**os.environ, "TERM": "dumb"},
        )
        # Strip ANSI escape codes from output
        ansi_escape = re.compile(r"\x1B(?:[@-Z\\-_]|\[[0-?]*[ -/]*[@-~])")
        stdout = ansi_escape.sub("", proc.stdout)
        stderr = ansi_escape.sub("", proc.stderr)
        return {
            "success": proc.returncode == 0,
            "stdout": stdout.strip(),
            "stderr": stderr.strip(),
            "returncode": proc.returncode,
        }
    except subprocess.TimeoutExpired:
        return {"success": False, "error": f"Timed out after {timeout}s"}
    except FileNotFoundError:
        return {"success": False, "error": "easyinstall command not found"}
    except Exception as exc:
        return {"success": False, "error": str(exc)}


def _run_python_stage(stage: str, extra_args: List[str] = None, timeout: int = 300) -> Dict[str, Any]:
    """Invoke easyinstall_config.py directly for operations that need it."""
    cmd = ["/usr/bin/python3", "/usr/local/lib/easyinstall_config.py", "--stage", stage]
    if extra_args:
        cmd.extend(extra_args)
    logger.info("Python stage: %s %s", stage, extra_args or "")
    try:
        proc = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return {
            "success": proc.returncode == 0,
            "stdout": proc.stdout.strip(),
            "stderr": proc.stderr.strip(),
        }
    except subprocess.TimeoutExpired:
        return {"success": False, "error": f"Stage '{stage}' timed out"}
    except Exception as exc:
        return {"success": False, "error": str(exc)}


def _get_site_info(domain: str) -> Optional[Dict[str, Any]]:
    """Read site metadata from the filesystem (no DB dependency)."""
    site_dir = Path(f"/var/www/html/{domain}")
    if not site_dir.exists():
        return None

    wp_config = site_dir / "wp-config.php"
    db_name = db_user = db_pass = None
    if wp_config.exists():
        text = wp_config.read_text(errors="replace")
        for key, var in [("db_name", "DB_NAME"), ("db_user", "DB_USER"), ("db_pass", "DB_PASSWORD")]:
            m = re.search(rf"define\(['\"]{ var}['\"],\s*['\"]([^'\"]+)['\"]", text)
            if m:
                locals()[key]  # ensure var exists
                if key == "db_name": db_name = m.group(1)
                elif key == "db_user": db_user = m.group(1)
                else: db_pass = m.group(1)

    # Redis port
    domain_slug = domain.replace(".", "-")
    redis_port = 6379
    redis_conf = Path(f"/etc/redis/redis-{domain_slug}.conf")
    if redis_conf.exists():
        for line in redis_conf.read_text().splitlines():
            if line.startswith("port "):
                try:
                    redis_port = int(line.split()[1])
                except (ValueError, IndexError):
                    pass

    # PHP version from nginx config
    nginx_conf = Path(f"/etc/nginx/sites-available/{domain}")
    php_version = "unknown"
    if nginx_conf.exists():
        m = re.search(r"php(\d+\.\d+)-fpm", nginx_conf.read_text())
        if m:
            php_version = m.group(1)

    ssl_enabled = Path(f"/etc/letsencrypt/live/{domain}").exists()
    scheme = "https" if ssl_enabled else "http"
    disk_usage = "?"
    try:
        result = subprocess.run(
            ["du", "-sh", str(site_dir)], capture_output=True, text=True
        )
        disk_usage = result.stdout.split("\t")[0] if result.returncode == 0 else "?"
    except Exception:
        pass

    return {
        "domain": domain,
        "path": str(site_dir),
        "site_url": f"{scheme}://{domain}",
        "admin_url": f"{scheme}://{domain}/wp-admin",
        "database_name": db_name,
        "database_user": db_user,
        "php_version": php_version,
        "redis_port": redis_port,
        "ssl_enabled": ssl_enabled,
        "disk_usage": disk_usage,
        "nginx_config": str(nginx_conf),
    }


def _collect_metrics(domain: str) -> Dict[str, Any]:
    """Gather live system and per-site metrics."""
    metrics: Dict[str, Any] = {
        "timestamp": datetime.utcnow().isoformat(),
        "cpu_usage": 0.0,
        "memory_usage": 0.0,
        "disk_usage": 0.0,
        "php_workers": 0,
        "redis_memory_mb": 0.0,
        "active_connections": 0,
    }
    # CPU
    try:
        r = subprocess.run(
            ["awk", "/cpu /{u=$2+$4;t=$2+$3+$4+$5; if(NR==1){u1=u;t1=t}else{printf \"%.1f\",100*(u-u1)/(t-t1)}}", "/proc/stat", "/proc/stat"],
            capture_output=True, text=True, timeout=5
        )
        if r.stdout.strip():
            metrics["cpu_usage"] = float(r.stdout.strip())
    except Exception:
        try:
            r = subprocess.run(["top", "-bn1"], capture_output=True, text=True, timeout=5)
            for line in r.stdout.splitlines():
                m = re.search(r"(\d+\.?\d*)\s*id", line)
                if m:
                    metrics["cpu_usage"] = round(100.0 - float(m.group(1)), 1)
                    break
        except Exception:
            pass

    # Memory
    try:
        r = subprocess.run(["free", "-m"], capture_output=True, text=True, timeout=3)
        for line in r.stdout.splitlines():
            if line.startswith("Mem:"):
                parts = line.split()
                total, used = int(parts[1]), int(parts[2])
                metrics["memory_usage"] = round(used / total * 100, 1) if total else 0.0
                break
    except Exception:
        pass

    # Disk
    try:
        r = subprocess.run(["df", "-h", "/"], capture_output=True, text=True, timeout=3)
        lines = r.stdout.splitlines()
        if len(lines) >= 2:
            pct = lines[1].split()[4].replace("%", "")
            metrics["disk_usage"] = float(pct)
    except Exception:
        pass

    # PHP-FPM workers
    try:
        r = subprocess.run(["pgrep", "-c", "php-fpm"], capture_output=True, text=True, timeout=3)
        if r.stdout.strip().isdigit():
            metrics["php_workers"] = int(r.stdout.strip())
    except Exception:
        pass

    # Redis memory for this site
    domain_slug = domain.replace(".", "-")
    redis_conf = Path(f"/etc/redis/redis-{domain_slug}.conf")
    if redis_conf.exists():
        redis_port = 6379
        for line in redis_conf.read_text().splitlines():
            if line.startswith("port "):
                try:
                    redis_port = int(line.split()[1])
                except (ValueError, IndexError):
                    pass
        try:
            r = subprocess.run(
                ["redis-cli", "-p", str(redis_port), "INFO", "memory"],
                capture_output=True, text=True, timeout=5,
            )
            for line in r.stdout.splitlines():
                if line.startswith("used_memory_human:"):
                    val = line.split(":")[1].strip()
                    if val.endswith("G"):
                        metrics["redis_memory_mb"] = float(val[:-1]) * 1024
                    elif val.endswith("M"):
                        metrics["redis_memory_mb"] = float(val[:-1])
                    elif val.endswith("K"):
                        metrics["redis_memory_mb"] = round(float(val[:-1]) / 1024, 2)
                    break
        except Exception:
            pass

    # Nginx active connections
    try:
        r = subprocess.run(
            ["bash", "-c", "ss -s | grep ESTAB | awk '{print $2}'"],
            capture_output=True, text=True, timeout=3,
        )
        if r.stdout.strip().isdigit():
            metrics["active_connections"] = int(r.stdout.strip())
    except Exception:
        pass

    return metrics


def _next_redis_port() -> int:
    """Find next available Redis port above 6380."""
    used_file = Path("/var/lib/easyinstall/used_redis_ports.txt")
    used: set = set()
    if used_file.exists():
        used = {int(p) for p in used_file.read_text().split() if p.isdigit()}
    port = 6380
    while port in used:
        port += 1
    return port


def _service_status(name: str) -> bool:
    try:
        r = subprocess.run(
            ["systemctl", "is-active", "--quiet", name], timeout=3
        )
        return r.returncode == 0
    except Exception:
        return False


# ── JWT auth helpers ──────────────────────────────────────────────────────────

_KEYS_FILE = CONFIG_DIR / "api_keys.json"

def _load_keys() -> Dict[str, Any]:
    if _KEYS_FILE.exists():
        try:
            return json.loads(_KEYS_FILE.read_text())
        except Exception:
            pass
    return {}


def _save_keys(keys: Dict[str, Any]) -> None:
    _KEYS_FILE.write_text(json.dumps(keys, indent=2, default=str))
    _KEYS_FILE.chmod(0o600)


def _create_token(username: str, role: str) -> str:
    payload = {
        "sub": username,
        "role": role,
        "iat": datetime.utcnow(),
        "exp": datetime.utcnow() + timedelta(hours=API_CFG["token_expiry_hours"]),
    }
    return jwt.encode(payload, API_CFG["secret_key"], algorithm="HS256")


def _decode_token(token: str) -> Dict[str, Any]:
    return jwt.decode(token, API_CFG["secret_key"], algorithms=["HS256"])


# ── Build FastAPI app ─────────────────────────────────────────────────────────

if _FASTAPI_AVAILABLE:
    app = FastAPI(
        title="EasyInstall Enterprise API",
        version="7.0.0",
        description=(
            "REST API for EasyInstall v7.0 — manage WordPress sites, backups, "
            "metrics, users and more without touching the CLI."
        ),
        docs_url="/api/docs",
        redoc_url="/api/redoc",
        openapi_url="/api/openapi.json",
    )

    if API_CFG["enable_cors"]:
        app.add_middleware(
            CORSMiddleware,
            allow_origins=API_CFG["allowed_origins"],
            allow_credentials=True,
            allow_methods=["*"],
            allow_headers=["*"],
        )

    _bearer = HTTPBearer(auto_error=True)

    def _require_auth(credentials: HTTPAuthorizationCredentials = Depends(_bearer)) -> Dict:
        """Dependency: validate JWT and return payload."""
        try:
            return _decode_token(credentials.credentials)
        except jwt.ExpiredSignatureError:
            raise HTTPException(status_code=401, detail="Token expired")
        except jwt.InvalidTokenError:
            raise HTTPException(status_code=401, detail="Invalid token")

    def _require_admin(payload: Dict = Depends(_require_auth)) -> Dict:
        if payload.get("role") not in ("super_admin", "admin"):
            raise HTTPException(status_code=403, detail="Admin role required")
        return payload

    # ── Pydantic models ───────────────────────────────────────────────────────

    class SiteCreateRequest(BaseModel):
        domain: str = Field(..., description="Bare domain, e.g. example.com")
        php_version: str = Field("8.3", description="PHP version: 8.2 | 8.3 | 8.4")
        enable_ssl: bool = Field(False, description="Issue Let's Encrypt certificate")
        redis_port: Optional[int] = Field(None, description="Override Redis port (auto if omitted)")

        @field_validator("domain")
        @classmethod
        def clean_domain(cls, v: str) -> str:
            v = re.sub(r"https?://", "", v).strip("/").lower()
            v = re.sub(r"^www\.", "", v)
            if not re.match(r"^[a-z0-9][a-z0-9\-\.]{1,252}[a-z0-9]$", v):
                raise ValueError("Invalid domain name")
            return v

        @field_validator("php_version")
        @classmethod
        def valid_php(cls, v: str) -> str:
            if v not in ("8.2", "8.3", "8.4"):
                raise ValueError("php_version must be 8.2, 8.3, or 8.4")
            return v

    class SiteDeleteRequest(BaseModel):
        confirm: bool = Field(..., description="Must be true to confirm deletion")

    class SSLRequest(BaseModel):
        force_renew: bool = Field(False)

    class BackupRequest(BaseModel):
        backup_type: str = Field("full", description="full | database | files")

    class CloneRequest(BaseModel):
        target_domain: str

    class LoginRequest(BaseModel):
        username: str
        password: str

    class ApiKeyCreateRequest(BaseModel):
        name: str = Field(..., description="Label for this key")
        role: str = Field("viewer", description="super_admin | admin | developer | viewer")

    class PhpSwitchRequest(BaseModel):
        php_version: str

    class WebSocketRequest(BaseModel):
        port: int = Field(8080)

    # ── Auth endpoints ────────────────────────────────────────────────────────

    @app.post("/api/v1/auth/login", tags=["Auth"])
    def login(req: LoginRequest):
        """Exchange credentials for a JWT. Credentials are stored in api_keys.json."""
        keys = _load_keys()
        user = keys.get("users", {}).get(req.username)
        if not user or user.get("password") != req.password:
            logger.warning("Failed login attempt: %s", req.username)
            raise HTTPException(status_code=401, detail="Invalid credentials")
        role = user.get("role", "viewer")
        token = _create_token(req.username, role)
        logger.info("Login: %s (%s)", req.username, role)
        return {"access_token": token, "token_type": "bearer", "role": role}

    @app.get("/api/v1/auth/me", tags=["Auth"])
    def me(payload: Dict = Depends(_require_auth)):
        return {"username": payload["sub"], "role": payload.get("role"), "exp": payload.get("exp")}

    # ── Health ────────────────────────────────────────────────────────────────

    @app.get("/api/v1/health", tags=["System"])
    def health():
        """Quick health check — no auth required."""
        return {
            "status": "ok",
            "version": "7.0",
            "timestamp": datetime.utcnow().isoformat(),
            "services": {
                "nginx":    _service_status("nginx"),
                "mariadb":  _service_status("mariadb"),
                "redis":    _service_status("redis-server"),
                "php84":    _service_status("php8.4-fpm"),
                "php83":    _service_status("php8.3-fpm"),
                "php82":    _service_status("php8.2-fpm"),
                "fail2ban": _service_status("fail2ban"),
                "autoheal": _service_status("autoheal"),
            },
        }

    # ── Sites ─────────────────────────────────────────────────────────────────

    @app.get("/api/v1/sites", tags=["Sites"])
    def list_sites(page: int = 1, per_page: int = 20, payload: Dict = Depends(_require_auth)):
        """List all WordPress sites managed by EasyInstall."""
        sites_root = Path("/var/www/html")
        sites = []
        if sites_root.exists():
            for entry in sorted(sites_root.iterdir()):
                if entry.is_dir() and (entry / "wp-config.php").exists():
                    info = _get_site_info(entry.name)
                    if info:
                        sites.append(info)
        start = (page - 1) * per_page
        return {
            "total": len(sites),
            "page": page,
            "per_page": per_page,
            "sites": sites[start: start + per_page],
        }

    @app.get("/api/v1/sites/{domain}", tags=["Sites"])
    def get_site(domain: str, payload: Dict = Depends(_require_auth)):
        """Get detailed info for a single site."""
        info = _get_site_info(domain)
        if not info:
            raise HTTPException(status_code=404, detail=f"Site '{domain}' not found")
        return info

    @app.post("/api/v1/sites", status_code=202, tags=["Sites"])
    def create_site(req: SiteCreateRequest, background_tasks: BackgroundTasks, payload: Dict = Depends(_require_admin)):
        """
        Create a new WordPress site. Runs asynchronously — returns job info immediately.
        The site will appear under /var/www/html/{domain} once the job completes.
        """
        if Path(f"/var/www/html/{req.domain}").exists():
            raise HTTPException(status_code=409, detail=f"Site '{req.domain}' already exists")

        redis_port = req.redis_port or _next_redis_port()
        ssl_flag = "--use-ssl" if req.enable_ssl else ""
        job_id = secrets.token_hex(8)

        def _do_create():
            args = [
                "--stage", "wordpress_install",
                "--domain", req.domain,
                "--php-version", req.php_version,
                "--redis-port", str(redis_port),
            ]
            if req.enable_ssl:
                args.append("--use-ssl")
            result = _run_python_stage("wordpress_install", args[2:])  # skip --stage
            # Record redis port
            port_file = Path("/var/lib/easyinstall/used_redis_ports.txt")
            port_file.parent.mkdir(parents=True, exist_ok=True)
            with port_file.open("a") as f:
                f.write(f"{redis_port}\n")
            log_status = "SUCCESS" if result["success"] else "FAILED"
            logger.info("Site creation %s: %s", log_status, req.domain)

        background_tasks.add_task(_do_create)
        return {
            "job_id": job_id,
            "status": "queued",
            "domain": req.domain,
            "php_version": req.php_version,
            "redis_port": redis_port,
            "ssl": req.enable_ssl,
            "message": "Site creation started. Poll GET /api/v1/sites/{domain} to check progress.",
        }

    @app.delete("/api/v1/sites/{domain}", tags=["Sites"])
    def delete_site(domain: str, req: SiteDeleteRequest, payload: Dict = Depends(_require_admin)):
        """Delete a WordPress site and all its resources."""
        if not req.confirm:
            raise HTTPException(status_code=400, detail="Set 'confirm: true' to delete")
        if not Path(f"/var/www/html/{domain}").exists():
            raise HTTPException(status_code=404, detail=f"Site '{domain}' not found")
        result = _run_easyinstall(["delete", domain])
        if not result["success"]:
            raise HTTPException(status_code=500, detail=result.get("stderr") or result.get("error"))
        logger.info("Site deleted by %s: %s", payload["sub"], domain)
        return {"status": "deleted", "domain": domain}

    @app.get("/api/v1/sites/{domain}/metrics", tags=["Sites"])
    def site_metrics(domain: str, payload: Dict = Depends(_require_auth)):
        """Real-time system + Redis metrics scoped to a site."""
        if not Path(f"/var/www/html/{domain}").exists():
            raise HTTPException(status_code=404, detail=f"Site '{domain}' not found")
        return _collect_metrics(domain)

    @app.post("/api/v1/sites/{domain}/backup", status_code=202, tags=["Sites"])
    def create_backup(domain: str, req: BackupRequest, background_tasks: BackgroundTasks, payload: Dict = Depends(_require_auth)):
        """Trigger a backup for the site."""
        if not Path(f"/var/www/html/{domain}").exists():
            raise HTTPException(status_code=404, detail=f"Site '{domain}' not found")
        job_id = secrets.token_hex(8)

        def _do_backup():
            result = _run_easyinstall(["backup-site", domain])
            logger.info("Backup %s for %s", "OK" if result["success"] else "FAILED", domain)

        background_tasks.add_task(_do_backup)
        return {"job_id": job_id, "status": "queued", "domain": domain, "type": req.backup_type}

    @app.post("/api/v1/sites/{domain}/clone", status_code=202, tags=["Sites"])
    def clone_site(domain: str, req: CloneRequest, background_tasks: BackgroundTasks, payload: Dict = Depends(_require_admin)):
        """Clone an existing site to a new domain."""
        if not Path(f"/var/www/html/{domain}").exists():
            raise HTTPException(status_code=404, detail=f"Source site '{domain}' not found")
        if Path(f"/var/www/html/{req.target_domain}").exists():
            raise HTTPException(status_code=409, detail=f"Target '{req.target_domain}' already exists")

        def _do_clone():
            result = _run_easyinstall(["clone", domain, req.target_domain])
            logger.info("Clone %s → %s: %s", domain, req.target_domain,
                        "OK" if result["success"] else result.get("stderr"))

        background_tasks.add_task(_do_clone)
        return {"status": "queued", "source": domain, "target": req.target_domain}

    @app.post("/api/v1/sites/{domain}/ssl", tags=["Sites"])
    def enable_ssl(domain: str, req: SSLRequest, payload: Dict = Depends(_require_admin)):
        """Enable Let's Encrypt SSL for a site."""
        if not Path(f"/var/www/html/{domain}").exists():
            raise HTTPException(status_code=404, detail=f"Site '{domain}' not found")
        result = _run_easyinstall(["ssl", domain])
        if not result["success"]:
            raise HTTPException(status_code=500, detail=result.get("stderr") or "SSL provisioning failed")
        return {"status": "ssl_enabled", "domain": domain, "https_url": f"https://{domain}"}

    @app.post("/api/v1/sites/{domain}/update", status_code=202, tags=["Sites"])
    def update_site(domain: str, background_tasks: BackgroundTasks, payload: Dict = Depends(_require_auth)):
        """Update WordPress core, plugins and themes."""
        if not Path(f"/var/www/html/{domain}").exists():
            raise HTTPException(status_code=404, detail=f"Site '{domain}' not found")

        def _do_update():
            result = _run_easyinstall(["update-site", domain])
            logger.info("Update %s: %s", domain, "OK" if result["success"] else result.get("stderr"))

        background_tasks.add_task(_do_update)
        return {"status": "queued", "domain": domain}

    @app.post("/api/v1/sites/{domain}/php-switch", tags=["Sites"])
    def switch_php(domain: str, req: PhpSwitchRequest, payload: Dict = Depends(_require_admin)):
        """Switch a site to a different PHP version."""
        if req.php_version not in ("8.2", "8.3", "8.4"):
            raise HTTPException(status_code=400, detail="php_version must be 8.2, 8.3, or 8.4")
        result = _run_easyinstall(["php-switch", domain, req.php_version])
        if not result["success"]:
            raise HTTPException(status_code=500, detail=result.get("stderr") or "PHP switch failed")
        return {"domain": domain, "php_version": req.php_version, "status": "switched"}

    @app.post("/api/v1/sites/{domain}/websocket", tags=["Sites"])
    def enable_websocket(domain: str, req: WebSocketRequest, payload: Dict = Depends(_require_admin)):
        """Enable WebSocket proxying for a site."""
        result = _run_easyinstall(["ws-enable", domain, str(req.port)])
        if not result["success"]:
            raise HTTPException(status_code=500, detail=result.get("stderr") or "WebSocket setup failed")
        return {"domain": domain, "ws_port": req.port, "status": "enabled"}

    @app.get("/api/v1/sites/{domain}/info", tags=["Sites"])
    def site_info(domain: str, payload: Dict = Depends(_require_auth)):
        """Alias for GET /sites/{domain} — returns full site metadata."""
        return get_site(domain, payload)

    # ── API key management ────────────────────────────────────────────────────

    @app.post("/api/v1/api-keys", tags=["API Keys"])
    def create_api_key(req: ApiKeyCreateRequest, payload: Dict = Depends(_require_admin)):
        """Create a named API key (stored in /etc/easyinstall/api_keys.json)."""
        keys = _load_keys()
        if "api_keys" not in keys:
            keys["api_keys"] = {}
        if req.name in keys["api_keys"]:
            raise HTTPException(status_code=409, detail=f"Key '{req.name}' already exists")
        new_key = f"ei_{secrets.token_urlsafe(32)}"
        keys["api_keys"][req.name] = {
            "key": new_key,
            "role": req.role,
            "created_by": payload["sub"],
            "created_at": datetime.utcnow().isoformat(),
        }
        _save_keys(keys)
        logger.info("API key created: %s (role: %s) by %s", req.name, req.role, payload["sub"])
        return {"name": req.name, "api_key": new_key, "role": req.role}

    @app.get("/api/v1/api-keys", tags=["API Keys"])
    def list_api_keys(payload: Dict = Depends(_require_admin)):
        keys = _load_keys()
        result = []
        for name, data in keys.get("api_keys", {}).items():
            result.append({
                "name": name,
                "role": data.get("role"),
                "created_by": data.get("created_by"),
                "created_at": data.get("created_at"),
                "key_preview": data["key"][:10] + "...",
            })
        return {"api_keys": result}

    @app.delete("/api/v1/api-keys/{name}", tags=["API Keys"])
    def revoke_api_key(name: str, payload: Dict = Depends(_require_admin)):
        keys = _load_keys()
        if name not in keys.get("api_keys", {}):
            raise HTTPException(status_code=404, detail=f"Key '{name}' not found")
        del keys["api_keys"][name]
        _save_keys(keys)
        logger.info("API key revoked: %s by %s", name, payload["sub"])
        return {"status": "revoked", "name": name}

    # ── System endpoints ──────────────────────────────────────────────────────

    @app.get("/api/v1/system/metrics", tags=["System"])
    def system_metrics(payload: Dict = Depends(_require_auth)):
        """Server-wide resource metrics (not scoped to a site)."""
        return _collect_metrics("_system_")

    @app.post("/api/v1/system/autotune", status_code=202, tags=["System"])
    def run_autotune(background_tasks: BackgroundTasks, payload: Dict = Depends(_require_admin)):
        """Run the 10-phase advanced auto-tuning pipeline."""
        def _do():
            result = _run_easyinstall(["autotune"])
            logger.info("Autotune: %s", "OK" if result["success"] else result.get("stderr"))
        background_tasks.add_task(_do)
        return {"status": "queued", "message": "Auto-tuning started in background"}

    @app.post("/api/v1/system/validate-config", tags=["System"])
    def validate_config(payload: Dict = Depends(_require_admin)):
        """Run the v7.0 config validator across nginx/php/mysql/redis."""
        result = _run_python_stage("stage_config_validator")
        return {
            "success": result["success"],
            "report": "/root/config-validation-report.txt",
            "output": result.get("stdout", "")[:2000],
        }

    @app.get("/api/v1/system/redis-ports", tags=["System"])
    def redis_ports(payload: Dict = Depends(_require_auth)):
        """List all allocated Redis ports."""
        result = _run_easyinstall(["redis-ports"])
        return {"output": result.get("stdout", "")}

    # ── WebSocket: live log streaming ────────────────────────────────────────

    @app.websocket("/api/v1/ws/logs")
    async def stream_logs(ws: WebSocket):
        """Stream the EasyInstall install log over WebSocket (no auth — bind to localhost only)."""
        await ws.accept()
        log_file = LOG_DIR / "install.log"
        try:
            proc = await __import__("asyncio").create_subprocess_exec(
                "tail", "-F", str(log_file),
                stdout=__import__("asyncio").subprocess.PIPE,
            )
            while True:
                line = await proc.stdout.readline()
                if line:
                    await ws.send_text(line.decode(errors="replace"))
        except Exception:
            pass
        finally:
            await ws.close()


# ── Entry point ───────────────────────────────────────────────────────────────

def main():
    if not _FASTAPI_AVAILABLE:
        print("ERROR: FastAPI not installed. Run:")
        print("  pip install fastapi uvicorn pyjwt --break-system-packages")
        return 1
    logger.info("Starting EasyInstall API on %s:%s", API_CFG["host"], API_CFG["port"])
    uvicorn.run(
        "easyinstall_api:app",
        host=API_CFG["host"],
        port=int(API_CFG["port"]),
        log_level=API_CFG.get("log_level", "info"),
        access_log=True,
        reload=False,
    )


if __name__ == "__main__":
    main()
