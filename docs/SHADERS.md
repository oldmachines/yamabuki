# CRT shaders

How the SDL player's shader pipeline works and why the shaders are baked on the build host. Moved here from the README; the short version is in the README's *Shaders* section.

`--shader <name>` runs the frame through a libretro CRT shader chain, and
`,` / `.` cycle through the rest of them without restarting. The cycle only
walks presets baked for the GPU profile you actually got, so it can never land
on a shader this device cannot compile; the replacement chain is built before
the incumbent is torn down, so a preset that fails costs a printed line and not
the picture. The shipped set is listed in
[`shaders/presets.conf`](../shaders/presets.conf) — the
cheap single-pass ones (`zfast-crt`, `crt-pi`, `crt-lottes-fast`,
`crt-easymode`, `sharp-bilinear`) and the heavyweights (`crt-royale`,
`crt-guest-advanced`, `crt-lottes`, `crt-easymode-halation`, `gtu-v050`,
`crt-geom`, `crt-hyllian`). Each is tagged `handheld` or `desktop`, and the tag
is printed at startup: it is a claim about a Cortex-A53-class device, not a
rating. crt-royale on a Mali-G31 is a slideshow, and the package says so rather
than letting you find out.

## The shaders are transpiled offline

These are libretro *slang* presets — Vulkan GLSL. Running them the way RetroArch
does means linking glslang and SPIRV-Cross (two C++ libraries, ~150k lines) into
the binary and compiling shaders on the device at load. Yamabuki does the
compile on the build host instead and ships the result:

```
  .slangp preset ──┐
  .slang shaders ──┤  tools/transpile_shaders.py   (build host, never shipped)
  .png LUTs      ──┘
        │
        ├─ glslang ──────► SPIR-V
        ├─ SPIRV-Cross ──► GLSL ES 300 / GLSL 330 / GLSL ES 100
        ├─ reflection ───► uniform offsets, types, sampler names
        └─ zlib ─────────► raw RGBA LUTs
        │
        ▼
  shaders/<profile>/<preset>/{preset.conf, pass*.vert, pass*.frag, *.bin}
        │
        ▼
  yamabuki-sdl  ── reads bytes, plumbs them into offsets
```

What that buys:

- **The emulator contains no shader compiler.** No glslang, no SPIRV-Cross, no
  SPIR-V, no C++ — and no PNG decoder either, since crt-royale's phosphor masks
  are decoded to raw RGBA at bake time. The runtime never parses a format it can
  avoid parsing.
- **The design goals survive.** The core stays pure Zig, `zig build` still needs
  nothing installed, and the handheld package is still a static musl binary that
  passes its own no-dynamic-deps assertion. A runtime shader compiler would have
  cost all three.
- **Nothing is compiled on the device.** A Cortex-A53 does not spend its startup
  budget parsing GLSL, and a driver bug in a vendor's shader compiler surfaces on
  the build machine rather than in someone's hands.
- **Every ambiguity is resolved once, where it can fail loudly.** Uniform
  offsets, sampler bindings, pass aliases, feedback targets, LUT dimensions — all
  settled at bake time. The runtime's job is reduced to memcpy-into-offset, which
  is why it can be allocation-free after `init`.
- **A shader that cannot work is absent, not broken.** A preset is written for a
  profile only if it transpiled *and* every uniform in it mapped to a semantic
  the runtime supplies. Failures are printed at bake, not discovered on a
  handheld.

The one cost is that adding a shader is a build step, not a drop-in file. Given
the target device, that trade is not close.

**glslang and SPIRV-Cross are built by `zig c++`.** Zig ships clang, so
`tools/build_shader_tools.sh` compiles both from pinned upstream source with the
toolchain this repo already requires — no system g++, no Vulkan SDK, no package
manager. The prerequisites for the whole shader pipeline are the pinned Zig,
cmake, and ninja. This is also the honest reason the *offline* route was chosen
over linking them in: it was never that Zig couldn't build them (it can, and
does), but that shipping a 150k-line C++ compiler to a handheld to do work that
can be done once on a laptop is the wrong shape.

Three GLSL profiles are baked and the frontend picks one at startup: **GL ES 3**
(the handheld primary), **GL 3.3** (desktop), and **GL ES 2** (for Mali-400-class
parts). A preset is only written for a profile if it actually transpiled *and*
every uniform in it mapped to a semantic the runtime supplies — so a preset
appearing in the directory and a preset running on your GPU are the same
statement. Five of the thirty-six (preset, profile) pairs are honestly skipped:
crt-geom and crt-hyllian build their sampling kernels with multidimensional
array constructors, which no ESSL below 310 has, and crt-guest-advanced needs
`textureSize`, which ESSL 100 lacks. If no profile works — an old GLES2 chip, no
GL driver at all, CI's dummy video driver — the frontend prints why and falls
back to the software blit. A missing shader never costs you the emulator.
