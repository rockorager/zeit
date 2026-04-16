# README Example Matches The Current API

The README had drifted behind the library's current Zig 0.16-style API.
The example still showed the older call shapes for `zeit.instant`,
`zeit.local`, and `zeit.loadTimeZone`, and it also referenced placeholders
that were not valid code in a standalone `main`.

This document brings the example back to runnable application code.
The first patch updates the top of the example so the program has a real
`std.Io` instance, uses the current function signatures, and cleans up the
loaded local timezone.

```diff id=6ab16617
diff --git a/README.md b/README.md
index 81982f4d7dea..03b3ff80db3b 100644
--- a/README.md
+++ b/README.md
@@ -17,17 +17,19 @@ Or install a [tag](https://github.com/rockorager/zeit/tags) instead of main.
 const std = @import("std");
 const zeit = @import("zeit");
 
-pub fn main() void {
+pub fn main() !void {
     const allocator = std.heap.page_allocator;
-    var env = try std.process.getEnvMap(allocator);
-    defer env.deinit();
+    var threaded = std.Io.Threaded.init(allocator, .{});
+    defer threaded.deinit();
+    const io = threaded.io();
 
     // Get an instant in time. The default gets "now" in UTC
-    const now = try zeit.instant(.{});
+    const now = try zeit.instant(io, .{});
 
     // Load our local timezone. This needs an allocator. Optionally pass in a
-    // *const std.process.EnvMap to support TZ and TZDIR environment variables
-    const local = try zeit.local(alloc, &env);
+    // zeit.EnvConfig to support TZ and TZDIR environment variables
+    const local = try zeit.local(allocator, io, .{});
+    defer local.deinit();
 
     // Convert our instant to a new timezone
     const now_local = now.in(&local);
```

The second patch fixes the rest of the example so it no longer relies on the
undefined `anywriter` placeholder, uses the updated timezone-loading call, and
passes the `io` handle through the parse examples as well.

```diff id=6f4db086 depends-on=6ab16617
diff --git a/README.md b/README.md
index 81982f4d7dea..03b3ff80db3b 100644
--- a/README.md
+++ b/README.md
@@ -51,29 +53,36 @@ pub fn main() void {
     //    .offset = -18000,
     // }
 
+    var buf: [256]u8 = undefined;
+    var writer = std.Io.Writer.fixed(&buf);
+
     // Format using strftime specifier. Format strings are not required to be comptime
-    try dt.strftime(anywriter, "%Y-%m-%d %H:%M:%S %Z");
+    try dt.strftime(&writer, "%Y-%m-%d %H:%M:%S %Z");
+    std.debug.print("{s}\n", .{writer.buffered()});
+
+    writer.end = 0;
 
     // Or...golang magic date specifiers. Format strings are not required to be comptime
-    try dt.gofmt(anywriter, "2006-01-02 15:04:05 MST");
+    try dt.gofmt(&writer, "2006-01-02 15:04:05 MST");
+    std.debug.print("{s}\n", .{writer.buffered()});
 
     // Load an arbitrary location using IANA location syntax. The location name
     // comes from an enum which will automatically map IANA location names to
-    // Windows names, as needed. Pass an optional EnvMap to support TZDIR
-    const vienna = try zeit.loadTimeZone(alloc, .@"Europe/Vienna", &env);
+    // Windows names, as needed. Pass an optional EnvConfig to support TZDIR
+    const vienna = try zeit.loadTimeZone(allocator, io, .@"Europe/Vienna", .{});
     defer vienna.deinit();
 
     // Parse an Instant from an ISO8601 or RFC3339 string
-    const iso = try zeit.instant(.{
-	.source = .{
-	    .iso8601 = "2024-03-16T08:38:29.496-1200",
-	},
+    _ = try zeit.instant(io, .{
+        .source = .{
+            .iso8601 = "2024-03-16T08:38:29.496-1200",
+        },
     });
 
-    const rfc3339 = try zeit.instant(.{
-	.source = .{
-	    .rfc3339 = "2024-03-16T08:38:29.496706064-1200",
-	},
+    _ = try zeit.instant(io, .{
+        .source = .{
+            .rfc3339 = "2024-03-16T08:38:29.496706064-1200",
+        },
     });
 }
 ```

Verification stays outside the patch body: `zig build test` passed, and a
repo-local sanity-check file using the updated example shape compiled cleanly.
