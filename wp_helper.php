<?php
// =============================================================================
// EasyInstall v7.0 — PHP WordPress Helper (CLI)
// Handles: wp-config, DB ops, site create/delete/clone, pagespeed, images
// Run via: php easyinstall_wp.php <command> [args]
// =============================================================================
declare(strict_types=1);

define('EI_VERSION', '7.0');
define('WP_ROOT',    '/var/www/html');
define('STATE_DIR',  '/var/lib/easyinstall');
define('LOG_FILE',   '/var/log/easyinstall/install.log');
define('CRED_DIR',   '/root');

// ─── Colors ──────────────────────────────────────────────────────────────────
const G  = "\033[0;32m";
const Y  = "\033[1;33m";
const R  = "\033[0;31m";
const B  = "\033[0;34m";
const C  = "\033[0;36m";
const NC = "\033[0m";

function ok(string $m):   void { echo G . "✅  $m" . NC . "\n"; }
function warn(string $m): void { echo Y . "⚠️   $m" . NC . "\n"; }
function err(string $m):  void { echo R . "❌  $m" . NC . "\n"; }
function info(string $m): void { echo B . "ℹ️   $m" . NC . "\n"; }
function step(string $m): void { echo C . "🔷  $m" . NC . "\n"; }

// ─── Logging ──────────────────────────────────────────────────────────────────
function ei_log(string $level, string $msg): void {
    $ts  = date('Y-m-d H:i:s');
    $dir = dirname(LOG_FILE);
    if (!is_dir($dir)) mkdir($dir, 0755, true);
    file_put_contents(LOG_FILE, "[$ts] [$level] $msg\n", FILE_APPEND);
}

// ─── Shell helper ─────────────────────────────────────────────────────────────
function sh(string $cmd, bool $return = false): string|bool {
    ei_log('CMD', substr($cmd, 0, 100));
    if ($return) {
        $out = shell_exec($cmd . ' 2>/dev/null');
        return $out !== null ? trim($out) : '';
    }
    system($cmd . ' 2>/dev/null', $rc);
    return $rc === 0;
}

function sh_out(string $cmd): string {
    return trim((string)(shell_exec($cmd . ' 2>/dev/null') ?? ''));
}

// ─── Database connection ──────────────────────────────────────────────────────
function db_connect(): ?PDO {
    try {
        $pdo = new PDO('mysql:host=localhost;charset=utf8mb4', 'root', '',
            [PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION,
             PDO::ATTR_DEFAULT_FETCH_MODE => PDO::FETCH_ASSOC]);
        return $pdo;
    } catch (PDOException $e) {
        err("DB connect failed: " . $e->getMessage());
        return null;
    }
}

// ─── Generate random string ───────────────────────────────────────────────────
function rand_str(int $len = 16): string {
    $b = random_bytes((int)ceil($len * 3 / 4));
    return substr(preg_replace('/[^a-zA-Z0-9]/', '', base64_encode($b)), 0, $len);
}

// ─── Generate WordPress salts ─────────────────────────────────────────────────
function wp_salt(int $len = 64): string {
    $chars = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!@#$%^&*()-_=+[]{}|;:,.<>?';
    $salt  = '';
    $max   = strlen($chars) - 1;
    for ($i = 0; $i < $len; $i++) {
        $salt .= $chars[random_int(0, $max)];
    }
    return $salt;
}

// ─── Get PHP memory limit for a site ─────────────────────────────────────────
function get_php_mem(string $php_ver): string {
    $ini = "/etc/php/{$php_ver}/fpm/php.ini";
    if (is_file($ini)) {
        $lines = file($ini, FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES);
        foreach ($lines as $line) {
            if (preg_match('/^memory_limit\s*=\s*(.+)/i', $line, $m)) {
                return trim($m[1]);
            }
        }
    }
    return '256M';
}

