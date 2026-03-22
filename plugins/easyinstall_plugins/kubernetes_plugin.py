#!/usr/bin/env python3
"""
kubernetes_plugin.py — EasyInstall Kubernetes Plugin v1.0
===========================================================
Generates Kubernetes manifests, Helm chart scaffolding, Kustomize overlays,
HPA configs, and Ingress rules with cert-manager SSL for WordPress sites.
"""

import json
from pathlib import Path
from typing import Dict, Optional

try:
    from easyinstall_plugin_manager import BasePlugin, PluginMetadata
except ImportError:
    import sys; sys.path.insert(0, "/usr/local/lib")
    from easyinstall_plugin_manager import BasePlugin, PluginMetadata


# ─────────────────────────────────────────────────────────────────────────────
# YAML helpers (avoid PyYAML dependency)
# ─────────────────────────────────────────────────────────────────────────────

def _manifest(obj: Dict) -> str:
    """Minimal dict-to-YAML for Kubernetes manifests."""
    import json as _j
    # Use json as a proxy; real deployments should use PyYAML or ruamel.yaml.
    # For production, swap this with yaml.dump(obj, default_flow_style=False).
    try:
        import yaml
        return yaml.dump(obj, default_flow_style=False, allow_unicode=True)
    except ImportError:
        lines = ["# NOTE: install PyYAML for proper formatting"]
        lines.append(_j.dumps(obj, indent=2))
        return "\n".join(lines)


