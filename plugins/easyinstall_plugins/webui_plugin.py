#!/usr/bin/env python3
"""
webui_plugin.py — EasyInstall Web UI Plugin v1.0
=================================================
Flask-based dashboard for managing WordPress sites, viewing metrics,
and controlling other EasyInstall plugins — all from a browser.

Start : easyinstall-plugin webui start [--port 8080]
Stop  : easyinstall-plugin webui stop
"""

import subprocess
import signal
import sys
from pathlib import Path
from typing import Optional

try:
    from easyinstall_plugin_manager import BasePlugin, PluginMetadata
except ImportError:
    sys.path.insert(0, "/usr/local/lib")
    from easyinstall_plugin_manager import BasePlugin, PluginMetadata


# ─────────────────────────────────────────────────────────────────────────────
# HTML / JS dashboard (self-contained single-file)
# ─────────────────────────────────────────────────────────────────────────────

DASHBOARD_HTML = """\
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8" />
<meta name="viewport" content="width=device-width, initial-scale=1.0" />
<title>EasyInstall Dashboard</title>
<style>
  :root {
    --bg: #0f1117; --surface: #1a1d2e; --border: #2d3050;
    --accent: #6c63ff; --green: #00d084; --red: #ff5f5f;
    --text: #e2e4f0; --muted: #8b8fac;
    --font: 'Inter', 'Segoe UI', system-ui, sans-serif;
  }
  * { box-sizing: border-box; margin: 0; padding: 0; }
  body { background: var(--bg); color: var(--text); font-family: var(--font); }
  header {
    background: var(--surface); border-bottom: 1px solid var(--border);
    padding: 16px 24px; display: flex; align-items: center; gap: 12px;
  }
  header h1 { font-size: 1.2rem; font-weight: 600; }
  header span.badge {
    background: var(--accent); color: #fff; font-size: 0.7rem;
    padding: 2px 8px; border-radius: 20px; font-weight: 600;
  }
  main { padding: 24px; max-width: 1200px; margin: 0 auto; }
  .grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(280px, 1fr)); gap: 16px; margin-bottom: 24px; }
  .card {
    background: var(--surface); border: 1px solid var(--border);
    border-radius: 12px; padding: 20px;
  }
  .card h3 { font-size: 0.85rem; color: var(--muted); margin-bottom: 8px; text-transform: uppercase; letter-spacing: .05em; }
  .card .val { font-size: 2rem; font-weight: 700; }
  .card .val.green { color: var(--green); }
  .card .val.red   { color: var(--red);   }
  table { width: 100%; border-collapse: collapse; background: var(--surface); border-radius: 12px; overflow: hidden; border: 1px solid var(--border); }
  th, td { padding: 12px 16px; text-align: left; font-size: 0.9rem; }
  th { background: #1e2140; color: var(--muted); font-weight: 600; text-transform: uppercase; letter-spacing: .05em; font-size: 0.75rem; }
  tr + tr td { border-top: 1px solid var(--border); }
  .pill {
    display: inline-block; padding: 2px 10px; border-radius: 20px;
    font-size: 0.75rem; font-weight: 600;
  }
  .pill.ok  { background: #00d08420; color: var(--green); }
  .pill.err { background: #ff5f5f20; color: var(--red);   }
  .section-title { font-size: 1rem; font-weight: 600; margin: 24px 0 12px; }
  button {
    background: var(--accent); color: #fff; border: none; padding: 8px 16px;
    border-radius: 8px; cursor: pointer; font-size: 0.85rem; font-weight: 600;
  }
  button:hover { opacity: 0.85; }
  button.danger { background: var(--red); }
  #log {
    background: #0a0c14; border: 1px solid var(--border); border-radius: 8px;
    padding: 16px; font-family: monospace; font-size: 0.82rem; color: #b0b4d0;
    height: 200px; overflow-y: auto; white-space: pre-wrap;
  }
</style>
</head>
<body>
<header>
  <span style="font-size:1.5rem">⚡</span>
  <h1>EasyInstall Dashboard</h1>
  <span class="badge">v7.0</span>
</header>
<main>
  <div class="grid" id="stats"></div>
  <div style="display:flex;align-items:center;justify-content:space-between">
    <div class="section-title">WordPress Sites</div>
    <button onclick="refreshSites()">↻ Refresh</button>
  </div>
  <table>
    <thead><tr><th>Domain</th><th>PHP</th><th>Redis</th><th>SSL</th><th>Status</th><th>Actions</th></tr></thead>
    <tbody id="sites"></tbody>
  </table>
  <div class="section-title">Plugins</div>
  <table>
    <thead><tr><th>Plugin</th><th>Version</th><th>State</th><th>Description</th><th>Actions</th></tr></thead>
    <tbody id="plugins"></tbody>
  </table>
  <div class="section-title">System Log</div>
  <div id="log">Loading log…</div>
</main>
<script>
async function api(path) {
  try { const r = await fetch(path); return r.ok ? r.json() : null; }
  catch { return null; }
}
async function refreshStats() {
  const d = await api('/api/stats');
  if (!d) return;
  const el = document.getElementById('stats');
  el.innerHTML = [
    ['Sites', d.sites ?? '—', 'green'],
    ['CPU %', d.cpu ?? '—', d.cpu > 80 ? 'red' : 'green'],
    ['RAM %', d.ram ?? '—', d.ram > 90 ? 'red' : 'green'],
    ['Disk %', d.disk ?? '—', d.disk > 90 ? 'red' : 'green'],
  ].map(([k,v,cls]) => `
    <div class="card">
      <h3>${k}</h3>
      <div class="val ${cls}">${v}</div>
    </div>`).join('');
}
async function refreshSites() {
  const d = await api('/api/sites');
  if (!d) return;
  document.getElementById('sites').innerHTML = d.map(s => `
    <tr>
      <td><strong>${s.domain}</strong></td>
      <td>${s.php ?? '—'}</td>
      <td><span class="pill ${s.redis ? 'ok':'err'}">${s.redis ? 'ON':'OFF'}</span></td>
      <td><span class="pill ${s.ssl   ? 'ok':'err'}">${s.ssl   ? 'ON':'OFF'}</span></td>
      <td><span class="pill ${s.status==='ok'?'ok':'err'}">${s.status}</span></td>
      <td>
        <button onclick="siteAction('${s.domain}','info')">Info</button>
      </td>
    </tr>`).join('') || '<tr><td colspan="6" style="color:var(--muted);text-align:center">No sites found</td></tr>';
}
async function refreshPlugins() {
  const d = await api('/api/plugins');
  if (!d) return;
  document.getElementById('plugins').innerHTML = d.map(p => `
    <tr>
      <td><strong>${p.module}</strong></td>
      <td>${p.version}</td>
      <td><span class="pill ${p.state==='enabled'?'ok':'err'}">${p.state}</span></td>
      <td>${p.description}</td>
      <td>
        ${p.state!=='enabled'
          ? `<button onclick="pluginAction('${p.module}','enable')">Enable</button>`
          : `<button class="danger" onclick="pluginAction('${p.module}','disable')">Disable</button>`}
      </td>
    </tr>`).join('');
}
async function refreshLog() {
  const d = await api('/api/log');
  if (d) { const el = document.getElementById('log'); el.textContent = d.lines.join(''); el.scrollTop = el.scrollHeight; }
}
async function siteAction(domain, action) {
  const d = await api(`/api/site/${action}?domain=${encodeURIComponent(domain)}`);
  alert(JSON.stringify(d, null, 2));
}
async function pluginAction(name, action) {
  await fetch(`/api/plugin/${action}`, {method:'POST', headers:{'Content-Type':'application/json'}, body: JSON.stringify({name})});
  refreshPlugins();
}
function init() { refreshStats(); refreshSites(); refreshPlugins(); refreshLog(); }
setInterval(refreshStats, 10000);
setInterval(refreshLog,   5000);
init();
</script>
</body>
</html>
"""

