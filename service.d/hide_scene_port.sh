#!/system/bin/sh

# Standalone Scene connect-probe hiding script.
# Keep this separate from the eBPF loader; it is packaged into service.d.

SCRIPT_DIR=${0%/*}
case "$SCRIPT_DIR" in
    */service.d) MODDIR=${SCRIPT_DIR%/service.d} ;;
    *) MODDIR="$SCRIPT_DIR" ;;
esac

PKG_NAME="com.omarea.vtools"
PORTS="8765 8788"
LOG_FILE="$MODDIR/hide_scene.log"

log_msg() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [SceneHidePort] $1" >> "$LOG_FILE"
    echo "[SceneHidePort] $1" > /dev/kmsg
}

> "$LOG_FILE"
chmod 666 "$LOG_FILE" 2>/dev/null

log_msg "Waiting for system boot completion..."
while [ "$(getprop sys.boot_completed)" != "1" ]; do
    sleep 2
done

log_msg "System booted. Extracting UID for $PKG_NAME..."
SCENE_UID=$(stat -c %u /data/data/$PKG_NAME 2>/dev/null)
if [ -z "$SCENE_UID" ] || ! echo "$SCENE_UID" | grep -qE '^[0-9]+$'; then
    SCENE_UID=$(cmd package list packages -U | grep "package:$PKG_NAME" | grep -oE 'uid:[0-9]+' | head -n 1 | cut -d':' -f2)
fi
if [ -z "$SCENE_UID" ] || ! echo "$SCENE_UID" | grep -qE '^[0-9]+$'; then
    SCENE_UID=$(dumpsys package $PKG_NAME | grep -E '^ *userId=[0-9]+' | head -n 1 | awk -F'=' '{print $2}' | awk '{print $1}')
fi

if [ -z "$SCENE_UID" ] || ! echo "$SCENE_UID" | grep -qE '^[0-9]+$'; then
    log_msg "Failed to get a valid UID for $PKG_NAME. Got: '$SCENE_UID'. Is the app installed? Exiting."
    exit 1
fi

log_msg "Successfully extracted valid UID: $SCENE_UID. Starting iptables daemon loop..."

# Boot fast-loop phase (check every 2s for the first 2 minutes)
BOOT_START_TIME=$(date +%s)
FAST_LOOP_DURATION=120

while true; do
    NEED_REAPPLY=false
    for PORT in $PORTS; do
        # Check if BOTH the first ACCEPT rule (UID 0) AND the REJECT rule exist
        # This is more robust than just checking REJECT.
        if ! iptables -C OUTPUT -p tcp --dport $PORT -m owner --uid-owner 0 -j ACCEPT >/dev/null 2>&1 || \
           ! iptables -C OUTPUT -p tcp --dport $PORT -j REJECT --reject-with tcp-reset >/dev/null 2>&1; then
            NEED_REAPPLY=true
            break
        fi
    done

    if [ "$NEED_REAPPLY" = "true" ]; then
        log_msg "Iptables rules missing or incomplete. Re-applying for all ports: $PORTS"
        for PORT in $PORTS; do
            for cmd in iptables ip6tables; do
                # Cleanup old rules
                for iface in "-o lo " ""; do
                    while $cmd -D OUTPUT ${iface}-p tcp --dport $PORT -m owner --uid-owner 0 -j ACCEPT 2>/dev/null; do :; done
                    while $cmd -D OUTPUT ${iface}-p tcp --dport $PORT -m owner --uid-owner 2000 -j ACCEPT 2>/dev/null; do :; done
                    while $cmd -D OUTPUT ${iface}-p tcp --dport $PORT -m owner --uid-owner $SCENE_UID -j ACCEPT 2>/dev/null; do :; done
                    while $cmd -D OUTPUT ${iface}-p tcp --dport $PORT -j REJECT --reject-with tcp-reset 2>/dev/null; do :; done
                done
                
                # Insert rules (in reverse order so they appear correctly at the top)
                $cmd -I OUTPUT 1 -p tcp --dport $PORT -j REJECT --reject-with tcp-reset
                $cmd -I OUTPUT 1 -p tcp --dport $PORT -m owner --uid-owner $SCENE_UID -j ACCEPT
                $cmd -I OUTPUT 1 -p tcp --dport $PORT -m owner --uid-owner 2000 -j ACCEPT
                $cmd -I OUTPUT 1 -p tcp --dport $PORT -m owner --uid-owner 0 -j ACCEPT
            done
        done
        log_msg "Rules re-applied successfully."
    fi

    # Determine sleep interval
    CURRENT_TIME=$(date +%s)
    ELAPSED=$((CURRENT_TIME - BOOT_START_TIME))
    
    if [ $ELAPSED -lt $FAST_LOOP_DURATION ]; then
        sleep 2
    else
        sleep 15
    fi
done
