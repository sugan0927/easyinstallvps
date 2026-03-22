#!/usr/bin/env python3
"""
easyinstall_plugin_manager.py — EasyInstall v7.0 Plugin Manager
================================================================
Core plugin infrastructure for loading, enabling, and managing
optional feature plugins. Designed as a pure ADD-ON — never
modifies any core EasyInstall files.

Plugin directory : /usr/local/lib/easyinstall_plugins/
Config directory : /etc/easyinstall/plugins/
Log file         : /var/log/easyinstall/plugins.log
"""

import os
import sys
import json
import logging
import importlib
import importlib.util
import inspect
from pathlib import Path
from typing import Dict, List, Optional, Any
from dataclasses import dataclass, field
from enum import Enum
from datetime import datetime


# ─────────────────────────────────────────────────────────────────────────────
# Setup logging
# ─────────────────────────────────────────────────────────────────────────────

LOG_FILE = Path("/var/log/easyinstall/plugins.log")

def _setup_root_logger():
    LOG_FILE.parent.mkdir(parents=True, exist_ok=True)
    fmt = logging.Formatter("[%(asctime)s] [%(levelname)s] %(name)s — %(message)s",
                            datefmt="%Y-%m-%d %H:%M:%S")
    root = logging.getLogger("easyinstall")
    root.setLevel(logging.DEBUG)
    if not root.handlers:
        sh = logging.StreamHandler()
        sh.setFormatter(fmt)
        root.addHandler(sh)
        try:
            fh = logging.FileHandler(LOG_FILE)
            fh.setFormatter(fmt)
            root.addHandler(fh)
        except PermissionError:
            pass
    return root

_logger = _setup_root_logger()


# ─────────────────────────────────────────────────────────────────────────────
# Data classes
# ─────────────────────────────────────────────────────────────────────────────

class PluginState(Enum):
    INSTALLED = "installed"
    ENABLED   = "enabled"
    DISABLED  = "disabled"
    BROKEN    = "broken"


@dataclass
class PluginMetadata:
    name:         str
    version:      str
    description:  str
    author:       str
    dependencies: List[str] = field(default_factory=list)
    conflicts:    List[str] = field(default_factory=list)
    requires:     List[str] = field(default_factory=list)   # system packages
    provides:     List[str] = field(default_factory=list)   # capabilities


# ─────────────────────────────────────────────────────────────────────────────
# Base plugin class
# ─────────────────────────────────────────────────────────────────────────────

class BasePlugin:
    """
    All EasyInstall plugins must inherit from this class and implement
    get_metadata() and initialize().
    """

    def __init__(self, config: Dict[str, Any]):
        self.config  = config
        self.enabled = False
        self.hooks:  Dict[str, Any] = {}
        self.logger  = logging.getLogger(f"easyinstall.{self.__class__.__name__}")

    # ── Abstract interface ────────────────────────────────────────────────────

    def get_metadata(self) -> PluginMetadata:
        """Return plugin metadata. Must be implemented by subclasses."""
        raise NotImplementedError

    def initialize(self) -> bool:
        """
        Validate prerequisites, create required directories / config files.
        Return True on success, False to abort enabling.
        """
        raise NotImplementedError

    # ── Lifecycle ─────────────────────────────────────────────────────────────

    def enable(self) -> bool:
        self.enabled = True
        self.logger.info("Plugin enabled")
        return True

    def disable(self) -> bool:
        self.enabled = False
        self.logger.info("Plugin disabled")
        return True

    def teardown(self):
        """Called when plugin is being uninstalled. Override to clean up."""
        pass

    # ── Hook system ───────────────────────────────────────────────────────────

    def register_hook(self, hook_name: str, callback):
        """Register a callback for a named event hook."""
        self.hooks[hook_name] = callback
        self.logger.debug(f"Registered hook: {hook_name}")

    def execute_hook(self, hook_name: str, *args, **kwargs):
        """Execute a registered hook if present."""
        cb = self.hooks.get(hook_name)
        if cb:
            try:
                return cb(*args, **kwargs)
            except Exception as exc:
                self.logger.error(f"Hook '{hook_name}' raised: {exc}")
        return None

    # ── Utility helpers ───────────────────────────────────────────────────────

    def run(self, cmd: str, check: bool = True) -> int:
        """Run a shell command. Returns return-code."""
        import subprocess
        result = subprocess.run(cmd, shell=True, capture_output=True, text=True)
        if result.returncode != 0 and check:
            self.logger.warning(f"Command failed [{result.returncode}]: {cmd}\n{result.stderr.strip()}")
        return result.returncode

    def require_binary(self, name: str) -> bool:
        """Check that an external binary is available on PATH."""
        import shutil
        found = shutil.which(name) is not None
        if not found:
            self.logger.warning(f"Required binary not found: {name}")
        return found


