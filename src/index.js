// src/index.js - Simple redirect to GitHub Pages
export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);
    
    // Health check
    if (url.pathname === '/health' || url.pathname === '/status') {
      return new Response(JSON.stringify({
        status: 'healthy',
        timestamp: new Date().toISOString(),
        worker: 'easyinstallvps'
      }), {
        headers: { 'Content-Type': 'application/json' }
      });
    }

    // Serve installation instructions
    const html = `
      <!DOCTYPE html>
      <html>
      <head>
          <title>EasyInstallVPS</title>
          <meta charset="UTF-8">
          <meta name="viewport" content="width=device-width, initial-scale=1.0">
          <style>
              body {
                  font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
                  background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
                  margin: 0;
                  padding: 20px;
                  min-height: 100vh;
                  display: flex;
                  align-items: center;
                  justify-content: center;
              }
              .container {
                  background: white;
                  border-radius: 20px;
                  padding: 40px;
                  max-width: 800px;
                  width: 100%;
                  box-shadow: 0 20px 60px rgba(0,0,0,0.3);
              }
              h1 {
                  color: #333;
                  margin: 0 0 10px 0;
                  font-size: 32px;
              }
              .subtitle {
                  color: #666;
                  margin-bottom: 30px;
                  font-size: 18px;
              }
              .repo-card {
                  background: #f8f9fa;
                  border-radius: 10px;
                  padding: 20px;
                  margin: 20px 0;
                  border-left: 4px solid #667eea;
              }
              .repo-card h3 {
                  margin: 0 0 10px 0;
                  color: #333;
              }
              .repo-url {
                  background: white;
                  padding: 12px;
                  border-radius: 5px;
                  font-family: monospace;
                  font-size: 16px;
                  border: 1px solid #e0e0e0;
                  margin: 10px 0;
                  word-break: break-all;
              }
              .btn {
                  display: inline-block;
                  background: #667eea;
                  color: white;
                  text-decoration: none;
                  padding: 12px 24px;
                  border-radius: 8px;
                  margin: 10px 10px 10px 0;
                  font-size: 16px;
                  transition: background 0.3s ease;
              }
              .btn:hover {
                  background: #764ba2;
              }
              .btn-outline {
                  background: transparent;
                  border: 2px solid #667eea;
                  color: #667eea;
              }
              .btn-outline:hover {
                  background: #667eea;
                  color: white;
              }
              .files-list {
                  margin: 30px 0;
              }
              .file-item {
                  padding: 15px;
                  background: #f8f9fa;
                  margin: 10px 0;
                  border-radius: 8px;
                  display: flex;
                  align-items: center;
                  justify-content: space-between;
              }
              .file-name {
                  font-family: monospace;
                  font-size: 16px;
                  font-weight: bold;
              }
              .file-desc {
                  color: #666;
                  font-size: 14px;
              }
              .badge {
                  background: #28a745;
                  color: white;
                  padding: 4px 8px;
                  border-radius: 4px;
                  font-size: 12px;
              }
              .footer {
                  margin-top: 30px;
                  padding-top: 20px;
                  border-top: 1px solid #e0e0e0;
                  text-align: center;
                  color: #999;
              }
          </style>
      </head>
      <body>
          <div class="container">
              <h1>🚀 EasyInstallVPS</h1>
              <div class="subtitle">One-click VPS Installation Scripts</div>
              
              <div class="repo-card">
                  <h3>📦 GitHub Repository</h3>
                  <div class="repo-url">https://github.com/sugan0927/easyinstallvps</div>
                  <a href="https://github.com/sugan0927/easyinstallvps" class="btn" target="_blank">Open on GitHub</a>
                  <a href="https://github.com/sugan0927/easyinstallvps/archive/refs/heads/main.zip" class="btn btn-outline">Download ZIP</a>
              </div>
              
              <h2>📁 Available Files</h2>
              <div class="files-list">
                  <div class="file-item">
                      <div>
                          <div class="file-name">easyinstall_wp.php</div>
                          <div class="file-desc">WordPress installation script</div>
                      </div>
                      <a href="https://raw.githubusercontent.com/sugan0927/easyinstallvps/main/easyinstall_wp.php" class="badge" target="_blank">View Raw</a>
                  </div>
                  
                  <div class="file-item">
                      <div>
                          <div class="file-name">easyinstall_core.py</div>
                          <div class="file-desc">Python core installation module</div>
                      </div>
                      <a href="https://raw.githubusercontent.com/sugan0927/easyinstallvps/main/easyinstall_core.py" class="badge" target="_blank">View Raw</a>
                  </div>
                  
                  <div class="file-item">
                      <div>
                          <div class="file-name">easyinstall.sh</div>
                          <div class="file-desc">Main shell installation script</div>
                      </div>
                      <a href="https://raw.githubusercontent.com/sugan0927/easyinstallvps/main/easyinstall.sh" class="badge" target="_blank">View Raw</a>
                  </div>
              </div>
              
              <h2>📥 Quick Install</h2>
              <div style="background: #1e1e2f; color: #fff; padding: 20px; border-radius: 10px; font-family: monospace; margin: 20px 0;">
                  # WordPress Installation<br>
                  curl -sSL https://raw.githubusercontent.com/sugan0927/easyinstallvps/main/easyinstall_wp.php | php<br><br>
                  
                  # Shell Installation<br>
                  curl -sSL https://raw.githubusercontent.com/sugan0927/easyinstallvps/main/easyinstall.sh | bash
              </div>
              
              <div class="footer">
                  EasyInstallVPS v1.0.0 | Cloudflare Worker
              </div>
          </div>
      </body>
      </html>
    `;

    return new Response(html, {
      headers: { 
        'Content-Type': 'text/html;charset=UTF-8',
        'Cache-Control': 'public, max-age=3600'
      }
    });
  }
};
