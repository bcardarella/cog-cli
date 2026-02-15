const std = @import("std");
const builtin = @import("builtin");
const parser = @import("parser.zig");

// ── DWARF Location Expression Evaluation ───────────────────────────────

// DWARF expression opcodes
const DW_OP_addr: u8 = 0x03;
const DW_OP_deref: u8 = 0x06;
const DW_OP_const1u: u8 = 0x08;
const DW_OP_const1s: u8 = 0x09;
const DW_OP_const2u: u8 = 0x0a;
const DW_OP_const2s: u8 = 0x0b;
const DW_OP_const4u: u8 = 0x0c;
const DW_OP_const4s: u8 = 0x0d;
const DW_OP_const8u: u8 = 0x0e;
const DW_OP_const8s: u8 = 0x0f;
const DW_OP_constu: u8 = 0x10;
const DW_OP_consts: u8 = 0x11;
const DW_OP_dup: u8 = 0x12;
const DW_OP_drop: u8 = 0x13;
const DW_OP_plus: u8 = 0x22;
const DW_OP_plus_uconst: u8 = 0x23;
const DW_OP_minus: u8 = 0x1c;
const DW_OP_mul: u8 = 0x1e;
const DW_OP_lit0: u8 = 0x30;
const DW_OP_lit31: u8 = 0x4f;
const DW_OP_reg0: u8 = 0x50;
const DW_OP_reg31: u8 = 0x6f;
const DW_OP_breg0: u8 = 0x70;
const DW_OP_breg31: u8 = 0x8f;
const DW_OP_regx: u8 = 0x90;
const DW_OP_fbreg: u8 = 0x91;
const DW_OP_stack_value: u8 = 0x9f;
const DW_OP_piece: u8 = 0x93;

// DWARF base type constants
const DW_ATE_signed: u8 = 0x05;
const DW_ATE_unsigned: u8 = 0x07;
const DW_ATE_float: u8 = 0x04;
const DW_ATE_boolean: u8 = 0x02;
const DW_ATE_address: u8 = 0x01;
const DW_ATE_signed_char: u8 = 0x06;
const DW_ATE_unsigned_char: u8 = 0x08;

pub const LocationResult = union(enum) {
    address: u64,
    register: u64,
    value: u64,
    empty: void,
};

pub const VariableValue = struct {
    name: []const u8,
    value_str: []const u8,
    type_str: []const u8,
};

pub const RegisterProvider = struct {
    ptr: *anyopaque,
    readFn: *const fn (ctx: *anyopaque, reg: u64) ?u64,

    pub fn read(self: RegisterProvider, reg: u64) ?u64 {
        return self.readFn(self.ptr, reg);
    }
};

pub const MemoryReader = struct {
    ptr: *anyopaque,
    readFn: *const fn (ctx: *anyopaque, addr: u64, size: usize) ?u64,

    pub fn read(self: MemoryReader, addr: u64, size: usize) ?u64 {
        return self.readFn(self.ptr, addr, size);
    }
};

/// Evaluate a DWARF location expression with optional memory reader for DW_OP_deref.
pub fn evalLocationWithMemory(
    expr: []const u8,
    regs: RegisterProvider,
    frame_base: ?u64,
    mem_reader: ?MemoryReader,
) LocationResult {
    return evalLocationImpl(expr, regs, frame_base, mem_reader);
}

/// Evaluate a DWARF location expression.
pub fn evalLocation(
    expr: []const u8,
    regs: RegisterProvider,
    frame_base: ?u64,
) LocationResult {
    return evalLocationImpl(expr, regs, frame_base, null);
}

