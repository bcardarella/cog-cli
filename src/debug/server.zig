const std = @import("std");
const json = std.json;
const Stringify = json.Stringify;
const Writer = std.io.Writer;
const types = @import("types.zig");
const session_mod = @import("session.zig");
const driver_mod = @import("driver.zig");

const SessionManager = session_mod.SessionManager;

// ── JSON-RPC Types ──────────────────────────────────────────────────────

pub const JsonRpcRequest = struct {
    jsonrpc: []const u8,
    id: ?json.Value = null,
    method: []const u8,
    params: ?json.Value = null,
};

pub const JsonRpcError = struct {
    code: i32,
    message: []const u8,
    data: ?json.Value = null,
};

// Standard JSON-RPC error codes
pub const PARSE_ERROR = -32700;
pub const INVALID_REQUEST = -32600;
pub const METHOD_NOT_FOUND = -32601;
pub const INVALID_PARAMS = -32602;
pub const INTERNAL_ERROR = -32603;

// ── Parsing ─────────────────────────────────────────────────────────────

pub fn parseJsonRpc(allocator: std.mem.Allocator, data: []const u8) !JsonRpcRequest {
    const parsed = try json.parseFromSlice(json.Value, allocator, data, .{});
    defer parsed.deinit();

    if (parsed.value != .object) return error.InvalidRequest;
    const obj = parsed.value.object;

    const method_val = obj.get("method") orelse return error.MissingMethod;
    if (method_val != .string) return error.MissingMethod;

    const id_val = obj.get("id");

    return .{
        .jsonrpc = "2.0",
        .id = if (id_val) |v| switch (v) {
            .integer => v,
            .string => v,
            .null => v,
            else => null,
        } else null,
        .method = try allocator.dupe(u8, method_val.string),
        .params = if (obj.get("params")) |p| switch (p) {
            .object, .array => p,
            else => null,
        } else null,
    };
}

// ── Response Formatting ─────────────────────────────────────────────────

pub fn formatJsonRpcResponse(allocator: std.mem.Allocator, id: ?json.Value, result: []const u8) ![]const u8 {
    var aw: Writer.Allocating = .init(allocator);
    errdefer aw.deinit();

    // Build manually to embed raw JSON for the result field
    try aw.writer.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
    if (id) |v| {
        switch (v) {
            .integer => |i| {
                var buf: [32]u8 = undefined;
                const s = std.fmt.bufPrint(&buf, "{d}", .{i}) catch "null";
                try aw.writer.writeAll(s);
            },
            .string => |s| {
                try aw.writer.writeByte('"');
                try aw.writer.writeAll(s);
                try aw.writer.writeByte('"');
            },
            else => try aw.writer.writeAll("null"),
        }
    } else {
        try aw.writer.writeAll("null");
    }
    try aw.writer.writeAll(",\"result\":");
    try aw.writer.writeAll(result);
    try aw.writer.writeByte('}');

    return try aw.toOwnedSlice();
}

pub fn formatJsonRpcError(allocator: std.mem.Allocator, id: ?json.Value, code: i32, message: []const u8) ![]const u8 {
    var aw: Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    var s: Stringify = .{ .writer = &aw.writer };

    try s.beginObject();
    try s.objectField("jsonrpc");
    try s.write("2.0");
    try s.objectField("id");
    if (id) |v| {
        try s.write(v);
    } else {
        try s.write(null);
    }
    try s.objectField("error");
    try s.beginObject();
    try s.objectField("code");
    try s.write(code);
    try s.objectField("message");
    try s.write(message);
    try s.endObject();
    try s.endObject();

    return try aw.toOwnedSlice();
}

// ── MCP Tool Definitions ────────────────────────────────────────────────

