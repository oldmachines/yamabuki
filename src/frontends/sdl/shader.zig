//! Multi-pass shader chain on GL ES 2/3.
//!
//! One `Chain` owns every GL object for a loaded preset: a program per pass, a
//! render target per pass but the last, the console frame as a texture (plus a
//! ring of previous frames when a shader asks for history), and one quad.
//! `render` walks the passes, sizing each target from `preset.passSize`, and
//! draws the final pass straight to the backbuffer inside a letterboxed
//! viewport that keeps the SNES 8:7 shape — the same geometry the software path
//! gets from `SDL_SetRenderLogicalPresentation`, so switching between them does
//! not move the picture.
//!
//! Everything after `init` is allocation-free. Targets are reallocated only
//! when the console changes resolution (hi-res/overscan) or the window is
//! resized, not per frame.
//!
//! There is exactly one uniform-upload path. Both slang blocks (the std140 UBO
//! and the push-constant block) are flattened to `uniform vec4 X[n]` arrays at
//! bake time, so the chain builds a byte block per pass and hands it to
//! `glUniform4fv`. That works identically on GLES2, which has no uniform
//! blocks at all, and GLES3 — the fallback runs the same code as the primary.

const std = @import("std");
const gl = @import("gl.zig");
const preset = @import("preset.zig");

const Preset = preset.Preset;
const Pass = preset.Pass;
const Size = preset.Size;

/// Largest flattened uniform block we will accept. The real shaders sit well
/// under this (a mat4, a handful of vec4 sizes, and the parameters); a bigger
/// one means the manifest is not what we think it is.
const max_block_bytes = 4096;

/// Frames of input history a shader may ask for.
const max_history = 8;

pub const Error = error{
    ShaderCompile,
    ProgramLink,
    FramebufferIncomplete,
    BlockTooLarge,
    /// The manifest wants a std140 uniform block but the context has no
    /// uniform-buffer entry points — a GLES3 preset on a GLES2 driver. The
    /// baker should never produce this pairing; if it does, fail rather than
    /// render with unset uniforms.
    NoUniformBuffers,
    /// The preset wants more frames of input history than the ring holds.
    TooMuchHistory,
    /// The LUT file's byte count does not match the width/height the manifest
    /// claims — the baked directory is inconsistent with itself.
    BadLut,
    MissingSource,
};

/// A pass's render target.
///
/// Feedback passes are double-buffered: the shader reads slot `1 - cur` (last
/// frame) while the pass writes slot `cur`. Passes without feedback use slot 0
/// only and never pay for the second texture — on a handheld with 512 MB
/// shared, a spare full-viewport RGBA8 per pass is not free.
const Target = struct {
    tex: [2]gl.Uint = .{ 0, 0 },
    fbo: [2]gl.Uint = .{ 0, 0 },
    size: Size = .{ .w = 0, .h = 0 },
    /// Which slot this frame writes. Always 0 for a non-feedback pass.
    cur: u1 = 0,
    double: bool = false,

    fn write(self: *const Target) gl.Uint {
        return self.fbo[self.cur];
    }
    fn read(self: *const Target) gl.Uint {
        return self.tex[self.cur];
    }
    /// Last frame's output. Identical to `read()` for a single-buffered pass,
    /// which is the honest answer on frame 0 before any history exists.
    fn readPrev(self: *const Target) gl.Uint {
        return if (self.double) self.tex[1 - self.cur] else self.tex[self.cur];
    }
};

const Program = struct {
    id: gl.Uint = 0,
    /// Attribute locations, resolved once at link.
    a_position: gl.Int = -1,
    a_texcoord: gl.Int = -1,
    /// std140 buffer for the UBO, in `.block` mode only.
    ubo_buffer: gl.Uint = 0,
    /// Location per uniform, parallel to `Pass.uniforms`. Used in `.plain`
    /// mode, and always for the push block (which SPIRV-Cross emits as plain
    /// uniforms in every profile).
    u_locs: [preset.max_uniforms]gl.Int = @splat(-1),
    /// One sampler location per declared texture, parallel to `Pass.textures`.
    u_samplers: [preset.max_textures]gl.Int = @splat(-1),
};

