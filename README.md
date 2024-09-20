# zeit

A time library written in zig.

## Usage

[API Documentation](https://rockorager.github.io/zeit/)

```zig
const std = @import("std");
const zeit = @import("zeit");

pub fn main() void {
    const allocator = std.heap.page_allocator;
    var env = try std.process.getEnvMap(allocator);
    defer env.deinit();

    // Get an instant in time. The default gets "now" in UTC
    const now = try zeit.instant(.{});

    // Load our local timezone. This needs an allocator. Optionally pass in a
    // *const std.process.EnvMap to support TZ and TZDIR environment variables
    const local = try zeit.local(alloc, &env);

    // Convert our instant to a new timezone
    const now_local = now.in(&local);

    // Generate date/time info for this instant
    const dt = now_local.time();

    // Print it out
    std.debug.print("{}", .{dt});

    // zeit.Time{
    //    .year = 2024,
    //    .month = zeit.Month.mar,
    //    .day = 16,
    //    .hour = 8,
    //    .minute = 38,
    //    .second = 29,
    //    .millisecond = 496,
    //    .microsecond = 706,
    //    .nanosecond = 64
    //    .offset = -18000,
    // }

    // Format using strftime specifier. Format strings are not required to be comptime
    try dt.strftime(anywriter, "%Y-%m-%d %H:%M:%S %Z");

    // Or...golang magic date specifiers. Format strings are not required to be comptime
    try dt.gofmt(anywriter, "2006-01-02 15:04:05 MST");

    // Load an arbitrary location using IANA location syntax. The location name
    // comes from an enum which will automatically map IANA location names to
    // Windows names, as needed. Pass an optional EnvMap to support TZDIR
    const vienna = try zeit.loadTimeZone(alloc, .@"Europe/Vienna", &env);
    defer vienna.deinit();

    // Parse an Instant from an ISO8601 or RFC3339 string
    const iso = try zeit.instant(.{
	.source = .{
	    .iso8601 = "2024-03-16T08:38:29.496-1200",
	},
    });

    const rfc3339 = try zeit.instant(.{
	.source = .{
	    .rfc3339 = "2024-03-16T08:38:29.496706064-1200",
	},
    });
}
```
