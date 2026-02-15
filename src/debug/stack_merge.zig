const std = @import("std");
const types = @import("types.zig");

// ── Hybrid Stack Merging ───────────────────────────────────────────────

pub const MergedFrame = struct {
    address: u64,
    function_name: []const u8,
    file: []const u8,
    line: u32,
    language: []const u8,
    is_boundary: bool,
    frame_index: u32,
};

pub const BoundaryResolver = struct {
    language: []const u8,
    markers: []const []const u8,
    resolve_fn: *const fn (allocator: std.mem.Allocator, frame: InputFrame) anyerror![]InputFrame,
};

pub const InputFrame = struct {
    address: u64,
    function_name: []const u8,
    file: []const u8,
    line: u32,
    language: []const u8,
};

/// Merge native stack frames with cross-language boundary detection.
/// When a frame's function name matches a boundary marker, the resolver
/// expands it into sub-frames from the target language runtime.
pub fn mergeStacks(
    native_frames: []const InputFrame,
    resolvers: []const BoundaryResolver,
    allocator: std.mem.Allocator,
) ![]MergedFrame {
    var merged: std.ArrayListUnmanaged(MergedFrame) = .empty;
    errdefer merged.deinit(allocator);

    var frame_idx: u32 = 0;

    for (native_frames) |frame| {
        // Check if this frame matches a boundary marker
        const resolver = findResolver(resolvers, frame.function_name);

        if (resolver) |r| {
            // This is a boundary frame — try to resolve it
            const sub_frames = r.resolve_fn(allocator, frame) catch {
                // Resolution failed — insert the boundary marker as-is
                try merged.append(allocator, .{
                    .address = frame.address,
                    .function_name = frame.function_name,
                    .file = frame.file,
                    .line = frame.line,
                    .language = frame.language,
                    .is_boundary = true,
                    .frame_index = frame_idx,
                });
                frame_idx += 1;
                continue;
            };
            defer allocator.free(sub_frames);

            // Insert expanded sub-frames
            for (sub_frames) |sub| {
                try merged.append(allocator, .{
                    .address = sub.address,
                    .function_name = sub.function_name,
                    .file = sub.file,
                    .line = sub.line,
                    .language = r.language,
                    .is_boundary = false,
                    .frame_index = frame_idx,
                });
                frame_idx += 1;
            }
        } else {
            // Normal frame — pass through
            try merged.append(allocator, .{
                .address = frame.address,
                .function_name = frame.function_name,
                .file = frame.file,
                .line = frame.line,
                .language = frame.language,
                .is_boundary = false,
                .frame_index = frame_idx,
            });
            frame_idx += 1;
        }
    }

    return try merged.toOwnedSlice(allocator);
}

fn findResolver(resolvers: []const BoundaryResolver, function_name: []const u8) ?*const BoundaryResolver {
    for (resolvers) |*r| {
        for (r.markers) |marker| {
            if (std.mem.eql(u8, function_name, marker) or
                std.mem.startsWith(u8, function_name, marker))
            {
                return r;
            }
        }
    }
    return null;
}

// ── Tests ───────────────────────────────────────────────────────────────

fn noopResolver(_: std.mem.Allocator, _: InputFrame) anyerror![]InputFrame {
    return &.{};
}

fn expandToGoFrames(allocator: std.mem.Allocator, _: InputFrame) anyerror![]InputFrame {
    const frames = try allocator.alloc(InputFrame, 2);
    frames[0] = .{
        .address = 0x5000,
        .function_name = "main.goroutine",
        .file = "main.go",
        .line = 42,
        .language = "go",
    };
    frames[1] = .{
        .address = 0x5100,
        .function_name = "runtime.goexit",
        .file = "runtime.go",
        .line = 1,
        .language = "go",
    };
    return frames;
}

fn failingResolver(_: std.mem.Allocator, _: InputFrame) anyerror![]InputFrame {
    return error.ResolutionFailed;
}

