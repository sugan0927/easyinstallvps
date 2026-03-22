#!/usr/bin/env python3
"""
EasyInstall AI Page Generator — v1.0
======================================
AI-powered custom WordPress page, theme, and plugin generator.
Uses the existing AI config from /etc/easyinstall/ai.conf.

Deploy to: /usr/local/lib/easyinstall_ai_pages.py

Supports all AI providers already configured in EasyInstall:
  - Ollama (local, free — default)
  - OpenAI (GPT-4o-mini, etc.)
  - Groq   (fast free tier)
  - Gemini (Google)

DO NOT MODIFY: easyinstall.sh, easyinstall_config.py, easyinstall-ai.sh
"""

import os
import re
import sys
import json
import time
import shutil
import logging
import textwrap
import argparse
import subprocess
from pathlib import Path
from datetime import datetime
from typing import Optional, Dict, Any, List

# ── Logging ───────────────────────────────────────────────────────────────────
LOG_DIR = Path("/var/log/easyinstall")
LOG_DIR.mkdir(parents=True, exist_ok=True)

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s — %(message)s",
    handlers=[
        logging.FileHandler(LOG_DIR / "ai-pages.log"),
        logging.StreamHandler(),
    ],
)
logger = logging.getLogger("easyinstall.ai_pages")

# ── Colors for terminal output ────────────────────────────────────────────────
GREEN  = "\033[0;32m"
YELLOW = "\033[1;33m"
RED    = "\033[0;31m"
BLUE   = "\033[0;34m"
PURPLE = "\033[0;35m"
CYAN   = "\033[0;36m"
NC     = "\033[0m"

def cprint(color: str, msg: str):
    print(f"{color}{msg}{NC}")

# ── AI Configuration loader (reads existing ai.conf) ─────────────────────────
AI_CONF_FILE = Path("/etc/easyinstall/ai.conf")

def load_ai_config() -> Dict[str, str]:
    """Load AI provider config from existing EasyInstall ai.conf (bash source format)."""
    cfg = {
        "AI_API_KEY":  "",
        "AI_ENDPOINT": "http://localhost:11434/api/chat",
        "AI_MODEL":    "phi3",
        "AI_PROVIDER": "ollama",
    }
    if AI_CONF_FILE.exists():
        for line in AI_CONF_FILE.read_text().splitlines():
            line = line.strip()
            if "=" in line and not line.startswith("#"):
                key, _, val = line.partition("=")
                val = val.strip().strip('"').strip("'")
                if key.strip() in cfg:
                    cfg[key.strip()] = val
    return cfg


def call_ai(system_prompt: str, user_prompt: str, max_tokens: int = 4000) -> str:
    """
    Call the configured AI provider. Mirrors the logic of ai_call() in
    easyinstall-ai.sh so all providers work identically.
    """
    cfg = load_ai_config()
    provider  = cfg["AI_PROVIDER"].lower()
    model     = cfg["AI_MODEL"]
    endpoint  = cfg["AI_ENDPOINT"]
    api_key   = cfg["AI_API_KEY"]

    headers = {"Content-Type": "application/json"}
    payload: Dict[str, Any] = {}

    # ── Ollama ────────────────────────────────────────────────────────────────
    if provider == "ollama" or "11434" in endpoint:
        payload = {
            "model": model,
            "messages": [
                {"role": "system", "content": system_prompt},
                {"role": "user",   "content": user_prompt},
            ],
            "stream": False,
            "options": {"num_predict": max_tokens},
        }
        url = endpoint
        def _parse(d): return d.get("message", {}).get("content", "") or d.get("response", "")

    # ── Gemini ────────────────────────────────────────────────────────────────
    elif provider == "gemini":
        url = f"{endpoint}/{model}:generateContent?key={api_key}"
        payload = {
            "contents": [{"parts": [{"text": f"{system_prompt}\n\n{user_prompt}"}]}],
            "generationConfig": {"maxOutputTokens": max_tokens},
        }
        def _parse(d): return d["candidates"][0]["content"]["parts"][0]["text"]

    # ── OpenAI / Groq / OpenAI-compatible ────────────────────────────────────
    else:
        headers["Authorization"] = f"Bearer {api_key}"
        payload = {
            "model": model,
            "messages": [
                {"role": "system", "content": system_prompt},
                {"role": "user",   "content": user_prompt},
            ],
            "max_tokens": max_tokens,
            "temperature": 0.7,
        }
        url = endpoint
        def _parse(d): return d["choices"][0]["message"]["content"]

    # ── HTTP call via curl (avoids requests dependency) ───────────────────────
    try:
        header_args = []
        for k, v in headers.items():
            header_args += ["-H", f"{k}: {v}"]

        result = subprocess.run(
            ["curl", "-s", "--max-time", "180", "-X", "POST", url]
            + header_args
            + ["-d", json.dumps(payload)],
            capture_output=True, text=True, timeout=200,
        )
        if result.returncode != 0:
            raise RuntimeError(f"curl failed: {result.stderr[:200]}")

        data = json.loads(result.stdout)
        return _parse(data).strip()

    except json.JSONDecodeError as exc:
        raise RuntimeError(f"AI response not valid JSON: {result.stdout[:300]}") from exc
    except Exception as exc:
        raise RuntimeError(f"AI call failed: {exc}") from exc


