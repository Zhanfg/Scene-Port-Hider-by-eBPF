#!/system/bin/sh

MODDIR=${0%/*}
LOADER="$MODDIR/system/bin/hideport_loader"
PROCESS_HELPER="$MODDIR/module_process.sh"
PIDFILE="/dev/hideport_loader.pid"
LOCKDIR="/dev/hideport_loader.lock"

if [ -r "$PROCESS_HELPER" ]; then
    # shellcheck disable=SC1090
    . "$PROCESS_HELPER"
    PID="$(read_verified_pidfile "$PIDFILE" "$LOADER" 2>/dev/null)"
    if [ -n "$PID" ]; then
        kill "$PID" 2>/dev/null
        i=0
        while kill -0 "$PID" 2>/dev/null && [ "$i" -lt 20 ]; do
            sleep 1
            i=$((i + 1))
        done
        if process_matches_loader "$PID" "$LOADER"; then
            kill -9 "$PID" 2>/dev/null
        fi
    fi
fi

rm -f "$PIDFILE"
rm -rf "$LOCKDIR"
