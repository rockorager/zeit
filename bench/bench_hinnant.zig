const std = @import("std");

const Date = struct {
    year: i32,
    month: u4,
    day: u5,
};

const days_per_era = 365 * 400 + 97;

/// Howard Hinnant's algorithm
/// https://howardhinnant.github.io/date_algorithms.html#civil_from_days
fn civilFromDays(days: i32) Date {
    const z = days + 719468;
    const era = @divFloor(z, days_per_era);
    const doe: u32 = @intCast(z - era * days_per_era);
    const yoe: u32 = @intCast(
        @divFloor(
            doe -
                @divFloor(doe, 1460) +
                @divFloor(doe, 36524) -
                @divFloor(doe, 146096),
            365,
        ),
    );
    const y: i32 = @as(i32, @intCast(yoe)) + era * 400;
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    const d = doy - @divFloor(153 * mp + 2, 5) + 1;
    const m = if (mp < 10) mp + 3 else mp - 9;
    return .{
        .year = if (m <= 2) y + 1 else y,
        .month = @intCast(m),
        .day = @truncate(d),
    };
}

pub fn main() !void {
    var result: i64 = 0;
    const iterations = 10_000_000;

    for (0..iterations) |i| {
        const days: i32 = @intCast(@as(i64, @intCast(i)) - iterations / 2);
        const date = civilFromDays(days);
        result +%= @as(i64, date.year) + @as(i64, date.month) + @as(i64, date.day);
    }

    std.debug.print("result: {}\n", .{result});
}