fn evalLocationImpl(
    expr: []const u8,
    regs: RegisterProvider,
    frame_base: ?u64,
    mem_reader: ?MemoryReader,
) LocationResult {
    var stack: [64]u64 = undefined;
    var sp: usize = 0;

    var pos: usize = 0;
    while (pos < expr.len) {
        const op = expr[pos];
        pos += 1;

        if (op >= DW_OP_lit0 and op <= DW_OP_lit31) {
            if (sp >= stack.len) return .empty;
            stack[sp] = op - DW_OP_lit0;
            sp += 1;
            continue;
        }

        if (op >= DW_OP_reg0 and op <= DW_OP_reg31) {
            return .{ .register = op - DW_OP_reg0 };
        }

        if (op >= DW_OP_breg0 and op <= DW_OP_breg31) {
            const reg_num = op - DW_OP_breg0;
            const offset = parser.readSLEB128(expr, &pos) catch return .empty;
            const reg_val = regs.read(reg_num) orelse return .empty;
            if (sp >= stack.len) return .empty;
            const result = if (offset >= 0)
                reg_val +% @as(u64, @intCast(offset))
            else
                reg_val -% @as(u64, @intCast(-offset));
            stack[sp] = result;
            sp += 1;
            continue;
        }

        switch (op) {
            DW_OP_addr => {
                if (pos + 8 > expr.len) return .empty;
                const addr = std.mem.readInt(u64, expr[pos..][0..8], .little);
                pos += 8;
                if (sp >= stack.len) return .empty;
                stack[sp] = addr;
                sp += 1;
            },
            DW_OP_fbreg => {
                const offset = parser.readSLEB128(expr, &pos) catch return .empty;
                const fb = frame_base orelse return .empty;
                if (sp >= stack.len) return .empty;
                const result = if (offset >= 0)
                    fb +% @as(u64, @intCast(offset))
                else
                    fb -% @as(u64, @intCast(-offset));
                stack[sp] = result;
                sp += 1;
            },
            DW_OP_regx => {
                const reg_num = parser.readULEB128(expr, &pos) catch return .empty;
                return .{ .register = reg_num };
            },
            DW_OP_constu => {
                const val = parser.readULEB128(expr, &pos) catch return .empty;
                if (sp >= stack.len) return .empty;
                stack[sp] = val;
                sp += 1;
            },
            DW_OP_consts => {
                const val = parser.readSLEB128(expr, &pos) catch return .empty;
                if (sp >= stack.len) return .empty;
                stack[sp] = @bitCast(val);
                sp += 1;
            },
            DW_OP_const1u => {
                if (pos >= expr.len) return .empty;
                if (sp >= stack.len) return .empty;
                stack[sp] = expr[pos];
                pos += 1;
                sp += 1;
            },
            DW_OP_const1s => {
                if (pos >= expr.len) return .empty;
                if (sp >= stack.len) return .empty;
                const s: i8 = @bitCast(expr[pos]);
                stack[sp] = @bitCast(@as(i64, s));
                pos += 1;
                sp += 1;
            },
            DW_OP_const2u => {
                if (pos + 2 > expr.len) return .empty;
                if (sp >= stack.len) return .empty;
                stack[sp] = std.mem.readInt(u16, expr[pos..][0..2], .little);
                pos += 2;
                sp += 1;
            },
            DW_OP_const2s => {
                if (pos + 2 > expr.len) return .empty;
                if (sp >= stack.len) return .empty;
                const s: i16 = @bitCast(std.mem.readInt(u16, expr[pos..][0..2], .little));
                stack[sp] = @bitCast(@as(i64, s));
                pos += 2;
                sp += 1;
            },
            DW_OP_const4u => {
                if (pos + 4 > expr.len) return .empty;
                if (sp >= stack.len) return .empty;
                stack[sp] = std.mem.readInt(u32, expr[pos..][0..4], .little);
                pos += 4;
                sp += 1;
            },
            DW_OP_const4s => {
                if (pos + 4 > expr.len) return .empty;
                if (sp >= stack.len) return .empty;
                const s: i32 = @bitCast(std.mem.readInt(u32, expr[pos..][0..4], .little));
                stack[sp] = @bitCast(@as(i64, s));
                pos += 4;
                sp += 1;
            },
            DW_OP_const8u => {
                if (pos + 8 > expr.len) return .empty;
                if (sp >= stack.len) return .empty;
                stack[sp] = std.mem.readInt(u64, expr[pos..][0..8], .little);
                pos += 8;
                sp += 1;
            },
            DW_OP_const8s => {
                if (pos + 8 > expr.len) return .empty;
                if (sp >= stack.len) return .empty;
                stack[sp] = std.mem.readInt(u64, expr[pos..][0..8], .little);
                pos += 8;
                sp += 1;
            },
            DW_OP_plus => {
                if (sp < 2) return .empty;
                sp -= 1;
                stack[sp - 1] = stack[sp - 1] +% stack[sp];
            },
            DW_OP_plus_uconst => {
                if (sp < 1) return .empty;
                const val = parser.readULEB128(expr, &pos) catch return .empty;
                stack[sp - 1] = stack[sp - 1] +% val;
            },
            DW_OP_minus => {
                if (sp < 2) return .empty;
                sp -= 1;
                stack[sp - 1] = stack[sp - 1] -% stack[sp];
            },
            DW_OP_mul => {
                if (sp < 2) return .empty;
                sp -= 1;
                stack[sp - 1] = stack[sp - 1] *% stack[sp];
            },
            DW_OP_deref => {
                if (sp < 1) return .empty;
                if (mem_reader) |reader| {
                    // Read 8 bytes from the debuggee's memory at the address on stack
                    const val = reader.read(stack[sp - 1], 8) orelse return .{ .address = stack[sp - 1] };
                    stack[sp - 1] = val;
                } else {
                    // No memory reader — return the address to be dereferenced externally
                    return .{ .address = stack[sp - 1] };
                }
            },
            DW_OP_dup => {
                if (sp < 1 or sp >= stack.len) return .empty;
                stack[sp] = stack[sp - 1];
                sp += 1;
            },
            DW_OP_drop => {
                if (sp < 1) return .empty;
                sp -= 1;
            },
            DW_OP_stack_value => {
                if (sp < 1) return .empty;
                return .{ .value = stack[sp - 1] };
            },
            DW_OP_piece => {
                const piece_size = parser.readULEB128(expr, &pos) catch return .empty;
                _ = piece_size;
                // Piece designator — return what we have so far
                if (sp > 0) return .{ .address = stack[sp - 1] };
            },
            else => {
                // Unknown opcode — can't continue
                break;
            },
        }
    }

    if (sp > 0) {
        return .{ .address = stack[sp - 1] };
    }
    return .empty;
}

