#!/usr/bin/env bash
# PrestaShop Upgrade Toolkit - shortcut for "ps-upgrade.sh backup"
DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "$DIR/ps-upgrade.sh" backup "$@"
