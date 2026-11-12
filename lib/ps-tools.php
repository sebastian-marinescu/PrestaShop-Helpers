<?php
/**
 * PrestaShop Upgrade Toolkit - PHP helper (CLI only).
 *
 * Used by ps-upgrade.sh for everything that is fragile in plain (portable) bash:
 * JSON/XML/YAML parsing, ZIP handling, version comparison, checksum based
 * integrity checks and token based override analysis.
 *
 * Usage: php ps-tools.php <command> [args...]
 *
 * @author Sebastian G. Marinescu
 */
if (PHP_SAPI !== 'cli') {
    http_response_code(404);
    exit(1);
}

error_reporting(E_ALL & ~E_DEPRECATED & ~E_USER_DEPRECATED);
ini_set('display_errors', 'stderr');
ini_set('memory_limit', '1024M');

$command = $argv[1] ?? 'help';
$args = array_slice($argv, 2);

/* -------------------------------------------------------------------------
 * Generic helpers
 * ---------------------------------------------------------------------- */

function out(string $line): void
{
    fwrite(STDOUT, $line . "\n");
}

function fail(string $message, int $code = 1): void
{
    fwrite(STDERR, 'ps-tools: ' . $message . "\n");
    exit($code);
}

function arg(array $args, int $index, ?string $default = null): string
{
    if (!isset($args[$index]) || $args[$index] === '') {
        if ($default === null) {
            fail('missing argument #' . ($index + 1));
        }

        return $default;
    }

    return $args[$index];
}

function tsv(array $fields): string
{
    // "|" separated (NOT tab: bash "read" collapses consecutive tabs = empty fields get lost)
    return implode('|', array_map(static function ($v) {
        return str_replace(['|', "\t", "\n", "\r"], '/', (string) $v);
    }, $fields));
}

function strip_cr(string $content): string
{
    return str_replace("\r", '', $content);
}

function rrmdir(string $dir): void
{
    if (!is_dir($dir)) {
        return;
    }
    $it = new RecursiveIteratorIterator(
        new RecursiveDirectoryIterator($dir, FilesystemIterator::SKIP_DOTS),
        RecursiveIteratorIterator::CHILD_FIRST
    );
    foreach ($it as $file) {
        $file->isDir() && !$file->isLink() ? rmdir($file->getPathname()) : unlink($file->getPathname());
    }
    rmdir($dir);
}

function tmp_file(string $suffix = ''): string
{
    $file = tempnam(sys_get_temp_dir(), 'psu');
    if ($suffix !== '') {
        rename($file, $file . $suffix);
        $file .= $suffix;
    }

    return $file;
}

/* -------------------------------------------------------------------------
 * Minimal YAML reader (indentation walker) - enough for theme.yml
 * ---------------------------------------------------------------------- */

function yml_clean_value(string $value): string
{
    $value = trim($value);
    if ($value === '' || $value === '~' || strtolower($value) === 'null') {
        return '';
    }
    if ($value[0] === '"' || $value[0] === "'") {
        $quote = $value[0];
        $end = strpos($value, $quote, 1);

        return $end === false ? substr($value, 1) : substr($value, 1, $end - 1);
    }
    $hash = strpos($value, ' #');
    if ($hash !== false) {
        $value = trim(substr($value, 0, $hash));
    }

    return $value;
}

/**
 * Returns ['scalar' => string|null, 'list' => string[]] for a dotted key.
 */
function yml_get(string $text, string $dottedKey): array
{
    $lines = preg_split('/\r\n|\r|\n/', $text);
    $keys = explode('.', $dottedKey);
    $start = 0;
    $end = count($lines);
    $parentIndent = -1;
    $found = null;

    foreach ($keys as $key) {
        $found = null;
        $childIndent = null;
        for ($i = $start; $i < $end; ++$i) {
            $line = $lines[$i];
            if (trim($line) === '' || preg_match('/^\s*#/', $line)) {
                continue;
            }
            $indent = strlen($line) - strlen(ltrim($line, ' '));
            if ($indent <= $parentIndent) {
                break;
            }
            if ($childIndent === null) {
                $childIndent = $indent;
            }
            if ($indent !== $childIndent) {
                continue;
            }
            if (preg_match('/^\s*' . preg_quote($key, '/') . '\s*:(?:\s+(.*))?$/', $line, $m)) {
                $blockEnd = $end;
                for ($j = $i + 1; $j < $end; ++$j) {
                    $l = $lines[$j];
                    if (trim($l) === '' || preg_match('/^\s*#/', $l)) {
                        continue;
                    }
                    $ind = strlen($l) - strlen(ltrim($l, ' '));
                    if ($ind <= $indent && !preg_match('/^\s*-\s/', $l)) {
                        $blockEnd = $j;
                        break;
                    }
                    if ($ind < $indent) {
                        $blockEnd = $j;
                        break;
                    }
                }
                $found = ['line' => $i, 'indent' => $indent, 'value' => $m[1] ?? '', 'end' => $blockEnd];
                break;
            }
        }
        if ($found === null) {
            return ['scalar' => null, 'list' => []];
        }
        $start = $found['line'] + 1;
        $end = $found['end'];
        $parentIndent = $found['indent'];
    }

    $list = [];
    for ($i = $start; $i < $end; ++$i) {
        if (preg_match('/^\s*-\s+(.*)$/', $lines[$i], $m)) {
            $item = yml_clean_value($m[1]);
            if ($item !== '' && strpos($item, ': ') === false) {
                $list[] = $item;
            }
        }
    }

    return ['scalar' => yml_clean_value($found['value']), 'list' => $list];
}