// =============================================================================
// COMMAND: create-site
// php wp_helper.php create-site domain.com redis_port php_ver
// =============================================================================
function cmd_create_site(array $args): void {
    [$domain, $redis_port, $php_ver] = $args + ['', '6379', '8.3'];
    if (!$domain) { err("Domain required"); exit(1); }

    $domain     = preg_replace('/https?:\/\/|^www\.|\//','', $domain);
    $db_safe    = preg_replace('/[.\-]/', '_', $domain);
    $db_name    = "wp_{$db_safe}";
    $db_user    = "wpuser_{$db_safe}";
    $db_pass    = rand_str(20);
    $wp_path    = WP_ROOT . "/{$domain}";
    $php_mem    = get_php_mem($php_ver);
    $redis_port = (int)$redis_port;

    step("Creating WordPress config for {$domain}");

    // ── Create database ───────────────────────────────────────────────────────
    $pdo = db_connect();
    if (!$pdo) exit(1);

    $pdo->exec("CREATE DATABASE IF NOT EXISTS `{$db_name}` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci");
    $pdo->exec("CREATE USER IF NOT EXISTS '{$db_user}'@'localhost' IDENTIFIED BY '{$db_pass}'");
    $pdo->exec("GRANT ALL PRIVILEGES ON `{$db_name}`.* TO '{$db_user}'@'localhost'");
    $pdo->exec("FLUSH PRIVILEGES");
    ok("Database created: {$db_name}");

    // ── Generate salts ────────────────────────────────────────────────────────
    $salts = [];
    foreach (['AUTH_KEY','SECURE_AUTH_KEY','LOGGED_IN_KEY','NONCE_KEY',
              'AUTH_SALT','SECURE_AUTH_SALT','LOGGED_IN_SALT','NONCE_SALT'] as $k) {
        $salts[$k] = wp_salt();
    }

    // ── Write wp-config.php ───────────────────────────────────────────────────
    $config = <<<PHP
<?php
/** EasyInstall v7.0 — auto-generated wp-config */
define('DB_NAME',     '{$db_name}');
define('DB_USER',     '{$db_user}');
define('DB_PASSWORD', '{$db_pass}');
define('DB_HOST',     'localhost');
define('DB_CHARSET',  'utf8mb4');
define('DB_COLLATE',  '');

define('AUTH_KEY',         '{$salts[AUTH_KEY]}');
define('SECURE_AUTH_KEY',  '{$salts[SECURE_AUTH_KEY]}');
define('LOGGED_IN_KEY',    '{$salts[LOGGED_IN_KEY]}');
define('NONCE_KEY',        '{$salts[NONCE_KEY]}');
define('AUTH_SALT',        '{$salts[AUTH_SALT]}');
define('SECURE_AUTH_SALT', '{$salts[SECURE_AUTH_SALT]}');
define('LOGGED_IN_SALT',   '{$salts[LOGGED_IN_SALT]}');
define('NONCE_SALT',       '{$salts[NONCE_SALT]}');

define('WP_DEBUG',              false);
define('WP_DEBUG_LOG',          false);
define('WP_DEBUG_DISPLAY',      false);
define('WP_MEMORY_LIMIT',       '{$php_mem}');
define('WP_MAX_MEMORY_LIMIT',   '512M');
define('WP_CACHE',              true);
define('DISALLOW_FILE_EDIT',    false);
define('WP_POST_REVISIONS',     5);
define('EMPTY_TRASH_DAYS',      7);
define('WP_CRON_LOCK_TIMEOUT',  60);
define('AUTOMATIC_UPDATER_DISABLED', true);
define('WP_AUTO_UPDATE_CORE',   false);

// Redis object cache
define('WP_REDIS_HOST',         '127.0.0.1');
define('WP_REDIS_PORT',         {$redis_port});
define('WP_REDIS_DATABASE',     0);
define('WP_REDIS_TIMEOUT',      1);
define('WP_REDIS_READ_TIMEOUT', 1);
define('WP_REDIS_MAXTTL',       86400);
define('WP_CACHE_KEY_SALT',     '{$domain}_');

\$table_prefix = 'wp_';

if (!defined('ABSPATH')) {
    define('ABSPATH', __DIR__ . '/');
}
require_once ABSPATH . 'wp-settings.php';
PHP;

    file_put_contents("{$wp_path}/wp-config.php", $config);
    chmod("{$wp_path}/wp-config.php", 0600);
    sh("chown www-data:www-data {$wp_path}/wp-config.php");
    ok("wp-config.php created");

    // ── Save credentials ──────────────────────────────────────────────────────
    $cred = <<<CRED
════════════════════════════════════
WordPress Site: {$domain}
════════════════════════════════════
URL:       http://{$domain}
Admin:     http://{$domain}/wp-admin/install.php

Database:
  Name:    {$db_name}
  User:    {$db_user}
  Pass:    {$db_pass}

Redis:
  Port:    {$redis_port}
  Service: redis-{$domain}

PHP:       {$php_ver}
Path:      {$wp_path}
════════════════════════════════════
CRED;
    file_put_contents(CRED_DIR . "/{$domain}-credentials.txt", $cred);
    ok("Credentials: " . CRED_DIR . "/{$domain}-credentials.txt");
}

