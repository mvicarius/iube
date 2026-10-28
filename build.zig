const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "iube",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    // Generated Wayland protocol bindings (xdg-shell, wlr-layer-shell and
    // cursor-shape) live in the tree so the build does not need
    // wayland-scanner or wayland-protocols.
    exe.root_module.addIncludePath(b.path("src/protocol"));
    exe.root_module.addCSourceFiles(.{
        .files = &.{
            "src/protocol/xdg-shell-protocol.c",
            "src/protocol/layer-shell-protocol.c",
            "src/protocol/cursor-shape-protocol.c",
        },
        .flags = &.{},
    });

    exe.root_module.linkSystemLibrary("wayland-client", .{});
    exe.root_module.linkSystemLibrary("xkbcommon", .{});

    const translated = b.addTranslateC(.{
        .root_source_file = b.path("src/protocol/c.h"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    translated.addIncludePath(b.path("src/protocol"));
    translated.linkSystemLibrary("wayland-client", .{});
    translated.linkSystemLibrary("xkbcommon", .{});
    exe.root_module.addImport("c", translated.createModule());

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
}
