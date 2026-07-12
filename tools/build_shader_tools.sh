#!/usr/bin/env bash
# Build glslang and SPIRV-Cross into .shader-tools/ (gitignored).
#
# These run on the *build host* only -- they transpile slang shaders to GLSL
# ahead of time (tools/transpile_shaders.py). Nothing they produce is linked
# into the emulator: yamabuki-sdl ships no shader compiler, no SPIR-V, and no
# C++. That is the whole point of baking offline rather than at runtime, and it
# is what keeps the handheld package a static musl binary with no dependencies.
#
# Zig is the C++ compiler here (it ships clang), so the only prerequisites are
# the toolchain this repo already pins plus cmake and ninja -- no system g++, no
# Vulkan SDK.
set -euo pipefail

cd "$(dirname "$0")/.."

GLSLANG_REV="76038dbb8708236407e121fa11e99a96377b88ad"
SPIRV_CROSS_REV="6c09849fe88c48eaed08413aa022aaa136a3a057"

ZIG="${ZIG:-zig}"
command -v "$ZIG" >/dev/null || { echo "zig not found (set \$ZIG or run tools/install_zig.sh)" >&2; exit 1; }
command -v cmake >/dev/null || { echo "cmake not found" >&2; exit 1; }

out="$(pwd)/.shader-tools"
src="${out}/src"
mkdir -p "${out}/bin" "${src}"

# CMake needs a compiler it can exec directly, so wrap `zig c++`/`zig cc`.
cat > "${out}/zig-cxx" <<EOF
#!/usr/bin/env bash
exec "$(command -v "$ZIG")" c++ "\$@"
EOF
cat > "${out}/zig-cc" <<EOF
#!/usr/bin/env bash
exec "$(command -v "$ZIG")" cc "\$@"
EOF
cat > "${out}/zig-ar" <<EOF
#!/usr/bin/env bash
exec "$(command -v "$ZIG")" ar "\$@"
EOF
cat > "${out}/zig-ranlib" <<EOF
#!/usr/bin/env bash
exec "$(command -v "$ZIG")" ranlib "\$@"
EOF
chmod +x "${out}"/zig-cxx "${out}"/zig-cc "${out}"/zig-ar "${out}"/zig-ranlib

CM_ARGS=(
    -G Ninja
    -DCMAKE_BUILD_TYPE=Release
    -DCMAKE_CXX_COMPILER="${out}/zig-cxx"
    -DCMAKE_C_COMPILER="${out}/zig-cc"
    -DCMAKE_AR="${out}/zig-ar"
    -DCMAKE_RANLIB="${out}/zig-ranlib"
)

fetch() {
    local url="$1" dir="$2" rev="$3"
    if [ ! -d "${dir}/.git" ]; then
        git init -q "${dir}"
        git -C "${dir}" remote add origin "${url}"
    fi
    git -C "${dir}" fetch --depth 1 origin "${rev}"
    git -C "${dir}" checkout -q FETCH_HEAD
}

fetch https://github.com/KhronosGroup/glslang.git "${src}/glslang" "${GLSLANG_REV}"
fetch https://github.com/KhronosGroup/SPIRV-Cross.git "${src}/SPIRV-Cross" "${SPIRV_CROSS_REV}"

# ENABLE_OPT=OFF drops the SPIRV-Tools dependency; we do not optimise the SPIR-V,
# SPIRV-Cross consumes it directly.
cmake -S "${src}/glslang" -B "${out}/build-glslang" "${CM_ARGS[@]}" \
    -DENABLE_OPT=OFF -DGLSLANG_TESTS=OFF -DGLSLANG_ENABLE_INSTALL=OFF -DBUILD_EXTERNAL=OFF
cmake --build "${out}/build-glslang" --parallel

cmake -S "${src}/SPIRV-Cross" -B "${out}/build-spirv-cross" "${CM_ARGS[@]}" \
    -DSPIRV_CROSS_ENABLE_TESTS=OFF -DSPIRV_CROSS_CLI=ON
cmake --build "${out}/build-spirv-cross" --parallel

find "${out}/build-glslang" -name 'glslang' -o -name 'glslangValidator' -type f \
    | head -1 | xargs -I{} cp {} "${out}/bin/glslang"
cp "${out}/build-spirv-cross/spirv-cross" "${out}/bin/spirv-cross"

echo "shader tools built:"
"${out}/bin/glslang" --version | head -1
"${out}/bin/spirv-cross" --help 2>&1 | head -1 || true
