const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;

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

/// the UTC time zone
pub const utc: TimeZone = TimeZone.fixed("UTC", 0, false);

pub fn local(alloc: std.mem.Allocator) !TimeZone {
    // TODO: consult TZ, make platform portable
    const f = try std.fs.cwd().openFile("/etc/localtime", .{});
    return TimeZone.parse(alloc, f.reader());
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
    return TimeZone.parse(alloc, f.reader());
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
    };

    /// convert this Instant to another timezone
    pub fn in(self: Instant, timezone: *const TimeZone) Instant {
        return .{
            .timestamp = self.timestamp,
            .timezone = timezone,
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
    };
    return .{
        .timestamp = ts,
        .timezone = cfg.timezone,
    };
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
            .timestamp = days * ns_per_day +
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

    test "instant" {
        const original = Instant{
            .timestamp = std.time.nanoTimestamp(),
            .timezone = &utc,
        };
        const time = original.time();
        const round_trip = time.instant();
        try std.testing.expectEqual(original.timestamp, round_trip.timestamp);
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

pub const TimeZone = struct {
    allocator: std.mem.Allocator,
    transitions: []const Transition,
    timetypes: []const Timetype,
    leapseconds: []const Leapsecond,
    footer: ?[]const u8,
    posix_tz: ?Posix,
    fixed: ?Fixed,

    pub const AdjustedTime = struct {
        designation: []const u8,
        timestamp: i64,
        is_dst: bool,
    };

    const Leapsecond = struct {
        occurrence: i48,
        correction: i16,
    };

    const Fixed = struct {
        name: []const u8,
        offset: i64,
        is_dst: bool,
    };

    const Timetype = struct {
        offset: i32,
        flags: u8,
        name_data: [6:0]u8,

        pub fn name(self: *const Timetype) [:0]const u8 {
            return std.mem.sliceTo(self.name_data[0..], 0);
        }

        pub fn isDst(self: Timetype) bool {
            return (self.flags & 0x01) > 0;
        }

        pub fn standardTimeIndicator(self: Timetype) bool {
            return (self.flags & 0x02) > 0;
        }

        pub fn utIndicator(self: Timetype) bool {
            return (self.flags & 0x04) > 0;
        }
    };

    const Transition = struct {
        ts: i64,
        timetype: *Timetype,
    };

    const Header = extern struct {
        magic: [4]u8,
        version: u8,
        reserved: [15]u8,
        counts: extern struct {
            isutcnt: u32,
            isstdcnt: u32,
            leapcnt: u32,
            timecnt: u32,
            typecnt: u32,
            charcnt: u32,
        },
    };

    pub fn fixed(name: []const u8, offset: i64, is_dst: bool) TimeZone {
        return .{
            .allocator = undefined,
            .transitions = undefined,
            .timetypes = undefined,
            .leapseconds = undefined,
            .footer = null,
            .posix_tz = null,
            .fixed = .{
                .name = name,
                .offset = offset,
                .is_dst = is_dst,
            },
        };
    }

    pub fn parse(allocator: std.mem.Allocator, reader: anytype) !TimeZone {
        var legacy_header = try reader.readStruct(Header);
        if (!std.mem.eql(u8, &legacy_header.magic, "TZif")) return error.BadHeader;
        if (legacy_header.version != 0 and legacy_header.version != '2' and legacy_header.version != '3') return error.BadVersion;

        if (builtin.target.cpu.arch.endian() != std.builtin.Endian.big) {
            std.mem.byteSwapAllFields(@TypeOf(legacy_header.counts), &legacy_header.counts);
        }

        if (legacy_header.version == 0) {
            return parseBlock(allocator, reader, legacy_header, true);
        } else {
            // If the format is modern, just skip over the legacy data
            const skipv = legacy_header.counts.timecnt * 5 + legacy_header.counts.typecnt * 6 + legacy_header.counts.charcnt + legacy_header.counts.leapcnt * 8 + legacy_header.counts.isstdcnt + legacy_header.counts.isutcnt;
            try reader.skipBytes(skipv, .{});

            var header = try reader.readStruct(Header);
            if (!std.mem.eql(u8, &header.magic, "TZif")) return error.BadHeader;
            if (header.version != '2' and header.version != '3') return error.BadVersion;
            if (builtin.target.cpu.arch.endian() != std.builtin.Endian.big) {
                std.mem.byteSwapAllFields(@TypeOf(header.counts), &header.counts);
            }

            return parseBlock(allocator, reader, header, false);
        }
    }

    fn parseBlock(allocator: std.mem.Allocator, reader: anytype, header: Header, legacy: bool) !TimeZone {
        if (header.counts.isstdcnt != 0 and header.counts.isstdcnt != header.counts.typecnt) return error.Malformed; // rfc8536: isstdcnt [...] MUST either be zero or equal to "typecnt"
        if (header.counts.isutcnt != 0 and header.counts.isutcnt != header.counts.typecnt) return error.Malformed; // rfc8536: isutcnt [...] MUST either be zero or equal to "typecnt"
        if (header.counts.typecnt == 0) return error.Malformed; // rfc8536: typecnt [...] MUST NOT be zero
        if (header.counts.charcnt == 0) return error.Malformed; // rfc8536: charcnt [...] MUST NOT be zero
        if (header.counts.charcnt > 256 + 6) return error.Malformed; // Not explicitly banned by rfc8536 but nonsensical

        var leapseconds = try allocator.alloc(Leapsecond, header.counts.leapcnt);
        errdefer allocator.free(leapseconds);
        var transitions = try allocator.alloc(Transition, header.counts.timecnt);
        errdefer allocator.free(transitions);
        var timetypes = try allocator.alloc(Timetype, header.counts.typecnt);
        errdefer allocator.free(timetypes);

        // Parse transition types
        var i: usize = 0;
        while (i < header.counts.timecnt) : (i += 1) {
            transitions[i].ts = if (legacy) try reader.readInt(i32, .big) else try reader.readInt(i64, .big);
        }

        i = 0;
        while (i < header.counts.timecnt) : (i += 1) {
            const tt = try reader.readByte();
            if (tt >= timetypes.len) return error.Malformed; // rfc8536: Each type index MUST be in the range [0, "typecnt" - 1]
            transitions[i].timetype = &timetypes[tt];
        }

        // Parse time types
        i = 0;
        while (i < header.counts.typecnt) : (i += 1) {
            const offset = try reader.readInt(i32, .big);
            if (offset < -2147483648) return error.Malformed; // rfc8536: utoff [...] MUST NOT be -2**31
            const dst = try reader.readByte();
            if (dst != 0 and dst != 1) return error.Malformed; // rfc8536: (is)dst [...] The value MUST be 0 or 1.
            const idx = try reader.readByte();
            if (idx > header.counts.charcnt - 1) return error.Malformed; // rfc8536: (desig)idx [...] Each index MUST be in the range [0, "charcnt" - 1]
            timetypes[i] = .{
                .offset = offset,
                .flags = dst,
                .name_data = undefined,
            };

            // Temporarily cache idx in name_data to be processed after we've read the designator names below
            timetypes[i].name_data[0] = idx;
        }

        var designators_data: [256 + 6]u8 = undefined;
        try reader.readNoEof(designators_data[0..header.counts.charcnt]);
        const designators = designators_data[0..header.counts.charcnt];
        if (designators[designators.len - 1] != 0) return error.Malformed; // rfc8536: charcnt [...] includes the trailing NUL (0x00) octet

        // Iterate through the timetypes again, setting the designator names
        for (timetypes) |*tt| {
            const name = std.mem.sliceTo(designators[tt.name_data[0]..], 0);
            // We are mandating the "SHOULD" 6-character limit so we can pack the struct better, and to conform to POSIX.
            if (name.len > 6) return error.Malformed; // rfc8536: Time zone designations SHOULD consist of at least three (3) and no more than six (6) ASCII characters.
            @memcpy(tt.name_data[0..name.len], name);
            tt.name_data[name.len] = 0;
        }

        // Parse leap seconds
        i = 0;
        while (i < header.counts.leapcnt) : (i += 1) {
            const occur: i64 = if (legacy) try reader.readInt(i32, .big) else try reader.readInt(i64, .big);
            if (occur < 0) return error.Malformed; // rfc8536: occur [...] MUST be nonnegative
            if (i > 0 and leapseconds[i - 1].occurrence + 2419199 > occur) return error.Malformed; // rfc8536: occur [...] each later value MUST be at least 2419199 greater than the previous value
            if (occur > std.math.maxInt(i48)) return error.Malformed; // Unreasonably far into the future

            const corr = try reader.readInt(i32, .big);
            if (i == 0 and corr != -1 and corr != 1) return error.Malformed; // rfc8536: The correction value in the first leap-second record, if present, MUST be either one (1) or minus one (-1)
            if (i > 0 and leapseconds[i - 1].correction != corr + 1 and leapseconds[i - 1].correction != corr - 1) return error.Malformed; // rfc8536: The correction values in adjacent leap-second records MUST differ by exactly one (1)
            if (corr > std.math.maxInt(i16)) return error.Malformed; // Unreasonably large correction

            leapseconds[i] = .{
                .occurrence = @as(i48, @intCast(occur)),
                .correction = @as(i16, @intCast(corr)),
            };
        }

        // Parse standard/wall indicators
        i = 0;
        while (i < header.counts.isstdcnt) : (i += 1) {
            const stdtime = try reader.readByte();
            if (stdtime == 1) {
                timetypes[i].flags |= 0x02;
            }
        }

        // Parse UT/local indicators
        i = 0;
        while (i < header.counts.isutcnt) : (i += 1) {
            const ut = try reader.readByte();
            if (ut == 1) {
                timetypes[i].flags |= 0x04;
                if (!timetypes[i].standardTimeIndicator()) return error.Malformed; // rfc8536: standard/wall value MUST be one (1) if the UT/local value is one (1)
            }
        }

        // Footer
        var footer: ?[]const u8 = null;
        var posix: ?Posix = null;
        if (!legacy) {
            if ((try reader.readByte()) != '\n') return error.Malformed; // An rfc8536 footer must start with a newline
            var footerdata_buf: [128]u8 = undefined;
            const footer_mem = reader.readUntilDelimiter(&footerdata_buf, '\n') catch |err| switch (err) {
                error.StreamTooLong => return error.OverlargeFooter, // Read more than 128 bytes, much larger than any reasonable POSIX TZ string
                else => return err,
            };
            if (footer_mem.len != 0) {
                footer = try allocator.dupe(u8, footer_mem);
                posix = try Posix.parse(footer.?);
            }
        }
        errdefer if (footer) |ft| allocator.free(ft);

        return TimeZone{
            .allocator = allocator,
            .transitions = transitions,
            .timetypes = timetypes,
            .leapseconds = leapseconds,
            .footer = footer,
            .posix_tz = posix,
            .fixed = null,
        };
    }

    pub fn deinit(self: TimeZone) void {
        // fixed timezones have no allocator
        if (self.fixed) |_| return;
        if (self.footer) |footer| {
            self.allocator.free(footer);
        }
        self.allocator.free(self.leapseconds);
        self.allocator.free(self.transitions);
        self.allocator.free(self.timetypes);
    }

    /// adjust a unix timestamp to the timezone
    pub fn adjust(self: TimeZone, ts: i64) AdjustedTime {
        // return early for fixed timezones
        if (self.fixed) |tz| {
            return .{
                .designation = tz.name,
                .timestamp = ts + tz.offset,
                .is_dst = tz.is_dst,
            };
        }

        // if we are past the last transition and have a footer, we use the
        // footer data
        if (self.transitions[self.transitions.len - 1].ts <= ts and
            self.posix_tz != null)
        {
            const posix = self.posix_tz.?;
            if (posix.dst) |dst| {
                return .{
                    .designation = dst,
                    .timestamp = ts - (posix.dst_offset orelse posix.std_offset - s_per_hour),
                    .is_dst = true,
                };
            } else {
                return .{
                    .designation = posix.std,
                    .timestamp = ts - posix.std_offset,
                    .is_dst = false,
                };
            }
        }

        const transition: Transition = blk: for (self.transitions, 0..) |transition, i| {
            // TODO: implement what go does, which is a copy of c for how to
            // handle times before the first transition how to handle this
            if (i == 0 and transition.ts > ts) @panic("unimplemented. please complain to tim");
            if (transition.ts <= ts) continue;
            // we use the latest transition before ts, which is one less than
            // our current iter
            break :blk self.transitions[i - 1];
        } else self.transitions[self.transitions.len - 1];
        return .{
            .designation = transition.timetype.name(),
            .timestamp = ts + transition.timetype.offset,
            .is_dst = transition.timetype.isDst(),
        };
    }
};

/// A parsed representation of a Posix TZ string
/// std offset dst [offset],start[/time],end[/time]
/// std and dst can be quoted with <>
/// offsets and times can be [+-]hh[:mm[:ss]]
/// start and end are of the form J<n>, <n> or M<m>.<w>.<d>
const Posix = struct {
    /// abbreviation for standard time
    std: []const u8,
    /// standard time offset in seconds
    std_offset: i64,
    /// abbreviation for daylight saving time
    dst: ?[]const u8 = null,
    /// offset when in dst, defaults to one hour less than std_offset if not present
    dst_offset: ?i64 = null,

    start: ?DSTSpec = null,
    end: ?DSTSpec = null,

    const DSTSpec = union(enum) {
        /// J<n>: julian day between 1 and 365, Leap day is never counted even in leap
        /// years
        julian: struct {
            day: u9,
            time: i64 = 7200,
        },
        /// <n>: julian day between 0 and 365. Leap day counts
        julian_leap: struct {
            day: u9,
            time: i64 = 7200,
        },
        /// M<m>.<w>.<d>: day d of week w of month m. Day is 0 (sunday) to 6. week
        /// is 1 to 5, where 5 would mean last d day of the month.
        mwd: struct {
            month: Month,
            week: u6,
            day: Weekday,
            time: i64 = 7200,
        },

        fn parse(str: []const u8) !DSTSpec {
            assert(str.len > 0);
            switch (str[0]) {
                'J' => {
                    const julian = try std.fmt.parseInt(u9, str[1..], 10);
                    return .{ .julian = .{ .day = julian } };
                },
                '0', '1', '2', '3', '4', '5', '6', '7', '8', '9' => |_| {
                    const julian = try std.fmt.parseInt(u9, str, 10);
                    return .{ .julian_leap = .{ .day = julian } };
                },
                'M' => {
                    var i: usize = 1;
                    const m_end = std.mem.indexOfScalarPos(u8, str, i, '.') orelse return error.InvalidPosix;
                    const month = try std.fmt.parseInt(u4, str[i..m_end], 10);
                    i = m_end + 1;
                    const w_end = std.mem.indexOfScalarPos(u8, str, i, '.') orelse return error.InvalidPosix;
                    const week = try std.fmt.parseInt(u6, str[i..w_end], 10);
                    i = w_end + 1;
                    const day = try std.fmt.parseInt(u3, str[i..], 10);
                    return .{
                        .mwd = .{
                            .month = @enumFromInt(month),
                            .week = week,
                            .day = @enumFromInt(day),
                        },
                    };
                },
                else => {},
            }
            return error.InvalidPosix;
        }

        test "DSTSpec.parse" {
            {
                const spec = try DSTSpec.parse("J365");
                try std.testing.expectEqual(365, spec.julian.day);
            }
            {
                const spec = try DSTSpec.parse("365");
                try std.testing.expectEqual(365, spec.julian_leap.day);
            }
            {
                const spec = try DSTSpec.parse("M3.5.1");
                try std.testing.expectEqual(.mar, spec.mwd.month);
                try std.testing.expectEqual(5, spec.mwd.week);
                try std.testing.expectEqual(.mon, spec.mwd.day);
            }
            {
                const spec = try DSTSpec.parse("M11.3.0");
                try std.testing.expectEqual(.nov, spec.mwd.month);
                try std.testing.expectEqual(3, spec.mwd.week);
                try std.testing.expectEqual(.sun, spec.mwd.day);
            }
        }
    };

    pub fn parse(str: []const u8) !Posix {
        var std_: []const u8 = "";
        var std_offset: i64 = 0;
        var dst: ?[]const u8 = null;
        var dst_offset: ?i64 = null;
        var start: ?DSTSpec = null;
        var end: ?DSTSpec = null;

        const State = enum {
            std,
            std_offset,
            dst,
            dst_offset,
            start,
            end,
        };

        var state: State = .std;
        var i: usize = 0;
        while (i < str.len) : (i += 1) {
            switch (state) {
                .std => {
                    switch (str[i]) {
                        '<' => {
                            // quoted. Consume until >
                            const end_qt = std.mem.indexOfScalar(u8, str[i..], '>') orelse return error.InvalidPosix;
                            std_ = str[i + 1 .. end_qt + i];
                            i = end_qt;
                            state = .std_offset;
                        },
                        else => {
                            i = std.mem.indexOfAnyPos(u8, str, i, "+-0123456789") orelse return error.InvalidPosix;
                            std_ = str[0..i];
                            // backup one so this gets parsed as an offset
                            i -= 1;
                            state = .std_offset;
                        },
                    }
                },
                .std_offset => {
                    const offset_start = i;
                    while (i < str.len) : (i += 1) {
                        switch (str[i]) {
                            '+',
                            '-',
                            ':',
                            '0',
                            '1',
                            '2',
                            '3',
                            '4',
                            '5',
                            '6',
                            '7',
                            '8',
                            '9',
                            => {
                                if (i == str.len - 1)
                                    std_offset = parseTime(str[offset_start..]);
                            },
                            else => {
                                std_offset = parseTime(str[offset_start..i]);
                                i -= 1;
                                state = .dst;
                                break;
                            },
                        }
                    }
                },
                .dst => {
                    switch (str[i]) {
                        '<' => {
                            // quoted. Consume until >
                            const dst_start = i + 1;
                            i = std.mem.indexOfScalarPos(u8, str, i, '>') orelse return error.InvalidPosix;
                            dst = str[dst_start..i];
                        },
                        else => {
                            const dst_start = i;
                            i += 1;
                            while (i < str.len) : (i += 1) {
                                switch (str[i]) {
                                    ',' => {
                                        dst = str[dst_start..i];
                                        state = .start;
                                        break;
                                    },
                                    '+', '-', '0', '1', '2', '3', '4', '5', '6', '7', '8', '9' => {
                                        dst = str[dst_start..i];
                                        // backup one so this gets parsed as an offset
                                        i -= 1;
                                        state = .dst_offset;
                                        break;
                                    },
                                    else => {
                                        if (i == str.len - 1)
                                            dst = str[dst_start..];
                                    },
                                }
                            }
                        },
                    }
                },
                .dst_offset => {
                    const offset_start = i;
                    while (i < str.len) : (i += 1) {
                        switch (str[i]) {
                            '+',
                            '-',
                            ':',
                            '0',
                            '1',
                            '2',
                            '3',
                            '4',
                            '5',
                            '6',
                            '7',
                            '8',
                            '9',
                            => {
                                if (i == str.len - 1)
                                    std_offset = parseTime(str[offset_start..]);
                            },
                            ',' => {
                                dst_offset = parseTime(str[offset_start..i]);
                                state = .start;
                                break;
                            },
                            else => {},
                        }
                    }
                },
                .start => {
                    const comma_idx = std.mem.indexOfScalarPos(u8, str, i, ',') orelse return error.InvalidPosix;
                    if (std.mem.indexOfScalarPos(u8, str[0..comma_idx], i, '/')) |idx| {
                        start = try DSTSpec.parse(str[i..idx]);
                        switch (start.?) {
                            .julian => |*j| j.time = parseTime(str[idx + 1 .. comma_idx]),
                            .julian_leap => |*j| j.time = parseTime(str[idx + 1 .. comma_idx]),
                            .mwd => |*m| m.time = parseTime(str[idx + 1 .. comma_idx]),
                        }
                    } else {
                        start = try DSTSpec.parse(str[i..comma_idx]);
                    }
                    state = .end;
                    i = comma_idx;
                },
                .end => {
                    if (std.mem.indexOfScalarPos(u8, str, i, '/')) |idx| {
                        end = try DSTSpec.parse(str[i..idx]);
                        switch (end.?) {
                            .julian => |*j| j.time = parseTime(str[idx + 1 ..]),
                            .julian_leap => |*j| j.time = parseTime(str[idx + 1 ..]),
                            .mwd => |*m| m.time = parseTime(str[idx + 1 ..]),
                        }
                    } else {
                        end = try DSTSpec.parse(str[i..]);
                    }
                    break;
                },
            }
        }
        return .{
            .std = std_,
            .std_offset = std_offset,
            .dst = dst,
            .dst_offset = dst_offset,
            .start = start,
            .end = end,
        };
    }

    fn parseTime(str: []const u8) i64 {
        const State = enum {
            hour,
            minute,
            second,
        };
        var is_neg = false;
        var state: State = .hour;
        var offset_h: i64 = 0;
        var offset_m: i64 = 0;
        var offset_s: i64 = 0;
        var i: usize = 0;
        while (i < str.len) : (i += 1) {
            switch (state) {
                .hour => {
                    switch (str[i]) {
                        '-' => is_neg = true,
                        '0', '1', '2', '3', '4', '5', '6', '7', '8', '9' => |d| {
                            offset_h = offset_h * 10 + @as(i64, d - '0');
                        },
                        ':' => state = .minute,
                        else => {},
                    }
                },
                .minute => {
                    switch (str[i]) {
                        '0', '1', '2', '3', '4', '5', '6', '7', '8', '9' => |d| {
                            offset_m = offset_m * 10 + @as(i64, d - '0');
                        },
                        ':' => state = .second,
                        else => {},
                    }
                },
                .second => {
                    switch (str[i]) {
                        '0', '1', '2', '3', '4', '5', '6', '7', '8', '9' => |d| {
                            offset_s = offset_s * 10 + @as(i64, d - '0');
                        },
                        else => {},
                    }
                },
            }
        }
        const offset = offset_h * s_per_hour + offset_m * s_per_min + offset_s;
        return if (is_neg) -offset else offset;
    }

    /// reports true if the unix timestamp occurs when DST is in effect
    fn isDST(self: Posix, timestamp: i64) bool {
        const start = self.start orelse return false;
        const end = self.end orelse return false;
        const days_from_epoch = @divFloor(timestamp, s_per_day);
        const civil = civilFromDays(days_from_epoch);
        const civil_month = @intFromEnum(civil.month);

        const start_s: i64 = switch (start) {
            .julian => |rule| blk: {
                const days = days_from_epoch - civil.month.daysBefore(civil.year) - civil.day + rule.day + 1;
                var s = (@as(i64, days - 1)) * s_per_day + rule.time;
                if (isLeapYear(civil.year) and rule.day >= 60) {
                    s += s_per_day;
                }
                break :blk s + self.std_offset;
            },
            .julian_leap => |rule| blk: {
                const days = days_from_epoch - civil.month.daysBefore(civil.year) - civil.day + rule.day;
                break :blk @as(i64, days) * s_per_day + rule.time + self.std_offset;
            },
            .mwd => |rule| blk: {
                const rule_month = @intFromEnum(rule.month);
                if (civil_month < rule_month) return false;
                // bail early if we are greater than this month. we know we only
                // rely on the end time. We yield a value that is before the
                // timestamp
                if (civil_month > rule_month) break :blk timestamp - 1;
                // we are in the same month
                // first_of_month is the weekday on the first of the month
                const first_of_month = weekdayFromDays(days_from_epoch - civil.day + 1);
                // days is the first "rule day" of the month (ie the first
                // Sunday of the month)
                var days: u9 = first_of_month.daysUntil(rule.day);
                var i: usize = 1;
                while (i < rule.week) : (i += 1) {
                    if (days + 7 >= rule.month.lastDay(civil.year)) break;
                    days += 7;
                }
                // days_from_epoch is the number of days to the DST day from the
                // epoch
                const dst_days_from_epoch: i64 = days_from_epoch - civil.day + days;

                break :blk @as(i64, dst_days_from_epoch) * s_per_day + rule.time + self.std_offset;
            },
        };

        const end_s: i64 = switch (end) {
            .julian => |rule| blk: {
                const days = days_from_epoch - civil.month.daysBefore(civil.year) - civil.day + rule.day + 1;
                var s = (@as(i64, days) - 1) * s_per_day + rule.time;
                if (isLeapYear(civil.year) and rule.day >= 60) {
                    s += s_per_day;
                }
                break :blk s + self.std_offset;
            },
            .julian_leap => |rule| blk: {
                const days = days_from_epoch - civil.month.daysBefore(civil.year) - civil.day + rule.day + 1;
                break :blk @as(i64, days) * s_per_day + rule.time + self.std_offset;
            },
            .mwd => |rule| blk: {
                const rule_month = @intFromEnum(rule.month);
                if (civil_month > rule_month) return false;
                // bail early if we are less than this month. we know we only
                // rely on the start time. We yield a value that is after the
                // timestamp
                if (civil_month < rule_month) break :blk timestamp + 1;
                // first_of_month is the weekday on the first of the month
                const first_of_month = weekdayFromDays(days_from_epoch - civil.day + 1);
                // days is the first "rule day" of the month (ie the first
                // Sunday of the month)
                var days: u9 = first_of_month.daysUntil(rule.day);
                var i: usize = 1;
                while (i < rule.week) : (i += 1) {
                    if (days + 7 >= rule.month.lastDay(civil.year)) break;
                    days += 7;
                }
                // days_from_epoch is the number of days to the DST day from the
                // epoch
                const dst_days_from_epoch: i64 = days_from_epoch - civil.day + days;

                break :blk @as(i64, dst_days_from_epoch) * s_per_day + rule.time + self.std_offset;
            },
        };

        return timestamp >= start_s and timestamp < end_s;
    }

    test "Posix.isDST" {
        const t = try parse("CST6CDT,M3.2.0,M11.1.0");
        try std.testing.expectEqual(false, t.isDST(1704088800)); // Jan 1 2024 00:00:00 CST
        try std.testing.expectEqual(false, t.isDST(1733032800)); // Dec 1 2024 00:00:00 CST
        try std.testing.expectEqual(true, t.isDST(1717218000)); // Jun 1 2024 00:00:00 CST
        // One second after DST starts
        try std.testing.expectEqual(true, t.isDST(1710057601));
        // One second before DST starts
        try std.testing.expectEqual(false, t.isDST(1710057599));
        // One second before DST ends
        try std.testing.expectEqual(true, t.isDST(1730620799));
        // One second after DST ends
        try std.testing.expectEqual(false, t.isDST(1730620801));

        const j = try parse("CST6CDT,J1,J4");
        try std.testing.expectEqual(true, j.isDST(1704268800));
    }

    test "Posix.parseTime" {
        try std.testing.expectEqual(0, parseTime("00:00:00"));
        try std.testing.expectEqual(-3600, parseTime("-1"));
        try std.testing.expectEqual(-7200, parseTime("-02:00:00"));
        try std.testing.expectEqual(3660, parseTime("+1:01"));
    }

    test "Posix.parse" {
        {
            const t = try parse("<UTC>-1");
            try std.testing.expectEqualStrings("UTC", t.std);
            try std.testing.expectEqual(-3600, t.std_offset);
        }
        {
            const t = try parse("<UTC>1");
            try std.testing.expectEqualStrings("UTC", t.std);
            try std.testing.expectEqual(3600, t.std_offset);
        }
        {
            const t = try parse("<UTC>+1");
            try std.testing.expectEqualStrings("UTC", t.std);
            try std.testing.expectEqual(3600, t.std_offset);
        }
        {
            const t = try parse("UTC+1");
            try std.testing.expectEqualStrings("UTC", t.std);
            try std.testing.expectEqual(3600, t.std_offset);
        }
        {
            const t = try parse("UTC+1:01");
            try std.testing.expectEqualStrings("UTC", t.std);
            try std.testing.expectEqual(3660, t.std_offset);
        }
        {
            const t = try parse("UTC-1:01:01");
            try std.testing.expectEqualStrings("UTC", t.std);
            try std.testing.expectEqual(-3661, t.std_offset);
        }
        {
            const t = try parse("CST1CDT");
            try std.testing.expectEqualStrings("CST", t.std);
            try std.testing.expectEqual(3600, t.std_offset);
            try std.testing.expectEqualStrings("CDT", t.dst.?);
        }
        {
            const t = try parse("CST1<CDT>");
            try std.testing.expectEqualStrings("CST", t.std);
            try std.testing.expectEqual(3600, t.std_offset);
            try std.testing.expectEqualStrings("CDT", t.dst.?);
        }
        {
            const t = try parse("CST1CDT,J100,J200");
            try std.testing.expectEqualStrings("CST", t.std);
            try std.testing.expectEqual(3600, t.std_offset);
            try std.testing.expectEqualStrings("CDT", t.dst.?);
            try std.testing.expectEqual(100, t.start.?.julian.day);
            try std.testing.expectEqual(200, t.end.?.julian.day);
        }
        {
            const t = try parse("CST1CDT,100,200");
            try std.testing.expectEqualStrings("CST", t.std);
            try std.testing.expectEqual(3600, t.std_offset);
            try std.testing.expectEqualStrings("CDT", t.dst.?);
            try std.testing.expectEqual(100, t.start.?.julian_leap.day);
            try std.testing.expectEqual(200, t.end.?.julian_leap.day);
        }
        {
            const t = try parse("CST1CDT,M3.5.1,M11.3.0");
            try std.testing.expectEqualStrings("CST", t.std);
            try std.testing.expectEqual(3600, t.std_offset);
            try std.testing.expectEqualStrings("CDT", t.dst.?);
            try std.testing.expectEqual(.mar, t.start.?.mwd.month);
            try std.testing.expectEqual(5, t.start.?.mwd.week);
            try std.testing.expectEqual(.mon, t.start.?.mwd.day);
            try std.testing.expectEqual(.nov, t.end.?.mwd.month);
            try std.testing.expectEqual(3, t.end.?.mwd.week);
            try std.testing.expectEqual(.sun, t.end.?.mwd.day);
        }
        {
            const t = try parse("CST1CDT,M3.5.1/02:00:00,M11.3.0/1");
            try std.testing.expectEqualStrings("CST", t.std);
            try std.testing.expectEqual(3600, t.std_offset);
            try std.testing.expectEqualStrings("CDT", t.dst.?);
            try std.testing.expectEqual(.mar, t.start.?.mwd.month);
            try std.testing.expectEqual(5, t.start.?.mwd.week);
            try std.testing.expectEqual(.mon, t.start.?.mwd.day);
            try std.testing.expectEqual(7200, t.start.?.mwd.time);
            try std.testing.expectEqual(.nov, t.end.?.mwd.month);
            try std.testing.expectEqual(3, t.end.?.mwd.week);
            try std.testing.expectEqual(.sun, t.end.?.mwd.day);
            try std.testing.expectEqual(3600, t.end.?.mwd.time);
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
}
