const std = @import("std");
const paths = @import("paths.zig");

pub const ToolConfig = struct {
    command: []const u8,
    args: []const []const u8,
};

pub const BrainConfig = struct {
    url: []const u8,
};

pub const DebugConfig = struct {
    timeout: ?i64 = null,
};

pub const Settings = struct {
    brain: ?BrainConfig = null,
    debug: ?DebugConfig = null,
    indexer: ?ToolConfig = null,
    editor: ?ToolConfig = null,
    creator: ?ToolConfig = null,
    deleter: ?ToolConfig = null,
    renamer: ?ToolConfig = null,

    /// Load merged settings: global (~/.config/cog/settings.json) with local (.cog/settings.json) overrides.
    pub fn load(allocator: std.mem.Allocator) ?Settings {
        const global = loadGlobal(allocator);
        const local = loadLocal(allocator);

        if (global == null and local == null) return null;

        // Merge: local overrides global field-by-field
        var result: Settings = .{};
        const g = global orelse Settings{};
        const l = local orelse Settings{};

        result.brain = l.brain orelse g.brain;
        result.debug = mergeDebugConfig(l.debug, g.debug);
        result.indexer = l.indexer orelse g.indexer;
        result.editor = l.editor orelse g.editor;
        result.creator = l.creator orelse g.creator;
        result.deleter = l.deleter orelse g.deleter;
        result.renamer = l.renamer orelse g.renamer;

        // Free the non-winning side's allocations
        if (l.brain != null) {
            if (g.brain) |gb| freeBrainConfig(allocator, &gb);
        }
        if (l.indexer != null) {
            if (g.indexer) |gi| freeToolConfig(allocator, &gi);
        } else if (local != null) {
            // local existed but had no indexer — nothing to free
        }
        if (l.editor != null) {
            if (g.editor) |ge| freeToolConfig(allocator, &ge);
        }
        if (l.creator != null) {
            if (g.creator) |gc| freeToolConfig(allocator, &gc);
        }
        if (l.deleter != null) {
            if (g.deleter) |gd| freeToolConfig(allocator, &gd);
        }
        if (l.renamer != null) {
            if (g.renamer) |gr| freeToolConfig(allocator, &gr);
        }

        return result;
    }

    /// Load settings from ~/.config/cog/settings.json.
    fn loadGlobal(allocator: std.mem.Allocator) ?Settings {
        const config_dir = paths.getGlobalConfigDir(allocator) catch return null;
        defer allocator.free(config_dir);

        const path = std.fmt.allocPrint(allocator, "{s}/settings.json", .{config_dir}) catch return null;
        defer allocator.free(path);

        return loadFromPath(allocator, path);
    }

    /// Load settings from .cog/settings.json (local project).
    fn loadLocal(allocator: std.mem.Allocator) ?Settings {
        const cog_dir = paths.findCogDir(allocator) catch return null;
        defer allocator.free(cog_dir);

        const path = std.fmt.allocPrint(allocator, "{s}/settings.json", .{cog_dir}) catch return null;
        defer allocator.free(path);

        return loadFromPath(allocator, path);
    }

    fn loadFromPath(allocator: std.mem.Allocator, path: []const u8) ?Settings {
        const file = std.fs.openFileAbsolute(path, .{}) catch return null;
        defer file.close();

        const data = file.readToEndAlloc(allocator, 64 * 1024) catch return null;
        defer allocator.free(data);

        return parse(allocator, data);
    }

    /// Parse settings from JSON content.
    pub fn parse(allocator: std.mem.Allocator, data: []const u8) ?Settings {
        const parsed = std.json.parseFromSlice(std.json.Value, allocator, data, .{}) catch return null;
        defer parsed.deinit();

        if (parsed.value != .object) return null;
        const obj = parsed.value.object;

        var result: Settings = .{};

        if (obj.get("brain")) |v| {
            result.brain = parseBrainConfig(allocator, v) catch return null;
        }
        if (obj.get("debug")) |v| {
            result.debug = parseDebugConfig(v);
        }
        if (obj.get("indexer")) |v| {
            result.indexer = parseToolConfig(allocator, v) catch return null;
        }
        if (obj.get("editor")) |v| {
            result.editor = parseToolConfig(allocator, v) catch return null;
        }
        if (obj.get("creator")) |v| {
            result.creator = parseToolConfig(allocator, v) catch return null;
        }
        if (obj.get("deleter")) |v| {
            result.deleter = parseToolConfig(allocator, v) catch return null;
        }
        if (obj.get("renamer")) |v| {
            result.renamer = parseToolConfig(allocator, v) catch return null;
        }

        return result;
    }

    pub fn deinit(self: *const Settings, allocator: std.mem.Allocator) void {
        if (self.brain) |cfg| freeBrainConfig(allocator, &cfg);
        if (self.indexer) |cfg| freeToolConfig(allocator, &cfg);
        if (self.editor) |cfg| freeToolConfig(allocator, &cfg);
        if (self.creator) |cfg| freeToolConfig(allocator, &cfg);
        if (self.deleter) |cfg| freeToolConfig(allocator, &cfg);
        if (self.renamer) |cfg| freeToolConfig(allocator, &cfg);
    }
};