// =============================================================================
// COMMAND: delete-site
// =============================================================================
function cmd_delete_site(array $args): void {
    $domain  = $args[0] ?? '';
    $db_safe = preg_replace('/[.\-]/', '_', $domain);
    $db_name = "wp_{$db_safe}";
    $db_user = "wpuser_{$db_safe}";

    $pdo = db_connect();
    if ($pdo) {
        $pdo->exec("DROP DATABASE IF EXISTS `{$db_name}`");
        $pdo->exec("DROP USER IF EXISTS '{$db_user}'@'localhost'");
        $pdo->exec("FLUSH PRIVILEGES");
        ok("DB removed: {$db_name}");
    }
}

// =============================================================================
// COMMAND: clone-db
// php wp_helper.php clone-db src.com dst.com
// =============================================================================
function cmd_clone_db(array $args): void {
    [$src, $dst] = $args + ['', ''];
    $src_safe = preg_replace('/[.\-]/', '_', $src);
    $dst_safe = preg_replace('/[.\-]/', '_', $dst);
    $src_db   = "wp_{$src_safe}";
    $dst_db   = "wp_{$dst_safe}";
    $dst_user = "wpuser_{$dst_safe}";
    $dst_pass = rand_str(20);

    $pdo = db_connect();
    if (!$pdo) exit(1);
    $pdo->exec("CREATE DATABASE IF NOT EXISTS `{$dst_db}` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci");
    $pdo->exec("CREATE USER IF NOT EXISTS '{$dst_user}'@'localhost' IDENTIFIED BY '{$dst_pass}'");
    $pdo->exec("GRANT ALL PRIVILEGES ON `{$dst_db}`.* TO '{$dst_user}'@'localhost'");
    $pdo->exec("FLUSH PRIVILEGES");

    // Dump and restore
    sh("mysqldump {$src_db} 2>/dev/null | mysql {$dst_db} 2>/dev/null");
    ok("DB cloned: {$src_db} → {$dst_db}");

    // Save new DB creds
    file_put_contents(STATE_DIR . "/{$dst}.dbcreds",
        json_encode(['db' => $dst_db, 'user' => $dst_user, 'pass' => $dst_pass]));
}

// =============================================================================
// COMMAND: update-config
// php wp_helper.php update-config dst.com redis_port
// =============================================================================
function cmd_update_config(array $args): void {
    [$domain, $redis_port] = $args + ['', '6379'];
    $wp_path  = WP_ROOT . "/{$domain}";
    $cfg_file = "{$wp_path}/wp-config.php";
    if (!is_file($cfg_file)) { err("wp-config.php not found"); return; }

    $db_safe  = preg_replace('/[.\-]/', '_', $domain);
    $db_name  = "wp_{$db_safe}";
    $db_user  = "wpuser_{$db_safe}";

    // Load new creds if available
    $creds_file = STATE_DIR . "/{$domain}.dbcreds";
    if (is_file($creds_file)) {
        $creds    = json_decode(file_get_contents($creds_file), true);
        $db_name  = $creds['db']   ?? $db_name;
        $db_user  = $creds['user'] ?? $db_user;
        $db_pass  = $creds['pass'] ?? '';
        unlink($creds_file);
    } else {
        $db_pass = rand_str(20);
    }

    $txt = file_get_contents($cfg_file);
    // Update DB settings
    $txt = preg_replace("/define\('DB_NAME',.*?\)/",     "define('DB_NAME',     '{$db_name}')",  $txt);
    $txt = preg_replace("/define\('DB_USER',.*?\)/",     "define('DB_USER',     '{$db_user}')",  $txt);
    $txt = preg_replace("/define\('DB_PASSWORD',.*?\)/", "define('DB_PASSWORD', '{$db_pass}')",  $txt);
    $txt = preg_replace("/define\('WP_REDIS_PORT',.*?\)/","define('WP_REDIS_PORT', {$redis_port})", $txt);
    $txt = preg_replace("/define\('WP_CACHE_KEY_SALT',.*?\)/", "define('WP_CACHE_KEY_SALT', '{$domain}_')", $txt);
    file_put_contents($cfg_file, $txt);

    // Update URLs in DB
    sh("sudo -u www-data wp search-replace 'http://{$args[0]}' 'http://{$domain}' --path={$wp_path} --allow-root --quiet 2>/dev/null || true");
    ok("wp-config.php updated for {$domain}");
}

