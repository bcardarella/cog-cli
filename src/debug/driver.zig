const std = @import("std");
const types = @import("types.zig");

const StopState = types.StopState;
const RunAction = types.RunAction;
const LaunchConfig = types.LaunchConfig;
const BreakpointInfo = types.BreakpointInfo;
const InspectRequest = types.InspectRequest;
const InspectResult = types.InspectResult;

/// Interface that all debug drivers must implement.
/// Both DwarfEngine and DapProxy provide these methods.
pub const DriverVTable = struct {
    launchFn: *const fn (ctx: *anyopaque, allocator: std.mem.Allocator, config: LaunchConfig) anyerror!void,
    runFn: *const fn (ctx: *anyopaque, allocator: std.mem.Allocator, action: RunAction) anyerror!StopState,
    setBreakpointFn: *const fn (ctx: *anyopaque, allocator: std.mem.Allocator, file: []const u8, line: u32, condition: ?[]const u8) anyerror!BreakpointInfo,
    removeBreakpointFn: *const fn (ctx: *anyopaque, allocator: std.mem.Allocator, id: u32) anyerror!void,
    listBreakpointsFn: *const fn (ctx: *anyopaque, allocator: std.mem.Allocator) anyerror![]const BreakpointInfo,
    inspectFn: *const fn (ctx: *anyopaque, allocator: std.mem.Allocator, request: InspectRequest) anyerror!InspectResult,
    stopFn: *const fn (ctx: *anyopaque, allocator: std.mem.Allocator) anyerror!void,
    deinitFn: *const fn (ctx: *anyopaque) void,
};

/// Runtime-polymorphic debug driver.
/// Wraps either a native DWARF engine or a DAP proxy.
pub const ActiveDriver = struct {
    ptr: *anyopaque,
    vtable: *const DriverVTable,
    driver_type: DriverType,

    pub const DriverType = enum {
        native,
        dap,
    };

    pub fn launch(self: *ActiveDriver, allocator: std.mem.Allocator, config: LaunchConfig) !void {
        return self.vtable.launchFn(self.ptr, allocator, config);
    }

    pub fn run(self: *ActiveDriver, allocator: std.mem.Allocator, action: RunAction) !StopState {
        return self.vtable.runFn(self.ptr, allocator, action);
    }

    pub fn setBreakpoint(self: *ActiveDriver, allocator: std.mem.Allocator, file: []const u8, line: u32, condition: ?[]const u8) !BreakpointInfo {
        return self.vtable.setBreakpointFn(self.ptr, allocator, file, line, condition);
    }

    pub fn removeBreakpoint(self: *ActiveDriver, allocator: std.mem.Allocator, id: u32) !void {
        return self.vtable.removeBreakpointFn(self.ptr, allocator, id);
    }

    pub fn listBreakpoints(self: *ActiveDriver, allocator: std.mem.Allocator) ![]const BreakpointInfo {
        return self.vtable.listBreakpointsFn(self.ptr, allocator);
    }

    pub fn inspect(self: *ActiveDriver, allocator: std.mem.Allocator, request: InspectRequest) !InspectResult {
        return self.vtable.inspectFn(self.ptr, allocator, request);
    }

    pub fn stop(self: *ActiveDriver, allocator: std.mem.Allocator) !void {
        return self.vtable.stopFn(self.ptr, allocator);
    }

    pub fn deinit(self: *ActiveDriver) void {
        self.vtable.deinitFn(self.ptr);
    }
};

// ── Mock Driver for Testing ─────────────────────────────────────────────

pub const MockDriver = struct {
    launched: bool = false,
    stopped: bool = false,
    run_count: u32 = 0,
    breakpoint_count: u32 = 0,

    pub fn activeDriver(self: *MockDriver) ActiveDriver {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &vtable,
            .driver_type = .dap,
        };
    }

    const vtable = DriverVTable{
        .launchFn = mockLaunch,
        .runFn = mockRun,
        .setBreakpointFn = mockSetBreakpoint,
        .removeBreakpointFn = mockRemoveBreakpoint,
        .listBreakpointsFn = mockListBreakpoints,
        .inspectFn = mockInspect,
        .stopFn = mockStop,
        .deinitFn = mockDeinit,
    };

    fn mockLaunch(ctx: *anyopaque, _: std.mem.Allocator, _: LaunchConfig) anyerror!void {
        const self: *MockDriver = @ptrCast(@alignCast(ctx));
        self.launched = true;
    }

    fn mockRun(ctx: *anyopaque, _: std.mem.Allocator, _: RunAction) anyerror!StopState {
        const self: *MockDriver = @ptrCast(@alignCast(ctx));
        self.run_count += 1;
        return .{ .stop_reason = .step };
    }

    fn mockSetBreakpoint(ctx: *anyopaque, _: std.mem.Allocator, file: []const u8, line: u32, _: ?[]const u8) anyerror!BreakpointInfo {
        const self: *MockDriver = @ptrCast(@alignCast(ctx));
        self.breakpoint_count += 1;
        return .{
            .id = self.breakpoint_count,
            .verified = true,
            .file = file,
            .line = line,
        };
    }

    fn mockRemoveBreakpoint(_: *anyopaque, _: std.mem.Allocator, _: u32) anyerror!void {}

    fn mockListBreakpoints(_: *anyopaque, _: std.mem.Allocator) anyerror![]const BreakpointInfo {
        return &.{};
    }

    fn mockInspect(_: *anyopaque, _: std.mem.Allocator, _: InspectRequest) anyerror!InspectResult {
        return .{ .result = "42", .@"type" = "int" };
    }

    fn mockStop(ctx: *anyopaque, _: std.mem.Allocator) anyerror!void {
        const self: *MockDriver = @ptrCast(@alignCast(ctx));
        self.stopped = true;
    }

    fn mockDeinit(_: *anyopaque) void {}
};

// ── Tests ───────────────────────────────────────────────────────────────

test "MockDriver implements ActiveDriver interface" {
    var mock = MockDriver{};
    var driver = mock.activeDriver();

    try driver.launch(std.testing.allocator, .{ .program = "test" });
    try std.testing.expect(mock.launched);

    const state = try driver.run(std.testing.allocator, .@"continue");
    try std.testing.expectEqual(types.StopReason.step, state.stop_reason);
    try std.testing.expectEqual(@as(u32, 1), mock.run_count);

    const bp = try driver.setBreakpoint(std.testing.allocator, "test.py", 10, null);
    try std.testing.expectEqual(@as(u32, 1), bp.id);
    try std.testing.expect(bp.verified);

    try driver.stop(std.testing.allocator);
    try std.testing.expect(mock.stopped);

    driver.deinit();
}
