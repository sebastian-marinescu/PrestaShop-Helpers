# PrestaShop-Helpers
Some bash-scripts helping with PrestaShop-Migrations

## Overview

| Script | Purpose | Docs |
|---|---|---|
| `ps-upgrade.sh` | **PrestaShop Upgrade Toolkit**: checks & reports, backups (without `img/`), restore, maintenance mode and core upgrades via the official Update Assistant CLI | [ps-upgrade.md](ps-upgrade.md) |
| `ps-backup.sh` / `ps-restore.sh` | Shortcuts for `ps-upgrade.sh backup` / `ps-upgrade.sh restore` | [ps-upgrade.md](ps-upgrade.md#7-backup--restore) |
| `sync-prod-to-staging.sh` | Synchronizes Staging with Production (Git, database, assets, `vendor/`, `.htaccess` adaptations) | [sync-prod-to-staging.md](sync-prod-to-staging.md) |
| `env-check.php` | Token protected endpoint used by `ps-upgrade.sh` to read the web server's PHP version/extensions | [ps-upgrade.md](ps-upgrade.md#3-einrichtung--env) |
| `reset_opcache.php` | Resets the PHP OPcache of the web server (called by the scripts) | – |
| `backup.sh`, `backup-db.sh`, `backup-database.php` | Legacy backup helpers | – |
| `get-sql-migrations.sh`, `run-sql-migrations.sh` | Legacy SQL-only migrations (**deprecated**: skip the PHP upgrade callbacks – use `ps-upgrade.sh` instead) | – |
| `img-from-thumb.sh`, `test-mailer-2023.php` | Misc. legacy helpers | – |

Configuration for all scripts: copy `.env.example` to `.env`.
