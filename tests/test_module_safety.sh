#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
tmp_root="$(mktemp -d)"
sleeper=""
trap '[[ -n "$sleeper" ]] && kill "$sleeper" 2>/dev/null || true; rm -rf "$tmp_root"' EXIT

assert_fails() {
    if "$@"; then
        echo "expected command to fail: $*" >&2
        exit 1
    fi
}

# Process helper tests use a real live PID and a controlled /proc fixture.
loader="$tmp_root/hideport_loader"
printf '#!/bin/sh\n' > "$loader"
chmod +x "$loader"
sleep 60 &
sleeper=$!

proc_root="$tmp_root/proc"
mkdir -p "$proc_root/$sleeper"
ln -s "$loader" "$proc_root/$sleeper/exe"
printf '%s\0%s\0' "$loader" '--port' > "$proc_root/$sleeper/cmdline"

PROC_ROOT="$proc_root"
export PROC_ROOT
# shellcheck source=../module_process.sh
. "$repo_root/module_process.sh"

process_matches_loader "$sleeper" "$loader"
assert_fails process_matches_loader "$sleeper" "$tmp_root/other_loader"
assert_fails process_matches_loader "not-a-pid" "$loader"

pidfile="$tmp_root/loader.pid"
write_pidfile_atomic "$pidfile" "$sleeper"
[[ "$(read_verified_pidfile "$pidfile" "$loader")" = "$sleeper" ]]

rm -f "$proc_root/$sleeper/exe"
ln -s "$tmp_root/unrelated" "$proc_root/$sleeper/exe"
printf '%s\0' "$tmp_root/unrelated" > "$proc_root/$sleeper/cmdline"
assert_fails read_verified_pidfile "$pidfile" "$loader"

# Package tests run from an isolated copy and never modify the checkout.
fixture="$tmp_root/package-fixture"
mkdir -p "$fixture/system/bin" "$fixture/btf"
for file in module.prop hideport.conf post-fs-data.sh service.sh hideport_start.sh \
            module_process.sh customize.sh uninstall.sh package.sh; do
    cp "$repo_root/$file" "$fixture/$file"
done
printf '#!/system/bin/sh\n' > "$fixture/system/bin/hideport_loader"
chmod +x "$fixture/system/bin/hideport_loader"

assert_fails bash "$fixture/package.sh" "$tmp_root/without-btf.zip"

# BTF magic bytes 9f eb 01 00 followed by fixture payload.
printf '\x9f\xeb\x01\x00fixture-btf\n' > "$fixture/btf/vmlinux.btf"
PREFIX="$tmp_root/prefix"
export PREFIX
mkdir -p "$PREFIX"
cat > "$PREFIX/build-inputs.txt" <<'EOF_INPUTS'
android_api=26
zlib_commit=fixture
elfutils_commit=fixture
libbpf_commit=fixture
EOF_INPUTS

bash "$fixture/package.sh" "$tmp_root/with-btf.zip"
[[ -s "$tmp_root/with-btf.zip" ]]
[[ -s "$tmp_root/with-btf.zip.sha256" ]]
unzip -t "$tmp_root/with-btf.zip" >/dev/null
for required in kernel_btf.sha256 build-manifest.txt module_process.sh system/bin/hideport_loader; do
    unzip -Z1 "$tmp_root/with-btf.zip" | grep -Fqx "$required"
done

grep -Eq '^[0-9a-f]{64}$' "$fixture/kernel_btf.sha256"
grep -Fq 'kernel_btf_sha256=' "$fixture/build-manifest.txt"
grep -Fq 'loader_sha256=' "$fixture/build-manifest.txt"

echo "All module safety tests passed"
