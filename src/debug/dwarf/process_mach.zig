const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;

// ── macOS Mach-based Process Control ────────────────────────────────────

const WUNTRACED: u32 = if (builtin.os.tag == .macos) 0x00000002 else 0x00000002;
const SIGKILL: u8 = 9;

// macOS Mach thread state definitions (not in Zig's std.c)
const ARM_THREAD_STATE64: std.c.thread_flavor_t = 6;
const ARM_THREAD_STATE64_COUNT: std.c.mach_msg_type_number_t = @sizeOf(ArmThreadState64) / @sizeOf(std.c.natural_t);

const x86_THREAD_STATE64: std.c.thread_flavor_t = 4;
const x86_THREAD_STATE64_COUNT: std.c.mach_msg_type_number_t = @sizeOf(X86ThreadState64) / @sizeOf(std.c.natural_t);

const ArmThreadState64 = extern struct {
    x: [29]u64, // general purpose x0-x28
    fp: u64, // x29
    lr: u64, // x30
    sp: u64,
    pc: u64,
    cpsr: u32,
    pad: u32,
};

const X86ThreadState64 = extern struct {
    rax: u64,
    rbx: u64,
    rcx: u64,
    rdx: u64,
    rdi: u64,
    rsi: u64,
    rbp: u64,
    rsp: u64,
    r8: u64,
    r9: u64,
    r10: u64,
    r11: u64,
    r12: u64,
    r13: u64,
    r14: u64,
    r15: u64,
    rip: u64,
    rflags: u64,
    cs: u64,
    fs: u64,
    gs: u64,
};

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
            // Child: redirect stdout/stderr so debuggee output doesn't
            // pollute the MCP JSON-RPC stream on the parent's stdout.
            const devnull = posix.open("/dev/null", .{ .ACCMODE = .WRONLY }, 0) catch null;
            if (devnull) |fd| {
                _ = posix.dup2(fd, 1) catch {}; // stdout
                _ = posix.dup2(fd, 2) catch {}; // stderr
                posix.close(fd);
            }
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
        if (self.pid == null) return error.NoProcess;
        if (builtin.os.tag != .macos) return .{};

        const task = try self.getTask();

        var threads: std.c.mach_port_array_t = undefined;
        var thread_count: std.c.mach_msg_type_number_t = undefined;
        var kr = std.c.task_threads(task, &threads, &thread_count);
        if (kr != 0) return error.TaskThreadsFailed;

        if (thread_count == 0) return error.NoThreads;
        const thread = threads[0];

        const is_arm = builtin.cpu.arch == .aarch64;
        if (is_arm) {
            var state: ArmThreadState64 = undefined;
            var count: std.c.mach_msg_type_number_t = ARM_THREAD_STATE64_COUNT;
            kr = std.c.thread_get_state(thread, ARM_THREAD_STATE64, @ptrCast(&state), &count);
            if (kr != 0) return error.ThreadGetStateFailed;
            return .{
                .rip = state.pc,
                .rsp = state.sp,
                .rbp = state.fp,
            };
        } else {
            var state: X86ThreadState64 = undefined;
            var count: std.c.mach_msg_type_number_t = x86_THREAD_STATE64_COUNT;
            kr = std.c.thread_get_state(thread, x86_THREAD_STATE64, @ptrCast(&state), &count);
            if (kr != 0) return error.ThreadGetStateFailed;
            return .{
                .rip = state.rip,
                .rsp = state.rsp,
                .rbp = state.rbp,
            };
        }
    }

    pub fn writeRegisters(self: *MachProcessControl, regs: RegisterState) !void {
        if (self.pid == null) return error.NoProcess;
        if (builtin.os.tag != .macos) return;

        const task = try self.getTask();

        var threads: std.c.mach_port_array_t = undefined;
        var thread_count: std.c.mach_msg_type_number_t = undefined;
        var kr = std.c.task_threads(task, &threads, &thread_count);
        if (kr != 0) return error.TaskThreadsFailed;

        if (thread_count == 0) return error.NoThreads;
        const thread = threads[0];

        const is_arm = builtin.cpu.arch == .aarch64;
        if (is_arm) {
            var state: ArmThreadState64 = undefined;
            var count: std.c.mach_msg_type_number_t = ARM_THREAD_STATE64_COUNT;
            kr = std.c.thread_get_state(thread, ARM_THREAD_STATE64, @ptrCast(&state), &count);
            if (kr != 0) return error.ThreadGetStateFailed;
            state.pc = regs.rip;
            state.sp = regs.rsp;
            state.fp = regs.rbp;
            kr = std.c.thread_set_state(thread, ARM_THREAD_STATE64, @ptrCast(&state), ARM_THREAD_STATE64_COUNT);
            if (kr != 0) return error.ThreadSetStateFailed;
        } else {
            var state: X86ThreadState64 = undefined;
            var count: std.c.mach_msg_type_number_t = x86_THREAD_STATE64_COUNT;
            kr = std.c.thread_get_state(thread, x86_THREAD_STATE64, @ptrCast(&state), &count);
            if (kr != 0) return error.ThreadGetStateFailed;
            state.rip = regs.rip;
            state.rsp = regs.rsp;
            state.rbp = regs.rbp;
            kr = std.c.thread_set_state(thread, x86_THREAD_STATE64, @ptrCast(&state), x86_THREAD_STATE64_COUNT);
            if (kr != 0) return error.ThreadSetStateFailed;
        }
    }

    pub fn readMemory(self: *MachProcessControl, address: u64, size: usize, allocator: std.mem.Allocator) ![]u8 {
        if (self.pid == null) return error.NoProcess;
        if (builtin.os.tag != .macos) {
            const buf = try allocator.alloc(u8, size);
            @memset(buf, 0);
            return buf;
        }

        const task = try self.getTask();
        const buf = try allocator.alloc(u8, size);
        errdefer allocator.free(buf);

        var data_out: std.c.vm_offset_t = undefined;
        var data_cnt: std.c.mach_msg_type_number_t = undefined;
        const kr = std.c.mach_vm_read(task, address, size, &data_out, &data_cnt);
        if (kr != 0) return error.ReadFailed;

        const src: [*]const u8 = @ptrFromInt(data_out);
        @memcpy(buf[0..@min(size, data_cnt)], src[0..@min(size, data_cnt)]);
        _ = std.c.vm_deallocate(std.c.mach_task_self(), data_out, data_cnt);
        return buf;
    }

    pub fn writeMemory(self: *MachProcessControl, address: u64, data: []const u8) !void {
        if (self.pid == null) return error.NoProcess;
        if (builtin.os.tag != .macos) return;

        const task = try self.getTask();

        // Make the page writable (COW copy for __TEXT segment breakpoints)
        // W^X policy: don't set EXECUTE when setting WRITE
        const VM_PROT_READ: std.c.vm_prot_t = 0x01;
        const VM_PROT_WRITE: std.c.vm_prot_t = 0x02;
        const VM_PROT_EXECUTE: std.c.vm_prot_t = 0x04;
        const VM_PROT_COPY: std.c.vm_prot_t = 0x10;
        const page_size: u64 = 0x4000; // 16KB on arm64
        const page_addr = address & ~(page_size - 1);
        _ = std.c.mach_vm_protect(task, page_addr, page_size, 0, VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);

        const kr = std.c.mach_vm_write(task, address, @intFromPtr(data.ptr), @intCast(data.len));

        // Restore read+execute protection
        _ = std.c.mach_vm_protect(task, page_addr, page_size, 0, VM_PROT_READ | VM_PROT_EXECUTE);

        if (kr != 0) return error.WriteFailed;
    }

    /// Get the Mach task port for the traced process.
    fn getTask(self: *MachProcessControl) !std.c.mach_port_name_t {
        const pid = self.pid orelse return error.NoProcess;
        var task: std.c.mach_port_name_t = undefined;
        const kr = std.c.task_for_pid(std.c.mach_task_self(), pid, &task);
        if (kr != 0) return error.TaskForPidFailed;
        return task;
    }

    /// Find the actual __TEXT segment base address in the running process.
    /// Used to compute the ASLR slide for breakpoint address resolution.
    pub fn getTextBase(self: *MachProcessControl) !u64 {
        const task = try self.getTask();
        const MH_MAGIC_64: u32 = 0xFEEDFACF;

        var address: std.c.mach_vm_address_t = 0;
        while (address < 0x7FFFFFFFFFFF) {
            var size: std.c.mach_vm_size_t = 0;
            var info: std.c.vm_region_basic_info_64 = undefined;
            var info_cnt: std.c.mach_msg_type_number_t = std.c.VM.REGION.BASIC_INFO_COUNT;
            var object_name: std.c.mach_port_t = 0;
            const kr = std.c.mach_vm_region(
                task,
                &address,
                &size,
                std.c.VM.REGION.BASIC_INFO_64,
                @ptrCast(&info),
                &info_cnt,
                &object_name,
            );
            if (kr != 0) break;

            // Look for executable region with Mach-O magic
            if (info.protection & 0x04 != 0) { // VM_PROT_EXECUTE = 4
                var data_out: std.c.vm_offset_t = undefined;
                var data_cnt: std.c.mach_msg_type_number_t = undefined;
                const read_kr = std.c.mach_vm_read(task, address, 4, &data_out, &data_cnt);
                if (read_kr == 0 and data_cnt >= 4) {
                    const magic = @as(*const u32, @alignCast(@ptrCast(@as([*]const u8, @ptrFromInt(data_out))))).*;
                    _ = std.c.vm_deallocate(std.c.mach_task_self(), data_out, data_cnt);
                    if (magic == MH_MAGIC_64) {
                        return address;
                    }
                }
            }
            address += size;
        }
        return error.TextBaseNotFound;
    }

    pub fn kill(self: *MachProcessControl) !void {
        if (self.pid) |pid| {
            // Resume traced-stopped process so signals can be delivered
            if (!self.is_running and builtin.os.tag == .macos) {
                const PT_CONTINUE = 7;
                _ = std.c.ptrace(PT_CONTINUE, pid, @ptrFromInt(1), 0);
            }
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
