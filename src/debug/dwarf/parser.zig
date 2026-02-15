const std = @import("std");
const builtin = @import("builtin");
const binary_macho = @import("binary_macho.zig");

// ── DWARF Debug Info Parser ────────────────────────────────────────────

// DWARF line number program opcodes
const DW_LNS_copy = 1;
const DW_LNS_advance_pc = 2;
const DW_LNS_advance_line = 3;
const DW_LNS_set_file = 4;
const DW_LNS_set_column = 5;
const DW_LNS_negate_stmt = 6;
const DW_LNS_set_basic_block = 7;
const DW_LNS_const_add_pc = 8;
const DW_LNS_fixed_advance_pc = 9;
const DW_LNS_set_prologue_end = 10;
const DW_LNS_set_epilogue_begin = 11;
const DW_LNS_set_isa = 12;

// Extended opcodes
const DW_LNE_end_sequence = 1;
const DW_LNE_set_address = 2;
const DW_LNE_define_file = 3;
const DW_LNE_set_discriminator = 4;

// Tag constants
const DW_TAG_compile_unit: u64 = 0x11;
const DW_TAG_subprogram: u64 = 0x2e;
const DW_TAG_variable: u64 = 0x34;
const DW_TAG_formal_parameter: u64 = 0x05;
const DW_TAG_base_type: u64 = 0x24;
const DW_TAG_structure_type: u64 = 0x13;
const DW_TAG_array_type: u64 = 0x01;
const DW_TAG_member: u64 = 0x0d;
const DW_TAG_subrange_type: u64 = 0x21;
const DW_TAG_pointer_type: u64 = 0x0f;
const DW_TAG_typedef: u64 = 0x16;
const DW_TAG_const_type: u64 = 0x26;

// Attribute constants
const DW_AT_name: u64 = 0x03;
const DW_AT_low_pc: u64 = 0x11;
const DW_AT_high_pc: u64 = 0x12;
const DW_AT_location: u64 = 0x02;
const DW_AT_type: u64 = 0x49;
const DW_AT_encoding: u64 = 0x3e;
const DW_AT_byte_size: u64 = 0x0b;
const DW_AT_data_member_location: u64 = 0x38;
const DW_AT_upper_bound: u64 = 0x2f;
const DW_AT_count: u64 = 0x37;

// Form constants
const DW_FORM_addr: u64 = 0x01;
const DW_FORM_block2: u64 = 0x03;
const DW_FORM_block4: u64 = 0x04;
const DW_FORM_data2: u64 = 0x05;
const DW_FORM_data4: u64 = 0x06;
const DW_FORM_data8: u64 = 0x07;
const DW_FORM_string: u64 = 0x08;
const DW_FORM_block: u64 = 0x09;
const DW_FORM_block1: u64 = 0x0a;
const DW_FORM_data1: u64 = 0x0b;
const DW_FORM_flag: u64 = 0x0c;
const DW_FORM_sdata: u64 = 0x0d;
const DW_FORM_strp: u64 = 0x0e;
const DW_FORM_udata: u64 = 0x0f;
const DW_FORM_ref_addr: u64 = 0x10;
const DW_FORM_ref1: u64 = 0x11;
const DW_FORM_ref2: u64 = 0x12;
const DW_FORM_ref4: u64 = 0x13;
const DW_FORM_ref8: u64 = 0x14;
const DW_FORM_ref_udata: u64 = 0x15;
const DW_FORM_sec_offset: u64 = 0x17;
const DW_FORM_exprloc: u64 = 0x18;
const DW_FORM_flag_present: u64 = 0x19;
const DW_FORM_strx: u64 = 0x1a;
const DW_FORM_addrx: u64 = 0x1b;
const DW_FORM_strx1: u64 = 0x25;
const DW_FORM_strx2: u64 = 0x26;
const DW_FORM_strx4: u64 = 0x27;
const DW_FORM_addrx1: u64 = 0x29;
const DW_FORM_addrx2: u64 = 0x2a;
const DW_FORM_addrx4: u64 = 0x2b;
const DW_FORM_data16: u64 = 0x1e;
const DW_FORM_line_strp: u64 = 0x1f;
const DW_FORM_implicit_const: u64 = 0x21;
const DW_FORM_rnglistx: u64 = 0x23;
const DW_FORM_loclistx: u64 = 0x22;
const DW_FORM_ref_sig8: u64 = 0x20;

// Children flag
const DW_CHILDREN_yes: u8 = 1;

pub const SourceLocation = struct {
    file: []const u8,
    line: u32,
    column: u32,
};

pub const AddressRange = struct {
    name: []const u8,
    low_pc: u64,
    high_pc: u64,
};

pub const LineEntry = struct {
    address: u64,
    file_index: u32,
    line: u32,
    column: u32,
    is_stmt: bool,
    end_sequence: bool,
};

pub const AbbrevEntry = struct {
    code: u64,
    tag: u64,
    has_children: bool,
    attributes: []const AbbrevAttr,
};

pub const AbbrevAttr = struct {
    name: u64,
    form: u64,
    implicit_const: i64,
};

pub const FunctionInfo = struct {
    name: []const u8,
    low_pc: u64,
    high_pc: u64,
};

pub const VariableInfo = struct {
    name: []const u8,
    location_expr: []const u8,
    type_encoding: u8,
    type_byte_size: u8,
    type_name: []const u8,
};

// ── LEB128 Encoding ────────────────────────────────────────────────────

pub fn readULEB128(data: []const u8, pos: *usize) !u64 {
    var result: u64 = 0;
    var shift: u32 = 0;
    while (pos.* < data.len) {
        const byte = data[pos.*];
        pos.* += 1;
        if (shift < 64) {
            result |= @as(u64, byte & 0x7f) << @intCast(shift);
        }
        if (byte & 0x80 == 0) return result;
        shift += 7;
        if (shift > 70) return error.Overflow;
    }
    return error.UnexpectedEndOfData;
}

pub fn readSLEB128(data: []const u8, pos: *usize) !i64 {
    var result: u64 = 0;
    var shift: u32 = 0;
    var last_byte: u8 = 0;
    while (pos.* < data.len) {
        const byte = data[pos.*];
        pos.* += 1;
        last_byte = byte;
        if (shift < 64) {
            result |= @as(u64, byte & 0x7f) << @intCast(shift);
        }
        shift += 7;
        if (byte & 0x80 == 0) {
            // Sign extend if the sign bit of the last byte is set
            if (shift < 64 and (last_byte & 0x40) != 0) {
                result |= ~@as(u64, 0) << @intCast(shift);
            }
            return @bitCast(result);
        }
        if (shift > 70) return error.Overflow;
    }
    return error.UnexpectedEndOfData;
}

// ── Abbreviation Table Parser ──────────────────────────────────────────

pub fn parseAbbrevTable(data: []const u8, allocator: std.mem.Allocator) ![]AbbrevEntry {
    var entries: std.ArrayListUnmanaged(AbbrevEntry) = .empty;
    defer {
        // Only free attribute slices on error; on success, caller owns them
    }
    errdefer {
        for (entries.items) |entry| {
            allocator.free(entry.attributes);
        }
        entries.deinit(allocator);
    }

    var pos: usize = 0;
    while (pos < data.len) {
        const code = try readULEB128(data, &pos);
        if (code == 0) break; // End of table

        const tag = try readULEB128(data, &pos);
        if (pos >= data.len) break;
        const has_children = data[pos] == DW_CHILDREN_yes;
        pos += 1;

        var attrs: std.ArrayListUnmanaged(AbbrevAttr) = .empty;
        errdefer attrs.deinit(allocator);

        while (pos < data.len) {
            const attr_name = try readULEB128(data, &pos);
            const attr_form = try readULEB128(data, &pos);
            if (attr_name == 0 and attr_form == 0) break;

            var implicit_const: i64 = 0;
            if (attr_form == DW_FORM_implicit_const) {
                implicit_const = try readSLEB128(data, &pos);
            }

            try attrs.append(allocator, .{
                .name = attr_name,
                .form = attr_form,
                .implicit_const = implicit_const,
            });
        }

        try entries.append(allocator, .{
            .code = code,
            .tag = tag,
            .has_children = has_children,
            .attributes = try attrs.toOwnedSlice(allocator),
        });
    }

    return try entries.toOwnedSlice(allocator);
}

