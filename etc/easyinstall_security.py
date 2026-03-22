#!/usr/bin/env python3
"""
EasyInstall Enterprise Security Module — v7.0
=============================================
RBAC, JWT management, audit trail helpers, SSL certificate manager,
firewall rule helpers, and GDPR-oriented data utilities.

Deploy to: /usr/local/lib/easyinstall_security.py
Usage:     easyinstall security <command>
           python3 /usr/local/lib/easyinstall_security.py --help
"""

import os
import re
import json
import secrets
import hashlib
import logging
import subprocess
from datetime import datetime, timedelta
from pathlib import Path
from typing import Optional, Dict, List, Any, Tuple

# ── Logging ───────────────────────────────────────────────────────────────────

LOG_DIR = Path("/var/log/easyinstall")
LOG_DIR.mkdir(parents=True, exist_ok=True)

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s — %(message)s",
    handlers=[
        logging.FileHandler(LOG_DIR / "security.log"),
        logging.StreamHandler(),
    ],
)
logger = logging.getLogger("easyinstall.security")

CONFIG_DIR = Path("/etc/easyinstall")
CONFIG_DIR.mkdir(parents=True, exist_ok=True)

# ── RBAC definitions ──────────────────────────────────────────────────────────

# Maps role → set of allowed actions.
# An action is a string like "sites:read", "sites:write", "users:admin", etc.
ROLE_PERMISSIONS: Dict[str, set] = {
    "super_admin": {"*"},                                                    # everything
    "admin": {
        "sites:read", "sites:write", "sites:delete",
        "backups:read", "backups:write",
        "metrics:read",
        "api_keys:read", "api_keys:write",
        "users:read",
        "system:read", "system:write",
        "security:read", "security:write",
    },
    "developer": {
        "sites:read", "sites:write",
        "backups:read", "backups:write",
        "metrics:read",
        "api_keys:read",
    },
    "viewer": {
        "sites:read",
        "metrics:read",
    },
    "auditor": {
        "sites:read",
        "metrics:read",
        "audit:read",
        "security:read",
    },
}


def check_permission(role: str, action: str) -> bool:
    """Return True if the role is allowed to perform action."""
    perms = ROLE_PERMISSIONS.get(role, set())
    return "*" in perms or action in perms


def require_permission(role: str, action: str) -> None:
    """Raise PermissionError if role cannot perform action."""
    if not check_permission(role, action):
        raise PermissionError(f"Role '{role}' cannot perform '{action}'")


# ── JWT helpers ───────────────────────────────────────────────────────────────

def _load_secret() -> str:
    secret_file = CONFIG_DIR / "jwt_secret.key"
    if secret_file.exists():
        return secret_file.read_text().strip()
    # Generate and persist a new secret
    new_secret = secrets.token_hex(64)
    secret_file.write_text(new_secret)
    secret_file.chmod(0o600)
    logger.info("Generated new JWT secret at %s", secret_file)
    return new_secret

_JWT_SECRET = _load_secret()

try:
    import jwt as _jwt_lib
    _JWT_AVAILABLE = True
except ImportError:
    _JWT_AVAILABLE = False
    logger.warning("PyJWT not installed — JWT operations unavailable. "
                   "Install: pip install pyjwt --break-system-packages")


def generate_token(username: str, role: str, expiry_hours: int = 24,
                   extra_claims: Dict = None) -> str:
    """Create a signed JWT for the given user."""
    if not _JWT_AVAILABLE:
        raise RuntimeError("PyJWT not installed")
    payload = {
        "sub": username,
        "role": role,
        "iat": datetime.utcnow(),
        "exp": datetime.utcnow() + timedelta(hours=expiry_hours),
        **(extra_claims or {}),
    }
    return _jwt_lib.encode(payload, _JWT_SECRET, algorithm="HS256")


def verify_token(token: str) -> Dict:
    """Decode and verify a JWT. Raises jwt.InvalidTokenError on failure."""
    if not _JWT_AVAILABLE:
        raise RuntimeError("PyJWT not installed")
    return _jwt_lib.decode(token, _JWT_SECRET, algorithms=["HS256"])


