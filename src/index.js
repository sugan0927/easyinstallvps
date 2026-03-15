// =============================================================================
// EasyInstall VPS — Cloudflare Worker v7.0
// Serves install.sh + easyinstall files from GitHub raw or R2
// Usage: curl -fsSL https://YOUR_WORKER.workers.dev/install.sh | sudo bash
// =============================================================================

// ── Config — यहाँ अपनी details डालें ──────────────────────────────────────────
const CONFIG = {
  // GitHub repo URL (raw) — अपना username और repo name डालें
  GITHUB_RAW:  "https://raw.githubusercontent.com/YOUR_USERNAME/YOUR_REPO/main",

  // Site name (branding के लिए)
  SITE_NAME:   "EasyInstallVPS",

  // Worker का apna domain (deploy के बाद मिलेगा)
  WORKER_URL:  "https://YOUR_WORKER.YOUR_ACCOUNT.workers.dev",

  // Allowed install methods
  VERSION:     "7.0",
};

// ── Security headers ──────────────────────────────────────────────────────────
const SEC = {
  "X-Content-Type-Options":    "nosniff",
  "X-Frame-Options":           "SAMEORIGIN",
  "Referrer-Policy":           "strict-origin-when-cross-origin",
  "Cache-Control":             "no-cache, no-store, must-revalidate",
};

