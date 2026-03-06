const std = @import("std");

/// Global debug log file handle. When null, all log calls are no-ops.
var log_file: ?std.fs.File = null;

/// Initialize debug logging by opening .cog/cog.log in the given cog directory (append mode).
pub fn init(cog_dir: []const u8) void {
    var path_buf: [4096]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/cog.log", .{cog_dir}) catch return;
    const path_z = std.fmt.bufPrintZ(path_buf[path.len + 1 ..], "{s}", .{path}) catch return;
    // bufPrintZ wrote into a sub-slice — we need the sentinel pointer
    const sentinel_path: [*:0]const u8 = @ptrCast(path_buf[path.len + 1 ..].ptr);
    _ = sentinel_path;

    // Open with createFile in append mode
    var dir = std.fs.openDirAbsolute(cog_dir, .{}) catch return;
    defer dir.close();
    log_file = dir.createFile("cog.log", .{ .truncate = false }) catch return;
    if (log_file) |f| {
        f.seekFromEnd(0) catch {};
    }
    _ = path_z;
    log("=== debug logging started ===", .{});
}

/// Initialize debug logging by finding .cog directory from cwd.
pub fn initFromCwd(allocator: std.mem.Allocator) void {
    const paths = @import("paths.zig");
    const cog_dir = paths.findCogDir(allocator) catch {
        // No .cog dir found — try to create one in cwd
        const fallback = paths.findOrCreateCogDir(allocator) catch return;
        defer allocator.free(fallback);
        init(fallback);
        return;
    };
    defer allocator.free(cog_dir);
    init(cog_dir);
}

/// Close the debug log file.
pub fn deinit() void {
    if (log_file) |f| {
        log("=== debug logging stopped ===", .{});
        f.close();
    }
    log_file = null;
}

/// Write a timestamped log entry. No-op when debug logging is not enabled.
pub fn log(comptime fmt: []const u8, args: anytype) void {
    const f = log_file orelse return;
    var buf: [128]u8 = undefined;
    const ts = std.time.timestamp();
    const prefix = std.fmt.bufPrint(&buf, "[{d}] ", .{ts}) catch return;
    f.writeAll(prefix) catch return;
    var msg_buf: [8192]u8 = undefined;
    const msg = std.fmt.bufPrint(&msg_buf, fmt, args) catch return;
    f.writeAll(msg) catch return;
    f.writeAll("\n") catch return;
}

/// Returns true when debug logging is active.
pub fn enabled() bool {
    return log_file != null;
}

test "debug_log disabled by default" {
    try std.testing.expect(!enabled());
    // Calling log when disabled should be a safe no-op
    log("this should not crash", .{});
}