/// Format a variable value for display.
pub fn formatVariable(
    raw_bytes: []const u8,
    type_name: []const u8,
    encoding: u8,
    byte_size: u8,
    buf: []u8,
) []const u8 {
    if (raw_bytes.len == 0) {
        return formatLiteral(buf, "<optimized out>");
    }

    switch (encoding) {
        DW_ATE_signed, DW_ATE_signed_char => {
            return switch (byte_size) {
                1 => formatTo(buf, "{d}", .{@as(i8, @bitCast(raw_bytes[0]))}),
                2 => blk: {
                    if (raw_bytes.len < 2) break :blk formatLiteral(buf, "<truncated>");
                    const val: i16 = @bitCast(std.mem.readInt(u16, raw_bytes[0..2], .little));
                    break :blk formatTo(buf, "{d}", .{val});
                },
                4 => blk: {
                    if (raw_bytes.len < 4) break :blk formatLiteral(buf, "<truncated>");
                    const val: i32 = @bitCast(std.mem.readInt(u32, raw_bytes[0..4], .little));
                    break :blk formatTo(buf, "{d}", .{val});
                },
                8 => blk: {
                    if (raw_bytes.len < 8) break :blk formatLiteral(buf, "<truncated>");
                    const val: i64 = @bitCast(std.mem.readInt(u64, raw_bytes[0..8], .little));
                    break :blk formatTo(buf, "{d}", .{val});
                },
                else => formatLiteral(buf, "<unsupported size>"),
            };
        },
        DW_ATE_unsigned, DW_ATE_unsigned_char => {
            return switch (byte_size) {
                1 => formatTo(buf, "{d}", .{raw_bytes[0]}),
                2 => blk: {
                    if (raw_bytes.len < 2) break :blk formatLiteral(buf, "<truncated>");
                    const val = std.mem.readInt(u16, raw_bytes[0..2], .little);
                    break :blk formatTo(buf, "{d}", .{val});
                },
                4 => blk: {
                    if (raw_bytes.len < 4) break :blk formatLiteral(buf, "<truncated>");
                    const val = std.mem.readInt(u32, raw_bytes[0..4], .little);
                    break :blk formatTo(buf, "{d}", .{val});
                },
                8 => blk: {
                    if (raw_bytes.len < 8) break :blk formatLiteral(buf, "<truncated>");
                    const val = std.mem.readInt(u64, raw_bytes[0..8], .little);
                    break :blk formatTo(buf, "{d}", .{val});
                },
                else => formatLiteral(buf, "<unsupported size>"),
            };
        },
        DW_ATE_address => {
            if (raw_bytes.len < 8) return formatLiteral(buf, "<truncated>");
            const val = std.mem.readInt(u64, raw_bytes[0..8], .little);
            return formatTo(buf, "0x{x}", .{val});
        },
        DW_ATE_boolean => {
            if (raw_bytes[0] != 0) {
                return formatLiteral(buf, "true");
            } else {
                return formatLiteral(buf, "false");
            }
        },
        DW_ATE_float => {
            return switch (byte_size) {
                4 => blk: {
                    if (raw_bytes.len < 4) break :blk formatLiteral(buf, "<truncated>");
                    const bits = std.mem.readInt(u32, raw_bytes[0..4], .little);
                    const val: f32 = @bitCast(bits);
                    break :blk formatTo(buf, "{d}", .{val});
                },
                8 => blk: {
                    if (raw_bytes.len < 8) break :blk formatLiteral(buf, "<truncated>");
                    const bits = std.mem.readInt(u64, raw_bytes[0..8], .little);
                    const val: f64 = @bitCast(bits);
                    break :blk formatTo(buf, "{d}", .{val});
                },
                else => formatLiteral(buf, "<unsupported float size>"),
            };
        },
        else => {
            _ = type_name;
            return formatTo(buf, "<unknown encoding 0x{x}>", .{encoding});
        },
    }
}

