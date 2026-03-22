# 🔌 EasyInstall Plugins — Complete Documentation

> **Important:** All plugins are optional add-ons. They never modify any core EasyInstall files.

---

## Quick Start

```bash
# One-command setup (installs plugin infrastructure)
sudo bash easyinstall-worker-setup

# List available plugins
easyinstall-plugin list

# Enable a plugin
easyinstall-plugin enable cloudflare_worker

# Start the web dashboard
easyinstall-plugin webui start --port 8080

# Health check
easyinstall-plugin doctor
```

---

## File Structure

```
plugins/
├── easyinstall-plugin              # CLI command  → /usr/local/bin/
├── easyinstall-worker-setup        # Setup script → /usr/local/bin/
├── easyinstall_plugin_manager.py   # Core manager → /usr/local/lib/
├── etc/
│   └── plugins/
│       └── cloudflare_worker.json  # Default configs → /etc/easyinstall/plugins/
└── easyinstall_plugins/            # All plugin files → /usr/local/lib/easyinstall_plugins/
    ├── __init__.py
    ├── cloudflare_worker.py
    ├── docker_plugin.py
    ├── kubernetes_plugin.py
    ├── podman_plugin.py
    ├── microvm_plugin.py
    ├── webui_plugin.py
    ├── debian_package.py
    ├── systemd_plugin.py
    ├── edge_script.py
    ├── pkg_manager.py
    ├── ts_worker.py
    └── build_system.py
```

---

## CLI Reference

| Command | Description |
|---------|-------------|
| `easyinstall-plugin list` | List all plugins with status |
| `easyinstall-plugin enable <name>` | Enable a plugin |
| `easyinstall-plugin disable <name>` | Disable a plugin |
| `easyinstall-plugin status [name]` | Show status (all or one) |
| `easyinstall-plugin info <name>` | Show full plugin metadata |
| `easyinstall-plugin install <name> --file=path` | Install from local file |
| `easyinstall-plugin install <name> --url=https://...` | Install from URL |
| `easyinstall-plugin uninstall <name>` | Remove a plugin |
| `easyinstall-plugin update` | Update all plugins |
| `easyinstall-plugin webui start [--port=8080]` | Start web dashboard |
| `easyinstall-plugin webui stop` | Stop web dashboard |
| `easyinstall-plugin doctor` | System health check |

---

## Plugin Reference

### 1. `cloudflare_worker` — Cloudflare Worker Plugin

Deploy WordPress edge logic to Cloudflare Workers with caching, rate limiting, and security headers.

**Module:** `cloudflare_worker.py`  
**Requires:** Node.js, npm, wrangler  
**Provides:** edge-cache, rate-limiting, edge-ssl

```python
from easyinstall_plugins.cloudflare_worker import CloudflareWorkerPlugin

p = CloudflareWorkerPlugin({})
p.initialize()

# Generate worker script
p.generate_worker_script("/tmp/worker.js")

# Generate wrangler config
p.generate_wrangler_config("example.com", kv_id="YOUR_KV_ID")

# Deploy
p.deploy_worker("example.com", api_token="CF_TOKEN", account_id="CF_ACCOUNT")

# Purge cache
p.purge_cache(zone_id="ZONE_ID", api_token="CF_TOKEN")
```

**Config:** `/etc/easyinstall/plugins/cloudflare_worker.json`
```json
{
  "api_token":      "your-cloudflare-api-token",
  "account_id":     "your-account-id",
  "zone_id":        "your-zone-id",
  "worker_name":    "easyinstall-wp",
  "kv_namespace_id": "your-kv-id"
}
```

---

### 2. `docker_plugin` — Docker Plugin

Generates Docker Compose stacks (WordPress + MariaDB + Redis + Nginx) and Docker Swarm configs.

**Module:** `docker_plugin.py`  
**Requires:** docker  
**Provides:** container-orchestration