function theme_info_from_yml(string $yml): array
{
    return [
        'name' => (string) yml_get($yml, 'name')['scalar'],
        'display_name' => (string) yml_get($yml, 'display_name')['scalar'],
        'version' => (string) yml_get($yml, 'version')['scalar'],
        'parent' => (string) yml_get($yml, 'parent')['scalar'],
        'from' => (string) yml_get($yml, 'meta.compatibility.from')['scalar'],
        'to' => (string) yml_get($yml, 'meta.compatibility.to')['scalar'],
        'modules' => implode(' ', yml_get($yml, 'dependencies.modules')['list']),
    ];
}

/* -------------------------------------------------------------------------
 * ZIP helpers
 * ---------------------------------------------------------------------- */

function psu_zip_open(string $file): ZipArchive
{
    if (!class_exists('ZipArchive')) {
        fail('PHP extension "zip" is not available for this PHP binary');
    }
    $zip = new ZipArchive();
    $res = $zip->open($file);
    if ($res !== true) {
        fail('cannot open zip ' . $file . ' (code ' . $res . ')');
    }

    return $zip;
}

/** Copies a zip entry to a file without loading it fully into memory. */
function psu_zip_entry_to_file(ZipArchive $zip, string $entry, string $target): bool
{
    $in = $zip->getStream($entry);
    if ($in === false) {
        return false;
    }
    $out = fopen($target, 'wb');
    stream_copy_to_stream($in, $out);
    fclose($in);
    fclose($out);

    return true;
}

/** Returns the path of the inner "prestashop.zip" (temp file) or the zip itself. */
function release_inner_zip(string $releaseZip, ?bool &$isTemp = null): string
{
    $zip = psu_zip_open($releaseZip);
    $isTemp = false;
    if ($zip->locateName('prestashop.zip') !== false) {
        $tmp = tmp_file('.zip');
        psu_zip_entry_to_file($zip, 'prestashop.zip', $tmp);
        $zip->close();
        $isTemp = true;

        return $tmp;
    }
    $zip->close();

    return $releaseZip;
}

function ps_version_from_source(string $content): string
{
    if (preg_match('/const\s+VERSION\s*=\s*[\'"]([0-9][^\'"]*)[\'"]/', $content, $m)) {
        return $m[1];
    }
    if (preg_match('/_PS_VERSION_[\'"]\s*,\s*[\'"]([0-9][^\'"]*)[\'"]/', $content, $m)) {
        return $m[1];
    }

    return '';
}

/* -------------------------------------------------------------------------
 * Release API helpers (api.prestashop-project.org)
 * ---------------------------------------------------------------------- */

function load_json_file(string $file)
{
    $data = json_decode((string) @file_get_contents($file), true);
    if ($data === null) {
        fail('invalid JSON in ' . $file);
    }

    return $data;
}

function release_rows(array $data, bool $includePre): array
{
    $rows = [];
    foreach ($data as $r) {
        if (empty($r['version']) || empty($r['zip_download_url']) || empty($r['xml_download_url'])) {
            continue;
        }
        $stability = $r['stability'] ?? 'stable';
        if (!$includePre && $stability !== 'stable') {
            continue;
        }
        $version = $r['version'];
        $dist = (string) ($r['distribution_version'] ?? '');
        if (isset($rows[$version]) && version_compare($rows[$version]['dist'] ?: '0', $dist ?: '0', '>=')) {
            continue;
        }
        $rows[$version] = [
            'version' => $version,
            'distribution' => $r['distribution'] ?? '',
            'dist' => $dist,
            'php_min' => $r['php_min_version'] ?? '',
            'php_max' => $r['php_max_version'] ?? '',
            'stability' => $stability,
            'zip' => $r['zip_download_url'],
            'xml' => $r['xml_download_url'],
            'md5' => $r['zip_md5'] ?? '',
            'notes' => $r['release_notes_url'] ?? '',
        ];
    }
    uksort($rows, 'version_compare');

    return $rows;
}

function release_tsv(array $row): string
{
    return tsv([
        $row['version'], $row['distribution'], $row['dist'], $row['php_min'], $row['php_max'],
        $row['stability'], $row['zip'], $row['xml'], $row['md5'], $row['notes'],
    ]);
}

/* -------------------------------------------------------------------------
 * Checksum XML helpers
 * ---------------------------------------------------------------------- */

function xml_walk(SimpleXMLElement $node, string $prefix, array &$files): void
{
    foreach ($node->children() as $child) {
        $name = (string) $child['name'];
        if ($child->getName() === 'dir') {
            xml_walk($child, $prefix . $name . '/', $files);
        } elseif ($child->getName() === 'md5file') {
            $files[$prefix . $name] = trim((string) $child);
        }
    }
}

function xml_files(string $xmlFile): array
{
    $xml = @simplexml_load_file($xmlFile);
    if ($xml === false || !isset($xml->ps_root_dir)) {
        fail('invalid checksum XML ' . $xmlFile);
    }
    $files = [];
    xml_walk($xml->ps_root_dir, '', $files);

    return $files;
}

/* -------------------------------------------------------------------------
 * Token based class analysis (for override reports)
 * ---------------------------------------------------------------------- */

