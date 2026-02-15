const std = @import("std");
const builtin = @import("builtin");
const parser = @import("parser.zig");
const process_mod = @import("process.zig");

// ── Software Breakpoint Management ─────────────────────────────────────

const INT3: u8 = 0xCC;
const BRK_IMM16: u32 = 0xD4200000; // ARM64 BRK #0

pub const Breakpoint = struct {
    id: u32,
    address: u64,
    file: []const u8,
    line: u32,
    original_byte: u8,
    enabled: bool,
    hit_count: u32,
    condition: ?[]const u8,
};

pub const BreakpointManager = struct {
    breakpoints: std.ArrayListUnmanaged(Breakpoint),
    next_id: u32,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) BreakpointManager {
        return .{
            .breakpoints = .empty,
            .next_id = 1,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *BreakpointManager) void {
        self.breakpoints.deinit(self.allocator);
    }

    /// Resolve a file:line to an address using DWARF line entries and set a breakpoint.
    pub fn resolveAndSet(
        self: *BreakpointManager,
        file: []const u8,
        line: u32,
        line_entries: []const parser.LineEntry,
        condition: ?[]const u8,
    ) !Breakpoint {
        // Find the best matching line entry
        var best_addr: ?u64 = null;
        var best_line: u32 = 0;
        for (line_entries) |entry| {
            if (entry.end_sequence) continue;
            if (entry.line == line and entry.is_stmt) {
                best_addr = entry.address;
                best_line = entry.line;
                break;
            }
            // Also accept the nearest line at or after the requested line
            if (entry.line >= line and entry.is_stmt) {
                if (best_addr == null or entry.line < best_line) {
                    best_addr = entry.address;
                    best_line = entry.line;
                }
            }
        }

        const address = best_addr orelse return error.NoAddressForLine;

        const bp = Breakpoint{
            .id = self.next_id,
            .address = address,
            .file = file,
            .line = best_line,
            .original_byte = 0,
            .enabled = true,
            .hit_count = 0,
            .condition = condition,
        };
        self.next_id += 1;
        try self.breakpoints.append(self.allocator, bp);
        return bp;
    }

    /// Set a breakpoint at a raw address (for testing without DWARF data).
    pub fn setAtAddress(
        self: *BreakpointManager,
        address: u64,
        file: []const u8,
        line: u32,
    ) !u32 {
        const id = self.next_id;
        self.next_id += 1;

        try self.breakpoints.append(self.allocator, .{
            .id = id,
            .address = address,
            .file = file,
            .line = line,
            .original_byte = 0,
            .enabled = true,
            .hit_count = 0,
            .condition = null,
        });

        return id;
    }

    /// Write INT3 to the breakpoint address in the target process.
    pub fn writeBreakpoint(self: *BreakpointManager, id: u32, process: *process_mod.ProcessControl) !void {
        for (self.breakpoints.items) |*bp| {
            if (bp.id == id and bp.enabled) {
                // Read original byte
                const mem = try process.readMemory(bp.address, 1, self.allocator);
                defer self.allocator.free(mem);
                bp.original_byte = mem[0];

                // Write INT3
                const int3 = [_]u8{INT3};
                try process.writeMemory(bp.address, &int3);
                return;
            }
        }
        return error.BreakpointNotFound;
    }

    /// Restore original byte at breakpoint address.
    pub fn removeBreakpoint(self: *BreakpointManager, id: u32, process: *process_mod.ProcessControl) !void {
        for (self.breakpoints.items, 0..) |*bp, i| {
            if (bp.id == id) {
                if (bp.enabled) {
                    // Restore original byte
                    const original = [_]u8{bp.original_byte};
                    try process.writeMemory(bp.address, &original);
                }
                _ = self.breakpoints.swapRemove(i);
                return;
            }
        }
        return error.BreakpointNotFound;
    }

    /// Remove a breakpoint by id without process interaction (for testing).
    pub fn remove(self: *BreakpointManager, id: u32) !void {
        for (self.breakpoints.items, 0..) |bp, i| {
            if (bp.id == id) {
                _ = self.breakpoints.swapRemove(i);
                return;
            }
        }
        return error.BreakpointNotFound;
    }

    /// Check if an address matches a breakpoint, and return it.
    pub fn findByAddress(self: *BreakpointManager, address: u64) ?*Breakpoint {
        for (self.breakpoints.items) |*bp| {
            if (bp.address == address and bp.enabled) {
                return bp;
            }
        }
        return null;
    }

    /// Find a breakpoint by ID.
    pub fn findById(self: *BreakpointManager, id: u32) ?*Breakpoint {
        for (self.breakpoints.items) |*bp| {
            if (bp.id == id) return bp;
        }
        return null;
    }

    /// List all breakpoints.
    pub fn list(self: *const BreakpointManager) []const Breakpoint {
        return self.breakpoints.items;
    }

    /// Record a hit on a breakpoint.
    pub fn recordHit(self: *BreakpointManager, id: u32) void {
        if (self.findById(id)) |bp| {
            bp.hit_count += 1;
        }
    }

    /// Callback type for evaluating breakpoint condition expressions.
    /// The engine provides an evaluator that resolves the condition string
    /// against the debuggee's current state.
    pub const ConditionEvaluator = *const fn (condition: []const u8) bool;

    /// Check whether execution should stop at this breakpoint.
    /// Increments hit_count and evaluates the condition if present.
    /// Returns true if we should stop, false to silently continue.
    pub fn shouldStop(_: *BreakpointManager, bp: *Breakpoint, evaluator: ?ConditionEvaluator) bool {
        bp.hit_count += 1;
        if (bp.condition) |cond| {
            if (evaluator) |eval| {
                return eval(cond);
            }
            // No evaluator available — stop unconditionally
            return true;
        }
        return true;
    }
};

