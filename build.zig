const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const dvui = b.dependency("dvui", .{
        .target = target,
        .optimize = optimize,
        .backend = .sdl3,
    });

    const exe = b.addExecutable(.{
        .name = "iube",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "dvui", .module = dvui.module("dvui_sdl3") },
                .{ .name = "sdl-backend", .module = dvui.module("sdl3") },
            },
        }),
    });

    // The dev shell supplies libraries via NIX_LDFLAGS/LD_LIBRARY_PATH. Bake
    // those paths into RUNPATH so the built binary also runs outside
    // `nix develop` (e.g. from a Hyprland keybind).
    if (b.graph.environ_map.get("NIX_LDFLAGS")) |ldflags| {
        var it = std.mem.tokenizeAny(u8, ldflags, " \t\n");
        while (it.next()) |flag| {
            if (!std.mem.startsWith(u8, flag, "-L")) continue;
            const dir = flag[2..];
            if (dir.len > 0) exe.root_module.addRPath(b.graph.cwdRelativePath(dir));
        }
    }
    if (b.graph.environ_map.get("LD_LIBRARY_PATH")) |library_path| {
        var it = std.mem.tokenizeScalar(u8, library_path, ':');
        while (it.next()) |dir| {
            if (dir.len > 0) exe.root_module.addRPath(b.graph.cwdRelativePath(dir));
        }
    }

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}
