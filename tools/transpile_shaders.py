#!/usr/bin/env python3
"""Bake libretro slang shader presets into GLSL the SDL frontend can run.

This is the offline half of shader support. Nothing here ships: it runs on the
build host, drives glslang and SPIRV-Cross over the presets listed in
shaders/presets.conf, and writes a directory of plain GLSL plus a manifest per
(preset, profile). The emulator then contains no shader compiler, no SPIR-V, and
no PNG decoder -- it reads bytes and plumbs them into offsets.

    slang (Vulkan GLSL)
      -> glslang        -> SPIR-V
      -> SPIRV-Cross    -> ESSL 300 / ESSL 100 / GLSL 330   (+ reflection JSON)
      -> preset.conf    -> src/frontends/sdl/preset.zig

Three profiles are emitted per preset, matching the frontend's context ladder:

    essl300   GL ES 3.0   the handheld primary (Mali-G31/G52, Adreno)
    glsl330   GL 3.3      desktop
    essl100   GL ES 2.0   the fallback for Mali-400-class parts

A profile is only written if every stage of every pass actually transpiled *and*
every uniform in it mapped to a semantic the runtime knows how to supply. A
shader that cannot be honoured is dropped from that profile with a printed
reason -- so "the preset is in the directory" and "the preset will run on this
GPU" are the same statement, and the handheld never ships a trap.

Usage:
    tools/fetch_shaders.sh                 # clone slang-shaders (pinned)
    tools/build_shader_tools.sh            # build glslang + SPIRV-Cross
    tools/transpile_shaders.py             # bake into shaders/
    tools/transpile_shaders.py --only crt-lottes --verbose
"""

import argparse
import json
import os
import re
import shutil
import struct
import subprocess
import sys
import tempfile
import zlib
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / "shader-src" / "slang-shaders"
OUT = ROOT / "shaders"
TOOLS = ROOT / ".shader-tools"

# Emitted GLSL profile -> (spirv-cross args, subdirectory).
#
# glsl330 gets --no-420pack-extension: without it, SPIRV-Cross emits
# layout(binding=N) guarded by "#ifdef GL_ARB_shading_language_420pack" --
# but the qualifier itself is unconditional, so on a driver that lacks the
# extension (e.g. macOS's OpenGL, capped at a 4.1 core profile) the shader
# fails to compile rather than falling back. The runtime never needed the
# qualifier anyway: it binds both UBOs (glUniformBlockBinding) and sampler
# units (glUniform1i) explicitly at link time from the manifest, so dropping
# the in-shader binding is free.
PROFILES = {
    "essl300": ["--version", "300", "--es"],
    "glsl330": ["--version", "330", "--no-es", "--no-420pack-extension"],
    "essl100": ["--version", "100", "--es"],
}

# Uniform-block members the runtime can supply, mapped to the manifest's
# semantic vocabulary. Anything outside this set (PassFeedback*, user LUT sizes,
# ...) causes the preset to be rejected for that profile rather than rendered
# with a zeroed uniform, which is the kind of bug that looks like a shader
# "almost working".
SEMANTICS = {
    "MVP": "mvp",
    "SourceSize": "source_size",
    "OriginalSize": "original_size",
    "OutputSize": "output_size",
    "FinalViewportSize": "final_viewport_size",
    "FrameCount": "frame_count",
    "FrameDirection": "frame_direction",
}
HISTORY_SIZE_RE = re.compile(r"^OriginalHistorySize(\d+)$")
PASS_SIZE_RE = re.compile(r"^PassOutputSize(\d+)$")

# Sampler names the runtime can bind.
HISTORY_TEX_RE = re.compile(r"^OriginalHistory(\d+)$")
PASS_TEX_RE = re.compile(r"^PassOutput(\d+)$")

WRAP_MAP = {
    "clamp_to_border": "clamp_to_border",
    "clamp_to_edge": "clamp_to_edge",
    "repeat": "repeat",
    "mirrored_repeat": "mirrored_repeat",
}


class Reject(Exception):
    """This preset cannot be honoured for this profile. Not fatal; it is news."""


