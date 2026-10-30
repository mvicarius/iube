//! iube command dispatch.
//!
//! Every command builds only the view it needs and then calls the shared
//! session loop. In particular:
//!
//!   iube          -> control panel (no .desktop scan)
//!   iube launch   -> launcher (no control panel setup)
//!   iube <tool>   -> tool view

const std = @import("std");
const cli = @import("cli.zig");
const config = @import("config.zig");
const session = @import("session.zig");
const launcher = @import("launcher.zig");
const panel = @import("panel.zig");
const placeholder = @import("placeholder.zig");
const audio_view = @import("audio_view.zig");
const bluetooth_view = @import("bluetooth_view.zig");
const wifi_view = @import("wifi_view.zig");
const power_view = @import("power_view.zig");
const tools = @import("tools.zig");

pub const std_options: std.Options = .{ .log_level = .warn };

const usage =
    \\iube - a small, dependency-light control panel for the Linux desktop
    \\
    \\Usage:
    \\  iube             open the iube control panel
    \\  iube launch      open the application launcher
    \\  iube audio       open the audio manager
    \\  iube bluetooth   open the Bluetooth controller
    \\  iube wifi        open the Wi-Fi manager
    \\  iube power       open the power manager
    \\  iube <tool> <action> [args]
    \\                   run a non-UI action (see docs/cli.md)
    \\  iube help        show this help
    \\  iube version     show the version
    \\
    \\All commands share the same config, theme, renderer and window behaviour.
    \\
;

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    // Action paths never construct a view: they exit before config, theme or
    // Wayland setup. `iube <tool>` with no action still opens the UI below.
    if (args.len > 2 and cli.isTool(args[1])) {
        const code = cli.run(init, args);
        if (code != 0) std.process.exit(code);
        return;
    }

    const env = config.Env{
        .home = init.environ_map.get("HOME"),
        .xdg_config_home = init.environ_map.get("XDG_CONFIG_HOME"),
    };

    if (args.len <= 1) {
        return runPanel(init, env);
    }

    const command = args[1];
    if (std.mem.eql(u8, command, "launch")) {
        return runLauncher(init, env);
    }
    if (std.mem.eql(u8, command, "panel")) {
        return runPanel(init, env);
    }
    if (std.mem.eql(u8, command, "audio")) {
        return runAudio(init, env);
    }
    if (std.mem.eql(u8, command, "bluetooth")) {
        return runBluetooth(init, env);
    }
    if (std.mem.eql(u8, command, "wifi")) {
        return runWifi(init, env);
    }
    if (std.mem.eql(u8, command, "power")) {
        return runPower(init, env);
    }
    if (std.mem.eql(u8, command, "help") or
        std.mem.eql(u8, command, "--help") or
        std.mem.eql(u8, command, "-h"))
    {
        printStdout(init.io, usage);
        return;
    }
    if (std.mem.eql(u8, command, "version") or
        std.mem.eql(u8, command, "--version") or
        std.mem.eql(u8, command, "-V"))
    {
        printStdout(init.io, "iube 0.1.0\n");
        return;
    }

    if (tools.find(command)) |tool| {
        return runPlaceholder(init, env, tool);
    }

    std.debug.print("iube: unknown command '{s}'\n\n{s}", .{ command, usage });
    std.process.exit(2);
}

fn runLauncher(init: std.process.Init, env: config.Env) !void {
    var view = try launcher.Launcher.init(
        init.io,
        init.gpa,
        .{
            .home = init.environ_map.get("HOME"),
            .xdg_data_home = init.environ_map.get("XDG_DATA_HOME"),
            .xdg_data_dirs = init.environ_map.get("XDG_DATA_DIRS"),
        },
        init.environ_map.get("TERMINAL"),
    );
    defer view.deinit();

    try session.run(init.io, init.gpa, env, &view);
}

fn runPanel(init: std.process.Init, env: config.Env) !void {
    var view = panel.Panel.init(init.gpa);
    defer view.deinit();
    try session.run(init.io, init.gpa, env, &view);
}

fn runPlaceholder(init: std.process.Init, env: config.Env, tool: *const tools.Tool) !void {
    var view = placeholder.Placeholder{ .tool = tool };
    try session.run(init.io, init.gpa, env, &view);
}

fn runAudio(init: std.process.Init, env: config.Env) !void {
    var view = audio_view.Audio.init(init.io, init.gpa, .{
        .xdg_runtime_dir = init.environ_map.get("XDG_RUNTIME_DIR"),
        .home = init.environ_map.get("HOME"),
        .xdg_config_home = init.environ_map.get("XDG_CONFIG_HOME"),
    });
    defer view.deinit();

    try session.run(init.io, init.gpa, env, &view);
}

fn runBluetooth(init: std.process.Init, env: config.Env) !void {
    var view = bluetooth_view.Bluetooth.init(init.io, init.gpa);
    defer view.deinit();

    try session.run(init.io, init.gpa, env, &view);
}

fn runWifi(init: std.process.Init, env: config.Env) !void {
    var view = wifi_view.Wifi.init(init.io, init.gpa);
    defer view.deinit();

    try session.run(init.io, init.gpa, env, &view);
}

fn runPower(init: std.process.Init, env: config.Env) !void {
    var view = power_view.Power.init(init.io, init.gpa);
    defer view.deinit();

    try session.run(init.io, init.gpa, env, &view);
}

fn printStdout(io: std.Io, text: []const u8) void {
    std.Io.File.stdout().writeStreamingAll(io, text) catch {};
}
