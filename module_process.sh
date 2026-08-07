#!/system/bin/sh

# Shared by startup and uninstall. Callers may override PROC_ROOT in tests.
PROC_ROOT="${PROC_ROOT:-/proc}"

is_decimal_pid() {
    case "$1" in
        ''|*[!0-9]*) return 1 ;;
        *) [ "$1" -gt 0 ] 2>/dev/null ;;
    esac
}

process_matches_loader() {
    local pid="$1"
    local loader="$2"
    local exe cmdline

    is_decimal_pid "$pid" || return 1
    kill -0 "$pid" 2>/dev/null || return 1

    exe="$(readlink "$PROC_ROOT/$pid/exe" 2>/dev/null)"
    if [ -n "$exe" ] && [ "$exe" = "$loader" ]; then
        return 0
    fi

    if [ -r "$PROC_ROOT/$pid/cmdline" ]; then
        cmdline="$(tr '\000' ' ' < "$PROC_ROOT/$pid/cmdline" 2>/dev/null)"
        case " $cmdline " in
            *" $loader "*) return 0 ;;
        esac
    fi

    return 1
}

read_verified_pidfile() {
    local pidfile="$1"
    local loader="$2"
    local pid

    [ -f "$pidfile" ] || return 1
    pid="$(cat "$pidfile" 2>/dev/null)"
    process_matches_loader "$pid" "$loader" || return 1
    echo "$pid"
}

write_pidfile_atomic() {
    local pidfile="$1"
    local pid="$2"
    local tmp="${pidfile}.$$"

    is_decimal_pid "$pid" || return 1
    printf '%s\n' "$pid" > "$tmp" || return 1
    mv -f "$tmp" "$pidfile"
}
