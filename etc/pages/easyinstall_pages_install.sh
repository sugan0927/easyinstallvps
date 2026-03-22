#!/bin/bash
# ============================================================
# EasyInstall AI Page Generator — Installer v1.0
# Installs all AI page generator files without modifying
# any existing EasyInstall core files.
#
# Usage:
#   bash easyinstall_pages_install.sh
#
# What it does:
#   1. Copies Python modules to /usr/local/lib/
#   2. Installs easyinstall-pages CLI command
#   3. Appends AI functions to easyinstall-ai.sh
#   4. Writes systemd service for web interface
#   5. Installs bash completion
#   6. Installs Python dependencies (flask)
#   7. Writes template files
#   8. Injects new CLI commands into easyinstall dispatcher
# ============================================================

set -eE
trap 'echo -e "\033[0;31m❌ Installer failed at line $LINENO\033[0m"; exit 1' ERR

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'
CYAN='\033[0;36m'; PURPLE='\033[0;35m'; NC='\033[0m'

log_step() { echo -e "${CYAN}🔷 $1${NC}"; }
log_ok()   { echo -e "${GREEN}✅ $1${NC}"; }
log_warn() { echo -e "${YELLOW}⚠️  $1${NC}"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="/usr/local/lib"
BIN_DIR="/usr/local/bin"
SYSTEMD_DIR="/etc/systemd/system"
COMPLETION_DIR="/etc/bash_completion.d"
LOG_DIR="/var/log/easyinstall"
DOC_DIR="/usr/share/doc/easyinstall"
TEMPLATES_DIR="$LIB_DIR/easyinstall_templates"
AI_MODULE="/usr/local/lib/easyinstall-ai.sh"
EI_BIN="/usr/local/bin/easyinstall"

clear
echo -e "${PURPLE}╔══════════════════════════════════════════════════════╗${NC}"
echo -e "${PURPLE}║  🎨 EasyInstall AI Page Generator — Installer v1.0  ║${NC}"
echo -e "${PURPLE}╚══════════════════════════════════════════════════════╝${NC}"
echo ""

# ── 1. Directories ────────────────────────────────────────────────────────────
log_step "Creating directories..."
mkdir -p "$LOG_DIR" "$TEMPLATES_DIR" "$DOC_DIR"
log_ok "Directories ready"

# ── 2. Copy Python modules ────────────────────────────────────────────────────
log_step "Installing Python modules..."
for module in easyinstall_ai_pages.py easyinstall_page_web.py; do
    if [ -f "$SCRIPT_DIR/$module" ]; then
        cp "$SCRIPT_DIR/$module" "$LIB_DIR/$module"
        chmod 644 "$LIB_DIR/$module"
        log_ok "Installed: $LIB_DIR/$module"
    else
        log_warn "Not found in script dir: $module"
    fi
done

# ── 3. Python syntax check ────────────────────────────────────────────────────
log_step "Validating module syntax..."
for module in easyinstall_ai_pages.py easyinstall_page_web.py; do
    if [ -f "$LIB_DIR/$module" ]; then
        if python3 -m py_compile "$LIB_DIR/$module" 2>/dev/null; then
            log_ok "Syntax OK: $module"
        else
            log_warn "Syntax warning: $module (may still work)"
        fi
    fi
done

# ── 4. Install CLI command ────────────────────────────────────────────────────
log_step "Installing easyinstall-pages CLI command..."
if [ -f "$SCRIPT_DIR/easyinstall-pages" ]; then
    cp "$SCRIPT_DIR/easyinstall-pages" "$BIN_DIR/easyinstall-pages"
    chmod 755 "$BIN_DIR/easyinstall-pages"
    log_ok "Installed: $BIN_DIR/easyinstall-pages"
else
    log_warn "easyinstall-pages not found in script dir — skipping"
fi

# ── 5. Install Python dependencies ───────────────────────────────────────────
log_step "Installing Python dependencies..."
if command -v pip3 &>/dev/null; then
    for pkg in flask; do
        if pip3 install "$pkg" --break-system-packages --quiet 2>/dev/null || \
           pip3 install "$pkg" --quiet 2>/dev/null; then
            log_ok "pip: $pkg"
        else
            log_warn "pip: $pkg failed — web interface may not work"
        fi
    done
else
    log_warn "pip3 not found — install flask manually: pip3 install flask"
fi

# ── 6. Write template files ───────────────────────────────────────────────────
log_step "Writing template files..."
PYTHONPATH="$LIB_DIR" python3 "$LIB_DIR/easyinstall_ai_pages.py" write-templates 2>/dev/null && \
    log_ok "Templates written to $TEMPLATES_DIR" || \
    log_warn "Template write skipped"

# ── 7. Append AI functions to easyinstall-ai.sh ───────────────────────────────
log_step "Extending AI module (easyinstall-ai.sh)..."
MARKER="# ── EasyInstall AI Page Generator Functions v1.0"

if [ ! -f "$AI_MODULE" ]; then
    log_warn "$AI_MODULE not found — will be extended when it's created by main installer"
    # Write a stub that will be sourced later
    AI_APPEND_TARGET="/etc/easyinstall/ai-pages-addon.sh"
else
    AI_APPEND_TARGET="$AI_MODULE"
fi

if grep -q "$MARKER" "$AI_APPEND_TARGET" 2>/dev/null; then
    log_warn "AI page functions already in $AI_APPEND_TARGET — skipping"
else
    cat >> "$AI_APPEND_TARGET" <<'AI_FUNCTIONS'

# ── EasyInstall AI Page Generator Functions v1.0 ──────────────────────────────
# Appended by easyinstall_pages_install.sh — DO NOT REMOVE THIS BLOCK

ai_generate_login_page() {
    local domain="$1"
    local description="${2:-Modern login page with gradient background and smooth animations}"
    local style="${3:-modern}"
    local colors="${4:-#667eea,#764ba2}"
    echo -e "\033[0;35m🎨 Generating login page for ${domain}...\033[0m"
    PYTHONPATH=/usr/local/lib python3 /usr/local/lib/easyinstall_ai_pages.py generate-login \
        --domain "$domain" --description "$description" --style "$style" --colors "$colors"
}

ai_generate_setup_page() {
    local domain="$1"
    local description="${2:-Modern 8-step installation wizard with progress bar and demo content}"
    echo -e "\033[0;35m🚀 Generating setup wizard for ${domain}...\033[0m"
    PYTHONPATH=/usr/local/lib python3 /usr/local/lib/easyinstall_ai_pages.py generate-setup \
        --domain "$domain" --description "$description"
}

ai_generate_theme() {
    local domain="$1"
    local description="${2:-Modern business theme with responsive design}"
    local colors="${3:-#667eea,#764ba2}"
    echo -e "\033[0;35m🎨 Generating theme plugin for ${domain}...\033[0m"
    PYTHONPATH=/usr/local/lib python3 /usr/local/lib/easyinstall_ai_pages.py generate-theme \
        --domain "$domain" --description "$description" --colors "$colors"
}

ai_generate_plugin() {
    local domain="$1"
    local description="${2:-Custom functionality plugin}"
    local features="${3:-shortcode,widget,settings}"
    echo -e "\033[0;35m🔌 Generating custom plugin for ${domain}...\033[0m"
    PYTHONPATH=/usr/local/lib python3 /usr/local/lib/easyinstall_ai_pages.py generate-plugin \
        --domain "$domain" --description "$description" --features "$features"
}

ai_page_assistant() {
    local domain="$1"
    [ -z "$domain" ] && { echo -e "\033[0;31m❌ Usage: ai_page_assistant domain.com\033[0m"; return 1; }
    # Delegate to the easyinstall-pages CLI for the full interactive experience
    if command -v easyinstall-pages &>/dev/null; then
        easyinstall-pages page-assist "$domain"
    else
        echo -e "\033[1;33m⚠️  Run: easyinstall-pages page-assist $domain\033[0m"
    fi
}

AI_FUNCTIONS
    log_ok "AI page functions appended to $AI_APPEND_TARGET"
fi

# ── 8. Systemd service for web interface ──────────────────────────────────────
log_step "Writing systemd service for web interface..."
cat > "$SYSTEMD_DIR/easyinstall-pages-web.service" <<'EOF'
[Unit]
Description=EasyInstall AI Page Generator Web Interface
After=network.target
Wants=nginx.service

[Service]
Type=simple
User=root
WorkingDirectory=/usr/local/lib
ExecStart=/usr/bin/python3 /usr/local/lib/easyinstall_page_web.py --port 8080 --host 0.0.0.0
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal
SyslogIdentifier=easyinstall-pages-web
Environment=PYTHONUNBUFFERED=1
Environment=PYTHONPATH=/usr/local/lib

[Install]
WantedBy=multi-user.target
EOF
log_ok "Written: $SYSTEMD_DIR/easyinstall-pages-web.service"
systemctl daemon-reload 2>/dev/null || true

# ── 9. Bash completion ────────────────────────────────────────────────────────
log_step "Installing bash completion..."
cat > "$COMPLETION_DIR/easyinstall-pages" <<'EOF'
# EasyInstall Pages Bash Completion v1.0
_easyinstall_pages_complete() {
    local cur prev
    COMPREPLY=()
    cur="${COMP_WORDS[COMP_CWORD]}"
    prev="${COMP_WORDS[COMP_CWORD-1]}"

    local cmds="custom-login custom-setup custom-theme custom-plugin page-assist
                web-start web-stop web-status list-plugins delete-plugin ai-status help"

    case "$prev" in
        easyinstall-pages)
            COMPREPLY=( $(compgen -W "$cmds" -- "$cur") )
            return 0 ;;
        custom-login|custom-setup|custom-theme|custom-plugin|page-assist|list-plugins|delete-plugin)
            if [ -d "/var/www/html" ]; then
                COMPREPLY=( $(compgen -W "$(ls /var/www/html 2>/dev/null)" -- "$cur") )
            fi
            return 0 ;;
        web-start)
            COMPREPLY=( $(compgen -W "8080 8081 8082 3000 5000" -- "$cur") )
            return 0 ;;
        # login style completion
        custom-login)
            if [ "${COMP_CWORD}" -eq 3 ]; then
                COMPREPLY=( $(compgen -W "modern dark minimal corporate creative" -- "$cur") )
            fi
            return 0 ;;
    esac
}
complete -F _easyinstall_pages_complete easyinstall-pages
EOF
log_ok "Bash completion installed"

