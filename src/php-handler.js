// src/php-handler.js
// Try different import approaches for php-wasm

// Approach 1: Dynamic import (most compatible with Workers)
export class PHPHandler {
  constructor(env) {
    this.env = env;
    this.php = null;
    this.phpModule = null;
  }

  async initPHP() {
    if (this.phpModule) return this.phpModule;
    
    try {
      // Try dynamic import
      const module = await import('php-wasm').catch(() => null);
      if (module && module.PHP) {
        this.phpModule = module.PHP;
        return this.phpModule;
      }
    } catch (e) {
      console.log('Dynamic import failed, trying alternatives...');
    }
    
    try {
      // Try alternative import
      const module = await import('@php-wasm/node').catch(() => null);
      if (module && module.PHP) {
        this.phpModule = module.PHP;
        return this.phpModule;
      }
    } catch (e) {
      console.log('@php-wasm/node import failed');
    }
    
    // Fallback to a simple PHP implementation
    console.warn('Using fallback PHP implementation');
    this.phpModule = this.createFallbackPHP();
    return this.phpModule;
  }

  createFallbackPHP() {
    // A very simple PHP fallback that just evaluates basic PHP code
    return class FallbackPHP {
      constructor() {
        this.variables = {};
      }
      
      defineVariable(name, value) {
        this.variables[name] = value;
      }
      
      async run(code) {
        // Simple PHP tag removal and basic evaluation
        // This is just for demonstration - in production, you'd need a real PHP runtime
        const cleaned = code.replace(/<\?php/g, '').replace(/\?>/g, '');
        
        // Extract and execute basic PHP constructs
        let output = '';
        
        // Handle echo statements
        const echoMatches = cleaned.match(/echo\s+["']([^"']+)["']/g);
        if (echoMatches) {
          echoMatches.forEach(match => {
            const content = match.match(/["']([^"']+)["']/)[1];
            output += content + '\n';
          });
        }
        
        // Handle variables
        const varMatches = cleaned.match(/\$([a-zA-Z_\x7f-\xff][a-zA-Z0-9_\x7f-\xff]*)\s*=\s*["']([^"']+)["']/g);
        if (varMatches) {
          varMatches.forEach(match => {
            const parts = match.match(/\$([a-zA-Z_\x7f-\xff][a-zA-Z0-9_\x7f-\xff]*)\s*=\s*["']([^"']+)["']/);
            if (parts) {
              this.variables[parts[1]] = parts[2];
            }
          });
        }
        
        return output || 'Fallback PHP execution (no output)';
      }
    };
  }

  async execute(phpCode, context) {
    try {
      // Initialize PHP runtime
      const PHPClass = await this.initPHP();
      this.php = new PHPClass({
        // Configure PHP ini settings
        ini: {
          memory_limit: '128M',
          max_execution_time: '30',
          display_errors: this.env?.ENVIRONMENT === 'development' ? '1' : '0',
          error_reporting: this.env?.ENVIRONMENT === 'development' ? 'E_ALL' : '0',
        },
      });

      // Set up PHP environment variables
      await this.setEnvironmentVariables(context);

      // Add custom PHP functions for Cloudflare integration
      await this.addCustomFunctions();

      // Execute the PHP code
      const result = await this.php.run(phpCode);

      return result;

    } catch (error) {
      console.error('PHP execution error:', error);
      
      // Fallback: Return a simple HTML page with error info
      return this.generateFallbackPage(phpCode, context, error);
    }
  }