# ── Template base files ───────────────────────────────────────────────────────
TEMPLATES_DIR = Path("/usr/local/lib/easyinstall_templates")

TEMPLATE_LOGIN_BASE = """\
<?php
/**
 * Plugin Name: {plugin_name}
 * Plugin URI:  https://{domain}
 * Description: {description}
 * Version:     1.0.0
 * Author:      EasyInstall AI
 * License:     GPL-2.0+
 */
if ( ! defined( 'ABSPATH' ) ) exit;

// ── Activation / Deactivation ─────────────────────────────────────────────────
register_activation_hook( __FILE__,   '__ei_login_activate' );
register_deactivation_hook( __FILE__, '__ei_login_deactivate' );
function __ei_login_activate()   {{ add_option( 'ei_custom_login_enabled', '1' ); }}
function __ei_login_deactivate() {{ delete_option( 'ei_custom_login_enabled' ); }}

// ── Hooks ─────────────────────────────────────────────────────────────────────
add_action( 'login_enqueue_scripts', '__ei_login_styles' );
add_filter( 'login_headerurl',       '__ei_login_logo_url' );
add_filter( 'login_headertext',      '__ei_login_logo_text' );

function __ei_login_logo_url()  {{ return home_url(); }}
function __ei_login_logo_text() {{ return get_bloginfo( 'name' ); }}

function __ei_login_styles() {{
?>
<style>
{css_content}
</style>
<script>
{js_content}
</script>
<?php
}}
"""

TEMPLATE_PLUGIN_BASE = """\
<?php
/**
 * Plugin Name: {plugin_name}
 * Plugin URI:  https://{domain}
 * Description: {description}
 * Version:     1.0.0
 * Author:      EasyInstall AI
 * License:     GPL-2.0+
 * Text Domain: ei-custom
 */
if ( ! defined( 'ABSPATH' ) ) exit;

define( 'EI_CUSTOM_VERSION', '1.0.0' );
define( 'EI_CUSTOM_PATH',    plugin_dir_path( __FILE__ ) );
define( 'EI_CUSTOM_URL',     plugin_dir_url( __FILE__ ) );

register_activation_hook( __FILE__,   array( 'EI_Custom_Plugin', 'activate' ) );
register_deactivation_hook( __FILE__, array( 'EI_Custom_Plugin', 'deactivate' ) );

{plugin_body}
"""


# ── Helper: write plugin safely ───────────────────────────────────────────────

def _write_plugin(domain: str, plugin_slug: str, php_content: str, extra_files: Dict[str, str] = None) -> Path:
    """Write plugin files to the WordPress plugins directory and return the plugin dir."""
    plugins_dir = Path(f"/var/www/html/{domain}/wp-content/plugins/{plugin_slug}")
    plugins_dir.mkdir(parents=True, exist_ok=True)

    main_file = plugins_dir / f"{plugin_slug}.php"
    main_file.write_text(php_content)
    main_file.chmod(0o644)

    if extra_files:
        for filename, content in extra_files.items():
            f = plugins_dir / filename
            f.parent.mkdir(parents=True, exist_ok=True)
            f.write_text(content)
            f.chmod(0o644)

    # Fix ownership
    subprocess.run(
        ["chown", "-R", "www-data:www-data", str(plugins_dir)],
        capture_output=True,
    )
    return plugins_dir


def _activate_plugin(domain: str, plugin_slug: str) -> bool:
    """Use WP-CLI to activate the plugin."""
    result = subprocess.run(
        [
            "wp", "--path", f"/var/www/html/{domain}",
            "--allow-root",
            "plugin", "activate", plugin_slug,
        ],
        capture_output=True, text=True, timeout=60,
    )
    return result.returncode == 0


def _result(success: bool, msg: str, plugin_slug: str = "", plugin_dir: str = "",
            activate_cmd: str = "") -> Dict[str, Any]:
    data = {"success": success, "message": msg}
    if plugin_slug:
        data["plugin_slug"] = plugin_slug
    if plugin_dir:
        data["plugin_dir"] = plugin_dir
    if activate_cmd:
        data["activate_cmd"] = activate_cmd
    return data


# ── AI Page Generator ─────────────────────────────────────────────────────────

