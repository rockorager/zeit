const std = @import("std");
const builtin = @import("builtin");

const Date = struct {
    year: i32,
    month: u4,
    day: u5,
};

const is_arm = builtin.cpu.arch == .aarch64 or builtin.cpu.arch == .arm;

const ERAS: u64 = 4726498270;
const D_SHIFT: u64 = 146097 * ERAS - 719469;
const Y_SHIFT: u64 = 400 * ERAS - 1;

const SCALE: u64 = if (is_arm) 1 else 32;
const SHIFT_0: u64 = 30556 * SCALE;
const SHIFT_1: u64 = 5980 * SCALE;

const C1: u64 = 505054698555331;
const C2: u64 = 50504432782230121;
const C3: u64 = @as(u64, 8619973866219416) * 32 / SCALE;

/// Ben Joffe's very fast 64-bit date algorithm
/// https://www.benjoffe.com/fast-date-64
fn civilFromDays(days: i32) Date {
    const rev: u64 = D_SHIFT -% @as(u64, @bitCast(@as(i64, days)));
    const cen: u64 = @truncate(@as(u128, C1) * rev >> 64);
    const jul: u64 = rev +% cen -% cen / 4;
    const num: u128 = @as(u128, C2) * jul;
    const yrs: u64 = Y_SHIFT -% @as(u64, @truncate(num >> 64));
    const low: u64 = @truncate(num);
    const ypt: u64 = @truncate(@as(u128, 24451 * SCALE) * low >> 64);

    if (is_arm) {
        const shift: u64 = SHIFT_0;
        const N: u64 = (yrs % 4) * (16 * SCALE) +% shift -% ypt;
        const M: u64 = N / (2048 * SCALE);
        const D: u64 = @truncate(@as(u128, C3) * (N % (2048 * SCALE)) >> 64);
        const bump: u64 = if (M > 12) 1 else 0;
        const month: u4 = @intCast(if (bump == 1) M - 12 else M);
        const day: u5 = @intCast(D + 1);
        const year: i32 = @intCast(@as(i64, @bitCast(yrs)) + @as(i64, @intCast(bump)));
        return .{ .year = year, .month = month, .day = day };
    } else {
        const bump: u64 = if (ypt < (3952 * SCALE)) 1 else 0;
        const shift: u64 = if (bump == 1) SHIFT_1 else SHIFT_0;
        const N: u64 = (yrs % 4) * (16 * SCALE) +% shift -% ypt;
        const M: u64 = N / (2048 * SCALE);
        const D: u64 = @truncate(@as(u128, C3) * (N % (2048 * SCALE)) >> 64);
        const month: u4 = @intCast(M);
        const day: u5 = @intCast(D + 1);
        const year: i32 = @intCast(@as(i64, @bitCast(yrs)) + @as(i64, @intCast(bump)));
        return .{ .year = year, .month = month, .day = day };
    }
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