function name_token_ids(): array
{
    $ids = [T_STRING];
    foreach (['T_NAME_QUALIFIED', 'T_NAME_FULLY_QUALIFIED'] as $const) {
        if (defined($const)) {
            $ids[] = constant($const);
        }
    }

    return $ids;
}

function token_text($t): string
{
    return is_array($t) ? $t[1] : $t;
}

function canonical(array $tokens): string
{
    $parts = [];
    foreach ($tokens as $t) {
        if (is_array($t) && in_array($t[0], [T_WHITESPACE, T_COMMENT, T_DOC_COMMENT], true)) {
            continue;
        }
        $parts[] = token_text($t);
    }

    return implode(' ', $parts);
}

/**
 * Returns [className => ['parent' => ..., 'modifiers' => ..., 'methods' => [name => [sig, body]], 'props' => [name => hash]]].
 */
function analyze_classes(string $code): array
{
    $tokens = token_get_all($code);
    $count = count($tokens);
    $classes = [];
    $depth = 0;
    $current = null;
    $classDepth = null;
    $modifiers = [];

    for ($i = 0; $i < $count; ++$i) {
        $t = $tokens[$i];
        $id = is_array($t) ? $t[0] : null;
        $text = token_text($t);

        if ($id === T_CLASS && $current === null) {
            // Skip "::class" and anonymous classes ("new class")
            $prev = $i - 1;
            while ($prev >= 0 && is_array($tokens[$prev]) && $tokens[$prev][0] === T_WHITESPACE) {
                --$prev;
            }
            if ($prev >= 0 && (token_text($tokens[$prev]) === '::' || (is_array($tokens[$prev]) && $tokens[$prev][0] === T_NEW))) {
                continue;
            }
            $classModifiers = [];
            $p = $prev;
            while ($p >= 0 && is_array($tokens[$p]) && in_array($tokens[$p][0], [T_ABSTRACT, T_FINAL, T_WHITESPACE], true)) {
                if ($tokens[$p][0] !== T_WHITESPACE) {
                    $classModifiers[] = strtolower($tokens[$p][1]);
                }
                --$p;
            }
            $name = null;
            $parent = '';
            for ($j = $i + 1; $j < $count; ++$j) {
                $tj = $tokens[$j];
                if ($name === null && is_array($tj) && $tj[0] === T_STRING) {
                    $name = $tj[1];
                } elseif (is_array($tj) && $tj[0] === T_EXTENDS) {
                    for ($k = $j + 1; $k < $count; ++$k) {
                        if (is_array($tokens[$k]) && in_array($tokens[$k][0], name_token_ids(), true)) {
                            $parent = ltrim($tokens[$k][1], '\\');
                            break;
                        }
                    }
                } elseif ($tj === '{') {
                    break;
                }
            }
            if ($name === null) {
                continue;
            }
            $current = $name;
            $classes[$current] = ['parent' => $parent, 'modifiers' => implode(' ', $classModifiers), 'methods' => [], 'props' => []];
            $classDepth = $depth;
            $modifiers = [];
            continue;
        }

        if ($text === '{' || $id === T_CURLY_OPEN || $id === T_DOLLAR_OPEN_CURLY_BRACES) {
            ++$depth;
            if ($current !== null && $depth === $classDepth + 1) {
                $modifiers = [];
            }
            continue;
        }
        if ($text === '}') {
            --$depth;
            if ($current !== null && $depth === $classDepth) {
                $current = null;
                $classDepth = null;
            }
            $modifiers = [];
            continue;
        }

        if ($current === null || $depth !== $classDepth + 1) {
            continue;
        }

        if ($text === ';') {
            $modifiers = [];
            continue;
        }
        if (is_array($t) && in_array($id, [T_PUBLIC, T_PROTECTED, T_PRIVATE, T_STATIC, T_FINAL, T_ABSTRACT, T_VAR], true)) {
            $modifiers[] = strtolower($text);
            continue;
        }

        if ($id === T_FUNCTION) {
            $sigTokens = [];
            $name = null;
            $j = $i + 1;
            for (; $j < $count; ++$j) {
                $tj = $tokens[$j];
                $txt = token_text($tj);
                if ($txt === '{' || $txt === ';') {
                    break;
                }
                if ($name === null && is_array($tj) && $tj[0] !== T_WHITESPACE && $txt !== '&') {
                    $name = $txt;
                }
                $sigTokens[] = $tj;
            }
            $body = '';
            if ($j < $count && token_text($tokens[$j]) === '{') {
                $bodyTokens = [];
                $level = 0;
                for ($k = $j; $k < $count; ++$k) {
                    $tk = $tokens[$k];
                    $txt = token_text($tk);
                    if ($txt === '{' || (is_array($tk) && in_array($tk[0], [T_CURLY_OPEN, T_DOLLAR_OPEN_CURLY_BRACES], true))) {
                        ++$level;
                    } elseif ($txt === '}') {
                        --$level;
                    }
                    $bodyTokens[] = $tk;
                    if ($level === 0) {
                        break;
                    }
                }
                $body = md5(canonical($bodyTokens));
                $i = $k;
            } else {
                $i = $j;
            }
            if ($name !== null) {
                sort($modifiers);
                $sig = trim(implode(' ', $modifiers) . ' function ' . canonical($sigTokens));
                $classes[$current]['methods'][strtolower($name)] = [
                    'name' => $name,
                    'sig' => $sig,
                    'body' => $body,
                    'struct' => sig_structure($modifiers, $sigTokens),
                ];
            }
            $modifiers = [];
            continue;
        }

        if ($id === T_VARIABLE && !empty($modifiers)) {
            $valueTokens = [];
            for ($j = $i; $j < $count; ++$j) {
                if (token_text($tokens[$j]) === ';') {
                    break;
                }
                $valueTokens[] = $tokens[$j];
            }
            $classes[$current]['props'][$text] = md5(canonical($valueTokens));
            $i = $j;
            $modifiers = [];
            continue;
        }
    }

    return $classes;
}

