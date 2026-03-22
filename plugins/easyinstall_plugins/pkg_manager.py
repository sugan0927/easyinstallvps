#!/usr/bin/env python3
"""
pkg_manager.py — EasyInstall Package Manager Plugin v1.0
=========================================================
Unified interface for installing, updating, version-locking,
and managing EasyInstall plugins and their system dependencies.
Maintains a local registry in /etc/easyinstall/plugins/registry.json.
"""

import json
import shutil
import subprocess
import hashlib
import urllib.request
from pathlib import Path
from typing import Dict, List, Optional, Any
from datetime import datetime

try:
    from easyinstall_plugin_manager import BasePlugin, PluginMetadata
except ImportError:
    import sys; sys.path.insert(0, "/usr/local/lib")
    from easyinstall_plugin_manager import BasePlugin, PluginMetadata


REGISTRY_PATH   = Path("/etc/easyinstall/plugins/registry.json")
LOCK_FILE_PATH  = Path("/etc/easyinstall/plugins/easyinstall.lock")
PLUGINS_DIR     = Path("/usr/local/lib/easyinstall_plugins")


def _load_registry() -> Dict:
    if REGISTRY_PATH.exists():
        try:
            return json.loads(REGISTRY_PATH.read_text())
        except json.JSONDecodeError:
            pass
    return {"packages": {}, "last_updated": ""}


def _save_registry(reg: Dict):
    REGISTRY_PATH.parent.mkdir(parents=True, exist_ok=True)
    reg["last_updated"] = datetime.utcnow().isoformat() + "Z"
    REGISTRY_PATH.write_text(json.dumps(reg, indent=2))


def _load_lock() -> Dict:
    if LOCK_FILE_PATH.exists():
        try:
            return json.loads(LOCK_FILE_PATH.read_text())
        except json.JSONDecodeError:
            pass
    return {"locked": {}}


def _save_lock(lock: Dict):
    LOCK_FILE_PATH.write_text(json.dumps(lock, indent=2))


