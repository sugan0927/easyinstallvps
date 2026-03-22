#!/usr/bin/env python3
"""
edge_script.py — EasyInstall Edge Script Plugin v1.0
=====================================================
Generates Cloudflare Worker edge function templates:
  - Cache strategies (HTML, static assets, API)
  - WebSocket proxy handler
  - Geo-routing rules
  - Security headers middleware
  - A/B test router
"""

from pathlib import Path
from typing import Dict, List, Optional

try:
    from easyinstall_plugin_manager import BasePlugin, PluginMetadata
except ImportError:
    import sys; sys.path.insert(0, "/usr/local/lib")
    from easyinstall_plugin_manager import BasePlugin, PluginMetadata


# ─────────────────────────────────────────────────────────────────────────────
# Edge function templates
# ─────────────────────────────────────────────────────────────────────────────

SECURITY_HEADERS_WORKER = """\
/**
 * Edge Security Headers Worker
 * Injects security headers on every response at the Cloudflare edge.
 */
const SECURITY_HEADERS = {
  'Strict-Transport-Security':  'max-age=63072000; includeSubDomains; preload',
  'X-Content-Type-Options':     'nosniff',
  'X-Frame-Options':            'SAMEORIGIN',
  'X-XSS-Protection':           '1; mode=block',
  'Referrer-Policy':            'strict-origin-when-cross-origin',
  'Permissions-Policy':         'geolocation=(), microphone=(), camera=()',
  'Content-Security-Policy':    "default-src 'self'; script-src 'self' 'unsafe-inline' https://cdnjs.cloudflare.com; style-src 'self' 'unsafe-inline'; img-src 'self' data: https:; font-src 'self' https://fonts.gstatic.com",
};

export default {
  async fetch(request, env, ctx) {
    const response = await fetch(request);
    const newResponse = new Response(response.body, response);
    for (const [k, v] of Object.entries(SECURITY_HEADERS)) {
      newResponse.headers.set(k, v);
    }
    // Remove headers that leak server info
    newResponse.headers.delete('X-Powered-By');
    newResponse.headers.delete('Server');
    return newResponse;
  },
};
"""

WEBSOCKET_HANDLER_WORKER = """\
/**
 * Edge WebSocket Proxy Worker
 * Forwards WebSocket connections to the origin; adds auth check.
 */
export default {
  async fetch(request, env, ctx) {
    const upgradeHeader = request.headers.get('Upgrade');
    if (upgradeHeader && upgradeHeader.toLowerCase() === 'websocket') {
      return handleWebSocket(request, env);
    }
    return fetch(request);
  },
};

async function handleWebSocket(request, env) {
  const [client, server] = new WebSocketPair();
  const url = new URL(request.url);

  // Optional: validate token before proxying
  const token = url.searchParams.get('token');
  if (env.WS_SECRET && token !== env.WS_SECRET) {
    return new Response('Unauthorized', { status: 401 });
  }

  const originUrl = `wss://${url.hostname}${url.pathname}${url.search}`;
  const originWS  = new WebSocket(originUrl);

  originWS.addEventListener('message', e => server.send(e.data));
  originWS.addEventListener('close',   e => server.close(e.code, e.reason));
  server.accept();
  server.addEventListener('message', e => originWS.send(e.data));
  server.addEventListener('close',   e => originWS.close(e.code, e.reason));

  return new Response(null, { status: 101, webSocket: client });
}
"""

GEO_ROUTING_WORKER = """\
/**
 * Edge Geo-Routing Worker
 * Redirect or serve different content based on visitor country.
 */
const GEO_RULES = {
  // countryCode: { redirect | origin }
  'CN': { action: 'redirect', target: 'https://{domain}/cn/' },
  'DE': { action: 'redirect', target: 'https://{domain}/de/' },
  'FR': { action: 'redirect', target: 'https://{domain}/fr/' },
};

export default {
  async fetch(request, env, ctx) {
    const country = request.cf?.country ?? 'XX';
    const rule    = GEO_RULES[country];

    if (rule) {
      if (rule.action === 'redirect') {
        return Response.redirect(rule.target, 302);
      }
      // Custom origin
      const url = new URL(request.url);
      url.hostname = rule.origin;
      return fetch(new Request(url.toString(), request));
    }

    return fetch(request);
  },
};
"""

AB_TEST_WORKER = """\
/**
 * Edge A/B Test Worker
 * Splits traffic 50/50 between two origin variants using a cookie.
 */
const VARIANT_COOKIE = 'ab_variant';

export default {
  async fetch(request, env, ctx) {
    const url     = new URL(request.url);
    const cookies = request.headers.get('Cookie') ?? '';
    let variant   = cookies.match(new RegExp(`${VARIANT_COOKIE}=([^;]+)`))?.[1];

    if (!variant) {
      variant = Math.random() < 0.5 ? 'a' : 'b';
    }

    // Route to different origin paths
    if (variant === 'b') {
      url.pathname = '/variant-b' + url.pathname;
    }

    const originResp = await fetch(new Request(url.toString(), request));
    const response   = new Response(originResp.body, originResp);
    response.headers.append('Set-Cookie',
      `${VARIANT_COOKIE}=${variant}; Max-Age=86400; Path=/; SameSite=Lax`);
    response.headers.set('X-AB-Variant', variant);
    return response;
  },
};
"""

