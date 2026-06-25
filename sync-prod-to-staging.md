# Staging Synchronization Guide (Production to Staging)

This guide describes how to configure and run the `sync-prod-to-staging.sh` script to synchronize your Staging environment with the Production environment on the same server.

## Features of the Script
1. **Dynamic Path Resolution**: Safely handles physical paths behind symlinks (like `/home/docutife/www/staging` and `production`).
2. **WIP Folder Protection**: Automatically compares staging/modules and production/modules. Any staging-only directories (e.g. `usm_configurator` or `smartblog`) are automatically backed up before the Git sync and restored afterward.
3. **Submodule Protection**: Leaves submodules completely untouched (preserves any local development inside submodules).
4. **Git Reset & Pull**: Force-resets all tracked files on Staging to match the Production `master` branch.
5. **Database Replication**: Backs up the old Staging database (saved in `helper/backups/`), dumps the Production database, imports it, and automatically updates the PrestaShop shop URLs and domains (`ps_shop_url` and `ps_configuration`) to match Staging. Automatically keeps the 3 newest backups on Staging and cleans up older ones that are older than 7 days.
6. **Zero-Transfer Image Fallback**: Injects Apache Rewrite rules in Staging's `.htaccess`. If an image does not exist locally on Staging, the server redirects the browser to Production's image url (`https://betz-designmoebel.ch/img/...`) on-the-fly. This saves gigabytes of transfer and disk space.
7. **Cache Cleansing**: Deletes PrestaShop's Symfony cache and triggers a PHP OPcache reset via HTTP curl.

---

## Instructions for Use on the Server

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
