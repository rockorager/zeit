const std = @import("std");
const builtin = @import("builtin");
const tz_names = @import("tz_names.zig");
pub const timezone = @import("timezone.zig");

const assert = std.debug.assert;

pub const TimeZone = timezone.TimeZone;
pub const TZName = tz_names.TZName;

const ns_per_us = std.time.ns_per_us;
const ns_per_ms = std.time.ns_per_ms;
const ns_per_s = std.time.ns_per_s;
const ns_per_min = std.time.ns_per_min;
const ns_per_hour = std.time.ns_per_hour;
const ns_per_day = std.time.ns_per_day;
const s_per_min = std.time.s_per_min;
const s_per_hour = std.time.s_per_hour;
const s_per_day = std.time.s_per_day;
const days_per_era = 365 * 400 + 97;

pub const utc: TimeZone = .{ .fixed = .{
    .name = "UTC",
    .offset = 0,
    .is_dst = false,
} };

pub fn local(alloc: std.mem.Allocator) !TimeZone {
    switch (builtin.os.tag) {
        .windows => {
            const win = try timezone.Windows.local(alloc);
            return .{ .windows = win };
        },
        else => {
            // TODO: consult TZ
            const f = try std.fs.cwd().openFile("/etc/localtime", .{});
            return .{ .tzinfo = try timezone.TZInfo.parse(alloc, f.reader()) };
        },
    }
}

pub fn loadTimeZoneFromName(alloc: std.mem.Allocator, name: TZName) !TimeZone {
    return loadTimeZone(alloc, name.asText());
}

pub fn loadTimeZone(alloc: std.mem.Allocator, loc: []const u8) !TimeZone {
    const zone_dirs = [_][]const u8{
        "/usr/share/zoneinfo/",
        "/usr/share/lib/zoneinfo/",
        "/usr/lib/locale/TZ/",
        "/etc/zoneinfo",
    };
    var dir: std.fs.Dir = for (zone_dirs) |zone_dir| {
        const dir = std.fs.openDirAbsolute(zone_dir, .{}) catch continue;
        break dir;
    } else return error.NoTimeZone;
    defer dir.close();
    const f = try dir.openFile(loc, .{});
    return .{ .tzinfo = try timezone.TZInfo.parse(alloc, f.reader()) };
}