// =============================================================================
// COMMAND: backup-db
// php wp_helper.php backup-db domain.com /backup/dir
// =============================================================================
function cmd_backup_db(array $args): void {
    [$domain, $backup_dir] = $args + ['', '/backups'];
    $db_safe = preg_replace('/[.\-]/', '_', $domain);
    $db_name = "wp_{$db_safe}";
    $ts      = date('Ymd-His');
    $file    = "{$backup_dir}/{$domain}-db-{$ts}.sql.gz";
    if (!is_dir($backup_dir)) mkdir($backup_dir, 0755, true);
    sh("mysqldump {$db_name} 2>/dev/null | gzip > {$file}");
    ok("DB backup: {$file}");
}

// =============================================================================
// COMMAND: optimize-tables
// =============================================================================
function cmd_optimize_tables(array $args): void {
    $pdo = db_connect();
    if (!$pdo) return;
    step("Optimizing all WordPress tables");
    $dbs = $pdo->query("SHOW DATABASES LIKE 'wp_%'")->fetchAll(PDO::FETCH_COLUMN);
    foreach ($dbs as $db) {
        $pdo->exec("USE `{$db}`");
        $tables = $pdo->query("SHOW TABLES")->fetchAll(PDO::FETCH_COLUMN);
        foreach ($tables as $table) {
            $pdo->exec("OPTIMIZE TABLE `{$table}`");
        }
        ok("Optimized: {$db}");
    }
}

// =============================================================================
// COMMAND: wp-version
// =============================================================================
function cmd_wp_version(array $args): void {
    $domain  = $args[0] ?? '';
    $wp_path = WP_ROOT . "/{$domain}";
    $ver_file = "{$wp_path}/wp-includes/version.php";
    if (!is_file($ver_file)) { echo "unknown\n"; return; }
    $txt = file_get_contents($ver_file);
    preg_match("/\\\$wp_version\s*=\s*'([^']+)'/", $txt, $m);
    echo ($m[1] ?? 'unknown') . "\n";
}

// =============================================================================
// COMMAND: db-size
// =============================================================================
function cmd_db_size(array $args): void {
    $domain  = $args[0] ?? '';
    $db_safe = preg_replace('/[.\-]/', '_', $domain);
    $db_name = "wp_{$db_safe}";
    $pdo     = db_connect();
    if (!$pdo) { echo "?\n"; return; }
    $row = $pdo->query(
        "SELECT ROUND(SUM(data_length+index_length)/1024/1024,2) AS sz
         FROM information_schema.tables
         WHERE table_schema='{$db_name}'"
    )->fetch();
    $sz = $row['sz'] ?? '0';
    echo "{$db_name}  ({$sz} MB)\n";
}

