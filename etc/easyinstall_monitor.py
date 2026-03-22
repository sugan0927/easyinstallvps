#!/usr/bin/env python3
"""
EasyInstall Enterprise Monitoring Module — v7.0
================================================
Prometheus metrics collector, anomaly detection, alerting,
Grafana dashboard template generator, and real-time performance watcher.

Deploy to: /usr/local/lib/easyinstall_monitor.py
Daemon:    systemctl start easyinstall-monitor
CLI:       easyinstall monitor [domain]
"""

import os
import re
import json
import time
import logging
import math
import subprocess
from datetime import datetime, timedelta
from pathlib import Path
from typing import Optional, List, Dict, Any, Tuple

# ── Logging ───────────────────────────────────────────────────────────────────

LOG_DIR = Path("/var/log/easyinstall")
LOG_DIR.mkdir(parents=True, exist_ok=True)

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s — %(message)s",
    handlers=[
        logging.FileHandler(LOG_DIR / "monitor.log"),
        logging.StreamHandler(),
    ],
)
logger = logging.getLogger("easyinstall.monitor")

CONFIG_DIR = Path("/etc/easyinstall")
CONFIG_DIR.mkdir(parents=True, exist_ok=True)

_DEFAULT_MON_CFG: Dict[str, Any] = {
    "poll_interval_seconds": 60,
    "metrics_history_hours": 24,
    "alert_cpu_threshold": 85.0,
    "alert_memory_threshold": 90.0,
    "alert_disk_threshold": 85.0,
    "alert_redis_memory_mb": 512,
    "prometheus_enabled": False,
    "prometheus_port": 9090,
    "alertmanager_url": "",
    "slack_webhook": "",
    "email_alerts": "",
}

def _load_mon_cfg() -> Dict[str, Any]:
    cfg = dict(_DEFAULT_MON_CFG)
    conf_file = CONFIG_DIR / "monitoring.conf"
    if conf_file.exists():
        try:
            cfg.update(json.loads(conf_file.read_text()))
        except Exception as exc:
            logger.warning("Failed to parse monitoring.conf: %s", exc)
    return cfg

MON_CFG = _load_mon_cfg()

# ── System metric collectors ──────────────────────────────────────────────────

def _run(cmd: str, timeout: int = 10) -> str:
    """Run a shell command and return stdout, or empty string on failure."""
    try:
        r = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=timeout)
        return r.stdout.strip()
    except Exception:
        return ""


def collect_system_metrics() -> Dict[str, Any]:
    """Collect server-wide metrics without requiring root."""
    metrics: Dict[str, Any] = {
        "timestamp": datetime.utcnow().isoformat(),
        "cpu_usage": 0.0,
        "memory_total_mb": 0,
        "memory_used_mb": 0,
        "memory_usage_pct": 0.0,
        "disk_total_gb": 0.0,
        "disk_used_gb": 0.0,
        "disk_usage_pct": 0.0,
        "load_1m": 0.0,
        "load_5m": 0.0,
        "load_15m": 0.0,
        "cpu_cores": 1,
        "uptime_seconds": 0,
        "tcp_connections": 0,
        "nginx_active_connections": 0,
    }

    # CPU — read /proc/stat twice 1 second apart
    def _cpu_pct() -> float:
        try:
            def _parse(line: str) -> Tuple[int, int]:
                parts = list(map(int, line.split()[1:]))
                idle = parts[3]
                total = sum(parts)
                return idle, total
            lines1 = Path("/proc/stat").read_text().splitlines()
            time.sleep(1)
            lines2 = Path("/proc/stat").read_text().splitlines()
            idle1, total1 = _parse(lines1[0])
            idle2, total2 = _parse(lines2[0])
            delta_total = total2 - total1
            delta_idle = idle2 - idle1
            if delta_total == 0:
                return 0.0
            return round(100.0 * (1 - delta_idle / delta_total), 1)
        except Exception:
            return 0.0

    metrics["cpu_usage"] = _cpu_pct()

    # Memory
    mem_raw = _run("cat /proc/meminfo")
    for line in mem_raw.splitlines():
        if line.startswith("MemTotal:"):
            metrics["memory_total_mb"] = int(line.split()[1]) // 1024
        elif line.startswith("MemAvailable:"):
            avail = int(line.split()[1]) // 1024
            metrics["memory_used_mb"] = metrics["memory_total_mb"] - avail
    if metrics["memory_total_mb"]:
        metrics["memory_usage_pct"] = round(
            metrics["memory_used_mb"] / metrics["memory_total_mb"] * 100, 1
        )

    # Disk
    df_out = _run("df -BG /")
    for line in df_out.splitlines()[1:]:
        parts = line.split()
        if len(parts) >= 5:
            metrics["disk_total_gb"] = int(parts[1].rstrip("G"))
            metrics["disk_used_gb"] = int(parts[2].rstrip("G"))
            metrics["disk_usage_pct"] = float(parts[4].rstrip("%"))

    # Load averages
    try:
        load_line = Path("/proc/loadavg").read_text()
        parts = load_line.split()
        metrics["load_1m"] = float(parts[0])
        metrics["load_5m"] = float(parts[1])
        metrics["load_15m"] = float(parts[2])
    except Exception:
        pass

    # CPU cores
    cores = _run("nproc")
    if cores.isdigit():
        metrics["cpu_cores"] = int(cores)

    # Uptime
    try:
        uptime_sec = float(Path("/proc/uptime").read_text().split()[0])
        metrics["uptime_seconds"] = int(uptime_sec)
    except Exception:
        pass

    # TCP connections
    ss_out = _run("ss -s")
    m = re.search(r"estab (\d+)", ss_out, re.IGNORECASE)
    if m:
        metrics["tcp_connections"] = int(m.group(1))

    # Nginx active connections via stub_status (if available)
    nginx_status = _run("curl -s --max-time 3 http://127.0.0.1/nginx-status 2>/dev/null || true")
    m = re.search(r"Active connections:\s*(\d+)", nginx_status)
    if m:
        metrics["nginx_active_connections"] = int(m.group(1))

    return metrics


