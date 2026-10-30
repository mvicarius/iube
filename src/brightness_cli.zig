//! Command-line actions for the brightness controller.
//!
//! These commands deliberately bypass Wayland: they read sysfs and call logind,
//! print one line and exit. Keeping them in their own module makes it easy to
//! move them behind a shared CLI dispatcher later without changing the
//! backend.

const std = @import("std");
const brightness = @import("brightness.zig");

pub const usage =
    \\Usage:
    \\  iube brightness               open the brightness controller
    \\  iube brightness up [percent]  raise brightness (default 5%)
    \\  iube brightness down [percent] lower brightness (default 5%)
    \\  iube brightness set <percent> set brightness (0-100)
    \\  iube brightness get           print the current brightness
    \\  iube brightness list          list backlight devices
    \\
;

pub fn run(init: std.process.Init, args: []const []const u8) void {
    runInner(init, args) catch |err| {
        printStderr(init.io, "iube brightness: ");
        printStderr(init.io, brightness.describe(err));
        printStderr(init.io, "\n");
        std.process.exit(1);
    };
}

fn runInner(init: std.process.Init, args: []const []const u8) !void {
    if (args.len < 3) usageError(init.io);
    const action = args[2];

    if (std.mem.eql(u8, action, "list")) {
        if (args.len != 3) usageError(init.io);
        var state = try brightness.read(init.io, init.gpa);
        defer state.deinit();

        var buffer: [160]u8 = undefined;
        for (state.devices) |device| {
            printStdout(init.io, device.listLine(&buffer));
            printStdout(init.io, "\n");
        }
        return;
    }

    if (std.mem.eql(u8, action, "get")) {
        if (args.len != 3) usageError(init.io);
        var state = try brightness.read(init.io, init.gpa);
        defer state.deinit();

        const device = state.selected() orelse return error.NoBacklight;
        var buffer: [96]u8 = undefined;
        const line = std.fmt.bufPrint(
            &buffer,
            "{s}: {d}%\n",
            .{ device.name, device.percent() },
        ) catch return error.NoBacklight;
        printStdout(init.io, line);
        return;
    }

    var target: u8 = 0;
    if (std.mem.eql(u8, action, "set")) {
        if (args.len != 4) usageError(init.io);
        target = try brightness.parsePercent(args[3]);
    } else if (std.mem.eql(u8, action, "up") or std.mem.eql(u8, action, "down")) {
        if (args.len > 4) usageError(init.io);
        const amount: u8 = if (args.len == 4)
            try brightness.parsePercent(args[3])
        else
            5;
        const direction: i32 = if (std.mem.eql(u8, action, "up")) 1 else -1;

        var state = try brightness.read(init.io, init.gpa);
        defer state.deinit();
        const device = state.selected() orelse return error.NoBacklight;
        target = brightness.clampPercent(
            @as(i32, device.percent()) + direction * @as(i32, amount),
        );
        return setAndPrint(init, device, target);
    } else {
        usageError(init.io);
    }

    var state = try brightness.read(init.io, init.gpa);
    defer state.deinit();
    const device = state.selected() orelse return error.NoBacklight;
    return setAndPrint(init, device, target);
}

fn setAndPrint(init: std.process.Init, device: brightness.Device, target: u8) !void {
    const value = brightness.rawForPercent(target, device.max_brightness);

    var client = try brightness.Client.connect(init.io, init.gpa);
    defer client.deinit();
    try client.setBrightness(device.name, value);

    var buffer: [96]u8 = undefined;
    const line = std.fmt.bufPrint(
        &buffer,
        "{s}: {d}%\n",
        .{ device.name, target },
    ) catch return error.SetFailed;
    printStdout(init.io, line);
}

fn usageError(io: std.Io) noreturn {
    printStderr(io, usage);
    std.process.exit(2);
}

fn printStdout(io: std.Io, text: []const u8) void {
    std.Io.File.stdout().writeStreamingAll(io, text) catch {};
}

fn printStderr(io: std.Io, text: []const u8) void {
    std.Io.File.stderr().writeStreamingAll(io, text) catch {};
}
