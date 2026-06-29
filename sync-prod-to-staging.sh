#!/bin/bash

# ------------------------------------------------------------------------------
# PrestaShop Staging Synchronization Script
# Synchronizes Staging with Production on the same server.
# ------------------------------------------------------------------------------

# Set colors
RED='\033[0;31m'
GREEN='\033[0;32m'
ORANGE='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Determine script directory
DIR="${BASH_SOURCE%/*}"
if [[ ! -d "$DIR" ]]; then DIR="$PWD"; fi

# Import helpers if common.sh exists
if [ -f "$DIR/common.sh" ]; then
    . "$DIR/common.sh"
fi

# Load environment configuration
ENV_FILE="$DIR/.env"
if [ ! -f "$ENV_FILE" ]; then
    echo -e "${RED}[Error] Configuration file .env not found in helper submodule!${NC}"
    echo -e "Please copy .env.example to .env and configure it before running this script."
    exit 1
fi

. "$ENV_FILE"

# Parse arguments
DRY_RUN=false
for arg in "$@"; do
    if [ "$arg" == "--dry-run" ] || [ "$arg" == "-d" ]; then
        DRY_RUN=true
    fi
done

# Resolve absolute physical paths (dereferencing symlinks)
PROD_DIR_PHYS=$(readlink -f "$PROD_DIR")
STAGING_DIR_PHYS=$(readlink -f "$STAGING_DIR")
PRESERVE_TEMP_DIR="/home/docutife/www/staging_sync_preserve"

# Dry-run notification
if [ "$DRY_RUN" = true ]; then
    echo -e "${ORANGE}==================================================${NC}"
    echo -e "${ORANGE}             DRY-RUN MODE ENABLED                 ${NC}"
    echo -e "${ORANGE}       No changes will be written to disk/DB      ${NC}"
    echo -e "${ORANGE}==================================================${NC}"
fi

# 1. Validation Checks
echo -e "${BLUE}=== Running validation checks... ===${NC}"

if [ ! -d "$PROD_DIR_PHYS" ]; then
    echo -e "${RED}[Error] Production directory does not exist: $PROD_DIR_PHYS${NC}"
    exit 1
fi

if [ ! -d "$STAGING_DIR_PHYS" ]; then
    echo -e "${RED}[Error] Staging directory does not exist: $STAGING_DIR_PHYS${NC}"
    exit 1
fi

for cmd in mysql mysqldump rsync git php curl; do
    if ! command -v "$cmd" &> /dev/null; then
        echo -e "${RED}[Error] Required CLI tool '$cmd' is not available on the system.${NC}"
        exit 1
    fi
done

echo -e "${GREEN}[Ok] All paths and CLI tools validated.${NC}"

# Read database credentials
STAGING_PARAMS="${STAGING_DIR_PHYS}/app/config/parameters.php"
PROD_PARAMS="${PROD_DIR_PHYS}/app/config/parameters.php"

if [ ! -f "$STAGING_PARAMS" ] || [ ! -f "$PROD_PARAMS" ]; then
    echo -e "${RED}[Error] PrestaShop parameters.php configuration files are missing!${NC}"
    exit 1
fi

# Extraction helper
get_param() {
    local key=$1
    local file=$2
    awk -F"'" "/^[[:space:]]*'$key'[[:space:]]*=>/{print \$4; exit}" "$file"
}

stagingDbHost=$(get_param "database_host" "$STAGING_PARAMS")
stagingDbName=$(get_param "database_name" "$STAGING_PARAMS")
stagingDbUser=$(get_param "database_user" "$STAGING_PARAMS")
stagingDbPass=$(get_param "database_password" "$STAGING_PARAMS")
stagingDbPrefix=$(get_param "database_prefix" "$STAGING_PARAMS")

prodDbHost=$(get_param "database_host" "$PROD_PARAMS")
prodDbName=$(get_param "database_name" "$PROD_PARAMS")
prodDbUser=$(get_param "database_user" "$PROD_PARAMS")
prodDbPass=$(get_param "database_password" "$PROD_PARAMS")
prodDbPrefix=$(get_param "database_prefix" "$PROD_PARAMS")

echo -e "Staging Database:   ${GREEN}${stagingDbName}${NC} on ${GREEN}${stagingDbHost}${NC} (Prefix: '${stagingDbPrefix}')"
echo -e "Production Database:${ORANGE}${prodDbName}${NC} on ${ORANGE}${prodDbHost}${NC} (Prefix: '${prodDbPrefix}')"

