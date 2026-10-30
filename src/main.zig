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
const bluetooth_view = @import("bluetooth_view.zig");
const wifi_view = @import("wifi_view.zig");
const wifi = @import("wifi.zig");
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
    \\  iube wifi connect <ssid>
    \\                   connect to a network, reading the password from stdin
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
        return runBluetooth(init, env);
    }
    if (std.mem.eql(u8, command, "wifi")) {
        if (args.len >= 3 and std.mem.eql(u8, args[2], "connect")) {
            return runWifiConnect(init, args[3..]);
        }
        if (args.len >= 3) {
            std.debug.print("iube: unknown wifi command '{s}'\n\n{s}", .{ args[2], usage });
            std.process.exit(2);
        }
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

fn runWifiConnect(init: std.process.Init, args: []const []const u8) !void {
    var ssid: ?[]const u8 = null;
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--password-stdin")) continue;
        if (std.mem.startsWith(u8, arg, "-")) {
            std.debug.print("iube: unknown option '{s}'\n", .{arg});
            std.process.exit(2);
        }
        if (ssid != null) {
            std.debug.print("iube: expected exactly one SSID\n", .{});
            std.process.exit(2);
        }
        ssid = arg;
    }

    const wanted = ssid orelse {
        std.debug.print("iube: wifi connect requires an SSID\n", .{});
        std.process.exit(2);
    };

    var client = wifi.Client.connect(init.io, init.gpa) catch |err| {
        std.debug.print("iube: cannot reach NetworkManager: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    defer client.deinit();

    var state = client.refresh(init.gpa) catch |err| {
        std.debug.print("iube: cannot load Wi-Fi state: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    defer state.deinit();

    var network: ?wifi.Network = null;
    for (state.networks) |candidate| {
        if (std.mem.eql(u8, candidate.ssid, wanted)) {
            network = candidate;
            break;
        }
    }
    const target = network orelse {
        std.debug.print(
            "iube: network '{s}' is not visible; run 'iube wifi' to scan\n",
            .{wanted},
        );
        std.process.exit(1);
    };
    const device = state.device orelse {
        std.debug.print("iube: no Wi-Fi device managed by NetworkManager\n", .{});
        std.process.exit(1);
    };

    if (target.connected) {
        printStdout(init.io, "Already connected.\n");
        return;
    }

    if (state.findSaved(target.ssid)) |saved| {
        client.activateSaved(device, target, saved) catch |err| {
            std.debug.print("iube: cannot activate saved profile: {s}\n", .{@errorName(err)});
            std.process.exit(1);
        };
    } else {
        var password_buffer: [256]u8 = undefined;
        var password: []const u8 = "";
        if (target.secured) {
            printStderr(init.io, "Password: ");
            password = readPassword(init.io, &password_buffer) catch |err| {
                std.debug.print("\niube: cannot read password: {s}\n", .{@errorName(err)});
                std.process.exit(1);
            };
            printStderr(init.io, "\n");
            if (password.len == 0) {
                std.debug.print("iube: password cannot be empty\n", .{});
                std.process.exit(1);
            }
        }

        const connect_result = client.addAndActivate(device, target, password);
        @memset(password_buffer[0..], 0);
        connect_result catch |err| {
            std.debug.print("iube: connection failed: {s}\n", .{@errorName(err)});
            std.process.exit(1);
        };
    }

    printStdout(init.io, "Connecting...\n");
    if (!waitForActivation(init.io, init.gpa, &client, target.ap_path)) {
        std.debug.print("iube: connection failed or timed out\n", .{});
        std.process.exit(1);
    }
    printStdout(init.io, "Connected.\n");
}

fn waitForActivation(
    io: std.Io,
    gpa: std.mem.Allocator,
    client: *wifi.Client,
    ap_path: []const u8,
) bool {
    var waited_ms: u32 = 0;
    // NM_DEVICE_STATE_ACTIVATED is 100 and NM_DEVICE_STATE_FAILED is 120.
    while (waited_ms < 10_000) : (waited_ms += 500) {
        std.Io.sleep(io, .fromMilliseconds(500), .awake) catch {};

        var state = client.refresh(gpa) catch continue;
        defer state.deinit();
        const device = state.device orelse continue;
        if (device.state == 120) return false;
        if (device.state == 100) return std.mem.eql(u8, device.active_ap, ap_path);
    }
    return false;
}

/// Read one line from stdin, disabling terminal echo when stdin is a TTY.
/// No password is ever placed in argv, and the caller wipes the buffer.
fn readPassword(io: std.Io, buffer: []u8) ![]const u8 {
    const fd = std.posix.STDIN_FILENO;
    const original = std.posix.tcgetattr(fd) catch null;
    if (original) |term| {
        var hidden = term;
        hidden.lflag.ECHO = false;
        std.posix.tcsetattr(fd, .NOW, hidden) catch {};
        defer std.posix.tcsetattr(fd, .NOW, term) catch {};
        return readLine(io, buffer);
    }
    return readLine(io, buffer);
}

fn readLine(io: std.Io, buffer: []u8) ![]const u8 {
    const file = std.Io.File.stdin();
    var len: usize = 0;
    while (len < buffer.len) {
        const count = file.readStreaming(io, &.{buffer[len..]}) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        if (count == 0) break;
        if (std.mem.indexOfScalar(u8, buffer[len .. len + count], '\n')) |newline| {
            len += newline;
            break;
        }
        len += count;
    }
    if (len > 0 and buffer[len - 1] == '\r') len -= 1;
    return buffer[0..len];
}

fn printStdout(io: std.Io, text: []const u8) void {
    std.Io.File.stdout().writeStreamingAll(io, text) catch {};
}

fn printStderr(io: std.Io, text: []const u8) void {
    std.Io.File.stderr().writeStreamingAll(io, text) catch {};
}