def rotate_jwt_secret() -> str:
    """Generate a new JWT signing secret (invalidates all existing tokens)."""
    new_secret = secrets.token_hex(64)
    secret_file = CONFIG_DIR / "jwt_secret.key"
    # Backup old secret
    backup = secret_file.with_suffix(f".key.bak.{int(datetime.utcnow().timestamp())}")
    if secret_file.exists():
        secret_file.rename(backup)
    secret_file.write_text(new_secret)
    secret_file.chmod(0o600)
    global _JWT_SECRET
    _JWT_SECRET = new_secret
    logger.warning("JWT secret rotated — all existing tokens are now invalid")
    return new_secret


# ── SSL certificate manager ───────────────────────────────────────────────────

class SSLManager:
    """Wrapper around certbot for Let's Encrypt certificate lifecycle."""

    CERT_BASE = Path("/etc/letsencrypt/live")
    RENEW_DAYS_THRESHOLD = 30

    @staticmethod
    def _run(cmd: str, timeout: int = 120) -> Tuple[bool, str]:
        result = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=timeout)
        output = result.stdout + result.stderr
        return result.returncode == 0, output.strip()

    def issue_certificate(self, domain: str, email: str = "admin@localhost",
                          webroot: str = None) -> bool:
        """Issue or renew a Let's Encrypt certificate for domain."""
        if webroot:
            cmd = (
                f"certbot certonly --webroot -w {webroot} -d {domain} "
                f"--email {email} --agree-tos --non-interactive --quiet"
            )
        else:
            cmd = (
                f"certbot certonly --nginx -d {domain} "
                f"--email {email} --agree-tos --non-interactive --quiet"
            )
        ok, out = self._run(cmd, timeout=180)
        if ok:
            logger.info("SSL certificate issued for %s", domain)
        else:
            logger.error("SSL issuance failed for %s: %s", domain, out[:500])
        return ok

    def renew_all(self, dry_run: bool = False) -> bool:
        """Renew all certificates nearing expiry."""
        cmd = "certbot renew --quiet" + (" --dry-run" if dry_run else "")
        ok, out = self._run(cmd, timeout=300)
        logger.info("certbot renew: %s", "OK" if ok else out[:300])
        return ok

    def get_expiry(self, domain: str) -> Optional[datetime]:
        """Return certificate expiry date, or None if not found."""
        cert_file = self.CERT_BASE / domain / "fullchain.pem"
        if not cert_file.exists():
            return None
        ok, out = self._run(f"openssl x509 -enddate -noout -in {cert_file}")
        if not ok:
            return None
        m = re.search(r"notAfter=(.+)", out)
        if m:
            try:
                return datetime.strptime(m.group(1).strip(), "%b %d %H:%M:%S %Y %Z")
            except ValueError:
                pass
        return None

    def days_until_expiry(self, domain: str) -> Optional[int]:
        expiry = self.get_expiry(domain)
        if not expiry:
            return None
        return (expiry - datetime.utcnow()).days

    def check_all_certificates(self) -> List[Dict]:
        """Scan all managed certs and return status for each."""
        results = []
        if not self.CERT_BASE.exists():
            return results
        for entry in self.CERT_BASE.iterdir():
            if entry.is_dir():
                domain = entry.name
                days = self.days_until_expiry(domain)
                results.append({
                    "domain": domain,
                    "days_remaining": days,
                    "status": (
                        "expired" if days is not None and days < 0
                        else "expiring_soon" if days is not None and days < self.RENEW_DAYS_THRESHOLD
                        else "ok" if days is not None
                        else "unknown"
                    ),
                })
        return results

    def revoke_certificate(self, domain: str) -> bool:
        """Revoke and delete a certificate."""
        cmd = f"certbot revoke --cert-name {domain} --non-interactive --quiet"
        ok, out = self._run(cmd, timeout=60)
        logger.info("SSL revoke %s: %s", domain, "OK" if ok else out[:200])
        return ok


ssl_manager = SSLManager()


# ── Firewall rule manager ─────────────────────────────────────────────────────

