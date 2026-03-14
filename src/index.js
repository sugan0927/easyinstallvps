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

    // Handle OPTIONS request (CORS preflight)
    if (request.method === 'OPTIONS') {
      return new Response(null, {
        headers: corsHeaders,
        status: 204,
      });
    }

    try {
      // Initialize handlers
      const githubFetcher = new GitHubFetcher(env);
      const phpHandler = new PHPHandler(env);

      // Check if it's a static file request
      const staticFiles = {
        '/favicon.ico': 'image/x-icon',
        '/robots.txt': 'text/plain',
      };

      if (staticFiles[url.pathname]) {
        return serveStaticFile(url.pathname, staticFiles[url.pathname]);
      }

      // Fetch PHP file from GitHub
      let phpCode;
      try {
        phpCode = await githubFetcher.fetchFile('easyinstall_wp.php');
      } catch (error) {
        console.error('GitHub fetch error:', error);
        return serveErrorPage(500, 'Failed to fetch PHP code from GitHub', error);
      }

      // Execute PHP code
      const result = await phpHandler.execute(phpCode, {
        request,
        env,
        queryParams: Object.fromEntries(url.searchParams),
        path: url.pathname,
        githubToken: env.GITHUB_TOKEN,
      });

      // Calculate execution time
      const executionTime = Date.now() - startTime;

      // Add execution time header in development
      const headers = {
        'Content-Type': 'text/html;charset=UTF-8',
        'X-Execution-Time': `${executionTime}ms`,
        ...corsHeaders,
      };

      return new Response(result, { headers });

    } catch (error) {
      console.error('Worker error:', error);
      return serveErrorPage(500, 'Internal Server Error', error);
    }
  },
};

// Helper function to serve static files
function serveStaticFile(path, contentType) {
  const files = {
    '/favicon.ico': '',
    '/robots.txt': 'User-agent: *\nDisallow:',
  };

  return new Response(files[path] || '', {
    headers: {
      'Content-Type': contentType,
      'Cache-Control': 'public, max-age=86400',
    },
  });
}

// Helper function to serve error pages
function serveErrorPage(status, message, error) {
  const html = `
    <!DOCTYPE html>
    <html lang="en">
    <head>
        <meta charset="UTF-8">
        <meta name="viewport" content="width=device-width, initial-scale=1.0">
        <title>EasyInstallPHP - Error ${status}</title>
        <style>
            body {
                font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Oxygen, Ubuntu, sans-serif;
                background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
                margin: 0;
                padding: 0;
                min-height: 100vh;
                display: flex;
                align-items: center;
                justify-content: center;
            }
            .error-container {
                background: white;
                border-radius: 20px;
                padding: 40px;
                max-width: 600px;
                margin: 20px;
                box-shadow: 0 20px 60px rgba(0,0,0,0.3);
            }
            h1 {
                color: #dc3545;
                margin-top: 0;
                font-size: 32px;
            }
            .error-details {
                background: #f8f9fa;
                padding: 20px;
                border-radius: 10px;
                margin-top: 20px;
                font-family: 'Courier New', monospace;
                font-size: 14px;
                overflow-x: auto;
            }
            .btn {
                display: inline-block;
                background: #667eea;
                color: white;
                text-decoration: none;
                padding: 10px 20px;
                border-radius: 5px;
                margin-top: 20px;
            }
            .btn:hover {
                background: #764ba2;
            }
        </style>
    </head>
    <body>
        <div class="error-container">
            <h1>⚠️ Error ${status}</h1>
            <p>${message}</p>
            ${error ? `
                <div class="error-details">
                    <strong>Details:</strong><br>
                    ${error.message || error}
                </div>
            ` : ''}
            <a href="/" class="btn">Return to Homepage</a>
        </div>
    </body>
    </html>
  `;

  return new Response(html, {
    status,
    headers: {
      'Content-Type': 'text/html;charset=UTF-8',
      'Cache-Control': 'no-cache',
    },
  });
}