# ─────────────────────────────────────────────────────────────────────────────
# Plugin Manager
# ─────────────────────────────────────────────────────────────────────────────

class PluginManager:
    """
    Discovers, loads, and manages all EasyInstall plugins.

    Usage::

        pm = PluginManager()
        pm.enable_plugin("cloudflare_worker")
        pm.execute_hook("site_created", domain="example.com")
    """

    PLUGINS_DIR = Path("/usr/local/lib/easyinstall_plugins")
    CONFIG_DIR  = Path("/etc/easyinstall/plugins")

    def __init__(self,
                 plugins_dir: Optional[str] = None,
                 config_dir:  Optional[str] = None):
        self.plugins_dir = Path(plugins_dir) if plugins_dir else self.PLUGINS_DIR
        self.config_dir  = Path(config_dir)  if config_dir  else self.CONFIG_DIR
        self.plugins:    Dict[str, BasePlugin] = {}
        self.logger      = logging.getLogger("easyinstall.PluginManager")

        self.config_dir.mkdir(parents=True, exist_ok=True)
        self._load_plugins()

    # ── Discovery ─────────────────────────────────────────────────────────────

    def _load_plugins(self):
        if not self.plugins_dir.exists():
            self.logger.warning(f"Plugins directory not found: {self.plugins_dir}")
            return

        for py_file in sorted(self.plugins_dir.glob("*.py")):
            if py_file.name.startswith("_"):
                continue
            self._load_plugin_file(py_file)

    def _load_plugin_file(self, py_file: Path):
        module_name = py_file.stem
        try:
            spec   = importlib.util.spec_from_file_location(module_name, py_file)
            module = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(module)

            for _, obj in inspect.getmembers(module, inspect.isclass):
                if issubclass(obj, BasePlugin) and obj is not BasePlugin:
                    config = self._get_plugin_config(module_name)
                    plugin = obj(config)
                    self.plugins[module_name] = plugin
                    self.logger.info(f"Loaded plugin: {module_name}")
                    return
        except Exception as exc:
            self.logger.error(f"Failed to load plugin '{py_file.name}': {exc}")

    # ── Config ────────────────────────────────────────────────────────────────

    def _get_plugin_config(self, plugin_name: str) -> Dict:
        cfg_file = self.config_dir / f"{plugin_name}.json"
        if cfg_file.exists():
            try:
                with open(cfg_file) as f:
                    return json.load(f)
            except json.JSONDecodeError:
                pass
        return {}

    def _save_plugin_state(self, plugin_name: str, state: str):
        state_file = self.config_dir / f"{plugin_name}.state"
        state_file.write_text(state)

    # ── Public API ────────────────────────────────────────────────────────────

    def enable_plugin(self, plugin_name: str) -> bool:
        plugin = self.plugins.get(plugin_name)
        if plugin is None:
            self.logger.error(f"Plugin not found: {plugin_name}")
            return False
        try:
            if plugin.initialize():
                plugin.enable()
                self._save_plugin_state(plugin_name, PluginState.ENABLED.value)
                self.logger.info(f"Plugin enabled: {plugin_name}")
                return True
            self.logger.error(f"Plugin initialization failed: {plugin_name}")
        except Exception as exc:
            self.logger.error(f"Exception enabling '{plugin_name}': {exc}")
            self._save_plugin_state(plugin_name, PluginState.BROKEN.value)
        return False

    def disable_plugin(self, plugin_name: str) -> bool:
        plugin = self.plugins.get(plugin_name)
        if plugin is None:
            return False
        plugin.disable()
        self._save_plugin_state(plugin_name, PluginState.DISABLED.value)
        self.logger.info(f"Plugin disabled: {plugin_name}")
        return True

    def get_plugin_state(self, plugin_name: str) -> PluginState:
        state_file = self.config_dir / f"{plugin_name}.state"
        if state_file.exists():
            try:
                return PluginState(state_file.read_text().strip())
            except ValueError:
                pass
        return PluginState.INSTALLED

    def execute_hook(self, hook_name: str, *args, **kwargs) -> List:
        """Broadcast a hook to all enabled plugins and collect results."""
        results = []
        for name, plugin in self.plugins.items():
            if plugin.enabled:
                result = plugin.execute_hook(hook_name, *args, **kwargs)
                if result is not None:
                    results.append((name, result))
        return results

    def list_plugins(self) -> List[Dict]:
        out = []
        for name, plugin in self.plugins.items():
            try:
                meta = plugin.get_metadata()
            except Exception:
                meta = PluginMetadata(name=name, version="?", description="(error)", author="?")
            out.append({
                "name":        meta.name,
                "module":      name,
                "version":     meta.version,
                "description": meta.description,
                "author":      meta.author,
                "state":       self.get_plugin_state(name).value,
            })
        return out


