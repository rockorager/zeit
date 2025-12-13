const std = @import("std");

/// Ben Joffe's fast full-range leap year algorithm
/// https://www.benjoffe.com/fast-leap-year
fn isLeapYear(year: i32) bool {
    const cen_bias: u32 = 2147483600;
    const cen_mul: u32 = 42949673;
    const cen_cutoff: u32 = 171798692;

    const a: u32 = @bitCast(year +% @as(i32, @bitCast(cen_bias)));
    const low: u32 = a *% cen_mul;
    const is_likely_cen = low < cen_cutoff;
    const mask: u5 = if (is_likely_cen) 15 else 3;
    return (year & mask) == 0;
}

pub fn main() !void {
    var result: u64 = 0;
    const iterations: i32 = 100_000_000;

    var year: i32 = -iterations / 2;
    while (year < iterations / 2) : (year += 1) {
        if (isLeapYear(year)) result += 1;
    }

    std.debug.print("result: {}\n", .{result});
}
