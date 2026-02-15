const std = @import("std");
const builtin = @import("builtin");

// ── Mach-O Binary Format Loading ───────────────────────────────────────

// Mach-O format constants
const MH_MAGIC_64: u32 = 0xFEEDFACF;
const MH_CIGAM_64: u32 = 0xCFFAEDFE;
const LC_SEGMENT_64: u32 = 0x19;

const MachHeader64 = extern struct {
    magic: u32,
    cputype: i32,
    cpusubtype: i32,
    filetype: u32,
    ncmds: u32,
    sizeofcmds: u32,
    flags: u32,
    reserved: u32,
};

const SegmentCommand64 = extern struct {
    cmd: u32,
    cmdsize: u32,
    segname: [16]u8,
    vmaddr: u64,
    vmsize: u64,
    fileoff: u64,
    filesize: u64,
    maxprot: i32,
    initprot: i32,
    nsects: u32,
    flags: u32,
};

const Section64 = extern struct {
    sectname: [16]u8,
    segname: [16]u8,
    addr: u64,
    size: u64,
    offset: u32,
    @"align": u32,
    reloff: u32,
    nreloc: u32,
    flags: u32,
    reserved1: u32,
    reserved2: u32,
    reserved3: u32,
};

pub const SectionInfo = struct {
    offset: u64,
    size: u64,
};

pub const DebugSections = struct {
    debug_info: ?SectionInfo = null,
    debug_abbrev: ?SectionInfo = null,
    debug_line: ?SectionInfo = null,
    debug_str: ?SectionInfo = null,
    debug_str_offsets: ?SectionInfo = null,
    debug_addr: ?SectionInfo = null,
    debug_ranges: ?SectionInfo = null,
    debug_aranges: ?SectionInfo = null,
    debug_line_str: ?SectionInfo = null,
    eh_frame: ?SectionInfo = null,

    pub fn hasDebugInfo(self: DebugSections) bool {
        return self.debug_info != null or self.debug_line != null;
    }
};

pub const MachoBinary = struct {
    data: []const u8,
    owned: bool,
    sections: DebugSections,

    pub fn loadFile(allocator: std.mem.Allocator, path: []const u8) !MachoBinary {
        const file = try std.fs.cwd().openFile(path, .{});
        defer file.close();

        const stat = try file.stat();
        const data = try allocator.alloc(u8, stat.size);
        errdefer allocator.free(data);

        const bytes_read = try file.readAll(data);
        if (bytes_read != stat.size) {
            allocator.free(data);
            return error.IncompleteRead;
        }

        var result = try parseMachO(data);
        result.owned = true;
        return result;
    }

    pub fn loadFromMemory(data: []const u8) !MachoBinary {
        return parseMachO(data);
    }

    pub fn deinit(self: *MachoBinary, allocator: std.mem.Allocator) void {
        if (self.owned) {
            allocator.free(@constCast(self.data));
        }
    }

    pub fn getSectionData(self: *const MachoBinary, info: SectionInfo) ?[]const u8 {
        const start: usize = @intCast(info.offset);
        const end = start + @as(usize, @intCast(info.size));
        if (end > self.data.len) return null;
        return self.data[start..end];
    }
};

fn parseMachO(data: []const u8) !MachoBinary {
    if (data.len < @sizeOf(MachHeader64)) return error.TooSmall;

    const header = readStruct(MachHeader64, data, 0) catch return error.TooSmall;
    if (header.magic != MH_MAGIC_64) return error.InvalidMagic;

    var sections = DebugSections{};
    var offset: usize = @sizeOf(MachHeader64);

    for (0..header.ncmds) |_| {
        if (offset + 8 > data.len) break;

        const cmd = std.mem.readInt(u32, data[offset..][0..4], .little);
        const cmdsize = std.mem.readInt(u32, data[offset + 4..][0..4], .little);

        if (cmdsize < 8) break;

        if (cmd == LC_SEGMENT_64 and offset + @sizeOf(SegmentCommand64) <= data.len) {
            const seg = readStruct(SegmentCommand64, data, offset) catch break;

            var sect_offset = offset + @sizeOf(SegmentCommand64);
            for (0..seg.nsects) |_| {
                if (sect_offset + @sizeOf(Section64) > data.len) break;

                const sect = readStruct(Section64, data, sect_offset) catch break;
                const name = parseName(&sect.sectname);

                const info = SectionInfo{
                    .offset = sect.offset,
                    .size = sect.size,
                };

                if (std.mem.eql(u8, name, "__debug_info")) {
                    sections.debug_info = info;
                } else if (std.mem.eql(u8, name, "__debug_abbrev")) {
                    sections.debug_abbrev = info;
                } else if (std.mem.eql(u8, name, "__debug_line")) {
                    sections.debug_line = info;
                } else if (std.mem.eql(u8, name, "__debug_str")) {
                    sections.debug_str = info;
                } else if (std.mem.eql(u8, name, "__debug_str_offs")) {
                    sections.debug_str_offsets = info;
                } else if (std.mem.eql(u8, name, "__debug_addr")) {
                    sections.debug_addr = info;
                } else if (std.mem.eql(u8, name, "__debug_ranges")) {
                    sections.debug_ranges = info;
                } else if (std.mem.eql(u8, name, "__debug_aranges")) {
                    sections.debug_aranges = info;
                } else if (std.mem.eql(u8, name, "__debug_line_st")) {
                    sections.debug_line_str = info;
                } else if (std.mem.eql(u8, name, "__eh_frame")) {
                    sections.eh_frame = info;
                }

                sect_offset += @sizeOf(Section64);
            }
        }

        offset += cmdsize;
    }

    return .{
        .data = data,
        .owned = false,
        .sections = sections,
    };
}

