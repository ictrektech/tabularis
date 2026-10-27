#!/bin/sh
set -eu
# VOS creates the bind mount as root. Initialize only this app's viewer storage.
if [ "$(id -u)" = 0 ]; then
    mkdir -p /data/.local/share/tabularis/plugins/drivers/redis
    chown -R 10001:10001 /data
    exec gosu 10001:10001 "$0" "$@"
fi
cp -R /usr/lib/tabularis/redis/. /data/.local/share/tabularis/plugins/drivers/redis/
exec node /usr/lib/tabularis/vos/gateway.mjs