class FirewallManager:
    """Thin wrapper around UFW."""

    @staticmethod
    def _ufw(args: str) -> Tuple[bool, str]:
        result = subprocess.run(
            f"ufw {args}", shell=True, capture_output=True, text=True, timeout=30
        )
        return result.returncode == 0, (result.stdout + result.stderr).strip()

    def status(self) -> str:
        _, out = self._ufw("status verbose")
        return out

    def allow_port(self, port: int, proto: str = "tcp", comment: str = "") -> bool:
        rule = f"allow {port}/{proto}"
        if comment:
            rule += f" comment '{comment}'"
        ok, out = self._ufw(rule)
        logger.info("UFW allow %d/%s: %s", port, proto, "OK" if ok else out)
        return ok

    def deny_port(self, port: int, proto: str = "tcp") -> bool:
        ok, out = self._ufw(f"deny {port}/{proto}")
        logger.info("UFW deny %d/%s: %s", port, proto, "OK" if ok else out)
        return ok

    def allow_ip(self, ip: str, port: Optional[int] = None) -> bool:
        rule = f"allow from {ip}"
        if port:
            rule += f" to any port {port}"
        ok, out = self._ufw(rule)
        logger.info("UFW allow IP %s: %s", ip, "OK" if ok else out)
        return ok

    def deny_ip(self, ip: str) -> bool:
        ok, out = self._ufw(f"deny from {ip}")
        logger.info("UFW deny IP %s: %s", ip, "OK" if ok else out)
        return ok

    def list_rules(self) -> List[str]:
        _, out = self._ufw("status numbered")
        return [line for line in out.splitlines() if line.strip() and not line.startswith("Status")]

    def enable(self) -> bool:
        ok, _ = self._ufw("enable")
        return ok

    def reload(self) -> bool:
        ok, _ = self._ufw("reload")
        return ok


firewall = FirewallManager()


# ── Fail2ban helpers ──────────────────────────────────────────────────────────

class Fail2banManager:
    """Helpers for querying and controlling Fail2ban."""

    @staticmethod
    def _f2b(cmd: str) -> Tuple[bool, str]:
        result = subprocess.run(
            f"fail2ban-client {cmd}", shell=True, capture_output=True, text=True, timeout=15
        )
        return result.returncode == 0, (result.stdout + result.stderr).strip()

    def status(self, jail: str = None) -> str:
        if jail:
            _, out = self._f2b(f"status {jail}")
        else:
            _, out = self._f2b("status")
        return out

    def get_banned_ips(self, jail: str = "wordpress") -> List[str]:
        ok, out = self._f2b(f"status {jail}")
        if not ok:
            return []
        m = re.search(r"Banned IP list:\s*(.+)", out)
        if m:
            return [ip.strip() for ip in m.group(1).split() if ip.strip()]
        return []

    def unban_ip(self, ip: str, jail: str = "wordpress") -> bool:
        ok, out = self._f2b(f"set {jail} unbanip {ip}")
        logger.info("Fail2ban unban %s from %s: %s", ip, jail, "OK" if ok else out)
        return ok

    def ban_ip(self, ip: str, jail: str = "wordpress") -> bool:
        ok, out = self._f2b(f"set {jail} banip {ip}")
        logger.info("Fail2ban ban %s in %s: %s", ip, jail, "OK" if ok else out)
        return ok

    def reload(self) -> bool:
        ok, _ = self._f2b("reload")
        return ok


fail2ban = Fail2banManager()


# ── WordPress security scanner ────────────────────────────────────────────────