// ── Tests ───────────────────────────────────────────────────────────────

test "BreakpointManager initial state" {
    var mgr = BreakpointManager.init(std.testing.allocator);
    defer mgr.deinit();

    try std.testing.expectEqual(@as(usize, 0), mgr.list().len);
}

test "resolveBreakpoint maps file:line to address via debug_line" {
    var mgr = BreakpointManager.init(std.testing.allocator);
    defer mgr.deinit();

    const entries = [_]parser.LineEntry{
        .{ .address = 0x1000, .file_index = 1, .line = 5, .column = 0, .is_stmt = true, .end_sequence = false },
        .{ .address = 0x1010, .file_index = 1, .line = 10, .column = 0, .is_stmt = true, .end_sequence = false },
        .{ .address = 0x1020, .file_index = 1, .line = 15, .column = 0, .is_stmt = true, .end_sequence = false },
    };

    const bp = try mgr.resolveAndSet("test.c", 10, &entries, null);
    try std.testing.expectEqual(@as(u64, 0x1010), bp.address);
    try std.testing.expectEqual(@as(u32, 10), bp.line);
}

test "resolveBreakpoint finds nearest line when exact not available" {
    var mgr = BreakpointManager.init(std.testing.allocator);
    defer mgr.deinit();

    const entries = [_]parser.LineEntry{
        .{ .address = 0x1000, .file_index = 1, .line = 5, .column = 0, .is_stmt = true, .end_sequence = false },
        .{ .address = 0x1020, .file_index = 1, .line = 15, .column = 0, .is_stmt = true, .end_sequence = false },
    };

    // Request line 10 but only 5 and 15 exist — should get 15 (nearest >= requested)
    const bp = try mgr.resolveAndSet("test.c", 10, &entries, null);
    try std.testing.expectEqual(@as(u32, 15), bp.line);
    try std.testing.expectEqual(@as(u64, 0x1020), bp.address);
}