/// Field descriptor for struct formatting.
pub const StructFieldInfo = struct {
    name: []const u8,
    offset: u16,
    encoding: u8,
    byte_size: u8,
};

/// Format a struct value with field names.
/// Output: {field1: val1, field2: val2}
pub fn formatStruct(
    raw_bytes: []const u8,
    fields: []const StructFieldInfo,
    buf: []u8,
) []const u8 {
    if (fields.len == 0) return formatLiteral(buf, "{}");

    var pos: usize = 0;
    if (pos < buf.len) {
        buf[pos] = '{';
        pos += 1;
    }

    for (fields, 0..) |field, i| {
        if (i > 0) {
            const sep = ", ";
            if (pos + sep.len <= buf.len) {
                @memcpy(buf[pos..][0..sep.len], sep);
                pos += sep.len;
            }
        }

        // Write field name
        if (pos + field.name.len <= buf.len) {
            @memcpy(buf[pos..][0..field.name.len], field.name);
            pos += field.name.len;
        }
        if (pos + 2 <= buf.len) {
            buf[pos] = ':';
            buf[pos + 1] = ' ';
            pos += 2;
        }

        // Format field value
        const field_start = field.offset;
        const field_end = field_start + field.byte_size;
        if (field_end <= raw_bytes.len) {
            var field_buf: [64]u8 = undefined;
            const val_str = formatVariable(
                raw_bytes[field_start..field_end],
                "",
                field.encoding,
                field.byte_size,
                &field_buf,
            );
            if (pos + val_str.len <= buf.len) {
                @memcpy(buf[pos..][0..val_str.len], val_str);
                pos += val_str.len;
            }
        } else {
            const trunc = "<truncated>";
            if (pos + trunc.len <= buf.len) {
                @memcpy(buf[pos..][0..trunc.len], trunc);
                pos += trunc.len;
            }
        }
    }

    if (pos < buf.len) {
        buf[pos] = '}';
        pos += 1;
    }

    return buf[0..pos];
}