class WordPressSecurityScanner:
    """Lightweight security checks for WordPress installations."""

    def scan_site(self, domain: str) -> Dict[str, Any]:
        """Run a battery of security checks on a WordPress site."""
        site_dir = Path(f"/var/www/html/{domain}")
        if not site_dir.exists():
            return {"error": f"Site '{domain}' not found"}

        findings: List[Dict] = []
        score = 100  # start at 100, deduct for each issue

        # 1. File permissions
        for bad_perm, expected, penalty in [
            ("wp-config.php", "640", 20),
            (".htaccess", "644", 5),
        ]:
            target = site_dir / bad_perm
            if target.exists():
                mode = oct(target.stat().st_mode)[-3:]
                if mode not in (expected, "600"):
                    findings.append({
                        "type": "file_permissions",
                        "severity": "high" if penalty >= 15 else "medium",
                        "file": bad_perm,
                        "current": mode,
                        "recommended": expected,
                        "fix": f"chmod {expected} {target}",
                    })
                    score -= penalty

        # 2. Debug mode in wp-config.php
        wp_config = site_dir / "wp-config.php"
        if wp_config.exists():
            content = wp_config.read_text(errors="replace")
            if "define('WP_DEBUG', true)" in content or 'define("WP_DEBUG", true)' in content:
                findings.append({
                    "type": "debug_enabled",
                    "severity": "high",
                    "message": "WP_DEBUG is enabled in production",
                    "fix": "Set WP_DEBUG to false in wp-config.php",
                })
                score -= 15

            # 3. Default table prefix
            if "table_prefix = 'wp_'" in content:
                findings.append({
                    "type": "default_table_prefix",
                    "severity": "medium",
                    "message": "Default 'wp_' table prefix detected",
                    "fix": "Change table_prefix to a custom value",
                })
                score -= 10

        # 4. Sensitive files exposed in web root
        for sensitive in ["wp-config.php.bak", "wp-config.php~", ".env", "debug.log", "phpinfo.php"]:
            if (site_dir / sensitive).exists():
                findings.append({
                    "type": "exposed_file",
                    "severity": "critical",
                    "file": sensitive,
                    "fix": f"Remove {site_dir / sensitive}",
                })
                score -= 25

        # 5. README / license in root
        for readme in ["readme.html", "license.txt", "wp-admin/install.php"]:
            target = site_dir / readme
            if target.exists() and readme.endswith(".html"):
                findings.append({
                    "type": "info_disclosure",
                    "severity": "low",
                    "file": readme,
                    "fix": f"Delete or restrict access to {readme}",
                })
                score -= 3

        # 6. Check SSL
        ssl_enabled = Path(f"/etc/letsencrypt/live/{domain}").exists()
        if not ssl_enabled:
            findings.append({
                "type": "no_ssl",
                "severity": "high",
                "message": "HTTPS not enabled",
                "fix": f"easyinstall ssl {domain}",
            })
            score -= 20

        # 7. Fail2ban active
        f2b_ok = subprocess.run(
            ["systemctl", "is-active", "--quiet", "fail2ban"], timeout=5
        ).returncode == 0
        if not f2b_ok:
            findings.append({
                "type": "fail2ban_inactive",
                "severity": "high",
                "message": "Fail2ban is not running",
                "fix": "systemctl start fail2ban && systemctl enable fail2ban",
            })
            score -= 15

        score = max(0, score)
        return {
            "domain": domain,
            "score": score,
            "rating": ("A" if score >= 90 else "B" if score >= 75 else "C" if score >= 60 else "D" if score >= 40 else "F"),
            "findings": findings,
            "scanned_at": datetime.utcnow().isoformat(),
            "ssl_enabled": ssl_enabled,
        }

    def scan_all_sites(self) -> List[Dict]:
        results = []
        sites_root = Path("/var/www/html")
        if sites_root.exists():
            for entry in sorted(sites_root.iterdir()):
                if entry.is_dir() and (entry / "wp-config.php").exists():
                    results.append(self.scan_site(entry.name))
        return results

    def auto_fix(self, domain: str, dry_run: bool = True) -> List[str]:
        """Apply safe automatic fixes. Always dry_run=True unless explicitly set."""
        scan = self.scan_site(domain)
        actions = []
        site_dir = Path(f"/var/www/html/{domain}")

        for finding in scan["findings"]:
            ftype = finding["type"]
            if ftype == "file_permissions":
                cmd = finding["fix"]
                if not dry_run:
                    subprocess.run(cmd, shell=True, timeout=10)
                actions.append(f"{'[DRY-RUN] ' if dry_run else ''}Fixed permissions: {cmd}")
            elif ftype == "exposed_file":
                target = site_dir / finding["file"]
                if not dry_run:
                    target.rename(target.with_suffix(".disabled"))
                actions.append(f"{'[DRY-RUN] ' if dry_run else ''}Disabled: {finding['file']}")

        return actions


