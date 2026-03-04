const std = @import("std");
const build_options = @import("build_options");
const paths = @import("paths.zig");
const scip = @import("scip.zig");
const protobuf = @import("protobuf.zig");
const tui = @import("tui.zig");
const help_text = @import("help_text.zig");

// ANSI styles
const cyan = "\x1B[36m";
const bold = "\x1B[1m";
const dim = "\x1B[2m";
const reset = "\x1B[0m";
const green = "\x1B[32m";
const red = "\x1B[31m";

fn printErr(msg: []const u8) void {
    if (@import("builtin").is_test) return;
    var buf: [4096]u8 = undefined;
    var w = std.fs.File.stderr().writer(&buf);
    w.interface.writeAll(msg) catch {};
    w.interface.flush() catch {};
}

fn printFmtErr(allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) void {
    const msg = std.fmt.allocPrint(allocator, fmt, args) catch return;
    defer allocator.free(msg);
    printErr(msg);
}

const BatchResult = struct {
    success: bool,
    file_count: usize,
};

/// Dispatch mem:* subcommands.
pub fn dispatch(allocator: std.mem.Allocator, subcmd: []const u8, args: []const [:0]const u8) !void {
    if (std.mem.eql(u8, subcmd, "mem:bootstrap")) {
        return memBootstrap(allocator, args);
    }

    printErr("error: unknown command '");
    printErr(subcmd);
    printErr("'\nRun " ++ dim ++ "cog mem --help" ++ reset ++ " to see available commands.\n");
    return error.Explained;
}

fn hasFlag(args: []const [:0]const u8, flag: []const u8) bool {
    for (args) |arg| {
        if (std.mem.eql(u8, arg, flag)) return true;
    }
    return false;
}

fn getFlagValue(args: []const [:0]const u8, flag: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg: []const u8 = args[i];
        if (std.mem.eql(u8, arg, flag)) {
            if (i + 1 < args.len) return args[i + 1];
            return null;
        }
        // Handle --flag=value
        if (std.mem.startsWith(u8, arg, flag) and arg.len > flag.len and arg[flag.len] == '=') {
            return arg[flag.len + 1 ..];
        }
    }
    return null;
}

fn memBootstrap(allocator: std.mem.Allocator, args: []const [:0]const u8) !void {
    if (hasFlag(args, "--help") or hasFlag(args, "-h")) {
        tui.header();
        printErr(help_text.mem_bootstrap);
        return;
    }

    // Parse options
    const batch_size: usize = if (getFlagValue(args, "--batch-size")) |v|
        std.fmt.parseInt(usize, v, 10) catch {
            printErr("error: invalid --batch-size value\n");
            return error.Explained;
        }
    else
        20;

    const concurrency: usize = if (getFlagValue(args, "--concurrency")) |v|
        std.fmt.parseInt(usize, v, 10) catch {
            printErr("error: invalid --concurrency value\n");
            return error.Explained;
        }
    else
        1;

    if (batch_size == 0) {
        printErr("error: --batch-size must be at least 1\n");
        return error.Explained;
    }
    if (concurrency == 0) {
        printErr("error: --concurrency must be at least 1\n");
        return error.Explained;
    }

    const clean = hasFlag(args, "--clean");

    try runBootstrap(allocator, batch_size, concurrency, clean);
}