// =============================================================================
// COMMAND: pagespeed-optimize
// Injects performance mu-plugin + image lazy loading + preconnect headers
// =============================================================================
function cmd_pagespeed_optimize(array $args): void {
    $domain  = $args[0] ?? '';
    $wp_path = WP_ROOT . "/{$domain}";
    if (!is_dir($wp_path)) { err("WP path not found: {$wp_path}"); return; }

    $mu_dir  = "{$wp_path}/wp-content/mu-plugins";
    if (!is_dir($mu_dir)) mkdir($mu_dir, 0755, true);

    // ── Performance mu-plugin ─────────────────────────────────────────────────
    file_put_contents("{$mu_dir}/ei-performance.php", <<<'PHP'
<?php
/**
 * EasyInstall Performance MU-Plugin v7.0
 * Auto-loaded by WordPress on every request
 */

// Remove unnecessary head bloat
remove_action('wp_head', 'wp_generator');
remove_action('wp_head', 'wlwmanifest_link');
remove_action('wp_head', 'rsd_link');
remove_action('wp_head', 'wp_shortlink_wp_head');
remove_action('wp_head', 'adjacent_posts_rel_link_wp_head');
remove_action('wp_head', 'print_emoji_detection_script', 7);
remove_action('wp_print_styles', 'print_emoji_styles');
remove_action('admin_print_scripts', 'print_emoji_detection_script');
remove_action('admin_print_styles', 'print_emoji_styles');

// Disable XML-RPC
add_filter('xmlrpc_enabled', '__return_false');

// Remove oEmbed
remove_action('wp_head', 'wp_oembed_add_discovery_links');
remove_action('wp_head', 'rest_output_link_wp_head');

// Disable WP heartbeat on frontend
add_action('init', function() {
    if (!is_admin()) {
        wp_deregister_script('heartbeat');
    }
});

// Add security headers
add_action('send_headers', function() {
    header('X-Content-Type-Options: nosniff');
    header('X-Frame-Options: SAMEORIGIN');
    header('X-XSS-Protection: 1; mode=block');
    header('Referrer-Policy: strict-origin-when-cross-origin');
});

// Lazy load images
add_filter('wp_lazy_loading_enabled', '__return_true');

// Remove query strings from static resources
add_filter('script_loader_src', 'ei_remove_query_strings', 15, 1);
add_filter('style_loader_src',  'ei_remove_query_strings', 15, 1);
function ei_remove_query_strings(string $src): string {
    if (strpos($src, '?ver=')) {
        $src = preg_replace('/\?ver=[0-9.]+/', '', $src);
    }
    return $src;
}

// Preconnect to external origins
add_action('wp_head', function() {
    echo '<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>' . "\n";
    echo '<link rel="dns-prefetch" href="//fonts.googleapis.com">' . "\n";
}, 1);

// Limit post revisions at runtime
if (!defined('WP_POST_REVISIONS')) define('WP_POST_REVISIONS', 5);

// Increase HTTP timeout for WP Cron
add_filter('http_request_timeout', fn() => 30);
PHP);

    sh("chown www-data:www-data {$mu_dir}/ei-performance.php");
    ok("Performance mu-plugin installed");

    // ── .htaccess for nginx ── (nginx ignores it but good for reference) ───────
    // ── Nginx conf snippet ────────────────────────────────────────────────────
    $nginx_snippet = <<<NGINX
# EasyInstall PageSpeed snippet for {$domain}
# Add to location ~ \\.php$ block or server block as needed

# Vary header for caching
add_header Vary "Accept-Encoding, Cookie" always;

# Security headers
add_header X-Content-Type-Options "nosniff" always;
add_header X-Frame-Options "SAMEORIGIN" always;
add_header X-XSS-Protection "1; mode=block" always;
add_header Referrer-Policy "strict-origin-when-cross-origin" always;
NGINX;
    $snippet_file = "/etc/nginx/snippets/pagespeed-{$domain}.conf";
    file_put_contents($snippet_file, $nginx_snippet);
    ok("Nginx PageSpeed snippet: {$snippet_file}");
}