# ─────────────────────────────────────────────────────────────────────────────
# CLI entry-point (used by easyinstall-plugin bash command)
# ─────────────────────────────────────────────────────────────────────────────

def main():
    import argparse
    ap = argparse.ArgumentParser(description="EasyInstall Plugin Manager")
    sub = ap.add_subparsers(dest="cmd")

    sub.add_parser("list",    help="List all plugins")
    en = sub.add_parser("enable",  help="Enable a plugin")
    en.add_argument("plugin")
    di = sub.add_parser("disable", help="Disable a plugin")
    di.add_argument("plugin")
    st = sub.add_parser("status",  help="Show plugin status")
    st.add_argument("plugin", nargs="?")
    inf = sub.add_parser("info",   help="Show plugin details")
    inf.add_argument("plugin")

    args = ap.parse_args()
    pm   = PluginManager()

    if args.cmd == "list":
        for p in pm.list_plugins():
            icon = {"enabled": "✅", "disabled": "⭕", "broken": "❌"}.get(p["state"], "📦")
            print(f"  {icon}  {p['module']:30s} v{p['version']:8s}  {p['description']}")

    elif args.cmd == "enable":
        ok = pm.enable_plugin(args.plugin)
        sys.exit(0 if ok else 1)

    elif args.cmd == "disable":
        ok = pm.disable_plugin(args.plugin)
        sys.exit(0 if ok else 1)

    elif args.cmd == "status":
        if args.plugin:
            state = pm.get_plugin_state(args.plugin)
            p = pm.plugins.get(args.plugin)
            if p:
                meta = p.get_metadata()
                print(f"Plugin : {meta.name}")
                print(f"Version: {meta.version}")
                print(f"Author : {meta.author}")
                print(f"State  : {state.value}")
                print(f"Deps   : {', '.join(meta.dependencies) or 'None'}")
            else:
                print(f"Plugin not found: {args.plugin}")
                sys.exit(1)
        else:
            for p in pm.list_plugins():
                print(f"  {p['module']:30s}  {p['state']}")

    elif args.cmd == "info":
        p = pm.plugins.get(args.plugin)
        if p:
            meta = p.get_metadata()
            print(f"Name        : {meta.name}")
            print(f"Version     : {meta.version}")
            print(f"Author      : {meta.author}")
            print(f"Description : {meta.description}")
            print(f"Dependencies: {', '.join(meta.dependencies) or 'None'}")
            print(f"Conflicts   : {', '.join(meta.conflicts) or 'None'}")
            print(f"Requires    : {', '.join(meta.requires) or 'None'}")
            print(f"Provides    : {', '.join(meta.provides) or 'None'}")
        else:
            print(f"Plugin not found: {args.plugin}")
            sys.exit(1)
    else:
        ap.print_help()


if __name__ == "__main__":
    main()