/// Format an array value with elements.
/// Output: [val1, val2, val3]
pub fn formatArray(
    raw_bytes: []const u8,
    element_encoding: u8,
    element_byte_size: u8,
    count: u32,
    buf: []u8,
) []const u8 {
    if (count == 0) return formatLiteral(buf, "[]");

    var pos: usize = 0;
    if (pos < buf.len) {
        buf[pos] = '[';
        pos += 1;
    }

    var i: u32 = 0;
    while (i < count) : (i += 1) {
        if (i > 0) {
            const sep = ", ";
            if (pos + sep.len <= buf.len) {
                @memcpy(buf[pos..][0..sep.len], sep);
                pos += sep.len;
            }
        }

        const elem_start = @as(usize, i) * element_byte_size;
        const elem_end = elem_start + element_byte_size;
        if (elem_end <= raw_bytes.len) {
            var elem_buf: [64]u8 = undefined;
            const val_str = formatVariable(
                raw_bytes[elem_start..elem_end],
                "",
                element_encoding,
                element_byte_size,
                &elem_buf,
            );
            if (pos + val_str.len <= buf.len) {
                @memcpy(buf[pos..][0..val_str.len], val_str);
                pos += val_str.len;
            }
        } else {
            const trunc = "...";
            if (pos + trunc.len <= buf.len) {
                @memcpy(buf[pos..][0..trunc.len], trunc);
                pos += trunc.len;
            }
            break;
        }
    }

    if (pos < buf.len) {
        buf[pos] = ']';
        pos += 1;
    }

    return buf[0..pos];
}

/// Inspect all local variables in the current frame.
/// Uses parsed variable info, register state, and optional memory reader
/// to evaluate locations and read values.
pub fn inspectLocals(
    variables: []const parser.VariableInfo,
    regs: RegisterProvider,
    frame_base: ?u64,
    mem_reader: ?MemoryReader,
    allocator: std.mem.Allocator,
) ![]VariableValue {
    var results: std.ArrayListUnmanaged(VariableValue) = .empty;
    errdefer {
        for (results.items) |v| {
            allocator.free(v.value_str);
            allocator.free(v.type_str);
        }
        results.deinit(allocator);
    }

    for (variables) |v| {
        if (v.location_expr.len == 0) continue;

        const loc = evalLocationWithMemory(v.location_expr, regs, frame_base, mem_reader);

        var value_str: []const u8 = "";
        switch (loc) {
            .value => |val| {
                // Stack value — format directly
                var raw: [8]u8 = undefined;
                std.mem.writeInt(u64, &raw, val, .little);
                var fmt_buf: [64]u8 = undefined;
                const effective_size = if (v.type_byte_size > 0) v.type_byte_size else 8;
                const formatted = formatVariable(raw[0..effective_size], v.type_name, v.type_encoding, effective_size, &fmt_buf);
                value_str = try allocator.dupe(u8, formatted);
            },
            .address => |addr| {
                // Address — try to read from memory
                if (mem_reader) |reader| {
                    const size: usize = if (v.type_byte_size > 0) v.type_byte_size else 8;
                    var raw: [8]u8 = undefined;
                    const val = reader.read(addr, size) orelse {
                        value_str = try allocator.dupe(u8, "<unreadable>");
                        break;
                    };
                    std.mem.writeInt(u64, &raw, val, .little);
                    var fmt_buf: [64]u8 = undefined;
                    const formatted = formatVariable(raw[0..size], v.type_name, v.type_encoding, @intCast(size), &fmt_buf);
                    value_str = try allocator.dupe(u8, formatted);
                } else {
                    var fmt_buf: [32]u8 = undefined;
                    const addr_str = formatTo(&fmt_buf, "0x{x}", .{addr});
                    value_str = try allocator.dupe(u8, addr_str);
                }
            },
            .register => |reg| {
                if (regs.read(reg)) |val| {
                    var raw: [8]u8 = undefined;
                    std.mem.writeInt(u64, &raw, val, .little);
                    var fmt_buf: [64]u8 = undefined;
                    const effective_size = if (v.type_byte_size > 0) v.type_byte_size else 8;
                    const formatted = formatVariable(raw[0..effective_size], v.type_name, v.type_encoding, effective_size, &fmt_buf);
                    value_str = try allocator.dupe(u8, formatted);
                } else {
                    value_str = try allocator.dupe(u8, "<unavailable>");
                }
            },
            .empty => {
                value_str = try allocator.dupe(u8, "<optimized out>");
            },
        }

        const type_str = try allocator.dupe(u8, v.type_name);

        try results.append(allocator, .{
            .name = v.name,
            .value_str = value_str,
            .type_str = type_str,
        });
    }

    return try results.toOwnedSlice(allocator);
}

