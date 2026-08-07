#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ZIP="${1:-$ROOT/../hideSceneport_module.zip}"

fail() {
    echo "[ERROR] $*" >&2
    exit 1
}

loader="$ROOT/system/bin/hideport_loader"
[[ -s "$loader" ]] || fail "Missing executable: $loader; run ./build.sh first"
[[ -f "$ROOT/module_process.sh" ]] || fail "Missing module_process.sh"

btf_source=""
for candidate in "$ROOT/btf/vmlinux.btf" "$ROOT/vmlinux.btf"; do
    if [[ -f "$candidate" ]]; then
        btf_source="$candidate"
        break
    fi
done
[[ -n "$btf_source" ]] || fail "No target vmlinux.btf found; refusing to create an uninstallable package"

btf_magic="$(xxd -p -l 4 "$btf_source")"
[[ "$btf_magic" == "9feb0100" ]] || fail "Invalid BTF magic in $btf_source"

btf_sha="$(sha256sum "$btf_source" | awk '{print $1}')"
[[ "$btf_sha" =~ ^[0-9a-f]{64}$ ]] || fail "Failed to calculate BTF SHA-256"
printf '%s\n' "$btf_sha" > "$ROOT/kernel_btf.sha256"

loader_sha="$(sha256sum "$loader" | awk '{print $1}')"
source_commit="unknown"
if git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    source_commit="$(git -C "$ROOT" rev-parse HEAD)"
fi

module_version="$(sed -n 's/^version=//p' "$ROOT/module.prop" | head -n 1)"
cat > "$ROOT/build-manifest.txt" <<EOF_MANIFEST
module_version=$module_version
source_commit=$source_commit
kernel_btf_sha256=$btf_sha
loader_sha256=$loader_sha
EOF_MANIFEST

if [[ -n "${PREFIX:-}" && -f "$PREFIX/build-inputs.txt" ]]; then
    cat "$PREFIX/build-inputs.txt" >> "$ROOT/build-manifest.txt"
elif [[ -f "$HOME/hideport-deps/android-arm64/build-inputs.txt" ]]; then
    cat "$HOME/hideport-deps/android-arm64/build-inputs.txt" >> "$ROOT/build-manifest.txt"
fi

(
    cd "$ROOT"
    files=(
        module.prop
        hideport.conf
        post-fs-data.sh
        service.sh
        hideport_start.sh
        module_process.sh
        customize.sh
        uninstall.sh
        kernel_btf.sha256
        build-manifest.txt
        system/bin/hideport_loader
    )

    rm -f "$ZIP"
    zip -X -r "$ZIP" "${files[@]}" -x '*/.git/*'
)

[[ -s "$ZIP" ]] || fail "Package was not created: $ZIP"
sha256sum "$ZIP" > "$ZIP.sha256"
echo "Wrote $ZIP and $ZIP.sha256"