test "mergeStacks passes through frames with no boundaries" {
    const frames = [_]InputFrame{
        .{ .address = 0x1000, .function_name = "main", .file = "main.c", .line = 10, .language = "c" },
        .{ .address = 0x1100, .function_name = "foo", .file = "foo.c", .line = 20, .language = "c" },
    };

    const merged = try mergeStacks(&frames, &.{}, std.testing.allocator);
    defer std.testing.allocator.free(merged);

    try std.testing.expectEqual(@as(usize, 2), merged.len);
    try std.testing.expectEqualStrings("main", merged[0].function_name);
    try std.testing.expectEqualStrings("foo", merged[1].function_name);
    try std.testing.expect(!merged[0].is_boundary);
    try std.testing.expect(!merged[1].is_boundary);
}

test "mergeStacks inserts boundary marker between language transitions" {
    const frames = [_]InputFrame{
        .{ .address = 0x1000, .function_name = "native_func", .file = "lib.c", .line = 5, .language = "c" },
        .{ .address = 0x2000, .function_name = "crosscall2", .file = "cgo.c", .line = 1, .language = "c" },
        .{ .address = 0x3000, .function_name = "after_call", .file = "lib.c", .line = 10, .language = "c" },
    };

    const go_markers = [_][]const u8{"crosscall2"};
    const resolvers = [_]BoundaryResolver{
        .{ .language = "go", .markers = &go_markers, .resolve_fn = expandToGoFrames },
    };

    const merged = try mergeStacks(&frames, &resolvers, std.testing.allocator);
    defer std.testing.allocator.free(merged);

    // Should have: native_func, 2 Go frames (expanded), after_call
    try std.testing.expectEqual(@as(usize, 4), merged.len);
    try std.testing.expectEqualStrings("native_func", merged[0].function_name);
    try std.testing.expectEqualStrings("c", merged[0].language);

    // Expanded Go frames
    try std.testing.expectEqualStrings("main.goroutine", merged[1].function_name);
    try std.testing.expectEqualStrings("go", merged[1].language);
    try std.testing.expectEqualStrings("runtime.goexit", merged[2].function_name);
    try std.testing.expectEqualStrings("go", merged[2].language);

    try std.testing.expectEqualStrings("after_call", merged[3].function_name);
}

test "BoundaryResolver matches frame by marker pattern" {
    const markers = [_][]const u8{ "crosscall2", "_cgo_topofstack" };
    const resolvers = [_]BoundaryResolver{
        .{ .language = "go", .markers = &markers, .resolve_fn = noopResolver },
    };

    try std.testing.expect(findResolver(&resolvers, "crosscall2") != null);
    try std.testing.expect(findResolver(&resolvers, "_cgo_topofstack") != null);
    try std.testing.expect(findResolver(&resolvers, "regular_func") == null);
}

test "mergeStacks skips unresolvable boundaries with marker" {
    const frames = [_]InputFrame{
        .{ .address = 0x1000, .function_name = "before", .file = "a.c", .line = 1, .language = "c" },
        .{ .address = 0x2000, .function_name = "crosscall2", .file = "cgo.c", .line = 1, .language = "c" },
        .{ .address = 0x3000, .function_name = "after", .file = "a.c", .line = 2, .language = "c" },
    };

    const markers = [_][]const u8{"crosscall2"};
    const resolvers = [_]BoundaryResolver{
        .{ .language = "go", .markers = &markers, .resolve_fn = failingResolver },
    };

    const merged = try mergeStacks(&frames, &resolvers, std.testing.allocator);
    defer std.testing.allocator.free(merged);

    // Failed resolution should keep the boundary frame as-is with is_boundary=true
    try std.testing.expectEqual(@as(usize, 3), merged.len);
    try std.testing.expect(merged[1].is_boundary);
    try std.testing.expectEqualStrings("crosscall2", merged[1].function_name);
}

test "mergeStacks preserves frame order after merge" {
    const frames = [_]InputFrame{
        .{ .address = 0x1000, .function_name = "a", .file = "a.c", .line = 1, .language = "c" },
        .{ .address = 0x2000, .function_name = "b", .file = "b.c", .line = 2, .language = "c" },
        .{ .address = 0x3000, .function_name = "c", .file = "c.c", .line = 3, .language = "c" },
    };

    const merged = try mergeStacks(&frames, &.{}, std.testing.allocator);
    defer std.testing.allocator.free(merged);

    try std.testing.expectEqual(@as(u32, 0), merged[0].frame_index);
    try std.testing.expectEqual(@as(u32, 1), merged[1].frame_index);
    try std.testing.expectEqual(@as(u32, 2), merged[2].frame_index);
}