# 2. Auto-Detect Staging-Only Modules
echo -e "\n${BLUE}=== Detecting Staging-Only Modules... ===${NC}"
STAGING_MODULES_DIR="${STAGING_DIR_PHYS}/modules"
PROD_MODULES_DIR="${PROD_DIR_PHYS}/modules"

MODULES_TO_PRESERVE=""

if [ "$AUTO_PRESERVE_STAGING_ONLY_MODULES" = true ]; then
    for dir in "${STAGING_MODULES_DIR}"/*/; do
        if [ -d "$dir" ]; then
            module_name=$(basename "$dir")
            # Skip if it is not a real directory or exists on production
            if [ ! -d "${PROD_MODULES_DIR}/${module_name}" ]; then
                echo -e "Detected WIP Staging-Only Module: ${ORANGE}modules/${module_name}${NC}"
                MODULES_TO_PRESERVE="${MODULES_TO_PRESERVE} modules/${module_name}"
            fi
        fi
    done
fi

# Always preserve app/config/parameters.php since it is versioned in git but contains local database configurations
if [ -f "${STAGING_DIR_PHYS}/app/config/parameters.php" ]; then
    MODULES_TO_PRESERVE="app/config/parameters.php ${MODULES_TO_PRESERVE}"
fi

# Add manual preserve paths
for path in $PRESERVE_PATHS; do
    echo -e "Detected manual preservation path: ${ORANGE}${path}${NC}"
    MODULES_TO_PRESERVE="${MODULES_TO_PRESERVE} ${path}"
done

# 3. Save WIP Files
if [ -n "$MODULES_TO_PRESERVE" ]; then
    echo -e "\n${BLUE}=== Preserving WIP files... ===${NC}"
    if [ "$DRY_RUN" = true ]; then
        echo "[Dry-Run] Would back up files to: ${PRESERVE_TEMP_DIR}"
        for path in $MODULES_TO_PRESERVE; do
            echo "[Dry-Run] Would copy ${STAGING_DIR_PHYS}/${path} to backup directory."
        done
    else
        # Clear backup dir if it exists
        rm -rf "$PRESERVE_TEMP_DIR"
        mkdir -p "$PRESERVE_TEMP_DIR"
        
        for path in $MODULES_TO_PRESERVE; do
            if [ -e "${STAGING_DIR_PHYS}/${path}" ]; then
                echo "Backing up: ${path}"
                parent_dir=$(dirname "${PRESERVE_TEMP_DIR}/${path}")
                mkdir -p "$parent_dir"
                cp -rp "${STAGING_DIR_PHYS}/${path}" "${PRESERVE_TEMP_DIR}/${path}"
            fi
        done
        echo -e "${GREEN}[Ok] WIP files backed up.${NC}"
    fi
else
    echo -e "\n${GREEN}No WIP files to preserve.${NC}"
fi

# 4. Git Alignment
echo -e "\n${BLUE}=== Aligning Git Repository with Master... ===${NC}"
if [ "$DRY_RUN" = true ]; then
    echo "[Dry-Run] Would run in ${STAGING_DIR_PHYS}:"
    echo "  git reset --hard"
    echo "  git fetch origin"
    echo "  git checkout master"
    echo "  git reset --hard origin/master"
else
    cd "$STAGING_DIR_PHYS"
    echo "Current Staging Git state:"
    git status -s
    
    echo "Resetting local staging modifications..."
    git reset --hard
    
    echo "Fetching and checking out master branch..."
    git fetch origin
    git checkout master
    git reset --hard origin/master
    echo -e "${GREEN}[Ok] Staging git aligned with master.${NC}"
fi

# 5. Restore WIP Files
if [ -n "$MODULES_TO_PRESERVE" ]; then
    echo -e "\n${BLUE}=== Restoring WIP files... ===${NC}"
    if [ "$DRY_RUN" = true ]; then
        for path in $MODULES_TO_PRESERVE; do
            echo "[Dry-Run] Would restore ${PRESERVE_TEMP_DIR}/${path} back to ${STAGING_DIR_PHYS}/${path}"
        done
    else
        for path in $MODULES_TO_PRESERVE; do
            if [ -e "${PRESERVE_TEMP_DIR}/${path}" ]; then
                echo "Restoring: ${path}"
                # Ensure destination folder exists
                dest_parent=$(dirname "${STAGING_DIR_PHYS}/${path}")
                mkdir -p "$dest_parent"
                # Remove if git pulled a placeholder or old version
                rm -rf "${STAGING_DIR_PHYS}/${path}"
                cp -rp "${PRESERVE_TEMP_DIR}/${path}" "${STAGING_DIR_PHYS}/${path}"
            fi
        done
        # Clean up temporary backup folder
        rm -rf "$PRESERVE_TEMP_DIR"
        echo -e "${GREEN}[Ok] WIP files restored.${NC}"
    fi
fi

# 6. Database Dump & Import
echo -e "\n${BLUE}=== Synchronizing Database... ===${NC}"
DATE=$(date "+%Y%m%d_%H%M%S")
STAGING_BACKUP_DIR="${STAGING_DIR_PHYS}/helper/backups"
STAGING_BACKUP_FILE="${STAGING_BACKUP_DIR}/backup_staging_before_sync_${DATE}.sql"
TEMP_PROD_DUMP="/tmp/prod_dump_${DATE}.sql"

if [ "$DRY_RUN" = true ]; then
    echo "[Dry-Run] Would ensure backup directory exists: ${STAGING_BACKUP_DIR}"
    echo "[Dry-Run] Would backup Staging database to: ${STAGING_BACKUP_FILE}"
    echo "[Dry-Run] Would dump Production database to: ${TEMP_PROD_DUMP}"
    echo "[Dry-Run] Would import ${TEMP_PROD_DUMP} into Staging database (${stagingDbName})"
    echo "[Dry-Run] Would run URL adjustments on Staging database:"
    echo "  UPDATE ${stagingDbPrefix}shop_url SET domain = '${STAGING_DOMAIN}', domain_ssl = '${STAGING_DOMAIN}';"
    echo "  UPDATE ${stagingDbPrefix}configuration SET value = '${STAGING_DOMAIN}' WHERE name = 'PS_SHOP_DOMAIN';"
    echo "  UPDATE ${stagingDbPrefix}configuration SET value = '${STAGING_DOMAIN}' WHERE name = 'PS_SHOP_DOMAIN_SSL';"
    echo "[Dry-Run] Would run backup cleanup (keeping last 3 backups, deleting older than 7 days)"
else
    # Ensure backup directory exists
    mkdir -p "$STAGING_BACKUP_DIR"

    # A. Backup Staging DB
    echo "Creating backup of current Staging database..."
    mysqldump -h"${stagingDbHost}" -u"${stagingDbUser}" -p"${stagingDbPass}" "${stagingDbName}" > "$STAGING_BACKUP_FILE"
    echo -e "${GREEN}[Ok] Staging database backup saved to: ${STAGING_BACKUP_FILE}${NC}"

    # B. Cleanup old backups (keep at least the 3 newest backups, delete older than 7 days)
    echo "Cleaning up old staging database backups..."
    backups=($(ls -t "${STAGING_BACKUP_DIR}"/backup_staging_before_sync_*.sql 2>/dev/null))
    
    if [ ${#backups[@]} -gt 3 ]; then
        for ((i=3; i<${#backups[@]}; i++)); do
            file="${backups[$i]}"
            if [ -n "$(find "$file" -mtime +7 2>/dev/null)" ]; then
                echo "Deleting old staging database backup: $(basename "$file")"
                rm -f "$file"
            fi
        done
    fi

    # C. Dump Production DB (Optimized schema + data pass)
    if [ "${EXCLUDE_HEAVY_DB_DATA:-true}" = true ]; then
        echo "Dumping Production database (Optimized: skipping heavy log & statistics data)..."
        # Pass 1: Dump schema (structures only) for all tables
        mysqldump -h"${prodDbHost}" -u"${prodDbUser}" -p"${prodDbPass}" --no-data "${prodDbName}" > "$TEMP_PROD_DUMP"
        
        # Pass 2: Dump data for all tables EXCEPT logs & statistics
        IGNORE_ARGS=""
        for tbl in log mail connections connections_page connections_source guest pagenotfound statsearch report404 gdpr_activity_log; do
            IGNORE_ARGS="${IGNORE_ARGS} --ignore-table=${prodDbName}.${prodDbPrefix}${tbl}"
        done
        mysqldump -h"${prodDbHost}" -u"${prodDbUser}" -p"${prodDbPass}" --no-create-info ${IGNORE_ARGS} "${prodDbName}" >> "$TEMP_PROD_DUMP"
    else
        echo "Dumping Production database (Full dump)..."
        mysqldump -h"${prodDbHost}" -u"${prodDbUser}" -p"${prodDbPass}" "${prodDbName}" > "$TEMP_PROD_DUMP"
    fi

    # D. Import into Staging DB
    echo "Importing Production database dump into Staging..."
    mysql -h"${stagingDbHost}" -u"${stagingDbUser}" -p"${stagingDbPass}" "${stagingDbName}" < "$TEMP_PROD_DUMP"
    rm -f "$TEMP_PROD_DUMP"

    # E. Adjust shop URLs and domains in Staging
    echo "Adjusting Staging URLs in database..."
    SQL_QUERIES="
        UPDATE ${stagingDbPrefix}shop_url SET domain = '${STAGING_DOMAIN}', domain_ssl = '${STAGING_DOMAIN}';
        UPDATE ${stagingDbPrefix}configuration SET value = '${STAGING_DOMAIN}' WHERE name = 'PS_SHOP_DOMAIN';
        UPDATE ${stagingDbPrefix}configuration SET value = '${STAGING_DOMAIN}' WHERE name = 'PS_SHOP_DOMAIN_SSL';
    "
    mysql -h"${stagingDbHost}" -u"${stagingDbUser}" -p"${stagingDbPass}" "${stagingDbName}" -e "${SQL_QUERIES}"
    echo -e "${GREEN}[Ok] Database sync and URL adaptation complete.${NC}"
fi

# 7. Asset Sync (rsync)
echo -e "\n${BLUE}=== Synchronizing Assets... ===${NC}"

sync_dir() {
    local name=$1
    echo "Syncing ${name} directory..."
    if [ "$DRY_RUN" = true ]; then
        echo "[Dry-Run] Would run: rsync -avz --delete --exclude='.htaccess' --exclude='index.php' ${PROD_DIR_PHYS}/${name}/ ${STAGING_DIR_PHYS}/${name}/"
    else
        rsync -avz --delete --exclude='.htaccess' --exclude='index.php' "${PROD_DIR_PHYS}/${name}/" "${STAGING_DIR_PHYS}/${name}/"
    fi
}

sync_dir "download"
sync_dir "upload"

if [ "$SYNC_IMAGES" = true ]; then
    echo "Syncing images (SYNC_IMAGES=true)..."
    if [ "$DRY_RUN" = true ]; then
        echo "[Dry-Run] Would run: rsync -avz --delete --exclude='.htaccess' --exclude='index.php' --exclude='default.jpg' --exclude='default.png' ${PROD_DIR_PHYS}/img/ ${STAGING_DIR_PHYS}/img/"
    else
        rsync -avz --delete --exclude='.htaccess' --exclude='index.php' --exclude='default.jpg' --exclude='default.png' "${PROD_DIR_PHYS}/img/" "${STAGING_DIR_PHYS}/img/"
    fi
else
    echo -e "${ORANGE}Image directory sync skipped (SYNC_IMAGES=false). Fallback Apache Rewrite rules will handle images.${NC}"
fi

# 8. Apache Rewrite Rules for Image Fallback & Domain Adaptations
echo -e "\n${BLUE}=== Updating Apache Rules & Image Fallbacks in .htaccess... ===${NC}"
HTACCESS_FILE="${STAGING_DIR_PHYS}/.htaccess"
IMG_HTACCESS_FILE="${STAGING_DIR_PHYS}/img/.htaccess"

if [ "$DRY_RUN" = true ]; then
    echo "[Dry-Run] Would adapt HTTP_HOST rules in ${HTACCESS_FILE} from ${PROD_DOMAIN} to ${STAGING_DOMAIN}"
    echo "[Dry-Run] Would inject product image clean URL fallback rules into ${HTACCESS_FILE}"
    echo "[Dry-Run] Would update permissions and inject missing image fallback rules into ${IMG_HTACCESS_FILE}"
else
    # A. Adapt PrestaShop HTTP_HOST rewrite conditions in root .htaccess so product/category rules match on Staging
    if [ -f "$HTACCESS_FILE" ]; then
        sed -i "s/RewriteCond %{HTTP_HOST} ^${PROD_DOMAIN}\$/RewriteCond %{HTTP_HOST} ^(${STAGING_DOMAIN}|${PROD_DOMAIN})\$/g" "$HTACCESS_FILE"
        
        # Remove legacy single-rule fallback blocks if present from earlier versions
        if grep -q "Staging Image Fallback Start" "$HTACCESS_FILE"; then
            sed -i '/# Staging Image Fallback Start/,/# Staging Image Fallback End/d' "$HTACCESS_FILE"
        fi
        if grep -q "Staging Clean URL Image Fallback Start" "$HTACCESS_FILE"; then
            sed -i '/# Staging Clean URL Image Fallback Start/,/# Staging Clean URL Image Fallback End/d' "$HTACCESS_FILE"
        fi

        # Inject clean URL fallback in root .htaccess using full %{REQUEST_URI} to preserve exact filenames
        (
            echo "# Staging Clean URL Image Fallback Start"
            echo "<IfModule mod_rewrite.c>"
            echo "  RewriteEngine On"
            echo "  RewriteCond %{REQUEST_FILENAME} !-f"
            echo "  RewriteRule ^[0-9]+.*\\.(jpe?g|webp|png|avif|gif)\$ https://${PROD_DOMAIN}%{REQUEST_URI} [QSA,L,R=302]"
            echo "  RewriteCond %{REQUEST_FILENAME} !-f"
            echo "  RewriteRule ^c/.*\\.(jpe?g|webp|png|avif|gif)\$ https://${PROD_DOMAIN}%{REQUEST_URI} [QSA,L,R=302]"
            echo "</IfModule>"
            echo "# Staging Clean URL Image Fallback End"
            echo ""
            cat "$HTACCESS_FILE"
        ) > "${HTACCESS_FILE}.tmp" && mv "${HTACCESS_FILE}.tmp" "$HTACCESS_FILE"
        echo -e "${GREEN}[Ok] Root .htaccess rules updated for Staging domain & clean URLs.${NC}"
    fi

    # B. Update img/.htaccess to grant access and redirect missing images without 403 Forbidden errors
    if [ -f "$IMG_HTACCESS_FILE" ]; then
        # Create an updated img/.htaccess that allows access and handles missing files
        cat <<EOT > "$IMG_HTACCESS_FILE"
# Staging Image Directory Fallback Start
<IfModule mod_rewrite.c>
  RewriteEngine On
  RewriteCond %{REQUEST_FILENAME} !-f
  RewriteRule ^(.*)\$ https://${PROD_DOMAIN}/img/\$1 [QSA,L,R=302]
</IfModule>
# Staging Image Directory Fallback End

# Apache 2.2
<IfModule !mod_authz_core.c>
    Order allow,deny
    Allow from all
</IfModule>

# Apache 2.4
<IfModule mod_authz_core.c>
    Require all granted
</IfModule>
EOT
        echo -e "${GREEN}[Ok] img/.htaccess permissions & fallback updated successfully.${NC}"
    fi
fi

# 9. Cache Reset & OPcache reset
echo -e "\n${BLUE}=== Resetting Caches... ===${NC}"
if [ "$DRY_RUN" = true ]; then
    echo "[Dry-Run] Would delete var/cache/prod/* and var/cache/dev/*"
    echo "[Dry-Run] Would hit reset endpoint: https://${STAGING_DOMAIN}/helper/reset_opcache.php"
else
    echo "Clearing PrestaShop Symfony cache..."
    # Fast rename & background delete trick to avoid waiting for thousands of file deletions
    for env in prod dev; do
        cache_path="${STAGING_DIR_PHYS}/var/cache/${env}"
        if [ -d "$cache_path" ]; then
            old_cache_path="${cache_path}_old_$(date +%s)"
            mv "$cache_path" "$old_cache_path" 2>/dev/null
            mkdir -p "$cache_path"
            chmod 775 "$cache_path" 2>/dev/null
            rm -rf "$old_cache_path" &
        fi
    done
    
    echo "Resetting PHP OPcache..."
    # Make curl call to trigger web-server OPcache reset (in case CLI doesn't clear FPM)
    # We bypass SSL verification check if hostpoint uses internal self-signed ssl on staging domain
    OPCACHE_RESET_URL="https://${STAGING_DOMAIN}/helper/reset_opcache.php"
    echo "Calling ${OPCACHE_RESET_URL}..."
    curl -s -k -L "${OPCACHE_RESET_URL}"
    echo -e "\n${GREEN}[Ok] Caches successfully reset.${NC}"
fi

echo -e "\n${GREEN}==================================================${NC}"
if [ "$DRY_RUN" = true ]; then
    echo -e "${GREEN}             DRY-RUN SYNC COMPLETE                ${NC}"
else
    echo -e "${GREEN}          STAGING SYNC SUCCESSFULLY RUN           ${NC}"
fi
echo -e "${GREEN}==================================================${NC}"