class AIPageGenerator:
    """
    Generate WordPress plugins using AI — login pages, setup wizards,
    themes, and general-purpose plugins.
    """

    # ── Custom Login Page ─────────────────────────────────────────────────────

    def generate_custom_login_page(
        self,
        domain: str,
        description: str = "Modern login page with gradient background and smooth animations",
        style: str = "modern",
        colors: str = "#667eea,#764ba2",
    ) -> Dict[str, Any]:
        """Generate a custom WordPress login page plugin using AI."""

        site_dir = Path(f"/var/www/html/{domain}")
        if not site_dir.exists():
            return _result(False, f"WordPress site not found: {domain}")

        cprint(PURPLE, f"🤖 Generating AI-powered login page for {domain}...")
        cprint(BLUE,   f"   Style: {style} | Colors: {colors}")

        primary, secondary = (colors.split(",") + ["#764ba2"])[:2]

        system_prompt = (
            "You are a senior WordPress developer and UI/UX designer. "
            "Generate complete, production-ready WordPress login page CSS and JavaScript. "
            "Output ONLY valid CSS inside a <CSS> block and JavaScript inside a <JS> block. "
            "No explanations, no markdown fences — only the two tagged blocks."
        )

        user_prompt = textwrap.dedent(f"""\
            Create a custom WordPress login page with these requirements:
            Description: {description}
            Style: {style}
            Primary color: {primary}
            Secondary color: {secondary}
            Domain: {domain}

            Requirements:
            - Replace the default WordPress login form styling completely
            - Make it fully responsive (mobile-first)
            - Add smooth CSS transitions/animations
            - Custom logo area at top
            - Branded background ({style} style: {primary} → {secondary} gradient for modern/dark, clean white for minimal/corporate)
            - Style the submit button, input fields, and labels
            - Add a subtle loading animation on submit
            - Keep form functionality intact (DO NOT break WordPress auth)
            - For "dark" style: dark background (#1a1a2e), light text, glowing inputs
            - For "minimal": white background, thin borders, no shadows
            - For "corporate": professional navy/grey, sharp corners
            - For "creative": bold colors, rounded corners, playful elements

            Output format (exactly):
            <CSS>
            /* your CSS here */
            </CSS>
            <JS>
            // your JS here
            </JS>
        """)

        try:
            ai_response = call_ai(system_prompt, user_prompt, max_tokens=3000)
        except RuntimeError as exc:
            return _result(False, f"AI call failed: {exc}")

        # Parse CSS and JS from response
        css_match = re.search(r"<CSS>(.*?)</CSS>", ai_response, re.DOTALL)
        js_match  = re.search(r"<JS>(.*?)</JS>",  ai_response, re.DOTALL)

        css_content = css_match.group(1).strip() if css_match else self._fallback_login_css(primary, secondary, style)
        js_content  = js_match.group(1).strip()  if js_match  else self._fallback_login_js()

        plugin_slug = "ei-custom-login"
        plugin_name = f"EI Custom Login — {domain}"

        php_content = TEMPLATE_LOGIN_BASE.format(
            plugin_name=plugin_name,
            domain=domain,
            description=description,
            css_content=css_content,
            js_content=js_content,
        )

        plugin_dir = _write_plugin(domain, plugin_slug, php_content)

        # Try auto-activate
        activated = _activate_plugin(domain, plugin_slug)
        activate_cmd = f"wp plugin activate {plugin_slug} --path=/var/www/html/{domain} --allow-root"

        cprint(GREEN, f"✅ Custom login page generated!")
        cprint(YELLOW, f"   Plugin: {plugin_dir}")
        cprint(YELLOW, f"   Preview: https://{domain}/wp-login.php")
        if not activated:
            cprint(YELLOW, f"   Activate: {activate_cmd}")

        return _result(
            True,
            f"Custom login page created for {domain}",
            plugin_slug=plugin_slug,
            plugin_dir=str(plugin_dir),
            activate_cmd=activate_cmd,
        )

    def _fallback_login_css(self, primary: str, secondary: str, style: str) -> str:
        """High-quality fallback CSS if AI is unavailable."""
        if style == "dark":
            bg = "#1a1a2e"; text = "#eee"; input_bg = "#16213e"; border = "#0f3460"
        elif style == "minimal":
            bg = "#f8f9fa"; text = "#333"; input_bg = "#fff"; border = "#dee2e6"
        elif style == "corporate":
            bg = "#1e3a5f"; text = "#fff"; input_bg = "#fff"; border = "#2c5282"
        else:  # modern / creative
            bg = f"linear-gradient(135deg, {primary} 0%, {secondary} 100%)"
            text = "#fff"; input_bg = "rgba(255,255,255,0.15)"; border = "rgba(255,255,255,0.3)"

        return f"""\
body.login {{
    background: {bg};
    font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif;
}}
body.login #login {{
    width: 360px;
    padding: 40px;
    background: rgba(255,255,255,0.08);
    border-radius: 16px;
    box-shadow: 0 20px 60px rgba(0,0,0,0.3);
    backdrop-filter: blur(10px);
    margin: 8% auto;
}}
body.login h1 a {{
    background-image: none;
    color: {text};
    font-size: 24px;
    font-weight: 700;
    text-align: center;
    text-decoration: none;
    display: block;
    height: auto;
    width: auto;
    margin-bottom: 24px;
}}
body.login form {{
    background: transparent;
    border: none;
    box-shadow: none;
    padding: 0;
}}
body.login label {{
    color: {text};
    font-size: 13px;
    font-weight: 500;
    letter-spacing: 0.5px;
    text-transform: uppercase;
}}
body.login input[type="text"],
body.login input[type="password"] {{
    background: {input_bg};
    border: 1px solid {border};
    border-radius: 8px;
    color: {text};
    padding: 12px 16px;
    font-size: 15px;
    width: 100%;
    box-sizing: border-box;
    transition: all 0.3s ease;
    margin-top: 6px;
}}
body.login input[type="text"]:focus,
body.login input[type="password"]:focus {{
    outline: none;
    border-color: {primary};
    box-shadow: 0 0 0 3px {primary}40;
}}
body.login input[type="submit"] {{
    background: linear-gradient(135deg, {primary}, {secondary});
    border: none;
    border-radius: 8px;
    color: #fff;
    cursor: pointer;
    font-size: 15px;
    font-weight: 600;
    height: 46px;
    width: 100%;
    letter-spacing: 0.5px;
    transition: all 0.3s ease;
    margin-top: 20px;
}}
body.login input[type="submit"]:hover {{
    transform: translateY(-2px);
    box-shadow: 0 8px 25px {primary}60;
    opacity: 0.95;
}}
body.login #nav, body.login #backtoblog {{
    text-align: center;
}}
body.login #nav a, body.login #backtoblog a {{
    color: {text};
    opacity: 0.7;
    text-decoration: none;
    font-size: 13px;
}}
body.login #nav a:hover, body.login #backtoblog a:hover {{
    opacity: 1;
    text-decoration: underline;
}}
body.login .message, body.login .notice {{
    border-radius: 8px;
    border-left-color: {primary};
}}
"""

    def _fallback_login_js(self) -> str:
        return """\
document.addEventListener('DOMContentLoaded', function() {
    var form = document.getElementById('loginform');
    if (form) {
        form.addEventListener('submit', function() {
            var btn = document.getElementById('wp-submit');
            if (btn) {
                btn.value = 'Signing in...';
                btn.style.opacity = '0.7';
                btn.style.cursor = 'not-allowed';
            }
        });
    }
    // Animate on load
    var login = document.getElementById('login');
    if (login) {
        login.style.opacity = '0';
        login.style.transform = 'translateY(20px)';
        login.style.transition = 'all 0.5s ease';
        setTimeout(function() {
            login.style.opacity = '1';
            login.style.transform = 'translateY(0)';
        }, 100);
    }
});
"""

    # ── Custom Setup Wizard ───────────────────────────────────────────────────

    def generate_custom_setup_page(
        self,
        domain: str,
        description: str = "Modern 8-step installation wizard with progress bar and demo content",
    ) -> Dict[str, Any]:
        """Generate a custom WordPress setup wizard plugin using AI."""

        site_dir = Path(f"/var/www/html/{domain}")
        if not site_dir.exists():
            return _result(False, f"WordPress site not found: {domain}")

        cprint(PURPLE, f"🤖 Generating AI-powered setup wizard for {domain}...")

        system_prompt = (
            "You are an expert WordPress plugin developer. "
            "Generate a complete WordPress setup wizard plugin — a multi-step admin wizard. "
            "Output ONLY the PHP class body (inside <PHP> tags) that will be inserted "
            "into the plugin skeleton. No explanations, just the tagged content."
        )

        user_prompt = (
            f"Create a WordPress setup wizard plugin for: {domain}\n"
            f"Description: {description}\n\n"
            "Requirements:\n"
            "- Admin page registered under Tools -> Setup Wizard\n"
            "- Multi-step wizard UI with progress bar (at least 6 steps)\n"
            "- Steps: Welcome, Site Info, Appearance, Plugins, Demo Content, Complete\n"
            "- AJAX-powered step transitions (no page reloads)\n"
            "- Save settings to wp_options on each step\n"
            "- Modern, clean UI using WordPress admin styles + custom CSS\n"
            "- Dismiss/skip option on each step\n"
            "- Final step shows a summary + Launch Site button\n"
            "- Works with WordPress 6.0+\n\n"
            "Generate a PHP class called EI_Setup_Wizard with:\n"
            "- register() method: add_action hooks\n"
            "- admin_page() method: render the wizard HTML\n"
            "- Inline CSS in the head (wp_add_inline_style or echo in admin_head)\n"
            "- Inline JS for AJAX step handling\n"
            "- save_step() method: handles AJAX nonce-verified saves\n\n"
            "Output format (exactly):\n"
            "<PHP>\n"
            "class EI_Setup_Wizard {\n"
            "    // full implementation here\n"
            "}\n"
            "add_action('plugins_loaded', function() { (new EI_Setup_Wizard())->register(); });\n"
            "</PHP>"
        )

        try:
            ai_response = call_ai(system_prompt, user_prompt, max_tokens=3500)
        except RuntimeError as exc:
            return _result(False, f"AI call failed: {exc}")

        php_match = re.search(r"<PHP>(.*?)</PHP>", ai_response, re.DOTALL)
        php_body  = php_match.group(1).strip() if php_match else self._fallback_setup_wizard()

        plugin_slug = "ei-custom-setup"
        php_content = TEMPLATE_PLUGIN_BASE.format(
            plugin_name=f"EI Custom Setup Wizard — {domain}",
            domain=domain,
            description=description,
            plugin_body=php_body,
        )

        plugin_dir = _write_plugin(domain, plugin_slug, php_content)
        activated  = _activate_plugin(domain, plugin_slug)
        activate_cmd = f"wp plugin activate {plugin_slug} --path=/var/www/html/{domain} --allow-root"

        cprint(GREEN,  f"✅ Custom setup wizard generated!")
        cprint(YELLOW, f"   Plugin: {plugin_dir}")
        cprint(YELLOW, f"   Access: https://{domain}/wp-admin/tools.php?page=ei-setup-wizard")

        return _result(True, f"Setup wizard created for {domain}",
                       plugin_slug=plugin_slug, plugin_dir=str(plugin_dir),
                       activate_cmd=activate_cmd)

    def _fallback_setup_wizard(self) -> str:
        return textwrap.dedent("""\
            class EI_Setup_Wizard {
                private $steps = ['welcome','site-info','appearance','plugins','demo','complete'];

                public function register() {
                    add_action('admin_menu', [$this, 'add_menu']);
                    add_action('wp_ajax_ei_save_step', [$this, 'save_step']);
                }

                public function add_menu() {
                    add_management_page('Setup Wizard','Setup Wizard','manage_options','ei-setup-wizard',[$this,'render']);
                }

                public function render() {
                    $current = isset($_GET['step']) ? intval($_GET['step']) : 0;
                    $total   = count($this->steps);
                    $pct     = round(($current / max($total-1,1)) * 100);
                    ?>
                    <div class="wrap" id="ei-wizard">
                    <style>
                    #ei-wizard{max-width:700px;margin:40px auto;font-family:-apple-system,sans-serif}
                    .ei-progress{background:#e9ecef;border-radius:50px;height:8px;margin:20px 0 40px}
                    .ei-progress-bar{background:linear-gradient(90deg,#667eea,#764ba2);height:100%;border-radius:50px;transition:width .4s}
                    .ei-card{background:#fff;border-radius:12px;padding:40px;box-shadow:0 4px 20px rgba(0,0,0,.08)}
                    .ei-btn{background:linear-gradient(135deg,#667eea,#764ba2);color:#fff;border:none;border-radius:8px;padding:12px 32px;font-size:15px;cursor:pointer;font-weight:600}
                    .ei-btn:hover{opacity:.9} .ei-skip{color:#999;font-size:13px;cursor:pointer;margin-left:16px}
                    h2{margin:0 0 8px;font-size:24px} .ei-sub{color:#666;margin:0 0 30px}
                    </style>
                    <h1>⚡ EasyInstall Setup Wizard</h1>
                    <div class="ei-progress"><div class="ei-progress-bar" style="width:<?php echo $pct ?>%"></div></div>
                    <div class="ei-card">
                    <?php
                    $labels = ['Welcome','Site Info','Appearance','Plugins','Demo Content','Complete'];
                    echo "<h2>Step ".($current+1)." of $total: ".$labels[$current]."</h2>";
                    echo "<p class='ei-sub'>Complete each step to set up your WordPress site.</p>";
                    if($current < $total-1){
                        $next = $current+1;
                        echo "<button class='ei-btn' onclick=\"location.href='?page=ei-setup-wizard&step=$next'\">Continue →</button>";
                        echo "<span class='ei-skip' onclick=\"location.href='?page=ei-setup-wizard&step=$next'\">Skip this step</span>";
                    } else {
                        echo "<h3>🎉 Setup Complete!</h3>";
                        echo "<p>Your site is ready.</p>";
                        echo "<a href='".home_url()."' class='ei-btn'>Launch Site →</a>";
                    }
                    ?>
                    </div></div>
                    <?php
                }

                public function save_step() {
                    check_ajax_referer('ei_setup','nonce');
                    $step = sanitize_text_field($_POST['step'] ?? '');
                    update_option("ei_setup_{$step}_done", 1);
                    wp_send_json_success(['step' => $step]);
                }
            }
            add_action('plugins_loaded', function() { (new EI_Setup_Wizard())->register(); });
        """)

    # ── Custom Theme Generator ────────────────────────────────────────────────

    def generate_custom_theme(
        self,
        domain: str,
        description: str = "Modern business theme with responsive design",
        colors: str = "#667eea,#764ba2",
    ) -> Dict[str, Any]:
        """Generate a custom child theme plugin using AI."""

        site_dir = Path(f"/var/www/html/{domain}")
        if not site_dir.exists():
            return _result(False, f"WordPress site not found: {domain}")

        cprint(PURPLE, f"🤖 Generating AI-powered theme customizations for {domain}...")

        primary, secondary = (colors.split(",") + ["#764ba2"])[:2]

        system_prompt = (
            "You are a WordPress theme developer and CSS expert. "
            "Generate a WordPress plugin that adds comprehensive CSS customizations "
            "and theme enhancements via wp_add_inline_style and add_action hooks. "
            "Output ONLY a PHP class body inside <PHP> tags."
        )

        user_prompt = (
            f"Create a WordPress theme customizer plugin for: {domain}\n"
            f"Description: {description}\n"
            f"Primary color: {primary}\n"
            f"Secondary color: {secondary}\n\n"
            "Requirements:\n"
            "- Plugin injects CSS via wp_add_inline_style (applies to any active theme)\n"
            f"- Custom header with gradient background ({primary} to {secondary})\n"
            "- Styled navigation menu (horizontal, sticky on scroll)\n"
            "- Hero section styles (full-width, centered text, CTA button)\n"
            "- Card-style post listings with hover effects\n"
            "- Custom button styles (.ei-btn class + override .wp-block-button)\n"
            "- Responsive typography scale (clamp-based)\n"
            "- Custom footer with gradient and copyright\n"
            "- Smooth scroll behavior\n"
            "- Loading animation for page transitions\n"
            "- Custom scrollbar styling (WebKit)\n"
            "- WordPress Customizer integration: add color picker for primary/secondary\n\n"
            "Output format (exactly):\n"
            "<PHP>\n"
            "class EI_Theme_Customizer {\n"
            "    // full implementation here\n"
            "}\n"
            "add_action('plugins_loaded', function() { (new EI_Theme_Customizer())->init(); });\n"
            "</PHP>"
        )

        try:
            ai_response = call_ai(system_prompt, user_prompt, max_tokens=3500)
        except RuntimeError as exc:
            return _result(False, f"AI call failed: {exc}")

        php_match = re.search(r"<PHP>(.*?)</PHP>", ai_response, re.DOTALL)
        php_body  = php_match.group(1).strip() if php_match else self._fallback_theme(primary, secondary)

        plugin_slug = "ei-custom-theme"
        php_content = TEMPLATE_PLUGIN_BASE.format(
            plugin_name=f"EI Custom Theme — {domain}",
            domain=domain,
            description=description,
            plugin_body=php_body,
        )

        plugin_dir = _write_plugin(domain, plugin_slug, php_content)
        activated  = _activate_plugin(domain, plugin_slug)
        activate_cmd = f"wp plugin activate {plugin_slug} --path=/var/www/html/{domain} --allow-root"

        cprint(GREEN,  f"✅ Custom theme plugin generated!")
        cprint(YELLOW, f"   Plugin: {plugin_dir}")
        cprint(YELLOW, f"   Customize: https://{domain}/wp-admin/customize.php")

        return _result(True, f"Theme plugin created for {domain}",
                       plugin_slug=plugin_slug, plugin_dir=str(plugin_dir),
                       activate_cmd=activate_cmd)

    def _fallback_theme(self, primary: str, secondary: str) -> str:
        return textwrap.dedent(f"""\
            class EI_Theme_Customizer {{
                public function init() {{
                    add_action('wp_head', [$this, 'inject_css']);
                    add_action('wp_footer', [$this, 'inject_js']);
                    add_action('customize_register', [$this, 'customizer_settings']);
                }}

                public function inject_css() {{
                    $primary   = get_option('ei_theme_primary',   '{primary}');
                    $secondary = get_option('ei_theme_secondary', '{secondary}');
                    echo "<style>
                    :root {{ --ei-primary: $primary; --ei-secondary: $secondary; }}
                    *, *::before, *::after {{ box-sizing: border-box; }}
                    html {{ scroll-behavior: smooth; }}
                    body {{ font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif; }}
                    .site-header {{
                        background: linear-gradient(135deg, $primary, $secondary);
                        padding: 0; position: sticky; top: 0; z-index: 999;
                        box-shadow: 0 2px 20px rgba(0,0,0,.15);
                    }}
                    .site-header .site-branding a,
                    .site-header .site-title a {{ color: #fff !important; text-decoration: none; }}
                    nav .nav-menu a, nav ul li a {{
                        color: rgba(255,255,255,.9) !important;
                        padding: 20px 16px; display: block;
                        transition: color .2s;
                    }}
                    nav .nav-menu a:hover, nav ul li a:hover {{ color: #fff !important; }}
                    .wp-block-button__link, .ei-btn {{
                        background: linear-gradient(135deg, $primary, $secondary) !important;
                        border: none !important; border-radius: 8px !important;
                        padding: 12px 28px !important; font-weight: 600 !important;
                        transition: all .3s !important; color: #fff !important;
                    }}
                    .wp-block-button__link:hover, .ei-btn:hover {{
                        transform: translateY(-2px);
                        box-shadow: 0 8px 25px rgba(0,0,0,.25) !important;
                    }}
                    .site-footer {{
                        background: linear-gradient(135deg, $primary, $secondary);
                        color: #fff; padding: 40px 20px; text-align: center; margin-top: 60px;
                    }}
                    .site-footer a {{ color: rgba(255,255,255,.8); text-decoration: none; }}
                    ::-webkit-scrollbar {{ width: 8px; }}
                    ::-webkit-scrollbar-track {{ background: #f1f1f1; }}
                    ::-webkit-scrollbar-thumb {{ background: $primary; border-radius: 4px; }}
                    </style>";
                }}

                public function inject_js() {{
                    echo "<script>
                    document.addEventListener('DOMContentLoaded',function(){{
                        var header = document.querySelector('.site-header');
                        if(header){{
                            window.addEventListener('scroll',function(){{
                                header.style.boxShadow = window.scrollY > 50
                                    ? '0 4px 30px rgba(0,0,0,.2)' : '0 2px 20px rgba(0,0,0,.15)';
                            }});
                        }}
                    }});
                    </script>";
                }}

                public function customizer_settings( $wp_customize ) {{
                    $wp_customize->add_section('ei_theme_colors', ['title' => 'EI Theme Colors', 'priority' => 30]);
                    $wp_customize->add_setting('ei_theme_primary',   ['default' => '{primary}',   'sanitize_callback' => 'sanitize_hex_color']);
                    $wp_customize->add_setting('ei_theme_secondary', ['default' => '{secondary}', 'sanitize_callback' => 'sanitize_hex_color']);
                    $wp_customize->add_control(new WP_Customize_Color_Control($wp_customize, 'ei_theme_primary',   ['section' => 'ei_theme_colors', 'label' => 'Primary Color']));
                    $wp_customize->add_control(new WP_Customize_Color_Control($wp_customize, 'ei_theme_secondary', ['section' => 'ei_theme_colors', 'label' => 'Secondary Color']));
                }}
            }}
            add_action('plugins_loaded', function() {{ (new EI_Theme_Customizer())->init(); }});
        """)

    # ── Custom Plugin Generator ───────────────────────────────────────────────

    def generate_custom_plugin(
        self,
        domain: str,
        description: str = "Custom WordPress functionality plugin",
        features: str = "shortcode,widget,settings",
    ) -> Dict[str, Any]:
        """Generate a custom WordPress plugin using AI based on feature list."""

        site_dir = Path(f"/var/www/html/{domain}")
        if not site_dir.exists():
            return _result(False, f"WordPress site not found: {domain}")

        features_list = [f.strip() for f in features.split(",")]
        cprint(PURPLE, f"🤖 Generating AI-powered plugin for {domain}...")
        cprint(BLUE,   f"   Features: {', '.join(features_list)}")

        system_prompt = (
            "You are a senior WordPress plugin developer following WordPress Coding Standards. "
            "Generate a complete, production-ready WordPress plugin. "
            "Output ONLY the plugin body PHP code inside <PHP> tags — no extra text."
        )

        user_prompt = textwrap.dedent(f"""\
            Create a WordPress plugin for: {domain}
            Description: {description}
            Features requested: {', '.join(features_list)}

            Implementation requirements for each feature:
            - shortcode:  [ei_custom] shortcode that renders a styled widget/card
            - widget:     WordPress sidebar widget extending WP_Widget
            - settings:   Admin settings page (Settings → EI Custom) with text/color fields
            - cpt:        Custom Post Type registration with proper labels and supports
            - rest:       Custom REST API endpoint GET /wp-json/ei/v1/data
            - ajax:       Frontend AJAX example (nonce-protected) + admin AJAX handler
            - dashboard:  Dashboard widget showing plugin stats
            - gutenberg:  Gutenberg block registration (PHP side, registers block.json)
            - cron:       WP-Cron scheduled task running hourly

            Only implement the features listed in "Features requested" above.
            Follow WordPress security best practices: nonces, sanitization, escaping.
            Use proper WordPress hooks (init, admin_menu, rest_api_init, etc.)
            Prefix all functions/classes with ei_ to avoid collisions.

            Output format:
            <PHP>
            // your complete plugin body here
            </PHP>
        """)

        try:
            ai_response = call_ai(system_prompt, user_prompt, max_tokens=4000)
        except RuntimeError as exc:
            return _result(False, f"AI call failed: {exc}")

        php_match = re.search(r"<PHP>(.*?)</PHP>", ai_response, re.DOTALL)
        php_body  = php_match.group(1).strip() if php_match else self._fallback_plugin(description, features_list)

        plugin_slug = "ei-custom-plugin"
        php_content = TEMPLATE_PLUGIN_BASE.format(
            plugin_name=f"EI Custom Plugin — {domain}",
            domain=domain,
            description=description,
            plugin_body=php_body,
        )

        plugin_dir = _write_plugin(domain, plugin_slug, php_content)
        activated  = _activate_plugin(domain, plugin_slug)
        activate_cmd = f"wp plugin activate {plugin_slug} --path=/var/www/html/{domain} --allow-root"

        cprint(GREEN,  f"✅ Custom plugin generated!")
        cprint(YELLOW, f"   Plugin: {plugin_dir}")
        cprint(YELLOW, f"   Settings: https://{domain}/wp-admin/options-general.php?page=ei-custom")

        return _result(True, f"Custom plugin created for {domain}",
                       plugin_slug=plugin_slug, plugin_dir=str(plugin_dir),
                       activate_cmd=activate_cmd)

    def _fallback_plugin(self, description: str, features: List[str]) -> str:
        blocks = [f"// EI Custom Plugin — {description}\n// Features: {', '.join(features)}\n"]

        if "shortcode" in features:
            blocks.append(textwrap.dedent("""\
                add_shortcode('ei_custom', function($atts) {
                    $a = shortcode_atts(['title' => 'EasyInstall Widget', 'text' => ''], $atts);
                    $title = esc_html($a['title']); $text = esc_html($a['text']);
                    return "<div style='border:1px solid #667eea;border-radius:8px;padding:20px;margin:16px 0;background:#f8f9ff'>
                        <h3 style='color:#667eea;margin:0 0 8px'>$title</h3><p style='margin:0'>$text</p></div>";
                });
            """))

        if "settings" in features:
            blocks.append(textwrap.dedent("""\
                add_action('admin_menu', function() {
                    add_options_page('EI Custom','EI Custom','manage_options','ei-custom','ei_settings_page');
                });
                function ei_settings_page() {
                    if(isset($_POST['ei_save'])) {
                        check_admin_referer('ei_settings');
                        update_option('ei_custom_title', sanitize_text_field($_POST['ei_title'] ?? ''));
                        echo '<div class="notice notice-success"><p>Settings saved.</p></div>';
                    }
                    $title = esc_attr(get_option('ei_custom_title','EasyInstall'));
                    echo '<div class="wrap"><h1>EI Custom Settings</h1>
                    <form method="post">'.wp_nonce_field('ei_settings','_wpnonce',true,false).'
                    <table class="form-table"><tr><th>Title</th><td>
                    <input type="text" name="ei_title" value="'.$title.'" class="regular-text"></td></tr></table>
                    <p class="submit"><button type="submit" name="ei_save" class="button-primary">Save Changes</button></p>
                    </form></div>';
                }
            """))

        if "widget" in features:
            blocks.append(textwrap.dedent("""\
                class EI_Custom_Widget extends WP_Widget {
                    public function __construct() {
                        parent::__construct('ei_custom_widget','EI Custom Widget',['description'=>'A custom EasyInstall widget']);
                    }
                    public function widget($args,$instance) {
                        echo $args['before_widget'];
                        $title = apply_filters('widget_title', $instance['title'] ?? 'EI Widget');
                        if($title) echo $args['before_title'].esc_html($title).$args['after_title'];
                        echo '<p>'.esc_html($instance['text'] ?? 'Custom widget content.').'</p>';
                        echo $args['after_widget'];
                    }
                    public function form($instance) {
                        $title = esc_attr($instance['title'] ?? 'EI Widget');
                        $text  = esc_attr($instance['text']  ?? '');
                        echo '<p><label>Title<input class="widefat" name="'.$this->get_field_name('title').'" type="text" value="'.$title.'"></label></p>';
                        echo '<p><label>Text<textarea class="widefat" name="'.$this->get_field_name('text').'">'.$text.'</textarea></label></p>';
                    }
                    public function update($new,$old) {
                        return ['title'=>sanitize_text_field($new['title']),'text'=>sanitize_textarea_field($new['text'])];
                    }
                }
                add_action('widgets_init', function() { register_widget('EI_Custom_Widget'); });
            """))

        return "\n".join(blocks)