scanner = WordPressSecurityScanner()


# ── GDPR helpers ──────────────────────────────────────────────────────────────

class GDPRHelper:
    """Helpers for GDPR-compliant data handling within WordPress sites."""

    @staticmethod
    def export_user_data(domain: str, user_email: str) -> Optional[str]:
        """
        Use WP-CLI to trigger a personal data export for user_email.
        Returns path to the export ZIP, or None on failure.
        """
        wp_path = f"/var/www/html/{domain}"
        if not Path(wp_path).exists():
            return None
        result = subprocess.run(
            ["wp", "--path", wp_path, "--allow-root",
             "user", "export-personal-data", user_email],
            capture_output=True, text=True, timeout=60,
        )
        if result.returncode == 0:
            return result.stdout.strip()
        logger.error("GDPR export failed for %s on %s: %s", user_email, domain, result.stderr[:300])
        return None

    @staticmethod
    def erase_user_data(domain: str, user_email: str) -> bool:
        """Use WP-CLI to erase personal data for user_email."""
        wp_path = f"/var/www/html/{domain}"
        if not Path(wp_path).exists():
            return False
        result = subprocess.run(
            ["wp", "--path", wp_path, "--allow-root",
             "user", "erase-personal-data", user_email],
            capture_output=True, text=True, timeout=60,
        )
        ok = result.returncode == 0
        logger.info("GDPR erase %s on %s: %s", user_email, domain, "OK" if ok else result.stderr[:200])
        return ok

    @staticmethod
    def find_pii_in_logs(log_paths: List[str] = None) -> List[str]:
        """Simple pattern scan for email addresses in log files."""
        if log_paths is None:
            log_paths = [
                "/var/log/nginx/access.log",
                "/var/log/easyinstall/install.log",
            ]
        email_re = re.compile(r"[a-zA-Z0-9._%+\-]+@[a-zA-Z0-9.\-]+\.[a-zA-Z]{2,}")
        hits: List[str] = []
        for lp in log_paths:
            path = Path(lp)
            if not path.exists():
                continue
            for i, line in enumerate(path.read_text(errors="replace").splitlines(), 1):
                matches = email_re.findall(line)
                for m in matches:
                    hits.append(f"{lp}:{i}: {m}")
        return hits


gdpr = GDPRHelper()


# ── Security report generator ─────────────────────────────────────────────────

def generate_security_report(output_file: str = "/root/security-report.txt") -> str:
    """Produce a comprehensive security report for all sites."""
    lines = [
        "=" * 60,
        "EasyInstall v7.0 — Security Report",
        f"Generated: {datetime.utcnow().isoformat()}",
        "=" * 60,
        "",
    ]

    # 1. Certificate status
    lines += ["=== SSL Certificates ==="]
    for cert in ssl_manager.check_all_certificates():
        status_icon = "✅" if cert["status"] == "ok" else "⚠️ " if cert["status"] == "expiring_soon" else "❌"
        days = cert["days_remaining"]
        lines.append(f"  {status_icon} {cert['domain']}: {days} days remaining ({cert['status']})")
    lines.append("")

    # 2. Firewall status
    lines += ["=== Firewall (UFW) ===", firewall.status()[:1000], ""]

    # 3. Fail2ban status
    lines += ["=== Fail2ban ===", fail2ban.status()[:800], ""]

    # 4. WordPress site security scans
    lines += ["=== WordPress Site Security Scores ==="]
    all_scans = scanner.scan_all_sites()
    for scan in all_scans:
        icon = "🟢" if scan["score"] >= 90 else "🟡" if scan["score"] >= 60 else "🔴"
        lines.append(f"  {icon} {scan['domain']}: {scan['score']}/100 (Grade {scan['rating']})")
        for finding in scan["findings"]:
            lines.append(f"      [{finding['severity'].upper()}] {finding.get('message', finding.get('file', ''))}")
            lines.append(f"        Fix: {finding.get('fix', 'See docs')}")
    lines.append("")

    report = "\n".join(lines)
    Path(output_file).write_text(report)
    Path(output_file).chmod(0o600)
    logger.info("Security report written to %s", output_file)
    return output_file


