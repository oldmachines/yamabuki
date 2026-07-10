#!/usr/bin/env bash
# Install the pinned Zig toolchain from PyPI (the Zig project publishes
# official binaries there as the `ziglang` wheel). Useful in environments
# where ziglang.org is unreachable; elsewhere any install method works as
# long as the version matches .zigversion.
set -euo pipefail

cd "$(dirname "$0")/.."
ZIG_VERSION="$(tr -d '[:space:]' < .zigversion)"

python3 -m pip install --quiet "ziglang==${ZIG_VERSION}"
ZIG_PKG_DIR="$(python3 -c 'import ziglang, os; print(ziglang.__path__[0])')"

mkdir -p "${HOME}/.local/bin"
ln -sf "${ZIG_PKG_DIR}/zig" "${HOME}/.local/bin/zig"

echo "zig ${ZIG_VERSION} installed at ${HOME}/.local/bin/zig"
echo "ensure ${HOME}/.local/bin is on your PATH"