fn runBootstrap(allocator: std.mem.Allocator, batch_size: usize, concurrency: usize, clean: bool) !void {
    // Get project root (cwd)
    const project_root = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(project_root);

    // Collect files
    printErr("\n" ++ bold ++ "  Collecting files..." ++ reset ++ "\n");
    var files = try collectSourceFiles(allocator);
    defer {
        for (files.items) |f| allocator.free(f);
        files.deinit(allocator);
    }

    if (files.items.len == 0) {
        printErr("  No files found to process.\n\n");
        return;
    }
    printFmtErr(allocator, "  Found {d} files\n", .{files.items.len});

    // Load checkpoint (unless --clean)
    const cog_dir = paths.findCogDir(allocator) catch blk: {
        // No .cog dir — try to create one
        break :blk paths.findOrCreateCogDir(allocator) catch {
            printErr("error: cannot find or create .cog directory\n");
            return error.Explained;
        };
    };
    defer allocator.free(cog_dir);

    const checkpoint_path = try std.fmt.allocPrint(allocator, "{s}/bootstrap-checkpoint.json", .{cog_dir});
    defer allocator.free(checkpoint_path);

    if (clean) {
        // Delete checkpoint file
        std.fs.deleteFileAbsolute(checkpoint_path) catch {};
        printErr("  Checkpoint cleared\n");
    }

    var processed = loadCheckpoint(allocator, checkpoint_path);
    defer {
        var it = processed.keyIterator();
        while (it.next()) |key| allocator.free(key.*);
        processed.deinit(allocator);
    }

    // Filter out already-processed files
    var remaining: std.ArrayListUnmanaged([]const u8) = .empty;
    defer remaining.deinit(allocator);
    for (files.items) |f| {
        if (!processed.contains(f)) {
            try remaining.append(allocator, f);
        }
    }

    if (remaining.items.len == 0) {
        printErr("  All files already processed. Use " ++ dim ++ "--clean" ++ reset ++ " to restart.\n\n");
        return;
    }

    if (processed.count() > 0) {
        printFmtErr(allocator, "  Resuming: {d} remaining ({d} already processed)\n", .{ remaining.items.len, processed.count() });
    }

    // Split into batches
    const total_batches = (remaining.items.len + batch_size - 1) / batch_size;
    printFmtErr(allocator, "  Processing {d} files in {d} batches (size={d}, concurrency={d})\n\n", .{
        remaining.items.len,
        total_batches,
        batch_size,
        concurrency,
    });

    var batches_done: usize = 0;
    var files_done: usize = 0;
    var errors: usize = 0;

    if (concurrency <= 1) {
        // Sequential processing
        var batch_start: usize = 0;
        while (batch_start < remaining.items.len) {
            const batch_end = @min(batch_start + batch_size, remaining.items.len);
            const batch_files = remaining.items[batch_start..batch_end];
            batches_done += 1;

            printFmtErr(allocator, "  " ++ cyan ++ "Batch {d}/{d}" ++ reset ++ " ({d} files)...\n", .{
                batches_done,
                total_batches,
                batch_files.len,
            });

            const result = runBatch(allocator, batch_files, project_root);
            if (result.success) {
                files_done += result.file_count;
                // Update checkpoint
                for (batch_files) |f| {
                    const duped = allocator.dupe(u8, f) catch continue;
                    processed.put(allocator, duped, {}) catch {
                        allocator.free(duped);
                    };
                }
                saveCheckpoint(allocator, checkpoint_path, &processed);
                printErr("    " ++ green ++ "done" ++ reset ++ "\n");
            } else {
                errors += 1;
                printErr("    " ++ red ++ "failed" ++ reset ++ "\n");
            }

            batch_start = batch_end;
        }
    } else {
        // Concurrent processing using threads
        var batch_start: usize = 0;
        while (batch_start < remaining.items.len) {
            // Launch up to `concurrency` batches in parallel
            var threads: std.ArrayListUnmanaged(std.Thread) = .empty;
            defer threads.deinit(allocator);

            var contexts: std.ArrayListUnmanaged(ThreadContext) = .empty;
            defer contexts.deinit(allocator);

            var launched: usize = 0;
            while (launched < concurrency and batch_start < remaining.items.len) {
                const batch_end = @min(batch_start + batch_size, remaining.items.len);
                const batch_files = remaining.items[batch_start..batch_end];

                try contexts.append(allocator, .{
                    .batch_files = batch_files,
                    .project_root = project_root,
                    .allocator = allocator,
                });

                batch_start = batch_end;
                launched += 1;
            }

            // Spawn threads for each context
            for (contexts.items) |*ctx| {
                const thread = std.Thread.spawn(.{}, runBatchThread, .{ctx}) catch {
                    ctx.result = .{ .success = false, .file_count = 0 };
                    continue;
                };
                try threads.append(allocator, thread);
            }

            // Join all threads
            for (threads.items) |thread| {
                thread.join();
            }

            // Collect results
            for (contexts.items) |ctx| {
                batches_done += 1;
                if (ctx.result.success) {
                    files_done += ctx.result.file_count;
                    for (ctx.batch_files) |f| {
                        const duped = allocator.dupe(u8, f) catch continue;
                        processed.put(allocator, duped, {}) catch {
                            allocator.free(duped);
                        };
                    }
                    printFmtErr(allocator, "  " ++ green ++ "Batch {d}/{d} done" ++ reset ++ " ({d} files)\n", .{
                        batches_done,
                        total_batches,
                        ctx.batch_files.len,
                    });
                } else {
                    errors += 1;
                    printFmtErr(allocator, "  " ++ red ++ "Batch {d}/{d} failed" ++ reset ++ "\n", .{
                        batches_done,
                        total_batches,
                    });
                }
            }

            // Save checkpoint after each wave
            saveCheckpoint(allocator, checkpoint_path, &processed);
        }
    }

    // Summary
    printErr("\n" ++ bold ++ "  Summary" ++ reset ++ "\n");
    printFmtErr(allocator, "    Files processed: {d}\n", .{files_done});
    if (errors > 0) {
        printFmtErr(allocator, "    Batch errors:    {d}\n", .{errors});
    }
    printFmtErr(allocator, "    Total processed: {d}/{d}\n\n", .{ processed.count(), files.items.len });
}