fn parseToolConfig(allocator: std.mem.Allocator, value: std.json.Value) !ToolConfig {
    if (value != .object) return error.InvalidSettings;
    const obj = value.object;

    const command_val = obj.get("command") orelse return error.InvalidSettings;
    if (command_val != .string) return error.InvalidSettings;
    const command = try allocator.dupe(u8, command_val.string);
    errdefer allocator.free(command);

    const args_val = obj.get("args") orelse {
        return .{ .command = command, .args = &.{} };
    };
    if (args_val != .array) {
        allocator.free(command);
        return error.InvalidSettings;
    }

    const args = try allocator.alloc([]const u8, args_val.array.items.len);
    var i: usize = 0;
    errdefer {
        for (args[0..i]) |a| allocator.free(a);
        allocator.free(args);
    }

    for (args_val.array.items) |item| {
        if (item != .string) return error.InvalidSettings;
        args[i] = try allocator.dupe(u8, item.string);
        i += 1;
    }

    return .{ .command = command, .args = args };
}

fn parseBrainConfig(allocator: std.mem.Allocator, value: std.json.Value) !BrainConfig {
    if (value != .object) return error.InvalidSettings;
    const obj = value.object;

    const url_val = obj.get("url") orelse return error.InvalidSettings;
    if (url_val != .string) return error.InvalidSettings;
    const url = try allocator.dupe(u8, url_val.string);

    return .{ .url = url };
}

fn freeBrainConfig(allocator: std.mem.Allocator, config: *const BrainConfig) void {
    allocator.free(config.url);
}

fn parseDebugConfig(value: std.json.Value) ?DebugConfig {
    if (value != .object) return null;
    const obj = value.object;

    var result: DebugConfig = .{};
    if (obj.get("timeout")) |v| {
        if (v == .integer) result.timeout = v.integer;
    }
    return result;
}

fn mergeDebugConfig(local: ?DebugConfig, global: ?DebugConfig) ?DebugConfig {
    const l = local orelse return global;
    const g = global orelse return local;
    return .{
        .timeout = l.timeout orelse g.timeout,
    };
}

fn freeToolConfig(allocator: std.mem.Allocator, config: *const ToolConfig) void {
    for (config.args) |arg| {
        allocator.free(arg);
    }
    if (config.args.len > 0) {
        allocator.free(config.args);
    }
    allocator.free(config.command);
}

/// Substitute placeholders in a single arg string.
/// Supported placeholders: {output}, {file}, {old}, {new}, {content}
pub fn substitutePlaceholder(allocator: std.mem.Allocator, template: []const u8, key: []const u8, value: []const u8) ![]const u8 {
    // Count occurrences
    var count: usize = 0;
    var pos: usize = 0;
    while (pos < template.len) {
        if (std.mem.startsWith(u8, template[pos..], key)) {
            count += 1;
            pos += key.len;
        } else {
            pos += 1;
        }
    }

    if (count == 0) return try allocator.dupe(u8, template);

    const new_len = template.len - (count * key.len) + (count * value.len);
    const result = try allocator.alloc(u8, new_len);
    var write_pos: usize = 0;
    var read_pos: usize = 0;

    while (read_pos < template.len) {
        if (std.mem.startsWith(u8, template[read_pos..], key)) {
            @memcpy(result[write_pos..][0..value.len], value);
            write_pos += value.len;
            read_pos += key.len;
        } else {
            result[write_pos] = template[read_pos];
            write_pos += 1;
            read_pos += 1;
        }
    }

    return result;
}

pub const Substitution = struct {
    key: []const u8,
    value: []const u8,
};

/// Substitute all known placeholders in an args array. Caller owns returned slice.
pub fn substituteArgs(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    subs: []const Substitution,
) ![]const []const u8 {
    const result = try allocator.alloc([]const u8, args.len);
    var i: usize = 0;
    errdefer {
        for (result[0..i]) |a| allocator.free(a);
        allocator.free(result);
    }

    for (args) |arg| {
        var current: []const u8 = try allocator.dupe(u8, arg);
        for (subs) |sub| {
            const next = substitutePlaceholder(allocator, current, sub.key, sub.value) catch {
                allocator.free(current);
                return error.SubstitutionFailed;
            };
            allocator.free(current);
            current = next;
        }
        result[i] = current;
        i += 1;
    }

    return result;
}

pub fn freeSubstitutedArgs(allocator: std.mem.Allocator, args: []const []const u8) void {
    for (args) |a| allocator.free(a);
    allocator.free(args);
}

// ── Tests ───────────────────────────────────────────────────────────────

