#!/usr/bin/env bash
# Starts a throwaway Nextcloud server with the Deck app for the end-to-end tests, without Docker.
#
# Caddy serves it over HTTPS with its own local CA (the app only talks HTTPS; run trust-ca.sh once so the system
# trusts that CA). No mail. Everything lives in $E2E_DIR, so `stop-server.sh` and `rm -rf "$E2E_DIR"` undo it.
#
# Two profiles (E2E_PROFILE):
#   minimal    (default) PHP's built-in server, SQLite, no memory cache, at the domain root, Nextcloud's own apps.
#   realistic  set up like a real server (#142): nginx and php-fpm with Nextcloud's recommended config and pretty
#              URLs, MariaDB, APCu and Redis (memory cache and file locking), background jobs run by cron.php,
#              installed at /nextcloud, and the app store apps many servers have (Talk, Calendar, Group folders…).
#              seed.sh adds a board with 300 cards.
#
# Environment (all optional):
#   NEXTCLOUD_VERSION  "latest" (default), a major such as "35", or an exact release such as "35.0.1"
#   DECK_VERSION       empty (default: the newest Deck the app store has for that server), or e.g. "1.19.0"
#   E2E_PROFILE        "minimal" (default) or "realistic"
#   E2E_EARLY_PARAMS   1 (default for minimal) installs the e2e_early_params test app, so a parameter in both the
#                      URL and the body takes the URL's value; 0 leaves it out, so the body's value wins. The
#                      realistic profile leaves it out by default: its apps decide, as on a real server.
#   E2E_DIR            working directory, default build/e2e
#   E2E_PORT           HTTPS port, default 8443
#   E2E_CADDY_ADMIN_PORT  port of Caddy's admin API on localhost, default 2999 (the UI tests use it)
#
# Writes $E2E_DIR/env: the server URL and the test users' names and passwords, as shell variables.
# Needs php (8.3 or 8.4 with gd, intl, mbstring, pdo_sqlite, xml, zip, curl), caddy, curl, jq and unzip; the
# realistic profile also php-fpm, nginx, mariadb and redis, and the php extensions pdo_mysql, apcu and redis.
set -euo pipefail

NEXTCLOUD_VERSION="${NEXTCLOUD_VERSION:-latest}"
DECK_VERSION="${DECK_VERSION:-}"
E2E_DIR="${E2E_DIR:-build/e2e}"
E2E_PORT="${E2E_PORT:-8443}"
E2E_PROFILE="${E2E_PROFILE:-minimal}"
# The port Caddy forwards to: PHP's built-in server, or nginx.
PHP_PORT="${E2E_PHP_PORT:-8080}"
DB_PORT="${E2E_DB_PORT:-3307}"
# Caddy's admin API, on localhost only: the UI tests use it to take the server off the network and back (#156).
CADDY_ADMIN_PORT="${E2E_CADDY_ADMIN_PORT:-2999}"

case "$E2E_PROFILE" in
    minimal)
        E2E_EARLY_PARAMS="${E2E_EARLY_PARAMS:-1}"
        WEB_ROOT=""
        ;;
    realistic)
        E2E_EARLY_PARAMS="${E2E_EARLY_PARAMS:-0}"
        WEB_ROOT="/nextcloud"
        ;;
    *)
        echo "Unknown E2E_PROFILE: $E2E_PROFILE (minimal or realistic)" >&2
        exit 1
        ;;
esac

mkdir -p "$E2E_DIR"
E2E_DIR="$(cd "$E2E_DIR" && pwd)"
# The realistic server lives in a subdirectory of the web server's root, as when it's installed at a sub-path.
DOC_ROOT="$E2E_DIR${WEB_ROOT:+/www}"
SERVER_DIR="$DOC_ROOT/nextcloud"
DATA_DIR="$E2E_DIR/data"
LOG_DIR="$E2E_DIR/logs"
SERVER_URL="https://localhost:$E2E_PORT$WEB_ROOT"
mkdir -p "$LOG_DIR" "$DOC_ROOT"
if [ -f "$E2E_DIR/profile" ] && [ "$(cat "$E2E_DIR/profile")" != "$E2E_PROFILE" ]; then
    echo "$E2E_DIR has a $(cat "$E2E_DIR/profile") server: stop it and delete $E2E_DIR first" >&2
    exit 1
