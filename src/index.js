// src/index.js - Simple GitHub Pages style
export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);
    
    // Handle different paths
    const files = {
      '/': 'index.html',
      '/easyinstall_wp.php': 'easyinstall_wp.php',
      '/easyinstall_core.py': 'easyinstall_core.py',
      '/easyinstall.sh': 'easyinstall.sh',
      '/wp': 'easyinstall_wp.php',
      '/python': 'easyinstall_core.py',
      '/shell': 'easyinstall.sh',
      '/install': 'easyinstall.sh'
    };

    // Get requested file
    const file = files[url.pathname] || files['/'];
    
    if (file === 'index.html') {
      // Serve main page
      return serveMainPage();
    } else {
      // Redirect to raw GitHub content
      const rawUrl = `https://raw.githubusercontent.com/sugan0927/easyinstallvps/main/${file}`;
      return Response.redirect(rawUrl, 302);
    }
  }
};

function serveMainPage() {
  const html = `<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>EasyInstallVPS - One Click VPS Installation</title>
    <style>
        * {
            margin: 0;
            padding: 0;
            box-sizing: border-box;
        }
        
        body {
            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Oxygen, Ubuntu, sans-serif;
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            min-height: 100vh;
            display: flex;
            align-items: center;
            justify-content: center;
            padding: 20px;
        }
        
        .container {
            background: white;
            border-radius: 20px;
            padding: 40px;
            max-width: 1000px;
            width: 100%;
            box-shadow: 0 20px 60px rgba(0,0,0,0.3);
        }
        
        .header {
            text-align: center;
            margin-bottom: 40px;
        }
        
        h1 {
            font-size: 48px;
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            -webkit-background-clip: text;
            -webkit-text-fill-color: transparent;
            margin-bottom: 10px;
        }
        
        .subtitle {
            color: #666;
            font-size: 18px;
        }
        
        .stats {
            display: flex;
            justify-content: center;
            gap: 40px;
            margin: 30px 0;
            padding: 20px;
            background: #f8f9fa;
            border-radius: 10px;
        }
        
        .stat-item {
            text-align: center;
        }
        
        .stat-value {
            font-size: 32px;
            font-weight: bold;
            color: #667eea;
        }
        
        .stat-label {
            color: #666;
            font-size: 14px;
            margin-top: 5px;
        }
        
        .files-grid {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(250px, 1fr));
            gap: 20px;
            margin: 30px 0;
        }
        
        .file-card {
            background: #f8f9fa;
            border-radius: 10px;
            padding: 20px;
            transition: transform 0.3s ease;
            border: 1px solid #e0e0e0;
        }
        
        .file-card:hover {
            transform: translateY(-5px);
            box-shadow: 0 10px 30px rgba(102, 126, 234, 0.2);
        }
        
        .file-icon {
            font-size: 40px;
            margin-bottom: 15px;
        }
        
        .file-name {
            font-size: 18px;
            font-weight: bold;
            margin-bottom: 10px;
            color: #333;
        }
        
        .file-desc {
            color: #666;
            font-size: 14px;
            margin-bottom: 20px;
        }
        
        .file-link {
            display: inline-block;
            padding: 8px 16px;
            background: #667eea;
            color: white;
            text-decoration: none;
            border-radius: 5px;
            font-size: 14px;
            transition: background 0.3s ease;
        }
        
        .file-link:hover {
            background: #764ba2;
        }
        
        .install-section {
            background: #1e1e2f;
            color: white;
            padding: 30px;
            border-radius: 10px;
            margin: 30px 0;
        }
        
        .install-title {
            font-size: 20px;
            margin-bottom: 20px;
        }
        
        .install-command {
            background: #2d2d44;
            padding: 15px;
            border-radius: 5px;
            font-family: 'Courier New', monospace;
            margin: 10px 0;
            overflow-x: auto;
        }
        
        .copy-btn {
            background: #4CAF50;
            color: white;
            border: none;
            padding: 8px 16px;
            border-radius: 5px;
            cursor: pointer;
            font-size: 14px;
            margin-top: 10px;
        }
        
        .copy-btn:hover {
            background: #45a049;
        }
        
        .footer {
            text-align: center;
            margin-top: 40px;
            padding-top: 20px;
            border-top: 1px solid #e0e0e0;
            color: #999;
        }
        
        .github-link {
            display: inline-flex;
            align-items: center;
            gap: 10px;
            padding: 12px 24px;
            background: #333;
            color: white;
            text-decoration: none;
            border-radius: 5px;
            margin: 20px 0;
        }
        
        .github-link:hover {
            background: #444;
        }
        
        .badge {
            display: inline-block;
            padding: 4px 8px;
            background: #28a745;
            color: white;
            border-radius: 4px;
            font-size: 12px;
            margin-left: 10px;
        }
        
        @media (max-width: 768px) {
            .container {
                padding: 20px;
            }
            
            h1 {
                font-size: 32px;
            }
            
            .stats {
                flex-direction: column;
                gap: 20px;
            }
        }
    </style>
</head>
<body>
    <div class="container">
        <div class="header">
            <h1>🚀 EasyInstallVPS</h1>
            <div class="subtitle">One-Click VPS Installation Scripts</div>
        </div>
        
        <div class="stats">
            <div class="stat-item">
                <div class="stat-value">3</div>
                <div class="stat-label">Installation Scripts</div>
            </div>
            <div class="stat-item">
                <div class="stat-value">PHP/Python</div>
                <div class="stat-label">Multi-Language</div>
            </div>
            <div class="stat-item">
                <div class="stat-value">One-Click</div>
                <div class="stat-label">Deployment</div>
            </div>
        </div>
        
        <a href="https://github.com/sugan0927/easyinstallvps" class="github-link" target="_blank">
            <svg height="20" width="20" viewBox="0 0 16 16" fill="currentColor">
                <path d="M8 0C3.58 0 0 3.58 0 8c0 3.54 2.29 6.53 5.47 7.59.4.07.55-.17.55-.38 0-.19-.01-.82-.01-1.49-2.01.37-2.53-.49-2.69-.94-.09-.23-.48-.94-.82-1.13-.28-.15-.68-.52-.01-.53.63-.01 1.08.58 1.23.82.72 1.21 1.87.87 2.33.66.07-.52.28-.87.51-1.07-1.78-.2-3.64-.89-3.64-3.95 0-.87.31-1.59.82-2.15-.08-.2-.36-1.02.08-2.12 0 0 .67-.21 2.2.82.64-.18 1.32-.27 2-.27.68 0 1.36.09 2 .27 1.53-1.04 2.2-.82 2.2-.82.44 1.1.16 1.92.08 2.12.51.56.82 1.27.82 2.15 0 3.07-1.87 3.75-3.65 3.95.29.25.54.73.54 1.48 0 1.07-.01 1.93-.01 2.2 0 .21.15.46.55.38A8.013 8.013 0 0016 8c0-4.42-3.58-8-8-8z"></path>
            </svg>
            View on GitHub
        </a>
        
        <h2 style="margin: 30px 0 20px 0;">📁 Available Scripts</h2>
        
        <div class="files-grid">
            <div class="file-card">
                <div class="file-icon">🐘</div>
                <div class="file-name">easyinstall_wp.php</div>
                <div class="file-desc">WordPress installation script with LEMP stack</div>
                <a href="/wp" class="file-link">View Script</a>
                <span class="badge">PHP</span>
            </div>
            
            <div class="file-card">
                <div class="file-icon">🐍</div>
                <div class="file-name">easyinstall_core.py</div>
                <div class="file-desc">Python core module for VPS automation</div>
                <a href="/python" class="file-link">View Script</a>
                <span class="badge">Python</span>
            </div>
            
            <div class="file-card">
                <div class="file-icon">📜</div>
                <div class="file-name">easyinstall.sh</div>
                <div class="file-desc">Main shell script for one-click installation</div>
                <a href="/shell" class="file-link">View Script</a>
                <span class="badge">Bash</span>
            </div>
        </div>
        
        <div class="install-section">
            <div class="install-title">⚡ Quick Install Commands</div>
            
            <div style="margin: 20px 0;">
                <div style="margin-bottom: 10px;">WordPress + LEMP Stack:</div>
                <div class="install-command" id="cmd1">curl -sSL https://raw.githubusercontent.com/sugan0927/easyinstallvps/main/easyinstall_wp.php | php</div>
                <button class="copy-btn" onclick="copyCommand('cmd1')">Copy Command</button>
            </div>
            
            <div style="margin: 20px 0;">
                <div style="margin-bottom: 10px;">Shell Installation:</div>
                <div class="install-command" id="cmd2">curl -sSL https://raw.githubusercontent.com/sugan0927/easyinstallvps/main/easyinstall.sh | bash</div>
                <button class="copy-btn" onclick="copyCommand('cmd2')">Copy Command</button>
            </div>
            
            <div style="margin: 20px 0;">
                <div style="margin-bottom: 10px;">Python Module:</div>
                <div class="install-command" id="cmd3">curl -sSL https://raw.githubusercontent.com/sugan0927/easyinstallvps/main/easyinstall_core.py -o easyinstall_core.py && python3 easyinstall_core.py</div>
                <button class="copy-btn" onclick="copyCommand('cmd3')">Copy Command</button>
            </div>
        </div>
        
        <div class="footer">
            <p>EasyInstallVPS v1.0.0 | Running on Cloudflare Workers</p>
            <p style="font-size: 12px; margin-top: 10px;">
                <a href="/health" style="color: #667eea;">Health Check</a> | 
                <a href="https://github.com/sugan0927/easyinstallvps/issues" style="color: #667eea;">Report Issue</a>
            </p>
        </div>
    </div>
    
    <script>
        function copyCommand(id) {
            const command = document.getElementById(id).innerText;
            navigator.clipboard.writeText(command).then(() => {
                alert('Command copied to clipboard!');
            });
        }
    </script>
</body>
</html>`;

  return new Response(html, {
    headers: {
      'Content-Type': 'text/html;charset=UTF-8',
      'Cache-Control': 'public, max-age=3600'
    }
  });
}
