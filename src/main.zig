//! iube command dispatch.
//!
//! Every command builds only the view it needs and then calls the shared
//! session loop. In particular:
//!
//!   iube          -> control panel (no .desktop scan)
//!   iube launch   -> launcher (no control panel setup)
//!   iube <tool>   -> tool view

const std = @import("std");
const config = @import("config.zig");
const session = @import("session.zig");
const launcher = @import("launcher.zig");
const panel = @import("panel.zig");
const placeholder = @import("placeholder.zig");
const audio_view = @import("audio_view.zig");
const bluetooth = @import("bluetooth.zig");
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
    \\  iube bluetooth pair <name|address>    pair a device
    \\  iube bluetooth forget <name|address>  forget a device
    \\  iube wifi        open the Wi-Fi manager
    \\  iube power       open the power manager
    \\  iube help        show this help
    \\  iube version     show the version
    \\
    \\All commands share the same config, theme, renderer and window behaviour.
    \\
;

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
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
        if (args.len > 2) return runBluetoothCli(init, args[2..]);
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

fn runBluetoothCli(init: std.process.Init, args: []const []const u8) !void {
    const command = bluetooth.parseCliCommand(args) catch |err| {
        switch (err) {
            error.MissingDevice => printStderr(init.io, "iube: this command needs a device name or address\n\n"),
            error.TooManyArguments => printStderr(init.io, "iube: too many arguments; quote device names that contain spaces\n\n"),
            error.UnknownCommand => printStderr(init.io, "iube: unknown bluetooth command\n\n"),
        }
        printStderr(init.io, bluetooth_usage);
        std.process.exit(2);
    };

    switch (command) {
        .help => printStdout(init.io, bluetooth_usage),
        .pair => |target| try pairBluetoothDevice(init, target),
        .forget => |target| try forgetBluetoothDevice(init, target),
    }
}

fn pairBluetoothDevice(init: std.process.Init, target: []const u8) !void {
    var client = bluetooth.Client.connect(init.io, init.gpa) catch |err| {
        printMessage(init.io, .stderr, "iube: cannot connect to the system D-Bus: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    defer client.deinit();

    var state = client.refresh(init.gpa) catch |err| {
        printMessage(init.io, .stderr, "iube: cannot read the BlueZ device tree: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    defer state.deinit();

    const device = resolveOrExit(init, state, target);
    if (state.adapter()) |adapter| {
        if (!adapter.powered) {
            printStderr(init.io, "iube: the Bluetooth adapter is off; turn it on in `iube bluetooth` first\n");
            std.process.exit(1);
        }
    }

    const outcome = client.pair(device.path) catch |err| {
        switch (err) {
            error.MethodFailed => printStderr(init.io, "iube: could not register the pairing agent (is bluetoothd running?)\n"),
            error.PasskeyRequired => printMessage(
                init.io,
                .stderr,
                "iube: \"{s}\" requires a passkey or PIN. This agent only supports just-works pairing.\n",
                .{device.label()},
            ),
            error.PairRejected => printMessage(
                init.io,
                .stderr,
                "iube: pairing with \"{s}\" was rejected. Check that the device is in pairing mode.\n",
                .{device.label()},
            ),
            error.PairTimedOut => printMessage(
                init.io,
                .stderr,
                "iube: pairing with \"{s}\" timed out.\n",
                .{device.label()},
            ),
            error.PairCancelled => printMessage(
                init.io,
                .stderr,
                "iube: pairing with \"{s}\" was cancelled.\n",
                .{device.label()},
            ),
            error.DeviceNotAvailable => printMessage(
                init.io,
                .stderr,
                "iube: \"{s}\" is not available. Put it in pairing mode and try again.\n",
                .{device.label()},
            ),
            error.AdapterNotReady => printStderr(init.io, "iube: the Bluetooth adapter is not ready\n"),
            error.PairInProgress => printMessage(
                init.io,
                .stderr,
                "iube: another pairing attempt with \"{s}\" is already in progress.\n",
                .{device.label()},
            ),
            error.PairFailed => printMessage(
                init.io,
                .stderr,
                "iube: pairing with \"{s}\" failed.\n",
                .{device.label()},
            ),
            else => printMessage(
                init.io,
                .stderr,
                "iube: pairing with \"{s}\" failed: {s}\n",
                .{ device.label(), @errorName(err) },
            ),
        }
        std.process.exit(1);
    };

    switch (outcome) {
        .paired => printMessage(init.io, .stdout, "Paired \"{s}\" ({s}).\n", .{ device.label(), device.address }),
        .already_paired => printMessage(init.io, .stdout, "\"{s}\" ({s}) is already paired.\n", .{ device.label(), device.address }),
    }
}

fn forgetBluetoothDevice(init: std.process.Init, target: []const u8) !void {
    var client = bluetooth.Client.connect(init.io, init.gpa) catch |err| {
        printMessage(init.io, .stderr, "iube: cannot connect to the system D-Bus: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    defer client.deinit();

    var state = client.refresh(init.gpa) catch |err| {
        printMessage(init.io, .stderr, "iube: cannot read the BlueZ device tree: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    defer state.deinit();

    const device = resolveOrExit(init, state, target);
    client.removeDevice(device) catch |err| {
        printMessage(
            init.io,
            .stderr,
            "iube: could not forget \"{s}\": {s}\n",
            .{ device.label(), @errorName(err) },
        );
        std.process.exit(1);
    };

    printMessage(init.io, .stdout, "Forgot \"{s}\" ({s}).\n", .{ device.label(), device.address });
}

fn resolveOrExit(init: std.process.Init, state: bluetooth.State, target: []const u8) bluetooth.Device {
    return switch (bluetooth.resolveDevice(state.devices, target)) {
        .found => |index| state.devices[index],
        .ambiguous => {
            printMessage(
                init.io,
                .stderr,
                "iube: several Bluetooth devices match \"{s}\"; use the address instead.\n",
                .{target},
            );
            std.process.exit(1);
        },
        .not_found => {
            printMessage(
                init.io,
                .stderr,
                "iube: no Bluetooth device matches \"{s}\". Run `iube bluetooth` and press D to discover it.\n",
                .{target},
            );
            std.process.exit(1);
        },
    };
}

const Output = enum { stdout, stderr };

fn printMessage(io: std.Io, output: Output, comptime format: []const u8, args: anytype) void {
    var buffer: [1024]u8 = undefined;
    const text = std.fmt.bufPrint(&buffer, format, args) catch {
        switch (output) {
            .stdout => printStdout(io, "iube: message too long\n"),
            .stderr => printStderr(io, "iube: message too long\n"),
        }
        return;
    };
    switch (output) {
        .stdout => printStdout(io, text),
        .stderr => printStderr(io, text),
    }
}

const bluetooth_usage =
    \\Usage:
    \\  iube bluetooth                        open the Bluetooth controller
    \\  iube bluetooth pair <name|address>    pair a device
    \\  iube bluetooth forget <name|address>  forget a device
    \\
    \\The pairing agent only supports just-works pairing. Devices that require a
    \\passkey or PIN cannot be paired yet.
    \\
;

fn printStdout(io: std.Io, text: []const u8) void {
    std.Io.File.stdout().writeStreamingAll(io, text) catch {};
}

fn printStderr(io: std.Io, text: []const u8) void {
    std.Io.File.stderr().writeStreamingAll(io, text) catch {};
}
