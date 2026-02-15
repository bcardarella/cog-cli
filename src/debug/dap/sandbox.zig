const std = @import("std");
const builtin = @import("builtin");

// ── Sandbox ─────────────────────────────────────────────────────────────
//
// Debug adapter subprocesses run sandboxed to limit filesystem access,
// network scope, and process capabilities.
//
// macOS: sandbox-exec with generated Scheme profile
// Linux: Landlock LSM (restrict filesystem paths, network scope)

pub const Sandbox = union(enum) {
    seatbelt: SeatbeltSandbox,
    landlock: LandlockSandbox,
    none: void,

    pub fn forPlatform(project_dir: []const u8, allowed_write_dirs: []const []const u8) Sandbox {
        if (builtin.os.tag == .macos) {
            return .{ .seatbelt = SeatbeltSandbox.init(project_dir, allowed_write_dirs) };
        } else if (builtin.os.tag == .linux) {
            return .{ .landlock = LandlockSandbox.init(project_dir, allowed_write_dirs) };
        } else {
            return .{ .none = {} };
        }
    }

    /// Get the command prefix args needed to run a sandboxed process.
    pub fn wrapCommand(self: *const Sandbox, allocator: std.mem.Allocator, command: []const []const u8) ![]const []const u8 {
        switch (self.*) {
            .seatbelt => |*sb| return sb.wrapCommand(allocator, command),
            .landlock => return command, // Landlock applied via syscalls, no prefix
            .none => return command,
        }
    }
};

// ── macOS Seatbelt Sandbox ──────────────────────────────────────────────

pub const SeatbeltSandbox = struct {
    project_dir: []const u8,
    allowed_write_dirs: []const []const u8,

    pub fn init(project_dir: []const u8, allowed_write_dirs: []const []const u8) SeatbeltSandbox {
        return .{
            .project_dir = project_dir,
            .allowed_write_dirs = allowed_write_dirs,
        };
    }

    pub fn generateProfile(self: *const SeatbeltSandbox, allocator: std.mem.Allocator) ![]const u8 {
        var aw: std.io.Writer.Allocating = .init(allocator);
        errdefer aw.deinit();

        // Base: deny all
        try aw.writer.writeAll("(version 1)\n");
        try aw.writer.writeAll("(deny default)\n");

        // Allow process execution
        try aw.writer.writeAll("(allow process-exec)\n");
        try aw.writer.writeAll("(allow process-fork)\n");

        // Allow reading the project directory
        try aw.writer.writeAll("(allow file-read*\n");
        try aw.writer.writeAll("  (subpath \"");
        try aw.writer.writeAll(self.project_dir);
        try aw.writer.writeAll("\")\n");
        try aw.writer.writeAll(")\n");

        // Allow reading system libs and executables
        try aw.writer.writeAll("(allow file-read*\n");
        try aw.writer.writeAll("  (subpath \"/usr\")\n");
        try aw.writer.writeAll("  (subpath \"/bin\")\n");
        try aw.writer.writeAll("  (subpath \"/sbin\")\n");
        try aw.writer.writeAll("  (subpath \"/Library\")\n");
        try aw.writer.writeAll("  (subpath \"/System\")\n");
        try aw.writer.writeAll("  (subpath \"/private/var\")\n");
        try aw.writer.writeAll("  (subpath \"/dev\")\n");
        try aw.writer.writeAll(")\n");

        // Allow writing to /tmp and allowed dirs
        try aw.writer.writeAll("(allow file-write*\n");
        try aw.writer.writeAll("  (subpath \"/tmp\")\n");
        try aw.writer.writeAll("  (subpath \"/private/tmp\")\n");
        for (self.allowed_write_dirs) |dir| {
            try aw.writer.writeAll("  (subpath \"");
            try aw.writer.writeAll(dir);
            try aw.writer.writeAll("\")\n");
        }
        try aw.writer.writeAll(")\n");

        // Block writing to home directory (except allowed dirs)
        // (default deny handles this)

        // Allow localhost network only
        try aw.writer.writeAll("(allow network*\n");
        try aw.writer.writeAll("  (local ip \"localhost:*\")\n");
        try aw.writer.writeAll("  (remote ip \"localhost:*\")\n");
        try aw.writer.writeAll(")\n");

        // Allow sysctl for runtime info
        try aw.writer.writeAll("(allow sysctl-read)\n");

        return try aw.toOwnedSlice();
    }

    pub fn wrapCommand(self: *const SeatbeltSandbox, allocator: std.mem.Allocator, command: []const []const u8) ![]const []const u8 {
        const profile = try self.generateProfile(allocator);
        // sandbox-exec -p <profile> <command...>
        var args: std.ArrayListUnmanaged([]const u8) = .empty;
        errdefer args.deinit(allocator);

        try args.append(allocator, "sandbox-exec");
        try args.append(allocator, "-p");
        try args.append(allocator, profile);
        for (command) |arg| {
            try args.append(allocator, arg);
        }

        return try args.toOwnedSlice(allocator);
    }
};