pub const Chain = struct {
    api: gl.Api,
    gles_major: u32,
    p: Preset,

    programs: [preset.max_passes]Program = @splat(.{}),
    targets: [preset.max_passes]Target = @splat(.{}),

    /// The console frame, and the ring of previous frames (index 0 is current).
    frames: [max_history]gl.Uint = @splat(0),
    history_depth: u8 = 0,
    head: u8 = 0,
    source_size: Size = .{ .w = 0, .h = 0 },

    /// Lookup tables, uploaded once from the raw RGBA the baker emitted.
    luts: [preset.max_luts]gl.Uint = @splat(0),

    quad: gl.Uint = 0,
    viewport: Size = .{ .w = 0, .h = 0 },
    frame_count: u32 = 0,

    /// Live parameter values, seeded from the manifest defaults.
    params: [preset.max_params]f32 = @splat(0),

    // --- construction -------------------------------------------------------

    /// Compile every pass of `p`, reading the GLSL next to the manifest.
    /// `dir` is the baked preset directory.
    pub fn init(
        self: *Chain,
        io: std.Io,
        gpa: std.mem.Allocator,
        api: gl.Api,
        gles_major: u32,
        p: Preset,
        dir: std.Io.Dir,
        log: *std.Io.Writer,
    ) !void {
        self.* = .{ .api = api, .gles_major = gles_major, .p = p };

        for (p.params[0..p.param_count], 0..) |q, i| self.params[i] = q.value;

        for (p.passes[0..p.pass_count]) |*pass| {
            if (pass.ubo_size > max_block_bytes) return Error.BlockTooLarge;
            self.history_depth = @max(self.history_depth, historyDepth(pass));
        }
        if (self.history_depth >= max_history) return Error.TooMuchHistory;

        for (p.passes[0..p.pass_count], 0..) |*pass, i| {
            const vs = try dir.readFileAlloc(io, pass.vert_str(), gpa, .limited(1 << 20));
            const fs = try dir.readFileAlloc(io, pass.frag_str(), gpa, .limited(1 << 20));
            self.programs[i] = try self.buildProgram(gpa, vs, fs, pass, log);
        }

        // A unit quad in [0,1]; the MVP maps it to clip space. This is the
        // convention every slang vertex shader is written against
        // (`gl_Position = MVP * Position`), so the baked shaders need no fixups.
        const verts = [_]f32{
            // x, y, u, v
            0, 0, 0, 0,
            1, 0, 1, 0,
            0, 1, 0, 1,
            1, 1, 1, 1,
        };
        api.glGenBuffers(1, @ptrCast(&self.quad));
        api.glBindBuffer(gl.ARRAY_BUFFER, self.quad);
        api.glBufferData(gl.ARRAY_BUFFER, @sizeOf(@TypeOf(verts)), &verts, gl.STATIC_DRAW);

        api.glGenTextures(@intCast(self.history_depth + 1), &self.frames);
        for (self.frames[0 .. self.history_depth + 1]) |t| {
            api.glBindTexture(gl.TEXTURE_2D, t);
            api.glTexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.NEAREST);
            api.glTexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.NEAREST);
            api.glTexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
            api.glTexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
        }

        // LUTs: raw RGBA8 straight from the baker, no image decoding here.
        for (p.luts[0..p.lut_count], 0..) |*l, i| {
            const want = @as(usize, l.w) * @as(usize, l.h) * 4;
            const bytes = try dir.readFileAlloc(io, l.file_str(), gpa, .limited(64 << 20));
            if (bytes.len != want) return Error.BadLut;

            var tex: gl.Uint = 0;
            api.glGenTextures(1, @ptrCast(&tex));
            api.glBindTexture(gl.TEXTURE_2D, tex);
            api.glPixelStorei(gl.UNPACK_ALIGNMENT, 4);
            const internal: gl.Int = if (gles_major >= 3) @intCast(gl.RGBA8) else @intCast(gl.RGBA);
            api.glTexImage2D(gl.TEXTURE_2D, 0, internal, @intCast(l.w), @intCast(l.h), 0, gl.RGBA, gl.UNSIGNED_BYTE, bytes.ptr);
            const use_mip = l.mipmap and gles_major >= 3;
            if (use_mip) api.glGenerateMipmap(gl.TEXTURE_2D);
            api.glTexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, filterMode(l.filter, use_mip));
            api.glTexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, filterMode(l.filter, false));
            api.glTexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.wrapMode(l.wrap, gles_major));
            api.glTexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.wrapMode(l.wrap, gles_major));
            self.luts[i] = tex;
        }

        api.glDisable(gl.DEPTH_TEST);
        api.glDisable(gl.CULL_FACE);
        api.glDisable(gl.BLEND);
        // The console framebuffer is tightly packed 16-bit; the default 4-byte
        // unpack alignment would shear any frame whose width is not a multiple
        // of 2 pixels.
        api.glPixelStorei(gl.UNPACK_ALIGNMENT, 2);
    }

    pub fn deinit(self: *Chain) void {
        const api = self.api;
        for (self.programs[0..self.p.pass_count]) |prog| {
            if (prog.id != 0) api.glDeleteProgram(prog.id);
            if (prog.ubo_buffer != 0) api.glDeleteBuffers(1, @ptrCast(&prog.ubo_buffer));
        }
        for (&self.targets) |*t| {
            for (0..2) |s| {
                if (t.fbo[s] != 0) api.glDeleteFramebuffers(1, @ptrCast(&t.fbo[s]));
                if (t.tex[s] != 0) api.glDeleteTextures(1, @ptrCast(&t.tex[s]));
            }
        }
        api.glDeleteTextures(@intCast(self.history_depth + 1), &self.frames);
        for (self.luts[0..self.p.lut_count]) |t| {
            if (t != 0) api.glDeleteTextures(1, @ptrCast(&t));
        }
        api.glDeleteBuffers(1, @ptrCast(&self.quad));
    }

    fn historyDepth(pass: *const Pass) u8 {
        var d: u8 = 0;
        for (pass.textures[0..pass.texture_count]) |t| {
            if (t.kind == .original_history) d = @max(d, t.index);
        }
        return d;
    }

    fn buildProgram(
        self: *Chain,
        gpa: std.mem.Allocator,
        vs: []const u8,
        fs: []const u8,
        pass: *const Pass,
        log: *std.Io.Writer,
    ) !Program {
        const api = self.api;
        const vsh = try self.compile(gpa, gl.VERTEX_SHADER, vs, pass.vert_str(), log);
        defer api.glDeleteShader(vsh);
        const fsh = try self.compile(gpa, gl.FRAGMENT_SHADER, fs, pass.frag_str(), log);
        defer api.glDeleteShader(fsh);

        const id = api.glCreateProgram();
        api.glAttachShader(id, vsh);
        api.glAttachShader(id, fsh);
        api.glLinkProgram(id);

        var ok: gl.Int = 0;
        api.glGetProgramiv(id, gl.LINK_STATUS, &ok);
        if (ok == gl.FALSE) {
            var len: gl.Int = 0;
            api.glGetProgramiv(id, gl.INFO_LOG_LENGTH, &len);
            if (len > 0) {
                const buf = try gpa.alloc(u8, @intCast(len));
                api.glGetProgramInfoLog(id, len, null, buf.ptr);
                log.print("shader link failed ({s}):\n{s}\n", .{ pass.frag_str(), buf }) catch {};
                log.flush() catch {};
            }
            api.glDeleteProgram(id);
            return Error.ProgramLink;
        }

        var prog: Program = .{ .id = id };
        prog.a_position = api.glGetAttribLocation(id, "Position");
        prog.a_texcoord = api.glGetAttribLocation(id, "TexCoord");

        var name_buf: [preset.max_name + 1]u8 = undefined;

        // `.block` mode: one std140 buffer, wired to the block's binding point.
        if (pass.ubo_mode == .block and pass.ubo_size > 0) {
            const getIndex = api.glGetUniformBlockIndex orelse return Error.NoUniformBuffers;
            const bindBlock = api.glUniformBlockBinding orelse return Error.NoUniformBuffers;
            const idx = getIndex(id, zed(&name_buf, pass.ubo_name_str()));
            if (idx != gl.INVALID_INDEX) {
                bindBlock(id, idx, pass.ubo_binding);
                api.glGenBuffers(1, @ptrCast(&prog.ubo_buffer));
                api.glBindBuffer(gl.UNIFORM_BUFFER, prog.ubo_buffer);
                api.glBufferData(gl.UNIFORM_BUFFER, @intCast(pass.ubo_size), null, gl.DYNAMIC_DRAW);
            }
        }

        // Every plain uniform (the whole UBO in `.plain` mode, and always the
        // push block) is addressed by its fully-qualified GLSL name.
        for (pass.uniforms[0..pass.uniform_count], 0..) |u, i| {
            if (u.block == .ubo and pass.ubo_mode == .block) continue;
            prog.u_locs[i] = api.glGetUniformLocation(id, zed(&name_buf, u.name_str()));
        }
        for (pass.textures[0..pass.texture_count], 0..) |t, i| {
            prog.u_samplers[i] = api.glGetUniformLocation(id, zed(&name_buf, t.name_str()));
        }
        return prog;
    }

    fn compile(
        self: *Chain,
        gpa: std.mem.Allocator,
        kind: gl.Enum,
        src: []const u8,
        what: []const u8,
        log: *std.Io.Writer,
    ) !gl.Uint {
        const api = self.api;
        const sh = api.glCreateShader(kind);
        const ptr: [*]const u8 = src.ptr;
        const len: gl.Int = @intCast(src.len);
        api.glShaderSource(sh, 1, @ptrCast(&ptr), @ptrCast(&len));
        api.glCompileShader(sh);

        var ok: gl.Int = 0;
        api.glGetShaderiv(sh, gl.COMPILE_STATUS, &ok);
        if (ok == gl.FALSE) {
            var n: gl.Int = 0;
            api.glGetShaderiv(sh, gl.INFO_LOG_LENGTH, &n);
            if (n > 0) {
                const buf = try gpa.alloc(u8, @intCast(n));
                api.glGetShaderInfoLog(sh, n, null, buf.ptr);
                log.print("shader compile failed ({s}):\n{s}\n", .{ what, buf }) catch {};
                log.flush() catch {};
            }
            api.glDeleteShader(sh);
            return Error.ShaderCompile;
        }
        return sh;
    }

    // --- per-frame ----------------------------------------------------------

    /// Upload the console's RGB565 frame. GL ES takes 5:6:5 natively, so this
    /// is a straight copy with no conversion pass.
    pub fn upload(self: *Chain, fb: []const u16, w: u32, h: u32) void {
        const api = self.api;
        if (self.history_depth > 0) {
            self.head = (self.head + 1) % (self.history_depth + 1);
        }
        const tex = self.frames[self.head];
        api.glBindTexture(gl.TEXTURE_2D, tex);
        if (w != self.source_size.w or h != self.source_size.h) {
            // Resolution switch: every frame in the ring has to be re-declared,
            // or a history sample would read a stale, differently-sized texture.
            for (self.frames[0 .. self.history_depth + 1]) |t| {
                api.glBindTexture(gl.TEXTURE_2D, t);
                api.glTexImage2D(gl.TEXTURE_2D, 0, gl.RGB, @intCast(w), @intCast(h), 0, gl.RGB, gl.UNSIGNED_SHORT_5_6_5, null);
            }
            self.source_size = .{ .w = w, .h = h };
            api.glBindTexture(gl.TEXTURE_2D, tex);
        }
        api.glTexSubImage2D(gl.TEXTURE_2D, 0, 0, 0, @intCast(w), @intCast(h), gl.RGB, gl.UNSIGNED_SHORT_5_6_5, fb.ptr);
    }

    /// Read the shader's own output back off the GPU as 24-bit RGB.
    ///
    /// This is the *rendered* picture — scanlines, mask, curvature and all — not
    /// the console's framebuffer, which is what the headless `--ppm` already
    /// dumps. Only the letterboxed rectangle is read, so the black bars never
    /// end up in the shot.
    ///
    /// Call it after `render` and before the swap: the back buffer still holds
    /// the frame. GL's origin is bottom-left, so the rows come back upside down
    /// and are flipped here.
    pub fn capture(self: *Chain, gpa: std.mem.Allocator, window: Size) !struct { w: u32, h: u32, rgb: []u8 } {
        const api = self.api;
        const box = letterbox(window, self.source_size);

        const rgba = try gpa.alloc(u8, @as(usize, box.w) * @as(usize, box.h) * 4);
        defer gpa.free(rgba);

        api.glFinish();
        api.glPixelStorei(gl.PACK_ALIGNMENT, 1);
        api.glReadPixels(box.x, box.y, @intCast(box.w), @intCast(box.h), gl.RGBA, gl.UNSIGNED_BYTE, rgba.ptr);

        const rgb = try gpa.alloc(u8, @as(usize, box.w) * @as(usize, box.h) * 3);
        for (0..box.h) |y| {
            const src_row = box.h - 1 - y; // flip: GL reads bottom-up
            for (0..box.w) |x| {
                const s = (src_row * box.w + x) * 4;
                const d = (y * box.w + x) * 3;
                rgb[d + 0] = rgba[s + 0];
                rgb[d + 1] = rgba[s + 1];
                rgb[d + 2] = rgba[s + 2];
            }
        }
        return .{ .w = box.w, .h = box.h, .rgb = rgb };
    }

    /// The letterboxed on-screen rectangle: the SNES 8:7 shape fitted into the
    /// window, matching the software path's logical presentation exactly.
    pub fn letterbox(window: Size, frame: Size) struct { x: i32, y: i32, w: u32, h: u32 } {
        // The software path presents onto a 512 x (2*h) canvas, so a 256-wide
        // frame doubles and a hi-res frame maps 1:1 — both land on the same
        // aspect.
        const aspect_w: f32 = 512.0;
        const aspect_h: f32 = @floatFromInt(@max(1, frame.h * 2));
        const want = aspect_w / aspect_h;
        const have = @as(f32, @floatFromInt(window.w)) / @as(f32, @floatFromInt(@max(1, window.h)));

        var w = window.w;
        var h = window.h;
        if (have > want) {
            w = @intFromFloat(@round(@as(f32, @floatFromInt(window.h)) * want));
        } else {
            h = @intFromFloat(@round(@as(f32, @floatFromInt(window.w)) / want));
        }
        w = @max(1, w);
        h = @max(1, h);
        return .{
            .x = @intCast((@as(i64, window.w) - @as(i64, w)) >> 1),
            .y = @intCast((@as(i64, window.h) - @as(i64, h)) >> 1),
            .w = w,
            .h = h,
        };
    }

    /// Run the chain and leave the result in the default framebuffer. The
    /// caller swaps.
    pub fn render(self: *Chain, window: Size) !void {
        const api = self.api;
        const p = &self.p;
        const box = letterbox(window, self.source_size);
        const view: Size = .{ .w = box.w, .h = box.h };

        if (view.w != self.viewport.w or view.h != self.viewport.h) {
            try self.resize(view);
            self.viewport = view;
        }

        api.glBindFramebuffer(gl.FRAMEBUFFER, 0);
        api.glViewport(0, 0, @intCast(window.w), @intCast(window.h));
        api.glClearColor(0, 0, 0, 1);
        api.glClear(gl.COLOR_BUFFER_BIT);

        var src_tex = self.frames[self.head];
        var src_size = self.source_size;
        const last = p.pass_count - 1;

        for (p.passes[0..p.pass_count], 0..) |*pass, i| {
            const is_last = (i == last);
            const out_size: Size = if (is_last) view else self.targets[i].size;

            if (is_last) {
                api.glBindFramebuffer(gl.FRAMEBUFFER, 0);
                api.glViewport(box.x, box.y, @intCast(box.w), @intCast(box.h));
            } else {
                api.glBindFramebuffer(gl.FRAMEBUFFER, self.targets[i].write());
                api.glViewport(0, 0, @intCast(out_size.w), @intCast(out_size.h));
            }

            // `mipmap_input` says THIS pass samples its *input* with mipmaps, so
            // the chain has to exist on the source texture before the draw — not
            // on this pass's output afterwards. Getting that backwards leaves the
            // source with a mipmap MIN_FILTER and no mipmap levels, which makes it
            // an *incomplete* texture; GL samples incomplete textures as black,
            // and the black propagates all the way down the chain. That is
            // exactly how crt-royale and crt-guest-advanced rendered a pure black
            // frame while every mipmap-free preset was fine.
            if (pass.mipmap and self.gles_major >= 3) {
                api.glActiveTexture(gl.TEXTURE0);
                api.glBindTexture(gl.TEXTURE_2D, src_tex);
                api.glGenerateMipmap(gl.TEXTURE_2D);
            }

            const prog = &self.programs[i];
            api.glUseProgram(prog.id);
            self.bindTextures(pass, prog, src_tex, i);
            self.uploadUniforms(pass, prog, src_size, out_size, view, is_last);
            self.drawQuad(prog);

            if (!is_last) {
                src_tex = self.targets[i].read();
                src_size = self.targets[i].size;
            }
        }

        // Flip the feedback buffers once, after every pass has read them. Doing
        // this inside the loop would let a later pass in the *same* frame read
        // the copy this frame just wrote, which is not feedback.
        for (self.targets[0..p.pass_count]) |*t| {
            if (t.double) t.cur = 1 - t.cur;
        }
        self.frame_count +%= 1;
    }

    fn bindTextures(self: *Chain, pass: *const Pass, prog: *const Program, src_tex: gl.Uint, pass_index: usize) void {
        const api = self.api;
        for (pass.textures[0..pass.texture_count], 0..) |t, i| {
            const loc = prog.u_samplers[i];
            if (loc < 0) continue; // optimized out of the shader; nothing to bind
            const tex: gl.Uint = switch (t.kind) {
                .source => src_tex,
                .original => self.frames[self.head],
                .pass_alias => blk: {
                    // A pass may only sample an earlier pass; the baker enforces
                    // this, but a forward reference here would sample a target
                    // that this frame has not written yet.
                    if (t.index >= pass_index) break :blk self.frames[self.head];
                    break :blk self.targets[t.index].read();
                },
                // Feedback legitimately points forward, or at this very pass:
                // it is last frame's copy, already written.
                .pass_feedback => self.targets[t.index].readPrev(),
                .original_history => blk: {
                    const n = self.history_depth + 1;
                    const back = (@as(u16, self.head) + n - t.index) % n;
                    break :blk self.frames[back];
                },
                .lut => self.luts[t.index],
            };
            api.glActiveTexture(gl.TEXTURE0 + t.unit);
            api.glBindTexture(gl.TEXTURE_2D, tex);
            // A LUT's sampling state was set once at upload — including its
            // mipmap chain. Re-applying the pass's filter here would silently
            // knock a mipmapped mask back to a single level.
            if (t.kind != .lut) {
                // `mipmap_input` applies to this pass's Source alone. Handing a
                // mipmap MIN_FILTER to Original, a pass alias or a feedback
                // target — none of which have a mipmap chain — would make *them*
                // incomplete, and sample black.
                const mipped = pass.mipmap and t.kind == .source and self.gles_major >= 3;
                api.glTexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, filterMode(t.filter, mipped));
                api.glTexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, filterMode(t.filter, false));
                api.glTexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.wrapMode(t.wrap, self.gles_major));
                api.glTexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.wrapMode(t.wrap, self.gles_major));
            }
            api.glUniform1i(loc, t.unit);
        }
    }

    /// The 0..1 quad -> clip space matrix every slang vertex shader multiplies
    /// its Position by. Column-major, as GL expects.
    const mvp: [16]f32 = .{
        2,  0,  0,  0,
        0,  2,  0,  0,
        0,  0,  2,  0,
        -1, -1, -1, 1,
    };

    /// The same, with Y negated — used by the final pass only.
    ///
    /// GL's framebuffer origin is bottom-left, so the console's *top* row (which
    /// is texel row 0) lands at the *bottom* of whatever is being drawn into.
    /// Every intermediate pass is self-consistent about that: it renders an FBO
    /// upside-down and the next pass samples it upside-down, and the two cancel.
    /// The default framebuffer is where the convention finally has to be paid,
    /// so exactly one flip belongs here — at the last pass, and nowhere else.
    ///
    /// Flipping the geometry rather than the texcoords also leaves `vTexCoord`
    /// with (0,0) at the top-left, which is what slang shaders assume when they
    /// use it for curvature and vignetting.
    const mvp_flip_y: [16]f32 = .{
        2,  0,  0,  0,
        0,  -2, 0,  0,
        0,  0,  2,  0,
        -1, 1,  -1, 1,
    };

    /// The value of one semantic, in the shape the shader declared it.
    const Value = union(preset.UType) {
        mat4: [16]f32,
        vec4: [4]f32,
        vec2: [2]f32,
        float: f32,
        int: i32,
        uint: u32,
    };

    fn valueOf(self: *const Chain, u: preset.Uniform, src: Size, out: Size, view: Size, is_last: bool) Value {
        return switch (u.semantic) {
            .mvp => .{ .mat4 = if (is_last) mvp_flip_y else mvp },
            .source_size => .{ .vec4 = sizeVec(src) },
            .original_size => .{ .vec4 = sizeVec(self.source_size) },
            .output_size => .{ .vec4 = sizeVec(out) },
            .final_viewport_size => .{ .vec4 = sizeVec(view) },
            .pass_output_size => .{ .vec4 = sizeVec(self.targets[@min(u.index, preset.max_passes - 1)].size) },
            // FrameCount is declared `uint` in the slang UBO, not a float. In
            // std140 that is a 4-byte integer slot, so the *bit pattern* goes in
            // — writing 1234.0f where the shader reads a uint yields garbage.
            .frame_count => .{ .uint = self.frame_count },
            .frame_direction => .{ .int = 1 },
            .parameter => .{ .float = self.params[u.index] },
        };
    }

    fn uploadUniforms(self: *Chain, pass: *const Pass, prog: *const Program, src: Size, out: Size, view: Size, is_last: bool) void {
        const api = self.api;

        // std140 path (GLES3 / desktop): pack the block once, upload once.
        var block: [max_block_bytes]u8 align(16) = undefined;
        const use_block = pass.ubo_mode == .block and pass.ubo_size > 0 and prog.ubo_buffer != 0;
        if (use_block) @memset(block[0..pass.ubo_size], 0);

        for (pass.uniforms[0..pass.uniform_count], 0..) |u, i| {
            const v = self.valueOf(u, src, out, view, is_last);
            if (use_block and u.block == .ubo) {
                writeBytes(block[0..pass.ubo_size], u.offset, switch (v) {
                    inline else => |*payload| std.mem.asBytes(payload),
                });
            } else {
                setUniform(api, prog.u_locs[i], v);
            }
        }

        if (use_block) {
            api.glBindBuffer(gl.UNIFORM_BUFFER, prog.ubo_buffer);
            if (api.glBufferSubData) |sub| {
                sub(gl.UNIFORM_BUFFER, 0, @intCast(pass.ubo_size), &block);
            } else {
                api.glBufferData(gl.UNIFORM_BUFFER, @intCast(pass.ubo_size), &block, gl.DYNAMIC_DRAW);
            }
            if (api.glBindBufferBase) |bind| bind(gl.UNIFORM_BUFFER, pass.ubo_binding, prog.ubo_buffer);
        }
    }

    fn drawQuad(self: *Chain, prog: *const Program) void {
        const api = self.api;
        api.glBindBuffer(gl.ARRAY_BUFFER, self.quad);
        if (prog.a_position >= 0) {
            api.glEnableVertexAttribArray(@intCast(prog.a_position));
            api.glVertexAttribPointer(@intCast(prog.a_position), 2, gl.FLOAT, 0, 4 * @sizeOf(f32), null);
        }
        if (prog.a_texcoord >= 0) {
            api.glEnableVertexAttribArray(@intCast(prog.a_texcoord));
            api.glVertexAttribPointer(@intCast(prog.a_texcoord), 2, gl.FLOAT, 0, 4 * @sizeOf(f32), @ptrFromInt(2 * @sizeOf(f32)));
        }
        api.glDrawArrays(gl.TRIANGLE_STRIP, 0, 4);
    }

    /// (Re)allocate the intermediate render targets. Called when the window or
    /// the console resolution changes — never per frame.
    fn resize(self: *Chain, view: Size) !void {
        const api = self.api;
        const p = &self.p;
        var src = self.source_size;

        for (p.passes[0..p.pass_count], 0..) |*pass, i| {
            const size = preset.passSize(pass, src, view);
            if (i + 1 == p.pass_count) {
                // The final pass draws to the backbuffer; it needs no target.
                self.targets[i].size = view;
                break;
            }
            const t = &self.targets[i];
            t.double = pass.feedback;
            const slots: u8 = if (t.double) 2 else 1;
            const fmt = self.targetFormat(pass);

            for (0..slots) |s| {
                if (t.tex[s] == 0) {
                    api.glGenTextures(1, @ptrCast(&t.tex[s]));
                    api.glGenFramebuffers(1, @ptrCast(&t.fbo[s]));
                }
                api.glBindTexture(gl.TEXTURE_2D, t.tex[s]);
                api.glTexImage2D(gl.TEXTURE_2D, 0, fmt.internal, @intCast(size.w), @intCast(size.h), 0, fmt.format, fmt.kind, null);
                api.glTexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR);
                api.glTexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR);
                api.glTexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
                api.glTexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);

                api.glBindFramebuffer(gl.FRAMEBUFFER, t.fbo[s]);
                api.glFramebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.TEXTURE_2D, t.tex[s], 0);
                if (api.glCheckFramebufferStatus(gl.FRAMEBUFFER) != gl.FRAMEBUFFER_COMPLETE) {
                    api.glBindFramebuffer(gl.FRAMEBUFFER, 0);
                    return Error.FramebufferIncomplete;
                }
                // A feedback pass reads slot 1-cur on its very first frame, so
                // both slots must start black rather than as uninitialized VRAM.
                api.glClearColor(0, 0, 0, 1);
                api.glClear(gl.COLOR_BUFFER_BIT);
            }
            t.size = size;
            src = size;
        }
        api.glBindFramebuffer(gl.FRAMEBUFFER, 0);
    }

    const Format = struct { internal: gl.Int, format: gl.Enum, kind: gl.Enum };

    /// GLES2 has no sized internal formats and no half-float render targets, so
    /// a float or sRGB target degrades to plain RGBA8 there. That is a visible
    /// banding difference on a handful of shaders, not a wrong image — and the
    /// baker only emits an essl100 variant for presets where it checked out.
    fn targetFormat(self: *const Chain, pass: *const Pass) Format {
        if (self.gles_major < 3) {
            return .{ .internal = @intCast(gl.RGBA), .format = gl.RGBA, .kind = gl.UNSIGNED_BYTE };
        }
        if (pass.float_fb) {
            return .{ .internal = @intCast(gl.RGBA16F), .format = gl.RGBA, .kind = gl.HALF_FLOAT };
        }
        if (pass.srgb_fb) {
            return .{ .internal = @intCast(gl.SRGB8_ALPHA8), .format = gl.RGBA, .kind = gl.UNSIGNED_BYTE };
        }
        return .{ .internal = @intCast(gl.RGBA8), .format = gl.RGBA, .kind = gl.UNSIGNED_BYTE };
    }
};