pub const tool_definitions = [_]ToolDef{
    .{
        .name = "debug_launch",
        .description = "Launch a program under the debugger",
        .input_schema = debug_launch_schema,
    },
    .{
        .name = "debug_breakpoint",
        .description = "Set, remove, or list breakpoints",
        .input_schema = debug_breakpoint_schema,
    },
    .{
        .name = "debug_run",
        .description = "Continue, step, or restart execution",
        .input_schema = debug_run_schema,
    },
    .{
        .name = "debug_inspect",
        .description = "Evaluate expressions and inspect variables",
        .input_schema = debug_inspect_schema,
    },
    .{
        .name = "debug_stop",
        .description = "Stop a debug session",
        .input_schema = debug_stop_schema,
    },
};

const ToolDef = struct {
    name: []const u8,
    description: []const u8,
    input_schema: []const u8,
};

const debug_launch_schema =
    \\{"type":"object","properties":{"program":{"type":"string","description":"Path to executable or script"},"args":{"type":"array","items":{"type":"string"},"description":"Program arguments"},"env":{"type":"object","description":"Environment variables"},"cwd":{"type":"string","description":"Working directory"},"language":{"type":"string","description":"Language hint (auto-detected from extension)"},"stop_on_entry":{"type":"boolean","default":false}},"required":["program"]}
;

const debug_breakpoint_schema =
    \\{"type":"object","properties":{"session_id":{"type":"string"},"action":{"type":"string","enum":["set","remove","list"]},"file":{"type":"string"},"line":{"type":"integer"},"condition":{"type":"string"},"hit_condition":{"type":"string"},"id":{"type":"integer"}},"required":["session_id","action"]}
;

const debug_run_schema =
    \\{"type":"object","properties":{"session_id":{"type":"string"},"action":{"type":"string","enum":["continue","step_into","step_over","step_out","restart"]}},"required":["session_id","action"]}
;

const debug_inspect_schema =
    \\{"type":"object","properties":{"session_id":{"type":"string"},"expression":{"type":"string"},"variable_ref":{"type":"integer"},"frame_id":{"type":"integer"},"scope":{"type":"string","enum":["locals","globals","arguments"]}},"required":["session_id"]}
;

const debug_stop_schema =
    \\{"type":"object","properties":{"session_id":{"type":"string"}},"required":["session_id"]}
;

// ── MCP Server ──────────────────────────────────────────────────────────

