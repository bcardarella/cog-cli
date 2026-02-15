const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Root module (library)
    const mod = b.addModule("cog", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .link_libc = true,
    });
    addTreeSitter(b, mod);

    // Executable
    const exe = b.addExecutable(.{
        .name = "cog",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "cog", .module = mod },
            },
        }),
    });

    b.installArtifact(exe);

    // Run step
    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // Tests
    const mod_tests = b.addTest(.{
        .root_module = mod,
    });
    const run_mod_tests = b.addRunArtifact(mod_tests);

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });
    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);

    // Release step
    const release_step = b.step("release", "Build release tarballs");
    addRelease(b, release_step, .aarch64, .macos, "darwin-arm64");
    addRelease(b, release_step, .x86_64, .macos, "darwin-x86_64");
    addRelease(b, release_step, .aarch64, .linux, "linux-arm64");
    addRelease(b, release_step, .x86_64, .linux, "linux-x86_64");
}

/// Add tree-sitter core and all grammar C source files to a module.
fn addTreeSitter(b: *std.Build, mod: *std.Build.Module) void {
    const ts_include = b.path("grammars/tree-sitter/include");
    const ts_src = b.path("grammars/tree-sitter/src");

    // Include paths
    mod.addIncludePath(ts_include);
    mod.addIncludePath(ts_src);
    mod.addIncludePath(b.path("grammars/go"));
    mod.addIncludePath(b.path("grammars/java"));
    mod.addIncludePath(b.path("grammars/c"));
    mod.addIncludePath(b.path("grammars/typescript"));
    mod.addIncludePath(b.path("grammars/tsx"));
    mod.addIncludePath(b.path("grammars/javascript"));
    mod.addIncludePath(b.path("grammars/python"));
    mod.addIncludePath(b.path("grammars/rust"));
    mod.addIncludePath(b.path("grammars/cpp"));

    const c_flags = &[_][]const u8{ "-std=c11", "-fno-exceptions" };

    // Tree-sitter core (unity build via lib.c)
    mod.addCSourceFile(.{
        .file = b.path("grammars/tree-sitter/src/lib.c"),
        .flags = c_flags,
    });

    // Grammar parsers (parser-only: Go, Java, C)
    mod.addCSourceFile(.{ .file = b.path("grammars/go/parser.c"), .flags = c_flags });
    mod.addCSourceFile(.{ .file = b.path("grammars/java/parser.c"), .flags = c_flags });
    mod.addCSourceFile(.{ .file = b.path("grammars/c/parser.c"), .flags = c_flags });

    // Grammar parsers + scanners: TypeScript, TSX, JavaScript, Python, Rust, C++
    mod.addCSourceFile(.{ .file = b.path("grammars/typescript/parser.c"), .flags = c_flags });
    mod.addCSourceFile(.{ .file = b.path("grammars/typescript/scanner.c"), .flags = c_flags });
    mod.addCSourceFile(.{ .file = b.path("grammars/tsx/parser.c"), .flags = c_flags });
    mod.addCSourceFile(.{ .file = b.path("grammars/tsx/scanner.c"), .flags = c_flags });
    mod.addCSourceFile(.{ .file = b.path("grammars/javascript/parser.c"), .flags = c_flags });
    mod.addCSourceFile(.{ .file = b.path("grammars/javascript/scanner.c"), .flags = c_flags });
    mod.addCSourceFile(.{ .file = b.path("grammars/python/parser.c"), .flags = c_flags });
    mod.addCSourceFile(.{ .file = b.path("grammars/python/scanner.c"), .flags = c_flags });
    mod.addCSourceFile(.{ .file = b.path("grammars/rust/parser.c"), .flags = c_flags });
    mod.addCSourceFile(.{ .file = b.path("grammars/rust/scanner.c"), .flags = c_flags });
    mod.addCSourceFile(.{ .file = b.path("grammars/cpp/parser.c"), .flags = c_flags });
    mod.addCSourceFile(.{ .file = b.path("grammars/cpp/scanner.c"), .flags = c_flags });
}

fn addRelease(
    b: *std.Build,
    release_step: *std.Build.Step,
    cpu_arch: std.Target.Cpu.Arch,
    os_tag: std.Target.Os.Tag,
    name: []const u8,
) void {
    const release_target = b.resolveTargetQuery(.{
        .cpu_arch = cpu_arch,
        .os_tag = os_tag,
    });

    const release_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = release_target,
        .link_libc = true,
    });
    addTreeSitter(b, release_mod);

    const release_exe = b.addExecutable(.{
        .name = "cog",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = release_target,
            .optimize = .ReleaseSafe,
            .imports = &.{
                .{ .name = "cog", .module = release_mod },
            },
        }),
    });

    const tar = b.addSystemCommand(&.{ "tar", "-czf" });
    const output = tar.addOutputFileArg(b.fmt("cog-{s}.tar.gz", .{name}));
    tar.addArgs(&.{"-C"});
    tar.addDirectoryArg(release_exe.getEmittedBin().dirname());
    tar.addArg("cog");

    const install_tar = b.addInstallFileWithDir(
        output,
        .{ .custom = "release" },
        b.fmt("cog-{s}.tar.gz", .{name}),
    );
    release_step.dependOn(&install_tar.step);
}