CACHE_STRATEGY_WORKER = """\
/**
 * Edge Multi-Strategy Cache Worker
 * Implements stale-while-revalidate for HTML, immutable for static assets,
 * and pass-through for API / admin paths.
 */
const BYPASS   = ['/wp-admin', '/wp-login.php', '/wp-json', '/wc-api'];
const STATIC   = /\\.(css|js|png|jpg|jpeg|gif|ico|svg|woff2?)(\\?.*)?$/i;
const HTML_TTL = 300;    // 5 min edge TTL for HTML
const STAT_TTL = 86400;  // 24 h for static

export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);

    if (BYPASS.some(p => url.pathname.startsWith(p)) ||
        request.method !== 'GET' ||
        request.headers.get('Cookie')?.includes('wordpress_logged_in')) {
      return fetch(request);
    }

    const cache = caches.default;
    const cacheKey = new Request(url.toString(), { headers: { 'Accept': request.headers.get('Accept') ?? '*/*' } });

    let cached = await cache.match(cacheKey);
    if (cached) {
      const age = parseInt(cached.headers.get('Age') ?? '0');
      if (age < (STATIC.test(url.pathname) ? STAT_TTL : HTML_TTL)) {
        return cached;
      }
      // Stale — revalidate in background
      ctx.waitUntil(
        fetch(request).then(r => r.status === 200 && cache.put(cacheKey, r.clone()))
      );
      return cached;
    }

    const response = await fetch(request);
    if (response.status === 200) {
      const toCache = new Response(response.clone().body, response);
      const ttl     = STATIC.test(url.pathname) ? STAT_TTL : HTML_TTL;
      toCache.headers.set('Cache-Control', `public, max-age=${ttl}`);
      ctx.waitUntil(cache.put(cacheKey, toCache));
    }
    return response;
  },
};
"""


class EdgeScriptPlugin(BasePlugin):

    TEMPLATES = {
        "security-headers": SECURITY_HEADERS_WORKER,
        "websocket":         WEBSOCKET_HANDLER_WORKER,
        "geo-routing":       GEO_ROUTING_WORKER,
        "ab-test":           AB_TEST_WORKER,
        "cache-strategy":    CACHE_STRATEGY_WORKER,
    }

    def get_metadata(self) -> PluginMetadata:
        return PluginMetadata(
            name        = "edge-script",
            version     = "1.0.0",
            description = "Cloudflare Worker edge function templates: cache, WebSocket, geo-routing, A/B",
            author      = "EasyInstall",
            requires    = [],
            provides    = ["edge-functions", "cache-strategy", "websocket-proxy", "geo-routing"],
        )

    def initialize(self) -> bool:
        return True

    def available_templates(self) -> List[str]:
        return list(self.TEMPLATES.keys())

    def generate(self, template_name: str, domain: str = "",
                  output_dir: str = "/tmp") -> Optional[str]:
        """
        Write a worker script from the named template.
        Returns the file path, or None if the template is unknown.
        """
        if template_name not in self.TEMPLATES:
            self.logger.error(f"Unknown template: {template_name}. "
                              f"Available: {self.available_templates()}")
            return None

        content = self.TEMPLATES[template_name]
        if domain:
            content = content.replace("{domain}", domain)

        out  = Path(output_dir)
        out.mkdir(parents=True, exist_ok=True)
        path = out / f"worker-{template_name}.js"
        path.write_text(content)
        self.logger.info(f"Edge script written: {path}")
        return str(path)

    def generate_all(self, domain: str = "", output_dir: str = "/tmp") -> Dict[str, str]:
        """Generate all templates and return {name: path} mapping."""
        result = {}
        for name in self.TEMPLATES:
            p = self.generate(name, domain=domain, output_dir=output_dir)
            if p:
                result[name] = p
        return result

    def combine(self, templates: List[str], domain: str = "",
                 output_path: str = "/tmp/combined-worker.js") -> str:
        """
        Combine multiple templates into a single worker using a router pattern.
        Returns the output file path.
        """
        parts = []
        for name in templates:
            tpl = self.TEMPLATES.get(name, "")
            if tpl:
                parts.append(f"// ── {name} ──────────────────────────────")
                # Strip the default export; we'll add a combined one
                stripped = "\n".join(
                    l for l in tpl.splitlines()
                    if not l.startswith("export default")
                )
                parts.append(stripped)

        router = """\

// ── Combined Router ──────────────────────────────────────────
export default {
  async fetch(request, env, ctx) {
    // Chain middleware: security headers → cache strategy → origin
    const url = new URL(request.url);
    let response = await fetch(request);
    // Add security headers
    const secureResp = new Response(response.body, response);
    for (const [k, v] of Object.entries(SECURITY_HEADERS)) {
      secureResp.headers.set(k, v);
    }
    return secureResp;
  },
};
"""
        combined = "\n\n".join(parts) + router
        Path(output_path).write_text(combined)
        self.logger.info(f"Combined worker written: {output_path}")
        return output_path
