#!/system/bin/sh

MODDIR=${0%/*}
CONF="$MODDIR/hideport.conf"
LOADER="$MODDIR/system/bin/hideport_loader"
PROCESS_HELPER="$MODDIR/module_process.sh"
LOG="$MODDIR/hideport.log"
PIDFILE="/dev/hideport_loader.pid"
LOCKDIR="/dev/hideport_loader.lock"
LOCK_OWNER="$LOCKDIR/owner.pid"

PKG="com.omarea.vtools"
PORTS="8788 8765 14731 14754"
ENABLE_EBPF=1
WAIT_FOR_PROCESS=0
EXTRA_ALLOWED_UIDS=""
WAIT_FOR_UID_TIMEOUT=300

[ -r "$PROCESS_HELPER" ] || {
    echo "missing process helper: $PROCESS_HELPER" >&2
    exit 1
}
# shellcheck disable=SC1090
. "$PROCESS_HELPER"

[ -f "$CONF" ] && . "$CONF"
START_CONTEXT="${1:-manual}"

log_msg() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') [$1] $2" >> "$LOG"
}

is_running() {
    local pid
    pid="$(read_verified_pidfile "$PIDFILE" "$LOADER" 2>/dev/null)" || {
        rm -f "$PIDFILE"
        return 1
    }
    [ -n "$pid" ]
}

startup_owner_alive() {
    local pid cmdline
    [ -f "$LOCK_OWNER" ] || return 1
    pid="$(cat "$LOCK_OWNER" 2>/dev/null)"
    is_decimal_pid "$pid" || return 1
    kill -0 "$pid" 2>/dev/null || return 1
    [ -r "$PROC_ROOT/$pid/cmdline" ] || return 0
    cmdline="$(tr '\000' ' ' < "$PROC_ROOT/$pid/cmdline" 2>/dev/null)"
    case "$cmdline" in
        *hideport_start.sh*) return 0 ;;
        *) return 1 ;;
    esac
}

acquire_lock() {
    if mkdir "$LOCKDIR" 2>/dev/null; then
        printf '%s\n' "$$" > "$LOCK_OWNER"
        return 0
    fi

    if startup_owner_alive; then
        return 1
    fi

    rm -rf "$LOCKDIR"
    mkdir "$LOCKDIR" 2>/dev/null || return 1
    printf '%s\n' "$$" > "$LOCK_OWNER"
}

cleanup_lock() {
    local owner
    owner="$(cat "$LOCK_OWNER" 2>/dev/null)"
    if [ "$owner" = "$$" ]; then
        rm -rf "$LOCKDIR"
    fi
}

validate_positive_integer() {
    case "$1" in
        ''|*[!0-9]*) return 1 ;;
        *) [ "$1" -gt 0 ] 2>/dev/null ;;
    esac
}

validate_config() {
    local port uid seen_ports

    case "$ENABLE_EBPF" in 0|1) ;; *) return 1 ;; esac
    case "$WAIT_FOR_PROCESS" in 0|1) ;; *) return 1 ;; esac
    validate_positive_integer "$WAIT_FOR_UID_TIMEOUT" || return 1

    case "$PKG" in
        ''|*[!A-Za-z0-9._-]*) return 1 ;;
    esac

    seen_ports=""
    for port in $PORTS; do
        validate_positive_integer "$port" || return 1
        [ "$port" -le 65535 ] || return 1
        case " $seen_ports " in
            *" $port "*) return 1 ;;
        esac
        seen_ports="$seen_ports $port"
    done
    [ -n "$seen_ports" ] || return 1

    for uid in $EXTRA_ALLOWED_UIDS; do
        validate_positive_integer "$uid" || return 1
        [ "$uid" -le 2147483647 ] || return 1
    done
}

user_to_uid() {
    local user="$1"
    local android_user app_id app_num

    case "$user" in
        '') return 1 ;;
        root) echo 0; return 0 ;;
        system) echo 1000; return 0 ;;
        shell) echo 2000; return 0 ;;
        *[!0-9]*) ;;
        *) echo "$user"; return 0 ;;
    esac

    android_user="$(echo "$user" | sed -n 's/^u\([0-9][0-9]*\)_a[0-9][0-9]*$/\1/p')"
    app_num="$(echo "$user" | sed -n 's/^u[0-9][0-9]*_a\([0-9][0-9]*\)$/\1/p')"
    if [ -n "$android_user" ] && [ -n "$app_num" ]; then
        app_id=$((10000 + app_num))
        echo $((android_user * 100000 + app_id))
        return 0
    fi

    return 1
}

append_unique_uid() {
    local list="$1"
    local uid="$2"

    [ -n "$uid" ] || {
        echo "$list"
        return 0
    }

    case " $list " in
        *" $uid "*) echo "$list" ;;
        *) echo "$list $uid" ;;
    esac
}

get_app_uids() {
    local uid user trusted_uids extra_uids stat_uids line

    trusted_uids=""
    extra_uids=""
    stat_uids=""

    uid="$(dumpsys package "$PKG" 2>/dev/null | sed -n 's/.*userId=\([0-9][0-9]*\).*/\1/p' | head -n 1)"
    trusted_uids="$(append_unique_uid "$trusted_uids" "$uid")"

    uid="$(cmd package list packages -U "$PKG" 2>/dev/null | sed -n 's/.* uid:\([0-9][0-9]*\).*/\1/p' | head -n 1)"
    trusted_uids="$(append_unique_uid "$trusted_uids" "$uid")"

    while IFS= read -r line; do
        user="${line%% *}"
        uid="$(user_to_uid "$user" 2>/dev/null)"
        trusted_uids="$(append_unique_uid "$trusted_uids" "$uid")"
    done <<EOF_PS
$(ps -A -o USER,ARGS 2>/dev/null | grep -F "$PKG")
EOF_PS

    extra_uids="$(echo "$EXTRA_ALLOWED_UIDS" | tr ' ' '\n' | sed '/^$/d' | sort -n -u | tr '\n' ' ')"

    if [ -z "$(echo "$trusted_uids $extra_uids" | tr ' ' '\n' | sed '/^$/d' | head -n 1)" ]; then
        return 1
    fi

    uid="$(stat -c "%u" "/data/data/$PKG" 2>/dev/null)"
    stat_uids="$(append_unique_uid "$stat_uids" "$uid")"

    echo "$trusted_uids $extra_uids $stat_uids" | tr ' ' '\n' | sed '/^$/d' | sort -n -u | tr '\n' ' '
}

