const std = @import("std");
const Reader = std.Io.Reader;
const builtin = @import("builtin");
const zeit = @import("zeit.zig");

const assert = std.debug.assert;

const Month = zeit.Month;
const Seconds = zeit.Seconds;
const Weekday = zeit.Weekday;

const s_per_min = std.time.s_per_min;
const s_per_hour = std.time.s_per_hour;
const s_per_day = std.time.s_per_day;

pub const TimeZone = union(enum) {
    fixed: Fixed,
    posix: Posix,
    tzinfo: TZInfo,
    windows: switch (builtin.os.tag) {
        .windows => Windows,
        else => Noop,
    },

    pub fn adjust(self: TimeZone, timestamp: Seconds) AdjustedTime {
        return switch (self) {
            inline else => |tz| tz.adjust(timestamp),
        };
    }

    pub fn deinit(self: TimeZone) void {
        return switch (self) {
            .fixed => {},
            .posix => {},
            .tzinfo => |tz| tz.deinit(),
            .windows => |tz| tz.deinit(),
        };
    }
};

pub const AdjustedTime = struct {
    designation: []const u8,
    timestamp: Seconds,
    is_dst: bool,
};

/// A Noop timezone we use for the windows struct when not on windows
pub const Noop = struct {
    pub fn adjust(_: Noop, timestamp: Seconds) AdjustedTime {
        return .{
            .designation = "noop",
            .timestamp = timestamp,
            .is_dst = false,
        };
    }

    pub fn deinit(_: Noop) void {}
};

/// A fixed timezone
pub const Fixed = struct {
    name: []const u8,
    offset: Seconds,
    is_dst: bool,

    pub fn adjust(self: Fixed, timestamp: Seconds) AdjustedTime {
        return .{
            .designation = self.name,
            .timestamp = timestamp + self.offset,
            .is_dst = self.is_dst,
        };
    }
};

