const std = @import("std");
const json = std.json;
const Stringify = json.Stringify;
const Writer = std.io.Writer;

// ── DAP Base Types ──────────────────────────────────────────────────────

pub const MessageType = enum {
    request,
    response,
    event,
};

pub const DapRequest = struct {
    seq: i64,
    command: []const u8,
    arguments: ?json.Value = null,

    pub fn serialize(self: *const DapRequest, allocator: std.mem.Allocator) ![]const u8 {
        var aw: Writer.Allocating = .init(allocator);
        errdefer aw.deinit();
        var s: Stringify = .{ .writer = &aw.writer };

        try s.beginObject();
        try s.objectField("seq");
        try s.write(self.seq);
        try s.objectField("type");
        try s.write("request");
        try s.objectField("command");
        try s.write(self.command);
        if (self.arguments) |args| {
            try s.objectField("arguments");
            try s.write(args);
        }
        try s.endObject();

        return try aw.toOwnedSlice();
    }
};

pub const DapResponse = struct {
    seq: i64,
    request_seq: i64,
    command: []const u8,
    success: bool,
    message: ?[]const u8 = null,
    body: ?json.Value = null,

    pub fn parse(allocator: std.mem.Allocator, data: []const u8) !DapResponse {
        const parsed = try json.parseFromSlice(json.Value, allocator, data, .{});
        defer parsed.deinit();

        if (parsed.value != .object) return error.InvalidResponse;
        const obj = parsed.value.object;

        const type_val = obj.get("type") orelse return error.InvalidResponse;
        if (type_val != .string) return error.InvalidResponse;
        if (!std.mem.eql(u8, type_val.string, "response")) return error.NotAResponse;

        const seq = if (obj.get("seq")) |v| switch (v) {
            .integer => v.integer,
            else => 0,
        } else 0;

        const request_seq = if (obj.get("request_seq")) |v| switch (v) {
            .integer => v.integer,
            else => 0,
        } else 0;

        const command_val = obj.get("command") orelse return error.InvalidResponse;
        if (command_val != .string) return error.InvalidResponse;
        const command = try allocator.dupe(u8, command_val.string);

        const success = if (obj.get("success")) |v| v == .bool and v.bool else false;

        const message = if (obj.get("message")) |v| blk: {
            if (v == .string) break :blk try allocator.dupe(u8, v.string);
            break :blk null;
        } else null;

        return .{
            .seq = seq,
            .request_seq = request_seq,
            .command = command,
            .success = success,
            .message = message,
        };
    }

    pub fn deinit(self: *const DapResponse, allocator: std.mem.Allocator) void {
        allocator.free(self.command);
        if (self.message) |m| allocator.free(m);
    }
};

pub const DapEvent = struct {
    seq: i64,
    event: []const u8,
    body: ?json.Value = null,

    // Parsed fields from common events
    stop_reason: ?[]const u8 = null,
    thread_id: ?i64 = null,
    exit_code: ?i64 = null,

    pub fn parse(allocator: std.mem.Allocator, data: []const u8) !DapEvent {
        const parsed = try json.parseFromSlice(json.Value, allocator, data, .{});
        defer parsed.deinit();

        if (parsed.value != .object) return error.InvalidEvent;
        const obj = parsed.value.object;

        const type_val = obj.get("type") orelse return error.InvalidEvent;
        if (type_val != .string) return error.InvalidEvent;
        if (!std.mem.eql(u8, type_val.string, "event")) return error.NotAnEvent;

        const seq = if (obj.get("seq")) |v| switch (v) {
            .integer => v.integer,
            else => 0,
        } else 0;

        const event_val = obj.get("event") orelse return error.InvalidEvent;
        if (event_val != .string) return error.InvalidEvent;
        const event = try allocator.dupe(u8, event_val.string);

        var result: DapEvent = .{
            .seq = seq,
            .event = event,
        };

        // Parse body for common events
        if (obj.get("body")) |body| {
            if (body == .object) {
                const body_obj = body.object;
                if (body_obj.get("reason")) |r| {
                    if (r == .string) {
                        result.stop_reason = try allocator.dupe(u8, r.string);
                    }
                }
                if (body_obj.get("threadId")) |t| {
                    if (t == .integer) result.thread_id = t.integer;
                }
                if (body_obj.get("exitCode")) |e| {
                    if (e == .integer) result.exit_code = e.integer;
                }
            }
        }

        return result;
    }

    pub fn deinit(self: *const DapEvent, allocator: std.mem.Allocator) void {
        allocator.free(self.event);
        if (self.stop_reason) |r| allocator.free(r);
    }
};

