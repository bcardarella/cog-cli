const std = @import("std");
const json = std.json;
const Stringify = json.Stringify;

// ── Core Debug Types ────────────────────────────────────────────────────

pub const SourceLocation = struct {
    file: []const u8,
    line: u32,
    column: u32 = 0,
    function: []const u8 = "",
};

pub const StackFrame = struct {
    id: u32,
    name: []const u8,
    source: []const u8,
    line: u32,
    column: u32 = 0,
    language: []const u8 = "",
    is_boundary: bool = false,

    pub fn jsonStringify(self: *const StackFrame, jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("id");
        try jw.write(self.id);
        try jw.objectField("name");
        try jw.write(self.name);
        try jw.objectField("source");
        try jw.write(self.source);
        try jw.objectField("line");
        try jw.write(self.line);
        try jw.objectField("column");
        try jw.write(self.column);
        if (self.language.len > 0) {
            try jw.objectField("language");
            try jw.write(self.language);
        }
        if (self.is_boundary) {
            try jw.objectField("is_boundary");
            try jw.write(true);
        }
        try jw.endObject();
    }
};

pub const Variable = struct {
    name: []const u8,
    value: []const u8,
    @"type": []const u8 = "",
    children_count: u32 = 0,
    variables_reference: u32 = 0,

    pub fn jsonStringify(self: *const Variable, jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("name");
        try jw.write(self.name);
        try jw.objectField("value");
        try jw.write(self.value);
        if (self.@"type".len > 0) {
            try jw.objectField("type");
            try jw.write(self.@"type");
        }
        if (self.children_count > 0) {
            try jw.objectField("children_count");
            try jw.write(self.children_count);
        }
        if (self.variables_reference > 0) {
            try jw.objectField("variables_reference");
            try jw.write(self.variables_reference);
        }
        try jw.endObject();
    }
};

pub const StopReason = enum {
    breakpoint,
    step,
    exception,
    exit,
    entry,
    pause,
};

pub const ExceptionInfo = struct {
    @"type": []const u8,
    message: []const u8,
};

pub const StopState = struct {
    stop_reason: StopReason,
    location: ?SourceLocation = null,
    stack_trace: []const StackFrame = &.{},
    locals: []const Variable = &.{},
    exception: ?ExceptionInfo = null,
    exit_code: ?i32 = null,

    pub fn jsonStringify(self: *const StopState, jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("stop_reason");
        try jw.write(@tagName(self.stop_reason));
        if (self.location) |loc| {
            try jw.objectField("location");
            try jw.beginObject();
            try jw.objectField("file");
            try jw.write(loc.file);
            try jw.objectField("line");
            try jw.write(loc.line);
            try jw.objectField("function");
            try jw.write(loc.function);
            try jw.endObject();
        }
        if (self.stack_trace.len > 0) {
            try jw.objectField("stack_trace");
            try jw.beginArray();
            for (self.stack_trace) |*frame| {
                try frame.jsonStringify(jw);
            }
            try jw.endArray();
        }
        if (self.locals.len > 0) {
            try jw.objectField("locals");
            try jw.beginArray();
            for (self.locals) |*v| {
                try v.jsonStringify(jw);
            }
            try jw.endArray();
        }
        if (self.exception) |exc| {
            try jw.objectField("exception");
            try jw.beginObject();
            try jw.objectField("type");
            try jw.write(exc.@"type");
            try jw.objectField("message");
            try jw.write(exc.message);
            try jw.endObject();
        }
        if (self.exit_code) |code| {
            try jw.objectField("exit_code");
            try jw.write(code);
        }
        try jw.endObject();
    }
};

pub const RunAction = enum {
    @"continue",
    step_into,
    step_over,
    step_out,
    restart,

    pub fn parse(s: []const u8) ?RunAction {
        const map = .{
            .{ "continue", .@"continue" },
            .{ "step_into", .step_into },
            .{ "step_over", .step_over },
            .{ "step_out", .step_out },
            .{ "restart", .restart },
        };
        inline for (map) |entry| {
            if (std.mem.eql(u8, s, entry[0])) return entry[1];
        }
        return null;
    }
};

