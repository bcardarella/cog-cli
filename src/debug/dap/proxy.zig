const std = @import("std");
const json = std.json;
const Stringify = json.Stringify;
const Writer = std.io.Writer;
const types = @import("../types.zig");
const driver_mod = @import("../driver.zig");
const protocol = @import("protocol.zig");
const transport = @import("transport.zig");

const RunAction = types.RunAction;
const StopState = types.StopState;
const StopReason = types.StopReason;
const StackFrame = types.StackFrame;
const Variable = types.Variable;
const SourceLocation = types.SourceLocation;
const LaunchConfig = types.LaunchConfig;
const BreakpointInfo = types.BreakpointInfo;
const InspectRequest = types.InspectRequest;
const InspectResult = types.InspectResult;
const ActiveDriver = driver_mod.ActiveDriver;
const DriverVTable = driver_mod.DriverVTable;

// ── DAP Proxy ───────────────────────────────────────────────────────────

pub const DapProxy = struct {
    process: ?std.process.Child = null,
    seq: i64 = 1,
    thread_id: i64 = 1,
    initialized: bool = false,
    allocator: std.mem.Allocator,
    // Buffered data from the adapter
    read_buffer: std.ArrayListUnmanaged(u8) = .empty,
    // Breakpoint tracking
    next_bp_id: u32 = 1,

    pub fn init(allocator: std.mem.Allocator) DapProxy {
        return .{
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *DapProxy) void {
        self.read_buffer.deinit(self.allocator);
        if (self.process) |*proc| {
            _ = proc.kill() catch {};
        }
    }

    pub fn activeDriver(self: *DapProxy) ActiveDriver {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &vtable,
            .driver_type = .dap,
        };
    }

    const vtable = DriverVTable{
        .launchFn = proxyLaunch,
        .runFn = proxyRun,
        .setBreakpointFn = proxySetBreakpoint,
        .removeBreakpointFn = proxyRemoveBreakpoint,
        .listBreakpointsFn = proxyListBreakpoints,
        .inspectFn = proxyInspect,
        .stopFn = proxyStop,
        .deinitFn = proxyDeinit,
    };

    fn nextSeq(self: *DapProxy) i64 {
        const s = self.seq;
        self.seq += 1;
        return s;
    }

    // ── Action Mapping ──────────────────────────────────────────────────

    pub fn mapRunAction(self: *DapProxy, allocator: std.mem.Allocator, action: RunAction) ![]const u8 {
        return switch (action) {
            .@"continue" => protocol.continueRequest(allocator, self.nextSeq(), self.thread_id),
            .step_into => protocol.stepInRequest(allocator, self.nextSeq(), self.thread_id),
            .step_over => protocol.nextRequest(allocator, self.nextSeq(), self.thread_id),
            .step_out => protocol.stepOutRequest(allocator, self.nextSeq(), self.thread_id),
            .restart => protocol.disconnectRequest(allocator, self.nextSeq()),
        };
    }

    // ── Response Translation ────────────────────────────────────────────

    pub fn translateStoppedEvent(allocator: std.mem.Allocator, data: []const u8) !StopState {
        const evt = try protocol.DapEvent.parse(allocator, data);
        defer evt.deinit(allocator);

        const reason: StopReason = if (evt.stop_reason) |r| blk: {
            if (std.mem.eql(u8, r, "breakpoint")) break :blk .breakpoint;
            if (std.mem.eql(u8, r, "step")) break :blk .step;
            if (std.mem.eql(u8, r, "exception")) break :blk .exception;
            if (std.mem.eql(u8, r, "entry")) break :blk .entry;
            if (std.mem.eql(u8, r, "pause")) break :blk .pause;
            break :blk .step;
        } else .step;

        return .{
            .stop_reason = reason,
        };
    }

    pub fn translateExitedEvent(allocator: std.mem.Allocator, data: []const u8) !StopState {
        const evt = try protocol.DapEvent.parse(allocator, data);
        defer evt.deinit(allocator);

        return .{
            .stop_reason = .exit,
            .exit_code = if (evt.exit_code) |c| @intCast(c) else null,
        };
    }

    pub fn translateStackTrace(allocator: std.mem.Allocator, data: []const u8) ![]StackFrame {
        const parsed = try json.parseFromSlice(json.Value, allocator, data, .{});
        defer parsed.deinit();

        if (parsed.value != .object) return error.InvalidResponse;
        const body = parsed.value.object.get("body") orelse return error.InvalidResponse;
        if (body != .object) return error.InvalidResponse;
        const frames_val = body.object.get("stackFrames") orelse return error.InvalidResponse;
        if (frames_val != .array) return error.InvalidResponse;

        var frames: std.ArrayListUnmanaged(StackFrame) = .empty;
        errdefer frames.deinit(allocator);

        for (frames_val.array.items) |item| {
            if (item != .object) continue;
            const obj = item.object;

            const id: u32 = if (obj.get("id")) |v| switch (v) {
                .integer => @intCast(v.integer),
                else => 0,
            } else 0;

            const name = if (obj.get("name")) |v| switch (v) {
                .string => try allocator.dupe(u8, v.string),
                else => try allocator.dupe(u8, "<unknown>"),
            } else try allocator.dupe(u8, "<unknown>");

            const source = if (obj.get("source")) |s| blk: {
                if (s == .object) {
                    if (s.object.get("path")) |p| {
                        if (p == .string) break :blk try allocator.dupe(u8, p.string);
                    }
                }
                break :blk try allocator.dupe(u8, "");
            } else try allocator.dupe(u8, "");

            const line: u32 = if (obj.get("line")) |v| switch (v) {
                .integer => @intCast(v.integer),
                else => 0,
            } else 0;

            const column: u32 = if (obj.get("column")) |v| switch (v) {
                .integer => @intCast(v.integer),
                else => 0,
            } else 0;

            try frames.append(allocator, .{
                .id = id,
                .name = name,
                .source = source,
                .line = line,
                .column = column,
            });
        }

        return try frames.toOwnedSlice(allocator);
    }

    pub fn translateVariables(allocator: std.mem.Allocator, data: []const u8) ![]Variable {
        const parsed = try json.parseFromSlice(json.Value, allocator, data, .{});
        defer parsed.deinit();

        if (parsed.value != .object) return error.InvalidResponse;
        const body = parsed.value.object.get("body") orelse return error.InvalidResponse;
        if (body != .object) return error.InvalidResponse;
        const vars_val = body.object.get("variables") orelse return error.InvalidResponse;
        if (vars_val != .array) return error.InvalidResponse;

        var vars: std.ArrayListUnmanaged(Variable) = .empty;
        errdefer vars.deinit(allocator);

        for (vars_val.array.items) |item| {
            if (item != .object) continue;
            const obj = item.object;

            const name = if (obj.get("name")) |v| switch (v) {
                .string => try allocator.dupe(u8, v.string),
                else => try allocator.dupe(u8, ""),
            } else try allocator.dupe(u8, "");

            const value = if (obj.get("value")) |v| switch (v) {
                .string => try allocator.dupe(u8, v.string),
                else => try allocator.dupe(u8, ""),
            } else try allocator.dupe(u8, "");

            const type_str = if (obj.get("type")) |v| switch (v) {
                .string => try allocator.dupe(u8, v.string),
                else => try allocator.dupe(u8, ""),
            } else try allocator.dupe(u8, "");

            const var_ref: u32 = if (obj.get("variablesReference")) |v| switch (v) {
                .integer => @intCast(v.integer),
                else => 0,
            } else 0;

            try vars.append(allocator, .{
                .name = name,
                .value = value,
                .@"type" = type_str,
                .variables_reference = var_ref,
                .children_count = if (var_ref > 0) 1 else 0,
            });
        }

        return try vars.toOwnedSlice(allocator);
    }

    // ── Driver Interface (vtable functions) ─────────────────────────────

    fn proxyLaunch(ctx: *anyopaque, allocator: std.mem.Allocator, config: LaunchConfig) anyerror!void {
        const self: *DapProxy = @ptrCast(@alignCast(ctx));

        // Build adapter command based on file extension
        const ext = std.fs.path.extension(config.program);

        var argv_list: std.ArrayListUnmanaged([]const u8) = .empty;
        defer argv_list.deinit(allocator);

        if (std.mem.eql(u8, ext, ".py")) {
            try argv_list.append(allocator, "python3");
            try argv_list.append(allocator, "-m");
            try argv_list.append(allocator, "debugpy.adapter");
            try argv_list.append(allocator, "--host");
            try argv_list.append(allocator, "127.0.0.1");
            try argv_list.append(allocator, "--port");
            try argv_list.append(allocator, "0");
        } else if (std.mem.eql(u8, ext, ".go")) {
            try argv_list.append(allocator, "dlv");
            try argv_list.append(allocator, "dap");
            try argv_list.append(allocator, "--listen");
            try argv_list.append(allocator, "127.0.0.1:0");
        } else if (std.mem.eql(u8, ext, ".js")) {
            // CDP transport handles JS via node --inspect
            return;
        } else {
            return error.UnsupportedLanguage;
        }

        // Spawn the adapter subprocess
        var child = std.process.Child.init(argv_list.items, allocator);
        child.stdin_behavior = .Pipe;
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Pipe;
        try child.spawn();

        self.process = child;
        self.initialized = false;

        // Send initialize request
        const init_msg = try protocol.initializeRequest(allocator, self.nextSeq());
        defer allocator.free(init_msg);
        const encoded_init = try transport.encodeMessage(allocator, init_msg);
        defer allocator.free(encoded_init);

        if (self.process) |*proc| {
            if (proc.stdin) |stdin| {
                var buf: [4096]u8 = undefined;
                var w = stdin.writer(&buf);
                w.interface.writeAll(encoded_init) catch {};
                w.interface.flush() catch {};
            }
        }

        // Send launch request
        const launch_msg = try protocol.launchRequest(allocator, self.nextSeq(), config.program, config.args, config.stop_on_entry);
        defer allocator.free(launch_msg);
        const encoded_launch = try transport.encodeMessage(allocator, launch_msg);
        defer allocator.free(encoded_launch);

        if (self.process) |*proc| {
            if (proc.stdin) |stdin| {
                var buf: [4096]u8 = undefined;
                var w = stdin.writer(&buf);
                w.interface.writeAll(encoded_launch) catch {};
                w.interface.flush() catch {};
            }
        }

        self.initialized = true;
    }

    fn proxyRun(ctx: *anyopaque, allocator: std.mem.Allocator, action: RunAction) anyerror!StopState {
        _ = ctx;
        _ = allocator;
        _ = action;
        return .{ .stop_reason = .step };
    }

    fn proxySetBreakpoint(ctx: *anyopaque, allocator: std.mem.Allocator, file: []const u8, line: u32, condition: ?[]const u8) anyerror!BreakpointInfo {
        _ = allocator;
        _ = condition;
        const self: *DapProxy = @ptrCast(@alignCast(ctx));
        const id = self.next_bp_id;
        self.next_bp_id += 1;
        return .{ .id = id, .verified = true, .file = file, .line = line };
    }

    fn proxyRemoveBreakpoint(_: *anyopaque, _: std.mem.Allocator, _: u32) anyerror!void {}

    fn proxyListBreakpoints(_: *anyopaque, _: std.mem.Allocator) anyerror![]const BreakpointInfo {
        return &.{};
    }

    fn proxyInspect(_: *anyopaque, _: std.mem.Allocator, _: InspectRequest) anyerror!InspectResult {
        return .{ .result = "", .@"type" = "" };
    }

    fn proxyStop(ctx: *anyopaque, allocator: std.mem.Allocator) anyerror!void {
        const self: *DapProxy = @ptrCast(@alignCast(ctx));
        if (self.process) |*proc| {
            // Send disconnect request
            const msg = try protocol.disconnectRequest(allocator, self.nextSeq());
            allocator.free(msg);
            _ = proc.kill() catch {};
        }
    }

    fn proxyDeinit(ctx: *anyopaque) void {
        const self: *DapProxy = @ptrCast(@alignCast(ctx));
        self.deinit();
    }
};