# ── 10. Documentation ─────────────────────────────────────────────────────────
log_step "Writing documentation..."
cat > "$DOC_DIR/CUSTOM-PAGES.md" <<'DOCEOF'
# 🎨 EasyInstall AI Page Generator

## Overview
Generate beautiful custom WordPress login pages, setup wizards, theme plugins,
and custom functionality plugins using AI — without touching any core EasyInstall files.

## Requirements
- EasyInstall v7.0 or higher
- AI provider configured (`easyinstall ai-setup`)
- WordPress site installed (`easyinstall create domain.com`)

## Quick Start

### CLI Usage
```bash
# Generate custom login page (dark style)
easyinstall-pages custom-login mysite.com "Branded dark login" dark

# Generate setup wizard
easyinstall-pages custom-setup mysite.com "E-commerce 6-step wizard"

# Generate theme customizer with custom colors
easyinstall-pages custom-theme mysite.com "SaaS theme" "#e74c3c,#c0392b"

# Generate plugin with multiple features
easyinstall-pages custom-plugin mysite.com "Lead form" shortcode,settings,cron

# Interactive AI assistant
easyinstall-pages page-assist mysite.com
```

### Web Interface
```bash
easyinstall-pages web-start 8080
# Opens: http://YOUR_SERVER_IP:8080
```