/// An Instant in time. Instants occur at a precise time and place, thus must
/// always carry with them a timezone.
pub const Instant = struct {
    /// the instant of time, in nanoseconds
    timestamp: i128,
    /// every instant occurs in a timezone. This is the timezone
    timezone: *const TimeZone,

    pub const Config = struct {
        source: Source = .now,
        timezone: *const TimeZone = &utc,
    };

    /// possible sources to create an Instant
    pub const Source = union(enum) {
        /// the current system time
        now,

        /// a specific unix timestamp (in seconds)
        unix_timestamp: i64,

        /// a specific unix timestamp (in nanoseconds)
        unix_nano: i128,

        /// create an Instant from a calendar date and time
        time: Time,

        /// parse a datetime from an ISO8601 string
        /// Supports most ISO8601 formats, _except_:
        /// - Week numbers (ie YYYY-Www)
        /// - Fractional minutes (ie YYYY-MM-DDTHH:MM.mmm)
        ///
        /// Strings can be in the extended or compact format and use ' ' or "T"
        /// as the time delimiter
        /// Examples of paresable strings:
        /// YYYY-MM-DD
        /// YYYY-MM-DDTHH
        /// YYYY-MM-DDTHH:MM
        /// YYYY-MM-DDTHH:MM:SS
        /// YYYY-MM-DDTHH:MM:SS.sss
        /// YYYY-MM-DDTHH:MM:SS.ssssss
        /// YYYY-MM-DDTHH:MM:SSZ
        /// YYYY-MM-DDTHH:MM:SS+hh:mm
        /// YYYYMMDDTHHMMSSZ
        iso8601: []const u8,

        /// Parse a datetime from an RFC3339 string. RFC3339 is similar to
        /// ISO8601 but is more strict, and allows for arbitrary fractional
        /// seconds. Using this field will use the same parser `iso8601`, but is
        /// provided for clarity
        /// Format: YYYY-MM-DDTHH:MM:SS.sss+hh:mm
        rfc3339: []const u8,

        /// Parse a datetime from an RFC5322 date-time spec
        rfc5322: []const u8,

        /// Parse a datetime from an RFC2822 date-time spec. This is an alias for RFC5322
        rfc2822: []const u8,
    };

    /// convert this Instant to another timezone
    pub fn in(self: Instant, zone: TimeZone) Instant {
        return .{
            .timestamp = self.timestamp,
            .timezone = zone,
        };
    }

    // convert the nanosecond timestamp into a unix timestamp (in seconds)
    pub fn unixTimestamp(self: Instant) i64 {
        return @intCast(@divFloor(self.timestamp, ns_per_s));
    }

    // generate a calendar date and time for this instant
    pub fn time(self: Instant) Time {
        const adjusted = self.timezone.adjust(self.unixTimestamp());
        const days = daysSinceEpoch(adjusted.timestamp);
        const date = civilFromDays(days);

        var seconds = @mod(adjusted.timestamp, s_per_day);
        const hours = @divFloor(seconds, s_per_hour);
        seconds -= hours * s_per_hour;
        const minutes = @divFloor(seconds, s_per_min);
        seconds -= minutes * s_per_min;

        // get the nanoseconds from the original timestamp
        var nanos = @mod(self.timestamp, ns_per_s);
        const millis = @divFloor(nanos, ns_per_ms);
        nanos -= millis * ns_per_ms;
        const micros = @divFloor(nanos, ns_per_us);
        nanos -= micros * ns_per_us;

        return .{
            .year = date.year,
            .month = date.month,
            .day = date.day,
            .hour = @intCast(hours),
            .minute = @intCast(minutes),
            .second = @intCast(seconds),
            .millisecond = @intCast(millis),
            .microsecond = @intCast(micros),
            .nanosecond = @intCast(nanos),
            .offset = @intCast(adjusted.timestamp - self.unixTimestamp()),
        };
    }

    /// add the duration to the Instant
    pub fn add(self: Instant, duration: Duration) Instant {
        const ns = duration.days * ns_per_day +
            duration.hours * ns_per_hour +
            duration.minutes * ns_per_min +
            duration.seconds * ns_per_s +
            duration.milliseconds * ns_per_ms +
            duration.microseconds * ns_per_us +
            duration.nanoseconds;
        return .{
            .timestamp = self.timestamp + ns,
            .timezone = self.timezone,
        };
    }

    /// subtract the duration from the Instant
    pub fn subtract(self: Instant, duration: Duration) Instant {
        const ns = duration.days * ns_per_day +
            duration.hours * ns_per_hour +
            duration.minutes * ns_per_min +
            duration.seconds * ns_per_s +
            duration.milliseconds * ns_per_ms +
            duration.microseconds * ns_per_us +
            duration.nanoseconds;
        return .{
            .timestamp = self.timestamp - ns,
            .timezone = self.timezone,
        };
    }
};

/// create a new Instant
pub fn instant(cfg: Instant.Config) !Instant {
    const ts: i128 = switch (cfg.source) {
        .now => std.time.nanoTimestamp(),
        .unix_timestamp => |unix| unix * ns_per_s,
        .unix_nano => |nano| nano,
        .time => |time| time.instant().timestamp,
        .iso8601,
        .rfc3339,
        => |iso| blk: {
            const t = try Time.fromISO8601(iso);
            break :blk t.instant().timestamp;
        },
        .rfc2822,
        .rfc5322,
        => |eml| blk: {
            const t = try Time.fromRFC5322(eml);
            break :blk t.instant().timestamp;
        },
    };
    return .{
        .timestamp = ts,
        .timezone = cfg.timezone,
    };
}

test "instant" {
    const original = Instant{
        .timestamp = std.time.nanoTimestamp(),
        .timezone = &utc,
    };
    const time = original.time();
    const round_trip = time.instant();
    try std.testing.expectEqual(original.timestamp, round_trip.timestamp);
}