fi
echo "$E2E_PROFILE" >"$E2E_DIR/profile"

log() { printf '==> %s\n' "$*"; }

# Random passwords per server, kept for restarts; the server only listens on localhost.
if [ ! -f "$E2E_DIR/passwords" ]; then
    {
        echo "ADMIN_PASSWORD=$(openssl rand -hex 16)"
        echo "ALICE_PASSWORD=$(openssl rand -hex 16)"
        echo "BOB_PASSWORD=$(openssl rand -hex 16)"
        echo "DB_PASSWORD=$(openssl rand -hex 16)"
    } >"$E2E_DIR/passwords"
    chmod 600 "$E2E_DIR/passwords"
fi
# shellcheck source=/dev/null
. "$E2E_DIR/passwords"

# occ needs APCu on the command line too once it's the memory cache.
occ() { php -d apc.enable_cli=1 "$SERVER_DIR/occ" --no-interaction "$@"; }

stop_pid() { # pid-file: stops the process and waits for it to exit
    local pid
    pid=$(cat "$1" 2>/dev/null || true)
    if [ -n "$pid" ] && kill "$pid" 2>/dev/null; then
        for _ in $(seq 1 30); do
            kill -0 "$pid" 2>/dev/null || break
            sleep 0.5
        done
    fi
    rm -f "$1"
}

# A program from PATH, or the first of the other candidates that exists (Homebrew and Debian put the daemons in
# sbin directories that aren't always on PATH).
find_program() { # name candidates...
    local name="$1" candidate
    shift
    for candidate in "$(command -v "$name" || true)" "$@"; do
        if [ -n "$candidate" ] && [ -x "$candidate" ]; then
            echo "$candidate"
            return
        fi
    done
    echo "Can't find $name" >&2
    exit 1
}

# MARK: - Download

case "$NEXTCLOUD_VERSION" in
    latest) archive="latest.zip" ;;
    *.*) archive="nextcloud-$NEXTCLOUD_VERSION.zip" ;;
    *) archive="latest-$NEXTCLOUD_VERSION.zip" ;;
esac

if [ ! -f "$SERVER_DIR/occ" ]; then
    log "Downloading Nextcloud ($archive)"
    curl -fsSL --retry 3 -o "$E2E_DIR/nextcloud.zip" "https://download.nextcloud.com/server/releases/$archive"
    unzip -q "$E2E_DIR/nextcloud.zip" -d "$DOC_ROOT"
    rm "$E2E_DIR/nextcloud.zip"
fi

# MARK: - Database and cache (realistic)

if [ "$E2E_PROFILE" = realistic ]; then
    MARIADB=$(find_program mariadbd /usr/sbin/mariadbd "$(brew --prefix 2>/dev/null)/opt/mariadb/bin/mariadbd")
    DB_DIR="$E2E_DIR/mariadb"
    DB_SOCKET="$E2E_DIR/mariadb.sock"
    stop_pid "$E2E_DIR/mariadb.pid"
    if [ ! -d "$DB_DIR/mysql" ]; then
        log "Creating the MariaDB database"
        # Run as you: you can sign in to it over its socket as yourself, without a password.
        mariadb-install-db --no-defaults --datadir="$DB_DIR" --auth-root-authentication-method=socket \
            >"$LOG_DIR/mariadb-install.log" 2>&1
    fi
    log "Starting MariaDB on 127.0.0.1:$DB_PORT"
    # READ COMMITTED, as Nextcloud recommends for MySQL and MariaDB.
    nohup "$MARIADB" --no-defaults --datadir="$DB_DIR" --socket="$DB_SOCKET" --port="$DB_PORT" \
        --bind-address=127.0.0.1 --skip-name-resolve --pid-file="$E2E_DIR/mariadb.pid" \
        --log-error="$LOG_DIR/mariadb.log" --transaction-isolation=READ-COMMITTED \
        --character-set-server=utf8mb4 --collation-server=utf8mb4_general_ci >/dev/null 2>&1 &
    for _ in $(seq 1 60); do
        mariadb --no-defaults --socket="$DB_SOCKET" -e 'SELECT 1' >/dev/null 2>&1 && break
        sleep 1
    done
    mariadb --no-defaults --socket="$DB_SOCKET" <<EOF