/** Normalizes a type declaration: no spaces, no leading "\", lower-case (class names are case-insensitive). */
function norm_type(string $type): string
{
    $type = strtolower(str_replace([' ', '\\'], '', $type));

    return $type;
}

/**
 * Structured signature from the modifier list and the tokens after "function":
 * ['static' => bool, 'vis' => string, 'params' => [['type','optional','variadic','byref']], 'return' => string]
 */
function sig_structure(array $modifiers, array $sigTokens): array
{
    $tokens = array_values(array_filter($sigTokens, static function ($t) {
        return !(is_array($t) && in_array($t[0], [T_WHITESPACE, T_COMMENT, T_DOC_COMMENT], true));
    }));
    $vis = 'public';
    foreach (['private', 'protected', 'public'] as $v) {
        if (in_array($v, $modifiers, true)) {
            $vis = $v;
        }
    }
    $struct = ['static' => in_array('static', $modifiers, true), 'vis' => $vis, 'params' => [], 'return' => '', 'return_raw' => ''];

    $count = count($tokens);
    $i = 0;
    while ($i < $count && token_text($tokens[$i]) !== '(') {
        ++$i;
    }
    $depth = 0;
    $current = [];
    $paramsTokens = [];
    for (; $i < $count; ++$i) {
        $txt = token_text($tokens[$i]);
        if ($txt === '(' || $txt === '[') {
            ++$depth;
            if ($depth === 1 && $txt === '(') {
                continue;
            }
        } elseif ($txt === ')' || $txt === ']') {
            --$depth;
            if ($depth === 0) {
                if ($current) {
                    $paramsTokens[] = $current;
                }
                ++$i;
                break;
            }
        } elseif ($txt === ',' && $depth === 1) {
            $paramsTokens[] = $current;
            $current = [];
            continue;
        }
        $current[] = $tokens[$i];
    }
    // return type
    if ($i < $count && token_text($tokens[$i]) === ':') {
        $ret = '';
        for (++$i; $i < $count; ++$i) {
            $ret .= token_text($tokens[$i]);
        }
        $struct['return'] = norm_type($ret);
        $struct['return_raw'] = $ret;
    }

    foreach ($paramsTokens as $pt) {
        $type = '';
        $optional = false;
        $variadic = false;
        $byref = false;
        $seenVar = false;
        $default = '';
        foreach ($pt as $t) {
            $txt = token_text($t);
            if (!$seenVar) {
                if (is_array($t) && $t[0] === T_VARIABLE) {
                    $seenVar = true;
                } elseif ($txt === '&') {
                    $byref = true;
                } elseif (is_array($t) && $t[0] === T_ELLIPSIS) {
                    $variadic = true;
                } elseif (!(is_array($t) && in_array($t[0], [T_PUBLIC, T_PROTECTED, T_PRIVATE], true))) {
                    $type .= $txt;
                }
            } elseif ($txt === '=') {
                $optional = true;
            } elseif ($optional) {
                $default .= $txt;
            }
        }
        $type = norm_type($type);
        // implicit nullable: "Type $x = null" is "?Type $x = null"
        if ($type !== '' && strtolower($default) === 'null' && $type[0] !== '?'
            && strpos($type, '|') === false && !in_array($type, ['mixed', 'null'], true)) {
            $type = '?' . $type;
        }
        $struct['params'][] = ['type' => $type, 'optional' => $optional || $variadic, 'variadic' => $variadic, 'byref' => $byref];
    }

    return $struct;
}

/** Structural equality (ignores parameter names and default values). */
function sig_equal(array $a, array $b): bool
{
    if ($a['static'] !== $b['static'] || $a['vis'] !== $b['vis'] || $a['return'] !== $b['return'] || count($a['params']) !== count($b['params'])) {
        return false;
    }
    foreach ($a['params'] as $i => $p) {
        $q = $b['params'][$i];
        if ($p['type'] !== $q['type'] || $p['optional'] !== $q['optional'] || $p['variadic'] !== $q['variadic'] || $p['byref'] !== $q['byref']) {
            return false;
        }
    }

    return true;
}

/**
 * Is the child (override) signature compatible with the parent (core) signature (PHP inheritance rules,
 * simplified)? Returns a list of problems (empty = compatible).
 */
