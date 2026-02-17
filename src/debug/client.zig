const std = @import("std");
const json = std.json;
const Stringify = json.Stringify;
const Writer = std.io.Writer;
const server = @import("server.zig");

// Re-use JSON-RPC helpers from server.zig
const parseJsonRpc = server.parseJsonRpc;
const formatJsonRpcResponse = server.formatJsonRpcResponse;
const formatJsonRpcError = server.formatJsonRpcError;
const PARSE_ERROR = server.PARSE_ERROR;
const INVALID_REQUEST = server.INVALID_REQUEST;
const METHOD_NOT_FOUND = server.METHOD_NOT_FOUND;
const INVALID_PARAMS = server.INVALID_PARAMS;
const INTERNAL_ERROR = server.INTERNAL_ERROR;

// ── Client Tool Definition ──────────────────────────────────────────────

const ClientToolDef = struct {
    name: []const u8,
    description: []const u8,
    input_schema: []const u8,
    target_tool: []const u8,
    inject_action: ?[]const u8,
};

// ── Client Tool Table (38 pass-through tools) ───────────────────────────

const client_tool_definitions = [_]ClientToolDef{
    .{
        .name = "debug/send_launch",
        .description = "Launch a program under the debugger",
        .input_schema = server.debug_launch_schema,
        .target_tool = "debug_launch",
        .inject_action = null,
    },
    .{
        .name = "debug/send_stop",
        .description = "Stop a debug session",
        .input_schema = server.debug_stop_schema,
        .target_tool = "debug_stop",
        .inject_action = null,
    },
    .{
        .name = "debug/send_attach",
        .description = "Attach to a running process",
        .input_schema = server.debug_attach_schema,
        .target_tool = "debug_attach",
        .inject_action = null,
    },
    .{
        .name = "debug/send_restart",
        .description = "Restart the debug session",
        .input_schema = server.debug_restart_schema,
        .target_tool = "debug_restart",
        .inject_action = null,
    },
    .{
        .name = "debug/send_sessions",
        .description = "List all active debug sessions",
        .input_schema = server.debug_sessions_schema,
        .target_tool = "debug_sessions",
        .inject_action = null,
    },
    // ── Breakpoint variants (inject action field) ────────────────────
    .{
        .name = "debug/send_breakpoint_set",
        .description = "Set a line breakpoint",
        .input_schema = breakpoint_set_schema,
        .target_tool = "debug_breakpoint",
        .inject_action = "set",
    },
    .{
        .name = "debug/send_breakpoint_set_function",
        .description = "Set a function breakpoint",
        .input_schema = breakpoint_set_function_schema,
        .target_tool = "debug_breakpoint",
        .inject_action = "set_function",
    },
    .{
        .name = "debug/send_breakpoint_set_exception",
        .description = "Set an exception breakpoint",
        .input_schema = breakpoint_set_exception_schema,
        .target_tool = "debug_breakpoint",
        .inject_action = "set_exception",
    },
    .{
        .name = "debug/send_breakpoint_remove",
        .description = "Remove a breakpoint",
        .input_schema = breakpoint_remove_schema,
        .target_tool = "debug_breakpoint",
        .inject_action = "remove",
    },
    .{
        .name = "debug/send_breakpoint_list",
        .description = "List all breakpoints",
        .input_schema = breakpoint_list_schema,
        .target_tool = "debug_breakpoint",
        .inject_action = "list",
    },
    // ── Remaining pass-through tools ────────────────────────────────
    .{
        .name = "debug/send_breakpoint_locations",
        .description = "Query valid breakpoint positions in a source file",
        .input_schema = server.debug_breakpoint_locations_schema,
        .target_tool = "debug_breakpoint_locations",
        .inject_action = null,
    },
    .{
        .name = "debug/send_run",
        .description = "Continue, step, or restart execution",
        .input_schema = server.debug_run_schema,
        .target_tool = "debug_run",
        .inject_action = null,
    },
    .{
        .name = "debug/send_inspect",
        .description = "Evaluate expressions and inspect variables",
        .input_schema = server.debug_inspect_schema,
        .target_tool = "debug_inspect",
        .inject_action = null,
    },
    .{
        .name = "debug/send_set_variable",
        .description = "Set the value of a variable in the current scope",
        .input_schema = server.debug_set_variable_schema,
        .target_tool = "debug_set_variable",
        .inject_action = null,
    },
    .{
        .name = "debug/send_set_expression",
        .description = "Evaluate and assign a complex expression",
        .input_schema = server.debug_set_expression_schema,
        .target_tool = "debug_set_expression",
        .inject_action = null,
    },
    .{
        .name = "debug/send_threads",
        .description = "List threads in a debug session",
        .input_schema = server.debug_threads_schema,
        .target_tool = "debug_threads",
        .inject_action = null,
    },
    .{
        .name = "debug/send_stacktrace",
        .description = "Get stack trace for a thread",
        .input_schema = server.debug_stacktrace_schema,
        .target_tool = "debug_stacktrace",
        .inject_action = null,
    },
    .{
        .name = "debug/send_scopes",
        .description = "List variable scopes for a stack frame",
        .input_schema = server.debug_scopes_schema,
        .target_tool = "debug_scopes",
        .inject_action = null,
    },
    .{
        .name = "debug/send_memory",
        .description = "Read or write process memory",
        .input_schema = server.debug_memory_schema,
        .target_tool = "debug_memory",
        .inject_action = null,
    },
    .{
        .name = "debug/send_disassemble",
        .description = "Disassemble instructions at an address",
        .input_schema = server.debug_disassemble_schema,
        .target_tool = "debug_disassemble",
        .inject_action = null,
    },
    .{
        .name = "debug/send_registers",
        .description = "Read CPU register values",
        .input_schema = server.debug_registers_schema,
        .target_tool = "debug_registers",
        .inject_action = null,
    },
    .{
        .name = "debug/send_write_register",
        .description = "Write a value to a CPU register",
        .input_schema = server.debug_write_register_schema,
        .target_tool = "debug_write_register",
        .inject_action = null,
    },
    .{
        .name = "debug/send_find_symbol",
        .description = "Search for symbol definitions by name",
        .input_schema = server.debug_find_symbol_schema,
        .target_tool = "debug_find_symbol",
        .inject_action = null,
    },
    .{
        .name = "debug/send_variable_location",
        .description = "Get the physical storage location of a variable",
        .input_schema = server.debug_variable_location_schema,
        .target_tool = "debug_variable_location",
        .inject_action = null,
    },
    .{
        .name = "debug/send_goto_targets",
        .description = "Discover valid goto target locations for a source line",
        .input_schema = server.debug_goto_targets_schema,
        .target_tool = "debug_goto_targets",
        .inject_action = null,
    },
    .{
        .name = "debug/send_step_in_targets",
        .description = "List step-in targets for a stack frame",
        .input_schema = server.debug_step_in_targets_schema,
        .target_tool = "debug_step_in_targets",
        .inject_action = null,
    },
    .{
        .name = "debug/send_restart_frame",
        .description = "Restart execution from a specific stack frame",
        .input_schema = server.debug_restart_frame_schema,
        .target_tool = "debug_restart_frame",
        .inject_action = null,
    },
    .{
        .name = "debug/send_instruction_breakpoint",
        .description = "Set or remove instruction-level breakpoints",
        .input_schema = server.debug_instruction_breakpoint_schema,
        .target_tool = "debug_instruction_breakpoint",
        .inject_action = null,
    },
    .{
        .name = "debug/send_watchpoint",
        .description = "Set a data breakpoint on a variable",
        .input_schema = server.debug_watchpoint_schema,
        .target_tool = "debug_watchpoint",
        .inject_action = null,
    },
    .{
        .name = "debug/send_capabilities",
        .description = "Query debug driver capabilities",
        .input_schema = server.debug_capabilities_schema,
        .target_tool = "debug_capabilities",
        .inject_action = null,
    },
    .{
        .name = "debug/send_modules",
        .description = "List loaded modules and shared libraries",
        .input_schema = server.debug_modules_schema,
        .target_tool = "debug_modules",
        .inject_action = null,
    },
    .{
        .name = "debug/send_loaded_sources",
        .description = "List all source files available in the debug session",
        .input_schema = server.debug_loaded_sources_schema,
        .target_tool = "debug_loaded_sources",
        .inject_action = null,
    },
    .{
        .name = "debug/send_source",
        .description = "Retrieve source code by source reference",
        .input_schema = server.debug_source_schema,
        .target_tool = "debug_source",
        .inject_action = null,
    },
    .{
        .name = "debug/send_completions",
        .description = "Get completions for variable names and expressions",
        .input_schema = server.debug_completions_schema,
        .target_tool = "debug_completions",
        .inject_action = null,
    },
    .{
        .name = "debug/send_exception_info",
        .description = "Get detailed information about the current exception",
        .input_schema = server.debug_exception_info_schema,
        .target_tool = "debug_exception_info",
        .inject_action = null,
    },
    .{
        .name = "debug/send_poll_events",
        .description = "Poll for pending debug events and notifications",
        .input_schema = server.debug_poll_events_schema,
        .target_tool = "debug_poll_events",
        .inject_action = null,
    },
    .{
        .name = "debug/send_cancel",
        .description = "Cancel a pending debug request",
        .input_schema = server.debug_cancel_schema,
        .target_tool = "debug_cancel",
        .inject_action = null,
    },
    .{
        .name = "debug/send_terminate_threads",
        .description = "Terminate specific threads",
        .input_schema = server.debug_terminate_threads_schema,
        .target_tool = "debug_terminate_threads",
        .inject_action = null,
    },
};

