//! CPU I/O multiply/divide unit ($4202-$4206 in, $4214-$4217 out).
//!
//! Results are computed instantly on the trigger write. Real hardware takes
//! 8 (multiply) / 16 (divide) CPU cycles; games overwhelmingly wait the
//! documented time, so instant results are safe for the fast core. The
//! accurate core can add result-latency emulation later.

const std = @import("std");

pub const MathUnit = struct {
    wrmpya: u8, // $4202
    dividend: u16, // $4204/$4205 (shared with multiply result register)
    rddiv: u16, // $4214/$4215 quotient
    rdmpy: u16, // $4216/$4217 product / remainder

    pub const init: MathUnit = .{ .wrmpya = 0xFF, .dividend = 0xFFFF, .rddiv = 0, .rdmpy = 0 };

    /// $4203 write: start 8x8 multiply.
    pub fn writeMultiplicand(self: *MathUnit, wrmpyb: u8) void {
        self.rdmpy = @as(u16, self.wrmpya) * wrmpyb;
        // Hardware quirk: RDDIV holds the multiplicand after a multiply.
        self.rddiv = wrmpyb;
    }

    /// $4206 write: start 16/8 divide.
    pub fn writeDivisor(self: *MathUnit, divisor: u8) void {
        if (divisor == 0) {
            self.rddiv = 0xFFFF;
            self.rdmpy = self.dividend;
        } else {
            self.rddiv = self.dividend / divisor;
            self.rdmpy = self.dividend % divisor;
        }
    }
};

test "multiply and divide" {
    var mu: MathUnit = .init;
    mu.wrmpya = 200;
    mu.writeMultiplicand(100);
    try std.testing.expectEqual(@as(u16, 20000), mu.rdmpy);

    mu.dividend = 1000;
    mu.writeDivisor(33);
    try std.testing.expectEqual(@as(u16, 30), mu.rddiv);
    try std.testing.expectEqual(@as(u16, 10), mu.rdmpy);

    mu.writeDivisor(0);
    try std.testing.expectEqual(@as(u16, 0xFFFF), mu.rddiv);
    try std.testing.expectEqual(@as(u16, 1000), mu.rdmpy);
}
