#!/bin/bash

LOCAL_DIRECTORY=$(pwd)/sql_upgrades
REMOTE_DIRECTORY=upgrade/sql/
REMOTE_REPOSITORY="git@github.com:PrestaShop/autoupgrade.git"

PS_CONFIG_FILE=../app/config/parameters.php
PS_DB_PREFIX=$(awk -F"'" '/database_prefix/{print $4}' ${PS_CONFIG_FILE})

function git_sparse_clone() {
  rurl="$1" localdir="$2" && shift 2

  mkdir -p "$localdir"
  cd "$localdir"

  git init
  git remote add -f origin "$rurl"

  git config core.sparseCheckout true

  # Loops over remaining args
  for i; do
    echo "$i" >> .git/info/sparse-checkout
  done

  git pull origin dev
}

git_sparse_clone "${REMOTE_REPOSITORY}" "${LOCAL_DIRECTORY}" "${REMOTE_DIRECTORY}"

cd ${LOCAL_DIRECTORY}
cp ${REMOTE_DIRECTORY}*.* ${LOCAL_DIRECTORY}

echo
echo "Replacing db-prefix"
sed -i '' "s/PREFIX_/${PS_DB_PREFIX}/g" *.sql

echo
echo "Removing unnecessary directories"
rm -rf ./*/ .git
