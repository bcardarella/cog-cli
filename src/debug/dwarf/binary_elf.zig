const std = @import("std");
const builtin = @import("builtin");
const binary_macho = @import("binary_macho.zig");

// ── ELF Binary Format Loading ──────────────────────────────────────────

const SectionInfo = binary_macho.SectionInfo;
const DebugSections = binary_macho.DebugSections;

// ELF format constants
const ELF_MAGIC = [4]u8{ 0x7f, 'E', 'L', 'F' };
const ELFCLASS64: u8 = 2;
const ELFDATA2LSB: u8 = 1;

const Elf64Header = extern struct {
    e_ident: [16]u8,
    e_type: u16,
    e_machine: u16,
    e_version: u32,
    e_entry: u64,
    e_phoff: u64,
    e_shoff: u64,
    e_flags: u32,
    e_ehsize: u16,
    e_phentsize: u16,
    e_phnum: u16,
    e_shentsize: u16,
    e_shnum: u16,
    e_shstrndx: u16,
};

const Elf64SectionHeader = extern struct {
    sh_name: u32,
    sh_type: u32,
    sh_flags: u64,
    sh_addr: u64,
    sh_offset: u64,
    sh_size: u64,
    sh_link: u32,
    sh_info: u32,
    sh_addralign: u64,
    sh_entsize: u64,
};

pub const ElfBinary = struct {
    data: []const u8,
    owned: bool,
    sections: DebugSections,

    pub fn loadFile(allocator: std.mem.Allocator, path: []const u8) !ElfBinary {
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

        var result = try parseElf(data);
        result.owned = true;
        return result;
    }

    pub fn loadFromMemory(data: []const u8) !ElfBinary {
        return parseElf(data);
    }

    pub fn deinit(self: *ElfBinary, allocator: std.mem.Allocator) void {
        if (self.owned) {
            allocator.free(@constCast(self.data));
        }
    }

    pub fn getSectionData(self: *const ElfBinary, info: SectionInfo) ?[]const u8 {
        const start: usize = @intCast(info.offset);
        const end = start + @as(usize, @intCast(info.size));
        if (end > self.data.len) return null;
        return self.data[start..end];
    }
};