def collect_site_metrics(domain: str) -> Dict[str, Any]:
    """Collect per-site metrics: PHP-FPM pool, Redis, MySQL, disk."""
    metrics: Dict[str, Any] = {
        "domain": domain,
        "timestamp": datetime.utcnow().isoformat(),
        "php_fpm_active": 0,
        "php_fpm_idle": 0,
        "php_fpm_total": 0,
        "redis_connected_clients": 0,
        "redis_used_memory_mb": 0.0,
        "redis_hit_rate_pct": 0.0,
        "redis_keyspace_hits": 0,
        "redis_keyspace_misses": 0,
        "mysql_threads_connected": 0,
        "mysql_slow_queries": 0,
        "mysql_qps": 0.0,
        "site_disk_mb": 0,
    }

    domain_slug = domain.replace(".", "-")

    # Redis
    redis_port = 6379
    redis_conf = Path(f"/etc/redis/redis-{domain_slug}.conf")
    if redis_conf.exists():
        for line in redis_conf.read_text().splitlines():
            if line.startswith("port "):
                try:
                    redis_port = int(line.split()[1])
                except (ValueError, IndexError):
                    pass
        redis_info = _run(f"redis-cli -p {redis_port} INFO ALL")
        for line in redis_info.splitlines():
            if ":" not in line:
                continue
            k, _, v = line.partition(":")
            k, v = k.strip(), v.strip()
            if k == "connected_clients":
                metrics["redis_connected_clients"] = int(v) if v.isdigit() else 0
            elif k == "used_memory":
                metrics["redis_used_memory_mb"] = round(int(v) / 1024 / 1024, 2) if v.isdigit() else 0
            elif k == "keyspace_hits":
                metrics["redis_keyspace_hits"] = int(v) if v.isdigit() else 0
            elif k == "keyspace_misses":
                metrics["redis_keyspace_misses"] = int(v) if v.isdigit() else 0
        hits = metrics["redis_keyspace_hits"]
        misses = metrics["redis_keyspace_misses"]
        total = hits + misses
        if total > 0:
            metrics["redis_hit_rate_pct"] = round(hits / total * 100, 1)

    # PHP-FPM pool status for this site
    for ver in ("8.4", "8.3", "8.2"):
        pool_status_url = f"http://127.0.0.1/php{ver}-fpm-status-{domain_slug}"
        status_out = _run(f"curl -s --max-time 3 '{pool_status_url}' 2>/dev/null || true")
        if status_out:
            m = re.search(r"active processes:\s*(\d+)", status_out)
            if m:
                metrics["php_fpm_active"] = int(m.group(1))
            m = re.search(r"idle processes:\s*(\d+)", status_out)
            if m:
                metrics["php_fpm_idle"] = int(m.group(1))
            metrics["php_fpm_total"] = metrics["php_fpm_active"] + metrics["php_fpm_idle"]
            break

    # MySQL
    mysql_out = _run("mysql -N -e \"SHOW GLOBAL STATUS WHERE Variable_name IN "
                     "('Threads_connected','Slow_queries','Questions');\" 2>/dev/null || true")
    for line in mysql_out.splitlines():
        parts = line.split()
        if len(parts) >= 2:
            if parts[0] == "Threads_connected":
                metrics["mysql_threads_connected"] = int(parts[1])
            elif parts[0] == "Slow_queries":
                metrics["mysql_slow_queries"] = int(parts[1])
            elif parts[0] == "Questions":
                metrics["mysql_qps"] = int(parts[1])  # raw count, not rate

    # Site disk usage
    du_out = _run(f"du -sm /var/www/html/{domain} 2>/dev/null || true")
    if du_out:
        try:
            metrics["site_disk_mb"] = int(du_out.split()[0])
        except (ValueError, IndexError):
            pass

    return metrics