/// Set one plain uniform with the call its declared type requires. A `uint` on
/// GLES2 has no glUniform1ui; ESSL 100 has no unsigned scalars either, so
/// SPIRV-Cross will have emitted it as an int and the fallback is exact.
fn setUniform(api: gl.Api, loc: gl.Int, v: Chain.Value) void {
    if (loc < 0) return; // optimized out of the shader
    switch (v) {
        .mat4 => |m| api.glUniformMatrix4fv(loc, 1, 0, &m),
        .vec4 => |x| api.glUniform4fv(loc, 1, &x),
        .vec2 => |x| api.glUniform2fv(loc, 1, &x),
        .float => |x| api.glUniform1f(loc, x),
        .int => |x| api.glUniform1i(loc, x),
        .uint => |x| if (api.glUniform1ui) |f| f(loc, x) else api.glUniform1i(loc, @bitCast(x)),
    }
}

fn filterMode(f: preset.Filter, mipmap: bool) gl.Int {
    if (mipmap) return gl.LINEAR_MIPMAP_LINEAR;
    return switch (f) {
        .nearest => gl.NEAREST,
        .linear => gl.LINEAR,
    };
}

/// libretro's `*Size` uniforms are vec4(w, h, 1/w, 1/h).
fn sizeVec(s: Size) [4]f32 {
    const w: f32 = @floatFromInt(@max(1, s.w));
    const h: f32 = @floatFromInt(@max(1, s.h));
    return .{ w, h, 1.0 / w, 1.0 / h };
}

