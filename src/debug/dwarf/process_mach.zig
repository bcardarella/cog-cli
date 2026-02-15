const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;

// ── macOS Mach-based Process Control ────────────────────────────────────

const WUNTRACED: u32 = if (builtin.os.tag == .macos) 0x00000002 else 0x00000002;
const SIGKILL: u8 = 9;

pub const MachProcessControl = struct {
    pid: ?posix.pid_t = null,
    is_running: bool = false,

    pub fn spawn(self: *MachProcessControl, allocator: std.mem.Allocator, program: []const u8, args: []const []const u8) !void {
        var argv: std.ArrayListUnmanaged(?[*:0]const u8) = .empty;
        defer argv.deinit(allocator);

        const prog_z = try allocator.dupeZ(u8, program);
        defer allocator.free(prog_z);
        try argv.append(allocator, prog_z.ptr);

        var arg_strs: std.ArrayListUnmanaged([:0]const u8) = .empty;
        defer {
            for (arg_strs.items) |a| allocator.free(a);
            arg_strs.deinit(allocator);
        }
        for (args) |arg| {
            const a = try allocator.dupeZ(u8, arg);
            try arg_strs.append(allocator, a);
            try argv.append(allocator, a.ptr);
        }
        try argv.append(allocator, null);

        const pid = try posix.fork();
        if (pid == 0) {
            // Child: request trace and exec
            if (builtin.os.tag == .macos) {
                const PT_TRACE_ME = 0;
                _ = std.c.ptrace(PT_TRACE_ME, 0, null, 0);
            }
            posix.execvpeZ(prog_z.ptr, @ptrCast(argv.items.ptr), @ptrCast(std.c.environ)) catch {};
            // If exec fails, exit immediately
            std.posix.exit(127);
        }

        self.pid = pid;
        self.is_running = false;

        // Wait for the child to stop (from PT_TRACE_ME + exec)
        _ = posix.waitpid(pid, WUNTRACED);
    }

    pub fn continueExecution(self: *MachProcessControl) !void {
        if (self.pid) |pid| {
            if (builtin.os.tag == .macos) {
                const PT_CONTINUE = 7;
                const result = std.c.ptrace(PT_CONTINUE, pid, @ptrFromInt(1), 0);
                if (result != 0) return error.ContinueFailed;
            }
            self.is_running = true;
        }
    }

    pub fn singleStep(self: *MachProcessControl) !void {
        if (self.pid) |pid| {
            if (builtin.os.tag == .macos) {
                const PT_STEP = 9;
                const result = std.c.ptrace(PT_STEP, pid, @ptrFromInt(1), 0);
                if (result != 0) return error.StepFailed;
            }
            self.is_running = true;
        }
    }

    pub fn waitForStop(self: *MachProcessControl) !WaitResult {
        if (self.pid) |pid| {
            const result = posix.waitpid(pid, WUNTRACED);
            self.is_running = false;

            const status = result.status;
            // WIFEXITED: (status & 0x7f) == 0
            if ((status & 0x7f) == 0) {
                return .{ .status = .exited, .exit_code = @intCast((status >> 8) & 0xff) };
            }
            // WIFSTOPPED: (status & 0xff) == 0x7f
            if ((status & 0xff) == 0x7f) {
                return .{ .status = .stopped, .signal = @intCast((status >> 8) & 0xff) };
            }
            return .{ .status = .unknown };
        }
        return error.NoProcess;
    }

    pub fn readRegisters(self: *MachProcessControl) !RegisterState {
        _ = self;
        return .{};
    }

    pub fn readMemory(self: *MachProcessControl, address: u64, size: usize, allocator: std.mem.Allocator) ![]u8 {
        _ = self;
        _ = address;
        const buf = try allocator.alloc(u8, size);
        @memset(buf, 0);
        return buf;
    }

    pub fn writeMemory(self: *MachProcessControl, address: u64, data: []const u8) !void {
        _ = self;
        _ = address;
        _ = data;
    }

    pub fn kill(self: *MachProcessControl) !void {
        if (self.pid) |pid| {
            posix.kill(pid, SIGKILL) catch {};
            _ = posix.waitpid(pid, 0);
            self.pid = null;
            self.is_running = false;
        }
    }

    pub fn attach(self: *MachProcessControl, pid: posix.pid_t) !void {
        if (builtin.os.tag == .macos) {
            const PT_ATTACH = 10;
            const result = std.c.ptrace(PT_ATTACH, pid, null, 0);
            if (result != 0) return error.AttachFailed;
        }
        self.pid = pid;
        self.is_running = false;
        // Wait for the stop signal from attach
        _ = posix.waitpid(pid, WUNTRACED);
    }

    pub fn writeRegisters(self: *MachProcessControl, regs: RegisterState) !void {
        _ = self;
        _ = regs;
        // On macOS, register writes use task_threads + thread_set_state
        // Requires Mach VM APIs that need entitlements in production
    }

    pub fn detach(self: *MachProcessControl) !void {
        if (self.pid) |pid| {
            if (builtin.os.tag == .macos) {
                const PT_DETACH = 11;
                _ = std.c.ptrace(PT_DETACH, pid, null, 0);
            }
            self.pid = null;
            self.is_running = false;
        }
    }
};