pub fn freeAbbrevTable(entries: []AbbrevEntry, allocator: std.mem.Allocator) void {
    for (entries) |entry| {
        allocator.free(entry.attributes);
    }
    allocator.free(entries);
}

// ── Line Program Parser ────────────────────────────────────────────────

pub const LineProgramHeader = struct {
    unit_length: u64,
    version: u16,
    header_length: u64,
    min_instruction_length: u8,
    max_ops_per_instruction: u8,
    default_is_stmt: bool,
    line_base: i8,
    line_range: u8,
    opcode_base: u8,
    standard_opcode_lengths: []const u8,
    directories: []const []const u8,
    files: []const FileEntry,
    header_end: usize, // offset where line program bytecode starts
    unit_end: usize, // offset where this unit ends
};

pub const FileEntry = struct {
    name: []const u8,
    dir_index: u64,
};

pub fn parseLineProgram(data: []const u8, allocator: std.mem.Allocator) ![]LineEntry {
    if (data.len < 4) return error.TooSmall;

    var pos: usize = 0;

    // Unit length
    const unit_length_32 = readU32(data, &pos) catch return error.TooSmall;
    var is_64bit = false;
    var unit_length: u64 = unit_length_32;
    if (unit_length_32 == 0xFFFFFFFF) {
        unit_length = readU64(data, &pos) catch return error.TooSmall;
        is_64bit = true;
    }
    const unit_end = pos + @as(usize, @intCast(unit_length));

    // Version
    const version = readU16(data, &pos) catch return error.TooSmall;

    // Address size and segment selector size (DWARF 5+)
    if (version >= 5) {
        if (pos >= data.len) return error.TooSmall;
        // address_size
        pos += 1;
        // segment_selector_size
        pos += 1;
    }

    // Header length
    var header_length: u64 = undefined;
    if (is_64bit) {
        header_length = readU64(data, &pos) catch return error.TooSmall;
    } else {
        header_length = readU32(data, &pos) catch return error.TooSmall;
    }
    const header_end = pos + @as(usize, @intCast(header_length));

    if (pos >= data.len) return error.TooSmall;
    const min_instruction_length = data[pos];
    pos += 1;

    if (version >= 4) {
        if (pos >= data.len) return error.TooSmall;
        // max_operations_per_instruction (not used in state machine yet)
        pos += 1;
    }

    if (pos >= data.len) return error.TooSmall;
    const default_is_stmt = data[pos] != 0;
    pos += 1;

    if (pos >= data.len) return error.TooSmall;
    const line_base: i8 = @bitCast(data[pos]);
    pos += 1;

    if (pos >= data.len) return error.TooSmall;
    const line_range = data[pos];
    pos += 1;

    if (pos >= data.len) return error.TooSmall;
    const opcode_base = data[pos];
    pos += 1;

    // Standard opcode lengths (opcode_base - 1 entries)
    if (opcode_base > 1) {
        const count = @as(usize, opcode_base) - 1;
        if (pos + count > data.len) return error.TooSmall;
        pos += count; // Skip standard opcode lengths
    }

    // Directories and files (DWARF 5 uses a different format)
    var dirs: std.ArrayListUnmanaged([]const u8) = .empty;
    defer dirs.deinit(allocator);
    var files: std.ArrayListUnmanaged(FileEntry) = .empty;
    defer files.deinit(allocator);

    if (version >= 5) {
        // DWARF 5 directory/file entry format
        // directory_entry_format_count
        if (pos >= data.len) return error.TooSmall;
        const dir_format_count = data[pos];
        pos += 1;

        // Read directory entry format pairs
        var dir_forms: std.ArrayListUnmanaged([2]u64) = .empty;
        defer dir_forms.deinit(allocator);
        for (0..dir_format_count) |_| {
            const content_type = try readULEB128(data, &pos);
            const form = try readULEB128(data, &pos);
            try dir_forms.append(allocator, .{ content_type, form });
        }

        // directories_count
        const dir_count = try readULEB128(data, &pos);
        for (0..@intCast(dir_count)) |_| {
            var dir_name: []const u8 = "";
            for (dir_forms.items) |pair| {
                const form = pair[1];
                if (pair[0] == 1) { // DW_LNCT_path
                    if (form == DW_FORM_string) {
                        dir_name = readNullTermString(data, &pos);
                    } else if (form == DW_FORM_line_strp) {
                        // Skip the offset for now
                        if (is_64bit) {
                            pos += 8;
                        } else {
                            pos += 4;
                        }
                    } else if (form == DW_FORM_strp) {
                        if (is_64bit) {
                            pos += 8;
                        } else {
                            pos += 4;
                        }
                    } else {
                        try skipForm(data, &pos, form, is_64bit);
                    }
                } else {
                    try skipForm(data, &pos, form, is_64bit);
                }
            }
            try dirs.append(allocator, dir_name);
        }

        // file_name_entry_format_count
        if (pos >= data.len) return error.TooSmall;
        const file_format_count = data[pos];
        pos += 1;

        var file_forms: std.ArrayListUnmanaged([2]u64) = .empty;
        defer file_forms.deinit(allocator);
        for (0..file_format_count) |_| {
            const content_type = try readULEB128(data, &pos);
            const form = try readULEB128(data, &pos);
            try file_forms.append(allocator, .{ content_type, form });
        }

        // file_names_count
        const file_count = try readULEB128(data, &pos);
        for (0..@intCast(file_count)) |_| {
            var file_name: []const u8 = "";
            var dir_index: u64 = 0;
            for (file_forms.items) |pair| {
                const form = pair[1];
                if (pair[0] == 1) { // DW_LNCT_path
                    if (form == DW_FORM_string) {
                        file_name = readNullTermString(data, &pos);
                    } else if (form == DW_FORM_line_strp) {
                        if (is_64bit) {
                            pos += 8;
                        } else {
                            pos += 4;
                        }
                    } else if (form == DW_FORM_strp) {
                        if (is_64bit) {
                            pos += 8;
                        } else {
                            pos += 4;
                        }
                    } else {
                        try skipForm(data, &pos, form, is_64bit);
                    }
                } else if (pair[0] == 2) { // DW_LNCT_directory_index
                    if (form == DW_FORM_data1 and pos < data.len) {
                        dir_index = data[pos];
                        pos += 1;
                    } else if (form == DW_FORM_data2) {
                        dir_index = readU16(data, &pos) catch 0;
                    } else if (form == DW_FORM_udata) {
                        dir_index = readULEB128(data, &pos) catch 0;
                    } else {
                        try skipForm(data, &pos, form, is_64bit);
                    }
                } else {
                    try skipForm(data, &pos, form, is_64bit);
                }
            }
            try files.append(allocator, .{ .name = file_name, .dir_index = dir_index });
        }
    } else {
        // DWARF 4 directory and file tables
        // Directories (null-terminated strings, terminated by empty string)
        while (pos < data.len and data[pos] != 0) {
            const dir = readNullTermString(data, &pos);
            try dirs.append(allocator, dir);
        }
        if (pos < data.len) pos += 1; // Skip terminating 0

        // Files
        while (pos < data.len and data[pos] != 0) {
            const name = readNullTermString(data, &pos);
            const dir_index = try readULEB128(data, &pos);
            _ = try readULEB128(data, &pos); // mod time
            _ = try readULEB128(data, &pos); // file size
            try files.append(allocator, .{ .name = name, .dir_index = dir_index });
        }
        if (pos < data.len) pos += 1; // Skip terminating 0
    }

    // Execute line program
    pos = header_end;
    var entries: std.ArrayListUnmanaged(LineEntry) = .empty;
    errdefer entries.deinit(allocator);

    // State machine
    var address: u64 = 0;
    var file_index: u32 = 1;
    var line: u32 = 1;
    var column: u32 = 0;
    var is_stmt: bool = default_is_stmt;
    var end_sequence: bool = false;

    while (pos < unit_end and pos < data.len) {
        const opcode = data[pos];
        pos += 1;

        if (opcode == 0) {
            // Extended opcode
            const ext_len = try readULEB128(data, &pos);
            const ext_end = pos + @as(usize, @intCast(ext_len));
            if (pos >= data.len) break;
            const ext_opcode = data[pos];
            pos += 1;

            switch (ext_opcode) {
                DW_LNE_end_sequence => {
                    end_sequence = true;
                    try entries.append(allocator, .{
                        .address = address,
                        .file_index = file_index,
                        .line = line,
                        .column = column,
                        .is_stmt = is_stmt,
                        .end_sequence = true,
                    });
                    // Reset state
                    address = 0;
                    file_index = 1;
                    line = 1;
                    column = 0;
                    is_stmt = default_is_stmt;
                    end_sequence = false;
                },
                DW_LNE_set_address => {
                    if (pos + 8 <= data.len) {
                        address = std.mem.readInt(u64, data[pos..][0..8], .little);
                    }
                    pos = ext_end;
                },
                DW_LNE_set_discriminator => {
                    _ = readULEB128(data, &pos) catch {};
                },
                else => {
                    pos = ext_end;
                },
            }
            if (pos < ext_end) pos = ext_end;
        } else if (opcode < opcode_base) {
            // Standard opcode
            switch (opcode) {
                DW_LNS_copy => {
                    try entries.append(allocator, .{
                        .address = address,
                        .file_index = file_index,
                        .line = line,
                        .column = column,
                        .is_stmt = is_stmt,
                        .end_sequence = false,
                    });
                },
                DW_LNS_advance_pc => {
                    const advance = try readULEB128(data, &pos);
                    address += advance * min_instruction_length;
                },
                DW_LNS_advance_line => {
                    const advance = try readSLEB128(data, &pos);
                    const new_line = @as(i64, line) + advance;
                    if (new_line > 0) {
                        line = @intCast(new_line);
                    }
                },
                DW_LNS_set_file => {
                    file_index = @intCast(try readULEB128(data, &pos));
                },
                DW_LNS_set_column => {
                    column = @intCast(try readULEB128(data, &pos));
                },
                DW_LNS_negate_stmt => {
                    is_stmt = !is_stmt;
                },
                DW_LNS_set_basic_block => {},
                DW_LNS_const_add_pc => {
                    if (line_range > 0) {
                        const adjust = (255 - opcode_base) / line_range;
                        address += @as(u64, adjust) * min_instruction_length;
                    }
                },
                DW_LNS_fixed_advance_pc => {
                    if (pos + 2 <= data.len) {
                        address += std.mem.readInt(u16, data[pos..][0..2], .little);
                        pos += 2;
                    }
                },
                DW_LNS_set_prologue_end, DW_LNS_set_epilogue_begin => {},
                DW_LNS_set_isa => {
                    _ = try readULEB128(data, &pos);
                },
                else => {
                    // Unknown standard opcode: skip its operands
                },
            }
        } else {
            // Special opcode
            if (line_range > 0) {
                const adjusted = @as(u32, opcode) - @as(u32, opcode_base);
                const line_inc = @as(i32, line_base) + @as(i32, @intCast(adjusted % line_range));
                const addr_inc = (adjusted / line_range) * min_instruction_length;
                address += addr_inc;
                const new_line = @as(i64, line) + line_inc;
                if (new_line > 0) {
                    line = @intCast(new_line);
                }
                try entries.append(allocator, .{
                    .address = address,
                    .file_index = file_index,
                    .line = line,
                    .column = column,
                    .is_stmt = is_stmt,
                    .end_sequence = false,
                });
            }
        }
    }

    return try entries.toOwnedSlice(allocator);
}