test "parse settings with indexer and editor" {
    const allocator = std.testing.allocator;
    const json =
        \\{"indexer":{"command":"scip-zig","args":["--root-path",".","--output","{output}"]},"editor":{"command":"sed","args":["-i","","s/{old}/{new}/g","{file}"]}}
    ;
    const settings = Settings.parse(allocator, json) orelse return error.ParseFailed;
    defer settings.deinit(allocator);

    try std.testing.expectEqualStrings("scip-zig", settings.indexer.?.command);
    try std.testing.expectEqual(@as(usize, 4), settings.indexer.?.args.len);
    try std.testing.expectEqualStrings("--output", settings.indexer.?.args[2]);
    try std.testing.expectEqualStrings("{output}", settings.indexer.?.args[3]);

    try std.testing.expectEqualStrings("sed", settings.editor.?.command);
    try std.testing.expectEqual(@as(usize, 4), settings.editor.?.args.len);
}

test "parse settings with only indexer" {
    const allocator = std.testing.allocator;
    const json =
        \\{"indexer":{"command":"scip-go","args":["--output","{output}"]}}
    ;
    const settings = Settings.parse(allocator, json) orelse return error.ParseFailed;
    defer settings.deinit(allocator);

    try std.testing.expect(settings.indexer != null);
    try std.testing.expect(settings.editor == null);
}

test "parse settings empty object" {
    const allocator = std.testing.allocator;
    const json = "{}";
    const settings = Settings.parse(allocator, json) orelse return error.ParseFailed;
    defer settings.deinit(allocator);

    try std.testing.expect(settings.indexer == null);
    try std.testing.expect(settings.editor == null);
}

test "parse settings invalid json returns null" {
    const allocator = std.testing.allocator;
    const result = Settings.parse(allocator, "not json");
    try std.testing.expect(result == null);
}

test "parse settings command without args" {
    const allocator = std.testing.allocator;
    const json =
        \\{"indexer":{"command":"my-indexer"}}
    ;
    const settings = Settings.parse(allocator, json) orelse return error.ParseFailed;
    defer settings.deinit(allocator);

    try std.testing.expectEqualStrings("my-indexer", settings.indexer.?.command);
    try std.testing.expectEqual(@as(usize, 0), settings.indexer.?.args.len);
}

test "parse settings with all CRUD tool configs" {
    const allocator = std.testing.allocator;
    const json =
        \\{"creator":{"command":"touch","args":["{file}"]},"deleter":{"command":"rm","args":["{file}"]},"renamer":{"command":"mv","args":["{old}","{new}"]}}
    ;
    const settings = Settings.parse(allocator, json) orelse return error.ParseFailed;
    defer settings.deinit(allocator);

    try std.testing.expect(settings.creator != null);
    try std.testing.expectEqualStrings("touch", settings.creator.?.command);
    try std.testing.expect(settings.deleter != null);
    try std.testing.expectEqualStrings("rm", settings.deleter.?.command);
    try std.testing.expect(settings.renamer != null);
    try std.testing.expectEqualStrings("mv", settings.renamer.?.command);
}

test "substitutePlaceholder basic" {
    const allocator = std.testing.allocator;
    const result = try substitutePlaceholder(allocator, "--output={output}", "{output}", "/path/to/index.scip");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("--output=/path/to/index.scip", result);
}

test "substitutePlaceholder no match" {
    const allocator = std.testing.allocator;
    const result = try substitutePlaceholder(allocator, "--verbose", "{output}", "/path");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("--verbose", result);
}

test "substitutePlaceholder exact match" {
    const allocator = std.testing.allocator;
    const result = try substitutePlaceholder(allocator, "{file}", "{file}", "src/main.zig");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("src/main.zig", result);
}

test "parse settings with debug timeout" {
    const allocator = std.testing.allocator;
    const json =
        \\{"debug":{"timeout":300000}}
    ;
    const settings = Settings.parse(allocator, json) orelse return error.ParseFailed;
    defer settings.deinit(allocator);

    try std.testing.expect(settings.debug != null);
    try std.testing.expectEqual(@as(i64, 300000), settings.debug.?.timeout.?);
}

test "parse settings debug without timeout uses null" {
    const allocator = std.testing.allocator;
    const json =
        \\{"debug":{}}
    ;
    const settings = Settings.parse(allocator, json) orelse return error.ParseFailed;
    defer settings.deinit(allocator);

    try std.testing.expect(settings.debug != null);
    try std.testing.expect(settings.debug.?.timeout == null);
}

test "substituteArgs multiple placeholders" {
    const allocator = std.testing.allocator;
    const args: []const []const u8 = &.{ "-i", "", "s/{old}/{new}/g", "{file}" };
    const subs: []const Substitution = &.{
        .{ .key = "{old}", .value = "hello" },
        .{ .key = "{new}", .value = "world" },
        .{ .key = "{file}", .value = "test.txt" },
    };
    const result = try substituteArgs(allocator, args, subs);
    defer freeSubstitutedArgs(allocator, result);

    try std.testing.expectEqual(@as(usize, 4), result.len);
    try std.testing.expectEqualStrings("-i", result[0]);
    try std.testing.expectEqualStrings("", result[1]);
    try std.testing.expectEqualStrings("s/hello/world/g", result[2]);
    try std.testing.expectEqualStrings("test.txt", result[3]);
}