FLASK_APP = """\
#!/usr/bin/env python3
\"\"\"EasyInstall Web UI — Flask server (generated by webui_plugin)\"\"\"
import os, sys, json, shutil, subprocess
from pathlib import Path
from flask import Flask, jsonify, request, send_from_directory

sys.path.insert(0, "/usr/local/lib")
try:
    from easyinstall_plugin_manager import PluginManager
    pm = PluginManager()
except Exception:
    pm = None

app = Flask(__name__, static_folder=None)
DASH_HTML = Path(__file__).parent / "dashboard.html"

@app.route("/")
def index():
    return DASH_HTML.read_text(), 200, {"Content-Type": "text/html"}

@app.route("/api/stats")
def stats():
    try:
        cpu  = float(subprocess.check_output("grep 'cpu ' /proc/stat | awk '{u=$2+$4; t=$2+$3+$4+$5; if (NR==1){u1=u;t1=t} else printf \\"%.0f\\", (u-u1)*100/(t-t1)}' <(sleep 1) /proc/stat", shell=True).decode() or 0)
    except Exception: cpu = 0
    try:
        ram_info = subprocess.check_output(["free", "-m"], text=True).split()
        total_i  = ram_info.index("Mem:") + 1
        used_pct = round(int(ram_info[total_i+1]) / int(ram_info[total_i]) * 100)
    except Exception: used_pct = 0
    try:
        disk_pct = int(subprocess.check_output("df / | awk 'NR==2{print $5}' | tr -d '%'", shell=True).decode().strip())
    except Exception: disk_pct = 0
    sites = len(list(Path("/var/www/html").glob("*/wp-config.php"))) if Path("/var/www/html").exists() else 0
    return jsonify({"cpu": cpu, "ram": used_pct, "disk": disk_pct, "sites": sites})

@app.route("/api/sites")
def sites():
    result = []
    base = Path("/var/www/html")
    if base.exists():
        for wp in base.glob("*/wp-config.php"):
            domain = wp.parent.name
            result.append({"domain": domain, "php": "8.2", "redis": True, "ssl": True, "status": "ok"})
    return jsonify(result)

@app.route("/api/plugins")
def plugins():
    if pm:
        return jsonify(pm.list_plugins())
    return jsonify([])

@app.route("/api/plugin/enable", methods=["POST"])
def plugin_enable():
    name = request.json.get("name", "")
    ok   = pm.enable_plugin(name) if pm else False
    return jsonify({"ok": ok})

@app.route("/api/plugin/disable", methods=["POST"])
def plugin_disable():
    name = request.json.get("name", "")
    ok   = pm.disable_plugin(name) if pm else False
    return jsonify({"ok": ok})

@app.route("/api/log")
def log():
    log_path = Path("/var/log/easyinstall/plugins.log")
    lines = log_path.read_text().splitlines(keepends=True)[-100:] if log_path.exists() else []
    return jsonify({"lines": lines})

if __name__ == "__main__":
    port = int(os.environ.get("EASYINSTALL_WEBUI_PORT", 8080))
    app.run(host="0.0.0.0", port=port, debug=False)
"""


