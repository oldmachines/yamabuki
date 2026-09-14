//! Save-state container: the versioned header, the serialized machine
//! payload, the cart-RAM tail and the image identity, and the checks that
//! refuse a state the running build cannot faithfully restore. Generic over
//! the console type: `Format(Self, accuracy_tag)` gives the size and the
//! save/load pair Console wraps. Moved out of console.zig as pure code
//! motion; the constants keep their names and are re-exported there.

const std = @import("std");
const serialize = @import("serialize.zig");
const cart_mod = @import("cart/cartridge.zig");
const console = @import("console.zig");

/// Save-state container magic ("YMBK") and format version. The version bumps
/// whenever the serialized field layout changes (there is no migration —
/// states are tied to the core revision that wrote them, standard for
/// in-development emulators).
pub const state_magic: [4]u8 = .{ 'Y', 'M', 'B', 'K' };
/// Version 8 appends the cartridge RAM (SRAM/BW-RAM, `cartridge.max_sram`
/// bytes) after the serialized payload. It was never in the payload —
/// harmless while cart RAM meant battery saves, fatal for SA-1
/// conversions whose whole game state lives in BW-RAM: every state load
/// or rewind press wiped the game. Version-7 states still load (their
/// cart RAM is simply not restored — it was never saved).
// v7: the header's spare bytes carry a structural fingerprint of the layout.
// Version 10 grows the cart-RAM TAIL 128 KiB -> 256 KiB: SRAM-cart window
// conversions keep the game's save RAM in a second BW-RAM bank
// (cart.sram_hi) above the relocated WRAM image. The serialized PAYLOAD is
// untouched — sram_hi is a separate, serialize-skipped array precisely so
// old states and every movie anchor keep loading byte-for-byte.
pub const state_version: u32 = 10;
const state_version_128k_cart_ram: u32 = 9;
const state_version_no_rom_crc: u32 = 8;
const state_version_no_cart_ram: u32 = 7;
/// Cart-RAM section length for a given on-disk state version.
fn stateCartRamLen(ver: u32) usize {
    return switch (ver) {
        state_version_no_cart_ram => 0,
        state_version_no_rom_crc, state_version_128k_cart_ram => cart_mod.max_sram,
        else => cart_mod.max_sram + cart_mod.max_sram_hi,
    };
}
pub const state_header_size: usize = 16;

pub const StateError = error{ BadMagic, UnsupportedVersion, WrongSize, Corrupt, WrongRom };