function sig_problems(array $child, array $parent): array
{
    $problems = [];
    $rank = ['private' => 0, 'protected' => 1, 'public' => 2];
    if ($child['static'] !== $parent['static']) {
        $problems[] = $parent['static'] ? 'Core-Methode ist jetzt static' : 'Core-Methode ist nicht mehr static';
    }
    if ($parent['vis'] !== 'private' && $rank[$child['vis']] < $rank[$parent['vis']]) {
        $problems[] = 'Sichtbarkeit enger als im Core (' . $parent['vis'] . ')';
    }
    $childVariadic = !empty($child['params']) && end($child['params'])['variadic'];
    foreach ($parent['params'] as $i => $pp) {
        if (!isset($child['params'][$i])) {
            if (!$childVariadic) {
                $problems[] = 'Parameter #' . ($i + 1) . ' fehlt im Override';
            }
            continue;
        }
        $cp = $child['params'][$i];
        if ($pp['optional'] && !$cp['optional']) {
            $problems[] = 'Parameter #' . ($i + 1) . ' ist im Core optional, im Override Pflicht';
        }
        if ($cp['type'] !== '' && $cp['type'] !== $pp['type'] && $cp['type'] !== '?' . ltrim($pp['type'], '?') && $cp['type'] !== 'mixed') {
            $problems[] = 'Parametertyp #' . ($i + 1) . ': Override "' . $cp['type'] . '" / Core "' . ($pp['type'] ?: 'ohne') . '"';
        }
    }
    foreach ($child['params'] as $i => $cp) {
        if (!isset($parent['params'][$i]) && !$cp['optional']) {
            $problems[] = 'Zusätzlicher Pflicht-Parameter #' . ($i + 1) . ' im Override';
        }
    }
    if ($parent['return'] !== '') {
        if ($child['return'] === '') {
            $problems[] = 'Rückgabetyp ": ' . $parent['return_raw'] . '" fehlt im Override';
        } elseif ($child['return'] !== $parent['return'] && $parent['return'] !== 'mixed') {
            $problems[] = 'Rückgabetyp: Override "' . $child['return'] . '" / Core "' . $parent['return'] . '"';
        }
    }

    return $problems;
}

/** Builds a map "ClassName" => file for all "class XxxCore" declarations below the given dirs. */
function core_class_map(string $root, array $subDirs): array
{
    $map = [];
    foreach ($subDirs as $sub) {
        $dir = rtrim($root, '/') . '/' . $sub;
        if (!is_dir($dir)) {
            continue;
        }
        $it = new RecursiveIteratorIterator(new RecursiveDirectoryIterator($dir, FilesystemIterator::SKIP_DOTS));
        foreach ($it as $file) {
            if ($file->getExtension() !== 'php') {
                continue;
            }
            $content = (string) @file_get_contents($file->getPathname());
            if (preg_match_all('/^\s*(?:abstract\s+|final\s+)*class\s+(\w+)Core\b/mi', $content, $m)) {
                foreach ($m[1] as $class) {
                    $map[strtolower($class)] = $file->getPathname();
                }
            }
        }
    }

    return $map;
}

function class_from_file(?string $file, string $className): ?array
{
    if ($file === null || !is_file($file)) {
        return null;
    }
    $classes = analyze_classes((string) file_get_contents($file));
    foreach ($classes as $name => $info) {
        if (strcasecmp($name, $className) === 0) {
            return $info;
        }
    }

    return null;
}

function module_info_from_source(string $content): array
{
    $info = ['version' => '', 'min' => '', 'max' => ''];
    if (preg_match('/\$this->version\s*=\s*[\'"]([^\'"]+)[\'"]/', $content, $m)) {
        $info['version'] = $m[1];
    }
    if (preg_match('/ps_versions_compliancy\s*=\s*(?:array\s*\(|\[)(.*?)(?:\)|\])\s*;/s', $content, $m)) {
        $block = $m[1];
        foreach (['min', 'max'] as $key) {
            if (preg_match('/[\'"]' . $key . '[\'"]\s*=>\s*(?:[\'"]([^\'"]+)[\'"]|(_PS_VERSION_))/', $block, $mm)) {
                $info[$key] = !empty($mm[2]) ? '_PS_VERSION_' : $mm[1];
            }
        }
    }

    return $info;
}

/* -------------------------------------------------------------------------
 * Commands
 * ---------------------------------------------------------------------- */

