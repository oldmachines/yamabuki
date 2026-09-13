# tools/

Host-side scripts. None of them ship; each runs on the build machine and
either fetches something the build needs or turns one artefact into another.

| Tool | What it does | Used by |
|---|---|---|
| `install_zig.sh` | Installs the Zig release named in `.zigversion` from the PyPI `ziglang` wheel, for machines where ziglang.org is unreachable. | README |
| `fetch_test_data.sh` | Shallow-clones the SingleStepTests 65816 and SPC700 vectors and the PeterLemon test ROMs into `test-data/` (gitignored). | every `test-*` step |
| `fetch_shaders.sh` | Clones the pinned libretro slang-shaders into `shader-src/` (gitignored, GPL, their authors'). | `zig build shaders` |
| `build_shader_tools.sh` | Builds glslang and SPIRV-Cross from pinned source into `.shader-tools/` using `zig c++` — no system compiler, no Vulkan SDK. | `zig build shaders`, CI |
| `transpile_shaders.py` | Bakes every preset in `shaders/presets.conf` to GLSL ES 3 / GL 3.3 / GLSL ES 1 plus a reflected-uniform manifest; decodes LUT PNGs to raw RGBA. Skips (and prints) any pair a profile cannot honour. | `zig build shaders` |
| `package_handheld.sh` | Builds the static musl handheld package and asserts it has no dynamic libc and no `NEEDED` shared object (`--verify-only` for CI). | README, CI |
| `capture_shaders.py` | Drives `yamabuki-sdl --shot`/`--shot-frames` to capture pixel-aligned before/after shader figures for `site/shots/`. | the landing page and the design deck |
| `wgdemo.zig` | Emits the smallest honest game that survives `--gen-sa1-patch --whole-game` (`zig build wg-demo`); `test-patchgen` builds it in-process. | `build.zig` |
| `dis65816.py` | A minimal 65816 disassembler for reading ROM call sites while debugging conversions. | SA-1 work (see `docs/SM_SA1_FINDINGS.md`) |
| `sm_decomp.py` | A port of Super Metroid's `$80:B0FF` decompressor, to check what a decompression site expands to. | SA-1 work |
| `sm_disasm_oracle.py` | Audits the generator's instruction boundaries against the InsaneFirebat Super Metroid disassembly and exports a per-byte code/data verdict (`--code-map`). It caught a boundary bug that shipped in v66-v68. | SA-1 work, `tests/surfaces/sm-sa1/README.md` |
| `sm_surfaces.py` | Regenerates Super Metroid's scripted `.ymv` verification surfaces. | `tests/surfaces/sm-sa1/scripted/` |
