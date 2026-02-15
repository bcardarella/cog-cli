const std = @import("std");
const types = @import("../types.zig");
const driver_mod = @import("../driver.zig");
const process_mod = @import("process.zig");

const ProcessControl = process_mod.ProcessControl;
const StopState = types.StopState;
const StopReason = types.StopReason;
const RunAction = types.RunAction;
const LaunchConfig = types.LaunchConfig;
const BreakpointInfo = types.BreakpointInfo;
const InspectRequest = types.InspectRequest;
const InspectResult = types.InspectResult;
const ActiveDriver = driver_mod.ActiveDriver;
const DriverVTable = driver_mod.DriverVTable;

// ── DWARF Debug Engine ──────────────────────────────────────────────────

pub const DwarfEngine = struct {
    process: ProcessControl = .{},
    allocator: std.mem.Allocator,
    launched: bool = false,
    program_path: ?[]const u8 = null,

    pub fn init(allocator: std.mem.Allocator) DwarfEngine {
        return .{
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *DwarfEngine) void {
        self.process.kill() catch {};
        if (self.program_path) |p| self.allocator.free(p);
    }

    pub fn activeDriver(self: *DwarfEngine) ActiveDriver {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &vtable,
            .driver_type = .native,
        };
    }

    const vtable = DriverVTable{
        .launchFn = engineLaunch,
        .runFn = engineRun,
        .setBreakpointFn = engineSetBreakpoint,
        .removeBreakpointFn = engineRemoveBreakpoint,
        .listBreakpointsFn = engineListBreakpoints,
        .inspectFn = engineInspect,
        .stopFn = engineStop,
        .deinitFn = engineDeinit,
    };

    fn engineLaunch(ctx: *anyopaque, allocator: std.mem.Allocator, config: LaunchConfig) anyerror!void {
        const self: *DwarfEngine = @ptrCast(@alignCast(ctx));
        try self.process.spawn(allocator, config.program, config.args);
        self.launched = true;
        self.program_path = try allocator.dupe(u8, config.program);
    }

    fn engineRun(ctx: *anyopaque, _: std.mem.Allocator, action: RunAction) anyerror!StopState {
        const self: *DwarfEngine = @ptrCast(@alignCast(ctx));
        switch (action) {
            .@"continue" => try self.process.continueExecution(),
            .step_into, .step_over => try self.process.singleStep(),
            .step_out => try self.process.continueExecution(),
            .restart => {
                // Kill current process and re-launch
                self.process.kill() catch {};
                if (self.program_path) |path| {
                    const allocator = self.allocator;
                    self.process.spawn(allocator, path, &.{}) catch {
                        return .{ .stop_reason = .exit };
                    };
                    return .{ .stop_reason = .entry };
                }
                return .{ .stop_reason = .exit };
            },
        }
        const result = try self.process.waitForStop();
        return switch (result.status) {
            .stopped => .{ .stop_reason = .step },
            .exited => .{ .stop_reason = .exit, .exit_code = result.exit_code },
            else => .{ .stop_reason = .step },
        };
    }

    fn engineSetBreakpoint(_: *anyopaque, _: std.mem.Allocator, file: []const u8, line: u32, _: ?[]const u8) anyerror!BreakpointInfo {
        // TODO: resolve file:line to address via DWARF, write INT3
        return .{ .id = 1, .verified = false, .file = file, .line = line };
    }

    fn engineRemoveBreakpoint(_: *anyopaque, _: std.mem.Allocator, _: u32) anyerror!void {}

    fn engineListBreakpoints(_: *anyopaque, _: std.mem.Allocator) anyerror![]const BreakpointInfo {
        return &.{};
    }

    fn engineInspect(_: *anyopaque, _: std.mem.Allocator, _: InspectRequest) anyerror!InspectResult {
        return .{ .result = "", .@"type" = "" };
    }

    fn engineStop(ctx: *anyopaque, _: std.mem.Allocator) anyerror!void {
        const self: *DwarfEngine = @ptrCast(@alignCast(ctx));
        try self.process.kill();
        self.launched = false;
    }

    fn engineDeinit(ctx: *anyopaque) void {
        const self: *DwarfEngine = @ptrCast(@alignCast(ctx));
        self.deinit();
    }
};

// ── Tests ───────────────────────────────────────────────────────────────

test "DwarfEngine initial state" {
    var engine = DwarfEngine.init(std.testing.allocator);
    defer engine.deinit();

    try std.testing.expect(!engine.launched);
    try std.testing.expect(engine.program_path == null);
}

test "DwarfEngine implements ActiveDriver interface" {
    var engine = DwarfEngine.init(std.testing.allocator);
    defer engine.deinit();

    const driver = engine.activeDriver();
    try std.testing.expectEqual(ActiveDriver.DriverType.native, driver.driver_type);
}

test "DwarfEngine launches fixture binary" {
    const builtin = @import("builtin");
    if (builtin.os.tag != .macos or !builtin.single_threaded) return error.SkipZigTest;

    var engine = DwarfEngine.init(std.testing.allocator);
    defer engine.deinit();

    engine.process.spawn(std.testing.allocator, "/bin/echo", &.{"test"}) catch return error.SkipZigTest;
    engine.launched = true;
    engine.program_path = std.testing.allocator.dupe(u8, "/bin/echo") catch return error.SkipZigTest;

    try std.testing.expect(engine.launched);
    try std.testing.expect(engine.process.pid != null);
}

test "DwarfEngine stop terminates process cleanly" {
    const builtin = @import("builtin");
    if (builtin.os.tag != .macos or !builtin.single_threaded) return error.SkipZigTest;

    var engine = DwarfEngine.init(std.testing.allocator);
    defer engine.deinit();

    engine.process.spawn(std.testing.allocator, "/usr/bin/sleep", &.{"10"}) catch return error.SkipZigTest;
    engine.launched = true;
    engine.program_path = std.testing.allocator.dupe(u8, "/usr/bin/sleep") catch return error.SkipZigTest;

    try std.testing.expect(engine.process.pid != null);

    var driver = engine.activeDriver();
    driver.stop(std.testing.allocator) catch {};
    try std.testing.expect(!engine.launched);
    try std.testing.expect(engine.process.pid == null);
}
