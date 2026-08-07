#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPS_DIR="${DEPS_DIR:-$ROOT/deps}"
PREFIX="${PREFIX:-$DEPS_DIR/android-arm64}"
ANDROID_API="${ANDROID_API:-26}"
ANDROID_NDK="${ANDROID_NDK:-${ANDROID_NDK_HOME:-}}"
JOBS="${JOBS:-$(nproc)}"

ZLIB_COMMIT="${ZLIB_COMMIT:-51b7f2abdade71cd9bb0e7a373ef2610ec6f9daf}"
ELFUTILS_COMMIT="${ELFUTILS_COMMIT:-18a015c0b0787ba5acb39801ab7c17dac50f584d}"
LIBBPF_COMMIT="${LIBBPF_COMMIT:-f7081a6baf3f54949aacb8c2fc11bb30783b83e9}"

fail() {
    echo "[ERROR] $*" >&2
    exit 1
}

[[ -n "$ANDROID_NDK" ]] || fail "Set ANDROID_NDK or ANDROID_NDK_HOME"

HOST_TAG="linux-x86_64"
TOOLCHAIN="$ANDROID_NDK/toolchains/llvm/prebuilt/$HOST_TAG"
export AR="$TOOLCHAIN/bin/llvm-ar"
export AS="$TOOLCHAIN/bin/llvm-as"
export CC="$TOOLCHAIN/bin/aarch64-linux-android${ANDROID_API}-clang"
export CXX="$TOOLCHAIN/bin/aarch64-linux-android${ANDROID_API}-clang++"
export LD="$TOOLCHAIN/bin/ld.lld"
export RANLIB="$TOOLCHAIN/bin/llvm-ranlib"
export STRIP="$TOOLCHAIN/bin/llvm-strip"
export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig"
export PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig"
export UAPI_COMPAT_CFLAGS="-D__user= -D__force= -D__iomem= -D__must_check= -DSHT_GNU_verdef=0x6ffffffd -DSHT_GNU_verneed=0x6ffffffe -DSHT_GNU_versym=0x6fffffff"
export CFLAGS="${CFLAGS:-} -fPIC $UAPI_COMPAT_CFLAGS"
export CPPFLAGS="${CPPFLAGS:-} -I$PREFIX/include"
export LDFLAGS="${LDFLAGS:-}"

for tool in "$AR" "$CC" "$CXX" "$LD" "$RANLIB" "$STRIP"; do
    [[ -x "$tool" ]] || fail "Android NDK tool is missing: $tool"
done

mkdir -p "$DEPS_DIR/src" "$PREFIX/include" "$PREFIX/lib/pkgconfig"
cd "$DEPS_DIR/src"

checkout_exact_commit() {
    local destination="$1"
    local repository_url="$2"
    local commit="$3"
    local actual

    [[ "$commit" =~ ^[0-9a-fA-F]{40}$ ]] || fail "invalid commit SHA for $destination"

    if [[ -d "$destination/.git" ]]; then
        actual="$(git -C "$destination" rev-parse HEAD 2>/dev/null || true)"
        if [[ "${actual,,}" != "${commit,,}" ]]; then
            rm -rf "$destination"
        fi
    elif [[ -e "$destination" ]]; then
        rm -rf "$destination"
    fi

    if [[ ! -d "$destination/.git" ]]; then
        git init -q "$destination"
        git -C "$destination" remote add origin "$repository_url"
        git -C "$destination" fetch -q --no-tags --depth=1 origin "$commit"
        git -C "$destination" checkout -q --detach FETCH_HEAD
    fi

    actual="$(git -C "$destination" rev-parse HEAD)"
    [[ "${actual,,}" == "${commit,,}" ]] || fail "$destination checkout mismatch"

    # Cached source directories may contain generated or locally modified
    # files from a previous partial build. Reset before every reuse so the
    # declared commit is also the actual working-tree input.
    git -C "$destination" reset -q --hard "$commit"
    git -C "$destination" clean -q -ffdx
}

if [[ ! -f "$PREFIX/include/libintl.h" ]]; then
    cat > "$PREFIX/include/libintl.h" <<'EOF_STUB'