# --- tiny PNG decoder -------------------------------------------------------
# The LUTs are phosphor masks: 8-bit, non-interlaced. Decoding them here means
# the emulator ships no image decoder at all.


def decode_png(path):
    data = path.read_bytes()
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise Reject(f"{path.name}: not a PNG")
    pos, idat, pal, trns = 8, b"", None, None
    w = h = depth = ctype = interlace = 0
    while pos < len(data):
        (length,) = struct.unpack(">I", data[pos : pos + 4])
        kind = data[pos + 4 : pos + 8]
        body = data[pos + 8 : pos + 8 + length]
        if kind == b"IHDR":
            w, h, depth, ctype, _, _, interlace = struct.unpack(">IIBBBBB", body)
        elif kind == b"PLTE":
            pal = body
        elif kind == b"tRNS":
            trns = body
        elif kind == b"IDAT":
            idat += body
        elif kind == b"IEND":
            break
        pos += 12 + length

    if depth != 8:
        raise Reject(f"{path.name}: {depth}-bit PNG unsupported (need 8)")
    if interlace:
        raise Reject(f"{path.name}: interlaced PNG unsupported")

    channels = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}.get(ctype)
    if channels is None:
        raise Reject(f"{path.name}: colour type {ctype} unsupported")

    raw = zlib.decompress(idat)
    stride = w * channels
    out = bytearray()
    prev = bytearray(stride)
    p = 0
    for _ in range(h):
        f = raw[p]
        line = bytearray(raw[p + 1 : p + 1 + stride])
        p += 1 + stride
        # Undo the per-scanline filter (PNG spec 9.2).
        for i in range(stride):
            a = line[i - channels] if i >= channels else 0
            b = prev[i]
            c = prev[i - channels] if i >= channels else 0
            x = line[i]
            if f == 1:
                x += a
            elif f == 2:
                x += b
            elif f == 3:
                x += (a + b) >> 1
            elif f == 4:
                pa, pb, pc = abs(b - c), abs(a - c), abs(a + b - 2 * c)
                x += a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
            elif f != 0:
                raise Reject(f"{path.name}: bad filter {f}")
            line[i] = x & 0xFF
        out += line
        prev = line

    # Expand whatever we got to straight RGBA8.
    rgba = bytearray(w * h * 4)
    for i in range(w * h):
        px = out[i * channels : (i + 1) * channels]
        if ctype == 0:
            r = g = b = px[0]
            a = 255
        elif ctype == 4:
            r = g = b = px[0]
            a = px[1]
        elif ctype == 2:
            r, g, b = px
            a = 255
        elif ctype == 6:
            r, g, b, a = px
        else:  # palette
            idx = px[0]
            r, g, b = pal[idx * 3 : idx * 3 + 3]
            a = trns[idx] if trns and idx < len(trns) else 255
        rgba[i * 4 : i * 4 + 4] = bytes((r, g, b, a))
    return w, h, bytes(rgba)


# --- slang front-end --------------------------------------------------------


def resolve_includes(path, seen=None):
    """Inline #include recursively, relative to the including file."""
    seen = seen or []
    if len(seen) > 32:
        raise Reject("#include nested too deep")
    out = []
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        m = re.match(r'\s*#include\s+"([^"]+)"', line)
        if m:
            inc = (path.parent / m.group(1)).resolve()
            if not inc.exists():
                raise Reject(f"missing include {m.group(1)}")
            out.append(resolve_includes(inc, seen + [path]))
        else:
            out.append(line)
    return "\n".join(out)


def parse_pragmas(text):
    """Pull #pragma parameter / #pragma format out of the (included) source."""
    params, fmt = [], None
    for line in text.splitlines():
        m = re.match(
            r'\s*#pragma\s+parameter\s+(\w+)\s+"[^"]*"\s+'
            r"([-\d.eE+]+)\s+([-\d.eE+]+)\s+([-\d.eE+]+)\s+([-\d.eE+]+)",
            line,
        )
        if m:
            params.append(
                {
                    "name": m.group(1),
                    "default": float(m.group(2)),
                    "min": float(m.group(3)),
                    "max": float(m.group(4)),
                    "step": float(m.group(5)),
                }
            )
        m = re.match(r"\s*#pragma\s+format\s+(\S+)", line)
        if m:
            fmt = m.group(1)
    return params, fmt


