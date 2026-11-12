<?php
/**
 * PrestaShop Upgrade Toolkit - environment check endpoint.
 *
 * Called by ps-upgrade.sh via HTTP to find out which PHP version/extensions the
 * WEB server uses (may differ from the CLI PHP) and which IP the shop sees for
 * requests coming from the server itself (needed for the maintenance whitelist).
 *
 * Protected by ENV_CHECK_TOKEN from helper/.env (generated automatically).
 *
 * @author Sebastian G. Marinescu
 */
header('Content-Type: application/json; charset=utf-8');
header('Cache-Control: no-store, no-cache, must-revalidate');
header('X-Robots-Tag: noindex, nofollow');

$token = '';
$envFile = __DIR__ . '/.env';
if (is_readable($envFile)) {
    foreach ((array) file($envFile) as $line) {
        if (preg_match('/^\s*ENV_CHECK_TOKEN\s*=\s*["\']?([A-Za-z0-9_\-]+)["\']?\s*$/', (string) $line, $m)) {
            $token = $m[1];
        }
    }
}

$given = isset($_GET['token']) ? (string) $_GET['token'] : '';
if ($token === '' || strlen($token) < 16 || !hash_equals($token, $given)) {
    http_response_code(403);
    echo json_encode(['error' => 'forbidden']);
    exit;
}

$remoteAddr = isset($_SERVER['REMOTE_ADDR']) ? (string) $_SERVER['REMOTE_ADDR'] : '';
$forwarded = isset($_SERVER['HTTP_X_FORWARDED_FOR']) ? (string) $_SERVER['HTTP_X_FORWARDED_FOR'] : '';

// Same logic as PrestaShop's Tools::getRemoteAddr()
$remoteIp = $remoteAddr;
if ($forwarded !== '' && ($remoteAddr === '' || preg_match('/^(10\.|127\.|172\.(1[6-9]|2\d|3[01])\.|192\.168\.|::1|fc|fd)/i', $remoteAddr))) {
    $parts = explode(',', $forwarded);
    $remoteIp = trim($parts[0]);
}

$extensions = array_map('strtolower', get_loaded_extensions());
sort($extensions);

echo json_encode([
    'php_version' => PHP_VERSION,
    'php_sapi' => PHP_SAPI,
    'extensions' => implode(' ', $extensions),
    'memory_limit' => (string) ini_get('memory_limit'),
    'max_execution_time' => (string) ini_get('max_execution_time'),
    'upload_max_filesize' => (string) ini_get('upload_max_filesize'),
    'post_max_size' => (string) ini_get('post_max_size'),
    'opcache_enabled' => function_exists('opcache_get_status') && @opcache_get_status(false) ? '1' : '0',
    'remote_ip' => $remoteIp,
    'remote_addr' => $remoteAddr,
    'x_forwarded_for' => $forwarded,
    'server_software' => isset($_SERVER['SERVER_SOFTWARE']) ? (string) $_SERVER['SERVER_SOFTWARE'] : '',
    'document_root' => isset($_SERVER['DOCUMENT_ROOT']) ? (string) $_SERVER['DOCUMENT_ROOT'] : '',
], JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES);