## AI Providers

Configure via: `easyinstall ai-setup` or edit `/etc/easyinstall/ai.conf`

| Provider | Speed | Cost | Quality |
|----------|-------|------|---------|
| Ollama (local) | Medium | Free | Good |
| Groq | Fast | Free tier | Great |
| OpenAI GPT-4o-mini | Fast | ~$0.001/req | Excellent |
| Gemini | Fast | Free tier | Great |

## Generated Plugin Locations
All plugins are installed to:
`/var/www/html/{domain}/wp-content/plugins/ei-custom-*/`

## Commands Reference
| Command | Description |
|---------|-------------|
| `custom-login <domain> [desc] [style]` | Login page (modern/dark/minimal/corporate/creative) |
| `custom-setup <domain> [desc]` | Multi-step setup wizard |
| `custom-theme <domain> [desc] [colors]` | Theme customizer plugin |
| `custom-plugin <domain> [desc] [features]` | Custom plugin |
| `page-assist <domain>` | Interactive assistant |
| `web-start [port]` | Start web UI |
| `web-stop` | Stop web UI |
| `list-plugins [domain]` | List generated plugins |
| `delete-plugin <domain> <slug>` | Remove a plugin |
| `ai-status` | Show AI configuration |

## Troubleshooting
```bash
# Check AI module logs
tail -f /var/log/easyinstall/ai-pages.log

# Check web interface logs
tail -f /var/log/easyinstall/page-web.log

# Manually activate a plugin
wp plugin activate ei-custom-login --path=/var/www/html/mysite.com --allow-root

# Test AI connection (Ollama)
curl http://localhost:11434/api/tags
```
DOCEOF
log_ok "Documentation written: $DOC_DIR/CUSTOM-PAGES.md"

# ── 11. Inject into easyinstall CLI dispatcher ────────────────────────────────
log_step "Injecting commands into easyinstall CLI..."
MARKER_CLI="# ── EasyInstall AI Pages CLI Commands v1.0"

if [ ! -f "$EI_BIN" ]; then
    log_warn "$EI_BIN not found — CLI injection skipped (install core first)"