test "mergeStacks tags each frame with correct language" {
    const frames = [_]InputFrame{
        .{ .address = 0x1000, .function_name = "native", .file = "lib.c", .line = 1, .language = "c" },
        .{ .address = 0x2000, .function_name = "crosscall2", .file = "cgo.c", .line = 1, .language = "c" },
    };

    const markers = [_][]const u8{"crosscall2"};
    const resolvers = [_]BoundaryResolver{
        .{ .language = "go", .markers = &markers, .resolve_fn = expandToGoFrames },
    };

    const merged = try mergeStacks(&frames, &resolvers, std.testing.allocator);
    defer std.testing.allocator.free(merged);

    try std.testing.expectEqualStrings("c", merged[0].language);
    try std.testing.expectEqualStrings("go", merged[1].language);
    try std.testing.expectEqualStrings("go", merged[2].language);
}

test "mergeStacks handles empty native frames" {
    const merged = try mergeStacks(&.{}, &.{}, std.testing.allocator);
    defer std.testing.allocator.free(merged);

    try std.testing.expectEqual(@as(usize, 0), merged.len);
}

test "mergeStacks handles boundary at stack bottom" {
    const frames = [_]InputFrame{
        .{ .address = 0x1000, .function_name = "crosscall2", .file = "cgo.c", .line = 1, .language = "c" },
    };

    const markers = [_][]const u8{"crosscall2"};
    const resolvers = [_]BoundaryResolver{
        .{ .language = "go", .markers = &markers, .resolve_fn = expandToGoFrames },
    };

    const merged = try mergeStacks(&frames, &resolvers, std.testing.allocator);
    defer std.testing.allocator.free(merged);

    // Boundary at bottom should still be expanded
    try std.testing.expectEqual(@as(usize, 2), merged.len);
    try std.testing.expectEqualStrings("main.goroutine", merged[0].function_name);
}

test "BoundaryResolver expands boundary into sub-frames" {
    // Test that a resolver correctly expands a boundary frame into sub-frames
    const frame = InputFrame{
        .address = 0x2000,
        .function_name = "crosscall2",
        .file = "cgo.c",
        .line = 1,
        .language = "c",
    };

    const sub_frames = try expandToGoFrames(std.testing.allocator, frame);
    defer std.testing.allocator.free(sub_frames);

    try std.testing.expectEqual(@as(usize, 2), sub_frames.len);
    try std.testing.expectEqualStrings("main.goroutine", sub_frames[0].function_name);
    try std.testing.expectEqualStrings("main.go", sub_frames[0].file);
    try std.testing.expectEqual(@as(u32, 42), sub_frames[0].line);
    try std.testing.expectEqualStrings("runtime.goexit", sub_frames[1].function_name);
}

test "mergeStacks handles multiple boundary resolvers" {
    const frames = [_]InputFrame{
        .{ .address = 0x1000, .function_name = "native", .file = "lib.c", .line = 1, .language = "c" },
        .{ .address = 0x2000, .function_name = "crosscall2", .file = "cgo.c", .line = 1, .language = "c" },
        .{ .address = 0x3000, .function_name = "v8_entry", .file = "v8.cc", .line = 1, .language = "c" },
    };

    const go_markers = [_][]const u8{"crosscall2"};
    const js_markers = [_][]const u8{"v8_entry"};
    const resolvers = [_]BoundaryResolver{
        .{ .language = "go", .markers = &go_markers, .resolve_fn = expandToGoFrames },
        .{ .language = "js", .markers = &js_markers, .resolve_fn = noopResolver },
    };

    const merged = try mergeStacks(&frames, &resolvers, std.testing.allocator);
    defer std.testing.allocator.free(merged);

    // native + 2 Go frames + 0 JS frames (noop)
    try std.testing.expectEqual(@as(usize, 3), merged.len);
    try std.testing.expectEqualStrings("c", merged[0].language);
    try std.testing.expectEqualStrings("go", merged[1].language);
}