/// Resolve an address to a source location using line entries.
pub fn resolveAddress(entries: []const LineEntry, files: []const FileEntry, address: u64) ?SourceLocation {
    // Find the line entry with the largest address <= target address
    var best: ?*const LineEntry = null;
    for (entries) |*entry| {
        if (entry.end_sequence) continue;
        if (entry.address <= address) {
            if (best == null or entry.address > best.?.address) {
                best = entry;
            }
        }
    }

    if (best) |entry| {
        const file_name = getFileName(files, entry.file_index);
        return .{
            .file = file_name,
            .line = entry.line,
            .column = entry.column,
        };
    }
    return null;
}

fn getFileName(files: []const FileEntry, index: u32) []const u8 {
    // DWARF 4: file indices are 1-based
    // DWARF 5: file indices are 0-based
    if (index > 0 and index - 1 < files.len) {
        return files[index - 1].name;
    }
    if (index < files.len) {
        return files[index].name;
    }
    return "<unknown>";
}

/// Additional sections needed for DWARF 5 indirect resolution.
pub const ExtraSections = struct {
    debug_str_offsets: ?[]const u8 = null,
    debug_addr: ?[]const u8 = null,
};

/// Parse .debug_info to extract function names.
pub fn parseCompilationUnit(
    debug_info: []const u8,
    debug_abbrev: []const u8,
    debug_str: ?[]const u8,
    allocator: std.mem.Allocator,
) ![]FunctionInfo {
    return parseCompilationUnitEx(debug_info, debug_abbrev, debug_str, .{}, allocator);
}

