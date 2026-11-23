#!/usr/bin/env bash
# Checks that PHP has the extensions the test server needs (#197), and names the missing ones.
#
#   scripts/e2e/check-php.sh [minimal|realistic]    (default: $E2E_PROFILE, else minimal)
#
# Exits 1 if any is missing. The realistic profile also needs pdo_mysql, apcu and redis. Without APCu, occ quietly
# falls back to no memory cache, so the server installs fine, but every web request fails with an empty 500:
# Nextcloud only allows that fallback on the command line.
set -euo pipefail

PROFILE="${1:-${E2E_PROFILE:-minimal}}"
required="gd intl mbstring pdo_sqlite xml zip curl"
if [ "$PROFILE" = realistic ]; then
    required="$required pdo_mysql apcu redis"
fi

loaded=$(php -m | tr '[:upper:]' '[:lower:]')
missing=""
for extension in $required; do
    grep -qx "$extension" <<<"$loaded" || missing="$missing $extension"
done

if [ -n "$missing" ]; then
    echo "PHP $(php -r 'echo PHP_VERSION;') is missing extensions for the $PROFILE test server:$missing" >&2
    exit 1
fi
echo "PHP $(php -r 'echo PHP_VERSION;') has the extensions for the $PROFILE test server: $required"