  async setEnvironmentVariables(context) {
    const { request, env, queryParams, path, githubToken } = context;

    // Set superglobals as PHP variables
    const serverVars = {
      'REQUEST_METHOD': request.method,
      'REQUEST_URI': path,
      'QUERY_STRING': new URLSearchParams(queryParams).toString(),
      'HTTP_HOST': request.headers.get('host') || '',
      'HTTP_USER_AGENT': request.headers.get('user-agent') || '',
      'REMOTE_ADDR': request.headers.get('cf-connecting-ip') || '',
      'SERVER_NAME': 'cloudflare-workers',
      'SERVER_SOFTWARE': 'Cloudflare Workers',
      'DOCUMENT_ROOT': '/',
      'GITHUB_TOKEN': githubToken,
    };

    Object.entries(serverVars).forEach(([key, value]) => {
      if (this.php && this.php.defineVariable) {
        this.php.defineVariable(`_SERVER['${key}']`, value);
      }
    });

    // Set query parameters
    if (this.php && this.php.defineVariable) {
      this.php.defineVariable('_GET', queryParams);
      this.php.defineVariable('_POST', {});
      this.php.defineVariable('_REQUEST', { ...queryParams });
      
      this.php.defineVariable('_ENV', {
        'APP_ENV': env?.ENVIRONMENT || 'production',
        'GITHUB_REPO': `${env?.GITHUB_REPO_OWNER || 'sugan0927'}/${env?.GITHUB_REPO_NAME || 'easyinstallvps'}`,
      });
    }
  }

  async addCustomFunctions() {
    if (!this.php || !this.php.run) return;
    
    const customFunctions = `
      <?php
      function cf_fetch($url, $options = []) {
          return "Fetching: " . $url;
      }
      
      function github_get_file($path) {
          return "Reading: " . $path;
      }
      
      function cf_log($message, $data = null) {
          error_log("[EasyInstallPHP] " . $message);
      }
      ?>
    `;

    try {
      await this.php.run(customFunctions);
    } catch (e) {
      console.log('Could not add custom functions:', e);
    }
  }