pub fn freeInspectResults(results: []VariableValue, allocator: std.mem.Allocator) void {
    for (results) |v| {
        allocator.free(v.value_str);
        allocator.free(v.type_str);
    }
    allocator.free(results);
}

fn formatTo(buf: []u8, comptime fmt: []const u8, args: anytype) []const u8 {
    const written = std.fmt.bufPrint(buf, fmt, args) catch return "<format error>";
    return written;
}

fn formatLiteral(buf: []u8, comptime str: []const u8) []const u8 {
    if (str.len > buf.len) return str[0..buf.len];
    @memcpy(buf[0..str.len], str);
    return buf[0..str.len];
}

// ── Tests ───────────────────────────────────────────────────────────────

const MockRegisters = struct {
    values: [32]u64 = [_]u64{0} ** 32,

    fn readReg(ctx: *anyopaque, reg: u64) ?u64 {
        const self: *MockRegisters = @ptrCast(@alignCast(ctx));
        if (reg < 32) return self.values[@intCast(reg)];
        return null;
    }

    fn provider(self: *MockRegisters) RegisterProvider {
        return .{
            .ptr = @ptrCast(self),
            .readFn = readReg,
        };
    }
};

test "evalLocation handles DW_OP_fbreg (frame base relative)" {
    // DW_OP_fbreg with offset -8
    const expr = [_]u8{ DW_OP_fbreg, 0x78 }; // -8 in SLEB128
    var regs = MockRegisters{};

    const result = evalLocation(&expr, regs.provider(), 0x7FFF0100);
    switch (result) {
        .address => |addr| try std.testing.expectEqual(@as(u64, 0x7FFF00F8), addr),
        else => return error.TestUnexpectedResult,
    }
}

test "evalLocation handles DW_OP_reg (register value)" {
    // DW_OP_reg0 = register 0
    const expr = [_]u8{DW_OP_reg0};
    var regs = MockRegisters{};
    regs.values[0] = 42;

    const result = evalLocation(&expr, regs.provider(), null);
    switch (result) {
        .register => |reg| try std.testing.expectEqual(@as(u64, 0), reg),
        else => return error.TestUnexpectedResult,
    }
}

test "evalLocation handles DW_OP_addr (absolute address)" {
    // DW_OP_addr followed by 8-byte address
    var expr: [9]u8 = undefined;
    expr[0] = DW_OP_addr;
    std.mem.writeInt(u64, expr[1..9], 0xDEADBEEF, .little);

    var regs = MockRegisters{};
    const result = evalLocation(&expr, regs.provider(), null);
    switch (result) {
        .address => |addr| try std.testing.expectEqual(@as(u64, 0xDEADBEEF), addr),
        else => return error.TestUnexpectedResult,
    }
}

test "evalLocation handles DW_OP_plus_uconst" {
    // Push address, then add offset
    var expr: [11]u8 = undefined;
    expr[0] = DW_OP_addr;
    std.mem.writeInt(u64, expr[1..9], 0x1000, .little);
    expr[9] = DW_OP_plus_uconst;
    expr[10] = 0x10; // offset 16

    var regs = MockRegisters{};
    const result = evalLocation(&expr, regs.provider(), null);
    switch (result) {
        .address => |addr| try std.testing.expectEqual(@as(u64, 0x1010), addr),
        else => return error.TestUnexpectedResult,
    }
}

test "evalLocation handles DW_OP_deref" {
    var expr: [10]u8 = undefined;
    expr[0] = DW_OP_addr;
    std.mem.writeInt(u64, expr[1..9], 0x2000, .little);
    expr[9] = DW_OP_deref;

    var regs = MockRegisters{};
    const result = evalLocation(&expr, regs.provider(), null);
    // Deref returns the address to be dereferenced
    switch (result) {
        .address => |addr| try std.testing.expectEqual(@as(u64, 0x2000), addr),
        else => return error.TestUnexpectedResult,
    }
}

