#!/usr/bin/env bash
# Fetch the libretro slang-shader sources into shader-src/ (gitignored).
#
# Same rule as the test data: pinned upstream, never vendored. The shaders are
# GPL-licensed and belong to their authors; this repo carries only the list of
# which ones we ship (shaders/presets.conf) and the baked output.
#
# Pin the revision so a bake is reproducible. Bump deliberately, then re-run
# tools/transpile_shaders.py and check the result.
set -euo pipefail

cd "$(dirname "$0")/.."

SLANG_SHADERS_REV="2793d819aeebe17503cc49e2e946d4b9cea0e2a2"

mkdir -p shader-src
dir="shader-src/slang-shaders"

if [ -d "${dir}/.git" ]; then
    git -C "${dir}" fetch --depth 1 origin "${SLANG_SHADERS_REV}"
else
    git init -q "${dir}"
    git -C "${dir}" remote add origin https://github.com/libretro/slang-shaders.git
    git -C "${dir}" fetch --depth 1 origin "${SLANG_SHADERS_REV}"
fi
git -C "${dir}" checkout -q FETCH_HEAD

echo "slang-shaders at ${SLANG_SHADERS_REV} under ${dir}/"