/// Parse .debug_info with optional DWARF 5 sections.
pub fn parseCompilationUnitEx(
    debug_info: []const u8,
    debug_abbrev: []const u8,
    debug_str: ?[]const u8,
    extra: ExtraSections,
    allocator: std.mem.Allocator,
) ![]FunctionInfo {
    var functions: std.ArrayListUnmanaged(FunctionInfo) = .empty;
    errdefer functions.deinit(allocator);

    if (debug_info.len < 11) return try functions.toOwnedSlice(allocator);

    var pos: usize = 0;

    // Compilation unit header
    const unit_length_32 = readU32(debug_info, &pos) catch return try functions.toOwnedSlice(allocator);
    var is_64bit = false;
    var unit_length: u64 = unit_length_32;
    if (unit_length_32 == 0xFFFFFFFF) {
        unit_length = readU64(debug_info, &pos) catch return try functions.toOwnedSlice(allocator);
        is_64bit = true;
    }
    const unit_end = pos + @as(usize, @intCast(unit_length));

    const version = readU16(debug_info, &pos) catch return try functions.toOwnedSlice(allocator);

    // DWARF 5 has unit_type before debug_abbrev_offset
    var address_size: u8 = 8;
    var abbrev_offset: u64 = undefined;
    if (version >= 5) {
        if (pos >= debug_info.len) return try functions.toOwnedSlice(allocator);
        _ = debug_info[pos]; // unit_type
        pos += 1;
        if (pos >= debug_info.len) return try functions.toOwnedSlice(allocator);
        address_size = debug_info[pos];
        pos += 1;
        if (is_64bit) {
            abbrev_offset = readU64(debug_info, &pos) catch return try functions.toOwnedSlice(allocator);
        } else {
            abbrev_offset = readU32(debug_info, &pos) catch return try functions.toOwnedSlice(allocator);
        }
    } else {
        if (is_64bit) {
            abbrev_offset = readU64(debug_info, &pos) catch return try functions.toOwnedSlice(allocator);
        } else {
            abbrev_offset = readU32(debug_info, &pos) catch return try functions.toOwnedSlice(allocator);
        }
        if (pos >= debug_info.len) return try functions.toOwnedSlice(allocator);
        address_size = debug_info[pos];
        pos += 1;
    }

    // Parse abbreviation table at the given offset
    const abbrev_data = if (abbrev_offset < debug_abbrev.len)
        debug_abbrev[@intCast(abbrev_offset)..]
    else
        return try functions.toOwnedSlice(allocator);

    const abbrevs = parseAbbrevTable(abbrev_data, allocator) catch return try functions.toOwnedSlice(allocator);
    defer freeAbbrevTable(abbrevs, allocator);

    // Track DWARF 5 bases (set from DW_AT_str_offsets_base and DW_AT_addr_base)
    var str_offsets_base: u64 = 0;
    var addr_base: u64 = 0;
    const DW_AT_str_offsets_base: u64 = 0x72;
    const DW_AT_addr_base: u64 = 0x73;

    // First pass: find bases from compile unit DIE
    if (version >= 5) {
        var first_pos = pos;
        const first_code = readULEB128(debug_info, &first_pos) catch 0;
        if (first_code != 0) {
            if (findAbbrev(abbrevs, first_code)) |first_abbrev| {
                for (first_abbrev.attributes) |attr| {
                    if (attr.form == DW_FORM_implicit_const) continue;

                    if (attr.name == DW_AT_str_offsets_base) {
                        if (attr.form == DW_FORM_sec_offset) {
                            str_offsets_base = if (is_64bit)
                                readU64(debug_info, &first_pos) catch 0
                            else
                                readU32(debug_info, &first_pos) catch 0;
                        } else {
                            skipForm(debug_info, &first_pos, attr.form, is_64bit) catch break;
                        }
                    } else if (attr.name == DW_AT_addr_base) {
                        if (attr.form == DW_FORM_sec_offset) {
                            addr_base = if (is_64bit)
                                readU64(debug_info, &first_pos) catch 0
                            else
                                readU32(debug_info, &first_pos) catch 0;
                        } else {
                            skipForm(debug_info, &first_pos, attr.form, is_64bit) catch break;
                        }
                    } else {
                        skipForm(debug_info, &first_pos, attr.form, is_64bit) catch break;
                    }
                }
            }
        }
    }

    // Walk DIEs
    while (pos < unit_end and pos < debug_info.len) {
        const abbrev_code = readULEB128(debug_info, &pos) catch break;
        if (abbrev_code == 0) continue; // Null entry

        // Find abbreviation
        const abbrev = findAbbrev(abbrevs, abbrev_code) orelse break;

        var name: ?[]const u8 = null;
        var low_pc: u64 = 0;
        var high_pc: u64 = 0;
        var high_pc_is_offset = false;

        for (abbrev.attributes) |attr| {
            if (attr.form == DW_FORM_implicit_const) {
                continue;
            }

            // Read attribute value
            switch (attr.name) {
                DW_AT_name => {
                    if (attr.form == DW_FORM_string) {
                        name = readNullTermString(debug_info, &pos);
                    } else if (attr.form == DW_FORM_strp) {
                        const str_offset = if (is_64bit)
                            readU64(debug_info, &pos) catch break
                        else
                            readU32(debug_info, &pos) catch break;
                        if (debug_str) |str_section| {
                            name = readStringAt(str_section, @intCast(str_offset));
                        }
                    } else if (attr.form == DW_FORM_strx or attr.form == DW_FORM_strx1 or
                        attr.form == DW_FORM_strx2 or attr.form == DW_FORM_strx4)
                    {
                        // DWARF 5: resolve through str_offsets table
                        const index = readFormIndex(debug_info, &pos, attr.form) catch break;
                        name = resolveStrx(debug_str, extra.debug_str_offsets, str_offsets_base, index, is_64bit);
                    } else {
                        skipForm(debug_info, &pos, attr.form, is_64bit) catch break;
                    }
                },
                DW_AT_low_pc => {
                    if (attr.form == DW_FORM_addr) {
                        if (address_size == 8) {
                            low_pc = readU64(debug_info, &pos) catch break;
                        } else {
                            low_pc = readU32(debug_info, &pos) catch break;
                        }
                    } else if (attr.form == DW_FORM_addrx or attr.form == DW_FORM_addrx1 or
                        attr.form == DW_FORM_addrx2 or attr.form == DW_FORM_addrx4)
                    {
                        const index = readFormIndex(debug_info, &pos, attr.form) catch break;
                        low_pc = resolveAddrx(extra.debug_addr, addr_base, index, address_size);
                    } else {
                        skipForm(debug_info, &pos, attr.form, is_64bit) catch break;
                    }
                },
                DW_AT_high_pc => {
                    if (attr.form == DW_FORM_addr) {
                        if (address_size == 8) {
                            high_pc = readU64(debug_info, &pos) catch break;
                        } else {
                            high_pc = readU32(debug_info, &pos) catch break;
                        }
                    } else if (attr.form == DW_FORM_data1 or attr.form == DW_FORM_data2 or
                        attr.form == DW_FORM_data4 or attr.form == DW_FORM_data8 or
                        attr.form == DW_FORM_udata or attr.form == DW_FORM_sdata)
                    {
                        high_pc_is_offset = true;
                        if (attr.form == DW_FORM_data1 and pos < debug_info.len) {
                            high_pc = debug_info[pos];
                            pos += 1;
                        } else if (attr.form == DW_FORM_data2) {
                            high_pc = readU16(debug_info, &pos) catch break;
                        } else if (attr.form == DW_FORM_data4) {
                            high_pc = readU32(debug_info, &pos) catch break;
                        } else if (attr.form == DW_FORM_data8) {
                            high_pc = readU64(debug_info, &pos) catch break;
                        } else if (attr.form == DW_FORM_udata) {
                            high_pc = readULEB128(debug_info, &pos) catch break;
                        } else if (attr.form == DW_FORM_sdata) {
                            const s = readSLEB128(debug_info, &pos) catch break;
                            high_pc = @intCast(s);
                        }
                    } else {
                        skipForm(debug_info, &pos, attr.form, is_64bit) catch break;
                    }
                },
                else => {
                    skipForm(debug_info, &pos, attr.form, is_64bit) catch break;
                },
            }
        }

        if (high_pc_is_offset) {
            high_pc = low_pc + high_pc;
        }

        if (abbrev.tag == DW_TAG_subprogram) {
            if (name) |n| {
                try functions.append(allocator, .{
                    .name = n,
                    .low_pc = low_pc,
                    .high_pc = high_pc,
                });
            }
        }
    }

    return try functions.toOwnedSlice(allocator);
}

