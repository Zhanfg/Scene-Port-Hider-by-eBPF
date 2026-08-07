#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ANDROID_API="${ANDROID_API:-26}"
ANDROID_NDK="${ANDROID_NDK:-${ANDROID_NDK_HOME:-}}"
DEPS_DIR="${DEPS_DIR:-$HOME/hideport-deps}"
PREFIX="${PREFIX:-$DEPS_DIR/android-arm64}"
BPFTOOL="${BPFTOOL:-}"

fail() {
    echo "[ERROR] $*" >&2
    exit 1
}

need_cmd() {
    command -v "$1" >/dev/null 2>&1
}

if [[ -z "$BPFTOOL" ]]; then
    if [[ -x /usr/local/sbin/bpftool ]]; then
        BPFTOOL=/usr/local/sbin/bpftool
    elif need_cmd bpftool; then
        BPFTOOL="$(command -v bpftool)"
    else
        fail "Missing bpftool; set BPFTOOL=/path/to/bpftool"
    fi
fi
[[ -x "$BPFTOOL" ]] || fail "bpftool is not executable: $BPFTOOL"

[[ -n "$ANDROID_NDK" ]] || fail "Set ANDROID_NDK or ANDROID_NDK_HOME to a preinstalled NDK"
ndk_clang="$ANDROID_NDK/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android${ANDROID_API}-clang"
[[ -x "$ndk_clang" ]] || fail "Android NDK clang is missing: $ndk_clang"

btf_file=""
for candidate in "$ROOT/btf/vmlinux.btf" "$ROOT/vmlinux.btf"; do
    if [[ -f "$candidate" ]]; then
        btf_file="$candidate"
        break
    fi
done

if [[ -n "$btf_file" ]]; then
    btf_magic="$(xxd -p -l 4 "$btf_file")"
    if [[ "$btf_magic" != "9feb0100" ]]; then
        fail "Unexpected BTF magic in $btf_file: $btf_magic; expected 9feb0100"
    fi

    echo "==> Generating src/vmlinux.h from $btf_file"
    tmp_header="$ROOT/src/vmlinux.h.tmp"
    rm -f "$tmp_header"
    "$BPFTOOL" btf dump file "$btf_file" format c > "$tmp_header"
    [[ -s "$tmp_header" ]] || fail "bpftool produced an empty vmlinux.h"
    mv "$tmp_header" "$ROOT/src/vmlinux.h"
elif [[ -f "$ROOT/src/vmlinux.h" ]]; then
    echo "==> Using existing src/vmlinux.h"
else
    fail "Missing target kernel BTF or src/vmlinux.h"
fi

echo "==> Building Android arm64 dependencies"
export ANDROID_NDK ANDROID_API DEPS_DIR PREFIX
bash "$ROOT/build_deps_android.sh"

echo "==> Building module binaries"
export LIBBPF_SRC="$PREFIX"
export LIBBPF_HEADERS="$PREFIX/include"
export LIBBPF_LIBDIR="$PREFIX/lib"
export BPFTOOL
bash "$ROOT/build.sh"

echo "==> Packaging module"
bash "$ROOT/package.sh"

echo "Built $ROOT/../hideSceneport_module.zip"
