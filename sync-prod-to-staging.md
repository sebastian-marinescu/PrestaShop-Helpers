# Staging Synchronization Guide (Production to Staging)

This guide describes how to configure and run the `sync-prod-to-staging.sh` script to synchronize your Staging environment with the Production environment on the same server.

## Features of the Script
1. **Dynamic Path Resolution**: Safely handles physical paths behind symlinks (like `/home/docutife/www/staging` and `production`).
2. **WIP Folder Protection**: Automatically compares staging/modules and production/modules. Any staging-only directories (e.g. `usm_configurator` or `smartblog`) are automatically backed up before the Git sync and restored afterward.
3. **Submodule Protection**: Leaves submodules completely untouched (preserves any local development inside submodules).
4. **Git Reset & Pull**: Force-resets all tracked files on Staging to match the Production `master` branch.
5. **Database Replication**: Backs up the old Staging database (saved in `helper/backups/`), dumps the Production database with automatic optimization (skipping heavy data for logs & statistics while keeping table structures), imports it, and updates shop URLs (`ps_shop_url` and `ps_configuration`). Keeps the 3 newest backups on Staging and cleans up older ones (>7 days).
6. **Zero-Transfer Image Fallback**: Automatically updates `.htaccess` on Staging to rewrite domain checks (`staging.betz-designmoebel.ch`), support clean product URLs (`235689-product...jpg`), and injects fallback redirects in `img/.htaccess`. Any missing product or CMS image automatically redirects on-the-fly to Production (`https://betz-designmoebel.ch/...`) without 403 Forbidden errors, saving gigabytes of disk space and sync time.
7. **Cache Cleansing**: Deletes PrestaShop's Symfony cache and triggers a PHP OPcache reset via HTTP curl.

---

## Instructions for Use on the Server

> [!WARNING]
> **Always run this script from the Staging helper directory** (`/home/www/staging/helper/`). Never run it from the Production helper directory, as the script loads the configuration and executes operations relative to its physical location.

### Step 1: Copy and Edit the Configuration
Connect via SSH to the server, navigate to this folder, and copy the template config:
```bash
cd /home/docutife/www/staging/helper
cp .env.example .env
```
Open `.env` and verify the settings. The default parameters are pre-configured for your Hostpoint setup:
* `SYNC_MODE=local`
* `PROD_DIR=/home/docutife/www/production`
* `STAGING_DIR=/home/docutife/www/staging`
* `PROD_DOMAIN=betz-designmoebel.ch`
* `STAGING_DOMAIN=staging.betz-designmoebel.ch`
* `AUTO_PRESERVE_STAGING_ONLY_MODULES=true`
* `SYNC_IMAGES=false` (highly recommended to keep it false to use Apache redirects and avoid heavy rsync transfers)

### Step 2: Make the Script Executable
Give the script execution permissions:
```bash
chmod +x sync-prod-to-staging.sh
```

### Step 3: Run a Dry Run (Safely Check Actions)
Before performing the sync, run the script with the `--dry-run` or `-d` flag. This will validate all files, paths, database credentials, list the modules it intends to preserve, and print the commands it *would* run:
```bash
./sync-prod-to-staging.sh --dry-run
```
Carefully check the output to ensure the paths and identified WIP modules are correct.

### Step 4: Perform the Sync
Run the script without flags to initiate the sync:
```bash
./sync-prod-to-staging.sh
```
Once it finishes, open the Staging website in your browser to verify that it is loading correctly, showing Production content, and displaying images via the rewrite fallback.
