const std = @import("std");

const Date = struct {
    year: i32,
    month: u4,
    day: u5,
};

const days_per_era = 365 * 400 + 97;

fn daysFromCivilCurrent(date: Date) i32 {
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

fn daysFromCivilBenjoffe(date: Date) i32 {
    const month: u32 = date.month;
    const bump: u32 = if (month <= 2) 1 else 0;
    const yrs: u32 = @bitCast(date.year +% 5880000 - @as(i32, @intCast(bump)));
    const cen: u32 = yrs / 100;
    const shift: i32 = if (bump == 1) 8829 else -2919;

    const year_days: u32 = yrs * 365 + yrs / 4 - cen + cen / 4;
    const month_days: u32 = @bitCast(@divFloor(979 * @as(i32, @intCast(month)) + shift, 32));
    return @bitCast(year_days +% month_days +% date.day -% 2148345369);
}

pub fn main() void {
    var mismatches: u32 = 0;

    // Test a wide range of years and all months/days
    const test_years = [_]i32{ -5000, -1000, -100, -1, 0, 1, 100, 1000, 1970, 2000, 2024, 5000, 100000, -100000 };

    for (test_years) |year| {
        for (1..13) |m| {
            const month: u4 = @intCast(m);
            for (1..29) |d| {
                const day: u5 = @intCast(d);
                const date = Date{ .year = year, .month = month, .day = day };
                const current = daysFromCivilCurrent(date);
                const benjoffe = daysFromCivilBenjoffe(date);

                if (current != benjoffe) {
                    mismatches += 1;
                    if (mismatches <= 10) {
                        std.debug.print("MISMATCH: {}-{:0>2}-{:0>2}: current={} benjoffe={}\n", .{ year, month, day, current, benjoffe });
                    }
                }
            }
        }
    }

    if (mismatches == 0) {
        std.debug.print("All tests passed!\n", .{});
    } else {
        std.debug.print("Total mismatches: {}\n", .{mismatches});
    }
}