// ── Request Builders ────────────────────────────────────────────────────

pub fn initializeRequest(allocator: std.mem.Allocator, seq: i64) ![]const u8 {
    var aw: Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    var s: Stringify = .{ .writer = &aw.writer };

    try s.beginObject();
    try s.objectField("seq");
    try s.write(seq);
    try s.objectField("type");
    try s.write("request");
    try s.objectField("command");
    try s.write("initialize");
    try s.objectField("arguments");
    try s.beginObject();
    try s.objectField("clientID");
    try s.write("cog-debug");
    try s.objectField("adapterID");
    try s.write("cog");
    try s.objectField("linesStartAt1");
    try s.write(true);
    try s.objectField("columnsStartAt1");
    try s.write(true);
    try s.objectField("supportsRunInTerminalRequest");
    try s.write(false);
    try s.endObject();
    try s.endObject();

    return try aw.toOwnedSlice();
}

pub fn launchRequest(allocator: std.mem.Allocator, seq: i64, program: []const u8, args: []const []const u8, stop_on_entry: bool) ![]const u8 {
    var aw: Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    var s: Stringify = .{ .writer = &aw.writer };

    try s.beginObject();
    try s.objectField("seq");
    try s.write(seq);
    try s.objectField("type");
    try s.write("request");
    try s.objectField("command");
    try s.write("launch");
    try s.objectField("arguments");
    try s.beginObject();
    try s.objectField("program");
    try s.write(program);
    if (args.len > 0) {
        try s.objectField("args");
        try s.beginArray();
        for (args) |arg| try s.write(arg);
        try s.endArray();
    }
    try s.objectField("stopOnEntry");
    try s.write(stop_on_entry);
    try s.endObject();
    try s.endObject();

    return try aw.toOwnedSlice();
}

pub fn setBreakpointsRequest(allocator: std.mem.Allocator, seq: i64, source_path: []const u8, lines: []const u32) ![]const u8 {
    var aw: Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    var s: Stringify = .{ .writer = &aw.writer };

    try s.beginObject();
    try s.objectField("seq");
    try s.write(seq);
    try s.objectField("type");
    try s.write("request");
    try s.objectField("command");
    try s.write("setBreakpoints");
    try s.objectField("arguments");
    try s.beginObject();
    try s.objectField("source");
    try s.beginObject();
    try s.objectField("path");
    try s.write(source_path);
    try s.endObject();
    try s.objectField("breakpoints");
    try s.beginArray();
    for (lines) |line| {
        try s.beginObject();
        try s.objectField("line");
        try s.write(line);
        try s.endObject();
    }
    try s.endArray();
    try s.endObject();
    try s.endObject();

    return try aw.toOwnedSlice();
}

pub fn continueRequest(allocator: std.mem.Allocator, seq: i64, thread_id: i64) ![]const u8 {
    return threadCommand(allocator, seq, "continue", thread_id);
}

pub fn stepInRequest(allocator: std.mem.Allocator, seq: i64, thread_id: i64) ![]const u8 {
    return threadCommand(allocator, seq, "stepIn", thread_id);
}

pub fn nextRequest(allocator: std.mem.Allocator, seq: i64, thread_id: i64) ![]const u8 {
    return threadCommand(allocator, seq, "next", thread_id);
}

pub fn stepOutRequest(allocator: std.mem.Allocator, seq: i64, thread_id: i64) ![]const u8 {
    return threadCommand(allocator, seq, "stepOut", thread_id);
}

pub fn stackTraceRequest(allocator: std.mem.Allocator, seq: i64, thread_id: i64, start_frame: i64, levels: i64) ![]const u8 {
    var aw: Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    var s: Stringify = .{ .writer = &aw.writer };

    try s.beginObject();
    try s.objectField("seq");
    try s.write(seq);
    try s.objectField("type");
    try s.write("request");
    try s.objectField("command");
    try s.write("stackTrace");
    try s.objectField("arguments");
    try s.beginObject();
    try s.objectField("threadId");
    try s.write(thread_id);
    try s.objectField("startFrame");
    try s.write(start_frame);
    try s.objectField("levels");
    try s.write(levels);
    try s.endObject();
    try s.endObject();

    return try aw.toOwnedSlice();
}

