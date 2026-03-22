#!/usr/bin/env python3
"""
EasyInstall AI Page Generator — Web Interface v1.0
====================================================
Flask-based web UI for generating WordPress pages, themes, and plugins via AI.

Deploy to: /usr/local/lib/easyinstall_page_web.py
Start:     easyinstall-pages web-start [port]
           python3 /usr/local/lib/easyinstall_page_web.py --port 8080
Access:    http://SERVER_IP:8080
"""

import os
import sys
import json
import time
import logging
import argparse
import subprocess
import threading
from pathlib import Path
from datetime import datetime
from typing import Dict, Any

LOG_DIR = Path("/var/log/easyinstall")
LOG_DIR.mkdir(parents=True, exist_ok=True)

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s — %(message)s",
    handlers=[
        logging.FileHandler(LOG_DIR / "page-web.log"),
        logging.StreamHandler(),
    ],
)
logger = logging.getLogger("easyinstall.page_web")

# ── Lazy Flask import ─────────────────────────────────────────────────────────
try:
    from flask import Flask, render_template_string, request, jsonify, redirect, url_for
    _FLASK_AVAILABLE = True
except ImportError:
    _FLASK_AVAILABLE = False
    logger.error("Flask not installed. Run: pip3 install flask --break-system-packages")

# ── HTML Template ─────────────────────────────────────────────────────────────
_HTML = """<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>EasyInstall AI Page Generator</title>
<style>
  *, *::before, *::after { box-sizing: border-box; }
  :root {
    --primary: #667eea; --secondary: #764ba2;
    --bg: #f0f2f5; --card: #fff;
    --text: #1a1a2e; --muted: #6c757d;
    --success: #28a745; --danger: #dc3545;
    --border: #e2e8f0;
  }
  body { margin: 0; font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif;
         background: var(--bg); color: var(--text); min-height: 100vh; }
  .header {
    background: linear-gradient(135deg, var(--primary), var(--secondary));
    color: #fff; padding: 0 32px;
    display: flex; align-items: center; justify-content: space-between;
    height: 64px; box-shadow: 0 2px 20px rgba(102,126,234,.4);
    position: sticky; top: 0; z-index: 100;
  }
  .header h1 { margin: 0; font-size: 20px; font-weight: 700; }
  .header .badge { background: rgba(255,255,255,.2); border-radius: 20px;
                   padding: 4px 12px; font-size: 12px; }
  .container { max-width: 1100px; margin: 0 auto; padding: 32px 20px; }
  .tabs { display: flex; gap: 4px; margin-bottom: 28px; flex-wrap: wrap; }
  .tab { padding: 10px 22px; border-radius: 8px; cursor: pointer; font-weight: 500;
         border: 2px solid transparent; transition: all .2s; font-size: 14px;
         background: #fff; color: var(--muted); }
  .tab.active { background: var(--primary); color: #fff; border-color: var(--primary); }
  .tab:hover:not(.active) { border-color: var(--primary); color: var(--primary); }
  .panel { display: none; } .panel.active { display: block; }
  .card { background: var(--card); border-radius: 16px; padding: 32px;
          box-shadow: 0 4px 20px rgba(0,0,0,.06); margin-bottom: 24px; }
  .grid { display: grid; grid-template-columns: 1fr 1fr; gap: 20px; }
  @media(max-width:640px) { .grid { grid-template-columns: 1fr; } }
  label { display: block; font-size: 13px; font-weight: 600; color: var(--muted);
          text-transform: uppercase; letter-spacing: .5px; margin-bottom: 6px; }
  input[type=text], input[type=color], select, textarea {
    width: 100%; padding: 11px 14px; border: 1.5px solid var(--border);
    border-radius: 8px; font-size: 14px; font-family: inherit;
    transition: border-color .2s, box-shadow .2s; background: #fff;
  }
  input:focus, select:focus, textarea:focus {
    outline: none; border-color: var(--primary);
    box-shadow: 0 0 0 3px rgba(102,126,234,.15);
  }
  textarea { resize: vertical; min-height: 80px; }
  .color-row { display: flex; gap: 12px; align-items: center; }
  .color-row input[type=color] { width: 48px; height: 42px; padding: 4px; cursor: pointer; }
  .color-row input[type=text] { flex: 1; }
  .btn {
    background: linear-gradient(135deg, var(--primary), var(--secondary));
    color: #fff; border: none; border-radius: 10px;
    padding: 13px 32px; font-size: 15px; font-weight: 600;
    cursor: pointer; transition: all .3s; display: inline-flex;
    align-items: center; gap: 8px;
  }
  .btn:hover { transform: translateY(-2px); box-shadow: 0 8px 25px rgba(102,126,234,.4); }
  .btn:disabled { opacity: .6; cursor: not-allowed; transform: none; }
  .btn-sm { padding: 8px 18px; font-size: 13px; border-radius: 7px; }
  .result { margin-top: 24px; display: none; }
  .result.show { display: block; }
  .result-box {
    border-radius: 10px; padding: 20px; font-size: 14px; line-height: 1.6;
  }
  .result-box.success { background: #f0fff4; border: 1.5px solid #68d391; }
  .result-box.error   { background: #fff5f5; border: 1.5px solid #fc8181; }
  .result-box h3 { margin: 0 0 12px; font-size: 16px; }
  .result-box .code {
    background: #1a1a2e; color: #a8dadc; border-radius: 6px;
    padding: 10px 14px; font-family: monospace; font-size: 13px;
    white-space: pre-wrap; word-break: break-all; margin-top: 10px;
  }
  .copy-btn { font-size: 12px; padding: 4px 10px; margin-left: 8px; }
  .spinner { display: none; width: 18px; height: 18px; border: 2.5px solid rgba(255,255,255,.4);
             border-top-color: #fff; border-radius: 50%; animation: spin .8s linear infinite; }
  @keyframes spin { to { transform: rotate(360deg); } }
  .sites-list { display: flex; flex-wrap: wrap; gap: 8px; margin-bottom: 8px; }
  .site-chip { background: var(--bg); border: 1.5px solid var(--border);
               border-radius: 20px; padding: 5px 14px; font-size: 13px;
               cursor: pointer; transition: all .2s; }
  .site-chip:hover { border-color: var(--primary); color: var(--primary); }
  .stat-grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(180px, 1fr)); gap: 16px; }
  .stat-card { background: linear-gradient(135deg, var(--primary), var(--secondary));
               color: #fff; border-radius: 12px; padding: 20px; text-align: center; }
  .stat-card .num { font-size: 32px; font-weight: 700; }
  .stat-card .lbl { font-size: 12px; opacity: .8; margin-top: 4px; }
  .ai-conf { font-family: monospace; font-size: 13px; background: #f8f9ff;
             border: 1.5px solid var(--border); border-radius: 8px; padding: 14px;
             white-space: pre; overflow-x: auto; }
  .progress-bar { height: 4px; background: var(--bg); border-radius: 2px; overflow: hidden; margin-top: 16px; display: none; }
  .progress-fill { height: 100%; background: linear-gradient(90deg, var(--primary), var(--secondary));
                   border-radius: 2px; width: 0; transition: width .3s; }
</style>
</head>
<body>
<div class="header">
  <h1>🎨 EasyInstall AI Page Generator</h1>
  <span class="badge">v1.0 — EasyInstall v7.0</span>
</div>

<div class="container">
  <!-- Stats row -->
  <div class="stat-grid" style="margin-bottom:28px">
    <div class="stat-card"><div class="num" id="stat-sites">—</div><div class="lbl">WordPress Sites</div></div>
    <div class="stat-card"><div class="num" id="stat-plugins">—</div><div class="lbl">Generated Plugins</div></div>
    <div class="stat-card"><div class="num" id="stat-provider">—</div><div class="lbl">AI Provider</div></div>
    <div class="stat-card"><div class="num" id="stat-model">—</div><div class="lbl">AI Model</div></div>
  </div>

  <!-- Tabs -->
  <div class="tabs">
    <div class="tab active" onclick="switchTab('login')">🔐 Login Page</div>
    <div class="tab" onclick="switchTab('setup')">🚀 Setup Wizard</div>
    <div class="tab" onclick="switchTab('theme')">🎨 Theme</div>
    <div class="tab" onclick="switchTab('plugin')">🔌 Plugin</div>
    <div class="tab" onclick="switchTab('status')">⚙️ AI Status</div>
  </div>

  <!-- Login Page Tab -->
  <div id="panel-login" class="panel active">
    <div class="card">
      <h2 style="margin:0 0 6px">🔐 Custom Login Page Generator</h2>
      <p style="color:var(--muted);margin:0 0 24px;font-size:14px">
        Generate a fully custom WordPress wp-login.php page using AI.
        The plugin replaces default styling without touching core files.
      </p>
      <div id="sites-login" class="sites-list"></div>
      <div class="grid">
        <div>
          <label>Domain *</label>
          <input type="text" id="login-domain" placeholder="mysite.com">
        </div>
        <div>
          <label>Style</label>
          <select id="login-style">
            <option value="modern">Modern (gradient, smooth animations)</option>
            <option value="dark">Dark (dark bg, glowing inputs)</option>
            <option value="minimal">Minimal (clean white, no shadows)</option>
            <option value="corporate">Corporate (professional navy/grey)</option>
            <option value="creative">Creative (bold, rounded, playful)</option>
          </select>
        </div>
      </div>
      <div style="margin-top:16px">
        <label>Description (tell AI what you want)</label>
        <textarea id="login-desc" placeholder="e.g. Modern dark login page with gradient background, company logo, and smooth animations...">Modern login page with gradient background and smooth animations</textarea>
      </div>
      <div class="grid" style="margin-top:16px">
        <div>
          <label>Primary Color</label>
          <div class="color-row">
            <input type="color" id="login-color1-picker" value="#667eea"
                   oninput="document.getElementById('login-color1').value=this.value">
            <input type="text" id="login-color1" value="#667eea"
                   oninput="document.getElementById('login-color1-picker').value=this.value">
          </div>
        </div>
        <div>
          <label>Secondary Color</label>
          <div class="color-row">
            <input type="color" id="login-color2-picker" value="#764ba2"
                   oninput="document.getElementById('login-color2').value=this.value">
            <input type="text" id="login-color2" value="#764ba2"
                   oninput="document.getElementById('login-color2-picker').value=this.value">
          </div>
        </div>
      </div>
      <div style="margin-top:24px">
        <button class="btn" onclick="generate('login')">
          <span id="btn-login-text">✨ Generate Login Page</span>
          <div class="spinner" id="spinner-login"></div>
        </button>
      </div>
      <div class="progress-bar" id="prog-login"><div class="progress-fill" id="progf-login"></div></div>
      <div class="result" id="result-login"></div>
    </div>
  </div>

  <!-- Setup Wizard Tab -->
  <div id="panel-setup" class="panel">
    <div class="card">
      <h2 style="margin:0 0 6px">🚀 Setup Wizard Generator</h2>
      <p style="color:var(--muted);margin:0 0 24px;font-size:14px">
        Generate a multi-step setup wizard for your WordPress site — great for themes and plugins.
      </p>
      <div id="sites-setup" class="sites-list"></div>
      <div class="grid">
        <div>
          <label>Domain *</label>
          <input type="text" id="setup-domain" placeholder="mysite.com">
        </div>
      </div>
      <div style="margin-top:16px">
        <label>Description</label>
        <textarea id="setup-desc" placeholder="e.g. E-commerce store setup wizard with 8 steps: welcome, payment, shipping, products...">Modern 8-step installation wizard with progress bar and demo content import</textarea>
      </div>
      <div style="margin-top:24px">
        <button class="btn" onclick="generate('setup')">
          <span id="btn-setup-text">✨ Generate Setup Wizard</span>
          <div class="spinner" id="spinner-setup"></div>
        </button>
      </div>
      <div class="progress-bar" id="prog-setup"><div class="progress-fill" id="progf-setup"></div></div>
      <div class="result" id="result-setup"></div>
    </div>
  </div>

  <!-- Theme Tab -->
  <div id="panel-theme" class="panel">
    <div class="card">
      <h2 style="margin:0 0 6px">🎨 Theme Customizer Generator</h2>
      <p style="color:var(--muted);margin:0 0 24px;font-size:14px">
        Generate a plugin that injects custom CSS/JS into any active WordPress theme.
        Adds Customizer color controls.
      </p>
      <div id="sites-theme" class="sites-list"></div>
      <div class="grid">
        <div>
          <label>Domain *</label>
          <input type="text" id="theme-domain" placeholder="mysite.com">
        </div>
      </div>
      <div style="margin-top:16px">
        <label>Description</label>
        <textarea id="theme-desc" placeholder="e.g. Modern SaaS business theme, dark header, card-style blog posts...">Modern business theme with responsive design and custom header</textarea>
      </div>
      <div class="grid" style="margin-top:16px">
        <div>
          <label>Primary Color</label>
          <div class="color-row">
            <input type="color" id="theme-color1-picker" value="#667eea"
                   oninput="document.getElementById('theme-color1').value=this.value">
            <input type="text" id="theme-color1" value="#667eea"
                   oninput="document.getElementById('theme-color1-picker').value=this.value">
          </div>
        </div>
        <div>
          <label>Secondary Color</label>
          <div class="color-row">
            <input type="color" id="theme-color2-picker" value="#764ba2"
                   oninput="document.getElementById('theme-color2').value=this.value">
            <input type="text" id="theme-color2" value="#764ba2"
                   oninput="document.getElementById('theme-color2-picker').value=this.value">
          </div>
        </div>
      </div>
      <div style="margin-top:24px">
        <button class="btn" onclick="generate('theme')">
          <span id="btn-theme-text">✨ Generate Theme Plugin</span>
          <div class="spinner" id="spinner-theme"></div>
        </button>
      </div>
      <div class="progress-bar" id="prog-theme"><div class="progress-fill" id="progf-theme"></div></div>
      <div class="result" id="result-theme"></div>
    </div>
  </div>

  <!-- Plugin Tab -->
  <div id="panel-plugin" class="panel">
    <div class="card">
      <h2 style="margin:0 0 6px">🔌 Custom Plugin Generator</h2>
      <p style="color:var(--muted);margin:0 0 24px;font-size:14px">
        Generate a fully custom WordPress plugin with any combination of features.
      </p>
      <div id="sites-plugin" class="sites-list"></div>
      <div class="grid">
        <div>
          <label>Domain *</label>
          <input type="text" id="plugin-domain" placeholder="mysite.com">
        </div>
      </div>
      <div style="margin-top:16px">
        <label>Description</label>
        <textarea id="plugin-desc" placeholder="e.g. Lead capture plugin with custom post type, admin dashboard, and email notifications...">Custom functionality plugin</textarea>
      </div>
      <div style="margin-top:16px">
        <label>Features (check all you need)</label>
        <div style="display:flex;flex-wrap:wrap;gap:10px;margin-top:8px">
          <label style="text-transform:none;letter-spacing:0;display:flex;align-items:center;gap:6px;cursor:pointer;font-weight:500">
            <input type="checkbox" value="shortcode" class="feat" checked> Shortcode
          </label>
          <label style="text-transform:none;letter-spacing:0;display:flex;align-items:center;gap:6px;cursor:pointer;font-weight:500">
            <input type="checkbox" value="widget" class="feat" checked> Widget
          </label>
          <label style="text-transform:none;letter-spacing:0;display:flex;align-items:center;gap:6px;cursor:pointer;font-weight:500">
            <input type="checkbox" value="settings" class="feat" checked> Settings Page
          </label>
          <label style="text-transform:none;letter-spacing:0;display:flex;align-items:center;gap:6px;cursor:pointer;font-weight:500">
            <input type="checkbox" value="cpt" class="feat"> Custom Post Type
          </label>
          <label style="text-transform:none;letter-spacing:0;display:flex;align-items:center;gap:6px;cursor:pointer;font-weight:500">
            <input type="checkbox" value="rest" class="feat"> REST API Endpoint
          </label>
          <label style="text-transform:none;letter-spacing:0;display:flex;align-items:center;gap:6px;cursor:pointer;font-weight:500">
            <input type="checkbox" value="ajax" class="feat"> AJAX Handler
          </label>
          <label style="text-transform:none;letter-spacing:0;display:flex;align-items:center;gap:6px;cursor:pointer;font-weight:500">
            <input type="checkbox" value="dashboard" class="feat"> Dashboard Widget
          </label>
          <label style="text-transform:none;letter-spacing:0;display:flex;align-items:center;gap:6px;cursor:pointer;font-weight:500">
            <input type="checkbox" value="cron" class="feat"> Scheduled Task (cron)
          </label>
        </div>
      </div>
      <div style="margin-top:24px">
        <button class="btn" onclick="generate('plugin')">
          <span id="btn-plugin-text">✨ Generate Plugin</span>
          <div class="spinner" id="spinner-plugin"></div>
        </button>
      </div>
      <div class="progress-bar" id="prog-plugin"><div class="progress-fill" id="progf-plugin"></div></div>
      <div class="result" id="result-plugin"></div>
    </div>
  </div>

  <!-- AI Status Tab -->
  <div id="panel-status" class="panel">
    <div class="card">
      <h2 style="margin:0 0 20px">⚙️ AI Configuration</h2>
      <div id="ai-status-content"><div style="color:var(--muted)">Loading...</div></div>
      <div style="margin-top:24px">
        <button class="btn btn-sm" onclick="loadStatus()">🔄 Refresh</button>
        <a href="/api/health" target="_blank" style="margin-left:12px;font-size:13px;color:var(--primary)">
          Health Check →
        </a>
      </div>
    </div>
  </div>
</div>

<script>
// ── Tab switching ─────────────────────────────────────────────────────────────
function switchTab(name) {
  document.querySelectorAll('.tab').forEach((t,i) => t.classList.remove('active'));
  document.querySelectorAll('.panel').forEach(p => p.classList.remove('active'));
  const tabs = ['login','setup','theme','plugin','status'];
  document.querySelectorAll('.tab')[tabs.indexOf(name)].classList.add('active');
  document.getElementById('panel-'+name).classList.add('active');
  if(name==='status') loadStatus();
}

// ── Load sites list ───────────────────────────────────────────────────────────
async function loadSites() {
  try {
    const r = await fetch('/api/sites'); const d = await r.json();
    ['login','setup','theme','plugin'].forEach(t => {
      const el = document.getElementById('sites-'+t);
      el.innerHTML = d.sites.length ? '<small style="color:var(--muted);width:100%;display:block;margin-bottom:4px">Click a site:</small>' : '';
      d.sites.forEach(s => {
        const chip = document.createElement('div');
        chip.className='site-chip'; chip.textContent=s;
        chip.onclick=()=>{ document.getElementById(t+'-domain').value=s; };
        el.appendChild(chip);
      });
    });
    document.getElementById('stat-sites').textContent = d.sites.length;
    document.getElementById('stat-plugins').textContent = d.ei_plugins;
  } catch(e) {}
}

// ── Load AI status ────────────────────────────────────────────────────────────
async function loadStatus() {
  try {
    const r = await fetch('/api/status'); const d = await r.json();
    document.getElementById('stat-provider').textContent = d.provider || '—';
    document.getElementById('stat-model').textContent = d.model || '—';
    document.getElementById('ai-status-content').innerHTML = `
      <div class="grid" style="margin-bottom:20px">
        <div><label>Provider</label><div style="font-size:18px;font-weight:600">${d.provider}</div></div>
        <div><label>Model</label><div style="font-size:18px;font-weight:600">${d.model}</div></div>
        <div><label>Endpoint</label><div style="font-size:13px;word-break:break-all">${d.endpoint}</div></div>
        <div><label>Config File</label><div style="font-size:13px">${d.config_file}</div></div>
      </div>
      <label>Current ai.conf</label>
      <div class="ai-conf">${escHtml(d.config_raw)}</div>
      <div style="margin-top:16px;font-size:13px;color:var(--muted)">
        To change provider: edit <code>/etc/easyinstall/ai.conf</code> or run <code>easyinstall ai-setup</code>
      </div>`;
  } catch(e) {
    document.getElementById('ai-status-content').innerHTML = '<div style="color:var(--danger)">Could not load status.</div>';
  }
}

function escHtml(s) {
  return String(s).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;');
}

// ── Generate ──────────────────────────────────────────────────────────────────
async function generate(type) {
  const btn = document.getElementById('btn-'+type+'-text');
  const spinner = document.getElementById('spinner-'+type);
  const result  = document.getElementById('result-'+type);
  const prog    = document.getElementById('prog-'+type);
  const progf   = document.getElementById('progf-'+type);

  let payload = {};
  if(type==='login') {
    payload = {
      domain:      document.getElementById('login-domain').value.trim(),
      description: document.getElementById('login-desc').value.trim(),
      style:       document.getElementById('login-style').value,
      colors:      document.getElementById('login-color1').value+','+document.getElementById('login-color2').value,
    };
  } else if(type==='setup') {
    payload = {
      domain:      document.getElementById('setup-domain').value.trim(),
      description: document.getElementById('setup-desc').value.trim(),
    };
  } else if(type==='theme') {
    payload = {
      domain:      document.getElementById('theme-domain').value.trim(),
      description: document.getElementById('theme-desc').value.trim(),
      colors:      document.getElementById('theme-color1').value+','+document.getElementById('theme-color2').value,
    };
  } else if(type==='plugin') {
    const feats = [...document.querySelectorAll('.feat:checked')].map(c=>c.value);
    payload = {
      domain:      document.getElementById('plugin-domain').value.trim(),
      description: document.getElementById('plugin-desc').value.trim(),
      features:    feats.join(','),
    };
  }

  if(!payload.domain) { alert('Please enter a domain name.'); return; }

  btn.textContent = 'Generating…';
  spinner.style.display = 'inline-block';
  result.classList.remove('show');
  prog.style.display = 'block';

  // Animate progress bar
  let pct = 5;
  const interval = setInterval(() => {
    pct = Math.min(pct + Math.random()*8, 85);
    progf.style.width = pct + '%';
  }, 600);

  try {
    const r = await fetch('/api/generate/'+type, {
      method: 'POST',
      headers: {'Content-Type':'application/json'},
      body: JSON.stringify(payload),
    });
    const data = await r.json();
    clearInterval(interval);
    progf.style.width = '100%';
    setTimeout(() => { prog.style.display='none'; progf.style.width='0'; }, 600);

    if(data.success) {
      result.innerHTML = `<div class="result-box success">
        <h3>✅ Generated successfully!</h3>
        <div><strong>Plugin:</strong> ${escHtml(data.plugin_slug || '')}</div>
        <div><strong>Location:</strong> ${escHtml(data.plugin_dir || '')}</div>
        ${data.activate_cmd ? `<div style="margin-top:10px"><strong>Activate command:</strong>
          <div class="code">${escHtml(data.activate_cmd)}
            <button class="btn btn-sm copy-btn" onclick="navigator.clipboard.writeText('${escHtml(data.activate_cmd)}')">Copy</button>
          </div></div>` : ''}
        <div style="margin-top:12px;font-size:13px;color:var(--muted)">${escHtml(data.message || '')}</div>
      </div>`;
    } else {
      result.innerHTML = `<div class="result-box error">
        <h3>❌ Generation failed</h3>
        <div>${escHtml(data.message || 'Unknown error')}</div>
      </div>`;
    }
  } catch(e) {
    clearInterval(interval);
    result.innerHTML = `<div class="result-box error"><h3>❌ Request failed</h3><div>${escHtml(e.message)}</div></div>`;
    prog.style.display = 'none';
  } finally {
    btn.textContent = { login:'✨ Generate Login Page', setup:'✨ Generate Setup Wizard',
                        theme:'✨ Generate Theme Plugin', plugin:'✨ Generate Plugin' }[type];
    spinner.style.display = 'none';
    result.classList.add('show');
    loadSites();
  }
}

// ── Init ──────────────────────────────────────────────────────────────────────
loadSites();
loadStatus();
</script>
</body>
</html>
"""

