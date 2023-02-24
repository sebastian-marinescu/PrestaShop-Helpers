<?php
/**
 * PrestaShop Database Backup Script
 */

(PHP_SAPI !== 'cli' || isset($_SERVER['HTTP_USER_AGENT'])) && die('cli only');

if (!defined('_PS_DIR_')) {
    define('_PS_DIR_', getcwd());
}
include(_PS_DIR_.'/../config/config.inc.php');
include(_PS_DIR_.'/../classes/PrestaShopBackup.php');

$shop_ids = Shop::getCompleteListOfShopsID();
foreach ($shop_ids as $shop_id) {
    Shop::setContext(Shop::CONTEXT_SHOP, (int)$shop_id);
    
    $back = new PrestaShopBackup();
    $back->add();
}

