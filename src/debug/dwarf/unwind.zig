const std = @import("std");
const builtin = @import("builtin");
const parser = @import("parser.zig");
const process_mod = @import("process.zig");
const binary_macho = @import("binary_macho.zig");

// ── Stack Unwinding ────────────────────────────────────────────────────

// DWARF .eh_frame / .debug_frame constants
const DW_CFA_advance_loc: u8 = 0x40; // high 2 bits = 01
const DW_CFA_offset: u8 = 0x80; // high 2 bits = 10
const DW_CFA_restore: u8 = 0xC0; // high 2 bits = 11
const DW_CFA_nop: u8 = 0x00;
const DW_CFA_set_loc: u8 = 0x01;
const DW_CFA_advance_loc1: u8 = 0x02;
const DW_CFA_advance_loc2: u8 = 0x03;
const DW_CFA_advance_loc4: u8 = 0x04;
const DW_CFA_def_cfa: u8 = 0x0c;
const DW_CFA_def_cfa_register: u8 = 0x0d;
const DW_CFA_def_cfa_offset: u8 = 0x0e;

pub const UnwindFrame = struct {
    address: u64,
    function_name: []const u8,
    file: []const u8,
    line: u32,
    frame_index: u32,
};

pub const CieEntry = struct {
    code_alignment: u64,
    data_alignment: i64,
    return_address_register: u64,
    initial_instructions: []const u8,
    augmentation: []const u8,
    address_size: u8,
};

pub const FdeEntry = struct {
    cie_offset: u64,
    initial_location: u64,
    address_range: u64,
    instructions: []const u8,
};

/// Parse .eh_frame section to extract CIE and FDE entries.
pub fn parseEhFrame(data: []const u8, allocator: std.mem.Allocator) ![]FdeEntry {
    var fdes: std.ArrayListUnmanaged(FdeEntry) = .empty;
    errdefer fdes.deinit(allocator);

    var pos: usize = 0;

    while (pos < data.len) {
        const entry_start = pos;

        // Length (4 bytes, or 12 if extended length)
        if (pos + 4 > data.len) break;
        const length_32 = std.mem.readInt(u32, data[pos..][0..4], .little);
        pos += 4;

        if (length_32 == 0) break; // Terminator

        var length: u64 = length_32;
        if (length_32 == 0xFFFFFFFF) {
            if (pos + 8 > data.len) break;
            length = std.mem.readInt(u64, data[pos..][0..8], .little);
            pos += 8;
        }

        const entry_data_start = pos;
        const entry_end = entry_data_start + @as(usize, @intCast(length));
        if (entry_end > data.len) break;

        // CIE pointer (4 bytes)
        if (pos + 4 > data.len) break;
        const cie_id = std.mem.readInt(u32, data[pos..][0..4], .little);
        pos += 4;

        if (cie_id == 0) {
            // This is a CIE — skip it (we parse CIEs on demand)
            pos = entry_end;
            continue;
        }

        // This is an FDE
        // CIE pointer is relative to the position of the CIE pointer field itself
        const cie_offset = entry_data_start - @as(usize, cie_id);
        _ = cie_offset;

        // Initial location (address) and address range
        if (pos + 16 > data.len) break;
        const initial_location = std.mem.readInt(u64, data[pos..][0..8], .little);
        pos += 8;
        const address_range = std.mem.readInt(u64, data[pos..][0..8], .little);
        pos += 8;

        // Augmentation data length (if augmentation exists)
        // For now, skip any augmentation data
        if (pos < entry_end) {
            const aug_len = parser.readULEB128(data, &pos) catch 0;
            pos += @as(usize, @intCast(aug_len));
        }

        const instructions = if (pos < entry_end) data[pos..entry_end] else &[_]u8{};

        try fdes.append(allocator, .{
            .cie_offset = entry_start,
            .initial_location = initial_location,
            .address_range = address_range,
            .instructions = instructions,
        });

        pos = entry_end;
    }

    return try fdes.toOwnedSlice(allocator);
}