#ifndef HIDEPORT_STUB_LIBINTL_H
#define HIDEPORT_STUB_LIBINTL_H
#define gettext(String) (String)
#define dgettext(Domain, String) (String)
#define dcgettext(Domain, String, Category) (String)
#define ngettext(String1, String2, N) ((N) == 1 ? (String1) : (String2))
#define dngettext(Domain, String1, String2, N) ((N) == 1 ? (String1) : (String2))
#define dcngettext(Domain, String1, String2, N, Category) ((N) == 1 ? (String1) : (String2))
#define textdomain(Domain) (Domain)
#define bindtextdomain(Domain, Directory) (Directory)
#define bind_textdomain_codeset(Domain, Codeset) (Codeset)
#endif
EOF_STUB
fi

if [[ ! -f "$PREFIX/lib/libz.a" ]]; then
    echo "==> Building zlib at $ZLIB_COMMIT"
    checkout_exact_commit zlib https://github.com/madler/zlib.git "$ZLIB_COMMIT"
    (
        cd zlib
        CHOST=aarch64-linux-android ./configure --static --prefix="$PREFIX"
        make -j"$JOBS"
        make install
    )
fi

if [[ ! -f "$PREFIX/lib/libelf.a" ]]; then
    echo "==> Building elfutils at $ELFUTILS_COMMIT"
    checkout_exact_commit elfutils https://github.com/libbpf/elfutils-mirror.git "$ELFUTILS_COMMIT"
    (
        cd elfutils
        autoreconf -fi
        ac_cv_search_argp_parse='none required' \
        ac_cv_func_argp_parse=yes \
        ac_cv_search__obstack_free='none required' \
        ac_cv_func__obstack_free=yes \
        CPPFLAGS="$CPPFLAGS" \
        ./configure \
            --host=aarch64-linux-android \
            --prefix="$PREFIX" \
            --disable-debuginfod \
            --disable-libdebuginfod \
            --disable-debuginfod-urls \
            --disable-nls \
            --disable-shared \
            --enable-static \
            --without-bzlib \
            --without-lzma \
            --without-zstd
        make -j"$JOBS" -C libelf CPPFLAGS="$CPPFLAGS" libelf.a
        install -d "$PREFIX/lib" "$PREFIX/include"
        install -m 0644 libelf/libelf.a "$PREFIX/lib/libelf.a"
        install -m 0644 libelf/libelf.h libelf/gelf.h libelf/nlist.h "$PREFIX/include/"
    )
fi

cat > "$PREFIX/lib/pkgconfig/libelf.pc" <<EOF_PC
prefix=$PREFIX
exec_prefix=\${prefix}
libdir=\${prefix}/lib
includedir=\${prefix}/include
Name: libelf
Description: ELF object file access library
Version: 0.191
Libs: -L\${libdir} -lelf
Cflags: -I\${includedir}
EOF_PC

if [[ ! -f "$PREFIX/lib/libbpf.a" ]]; then
    echo "==> Building libbpf at $LIBBPF_COMMIT"
    checkout_exact_commit libbpf https://github.com/libbpf/libbpf.git "$LIBBPF_COMMIT"
    (
        cd libbpf/src
        make -j"$JOBS" \
            CC="$CC" AR="$AR" RANLIB="$RANLIB" \
            BUILD_STATIC_ONLY=1 OBJDIR=build PREFIX="$PREFIX" \
            INCLUDEDIR="$PREFIX/include" LIBDIR="$PREFIX/lib" \
            UAPIDIR="$PREFIX/include" \
            CFLAGS="-I$PREFIX/include -fPIC $UAPI_COMPAT_CFLAGS" \
            LDFLAGS="-L$PREFIX/lib"
        make install \
            BUILD_STATIC_ONLY=1 OBJDIR=build PREFIX="$PREFIX" \
            INCLUDEDIR="$PREFIX/include" LIBDIR="$PREFIX/lib" \
            UAPIDIR="$PREFIX/include"
    )
fi

cat > "$PREFIX/build-inputs.txt" <<EOF_INPUTS
android_api=$ANDROID_API
zlib_commit=$ZLIB_COMMIT
elfutils_commit=$ELFUTILS_COMMIT
libbpf_commit=$LIBBPF_COMMIT
EOF_INPUTS

for artifact in "$PREFIX/lib/libz.a" "$PREFIX/lib/libelf.a" "$PREFIX/lib/libbpf.a"; do
    [[ -s "$artifact" ]] || fail "dependency artifact is missing: $artifact"
done

cat <<EOF
Dependencies are ready:
  PREFIX=$PREFIX
  ZLIB_COMMIT=$ZLIB_COMMIT
  ELFUTILS_COMMIT=$ELFUTILS_COMMIT
  LIBBPF_COMMIT=$LIBBPF_COMMIT
EOF