/// Read an index value from a DW_FORM_strx* or DW_FORM_addrx* form.
fn readFormIndex(data: []const u8, pos: *usize, form: u64) !u64 {
    return switch (form) {
        DW_FORM_strx1, DW_FORM_addrx1 => blk: {
            if (pos.* >= data.len) break :blk error.OutOfBounds;
            const v = data[pos.*];
            pos.* += 1;
            break :blk @as(u64, v);
        },
        DW_FORM_strx2, DW_FORM_addrx2 => readU16(data, pos) catch |e| return e,
        DW_FORM_strx4, DW_FORM_addrx4 => readU32(data, pos) catch |e| return e,
        DW_FORM_strx, DW_FORM_addrx => readULEB128(data, pos),
        else => error.UnknownForm,
    };
}

/// Resolve a DW_FORM_strx index to a string via .debug_str_offsets and .debug_str.
fn resolveStrx(debug_str: ?[]const u8, str_offsets: ?[]const u8, base: u64, index: u64, is_64bit: bool) ?[]const u8 {
    const offsets = str_offsets orelse return null;
    const str = debug_str orelse return null;

    const entry_size: u64 = if (is_64bit) 8 else 4;
    const offset_pos = base + index * entry_size;

    if (offset_pos + entry_size > offsets.len) return null;

    const str_offset: u64 = if (is_64bit)
        std.mem.readInt(u64, offsets[@intCast(offset_pos)..][0..8], .little)
    else
        std.mem.readInt(u32, offsets[@intCast(offset_pos)..][0..4], .little);

    return readStringAt(str, @intCast(str_offset));
}

/// Resolve a DW_FORM_addrx index to an address via .debug_addr.
fn resolveAddrx(debug_addr_section: ?[]const u8, base: u64, index: u64, address_size: u8) u64 {
    const addr_data = debug_addr_section orelse return 0;

    const offset_pos = base + index * address_size;
    if (offset_pos + address_size > addr_data.len) return 0;

    if (address_size == 8) {
        return std.mem.readInt(u64, addr_data[@intCast(offset_pos)..][0..8], .little);
    } else if (address_size == 4) {
        return std.mem.readInt(u32, addr_data[@intCast(offset_pos)..][0..4], .little);
    }
    return 0;
}

/// Find a function by name in parsed function list.
pub fn resolveFunction(functions: []const FunctionInfo, name: []const u8) ?AddressRange {
    for (functions) |f| {
        if (std.mem.eql(u8, f.name, name)) {
            return .{
                .name = f.name,
                .low_pc = f.low_pc,
                .high_pc = f.high_pc,
            };
        }
    }
    return null;
}

/// Parse .debug_info to extract variable declarations (DW_TAG_variable and DW_TAG_formal_parameter).
pub fn parseVariables(
    debug_info: []const u8,
    debug_abbrev: []const u8,
    debug_str: ?[]const u8,
    allocator: std.mem.Allocator,
) ![]VariableInfo {
    return parseVariablesEx(debug_info, debug_abbrev, debug_str, .{}, allocator);
}

/// Parse variables with optional DWARF 5 sections.
pub fn parseVariablesEx(
    debug_info: []const u8,
    debug_abbrev: []const u8,
    debug_str: ?[]const u8,
    extra: ExtraSections,
    allocator: std.mem.Allocator,
) ![]VariableInfo {
    var variables: std.ArrayListUnmanaged(VariableInfo) = .empty;
    errdefer {
        for (variables.items) |v| {
            allocator.free(v.location_expr);
        }
        variables.deinit(allocator);
    }

    if (debug_info.len < 11) return try variables.toOwnedSlice(allocator);

    var pos: usize = 0;

    // Compilation unit header
    const unit_length_32 = readU32(debug_info, &pos) catch return try variables.toOwnedSlice(allocator);
    var is_64bit = false;
    var unit_length: u64 = unit_length_32;
    if (unit_length_32 == 0xFFFFFFFF) {
        unit_length = readU64(debug_info, &pos) catch return try variables.toOwnedSlice(allocator);
        is_64bit = true;
    }
    const unit_end = pos + @as(usize, @intCast(unit_length));
    const cu_start = if (is_64bit) @as(usize, 12) else @as(usize, 4);

    const version = readU16(debug_info, &pos) catch return try variables.toOwnedSlice(allocator);

    var address_size: u8 = 8;
    var abbrev_offset: u64 = undefined;
    if (version >= 5) {
        if (pos >= debug_info.len) return try variables.toOwnedSlice(allocator);
        pos += 1; // unit_type
        if (pos >= debug_info.len) return try variables.toOwnedSlice(allocator);
        address_size = debug_info[pos];
        pos += 1;
        abbrev_offset = if (is_64bit)
            readU64(debug_info, &pos) catch return try variables.toOwnedSlice(allocator)
        else
            readU32(debug_info, &pos) catch return try variables.toOwnedSlice(allocator);
    } else {
        abbrev_offset = if (is_64bit)
            readU64(debug_info, &pos) catch return try variables.toOwnedSlice(allocator)
        else
            readU32(debug_info, &pos) catch return try variables.toOwnedSlice(allocator);
        if (pos >= debug_info.len) return try variables.toOwnedSlice(allocator);
        address_size = debug_info[pos];
        pos += 1;
    }

    const abbrev_data = if (abbrev_offset < debug_abbrev.len)
        debug_abbrev[@intCast(abbrev_offset)..]
    else
        return try variables.toOwnedSlice(allocator);

    const abbrevs = parseAbbrevTable(abbrev_data, allocator) catch return try variables.toOwnedSlice(allocator);
    defer freeAbbrevTable(abbrevs, allocator);

    // Collect base type info by offset for type resolution
    const TypeInfo = struct { encoding: u8, byte_size: u8, name: []const u8 };
    var type_map = std.AutoHashMap(u64, TypeInfo).init(allocator);
    defer type_map.deinit();

    // First pass: collect base types
    {
        var scan_pos = pos;
        while (scan_pos < unit_end and scan_pos < debug_info.len) {
            const die_offset = scan_pos - cu_start; // offset relative to CU start
            const abbrev_code = readULEB128(debug_info, &scan_pos) catch break;
            if (abbrev_code == 0) continue;
            const abbrev = findAbbrev(abbrevs, abbrev_code) orelse break;

            var t_name: ?[]const u8 = null;
            var t_encoding: u8 = 0;
            var t_byte_size: u8 = 0;

            for (abbrev.attributes) |attr| {
                if (attr.form == DW_FORM_implicit_const) continue;
                switch (attr.name) {
                    DW_AT_name => {
                        if (attr.form == DW_FORM_string) {
                            t_name = readNullTermString(debug_info, &scan_pos);
                        } else if (attr.form == DW_FORM_strp) {
                            const str_offset = if (is_64bit)
                                readU64(debug_info, &scan_pos) catch break
                            else
                                readU32(debug_info, &scan_pos) catch break;
                            if (debug_str) |s| t_name = readStringAt(s, @intCast(str_offset));
                        } else if (attr.form == DW_FORM_strx or attr.form == DW_FORM_strx1 or
                            attr.form == DW_FORM_strx2 or attr.form == DW_FORM_strx4)
                        {
                            const index = readFormIndex(debug_info, &scan_pos, attr.form) catch break;
                            t_name = resolveStrx(debug_str, extra.debug_str_offsets, 0, index, is_64bit);
                        } else {
                            skipForm(debug_info, &scan_pos, attr.form, is_64bit) catch break;
                        }
                    },
                    DW_AT_encoding => {
                        if (attr.form == DW_FORM_data1 and scan_pos < debug_info.len) {
                            t_encoding = debug_info[scan_pos];
                            scan_pos += 1;
                        } else {
                            skipForm(debug_info, &scan_pos, attr.form, is_64bit) catch break;
                        }
                    },
                    DW_AT_byte_size => {
                        if (attr.form == DW_FORM_data1 and scan_pos < debug_info.len) {
                            t_byte_size = debug_info[scan_pos];
                            scan_pos += 1;
                        } else {
                            skipForm(debug_info, &scan_pos, attr.form, is_64bit) catch break;
                        }
                    },
                    else => {
                        skipForm(debug_info, &scan_pos, attr.form, is_64bit) catch break;
                    },
                }
            }

            if (abbrev.tag == DW_TAG_base_type) {
                type_map.put(die_offset, .{
                    .encoding = t_encoding,
                    .byte_size = t_byte_size,
                    .name = t_name orelse "",
                }) catch {};
            }
        }
    }

    // Second pass: collect variables
    while (pos < unit_end and pos < debug_info.len) {
        const abbrev_code = readULEB128(debug_info, &pos) catch break;
        if (abbrev_code == 0) continue;
        const abbrev = findAbbrev(abbrevs, abbrev_code) orelse break;

        var v_name: ?[]const u8 = null;
        var v_location: ?[]const u8 = null;
        var v_type_ref: u64 = 0;

        for (abbrev.attributes) |attr| {
            if (attr.form == DW_FORM_implicit_const) continue;
            switch (attr.name) {
                DW_AT_name => {
                    if (attr.form == DW_FORM_string) {
                        v_name = readNullTermString(debug_info, &pos);
                    } else if (attr.form == DW_FORM_strp) {
                        const str_offset = if (is_64bit)
                            readU64(debug_info, &pos) catch break
                        else
                            readU32(debug_info, &pos) catch break;
                        if (debug_str) |s| v_name = readStringAt(s, @intCast(str_offset));
                    } else if (attr.form == DW_FORM_strx or attr.form == DW_FORM_strx1 or
                        attr.form == DW_FORM_strx2 or attr.form == DW_FORM_strx4)
                    {
                        const index = readFormIndex(debug_info, &pos, attr.form) catch break;
                        v_name = resolveStrx(debug_str, extra.debug_str_offsets, 0, index, is_64bit);
                    } else {
                        skipForm(debug_info, &pos, attr.form, is_64bit) catch break;
                    }
                },
                DW_AT_location => {
                    if (attr.form == DW_FORM_exprloc) {
                        const loc_len = readULEB128(debug_info, &pos) catch break;
                        const loc_end = pos + @as(usize, @intCast(loc_len));
                        if (loc_end <= debug_info.len) {
                            v_location = debug_info[pos..loc_end];
                        }
                        pos = loc_end;
                    } else {
                        skipForm(debug_info, &pos, attr.form, is_64bit) catch break;
                    }
                },
                DW_AT_type => {
                    if (attr.form == DW_FORM_ref4) {
                        v_type_ref = readU32(debug_info, &pos) catch break;
                    } else if (attr.form == DW_FORM_ref1 and pos < debug_info.len) {
                        v_type_ref = debug_info[pos];
                        pos += 1;
                    } else if (attr.form == DW_FORM_ref2) {
                        v_type_ref = readU16(debug_info, &pos) catch break;
                    } else if (attr.form == DW_FORM_ref8) {
                        v_type_ref = readU64(debug_info, &pos) catch break;
                    } else if (attr.form == DW_FORM_ref_udata) {
                        v_type_ref = readULEB128(debug_info, &pos) catch break;
                    } else {
                        skipForm(debug_info, &pos, attr.form, is_64bit) catch break;
                    }
                },
                else => {
                    skipForm(debug_info, &pos, attr.form, is_64bit) catch break;
                },
            }
        }

        if (abbrev.tag == DW_TAG_variable or abbrev.tag == DW_TAG_formal_parameter) {
            if (v_name) |name| {
                // Resolve type info from collected base types
                var encoding: u8 = 0;
                var byte_size: u8 = 0;
                var type_name: []const u8 = "";
                if (type_map.get(v_type_ref)) |ti| {
                    encoding = ti.encoding;
                    byte_size = ti.byte_size;
                    type_name = ti.name;
                }

                const loc_expr = if (v_location) |loc|
                    try allocator.dupe(u8, loc)
                else
                    try allocator.alloc(u8, 0);

                try variables.append(allocator, .{
                    .name = name,
                    .location_expr = loc_expr,
                    .type_encoding = encoding,
                    .type_byte_size = byte_size,
                    .type_name = type_name,
                });
            }
        }
    }

    return try variables.toOwnedSlice(allocator);
}