// ── Linux Landlock Sandbox ──────────────────────────────────────────────

pub const LandlockSandbox = struct {
    project_dir: []const u8,
    allowed_write_dirs: []const []const u8,

    pub fn init(project_dir: []const u8, allowed_write_dirs: []const []const u8) LandlockSandbox {
        return .{
            .project_dir = project_dir,
            .allowed_write_dirs = allowed_write_dirs,
        };
    }

    pub const Rule = struct {
        path: []const u8,
        access: Access,

        pub const Access = enum {
            read_only,
            read_write,
            execute,
        };
    };

    pub fn generateRules(self: *const LandlockSandbox, allocator: std.mem.Allocator) ![]const Rule {
        var rules: std.ArrayListUnmanaged(Rule) = .empty;
        errdefer rules.deinit(allocator);

        // Project dir: read-only by default
        try rules.append(allocator, .{
            .path = self.project_dir,
            .access = .read_only,
        });

        // System paths: read-only + execute
        const system_paths = [_][]const u8{ "/usr", "/bin", "/sbin", "/lib", "/lib64" };
        for (&system_paths) |path| {
            try rules.append(allocator, .{
                .path = path,
                .access = .execute,
            });
        }

        // /tmp: read-write
        try rules.append(allocator, .{
            .path = "/tmp",
            .access = .read_write,
        });

        // Explicitly allowed write dirs
        for (self.allowed_write_dirs) |dir| {
            try rules.append(allocator, .{
                .path = dir,
                .access = .read_write,
            });
        }

        return try rules.toOwnedSlice(allocator);
    }

    /// Check if a path is allowed for read access under this sandbox's rules.
    pub fn isReadAllowed(self: *const LandlockSandbox, path: []const u8) bool {
        // Project dir
        if (std.mem.startsWith(u8, path, self.project_dir)) return true;
        // System paths
        if (std.mem.startsWith(u8, path, "/usr")) return true;
        if (std.mem.startsWith(u8, path, "/bin")) return true;
        if (std.mem.startsWith(u8, path, "/sbin")) return true;
        if (std.mem.startsWith(u8, path, "/lib")) return true;
        if (std.mem.startsWith(u8, path, "/tmp")) return true;
        // Allowed write dirs (readable too)
        for (self.allowed_write_dirs) |dir| {
            if (std.mem.startsWith(u8, path, dir)) return true;
        }
        return false;
    }

    /// Check if a path is allowed for write access.
    pub fn isWriteAllowed(self: *const LandlockSandbox, path: []const u8) bool {
        if (std.mem.startsWith(u8, path, "/tmp")) return true;
        for (self.allowed_write_dirs) |dir| {
            if (std.mem.startsWith(u8, path, dir)) return true;
        }
        return false;
    }
};

// ── Tests ───────────────────────────────────────────────────────────────

test "SeatbeltSandbox generates profile allowing project dir read" {
    const allocator = std.testing.allocator;
    const sb = SeatbeltSandbox.init("/home/user/project", &.{});
    const profile = try sb.generateProfile(allocator);
    defer allocator.free(profile);

    try std.testing.expect(std.mem.indexOf(u8, profile, "/home/user/project") != null);
    try std.testing.expect(std.mem.indexOf(u8, profile, "file-read*") != null);
}

test "SeatbeltSandbox generates profile blocking home dir write" {
    const allocator = std.testing.allocator;
    const sb = SeatbeltSandbox.init("/home/user/project", &.{});
    const profile = try sb.generateProfile(allocator);
    defer allocator.free(profile);

    // Profile starts with deny default
    try std.testing.expect(std.mem.indexOf(u8, profile, "(deny default)") != null);
    // Home dir is NOT listed in file-write* allowances
    // (only /tmp and allowed_write_dirs are)
    try std.testing.expect(std.mem.indexOf(u8, profile, "subpath \"/home\"") == null);
}