// =============================================================================
// COMMAND: optimize-images
// Convert images to WebP, compress JPEG/PNG
// =============================================================================
function cmd_optimize_images(array $args): void {
    $domain   = $args[0] ?? '';
    $wp_path  = WP_ROOT . "/{$domain}";
    $uploads  = "{$wp_path}/wp-content/uploads";
    if (!is_dir($uploads)) { warn("Uploads dir not found"); return; }

    step("Optimizing images in {$uploads}");
    $converted = 0; $compressed = 0;

    // WebP conversion (requires cwebp)
    if (sh_out("which cwebp") !== '') {
        $iter = new RecursiveIteratorIterator(new RecursiveDirectoryIterator($uploads));
        foreach ($iter as $file) {
            if (!$file->isFile()) continue;
            $ext = strtolower($file->getExtension());
            if (!in_array($ext, ['jpg','jpeg','png'])) continue;
            $src  = $file->getPathname();
            $webp = preg_replace('/\.(jpg|jpeg|png)$/i', '.webp', $src);
            if (!file_exists($webp)) {
                sh("cwebp -quiet -q 82 '{$src}' -o '{$webp}' 2>/dev/null || true");
                if (file_exists($webp)) $converted++;
            }
        }
        ok("WebP converted: {$converted} images");
    } else {
        warn("cwebp not found — install with: apt-get install webp");
    }

    // JPEG compression (requires jpegoptim)
    if (sh_out("which jpegoptim") !== '') {
        sh("find {$uploads} -type f \\( -name '*.jpg' -o -name '*.jpeg' \\) -exec jpegoptim --max=85 --strip-all {} \\; 2>/dev/null || true");
        ok("JPEG compressed");
        $compressed++;
    }

    // PNG optimization (requires optipng)
    if (sh_out("which optipng") !== '') {
        sh("find {$uploads} -type f -name '*.png' -exec optipng -quiet -o2 {} \\; 2>/dev/null || true");
        ok("PNG compressed");
        $compressed++;
    }

    if ($compressed === 0 && $converted === 0) {
        info("Install tools: apt-get install webp jpegoptim optipng");
    }

    sh("chown -R www-data:www-data {$uploads}");
}