def stage_source(text, stage):
    """Split a .slang into one stage.

    Everything before the first `#pragma stage` is common to both stages; after
    that, only the matching stage's block is kept. The pragmas themselves are
    dropped -- glslang has no idea what they mean.
    """
    lines, out, current = text.splitlines(), [], None
    for line in lines:
        m = re.match(r"\s*#pragma\s+stage\s+(\w+)", line)
        if m:
            current = m.group(1)
            continue
        if re.match(r"\s*#pragma\s+(name|format|parameter)\b", line):
            continue
        if current is None or current == stage:
            out.append(line)
    return "\n".join(out) + "\n"


def instance_name(glsl, block_name, fallback):
    """The instance a uniform block was declared with in the emitted GLSL.

    Reflection reports the *block* name for UBOs (`UBO`) but the *instance* for
    push constants (`params`), and the plain-uniform path needs the instance --
    members are addressed as `global.MVP`. The emitted GLSL is the only place
    both forms are unambiguous, so read it from there:

        layout(std140) uniform UBO { ... } global;   // block form  (ES3)
        uniform UBO global;                          // plain form  (ES2)
    """
    m = re.search(rf"uniform\s+{re.escape(block_name)}\s*\{{.*?\}}\s*(\w+)\s*;", glsl, re.S)
    if m:
        return m.group(1)
    m = re.search(rf"uniform\s+{re.escape(block_name)}\s+(\w+)\s*;", glsl)
    if m:
        return m.group(1)
    return fallback


def run(cmd, **kw):
    r = subprocess.run(cmd, capture_output=True, text=True, **kw)
    if r.returncode != 0:
        # A tool that fails with no output at all is a crash, not a compile
        # error; carry the exit code so the two are distinguishable (a signal
        # shows up as a negative code on POSIX).
        out = (r.stdout + r.stderr).strip()
        raise Reject(out.splitlines()[0] if out else f"tool failed silently (exit {r.returncode})")
    return r.stdout


def glslang_bin():
    for name in ("glslang", "glslangValidator", "glslang.exe", "glslangValidator.exe"):
        p = TOOLS / "bin" / name
        if p.exists():
            return str(p)
    found = shutil.which("glslang") or shutil.which("glslangValidator")
    if found:
        return found
    sys.exit("glslang not found -- run tools/build_shader_tools.sh")


def spirv_cross_bin():
    for name in ("spirv-cross", "spirv-cross.exe"):
        p = TOOLS / "bin" / name
        if p.exists():
            return str(p)
    found = shutil.which("spirv-cross")
    if found:
        return found
    sys.exit("spirv-cross not found -- run tools/build_shader_tools.sh")


# --- .slangp ----------------------------------------------------------------


def parse_slangp(path):
    cfg = {}
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        line = line.split("#", 1)[0].strip()
        if not line or "=" not in line:
            continue
        k, v = line.split("=", 1)
        cfg[k.strip()] = v.strip().strip('"')
    return cfg


def cfg_get(cfg, key, i, default=None):
    return cfg.get(f"{key}{i}", default)


def cfg_bool(cfg, key, i, default=False):
    v = cfg_get(cfg, key, i)
    if v is None:
        return default
    return str(v).lower() in ("true", "1")


def scale_of(cfg, i, axis):
    """(scale_type, value) for one axis of one pass, per the libretro rules."""
    t = cfg_get(cfg, f"scale_type_{axis}", i) or cfg_get(cfg, "scale_type", i)
    v = cfg_get(cfg, f"scale_{axis}", i) or cfg_get(cfg, "scale", i)
    if t is None:
        # No scale given at all: a pass defaults to 1x its source.
        return "source", 1.0
    if t == "absolute":
        return "absolute", float(int(float(v or 0)))
    if t not in ("source", "viewport"):
        raise Reject(f"pass {i}: unknown scale_type {t}")
    return t, float(v if v is not None else 1.0)


# --- baking -----------------------------------------------------------------


