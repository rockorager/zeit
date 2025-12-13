const std = @import("std");

const Date = struct {
    year: i32,
    month: u4,
    day: u5,
};

/// Ben Joffe's fast overflow-safe inverse function
/// https://www.benjoffe.com/fast-date-64
fn daysFromCivil(date: Date) i32 {
    const month: u32 = date.month;
    const bump: u32 = if (month <= 2) 1 else 0;
    const yrs: u32 = @bitCast(date.year +% 5880000 - @as(i32, @intCast(bump)));
    const cen: u32 = yrs / 100;
    const shift: i32 = if (bump == 1) 8829 else -2919;

    const year_days: u32 = yrs * 365 + yrs / 4 - cen + cen / 4;
    const month_days: u32 = @bitCast(@divFloor(979 * @as(i32, @intCast(month)) + shift, 32));
    return @bitCast(year_days +% month_days +% date.day -% 2148345369);
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
