const std = @import("std");

/// Current Neri/Schneider algorithm
fn isLeapYear(year: i32) bool {
    const d: i32 = if (@mod(year, 100) != 0) 4 else 16;
    return (year & (d - 1)) == 0;
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