```bash
# Enable
easyinstall-plugin enable docker_plugin

# Python API
from easyinstall_plugins.docker_plugin import DockerPlugin
p = DockerPlugin({})
p.initialize()

# Generate compose file
path = p.generate_compose("example.com", db_password="secure_pass")

# Start stack
p.up(path)

# Backup database
p.backup("example.com")

# Docker Swarm stack
p.generate_swarm_stack("example.com", replicas=3)
```

---

### 3. `kubernetes_plugin` — Kubernetes Plugin

Generates complete Kubernetes manifests (Deployments, Services, PVCs, Ingress, HPA) and Helm chart scaffolding.

**Module:** `kubernetes_plugin.py`  
**Requires:** kubectl (optional, for apply)  
**Provides:** k8s-orchestration, helm-chart, hpa

```python
from easyinstall_plugins.kubernetes_plugin import KubernetesPlugin

p = KubernetesPlugin({})
p.initialize()

# Generate full manifest set
manifests_dir = p.generate_manifests("example.com", db_password="secure")

# Apply to cluster
p.apply(manifests_dir)

# Scaffold Helm chart
p.generate_helm_chart("example.com", output_dir="/opt/helm")
```

---

### 4. `podman_plugin` — Podman Plugin

Rootless containers with Podman. Generates podman-compose files, Quadlet units, and auto-update configuration.

**Module:** `podman_plugin.py`  
**Requires:** podman  
**Provides:** rootless-containers, quadlet, auto-update

```python
from easyinstall_plugins.podman_plugin import PodmanPlugin

p = PodmanPlugin({})
p.initialize()

# Generate compose
p.generate_compose("example.com")

# Generate Quadlet unit (Podman 4.4+)
p.generate_quadlet("example.com")

# Enable auto-updates
p.enable_auto_update()
```

---

### 5. `microvm_plugin` — MicroVM Plugin

Firecracker and Cloud Hypervisor microVM configuration for lightweight VM isolation per WordPress site.

**Module:** `microvm_plugin.py`  
**Requires:** firecracker  
**Provides:** vm-isolation, microvm-lifecycle, vm-snapshot

```python
from easyinstall_plugins.microvm_plugin import MicroVMPlugin

p = MicroVMPlugin({})
p.initialize()

# Create rootfs image
p.create_rootfs("example.com", size_mb=2048)

# Generate Firecracker config
p.generate_firecracker_config("example.com", vcpus=2, mem_mib=512)

# Generate systemd unit
p.generate_systemd_unit("example.com")

# Snapshot running VM
p.snapshot("example.com")
```

---

### 6. `webui_plugin` — Web UI Dashboard

Flask-based browser dashboard for site management, plugin control, and live metrics.

**Module:** `webui_plugin.py`  
**Requires:** python3-flask  
**Provides:** web-dashboard, rest-api

```bash
# Start dashboard
easyinstall-plugin webui start --port 8080
# Open: http://YOUR_SERVER_IP:8080

# Stop dashboard
easyinstall-plugin webui stop

# Install as systemd service
easyinstall-plugin enable webui_plugin
```

**API Endpoints:**
- `GET /api/stats` — CPU, RAM, disk, site count
- `GET /api/sites` — List WordPress sites
- `GET /api/plugins` — List plugins
- `POST /api/plugin/enable` — Enable plugin `{"name": "..."}`
- `POST /api/plugin/disable` — Disable plugin
- `GET /api/log` — Last 100 log lines

---

### 7. `debian_package` — Debian Package Plugin

Build `.deb` packages for EasyInstall and manage a self-hosted APT repository.

**Module:** `debian_package.py`  
**Requires:** dpkg-dev  
**Provides:** deb-build, apt-repo