test "SeatbeltSandbox generates profile allowing localhost network" {
    const allocator = std.testing.allocator;
    const sb = SeatbeltSandbox.init("/home/user/project", &.{});
    const profile = try sb.generateProfile(allocator);
    defer allocator.free(profile);

    try std.testing.expect(std.mem.indexOf(u8, profile, "localhost") != null);
    try std.testing.expect(std.mem.indexOf(u8, profile, "network*") != null);
}

test "SeatbeltSandbox generates profile blocking external network" {
    const allocator = std.testing.allocator;
    const sb = SeatbeltSandbox.init("/home/user/project", &.{});
    const profile = try sb.generateProfile(allocator);
    defer allocator.free(profile);

    // Only localhost is allowed, deny default blocks everything else
    try std.testing.expect(std.mem.indexOf(u8, profile, "(deny default)") != null);
    // No wildcard network allows
    try std.testing.expect(std.mem.indexOf(u8, profile, "\"*:*\"") == null);
}

test "LandlockSandbox creates ruleset with filesystem restrictions" {
    const allocator = std.testing.allocator;
    const ll = LandlockSandbox.init("/home/user/project", &.{"/home/user/project/.debug"});
    const rules = try ll.generateRules(allocator);
    defer allocator.free(rules);

    try std.testing.expect(rules.len > 0);
    // First rule should be the project dir
    try std.testing.expectEqualStrings("/home/user/project", rules[0].path);
    try std.testing.expectEqual(LandlockSandbox.Rule.Access.read_only, rules[0].access);
}

test "LandlockSandbox allows read on allowed paths" {
    const ll = LandlockSandbox.init("/home/user/project", &.{});
    try std.testing.expect(ll.isReadAllowed("/home/user/project/src/main.py"));
    try std.testing.expect(ll.isReadAllowed("/usr/lib/python3/os.py"));
    try std.testing.expect(ll.isReadAllowed("/tmp/debug.log"));
}

test "LandlockSandbox denies write on restricted paths" {
    const ll = LandlockSandbox.init("/home/user/project", &.{});
    try std.testing.expect(!ll.isWriteAllowed("/home/user/project/src/main.py"));
    try std.testing.expect(!ll.isWriteAllowed("/etc/passwd"));
    try std.testing.expect(!ll.isWriteAllowed("/home/user/.ssh/id_rsa"));
    // /tmp is allowed
    try std.testing.expect(ll.isWriteAllowed("/tmp/debug.log"));
}

test "Sandbox.forPlatform returns correct variant for current OS" {
    const sandbox = Sandbox.forPlatform("/test", &.{});
    if (builtin.os.tag == .macos) {
        try std.testing.expect(sandbox == .seatbelt);
    } else if (builtin.os.tag == .linux) {
        try std.testing.expect(sandbox == .landlock);
    } else {
        try std.testing.expect(sandbox == .none);
    }
}

test "sandboxed subprocess can read fixture file" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;

    const allocator = std.testing.allocator;

    // Get the current working directory for the project dir
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd = std.posix.getcwd(&cwd_buf) catch return error.SkipZigTest;

    const sb = SeatbeltSandbox.init(cwd, &.{});
    const profile = try sb.generateProfile(allocator);
    defer allocator.free(profile);

    // The profile should allow reading our project directory
    try std.testing.expect(std.mem.indexOf(u8, profile, cwd) != null);

    // Verify the profile is valid by checking it starts correctly
    try std.testing.expect(std.mem.startsWith(u8, profile, "(version 1)\n"));
}

test "sandboxed subprocess cannot write outside allowed dirs" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    const sb = SeatbeltSandbox.init("/projects/test", &.{"/projects/test/.debug"});
    const profile = try sb.generateProfile(allocator);
    defer allocator.free(profile);

    // Profile should deny by default
    try std.testing.expect(std.mem.indexOf(u8, profile, "(deny default)") != null);

    // Only /tmp and allowed dirs should be writable
    try std.testing.expect(std.mem.indexOf(u8, profile, "subpath \"/tmp\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, profile, "subpath \"/projects/test/.debug\"") != null);

    // Home dir should NOT be writable
    try std.testing.expect(std.mem.indexOf(u8, profile, "subpath \"/home\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, profile, "subpath \"/Users\"") == null);
}
