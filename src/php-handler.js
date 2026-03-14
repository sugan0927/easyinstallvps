// src/php-handler.js
import { PHP } from 'php-wasm';

export class PHPHandler {
  constructor(env) {
    this.env = env;
    this.php = null;
  }

  async execute(phpCode, context) {
    try {
      // Initialize PHP runtime
      this.php = new PHP({
        // Configure PHP ini settings
        ini: {
          'memory_limit': '128M',
          'max_execution_time': '30',
          'display_errors': this.env.ENVIRONMENT === 'development' ? '1' : '0',
          'error_reporting': this.env.ENVIRONMENT === 'development' ? 'E_ALL' : '0',
        },
      });

      // Set up PHP environment variables
      this.setEnvironmentVariables(context);

      // Add custom PHP functions for Cloudflare integration
      await this.addCustomFunctions();

      // Execute the PHP code
      const result = await this.php.run(phpCode);

      return result;

    } catch (error) {
      console.error('PHP execution error:', error);
      throw new Error(`PHP Error: ${error.message}`);
    }
  }

  setEnvironmentVariables(context) {
    const { request, env, queryParams, path, githubToken } = context;

    // Set superglobals
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

    // Set $_SERVER variables
    Object.entries(serverVars).forEach(([key, value]) => {
      this.php.defineVariable(`_SERVER['${key}']`, value);
    });

    // Set $_GET variables
    this.php.defineVariable('_GET', queryParams);

    // Set $_POST variables (for form submissions)
    // Note: This is simplified - in production, you'd parse the request body
    this.php.defineVariable('_POST', {});

    // Set $_REQUEST (merge of GET and POST)
    this.php.defineVariable('_REQUEST', { ...queryParams });

    // Set environment variables
    this.php.defineVariable('_ENV', {
      'APP_ENV': env.ENVIRONMENT || 'production',
      'GITHUB_REPO': `${env.GITHUB_REPO_OWNER}/${env.GITHUB_REPO_NAME}`,
    });
  }

  async addCustomFunctions() {
    // Add custom PHP functions for Cloudflare integration
    const customFunctions = `
      <?php
      // Custom function to make HTTP requests via Cloudflare
      function cf_fetch($url, $options = []) {
          $ch = curl_init($url);
          curl_setopt($ch, CURLOPT_RETURNTRANSFER, true);
          curl_setopt($ch, CURLOPT_FOLLOWLOCATION, true);
          curl_setopt($ch, CURLOPT_TIMEOUT, 30);
          
          if (isset($options['headers'])) {
              curl_setopt($ch, CURLOPT_HTTPHEADER, $options['headers']);
          }
          
          if (isset($options['method']) && $options['method'] !== 'GET') {
              curl_setopt($ch, CURLOPT_CUSTOMREQUEST, $options['method']);
          }
          
          if (isset($options['body'])) {
              curl_setopt($ch, CURLOPT_POSTFIELDS, $options['body']);
          }
          
          $response = curl_exec($ch);
          $info = curl_getinfo($ch);
          curl_close($ch);
          
          return [
              'body' => $response,
              'status' => $info['http_code'],
              'headers' => []
          ];
      }
      
      // Custom function to read GitHub files
      function github_get_file($path) {
          $token = $_SERVER['GITHUB_TOKEN'] ?? '';
          $repo = $_ENV['GITHUB_REPO'] ?? 'sugan0927/easyinstallvps';
          
          $url = "https://api.github.com/repos/{$repo}/contents/{$path}";
          $headers = [
              'Authorization: token ' . $token,
              'User-Agent: Cloudflare-Worker',
              'Accept: application/vnd.github.v3.raw'
          ];
          
          $result = cf_fetch($url, ['headers' => $headers]);
          return $result['body'];
      }
      
      // Log function for debugging
      function cf_log($message, $data = null) {
          error_log("[EasyInstallPHP] " . $message . ($data ? ": " . json_encode($data) : ""));
      }
      ?>
    `;

    await this.php.run(customFunctions);
  }
}