pub fn Format(comptime Self: type, comptime accuracy_tag: u8) type {
    return struct {
        pub const size: usize = blk: {
            @setEvalBranchQuota(100_000);
            break :blk state_header_size + serialize.byteSize(Self) + cart_mod.max_sram + cart_mod.max_sram_hi + 4;
        };
        const payload_size: usize = blk: {
            @setEvalBranchQuota(100_000);
            break :blk serialize.byteSize(Self);
        };

        /// Structural fingerprint of the serialized layout, carried in the
        /// header's spare bytes (truncated to 24 bits). The version number is
        /// hand-maintained and the size check only sees the byte count — a
        /// same-width field reorder passes both and deserializes garbage.
        /// This is the check nobody has to remember to bump.
        const fingerprint: u24 = @truncate(serialize.fingerprint(Self));

        /// Serialize the whole machine into `out` (>= `size` bytes)
        /// behind a versioned header. The ROM image is not saved; loading
        /// requires a console built from the same ROM.
        pub fn save(self: *const Self, out: []u8) usize {
            // An unconditional check, not a debug assert: `serialize.write`
            // does no bounds checking of its own, so a short buffer in a
            // ReleaseFast build would be silent heap corruption.
            if (out.len < size) @panic("saveState: buffer smaller than state_size");
            @memcpy(out[0..4], &state_magic);
            std.mem.writeInt(u32, out[4..8], state_version, .little);
            std.mem.writeInt(u32, out[8..12], @intCast(payload_size), .little);
            out[12] = accuracy_tag;
            std.mem.writeInt(u24, out[13..16], fingerprint, .little);
            _ = serialize.write(Self, self, out[state_header_size..]);
            // Cart RAM after the payload: battery SRAM on a plain cart,
            // the game's whole working state on an SA-1 conversion.
            @memcpy(out[state_header_size + payload_size ..][0..cart_mod.max_sram], &self.bus.cart.sram);
            @memcpy(out[state_header_size + payload_size + cart_mod.max_sram ..][0..cart_mod.max_sram_hi], &self.bus.cart.sram_hi);
            // The loaded image's identity rides at the tail (version 9): a
            // state restores the WHOLE machine, and on a conversion image
            // that machine is meaningful only on the exact build it was
            // saved from — a different union's relocation era and SA-1
            // state deserialize as total garbage. Measured: a five-day-old
            // pre-split state loaded onto the split image garbled the
            // entire game.
            std.mem.writeInt(u32, out[state_header_size + payload_size + cart_mod.max_sram + cart_mod.max_sram_hi ..][0..4], self.bus.cart.rom_crc, .little);
            return size;
        }

        /// Restore a state written by `saveState` (same core version and
        /// accuracy). Header validation happens before any machine state is
        /// touched; a payload that fails mid-read (Corrupt) leaves partial
        /// state, which frontends treat as fatal (reload the game).
        pub fn load(self: *Self, in: []const u8) StateError!void {
            if (in.len < state_header_size) return error.WrongSize;
            if (!std.mem.eql(u8, in[0..4], &state_magic)) return error.BadMagic;
            const ver = std.mem.readInt(u32, in[4..8], .little);
            if (ver != state_version and ver != state_version_128k_cart_ram and
                ver != state_version_no_rom_crc and ver != state_version_no_cart_ram)
                return error.UnsupportedVersion;
            const cart_ram_len = stateCartRamLen(ver);
            const with_rom_crc = ver >= state_version_128k_cart_ram;
            const expect: usize = state_header_size + payload_size +
                cart_ram_len + @as(usize, if (with_rom_crc) 4 else 0);
            const payload = in[state_header_size..@min(in.len, state_header_size + payload_size)];
            if (std.mem.readInt(u32, in[8..12], .little) != payload_size or
                in.len != expect)
                return error.WrongSize;
            if (in[12] != accuracy_tag) return error.Corrupt;
            // A state whose layout fingerprint disagrees was written by a
            // build whose field tree differs — even at the same version and
            // byte count. Refusing it here is what stops a same-size field
            // reorder from deserializing garbage into the wrong fields.
            if (std.mem.readInt(u24, in[13..16], .little) != fingerprint)
                return error.UnsupportedVersion;
            // Image identity (version 9+): refuse BEFORE touching the
            // machine — restoring another image's state is never partial
            // damage, it is a different machine entirely. Pre-9 states
            // carry no identity and load on trust, as they always did.
            if (with_rom_crc and !console.dbg_ignore_state_rom_crc and
                std.mem.readInt(u32, in[state_header_size + payload_size + cart_ram_len ..][0..4], .little) != self.bus.cart.rom_crc)
                return error.WrongRom;
            _ = serialize.read(Self, self, payload) catch return error.Corrupt;
            // Cart RAM rides after the payload since version 8; an older
            // state simply never saved it, and the machine keeps what it
            // has (battery SRAM semantics — the pre-8 status quo).
            if (cart_ram_len != 0) {
                @memcpy(&self.bus.cart.sram, in[state_header_size + payload_size ..][0..cart_mod.max_sram]);
                if (cart_ram_len > cart_mod.max_sram)
                    @memcpy(&self.bus.cart.sram_hi, in[state_header_size + payload_size + cart_mod.max_sram ..][0..cart_mod.max_sram_hi])
                else
                    // An older state's tail has no second bank; it was zero
                    // when that state was written (no cart used it).
                    @memset(&self.bus.cart.sram_hi, 0);
            }
            self.postLoad();
        }
    };
}