/// A parsed representation of a Posix TZ string
/// std offset dst [offset],start[/time],end[/time]
/// std and dst can be quoted with <>
/// offsets and times can be [+-]hh[:mm[:ss]]
/// start and end are of the form J<n>, <n> or M<m>.<w>.<d>
pub const Posix = struct {
    /// abbreviation for standard time
    std: []const u8,
    /// standard time offset in seconds
    std_offset: Seconds,
    /// abbreviation for daylight saving time
    dst: ?[]const u8 = null,
    /// offset when in dst, defaults to one hour less than std_offset if not present
    dst_offset: ?Seconds = null,

    start: ?DSTSpec = null,
    end: ?DSTSpec = null,

    const DSTSpec = union(enum) {
        /// J<n>: julian day between 1 and 365, Leap day is never counted even in leap
        /// years
        julian: struct {
            day: u9,
            time: Seconds = 7200,
        },
        /// <n>: julian day between 0 and 365. Leap day counts
        julian_leap: struct {
            day: u9,
            time: Seconds = 7200,
        },
        /// M<m>.<w>.<d>: day d of week w of month m. Day is 0 (sunday) to 6. week
        /// is 1 to 5, where 5 would mean last d day of the month.
        mwd: struct {
            month: Month,
            week: u6,
            day: Weekday,
            time: Seconds = 7200,
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
    };

    pub fn parse(str: []const u8) !Posix {
        var std_: []const u8 = "";
        var std_offset: Seconds = 0;
        var dst: ?[]const u8 = null;
        var dst_offset: ?Seconds = null;
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

    fn parseTime(str: []const u8) Seconds {
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
    fn isDST(self: Posix, timestamp: Seconds) bool {
        const start = self.start orelse return false;
        const end = self.end orelse return false;
        const days_from_epoch = @divFloor(timestamp, s_per_day);
        const civil = zeit.civilFromDays(days_from_epoch);
        const civil_month = @intFromEnum(civil.month);

        const start_s: Seconds = switch (start) {
            .julian => |rule| blk: {
                const days = days_from_epoch - civil.month.daysBefore(civil.year) - civil.day + rule.day + 1;
                var s = (@as(i64, days - 1)) * s_per_day + rule.time;
                if (zeit.isLeapYear(civil.year) and rule.day >= 60) {
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
                const first_of_month = zeit.weekdayFromDays(days_from_epoch - civil.day + 1);
                // days is the first "rule day" of the month (ie the first
                // Sunday of the month)
                var days: u9 = first_of_month.daysUntil(rule.day) + 1;
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

        const end_s: Seconds = switch (end) {
            .julian => |rule| blk: {
                const days = days_from_epoch - civil.month.daysBefore(civil.year) - civil.day + rule.day + 1;
                var s = (@as(i64, days) - 1) * s_per_day + rule.time;
                if (zeit.isLeapYear(civil.year) and rule.day >= 60) {
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
                const first_of_month = zeit.weekdayFromDays(days_from_epoch - civil.day + 1);
                // days is the first "rule day" of the month (ie the first
                // Sunday of the month)
                var days: u9 = first_of_month.daysUntil(rule.day) + 1;
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

    pub fn adjust(self: Posix, timestamp: Seconds) AdjustedTime {
        if (self.isDST(timestamp)) {
            return .{
                .designation = self.dst orelse self.std,
                .timestamp = timestamp - (self.dst_offset orelse self.std_offset - s_per_hour),
                .is_dst = true,
            };
        }
        return .{
            .designation = self.std,
            .timestamp = timestamp - self.std_offset,
            .is_dst = false,
        };
    }
};

pub const TZInfo = struct {
    allocator: std.mem.Allocator,
    transitions: []const Transition,
    timetypes: []const Timetype,
    leapseconds: []const Leapsecond,
    footer: ?[]const u8,
    posix_tz: ?Posix,

    const Leapsecond = struct {
        occurrence: i48,
        correction: i16,
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
        ts: Seconds,
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

    pub fn parse(allocator: std.mem.Allocator, reader: *Reader) !TZInfo {
        var legacy_header = try reader.takeStruct(Header, .big);
        if (!std.mem.eql(u8, &legacy_header.magic, "TZif")) return error.BadHeader;
        if (legacy_header.version != 0 and legacy_header.version != '2' and legacy_header.version != '3') return error.BadVersion;

        if (legacy_header.version == 0) {
            return parseBlock(allocator, reader, legacy_header, true);
        } else {
            // If the format is modern, just skip over the legacy data
            const skipv = legacy_header.counts.timecnt * 5 + legacy_header.counts.typecnt * 6 + legacy_header.counts.charcnt + legacy_header.counts.leapcnt * 8 + legacy_header.counts.isstdcnt + legacy_header.counts.isutcnt;
            try reader.discardAll(skipv);

            var header = try reader.takeStruct(Header, .big);
            if (!std.mem.eql(u8, &header.magic, "TZif")) return error.BadHeader;
            if (header.version != '2' and header.version != '3') return error.BadVersion;

            return parseBlock(allocator, reader, header, false);
        }
    }

    fn parseBlock(allocator: std.mem.Allocator, reader: *Reader, header: Header, legacy: bool) !TZInfo {
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
            transitions[i].ts = if (legacy) try reader.takeInt(i32, .big) else try reader.takeInt(i64, .big);
        }

        i = 0;
        while (i < header.counts.timecnt) : (i += 1) {
            const tt = try reader.takeByte();
            if (tt >= timetypes.len) return error.Malformed; // rfc8536: Each type index MUST be in the range [0, "typecnt" - 1]
            transitions[i].timetype = &timetypes[tt];
        }

        // Parse time types
        i = 0;
        while (i < header.counts.typecnt) : (i += 1) {
            const offset = try reader.takeInt(i32, .big);
            if (offset < -2147483648) return error.Malformed; // rfc8536: utoff [...] MUST NOT be -2**31
            const dst = try reader.takeByte();
            if (dst != 0 and dst != 1) return error.Malformed; // rfc8536: (is)dst [...] The value MUST be 0 or 1.
            const idx = try reader.takeByte();
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
        try reader.readSliceAll(designators_data[0..header.counts.charcnt]);
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
            const occur: i64 = if (legacy) try reader.takeInt(i32, .big) else try reader.takeInt(i64, .big);
            if (occur < 0) return error.Malformed; // rfc8536: occur [...] MUST be nonnegative
            if (i > 0 and leapseconds[i - 1].occurrence + 2419199 > occur) return error.Malformed; // rfc8536: occur [...] each later value MUST be at least 2419199 greater than the previous value
            if (occur > std.math.maxInt(i48)) return error.Malformed; // Unreasonably far into the future

            const corr = try reader.takeInt(i32, .big);
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
            const stdtime = try reader.takeByte();
            if (stdtime == 1) {
                timetypes[i].flags |= 0x02;
            }
        }

        // Parse UT/local indicators
        i = 0;
        while (i < header.counts.isutcnt) : (i += 1) {
            const ut = try reader.takeByte();
            if (ut == 1) {
                timetypes[i].flags |= 0x04;
                if (!timetypes[i].standardTimeIndicator()) return error.Malformed; // rfc8536: standard/wall value MUST be one (1) if the UT/local value is one (1)
            }
        }

        // Footer
        var footer: ?[]const u8 = null;
        var posix: ?Posix = null;
        if (!legacy) {
            if ((try reader.takeByte()) != '\n') return error.Malformed; // An rfc8536 footer must start with a newline

            std.debug.assert(reader.buffer.len >= 128);
            const footer_mem = reader.takeSentinel('\n') catch |err| switch (err) {
                error.StreamTooLong => return error.OverlargeFooter, // Read more than 128 bytes, much larger than any reasonable POSIX TZ string
                else => return err,
            };

            if (footer_mem.len != 0) {
                footer = try allocator.dupe(u8, footer_mem);
                posix = try Posix.parse(footer.?);
            }
        }
        errdefer if (footer) |ft| allocator.free(ft);

        return .{
            .allocator = allocator,
            .transitions = transitions,
            .timetypes = timetypes,
            .leapseconds = leapseconds,
            .footer = footer,
            .posix_tz = posix,
        };
    }

    pub fn deinit(self: TZInfo) void {
        if (self.footer) |footer| {
            self.allocator.free(footer);
        }
        self.allocator.free(self.leapseconds);
        self.allocator.free(self.transitions);
        self.allocator.free(self.timetypes);
    }

    /// adjust a unix timestamp to the timezone
    pub fn adjust(self: TZInfo, timestamp: Seconds) AdjustedTime {
        // if we are past the last transition and have a footer, we use the
        // footer data
        if ((self.transitions.len == 0 or self.transitions[self.transitions.len - 1].ts <= timestamp) and
            self.posix_tz != null)
        {
            const posix = self.posix_tz.?;
            return posix.adjust(timestamp);
        }

        const transition: Transition = blk: for (self.transitions, 0..) |transition, i| {
            // TODO: implement what go does, which is a copy of c for how to
            // handle times before the first transition how to handle this
            if (i == 0 and transition.ts > timestamp) @panic("unimplemented. please complain to tim");
            if (transition.ts <= timestamp) continue;
            // we use the latest transition before ts, which is one less than
            // our current iter
            break :blk self.transitions[i - 1];
        } else self.transitions[self.transitions.len - 1];
        return .{
            .designation = transition.timetype.name(),
            .timestamp = timestamp + transition.timetype.offset,
            .is_dst = transition.timetype.isDst(),
        };
    }
};

pub const Windows = struct {
    const windows = struct {
        const BOOL = std.os.windows.BOOL;
        const BOOLEAN = std.os.windows.BOOLEAN;
        const DWORD = std.os.windows.DWORD;
        const FILETIME = std.os.windows.FILETIME;
        const LONG = std.os.windows.LONG;
        const USHORT = std.os.windows.USHORT;
        const WCHAR = std.os.windows.WCHAR;
        const WORD = std.os.windows.WORD;

        const epoch = std.time.epoch.windows;
        const ERROR_SUCCESS = 0x00;
        const ERROR_NO_MORE_ITEMS = 0x103;
        pub const TIME_ZONE_ID_INVALID = @as(DWORD, std.math.maxInt(DWORD));

        const DYNAMIC_TIME_ZONE_INFORMATION = extern struct {
            Bias: LONG,
            StandardName: [32]WCHAR,
            StandardDate: SYSTEMTIME,
            StandardBias: LONG,
            DaylightName: [32]WCHAR,
            DaylightDate: SYSTEMTIME,
            DaylightBias: LONG,
            TimeZoneKeyName: [128]WCHAR,
            DynamicDaylightTimeDisabled: BOOLEAN,
        };

        const SYSTEMTIME = extern struct {
            wYear: WORD,
            wMonth: WORD,
            wDayOfWeek: WORD,
            wDay: WORD,
            wHour: WORD,
            wMinute: WORD,
            wSecond: WORD,
            wMilliseconds: WORD,
        };

        const TIME_ZONE_INFORMATION = extern struct {
            Bias: LONG,
            StandardName: [32]WCHAR,
            StandardDate: SYSTEMTIME,
            StandardBias: LONG,
            DaylightName: [32]WCHAR,
            DaylightDate: SYSTEMTIME,
            DaylightBias: LONG,
        };

        pub extern "advapi32" fn EnumDynamicTimeZoneInformation(dwIndex: DWORD, lpTimeZoneInformation: *DYNAMIC_TIME_ZONE_INFORMATION) callconv(.winapi) DWORD;
        pub extern "kernel32" fn GetDynamicTimeZoneInformation(pTimeZoneInformation: *DYNAMIC_TIME_ZONE_INFORMATION) callconv(.winapi) DWORD;
        pub extern "kernel32" fn GetTimeZoneInformationForYear(wYear: USHORT, pdtzi: ?*const DYNAMIC_TIME_ZONE_INFORMATION, ptzi: *TIME_ZONE_INFORMATION) callconv(.winapi) BOOL;
        pub extern "kernel32" fn SystemTimeToTzSpecificLocalTimeEx(lpTimeZoneInfo: ?*const DYNAMIC_TIME_ZONE_INFORMATION, lpUniversalTime: *const SYSTEMTIME, lpLocalTime: *SYSTEMTIME) callconv(.winapi) BOOL;
    };

    zoneinfo: windows.DYNAMIC_TIME_ZONE_INFORMATION,
    allocator: std.mem.Allocator,
    standard_name: []const u8,
    dst_name: []const u8,

    /// retrieves the local timezone settings for this machine
    pub fn local(allocator: std.mem.Allocator) !Windows {
        var info: windows.DYNAMIC_TIME_ZONE_INFORMATION = undefined;
        const result = windows.GetDynamicTimeZoneInformation(&info);
        if (result == windows.TIME_ZONE_ID_INVALID) return error.TimeZoneIdInvalid;
        const std_idx = std.mem.indexOfScalar(u16, &info.StandardName, 0x00) orelse info.StandardName.len;
        const dst_idx = std.mem.indexOfScalar(u16, &info.DaylightName, 0x00) orelse info.DaylightName.len;
        const standard_name = try std.unicode.utf16LeToUtf8Alloc(allocator, info.StandardName[0..std_idx]);
        const dst_name = try std.unicode.utf16LeToUtf8Alloc(allocator, info.DaylightName[0..dst_idx]);
        return .{
            .zoneinfo = info,
            .allocator = allocator,
            .standard_name = standard_name,
            .dst_name = dst_name,
        };
    }

    pub fn deinit(self: Windows) void {
        self.allocator.free(self.standard_name);
        self.allocator.free(self.dst_name);
    }

    /// Adjusts the time to the timezone
    /// 1. Convert timestamp to windows.SYSTEMTIME using internal methods
    /// 2. Convert SYSTEMTIME to target timezone using windows api
    /// 3. Get the relevant TIME_ZONE_INFORMATION for the year
    /// 4. Determine if we are in DST or not
    /// 5. Return result
    pub fn adjust(self: Windows, timestamp: Seconds) AdjustedTime {
        const instant = zeit.instant(.{ .source = .{ .unix_timestamp = timestamp } }) catch unreachable;
        const time = instant.time();

        const systemtime: windows.SYSTEMTIME = .{
            .wYear = @intCast(time.year),
            .wMonth = @intFromEnum(time.month),
            .wDayOfWeek = 0, // not used in calculation
            .wDay = time.day,
            .wHour = time.hour,
            .wMinute = time.minute,
            .wSecond = time.second,
            .wMilliseconds = time.millisecond,
        };

        var localtime: windows.SYSTEMTIME = undefined;
        if (windows.SystemTimeToTzSpecificLocalTimeEx(&self.zoneinfo, &systemtime, &localtime) == 0) {
            const err = std.os.windows.kernel32.GetLastError();
            std.log.err("{}", .{err});
            @panic("TODO");
        }
        var tzi: windows.TIME_ZONE_INFORMATION = undefined;
        if (windows.GetTimeZoneInformationForYear(localtime.wYear, &self.zoneinfo, &tzi) == 0) {
            const err = std.os.windows.kernel32.GetLastError();
            std.log.err("{}", .{err});
            @panic("TODO");
        }
        const is_dst = isDST(timestamp, &tzi, &localtime);
        return .{
            .designation = if (is_dst) self.dst_name else self.standard_name,
            .timestamp = systemtimeToUnixTimestamp(localtime),
            .is_dst = is_dst,
        };
    }

    fn systemtimeToUnixTimestamp(sys: windows.SYSTEMTIME) Seconds {
        const lzt = systemtimetoZeitTime(sys);
        return lzt.instant().unixTimestamp();
    }

    fn systemtimetoZeitTime(sys: windows.SYSTEMTIME) zeit.Time {
        return .{
            .year = sys.wYear,
            .month = @enumFromInt(sys.wMonth),
            .day = @intCast(sys.wDay),
            .hour = @intCast(sys.wHour),
            .minute = @intCast(sys.wMinute),
            .second = @intCast(sys.wSecond),
            .millisecond = @intCast(sys.wMilliseconds),
        };
    }

    fn isDST(timestamp: Seconds, tzi: *const windows.TIME_ZONE_INFORMATION, time: *const windows.SYSTEMTIME) bool {
        // If wMonth on StandardDate is 0, the timezone doesn't have DST
        if (tzi.StandardDate.wMonth == 0) return false;
        const start = tzi.DaylightDate;
        const end = tzi.StandardDate;

        // Before DST starts
        if (time.wMonth < start.wMonth) return false;
        // After DST ends
        if (time.wMonth > end.wMonth) return false;
        // In the months between
        if (time.wMonth > start.wMonth and time.wMonth < end.wMonth) return true;

        const days_from_epoch = @divFloor(timestamp, s_per_day);
        // first_of_month is the weekday on the first of the month
        const first_of_month = zeit.weekdayFromDays(days_from_epoch - time.wDay + 1);

        // In the start transition month
        if (time.wMonth == start.wMonth) {
            // days is the first "rule day" of the month (ie the first
            // Sunday of the month)
            var days: u9 = first_of_month.daysUntil(@enumFromInt(start.wDayOfWeek));
            var i: usize = 1;
            while (i < start.wDay) : (i += 1) {
                const month: zeit.Month = @enumFromInt(start.wDay);
                if (days + 7 >= month.lastDay(time.wYear)) break;
                days += 7;
            }
            if (time.wDay == days) {
                if (time.wHour == start.wHour) {
                    return time.wMinute >= start.wMinute;
                }
                return time.wHour >= start.wHour;
            }
            return time.wDay >= days;
        }
        // In the end transition month
        if (time.wMonth == end.wMonth) {
            // days is the first "rule day" of the month (ie the first
            // Sunday of the month)
            var days: u9 = first_of_month.daysUntil(@enumFromInt(end.wDayOfWeek));
            var i: usize = 1;
            while (i < end.wDay) : (i += 1) {
                const month: zeit.Month = @enumFromInt(end.wDay);
                if (days + 7 >= month.lastDay(time.wYear)) break;
                days += 7;
            }
            if (time.wDay == days) {
                if (time.wHour == end.wHour) {
                    return time.wMinute < end.wMinute;
                }
                return time.wHour < end.wHour;
            }
            return time.wDay < days;
        }
        return false;
    }

    pub fn loadFromName(allocator: std.mem.Allocator, name: []const u8) !Windows {
        var buf: [128]u16 = undefined;
        const n = try std.unicode.utf8ToUtf16Le(&buf, name);
        const target = buf[0..n];

        var result: windows.DWORD = windows.ERROR_SUCCESS;
        var i: windows.DWORD = 0;
        var dtzi: windows.DYNAMIC_TIME_ZONE_INFORMATION = undefined;
        while (result == windows.ERROR_SUCCESS) : (i += 1) {
            result = windows.EnumDynamicTimeZoneInformation(i, &dtzi);
            const name_idx = std.mem.indexOfScalar(u16, &dtzi.TimeZoneKeyName, 0x00) orelse dtzi.TimeZoneKeyName.len;
            if (std.mem.eql(u16, target, dtzi.TimeZoneKeyName[0..name_idx])) break;
        } else return error.TimezoneNotFound;

        const std_idx = std.mem.indexOfScalar(u16, &dtzi.StandardName, 0x00) orelse dtzi.StandardName.len;
        const dst_idx = std.mem.indexOfScalar(u16, &dtzi.DaylightName, 0x00) orelse dtzi.DaylightName.len;
        const standard_name = try std.unicode.utf16LeToUtf8Alloc(allocator, dtzi.StandardName[0..std_idx]);
        const dst_name = try std.unicode.utf16LeToUtf8Alloc(allocator, dtzi.DaylightName[0..dst_idx]);
        return .{
            .zoneinfo = dtzi,
            .allocator = allocator,
            .standard_name = standard_name,
            .dst_name = dst_name,
        };
    }
};

test "timezone.zig: test Fixed" {
    const fixed: Fixed = .{
        .name = "test",
        .offset = -600,
        .is_dst = false,
    };
    const adjusted = fixed.adjust(0);
    try std.testing.expectEqual(-600, adjusted.timestamp);
}

test "timezone.zig: Posix.isDST" {
    const t = try Posix.parse("CST6CDT,M3.2.0,M11.1.0");
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

    const j = try Posix.parse("CST6CDT,J1,J4");
    try std.testing.expectEqual(true, j.isDST(1704268800));
}

test "timezone.zig: Posix.parseTime" {
    try std.testing.expectEqual(0, Posix.parseTime("00:00:00"));
    try std.testing.expectEqual(-3600, Posix.parseTime("-1"));
    try std.testing.expectEqual(-7200, Posix.parseTime("-02:00:00"));
    try std.testing.expectEqual(3660, Posix.parseTime("+1:01"));
}

test "timezone.zig: Posix.parse" {
    {
        const t = try Posix.parse("<UTC>-1");
        try std.testing.expectEqualStrings("UTC", t.std);
        try std.testing.expectEqual(-3600, t.std_offset);
    }
    {
        const t = try Posix.parse("<UTC>1");
        try std.testing.expectEqualStrings("UTC", t.std);
        try std.testing.expectEqual(3600, t.std_offset);
    }
    {
        const t = try Posix.parse("<UTC>+1");
        try std.testing.expectEqualStrings("UTC", t.std);
        try std.testing.expectEqual(3600, t.std_offset);
    }
    {
        const t = try Posix.parse("UTC+1");
        try std.testing.expectEqualStrings("UTC", t.std);
        try std.testing.expectEqual(3600, t.std_offset);
    }
    {
        const t = try Posix.parse("UTC+1:01");
        try std.testing.expectEqualStrings("UTC", t.std);
        try std.testing.expectEqual(3660, t.std_offset);
    }
    {
        const t = try Posix.parse("UTC-1:01:01");
        try std.testing.expectEqualStrings("UTC", t.std);
        try std.testing.expectEqual(-3661, t.std_offset);
    }
    {
        const t = try Posix.parse("CST1CDT");
        try std.testing.expectEqualStrings("CST", t.std);
        try std.testing.expectEqual(3600, t.std_offset);
        try std.testing.expectEqualStrings("CDT", t.dst.?);
    }
    {
        const t = try Posix.parse("CST1<CDT>");
        try std.testing.expectEqualStrings("CST", t.std);
        try std.testing.expectEqual(3600, t.std_offset);
        try std.testing.expectEqualStrings("CDT", t.dst.?);
    }
    {
        const t = try Posix.parse("CST1CDT,J100,J200");
        try std.testing.expectEqualStrings("CST", t.std);
        try std.testing.expectEqual(3600, t.std_offset);
        try std.testing.expectEqualStrings("CDT", t.dst.?);
        try std.testing.expectEqual(100, t.start.?.julian.day);
        try std.testing.expectEqual(200, t.end.?.julian.day);
    }
    {
        const t = try Posix.parse("CST1CDT,100,200");
        try std.testing.expectEqualStrings("CST", t.std);
        try std.testing.expectEqual(3600, t.std_offset);
        try std.testing.expectEqualStrings("CDT", t.dst.?);
        try std.testing.expectEqual(100, t.start.?.julian_leap.day);
        try std.testing.expectEqual(200, t.end.?.julian_leap.day);
    }
    {
        const t = try Posix.parse("CST1CDT,M3.5.1,M11.3.0");
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
        const t = try Posix.parse("CST1CDT,M3.5.1/02:00:00,M11.3.0/1");
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

test "timezone.zig: Posix.adjust" {
    {
        const t = try Posix.parse("UTC+1");
        const adjusted = t.adjust(0);
        try std.testing.expectEqual(-3600, adjusted.timestamp);
    }

    {
        const t = try Posix.parse("CST6CDT,M3.2.0/2:00:00,M11.1.0/2:00:00");
        const adjusted = t.adjust(1704088800);
        try std.testing.expectEqual(1704067200, adjusted.timestamp);
        try std.testing.expectEqualStrings("CST", adjusted.designation);

        const adjusted_dst = t.adjust(1710057600);
        try std.testing.expectEqual(1710039600, adjusted_dst.timestamp);
        try std.testing.expectEqualStrings("CDT", adjusted_dst.designation);
    }
}

test "timezone.zig: Posix.DSTSpec.parse" {
    {
        const spec = try Posix.DSTSpec.parse("J365");
        try std.testing.expectEqual(365, spec.julian.day);
    }
    {
        const spec = try Posix.DSTSpec.parse("365");
        try std.testing.expectEqual(365, spec.julian_leap.day);
    }
    {
        const spec = try Posix.DSTSpec.parse("M3.5.1");
        try std.testing.expectEqual(.mar, spec.mwd.month);
        try std.testing.expectEqual(5, spec.mwd.week);
        try std.testing.expectEqual(.mon, spec.mwd.day);
    }
    {
        const spec = try Posix.DSTSpec.parse("M11.3.0");
        try std.testing.expectEqual(.nov, spec.mwd.month);
        try std.testing.expectEqual(3, spec.mwd.week);
        try std.testing.expectEqual(.sun, spec.mwd.day);
    }
}