class WebUIPlugin(BasePlugin):

    UI_DIR = Path("/usr/local/lib/easyinstall_webui")

    def get_metadata(self) -> PluginMetadata:
        return PluginMetadata(
            name        = "webui",
            version     = "1.0.0",
            description = "Flask-based browser dashboard for managing WordPress sites and plugins",
            author      = "EasyInstall",
            requires    = ["python3-flask"],
            provides    = ["web-dashboard", "rest-api"],
        )

    def initialize(self) -> bool:
        self.UI_DIR.mkdir(parents=True, exist_ok=True)
        try:
            import flask  # noqa
        except ImportError:
            self.logger.warning("Flask not installed. Run: pip3 install flask")
        (self.UI_DIR / "dashboard.html").write_text(DASHBOARD_HTML)
        (self.UI_DIR / "app.py").write_text(FLASK_APP)
        self.logger.info(f"Web UI files written to {self.UI_DIR}")
        return True

    def start(self, port: int = 8080) -> bool:
        """Launch the Flask server in the background."""
        import os
        env = os.environ.copy()
        env["EASYINSTALL_WEBUI_PORT"] = str(port)
        pid_file = Path("/run/easyinstall-webui.pid")
        proc = subprocess.Popen(
            ["python3", str(self.UI_DIR / "app.py")],
            env=env,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        pid_file.write_text(str(proc.pid))
        self.logger.info(f"Web UI started on http://0.0.0.0:{port}  (PID {proc.pid})")
        return True

    def stop(self) -> bool:
        pid_file = Path("/run/easyinstall-webui.pid")
        if not pid_file.exists():
            self.logger.warning("Web UI is not running (no PID file)")
            return False
        pid = int(pid_file.read_text().strip())
        try:
            import os
            os.kill(pid, signal.SIGTERM)
            pid_file.unlink()
            self.logger.info(f"Web UI stopped (PID {pid})")
            return True
        except ProcessLookupError:
            pid_file.unlink(missing_ok=True)
            self.logger.warning("Web UI process not found")
            return False

    def generate_systemd_unit(self, port: int = 8080,
                               output_dir: str = "/etc/systemd/system") -> str:
        """Write a systemd service unit for the dashboard."""
        unit = f"""\
[Unit]
Description=EasyInstall Web Dashboard
After=network.target

[Service]
Type=simple
Environment=EASYINSTALL_WEBUI_PORT={port}
ExecStart=/usr/bin/python3 {self.UI_DIR}/app.py
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
"""
        path = Path(output_dir) / "easyinstall-webui.service"
        path.write_text(unit)
        self.logger.info(f"systemd unit written to {path}")
        return str(path)
