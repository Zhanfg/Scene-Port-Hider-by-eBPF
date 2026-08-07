#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$ROOT/src"
OUT="$ROOT/system/bin"

ANDROID_API="${ANDROID_API:-26}"
ANDROID_NDK="${ANDROID_NDK:-${ANDROID_NDK_HOME:-}}"
LIBBPF_SRC="${LIBBPF_SRC:-}"
BPF_CC="${BPF_CC:-clang}"
BPFTOOL="${BPFTOOL:-bpftool}"
TARGET_CC="${TARGET_CC:-}"
VMLINUX_H="${VMLINUX_H:-$SRC/vmlinux.h}"
EXTRA_LDLIBS="${EXTRA_LDLIBS:-}"

fail() {
    echo "[ERROR] $*" >&2
    exit 1
}

[[ -n "$ANDROID_NDK" ]] || fail "Set ANDROID_NDK or ANDROID_NDK_HOME"
[[ -n "$LIBBPF_SRC" ]] || fail "Set LIBBPF_SRC to a libbpf checkout/build directory"
[[ -f "$VMLINUX_H" ]] || fail "Missing $VMLINUX_H; generate it from the target kernel BTF"

if [[ -z "$TARGET_CC" ]]; then
    HOST_TAG="linux-x86_64"
    case "$(uname -s)" in
        Darwin) HOST_TAG="darwin-x86_64" ;;
        MINGW*|MSYS*|CYGWIN*) HOST_TAG="windows-x86_64" ;;
    esac
    TARGET_CC="$ANDROID_NDK/toolchains/llvm/prebuilt/$HOST_TAG/bin/aarch64-linux-android${ANDROID_API}-clang"
fi

if [[ "$BPF_CC" == */* ]]; then
    [[ -x "$BPF_CC" ]] || fail "BPF compiler is not executable: $BPF_CC"
else
    command -v "$BPF_CC" >/dev/null 2>&1 || fail "BPF compiler is missing: $BPF_CC"
fi
if [[ "$BPFTOOL" == */* ]]; then
    [[ -x "$BPFTOOL" ]] || fail "bpftool is not executable: $BPFTOOL"
else
    command -v "$BPFTOOL" >/dev/null 2>&1 || fail "bpftool is missing: $BPFTOOL"
fi
[[ -x "$TARGET_CC" ]] || fail "Android target compiler is missing: $TARGET_CC"

LIBBPF_HEADERS="${LIBBPF_HEADERS:-}"
if [[ -z "$LIBBPF_HEADERS" ]]; then
    for candidate in \
        "$LIBBPF_SRC/include" \
        "$LIBBPF_SRC/src/root/usr/include" \
        "$LIBBPF_SRC/root/usr/include"; do
        if [[ -f "$candidate/bpf/bpf_core_read.h" ]]; then
            LIBBPF_HEADERS="$candidate"
            break
        fi
    done
fi

[[ -n "$LIBBPF_HEADERS" && -f "$LIBBPF_HEADERS/bpf/bpf_core_read.h" ]] || \
    fail "Could not find libbpf headers; set LIBBPF_HEADERS"

LIBBPF_LIBDIR="${LIBBPF_LIBDIR:-$LIBBPF_SRC/src}"
[[ -f "$LIBBPF_LIBDIR/libbpf.a" ]] || fail "Missing $LIBBPF_LIBDIR/libbpf.a"
[[ -f "$LIBBPF_LIBDIR/libelf.a" ]] || fail "Missing $LIBBPF_LIBDIR/libelf.a"
[[ -f "$LIBBPF_LIBDIR/libz.a" ]] || fail "Missing $LIBBPF_LIBDIR/libz.a"

mkdir -p "$OUT"

"$BPF_CC" -target bpf -D__TARGET_ARCH_arm64 -g -O2 \
    -I"$SRC" \
    -I"$LIBBPF_HEADERS" \
    -c "$SRC/hideport.bpf.c" \
    -o "$OUT/hideport.bpf.o"
[[ -s "$OUT/hideport.bpf.o" ]] || fail "BPF object was not generated"

skeleton_tmp="$SRC/hideport.skel.h.tmp"
rm -f "$skeleton_tmp"
"$BPFTOOL" gen skeleton "$OUT/hideport.bpf.o" > "$skeleton_tmp"
[[ -s "$skeleton_tmp" ]] || fail "bpftool generated an empty skeleton"
mv "$skeleton_tmp" "$SRC/hideport.skel.h"

extra_ldlibs=()
if [[ -n "$EXTRA_LDLIBS" ]]; then
    read -r -a extra_ldlibs <<< "$EXTRA_LDLIBS"
fi

"$TARGET_CC" -O2 -Wall -Wextra -static \
    -I"$SRC" \
    -I"$LIBBPF_HEADERS" \
    -L"$LIBBPF_LIBDIR" \
    -o "$OUT/hideport_loader" \
    "$SRC/hideport_loader.c" \
    "$SRC/tls_align.S" \
    -lbpf -lelf -lz "${extra_ldlibs[@]}"
[[ -s "$OUT/hideport_loader" ]] || fail "Android loader was not generated"

chmod 0755 "$OUT/hideport_loader" 2>/dev/null || \
    echo "Warning: could not chmod $OUT/hideport_loader; this is normal on some /mnt/* WSL mounts."
echo "Built $OUT/hideport_loader and $OUT/hideport.bpf.o"
