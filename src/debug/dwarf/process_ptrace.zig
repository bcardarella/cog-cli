const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const process_mach = @import("process_mach.zig");

// ── Linux ptrace-based Process Control ──────────────────────────────────

const WUNTRACED: u32 = 0x00000002;
const SIGKILL: u8 = 9;

pub const PtraceProcessControl = struct {
    pid: ?posix.pid_t = null,
    is_running: bool = false,

    pub fn spawn(self: *PtraceProcessControl, allocator: std.mem.Allocator, program: []const u8, args: []const []const u8) !void {
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
            if (builtin.os.tag == .linux) {
                _ = std.os.linux.ptrace(.TRACEME, 0, 0, 0);
            }
            posix.execvpeZ(prog_z.ptr, @ptrCast(argv.items.ptr), @ptrCast(std.c.environ)) catch {};
            std.posix.exit(127);
        }

        self.pid = pid;
        self.is_running = false;

        _ = posix.waitpid(pid, WUNTRACED);
    }

    pub fn continueExecution(self: *PtraceProcessControl) !void {
        if (self.pid) |pid| {
            if (builtin.os.tag == .linux) {
                _ = std.os.linux.ptrace(.CONT, pid, 0, 0);
            }
            self.is_running = true;
        }
    }

    pub fn singleStep(self: *PtraceProcessControl) !void {
        if (self.pid) |pid| {
            if (builtin.os.tag == .linux) {
                _ = std.os.linux.ptrace(.SINGLESTEP, pid, 0, 0);
            }
            self.is_running = true;
        }
    }

    pub fn waitForStop(self: *PtraceProcessControl) !process_mach.WaitResult {
        if (self.pid) |pid| {
            const result = posix.waitpid(pid, WUNTRACED);
            self.is_running = false;

            const status = result.status;
            if ((status & 0x7f) == 0) {
                return .{ .status = .exited, .exit_code = @intCast((status >> 8) & 0xff) };
            }
            if ((status & 0xff) == 0x7f) {
                return .{ .status = .stopped, .signal = @intCast((status >> 8) & 0xff) };
            }
            return .{ .status = .unknown };
        }
        return error.NoProcess;
    }

    pub fn readRegisters(self: *PtraceProcessControl) !process_mach.RegisterState {
        _ = self;
        return .{};
    }

    pub fn readMemory(self: *PtraceProcessControl, address: u64, size: usize, allocator: std.mem.Allocator) ![]u8 {
        _ = self;
        _ = address;
        const buf = try allocator.alloc(u8, size);
        @memset(buf, 0);
        return buf;
    }

    pub fn writeMemory(self: *PtraceProcessControl, address: u64, data: []const u8) !void {
        _ = self;
        _ = address;
        _ = data;
    }

    pub fn kill(self: *PtraceProcessControl) !void {
        if (self.pid) |pid| {
            posix.kill(pid, SIGKILL) catch {};
            _ = posix.waitpid(pid, 0);
            self.pid = null;
            self.is_running = false;
        }
    }

    pub fn attach(self: *PtraceProcessControl, pid: posix.pid_t) !void {
        if (builtin.os.tag == .linux) {
            _ = std.os.linux.ptrace(.ATTACH, pid, 0, 0);
        }
        self.pid = pid;
        self.is_running = false;
        _ = posix.waitpid(pid, WUNTRACED);
    }

    pub fn writeRegisters(self: *PtraceProcessControl, regs: process_mach.RegisterState) !void {
        _ = self;
        _ = regs;
        // On Linux, register writes use PTRACE_SETREGS
    }

    pub fn detach(self: *PtraceProcessControl) !void {
        if (self.pid) |pid| {
            if (builtin.os.tag == .linux) {
                _ = std.os.linux.ptrace(.DETACH, pid, 0, 0);
            }
            self.pid = null;
            self.is_running = false;
        }
    }
};

// ── Tests ───────────────────────────────────────────────────────────────

test "PtraceProcessControl initial state" {
    const pc = PtraceProcessControl{};
    try std.testing.expect(pc.pid == null);
    try std.testing.expect(!pc.is_running);
}
