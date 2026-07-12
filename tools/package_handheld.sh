#!/usr/bin/env bash
#
# Build and package the handheld release artifacts for a musl target, verifying
# they are statically linked (no external shared-library dependencies) so they
# drop onto a stock RetroArch firmware with nothing else to install.
#
#   tools/package_handheld.sh [zig-target]   default: aarch64-linux-musl
#   tools/package_handheld.sh --verify-only [zig-target]
#
# The static-linkage check is the point: it fails loudly if a change pulls in a
# dynamic libc (or any NEEDED shared object), which would break a handheld that
# lacks the matching runtime. CI runs this for every musl cross target.
set -euo pipefail
cd "$(dirname "$0")/.."

verify_only=0
target=aarch64-linux-musl
for arg in "$@"; do
  case "$arg" in
    --verify-only) verify_only=1 ;;
    *) target="$arg" ;;
  esac
done

case "$target" in
  *musl*) ;;
  *) echo "refusing to package '$target': handheld builds must be *-musl (static libc)" >&2; exit 2 ;;
esac

echo ">> building $target (ReleaseFast)"
rm -rf zig-out
zig build -Doptimize=ReleaseFast -Dtarget="$target"

# A statically-linked ELF has no NEEDED shared libraries and no program
# interpreter (executables). Shared objects (the libretro core) are DYN by
# nature but must still carry no NEEDED entries.
fail=0
check() {
  local f="$1"
  if readelf -d "$f" 2>/dev/null | grep -q '(NEEDED)'; then
    echo "NOT STATIC: $f depends on a shared library:" >&2
    readelf -d "$f" | grep '(NEEDED)' >&2
    fail=1
  fi
  if readelf -l "$f" 2>/dev/null | grep -qi 'Requesting program interpreter'; then
    echo "NOT STATIC: $f has a dynamic interpreter" >&2
    fail=1
  fi
}

artifacts=()
for f in zig-out/bin/* zig-out/lib/*; do
  [ -f "$f" ] || continue
  artifacts+=("$f")
  check "$f"
done

if [ "$fail" -ne 0 ]; then
  echo ">> static-linkage check FAILED for $target" >&2
  exit 1
fi
echo ">> static-linkage OK: ${#artifacts[@]} artifact(s) self-contained"
for f in "${artifacts[@]}"; do
  printf '   %-40s %8s bytes\n' "$(basename "$f")" "$(stat -c%s "$f")"
done

if [ "$verify_only" -eq 1 ]; then
  exit 0
fi

pkg="yamabuki-$target"
stage="$(mktemp -d)/$pkg"
mkdir -p "$stage"
cp -r zig-out/bin zig-out/lib "$stage"/ 2>/dev/null || true
tar -czf "$pkg.tar.gz" -C "$(dirname "$stage")" "$pkg"
echo ">> wrote $pkg.tar.gz ($(stat -c%s "$pkg.tar.gz") bytes)"
