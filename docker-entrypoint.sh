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

IDENTITY_CHANGED=0

if [ "$CURRENT_UID" != "$PUID" ] || [ "$CURRENT_GID" != "$PGID" ]; then
    IDENTITY_CHANGED=1
fi

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

ensure_tree_owner() {
    TARGET_PATH="$1"
    MISMATCHED_PATH="$(
        find "$TARGET_PATH" \
            \( ! -uid "$PUID" -o ! -gid "$PGID" \) \
            -print \
            -quit
    )"

    if [ -n "$MISMATCHED_PATH" ]; then
        echo "Correcting ownership: $TARGET_PATH"
        chown -R satisfactory:satisfactory "$TARGET_PATH"
    fi
}

if [ "$IDENTITY_CHANGED" -eq 1 ]; then
    chown -R satisfactory:satisfactory \
        /home/satisfactory/.fex-emu \
        /home/satisfactory/steamcmd \
        /home/satisfactory/.config/Epic \
        /home/satisfactory/server-file
else
    ensure_tree_owner /home/satisfactory/.config/Epic
    ensure_tree_owner /home/satisfactory/server-file
fi

exec setpriv \
    --reuid=satisfactory \
    --regid=satisfactory \
    --init-groups \
    -- \
    "$@"