pub fn variablesRequest(allocator: std.mem.Allocator, seq: i64, variables_ref: i64) ![]const u8 {
    var aw: Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    var s: Stringify = .{ .writer = &aw.writer };

    try s.beginObject();
    try s.objectField("seq");
    try s.write(seq);
    try s.objectField("type");
    try s.write("request");
    try s.objectField("command");
    try s.write("variables");
    try s.objectField("arguments");
    try s.beginObject();
    try s.objectField("variablesReference");
    try s.write(variables_ref);
    try s.endObject();
    try s.endObject();

    return try aw.toOwnedSlice();
}

pub fn evaluateRequest(allocator: std.mem.Allocator, seq: i64, expression: []const u8, frame_id: ?i64) ![]const u8 {
    var aw: Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    var s: Stringify = .{ .writer = &aw.writer };

    try s.beginObject();
    try s.objectField("seq");
    try s.write(seq);
    try s.objectField("type");
    try s.write("request");
    try s.objectField("command");
    try s.write("evaluate");
    try s.objectField("arguments");
    try s.beginObject();
    try s.objectField("expression");
    try s.write(expression);
    try s.objectField("context");
    try s.write("repl");
    if (frame_id) |fid| {
        try s.objectField("frameId");
        try s.write(fid);
    }
    try s.endObject();
    try s.endObject();

    return try aw.toOwnedSlice();
}

pub fn disconnectRequest(allocator: std.mem.Allocator, seq: i64) ![]const u8 {
    var aw: Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    var s: Stringify = .{ .writer = &aw.writer };

    try s.beginObject();
    try s.objectField("seq");
    try s.write(seq);
    try s.objectField("type");
    try s.write("request");
    try s.objectField("command");
    try s.write("disconnect");
    try s.objectField("arguments");
    try s.beginObject();
    try s.objectField("terminateDebuggee");
    try s.write(true);
    try s.endObject();
    try s.endObject();

    return try aw.toOwnedSlice();
}

pub fn scopesRequest(allocator: std.mem.Allocator, seq: i64, frame_id: i64) ![]const u8 {
    var aw: Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    var s: Stringify = .{ .writer = &aw.writer };

    try s.beginObject();
    try s.objectField("seq");
    try s.write(seq);
    try s.objectField("type");
    try s.write("request");
    try s.objectField("command");
    try s.write("scopes");
    try s.objectField("arguments");
    try s.beginObject();
    try s.objectField("frameId");
    try s.write(frame_id);
    try s.endObject();
    try s.endObject();

    return try aw.toOwnedSlice();
}

fn threadCommand(allocator: std.mem.Allocator, seq: i64, command: []const u8, thread_id: i64) ![]const u8 {
    var aw: Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    var s: Stringify = .{ .writer = &aw.writer };

    try s.beginObject();
    try s.objectField("seq");
    try s.write(seq);
    try s.objectField("type");
    try s.write("request");
    try s.objectField("command");
    try s.write(command);
    try s.objectField("arguments");
    try s.beginObject();
    try s.objectField("threadId");
    try s.write(thread_id);
    try s.endObject();
    try s.endObject();

    return try aw.toOwnedSlice();
}

// ── Tests ───────────────────────────────────────────────────────────────