# ── Anomaly detection (simple z-score, no sklearn required) ──────────────────

class AnomalyDetector:
    """
    Simple rolling z-score anomaly detector.
    Flags a value as anomalous when it deviates more than `threshold` sigma
    from the recent rolling mean.
    """

    def __init__(self, window: int = 60, threshold: float = 3.0):
        self._window = window
        self._threshold = threshold
        self._history: Dict[str, List[float]] = {}

    def update(self, metric_name: str, value: float) -> bool:
        """Add a new value and return True if it is anomalous."""
        buf = self._history.setdefault(metric_name, [])
        buf.append(value)
        if len(buf) > self._window:
            buf.pop(0)
        if len(buf) < 10:
            return False  # need warm-up data
        n = len(buf)
        mean = sum(buf) / n
        variance = sum((x - mean) ** 2 for x in buf) / n
        std = math.sqrt(variance)
        if std < 0.01:
            return False
        z = abs(value - mean) / std
        return z > self._threshold

    def get_baseline(self, metric_name: str) -> Dict[str, float]:
        buf = self._history.get(metric_name, [])
        if not buf:
            return {}
        mean = sum(buf) / len(buf)
        variance = sum((x - mean) ** 2 for x in buf) / len(buf)
        return {"mean": round(mean, 2), "std": round(math.sqrt(variance), 2), "samples": len(buf)}


# ── Alerting ──────────────────────────────────────────────────────────────────

class AlertDispatcher:
    """Send alerts via Slack webhook, email, or write to a local alert log."""

    ALERT_LOG = LOG_DIR / "alerts.log"

    def _write_log(self, level: str, title: str, message: str, domain: str = None):
        entry = {
            "timestamp": datetime.utcnow().isoformat(),
            "level": level,
            "domain": domain,
            "title": title,
            "message": message,
        }
        with self.ALERT_LOG.open("a") as f:
            f.write(json.dumps(entry) + "\n")

    def send_slack(self, title: str, message: str, level: str = "warning", domain: str = None) -> bool:
        webhook = MON_CFG.get("slack_webhook", "")
        if not webhook:
            return False
        emoji = {"critical": "🔴", "warning": "🟡", "info": "🟢"}.get(level, "⚪")
        text = f"{emoji} *EasyInstall Alert* — {title}\n{message}"
        if domain:
            text += f"\nSite: `{domain}`"
        try:
            result = subprocess.run(
                ["curl", "-s", "-X", "POST", webhook,
                 "-H", "Content-Type: application/json",
                 "-d", json.dumps({"text": text})],
                capture_output=True, timeout=15,
            )
            return result.returncode == 0
        except Exception as exc:
            logger.error("Slack webhook failed: %s", exc)
            return False

    def send_email(self, subject: str, body: str) -> bool:
        email = MON_CFG.get("email_alerts", "")
        if not email:
            return False
        try:
            result = subprocess.run(
                ["mail", "-s", subject, email],
                input=body.encode(), capture_output=True, timeout=30,
            )
            return result.returncode == 0
        except Exception as exc:
            logger.error("Email alert failed: %s", exc)
            return False

    def alert(self, title: str, message: str, level: str = "warning", domain: str = None):
        self._write_log(level, title, message, domain)
        self.send_slack(title, message, level, domain)
        if level == "critical":
            self.send_email(f"[CRITICAL] {title}", message)
        logger.warning("[%s] %s: %s", level.upper(), title, message[:200])

    def get_recent_alerts(self, hours: int = 24) -> List[Dict]:
        if not self.ALERT_LOG.exists():
            return []
        cutoff = (datetime.utcnow() - timedelta(hours=hours)).isoformat()
        results = []
        for line in self.ALERT_LOG.read_text().splitlines():
            try:
                entry = json.loads(line)
                if entry.get("timestamp", "") >= cutoff:
                    results.append(entry)
            except json.JSONDecodeError:
                pass
        return results[-200:]


