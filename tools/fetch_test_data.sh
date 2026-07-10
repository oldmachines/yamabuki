#!/usr/bin/env bash
# Fetch test vectors and test ROMs into test-data/ (gitignored — the
# SingleStepTests repos are hundreds of MB and must never be committed).
# Shallow clones; re-running updates existing checkouts.
set -euo pipefail

cd "$(dirname "$0")/.."
mkdir -p test-data

fetch() {
    local url="$1" dir="$2"
    if [ -d "test-data/${dir}/.git" ]; then
        git -C "test-data/${dir}" fetch --depth 1 origin
        git -C "test-data/${dir}" reset --hard origin/HEAD
    else
        git clone --depth 1 "${url}" "test-data/${dir}"
    fi
}

fetch https://github.com/SingleStepTests/65816.git sst-65816
fetch https://github.com/SingleStepTests/spc700.git sst-spc700
fetch https://github.com/PeterLemon/SNES.git snes-roms

echo "test data ready under test-data/"