pub const BreakpointAction = enum {
    set,
    remove,
    list,
};

pub const BreakpointInfo = struct {
    id: u32,
    verified: bool,
    file: []const u8,
    line: u32,
    condition: ?[]const u8 = null,
    hit_condition: ?[]const u8 = null,

    pub fn jsonStringify(self: *const BreakpointInfo, jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("id");
        try jw.write(self.id);
        try jw.objectField("verified");
        try jw.write(self.verified);
        try jw.objectField("file");
        try jw.write(self.file);
        try jw.objectField("line");
        try jw.write(self.line);
        if (self.condition) |c| {
            try jw.objectField("condition");
            try jw.write(c);
        }
        if (self.hit_condition) |h| {
            try jw.objectField("hit_condition");
            try jw.write(h);
        }
        try jw.endObject();
    }
};

pub const LaunchConfig = struct {
    program: []const u8,
    args: []const []const u8 = &.{},
    env: ?std.json.ObjectMap = null,
    cwd: ?[]const u8 = null,
    language: ?[]const u8 = null,
    stop_on_entry: bool = false,

    pub fn parseFromJson(allocator: std.mem.Allocator, value: std.json.Value) !LaunchConfig {
        if (value != .object) return error.InvalidParams;
        const obj = value.object;

        const program_val = obj.get("program") orelse return error.InvalidParams;
        if (program_val != .string) return error.InvalidParams;
        const program = try allocator.dupe(u8, program_val.string);
        errdefer allocator.free(program);

        var args_list: std.ArrayListUnmanaged([]const u8) = .empty;
        errdefer {
            for (args_list.items) |a| allocator.free(a);
            args_list.deinit(allocator);
        }
        if (obj.get("args")) |args_val| {
            if (args_val == .array) {
                for (args_val.array.items) |item| {
                    if (item == .string) {
                        try args_list.append(allocator, try allocator.dupe(u8, item.string));
                    }
                }
            }
        }

        const stop_on_entry = if (obj.get("stop_on_entry")) |v| v == .bool and v.bool else false;

        const language = if (obj.get("language")) |v| blk: {
            if (v == .string) break :blk try allocator.dupe(u8, v.string);
            break :blk null;
        } else null;

        const cwd = if (obj.get("cwd")) |v| blk: {
            if (v == .string) break :blk try allocator.dupe(u8, v.string);
            break :blk null;
        } else null;

        return .{
            .program = program,
            .args = try args_list.toOwnedSlice(allocator),
            .cwd = cwd,
            .language = language,
            .stop_on_entry = stop_on_entry,
        };
    }

    pub fn deinit(self: *const LaunchConfig, allocator: std.mem.Allocator) void {
        allocator.free(self.program);
        for (self.args) |a| allocator.free(a);
        allocator.free(self.args);
        if (self.language) |l| allocator.free(l);
        if (self.cwd) |c| allocator.free(c);
    }
};

pub const InspectRequest = struct {
    expression: ?[]const u8 = null,
    variable_ref: ?u32 = null,
    frame_id: ?u32 = null,
    scope: ?[]const u8 = null,
};

pub const InspectResult = struct {
    result: []const u8 = "",
    @"type": []const u8 = "",
    children: []const Variable = &.{},

    pub fn jsonStringify(self: *const InspectResult, jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("result");
        try jw.write(self.result);
        if (self.@"type".len > 0) {
            try jw.objectField("type");
            try jw.write(self.@"type");
        }
        if (self.children.len > 0) {
            try jw.objectField("children");
            try jw.beginArray();
            for (self.children) |*c| {
                try c.jsonStringify(jw);
            }
            try jw.endArray();
        }
        try jw.endObject();
    }
};

