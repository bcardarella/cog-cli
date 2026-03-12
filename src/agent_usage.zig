const std = @import("std");
const paths = @import("paths.zig");
const debug_log = @import("debug_log.zig");

pub const count_file_name = "agent-selection-counts.json";

pub const Counts = std.StringHashMap(u64);

pub fn deinitCounts(allocator: std.mem.Allocator, counts: *Counts) void {
    var iter = counts.iterator();
    while (iter.next()) |entry| {
        allocator.free(entry.key_ptr.*);
    }
    counts.deinit();
}

pub fn loadCounts(allocator: std.mem.Allocator) !Counts {
    var counts = Counts.init(allocator);
    errdefer deinitCounts(allocator, &counts);

    const config_dir = paths.getGlobalConfigDir(allocator) catch return counts;
    defer allocator.free(config_dir);

    const count_path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ config_dir, count_file_name }) catch return counts;
    defer allocator.free(count_path);

    const file = std.fs.openFileAbsolute(count_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return counts,
        else => return err,
    };
    defer file.close();

    const body = try file.readToEndAlloc(allocator, 64 * 1024);
    defer allocator.free(body);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return counts;

    var iter = parsed.value.object.iterator();
    while (iter.next()) |entry| {
        if (entry.value_ptr.* != .integer) continue;
        if (entry.value_ptr.integer < 0) continue;
        try counts.put(try allocator.dupe(u8, entry.key_ptr.*), @intCast(entry.value_ptr.integer));
    }
    return counts;
}

pub fn incrementCounts(allocator: std.mem.Allocator, ids: []const []const u8) !void {
    if (ids.len == 0) return;

    var counts = try loadCounts(allocator);
    defer deinitCounts(allocator, &counts);

    for (ids) |id| {
        if (counts.getPtr(id)) |count| {
            count.* += 1;
        } else {
            try counts.put(try allocator.dupe(u8, id), 1);
        }
    }

    const config_dir = try paths.getGlobalConfigDir(allocator);
    defer allocator.free(config_dir);
    std.fs.makeDirAbsolute(config_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    const count_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ config_dir, count_file_name });
    defer allocator.free(count_path);
    debug_log.log("agent_usage.incrementCounts: {s}", .{count_path});

    var keys: std.ArrayListUnmanaged([]const u8) = .empty;
    defer keys.deinit(allocator);
    var iter = counts.iterator();
    while (iter.next()) |entry| {
        try keys.append(allocator, entry.key_ptr.*);
    }
    std.mem.sort([]const u8, keys.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lessThan);

    var aw: std.io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    var s: std.json.Stringify = .{ .writer = &aw.writer };
    try s.beginObject();
    for (keys.items) |key| {
        try s.objectField(key);
        try s.write(counts.get(key).?);
    }
    try s.endObject();
    const body = try aw.toOwnedSlice();
    defer allocator.free(body);

    const file = try std.fs.createFileAbsolute(count_path, .{});
    defer file.close();
    try file.writeAll(body);
    try file.writeAll("\n");
}

pub fn countFor(counts: *const Counts, id: []const u8) u64 {
    return counts.get(id) orelse 0;
}