pub const Month = enum(u4) {
    jan = 1,
    feb,
    mar,
    apr,
    may,
    jun,
    jul,
    aug,
    sep,
    oct,
    nov,
    dec,

    /// returns the last day of the month
    /// Neri/Schneider algorithm
    pub fn lastDay(self: Month, year: i32) u5 {
        const m: u5 = @intFromEnum(self);
        if (m == 2) return if (isLeapYear(year)) 29 else 28;
        return 30 | (m ^ (m >> 3));
    }

    /// returns the full name of the month, eg "January"
    pub fn name(self: Month) []const u8 {
        return switch (self) {
            .jan => "January",
            .feb => "February",
            .mar => "March",
            .apr => "April",
            .may => "May",
            .jun => "June",
            .jul => "July",
            .aug => "August",
            .sep => "September",
            .oct => "October",
            .nov => "November",
            .dec => "December",
        };
    }

    /// returns the short name of the month, eg "Jan"
    pub fn shortName(self: Month) []const u8 {
        return self.name()[0..3];
    }

    test "lastDayOfMonth" {
        try std.testing.expectEqual(29, Month.feb.lastDay(2000));

        try std.testing.expectEqual(31, Month.jan.lastDay(2001));
        try std.testing.expectEqual(28, Month.feb.lastDay(2001));
        try std.testing.expectEqual(31, Month.mar.lastDay(2001));
        try std.testing.expectEqual(30, Month.apr.lastDay(2001));
        try std.testing.expectEqual(31, Month.may.lastDay(2001));
        try std.testing.expectEqual(30, Month.jun.lastDay(2001));
        try std.testing.expectEqual(31, Month.jul.lastDay(2001));
        try std.testing.expectEqual(31, Month.aug.lastDay(2001));
        try std.testing.expectEqual(30, Month.sep.lastDay(2001));
        try std.testing.expectEqual(31, Month.oct.lastDay(2001));
        try std.testing.expectEqual(30, Month.nov.lastDay(2001));
        try std.testing.expectEqual(31, Month.dec.lastDay(2001));
    }

    /// the number of days in a year before this month
    pub fn daysBefore(self: Month, year: i32) u9 {
        var m = @intFromEnum(self) - 1;
        var result: u9 = 0;
        while (m > 0) : (m -= 1) {
            const month: Month = @enumFromInt(m);
            result += month.lastDay(year);
        }
        return result;
    }

    test "daysBefore" {
        try std.testing.expectEqual(60, Month.mar.daysBefore(2000));
        try std.testing.expectEqual(0, Month.jan.daysBefore(2001));
        try std.testing.expectEqual(31, Month.feb.daysBefore(2001));
        try std.testing.expectEqual(59, Month.mar.daysBefore(2001));
    }
};

pub const Duration = struct {
    days: usize = 0,
    hours: usize = 0,
    minutes: usize = 0,
    seconds: usize = 0,
    milliseconds: usize = 0,
    microseconds: usize = 0,
    nanoseconds: usize = 0,
};

pub const Weekday = enum(u3) {
    sun = 0,
    mon,
    tue,
    wed,
    thu,
    fri,
    sat,

    /// number of days from self until other. Returns 0 when self == other
    pub fn daysUntil(self: Weekday, other: Weekday) u3 {
        const d = @intFromEnum(other) -% @intFromEnum(self);
        return if (d <= 6) @intCast(d) else @intCast(d +% 7);
    }

    /// returns the full name of the day, eg "Tuesday"
    pub fn name(self: Weekday) []const u8 {
        return switch (self) {
            .sun => "Sunday",
            .mon => "Monday",
            .tue => "Tuesday",
            .wed => "Wednesday",
            .thu => "Thursday",
            .fri => "Friday",
            .sat => "Saturday",
        };
    }

    /// returns the short name of the day, eg "Tue"
    pub fn shortName(self: Weekday) []const u8 {
        return self.name()[0..3];
    }

    test "daysUntil" {
        const wed: Weekday = .wed;
        try std.testing.expectEqual(0, wed.daysUntil(.wed));
        try std.testing.expectEqual(6, wed.daysUntil(.tue));
    }
};

pub const Date = struct {
    year: i32,
    month: Month,
    day: u5, // 1-31
};