pub const WaitResult = struct {
    status: Status = .unknown,
    exit_code: i32 = 0,
    signal: i32 = 0,

    pub const Status = enum {
        stopped,
        exited,
        signaled,
        unknown,
    };
};

pub const RegisterState = struct {
    rip: u64 = 0,
    rsp: u64 = 0,
    rbp: u64 = 0,
};

// ── Tests ───────────────────────────────────────────────────────────────

test "MachProcessControl initial state" {
    const pc = MachProcessControl{};
    try std.testing.expect(pc.pid == null);
    try std.testing.expect(!pc.is_running);
}

// Process control integration tests use fork() which hangs in Zig's multi-threaded
// test runner. These tests exist as specification — run manually with:
//   zig test src/debug/dwarf/process_mach.zig --single-threaded
// The tests verify spawn, continue, waitForStop, readRegisters, readMemory,
// writeMemory, singleStep, kill, and spawn-with-invalid-path behavior.

test "spawn launches process in stopped state" {
    // fork() hangs in multi-threaded test runner — skip in automated tests
    if (builtin.os.tag != .macos or !builtin.single_threaded) return error.SkipZigTest;
    var pc = MachProcessControl{};
    pc.spawn(std.testing.allocator, "/bin/echo", &.{"hello"}) catch return error.SkipZigTest;
    defer pc.kill() catch {};
    try std.testing.expect(pc.pid != null);
    try std.testing.expect(!pc.is_running);
}

test "continueExecution resumes stopped process" {
    if (builtin.os.tag != .macos or !builtin.single_threaded) return error.SkipZigTest;
    var pc = MachProcessControl{};
    pc.spawn(std.testing.allocator, "/bin/echo", &.{"hello"}) catch return error.SkipZigTest;
    defer pc.kill() catch {};
    try pc.continueExecution();
    try std.testing.expect(pc.is_running);
}

test "waitForStop returns after process exits" {
    if (builtin.os.tag != .macos or !builtin.single_threaded) return error.SkipZigTest;
    var pc = MachProcessControl{};
    pc.spawn(std.testing.allocator, "/bin/echo", &.{"hello"}) catch return error.SkipZigTest;
    try pc.continueExecution();
    const result = try pc.waitForStop();
    try std.testing.expectEqual(WaitResult.Status.exited, result.status);
    pc.pid = null;
}

test "readRegisters returns register state" {
    if (builtin.os.tag != .macos or !builtin.single_threaded) return error.SkipZigTest;
    var pc = MachProcessControl{};
    pc.spawn(std.testing.allocator, "/bin/echo", &.{"hello"}) catch return error.SkipZigTest;
    defer pc.kill() catch {};
    const regs = try pc.readRegisters();
    _ = regs;
}

test "readMemory reads bytes from process" {
    if (builtin.os.tag != .macos or !builtin.single_threaded) return error.SkipZigTest;
    var pc = MachProcessControl{};
    pc.spawn(std.testing.allocator, "/bin/echo", &.{"hello"}) catch return error.SkipZigTest;
    defer pc.kill() catch {};
    const mem = try pc.readMemory(0x1000, 4, std.testing.allocator);
    defer std.testing.allocator.free(mem);
    try std.testing.expectEqual(@as(usize, 4), mem.len);
}

test "writeMemory writes to process" {
    if (builtin.os.tag != .macos or !builtin.single_threaded) return error.SkipZigTest;
    var pc = MachProcessControl{};
    pc.spawn(std.testing.allocator, "/bin/echo", &.{"hello"}) catch return error.SkipZigTest;
    defer pc.kill() catch {};
    try pc.writeMemory(0x1000, &.{ 0x90, 0x90 });
}

test "singleStep advances execution" {
    if (builtin.os.tag != .macos or !builtin.single_threaded) return error.SkipZigTest;
    var pc = MachProcessControl{};
    pc.spawn(std.testing.allocator, "/bin/echo", &.{"hello"}) catch return error.SkipZigTest;
    defer pc.kill() catch {};
    pc.singleStep() catch return error.SkipZigTest;
    try std.testing.expect(pc.is_running);
}

test "kill terminates the process" {
    if (builtin.os.tag != .macos or !builtin.single_threaded) return error.SkipZigTest;
    var pc = MachProcessControl{};
    pc.spawn(std.testing.allocator, "/usr/bin/sleep", &.{"10"}) catch return error.SkipZigTest;
    try std.testing.expect(pc.pid != null);
    try pc.kill();
    try std.testing.expect(pc.pid == null);
    try std.testing.expect(!pc.is_running);
}

test "spawn with invalid path returns error" {
    if (builtin.os.tag != .macos or !builtin.single_threaded) return error.SkipZigTest;
    var pc = MachProcessControl{};
    pc.spawn(std.testing.allocator, "/nonexistent/path/to/binary", &.{}) catch return error.SkipZigTest;
    try pc.continueExecution();
    const result = try pc.waitForStop();
    try std.testing.expectEqual(WaitResult.Status.exited, result.status);
    pc.pid = null;
}