# ── CLI interface ─────────────────────────────────────────────────────────────

if __name__ == "__main__":
    import argparse

    parser = argparse.ArgumentParser(description="EasyInstall Security Module v7.0")
    sub = parser.add_subparsers(dest="cmd", help="Command")

    # ssl
    ssl_p = sub.add_parser("ssl-status", help="Show SSL certificate status for all sites")
    ssl_p.add_argument("--domain", help="Check specific domain only")

    # scan
    scan_p = sub.add_parser("scan", help="Run WordPress security scan")
    scan_p.add_argument("domain", nargs="?", help="Specific domain (omit for all sites)")
    scan_p.add_argument("--fix", action="store_true", help="Auto-apply safe fixes (dry-run by default)")

    # firewall
    fw_p = sub.add_parser("firewall", help="Firewall management")
    fw_p.add_argument("action", choices=["status", "allow", "deny", "list"])
    fw_p.add_argument("--port", type=int)
    fw_p.add_argument("--ip")

    # fail2ban
    f2b_p = sub.add_parser("fail2ban", help="Fail2ban management")
    f2b_p.add_argument("action", choices=["status", "banned", "unban"])
    f2b_p.add_argument("--jail", default="wordpress")
    f2b_p.add_argument("--ip")

    # report
    rep_p = sub.add_parser("report", help="Generate full security report")
    rep_p.add_argument("--output", default="/root/security-report.txt")

    # rotate-jwt
    rot_p = sub.add_parser("rotate-jwt", help="Rotate JWT signing secret (invalidates all tokens)")

    args = parser.parse_args()

    if args.cmd == "ssl-status":
        certs = ssl_manager.check_all_certificates()
        if args.domain:
            certs = [c for c in certs if c["domain"] == args.domain]
        for c in certs:
            icon = "✅" if c["status"] == "ok" else "⚠️ " if c["status"] == "expiring_soon" else "❌"
            print(f"{icon} {c['domain']}: {c['days_remaining']} days ({c['status']})")

    elif args.cmd == "scan":
        if args.domain:
            result = scanner.scan_site(args.domain)
            print(json.dumps(result, indent=2))
            if args.fix:
                fixes = scanner.auto_fix(args.domain, dry_run=not args.fix)
                for f in fixes:
                    print(f)
        else:
            results = scanner.scan_all_sites()
            for r in results:
                icon = "🟢" if r["score"] >= 90 else "🟡" if r["score"] >= 60 else "🔴"
                print(f"{icon} {r['domain']:30s} Score: {r['score']:3d}/100  Grade: {r['rating']}  Issues: {len(r['findings'])}")

    elif args.cmd == "firewall":
        if args.action == "status":
            print(firewall.status())
        elif args.action == "list":
            for rule in firewall.list_rules():
                print(rule)
        elif args.action == "allow" and args.port:
            firewall.allow_port(args.port)
        elif args.action == "deny" and args.port:
            firewall.deny_port(args.port)

    elif args.cmd == "fail2ban":
        if args.action == "status":
            print(fail2ban.status(args.jail))
        elif args.action == "banned":
            ips = fail2ban.get_banned_ips(args.jail)
            print(f"Banned IPs in '{args.jail}':", ", ".join(ips) if ips else "none")
        elif args.action == "unban" and args.ip:
            fail2ban.unban_ip(args.ip, args.jail)

    elif args.cmd == "report":
        report_path = generate_security_report(args.output)
        print(f"Report saved to: {report_path}")

    elif args.cmd == "rotate-jwt":
        new_secret = rotate_jwt_secret()
        print("JWT secret rotated. All existing tokens are now invalid.")
        print("Users must log in again.")

    else:
        parser.print_help()
