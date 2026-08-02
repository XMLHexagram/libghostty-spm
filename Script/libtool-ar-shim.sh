#!/bin/bash
#
# Drop-in replacement for `libtool -static -o OUT IN...`, for local builds.
#
# ## Why this exists
# Xcode 27's libtool refuses archive members whose Mach-O header isn't 8-byte
# aligned, and zig 0.15.2 emits plenty of those in its vendored C dependencies
# (oniguruma, freetype, zlib, harfbuzz…). It doesn't fail — it prints
# `ignoring archive member 'ascii.o' - 64-bit mach-o not 8-byte aligned` and
# carries on, so the combined archive is silently missing those objects. The
# failure only surfaces much later, as `Undefined symbols: _OnigEncodingASCII`
# when an app tries to link the result.
#
# `ar` has no such check and preserves every member, so unpack each input and
# repack with `ar`. Verified against the published boite-mirror.1.2.0 archive:
# the symbol is present as a definition (`D`), not just a reference (`U`).
#
# ## Wiring
# ghostty's `src/build/LibtoolStep.zig` runs a bare `libtool`, resolved through
# PATH — so putting a directory containing a `libtool` symlink to this script
# ahead of PATH is enough. No ghostty patch needed, which matters: this is a
# property of THIS machine's toolchain, not something to carry upstream.
set -euo pipefail

args=("$@")
out=""
inputs=()
i=0
while [ $i -lt ${#args[@]} ]; do
    case "${args[$i]}" in
        -static) ;;
        -o) i=$((i + 1)); out="${args[$i]}" ;;
        *) inputs+=("${args[$i]}") ;;
    esac
    i=$((i + 1))
done

if [ -z "$out" ] || [ ${#inputs[@]} -eq 0 ]; then
    # Not a shape we understand — hand it to the real libtool untouched.
    exec /usr/bin/libtool "$@"
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

n=0
for lib in "${inputs[@]}"; do
    n=$((n + 1))
    d="$work/$n"
    mkdir -p "$d"
    # `ar x` writes members mode 0200 (not even readable), and zig's cache
    # objects are read-only to begin with; make them usable before repacking.
    (cd "$d" && ar x "$lib" && chmod u+rw ./*.o 2>/dev/null || true)
done

# Flatten, disambiguating same-named members across archives (several of these
# libraries ship their own `util.o`). Order is irrelevant: `ar s` writes a
# symbol index covering the whole archive.
flat="$work/flat"
mkdir -p "$flat"
for d in "$work"/[0-9]*; do
    [ -d "$d" ] || continue
    for o in "$d"/*.o; do
        [ -f "$o" ] || continue
        cp "$o" "$flat/$(basename "$d")-$(basename "$o")"
    done
done

rm -f "$out"
(cd "$flat" && ar crs "$out" ./*.o)