const ThreadContext = struct {
    batch_files: []const []const u8,
    project_root: []const u8,
    allocator: std.mem.Allocator,
    result: BatchResult = .{ .success = false, .file_count = 0 },
};

fn runBatchThread(ctx: *ThreadContext) void {
    ctx.result = runBatch(ctx.allocator, ctx.batch_files, ctx.project_root);
}

fn runBatch(allocator: std.mem.Allocator, batch_files: []const []const u8, project_root: []const u8) BatchResult {
    // Build prompt: template + file list
    const template = build_options.bootstrap_prompt;

    // Build file list string
    var file_list_buf: std.ArrayListUnmanaged(u8) = .empty;
    defer file_list_buf.deinit(allocator);
    for (batch_files) |f| {
        file_list_buf.appendSlice(allocator, "- ") catch return .{ .success = false, .file_count = 0 };
        file_list_buf.appendSlice(allocator, f) catch return .{ .success = false, .file_count = 0 };
        file_list_buf.append(allocator, '\n') catch return .{ .success = false, .file_count = 0 };
    }

    // Replace {file_list} placeholder in template
    const prompt = replaceFileList(allocator, template, file_list_buf.items) catch return .{ .success = false, .file_count = 0 };
    defer allocator.free(prompt);

    // Spawn claude -p via env -u to unset vars that prevent nested claude
    const argv: []const []const u8 = &.{
        "env",
        "-u",
        "CLAUDECODE",
        "-u",
        "CLAUDE_CODE_ENTRYPOINT",
        "claude",
        "-p",
        prompt,
        "--output-format",
        "json",
        "--dangerously-skip-permissions",
    };

    var child = std.process.Child.init(argv, allocator);
    child.cwd = project_root;
    child.stderr_behavior = .Inherit;
    child.stdout_behavior = .Pipe;

    child.spawn() catch return .{ .success = false, .file_count = 0 };

    // Read stdout (JSON output)
    // We need to drain stdout to prevent pipe blockage
    const stdout = child.stdout orelse {
        _ = child.wait() catch {};
        return .{ .success = false, .file_count = 0 };
    };
    _ = stdout.readToEndAlloc(allocator, 10 * 1024 * 1024) catch {
        _ = child.wait() catch {};
        return .{ .success = false, .file_count = 0 };
    };

    const term = child.wait() catch return .{ .success = false, .file_count = 0 };
    const success = term.Exited == 0;

    return .{
        .success = success,
        .file_count = if (success) batch_files.len else 0,
    };
}