pub const Time = struct {
    year: i32 = 1970,
    month: Month = .jan,
    day: u5 = 1, // 1-31
    hour: u5 = 0, // 0-23
    minute: u6 = 0, // 0-59
    second: u6 = 0, // 0-60
    millisecond: u10 = 0, // 0-999
    microsecond: u10 = 0, // 0-999
    nanosecond: u10 = 0, // 0-999
    offset: i32 = 0, // offset from UTC in seconds

    /// Creates a UTC Instant for this time
    pub fn instant(self: Time) Instant {
        const days = daysFromCivil(.{
            .year = self.year,
            .month = self.month,
            .day = self.day,
        });
        return .{
            .timestamp = @as(i128, days) * ns_per_day +
                @as(i128, self.hour) * ns_per_hour +
                @as(i128, self.minute) * ns_per_min +
                @as(i128, self.second) * ns_per_s +
                @as(i128, self.millisecond) * ns_per_ms +
                @as(i128, self.microsecond) * ns_per_us +
                @as(i128, self.nanosecond) -
                @as(i128, self.offset) * ns_per_s,

            .timezone = &utc,
        };
    }

    pub fn fromISO8601(iso: []const u8) !Time {
        const parseInt = std.fmt.parseInt;
        var time: Time = .{};
        const State = enum {
            year,
            month_or_ordinal,
            day,
            hour,
            minute,
            minute_fraction_or_second,
            second_fraction_or_offset,
        };
        var state: State = .year;
        var i: usize = 0;
        while (i < iso.len) {
            switch (state) {
                .year => {
                    if (iso.len <= 4) {
                        // year only data
                        const int = try parseInt(i32, iso, 10);
                        time.year = int * std.math.pow(i32, 10, @as(i32, @intCast(4 - iso.len)));
                        break;
                    } else {
                        time.year = try parseInt(i32, iso[0..4], 10);
                        state = .month_or_ordinal;
                        i += 4;
                        if (iso[i] == '-') i += 1;
                    }
                },
                .month_or_ordinal => {
                    const token_end = std.mem.indexOfAnyPos(u8, iso, i, "- T") orelse iso.len;
                    switch (token_end - i) {
                        2 => {
                            const m: u4 = try parseInt(u4, iso[i..token_end], 10);
                            time.month = @enumFromInt(m);
                            state = .day;
                        },
                        3 => { // ordinal
                            const doy = try parseInt(u9, iso[i..token_end], 10);
                            var m: u4 = 1;
                            var days: u9 = 0;
                            while (m <= 12) : (m += 1) {
                                const month: Month = @enumFromInt(m);

                                if (days + month.lastDay(time.year) < doy) {
                                    days += month.lastDay(time.year);
                                    continue;
                                }
                                time.month = month;
                                time.day = @intCast(doy - days);
                                break;
                            }
                            state = .hour;
                        },
                        4 => { // MMDD
                            const m: u4 = try parseInt(u4, iso[i .. i + 2], 10);
                            time.month = @enumFromInt(m);
                            time.day = try parseInt(u4, iso[i + 2 .. token_end], 10);
                            state = .hour;
                        },
                        else => return error.InvalidISO8601,
                    }
                    i = token_end + 1;
                },
                .day => {
                    time.day = try parseInt(u5, iso[i .. i + 2], 10);
                    // add 3 instead of 2 because we either have a trailing ' ',
                    // 'T', or EOF
                    i += 3;
                    state = .hour;
                },
                .hour => {
                    time.hour = try parseInt(u5, iso[i .. i + 2], 10);
                    i += 2;
                    state = .minute;
                },
                .minute => {
                    if (iso[i] == ':') i += 1;
                    time.minute = try parseInt(u6, iso[i .. i + 2], 10);
                    i += 2;
                    state = .minute_fraction_or_second;
                },
                .minute_fraction_or_second => {
                    const b = iso[i];
                    if (b == '.') return error.UnhandledFormat; // TODO:
                    if (b == ':') i += 1;
                    time.second = try parseInt(u6, iso[i .. i + 2], 10);
                    i += 2;
                    state = .second_fraction_or_offset;
                },
                .second_fraction_or_offset => {
                    switch (iso[i]) {
                        'Z' => break,
                        '+', '-' => {
                            const sign: i32 = if (iso[i] == '-') -1 else 1;
                            i += 1;
                            const hour = try parseInt(u5, iso[i .. i + 2], 10);
                            i += 2;
                            time.offset = sign * hour * s_per_hour;
                            if (i >= iso.len - 1) break;
                            if (iso[i] == ':') i += 1;
                            const minute = try parseInt(u6, iso[i .. i + 2], 10);
                            time.offset += sign * minute * s_per_min;
                            i += 2;
                            break;
                        },
                        '.' => {
                            i += 1;
                            const frac_end = std.mem.indexOfAnyPos(u8, iso, i, "Z+-") orelse iso.len;
                            const rhs = try parseInt(u64, iso[i..frac_end], 10);
                            const sigs = frac_end - i;
                            // convert sigs to nanoseconds
                            const pow = std.math.pow(u64, 10, @as(u64, @intCast(9 - sigs)));
                            var nanos = rhs * pow;
                            time.millisecond = @intCast(@divFloor(nanos, ns_per_ms));
                            nanos -= @as(u64, time.millisecond) * ns_per_ms;
                            time.microsecond = @intCast(@divFloor(nanos, ns_per_us));
                            nanos -= @as(u64, time.microsecond) * ns_per_us;
                            time.nanosecond = @intCast(nanos);
                            i = frac_end;
                        },
                        else => return error.InvalidISO8601,
                    }
                },
            }
        }
        return time;
    }

    test "fromISO8601" {
        {
            const year = try Time.fromISO8601("2000");
            try std.testing.expectEqual(2000, year.year);
        }
        {
            const ym = try Time.fromISO8601("200002");
            try std.testing.expectEqual(2000, ym.year);
            try std.testing.expectEqual(.feb, ym.month);

            const ym_ext = try Time.fromISO8601("2000-02");
            try std.testing.expectEqual(2000, ym_ext.year);
            try std.testing.expectEqual(.feb, ym_ext.month);
        }
        {
            const ymd = try Time.fromISO8601("20000212");
            try std.testing.expectEqual(2000, ymd.year);
            try std.testing.expectEqual(.feb, ymd.month);
            try std.testing.expectEqual(12, ymd.day);

            const ymd_ext = try Time.fromISO8601("2000-02-12");
            try std.testing.expectEqual(2000, ymd_ext.year);
            try std.testing.expectEqual(.feb, ymd_ext.month);
            try std.testing.expectEqual(12, ymd_ext.day);
        }
        {
            const ordinal = try Time.fromISO8601("2000031");
            try std.testing.expectEqual(2000, ordinal.year);
            try std.testing.expectEqual(.jan, ordinal.month);
            try std.testing.expectEqual(31, ordinal.day);

            const ordinal_ext = try Time.fromISO8601("2000-043");
            try std.testing.expectEqual(2000, ordinal_ext.year);
            try std.testing.expectEqual(.feb, ordinal_ext.month);
            try std.testing.expectEqual(12, ordinal_ext.day);
        }
        {
            const ymdh = try Time.fromISO8601("20000212 11");
            try std.testing.expectEqual(2000, ymdh.year);
            try std.testing.expectEqual(.feb, ymdh.month);
            try std.testing.expectEqual(12, ymdh.day);
            try std.testing.expectEqual(11, ymdh.hour);

            const ymdh_ext = try Time.fromISO8601("2000-02-12T11");
            try std.testing.expectEqual(2000, ymdh_ext.year);
            try std.testing.expectEqual(.feb, ymdh_ext.month);
            try std.testing.expectEqual(12, ymdh_ext.day);
            try std.testing.expectEqual(11, ymdh_ext.hour);
        }
        {
            const full = try Time.fromISO8601("20000212 111213Z");
            try std.testing.expectEqual(2000, full.year);
            try std.testing.expectEqual(.feb, full.month);
            try std.testing.expectEqual(12, full.day);
            try std.testing.expectEqual(11, full.hour);
            try std.testing.expectEqual(12, full.minute);
            try std.testing.expectEqual(13, full.second);

            const full_ext = try Time.fromISO8601("2000-02-12T11:12:13Z");
            try std.testing.expectEqual(2000, full_ext.year);
            try std.testing.expectEqual(.feb, full_ext.month);
            try std.testing.expectEqual(12, full_ext.day);
            try std.testing.expectEqual(11, full_ext.hour);
            try std.testing.expectEqual(12, full_ext.minute);
            try std.testing.expectEqual(13, full_ext.second);
        }
        {
            const s_frac = try Time.fromISO8601("2000-02-12T11:12:13.123Z");
            try std.testing.expectEqual(123, s_frac.millisecond);
            try std.testing.expectEqual(0, s_frac.microsecond);
            try std.testing.expectEqual(0, s_frac.nanosecond);
        }
        {
            const offset = try Time.fromISO8601("2000-02-12T11:12:13.123-12:00");
            try std.testing.expectEqual(-12 * s_per_hour, offset.offset);
        }
        {
            const offset = try Time.fromISO8601("2000-02-12T11:12:13+12:30");
            try std.testing.expectEqual(12 * s_per_hour + 30 * s_per_min, offset.offset);
        }
        {
            const offset = try Time.fromISO8601("20000212T111213+1230");
            try std.testing.expectEqual(12 * s_per_hour + 30 * s_per_min, offset.offset);
        }
    }

    pub fn fromRFC5322(eml: []const u8) !Time {
        const parseInt = std.fmt.parseInt;
        var time: Time = .{};
        var i: usize = 0;
        // day
        {
            // consume until a digit
            while (i < eml.len and !std.ascii.isDigit(eml[i])) : (i += 1) {}
            const end = std.mem.indexOfScalarPos(u8, eml, i, ' ') orelse return error.InvalidFormat;
            time.day = try parseInt(u5, eml[i..end], 10);
            i = end + 1;
        }

        // month
        {
            // consume until an alpha
            while (i < eml.len and !std.ascii.isAlphabetic(eml[i])) : (i += 1) {}
            assert(eml.len >= i + 3);
            var buf: [3]u8 = undefined;
            buf[0] = std.ascii.toLower(eml[i]);
            buf[1] = std.ascii.toLower(eml[i + 1]);
            buf[2] = std.ascii.toLower(eml[i + 2]);
            time.month = std.meta.stringToEnum(Month, &buf) orelse return error.InvalidFormat;
            i += 3;
        }

        // year
        {
            // consume until a digit
            while (i < eml.len and !std.ascii.isDigit(eml[i])) : (i += 1) {}
            assert(eml.len >= i + 4);
            time.year = try parseInt(i32, eml[i .. i + 4], 10);
            i += 4;
        }

        // hour
        {
            // consume until a digit
            while (i < eml.len and !std.ascii.isDigit(eml[i])) : (i += 1) {}
            const end = std.mem.indexOfScalarPos(u8, eml, i, ':') orelse return error.InvalidFormat;
            time.hour = try parseInt(u5, eml[i..end], 10);
            i = end + 1;
        }
        // minute
        {
            // consume until a digit
            while (i < eml.len and !std.ascii.isDigit(eml[i])) : (i += 1) {}
            assert(i + 2 < eml.len);
            time.minute = try parseInt(u6, eml[i .. i + 2], 10);
            i += 2;
        }
        // second and zone
        {
            assert(i < eml.len);
            // seconds are optional
            if (eml[i] == ':') {
                i += 1;
                assert(i + 2 < eml.len);
                time.second = try parseInt(u6, eml[i .. i + 2], 10);
                i += 2;
            }
            // consume whitespace
            while (i < eml.len and std.ascii.isWhitespace(eml[i])) : (i += 1) {}
            assert(i + 5 <= eml.len);
            const hours = try parseInt(i32, eml[i .. i + 3], 10);
            const minutes = try parseInt(i32, eml[i + 3 .. i + 5], 10);
            const offset_minutes: i32 = if (hours > 0)
                hours * 60 + minutes
            else
                hours * 60 - minutes;
            time.offset = offset_minutes * 60;
        }
        return time;
    }

    test "fromRFC5322" {
        {
            const time = try Time.fromRFC5322("Thu, 13 Feb 1969 23:32:54 -0330");
            try std.testing.expectEqual(1969, time.year);
            try std.testing.expectEqual(.feb, time.month);
            try std.testing.expectEqual(13, time.day);
            try std.testing.expectEqual(23, time.hour);
            try std.testing.expectEqual(32, time.minute);
            try std.testing.expectEqual(54, time.second);
            try std.testing.expectEqual(-12_600, time.offset);
        }
        {
            // FWS everywhere
            const time = try Time.fromRFC5322("  Thu,    13 \tFeb 1969\t\r\n 23:32:54    -0330");
            try std.testing.expectEqual(1969, time.year);
            try std.testing.expectEqual(.feb, time.month);
            try std.testing.expectEqual(13, time.day);
            try std.testing.expectEqual(23, time.hour);
            try std.testing.expectEqual(32, time.minute);
            try std.testing.expectEqual(54, time.second);
            try std.testing.expectEqual(-12_600, time.offset);
        }
    }

    pub const Format = union(enum) {
        rfc3339, // YYYY-MM-DD-THH:MM:SS.sss+00:00
    };

    pub fn bufPrint(self: Time, buf: []u8, fmt: Format) ![]u8 {
        switch (fmt) {
            .rfc3339 => {
                if (self.year < 0) return error.InvalidTime;
                if (self.offset == 0)
                    return std.fmt.bufPrint(
                        buf,
                        "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}Z",
                        .{
                            @as(u32, @intCast(self.year)),
                            @intFromEnum(self.month),
                            self.day,
                            self.hour,
                            self.minute,
                            self.second,
                            self.millisecond,
                        },
                    )
                else {
                    const h = @divFloor(@abs(self.offset), s_per_hour);
                    const min = @divFloor(@abs(self.offset) - h * s_per_hour, s_per_min);
                    const sign: u8 = if (self.offset > 0) '+' else '-';
                    return std.fmt.bufPrint(
                        buf,
                        "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}{c}{d:0>2}:{d:0>2}",
                        .{
                            @as(u32, @intCast(self.year)),
                            @intFromEnum(self.month),
                            self.day,
                            self.hour,
                            self.minute,
                            self.second,
                            self.millisecond,
                            sign,
                            h,
                            min,
                        },
                    );
                }
            },
        }
    }
};