pub const McpServer = struct {
    session_manager: SessionManager,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) McpServer {
        return .{
            .session_manager = SessionManager.init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *McpServer) void {
        self.session_manager.deinit();
    }

    /// Handle an MCP JSON-RPC request and return a response.
    pub fn handleRequest(self: *McpServer, allocator: std.mem.Allocator, method: []const u8, params: ?json.Value, id: ?json.Value) ![]const u8 {
        if (std.mem.eql(u8, method, "initialize")) {
            return self.handleInitialize(allocator, id);
        } else if (std.mem.eql(u8, method, "tools/list")) {
            return self.handleToolsList(allocator, id);
        } else if (std.mem.eql(u8, method, "tools/call")) {
            return self.handleToolsCall(allocator, params, id);
        } else {
            return formatJsonRpcError(allocator, id, METHOD_NOT_FOUND, "Method not found");
        }
    }

    fn handleInitialize(self: *McpServer, allocator: std.mem.Allocator, id: ?json.Value) ![]const u8 {
        _ = self;
        const result =
            \\{"protocolVersion":"2024-11-05","capabilities":{"tools":{"listChanged":false}},"serverInfo":{"name":"cog-debug","version":"0.1.0"}}
        ;
        return formatJsonRpcResponse(allocator, id, result);
    }

    fn handleToolsList(self: *McpServer, allocator: std.mem.Allocator, id: ?json.Value) ![]const u8 {
        _ = self;
        var aw: Writer.Allocating = .init(allocator);
        defer aw.deinit();

        // Build tools list with raw schema embedding
        try aw.writer.writeAll("{\"tools\":[");
        for (&tool_definitions, 0..) |*tool, i| {
            if (i > 0) try aw.writer.writeByte(',');
            try aw.writer.writeAll("{\"name\":\"");
            try aw.writer.writeAll(tool.name);
            try aw.writer.writeAll("\",\"description\":\"");
            try aw.writer.writeAll(tool.description);
            try aw.writer.writeAll("\",\"inputSchema\":");
            try aw.writer.writeAll(tool.input_schema);
            try aw.writer.writeByte('}');
        }
        try aw.writer.writeAll("]}");

        const result = try aw.toOwnedSlice();
        defer allocator.free(result);
        return formatJsonRpcResponse(allocator, id, result);
    }

    fn handleToolsCall(self: *McpServer, allocator: std.mem.Allocator, params: ?json.Value, id: ?json.Value) ![]const u8 {
        const p = params orelse return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Missing params");
        if (p != .object) return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Params must be object");

        const name_val = p.object.get("name") orelse return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Missing tool name");
        if (name_val != .string) return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Tool name must be string");
        const tool_name = name_val.string;

        const tool_args = p.object.get("arguments");

        if (std.mem.eql(u8, tool_name, "debug_launch")) {
            return self.toolLaunch(allocator, tool_args, id);
        } else if (std.mem.eql(u8, tool_name, "debug_breakpoint")) {
            return self.toolBreakpoint(allocator, tool_args, id);
        } else if (std.mem.eql(u8, tool_name, "debug_run")) {
            return self.toolRun(allocator, tool_args, id);
        } else if (std.mem.eql(u8, tool_name, "debug_inspect")) {
            return self.toolInspect(allocator, tool_args, id);
        } else if (std.mem.eql(u8, tool_name, "debug_stop")) {
            return self.toolStop(allocator, tool_args, id);
        } else {
            return formatJsonRpcError(allocator, id, METHOD_NOT_FOUND, "Unknown tool");
        }
    }

    // ── Tool Implementations ────────────────────────────────────────────

    fn toolLaunch(self: *McpServer, allocator: std.mem.Allocator, args: ?json.Value, id: ?json.Value) ![]const u8 {
        const a = args orelse return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Missing arguments");
        if (a != .object) return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Arguments must be object");

        const config = types.LaunchConfig.parseFromJson(allocator, a) catch {
            return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Invalid launch config: program is required");
        };
        defer config.deinit(allocator);

        // Determine driver type from language hint or file extension
        const use_dap = blk: {
            if (config.language) |lang| {
                if (std.mem.eql(u8, lang, "python") or
                    std.mem.eql(u8, lang, "javascript") or
                    std.mem.eql(u8, lang, "go") or
                    std.mem.eql(u8, lang, "java")) break :blk true;
            }
            // Check file extension
            const ext = std.fs.path.extension(config.program);
            if (std.mem.eql(u8, ext, ".py") or
                std.mem.eql(u8, ext, ".js") or
                std.mem.eql(u8, ext, ".go") or
                std.mem.eql(u8, ext, ".java")) break :blk true;
            break :blk false;
        };

        if (use_dap) {
            const dap_proxy = @import("dap/proxy.zig");
            var proxy = try allocator.create(dap_proxy.DapProxy);
            proxy.* = dap_proxy.DapProxy.init(allocator);
            errdefer {
                proxy.deinit();
                allocator.destroy(proxy);
            }

            var driver = proxy.activeDriver();
            driver.launch(allocator, config) catch |err| {
                return formatJsonRpcError(allocator, id, INTERNAL_ERROR, @errorName(err));
            };

            const session_id = try self.session_manager.createSession(driver);
            if (self.session_manager.getSession(session_id)) |s| {
                s.status = .stopped;
            }

            var aw: Writer.Allocating = .init(allocator);
            defer aw.deinit();
            var s: Stringify = .{ .writer = &aw.writer };
            try s.beginObject();
            try s.objectField("session_id");
            try s.write(session_id);
            try s.objectField("status");
            try s.write("stopped");
            try s.endObject();
            const result = try aw.toOwnedSlice();
            defer allocator.free(result);
            return formatJsonRpcResponse(allocator, id, result);
        } else {
            const dwarf_engine = @import("dwarf/engine.zig");
            var engine = try allocator.create(dwarf_engine.DwarfEngine);
            engine.* = dwarf_engine.DwarfEngine.init(allocator);
            errdefer {
                engine.deinit();
                allocator.destroy(engine);
            }

            var driver = engine.activeDriver();
            driver.launch(allocator, config) catch |err| {
                return formatJsonRpcError(allocator, id, INTERNAL_ERROR, @errorName(err));
            };

            const session_id = try self.session_manager.createSession(driver);
            if (self.session_manager.getSession(session_id)) |ss| {
                ss.status = .stopped;
            }

            var aw: Writer.Allocating = .init(allocator);
            defer aw.deinit();
            var s: Stringify = .{ .writer = &aw.writer };
            try s.beginObject();
            try s.objectField("session_id");
            try s.write(session_id);
            try s.objectField("status");
            try s.write("stopped");
            try s.endObject();
            const result = try aw.toOwnedSlice();
            defer allocator.free(result);
            return formatJsonRpcResponse(allocator, id, result);
        }
    }

    fn toolBreakpoint(self: *McpServer, allocator: std.mem.Allocator, args: ?json.Value, id: ?json.Value) ![]const u8 {
        const a = args orelse return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Missing arguments");
        if (a != .object) return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Arguments must be object");

        const session_id_val = a.object.get("session_id") orelse return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Missing session_id");
        if (session_id_val != .string) return formatJsonRpcError(allocator, id, INVALID_PARAMS, "session_id must be string");

        const session = self.session_manager.getSession(session_id_val.string) orelse
            return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Unknown session");

        const action_val = a.object.get("action") orelse return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Missing action");
        if (action_val != .string) return formatJsonRpcError(allocator, id, INVALID_PARAMS, "action must be string");
        const action_str = action_val.string;

        if (std.mem.eql(u8, action_str, "set")) {
            const file_val = a.object.get("file") orelse return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Missing file for set");
            if (file_val != .string) return formatJsonRpcError(allocator, id, INVALID_PARAMS, "file must be string");
            const line_val = a.object.get("line") orelse return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Missing line for set");
            if (line_val != .integer) return formatJsonRpcError(allocator, id, INVALID_PARAMS, "line must be integer");

            const condition = if (a.object.get("condition")) |c| (if (c == .string) c.string else null) else null;

            const bp = session.driver.setBreakpoint(allocator, file_val.string, @intCast(line_val.integer), condition) catch |err| {
                return formatJsonRpcError(allocator, id, INTERNAL_ERROR, @errorName(err));
            };

            var aw: Writer.Allocating = .init(allocator);
            defer aw.deinit();
            var s: Stringify = .{ .writer = &aw.writer };
            try s.beginObject();
            try s.objectField("breakpoints");
            try s.beginArray();
            try bp.jsonStringify(&s);
            try s.endArray();
            try s.endObject();
            const result = try aw.toOwnedSlice();
            defer allocator.free(result);
            return formatJsonRpcResponse(allocator, id, result);
        } else if (std.mem.eql(u8, action_str, "remove")) {
            const bp_id_val = a.object.get("id") orelse return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Missing id for remove");
            if (bp_id_val != .integer) return formatJsonRpcError(allocator, id, INVALID_PARAMS, "id must be integer");

            session.driver.removeBreakpoint(allocator, @intCast(bp_id_val.integer)) catch |err| {
                return formatJsonRpcError(allocator, id, INTERNAL_ERROR, @errorName(err));
            };

            return formatJsonRpcResponse(allocator, id, "{\"removed\":true}");
        } else if (std.mem.eql(u8, action_str, "list")) {
            const bps = session.driver.listBreakpoints(allocator) catch |err| {
                return formatJsonRpcError(allocator, id, INTERNAL_ERROR, @errorName(err));
            };

            var aw: Writer.Allocating = .init(allocator);
            defer aw.deinit();
            var s: Stringify = .{ .writer = &aw.writer };
            try s.beginObject();
            try s.objectField("breakpoints");
            try s.beginArray();
            for (bps) |*bp| {
                try bp.jsonStringify(&s);
            }
            try s.endArray();
            try s.endObject();
            const result = try aw.toOwnedSlice();
            defer allocator.free(result);
            return formatJsonRpcResponse(allocator, id, result);
        } else {
            return formatJsonRpcError(allocator, id, INVALID_PARAMS, "action must be set, remove, or list");
        }
    }

    fn toolRun(self: *McpServer, allocator: std.mem.Allocator, args: ?json.Value, id: ?json.Value) ![]const u8 {
        const a = args orelse return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Missing arguments");
        if (a != .object) return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Arguments must be object");

        const session_id_val = a.object.get("session_id") orelse return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Missing session_id");
        if (session_id_val != .string) return formatJsonRpcError(allocator, id, INVALID_PARAMS, "session_id must be string");

        const session = self.session_manager.getSession(session_id_val.string) orelse
            return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Unknown session");

        const action_val = a.object.get("action") orelse return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Missing action");
        if (action_val != .string) return formatJsonRpcError(allocator, id, INVALID_PARAMS, "action must be string");

        const action = types.RunAction.parse(action_val.string) orelse
            return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Invalid action");

        session.status = .running;
        const state = session.driver.run(allocator, action) catch |err| {
            return formatJsonRpcError(allocator, id, INTERNAL_ERROR, @errorName(err));
        };

        session.status = if (state.stop_reason == .exit) .terminated else .stopped;

        var aw: Writer.Allocating = .init(allocator);
        defer aw.deinit();
        var s: Stringify = .{ .writer = &aw.writer };
        try state.jsonStringify(&s);
        const result = try aw.toOwnedSlice();
        defer allocator.free(result);
        return formatJsonRpcResponse(allocator, id, result);
    }

    fn toolInspect(self: *McpServer, allocator: std.mem.Allocator, args: ?json.Value, id: ?json.Value) ![]const u8 {
        const a = args orelse return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Missing arguments");
        if (a != .object) return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Arguments must be object");

        const session_id_val = a.object.get("session_id") orelse return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Missing session_id");
        if (session_id_val != .string) return formatJsonRpcError(allocator, id, INVALID_PARAMS, "session_id must be string");

        const session = self.session_manager.getSession(session_id_val.string) orelse
            return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Unknown session");

        const request = types.InspectRequest{
            .expression = if (a.object.get("expression")) |v| (if (v == .string) v.string else null) else null,
            .variable_ref = if (a.object.get("variable_ref")) |v| (if (v == .integer) @as(u32, @intCast(v.integer)) else null) else null,
            .frame_id = if (a.object.get("frame_id")) |v| (if (v == .integer) @as(u32, @intCast(v.integer)) else null) else null,
            .scope = if (a.object.get("scope")) |v| (if (v == .string) v.string else null) else null,
        };

        const result_val = session.driver.inspect(allocator, request) catch |err| {
            return formatJsonRpcError(allocator, id, INTERNAL_ERROR, @errorName(err));
        };

        var aw: Writer.Allocating = .init(allocator);
        defer aw.deinit();
        var s: Stringify = .{ .writer = &aw.writer };
        try result_val.jsonStringify(&s);
        const result = try aw.toOwnedSlice();
        defer allocator.free(result);
        return formatJsonRpcResponse(allocator, id, result);
    }

    fn toolStop(self: *McpServer, allocator: std.mem.Allocator, args: ?json.Value, id: ?json.Value) ![]const u8 {
        const a = args orelse return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Missing arguments");
        if (a != .object) return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Arguments must be object");

        const session_id_val = a.object.get("session_id") orelse return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Missing session_id");
        if (session_id_val != .string) return formatJsonRpcError(allocator, id, INVALID_PARAMS, "session_id must be string");

        const session_id = session_id_val.string;

        if (self.session_manager.getSession(session_id)) |session| {
            session.driver.stop(allocator) catch {};
        }

        // Copy key before destroying since destroySession frees the key
        const id_copy = try allocator.dupe(u8, session_id);
        defer allocator.free(id_copy);
        _ = self.session_manager.destroySession(id_copy);

        return formatJsonRpcResponse(allocator, id, "{\"stopped\":true}");
    }

    // ── Stdio Transport ─────────────────────────────────────────────────

    pub fn runStdio(self: *McpServer) !void {
        const stdin = std.fs.File.stdin();
        const stdout = std.fs.File.stdout();
        var reader_buf: [65536]u8 = undefined;
        var reader = stdin.reader(&reader_buf);

        while (true) {
            const line = reader.interface.takeDelimiterExclusive('\n') catch |err| switch (err) {
                error.ReadFailed => return, // EOF or read error
                error.EndOfStream => return, // EOF
                error.StreamTooLong => continue,
            };

            if (line.len == 0) continue;

            // Parse JSON-RPC
            const parsed = parseJsonRpc(self.allocator, line) catch {
                const err_resp = try formatJsonRpcError(self.allocator, null, PARSE_ERROR, "Parse error");
                defer self.allocator.free(err_resp);
                var write_buf: [65536]u8 = undefined;
                var w = stdout.writer(&write_buf);
                w.interface.writeAll(err_resp) catch {};
                w.interface.writeByte('\n') catch {};
                w.interface.flush() catch {};
                continue;
            };
            defer self.allocator.free(parsed.method);

            const response = try self.handleRequest(self.allocator, parsed.method, parsed.params, parsed.id);
            defer self.allocator.free(response);

            var write_buf: [65536]u8 = undefined;
            var w = stdout.writer(&write_buf);
            w.interface.writeAll(response) catch {};
            w.interface.writeByte('\n') catch {};
            w.interface.flush() catch {};
        }
    }
};