fn replaceFileList(allocator: std.mem.Allocator, template: []const u8, file_list: []const u8) ![]u8 {
    const placeholder = "{file_list}";
    const idx = std.mem.indexOf(u8, template, placeholder) orelse {
        return allocator.dupe(u8, template);
    };
    const result = try allocator.alloc(u8, template.len - placeholder.len + file_list.len);
    @memcpy(result[0..idx], template[0..idx]);
    @memcpy(result[idx .. idx + file_list.len], file_list);
    @memcpy(result[idx + file_list.len ..], template[idx + placeholder.len ..]);
    return result;
}

/// Collect files from SCIP index + doc globs.
fn collectSourceFiles(allocator: std.mem.Allocator) !std.ArrayListUnmanaged([]const u8) {
    var files: std.ArrayListUnmanaged([]const u8) = .empty;
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(allocator);

    // 1. Load SCIP index if available
    const cog_dir = paths.findCogDir(allocator) catch null;
    defer if (cog_dir) |d| allocator.free(d);

    if (cog_dir) |cd| {
        loadScipFiles(allocator, cd, &files, &seen);
    }

    // 2. Walk for documentation files
    try walkForDocs(allocator, ".", &files, &seen);

    // 3. Sort alphabetically
    sortFiles(files.items);

    return files;
}

fn loadScipFiles(
    allocator: std.mem.Allocator,
    cog_dir: []const u8,
    files: *std.ArrayListUnmanaged([]const u8),
    seen: *std.StringHashMapUnmanaged(void),
) void {
    const index_path = std.fmt.allocPrint(allocator, "{s}/index.scip", .{cog_dir}) catch return;
    defer allocator.free(index_path);

    const file = std.fs.openFileAbsolute(index_path, .{}) catch return;
    defer file.close();

    const data = file.readToEndAlloc(allocator, 256 * 1024 * 1024) catch return;
    var index = scip.decode(allocator, data) catch {
        allocator.free(data);
        return;
    };
    defer {
        scip.freeIndex(allocator, &index);
        allocator.free(data);
    }

    for (index.documents) |doc| {
        if (doc.relative_path.len > 0 and !seen.contains(doc.relative_path)) {
            const duped = allocator.dupe(u8, doc.relative_path) catch continue;
            files.append(allocator, duped) catch {
                allocator.free(duped);
                continue;
            };
            seen.put(allocator, duped, {}) catch {};
        }
    }
}

fn walkForDocs(
    allocator: std.mem.Allocator,
    dir_path: []const u8,
    files: *std.ArrayListUnmanaged([]const u8),
    seen: *std.StringHashMapUnmanaged(void),
) !void {
    var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch return;
    defer dir.close();

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        // Skip hidden dirs and common non-source dirs
        if (entry.name[0] == '.') continue;
        if (std.mem.eql(u8, entry.name, "node_modules")) continue;
        if (std.mem.eql(u8, entry.name, "vendor")) continue;
        if (std.mem.eql(u8, entry.name, "target")) continue;
        if (std.mem.eql(u8, entry.name, "zig-out")) continue;
        if (std.mem.eql(u8, entry.name, "zig-cache")) continue;
        if (std.mem.eql(u8, entry.name, "grammars")) continue;

        const child_path = if (std.mem.eql(u8, dir_path, "."))
            try allocator.dupe(u8, entry.name)
        else
            try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir_path, entry.name });

        if (entry.kind == .directory) {
            try walkForDocs(allocator, child_path, files, seen);
            allocator.free(child_path);
        } else if (entry.kind == .file) {
            if (isDocFile(entry.name) and !seen.contains(child_path)) {
                try files.append(allocator, child_path);
                try seen.put(allocator, child_path, {});
            } else {
                allocator.free(child_path);
            }
        } else {
            allocator.free(child_path);
        }
    }
}

fn isDocFile(name: []const u8) bool {
    // Match *.md files
    if (std.mem.endsWith(u8, name, ".md")) return true;

    // Match README*, CHANGELOG*, LICENSE* (case-sensitive)
    const upper = name;
    if (std.mem.startsWith(u8, upper, "README")) return true;
    if (std.mem.startsWith(u8, upper, "CHANGELOG")) return true;
    if (std.mem.startsWith(u8, upper, "LICENSE")) return true;

    return false;
}