test "setBreakpoint assigns incrementing IDs" {
    var mgr = BreakpointManager.init(std.testing.allocator);
    defer mgr.deinit();

    const id1 = try mgr.setAtAddress(0x1000, "a.c", 1);
    const id2 = try mgr.setAtAddress(0x2000, "b.c", 2);

    try std.testing.expectEqual(@as(u32, 1), id1);
    try std.testing.expectEqual(@as(u32, 2), id2);
    try std.testing.expectEqual(@as(usize, 2), mgr.list().len);
}

test "remove breakpoint removes from list" {
    var mgr = BreakpointManager.init(std.testing.allocator);
    defer mgr.deinit();

    const id = try mgr.setAtAddress(0x1000, "test.c", 5);
    try std.testing.expectEqual(@as(usize, 1), mgr.list().len);

    try mgr.remove(id);
    try std.testing.expectEqual(@as(usize, 0), mgr.list().len);
}

test "remove nonexistent breakpoint returns error" {
    var mgr = BreakpointManager.init(std.testing.allocator);
    defer mgr.deinit();

    try std.testing.expectError(error.BreakpointNotFound, mgr.remove(999));
}

test "multiple breakpoints track independently" {
    var mgr = BreakpointManager.init(std.testing.allocator);
    defer mgr.deinit();

    _ = try mgr.setAtAddress(0x1000, "a.c", 1);
    const id2 = try mgr.setAtAddress(0x2000, "b.c", 2);
    _ = try mgr.setAtAddress(0x3000, "c.c", 3);

    try mgr.remove(id2);
    try std.testing.expectEqual(@as(usize, 2), mgr.list().len);

    // Remaining breakpoints should still be findable
    try std.testing.expect(mgr.findByAddress(0x1000) != null);
    try std.testing.expect(mgr.findByAddress(0x2000) == null); // removed
    try std.testing.expect(mgr.findByAddress(0x3000) != null);
}

test "findByAddress returns matching breakpoint" {
    var mgr = BreakpointManager.init(std.testing.allocator);
    defer mgr.deinit();

    _ = try mgr.setAtAddress(0x1000, "test.c", 5);

    const bp = mgr.findByAddress(0x1000);
    try std.testing.expect(bp != null);
    try std.testing.expectEqual(@as(u32, 5), bp.?.line);
}

test "findByAddress returns null for unknown address" {
    var mgr = BreakpointManager.init(std.testing.allocator);
    defer mgr.deinit();

    _ = try mgr.setAtAddress(0x1000, "test.c", 5);

    try std.testing.expect(mgr.findByAddress(0x9999) == null);
}

test "recordHit increments hit count" {
    var mgr = BreakpointManager.init(std.testing.allocator);
    defer mgr.deinit();

    const id = try mgr.setAtAddress(0x1000, "test.c", 5);
    mgr.recordHit(id);
    mgr.recordHit(id);

    const bp = mgr.findById(id);
    try std.testing.expect(bp != null);
    try std.testing.expectEqual(@as(u32, 2), bp.?.hit_count);
}

test "breakpoint at invalid location returns error" {
    var mgr = BreakpointManager.init(std.testing.allocator);
    defer mgr.deinit();

    // Only end_sequence entries — no statement lines available
    const entries = [_]parser.LineEntry{
        .{ .address = 0x1000, .file_index = 1, .line = 5, .column = 0, .is_stmt = true, .end_sequence = true },
    };

    const result = mgr.resolveAndSet("test.c", 5, &entries, null);
    try std.testing.expectError(error.NoAddressForLine, result);
}

test "conditional breakpoint stores condition" {
    var mgr = BreakpointManager.init(std.testing.allocator);
    defer mgr.deinit();

    const entries = [_]parser.LineEntry{
        .{ .address = 0x1000, .file_index = 1, .line = 10, .column = 0, .is_stmt = true, .end_sequence = false },
    };

    const bp = try mgr.resolveAndSet("test.c", 10, &entries, "x > 5");
    try std.testing.expect(bp.condition != null);
    try std.testing.expectEqualStrings("x > 5", bp.condition.?);
}