  generateFallbackPage(phpCode, context, error) {
    const { path, queryParams } = context;
    
    return `
      <!DOCTYPE html>
      <html>
      <head>
          <title>EasyInstallPHP - Development Mode</title>
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
                  padding: 30px;
                  max-width: 1200px;
                  width: 100%;
                  box-shadow: 0 20px 60px rgba(0,0,0,0.3);
              }
              .header {
                  display: flex;
                  align-items: center;
                  justify-content: space-between;
                  margin-bottom: 30px;
                  padding-bottom: 20px;
                  border-bottom: 2px solid #f0f0f0;
              }
              h1 {
                  color: #333;
                  margin: 0;
                  font-size: 28px;
              }
              .badge {
                  background: #667eea;
                  color: white;
                  padding: 8px 16px;
                  border-radius: 20px;
                  font-size: 14px;
              }
              .info-grid {
                  display: grid;
                  grid-template-columns: repeat(auto-fit, minmax(300px, 1fr));
                  gap: 20px;
                  margin-bottom: 30px;
              }
              .info-card {
                  background: #f8f9fa;
                  padding: 20px;
                  border-radius: 10px;
                  border-left: 4px solid #667eea;
              }
              .info-card h3 {
                  margin: 0 0 15px 0;
                  color: #333;
                  font-size: 18px;
                  display: flex;
                  align-items: center;
                  gap: 8px;
              }
              .info-card pre {
                  background: white;
                  padding: 10px;
                  border-radius: 5px;
                  margin: 0;
                  overflow-x: auto;
                  font-size: 13px;
                  border: 1px solid #e0e0e0;
              }
              .php-code {
                  background: #1e1e2f;
                  color: #fff;
                  padding: 20px;
                  border-radius: 10px;
                  overflow-x: auto;
                  font-family: 'Courier New', monospace;
                  font-size: 14px;
                  margin: 20px 0;
              }
              .php-code .keyword { color: #ff79c6; }
              .php-code .string { color: #f1fa8c; }
              .php-code .comment { color: #6272a4; }
              .error-message {
                  background: #fee;
                  color: #c00;
                  padding: 15px;
                  border-radius: 10px;
                  margin: 20px 0;
                  border: 1px solid #fcc;
              }
              .btn {
                  display: inline-block;
                  background: #667eea;
                  color: white;
                  text-decoration: none;
                  padding: 12px 24px;
                  border-radius: 8px;
                  border: none;
                  cursor: pointer;
                  font-size: 16px;
                  transition: background 0.3s ease;
                  margin-right: 10px;
              }
              .btn:hover {
                  background: #764ba2;
              }
              .btn-secondary {
                  background: #6c757d;
              }
              .btn-secondary:hover {
                  background: #5a6268;
              }
              .tabs {
                  display: flex;
                  gap: 10px;
                  margin-bottom: 20px;
                  border-bottom: 2px solid #f0f0f0;
                  padding-bottom: 10px;
              }
              .tab {
                  padding: 10px 20px;
                  cursor: pointer;
                  border-radius: 5px 5px 0 0;
                  color: #666;
              }
              .tab.active {
                  background: #667eea;
                  color: white;
              }
              .tab-content {
                  display: none;
              }
              .tab-content.active {
                  display: block;
              }
          </style>
      </head>
      <body>
          <div class="container">
              <div class="header">
                  <h1>🚀 EasyInstallPHP</h1>
                  <span class="badge">Development Mode</span>
              </div>
              
              <div class="info-grid">
                  <div class="info-card">
                      <h3>📁 Request Info</h3>
                      <pre>Path: ${path || '/'}
Method: ${context.request.method}
Query: ${JSON.stringify(queryParams, null, 2)}</pre>
                  </div>
                  
                  <div class="info-card">
                      <h3>🔧 Environment</h3>
                      <pre>Environment: ${context.env?.ENVIRONMENT || 'production'}
GitHub Repo: ${context.env?.GITHUB_REPO_OWNER || 'sugan0927'}/${context.env?.GITHUB_REPO_NAME || 'easyinstallvps'}
PHP Runtime: Fallback Mode</pre>
                  </div>
                  
                  <div class="info-card">
                      <h3>📊 Status</h3>
                      <pre>Worker: Active
PHP-WASM: ⚠️ Not Loaded
Mode: Development Fallback
Timestamp: ${new Date().toISOString()}</pre>
                  </div>
              </div>
              
              ${error ? `
                  <div class="error-message">
                      <strong>⚠️ PHP Error:</strong> ${error.message}
                  </div>
              ` : ''}
              
              <div class="tabs">
                  <div class="tab active" onclick="showTab('output')">📤 Output</div>
                  <div class="tab" onclick="showTab('code')">📄 PHP Code</div>
                  <div class="tab" onclick="showTab('github')">📦 GitHub Files</div>
              </div>
              
              <div id="output" class="tab-content active">
                  <h3>PHP Output (Fallback Mode)</h3>
                  <div class="php-code">
                      <?php
                      echo "Welcome to EasyInstallPHP!\\n";
                      echo "Path: " . (${JSON.stringify(path)} ?: '/') . "\\n";
                      echo "Time: " . date('Y-m-d H:i:s') . "\\n";
                      ?>
                  </div>
                  <div>
                      <a href="/" class="btn">🏠 Home</a>
                      <button onclick="window.location.reload()" class="btn btn-secondary">🔄 Retry</button>
                      <a href="/health" class="btn btn-secondary">❤️ Health Check</a>
                  </div>
              </div>
              
              <div id="code" class="tab-content">
                  <h3>PHP Source Code (First 500 chars)</h3>
                  <pre class="php-code">${this.escapeHtml(phpCode.substring(0, 500))}${phpCode.length > 500 ? '...' : ''}</pre>
              </div>
              
              <div id="github" class="tab-content">
                  <h3>GitHub Files</h3>
                  <ul style="list-style: none; padding: 0;">
                      <li style="padding: 10px; background: #f8f9fa; margin: 5px 0; border-radius: 5px;">
                          📄 <strong>easyinstall_wp.php</strong> - Main PHP Installer
                      </li>
                      <li style="padding: 10px; background: #f8f9fa; margin: 5px 0; border-radius: 5px;">
                          🐍 <strong>easyinstall_core.py</strong> - Python Core
                      </li>
                      <li style="padding: 10px; background: #f8f9fa; margin: 5px 0; border-radius: 5px;">
                          📜 <strong>easyinstall.sh</strong> - Shell Script
                      </li>
                  </ul>
              </div>
          </div>
          
          <script>
              function showTab(tabId) {
                  document.querySelectorAll('.tab-content').forEach(el => {
                      el.classList.remove('active');
                  });
                  document.querySelectorAll('.tab').forEach(el => {
                      el.classList.remove('active');
                  });
                  document.getElementById(tabId).classList.add('active');
                  event.target.classList.add('active');
              }
          </script>
      </body>
      </html>
    `;
  }

  escapeHtml(text) {
    return text
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;')
      .replace(/'/g, '&#039;');
  }
}
