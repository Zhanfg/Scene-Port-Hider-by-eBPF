#!/system/bin/sh

SKIPUNZIP=0

# ── abort fallback (in case the installer framework hasn't defined it) ──
if ! command -v abort >/dev/null 2>&1; then
    abort() {
        ui_print "$1" 2>/dev/null || echo "$1"
        [ -d "$MODPATH" ] && rm -rf "$MODPATH"
        exit 1
    }
fi

# ── SHA-256 helper ──
calc_sha256() {
    local file="$1"
    local line

    if command -v sha256sum >/dev/null 2>&1; then
        line="$(sha256sum "$file" 2>/dev/null)" || return 1
    elif command -v toybox >/dev/null 2>&1; then
        line="$(toybox sha256sum "$file" 2>/dev/null)" || return 1
    elif command -v busybox >/dev/null 2>&1; then
        line="$(busybox sha256sum "$file" 2>/dev/null)" || return 1
    else
        return 1
    fi

    echo "${line%% *}"
}

extract_package_file() {
    local archive_path="$1"
    local destination="$2"

    [ -n "$ZIPFILE" ] || return 1
    command -v unzip >/dev/null 2>&1 || return 1
    unzip -p "$ZIPFILE" "$archive_path" > "$destination" 2>/dev/null
    [ -s "$destination" ]
}

manifest_value() {
    local manifest="$1"
    local key="$2"
    sed -n "s/^${key}=//p" "$manifest" | head -n 1
}

ui_print "- Installing Scene Port Hider by eBPF"

expected_file="$MODPATH/kernel_btf.sha256"
manifest_file="$MODPATH/build-manifest.txt"
loader_file="$MODPATH/system/bin/hideport_loader"
tmp_expected="${TMPDIR:-/dev}/hideSceneport_kernel_btf.sha256"
tmp_manifest="${TMPDIR:-/dev}/hideSceneport_build_manifest.txt"
current_btf="/sys/kernel/btf/vmlinux"

# Try extracting required metadata from the ZIP when the installer framework
# has not yet unpacked it to MODPATH.
if [ ! -f "$expected_file" ] && extract_package_file kernel_btf.sha256 "$tmp_expected"; then
    expected_file="$tmp_expected"
fi
if [ ! -f "$manifest_file" ] && extract_package_file build-manifest.txt "$tmp_manifest"; then
    manifest_file="$tmp_manifest"
fi

if [ ! -f "$expected_file" ]; then
    abort "! No kernel BTF fingerprint found. Rebuild with the target kernel BTF."
fi
if [ ! -f "$manifest_file" ]; then
    abort "! No build-manifest.txt found in module package"
fi
if [ ! -s "$loader_file" ]; then
    abort "! Missing hideport_loader in module package"
fi

read -r expected < "$expected_file"
case "$expected" in
    ''|*[!0-9a-f]*) abort "! Invalid kernel BTF fingerprint in module package" ;;
esac
[ "${#expected}" -eq 64 ] || abort "! Invalid kernel BTF fingerprint length"

expected_loader="$(manifest_value "$manifest_file" loader_sha256)"
case "$expected_loader" in
    ''|*[!0-9a-f]*) abort "! Invalid loader SHA-256 in build manifest" ;;
esac
[ "${#expected_loader}" -eq 64 ] || abort "! Invalid loader SHA-256 length"

actual_loader="$(calc_sha256 "$loader_file")" || abort "! Failed to calculate loader SHA-256"
if [ "$expected_loader" != "$actual_loader" ]; then
    abort "! hideport_loader does not match build-manifest.txt"
fi
ui_print "- Loader integrity matched build manifest"

if [ ! -r "$current_btf" ]; then
    abort "! Cannot read $current_btf on this device"
fi

actual="$(calc_sha256 "$current_btf")" || abort "! Failed to calculate current kernel BTF fingerprint"

ui_print "- Expected kernel BTF: $expected"
ui_print "- Current  kernel BTF: $actual"

if [ "$expected" != "$actual" ]; then
    abort "! Kernel BTF mismatch. This module was built for another kernel/device."
fi

ui_print "- Kernel BTF matched"
ui_print "- Edit hideport.conf if your package or ports differ"

rm -rf "$MODPATH/service.d" "$MODPATH/hide_scene_port.sh"

# ── Permissions ──
set_permissions() {
    set_perm_recursive "$MODPATH" 0 0 0755 0644
    set_perm "$MODPATH/post-fs-data.sh" 0 0 0755
    set_perm "$MODPATH/service.sh" 0 0 0755
    set_perm "$MODPATH/hideport_start.sh" 0 0 0755
    set_perm "$MODPATH/system/bin/hideport_loader" 0 0 0755
}