pub fn daysSinceEpoch(timestamp: i64) i64 {
    return @divTrunc(timestamp, s_per_day);
}

test "days since epoch" {
    try std.testing.expectEqual(0, daysSinceEpoch(0));
    try std.testing.expectEqual(-1, daysSinceEpoch(-(s_per_day + 1)));
    try std.testing.expectEqual(1, daysSinceEpoch(s_per_day + 1));
    try std.testing.expectEqual(19797, daysSinceEpoch(1710523947));
}

pub fn isLeapYear(year: i32) bool {
    // Neri/Schneider algorithm
    const d: i32 = if (@mod(year, 100) != 0) 4 else 16;
    return (year & (d - 1)) == 0;
    // if (@mod(year, 4) != 0)
    //     return false;
    // if (@mod(year, 100) != 0)
    //     return true;
    // return (0 == @mod(year, 400));
}

/// returns the weekday given a number of days since the unix epoch
/// https://howardhinnant.github.io/date_algorithms.html#weekday_from_days
pub fn weekdayFromDays(days: i64) Weekday {
    if (days >= -4)
        return @enumFromInt(@mod((days + 4), 7))
    else
        return @enumFromInt(@mod((days + 5), 7) + 6);
}

test "weekdayFromDays" {
    try std.testing.expectEqual(.thu, weekdayFromDays(0));
}