switch ($command) {
    case 'vercmp':
        // vercmp <a> <op> <b>  -> exit 0 if true
        exit(version_compare(arg($args, 0), arg($args, 2), arg($args, 1)) ? 0 : 1);

    case 'sortver':
        // Sorts stdin lines by their first (tab separated) field as version, ascending.
        $lines = array_filter(array_map('rtrim', file('php://stdin')), 'strlen');
        usort($lines, static function ($a, $b) {
            return version_compare(explode("\t", $a)[0], explode("\t", $b)[0]);
        });
        foreach ($lines as $line) {
            out($line);
        }
        break;

    case 'theme-info':
        // theme-info <theme.yml | theme.zip>
        $source = arg($args, 0);
        if (preg_match('/\.zip$/i', $source)) {
            $zip = psu_zip_open($source);
            $yml = $zip->getFromName('config/theme.yml');
            $zip->close();
            if ($yml === false) {
                fail('no config/theme.yml in ' . $source);
            }
        } else {
            $yml = (string) @file_get_contents($source);
        }
        foreach (theme_info_from_yml($yml) as $k => $v) {
            out($k . '=' . $v);
        }
        break;

    case 'releases':
        // releases <api.json> [include_pre=0] [greater_than_version]
        $rows = release_rows(load_json_file(arg($args, 0)), arg($args, 1, '0') === '1');
        $greater = $args[2] ?? '';
        foreach ($rows as $row) {
            if ($greater !== '' && !version_compare($row['version'], $greater, '>')) {
                continue;
            }
            out(release_tsv($row));
        }
        break;

    case 'release-info':
        // release-info <api.json> <version>
        $rows = release_rows(load_json_file(arg($args, 0)), true);
        $version = arg($args, 1);
        if (!isset($rows[$version])) {
            exit(1);
        }
        out(release_tsv($rows[$version]));
        break;

    case 'autoupgrade-info':
        // autoupgrade-info <autoupgrade.json> <current_ps_version>
        $data = load_json_file(arg($args, 0));
        $ps = arg($args, 1);
        foreach ($data['prestashop'] ?? [] as $range) {
            if (version_compare($ps, $range['prestashop_min'], '>=') && version_compare($ps, $range['prestashop_max'], '<=')) {
                $rec = $range['autoupgrade_recommended'] ?? [];
                out(tsv([$rec['last_version'] ?? '', $rec['download']['link'] ?? '', $rec['download']['md5'] ?? '']));
                exit(0);
            }
        }
        exit(1);

    case 'xml-version':
        $xml = @simplexml_load_file(arg($args, 0));
        if ($xml === false || !isset($xml->ps_root_dir)) {
            exit(1);
        }
        out((string) $xml->ps_root_dir['version']);
        break;

    case 'xml-dirs':
        // xml-dirs <xml> <subdir>  -> first level directory names below subdir
        $prefix = rtrim(arg($args, 1), '/') . '/';
        $dirs = [];
        foreach (array_keys(xml_files(arg($args, 0))) as $path) {
            if (strpos($path, $prefix) === 0) {
                $rest = substr($path, strlen($prefix));
                if (strpos($rest, '/') !== false) {
                    $dirs[explode('/', $rest)[0]] = true;
                }
            }
        }
        ksort($dirs);
        foreach (array_keys($dirs) as $d) {
            out($d);
        }
        break;

    case 'zip-ps-version':
        // zip-ps-version <release.zip>
        $inner = release_inner_zip(arg($args, 0), $isTemp);
        $zip = psu_zip_open($inner);
        $version = '';
        foreach (['src/Core/Version.php', 'app/AppKernel.php', 'config/settings.inc.php'] as $candidate) {
            $content = $zip->getFromName($candidate);
            if ($content !== false && ($version = ps_version_from_source($content)) !== '') {
                break;
            }
        }
        $hasVendor = $zip->locateName('vendor/autoload.php') !== false;
        $zip->close();
        if ($isTemp) {
            unlink($inner);
        }
        out(tsv([$version, $hasVendor ? 'vendor' : 'novendor']));
        exit($version === '' ? 1 : 0);

    case 'release-extract':
        // release-extract <release.zip> <dest> <prefix>...  (extracts matching entries of the inner prestashop.zip)
        $dest = rtrim(arg($args, 1), '/');
        $prefixes = array_slice($args, 2);
        $inner = release_inner_zip(arg($args, 0), $isTemp);
        $zip = psu_zip_open($inner);
        $entries = [];
        for ($i = 0; $i < $zip->numFiles; ++$i) {
            $name = $zip->getNameIndex($i);
            foreach ($prefixes as $p) {
                if (strpos($name, $p) === 0) {
                    $entries[] = $name;
                    break;
                }
            }
        }
        if (!is_dir($dest)) {
            mkdir($dest, 0775, true);
        }
        if ($entries && !$zip->extractTo($dest, $entries)) {
            fail('extraction failed');
        }
        $zip->close();
        if ($isTemp) {
            unlink($inner);
        }
        out((string) count($entries));
        break;

    case 'zip-extract':
        // zip-extract <zip> <dest>
        $zip = psu_zip_open(arg($args, 0));
        $dest = arg($args, 1);
        if (!is_dir($dest)) {
            mkdir($dest, 0775, true);
        }
        if (!$zip->extractTo($dest)) {
            fail('extraction failed');
        }
        $zip->close();
        break;

    case 'integrity':
        // integrity <xml> <root> <admin_dir>  -> "MODIFIED|MISSING<TAB>path" (EOL-only differences are ignored)
        $root = rtrim(arg($args, 1), '/');
        $adminDir = arg($args, 2);
        $total = 0;
        $eolOnly = 0;
        foreach (xml_files(arg($args, 0)) as $path => $md5) {
            $local = preg_replace('#^admin/#', $adminDir . '/', $path);
            ++$total;
            $file = $root . '/' . $local;
            if (!is_file($file)) {
                out(tsv(['MISSING', $local]));
                continue;
            }
            if (md5_file($file) === $md5) {
                continue;
            }
            $content = (string) file_get_contents($file);
            $lf = strip_cr($content);
            if (md5($lf) === $md5 || md5(str_replace("\n", "\r\n", $lf)) === $md5) {
                ++$eolOnly;
                continue;
            }
            out(tsv(['MODIFIED', $local]));
        }
        out(tsv(['TOTAL', $total]));
        out(tsv(['EOL_ONLY', $eolOnly]));
        break;

    case 'override-report':
        // override-report <root> <new_core_dir>
        $root = rtrim(arg($args, 0), '/');
        $newRoot = rtrim(arg($args, 1), '/');
        $oldMap = core_class_map($root, ['classes', 'controllers']);
        $newMap = core_class_map($newRoot, ['classes', 'controllers']);
        $overrideDir = $root . '/override';
        if (!is_dir($overrideDir)) {
            break;
        }
        $it = new RecursiveIteratorIterator(new RecursiveDirectoryIterator($overrideDir, FilesystemIterator::SKIP_DOTS));
        $files = [];
        foreach ($it as $file) {
            $files[] = $file->getPathname();
        }
        sort($files);

        // Pass 1: which file declares which override class (XyzCore parent)?
        $parsed = [];
        $owners = [];
        foreach ($files as $path) {
            $rel = str_replace('\\', '/', substr($path, strlen($root) + 1));
            $base = basename($path);
            if ($base === 'index.php' || $base === '.htaccess' || $base === '_do_not_remove') {
                continue;
            }
            if (strpos($rel, 'override/modules/') === 0) {
                out(tsv(['MODULE', $rel, '', '', substr($path, -4) === '.php' ? 'Modul-Controller-Override' : 'kein .php (wird ignoriert)']));
                continue;
            }
            if (substr($path, -4) !== '.php') {
                out(tsv(['IGNORED', $rel, '', '', 'kein .php (wird von PrestaShop ignoriert)']));
                continue;
            }
            $classes = analyze_classes((string) file_get_contents($path));
            $overrideClasses = [];
            foreach ($classes as $className => $info) {
                if (strcasecmp($info['parent'], $className . 'Core') === 0) {
                    $overrideClasses[$className] = $info;
                    $owners[strtolower($className)][] = $rel;
                }
            }
            if (!$overrideClasses) {
                $coreCopies = array_filter(array_keys($classes), static function ($c) {
                    return substr($c, -4) === 'Core';
                });
                out(tsv(['NOCLASS', $rel, '', '', $coreCopies
                    ? 'deklariert die Core-Klasse ' . implode(', ', $coreCopies) . ' selbst (Kopie des Cores?) – manuell prüfen'
                    : 'keine Override-Klasse (class X extends XCore) gefunden']));
                continue;
            }
            $parsed[$rel] = $overrideClasses;
        }

        // PrestaShop indexes only ONE file per class: prefer "<Class>.php", else the last one found
        $active = [];
        foreach ($owners as $key => $relFiles) {
            $chosen = end($relFiles);
            foreach ($relFiles as $candidate) {
                if (strcasecmp(basename($candidate, '.php'), $key) === 0) {
                    $chosen = $candidate;
                }
            }
            $active[$key] = $chosen;
            foreach ($relFiles as $candidate) {
                if ($candidate !== $chosen) {
                    out(tsv(['DUPLICATE', $candidate, '', '', 'deklariert dieselbe Override-Klasse wie ' . $chosen . ' – PrestaShop nutzt nur eine Datei, bitte entfernen']));
                }
            }
        }

        // Pass 2: compare the active override classes with old/new core
        foreach ($parsed as $rel => $overrideClasses) {
            foreach ($overrideClasses as $className => $info) {
                $key = strtolower($className);
                if ($active[$key] !== $rel) {
                    continue;
                }
                $old = class_from_file($oldMap[$key] ?? null, $className . 'Core');
                $new = class_from_file($newMap[$key] ?? null, $className . 'Core');
                if ($old === null) {
                    out(tsv(['CORE_NOT_FOUND', $rel, $className, '', 'Core-Klasse ' . $className . 'Core nicht gefunden']));
                    continue;
                }
                if ($new === null) {
                    out(tsv(['CLASS_REMOVED', $rel, $className, '', 'Core-Klasse ' . $className . 'Core existiert in der Zielversion nicht mehr']));
                    continue;
                }
                if ($old['modifiers'] !== $new['modifiers']) {
                    out(tsv(['SIG', $rel, $className, '(class)', 'Klassen-Modifier: "' . $old['modifiers'] . '" -> "' . $new['modifiers'] . '"']));
                }
                foreach ($info['methods'] as $mKey => $m) {
                    $o = $old['methods'][$mKey] ?? null;
                    $n = $new['methods'][$mKey] ?? null;
                    if ($o === null && $n === null) {
                        out(tsv(['NEW_METHOD', $rel, $className, $m['name'], 'eigene Methode (nicht im Core)']));
                    } elseif ($o === null) {
                        $problems = sig_problems($m['struct'], $n['struct']);
                        out(tsv([$problems ? 'SIG' : 'CHANGED', $rel, $className, $m['name'],
                            'Methode ist NEU im Core der Zielversion (' . $n['sig'] . ')' . ($problems ? ': ' . implode('; ', $problems) : ' – Override kompatibel')]));
                    } elseif ($n === null) {
                        out(tsv(['REMOVED', $rel, $className, $m['name'], 'Methode existiert im Core der Zielversion nicht mehr']));
                    } elseif (!sig_equal($o['struct'], $n['struct'])) {
                        $problems = sig_problems($m['struct'], $n['struct']);
                        if ($problems) {
                            out(tsv(['SIG', $rel, $className, $m['name'], implode('; ', $problems) . '  [Core NEU: ' . $n['sig'] . ']']));
                        } else {
                            out(tsv(['CHANGED', $rel, $className, $m['name'], 'Signatur im Core geaendert, Override bleibt kompatibel'
                                . ($o['body'] !== $n['body'] ? '; Core-Implementierung geaendert' : '')]));
                        }
                    } elseif ($o['body'] !== $n['body']) {
                        out(tsv(['CHANGED', $rel, $className, $m['name'], 'Core-Implementierung geaendert']));
                    } else {
                        out(tsv(['OK', $rel, $className, $m['name'], 'unveraendert']));
                    }
                }
                foreach ($info['props'] as $prop => $hash) {
                    $o = $old['props'][$prop] ?? null;
                    $n = $new['props'][$prop] ?? null;
                    if ($o === null) {
                        continue;
                    }
                    if ($n === null) {
                        out(tsv(['PROP_REMOVED', $rel, $className, $prop, 'Property existiert im Core der Zielversion nicht mehr']));
                    } elseif ($o !== $n) {
                        out(tsv(['PROP_CHANGED', $rel, $className, $prop, 'Property-Definition im Core geaendert']));
                    }
                }
            }
        }
        break;

    case 'module-info':
        // module-info <modules/x/x.php>
        $content = (string) @file_get_contents(arg($args, 0));
        foreach (module_info_from_source($content) as $k => $v) {
            out($k . '=' . $v);
        }
        break;

    case 'theme-index':
        // theme-index <themes_dir> <cache_dir> <index_file>
        // index line: sha256 TAB type TAB name TAB version TAB from TAB to TAB cachefile TAB source
        $themesDir = rtrim(arg($args, 0), '/');
        $cacheDir = rtrim(arg($args, 1), '/');
        $indexFile = arg($args, 2);
        if (!is_dir($cacheDir)) {
            mkdir($cacheDir, 0775, true);
        }
        $index = [];
        if (is_file($indexFile)) {
            foreach (file($indexFile, FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES) as $line) {
                $f = explode('|', $line);
                if (count($f) >= 8 && is_file($f[6])) {
                    $index[$f[0]][] = $f;
                }
            }
        }
        $classify = static function (string $zipFile) {
            $zip = new ZipArchive();
            if ($zip->open($zipFile) !== true) {
                return null;
            }
            $yml = $zip->getFromName('config/theme.yml');
            if ($yml !== false) {
                $zip->close();
                $info = theme_info_from_yml($yml);

                return ['theme', $info['name'], $info['version'], $info['from'], $info['to']];
            }
            for ($i = 0; $i < $zip->numFiles; ++$i) {
                $name = $zip->getNameIndex($i);
                if (preg_match('#^([A-Za-z0-9_]+)/\1\.php$#', $name, $m)) {
                    $info = module_info_from_source((string) $zip->getFromIndex($i));
                    $zip->close();

                    return ['module', $m[1], $info['version'], $info['min'], $info['max']];
                }
            }
            $zip->close();

            return null;
        };
        $outerFiles = glob($themesDir . '/*.zip') ?: [];
        foreach ($outerFiles as $outer) {
            $sha = hash_file('sha256', $outer);
            if (isset($index[$sha])) {
                continue;
            }
            $index[$sha] = [];
            $register = static function (array $c, string $sourceZip, string $label) use (&$index, $sha, $cacheDir, $outer) {
                $target = $cacheDir . '/' . $c[0] . '-' . $c[1] . '-' . $c[2] . '.zip';
                if (!is_file($target)) {
                    copy($sourceZip, $target);
                }
                $index[$sha][] = [$sha, $c[0], $c[1], $c[2], $c[3], $c[4], $target, basename($outer) . ($label !== '' ? ' :: ' . $label : '')];
            };
            $c = $classify($outer);
            if ($c !== null) {
                $register($c, $outer, '');
                continue;
            }
            $zip = psu_zip_open($outer);
            for ($i = 0; $i < $zip->numFiles; ++$i) {
                $name = $zip->getNameIndex($i);
                if (!preg_match('/\.zip$/i', $name)) {
                    continue;
                }
                $tmp = tmp_file('.zip');
                if (psu_zip_entry_to_file($zip, $name, $tmp)) {
                    $c = $classify($tmp);
                    if ($c !== null) {
                        $register($c, $tmp, $name);
                    }
                }
                @unlink($tmp);
            }
            $zip->close();
        }
        $lines = [];
        foreach ($index as $entries) {
            foreach ($entries as $f) {
                $lines[] = tsv($f);
            }
        }
        file_put_contents($indexFile, $lines ? implode("\n", $lines) . "\n" : '');
        foreach ($lines as $line) {
            out($line);
        }
        break;

    case 'files-equal':
        // files-equal <a> <b>  -> exit 0 if equal ignoring CR
        $a = arg($args, 0);
        $b = arg($args, 1);
        if (!is_file($a) || !is_file($b)) {
            exit(2);
        }
        exit(strip_cr((string) file_get_contents($a)) === strip_cr((string) file_get_contents($b)) ? 0 : 1);

    case 'json-write':
        // json-write <file> key=value ...
        $file = arg($args, 0);
        $data = [];
        foreach (array_slice($args, 1) as $pair) {
            $pos = strpos($pair, '=');
            if ($pos === false) {
                continue;
            }
            $data[substr($pair, 0, $pos)] = substr($pair, $pos + 1);
        }
        file_put_contents($file, json_encode($data, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE) . "\n");
        break;

    case 'json-get':
        // json-get <file> <key>  (flat or dotted key)
        $data = load_json_file(arg($args, 0));
        foreach (explode('.', arg($args, 1)) as $k) {
            if (!is_array($data) || !array_key_exists($k, $data)) {
                exit(1);
            }
            $data = $data[$k];
        }
        out(is_array($data) ? implode(' ', $data) : (string) $data);
        break;

    case 'hash':
        // hash <algo> <file>
        out((string) hash_file(arg($args, 0), arg($args, 1)));
        break;

    default:
        out('Usage: php ps-tools.php <vercmp|sortver|theme-info|releases|release-info|autoupgrade-info|xml-version|xml-dirs|'
            . 'zip-ps-version|release-extract|zip-extract|integrity|override-report|module-info|theme-index|files-equal|'
            . 'json-write|json-get|hash> ...');
        exit($command === 'help' ? 0 : 1);
}