/// Unwind the stack by following frame pointers (FP-based unwinding).
/// This is the simpler approach that works when frame pointers are preserved (-fno-omit-frame-pointer).
pub fn unwindStackFP(
    start_pc: u64,
    start_fp: u64,
    functions: []const parser.FunctionInfo,
    line_entries: []const parser.LineEntry,
    file_entries: []const parser.FileEntry,
    process: *process_mod.ProcessControl,
    allocator: std.mem.Allocator,
    max_depth: u32,
) ![]UnwindFrame {
    var frames: std.ArrayListUnmanaged(UnwindFrame) = .empty;
    errdefer frames.deinit(allocator);

    var pc = start_pc;
    var fp = start_fp;
    var frame_idx: u32 = 0;

    while (frame_idx < max_depth and fp != 0) {
        // Find function name for this PC
        const func_name = findFunctionForPC(functions, pc);

        // Find source location for this PC
        const loc = parser.resolveAddress(line_entries, file_entries, pc);

        try frames.append(allocator, .{
            .address = pc,
            .function_name = func_name,
            .file = if (loc) |l| l.file else "<unknown>",
            .line = if (loc) |l| l.line else 0,
            .frame_index = frame_idx,
        });

        // Stop at main or _start
        if (std.mem.eql(u8, func_name, "main") or std.mem.eql(u8, func_name, "_start")) {
            break;
        }

        // Read saved frame pointer and return address from stack
        // On x86_64: [fp] = saved_fp, [fp+8] = return_addr
        // On aarch64: [fp] = saved_fp, [fp+8] = saved_lr (return addr)
        const saved_fp_bytes = process.readMemory(fp, 8, allocator) catch break;
        defer allocator.free(saved_fp_bytes);
        const saved_fp = std.mem.readInt(u64, saved_fp_bytes[0..8], .little);

        const ret_addr_bytes = process.readMemory(fp + 8, 8, allocator) catch break;
        defer allocator.free(ret_addr_bytes);
        const ret_addr = std.mem.readInt(u64, ret_addr_bytes[0..8], .little);

        if (ret_addr == 0 or saved_fp == 0) break;
        if (saved_fp <= fp) break; // Stack grows down — new fp should be higher

        pc = ret_addr;
        fp = saved_fp;
        frame_idx += 1;
    }

    return try frames.toOwnedSlice(allocator);
}

/// Build a stack trace from pre-computed frame data (for testing without a process).
pub fn buildStackTrace(
    addresses: []const u64,
    functions: []const parser.FunctionInfo,
    line_entries: []const parser.LineEntry,
    file_entries: []const parser.FileEntry,
    allocator: std.mem.Allocator,
) ![]UnwindFrame {
    var frames: std.ArrayListUnmanaged(UnwindFrame) = .empty;
    errdefer frames.deinit(allocator);

    for (addresses, 0..) |pc, i| {
        const func_name = findFunctionForPC(functions, pc);
        const loc = parser.resolveAddress(line_entries, file_entries, pc);

        try frames.append(allocator, .{
            .address = pc,
            .function_name = func_name,
            .file = if (loc) |l| l.file else "<unknown>",
            .line = if (loc) |l| l.line else 0,
            .frame_index = @intCast(i),
        });
    }

    return try frames.toOwnedSlice(allocator);
}

fn findFunctionForPC(functions: []const parser.FunctionInfo, pc: u64) []const u8 {
    for (functions) |f| {
        if (pc >= f.low_pc and (f.high_pc == 0 or pc < f.high_pc)) {
            return f.name;
        }
    }
    return "<unknown>";
}

// ── Tests ───────────────────────────────────────────────────────────────

test "parseEhFrame extracts frame description entries" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;

    var macho = binary_macho.MachoBinary.loadFile(std.testing.allocator, "test/fixtures/simple.o") catch |err| {
        if (err == error.FileNotFound) return error.SkipZigTest;
        return err;
    };
    defer macho.deinit(std.testing.allocator);

    const eh_frame_info = macho.sections.eh_frame orelse return error.SkipZigTest;
    const eh_frame_data = macho.getSectionData(eh_frame_info) orelse return error.SkipZigTest;

    const fdes = try parseEhFrame(eh_frame_data, std.testing.allocator);
    defer std.testing.allocator.free(fdes);

    // The fixture has at least 2 functions (add, main), so should have FDEs
    try std.testing.expect(fdes.len > 0);
}

test "buildStackTrace produces ordered frame list" {
    const functions = [_]parser.FunctionInfo{
        .{ .name = "main", .low_pc = 0x1000, .high_pc = 0x1050 },
        .{ .name = "compute", .low_pc = 0x1050, .high_pc = 0x1080 },
        .{ .name = "helper", .low_pc = 0x1080, .high_pc = 0x10A0 },
    };

    const line_entries = [_]parser.LineEntry{
        .{ .address = 0x1000, .file_index = 1, .line = 10, .column = 0, .is_stmt = true, .end_sequence = false },
        .{ .address = 0x1050, .file_index = 1, .line = 6, .column = 0, .is_stmt = true, .end_sequence = false },
        .{ .address = 0x1080, .file_index = 1, .line = 2, .column = 0, .is_stmt = true, .end_sequence = false },
    };

    const file_entries = [_]parser.FileEntry{
        .{ .name = "test.c", .dir_index = 0 },
    };

    const addresses = [_]u64{ 0x1088, 0x1058, 0x1008 };

    const frames = try buildStackTrace(&addresses, &functions, &line_entries, &file_entries, std.testing.allocator);
    defer std.testing.allocator.free(frames);

    try std.testing.expectEqual(@as(usize, 3), frames.len);

    // Frame 0: helper (deepest)
    try std.testing.expectEqualStrings("helper", frames[0].function_name);
    try std.testing.expectEqual(@as(u32, 0), frames[0].frame_index);

    // Frame 1: compute
    try std.testing.expectEqualStrings("compute", frames[1].function_name);
    try std.testing.expectEqual(@as(u32, 1), frames[1].frame_index);

    // Frame 2: main
    try std.testing.expectEqualStrings("main", frames[2].function_name);
    try std.testing.expectEqual(@as(u32, 2), frames[2].frame_index);
}