/// return the civil date from the number of days since the epoch
/// This is an implementation of Howard Hinnant's algorithm
/// https://howardhinnant.github.io/date_algorithms.html#civil_from_days
pub fn civilFromDays(days: i64) Date {
    // shift epoch from 1970-01-01 to 0000-03-01
    const z = days + 719468;

    // Compute era
    const era = if (z >= 0)
        @divFloor(z, days_per_era)
    else
        @divFloor(z - days_per_era - 1, days_per_era);

    const doe: u32 = @intCast(z - era * days_per_era); // [0, days_per_era-1]
    const yoe: u32 = @intCast(
        @divFloor(
            doe -
                @divFloor(doe, 1460) +
                @divFloor(doe, 36524) -
                @divFloor(doe, 146096),
            365,
        ),
    ); // [0, 399]
    const y: i32 = @intCast(yoe + era * 400);
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100)); // [0, 365]
    const mp = @divFloor(5 * doy + 2, 153); // [0, 11]
    const d = doy - @divFloor(153 * mp + 2, 5) + 1; // [1, 31]
    const m = if (mp < 10) mp + 3 else mp - 9; // [1, 12]
    return .{
        .year = if (m <= 2) y + 1 else y,
        .month = @enumFromInt(m),
        .day = @truncate(d),
    };
}
/// return the number of days since the epoch from the civil date
pub fn daysFromCivil(date: Date) i64 {
    const m = @intFromEnum(date.month);
    const y = if (m <= 2) date.year - 1 else date.year;
    const era = if (y >= 0) @divFloor(y, 400) else @divFloor(y - 399, 400);
    const yoe: u32 = @intCast(y - era * 400);
    const doy = blk: {
        const a: u32 = if (m > 2) m - 3 else m + 9;
        const b = a * 153 + 2;
        break :blk @divFloor(b, 5) + date.day - 1;
    };
    const doe: i32 = @intCast(yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy);
    return era * days_per_era + doe - 719468;
}

test {
    std.testing.refAllDecls(@This());
    _ = @import("timezone.zig");
}