fn parseElf(data: []const u8) !ElfBinary {
    if (data.len < @sizeOf(Elf64Header)) return error.TooSmall;

    const header = readStruct(Elf64Header, data, 0) catch return error.TooSmall;

    // Validate ELF magic
    if (!std.mem.eql(u8, header.e_ident[0..4], &ELF_MAGIC)) return error.InvalidMagic;
    // We only support 64-bit little-endian ELF
    if (header.e_ident[4] != ELFCLASS64) return error.UnsupportedFormat;
    if (header.e_ident[5] != ELFDATA2LSB) return error.UnsupportedFormat;

    var sections = DebugSections{};

    // Read section string table
    if (header.e_shstrndx == 0 or header.e_shnum == 0) {
        return .{ .data = data, .owned = false, .sections = sections };
    }

    const shstrtab_offset = header.e_shoff + @as(u64, header.e_shstrndx) * @as(u64, header.e_shentsize);
    const shstrtab_hdr = readStruct(Elf64SectionHeader, data, @intCast(shstrtab_offset)) catch {
        return .{ .data = data, .owned = false, .sections = sections };
    };

    const strtab_start: usize = @intCast(shstrtab_hdr.sh_offset);
    const strtab_end = strtab_start + @as(usize, @intCast(shstrtab_hdr.sh_size));
    if (strtab_end > data.len) {
        return .{ .data = data, .owned = false, .sections = sections };
    }
    const strtab = data[strtab_start..strtab_end];

    // Iterate section headers
    for (0..header.e_shnum) |i| {
        const sh_offset = header.e_shoff + @as(u64, @intCast(i)) * @as(u64, header.e_shentsize);
        const shdr = readStruct(Elf64SectionHeader, data, @intCast(sh_offset)) catch continue;

        const name = readStringFromTable(strtab, shdr.sh_name);
        if (name.len == 0) continue;

        const info = SectionInfo{
            .offset = shdr.sh_offset,
            .size = shdr.sh_size,
        };

        if (std.mem.eql(u8, name, ".debug_info")) {
            sections.debug_info = info;
        } else if (std.mem.eql(u8, name, ".debug_abbrev")) {
            sections.debug_abbrev = info;
        } else if (std.mem.eql(u8, name, ".debug_line")) {
            sections.debug_line = info;
        } else if (std.mem.eql(u8, name, ".debug_str")) {
            sections.debug_str = info;
        } else if (std.mem.eql(u8, name, ".debug_ranges")) {
            sections.debug_ranges = info;
        } else if (std.mem.eql(u8, name, ".debug_aranges")) {
            sections.debug_aranges = info;
        } else if (std.mem.eql(u8, name, ".debug_line_str")) {
            sections.debug_line_str = info;
        } else if (std.mem.eql(u8, name, ".eh_frame")) {
            sections.eh_frame = info;
        }
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

fn readStringFromTable(table: []const u8, offset: u32) []const u8 {
    if (offset >= table.len) return "";
    const start = table[offset..];
    for (start, 0..) |c, i| {
        if (c == 0) return start[0..i];
    }
    return start;
}

// ── Tests ───────────────────────────────────────────────────────────────

test "loadFromMemory rejects data too small for header" {
    const small = [_]u8{0} ** 10;
    const result = ElfBinary.loadFromMemory(&small);
    try std.testing.expectError(error.TooSmall, result);
}

test "loadFromMemory rejects invalid magic" {
    var data = [_]u8{0} ** @sizeOf(Elf64Header);
    data[0] = 0xDE;
    data[1] = 0xAD;
    const result = ElfBinary.loadFromMemory(&data);
    try std.testing.expectError(error.InvalidMagic, result);
}

test "loadFromMemory rejects 32-bit ELF" {
    var data = [_]u8{0} ** @sizeOf(Elf64Header);
    // Set ELF magic
    data[0] = 0x7f;
    data[1] = 'E';
    data[2] = 'L';
    data[3] = 'F';
    data[4] = 1; // ELFCLASS32 - not supported
    data[5] = ELFDATA2LSB;
    const result = ElfBinary.loadFromMemory(&data);
    try std.testing.expectError(error.UnsupportedFormat, result);
}

test "loadFromMemory accepts valid ELF header with zero sections" {
    var data = [_]u8{0} ** @sizeOf(Elf64Header);
    data[0] = 0x7f;
    data[1] = 'E';
    data[2] = 'L';
    data[3] = 'F';
    data[4] = ELFCLASS64;
    data[5] = ELFDATA2LSB;

    const binary = try ElfBinary.loadFromMemory(&data);
    try std.testing.expect(!binary.sections.hasDebugInfo());
}

test "readStringFromTable extracts null-terminated string" {
    const table = ".debug_info\x00.debug_line\x00";
    const name = readStringFromTable(table, 0);
    try std.testing.expectEqualStrings(".debug_info", name);
}

test "readStringFromTable extracts string at offset" {
    const table = ".debug_info\x00.debug_line\x00";
    const name = readStringFromTable(table, 12);
    try std.testing.expectEqualStrings(".debug_line", name);
}

test "readStringFromTable returns empty for out-of-bounds offset" {
    const table = "test\x00";
    const name = readStringFromTable(table, 100);
    try std.testing.expectEqualStrings("", name);
}

test "loadBinary returns error for non-ELF file" {
    const result = ElfBinary.loadFile(std.testing.allocator, "build.zig");
    try std.testing.expectError(error.InvalidMagic, result);
}

test "loadBinary identifies correct binary format" {
    var binary = ElfBinary.loadFile(std.testing.allocator, "test/fixtures/simple.elf.o") catch |err| {
        if (err == error.FileNotFound) return error.SkipZigTest;
        return err;
    };
    defer binary.deinit(std.testing.allocator);

    // Successfully loaded means it's valid ELF
    try std.testing.expect(true);
}

test "loadBinary locates .debug_info section" {
    var binary = ElfBinary.loadFile(std.testing.allocator, "test/fixtures/simple.elf.o") catch |err| {
        if (err == error.FileNotFound) return error.SkipZigTest;
        return err;
    };
    defer binary.deinit(std.testing.allocator);

    try std.testing.expect(binary.sections.debug_info != null);
    const info = binary.sections.debug_info.?;
    try std.testing.expect(info.size > 0);
}

test "loadBinary locates .debug_line section" {
    var binary = ElfBinary.loadFile(std.testing.allocator, "test/fixtures/simple.elf.o") catch |err| {
        if (err == error.FileNotFound) return error.SkipZigTest;
        return err;
    };
    defer binary.deinit(std.testing.allocator);

    try std.testing.expect(binary.sections.debug_line != null);
    const info = binary.sections.debug_line.?;
    try std.testing.expect(info.size > 0);
}

test "loadBinary locates .debug_abbrev section" {
    var binary = ElfBinary.loadFile(std.testing.allocator, "test/fixtures/simple.elf.o") catch |err| {
        if (err == error.FileNotFound) return error.SkipZigTest;
        return err;
    };
    defer binary.deinit(std.testing.allocator);

    try std.testing.expect(binary.sections.debug_abbrev != null);
    const info = binary.sections.debug_abbrev.?;
    try std.testing.expect(info.size > 0);
}

test "loadBinary locates .debug_str section" {
    var binary = ElfBinary.loadFile(std.testing.allocator, "test/fixtures/simple.elf.o") catch |err| {
        if (err == error.FileNotFound) return error.SkipZigTest;
        return err;
    };
    defer binary.deinit(std.testing.allocator);

    try std.testing.expect(binary.sections.debug_str != null);
    const info = binary.sections.debug_str.?;
    try std.testing.expect(info.size > 0);
}

test "loadBinary locates .eh_frame section" {
    var binary = ElfBinary.loadFile(std.testing.allocator, "test/fixtures/multi_func.elf.o") catch |err| {
        if (err == error.FileNotFound) return error.SkipZigTest;
        return err;
    };
    defer binary.deinit(std.testing.allocator);

    // multi_func.elf.o should have .eh_frame with call frame info for stack unwinding
    if (binary.sections.eh_frame) |info| {
        try std.testing.expect(info.size > 0);
        const data = binary.getSectionData(info);
        try std.testing.expect(data != null);
    }
}

test "getSectionData returns correct byte slice for ELF" {
    var binary = ElfBinary.loadFile(std.testing.allocator, "test/fixtures/simple.elf.o") catch |err| {
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

test "loadBinary returns error for non-debug ELF binary" {
    // A Mach-O object file has wrong magic for ELF
    const result = ElfBinary.loadFile(std.testing.allocator, "test/fixtures/simple.o");
    if (result) |_| {
        // If it somehow loaded, that's unexpected for a Mach-O file
        unreachable;
    } else |err| {
        try std.testing.expect(err == error.InvalidMagic or err == error.UnsupportedFormat or err == error.FileNotFound);
    }
}