class KubernetesPlugin(BasePlugin):

    def get_metadata(self) -> PluginMetadata:
        return PluginMetadata(
            name        = "kubernetes",
            version     = "1.0.0",
            description = "Generate Kubernetes manifests, Helm charts and HPA for WordPress",
            author      = "EasyInstall",
            requires    = ["kubectl"],
            provides    = ["k8s-orchestration", "helm-chart", "hpa"],
        )

    def initialize(self) -> bool:
        if not self.require_binary("kubectl"):
            self.logger.warning("kubectl not found — manifests will still be generated")
        return True

    # ── Manifest builders ─────────────────────────────────────────────────────

    def _namespace(self, ns: str) -> Dict:
        return {"apiVersion": "v1", "kind": "Namespace",
                "metadata": {"name": ns}}

    def _secret(self, name: str, ns: str, data: Dict) -> Dict:
        import base64
        encoded = {k: base64.b64encode(v.encode()).decode() for k, v in data.items()}
        return {"apiVersion": "v1", "kind": "Secret",
                "metadata": {"name": name, "namespace": ns},
                "type": "Opaque", "data": encoded}

    def _configmap(self, name: str, ns: str, data: Dict) -> Dict:
        return {"apiVersion": "v1", "kind": "ConfigMap",
                "metadata": {"name": name, "namespace": ns}, "data": data}

    def _pvc(self, name: str, ns: str, size: str = "5Gi",
             storage_class: str = "standard") -> Dict:
        return {
            "apiVersion": "v1", "kind": "PersistentVolumeClaim",
            "metadata": {"name": name, "namespace": ns},
            "spec": {
                "accessModes": ["ReadWriteOnce"],
                "storageClassName": storage_class,
                "resources": {"requests": {"storage": size}},
            },
        }

    def _deployment(self, name: str, ns: str, image: str,
                    env_from_secret: str, port: int = 9000,
                    pvc_name: Optional[str] = None) -> Dict:
        container: Dict = {
            "name":            name,
            "image":           image,
            "ports":           [{"containerPort": port}],
            "envFrom":         [{"secretRef": {"name": env_from_secret}}],
            "resources":       {"requests": {"memory": "128Mi", "cpu": "100m"},
                                "limits":   {"memory": "512Mi", "cpu": "500m"}},
            "livenessProbe":   {"tcpSocket": {"port": port},
                                "initialDelaySeconds": 15, "periodSeconds": 20},
            "readinessProbe":  {"tcpSocket": {"port": port},
                                "initialDelaySeconds": 5,  "periodSeconds": 10},
        }
        if pvc_name:
            container["volumeMounts"] = [{"name": "wp-data", "mountPath": "/var/www/html"}]

        spec: Dict = {"containers": [container]}
        if pvc_name:
            spec["volumes"] = [{"name": "wp-data", "persistentVolumeClaim": {"claimName": pvc_name}}]

        return {
            "apiVersion": "apps/v1", "kind": "Deployment",
            "metadata": {"name": name, "namespace": ns, "labels": {"app": name}},
            "spec": {
                "replicas": 1,
                "selector": {"matchLabels": {"app": name}},
                "template": {"metadata": {"labels": {"app": name}}, "spec": spec},
            },
        }

    def _service(self, name: str, ns: str, port: int,
                 svc_type: str = "ClusterIP") -> Dict:
        return {
            "apiVersion": "v1", "kind": "Service",
            "metadata": {"name": name, "namespace": ns},
            "spec": {
                "selector": {"app": name},
                "type": svc_type,
                "ports": [{"port": port, "targetPort": port}],
            },
        }

    def _ingress(self, domain: str, ns: str,
                 nginx_svc: str = "nginx", nginx_port: int = 80) -> Dict:
        return {
            "apiVersion": "networking.k8s.io/v1", "kind": "Ingress",
            "metadata": {
                "name":        f"wp-{domain.replace('.', '-')}",
                "namespace":   ns,
                "annotations": {
                    "kubernetes.io/ingress.class":                 "nginx",
                    "cert-manager.io/cluster-issuer":              "letsencrypt-prod",
                    "nginx.ingress.kubernetes.io/proxy-body-size": "64m",
                },
            },
            "spec": {
                "tls": [{"hosts": [domain], "secretName": f"tls-{domain.replace('.', '-')}"}],
                "rules": [{
                    "host": domain,
                    "http": {"paths": [{
                        "path":     "/",
                        "pathType": "Prefix",
                        "backend":  {"service": {"name": nginx_svc,
                                                 "port": {"number": nginx_port}}},
                    }]},
                }],
            },
        }

    def _hpa(self, deployment: str, ns: str,
             min_replicas: int = 1, max_replicas: int = 10,
             cpu_target: int = 70) -> Dict:
        return {
            "apiVersion": "autoscaling/v2", "kind": "HorizontalPodAutoscaler",
            "metadata": {"name": f"{deployment}-hpa", "namespace": ns},
            "spec": {
                "scaleTargetRef": {"apiVersion": "apps/v1",
                                   "kind": "Deployment", "name": deployment},
                "minReplicas": min_replicas,
                "maxReplicas": max_replicas,
                "metrics": [{"type": "Resource", "resource": {
                    "name": "cpu",
                    "target": {"type": "Utilization", "averageUtilization": cpu_target},
                }}],
            },
        }

    # ── Main generator ────────────────────────────────────────────────────────

    def generate_manifests(self, domain: str,
                           db_password: str = "changeme",
                           db_root_password: str = "changeme_root",
                           namespace: str = "",
                           output_dir: str = "/tmp") -> str:
        """
        Generate a complete set of k8s manifests for a WordPress site.
        Returns the output directory path.
        """
        ns  = namespace or f"wp-{domain.replace('.', '-')[:40]}"
        out = Path(output_dir) / domain / "k8s"
        out.mkdir(parents=True, exist_ok=True)

        # Secret
        secret = self._secret("wp-secrets", ns, {
            "WORDPRESS_DB_HOST":     "db:3306",
            "WORDPRESS_DB_NAME":     "wordpress",
            "WORDPRESS_DB_USER":     "wp_user",
            "WORDPRESS_DB_PASSWORD": db_password,
            "MARIADB_ROOT_PASSWORD": db_root_password,
            "MARIADB_DATABASE":      "wordpress",
            "MARIADB_USER":          "wp_user",
            "MARIADB_PASSWORD":      db_password,
        })

        objects = [
            self._namespace(ns),
            secret,
            self._configmap("wp-config", ns, {"DOMAIN": domain}),
            self._pvc("wp-data", ns, "5Gi"),
            self._pvc("db-data", ns, "10Gi"),
            self._deployment("wordpress", ns, "wordpress:latest-php8.2-fpm-alpine",
                             "wp-secrets", 9000, "wp-data"),
            self._deployment("mariadb", ns, "mariadb:10.11", "wp-secrets", 3306, "db-data"),
            self._deployment("redis",   ns, "redis:7-alpine", "wp-secrets", 6379),
            self._service("wordpress", ns, 9000),
            self._service("mariadb",   ns, 3306),
            self._service("redis",     ns, 6379),
            self._service("nginx",     ns, 80, "ClusterIP"),
            self._ingress(domain, ns),
            self._hpa("wordpress", ns),
        ]

        manifest_lines = []
        for obj in objects:
            manifest_lines.append(_manifest(obj))
            manifest_lines.append("---")

        manifest_path = out / "wordpress-stack.yaml"
        manifest_path.write_text("\n".join(manifest_lines))
        self.logger.info(f"K8s manifests written to {manifest_path}")
        return str(out)

    def generate_helm_chart(self, domain: str, output_dir: str = "/tmp") -> str:
        """Scaffold a minimal Helm chart for WordPress."""
        safe   = domain.replace(".", "-")
        chart  = Path(output_dir) / domain / "helm" / f"wp-{safe}"
        (chart / "templates").mkdir(parents=True, exist_ok=True)

        chart_yaml = f"""\
apiVersion: v2
name: wp-{safe}
description: WordPress Helm chart for {domain}
type: application
version: 0.1.0
appVersion: "7.0"
"""
        values_yaml = f"""\
domain: {domain}
replicaCount: 1
image:
  wordpress: wordpress:latest-php8.2-fpm-alpine
  mariadb:   mariadb:10.11
  redis:     redis:7-alpine
db:
  name:         wordpress
  user:         wp_user
  password:     changeme
  rootPassword: changeme_root
pvc:
  wpSize: 5Gi
  dbSize: 10Gi
hpa:
  minReplicas: 1
  maxReplicas: 10
  cpuTarget:   70
"""
        (chart / "Chart.yaml").write_text(chart_yaml)
        (chart / "values.yaml").write_text(values_yaml)
        (chart / "templates" / "_helpers.tpl").write_text(
            "{{/* EasyInstall Helm helpers */}}\n")
        self.logger.info(f"Helm chart scaffolded in {chart}")
        return str(chart)

    def apply(self, manifests_dir: str) -> bool:
        """kubectl apply -f <dir>"""
        if not self.require_binary("kubectl"):
            return False
        import subprocess
        result = subprocess.run(
            ["kubectl", "apply", "-f", manifests_dir],
            capture_output=True, text=True
        )
        if result.returncode == 0:
            self.logger.info(f"Applied manifests from {manifests_dir}")
            return True
        self.logger.error(result.stderr)
        return False