dispatcher = AlertDispatcher()
anomaly_detector = AnomalyDetector()


# ── Threshold checking ────────────────────────────────────────────────────────

def _check_thresholds(sys_metrics: Dict, site_metrics: Dict = None) -> List[Dict]:
    """Compare collected metrics against configured thresholds and return alerts."""
    alerts = []
    domain = (site_metrics or {}).get("domain", "system")

    cpu = sys_metrics.get("cpu_usage", 0)
    if cpu > MON_CFG["alert_cpu_threshold"]:
        alerts.append({
            "title": "High CPU Usage",
            "message": f"CPU at {cpu}% (threshold: {MON_CFG['alert_cpu_threshold']}%)",
            "level": "critical" if cpu > 95 else "warning",
            "domain": domain,
        })
    if anomaly_detector.update("cpu", cpu):
        baseline = anomaly_detector.get_baseline("cpu")
        alerts.append({
            "title": "CPU Anomaly Detected",
            "message": f"CPU {cpu}% deviates significantly from baseline {baseline}",
            "level": "warning",
            "domain": domain,
        })

    mem = sys_metrics.get("memory_usage_pct", 0)
    if mem > MON_CFG["alert_memory_threshold"]:
        alerts.append({
            "title": "High Memory Usage",
            "message": f"Memory at {mem}% (threshold: {MON_CFG['alert_memory_threshold']}%)",
            "level": "critical" if mem > 97 else "warning",
            "domain": domain,
        })

    disk = sys_metrics.get("disk_usage_pct", 0)
    if disk > MON_CFG["alert_disk_threshold"]:
        alerts.append({
            "title": "High Disk Usage",
            "message": f"Disk at {disk}% (threshold: {MON_CFG['alert_disk_threshold']}%)",
            "level": "critical" if disk > 95 else "warning",
            "domain": domain,
        })

    if site_metrics:
        redis_mb = site_metrics.get("redis_used_memory_mb", 0)
        if redis_mb > MON_CFG["alert_redis_memory_mb"]:
            alerts.append({
                "title": "Redis Memory High",
                "message": f"Redis using {redis_mb}MB for {domain} (threshold: {MON_CFG['alert_redis_memory_mb']}MB)",
                "level": "warning",
                "domain": domain,
            })

    return alerts


# ── Prometheus metrics exporter ───────────────────────────────────────────────