pub fn freeVariables(variables: []VariableInfo, allocator: std.mem.Allocator) void {
    for (variables) |v| {
        allocator.free(v.location_expr);
    }
    allocator.free(variables);
}

// ── Helper Functions ───────────────────────────────────────────────────

fn findAbbrev(abbrevs: []const AbbrevEntry, code: u64) ?*const AbbrevEntry {
    for (abbrevs) |*entry| {
        if (entry.code == code) return entry;
    }
    return null;
}

fn readNullTermString(data: []const u8, pos: *usize) []const u8 {
    const start = pos.*;
    while (pos.* < data.len and data[pos.*] != 0) {
        pos.* += 1;
    }
    const result = data[start..pos.*];
    if (pos.* < data.len) pos.* += 1; // Skip null terminator
    return result;
}

fn readStringAt(data: []const u8, offset: usize) ?[]const u8 {
    if (offset >= data.len) return null;
    var end = offset;
    while (end < data.len and data[end] != 0) {
        end += 1;
    }
    return data[offset..end];
}

fn readU16(data: []const u8, pos: *usize) !u16 {
    if (pos.* + 2 > data.len) return error.OutOfBounds;
    const result = std.mem.readInt(u16, data[pos.*..][0..2], .little);
    pos.* += 2;
    return result;
}

fn readU32(data: []const u8, pos: *usize) !u32 {
    if (pos.* + 4 > data.len) return error.OutOfBounds;
    const result = std.mem.readInt(u32, data[pos.*..][0..4], .little);
    pos.* += 4;
    return result;
}

fn readU64(data: []const u8, pos: *usize) !u64 {
    if (pos.* + 8 > data.len) return error.OutOfBounds;
    const result = std.mem.readInt(u64, data[pos.*..][0..8], .little);
    pos.* += 8;
    return result;
}

fn skipForm(data: []const u8, pos: *usize, form: u64, is_64bit: bool) !void {
    switch (form) {
        DW_FORM_addr => pos.* += 8, // Assuming 64-bit addresses
        DW_FORM_data1, DW_FORM_ref1, DW_FORM_flag, DW_FORM_strx1, DW_FORM_addrx1 => pos.* += 1,
        DW_FORM_data2, DW_FORM_ref2, DW_FORM_strx2, DW_FORM_addrx2 => pos.* += 2,
        DW_FORM_data4, DW_FORM_ref4, DW_FORM_strx4, DW_FORM_addrx4 => pos.* += 4,
        DW_FORM_data8, DW_FORM_ref8, DW_FORM_ref_sig8 => pos.* += 8,
        DW_FORM_data16 => pos.* += 16,
        DW_FORM_string => {
            _ = readNullTermString(data, pos);
        },
        DW_FORM_strp, DW_FORM_sec_offset, DW_FORM_ref_addr, DW_FORM_line_strp => {
            if (is_64bit) {
                pos.* += 8;
            } else {
                pos.* += 4;
            }
        },
        DW_FORM_sdata => {
            _ = try readSLEB128(data, pos);
        },
        DW_FORM_udata, DW_FORM_ref_udata, DW_FORM_strx, DW_FORM_addrx, DW_FORM_rnglistx, DW_FORM_loclistx => {
            _ = try readULEB128(data, pos);
        },
        DW_FORM_block1 => {
            if (pos.* < data.len) {
                const len = data[pos.*];
                pos.* += 1 + len;
            }
        },
        DW_FORM_block2 => {
            const len = try readU16(data, pos);
            pos.* += len;
        },
        DW_FORM_block4 => {
            const len = try readU32(data, pos);
            pos.* += @intCast(len);
        },
        DW_FORM_block, DW_FORM_exprloc => {
            const len = try readULEB128(data, pos);
            pos.* += @intCast(len);
        },
        DW_FORM_flag_present => {}, // No data, presence is the value
        DW_FORM_implicit_const => {}, // Value in abbrev table
        else => {
            // Unknown form - cannot determine size
            return error.UnknownForm;
        },
    }
    if (pos.* > data.len) return error.OutOfBounds;
}