def bake(name, tier, slangp, profile, verbose):
    cfg = parse_slangp(slangp)
    n_passes = int(float(cfg.get("shaders", "0")))
    if n_passes == 0:
        raise Reject("preset declares no passes")
    if n_passes > 16:
        raise Reject(f"{n_passes} passes exceeds the runtime's limit of 16")

    outdir = OUT / profile / name
    lines = [
        f"# baked from {slangp.relative_to(SRC)} by tools/transpile_shaders.py",
        "# do not edit; re-run the baker",
        f"name {name}",
        f"tier {tier}",
        f"profile {profile}",
    ]

    # LUTs are preset-global in libretro; decode them once up front.
    luts = {}
    if cfg.get("textures"):
        for lut in cfg["textures"].split(";"):
            lut = lut.strip()
            if not lut:
                continue
            rel = cfg.get(lut)
            if not rel:
                raise Reject(f"texture {lut} declared but has no path")
            png = (slangp.parent / rel).resolve()
            if not png.exists():
                raise Reject(f"missing LUT {rel}")
            w, h, rgba = decode_png(png)
            binfile = f"{lut}.bin"
            luts[lut] = {
                "file": binfile,
                "w": w,
                "h": h,
                "filter": "linear" if str(cfg.get(f"{lut}_linear", "true")).lower() == "true" else "nearest",
                "wrap": WRAP_MAP.get(cfg.get(f"{lut}_wrap_mode", "repeat"), "repeat"),
                "mipmap": str(cfg.get(f"{lut}_mipmap", "false")).lower() == "true",
                "rgba": rgba,
            }

    # Aliases must be known before any pass references one.
    aliases = {}
    for i in range(n_passes):
        a = cfg_get(cfg, "alias", i)
        if a:
            aliases[a] = i

    all_params = {}
    pass_blocks = []
    tmp = Path(tempfile.mkdtemp(prefix="yamabuki-shader-"))
    try:
        for i in range(n_passes):
            rel = cfg_get(cfg, "shader", i)
            if not rel:
                raise Reject(f"pass {i}: no shader path")
            slang = (slangp.parent / rel).resolve()
            if not slang.exists():
                raise Reject(f"pass {i}: missing {rel}")

            text = resolve_includes(slang)
            params, fmt = parse_pragmas(text)
            for p in params:
                all_params.setdefault(p["name"], p)

            block = {"i": i, "files": {}, "fmt": fmt}

            # Both stages are reflected and merged. A linked GL program has one
            # uniform namespace, and the two stages do not declare the same
            # blocks: MVP lives in the vertex shader's UBO while the sizes and
            # parameters live in the fragment shader's push block. Reflecting
            # only the fragment stage silently loses MVP -- the geometry then
            # renders with an unset matrix, which is a black screen, not an
            # error.
            blocks = {}      # block name -> merged declaration
            samplers = {}    # sampler name -> declaration (fragment, in practice)

            for stage, ext in (("vertex", "vert"), ("fragment", "frag")):
                stage_file = tmp / f"p{i}.{ext}"
                stage_file.write_text(stage_source(text, stage), encoding="utf-8")
                spv = tmp / f"p{i}.{ext}.spv"
                run([glslang_bin(), "-V", "--target-env", "vulkan1.0",
                     "-S", "vert" if stage == "vertex" else "frag",
                     "-o", str(spv), str(stage_file)])

                # No --flatten-ubo: it requires every member of a block to share
                # a basic type, and the slang UBO mixes `mat4 MVP` with
                # `uint FrameCount`. Let SPIRV-Cross pick the natural form for
                # the profile (std140 block on ES3/desktop, plain struct on ES2)
                # and record which one it chose.
                # Natural output first. --flatten-multidimensional-arrays is a
                # *fallback*, not a default: ESSL below 310 has no arrays of
                # arrays, but flattening breaks any shader that uses a
                # multidimensional array *constructor* -- and desktop GLSL, which
                # supports them natively, would be broken for nothing.
                base = [spirv_cross_bin(), *PROFILES[profile],
                        "--remove-unused-variables", str(spv)]
                try:
                    glsl = run(base)
                except Reject:
                    glsl = run(base + ["--flatten-multidimensional-arrays"])
                block["files"][f"pass{i}.{ext}"] = glsl

                # The input file must precede --reflect, which otherwise eats it
                # as its own argument.
                r = json.loads(run([spirv_cross_bin(), str(spv), "--reflect"]))
                types = r.get("types", {})

                for key, kind in (("ubos", "ubo"), ("push_constants", "push")):
                    for b in r.get(key, []):
                        tname = types[b["type"]]["name"]
                        e = blocks.setdefault(tname, {
                            "kind": kind,
                            "binding": b.get("binding", 0),
                            "size": 0,
                            "members": {},
                            "instance": None,
                        })
                        e["size"] = max(e["size"], b.get("block_size", 0))
                        for m in types[b["type"]]["members"]:
                            e["members"][m["name"]] = (m["offset"], m["type"])
                        if e["instance"] is None:
                            e["instance"] = instance_name(glsl, tname, b.get("name") or tname)

                for s in (r.get("separate_images") or r.get("textures") or []):
                    samplers.setdefault(s["name"], s)

            block["blocks"] = blocks
            block["samplers"] = list(samplers.values())

            # Does the emitted GLSL of either stage actually read `global.X`?
            both = block["files"][f"pass{i}.vert"] + "\n" + block["files"][f"pass{i}.frag"]
            block["reads"] = lambda glsl_name, _src=both: re.search(
                rf"\b{re.escape(glsl_name)}\b", _src) is not None
            pass_blocks.append(block)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

    # Which passes are sampled as feedback? Those need their render target
    # double-buffered so last frame's copy survives being overwritten. This has
    # to be known before any pass is emitted, because the reference can come
    # from a *later* pass (or the pass itself) -- that is the whole point of
    # feedback.
    feedback_passes = set()
    for b in pass_blocks:
        for s in b["samplers"]:
            n = s["name"]
            if n.endswith("Feedback") and n[: -len("Feedback")] in aliases:
                feedback_passes.add(aliases[n[: -len("Feedback")]])

    # The runtime's limits are the baker's limits. crt-guest-advanced declares
    # 148 parameters, and the first version of this baker happily emitted a
    # manifest that the frontend then refused to load — exactly the "it is in the
    # directory but it does not run" failure this pipeline exists to prevent.
    # Mirror preset.zig here so the mismatch fails on the build host.
    if len(all_params) > 192:  # preset.zig: max_params
        raise Reject(f"{len(all_params)} parameters exceeds the runtime's limit of 192")

    # Emit params before anything references them by name.
    for p in all_params.values():
        lines.append(f"param {p['name']} {p['default']:g} {p['min']:g} {p['max']:g} {p['step']:g}")
    for lname, l in luts.items():
        lines.append(f"lut {lname} {l['file']} {l['w']} {l['h']} {l['filter']} {l['wrap']} {int(l['mipmap'])}")

    for block in pass_blocks:
        i = block["i"]

        lines.append(f"pass {i}")
        lines.append(f"  vert pass{i}.vert")
        lines.append(f"  frag pass{i}.frag")
        sx, vx = scale_of(cfg, i, "x")
        sy, vy = scale_of(cfg, i, "y")
        # The last pass always lands on the viewport; the runtime ignores its
        # scale, so record it truthfully but harmlessly.
        lines.append(f"  scale_x {sx} {vx:g}")
        lines.append(f"  scale_y {sy} {vy:g}")
        lines.append(f"  filter {'linear' if cfg_bool(cfg, 'filter_linear', i, True) else 'nearest'}")
        lines.append(f"  wrap {WRAP_MAP.get(cfg_get(cfg, 'wrap_mode', i, 'clamp_to_edge'), 'clamp_to_edge')}")
        fmt = (block["fmt"] or "").upper()
        float_fb = cfg_bool(cfg, "float_framebuffer", i) or "SFLOAT" in fmt
        lines.append(f"  float_fb {int(float_fb)}")
        lines.append(f"  srgb_fb {int(cfg_bool(cfg, 'srgb_framebuffer', i))}")
        lines.append(f"  mipmap {int(cfg_bool(cfg, 'mipmap_input', i))}")
        if i in feedback_passes:
            lines.append("  feedback 1")
        alias = cfg_get(cfg, "alias", i)
        if alias:
            lines.append(f"  alias {alias}")

        # Uniform blocks.
        #
        # SPIRV-Cross emits the UBO as a real std140 block on ESSL 300 / GLSL
        # 330, and as a plain uniform struct on ESSL 100 (which has no uniform
        # blocks). The push-constant block always comes out plain. Record which,
        # plus each member's offset *and* its fully-qualified GLSL name, so the
        # runtime can take either path without inferring anything.
        for tname, b in block["blocks"].items():
            kind, iname = b["kind"], b["instance"]
            if kind == "ubo":
                # ESSL 100 has no uniform blocks, so SPIRV-Cross emits the UBO
                # as a plain struct there and as std140 everywhere else.
                mode = "plain" if profile == "essl100" else "block"
                lines.append(f"  ubo {b['binding']} {b['size']} {tname} {mode}")
            # The push block is always plain uniforms; it needs no size and no
            # manifest line of its own, only its members below.

            for mname, (off, utype) in sorted(b["members"].items(), key=lambda kv: kv[1][0]):
                if utype not in ("mat4", "vec4", "vec2", "float", "int", "uint"):
                    raise Reject(f"pass {i}: uniform '{mname}' has unsupported type {utype}")
                glsl = f"{iname}.{mname}"

                if mname in SEMANTICS:
                    sem = SEMANTICS[mname]
                elif mname in all_params:
                    sem = f"param {mname}"
                elif HISTORY_SIZE_RE.match(mname):
                    # Every history frame has the console's current dimensions,
                    # so its size is the original's.
                    sem = "original_size"
                elif PASS_SIZE_RE.match(mname):
                    idx = PASS_SIZE_RE.match(mname).group(1)
                    if int(idx) >= i:
                        raise Reject(f"pass {i}: reads PassOutputSize{idx}, which has not run yet")
                    sem = f"pass_output_size {idx}"
                elif mname.endswith("FeedbackSize") and mname[: -len("FeedbackSize")] in aliases:
                    # A feedback target is the same size as the pass that writes
                    # it; only its *contents* are a frame stale.
                    sem = f"pass_output_size {aliases[mname[: -len('FeedbackSize')]]}"
                elif mname.endswith("Size") and mname[: -len("Size")] in aliases:
                    # `<Alias>Size` is how a slang shader asks for the dimensions
                    # of an aliased earlier pass.
                    idx = aliases[mname[: -len("Size")]]
                    if idx >= i:
                        raise Reject(f"pass {i}: reads {mname}, which has not run yet")
                    sem = f"pass_output_size {idx}"
                elif not block["reads"](glsl):
                    # Dead block member. Shaders declare fields they then shadow
                    # with a #define (crt-guest-advanced does exactly this with
                    # LUTLOW/LUTBR), so the field occupies std140 space but is
                    # never read. Leaving those bytes zero is correct.
                    #
                    # The test is deliberately "does the emitted GLSL reference
                    # it", not "do we recognise the name" -- an unknown name that
                    # IS read is a semantic we failed to implement, and skipping
                    # it would render a plausible-looking but wrong frame.
                    continue
                else:
                    raise Reject(f"pass {i}: unsupported uniform '{mname}' (read by the shader)")

                lines.append(f"  uniform {kind} {off} {glsl} {utype} {sem}")

        # Samplers.
        unit = 0
        for s in block["samplers"]:
            sname = s["name"]
            if sname == "Source":
                spec = "source -"
            elif sname == "Original":
                spec = "original -"
            elif HISTORY_TEX_RE.match(sname):
                spec = f"history {HISTORY_TEX_RE.match(sname).group(1)}"
            elif PASS_TEX_RE.match(sname):
                idx = int(PASS_TEX_RE.match(sname).group(1))
                if idx >= i:
                    raise Reject(f"pass {i}: samples PassOutput{idx}, which has not run yet")
                spec = f"pass __index{idx}"
            elif sname.endswith("Feedback") and sname[: -len("Feedback")] in aliases:
                # Feedback: the aliased pass's output from the *previous* frame.
                # Unlike a normal pass reference this may point at a later pass
                # (or itself) -- last frame's copy has already been written.
                spec = f"feedback {sname[: -len('Feedback')]}"
            elif sname in aliases:
                if aliases[sname] >= i:
                    raise Reject(f"pass {i}: samples alias '{sname}' from a later pass")
                spec = f"pass {sname}"
            elif sname in luts:
                spec = f"lut {sname}"
            else:
                raise Reject(f"pass {i}: unsupported sampler '{sname}'")

            if sname in luts:
                f, w = luts[sname]["filter"], luts[sname]["wrap"]
            else:
                f = "linear" if cfg_bool(cfg, "filter_linear", i, True) else "nearest"
                w = WRAP_MAP.get(cfg_get(cfg, "wrap_mode", i, "clamp_to_edge"), "clamp_to_edge")
            lines.append(f"  texture {unit} {sname} {spec} {f} {w}")
            unit += 1
        if unit > 12:
            raise Reject(f"pass {i}: {unit} samplers exceeds the runtime's limit of 12")

    # PassOutputN has no alias to point at, so synthesise one for the target
    # pass and rewrite the reference.
    text = "\n".join(lines) + "\n"
    for m in sorted(set(re.findall(r"__index(\d+)", text)), key=int):
        idx = int(m)
        synth = f"__pass{idx}"
        text = text.replace(f"pass __index{idx}", f"pass {synth}")
        # Insert the alias into that pass's block if it has none.
        block_re = re.compile(rf"(^pass {idx}$)(.*?)(?=^pass \d+$|\Z)", re.M | re.S)
        mm = block_re.search(text)
        if not mm:
            raise Reject(f"cannot alias pass {idx}")
        if re.search(r"^\s+alias ", mm.group(2), re.M):
            existing = re.search(r"^\s+alias (\S+)", mm.group(2), re.M).group(1)
            text = text.replace(f"pass {synth}", f"pass {existing}")
        else:
            text = text[: mm.end(1)] + f"\n  alias {synth}" + text[mm.end(1) :]

    # Write only once everything validated -- a half-baked directory would look
    # like a working preset to the frontend.
    if outdir.exists():
        shutil.rmtree(outdir)
    outdir.mkdir(parents=True)
    (outdir / "preset.conf").write_text(text, encoding="utf-8")
    for block in pass_blocks:
        for fname, content in block["files"].items():
            (outdir / fname).write_text(content, encoding="utf-8")
    for l in luts.values():
        (outdir / l["file"]).write_bytes(l["rgba"])

    return sum(1 for _ in pass_blocks)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--only", help="bake just this preset")
    ap.add_argument("--verbose", action="store_true")
    args = ap.parse_args()

    if not SRC.exists():
        sys.exit(f"{SRC} missing -- run tools/fetch_shaders.sh")

    listing = (OUT / "presets.conf").read_text(encoding="utf-8")
    wanted = []
    for line in listing.splitlines():
        line = line.split("#", 1)[0].strip()
        if not line:
            continue
        name, tier, path = (f.strip() for f in line.split("|"))
        if args.only and name != args.only:
            continue
        wanted.append((name, tier, SRC / path))
    if not wanted:
        sys.exit("nothing to bake")

    ok, failed = 0, []
    for name, tier, slangp in wanted:
        if not slangp.exists():
            failed.append((name, "*", f"missing {slangp}"))
            continue
        for profile in PROFILES:
            try:
                n = bake(name, tier, slangp, profile, args.verbose)
                print(f"  {name:<26} {profile:<8} {n} pass{'' if n == 1 else 'es'}")
                ok += 1
            except Reject as e:
                failed.append((name, profile, str(e)))
                if args.verbose:
                    print(f"  {name:<26} {profile:<8} SKIP: {e}")

    print(f"\nbaked {ok} (preset, profile) pairs into {OUT}/")
    if failed:
        # Not an error: a shader that cannot run on GLES2 is expected news, and
        # silently dropping it is what we are trying to avoid.
        print(f"\n{len(failed)} skipped:")
        for name, profile, why in failed:
            print(f"  {name:<26} {profile:<8} {why}")


if __name__ == "__main__":
    main()
