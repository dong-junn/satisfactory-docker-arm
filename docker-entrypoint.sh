#!/bin/sh
set -eu

if [ -z "${PUID:-}" ] && [ -z "${PGID:-}" ]; then
    HOST_OWNER_PATH="${HOST_OWNER_PATH:-/run/host-owner}"

    if [ ! -e "$HOST_OWNER_PATH" ]; then
        echo "Cannot detect host UID/GID: $HOST_OWNER_PATH is not mounted" >&2
        exit 1
    fi

    PUID="$(stat -c '%u' "$HOST_OWNER_PATH")"
    PGID="$(stat -c '%g' "$HOST_OWNER_PATH")"
elif [ -z "${PUID:-}" ] || [ -z "${PGID:-}" ]; then
    echo "PUID and PGID must be provided together" >&2
    exit 1
fi

case "$PUID" in
    ''|*[!0-9]*|0)
        echo "PUID must be a positive integer: $PUID" >&2
        exit 1
        ;;
esac

case "$PGID" in
    ''|*[!0-9]*|0)
        echo "PGID must be a positive integer: $PGID" >&2
        exit 1
        ;;
esac

CURRENT_UID="$(id -u satisfactory)"
CURRENT_GID="$(id -g satisfactory)"

if [ "$CURRENT_GID" != "$PGID" ]; then
    groupmod --non-unique --gid "$PGID" satisfactory
fi

if [ "$CURRENT_UID" != "$PUID" ]; then
    usermod \
        --non-unique \
        --uid "$PUID" \
        --gid "$PGID" \
        satisfactory
elif [ "$CURRENT_GID" != "$PGID" ]; then
    usermod --gid "$PGID" satisfactory
fi

mkdir -p \
    /home/satisfactory/.config/Epic \
    /home/satisfactory/server-file

chown satisfactory:satisfactory \
    /home/satisfactory \
    /home/satisfactory/.config

chown -R satisfactory:satisfactory \
    /home/satisfactory/.fex-emu \
    /home/satisfactory/steamcmd \
    /home/satisfactory/.config/Epic \
    /home/satisfactory/server-file

exec setpriv \
    --reuid=satisfactory \
    --regid=satisfactory \
    --init-groups \
    -- \
    "$@"