// ── Tests ───────────────────────────────────────────────────────────────

test "readULEB128 decodes single byte" {
    const data = [_]u8{0x42};
    var pos: usize = 0;
    const result = try readULEB128(&data, &pos);
    try std.testing.expectEqual(@as(u64, 0x42), result);
    try std.testing.expectEqual(@as(usize, 1), pos);
}

test "readULEB128 decodes multi-byte" {
    // 624485 = 0x98765 = 0b10011000011101100101
    // LEB128: 0xE5, 0x8E, 0x26
    const data = [_]u8{ 0xE5, 0x8E, 0x26 };
    var pos: usize = 0;
    const result = try readULEB128(&data, &pos);
    try std.testing.expectEqual(@as(u64, 624485), result);
    try std.testing.expectEqual(@as(usize, 3), pos);
}

test "readULEB128 decodes zero" {
    const data = [_]u8{0x00};
    var pos: usize = 0;
    const result = try readULEB128(&data, &pos);
    try std.testing.expectEqual(@as(u64, 0), result);
}

test "readULEB128 returns error on empty data" {
    const data = [_]u8{};
    var pos: usize = 0;
    try std.testing.expectError(error.UnexpectedEndOfData, readULEB128(&data, &pos));
}

test "readSLEB128 decodes positive value" {
    // 42 = 0x2A = 0b00101010, bit 6 is clear so it's positive in SLEB128
    const data = [_]u8{0x2A};
    var pos: usize = 0;
    const result = try readSLEB128(&data, &pos);
    try std.testing.expectEqual(@as(i64, 42), result);
}

test "readSLEB128 decodes negative value" {
    // -123456 in SLEB128: 0xC0, 0xBB, 0x78
    const data = [_]u8{ 0xC0, 0xBB, 0x78 };
    var pos: usize = 0;
    const result = try readSLEB128(&data, &pos);
    try std.testing.expectEqual(@as(i64, -123456), result);
}

test "readSLEB128 decodes minus one" {
    const data = [_]u8{0x7f};
    var pos: usize = 0;
    const result = try readSLEB128(&data, &pos);
    try std.testing.expectEqual(@as(i64, -1), result);
}

test "parseAbbrevTable parses abbreviation declarations" {
    // Construct a minimal abbreviation table:
    // Entry 1: code=1, tag=DW_TAG_compile_unit (0x11), has_children=yes
    //   attr: DW_AT_name (0x03), DW_FORM_string (0x08)
    //   end: 0, 0
    // End: 0
    const data = [_]u8{
        0x01,       // code = 1
        0x11,       // tag = DW_TAG_compile_unit
        0x01,       // has_children = yes
        0x03, 0x08, // DW_AT_name, DW_FORM_string
        0x00, 0x00, // end of attributes
        0x00, // end of table
    };

    const entries = try parseAbbrevTable(&data, std.testing.allocator);
    defer freeAbbrevTable(entries, std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), entries.len);
    try std.testing.expectEqual(@as(u64, 1), entries[0].code);
    try std.testing.expectEqual(DW_TAG_compile_unit, entries[0].tag);
    try std.testing.expect(entries[0].has_children);
    try std.testing.expectEqual(@as(usize, 1), entries[0].attributes.len);
    try std.testing.expectEqual(DW_AT_name, entries[0].attributes[0].name);
    try std.testing.expectEqual(DW_FORM_string, entries[0].attributes[0].form);
}

test "parseAbbrevTable parses multiple entries" {
    const data = [_]u8{
        // Entry 1: compile_unit
        0x01,       0x11, 0x01,
        0x03,       0x08, // AT_name, FORM_string
        0x00,       0x00,
        // Entry 2: subprogram
        0x02,       0x2e, 0x00, // no children
        0x03,       0x08, // AT_name, FORM_string
        0x11,       0x01, // AT_low_pc, FORM_addr
        0x00,       0x00,
        // End
        0x00,
    };

    const entries = try parseAbbrevTable(&data, std.testing.allocator);
    defer freeAbbrevTable(entries, std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), entries.len);
    try std.testing.expectEqual(DW_TAG_compile_unit, entries[0].tag);
    try std.testing.expectEqual(DW_TAG_subprogram, entries[1].tag);
    try std.testing.expect(!entries[1].has_children);
    try std.testing.expectEqual(@as(usize, 2), entries[1].attributes.len);
}

test "resolveAddress returns null for empty entries" {
    const entries = [_]LineEntry{};
    const files = [_]FileEntry{};
    const result = resolveAddress(&entries, &files, 0x1000);
    try std.testing.expect(result == null);
}

test "resolveAddress returns null for unknown address" {
    const entries = [_]LineEntry{
        .{ .address = 0x2000, .file_index = 1, .line = 10, .column = 0, .is_stmt = true, .end_sequence = false },
    };
    const files = [_]FileEntry{
        .{ .name = "test.c", .dir_index = 0 },
    };
    // Address before any entry
    const result = resolveAddress(&entries, &files, 0x1000);
    try std.testing.expect(result == null);
}

test "resolveAddress returns source location for known address" {
    const entries = [_]LineEntry{
        .{ .address = 0x1000, .file_index = 1, .line = 5, .column = 3, .is_stmt = true, .end_sequence = false },
        .{ .address = 0x1010, .file_index = 1, .line = 6, .column = 0, .is_stmt = true, .end_sequence = false },
        .{ .address = 0x1020, .file_index = 1, .line = 7, .column = 0, .is_stmt = true, .end_sequence = true },
    };
    const files = [_]FileEntry{
        .{ .name = "test.c", .dir_index = 0 },
    };
    const result = resolveAddress(&entries, &files, 0x1008);
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("test.c", result.?.file);
    try std.testing.expectEqual(@as(u32, 5), result.?.line);
}

test "resolveAddress maps address between entries" {
    const entries = [_]LineEntry{
        .{ .address = 0x1000, .file_index = 1, .line = 10, .column = 0, .is_stmt = true, .end_sequence = false },
        .{ .address = 0x1020, .file_index = 1, .line = 15, .column = 0, .is_stmt = true, .end_sequence = false },
    };
    const files = [_]FileEntry{
        .{ .name = "main.c", .dir_index = 0 },
    };
    // Address between two entries should map to the earlier entry
    const result = resolveAddress(&entries, &files, 0x1010);
    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(u32, 10), result.?.line);
}

test "resolveFunction returns address range for known function" {
    const functions = [_]FunctionInfo{
        .{ .name = "main", .low_pc = 0x1000, .high_pc = 0x1050 },
        .{ .name = "add", .low_pc = 0x1050, .high_pc = 0x1080 },
    };
    const result = resolveFunction(&functions, "add");
    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(u64, 0x1050), result.?.low_pc);
    try std.testing.expectEqual(@as(u64, 0x1080), result.?.high_pc);
}