fn writeBytes(buf: []u8, off: u32, bytes: []const u8) void {
    // A manifest offset past the reflected block size would be a baker bug;
    // clip rather than corrupt adjacent uniforms or trap.
    if (off + bytes.len > buf.len) return;
    @memcpy(buf[off..][0..bytes.len], bytes);
}

/// Null-terminate a name into a scratch buffer for the GL C ABI.
fn zed(buf: *[preset.max_name + 1]u8, name: []const u8) [*:0]const u8 {
    const n = @min(name.len, preset.max_name);
    @memcpy(buf[0..n], name[0..n]);
    buf[n] = 0;
    return @ptrCast(buf);
}

// --- tests -----------------------------------------------------------------

const testing = std.testing;

test "letterbox: a wide window pillarboxes to 8:7 and stays centred" {
    const box = Chain.letterbox(.{ .w = 1920, .h = 1080 }, .{ .w = 256, .h = 224 });
    // 8:7 of 1080 high = 1234 wide.
    try testing.expectEqual(@as(u32, 1234), box.w);
    try testing.expectEqual(@as(u32, 1080), box.h);
    try testing.expectEqual(@as(i32, 343), box.x);
    try testing.expectEqual(@as(i32, 0), box.y);
}

test "letterbox: a tall window letterboxes instead" {
    const box = Chain.letterbox(.{ .w = 640, .h = 960 }, .{ .w = 256, .h = 224 });
    try testing.expectEqual(@as(u32, 640), box.w);
    try testing.expectEqual(@as(u32, 560), box.h); // 640 / (8/7)
    try testing.expectEqual(@as(i32, 0), box.x);
    try testing.expectEqual(@as(i32, 200), box.y);
}