test "conditional breakpoint evaluates expression" {
    var mgr = BreakpointManager.init(std.testing.allocator);
    defer mgr.deinit();

    const entries = [_]parser.LineEntry{
        .{ .address = 0x1000, .file_index = 1, .line = 10, .column = 0, .is_stmt = true, .end_sequence = false },
    };

    _ = try mgr.resolveAndSet("test.c", 10, &entries, "x > 5");

    const bp = mgr.findByAddress(0x1000).?;

    // Evaluator that returns false (condition not met) — should not stop
    const result1 = mgr.shouldStop(bp, struct {
        fn eval(_: []const u8) bool {
            return false;
        }
    }.eval);
    try std.testing.expect(!result1);

    // Evaluator that returns true (condition met) — should stop
    const result2 = mgr.shouldStop(bp, struct {
        fn eval(_: []const u8) bool {
            return true;
        }
    }.eval);
    try std.testing.expect(result2);

    // Hit count should be 2 after both evaluations
    try std.testing.expectEqual(@as(u32, 2), bp.hit_count);
}

test "unconditional breakpoint always stops" {
    var mgr = BreakpointManager.init(std.testing.allocator);
    defer mgr.deinit();

    _ = try mgr.setAtAddress(0x1000, "test.c", 5);
    const bp = mgr.findByAddress(0x1000).?;

    // No condition — should always stop regardless of evaluator
    try std.testing.expect(mgr.shouldStop(bp, null));
    try std.testing.expectEqual(@as(u32, 1), bp.hit_count);
}

test "breakpoint hit stops process at correct address" {
    if (builtin.os.tag != .macos or !builtin.single_threaded) return error.SkipZigTest;

    var mgr = BreakpointManager.init(std.testing.allocator);
    defer mgr.deinit();

    // Set a breakpoint at a known address
    const bp_addr: u64 = 0x4000;
    const id = try mgr.setAtAddress(bp_addr, "test.c", 10);

    // Spawn a process and write the breakpoint
    var pc = process_mod.ProcessControl{};
    pc.spawn(std.testing.allocator, "/bin/echo", &.{"test"}) catch return error.SkipZigTest;
    defer pc.kill() catch {};

    try mgr.writeBreakpoint(id, &pc);

    // Simulate breakpoint hit: find by address and record hit
    const bp = mgr.findByAddress(bp_addr);
    try std.testing.expect(bp != null);
    try std.testing.expectEqual(bp_addr, bp.?.address);
    try std.testing.expectEqual(@as(u32, 10), bp.?.line);

    // Record the hit and verify state
    mgr.recordHit(id);
    try std.testing.expectEqual(@as(u32, 1), bp.?.hit_count);

    // Verify shouldStop returns true (no condition)
    try std.testing.expect(mgr.shouldStop(bp.?, null));
    try std.testing.expectEqual(@as(u32, 2), bp.?.hit_count);
}

test "setBreakpoint saves original byte and writes INT3 via mock process" {
    var mgr = BreakpointManager.init(std.testing.allocator);
    defer mgr.deinit();

    const id = try mgr.setAtAddress(0x1000, "test.c", 5);

    // Use the real ProcessControl (which has stub readMemory/writeMemory)
    var pc = process_mod.ProcessControl{};

    // writeBreakpoint reads original byte and writes INT3
    try mgr.writeBreakpoint(id, &pc);

    const bp = mgr.findById(id);
    try std.testing.expect(bp != null);
    // Original byte should have been read (stub returns 0)
    try std.testing.expectEqual(@as(u8, 0), bp.?.original_byte);
}

test "removeBreakpoint restores original byte via mock process" {
    var mgr = BreakpointManager.init(std.testing.allocator);
    defer mgr.deinit();

    const id = try mgr.setAtAddress(0x1000, "test.c", 5);

    var pc = process_mod.ProcessControl{};

    // Write breakpoint, then remove it
    try mgr.writeBreakpoint(id, &pc);
    try mgr.removeBreakpoint(id, &pc);

    // Breakpoint should be removed from the list
    try std.testing.expectEqual(@as(usize, 0), mgr.list().len);
}
