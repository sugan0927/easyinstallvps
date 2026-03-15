// src/index.js - EasyInstallVPS Cloudflare Worker
export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);
    
    // Handle /install.sh path to return the bash script
    if (url.pathname === '/install.sh') {
      const installScript = `#!/bin/bash
# EasyInstall VPS Master Script
# (Your complete install.sh content goes here)
# For the full script, refer to our conversation history.
set -e
echo "🚀 EasyInstall VPS Installer"
# ... (rest of your install.sh code)
`;
      return new Response(installScript, {
        headers: { 'Content-Type': 'text/plain;charset=UTF-8' },
      });
    }

    // Default: Serve main HTML page
    const html = `<!DOCTYPE html>
<html>
<head>
    <title>EasyInstallVPS</title>
    <meta charset="UTF-8">
    <style>
        body { font-family: sans-serif; text-align: center; padding: 50px; }
        h1 { color: #333; }
    </style>
</head>
<body>
    <h1>🚀 EasyInstallVPS</h1>
    <p>Your Cloudflare Worker is live and ready!</p>
    <p><a href="/install.sh">Click here to download install.sh</a></p>
</body>
</html>`;
    
    return new Response(html, {
      headers: { 'Content-Type': 'text/html;charset=UTF-8' },
    });
  },
};