// ── Tests ───────────────────────────────────────────────────────────────

test "parseJsonRpc extracts method and params from valid request" {
    const allocator = std.testing.allocator;
    const input =
        \\{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}
    ;
    const req = try parseJsonRpc(allocator, input);
    defer allocator.free(req.method);

    try std.testing.expectEqualStrings("tools/list", req.method);
}

test "parseJsonRpc returns error for missing method" {
    const allocator = std.testing.allocator;
    const input =
        \\{"jsonrpc":"2.0","id":1}
    ;
    const result = parseJsonRpc(allocator, input);
    try std.testing.expectError(error.MissingMethod, result);
}

test "parseJsonRpc handles request without params" {
    const allocator = std.testing.allocator;
    const input =
        \\{"jsonrpc":"2.0","id":1,"method":"initialize"}
    ;
    const req = try parseJsonRpc(allocator, input);
    defer allocator.free(req.method);

    try std.testing.expectEqualStrings("initialize", req.method);
    try std.testing.expect(req.params == null);
}

test "formatJsonRpcError produces error response with code" {
    const allocator = std.testing.allocator;
    const result = try formatJsonRpcError(allocator, null, METHOD_NOT_FOUND, "Method not found");
    defer allocator.free(result);

    const parsed = try json.parseFromSlice(json.Value, allocator, result, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;

    try std.testing.expectEqualStrings("2.0", obj.get("jsonrpc").?.string);
    const err_obj = obj.get("error").?.object;
    try std.testing.expectEqual(@as(i64, METHOD_NOT_FOUND), err_obj.get("code").?.integer);
    try std.testing.expectEqualStrings("Method not found", err_obj.get("message").?.string);
}

test "handleInitialize returns server capabilities" {
    const allocator = std.testing.allocator;
    var mcp = McpServer.init(allocator);
    defer mcp.deinit();

    const response = try mcp.handleRequest(allocator, "initialize", null, null);
    defer allocator.free(response);

    const parsed = try json.parseFromSlice(json.Value, allocator, response, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;

    const result = obj.get("result").?.object;
    try std.testing.expectEqualStrings("cog-debug", result.get("serverInfo").?.object.get("name").?.string);
}

test "handleToolsList returns 5 debug tools with schemas" {
    const allocator = std.testing.allocator;
    var mcp = McpServer.init(allocator);
    defer mcp.deinit();

    const response = try mcp.handleRequest(allocator, "tools/list", null, null);
    defer allocator.free(response);

    const parsed = try json.parseFromSlice(json.Value, allocator, response, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    const result = obj.get("result").?.object;
    const tools = result.get("tools").?.array;

    try std.testing.expectEqual(@as(usize, 5), tools.items.len);

    const expected_names = [_][]const u8{ "debug_launch", "debug_breakpoint", "debug_run", "debug_inspect", "debug_stop" };
    for (tools.items, 0..) |tool, i| {
        try std.testing.expectEqualStrings(expected_names[i], tool.object.get("name").?.string);
    }
}

test "handleToolsCall dispatches to correct tool handler" {
    const allocator = std.testing.allocator;
    var mcp = McpServer.init(allocator);
    defer mcp.deinit();

    // debug_stop with unknown session should return a result (stopped:true)
    const params_str =
        \\{"name":"debug_stop","arguments":{"session_id":"nonexistent"}}
    ;
    const params_parsed = try json.parseFromSlice(json.Value, allocator, params_str, .{});
    defer params_parsed.deinit();

    const response = try mcp.handleRequest(allocator, "tools/call", params_parsed.value, null);
    defer allocator.free(response);

    const parsed = try json.parseFromSlice(json.Value, allocator, response, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    // Should have a result with stopped:true
    const result = obj.get("result").?.object;
    try std.testing.expect(result.get("stopped").?.bool);
}

test "formatJsonRpcResponse produces valid JSON-RPC 2.0 response" {
    const allocator = std.testing.allocator;
    const result = try formatJsonRpcResponse(allocator, .{ .integer = 42 }, "{\"status\":\"ok\"}");
    defer allocator.free(result);

    const parsed = try json.parseFromSlice(json.Value, allocator, result, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;

    try std.testing.expectEqualStrings("2.0", obj.get("jsonrpc").?.string);
    try std.testing.expectEqual(@as(i64, 42), obj.get("id").?.integer);
    const res_obj = obj.get("result").?.object;
    try std.testing.expectEqualStrings("ok", res_obj.get("status").?.string);
}

test "handleToolsCall returns MethodNotFound for unknown tool" {
    const allocator = std.testing.allocator;
    var mcp = McpServer.init(allocator);
    defer mcp.deinit();

    const params_str =
        \\{"name":"nonexistent_tool","arguments":{}}
    ;
    const params_parsed = try json.parseFromSlice(json.Value, allocator, params_str, .{});
    defer params_parsed.deinit();

    const response = try mcp.handleRequest(allocator, "tools/call", params_parsed.value, null);
    defer allocator.free(response);

    const parsed = try json.parseFromSlice(json.Value, allocator, response, .{});
    defer parsed.deinit();
    const err = parsed.value.object.get("error").?.object;
    try std.testing.expectEqual(@as(i64, METHOD_NOT_FOUND), err.get("code").?.integer);
}

test "tool schema for debug_launch has required program field" {
    const schema = try json.parseFromSlice(json.Value, std.testing.allocator, debug_launch_schema, .{});
    defer schema.deinit();
    const obj = schema.value.object;

    try std.testing.expectEqualStrings("object", obj.get("type").?.string);
    const required = obj.get("required").?.array;
    try std.testing.expectEqual(@as(usize, 1), required.items.len);
    try std.testing.expectEqualStrings("program", required.items[0].string);
}

test "tool schema for debug_run has required session_id and action" {
    const schema = try json.parseFromSlice(json.Value, std.testing.allocator, debug_run_schema, .{});
    defer schema.deinit();
    const required = schema.value.object.get("required").?.array;

    try std.testing.expectEqual(@as(usize, 2), required.items.len);
    try std.testing.expectEqualStrings("session_id", required.items[0].string);
    try std.testing.expectEqualStrings("action", required.items[1].string);
}
