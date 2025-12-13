const std = @import("std");

fn isLeapYearCurrent(year: i32) bool {
    const d: i32 = if (@mod(year, 100) != 0) 4 else 16;
    return (year & (d - 1)) == 0;
}

fn isLeapYearBenjoffe(year: i32) bool {
    const cen_bias: u32 = 2147483600;
    const cen_mul: u32 = 42949673;
    const cen_cutoff: u32 = 171798692;

    const a: u32 = @bitCast(year +% @as(i32, @bitCast(cen_bias)));
    const low: u32 = a *% cen_mul;
    const is_likely_cen = low < cen_cutoff;
    const mask: u5 = if (is_likely_cen) 15 else 3;
    return (year & mask) == 0;
}

pub fn main() void {
    var mismatches: u32 = 0;

    // Test full range of interesting years
    var year: i32 = -1_000_000;
    while (year <= 1_000_000) : (year += 1) {
        const current = isLeapYearCurrent(year);
        const benjoffe = isLeapYearBenjoffe(year);

        if (current != benjoffe) {
            mismatches += 1;
            if (mismatches <= 10) {
                std.debug.print("MISMATCH: year={}: current={} benjoffe={}\n", .{ year, current, benjoffe });
            }
        }
    }

    if (mismatches == 0) {
        std.debug.print("All tests passed!\n", .{});
    } else {
        std.debug.print("Total mismatches: {}\n", .{mismatches});
    }
}