class PkgManagerPlugin(BasePlugin):

    def get_metadata(self) -> PluginMetadata:
        return PluginMetadata(
            name        = "pkg-manager",
            version     = "1.0.0",
            description = "Unified plugin/package manager: install, update, lock, registry",
            author      = "EasyInstall",
            requires    = [],
            provides    = ["pkg-install", "pkg-update", "version-lock", "plugin-registry"],
        )

    def initialize(self) -> bool:
        PLUGINS_DIR.mkdir(parents=True, exist_ok=True)
        REGISTRY_PATH.parent.mkdir(parents=True, exist_ok=True)
        if not REGISTRY_PATH.exists():
            _save_registry({"packages": {}})
        return True

    # ── Registry ──────────────────────────────────────────────────────────────

    def list_installed(self) -> List[Dict]:
        reg = _load_registry()
        return [{"name": k, **v} for k, v in reg["packages"].items()]

    def register_package(self, name: str, version: str, source: str,
                          file_hash: str = "") -> bool:
        reg = _load_registry()
        reg["packages"][name] = {
            "version":     version,
            "source":      source,
            "hash":        file_hash,
            "installed_at": datetime.utcnow().isoformat() + "Z",
        }
        _save_registry(reg)
        self.logger.info(f"Registered package: {name} v{version}")
        return True

    def unregister_package(self, name: str) -> bool:
        reg = _load_registry()
        if name in reg["packages"]:
            del reg["packages"][name]
            _save_registry(reg)
            self.logger.info(f"Unregistered: {name}")
            return True
        return False

    # ── Install / uninstall ───────────────────────────────────────────────────

    def install(self, name: str, source_url: str = "",
                 source_file: str = "") -> bool:
        """
        Install a plugin from a URL or local file.
        Copies the .py file into PLUGINS_DIR and registers it.
        """
        lock = _load_lock()
        if name in lock.get("locked", {}):
            locked_ver = lock["locked"][name]
            self.logger.warning(f"Package '{name}' is locked at version {locked_ver}. Unlock first.")
            return False

        if source_file:
            src = Path(source_file)
            if not src.exists():
                self.logger.error(f"Source file not found: {source_file}")
                return False
            dest = PLUGINS_DIR / src.name
            shutil.copy2(src, dest)
            h = hashlib.sha256(src.read_bytes()).hexdigest()[:16]
            self.register_package(name, "local", source_file, h)
            self.logger.info(f"Installed from file: {dest}")
            return True

        if source_url:
            try:
                dest = PLUGINS_DIR / f"{name}.py"
                with urllib.request.urlopen(source_url, timeout=30) as resp:
                    data = resp.read()
                dest.write_bytes(data)
                h = hashlib.sha256(data).hexdigest()[:16]
                self.register_package(name, "remote", source_url, h)
                self.logger.info(f"Installed from URL: {dest}")
                return True
            except Exception as exc:
                self.logger.error(f"Download failed: {exc}")
                return False

        self.logger.error("Provide source_url or source_file")
        return False

    def uninstall(self, name: str, force: bool = False) -> bool:
        lock = _load_lock()
        if name in lock.get("locked", {}) and not force:
            self.logger.warning(f"'{name}' is version-locked. Use force=True to override.")
            return False

        plugin_file = PLUGINS_DIR / f"{name}.py"
        if plugin_file.exists():
            plugin_file.unlink()
            self.logger.info(f"Removed: {plugin_file}")
        self.unregister_package(name)
        return True

    # ── Version locking ───────────────────────────────────────────────────────

    def lock(self, name: str, version: str) -> bool:
        lock = _load_lock()
        lock.setdefault("locked", {})[name] = version
        _save_lock(lock)
        self.logger.info(f"Locked {name} at version {version}")
        return True

    def unlock(self, name: str) -> bool:
        lock = _load_lock()
        if name in lock.get("locked", {}):
            del lock["locked"][name]
            _save_lock(lock)
            self.logger.info(f"Unlocked: {name}")
            return True
        self.logger.warning(f"'{name}' is not locked")
        return False

    def list_locked(self) -> Dict[str, str]:
        return _load_lock().get("locked", {})

    # ── System dependency installer ───────────────────────────────────────────

    def install_system_deps(self, packages: List[str]) -> bool:
        """Install system packages via apt-get."""
        if not packages:
            return True
        cmd = ["apt-get", "install", "-y", "-q", "--no-install-recommends"] + packages
        result = subprocess.run(cmd, capture_output=True, text=True)
        if result.returncode == 0:
            self.logger.info(f"Installed system deps: {' '.join(packages)}")
            return True
        self.logger.error(result.stderr)
        return False

    def install_pip_deps(self, packages: List[str]) -> bool:
        """Install Python packages via pip3."""
        if not packages:
            return True
        result = subprocess.run(
            ["pip3", "install", "--quiet"] + packages,
            capture_output=True, text=True
        )
        if result.returncode == 0:
            self.logger.info(f"Installed pip deps: {' '.join(packages)}")
            return True
        self.logger.error(result.stderr)
        return False

    # ── Update automation ─────────────────────────────────────────────────────

    def check_updates(self) -> Dict[str, Any]:
        """
        Returns a dict of packages with available updates.
        Currently a stub — extend with a remote registry check.
        """
        installed = {p["name"]: p["version"] for p in self.list_installed()}
        locked    = self.list_locked()
        updatable = {}
        for name, version in installed.items():
            if name not in locked:
                # Placeholder: in production, compare against remote registry
                updatable[name] = {"current": version, "latest": "check-remote"}
        return updatable

    def update_all(self, dry_run: bool = False) -> List[str]:
        """Update all non-locked packages. Returns list of updated package names."""
        locked    = set(self.list_locked().keys())
        installed = self.list_installed()
        updated   = []
        for pkg in installed:
            name = pkg["name"]
            if name in locked:
                self.logger.info(f"Skipping locked: {name}")
                continue
            if dry_run:
                self.logger.info(f"[dry-run] Would update: {name}")
            else:
                # Re-install from same source if source_url available
                source_url = pkg.get("source", "")
                if source_url.startswith("http"):
                    if self.install(name, source_url=source_url):
                        updated.append(name)
        return updated
