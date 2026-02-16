const std = @import("std");
const builtin = @import("builtin");
const types = @import("../types.zig");
const driver_mod = @import("../driver.zig");
const process_mod = @import("process.zig");
const breakpoint_mod = @import("breakpoints.zig");
const binary_macho = @import("binary_macho.zig");
const parser = @import("parser.zig");

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
const BreakpointManager = breakpoint_mod.BreakpointManager;

// ── DWARF Debug Engine ──────────────────────────────────────────────────

pub const DwarfEngine = struct {
    process: ProcessControl = .{},
    allocator: std.mem.Allocator,
    launched: bool = false,
    program_path: ?[]const u8 = null,
    bp_manager: BreakpointManager,
    line_entries: []parser.LineEntry = &.{},
    binary: ?binary_macho.MachoBinary = null,
    /// Track whether we just hit a breakpoint and need to step past it
    stepping_past_bp: ?u64 = null,

    pub fn init(allocator: std.mem.Allocator) DwarfEngine {
        return .{
            .allocator = allocator,
            .bp_manager = BreakpointManager.init(allocator),
        };
    }

    pub fn deinit(self: *DwarfEngine) void {
        self.process.kill() catch {};
        if (self.program_path) |p| self.allocator.free(p);
        self.bp_manager.deinit();
        if (self.line_entries.len > 0) self.allocator.free(self.line_entries);
        if (self.binary) |*b| b.deinit(self.allocator);
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

    // ── Launch ──────────────────────────────────────────────────────

    fn engineLaunch(ctx: *anyopaque, allocator: std.mem.Allocator, config: LaunchConfig) anyerror!void {
        const self: *DwarfEngine = @ptrCast(@alignCast(ctx));
        try self.process.spawn(allocator, config.program, config.args);
        self.launched = true;
        self.program_path = try allocator.dupe(u8, config.program);

        // Load binary and parse DWARF line tables for breakpoint resolution
        self.loadDebugInfo(config.program) catch {};

        // Compute ASLR slide and adjust line entry addresses
        self.applyAslrSlide() catch {};
    }

    fn applyAslrSlide(self: *DwarfEngine) !void {
        if (self.line_entries.len == 0) return;
        const binary = self.binary orelse return;
        if (binary.text_vmaddr == 0) return;

        const actual_base = self.process.getTextBase() catch return;
        if (actual_base == binary.text_vmaddr) return; // no slide

        const slide: i64 = @as(i64, @intCast(actual_base)) - @as(i64, @intCast(binary.text_vmaddr));

        for (self.line_entries) |*entry| {
            if (slide > 0) {
                entry.address +%= @intCast(@as(u64, @intCast(slide)));
            } else {
                entry.address -%= @intCast(@as(u64, @intCast(-slide)));
            }
        }
    }

    fn loadDebugInfo(self: *DwarfEngine, program: []const u8) !void {
        if (builtin.os.tag != .macos) return;

        var binary = binary_macho.MachoBinary.loadFile(self.allocator, program) catch return;
        errdefer binary.deinit(self.allocator);

        // Try loading debug_line from the binary itself
        if (binary.sections.debug_line) |line_section| {
            if (binary.getSectionData(line_section)) |line_data| {
                const entries = parser.parseLineProgram(line_data, self.allocator) catch return;
                if (entries.len > 0) {
                    self.line_entries = entries;
                }
            }
        }

        // Fallback: on macOS, Apple clang stores DWARF in a .dSYM bundle
        if (self.line_entries.len == 0) {
            self.loadDsymDebugInfo(program) catch {};
        }

        self.binary = binary;
    }

    fn loadDsymDebugInfo(self: *DwarfEngine, program: []const u8) !void {
        // dSYM path: <program>.dSYM/Contents/Resources/DWARF/<basename>
        const basename = std.fs.path.basename(program);

        const dsym_path = try std.fmt.allocPrint(
            self.allocator,
            "{s}.dSYM/Contents/Resources/DWARF/{s}",
            .{ program, basename },
        );
        defer self.allocator.free(dsym_path);

        var dsym_binary = binary_macho.MachoBinary.loadFile(self.allocator, dsym_path) catch return;
        defer dsym_binary.deinit(self.allocator);

        if (dsym_binary.sections.debug_line) |line_section| {
            if (dsym_binary.getSectionData(line_section)) |line_data| {
                const entries = parser.parseLineProgram(line_data, self.allocator) catch return;
                if (entries.len > 0) {
                    self.line_entries = entries;
                }
            }
        }
    }

    // ── Run ─────────────────────────────────────────────────────────

    fn engineRun(ctx: *anyopaque, _: std.mem.Allocator, action: RunAction) anyerror!StopState {
        const self: *DwarfEngine = @ptrCast(@alignCast(ctx));
        switch (action) {
            .@"continue" => {
                // If we're stopped at a breakpoint, step past it first
                if (self.stepping_past_bp) |bp_addr| {
                    try self.stepPastBreakpoint(bp_addr);
                    self.stepping_past_bp = null;
                }
                try self.process.continueExecution();
            },
            .step_into, .step_over => try self.process.singleStep(),
            .step_out => {
                if (self.stepping_past_bp) |bp_addr| {
                    try self.stepPastBreakpoint(bp_addr);
                    self.stepping_past_bp = null;
                }
                try self.process.continueExecution();
            },
            .restart => {
                self.process.kill() catch {};
                if (self.program_path) |path| {
                    self.process.spawn(self.allocator, path, &.{}) catch {
                        return .{ .stop_reason = .exit };
                    };
                    // Re-arm all breakpoints in the new process
                    self.rearmAllBreakpoints();
                    return .{ .stop_reason = .entry };
                }
                return .{ .stop_reason = .exit };
            },
        }

        const result = try self.process.waitForStop();
        return switch (result.status) {
            .stopped => self.handleStop(result.signal),
            .exited => .{ .stop_reason = .exit, .exit_code = result.exit_code },
            else => .{ .stop_reason = .step },
        };
    }

    fn handleStop(self: *DwarfEngine, signal: i32) StopState {
        const SIGTRAP = 5;
        if (signal != SIGTRAP) {
            return .{ .stop_reason = .step };
        }

        // Read PC to check if we hit a breakpoint
        const regs = self.process.readRegisters() catch {
            return .{ .stop_reason = .step };
        };

        // On x86_64, after INT3, RIP points past the 0xCC byte, so bp address is RIP-1
        // On ARM64, after BRK, PC points at the BRK instruction itself
        const is_arm = builtin.cpu.arch == .aarch64;
        const bp_addr = if (is_arm) regs.rip else regs.rip - 1;

        if (self.bp_manager.findByAddress(bp_addr)) |bp| {
            // We hit a breakpoint!
            bp.hit_count += 1;

            // Rewind PC to the breakpoint address (before INT3)
            if (!is_arm) {
                var new_regs = regs;
                new_regs.rip = bp_addr;
                self.process.writeRegisters(new_regs) catch {};
            }

            // Mark that we need to step past this breakpoint on next continue
            self.stepping_past_bp = bp_addr;

            // Build location from breakpoint info
            return .{
                .stop_reason = .breakpoint,
                .location = .{
                    .file = bp.file,
                    .line = bp.line,
                },
            };
        }

        return .{ .stop_reason = .step };
    }

    fn stepPastBreakpoint(self: *DwarfEngine, bp_addr: u64) !void {
        if (self.bp_manager.findByAddress(bp_addr)) |bp| {
            // 1. Restore original bytes
            try self.process.writeMemory(bp_addr, &bp.original_bytes);

            // 2. Single-step past the original instruction
            try self.process.singleStep();
            _ = try self.process.waitForStop();

            // 3. Re-insert trap instruction
            try self.process.writeMemory(bp_addr, breakpoint_mod.trap_instruction);
        }
    }

    fn rearmAllBreakpoints(self: *DwarfEngine) void {
        for (self.bp_manager.breakpoints.items) |*bp| {
            if (bp.enabled) {
                self.bp_manager.writeBreakpoint(bp.id, &self.process) catch {};
            }
        }
    }

    // ── Breakpoints ─────────────────────────────────────────────────

    fn engineSetBreakpoint(ctx: *anyopaque, _: std.mem.Allocator, file: []const u8, line: u32, condition: ?[]const u8) anyerror!BreakpointInfo {
        const self: *DwarfEngine = @ptrCast(@alignCast(ctx));

        if (self.line_entries.len > 0) {
            // Resolve file:line to address via DWARF line table
            const bp = try self.bp_manager.resolveAndSet(file, line, self.line_entries, condition);

            // Write INT3 into the process
            self.bp_manager.writeBreakpoint(bp.id, &self.process) catch |err| {
                // If write fails, remove the breakpoint and propagate
                self.bp_manager.remove(bp.id) catch {};
                return err;
            };

            return .{
                .id = bp.id,
                .verified = true,
                .file = bp.file,
                .line = bp.line,
                .condition = condition,
            };
        }

        // No debug info — return unverified breakpoint
        return .{ .id = 0, .verified = false, .file = file, .line = line };
    }

    fn engineRemoveBreakpoint(ctx: *anyopaque, _: std.mem.Allocator, id: u32) anyerror!void {
        const self: *DwarfEngine = @ptrCast(@alignCast(ctx));
        self.bp_manager.removeBreakpoint(id, &self.process) catch {
            // If process write fails, at least remove from list
            self.bp_manager.remove(id) catch {};
        };
    }

    fn engineListBreakpoints(ctx: *anyopaque, allocator: std.mem.Allocator) anyerror![]const BreakpointInfo {
        const self: *DwarfEngine = @ptrCast(@alignCast(ctx));
        const bps = self.bp_manager.list();
        if (bps.len == 0) return &.{};

        const result = try allocator.alloc(BreakpointInfo, bps.len);
        for (bps, 0..) |bp, i| {
            result[i] = .{
                .id = bp.id,
                .verified = bp.enabled,
                .file = bp.file,
                .line = bp.line,
                .condition = bp.condition,
            };
        }
        return result;
    }

    // ── Inspect ─────────────────────────────────────────────────────

    fn engineInspect(_: *anyopaque, _: std.mem.Allocator, _: InspectRequest) anyerror!InspectResult {
        // TODO: evaluate expressions using DWARF location info + process memory
        return .{ .result = "", .@"type" = "" };
    }

    // ── Stop ────────────────────────────────────────────────────────

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
    try std.testing.expectEqual(@as(usize, 0), engine.bp_manager.list().len);
}

test "DwarfEngine implements ActiveDriver interface" {
    var engine = DwarfEngine.init(std.testing.allocator);
    defer engine.deinit();

    const driver = engine.activeDriver();
    try std.testing.expectEqual(ActiveDriver.DriverType.native, driver.driver_type);
}

test "DwarfEngine launches fixture binary" {
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

test "DwarfEngine setBreakpoint without debug info returns unverified" {
    var engine = DwarfEngine.init(std.testing.allocator);
    defer engine.deinit();

    // No binary loaded, no line entries — use the vtable via activeDriver
    var driver = engine.activeDriver();
    const bp = try driver.setBreakpoint(std.testing.allocator, "test.c", 10, null);
    try std.testing.expect(!bp.verified);
}