fn sortFiles(items: [][]const u8) void {
    std.mem.sort([]const u8, items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lessThan);
}

fn loadCheckpoint(allocator: std.mem.Allocator, checkpoint_path: []const u8) std.StringHashMapUnmanaged(void) {
    var map: std.StringHashMapUnmanaged(void) = .empty;

    const file = std.fs.openFileAbsolute(checkpoint_path, .{}) catch return map;
    defer file.close();

    const data = file.readToEndAlloc(allocator, 4 * 1024 * 1024) catch return map;
    defer allocator.free(data);

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, data, .{}) catch return map;
    defer parsed.deinit();

    if (parsed.value != .object) return map;
    const obj = parsed.value.object;

    const files_val = obj.get("processed_files") orelse return map;
    if (files_val != .array) return map;

    for (files_val.array.items) |item| {
        if (item == .string) {
            const duped = allocator.dupe(u8, item.string) catch continue;
            map.put(allocator, duped, {}) catch {
                allocator.free(duped);
            };
        }
    }

    return map;
}

fn saveCheckpoint(allocator: std.mem.Allocator, checkpoint_path: []const u8, processed: *std.StringHashMapUnmanaged(void)) void {
    // Collect all keys into a sorted slice
    var keys: std.ArrayListUnmanaged([]const u8) = .empty;
    defer keys.deinit(allocator);

    var it = processed.keyIterator();
    while (it.next()) |key| {
        keys.append(allocator, key.*) catch continue;
    }
    sortFiles(keys.items);

    // Build JSON manually
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);

    buf.appendSlice(allocator, "{\n  \"version\": 1,\n  \"processed_files\": [\n") catch return;

    for (keys.items, 0..) |key, i| {
        buf.appendSlice(allocator, "    \"") catch return;
        // Escape the key for JSON
        for (key) |c| {
            switch (c) {
                '"' => buf.appendSlice(allocator, "\\\"") catch return,
                '\\' => buf.appendSlice(allocator, "\\\\") catch return,
                '\n' => buf.appendSlice(allocator, "\\n") catch return,
                else => buf.append(allocator, c) catch return,
            }
        }
        buf.append(allocator, '"') catch return;
        if (i + 1 < keys.items.len) {
            buf.append(allocator, ',') catch return;
        }
        buf.append(allocator, '\n') catch return;
    }

    buf.appendSlice(allocator, "  ]\n}\n") catch return;

    // Write atomically
    const file = std.fs.createFileAbsolute(checkpoint_path, .{}) catch return;
    defer file.close();
    file.writeAll(buf.items) catch {};
}

// Tests
test "replaceFileList basic" {
    const allocator = std.testing.allocator;
    const result = try replaceFileList(allocator, "prefix {file_list} suffix", "a.zig\nb.zig\n");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("prefix a.zig\nb.zig\n suffix", result);
}

test "replaceFileList no placeholder" {
    const allocator = std.testing.allocator;
    const result = try replaceFileList(allocator, "no placeholder here", "files");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("no placeholder here", result);
}

test "isDocFile" {
    try std.testing.expect(isDocFile("README.md"));
    try std.testing.expect(isDocFile("CHANGELOG.md"));
    try std.testing.expect(isDocFile("LICENSE"));
    try std.testing.expect(isDocFile("README"));
    try std.testing.expect(isDocFile("docs.md"));
    try std.testing.expect(!isDocFile("main.zig"));
    try std.testing.expect(!isDocFile("config.json"));
}

test "sortFiles" {
    const allocator = std.testing.allocator;
    var items = [_][]const u8{ "c.zig", "a.zig", "b.zig" };
    sortFiles(&items);
    try std.testing.expectEqualStrings("a.zig", items[0]);
    try std.testing.expectEqualStrings("b.zig", items[1]);
    try std.testing.expectEqualStrings("c.zig", items[2]);
    _ = allocator;
}

test "loadCheckpoint missing file" {
    const allocator = std.testing.allocator;
    var map = loadCheckpoint(allocator, "/tmp/nonexistent-bootstrap-checkpoint.json");
    defer map.deinit(allocator);
    try std.testing.expectEqual(@as(u32, 0), map.count());
}