```python
from easyinstall_plugins.debian_package import DebianPackagePlugin

p = DebianPackagePlugin({})
p.initialize()

# Build a .deb
deb = p.build("example.com", version="1.0.0", output_dir="/dist")

# Create APT repository
p.create_repository("/var/www/apt")
p.update_repository("/var/www/apt")

# Install
p.install_deb(deb)
```

---

### 8. `systemd_plugin` — Extended Systemd Plugin

Installs additional systemd service and timer units for monitoring, healing, backups, and log rotation.

**Module:** `systemd_plugin.py`  
**Requires:** systemd  
**Provides:** glances, autoheal-timer, backup-timer, log-rotation

```bash
# Install all extended units
easyinstall-plugin enable systemd_plugin
```

**Installed Units:**
| Unit | Type | Schedule |
|------|------|----------|
| `easyinstall-glances` | service | always-on |
| `easyinstall-autoheal-extended` | timer | every 10 min |
| `easyinstall-resource-governor` | timer | hourly |
| `easyinstall-log-rotation` | timer | daily |
| `easyinstall-backup-timer` | timer | 02:00 daily |

```python
# Custom unit
from easyinstall_plugins.systemd_plugin import SystemdPlugin
p = SystemdPlugin({})
p.generate_custom_unit("my-task", "My custom task", "/usr/local/bin/my-script.sh", interval="weekly")
```

---

### 9. `edge_script` — Edge Script Plugin

Ready-to-use Cloudflare Worker JavaScript templates for common edge patterns.

**Module:** `edge_script.py`  
**Requires:** none  
**Provides:** edge-functions, cache-strategy, websocket-proxy, geo-routing

**Available Templates:**
- `security-headers` — Inject security headers on every response
- `websocket` — WebSocket proxy with optional token auth
- `geo-routing` — Country-based redirect/origin routing
- `ab-test` — 50/50 A/B traffic split with cookie persistence
- `cache-strategy` — Multi-TTL stale-while-revalidate caching

```python
from easyinstall_plugins.edge_script import EdgeScriptPlugin

p = EdgeScriptPlugin({})

# Generate single template
p.generate("security-headers", domain="example.com", output_dir="/tmp")

# Generate all
p.generate_all(domain="example.com", output_dir="/opt/workers")

# Combine multiple into one worker
p.combine(["security-headers", "cache-strategy"], domain="example.com")
```

---

### 10. `pkg_manager` — Package Manager Plugin

Unified plugin registry with install/uninstall, version locking, and update automation.

**Module:** `pkg_manager.py`  
**Requires:** none  
**Provides:** pkg-install, pkg-update, version-lock, plugin-registry

```python
from easyinstall_plugins.pkg_manager import PkgManagerPlugin

p = PkgManagerPlugin({})
p.initialize()

# Install from URL
p.install("my-plugin", source_url="https://example.com/my_plugin.py")

# Install from file
p.install("my-plugin", source_file="/path/to/my_plugin.py")

# Lock version
p.lock("cloudflare_worker", "1.0.0")

# Update all (respects locks)
p.update_all()

# List installed
for pkg in p.list_installed():
    print(pkg)
```

**Registry:** `/etc/easyinstall/plugins/registry.json`  
**Lock file:** `/etc/easyinstall/plugins/easyinstall.lock`

---

### 11. `ts_worker` — TypeScript Worker Plugin

Scaffold complete TypeScript Cloudflare Worker projects with type definitions, Vitest tests, and Wrangler deploy config.

**Module:** `ts_worker.py`  
**Requires:** node, npm  
**Provides:** ts-worker, worker-types, vitest-tests

```python
from easyinstall_plugins.ts_worker import TypeScriptWorkerPlugin

p = TypeScriptWorkerPlugin({})
p.initialize()

# Scaffold project
project_dir = p.scaffold("example.com", output_dir="/opt/workers")

# Install deps
p.install_deps(project_dir)

# Type-check
p.build(project_dir)

# Run tests
p.run_tests(project_dir)

# Deploy
p.deploy(project_dir, env="production")
```