CREATE DATABASE IF NOT EXISTS nextcloud CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;
CREATE USER IF NOT EXISTS 'nextcloud'@'127.0.0.1' IDENTIFIED BY '$DB_PASSWORD';
GRANT ALL PRIVILEGES ON nextcloud.* TO 'nextcloud'@'127.0.0.1';
FLUSH PRIVILEGES;
EOF

    REDIS_SOCKET="$E2E_DIR/redis.sock"
    stop_pid "$E2E_DIR/redis.pid"
    log "Starting Redis on $REDIS_SOCKET"
    redis-server --port 0 --unixsocket "$REDIS_SOCKET" --unixsocketperm 700 --dir "$E2E_DIR" --save "" \
        --daemonize yes --pidfile "$E2E_DIR/redis.pid" --logfile "$LOG_DIR/redis.log"
    for _ in $(seq 1 30); do
        [ -S "$REDIS_SOCKET" ] && break
        sleep 0.5
    done
fi

# MARK: - Install

if ! occ status --output=json 2>/dev/null | jq -e '.installed' >/dev/null; then
    log "Installing Nextcloud"
    if [ "$E2E_PROFILE" = realistic ]; then
        database=(--database mysql --database-host "127.0.0.1:$DB_PORT" --database-name nextcloud
            --database-user nextcloud --database-pass "$DB_PASSWORD")
    else
        database=(--database sqlite)
    fi
    occ maintenance:install \
        "${database[@]}" \
        --admin-user admin \
        --admin-pass "$ADMIN_PASSWORD" \
        --data-dir "$DATA_DIR"
fi
occ status

log "Configuring Nextcloud for $SERVER_URL behind Caddy"
occ config:system:set trusted_domains 0 --value="localhost:$E2E_PORT"
occ config:system:set trusted_domains 1 --value="localhost"
occ config:system:set overwrite.cli.url --value="$SERVER_URL"
occ config:system:set overwriteprotocol --value=https
occ config:system:set trusted_proxies 0 --value=127.0.0.1
occ config:system:set trusted_proxies 1 --value=::1
occ config:system:set loglevel --type=integer --value=2
occ config:system:set logfile --value="$LOG_DIR/nextcloud.log"
# The tests sign in and fail to sign in many times in a row; don't slow them down or lock them out.
occ config:system:set auth.bruteforce.protection.enabled --type=boolean --value=false
occ config:system:set ratelimit.protection.enabled --type=boolean --value=false
# No mail server or update checks here.
occ config:system:set updatechecker --type=boolean --value=false
occ config:system:set has_internet_connection --type=boolean --value=true
occ config:system:set appstoreenabled --type=boolean --value=true
# Short test passwords, and no request to haveibeenpwned.com for them.
occ app:disable password_policy >/dev/null 2>&1 || true
# Skip the first-run wizard and dashboard prompts in the browser sign-in page.
occ app:disable firstrunwizard >/dev/null 2>&1 || true

if [ "$E2E_PROFILE" = realistic ]; then
    log "Configuring the sub-path, pretty URLs, memory cache, file locking and background jobs"
    occ config:system:set overwritewebroot --value="$WEB_ROOT"
    # With nginx's front_controller_active, Nextcloud's own links leave out index.php.
    occ config:system:set htaccess.RewriteBase --value="$WEB_ROOT"
    occ config:system:set memcache.local --value='\OC\Memcache\APCu'
    occ config:system:set memcache.distributed --value='\OC\Memcache\Redis'
    occ config:system:set memcache.locking --value='\OC\Memcache\Redis'
    occ config:system:set redis host --value="$REDIS_SOCKET"
    occ config:system:set redis port --type=integer --value=0
    occ config:system:set filelocking.enabled --type=boolean --value=true
    occ background:cron
fi

# MARK: - Deck

if occ app:list --output=json | jq -e '.enabled.deck' >/dev/null; then
    log "Deck already enabled"