wait_for_uid() {
    local uids i
    i=0

    while [ "$i" -lt "$WAIT_FOR_UID_TIMEOUT" ]; do
        uids="$(get_app_uids)"
        if [ -n "$uids" ]; then
            echo "$uids"
            return 0
        fi
        i=$((i + 1))
        sleep 1
    done

    return 1
}

wait_for_process_if_requested() {
    [ "$WAIT_FOR_PROCESS" = "1" ] || return 0

    while ! pidof "$PKG" >/dev/null 2>&1; do
        sleep 1
    done
    sleep 3
}

validate_config || {
    log_msg "$START_CONTEXT" "invalid configuration; loader not started"
    exit 1
}

if [ "$ENABLE_EBPF" != "1" ]; then
    log_msg "$START_CONTEXT" "eBPF loader disabled by config"
    exit 0
fi

if is_running; then
    log_msg "$START_CONTEXT" "hideport_loader is already running"
    exit 0
fi

if ! acquire_lock; then
    log_msg "$START_CONTEXT" "another verified startup is in progress"
    exit 0
fi
trap cleanup_lock EXIT INT TERM

if is_running; then
    log_msg "$START_CONTEXT" "hideport_loader started while waiting for lock"
    exit 0
fi

if [ ! -x "$LOADER" ]; then
    log_msg "$START_CONTEXT" "missing executable: $LOADER"
    exit 1
fi

APP_UIDS="$(wait_for_uid)"
if [ -z "$APP_UIDS" ]; then
    log_msg "$START_CONTEXT" "failed to resolve UID for package $PKG"
    exit 1
fi

wait_for_process_if_requested

set --
for port in $PORTS; do
    set -- "$@" --port "$port"
done
for uid in $APP_UIDS; do
    set -- "$@" --uid "$uid"
done

log_msg "$START_CONTEXT" "starting hideport_loader for package $PKG uids $APP_UIDS ports $PORTS"
"$LOADER" "$@" >> "$LOG" 2>&1 &
loader_pid=$!

if ! write_pidfile_atomic "$PIDFILE" "$loader_pid"; then
    kill "$loader_pid" 2>/dev/null
    log_msg "$START_CONTEXT" "failed to write loader PID file"
    exit 1
fi

sleep 1
if ! process_matches_loader "$loader_pid" "$LOADER"; then
    wait "$loader_pid" 2>/dev/null
    status=$?
    rm -f "$PIDFILE"
    log_msg "$START_CONTEXT" "loader exited during startup with status $status"
    exit 1
fi

log_msg "$START_CONTEXT" "hideport_loader started with pid $loader_pid"