test "letterbox: a hi-res frame lands on exactly the same rect as a 256-wide one" {
    // The console emits 256- or 512-wide frames at the same height (ppu.zig
    // fb_height; 224 or 239 with overscan) — hi-res doubles the horizontal
    // sample count, not the picture. So a mode switch mid-game must not move or
    // resize the image, which holds because the shape depends only on height.
    const lo = Chain.letterbox(.{ .w = 1600, .h = 900 }, .{ .w = 256, .h = 224 });
    const hi = Chain.letterbox(.{ .w = 1600, .h = 900 }, .{ .w = 512, .h = 224 });
    try testing.expectEqual(lo.w, hi.w);
    try testing.expectEqual(lo.h, hi.h);
    try testing.expectEqual(lo.x, hi.x);
    try testing.expectEqual(lo.y, hi.y);
}

test "letterbox: overscan is taller, not stretched" {
    // 239 visible lines is more picture, so the rect gets taller relative to
    // its width rather than the same picture being squashed.
    const normal = Chain.letterbox(.{ .w = 1600, .h = 1600 }, .{ .w = 256, .h = 224 });
    const over = Chain.letterbox(.{ .w = 1600, .h = 1600 }, .{ .w = 256, .h = 239 });
    try testing.expect(over.h > normal.h);
    try testing.expectEqual(@as(u32, 1600), over.w);
}

