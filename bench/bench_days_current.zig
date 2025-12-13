const std = @import("std");

const Date = struct {
    year: i32,
    month: u4,
    day: u5,
};

const days_per_era = 365 * 400 + 97;

/// Current Hinnant algorithm
fn daysFromCivil(date: Date) i32 {
    const m: i32 = date.month;
    const y: i32 = if (m <= 2) date.year - 1 else date.year;
    const era = @divFloor(y, 400);
    const yoe: u32 = @intCast(y - era * 400);
    const doy = blk: {
        const a: u32 = if (m > 2) @intCast(m - 3) else @intCast(m + 9);
        const b = a * 153 + 2;
        break :blk @divFloor(b, 5) + date.day - 1;
    };
    const doe: i32 = @intCast(yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy);
    return era * days_per_era + doe - 719468;
}

pub fn main() !void {
    var result: i64 = 0;
    const iterations = 10_000_000;

    for (0..iterations) |i| {
        const year: i32 = @intCast(@as(i64, @intCast(i)) - iterations / 2);
        const date = Date{ .year = year, .month = 6, .day = 15 };
        result +%= daysFromCivil(date);
    }

    std.debug.print("result: {}\n", .{result});
}