class PrometheusExporter:
    """
    Minimal Prometheus text format exporter.
    Exposes metrics at http://HOST:9091/metrics
    """

    PORT = int(MON_CFG.get("prometheus_port", 9091))

    def build_metrics_text(self) -> str:
        sys_m = collect_system_metrics()
        lines = [
            "# HELP easyinstall_cpu_usage CPU usage percentage",
            "# TYPE easyinstall_cpu_usage gauge",
            f"easyinstall_cpu_usage {sys_m['cpu_usage']}",
            "# HELP easyinstall_memory_usage Memory usage percentage",
            "# TYPE easyinstall_memory_usage gauge",
            f"easyinstall_memory_usage {sys_m['memory_usage_pct']}",
            "# HELP easyinstall_disk_usage Disk usage percentage",
            "# TYPE easyinstall_disk_usage gauge",
            f"easyinstall_disk_usage {sys_m['disk_usage_pct']}",
            "# HELP easyinstall_load_1m 1-minute load average",
            "# TYPE easyinstall_load_1m gauge",
            f"easyinstall_load_1m {sys_m['load_1m']}",
            "# HELP easyinstall_tcp_connections Active TCP connections",
            "# TYPE easyinstall_tcp_connections gauge",
            f"easyinstall_tcp_connections {sys_m['tcp_connections']}",
        ]
        # Per-site Redis metrics
        sites_root = Path("/var/www/html")
        if sites_root.exists():
            for entry in sites_root.iterdir():
                if entry.is_dir() and (entry / "wp-config.php").exists():
                    sm = collect_site_metrics(entry.name)
                    label = f'domain="{entry.name}"'
                    lines += [
                        f"easyinstall_redis_memory_mb{{{label}}} {sm['redis_used_memory_mb']}",
                        f"easyinstall_redis_hit_rate{{{label}}} {sm['redis_hit_rate_pct']}",
                        f"easyinstall_site_disk_mb{{{label}}} {sm['site_disk_mb']}",
                    ]
        return "\n".join(lines) + "\n"

    def start(self):
        from http.server import HTTPServer, BaseHTTPRequestHandler

        exporter = self

        class Handler(BaseHTTPRequestHandler):
            def do_GET(self):
                if self.path == "/metrics":
                    body = exporter.build_metrics_text().encode()
                    self.send_response(200)
                    self.send_header("Content-Type", "text/plain; charset=utf-8")
                    self.send_header("Content-Length", len(body))
                    self.end_headers()
                    self.wfile.write(body)
                else:
                    self.send_response(404)
                    self.end_headers()

            def log_message(self, fmt, *args):
                pass  # silence access log

        server = HTTPServer(("0.0.0.0", self.PORT), Handler)
        logger.info("Prometheus exporter listening on port %s/metrics", self.PORT)
        server.serve_forever()


# ── Grafana dashboard template ────────────────────────────────────────────────