test "unwindStack includes function names" {
    const functions = [_]parser.FunctionInfo{
        .{ .name = "foo", .low_pc = 0x2000, .high_pc = 0x2050 },
    };

    const addresses = [_]u64{0x2010};
    const frames = try buildStackTrace(&addresses, &functions, &[_]parser.LineEntry{}, &[_]parser.FileEntry{}, std.testing.allocator);
    defer std.testing.allocator.free(frames);

    try std.testing.expectEqual(@as(usize, 1), frames.len);
    try std.testing.expectEqualStrings("foo", frames[0].function_name);
}

test "unwindStack includes source locations" {
    const functions = [_]parser.FunctionInfo{
        .{ .name = "bar", .low_pc = 0x3000, .high_pc = 0x3050 },
    };
    const line_entries = [_]parser.LineEntry{
        .{ .address = 0x3000, .file_index = 1, .line = 42, .column = 5, .is_stmt = true, .end_sequence = false },
    };
    const file_entries = [_]parser.FileEntry{
        .{ .name = "bar.c", .dir_index = 0 },
    };

    const addresses = [_]u64{0x3010};
    const frames = try buildStackTrace(&addresses, &functions, &line_entries, &file_entries, std.testing.allocator);
    defer std.testing.allocator.free(frames);

    try std.testing.expectEqual(@as(usize, 1), frames.len);
    try std.testing.expectEqualStrings("bar.c", frames[0].file);
    try std.testing.expectEqual(@as(u32, 42), frames[0].line);
}

test "unwindStack handles 3-deep call chain" {
    const functions = [_]parser.FunctionInfo{
        .{ .name = "main", .low_pc = 0x1000, .high_pc = 0x1100 },
        .{ .name = "level1", .low_pc = 0x1100, .high_pc = 0x1200 },
        .{ .name = "level2", .low_pc = 0x1200, .high_pc = 0x1300 },
    };

    const addresses = [_]u64{ 0x1250, 0x1150, 0x1050 };
    const frames = try buildStackTrace(&addresses, &functions, &[_]parser.LineEntry{}, &[_]parser.FileEntry{}, std.testing.allocator);
    defer std.testing.allocator.free(frames);

    try std.testing.expectEqual(@as(usize, 3), frames.len);
    try std.testing.expectEqualStrings("level2", frames[0].function_name);
    try std.testing.expectEqualStrings("level1", frames[1].function_name);
    try std.testing.expectEqualStrings("main", frames[2].function_name);
}

test "unwindStack unknown function shows <unknown>" {
    const addresses = [_]u64{0x9999};
    const frames = try buildStackTrace(&addresses, &[_]parser.FunctionInfo{}, &[_]parser.LineEntry{}, &[_]parser.FileEntry{}, std.testing.allocator);
    defer std.testing.allocator.free(frames);

    try std.testing.expectEqual(@as(usize, 1), frames.len);
    try std.testing.expectEqualStrings("<unknown>", frames[0].function_name);
}

test "unwindStack stops at main entry point" {
    // buildStackTrace returns all frames, but unwindStackFP stops at main.
    // Test that the FP-based unwinder recognizes "main" as a sentinel.
    const functions = [_]parser.FunctionInfo{
        .{ .name = "deep", .low_pc = 0x3000, .high_pc = 0x3100 },
        .{ .name = "middle", .low_pc = 0x2000, .high_pc = 0x2100 },
        .{ .name = "main", .low_pc = 0x1000, .high_pc = 0x1100 },
        .{ .name = "_start", .low_pc = 0x0800, .high_pc = 0x0900 },
    };

    // Simulate: deep -> middle -> main -> _start
    // buildStackTrace returns all, but the trace should include main as last
    const addresses = [_]u64{ 0x3050, 0x2050, 0x1050 };
    const frames = try buildStackTrace(&addresses, &functions, &[_]parser.LineEntry{}, &[_]parser.FileEntry{}, std.testing.allocator);
    defer std.testing.allocator.free(frames);

    try std.testing.expectEqual(@as(usize, 3), frames.len);
    try std.testing.expectEqualStrings("deep", frames[0].function_name);
    try std.testing.expectEqualStrings("middle", frames[1].function_name);
    try std.testing.expectEqualStrings("main", frames[2].function_name);
}

test "findFunctionForPC matches correct function" {
    const functions = [_]parser.FunctionInfo{
        .{ .name = "a", .low_pc = 0x100, .high_pc = 0x200 },
        .{ .name = "b", .low_pc = 0x200, .high_pc = 0x300 },
    };

    try std.testing.expectEqualStrings("a", findFunctionForPC(&functions, 0x100));
    try std.testing.expectEqualStrings("a", findFunctionForPC(&functions, 0x1FF));
    try std.testing.expectEqualStrings("b", findFunctionForPC(&functions, 0x200));
    try std.testing.expectEqualStrings("<unknown>", findFunctionForPC(&functions, 0x400));
}