test "DapRequest serializes with correct seq and type" {
    const allocator = std.testing.allocator;
    const req = DapRequest{
        .seq = 1,
        .command = "initialize",
    };
    const data = try req.serialize(allocator);
    defer allocator.free(data);

    const parsed = try json.parseFromSlice(json.Value, allocator, data, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;

    try std.testing.expectEqual(@as(i64, 1), obj.get("seq").?.integer);
    try std.testing.expectEqualStrings("request", obj.get("type").?.string);
    try std.testing.expectEqualStrings("initialize", obj.get("command").?.string);
}

test "DapResponse deserializes success response" {
    const allocator = std.testing.allocator;
    const data =
        \\{"seq":1,"type":"response","request_seq":1,"command":"initialize","success":true}
    ;
    const resp = try DapResponse.parse(allocator, data);
    defer resp.deinit(allocator);

    try std.testing.expect(resp.success);
    try std.testing.expectEqualStrings("initialize", resp.command);
    try std.testing.expectEqual(@as(i64, 1), resp.request_seq);
}

test "DapResponse deserializes error response" {
    const allocator = std.testing.allocator;
    const data =
        \\{"seq":2,"type":"response","request_seq":1,"command":"launch","success":false,"message":"Failed to launch"}
    ;
    const resp = try DapResponse.parse(allocator, data);
    defer resp.deinit(allocator);

    try std.testing.expect(!resp.success);
    try std.testing.expectEqualStrings("launch", resp.command);
    try std.testing.expectEqualStrings("Failed to launch", resp.message.?);
}

test "DapEvent deserializes stopped event with reason" {
    const allocator = std.testing.allocator;
    const data =
        \\{"seq":5,"type":"event","event":"stopped","body":{"reason":"breakpoint","threadId":1}}
    ;
    const evt = try DapEvent.parse(allocator, data);
    defer evt.deinit(allocator);

    try std.testing.expectEqualStrings("stopped", evt.event);
    try std.testing.expectEqualStrings("breakpoint", evt.stop_reason.?);
    try std.testing.expectEqual(@as(i64, 1), evt.thread_id.?);
}

test "DapEvent deserializes exited event with exit code" {
    const allocator = std.testing.allocator;
    const data =
        \\{"seq":10,"type":"event","event":"exited","body":{"exitCode":0}}
    ;
    const evt = try DapEvent.parse(allocator, data);
    defer evt.deinit(allocator);

    try std.testing.expectEqualStrings("exited", evt.event);
    try std.testing.expectEqual(@as(i64, 0), evt.exit_code.?);
}

test "InitializeRequest has correct command and arguments" {
    const allocator = std.testing.allocator;
    const data = try initializeRequest(allocator, 1);
    defer allocator.free(data);

    const parsed = try json.parseFromSlice(json.Value, allocator, data, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;

    try std.testing.expectEqualStrings("initialize", obj.get("command").?.string);
    const args = obj.get("arguments").?.object;
    try std.testing.expectEqualStrings("cog-debug", args.get("clientID").?.string);
    try std.testing.expect(args.get("linesStartAt1").?.bool);
}

test "SetBreakpointsRequest serializes source and breakpoints" {
    const allocator = std.testing.allocator;
    const lines = [_]u32{ 10, 20 };
    const data = try setBreakpointsRequest(allocator, 3, "/test/file.py", &lines);
    defer allocator.free(data);

    const parsed = try json.parseFromSlice(json.Value, allocator, data, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;

    try std.testing.expectEqualStrings("setBreakpoints", obj.get("command").?.string);
    const args = obj.get("arguments").?.object;
    try std.testing.expectEqualStrings("/test/file.py", args.get("source").?.object.get("path").?.string);
    const bps = args.get("breakpoints").?.array;
    try std.testing.expectEqual(@as(usize, 2), bps.items.len);
    try std.testing.expectEqual(@as(i64, 10), bps.items[0].object.get("line").?.integer);
}

test "ContinueRequest serializes with threadId" {
    const allocator = std.testing.allocator;
    const data = try continueRequest(allocator, 5, 1);
    defer allocator.free(data);

    const parsed = try json.parseFromSlice(json.Value, allocator, data, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;

    try std.testing.expectEqualStrings("continue", obj.get("command").?.string);
    try std.testing.expectEqual(@as(i64, 1), obj.get("arguments").?.object.get("threadId").?.integer);
}

test "StepInRequest serializes with threadId" {
    const allocator = std.testing.allocator;
    const data = try stepInRequest(allocator, 6, 1);
    defer allocator.free(data);

    const parsed = try json.parseFromSlice(json.Value, allocator, data, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("stepIn", parsed.value.object.get("command").?.string);
}

test "StackTraceRequest serializes with startFrame and levels" {
    const allocator = std.testing.allocator;
    const data = try stackTraceRequest(allocator, 7, 1, 0, 5);
    defer allocator.free(data);

    const parsed = try json.parseFromSlice(json.Value, allocator, data, .{});
    defer parsed.deinit();
    const args = parsed.value.object.get("arguments").?.object;

    try std.testing.expectEqual(@as(i64, 0), args.get("startFrame").?.integer);
    try std.testing.expectEqual(@as(i64, 5), args.get("levels").?.integer);
}

test "VariablesRequest serializes with variablesReference" {
    const allocator = std.testing.allocator;
    const data = try variablesRequest(allocator, 8, 42);
    defer allocator.free(data);

    const parsed = try json.parseFromSlice(json.Value, allocator, data, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(i64, 42), parsed.value.object.get("arguments").?.object.get("variablesReference").?.integer);
}

test "EvaluateRequest serializes with expression and frameId" {
    const allocator = std.testing.allocator;
    const data = try evaluateRequest(allocator, 9, "len(items)", 3);
    defer allocator.free(data);

    const parsed = try json.parseFromSlice(json.Value, allocator, data, .{});
    defer parsed.deinit();
    const args = parsed.value.object.get("arguments").?.object;

    try std.testing.expectEqualStrings("len(items)", args.get("expression").?.string);
    try std.testing.expectEqual(@as(i64, 3), args.get("frameId").?.integer);
}