test "evalLocation handles DW_OP_breg with offset" {
    // DW_OP_breg6 (rbp on x86_64) with offset -16
    const expr = [_]u8{ DW_OP_breg0 + 6, 0x70 }; // -16 in SLEB128
    var regs = MockRegisters{};
    regs.values[6] = 0x7FFF0200;

    const result = evalLocation(&expr, regs.provider(), null);
    switch (result) {
        .address => |addr| try std.testing.expectEqual(@as(u64, 0x7FFF01F0), addr),
        else => return error.TestUnexpectedResult,
    }
}

test "evalLocation handles stack_value" {
    // Push constant, mark as stack value
    const expr = [_]u8{ DW_OP_constu, 42, DW_OP_stack_value };
    var regs = MockRegisters{};

    const result = evalLocation(&expr, regs.provider(), null);
    switch (result) {
        .value => |val| try std.testing.expectEqual(@as(u64, 42), val),
        else => return error.TestUnexpectedResult,
    }
}

test "evalLocation returns empty for empty expression" {
    const expr = [_]u8{};
    var regs = MockRegisters{};
    const result = evalLocation(&expr, regs.provider(), null);
    switch (result) {
        .empty => {},
        else => return error.TestUnexpectedResult,
    }
}

test "formatVariable formats integer correctly" {
    var raw = [_]u8{ 42, 0, 0, 0 };
    var buf: [64]u8 = undefined;
    const result = formatVariable(&raw, "int", DW_ATE_signed, 4, &buf);
    try std.testing.expectEqualStrings("42", result);
}

test "formatVariable formats negative integer" {
    // -1 as i32 = 0xFFFFFFFF
    var raw = [_]u8{ 0xFF, 0xFF, 0xFF, 0xFF };
    var buf: [64]u8 = undefined;
    const result = formatVariable(&raw, "int", DW_ATE_signed, 4, &buf);
    try std.testing.expectEqualStrings("-1", result);
}

test "formatVariable formats pointer as hex address" {
    var raw: [8]u8 = undefined;
    std.mem.writeInt(u64, &raw, 0xDEADBEEF, .little);
    var buf: [64]u8 = undefined;
    const result = formatVariable(&raw, "int*", DW_ATE_address, 8, &buf);
    try std.testing.expectEqualStrings("0xdeadbeef", result);
}

test "formatVariable formats boolean" {
    var raw_true = [_]u8{1};
    var raw_false = [_]u8{0};
    var buf: [64]u8 = undefined;

    const true_str = formatVariable(&raw_true, "bool", DW_ATE_boolean, 1, &buf);
    try std.testing.expectEqualStrings("true", true_str);

    const false_str = formatVariable(&raw_false, "bool", DW_ATE_boolean, 1, &buf);
    try std.testing.expectEqualStrings("false", false_str);
}

test "formatVariable formats unsigned integer" {
    var raw = [_]u8{ 255, 0, 0, 0 };
    var buf: [64]u8 = undefined;
    const result = formatVariable(&raw, "unsigned int", DW_ATE_unsigned, 4, &buf);
    try std.testing.expectEqualStrings("255", result);
}

test "formatVariable formats empty bytes as optimized out" {
    const raw = [_]u8{};
    var buf: [64]u8 = undefined;
    const result = formatVariable(&raw, "int", DW_ATE_signed, 4, &buf);
    try std.testing.expectEqualStrings("<optimized out>", result);
}

test "formatVariable formats struct with field names" {
    // Struct with two i32 fields: {x: 42, y: 10}
    var raw: [8]u8 = undefined;
    std.mem.writeInt(i32, raw[0..4], 42, .little);
    std.mem.writeInt(i32, raw[4..8], 10, .little);

    const fields = [_]StructFieldInfo{
        .{ .name = "x", .offset = 0, .encoding = DW_ATE_signed, .byte_size = 4 },
        .{ .name = "y", .offset = 4, .encoding = DW_ATE_signed, .byte_size = 4 },
    };

    var buf: [128]u8 = undefined;
    const result = formatStruct(&raw, &fields, &buf);
    try std.testing.expectEqualStrings("{x: 42, y: 10}", result);
}