test "resolveFunction returns null for unknown function" {
    const functions = [_]FunctionInfo{
        .{ .name = "main", .low_pc = 0x1000, .high_pc = 0x1050 },
    };
    const result = resolveFunction(&functions, "nonexistent");
    try std.testing.expect(result == null);
}

test "parseLineProgram parses fixture debug_line section" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;

    const macho = binary_macho.MachoBinary.loadFile(std.testing.allocator, "test/fixtures/simple.o") catch |err| {
        if (err == error.FileNotFound) return error.SkipZigTest;
        return err;
    };
    defer {
        var m = macho;
        m.deinit(std.testing.allocator);
    }

    const line_info = macho.sections.debug_line orelse return error.SkipZigTest;
    const line_data = macho.getSectionData(line_info) orelse return error.SkipZigTest;

    const entries = try parseLineProgram(line_data, std.testing.allocator);
    defer std.testing.allocator.free(entries);

    // Should have at least some line entries
    try std.testing.expect(entries.len > 0);

    // At least one entry should have line > 0
    var has_valid_line = false;
    for (entries) |entry| {
        if (entry.line > 0 and !entry.end_sequence) {
            has_valid_line = true;
            break;
        }
    }
    try std.testing.expect(has_valid_line);
}

test "parseCompilationUnit extracts function names from fixture" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;

    const macho = binary_macho.MachoBinary.loadFile(std.testing.allocator, "test/fixtures/simple.o") catch |err| {
        if (err == error.FileNotFound) return error.SkipZigTest;
        return err;
    };
    defer {
        var m = macho;
        m.deinit(std.testing.allocator);
    }

    const info_section = macho.sections.debug_info orelse return error.SkipZigTest;
    const abbrev_section = macho.sections.debug_abbrev orelse return error.SkipZigTest;

    const info_data = macho.getSectionData(info_section) orelse return error.SkipZigTest;
    const abbrev_data = macho.getSectionData(abbrev_section) orelse return error.SkipZigTest;
    const str_data = if (macho.sections.debug_str) |s| macho.getSectionData(s) else null;
    const str_offsets_data = if (macho.sections.debug_str_offsets) |s| macho.getSectionData(s) else null;
    const addr_data = if (macho.sections.debug_addr) |s| macho.getSectionData(s) else null;

    const functions = try parseCompilationUnitEx(
        info_data,
        abbrev_data,
        str_data,
        .{ .debug_str_offsets = str_offsets_data, .debug_addr = addr_data },
        std.testing.allocator,
    );
    defer std.testing.allocator.free(functions);

    // The fixture has 'add' and 'main' functions
    var found_add = false;
    var found_main = false;
    for (functions) |f| {
        if (std.mem.eql(u8, f.name, "add")) found_add = true;
        if (std.mem.eql(u8, f.name, "main")) found_main = true;
    }

    // At least one function should be found
    try std.testing.expect(found_add or found_main);
}

test "parseCompilationUnit extracts variable declarations" {
    // Construct a minimal DWARF .debug_info with a variable DIE.
    // CU header: length=33, version=4, abbrev_offset=0, addr_size=8
    // DIE 1 (abbrev 1): DW_TAG_compile_unit, DW_AT_name="test.c"
    // DIE 2 (abbrev 2): DW_TAG_base_type, DW_AT_name="int", DW_AT_encoding=5, DW_AT_byte_size=4
    // DIE 3 (abbrev 3): DW_TAG_variable, DW_AT_name="x", DW_AT_type=ref4(offset of base_type)
    //
    // Abbreviation table:
    // 1: DW_TAG_compile_unit, has_children, AT_name(FORM_string), 0,0
    // 2: DW_TAG_base_type, no_children, AT_name(FORM_string), AT_encoding(FORM_data1), AT_byte_size(FORM_data1), 0,0
    // 3: DW_TAG_variable, no_children, AT_name(FORM_string), AT_type(FORM_ref4), 0,0
    // 0: end

    const abbrev_data = [_]u8{
        // Abbrev 1: compile_unit
        0x01, 0x11, 0x01, // code=1, tag=compile_unit, has_children=yes
        0x03, 0x08, // AT_name, FORM_string
        0x00, 0x00,
        // Abbrev 2: base_type
        0x02, 0x24, 0x00, // code=2, tag=base_type, no_children
        0x03, 0x08, // AT_name, FORM_string
        0x3e, 0x0b, // AT_encoding, FORM_data1
        0x0b, 0x0b, // AT_byte_size, FORM_data1
        0x00, 0x00,
        // Abbrev 3: variable
        0x03, 0x34, 0x00, // code=3, tag=variable, no_children
        0x03, 0x08, // AT_name, FORM_string
        0x49, 0x13, // AT_type, FORM_ref4
        0x00, 0x00,
        // End
        0x00,
    };

    // Build debug_info:
    // CU header: 4-byte length (to be filled), version=4, abbrev_offset=0, addr_size=8
    // Then DIEs
    var info_buf: [128]u8 = undefined;
    var ipos: usize = 0;

    // Leave space for length (4 bytes)
    ipos += 4;

    // Version = 4
    std.mem.writeInt(u16, info_buf[ipos..][0..2], 4, .little);
    ipos += 2;

    // Abbrev offset = 0
    std.mem.writeInt(u32, info_buf[ipos..][0..4], 0, .little);
    ipos += 4;

    // Address size = 8
    info_buf[ipos] = 8;
    ipos += 1;

    // DIE 1: compile_unit, AT_name="test.c\0"
    info_buf[ipos] = 0x01; // abbrev code 1
    ipos += 1;
    const cu_name = "test.c";
    @memcpy(info_buf[ipos..][0..cu_name.len], cu_name);
    ipos += cu_name.len;
    info_buf[ipos] = 0; // null terminator
    ipos += 1;

    // DIE 2: base_type at offset (ipos - 4) relative to CU start
    const base_type_offset = ipos - 4; // offset from start of CU header data
    info_buf[ipos] = 0x02; // abbrev code 2
    ipos += 1;
    const type_name = "int";
    @memcpy(info_buf[ipos..][0..type_name.len], type_name);
    ipos += type_name.len;
    info_buf[ipos] = 0;
    ipos += 1;
    info_buf[ipos] = 0x05; // DW_ATE_signed
    ipos += 1;
    info_buf[ipos] = 0x04; // 4 bytes
    ipos += 1;

    // DIE 3: variable
    info_buf[ipos] = 0x03; // abbrev code 3
    ipos += 1;
    const var_name = "x";
    @memcpy(info_buf[ipos..][0..var_name.len], var_name);
    ipos += var_name.len;
    info_buf[ipos] = 0;
    ipos += 1;
    // AT_type: ref4 pointing to base_type_offset
    std.mem.writeInt(u32, info_buf[ipos..][0..4], @intCast(base_type_offset), .little);
    ipos += 4;

    // Null DIE (end of children)
    info_buf[ipos] = 0x00;
    ipos += 1;

    // Fill in CU length (total - 4 bytes for the length field itself)
    const cu_len: u32 = @intCast(ipos - 4);
    std.mem.writeInt(u32, info_buf[0..4], cu_len, .little);

    const vars = try parseVariables(info_buf[0..ipos], &abbrev_data, null, std.testing.allocator);
    defer freeVariables(vars, std.testing.allocator);

    try std.testing.expect(vars.len >= 1);

    var found_x = false;
    for (vars) |v| {
        if (std.mem.eql(u8, v.name, "x")) {
            found_x = true;
            try std.testing.expectEqual(@as(u8, 0x05), v.type_encoding); // DW_ATE_signed
            try std.testing.expectEqual(@as(u8, 4), v.type_byte_size);
        }
    }
    try std.testing.expect(found_x);
}