// ── Breakpoint variant schemas (action field removed) ───────────────────

const breakpoint_set_schema =
    \\{"type":"object","properties":{"session_id":{"type":"string"},"file":{"type":"string"},"line":{"type":"integer"},"condition":{"type":"string"},"hit_condition":{"type":"string"},"log_message":{"type":"string"}},"required":["session_id","file","line"]}
;

const breakpoint_set_function_schema =
    \\{"type":"object","properties":{"session_id":{"type":"string"},"function":{"type":"string"}},"required":["session_id","function"]}
;

const breakpoint_set_exception_schema =
    \\{"type":"object","properties":{"session_id":{"type":"string"},"filters":{"type":"array","items":{"type":"string"}}},"required":["session_id","filters"]}
;

const breakpoint_remove_schema =
    \\{"type":"object","properties":{"session_id":{"type":"string"},"id":{"type":"integer"}},"required":["session_id","id"]}
;

const breakpoint_list_schema =
    \\{"type":"object","properties":{"session_id":{"type":"string"}},"required":["session_id"]}
;

// ── MCP Client ──────────────────────────────────────────────────────────

pub const McpClient = struct {
    allocator: std.mem.Allocator,
    subprocess: ?std.process.Child = null,
    read_buffer: std.ArrayListUnmanaged(u8) = .empty,
    next_id: i64 = 1,

    pub fn init(allocator: std.mem.Allocator) McpClient {
        return .{
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *McpClient) void {
        self.killSubprocess();
        self.read_buffer.deinit(self.allocator);
    }

    // ── Subprocess Management ───────────────────────────────────────

    fn startSubprocess(self: *McpClient) !void {
        if (self.subprocess != null) return;

        var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
        const exe_path = try std.fs.selfExePath(&exe_buf);
        const exe_owned = try self.allocator.dupe(u8, exe_path);

        var child = std.process.Child.init(
            &.{ exe_owned, "debug/serve" },
            self.allocator,
        );
        child.stdin_behavior = .Pipe;
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Pipe;

        try child.spawn();

        self.allocator.free(exe_owned);
        self.subprocess = child;
    }

    fn killSubprocess(self: *McpClient) void {
        var child = self.subprocess orelse return;

        if (child.stdin) |*stdin| {
            stdin.close();
            child.stdin = null;
        }

        _ = child.kill() catch {};

        if (child.stdout) |*stdout| {
            stdout.close();
            child.stdout = null;
        }
        if (child.stderr) |*stderr| {
            stderr.close();
            child.stderr = null;
        }

        _ = child.wait() catch {};

        self.subprocess = null;
        self.read_buffer.items.len = 0;
    }

    /// Send the MCP initialize handshake to the subprocess.
    fn sendInitialize(self: *McpClient) !void {
        const request_id = self.next_id;
        self.next_id += 1;

        var aw: Writer.Allocating = .init(self.allocator);
        defer aw.deinit();
        var jw: Stringify = .{ .writer = &aw.writer };

        try jw.beginObject();
        try jw.objectField("jsonrpc");
        try jw.write("2.0");
        try jw.objectField("id");
        try jw.write(request_id);
        try jw.objectField("method");
        try jw.write("initialize");
        try jw.objectField("params");
        try jw.beginObject();
        try jw.objectField("protocolVersion");
        try jw.write("2024-11-05");
        try jw.objectField("capabilities");
        try jw.beginObject();
        try jw.endObject();
        try jw.objectField("clientInfo");
        try jw.beginObject();
        try jw.objectField("name");
        try jw.write("cog-debug-client");
        try jw.objectField("version");
        try jw.write("0.1.0");
        try jw.endObject();
        try jw.endObject();
        try jw.endObject();

        const envelope = try aw.toOwnedSlice();
        defer self.allocator.free(envelope);

        try self.writeToSubprocess(envelope);

        // Read and discard the initialize response
        const response_line = try self.readLineFromSubprocess();
        self.allocator.free(response_line);
    }

    // ── I/O Helpers ─────────────────────────────────────────────────

    fn writeToSubprocess(self: *McpClient, line: []const u8) !void {
        const child = &(self.subprocess orelse return error.SubprocessNotRunning);
        const stdin = child.stdin orelse return error.SubprocessNotRunning;
        var buf: [65536]u8 = undefined;
        var w = stdin.writer(&buf);
        w.interface.writeAll(line) catch return error.WriteFailed;
        w.interface.writeByte('\n') catch return error.WriteFailed;
        w.interface.flush() catch return error.WriteFailed;
    }

    fn readLineFromSubprocess(self: *McpClient) ![]const u8 {
        const child = &(self.subprocess orelse return error.SubprocessNotRunning);
        const stdout = child.stdout orelse return error.SubprocessNotRunning;
        var buf: [65536]u8 = undefined;
        var reader = stdout.reader(&buf);

        // Check if we already have a complete line in the buffer
        if (std.mem.indexOfScalar(u8, self.read_buffer.items, '\n')) |nl_pos| {
            const line = try self.allocator.dupe(u8, self.read_buffer.items[0..nl_pos]);
            const remaining = self.read_buffer.items.len - nl_pos - 1;
            if (remaining > 0) {
                std.mem.copyForwards(u8, self.read_buffer.items[0..remaining], self.read_buffer.items[nl_pos + 1 ..]);
            }
            self.read_buffer.items.len = remaining;
            return line;
        }

        // Read more data until we find a newline
        while (true) {
            const chunk = reader.interface.takeDelimiter('\n') catch |err| switch (err) {
                error.ReadFailed => return error.SubprocessClosed,
                error.StreamTooLong => return error.SubprocessClosed,
            } orelse return error.SubprocessClosed;

            if (chunk.len == 0) {
                if (self.read_buffer.items.len > 0) {
                    const line = try self.allocator.dupe(u8, self.read_buffer.items);
                    self.read_buffer.items.len = 0;
                    return line;
                }
                continue;
            }

            try self.read_buffer.appendSlice(self.allocator, chunk);

            const line = try self.allocator.dupe(u8, self.read_buffer.items);
            self.read_buffer.items.len = 0;
            return line;
        }
    }

    // ── MCP Server Loop ─────────────────────────────────────────────

    pub fn runStdio(self: *McpClient) !void {
        // Start the debug server subprocess and initialize it
        try self.startSubprocess();
        try self.sendInitialize();

        const stdin = std.fs.File.stdin();
        const stdout = std.fs.File.stdout();
        var reader_buf: [65536]u8 = undefined;
        var reader = stdin.reader(&reader_buf);

        while (true) {
            const line = reader.interface.takeDelimiter('\n') catch |err| switch (err) {
                error.ReadFailed => return,
                error.StreamTooLong => continue,
            } orelse return; // null = EOF

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
            defer parsed.deinit(self.allocator);

            const response = self.handleRequest(self.allocator, parsed.method, parsed.params, parsed.id) catch |err| blk: {
                break :blk formatJsonRpcError(self.allocator, parsed.id, INTERNAL_ERROR, @errorName(err)) catch continue;
            };
            defer self.allocator.free(response);

            var write_buf: [65536]u8 = undefined;
            var w = stdout.writer(&write_buf);
            w.interface.writeAll(response) catch {};
            w.interface.writeByte('\n') catch {};
            w.interface.flush() catch {};
        }
    }

    // ── Request Routing ─────────────────────────────────────────────

    fn handleRequest(self: *McpClient, allocator: std.mem.Allocator, method: []const u8, params: ?json.Value, id: ?json.Value) ![]const u8 {
        if (std.mem.eql(u8, method, "initialize")) {
            return handleInitialize(allocator, id);
        } else if (std.mem.eql(u8, method, "tools/list")) {
            return handleToolsList(allocator, id);
        } else if (std.mem.eql(u8, method, "tools/call")) {
            return self.handleToolsCall(allocator, params, id);
        } else if (std.mem.eql(u8, method, "notifications/initialized")) {
            return formatJsonRpcResponse(allocator, id, "null");
        } else {
            return formatJsonRpcError(allocator, id, METHOD_NOT_FOUND, "Method not found");
        }
    }

    fn handleInitialize(allocator: std.mem.Allocator, id: ?json.Value) ![]const u8 {
        const result =
            \\{"protocolVersion":"2024-11-05","capabilities":{"tools":{"listChanged":false}},"serverInfo":{"name":"cog-debug-client","version":"0.1.0"}}
        ;
        return formatJsonRpcResponse(allocator, id, result);
    }

    fn handleToolsList(allocator: std.mem.Allocator, id: ?json.Value) ![]const u8 {
        var aw: Writer.Allocating = .init(allocator);
        defer aw.deinit();

        try aw.writer.writeAll("{\"tools\":[");

        for (&client_tool_definitions, 0..) |*tool, i| {
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

    fn handleToolsCall(self: *McpClient, allocator: std.mem.Allocator, params: ?json.Value, id: ?json.Value) ![]const u8 {
        const p = params orelse return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Missing params");
        if (p != .object) return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Params must be object");

        const name_val = p.object.get("name") orelse return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Missing tool name");
        if (name_val != .string) return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Tool name must be string");
        const tool_name = name_val.string;

        const tool_args = p.object.get("arguments");

        inline for (&client_tool_definitions) |*def| {
            if (std.mem.eql(u8, tool_name, def.name)) {
                return self.handleGenericTool(allocator, def, tool_args, id);
            }
        }

        return formatJsonRpcError(allocator, id, METHOD_NOT_FOUND, "Unknown tool");
    }

    // ── Generic Tool Handler ────────────────────────────────────────

    fn handleGenericTool(
        self: *McpClient,
        allocator: std.mem.Allocator,
        comptime def: *const ClientToolDef,
        tool_args: ?json.Value,
        id: ?json.Value,
    ) ![]const u8 {
        const request_id = self.next_id;
        self.next_id += 1;

        // Build JSON-RPC envelope for the subprocess
        var aw: Writer.Allocating = .init(allocator);
        defer aw.deinit();
        var jw: Stringify = .{ .writer = &aw.writer };

        try jw.beginObject();
        try jw.objectField("jsonrpc");
        try jw.write("2.0");
        try jw.objectField("id");
        try jw.write(request_id);
        try jw.objectField("method");
        try jw.write("tools/call");
        try jw.objectField("params");
        try jw.beginObject();
        try jw.objectField("name");
        try jw.write(def.target_tool);
        try jw.objectField("arguments");
        try jw.beginObject();

        // Inject action field if needed
        if (def.inject_action) |action| {
            try jw.objectField("action");
            try jw.write(action);
        }

        // Copy all fields from tool_args
        if (tool_args) |args| {
            if (args == .object) {
                var it = args.object.iterator();
                while (it.next()) |entry| {
                    try jw.objectField(entry.key_ptr.*);
                    try jw.write(entry.value_ptr.*);
                }
            }
        }

        try jw.endObject(); // arguments
        try jw.endObject(); // params
        try jw.endObject(); // root

        const envelope = try aw.toOwnedSlice();
        defer allocator.free(envelope);

        // Send to subprocess and read response
        self.writeToSubprocess(envelope) catch |err| {
            return formatJsonRpcError(allocator, id, INTERNAL_ERROR, @errorName(err));
        };

        const response_line = self.readLineFromSubprocess() catch |err| {
            return formatJsonRpcError(allocator, id, INTERNAL_ERROR, @errorName(err));
        };
        defer allocator.free(response_line);

        return wrapAsToolResult(allocator, id, response_line);
    }
};

// ── Helpers ─────────────────────────────────────────────────────────────

/// Wrap a raw subprocess response as an MCP tool result content block.
fn wrapAsToolResult(allocator: std.mem.Allocator, id: ?json.Value, raw_response: []const u8) ![]const u8 {
    var aw: Writer.Allocating = .init(allocator);
    defer aw.deinit();
    var jw: Stringify = .{ .writer = &aw.writer };

    try jw.beginObject();
    try jw.objectField("content");
    try jw.beginArray();
    try jw.beginObject();
    try jw.objectField("type");
    try jw.write("text");
    try jw.objectField("text");
    try jw.write(raw_response);
    try jw.endObject();
    try jw.endArray();
    try jw.endObject();

    const result = try aw.toOwnedSlice();
    defer allocator.free(result);
    return formatJsonRpcResponse(allocator, id, result);
}

// ── Tests ───────────────────────────────────────────────────────────────

test "client tool table has 38 entries" {
    try std.testing.expectEqual(@as(usize, 38), client_tool_definitions.len);
}

test "handleInitialize returns valid response" {
    const allocator = std.testing.allocator;
    const response = try McpClient.handleInitialize(allocator, null);
    defer allocator.free(response);

    try std.testing.expect(std.mem.indexOf(u8, response, "cog-debug-client") != null);
}

test "handleToolsList returns 38 tools" {
    const allocator = std.testing.allocator;

    const response = try McpClient.handleToolsList(allocator, null);
    defer allocator.free(response);

    try std.testing.expect(std.mem.indexOf(u8, response, "debug/send_launch") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "debug/send_breakpoint_set") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "debug/send_run") != null);
    // Lifecycle tools should NOT be present
    try std.testing.expect(std.mem.indexOf(u8, response, "\"debug/server\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"debug/kill\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"debug/send_init\"") == null);
}

test "wrapAsToolResult produces valid content block" {
    const allocator = std.testing.allocator;
    const raw = "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}}";
    const result = try wrapAsToolResult(allocator, null, raw);
    defer allocator.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, "\"content\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"type\":\"text\"") != null);
}