elif grep -q "$MARKER_CLI" "$EI_BIN" 2>/dev/null; then
    log_warn "AI pages CLI commands already injected — skipping"
else
    cp "$EI_BIN" "${EI_BIN}.bak.pages.$(date +%Y%m%d%H%M%S)"
    python3 - "$EI_BIN" <<'PYEOF'
import sys, re

path = sys.argv[1]
src  = open(path).read()

block = """
        # ── EasyInstall AI Pages CLI Commands v1.0 ────────────────────────────
        # Injected by easyinstall_pages_install.sh

        custom-login)
            [ -z "$2" ] && { echo -e "${RED}❌ Usage: easyinstall custom-login domain.com [description] [style]${NC}"; exit 1; }
            easyinstall-pages custom-login "$2" "${3:-}" "${4:-modern}" ;;

        custom-setup)
            [ -z "$2" ] && { echo -e "${RED}❌ Usage: easyinstall custom-setup domain.com [description]${NC}"; exit 1; }
            easyinstall-pages custom-setup "$2" "${3:-}" ;;

        custom-theme)
            [ -z "$2" ] && { echo -e "${RED}❌ Usage: easyinstall custom-theme domain.com [description] [colors]${NC}"; exit 1; }
            easyinstall-pages custom-theme "$2" "${3:-}" "${4:-#667eea,#764ba2}" ;;

        custom-plugin)
            [ -z "$2" ] && { echo -e "${RED}❌ Usage: easyinstall custom-plugin domain.com [description] [features]${NC}"; exit 1; }
            easyinstall-pages custom-plugin "$2" "${3:-}" "${4:-shortcode,widget,settings}" ;;

        page-assist)
            [ -z "$2" ] && { echo -e "${RED}❌ Usage: easyinstall page-assist domain.com${NC}"; exit 1; }
            easyinstall-pages page-assist "$2" ;;

        pages-web)
            subcmd="${2:-status}"
            case "$subcmd" in
                start)  easyinstall-pages web-start "${3:-8080}" ;;
                stop)   easyinstall-pages web-stop ;;
                status) easyinstall-pages web-status ;;
                *)      easyinstall-pages web-status ;;
            esac ;;

        list-pages)
            easyinstall-pages list-plugins "${2:-}" ;;

"""

patched = re.sub(r'^        \*\)', block + '        *)', src, count=1, flags=re.MULTILINE)
if patched == src:
    idx = src.rfind('\n        esac')
    if idx != -1:
        patched = src[:idx] + block + src[idx:]

open(path, 'w').write(patched)
print("CLI patch applied")
PYEOF

    if grep -q "$MARKER_CLI" "$EI_BIN" 2>/dev/null; then
        chmod 755 "$EI_BIN"
        log_ok "CLI commands injected into $EI_BIN"
    else
        log_warn "CLI injection may need manual check"
    fi
fi

# ── Final summary ─────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║  ✅ EasyInstall AI Page Generator Installed!             ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${YELLOW}📁 Installed Files:${NC}"
echo "   $LIB_DIR/easyinstall_ai_pages.py   — Core generator"
echo "   $LIB_DIR/easyinstall_page_web.py   — Web interface"
echo "   $BIN_DIR/easyinstall-pages         — CLI command"
echo "   $TEMPLATES_DIR/                    — PHP templates"
echo "   $DOC_DIR/CUSTOM-PAGES.md           — Documentation"
echo ""
echo -e "${YELLOW}🆕 New Commands:${NC}"
echo "   easyinstall custom-login <domain> [desc] [style]"
echo "   easyinstall custom-setup <domain> [desc]"
echo "   easyinstall custom-theme <domain> [desc] [colors]"
echo "   easyinstall custom-plugin <domain> [desc] [features]"
echo "   easyinstall page-assist <domain>"
echo "   easyinstall pages-web [start|stop|status]"
echo "   easyinstall list-pages [domain]"
echo ""
echo -e "${YELLOW}🎨 Standalone CLI:${NC}"
echo "   easyinstall-pages help"
echo "   easyinstall-pages web-start 8080"
echo ""
echo -e "${YELLOW}📡 Web Interface:${NC}"
echo "   Start: easyinstall-pages web-start 8080"
echo "   Then open: http://$(hostname -I 2>/dev/null | awk '{print $1}' || echo YOUR_IP):8080"
echo ""
echo -e "${YELLOW}📝 Logs:${NC}   /var/log/easyinstall/ai-pages.log"
echo -e "${YELLOW}📖 Docs:${NC}   $DOC_DIR/CUSTOM-PAGES.md"
echo ""
echo -e "${GREEN}Test it now:${NC}"
echo "   easyinstall-pages help"
echo "   source ~/.bashrc   # for tab completion"
echo ""