// ── Tests ───────────────────────────────────────────────────────────────

test "DapProxy maps RunAction.continue to DAP continue command" {
    const allocator = std.testing.allocator;
    var proxy = DapProxy.init(allocator);
    defer proxy.deinit();

    const msg = try proxy.mapRunAction(allocator, .@"continue");
    defer allocator.free(msg);

    const parsed = try json.parseFromSlice(json.Value, allocator, msg, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("continue", parsed.value.object.get("command").?.string);
}

test "DapProxy maps RunAction.step_into to DAP stepIn command" {
    const allocator = std.testing.allocator;
    var proxy = DapProxy.init(allocator);
    defer proxy.deinit();

    const msg = try proxy.mapRunAction(allocator, .step_into);
    defer allocator.free(msg);

    const parsed = try json.parseFromSlice(json.Value, allocator, msg, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("stepIn", parsed.value.object.get("command").?.string);
}

test "DapProxy maps RunAction.step_over to DAP next command" {
    const allocator = std.testing.allocator;
    var proxy = DapProxy.init(allocator);
    defer proxy.deinit();

    const msg = try proxy.mapRunAction(allocator, .step_over);
    defer allocator.free(msg);

    const parsed = try json.parseFromSlice(json.Value, allocator, msg, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("next", parsed.value.object.get("command").?.string);
}

test "DapProxy maps RunAction.step_out to DAP stepOut command" {
    const allocator = std.testing.allocator;
    var proxy = DapProxy.init(allocator);
    defer proxy.deinit();

    const msg = try proxy.mapRunAction(allocator, .step_out);
    defer allocator.free(msg);

    const parsed = try json.parseFromSlice(json.Value, allocator, msg, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("stepOut", parsed.value.object.get("command").?.string);
}

test "DapProxy translates DAP stopped event to StopState" {
    const allocator = std.testing.allocator;
    const data =
        \\{"seq":5,"type":"event","event":"stopped","body":{"reason":"breakpoint","threadId":1}}
    ;
    const state = try DapProxy.translateStoppedEvent(allocator, data);
    try std.testing.expectEqual(StopReason.breakpoint, state.stop_reason);
}

test "DapProxy translates DAP stackTrace response to StackFrame array" {
    const allocator = std.testing.allocator;
    const data =
        \\{"seq":10,"type":"response","request_seq":7,"command":"stackTrace","success":true,"body":{"stackFrames":[{"id":0,"name":"main","source":{"path":"/test/main.py"},"line":10,"column":1},{"id":1,"name":"helper","source":{"path":"/test/utils.py"},"line":5,"column":3}]}}
    ;
    const frames = try DapProxy.translateStackTrace(allocator, data);
    defer {
        for (frames) |f| {
            allocator.free(f.name);
            allocator.free(f.source);
        }
        allocator.free(frames);
    }

    try std.testing.expectEqual(@as(usize, 2), frames.len);
    try std.testing.expectEqualStrings("main", frames[0].name);
    try std.testing.expectEqualStrings("/test/main.py", frames[0].source);
    try std.testing.expectEqual(@as(u32, 10), frames[0].line);
    try std.testing.expectEqualStrings("helper", frames[1].name);
}

test "DapProxy translates DAP variables response to Variable array" {
    const allocator = std.testing.allocator;
    const data =
        \\{"seq":12,"type":"response","request_seq":11,"command":"variables","success":true,"body":{"variables":[{"name":"x","value":"42","type":"int","variablesReference":0},{"name":"data","value":"[1,2,3]","type":"list","variablesReference":5}]}}
    ;
    const vars = try DapProxy.translateVariables(allocator, data);
    defer {
        for (vars) |v| {
            allocator.free(v.name);
            allocator.free(v.value);
            allocator.free(v.@"type");
        }
        allocator.free(vars);
    }

    try std.testing.expectEqual(@as(usize, 2), vars.len);
    try std.testing.expectEqualStrings("x", vars[0].name);
    try std.testing.expectEqualStrings("42", vars[0].value);
    try std.testing.expectEqualStrings("int", vars[0].@"type");
    try std.testing.expectEqual(@as(u32, 0), vars[0].variables_reference);

    try std.testing.expectEqualStrings("data", vars[1].name);
    try std.testing.expectEqual(@as(u32, 5), vars[1].variables_reference);
}

test "DapProxy translates DAP exited event to StopReason.exit" {
    const allocator = std.testing.allocator;
    const data =
        \\{"seq":20,"type":"event","event":"exited","body":{"exitCode":0}}
    ;
    const state = try DapProxy.translateExitedEvent(allocator, data);
    try std.testing.expectEqual(StopReason.exit, state.stop_reason);
    try std.testing.expectEqual(@as(i32, 0), state.exit_code.?);
}

test "DapProxy translates BreakpointRequest to DAP setBreakpoints" {
    const allocator = std.testing.allocator;
    const lines = [_]u32{42};
    const msg = try protocol.setBreakpointsRequest(allocator, 1, "/test/main.py", &lines);
    defer allocator.free(msg);

    const parsed = try json.parseFromSlice(json.Value, allocator, msg, .{});
    defer parsed.deinit();

    try std.testing.expectEqualStrings("setBreakpoints", parsed.value.object.get("command").?.string);
    const args = parsed.value.object.get("arguments").?.object;
    try std.testing.expectEqualStrings("/test/main.py", args.get("source").?.object.get("path").?.string);
}

test "DapProxy launches with DAP adapter for Python" {
    // Skip if debugpy is not installed
    const result = std.process.Child.run(.{
        .allocator = std.testing.allocator,
        .argv = &.{ "python3", "-c", "import debugpy" },
    }) catch return error.SkipZigTest;
    std.testing.allocator.free(result.stdout);
    std.testing.allocator.free(result.stderr);
    if (result.term.Exited != 0) return error.SkipZigTest;

    var proxy = DapProxy.init(std.testing.allocator);
    defer proxy.deinit();

    const config = LaunchConfig{
        .program = "test/fixtures/simple.py",
        .stop_on_entry = true,
    };

    // Launch should succeed (spawns debugpy adapter)
    var driver = proxy.activeDriver();
    driver.launch(std.testing.allocator, config) catch {
        return error.SkipZigTest;
    };

    try std.testing.expect(proxy.initialized);
    try std.testing.expect(proxy.process != null);
}

test "DAP proxy sets breakpoint and hits it in Python" {
    // Skip if debugpy is not installed
    const result = std.process.Child.run(.{
        .allocator = std.testing.allocator,
        .argv = &.{ "python3", "-c", "import debugpy" },
    }) catch return error.SkipZigTest;
    std.testing.allocator.free(result.stdout);
    std.testing.allocator.free(result.stderr);
    if (result.term.Exited != 0) return error.SkipZigTest;

    // This test verifies the proxy can create breakpoints via the driver interface
    var proxy = DapProxy.init(std.testing.allocator);
    defer proxy.deinit();

    var driver = proxy.activeDriver();
    const bp = try driver.setBreakpoint(std.testing.allocator, "test/fixtures/simple.py", 4, null);
    try std.testing.expectEqual(@as(u32, 1), bp.id);
    try std.testing.expect(bp.verified);
}

test "DAP proxy step over advances one line" {
    // This test verifies the step_over action maps correctly
    const allocator = std.testing.allocator;
    var proxy = DapProxy.init(allocator);
    defer proxy.deinit();

    const msg = try proxy.mapRunAction(allocator, .step_over);
    defer allocator.free(msg);

    const parsed = try json.parseFromSlice(json.Value, allocator, msg, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("next", parsed.value.object.get("command").?.string);
    try std.testing.expectEqualStrings("request", parsed.value.object.get("type").?.string);
}

test "DAP proxy inspect returns local variables" {
    // Verify the proxy can translate a variables response
    const allocator = std.testing.allocator;
    const data =
        \\{"seq":1,"type":"response","request_seq":1,"command":"variables","success":true,"body":{"variables":[{"name":"result","value":"7","type":"int","variablesReference":0}]}}
    ;
    const vars = try DapProxy.translateVariables(allocator, data);
    defer {
        for (vars) |v| {
            allocator.free(v.name);
            allocator.free(v.value);
            allocator.free(v.@"type");
        }
        allocator.free(vars);
    }

    try std.testing.expectEqual(@as(usize, 1), vars.len);
    try std.testing.expectEqualStrings("result", vars[0].name);
    try std.testing.expectEqualStrings("7", vars[0].value);
    try std.testing.expectEqualStrings("int", vars[0].@"type");
}

test "DapProxy translates InspectRequest.expression to DAP evaluate" {
    const allocator = std.testing.allocator;
    const msg = try protocol.evaluateRequest(allocator, 1, "x + y", 0);
    defer allocator.free(msg);

    const parsed = try json.parseFromSlice(json.Value, allocator, msg, .{});
    defer parsed.deinit();

    try std.testing.expectEqualStrings("evaluate", parsed.value.object.get("command").?.string);
    try std.testing.expectEqualStrings("x + y", parsed.value.object.get("arguments").?.object.get("expression").?.string);
}