test "sizeVec: the reciprocals shaders divide by are never inf" {
    const v = sizeVec(.{ .w = 0, .h = 0 });
    try testing.expectEqual(@as(f32, 1), v[0]);
    try testing.expectEqual(@as(f32, 1), v[2]);
}

test "writeBytes: an out-of-range offset is dropped, not written past the block" {
    var buf: [16]u8 = @splat(0xAA);
    writeBytes(buf[0..8], 4, std.mem.asBytes(&[4]f32{ 1, 2, 3, 4 }));
    // Would have run off the end of the 8-byte block; nothing changed.
    for (buf) |b| try testing.expectEqual(@as(u8, 0xAA), b);
}

test "frame_count is a uint, not a float — the std140 slot holds the integer" {
    // The slang UBO declares FrameCount as `uint`. Packing 1234.0f where the
    // shader reads a uint gives 1150844928, and the shader's frame-varying
    // effects (noise, interlace) go quietly wrong rather than failing loudly.
    var chain: Chain = undefined;
    chain.frame_count = 1234;
    chain.source_size = .{ .w = 256, .h = 224 };
    const one: Size = .{ .w = 1, .h = 1 };

    const v = chain.valueOf(.{ .block = .ubo, .offset = 0, .semantic = .frame_count }, one, one, one, false);
    try testing.expectEqual(@as(u32, 1234), v.uint);

    var buf: [16]u8 = @splat(0);
    writeBytes(&buf, 0, switch (v) {
        inline else => |*payload| std.mem.asBytes(payload),
    });
    try testing.expectEqual(@as(u32, 1234), std.mem.bytesToValue(u32, buf[0..4]));
}