// ── Main install.sh script — यही VPS पर run होता है ─────────────────────────
function generateInstallSh(workerUrl) {
  // Using array join to avoid JS template literal conflicts with bash ${} syntax
  const lines = [
    '#!/bin/bash',
    '# =============================================================================',
    '# EasyInstall VPS v7.0 — Master Install Script',
    '# Usage: sudo bash -c "$(curl -fsSL ' + workerUrl + '/install.sh)"',
    '# Debian 12 / Ubuntu 22.04 / Ubuntu 24.04',
    '# =============================================================================',
    "set -eE",
    "",
    "G='\\033[0;32m'; Y='\\033[1;33m'; R='\\033[0;31m'",
    "B='\\033[0;34m'; C='\\033[0;36m'; N='\\033[0m'",
    "",
    'VERSION="7.0"',
    'WORKER_URL="' + workerUrl + '"',
    'LIB_DIR="/usr/local/lib/easyinstall"',
    'BIN_PATH="/usr/local/bin/easyinstall"',
    "",
    "print_banner() {",
    "    echo -e \"${C}\"",
    "    echo '================================'",
    "    echo '  EasyInstall VPS v7.0'",
    "    echo '  WordPress Performance Stack'",
    "    echo '================================'",
    "    echo -e \"${N}\"",
    "}",
    "",
    "check_root() {",
    '    [ "${EUID}" -eq 0 ] || {',
    "        echo -e \"${R}Please run as root: sudo bash -c \\$(curl ...)${N}\"",
    "        exit 1",
    "    }",
    "}",
    "",
    "check_os() {",
    "    . /etc/os-release 2>/dev/null || true",
    '    OS_ID="${ID:-unknown}"',
    '    OS_VER="${VERSION_ID:-0}"',
    '    case "${OS_ID}" in',
    "        debian)",
    '            MAJOR="${OS_VER%%.*}"',
    '            [ "${MAJOR}" -ge 11 ] || {',
    "                echo -e \"${R}Debian 11+ required (detected: ${OS_VER})${N}\"",
    "                exit 1",
    "            }",
    "            ;;",
    "        ubuntu)",
    '            case "${OS_VER}" in',
    "                20.04|22.04|24.04) ;;",
    "                *) echo -e \"${R}Ubuntu 20.04/22.04/24.04 required${N}\"; exit 1 ;;",
    "            esac",
    "            ;;",
    "        *)",
    '            echo -e "${R}Unsupported OS: ${OS_ID}. Use Debian/Ubuntu.${N}"',
    "            exit 1",
    "            ;;",
    "    esac",
    '    echo -e "${G}OS: ${OS_ID} ${OS_VER}${N}"',
    "}",
    "",
    "check_disk() {",
    "    AVAIL=$(df -m / | awk 'NR==2{print $4}')",
    '    [ "${AVAIL}" -ge 3072 ] || {',
    '        echo -e "${R}Need 3GB+ free disk (available: ${AVAIL}MB)${N}"',
    "        exit 1",
    "    }",
    '    echo -e "${G}Disk: ${AVAIL}MB available${N}"',
    "}",
    "",
    "block_apache() {",
    '    echo -e "${Y}Blocking Apache2 (prevents port 80 conflict with Nginx)...${N}"',
    "    mkdir -p /etc/apt/preferences.d",
    "    cat > /etc/apt/preferences.d/block-apache2.pref << 'APACHEPREF'",
    "Package: apache2 apache2-bin apache2-data apache2-utils libapache2-mod-php*",
    "Pin: release *",
    "Pin-Priority: -1",
    "APACHEPREF",
    "    if dpkg -l 2>/dev/null | grep -q '^ii.*apache2 '; then",
    '        echo -e "${Y}Apache2 found — removing to free port 80...${N}"',
    "        systemctl stop apache2 2>/dev/null || true",
    "        systemctl disable apache2 2>/dev/null || true",
    "        DEBIAN_FRONTEND=noninteractive apt-get remove -y --purge \\",
    "            apache2 apache2-bin apache2-data apache2-utils \\",
    "            libapache2-mod-php* 2>/dev/null || true",
    "        apt-get autoremove -y 2>/dev/null || true",
    "        rm -rf /etc/apache2 2>/dev/null || true",
    '        echo -e "${G}Apache2 removed — port 80 free${N}"',
    "    else",
    '        echo -e "${G}Apache2 not installed — port 80 is free${N}"',
    "    fi",
    "}",
    "",
    "install_deps() {",
    '    echo -e "${B}Installing base dependencies...${N}"',
    "    export DEBIAN_FRONTEND=noninteractive",
    "    apt-get update -y -q 2>/dev/null",
    "    apt-get install -y -q --no-install-recommends \\",
    "        curl wget python3 git unzip \\",
    "        gnupg ca-certificates lsb-release apt-transport-https \\",
    "        2>/dev/null || true",
    "    apt-get install -y -q --no-install-recommends php-cli 2>/dev/null || \\",
    "    apt-get install -y -q --no-install-recommends php8.2-cli 2>/dev/null || true",
    '    echo -e "${G}Base dependencies installed${N}"',
    "}",
    "",
    "download_files() {",
    '    echo -e "${B}Downloading EasyInstall engine files...${N}"',
    "    mkdir -p \"${LIB_DIR}\"",
    "    FILES=(easyinstall_core.py:core.py easyinstall_wp.php:wp_helper.php)",
    "    for entry in \"${FILES[@]}\"; do",
    '        src="${entry%%:*}"',
    '        dst="${entry##*:}"',
    '        echo "  Downloading ${src}..."',
    '        if curl -fsSL --max-time 60 "${WORKER_URL}/files/${src}" -o "${LIB_DIR}/${dst}"; then',
    '            echo -e "  ${G}${dst} downloaded${N}"',
    "        else",
    '            echo -e "  ${R}Failed: ${src}${N}"',
    "            exit 1",
    "        fi",
    "    done",
    '    chmod +x "${LIB_DIR}/core.py"',
    '    echo -e "${G}Engine files downloaded${N}"',
    "}",
    "",
    "install_command() {",
    '    echo -e "${B}Installing easyinstall command...${N}"',
    "    mkdir -p /usr/local/lib/easyinstall /var/log/easyinstall /var/lib/easyinstall",
    "    cat > \"${BIN_PATH}\" << 'CMDEOF'",
    "#!/bin/bash",
    "VERSION=\"7.0\"",
    "LIB_DIR=\"/usr/local/lib/easyinstall\"",
    "PYTHON_ENGINE=\"${LIB_DIR}/core.py\"",
    "PHP_HELPER=\"${LIB_DIR}/wp_helper.php\"",
    "G='\\033[0;32m'; Y='\\033[1;33m'; R='\\033[0;31m'; C='\\033[0;36m'; N='\\033[0m'",
    "_need_root()   { [ \"${EUID}\" -eq 0 ] || { echo -e \"${R}Run as root${N}\"; exit 1; }; }",
    "_need_python() { command -v python3 >/dev/null 2>&1 || apt-get install -y python3 -q; }",
    "_need_php()    { command -v php >/dev/null 2>&1 || apt-get install -y --no-install-recommends php-cli -q 2>/dev/null || true; }",
    "_py()  { python3 \"${PYTHON_ENGINE}\" \"$@\"; }",
    "CMD=\"${1:-help}\"; shift || true",
    "case \"${CMD}\" in",
    "    install)      _need_root; _need_python; _need_php; _py install \"$@\" ;;",
    "    create)       _need_root; _need_python; _need_php",
    "                  [ -z \"${1}\" ] && { echo -e \"${R}Usage: easyinstall create domain.com [--ssl]${N}\"; exit 1; }",
    "                  _py create \"$@\" ;;",
    "    delete)       _need_root; _need_python; _py delete \"$@\" ;;",
    "    list)         _need_python; _py list ;;",
    "    site-info)    _need_python; _need_php; _py site-info \"$@\" ;;",
    "    update-site)  _need_root; _need_python; _need_php; _py update-site \"$@\" ;;",
    "    clone)        _need_root; _need_python; _need_php; _py clone \"$@\" ;;",
    "    php-switch)   _need_root; _need_python; _py php-switch \"$@\" ;;",
    "    ssl)          _need_root; _need_python; _py ssl \"$@\" ;;",
    "    ssl-renew)    _need_root; _need_python; _py ssl-renew ;;",
    "    redis-status) _need_python; _py redis-status ;;",
    "    redis-restart)_need_root; _need_python; _py redis-restart \"$@\" ;;",
    "    redis-ports)  _need_python; _py redis-ports ;;",
    "    redis-cli)    REDIS_CONF=\"/etc/redis/redis-${1//./-}.conf\"",
    "                  PORT=$(grep '^port' \"${REDIS_CONF}\" 2>/dev/null | awk '{print $2}' || echo 6379)",
    "                  exec redis-cli -p \"${PORT}\" ;;",
    "    status)       _need_python; _py status ;;",
    "    health)       _need_python; _py health ;;",
    "    monitor)      _need_python; _py monitor ;;",
    "    logs)         _need_python; _py logs \"$@\" ;;",
    "    perf)         _need_python; _py perf ;;",
    "    self-heal|selfheal)    _need_root; _need_python; _py self-heal \"${1:-full}\" ;;",
    "    self-update|selfupdate)_need_root; _need_python; _py self-update \"${1:-all}\" ;;",
    "    self-check|selfcheck)  _need_python; _py self-check ;;",
    "    backup)       _need_root; _need_python; _py backup \"$@\" ;;",
    "    optimize)     _need_root; _need_python; _py optimize ;;",
    "    clean)        _need_root; _need_python; _py clean ;;",
    "    ws-enable)    _need_root; _need_python; _py ws-enable \"$@\" ;;",
    "    ws-disable)   _need_root; _need_python; _py ws-disable \"$@\" ;;",
    "    ws-status)    _need_python; _py ws-status \"$@\" ;;",
    "    ws-test)      _need_python; _py ws-test \"$@\" ;;",
    "    http3-enable) _need_root; _need_python; _py http3-enable ;;",
    "    http3-status) _need_python; _py http3-status ;;",
    "    edge-setup)   _need_root; _need_python; _py edge-setup ;;",
    "    edge-status)  _need_python; _py edge-status ;;",
    "    edge-purge)   _need_root; _need_python; _py edge-purge \"$@\" ;;",
    "    ai-diagnose)  _need_python; _py ai-diagnose \"$@\" ;;",
    "    ai-optimize)  _need_python; _py ai-optimize ;;",
    "    ai-setup)     _need_python; _py ai-setup ;;",
    "    pagespeed)    _need_root; _need_python; _need_php; _py pagespeed \"$@\" ;;",
    "    fix-apache|fix-nginx) _need_root; _need_python; _py fix-apache \"$@\" ;;",
    "    version)      echo \"EasyInstall v${VERSION}\" ;;",
    "    help|--help|-h)",
    "        echo 'EasyInstall v7.0 — Commands:'",
    "        echo '  install               Full stack install'",
    "        echo '  create domain.com     WordPress site'",
    "        echo '  delete domain.com     Delete site'",
    "        echo '  list                  List all sites'",
    "        echo '  site-info domain      Site details'",
    "        echo '  update-site domain    Update WP core/plugins/themes'",
    "        echo '  clone src dst         Clone site'",
    "        echo '  php-switch domain v   Switch PHP version'",
    "        echo '  ssl domain            Enable SSL'",
    "        echo '  ssl-renew             Renew all SSL'",
    "        echo '  redis-status          Redis instances'",
    "        echo '  status                System status'",
    "        echo '  health                Health check'",
    "        echo '  monitor               Live monitor'",
    "        echo '  logs [domain]         View logs'",
    "        echo '  self-heal [mode]      Auto-fix services'",
    "        echo '  self-heal 502         Fix 502 Bad Gateway'",
    "        echo '  self-update [pkg]     Update packages'",
    "        echo '  self-check            Version status'",
    "        echo '  backup [domain]       Backup site/all'",
    "        echo '  optimize              DB + cache optimize'",
    "        echo '  clean                 Clean logs/temp'",
    "        echo '  ws-enable domain port WebSocket enable'",
    "        echo '  http3-enable          HTTP/3 + QUIC'",
    "        echo '  edge-setup            Edge computing'",
    "        echo '  ai-diagnose           AI log analysis'",
    "        echo '  pagespeed optimize d  PageSpeed optimize'",
    "        echo '  fix-apache            Apache conflict fix'",
    "        ;;",
    "    *) echo -e \"${R}Unknown: ${CMD}${N}  |  Run: easyinstall help\"; exit 1 ;;",
    "esac",
    "CMDEOF",
    '    chmod +x "${BIN_PATH}"',
    '    echo -e "${G}easyinstall command installed${N}"',
    "}",
    "",
    "print_success() {",
    "    IP=$(hostname -I | awk '{print $1}')",
    "    echo ''",
    '    echo -e "${G}=====================================${N}"',
    '    echo -e "${G}EasyInstall v7.0 — Setup Complete!${N}"',
    '    echo -e "${G}=====================================${N}"',
    "    echo ''",
    '    echo -e "${Y}Next steps:${N}"',
    "    echo '  1. Full stack install:'",
    '    echo -e "     ${C}easyinstall install${N}"',
    "    echo '  2. Create WordPress site:'",
    '    echo -e "     ${C}easyinstall create yourdomain.com --ssl${N}"',
    "    echo '  3. If 502 error (Apache conflict):'",
    '    echo -e "     ${C}easyinstall fix-apache${N}"',
    "    echo '  4. Help:'",
    '    echo -e "     ${C}easyinstall help${N}"',
    "    echo ''",
    '    echo -e "  Server IP: ${C}${IP}${N}"',
    "    echo ''",
    "}",
    "",
    "main() {",
    "    print_banner",
    "    check_root",
    "    check_os",
    "    check_disk",
    "    block_apache",
    "    install_deps",
    "    download_files",
    "    install_command",
    '    if [ "${1:-}" = "--auto-install" ]; then',
    '        echo -e "${Y}Running full stack install...${N}"',
    "        easyinstall install",
    "    fi",
    "    print_success",
    "}",
    "",
    'main "$@"',
  ];
  return lines.join('\n');
}


