pub const types = @import("debug/types.zig");
pub const driver = @import("debug/driver.zig");
pub const session = @import("debug/session.zig");
pub const server = @import("debug/server.zig");
pub const dap_protocol = @import("debug/dap/protocol.zig");
pub const dap_transport = @import("debug/dap/transport.zig");
pub const dap_proxy = @import("debug/dap/proxy.zig");
pub const dap_sandbox = @import("debug/dap/sandbox.zig");
pub const dwarf_process = @import("debug/dwarf/process.zig");
pub const dwarf_engine = @import("debug/dwarf/engine.zig");
pub const dwarf_binary_macho = @import("debug/dwarf/binary_macho.zig");
pub const dwarf_binary_elf = @import("debug/dwarf/binary_elf.zig");
pub const dwarf_parser = @import("debug/dwarf/parser.zig");
pub const stack_merge = @import("debug/stack_merge.zig");
pub const dwarf_breakpoints = @import("debug/dwarf/breakpoints.zig");
pub const dwarf_unwind = @import("debug/dwarf/unwind.zig");
pub const dwarf_location = @import("debug/dwarf/location.zig");

const std = @import("std");
const help = @import("help_text.zig");
const tui = @import("tui.zig");

// ANSI styles
const dim = "\x1B[2m";
const reset = "\x1B[0m";

fn printErr(msg: []const u8) void {
    if (@import("builtin").is_test) return;
    var buf: [4096]u8 = undefined;
    var w = std.fs.File.stderr().writer(&buf);
    w.interface.writeAll(msg) catch {};
    w.interface.flush() catch {};
}

fn printCommandHelp(comptime help_text: []const u8) void {
    tui.header();
    printErr(help_text);
}

/// Dispatch debug subcommands.
pub fn dispatch(allocator: std.mem.Allocator, subcmd: []const u8, args: []const [:0]const u8) !void {
    if (std.mem.eql(u8, subcmd, "debug/serve")) return debugServe(allocator, args);

    printErr("error: unknown command '");
    printErr(subcmd);
    printErr("'\nRun " ++ dim ++ "cog --help" ++ reset ++ " to see available commands.\n");
    return error.Explained;
}

fn hasFlag(args: []const [:0]const u8, flag: []const u8) bool {
    for (args) |arg| {
        if (std.mem.eql(u8, arg, flag)) return true;
    }
    return false;
}

fn debugServe(allocator: std.mem.Allocator, args: []const [:0]const u8) !void {
    if (hasFlag(args, "--help") or hasFlag(args, "-h")) {
        printCommandHelp(help.debug_serve);
        return;
    }

    var mcp_server = server.McpServer.init(allocator);
    defer mcp_server.deinit();

    try mcp_server.runStdio();
}

test {
    _ = types;
    _ = driver;
    _ = session;
    _ = server;
    _ = dap_protocol;
    _ = dap_transport;
    _ = dap_proxy;
    _ = dap_sandbox;
    _ = dwarf_process;
    _ = dwarf_engine;
    _ = dwarf_binary_macho;
    _ = dwarf_binary_elf;
    _ = dwarf_parser;
    _ = stack_merge;
    _ = dwarf_breakpoints;
    _ = dwarf_unwind;
    _ = dwarf_location;
}

test "cog debug routes to debug dispatch" {
    // Test that the dispatch function correctly identifies the debug/serve command
    // (without actually starting the server which would block)
    const allocator = std.testing.allocator;

    // An unknown debug subcommand should return Explained error
    const result = dispatch(allocator, "debug/unknown", &.{});
    try std.testing.expectError(error.Explained, result);
}

test "cog debug serve --help prints debug help" {
    // Calling debug/serve with --help should print help and return without error
    const allocator = std.testing.allocator;
    const args = [_][:0]const u8{"--help"};
    // This should not error — it prints help text and returns
    try dispatch(allocator, "debug/serve", &args);
}
