// src/index.js
import { PHPHandler } from './php-handler';
import { GitHubFetcher } from './github-fetcher';

export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);
    const startTime = Date.now();
    
    // CORS Headers
    const corsHeaders = {
      'Access-Control-Allow-Origin': '*',
      'Access-Control-Allow-Methods': 'GET, POST, PUT, DELETE, OPTIONS',
      'Access-Control-Allow-Headers': 'Content-Type, Authorization',
      'Access-Control-Max-Age': '86400',
    };

    // Handle OPTIONS request
    if (request.method === 'OPTIONS') {
      return new Response(null, {
        headers: corsHeaders,
        status: 204,
      });
    }

    // Health check endpoint
    if (url.pathname === '/health' || url.pathname === '/status') {
      return new Response(JSON.stringify({
        status: 'healthy',
        timestamp: new Date().toISOString(),
        environment: env.ENVIRONMENT || 'production',
        version: '1.0.0'
      }), {
        headers: {
          'Content-Type': 'application/json',
          ...corsHeaders
        }
      });
    }

    try {
      // Initialize handlers with error handling
      if (!env.GITHUB_TOKEN) {
        throw new Error('GITHUB_TOKEN environment variable is not set');
      }

      const githubFetcher = new GitHubFetcher(env);
      const phpHandler = new PHPHandler(env);

      // Determine which file to fetch based on path
      let fileToFetch = 'easyinstall_wp.php';
      
      if (url.pathname.includes('/core') || url.pathname.includes('/python')) {
        fileToFetch = 'easyinstall_core.py';
      } else if (url.pathname.includes('/install') || url.pathname.includes('/sh')) {
        fileToFetch = 'easyinstall.sh';
      } else if (url.pathname === '/') {
        fileToFetch = 'easyinstall_wp.php';
      }

      // Fetch file from GitHub with retry logic
      let phpCode;
      let retries = 3;
      
      while (retries > 0) {
        try {
          phpCode = await githubFetcher.fetchFile(fileToFetch);
          break;
        } catch (error) {
          retries--;
          if (retries === 0) throw error;
          await new Promise(resolve => setTimeout(resolve, 1000));
        }
      }

      if (!phpCode) {
        throw new Error(`Failed to fetch ${fileToFetch} from GitHub`);
      }

      // Execute PHP code
      const result = await phpHandler.execute(phpCode, {
        request,
        env,
        queryParams: Object.fromEntries(url.searchParams),
        path: url.pathname,
        githubToken: env.GITHUB_TOKEN,
      });

      const executionTime = Date.now() - startTime;

      const headers = {
        'Content-Type': 'text/html;charset=UTF-8',
        'X-Execution-Time': `${executionTime}ms`,
        'X-File-Served': fileToFetch,
        ...corsHeaders,
      };

      return new Response(result, { headers });

    } catch (error) {
      console.error('Worker error:', error);
      return serveErrorPage(500, 'Internal Server Error', error, env);
    }
  },
};

function serveErrorPage(status, message, error, env) {
  const isDev = env && env.ENVIRONMENT === 'development';
  
  const html = `
    <!DOCTYPE html>
    <html lang="en">
    <head>
        <meta charset="UTF-8">
        <meta name="viewport" content="width=device-width, initial-scale=1.0">
        <title>EasyInstallPHP - Error ${status}</title>
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
            .error-container {
                background: white;
                border-radius: 20px;
                padding: 40px;
                max-width: 800px;
                width: 100%;
                box-shadow: 0 20px 60px rgba(0,0,0,0.3);
                animation: slideIn 0.5s ease;
            }
            @keyframes slideIn {
                from {
                    opacity: 0;
                    transform: translateY(-20px);
                }
                to {
                    opacity: 1;
                    transform: translateY(0);
                }
            }
            h1 {
                color: #dc3545;
                margin-top: 0;
                font-size: 32px;
                display: flex;
                align-items: center;
                gap: 10px;
            }
            h1:before {
                content: "⚠️";
                font-size: 40px;
            }
            .error-code {
                background: #f8f9fa;
                padding: 15px 20px;
                border-radius: 10px;
                margin: 20px 0;
                border-left: 4px solid #dc3545;
            }
            .error-details {
                background: #f8f9fa;
                padding: 20px;
                border-radius: 10px;
                margin: 20px 0;
                font-family: 'Courier New', monospace;
                font-size: 14px;
                overflow-x: auto;
                border: 1px solid #e9ecef;
            }
            .error-stack {
                color: #666;
                font-size: 12px;
                margin-top: 10px;
                padding-top: 10px;
                border-top: 1px solid #e9ecef;
            }
            .btn {
                display: inline-block;
                background: #667eea;
                color: white;
                text-decoration: none;
                padding: 12px 24px;
                border-radius: 8px;
                margin-top: 20px;
                border: none;
                cursor: pointer;
                font-size: 16px;
                transition: background 0.3s ease;
            }
            .btn:hover {
                background: #764ba2;
            }
            .btn-group {
                display: flex;
                gap: 10px;
                margin-top: 20px;
            }
            .btn-secondary {
                background: #6c757d;
            }
            .btn-secondary:hover {
                background: #5a6268;
            }
            .info {
                background: #e3f2fd;
                padding: 15px;
                border-radius: 8px;
                margin: 20px 0;
                border-left: 4px solid #2196f3;
            }
            .timestamp {
                color: #999;
                font-size: 12px;
                margin-top: 20px;
                text-align: right;
            }
        </style>
    </head>
    <body>
        <div class="error-container">
            <h1>Error ${status}</h1>
            <div class="error-code">${message}</div>
            
            ${isDev && error ? `
                <div class="error-details">
                    <strong>🔍 Error Details:</strong><br>
                    ${error.message || error}
                    ${error.stack ? `<div class="error-stack">${error.stack}</div>` : ''}
                </div>
            ` : ''}
            
            <div class="info">
                <strong>ℹ️ Information:</strong><br>
                • Environment: ${env?.ENVIRONMENT || 'production'}<br>
                • Repository: ${env?.GITHUB_REPO_OWNER || 'sugan0927'}/${env?.GITHUB_REPO_NAME || 'easyinstallvps'}<br>
                • Timestamp: ${new Date().toLocaleString()}
            </div>
            
            <div class="btn-group">
                <a href="/" class="btn">🏠 Return to Homepage</a>
                <button onclick="window.location.reload()" class="btn btn-secondary">🔄 Retry</button>
            </div>
            
            <div class="timestamp">
                Request ID: ${crypto.randomUUID().split('-')[0]}
            </div>
        </div>
    </body>
    </html>
  `;

  return new Response(html, {
    status,
    headers: {
      'Content-Type': 'text/html;charset=UTF-8',
      'Cache-Control': 'no-cache, no-store, must-revalidate',
    },
  });
}