// ── Request handler ──────────────────────────────────────────────────────────
export default {
  async fetch(request, env) {
    const url    = new URL(request.url);
    const path   = url.pathname;
    const method = request.method;

    // ── CORS headers ──────────────────────────────────────────────────────
    const corsHeaders = {
      "Access-Control-Allow-Origin":  "*",
      "Access-Control-Allow-Methods": "GET, HEAD, OPTIONS",
    };

    if (method === "OPTIONS") {
      return new Response(null, { status: 204, headers: corsHeaders });
    }

    // ── Route: / — Homepage ───────────────────────────────────────────────
    if (path === "/" || path === "") {
      const workerUrl = `${url.protocol}//${url.host}`;
      return new Response(homepageHTML(workerUrl, CONFIG.VERSION), {
        headers: { ...SEC, ...corsHeaders, "Content-Type": "text/html; charset=utf-8" },
      });
    }

    // ── Route: /install.sh — Main install script ──────────────────────────
    if (path === "/install.sh" || path === "/install") {
      const workerUrl = `${url.protocol}//${url.host}`;
      const script    = generateInstallSh(workerUrl);
      return new Response(script, {
        headers: {
          ...SEC,
          ...corsHeaders,
          "Content-Type":        "text/plain; charset=utf-8",
          "Content-Disposition": "inline; filename=install.sh",
        },
      });
    }

    // ── Route: /files/:filename — Serve engine files ──────────────────────
    if (path.startsWith("/files/")) {
      const filename = path.replace("/files/", "");
      const allowed  = ["easyinstall_core.py", "easyinstall_wp.php", "easyinstall.sh"];

      if (!allowed.includes(filename)) {
        return new Response("File not found", { status: 404, headers: corsHeaders });
      }

      // R2 से serve करें अगर available हो
      if (env.FILES_BUCKET) {
        try {
          const obj = await env.FILES_BUCKET.get(filename);
          if (obj) {
            const ext  = filename.split(".").pop();
            const mime = ext === "py" ? "text/x-python" :
                         ext === "php" ? "application/x-php" :
                         "text/plain";
            return new Response(obj.body, {
              headers: {
                ...corsHeaders,
                "Content-Type":  mime + "; charset=utf-8",
                "Cache-Control": "public, max-age=300",
              },
            });
          }
        } catch (e) {
          console.error("R2 error:", e);
        }
      }

      // R2 नहीं है — GitHub raw से redirect करें
      const githubUrl = `${CONFIG.GITHUB_RAW}/${filename}`;
      return Response.redirect(githubUrl, 302);
    }

    // ── Route: /api/status — Worker status ───────────────────────────────
    if (path === "/api/status") {
      return Response.json({
        status:  "ok",
        version: CONFIG.VERSION,
        name:    CONFIG.SITE_NAME,
        time:    new Date().toISOString(),
        region:  request.cf?.colo ?? "unknown",
        routes: [
          "GET /               — Homepage",
          "GET /install.sh     — Master install script",
          "GET /files/<name>   — Engine files (core.py, wp_helper.php)",
          "GET /api/status     — This status endpoint",
        ],
      }, {
        headers: { ...SEC, ...corsHeaders },
      });
    }

    // ── 404 ───────────────────────────────────────────────────────────────
    return new Response("Not Found", {
      status:  404,
      headers: { ...corsHeaders, "Content-Type": "text/plain" },
    });
  },
};