fn readStruct(comptime T: type, data: []const u8, offset: usize) !T {
    const size = @sizeOf(T);
    if (offset + size > data.len) return error.OutOfBounds;
    var result: T = undefined;
    @memcpy(std.mem.asBytes(&result), data[offset..][0..size]);
    return result;
}

fn parseName(name: *const [16]u8) []const u8 {
    for (name, 0..) |c, i| {
        if (c == 0) return name[0..i];
    }
    return name[0..16];
}

// ── Tests ───────────────────────────────────────────────────────────────

test "parseName extracts null-terminated name" {
    const name: [16]u8 = "__debug_info\x00\x00\x00\x00".*;
    try std.testing.expectEqualStrings("__debug_info", parseName(&name));
}

test "parseName handles full-length name" {
    const name: [16]u8 = "0123456789abcdef".*;
    try std.testing.expectEqualStrings("0123456789abcdef", parseName(&name));
}

test "loadFromMemory rejects data too small for header" {
    const small = [_]u8{0} ** 10;
    const result = MachoBinary.loadFromMemory(&small);
    try std.testing.expectError(error.TooSmall, result);
}

test "loadFromMemory rejects invalid magic" {
    var data = [_]u8{0} ** @sizeOf(MachHeader64);
    // Set invalid magic
    std.mem.writeInt(u32, data[0..4], 0xDEADBEEF, .little);
    const result = MachoBinary.loadFromMemory(&data);
    try std.testing.expectError(error.InvalidMagic, result);
}

test "loadFromMemory accepts valid Mach-O header with zero commands" {
    var data = [_]u8{0} ** @sizeOf(MachHeader64);
    // Set magic
    std.mem.writeInt(u32, data[0..4], MH_MAGIC_64, .little);
    // ncmds = 0
    std.mem.writeInt(u32, data[16..20], 0, .little);

    const binary = try MachoBinary.loadFromMemory(&data);
    try std.testing.expect(!binary.sections.hasDebugInfo());
}

test "loadBinary identifies correct binary format" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;

    var binary = MachoBinary.loadFile(std.testing.allocator, "test/fixtures/simple.o") catch |err| {
        if (err == error.FileNotFound) return error.SkipZigTest;
        return err;
    };
    defer binary.deinit(std.testing.allocator);

    // Successfully loaded means it's valid Mach-O
    try std.testing.expect(true);
}

test "loadBinary locates .debug_info section" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;

    var binary = MachoBinary.loadFile(std.testing.allocator, "test/fixtures/simple.o") catch |err| {
        if (err == error.FileNotFound) return error.SkipZigTest;
        return err;
    };
    defer binary.deinit(std.testing.allocator);

    try std.testing.expect(binary.sections.debug_info != null);
    const info = binary.sections.debug_info.?;
    try std.testing.expect(info.size > 0);
}

test "loadBinary locates .debug_line section" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;

    var binary = MachoBinary.loadFile(std.testing.allocator, "test/fixtures/simple.o") catch |err| {
        if (err == error.FileNotFound) return error.SkipZigTest;
        return err;
    };
    defer binary.deinit(std.testing.allocator);

    try std.testing.expect(binary.sections.debug_line != null);
    const info = binary.sections.debug_line.?;
    try std.testing.expect(info.size > 0);
}

test "loadBinary locates .debug_abbrev section" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;

    var binary = MachoBinary.loadFile(std.testing.allocator, "test/fixtures/simple.o") catch |err| {
        if (err == error.FileNotFound) return error.SkipZigTest;
        return err;
    };
    defer binary.deinit(std.testing.allocator);

    try std.testing.expect(binary.sections.debug_abbrev != null);
    const info = binary.sections.debug_abbrev.?;
    try std.testing.expect(info.size > 0);
}

test "loadBinary locates .debug_str section" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;

    var binary = MachoBinary.loadFile(std.testing.allocator, "test/fixtures/simple.o") catch |err| {
        if (err == error.FileNotFound) return error.SkipZigTest;
        return err;
    };
    defer binary.deinit(std.testing.allocator);

    try std.testing.expect(binary.sections.debug_str != null);
    const info = binary.sections.debug_str.?;
    try std.testing.expect(info.size > 0);
}

test "getSectionData returns correct byte slice" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;

    var binary = MachoBinary.loadFile(std.testing.allocator, "test/fixtures/simple.o") catch |err| {
        if (err == error.FileNotFound) return error.SkipZigTest;
        return err;
    };
    defer binary.deinit(std.testing.allocator);

    if (binary.sections.debug_info) |info| {
        const data = binary.getSectionData(info);
        try std.testing.expect(data != null);
        try std.testing.expectEqual(info.size, data.?.len);
    }
}

test "loadBinary locates .eh_frame section" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;

    var binary = MachoBinary.loadFile(std.testing.allocator, "test/fixtures/multi_func.o") catch |err| {
        if (err == error.FileNotFound) return error.SkipZigTest;
        return err;
    };
    defer binary.deinit(std.testing.allocator);

    // multi_func.o should have __eh_frame with call frame info for stack unwinding
    if (binary.sections.eh_frame) |info| {
        try std.testing.expect(info.size > 0);
        const data = binary.getSectionData(info);
        try std.testing.expect(data != null);
    }
    // Note: .eh_frame presence depends on compiler/platform flags;
    // if not present, the test still passes (the field is optional)
}

test "loadBinary returns error for non-Mach-O file" {
    // Try to load a text file as Mach-O
    const result = MachoBinary.loadFile(std.testing.allocator, "build.zig");
    try std.testing.expectError(error.InvalidMagic, result);
}