test "feedback reads last frame's texture, and a plain pass reads this frame's" {
    var t: Target = .{ .tex = .{ 10, 11 }, .fbo = .{ 20, 21 }, .double = true, .cur = 0 };

    // Frame N: the pass writes slot 0, so feedback must read slot 1.
    try testing.expectEqual(@as(gl.Uint, 20), t.write());
    try testing.expectEqual(@as(gl.Uint, 10), t.read());
    try testing.expectEqual(@as(gl.Uint, 11), t.readPrev());

    t.cur = 1 - t.cur; // end of frame

    // Frame N+1: writes slot 1; feedback now reads what frame N wrote (slot 0).
    try testing.expectEqual(@as(gl.Uint, 21), t.write());
    try testing.expectEqual(@as(gl.Uint, 10), t.readPrev());

    // A single-buffered pass has no previous copy; readPrev must not hand back
    // the other, never-allocated slot (texture 0 = "no texture" in GL).
    var single: Target = .{ .tex = .{ 10, 0 }, .fbo = .{ 20, 0 }, .double = false };
    try testing.expectEqual(@as(gl.Uint, 10), single.readPrev());
}

test "only the final pass flips Y — intermediate passes must not" {
    // The bug this pins: every pass used the same MVP, so the console's top row
    // (texel row 0) landed at the bottom of the default framebuffer and the
    // whole picture rendered UPSIDE DOWN. It shipped, because the only test
    // image was radially symmetric and no unit test looks at a screen.
    //
    // GL's origin is bottom-left. Intermediate passes render an FBO inverted and
    // the next pass samples it inverted, so they cancel; the convention is paid
    // exactly once, at the last pass. Flip anywhere else and it un-fixes itself.
    var chain: Chain = undefined;
    chain.source_size = .{ .w = 256, .h = 224 };
    const one: Size = .{ .w = 1, .h = 1 };
    const u: preset.Uniform = .{ .block = .ubo, .offset = 0, .semantic = .mvp };

    const intermediate = chain.valueOf(u, one, one, one, false).mat4;
    const final = chain.valueOf(u, one, one, one, true).mat4;

    // m[5] is the Y scale; m[13] the Y translation.
    try testing.expectEqual(@as(f32, 2), intermediate[5]);
    try testing.expectEqual(@as(f32, -1), intermediate[13]);
    try testing.expectEqual(@as(f32, -2), final[5]);
    try testing.expectEqual(@as(f32, 1), final[13]);

    // Both map the unit quad onto the full clip volume in Y — one upright, one
    // inverted. y=0 and y=1 must land on -1 and +1 in some order, never inside.
    for ([_][16]f32{ intermediate, final }) |m| {
        const y_at_0 = m[13]; // y = 0
        const y_at_1 = m[5] + m[13]; // y = 1
        try testing.expectEqual(@as(f32, 0), y_at_0 + y_at_1); // symmetric about 0
        try testing.expectEqual(@as(f32, 1), @abs(y_at_0));
    }
}

test "a parameter resolves through its index to the live value" {
    var chain: Chain = undefined;
    chain.source_size = .{ .w = 256, .h = 224 };
    chain.params[3] = 0.75;
    const one: Size = .{ .w = 1, .h = 1 };
    const v = chain.valueOf(
        .{ .block = .ubo, .offset = 0, .semantic = .parameter, .index = 3 },
        one,
        one,
        one,
        false,
    );
    try testing.expectEqual(@as(f32, 0.75), v.float);
}