// ── Homepage HTML ─────────────────────────────────────────────────────────────
function homepageHTML(workerUrl, version) {
  return `<!DOCTYPE html>
<html lang="hi">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>EasyInstall VPS v${version}</title>
<style>
  *{box-sizing:border-box;margin:0;padding:0}
  body{font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;
       background:#0d1117;color:#e6edf3;min-height:100vh;
       display:flex;flex-direction:column;align-items:center;justify-content:center;padding:24px}
  .card{background:#161b22;border:1px solid #30363d;border-radius:12px;
        padding:40px;max-width:680px;width:100%}
  h1{font-size:1.8em;font-weight:600;color:#58a6ff;margin-bottom:8px}
  .badge{background:#1f2937;border:1px solid #30363d;border-radius:20px;
         padding:3px 12px;font-size:12px;color:#8b949e;display:inline-block;margin-bottom:24px}
  h2{font-size:1em;font-weight:500;color:#8b949e;margin:24px 0 10px;
     text-transform:uppercase;letter-spacing:.05em}
  .cmd{background:#0d1117;border:1px solid #30363d;border-radius:8px;
       padding:14px 18px;font-family:'Courier New',monospace;font-size:14px;
       color:#58a6ff;word-break:break-all;position:relative;margin-bottom:16px}
  .copy-btn{position:absolute;right:10px;top:8px;background:#21262d;
            border:1px solid #30363d;border-radius:6px;padding:4px 10px;
            font-size:11px;color:#8b949e;cursor:pointer}
  .copy-btn:hover{background:#30363d;color:#e6edf3}
  .steps{list-style:none;counter-reset:steps}
  .steps li{counter-increment:steps;padding:10px 0 10px 44px;position:relative;
            border-bottom:1px solid #21262d;color:#8b949e;font-size:14px}
  .steps li:last-child{border:none}
  .steps li::before{content:counter(steps);position:absolute;left:0;
                    background:#1f2937;border:1px solid #30363d;
                    width:28px;height:28px;border-radius:50%;
                    display:flex;align-items:center;justify-content:center;
                    font-size:12px;font-weight:600;color:#58a6ff;top:8px}
  .steps li code{background:#0d1117;padding:2px 6px;border-radius:4px;
                 font-size:12px;color:#79c0ff;border:1px solid #30363d}
  .features{display:grid;grid-template-columns:1fr 1fr;gap:10px;margin-top:8px}
  .feat{background:#0d1117;border:1px solid #21262d;border-radius:8px;
        padding:12px;font-size:13px;color:#8b949e}
  .feat strong{color:#e6edf3;display:block;margin-bottom:4px;font-size:14px}
  .warn{background:#1f1a0e;border:1px solid #3d2b00;border-radius:8px;
        padding:12px 16px;font-size:13px;color:#d29922;margin-top:16px}
  a{color:#58a6ff;text-decoration:none}
  footer{margin-top:24px;font-size:12px;color:#484f58;text-align:center}
</style>
</head>
<body>
<div class="card">
  <h1>⚡ EasyInstall VPS</h1>
  <span class="badge">v${version} — WordPress Performance Stack</span>

  <h2>Quick Install</h2>
  <div class="cmd" id="cmd1">
    sudo bash -c "$(curl -fsSL ${workerUrl}/install.sh)"
    <button class="copy-btn" onclick="copy('cmd1')">Copy</button>
  </div>

  <h2>Step-by-step</h2>
  <ol class="steps">
    <li>Run install command above on your Debian/Ubuntu VPS</li>
    <li>Full stack install: <code>easyinstall install</code></li>
    <li>Create WordPress: <code>easyinstall create domain.com --ssl</code></li>
    <li>Check status: <code>easyinstall status</code></li>
  </ol>

  <h2>Fix Apache Conflict (502 Error)</h2>
  <div class="cmd" id="cmd2">
    easyinstall fix-apache
    <button class="copy-btn" onclick="copy('cmd2')">Copy</button>
  </div>
  <div class="warn">
    ⚠️ If you get a 502 error, Apache2 may be blocking port 80.
    Run <strong>easyinstall fix-apache</strong> to remove Apache and restore Nginx.
  </div>

  <h2>Features</h2>
  <div class="features">
    <div class="feat"><strong>Nginx</strong>Official mainline + FastCGI cache</div>
    <div class="feat"><strong>PHP 8.4/8.3/8.2</strong>FPM + OPcache + Redis</div>
    <div class="feat"><strong>MariaDB 11.x</strong>Performance tuned for WP</div>
    <div class="feat"><strong>Redis</strong>Per-site instances, auto-port</div>
    <div class="feat"><strong>Auto SSL</strong>Let's Encrypt + certbot</div>
    <div class="feat"><strong>Self-Heal</strong>Auto-fix services + 502</div>
    <div class="feat"><strong>CI/CD ready</strong>GitHub Actions + deploy</div>
    <div class="feat"><strong>AI Diagnose</strong>Log analysis + suggestions</div>
  </div>

  <h2>All Commands</h2>
  <div class="cmd" id="cmd3">
    easyinstall help
    <button class="copy-btn" onclick="copy('cmd3')">Copy</button>
  </div>

  <h2>API</h2>
  <a href="/api/status">/api/status</a> &nbsp;·&nbsp;
  <a href="/install.sh">/install.sh</a> &nbsp;·&nbsp;
  <a href="/files/easyinstall_core.py">/files/easyinstall_core.py</a>
</div>

<footer>EasyInstall VPS v${version} — Cloudflare Workers Edge</footer>

<script>
function copy(id) {
  const el = document.getElementById(id);
  const txt = el.childNodes[0].textContent.trim();
  navigator.clipboard.writeText(txt).then(() => {
    const btn = el.querySelector('.copy-btn');
    btn.textContent = 'Copied!';
    setTimeout(() => btn.textContent = 'Copy', 2000);
  });
}
</script>
</body>
</html>`;
}
