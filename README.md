# EasyInstall VPS v7.0

WordPress Performance Stack — Nginx + PHP + MariaDB + Redis
Cloudflare Workers + GitHub Private Repo deployment

---

## Quick Install (VPS पर)

```bash
sudo bash -c "$(curl -fsSL https://YOUR_WORKER.workers.dev/install.sh)"
```

फिर:
```bash
easyinstall install
easyinstall create yourdomain.com --ssl
```

---

## 502 Error Fix (Apache Conflict)

```bash
# Apache port 80 block करता है — यह fix करें
easyinstall fix-apache

# या manual fix
systemctl stop apache2
apt-get remove -y --purge apache2 apache2-bin apache2-data libapache2-mod-php*
apt-get autoremove -y
systemctl start nginx
```

---

## CF Worker Deploy करें

### Step 1 — Files तैयार करें

```
your-repo/
├── worker.js              ← Cloudflare Worker
├── wrangler.jsonc         ← Wrangler config
├── easyinstall_core.py    ← Python engine
├── easyinstall_wp.php     ← PHP WP helper
├── easyinstall.sh         ← Bash orchestrator
└── .github/workflows/
    └── deploy.yml         ← GitHub Actions CI/CD
```

### Step 2 — wrangler.jsonc में अपनी details डालें

```jsonc
{
  "name": "easyinstall-vps",
  "vars": {
    "GITHUB_RAW": "https://raw.githubusercontent.com/YOUR_USERNAME/YOUR_REPO/main"
  }
}
```

### Step 3 — R2 Bucket बनाएं (optional)

```bash
wrangler r2 bucket create easyinstall-files
```
`wrangler.jsonc` में r2_buckets uncomment करें।

### Step 4 — GitHub Secrets add करें

| Secret | Value |
|--------|-------|
| `CF_API_TOKEN`  | Cloudflare API token (Workers edit permission) |
| `CF_ACCOUNT_ID` | Cloudflare Account ID (Dashboard sidebar में) |

### Step 5 — Deploy

```bash
# Manual deploy
wrangler deploy

# या main branch push करें — GitHub Actions auto-deploy करेगा
git push origin main
```

---

## सभी Commands

| Command | Description |
|---------|-------------|
| `easyinstall install` | Full stack install |
| `easyinstall create domain.com --ssl` | WordPress site बनाएं |
| `easyinstall delete domain.com` | Site हटाएं |
| `easyinstall list` | सभी sites |
| `easyinstall site-info domain.com` | Site details |
| `easyinstall update-site domain.com --all` | WP core+plugins+themes update |
| `easyinstall update-site all` | सभी sites update |
| `easyinstall clone src.com dst.com` | Site clone |
| `easyinstall php-switch domain.com 8.4` | PHP version बदलें |
| `easyinstall ssl domain.com` | SSL enable |
| `easyinstall ssl-renew` | SSL renew |
| `easyinstall redis-status` | Redis status |
| `easyinstall status` | System status |
| `easyinstall health` | Health check |
| `easyinstall monitor` | Live monitor |
| `easyinstall logs [domain]` | Logs देखें |
| `easyinstall self-heal [mode]` | Auto-fix services |
| `easyinstall self-heal 502` | 502 error fix |
| `easyinstall self-update all` | सब update करें |
| `easyinstall self-check` | Versions check |
| `easyinstall backup [domain]` | Backup |
| `easyinstall optimize` | DB + cache optimize |
| `easyinstall clean` | Logs + temp clean |
| `easyinstall ws-enable domain port` | WebSocket enable |
| `easyinstall http3-enable` | HTTP/3 + QUIC |
| `easyinstall edge-setup` | Edge computing layer |
| `easyinstall ai-diagnose` | AI log analysis |
| `easyinstall pagespeed optimize domain` | PageSpeed optimize |
| **`easyinstall fix-apache`** | **Apache conflict fix** |
| **`easyinstall self-heal 502`** | **502 Bad Gateway fix** |

---

## Self-Heal Modes

```bash
easyinstall self-heal full      # सब कुछ heal करें
easyinstall self-heal services  # services restart
easyinstall self-heal configs   # configs fix
easyinstall self-heal ssl       # SSL renew
easyinstall self-heal disk      # disk cleanup
easyinstall self-heal wp        # WP permissions + update
easyinstall self-heal 502       # 502 Bad Gateway fix
```

---

## Supported OS

- Debian 11 (Bullseye)
- Debian 12 (Bookworm) ✅ Tested
- Ubuntu 20.04 LTS
- Ubuntu 22.04 LTS ✅ Tested
- Ubuntu 24.04 LTS ✅ Tested

---

## Architecture

```
VPS Server
├── Nginx (official mainline)     ← Port 80/443
├── PHP 8.4/8.3/8.2-FPM          ← FastCGI socket
├── MariaDB 11.4                  ← localhost:3306
├── Redis (per-site instances)    ← localhost:6379+
└── /usr/local/bin/easyinstall    ← Command

/usr/local/lib/easyinstall/
├── core.py      ← Python engine (install, manage, heal)
└── wp_helper.php ← PHP WP ops (DB, config, pagespeed)

Cloudflare Workers
├── worker.js        ← Serves install.sh + files
├── R2 Bucket        ← Stores engine files
└── GitHub Actions   ← Auto-deploy on push
```