test "formatVariable formats array with elements" {
    // Array of 3 i32: [1, 2, 3]
    var raw: [12]u8 = undefined;
    std.mem.writeInt(i32, raw[0..4], 1, .little);
    std.mem.writeInt(i32, raw[4..8], 2, .little);
    std.mem.writeInt(i32, raw[8..12], 3, .little);

    var buf: [128]u8 = undefined;
    const result = formatArray(&raw, DW_ATE_signed, 4, 3, &buf);
    try std.testing.expectEqualStrings("[1, 2, 3]", result);
}

const MockMemory = struct {
    data: std.AutoHashMap(u64, u64),

    fn init(allocator: std.mem.Allocator) MockMemory {
        return .{ .data = std.AutoHashMap(u64, u64).init(allocator) };
    }

    fn deinit(self: *MockMemory) void {
        self.data.deinit();
    }

    fn readMem(ctx: *anyopaque, addr: u64, size: usize) ?u64 {
        _ = size;
        const self: *MockMemory = @ptrCast(@alignCast(ctx));
        return self.data.get(addr);
    }

    fn reader(self: *MockMemory) MemoryReader {
        return .{
            .ptr = @ptrCast(self),
            .readFn = readMem,
        };
    }
};

test "inspectLocals returns all variables in current frame" {
    // Set up variables with stack_value location expressions
    const var_x = parser.VariableInfo{
        .name = "x",
        .location_expr = &[_]u8{ DW_OP_constu, 42, DW_OP_stack_value },
        .type_encoding = DW_ATE_signed,
        .type_byte_size = 4,
        .type_name = "int",
    };
    const var_y = parser.VariableInfo{
        .name = "y",
        .location_expr = &[_]u8{ DW_OP_constu, 10, DW_OP_stack_value },
        .type_encoding = DW_ATE_signed,
        .type_byte_size = 4,
        .type_name = "int",
    };
    const vars = [_]parser.VariableInfo{ var_x, var_y };

    var regs = MockRegisters{};
    const results = try inspectLocals(&vars, regs.provider(), null, null, std.testing.allocator);
    defer freeInspectResults(results, std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), results.len);
    try std.testing.expectEqualStrings("x", results[0].name);
    try std.testing.expectEqualStrings("42", results[0].value_str);
    try std.testing.expectEqualStrings("int", results[0].type_str);
    try std.testing.expectEqualStrings("y", results[1].name);
    try std.testing.expectEqualStrings("10", results[1].value_str);
}

test "inspectLocals reads correct integer value from memory" {
    // Variable at frame_base - 8, value is 99
    const var_x = parser.VariableInfo{
        .name = "x",
        .location_expr = &[_]u8{ DW_OP_fbreg, 0x78 }, // fbreg offset -8
        .type_encoding = DW_ATE_signed,
        .type_byte_size = 4,
        .type_name = "int",
    };
    const vars = [_]parser.VariableInfo{var_x};

    var regs = MockRegisters{};
    var mem = MockMemory.init(std.testing.allocator);
    defer mem.deinit();
    // Frame base is 0x1000, variable at 0x1000 - 8 = 0xFF8
    try mem.data.put(0xFF8, 99);

    const results = try inspectLocals(&vars, regs.provider(), 0x1000, mem.reader(), std.testing.allocator);
    defer freeInspectResults(results, std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("x", results[0].name);
    try std.testing.expectEqualStrings("99", results[0].value_str);
}

test "evalLocationWithMemory handles DW_OP_deref with reader" {
    var expr: [10]u8 = undefined;
    expr[0] = DW_OP_addr;
    std.mem.writeInt(u64, expr[1..9], 0x2000, .little);
    expr[9] = DW_OP_deref;

    var regs = MockRegisters{};
    var mem = MockMemory.init(std.testing.allocator);
    defer mem.deinit();
    try mem.data.put(0x2000, 0xCAFEBABE);

    const result = evalLocationWithMemory(&expr, regs.provider(), null, mem.reader());
    switch (result) {
        .address => |addr| try std.testing.expectEqual(@as(u64, 0xCAFEBABE), addr),
        else => return error.TestUnexpectedResult,
    }
}
