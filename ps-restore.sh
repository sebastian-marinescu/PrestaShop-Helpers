#!/usr/bin/env bash
# PrestaShop Upgrade Toolkit - shortcut for "ps-upgrade.sh restore [set|latest]"
DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "$DIR/ps-upgrade.sh" restore "$@"