elif [ -n "$DECK_VERSION" ]; then
    log "Installing Deck $DECK_VERSION from its release"
    curl -fsSL --retry 3 -o "$E2E_DIR/deck.tar.gz" \
        "https://github.com/nextcloud-releases/deck/releases/download/v$DECK_VERSION/deck-v$DECK_VERSION.tar.gz"
    rm -rf "$SERVER_DIR/apps/deck"
    tar xzf "$E2E_DIR/deck.tar.gz" -C "$SERVER_DIR/apps"
    rm "$E2E_DIR/deck.tar.gz"
    occ app:enable deck
else
    log "Installing the newest Deck for this server from the app store"
    occ app:install deck
fi

# MARK: - Test app

# MARK: - Other apps (realistic)

# Apps from the app store that many servers have. They hook into requests, sign-in and sharing, so the tests see
# them as a real server's users would. One that has no release for this Nextcloud yet is left out, with a warning.
REALISTIC_APPS="twofactor_totp spreed calendar contacts tasks notes groupfolders forms polls collectives"
if [ "$E2E_PROFILE" = realistic ]; then
    for app in $REALISTIC_APPS; do
        if occ app:list --output=json | jq -e --arg app "$app" '.enabled[$app]' >/dev/null; then
            continue
        fi
        log "Installing $app"
        if ! occ app:install "$app" >"$LOG_DIR/app-$app.log" 2>&1 && ! occ app:enable "$app" >>"$LOG_DIR/app-$app.log" 2>&1; then
            echo "warning: couldn't install $app: $(tail -1 "$LOG_DIR/app-$app.log")" >&2
            if [ -n "${GITHUB_ACTIONS:-}" ]; then
                echo "::warning::$app isn't installed on the realistic server: $(tail -1 "$LOG_DIR/app-$app.log")"
            fi
        fi
    done
fi

# MARK: - Test app

# Real servers run apps that read request parameters while booting, which changes which value wins when the URL
# and the body set the same parameter (#131). This test-only app does the same, so the tests see that case;
# without it, the body's value wins. The tests have to pass both ways.
rm -rf "$SERVER_DIR/apps/e2e_early_params"
if [ "$E2E_EARLY_PARAMS" = 1 ]; then
    cp -R "$(dirname "$0")/apps/e2e_early_params" "$SERVER_DIR/apps/"
    occ app:enable e2e_early_params
else
    occ app:remove e2e_early_params >/dev/null 2>&1 || true
fi

# MARK: - Users

add_user() { # user display-name password
    if ! occ user:info "$1" >/dev/null 2>&1; then
        OC_PASS="$3" occ user:add --password-from-env --display-name="$2" "$1"
    fi
}
add_user alice "Alice Example" "$ALICE_PASSWORD"
add_user bob "Bob Example" "$BOB_PASSWORD"
occ group:add family >/dev/null 2>&1 || true
occ group:adduser family alice
occ group:adduser family bob

# MARK: - Serve

stop_pid "$E2E_DIR/php.pid"
stop_pid "$E2E_DIR/php-fpm.pid"
stop_pid "$E2E_DIR/nginx.pid"
stop_pid "$E2E_DIR/caddy.pid"

if [ "$E2E_PROFILE" = minimal ]; then
    log "Starting PHP on 127.0.0.1:$PHP_PORT"
    # The built-in server handles one request at a time unless it forks workers; the app sends several at once.
    PHP_CLI_SERVER_WORKERS=8 nohup php -d memory_limit=512M -S "127.0.0.1:$PHP_PORT" -t "$SERVER_DIR" \
        >"$LOG_DIR/php.log" 2>&1 &
    echo $! >"$E2E_DIR/php.pid"
else
    php_version=$(php -r 'echo PHP_MAJOR_VERSION . "." . PHP_MINOR_VERSION;')
    php_dir=$(dirname "$(php -r 'echo realpath(PHP_BINARY);')")
    PHP_FPM=$(find_program php-fpm "$php_dir/../sbin/php-fpm" "/usr/sbin/php-fpm$php_version")
    FPM_SOCKET="$E2E_DIR/php-fpm.sock"
    cat >"$E2E_DIR/php-fpm.conf" <<EOF
[global]
pid = $E2E_DIR/php-fpm.pid
error_log = $LOG_DIR/php-fpm.log
daemonize = yes