// ── Tests ───────────────────────────────────────────────────────────────

fn stringifyToString(allocator: std.mem.Allocator, value: anytype) ![]const u8 {
    var aw: std.io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    var jw: json.Stringify = .{ .writer = &aw.writer };
    try value.jsonStringify(&jw);
    return try aw.toOwnedSlice();
}

test "StackFrame serializes to JSON correctly" {
    const allocator = std.testing.allocator;
    const frame = StackFrame{
        .id = 0,
        .name = "main",
        .source = "test.py",
        .line = 42,
        .column = 1,
    };
    const result = try stringifyToString(allocator, frame);
    defer allocator.free(result);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, result, .{});
    defer parsed.deinit();

    try std.testing.expectEqualStrings("main", parsed.value.object.get("name").?.string);
    try std.testing.expectEqualStrings("test.py", parsed.value.object.get("source").?.string);
    try std.testing.expectEqual(@as(i64, 42), parsed.value.object.get("line").?.integer);
}

test "Variable serializes with children count" {
    const allocator = std.testing.allocator;
    const v = Variable{
        .name = "data",
        .value = "{...}",
        .@"type" = "dict",
        .children_count = 3,
        .variables_reference = 7,
    };
    const result = try stringifyToString(allocator, v);
    defer allocator.free(result);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, result, .{});
    defer parsed.deinit();

    try std.testing.expectEqualStrings("data", parsed.value.object.get("name").?.string);
    try std.testing.expectEqual(@as(i64, 3), parsed.value.object.get("children_count").?.integer);
    try std.testing.expectEqual(@as(i64, 7), parsed.value.object.get("variables_reference").?.integer);
}

test "StopState includes location and locals" {
    const allocator = std.testing.allocator;
    const locals = [_]Variable{
        .{ .name = "x", .value = "42", .@"type" = "int" },
    };
    const state = StopState{
        .stop_reason = .breakpoint,
        .location = .{ .file = "main.py", .line = 42, .function = "process" },
        .locals = &locals,
    };
    const result = try stringifyToString(allocator, state);
    defer allocator.free(result);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, result, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;

    try std.testing.expectEqualStrings("breakpoint", obj.get("stop_reason").?.string);
    const loc = obj.get("location").?.object;
    try std.testing.expectEqualStrings("main.py", loc.get("file").?.string);
    try std.testing.expectEqual(@as(i64, 42), loc.get("line").?.integer);
}

test "LaunchConfig parses from JSON with defaults" {
    const allocator = std.testing.allocator;
    const input = "{\"program\": \"/usr/bin/python3\", \"args\": [\"script.py\"]}";

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, input, .{});
    defer parsed.deinit();

    const config = try LaunchConfig.parseFromJson(allocator, parsed.value);
    defer config.deinit(allocator);

    try std.testing.expectEqualStrings("/usr/bin/python3", config.program);
    try std.testing.expectEqual(@as(usize, 1), config.args.len);
    try std.testing.expectEqualStrings("script.py", config.args[0]);
    try std.testing.expect(!config.stop_on_entry);
    try std.testing.expect(config.language == null);
}

test "RunAction parses all valid action strings" {
    try std.testing.expectEqual(RunAction.@"continue", RunAction.parse("continue").?);
    try std.testing.expectEqual(RunAction.step_into, RunAction.parse("step_into").?);
    try std.testing.expectEqual(RunAction.step_over, RunAction.parse("step_over").?);
    try std.testing.expectEqual(RunAction.step_out, RunAction.parse("step_out").?);
    try std.testing.expectEqual(RunAction.restart, RunAction.parse("restart").?);
}

test "RunAction rejects invalid action string" {
    try std.testing.expect(RunAction.parse("invalid") == null);
    try std.testing.expect(RunAction.parse("") == null);
    try std.testing.expect(RunAction.parse("CONTINUE") == null);
}