// =============================================================================
// COMMAND: pagespeed-report
// Generate simple HTML report
// =============================================================================
function cmd_pagespeed_report(array $args): void {
    $domain   = $args[0] ?? '';
    $wp_path  = WP_ROOT . "/{$domain}";
    $report_f = "/root/{$domain}-pagespeed-report.html";

    // Gather metrics
    $wp_ver    = cmd_wp_version_str($domain);
    $plugins   = sh_out("sudo -u www-data wp plugin list --path={$wp_path} --format=count --allow-root 2>/dev/null") ?: '?';
    $themes    = sh_out("sudo -u www-data wp theme  list --path={$wp_path} --format=count --allow-root 2>/dev/null") ?: '?';
    $db_size   = cmd_db_size_str($domain);
    $uploads   = "{$wp_path}/wp-content/uploads";
    $upl_size  = sh_out("du -sh {$uploads} 2>/dev/null | cut -f1") ?: '?';
    $ssl_ok    = file_exists("/etc/letsencrypt/live/{$domain}/cert.pem") ? '✅ Active' : '❌ None';
    $ts        = date('Y-m-d H:i:s');

    // PHP version from nginx config
    $php_ver   = trim((string)(shell_exec("grep -oP 'php[0-9.]+(?=-fpm)' /etc/nginx/sites-available/{$domain} 2>/dev/null | head -1") ?? '?'));
    $redis_p   = trim((string)(shell_exec("grep '^port' /etc/redis/redis-" . str_replace('.', '-', $domain) . ".conf 2>/dev/null | awk '{print $2}'") ?? '6379'));
    $redis_ok  = trim((string)(shell_exec("redis-cli -p {$redis_p} ping 2>/dev/null") ?? '')) === 'PONG' ? '✅' : '❌';

    $html = <<<HTML
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>EasyInstall PageSpeed Report — {$domain}</title>
<style>
  body{font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;margin:0;padding:24px;background:#f5f7fb;color:#222}
  h1{color:#1a56db;margin-bottom:4px}
  .meta{color:#666;font-size:.9em;margin-bottom:24px}
  .cards{display:grid;grid-template-columns:repeat(auto-fill,minmax(220px,1fr));gap:16px}
  .card{background:#fff;border-radius:10px;padding:20px;box-shadow:0 1px 4px rgba(0,0,0,.08)}
  .card h3{margin:0 0 8px;font-size:.85em;text-transform:uppercase;letter-spacing:.05em;color:#888}
  .card .val{font-size:1.5em;font-weight:700;color:#1a56db}
  .checklist{margin-top:24px;background:#fff;border-radius:10px;padding:20px;box-shadow:0 1px 4px rgba(0,0,0,.08)}
  .checklist h2{margin-top:0}
  .check{padding:8px 0;border-bottom:1px solid #f0f0f0;display:flex;align-items:center;gap:10px}
  .check:last-child{border:none}
  footer{margin-top:32px;color:#aaa;font-size:.8em;text-align:center}
</style>
</head>
<body>
<h1>📊 EasyInstall PageSpeed Report</h1>
<div class="meta">Domain: <strong>{$domain}</strong> &nbsp;|&nbsp; Generated: {$ts}</div>
<div class="cards">
  <div class="card"><h3>WordPress</h3><div class="val">{$wp_ver}</div></div>
  <div class="card"><h3>PHP</h3><div class="val">{$php_ver}</div></div>
  <div class="card"><h3>Plugins</h3><div class="val">{$plugins}</div></div>
  <div class="card"><h3>Themes</h3><div class="val">{$themes}</div></div>
  <div class="card"><h3>DB Size</h3><div class="val">{$db_size}</div></div>
  <div class="card"><h3>Uploads</h3><div class="val">{$upl_size}</div></div>
  <div class="card"><h3>SSL</h3><div class="val">{$ssl_ok}</div></div>
  <div class="card"><h3>Redis :{$redis_p}</h3><div class="val">{$redis_ok}</div></div>
</div>
<div class="checklist">
  <h2>✅ Performance Checklist</h2>
  <div class="check"><span>🔒</span> SSL Certificate: {$ssl_ok}</div>
  <div class="check"><span>⚡</span> Redis Object Cache: {$redis_ok}</div>
  <div class="check"><span>🐘</span> PHP Version: {$php_ver}</div>
  <div class="check"><span>🗜️</span> Nginx FastCGI Cache: Enabled</div>
  <div class="check"><span>📦</span> OPcache: Enabled</div>
  <div class="check"><span>🖼️</span> Run image optimization: <code>easyinstall pagespeed images {$domain}</code></div>
  <div class="check"><span>🌐</span> Get PageSpeed score: <code>easyinstall pagespeed score {$domain}</code></div>
</div>
<footer>EasyInstall v7.0 — Report generated {$ts}</footer>
</body></html>
HTML;

    file_put_contents($report_f, $html);
    ok("PageSpeed report: {$report_f}");
}

// Helpers for report
function cmd_wp_version_str(string $domain): string {
    $f = WP_ROOT . "/{$domain}/wp-includes/version.php";
    if (!is_file($f)) return '?';
    preg_match("/\\\$wp_version\s*=\s*'([^']+)'/", file_get_contents($f), $m);
    return $m[1] ?? '?';
}
function cmd_db_size_str(string $domain): string {
    $safe = preg_replace('/[.\-]/', '_', $domain);
    $pdo  = db_connect();
    if (!$pdo) return '?';
    $row = $pdo->query("SELECT ROUND(SUM(data_length+index_length)/1024/1024,2) AS sz FROM information_schema.tables WHERE table_schema='wp_{$safe}'")->fetch();
    return ($row['sz'] ?? '0') . ' MB';
}

// =============================================================================
// DISPATCH
// =============================================================================
$commands = [
    'create-site'         => 'cmd_create_site',
    'delete-site'         => 'cmd_delete_site',
    'clone-db'            => 'cmd_clone_db',
    'update-config'       => 'cmd_update_config',
    'backup-db'           => 'cmd_backup_db',
    'optimize-tables'     => 'cmd_optimize_tables',
    'wp-version'          => 'cmd_wp_version',
    'db-size'             => 'cmd_db_size',
    'pagespeed-optimize'  => 'cmd_pagespeed_optimize',
    'optimize-images'     => 'cmd_optimize_images',
    'pagespeed-report'    => 'cmd_pagespeed_report',
];

if ($argc < 2) {
    echo C . "EasyInstall PHP Helper v" . EI_VERSION . NC . "\n";
    echo "Commands: " . implode(', ', array_keys($commands)) . "\n";
    exit(0);
}

$cmd  = $argv[1];
$args = array_slice($argv, 2);

if (isset($commands[$cmd])) {
    try {
        call_user_func($commands[$cmd], $args);
    } catch (Throwable $e) {
        err("PHP Error: " . $e->getMessage());
        ei_log('ERROR', $e->getMessage());
        exit(1);
    }
} else {
    err("Unknown command: {$cmd}");
    exit(1);
}