def generate_grafana_dashboard(output_dir: str = "/etc/easyinstall/grafana") -> str:
    """Write a Grafana dashboard JSON template for EasyInstall metrics."""
    dashboard = {
        "title": "EasyInstall v7.0 — WordPress Infrastructure",
        "uid": "easyinstall-main",
        "schemaVersion": 36,
        "version": 1,
        "refresh": "30s",
        "panels": [
            {
                "id": 1, "title": "CPU Usage %", "type": "timeseries",
                "datasource": "Prometheus",
                "targets": [{"expr": "easyinstall_cpu_usage", "legendFormat": "CPU %"}],
                "gridPos": {"h": 8, "w": 12, "x": 0, "y": 0},
                "fieldConfig": {"defaults": {"unit": "percent", "max": 100}},
            },
            {
                "id": 2, "title": "Memory Usage %", "type": "timeseries",
                "datasource": "Prometheus",
                "targets": [{"expr": "easyinstall_memory_usage", "legendFormat": "Memory %"}],
                "gridPos": {"h": 8, "w": 12, "x": 12, "y": 0},
                "fieldConfig": {"defaults": {"unit": "percent", "max": 100}},
            },
            {
                "id": 3, "title": "Disk Usage %", "type": "gauge",
                "datasource": "Prometheus",
                "targets": [{"expr": "easyinstall_disk_usage", "legendFormat": "Disk %"}],
                "gridPos": {"h": 8, "w": 6, "x": 0, "y": 8},
                "fieldConfig": {"defaults": {"unit": "percent", "max": 100,
                                             "thresholds": {"steps": [
                                                 {"color": "green", "value": 0},
                                                 {"color": "yellow", "value": 75},
                                                 {"color": "red", "value": 90},
                                             ]}}},
            },
            {
                "id": 4, "title": "TCP Connections", "type": "stat",
                "datasource": "Prometheus",
                "targets": [{"expr": "easyinstall_tcp_connections", "legendFormat": "Connections"}],
                "gridPos": {"h": 4, "w": 6, "x": 6, "y": 8},
            },
            {
                "id": 5, "title": "Redis Memory per Site (MB)", "type": "bargauge",
                "datasource": "Prometheus",
                "targets": [{"expr": "easyinstall_redis_memory_mb",
                             "legendFormat": "{{domain}}"}],
                "gridPos": {"h": 8, "w": 12, "x": 12, "y": 8},
                "fieldConfig": {"defaults": {"unit": "decmbytes"}},
            },
        ],
    }
    out_dir = Path(output_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    output_file = out_dir / "dashboard.json"
    output_file.write_text(json.dumps(dashboard, indent=2))
    logger.info("Grafana dashboard written to %s", output_file)
    return str(output_file)


# ── Monitoring daemon ─────────────────────────────────────────────────────────

def run_monitor_daemon():
    """
    Poll metrics every MON_CFG['poll_interval_seconds'] seconds.
    Writes metrics to the EasyInstall DB and triggers alerts.
    """
    try:
        from easyinstall_db import get_db
        db = get_db()
        _db_available = True
    except ImportError:
        logger.warning("easyinstall_db not available — metrics will not be persisted")
        _db_available = False

    logger.info("Monitor daemon started (interval=%ds)", MON_CFG["poll_interval_seconds"])
    poll_interval = int(MON_CFG["poll_interval_seconds"])

    while True:
        try:
            sys_metrics = collect_system_metrics()
            alerts = _check_thresholds(sys_metrics)

            # Per-site
            sites_root = Path("/var/www/html")
            if sites_root.exists():
                for entry in sites_root.iterdir():
                    if entry.is_dir() and (entry / "wp-config.php").exists():
                        domain = entry.name
                        site_metrics = collect_site_metrics(domain)
                        merged = {**sys_metrics, **site_metrics}

                        if _db_available:
                            db.record_metric(domain, merged)

                        site_alerts = _check_thresholds(sys_metrics, site_metrics)
                        alerts.extend(site_alerts)

            # Dispatch alerts
            for alert in alerts:
                dispatcher.alert(
                    title=alert["title"],
                    message=alert["message"],
                    level=alert.get("level", "warning"),
                    domain=alert.get("domain"),
                )

        except Exception as exc:
            logger.error("Monitor cycle error: %s", exc)

        time.sleep(poll_interval)


# ── CLI ───────────────────────────────────────────────────────────────────────

if __name__ == "__main__":
    import argparse

    parser = argparse.ArgumentParser(description="EasyInstall Monitor v7.0")
    sub = parser.add_subparsers(dest="cmd")

    sub.add_parser("daemon", help="Run monitoring daemon (blocks)")
    sub.add_parser("system", help="Print current system metrics as JSON")
    sub.add_parser("sites", help="Print per-site metrics for all sites")

    site_p = sub.add_parser("site", help="Print metrics for one site")
    site_p.add_argument("domain")

    sub.add_parser("alerts", help="Show recent alerts (last 24h)")
    sub.add_parser("prometheus", help="Start Prometheus metrics exporter")
    sub.add_parser("grafana", help="Generate Grafana dashboard template")

    args = parser.parse_args()

    if args.cmd == "daemon":
        run_monitor_daemon()

    elif args.cmd == "system":
        print(json.dumps(collect_system_metrics(), indent=2))

    elif args.cmd == "sites":
        sites_root = Path("/var/www/html")
        all_metrics = []
        if sites_root.exists():
            for entry in sites_root.iterdir():
                if entry.is_dir() and (entry / "wp-config.php").exists():
                    all_metrics.append(collect_site_metrics(entry.name))
        print(json.dumps(all_metrics, indent=2))

    elif args.cmd == "site":
        print(json.dumps(collect_site_metrics(args.domain), indent=2))

    elif args.cmd == "alerts":
        recent = dispatcher.get_recent_alerts()
        for a in recent:
            level = a.get("level", "info").upper()
            icon = "🔴" if level == "CRITICAL" else "🟡" if level == "WARNING" else "🟢"
            print(f"{icon} [{a['timestamp']}] {a['title']} — {a['message'][:100]}")

    elif args.cmd == "prometheus":
        PrometheusExporter().start()

    elif args.cmd == "grafana":
        path = generate_grafana_dashboard()
        print(f"Grafana dashboard saved to: {path}")

    else:
        # Default: pretty-print system summary
        m = collect_system_metrics()
        print(f"\n{'='*50}")
        print("  EasyInstall Monitor v7.0 — System Summary")
        print(f"{'='*50}")
        print(f"  CPU     : {m['cpu_usage']}%")
        print(f"  Memory  : {m['memory_usage_pct']}%  ({m['memory_used_mb']}MB / {m['memory_total_mb']}MB)")
        print(f"  Disk    : {m['disk_usage_pct']}%  ({m['disk_used_gb']}GB / {m['disk_total_gb']}GB)")
        print(f"  Load    : {m['load_1m']} / {m['load_5m']} / {m['load_15m']} (1/5/15m)")
        print(f"  Conns   : {m['tcp_connections']} TCP")
        print(f"  Uptime  : {m['uptime_seconds'] // 3600}h {(m['uptime_seconds'] % 3600) // 60}m")
        print()