# ── Template file writer ──────────────────────────────────────────────────────

def write_template_files():
    """Write base template files to /usr/local/lib/easyinstall_templates/."""
    TEMPLATES_DIR.mkdir(parents=True, exist_ok=True)

    templates = {
        "login-page.template.php": "<?php\n// EasyInstall Login Page Template\n// Used by easyinstall_ai_pages.py\n",
        "setup-wizard.template.php": "<?php\n// EasyInstall Setup Wizard Template\n",
        "plugin-base.template.php": "<?php\n// EasyInstall Plugin Base Template\n",
        "theme-base.template.css": "/* EasyInstall Theme Base CSS */\n:root { --ei-primary: #667eea; --ei-secondary: #764ba2; }\n",
        "step-template.php": "<?php\n// EasyInstall Step Template\n// $step_number, $step_title, $step_content variables available\n",
    }

    for name, content in templates.items():
        path = TEMPLATES_DIR / name
        if not path.exists():
            path.write_text(content)

    logger.info("Template files written to %s", TEMPLATES_DIR)


# ── CLI argument parser ───────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(
        description="EasyInstall AI Page Generator v1.0",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=textwrap.dedent("""\
            Examples:
              %(prog)s generate-login  --domain mysite.com --style dark
              %(prog)s generate-setup  --domain mysite.com --description "E-commerce wizard"
              %(prog)s generate-theme  --domain mysite.com --colors "#e74c3c,#c0392b"
              %(prog)s generate-plugin --domain mysite.com --features shortcode,widget,settings
              %(prog)s write-templates
        """),
    )
    sub = parser.add_subparsers(dest="command", help="Sub-command")

    # generate-login
    p_login = sub.add_parser("generate-login", help="Generate custom login page")
    p_login.add_argument("--domain",      required=True)
    p_login.add_argument("--description", default="Modern login page with gradient background")
    p_login.add_argument("--style",       default="modern",
                         choices=["modern", "minimal", "corporate", "creative", "dark"])
    p_login.add_argument("--colors",      default="#667eea,#764ba2")
    p_login.add_argument("--json",        action="store_true", help="Output JSON result")

    # generate-setup
    p_setup = sub.add_parser("generate-setup", help="Generate setup wizard")
    p_setup.add_argument("--domain",      required=True)
    p_setup.add_argument("--description", default="Modern 8-step installation wizard")
    p_setup.add_argument("--json",        action="store_true")

    # generate-theme
    p_theme = sub.add_parser("generate-theme", help="Generate theme customizations")
    p_theme.add_argument("--domain",      required=True)
    p_theme.add_argument("--description", default="Modern business theme with responsive design")
    p_theme.add_argument("--colors",      default="#667eea,#764ba2")
    p_theme.add_argument("--json",        action="store_true")

    # generate-plugin
    p_plugin = sub.add_parser("generate-plugin", help="Generate custom plugin")
    p_plugin.add_argument("--domain",      required=True)
    p_plugin.add_argument("--description", default="Custom WordPress functionality plugin")
    p_plugin.add_argument("--features",    default="shortcode,widget,settings")
    p_plugin.add_argument("--json",        action="store_true")

    # write-templates
    sub.add_parser("write-templates", help="Write base template files")

    args = parser.parse_args()

    if not args.command:
        parser.print_help()
        sys.exit(0)

    if args.command == "write-templates":
        write_template_files()
        cprint(GREEN, f"✅ Templates written to {TEMPLATES_DIR}")
        return

    gen = AIPageGenerator()
    result: Dict[str, Any] = {}

    if args.command == "generate-login":
        result = gen.generate_custom_login_page(
            args.domain, args.description, args.style, args.colors
        )
    elif args.command == "generate-setup":
        result = gen.generate_custom_setup_page(args.domain, args.description)
    elif args.command == "generate-theme":
        result = gen.generate_custom_theme(args.domain, args.description, args.colors)
    elif args.command == "generate-plugin":
        result = gen.generate_custom_plugin(args.domain, args.description, args.features)

    if getattr(args, "json", False):
        print(json.dumps(result, indent=2))
    elif not result.get("success", True):
        cprint(RED, f"❌ {result.get('message', 'Unknown error')}")
        sys.exit(1)
    else:
        if result.get("activate_cmd"):
            cprint(CYAN, f"\n   Activate command: {result['activate_cmd']}")


if __name__ == "__main__":
    main()
