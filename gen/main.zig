//! Generates zig code for well-known timezones. Makes an enum of the "posix" style name
//! ("America/Chicago") and a function to return the timezone name as text. The name as text is
//! portable by platform: on Windows it will return the Windows name of this timezone
//!
//! Source data available at https://github.com/unicode-org/cldr/blob/main/common/supplemental/windowsZones.xml
const std = @import("std");

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const data = @embedFile("windowsZones.xml");

    var zones: std.ArrayList(MapZone) = .empty;

    var read_idx: usize = 0;
    while (read_idx < data.len) {
        const eol = std.mem.indexOfScalarPos(u8, data, read_idx, '\n') orelse data.len;
        defer read_idx = eol + 1;
        const input_line = data[read_idx..eol];
        const line = std.mem.trimRight(u8, std.mem.trim(u8, input_line, " \t<>"), "/");
        if (!std.mem.startsWith(u8, line, "mapZone")) continue;
        var idx: usize = 0;
        const windows = blk: {
            idx = std.mem.indexOfScalarPos(u8, line, idx, '"') orelse unreachable;
            const start = idx + 1;
            idx = std.mem.indexOfScalarPos(u8, line, start, '"') orelse unreachable;
            const end = idx;
            break :blk line[start..end];
        };
        const territory = blk: {
            idx = std.mem.indexOfScalarPos(u8, line, idx + 1, '"') orelse unreachable;
            const start = idx + 1;
            idx = std.mem.indexOfScalarPos(u8, line, start, '"') orelse unreachable;
            const end = idx;
            break :blk line[start..end];
        };
        const posix = blk: {
            idx = std.mem.indexOfScalarPos(u8, line, idx + 1, '"') orelse unreachable;
            const start = idx + 1;
            idx = std.mem.indexOfScalarPos(u8, line, start, '"') orelse unreachable;
            const end = idx;
            break :blk line[start..end];
        };

        var iter = std.mem.splitScalar(u8, posix, ' ');
        while (iter.next()) |psx| {
            const map_zone: MapZone = .{
                .windows = windows,
                .territory = territory,
                .posix = psx,
            };
            if (psx.len == 0) continue;
            for (zones.items) |item| {
                if (std.mem.eql(u8, item.windows, map_zone.windows) and
                    std.mem.eql(u8, item.posix, map_zone.posix)) break;
            } else try zones.append(allocator, map_zone);
        }
    }

    std.mem.sort(MapZone, zones.items, {}, lessThan);

    const out = try std.fs.cwd().createFile("src/location.zig", .{});
    defer out.close();

    var output_buffer: [2048]u8 = undefined;
    var writer = out.writer(&output_buffer);
    try writeFile(zones.items, &writer.interface);
}

fn lessThan(_: void, lhs: MapZone, rhs: MapZone) bool {
    return std.mem.order(u8, lhs.posix, rhs.posix).compare(.lt);
}

const MapZone = struct {
    windows: []const u8,
    territory: []const u8,
    posix: []const u8,
};

fn writeFile(items: []const MapZone, writer: *std.io.Writer) !void {
    try writer.writeAll(
        \\//!This file is generated. Do not edit directly! Run `zig build generate` to update after obtaining
        \\//!the latest dataset.
        \\
        \\const builtin = @import("builtin");
        \\pub const Location = enum {
        \\
    );
    for (items) |item| {
        try writer.print("@\"{s}\",\n", .{item.posix});
    }

    try writer.writeAll("\n");

    try writer.writeAll(
        \\        pub fn asText(self: Location) []const u8 {
        \\            switch (builtin.os.tag) {
        \\                .windows => {},
        \\                else => return @tagName(self),
        \\            }
    );

    try writer.writeAll("        return switch (self) {\n");
    for (items) |item| {
        try writer.print(".@\"{s}\" => \"{s}\",\n", .{ item.posix, item.windows });
    }
    try writer.writeAll("};}};");
    try writer.flush(); // don't forget to flush!
}
