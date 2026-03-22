#!/usr/bin/env python3
"""
systemd_plugin.py — EasyInstall Extended Systemd Services Plugin v1.0
=======================================================================
Creates additional systemd service/timer units for:
  - Glances monitoring
  - Extended autoheal
  - Resource governor timer
  - Log rotation service
  - Scheduled backup timer
  - Custom service generator helper
"""

import subprocess
from pathlib import Path
from typing import Dict, List, Optional

try:
    from easyinstall_plugin_manager import BasePlugin, PluginMetadata
except ImportError:
    import sys; sys.path.insert(0, "/usr/local/lib")
    from easyinstall_plugin_manager import BasePlugin, PluginMetadata


# ─────────────────────────────────────────────────────────────────────────────
# Unit templates
# ─────────────────────────────────────────────────────────────────────────────

UNITS: Dict[str, Dict[str, str]] = {

    "glances": {
        "service": """\
[Unit]
Description=EasyInstall — Glances System Monitor
After=network.target

[Service]
Type=simple
ExecStartPre=/bin/sh -c 'command -v glances || pip3 install glances --quiet'
ExecStart=/usr/local/bin/glances -w --port 61208 --disable-browser --quiet
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
""",
    },

    "autoheal-extended": {
        "service": """\
[Unit]
Description=EasyInstall — Extended Autoheal (PHP-FPM + Redis + Nginx)
After=network.target php*-fpm.service nginx.service redis*.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/easyinstall self-heal full
StandardOutput=journal
StandardError=journal
""",
        "timer": """\
[Unit]
Description=EasyInstall — Extended Autoheal Timer

[Timer]
OnBootSec=5min
OnUnitActiveSec=10min
Persistent=true

[Install]
WantedBy=timers.target
""",
    },

    "resource-governor": {
        "service": """\
[Unit]
Description=EasyInstall — Resource Governor (CPU/RAM throttle)
After=network.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/easyinstall optimize
ExecStartPost=/usr/bin/bash -c '\\
    for pid in $(pgrep php-fpm); do \\
        ionice -c 2 -n 4 -p $pid 2>/dev/null || true; \\
    done'
StandardOutput=journal
StandardError=journal
""",
        "timer": """\
[Unit]
Description=EasyInstall — Resource Governor Timer

[Timer]
OnBootSec=2min
OnCalendar=hourly
Persistent=true

[Install]
WantedBy=timers.target
""",
    },

    "log-rotation": {
        "service": """\
[Unit]
Description=EasyInstall — Custom Log Rotation
After=network.target

[Service]
Type=oneshot
ExecStart=/usr/sbin/logrotate /etc/logrotate.d/easyinstall-extended
StandardOutput=journal
StandardError=journal
""",
        "timer": """\
[Unit]
Description=EasyInstall — Log Rotation Timer

[Timer]
OnCalendar=daily
Persistent=true
RandomizedDelaySec=1h

[Install]
WantedBy=timers.target
""",
    },

    "backup-timer": {
        "service": """\
[Unit]
Description=EasyInstall — Scheduled Site Backup
After=network.target mysqld.service mariadb.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/easyinstall backup
StandardOutput=journal
StandardError=journal
""",
        "timer": """\
[Unit]
Description=EasyInstall — Daily Backup Timer

[Timer]
OnCalendar=*-*-* 02:00:00
Persistent=true
RandomizedDelaySec=30min

[Install]
WantedBy=timers.target
""",
    },
}

LOGROTATE_CONF = """\
/var/log/easyinstall/*.log {
    daily
    missingok
    rotate 14
    compress
    delaycompress
    notifempty
    create 0640 root adm
    sharedscripts
    postrotate
        systemctl reload nginx 2>/dev/null || true
    endscript
}

/var/log/nginx/*.log {
    daily
    missingok
    rotate 14
    compress
    delaycompress
    notifempty
    sharedscripts
    postrotate
        systemctl reload nginx 2>/dev/null || true
    endscript
}
"""