Generated project structure:
```
example-com-worker/
├── src/
│   ├── index.ts          # Main worker with caching & security headers
│   └── index.test.ts     # Vitest unit tests
├── tsconfig.json
├── package.json
├── wrangler.toml
├── deno.json
└── .gitignore
```

---

### 12. `build_system` — Build System Plugin

CI/CD pipeline generation, Docker multi-arch builds, Makefile scaffolding, and semantic version tagging.

**Module:** `build_system.py`  
**Requires:** docker, git  
**Provides:** ci-cd, docker-build, deb-build, makefile, version-tagging

```python
from easyinstall_plugins.build_system import BuildSystemPlugin

p = BuildSystemPlugin({})
p.initialize()

# Generate everything
p.generate_all("example.com", project_dir=".", docker_image="myrepo/wordpress")

# Individual generators
p.generate_github_actions("example.com")
p.generate_dockerfile(php_version="8.2")
p.generate_makefile("example.com")

# Build Docker image (multi-arch)
p.build_docker_image("myrepo/wordpress:latest",
                     platforms=["linux/amd64","linux/arm64"], push=True)

# Version management
p.create_git_tag("1.2.0", push=True)
p.bump_version("minor")
```

---

## Writing a Custom Plugin

```python
# /usr/local/lib/easyinstall_plugins/my_plugin.py
from easyinstall_plugin_manager import BasePlugin, PluginMetadata

class MyPlugin(BasePlugin):
    def get_metadata(self) -> PluginMetadata:
        return PluginMetadata(
            name        = "my-plugin",
            version     = "1.0.0",
            description = "My custom EasyInstall plugin",
            author      = "You",
            requires    = [],          # system binaries needed
            provides    = ["my-feature"],
        )

    def initialize(self) -> bool:
        # Set up files, check prerequisites, etc.
        self.logger.info("My plugin initialising...")
        return True   # return False to abort enabling

    def my_method(self, domain: str) -> str:
        # Your logic here
        return f"Did something for {domain}"
```

### Plugin Hooks

```python
def on_site_created(self, domain: str):
    self.logger.info(f"Site created: {domain}")
    self.my_method(domain)

# Register during initialize():
def initialize(self) -> bool:
    self.register_hook("site_created", self.on_site_created)
    return True
```

---

## Troubleshooting

```bash
# Check system health
easyinstall-plugin doctor

# View plugin logs
tail -f /var/log/easyinstall/plugins.log

# Verify plugin loaded
easyinstall-plugin status cloudflare_worker

# Reinstall a broken plugin
easyinstall-plugin uninstall cloudflare_worker
easyinstall-plugin install cloudflare_worker --file=/path/to/cloudflare_worker.py

# Check Python path
python3 -c "import sys; print('\n'.join(sys.path))"

# Manual plugin test
python3 -c "
import sys; sys.path.insert(0, '/usr/local/lib')
from easyinstall_plugins.cloudflare_worker import CloudflareWorkerPlugin
p = CloudflareWorkerPlugin({})
p.initialize()
meta = p.get_metadata()
print(meta.name, meta.version)
"
```

---

## Core Files — Never Modified

The following files are **never touched** by the plugin system:

- `/usr/local/bin/easyinstall`
- `/usr/local/lib/easyinstall_config.py`
- `/usr/local/lib/easyinstall-ai.sh`
- `/usr/local/lib/easyinstall_ai_pages.py`
- `/usr/local/lib/easyinstall_api.py`
- `/usr/local/lib/easyinstall_db.py`
- `/usr/local/lib/easyinstall_security.py`
- `/usr/local/lib/easyinstall_monitor.py`
- `/usr/local/lib/easyinstall_autotune.sh`
- `/etc/easyinstall/ai.conf`
- `/etc/easyinstall/api.conf`
- `/etc/easyinstall/database.conf`
- `/var/www/html/` (all WordPress sites)