[nextcloud]
listen = $FPM_SOCKET
pm = static
pm.max_children = 8
clear_env = no
catch_workers_output = yes
php_admin_value[memory_limit] = 512M
php_admin_value[upload_max_filesize] = 512M
php_admin_value[post_max_size] = 512M
php_admin_value[output_buffering] = 0
EOF
    log "Starting php-fpm ($PHP_FPM)"
    "$PHP_FPM" --fpm-config "$E2E_DIR/php-fpm.conf"

    # Nextcloud's recommended nginx config for a server in a subdirectory, trimmed to what the tests reach:
    # https://docs.nextcloud.com/server/latest/admin_manual/installation/nginx.html
    NGINX=$(find_program nginx /usr/sbin/nginx)
    mkdir -p "$E2E_DIR/nginx/temp"
    cat >"$E2E_DIR/nginx/nginx.conf" <<EOF
worker_processes 2;
pid $E2E_DIR/nginx.pid;
error_log $LOG_DIR/nginx-error.log warn;
events { worker_connections 256; }
http {
    types {
        text/html html; text/css css; text/javascript js mjs; application/json json map;
        image/svg+xml svg; image/png png; image/gif gif; image/jpeg jpg; image/x-icon ico;
        application/wasm wasm; font/woff woff; font/woff2 woff2;
    }
    default_type application/octet-stream;
    access_log $LOG_DIR/nginx-access.log;
    client_body_temp_path $E2E_DIR/nginx/temp/body;
    fastcgi_temp_path $E2E_DIR/nginx/temp/fastcgi;
    proxy_temp_path $E2E_DIR/nginx/temp/proxy;
    uwsgi_temp_path $E2E_DIR/nginx/temp/uwsgi;
    scgi_temp_path $E2E_DIR/nginx/temp/scgi;
    upstream php-handler { server unix:$FPM_SOCKET; }
    map \$arg_v \$asset_immutable { "" ""; default ", immutable"; }

    server {
        listen 127.0.0.1:$PHP_PORT;
        server_name localhost;
        root $DOC_ROOT;
        client_max_body_size 512M;
        client_body_timeout 300s;
        fastcgi_buffers 64 4K;
        gzip on;
        gzip_types text/css text/javascript application/json image/svg+xml;

        location = / { return 301 $WEB_ROOT/; }
        location ^~ /.well-known {
            location = /.well-known/carddav { return 301 $WEB_ROOT/remote.php/dav/; }
            location = /.well-known/caldav { return 301 $WEB_ROOT/remote.php/dav/; }
            return 301 $WEB_ROOT/index.php\$request_uri;
        }

        location ^~ $WEB_ROOT {
            index index.php index.html $WEB_ROOT/index.php\$request_uri;
            location = $WEB_ROOT { return 301 $WEB_ROOT/; }
            location ~ ^$WEB_ROOT/(?:build|tests|config|lib|3rdparty|templates|data)(?:\$|/) { return 404; }
            location ~ ^$WEB_ROOT/(?:\.|autotest|occ|issue|indie|db_|console) { return 404; }

            location ~ \.php(?:\$|/) {
                rewrite ^$WEB_ROOT/(?!index|remote|public|cron|core\/ajax\/update|status|ocs\/v[12]|updater\/.+|ocs-provider\/.+|.+\/richdocumentscode(_arm64)?\/proxy) $WEB_ROOT/index.php\$request_uri;
                fastcgi_split_path_info ^(.+?\.php)(/.*)\$;
                set \$path_info \$fastcgi_path_info;
                try_files \$fastcgi_script_name =404;
                fastcgi_param QUERY_STRING \$query_string;
                fastcgi_param REQUEST_METHOD \$request_method;
                fastcgi_param CONTENT_TYPE \$content_type;
                fastcgi_param CONTENT_LENGTH \$content_length;
                fastcgi_param SCRIPT_NAME \$fastcgi_script_name;
                fastcgi_param REQUEST_URI \$request_uri;
                fastcgi_param DOCUMENT_URI \$document_uri;
                fastcgi_param DOCUMENT_ROOT \$document_root;
                fastcgi_param SERVER_PROTOCOL \$server_protocol;
                fastcgi_param REQUEST_SCHEME \$scheme;
                fastcgi_param GATEWAY_INTERFACE CGI/1.1;
                fastcgi_param SERVER_SOFTWARE nginx/\$nginx_version;
                fastcgi_param REMOTE_ADDR \$remote_addr;
                fastcgi_param REMOTE_PORT \$remote_port;
                fastcgi_param SERVER_ADDR \$server_addr;
                fastcgi_param SERVER_PORT \$server_port;
                fastcgi_param SERVER_NAME \$server_name;
                fastcgi_param REDIRECT_STATUS 200;
                fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
                fastcgi_param PATH_INFO \$path_info;
                fastcgi_param HTTPS on;
                fastcgi_param modHeadersAvailable true;
                fastcgi_param front_controller_active true;
                fastcgi_pass php-handler;
                fastcgi_intercept_errors on;
                fastcgi_request_buffering off;
                fastcgi_max_temp_file_size 0;
            }

            location ~ \.(?:css|js|mjs|svg|gif|ico|jpg|png|webp|wasm|tflite|map|ogg|flac)\$ {
                try_files \$uri $WEB_ROOT/index.php\$request_uri;
                add_header Cache-Control "public, max-age=15778463\$asset_immutable";
                access_log off;
            }
            location ~ \.(otf|woff2?)\$ {
                try_files \$uri $WEB_ROOT/index.php\$request_uri;
                expires 7d;
                access_log off;
            }
            location $WEB_ROOT/remote { return 301 $WEB_ROOT/remote.php\$request_uri; }
            location $WEB_ROOT { try_files \$uri \$uri/ $WEB_ROOT/index.php\$request_uri; }
        }
    }
}
EOF
    log "Starting nginx on 127.0.0.1:$PHP_PORT"
    "$NGINX" -p "$E2E_DIR/nginx" -e "$LOG_DIR/nginx-error.log" -c "$E2E_DIR/nginx/nginx.conf"