class SystemdPlugin(BasePlugin):

    SYSTEMD_DIR  = Path("/etc/systemd/system")
    LOGROTATE_DIR = Path("/etc/logrotate.d")

    def get_metadata(self) -> PluginMetadata:
        return PluginMetadata(
            name        = "systemd-extended",
            version     = "1.0.0",
            description = "Extended systemd units: Glances, autoheal, resource governor, backup timer",
            author      = "EasyInstall",
            requires    = ["systemd"],
            provides    = ["glances", "autoheal-timer", "backup-timer", "log-rotation"],
        )

    def initialize(self) -> bool:
        if not self.require_binary("systemctl"):
            self.logger.error("systemd is required")
            return False
        return True

    # ── Core methods ──────────────────────────────────────────────────────────

    def _write_unit(self, name: str, unit_type: str, content: str) -> Path:
        path = self.SYSTEMD_DIR / f"easyinstall-{name}.{unit_type}"
        path.write_text(content)
        self.logger.info(f"Unit written: {path.name}")
        return path

    def enable_unit(self, unit_name: str) -> bool:
        """Enable and optionally start a unit."""
        result = subprocess.run(
            ["systemctl", "enable", "--now", unit_name],
            capture_output=True, text=True
        )
        if result.returncode == 0:
            self.logger.info(f"Enabled: {unit_name}")
            return True
        self.logger.warning(f"Enable failed [{unit_name}]: {result.stderr.strip()}")
        return False

    def install_all(self) -> List[str]:
        """Install all extended units and return list of enabled unit names."""
        # logrotate config
        self.LOGROTATE_DIR.mkdir(exist_ok=True)
        (self.LOGROTATE_DIR / "easyinstall-extended").write_text(LOGROTATE_CONF)

        installed = []
        for name, parts in UNITS.items():
            for unit_type, content in parts.items():
                self._write_unit(name, unit_type, content)
            # Reload daemon once per unit group
            subprocess.run(["systemctl", "daemon-reload"], capture_output=True)
            unit_file = f"easyinstall-{name}.{'timer' if 'timer' in parts else 'service'}"
            if self.enable_unit(unit_file):
                installed.append(unit_file)

        self.logger.info(f"Installed {len(installed)} extended units")
        return installed

    def install_unit(self, unit_name: str) -> bool:
        """Install and enable a single named unit."""
        if unit_name not in UNITS:
            self.logger.error(f"Unknown unit: {unit_name}. Available: {list(UNITS.keys())}")
            return False
        for utype, content in UNITS[unit_name].items():
            self._write_unit(unit_name, utype, content)
        subprocess.run(["systemctl", "daemon-reload"], capture_output=True)
        unit_file = f"easyinstall-{unit_name}.{'timer' if 'timer' in UNITS[unit_name] else 'service'}"
        return self.enable_unit(unit_file)

    def generate_custom_unit(self, name: str, description: str,
                              exec_start: str, interval: Optional[str] = None,
                              output_dir: str = "/etc/systemd/system") -> List[str]:
        """
        Generate a custom service (and optionally timer) unit.
        Returns list of written paths.
        """
        svc = f"""\
[Unit]
Description={description}
After=network.target

[Service]
Type=oneshot
ExecStart={exec_start}
StandardOutput=journal
StandardError=journal
"""
        paths = []
        svc_path = Path(output_dir) / f"easyinstall-custom-{name}.service"
        svc_path.write_text(svc)
        paths.append(str(svc_path))

        if interval:
            tmr = f"""\
[Unit]
Description={description} Timer

[Timer]
OnCalendar={interval}
Persistent=true

[Install]
WantedBy=timers.target
"""
            tmr_path = Path(output_dir) / f"easyinstall-custom-{name}.timer"
            tmr_path.write_text(tmr)
            paths.append(str(tmr_path))

        subprocess.run(["systemctl", "daemon-reload"], capture_output=True)
        self.logger.info(f"Custom unit(s) written: {paths}")
        return paths

    def list_units(self) -> List[str]:
        """List all easyinstall-*.service/timer units in systemd dir."""
        return [p.name for p in self.SYSTEMD_DIR.glob("easyinstall-*")]