# ── Flask app ─────────────────────────────────────────────────────────────────
if _FLASK_AVAILABLE:
    app = Flask(__name__)
    app.secret_key = os.urandom(24)

    def _get_sites() -> list:
        sites_root = Path("/var/www/html")
        sites = []
        if sites_root.exists():
            for entry in sorted(sites_root.iterdir()):
                if entry.is_dir() and (entry / "wp-config.php").exists():
                    sites.append(entry.name)
        return sites

    def _count_ei_plugins() -> int:
        count = 0
        sites_root = Path("/var/www/html")
        if sites_root.exists():
            for site in sites_root.iterdir():
                plugins_dir = site / "wp-content" / "plugins"
                if plugins_dir.exists():
                    count += sum(1 for p in plugins_dir.iterdir()
                                 if p.is_dir() and p.name.startswith("ei-"))
        return count

    def _load_ai_cfg_raw() -> str:
        f = Path("/etc/easyinstall/ai.conf")
        if f.exists():
            return f.read_text()
        return "# /etc/easyinstall/ai.conf not found\n# Run: easyinstall ai-setup"

    @app.route("/")
    def index():
        return render_template_string(_HTML)

    @app.route("/api/health")
    def health():
        return jsonify({"status": "ok", "version": "1.0", "timestamp": datetime.utcnow().isoformat()})

    @app.route("/api/sites")
    def api_sites():
        return jsonify({"sites": _get_sites(), "ei_plugins": _count_ei_plugins()})

    @app.route("/api/status")
    def api_status():
        from easyinstall_ai_pages import load_ai_config
        cfg = load_ai_config()
        return jsonify({
            "provider":    cfg["AI_PROVIDER"],
            "model":       cfg["AI_MODEL"],
            "endpoint":    cfg["AI_ENDPOINT"],
            "config_file": str(Path("/etc/easyinstall/ai.conf")),
            "config_raw":  _load_ai_cfg_raw(),
        })

    def _run_generator(gen_type: str, data: Dict) -> Dict[str, Any]:
        """Run the generator in a subprocess to keep the web server responsive."""
        sys.path.insert(0, "/usr/local/lib")
        try:
            from easyinstall_ai_pages import AIPageGenerator
            gen = AIPageGenerator()
            if gen_type == "login":
                return gen.generate_custom_login_page(
                    data["domain"], data.get("description",""), data.get("style","modern"), data.get("colors","#667eea,#764ba2")
                )
            elif gen_type == "setup":
                return gen.generate_custom_setup_page(data["domain"], data.get("description",""))
            elif gen_type == "theme":
                return gen.generate_custom_theme(data["domain"], data.get("description",""), data.get("colors","#667eea,#764ba2"))
            elif gen_type == "plugin":
                return gen.generate_custom_plugin(data["domain"], data.get("description",""), data.get("features","shortcode"))
        except Exception as exc:
            return {"success": False, "message": str(exc)}
        return {"success": False, "message": "Unknown generator type"}

    for _gtype in ("login", "setup", "theme", "plugin"):
        def _make_route(gt):
            @app.route(f"/api/generate/{gt}", methods=["POST"], endpoint=f"gen_{gt}")
            def _gen_route():
                data = request.get_json(force=True) or {}
                if not data.get("domain"):
                    return jsonify({"success": False, "message": "domain is required"}), 400
                result = _run_generator(gt, data)
                return jsonify(result)
            return _gen_route
        _make_route(_gtype)


# ── Entry point ───────────────────────────────────────────────────────────────
def main():
    parser = argparse.ArgumentParser(description="EasyInstall Page Generator Web Interface")
    parser.add_argument("--port", type=int, default=8080)
    parser.add_argument("--host", default="0.0.0.0")
    args = parser.parse_args()

    if not _FLASK_AVAILABLE:
        print("Flask not installed. Run: pip3 install flask --break-system-packages")
        sys.exit(1)

    # Ensure ai_pages module is importable
    sys.path.insert(0, "/usr/local/lib")

    logger.info("Starting EasyInstall Page Generator Web UI on http://%s:%s", args.host, args.port)
    app.run(host=args.host, port=args.port, debug=False, threaded=True)


if __name__ == "__main__":
    main()