fi

cat >"$E2E_DIR/Caddyfile" <<EOF
{
	admin localhost:$CADDY_ADMIN_PORT
	skip_install_trust
	storage file_system "$E2E_DIR/caddy"
	log {
		output file "$LOG_DIR/caddy.log"
	}
}

https://localhost:$E2E_PORT {
	tls internal
	reverse_proxy 127.0.0.1:$PHP_PORT
}
EOF

log "Starting Caddy on $SERVER_URL"
nohup caddy run --config "$E2E_DIR/Caddyfile" --adapter caddyfile >"$LOG_DIR/caddy-run.log" 2>&1 &
echo $! >"$E2E_DIR/caddy.pid"

# Caddy creates its CA and the localhost certificate on first start.
CA_CERT="$E2E_DIR/caddy/pki/authorities/local/root.crt"
for _ in $(seq 1 60); do
    if [ -f "$CA_CERT" ] && curl -fs --cacert "$CA_CERT" -o /dev/null "$SERVER_URL/status.php"; then
        break
    fi
    sleep 1
done
curl -fsS --cacert "$CA_CERT" "$SERVER_URL/status.php"
echo

cat >"$E2E_DIR/env" <<EOF
E2E_SERVER_URL=$SERVER_URL
E2E_CADDY_ADMIN=http://localhost:$CADDY_ADMIN_PORT
E2E_CA_CERT=$CA_CERT
E2E_ADMIN_PASSWORD=$ADMIN_PASSWORD
E2E_ALICE_USER=alice
E2E_ALICE_PASSWORD=$ALICE_PASSWORD
E2E_BOB_USER=bob
E2E_BOB_PASSWORD=$BOB_PASSWORD
E2E_NEXTCLOUD_VERSION=$(occ status --output=json | jq -r .versionstring)
E2E_DECK_VERSION=$(occ app:list --output=json | jq -r '.enabled.deck')
E2E_PROFILE=$E2E_PROFILE
E2E_EARLY_PARAMS=$E2E_EARLY_PARAMS
EOF
if [ "$E2E_PROFILE" = realistic ]; then
    # Run the background jobs once, as cron would every five minutes.
    log "Running background jobs"
    php -d apc.enable_cli=1 -d memory_limit=512M "$SERVER_DIR/cron.php" >"$LOG_DIR/cron.log" 2>&1 ||
        echo "warning: cron.php failed, see $LOG_DIR/cron.log" >&2
fi
log "Server ready at $SERVER_URL: $(grep -E 'VERSION|PROFILE|EARLY' "$E2E_DIR/env" | tr '\n' ' ')"
