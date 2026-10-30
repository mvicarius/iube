//! Non-UI actions for keybinds and status bars.
//!
//! `iube <tool>` still opens the tool's layer-shell view. When an action is
//! present, this module runs it through the same backend clients and returns
//! before `main.zig` touches Wayland, the config or the theme.
//!
//! The grammar is deliberately small and stable:
//!
//!   iube audio volume-up [percent]
//!   iube audio volume-down [percent]
//!   iube audio mute
//!   iube audio mic-mute
//!   iube audio default <name>
//!   iube bluetooth power on|off|toggle
//!   ...

const std = @import("std");
const audio = @import("audio.zig");
const bluetooth = @import("bluetooth.zig");
const wifi = @import("wifi.zig");
const power = @import("power.zig");

const default_volume_step = 5;
const wifi_scan_wait_ms = 1500;

pub const OnOff = enum {
    on,
    off,
    toggle,

    fn value(self: OnOff, current: bool) bool {
        return switch (self) {
            .on => true,
            .off => false,
            .toggle => !current,
        };
    }
};

pub const Profile = enum {
    low_power,
    balanced,
    performance,

    fn name(self: Profile) []const u8 {
        return switch (self) {
            .low_power => "low-power",
            .balanced => "balanced",
            .performance => "performance",
        };
    }

    fn parse(text: []const u8) ?Profile {
        if (std.mem.eql(u8, text, "low-power")) return .low_power;
        if (std.mem.eql(u8, text, "balanced")) return .balanced;
        if (std.mem.eql(u8, text, "performance")) return .performance;
        return null;
    }
};

pub const Action = union(enum) {
    audio_volume_up: u8,
    audio_volume_down: u8,
    audio_mute,
    audio_mic_mute,
    audio_default: []const u8,
    bluetooth_power: OnOff,
    bluetooth_discover: OnOff,
    bluetooth_connect: []const u8,
    bluetooth_disconnect: []const u8,
    bluetooth_list,
    wifi_power: OnOff,
    wifi_scan,
    wifi_list,
    wifi_connect: []const u8,
    wifi_disconnect,
    power_action: power.Action,
    power_profile_next,
    power_profile_set: Profile,
    power_battery,
};

pub const ParseError = error{
    UnknownCommand,
    UnknownAction,
    MissingArgument,
    InvalidArgument,
    TooManyArguments,
};

/// Commands that have both a UI view and a non-UI action grammar.
pub fn isTool(name: []const u8) bool {
    return std.mem.eql(u8, name, "audio") or
        std.mem.eql(u8, name, "bluetooth") or
        std.mem.eql(u8, name, "wifi") or
        std.mem.eql(u8, name, "power");
}

/// Parse a tool name and the arguments after it. The returned slices point
/// into `rest`, which stays alive for the duration of the process.
pub fn parse(command: []const u8, rest: []const []const u8) ParseError!Action {
    if (std.mem.eql(u8, command, "audio")) return parseAudio(rest);
    if (std.mem.eql(u8, command, "bluetooth")) return parseBluetooth(rest);
    if (std.mem.eql(u8, command, "wifi")) return parseWifi(rest);
    if (std.mem.eql(u8, command, "power")) return parsePower(rest);
    return error.UnknownCommand;
}

fn parseAudio(rest: []const []const u8) ParseError!Action {
    if (rest.len == 0) return error.MissingArgument;
    const action = rest[0];

    if (std.mem.eql(u8, action, "volume-up") or std.mem.eql(u8, action, "volume-down")) {
        if (rest.len > 2) return error.TooManyArguments;
        const percent = if (rest.len == 2) try parsePercent(rest[1]) else default_volume_step;
        return if (std.mem.eql(u8, action, "volume-up"))
            .{ .audio_volume_up = percent }
        else
            .{ .audio_volume_down = percent };
    }
    if (std.mem.eql(u8, action, "mute")) {
        if (rest.len > 1) return error.TooManyArguments;
        return .audio_mute;
    }
    if (std.mem.eql(u8, action, "mic-mute")) {
        if (rest.len > 1) return error.TooManyArguments;
        return .audio_mic_mute;
    }
    if (std.mem.eql(u8, action, "default")) {
        if (rest.len < 2) return error.MissingArgument;
        if (rest.len > 2) return error.TooManyArguments;
        return .{ .audio_default = rest[1] };
    }
    return error.UnknownAction;
}

fn parseBluetooth(rest: []const []const u8) ParseError!Action {
    if (rest.len == 0) return error.MissingArgument;
    const action = rest[0];

    if (std.mem.eql(u8, action, "power")) {
        if (rest.len < 2) return error.MissingArgument;
        if (rest.len > 2) return error.TooManyArguments;
        return .{ .bluetooth_power = try parseOnOff(rest[1]) };
    }
    if (std.mem.eql(u8, action, "discover")) {
        if (rest.len < 2) return error.MissingArgument;
        if (rest.len > 2) return error.TooManyArguments;
        const value = try parseOnOff(rest[1]);
        if (value == .toggle) return error.InvalidArgument;
        return .{ .bluetooth_discover = value };
    }
    if (std.mem.eql(u8, action, "connect") or std.mem.eql(u8, action, "disconnect")) {
        if (rest.len < 2) return error.MissingArgument;
        if (rest.len > 2) return error.TooManyArguments;
        return if (std.mem.eql(u8, action, "connect"))
            .{ .bluetooth_connect = rest[1] }
        else
            .{ .bluetooth_disconnect = rest[1] };
    }
    if (std.mem.eql(u8, action, "list")) {
        if (rest.len > 1) return error.TooManyArguments;
        return .bluetooth_list;
    }
    return error.UnknownAction;
}

fn parseWifi(rest: []const []const u8) ParseError!Action {
    if (rest.len == 0) return error.MissingArgument;
    const action = rest[0];

    if (std.mem.eql(u8, action, "on") or
        std.mem.eql(u8, action, "off") or
        std.mem.eql(u8, action, "toggle"))
    {
        if (rest.len > 1) return error.TooManyArguments;
        return .{ .wifi_power = try parseOnOff(action) };
    }
    if (std.mem.eql(u8, action, "scan")) {
        if (rest.len > 1) return error.TooManyArguments;
        return .wifi_scan;
    }
    if (std.mem.eql(u8, action, "list")) {
        if (rest.len > 1) return error.TooManyArguments;
        return .wifi_list;
    }
    if (std.mem.eql(u8, action, "connect")) {
        if (rest.len < 2) return error.MissingArgument;
        if (rest.len > 2) return error.TooManyArguments;
        return .{ .wifi_connect = rest[1] };
    }
    if (std.mem.eql(u8, action, "disconnect")) {
        if (rest.len > 1) return error.TooManyArguments;
        return .wifi_disconnect;
    }
    return error.UnknownAction;
}

fn parsePower(rest: []const []const u8) ParseError!Action {
    if (rest.len == 0) return error.MissingArgument;
    const action = rest[0];

    if (std.mem.eql(u8, action, "suspend")) {
        if (rest.len > 1) return error.TooManyArguments;
        return .{ .power_action = .suspend_system };
    }
    if (std.mem.eql(u8, action, "hibernate")) {
        if (rest.len > 1) return error.TooManyArguments;
        return .{ .power_action = .hibernate };
    }
    if (std.mem.eql(u8, action, "reboot")) {
        if (rest.len > 1) return error.TooManyArguments;
        return .{ .power_action = .reboot };
    }
    if (std.mem.eql(u8, action, "poweroff")) {
        if (rest.len > 1) return error.TooManyArguments;
        return .{ .power_action = .power_off };
    }
    if (std.mem.eql(u8, action, "lock")) {
        if (rest.len > 1) return error.TooManyArguments;
        return .{ .power_action = .lock };
    }
    if (std.mem.eql(u8, action, "battery")) {
        if (rest.len > 1) return error.TooManyArguments;
        return .power_battery;
    }
    if (std.mem.eql(u8, action, "profile")) {
        if (rest.len < 2) return error.MissingArgument;
        if (std.mem.eql(u8, rest[1], "next")) {
            if (rest.len > 2) return error.TooManyArguments;
            return .power_profile_next;
        }
        if (std.mem.eql(u8, rest[1], "set")) {
            if (rest.len < 3) return error.MissingArgument;
            if (rest.len > 3) return error.TooManyArguments;
            const profile = Profile.parse(rest[2]) orelse return error.InvalidArgument;
            return .{ .power_profile_set = profile };
        }
        return error.UnknownAction;
    }
    return error.UnknownAction;
}

fn parsePercent(text: []const u8) ParseError!u8 {
    const value = std.fmt.parseInt(u8, text, 10) catch return error.InvalidArgument;
    if (value > 100) return error.InvalidArgument;
    return value;
}

fn parseOnOff(text: []const u8) ParseError!OnOff {
    if (std.mem.eql(u8, text, "on")) return .on;
    if (std.mem.eql(u8, text, "off")) return .off;
    if (std.mem.eql(u8, text, "toggle")) return .toggle;
    return error.InvalidArgument;
}

/// Run one non-UI action and return the process exit code.
pub fn run(init: std.process.Init, args: []const []const u8) u8 {
    const action = parse(args[1], args[2..]) catch |err| {
        printErr(init.io, "iube: {s}\n", .{parseErrorMessage(err)});
        printErr(init.io, "Try 'iube help'.\n", .{});
        return 2;
    };

    execute(init, action) catch |err| {
        printErr(init.io, "iube: {s}\n", .{failureMessage(err)});
        return 1;
    };
    return 0;
}

fn execute(init: std.process.Init, action: Action) !void {
    switch (action) {
        .audio_volume_up => |percent| try audioVolume(init, percent, true),
        .audio_volume_down => |percent| try audioVolume(init, percent, false),
        .audio_mute => try audioMute(init, .sink),
        .audio_mic_mute => try audioMute(init, .source),
        .audio_default => |query| try audioDefault(init, query),
        .bluetooth_power => |state| try bluetoothPower(init, state),
        .bluetooth_discover => |state| try bluetoothDiscover(init, state),
        .bluetooth_connect => |query| try bluetoothConnection(init, query, true),
        .bluetooth_disconnect => |query| try bluetoothConnection(init, query, false),
        .bluetooth_list => try bluetoothList(init),
        .wifi_power => |state| try wifiPower(init, state),
        .wifi_scan => try wifiScan(init),
        .wifi_list => try wifiList(init),
        .wifi_connect => |ssid| try wifiConnect(init, ssid),
        .wifi_disconnect => try wifiDisconnect(init),
        .power_action => |power_action| try powerRun(init, power_action),
        .power_profile_next => try powerProfileNext(init),
        .power_profile_set => |profile| try powerProfileSet(init, profile),
        .power_battery => try powerBattery(init),
    }
}

fn audioEnvironment(init: std.process.Init) audio.Env {
    return .{
        .xdg_runtime_dir = init.environ_map.get("XDG_RUNTIME_DIR"),
        .home = init.environ_map.get("HOME"),
        .xdg_config_home = init.environ_map.get("XDG_CONFIG_HOME"),
    };
}

fn audioVolume(init: std.process.Init, percent: u8, up: bool) !void {
    var client = try audio.Client.connect(init.io, init.gpa, audioEnvironment(init));
    defer client.deinit();
    var state = try client.refresh(init.gpa);
    defer state.deinit();

    const default_name = state.default_sink orelse return error.NoDefaultSink;
    const device = defaultDevice(state.sinks, default_name) orelse return error.NoDefaultSink;
    const delta: i16 = if (up) @intCast(percent) else -@as(i16, @intCast(percent));
    const target = volumeTarget(device.percent(), delta);
    try client.setVolumePercent(device, target);
    printOut(init.io, "Volume: {d}%\n", .{target});
}

fn audioMute(init: std.process.Init, kind: audio.Kind) !void {
    var client = try audio.Client.connect(init.io, init.gpa, audioEnvironment(init));
    defer client.deinit();
    var state = try client.refresh(init.gpa);
    defer state.deinit();

    const devices = state.devices(kind);
    const default_name = switch (kind) {
        .sink => state.default_sink orelse return error.NoDefaultSink,
        .source => state.default_source orelse return error.NoDefaultSource,
    };
    const device = defaultDevice(devices, default_name) orelse switch (kind) {
        .sink => return error.NoDefaultSink,
        .source => return error.NoDefaultSource,
    };
    try client.toggleMute(device);
    printOut(init.io, "{s}: {s}\n", .{
        if (kind == .sink) "Output" else "Input",
        if (device.mute) "unmuted" else "muted",
    });
}

fn audioDefault(init: std.process.Init, query: []const u8) !void {
    var client = try audio.Client.connect(init.io, init.gpa, audioEnvironment(init));
    defer client.deinit();
    var state = try client.refresh(init.gpa);
    defer state.deinit();

    const sink_index = findAudioDevice(state.sinks, query);
    const source_index = findAudioDevice(state.sources, query);
    if (sink_index != null and source_index != null) return error.AmbiguousDevice;

    const device = if (sink_index) |index|
        state.sinks[index]
    else if (source_index) |index|
        state.sources[index]
    else
        return error.AudioDeviceNotFound;

    try client.setDefault(device);
    printOut(init.io, "Default {s}: {s}\n", .{
        if (device.kind == .sink) "output" else "input",
        device.label(),
    });
}

fn bluetoothPower(init: std.process.Init, requested: OnOff) !void {
    var client = try bluetooth.Client.connect(init.io, init.gpa);
    defer client.deinit();
    var state = try client.refresh(init.gpa);
    defer state.deinit();

    const adapter = state.adapter() orelse return error.NoAdapter;
    const powered = requested.value(adapter.powered);
    try client.setAdapterPowered(adapter, powered);
    printOut(init.io, "Bluetooth: {s}\n", .{if (powered) "on" else "off"});
}

fn bluetoothDiscover(init: std.process.Init, requested: OnOff) !void {
    var client = try bluetooth.Client.connect(init.io, init.gpa);
    defer client.deinit();
    var state = try client.refresh(init.gpa);
    defer state.deinit();

    const adapter = state.adapter() orelse return error.NoAdapter;
    const discovering = requested.value(adapter.discovering);
    try client.setDiscovering(adapter, discovering);
    printOut(init.io, "Discovery: {s}\n", .{if (discovering) "on" else "off"});
}

fn bluetoothConnection(init: std.process.Init, query: []const u8, connect: bool) !void {
    var client = try bluetooth.Client.connect(init.io, init.gpa);
    defer client.deinit();
    var state = try client.refresh(init.gpa);
    defer state.deinit();

    const index = findBluetoothDevice(state.devices, query) orelse return error.BluetoothDeviceNotFound;
    const device = state.devices[index];
    try client.setConnected(device, connect);
    printOut(init.io, "{s}: {s}\n", .{
        if (connect) "Connected" else "Disconnected",
        device.label(),
    });
}

fn bluetoothList(init: std.process.Init) !void {
    var client = try bluetooth.Client.connect(init.io, init.gpa);
    defer client.deinit();
    var state = try client.refresh(init.gpa);
    defer state.deinit();

    if (state.adapter()) |adapter| {
        printOut(init.io, "Adapter: {s}\t{s}\t{s}\n", .{
            adapter.label(),
            adapter.address,
            if (adapter.powered) "on" else "off",
        });
    } else {
        printOut(init.io, "No Bluetooth adapter\n", .{});
        return;
    }

    if (state.devices.len == 0) {
        printOut(init.io, "No devices\n", .{});
        return;
    }
    for (state.devices) |device| {
        printOut(init.io, "{s}\t{s}\t{s}\n", .{
            device.stateLabel(),
            device.label(),
            device.address,
        });
    }
}

fn wifiPower(init: std.process.Init, requested: OnOff) !void {
    var client = try wifi.Client.connect(init.io, init.gpa);
    defer client.deinit();
    var state = try client.refresh(init.gpa);
    defer state.deinit();

    const enabled = requested.value(state.wireless_enabled);
    try client.setWirelessEnabled(enabled);
    printOut(init.io, "Wi-Fi: {s}\n", .{if (enabled) "on" else "off"});
}

fn wifiScan(init: std.process.Init) !void {
    var client = try wifi.Client.connect(init.io, init.gpa);
    defer client.deinit();
    var state = try client.refresh(init.gpa);
    defer state.deinit();

    const device = state.device orelse return error.NoWifiDevice;
    try client.requestScan(device);
    std.Io.sleep(init.io, .fromMilliseconds(wifi_scan_wait_ms), .awake) catch {};

    var refreshed = try client.refresh(init.gpa);
    defer refreshed.deinit();
    printWifiState(init.io, refreshed);
}

fn wifiList(init: std.process.Init) !void {
    var client = try wifi.Client.connect(init.io, init.gpa);
    defer client.deinit();
    var state = try client.refresh(init.gpa);
    defer state.deinit();
    printWifiState(init.io, state);
}

fn wifiConnect(init: std.process.Init, ssid: []const u8) !void {
    var client = try wifi.Client.connect(init.io, init.gpa);
    defer client.deinit();
    var state = try client.refresh(init.gpa);
    defer state.deinit();

    const device = state.device orelse return error.NoWifiDevice;
    const saved = state.findSaved(ssid) orelse return error.NoSavedProfile;

    // NetworkManager accepts "/" as "let me pick the access point"; use it
    // when the saved network is not in the current scan results.
    var ap_path: []const u8 = "/";
    for (state.networks) |network| {
        if (std.mem.eql(u8, network.ssid, ssid)) {
            ap_path = network.ap_path;
            break;
        }
    }
    if (std.mem.eql(u8, ap_path, "/") and state.networks.len == 0) {
        return error.NetworkNotFound;
    }

    const network = wifi.Network{
        .ap_path = ap_path,
        .ssid = ssid,
        .strength = 0,
        .frequency = 0,
        .secured = false,
        .connected = false,
    };
    try client.activateSaved(device, network, saved);
    printOut(init.io, "Connecting to {s}\n", .{ssid});
}

fn wifiDisconnect(init: std.process.Init) !void {
    var client = try wifi.Client.connect(init.io, init.gpa);
    defer client.deinit();
    var state = try client.refresh(init.gpa);
    defer state.deinit();

    const device = state.device orelse return error.NoWifiDevice;
    if (std.mem.eql(u8, device.active_ap, "/")) return error.NotConnected;
    try client.disconnect(device);
    printOut(init.io, "Disconnected\n", .{});
}

fn powerRun(init: std.process.Init, action: power.Action) !void {
    var client = try power.Client.connect(init.io, init.gpa);
    defer client.deinit();
    try client.invoke(action);
    printOut(init.io, "{s}\n", .{action.title()});
}

fn powerProfileNext(init: std.process.Init) !void {
    var client = try power.Client.connect(init.io, init.gpa);
    defer client.deinit();
    var state = try client.refresh(init.gpa);
    defer state.deinit();

    const profile = state.profile orelse return error.ProfileUnavailable;
    if (profile.choices.len == 0) return error.ProfileUnavailable;

    var active_index: usize = 0;
    for (profile.choices, 0..) |choice, index| {
        if (std.mem.eql(u8, choice, profile.active)) {
            active_index = index;
            break;
        }
    }
    const next = profile.choices[(active_index + 1) % profile.choices.len];
    try client.setProfile(profile, next);
    printOut(init.io, "Power profile: {s}\n", .{next});
}

fn powerProfileSet(init: std.process.Init, requested: Profile) !void {
    var client = try power.Client.connect(init.io, init.gpa);
    defer client.deinit();
    var state = try client.refresh(init.gpa);
    defer state.deinit();

    const profile = state.profile orelse return error.ProfileUnavailable;
    const name = requested.name();
    var available = false;
    for (profile.choices) |choice| {
        if (std.mem.eql(u8, choice, name)) {
            available = true;
            break;
        }
    }
    if (!available) return error.ProfileNotAvailable;

    try client.setProfile(profile, name);
    printOut(init.io, "Power profile: {s}\n", .{name});
}

fn powerBattery(init: std.process.Init) !void {
    var state = try power.read(init.io, init.gpa);
    defer state.deinit();

    if (state.battery) |battery| {
        printOut(init.io, "{d}%\t{s}\tAC: {s}\n", .{
            battery.percent,
            battery.status.label(),
            if (state.ac_online) "on" else "off",
        });
    } else {
        printOut(init.io, "No battery\tAC: {s}\n", .{if (state.ac_online) "on" else "off"});
    }
}

fn printWifiState(io: std.Io, state: wifi.State) void {
    printOut(io, "Wi-Fi: {s}\n", .{if (state.wireless_enabled) "on" else "off"});
    if (state.device == null) {
        printOut(io, "No Wi-Fi device\n", .{});
        return;
    }
    if (state.networks.len == 0) {
        printOut(io, "No networks\n", .{});
        return;
    }
    for (state.networks) |network| {
        const status = if (network.connected)
            "connected"
        else if (state.findSaved(network.ssid) != null)
            "saved"
        else if (network.secured)
            "secured"
        else
            "open";
        printOut(io, "{s}\t{s}\t{d}%\t{s}\n", .{
            network.label(),
            status,
            network.strength,
            network.bandLabel() orelse "",
        });
    }
}

/// Clamp the current volume to 0-100 before applying the step, so a value
/// above 100 (PulseAudio allows up to 150%) comes back into range.
fn volumeTarget(current: u8, delta: i16) u8 {
    const base: i16 = @intCast(@min(current, 100));
    const target = std.math.clamp(base + delta, 0, 100);
    return @intCast(target);
}

fn defaultDevice(devices: []const audio.Device, default_name: []const u8) ?audio.Device {
    for (devices) |device| {
        if (std.mem.eql(u8, device.name, default_name)) return device;
    }
    return null;
}

fn findAudioDevice(devices: []const audio.Device, query: []const u8) ?usize {
    for (devices, 0..) |device, index| {
        if (std.ascii.eqlIgnoreCase(device.name, query) or
            std.ascii.eqlIgnoreCase(device.description, query))
        {
            return index;
        }
    }
    return null;
}

fn findBluetoothDevice(devices: []const bluetooth.Device, query: []const u8) ?usize {
    for (devices, 0..) |device, index| {
        if (std.ascii.eqlIgnoreCase(device.name, query) or
            std.ascii.eqlIgnoreCase(device.address, query))
        {
            return index;
        }
    }
    return null;
}

fn parseErrorMessage(err: ParseError) []const u8 {
    return switch (err) {
        error.UnknownCommand => "unknown command",
        error.UnknownAction => "unknown action",
        error.MissingArgument => "missing argument",
        error.InvalidArgument => "invalid argument (percent is 0-100, state is on/off/toggle)",
        error.TooManyArguments => "too many arguments",
    };
}

fn failureMessage(err: anyerror) []const u8 {
    return switch (err) {
        error.NoDefaultSink => "no default audio output",
        error.NoDefaultSource => "no default audio input",
        error.AudioDeviceNotFound => "audio device not found",
        error.AmbiguousDevice => "more than one audio device matches",
        error.NoAdapter => "no Bluetooth adapter",
        error.BluetoothDeviceNotFound => "Bluetooth device not found",
        error.NoWifiDevice => "no Wi-Fi device",
        error.NetworkNotFound => "network not found; run 'iube wifi scan' first",
        error.NoSavedProfile => "no saved Wi-Fi profile for that network",
        error.NotConnected => "not connected",
        error.ProfileUnavailable => "power profiles are not available",
        error.ProfileNotAvailable => "that power profile is not available",
        error.AccessDenied => "permission denied",
        error.Timeout => "the system service timed out",
        error.ConnectionRefused => "the system service is not running",
        error.ConnectionClosed => "the system service closed the connection",
        error.MethodFailed => "the system service rejected the request",
        error.FileNotFound => "a required system file is missing",
        else => @errorName(err),
    };
}

fn printOut(io: std.Io, comptime format: []const u8, args: anytype) void {
    var buffer: [1024]u8 = undefined;
    const text = std.fmt.bufPrint(&buffer, format, args) catch return;
    std.Io.File.stdout().writeStreamingAll(io, text) catch {};
}

fn printErr(io: std.Io, comptime format: []const u8, args: anytype) void {
    var buffer: [1024]u8 = undefined;
    const text = std.fmt.bufPrint(&buffer, format, args) catch return;
    std.Io.File.stderr().writeStreamingAll(io, text) catch {};
}

test "parse audio actions" {
    var percent = [_][]const u8{"volume-up"};
    try std.testing.expectEqual(
        @as(u8, default_volume_step),
        (try parse("audio", &percent)).audio_volume_up,
    );

    var up = [_][]const u8{ "volume-up", "12" };
    try std.testing.expectEqual(@as(u8, 12), (try parse("audio", &up)).audio_volume_up);

    var down = [_][]const u8{ "volume-down", "0" };
    try std.testing.expectEqual(@as(u8, 0), (try parse("audio", &down)).audio_volume_down);

    var mute = [_][]const u8{"mic-mute"};
    try std.testing.expectEqual(Action.audio_mic_mute, try parse("audio", &mute));

    var device = [_][]const u8{ "default", "alsa_output.test" };
    const parsed = try parse("audio", &device);
    try std.testing.expectEqualStrings("alsa_output.test", parsed.audio_default);
}

test "parse audio rejects bad arguments" {
    var loud = [_][]const u8{ "volume-up", "101" };
    try std.testing.expectError(error.InvalidArgument, parse("audio", &loud));

    var text = [_][]const u8{ "volume-down", "five" };
    try std.testing.expectError(error.InvalidArgument, parse("audio", &text));

    var missing = [_][]const u8{"default"};
    try std.testing.expectError(error.MissingArgument, parse("audio", &missing));

    var extra = [_][]const u8{ "mute", "now" };
    try std.testing.expectError(error.TooManyArguments, parse("audio", &extra));

    var unknown = [_][]const u8{"fade"};
    try std.testing.expectError(error.UnknownAction, parse("audio", &unknown));
}

test "parse bluetooth actions" {
    var power_on = [_][]const u8{ "power", "on" };
    try std.testing.expectEqual(OnOff.on, (try parse("bluetooth", &power_on)).bluetooth_power);

    var discover = [_][]const u8{ "discover", "off" };
    try std.testing.expectEqual(OnOff.off, (try parse("bluetooth", &discover)).bluetooth_discover);

    var discover_toggle = [_][]const u8{ "discover", "toggle" };
    try std.testing.expectError(error.InvalidArgument, parse("bluetooth", &discover_toggle));

    var connect = [_][]const u8{ "connect", "Headphones" };
    try std.testing.expectEqualStrings("Headphones", (try parse("bluetooth", &connect)).bluetooth_connect);

    var list = [_][]const u8{"list"};
    try std.testing.expectEqual(Action.bluetooth_list, try parse("bluetooth", &list));
}

test "parse wifi actions" {
    var toggle = [_][]const u8{"toggle"};
    try std.testing.expectEqual(OnOff.toggle, (try parse("wifi", &toggle)).wifi_power);

    var connect = [_][]const u8{ "connect", "Home" };
    try std.testing.expectEqualStrings("Home", (try parse("wifi", &connect)).wifi_connect);

    var scan = [_][]const u8{"scan"};
    try std.testing.expectEqual(Action.wifi_scan, try parse("wifi", &scan));

    var disconnect = [_][]const u8{"disconnect"};
    try std.testing.expectEqual(Action.wifi_disconnect, try parse("wifi", &disconnect));
}

test "parse power actions" {
    var suspend_args = [_][]const u8{"suspend"};
    try std.testing.expectEqual(power.Action.suspend_system, (try parse("power", &suspend_args)).power_action);

    var poweroff = [_][]const u8{"poweroff"};
    try std.testing.expectEqual(power.Action.power_off, (try parse("power", &poweroff)).power_action);

    var next = [_][]const u8{ "profile", "next" };
    try std.testing.expectEqual(Action.power_profile_next, try parse("power", &next));

    var set = [_][]const u8{ "profile", "set", "performance" };
    try std.testing.expectEqual(Profile.performance, (try parse("power", &set)).power_profile_set);

    var bad_set = [_][]const u8{ "profile", "set", "turbo" };
    try std.testing.expectError(error.InvalidArgument, parse("power", &bad_set));

    var missing_set = [_][]const u8{ "profile", "set" };
    try std.testing.expectError(error.MissingArgument, parse("power", &missing_set));

    var battery = [_][]const u8{"battery"};
    try std.testing.expectEqual(Action.power_battery, try parse("power", &battery));
}

test "parse rejects unknown commands and tools" {
    var list = [_][]const u8{"list"};
    try std.testing.expectError(error.UnknownCommand, parse("teleport", &list));

    var none: [0][]const u8 = .{};
    try std.testing.expectError(error.MissingArgument, parse("wifi", &none));
}

test "volume target clamps to 0-100" {
    try std.testing.expectEqual(@as(u8, 55), volumeTarget(50, 5));
    try std.testing.expectEqual(@as(u8, 45), volumeTarget(50, -5));
    try std.testing.expectEqual(@as(u8, 100), volumeTarget(98, 5));
    try std.testing.expectEqual(@as(u8, 0), volumeTarget(2, -5));
    try std.testing.expectEqual(@as(u8, 95), volumeTarget(120, -5));
    try std.testing.expectEqual(@as(u8, 100), volumeTarget(120, 5));
}

test "audio device lookup is case-insensitive on name and description" {
    const devices = [_]audio.Device{
        .{ .kind = .sink, .index = 0, .name = "alsa_output.test", .description = "Test Speaker", .channels = 2, .volume = 0, .mute = false, .is_default = false },
        .{ .kind = .sink, .index = 1, .name = "alsa_output.other", .description = "Other", .channels = 2, .volume = 0, .mute = false, .is_default = false },
    };
    try std.testing.expectEqual(@as(?usize, 0), findAudioDevice(&devices, "ALSA_OUTPUT.TEST"));
    try std.testing.expectEqual(@as(?usize, 0), findAudioDevice(&devices, "test speaker"));
    try std.testing.expectEqual(@as(?usize, 1), findAudioDevice(&devices, "OTHER"));
    try std.testing.expect(findAudioDevice(&devices, "missing") == null);

    try std.testing.expectEqual(@as(?audio.Device, devices[0]), defaultDevice(&devices, "alsa_output.test"));
    try std.testing.expect(defaultDevice(&devices, "missing") == null);
}

test "bluetooth device lookup matches name or address case-insensitively" {
    const devices = [_]bluetooth.Device{
        .{ .path = "/org/bluez/hci0/dev_1", .adapter_path = "/org/bluez/hci0", .name = "Headphones", .address = "AA:BB:CC:DD:EE:FF" },
        .{ .path = "/org/bluez/hci0/dev_2", .adapter_path = "/org/bluez/hci0", .name = "Keyboard", .address = "11:22:33:44:55:66" },
    };
    try std.testing.expectEqual(@as(?usize, 0), findBluetoothDevice(&devices, "headphones"));
    try std.testing.expectEqual(@as(?usize, 0), findBluetoothDevice(&devices, "aa:bb:cc:dd:ee:ff"));
    try std.testing.expectEqual(@as(?usize, 1), findBluetoothDevice(&devices, "11:22:33:44:55:66"));
    try std.testing.expect(findBluetoothDevice(&devices, "mouse") == null);
}

test "tool detection" {
    try std.testing.expect(isTool("audio"));
    try std.testing.expect(isTool("bluetooth"));
    try std.testing.expect(isTool("wifi"));
    try std.testing.expect(isTool("power"));
    try std.testing.expect(!isTool("launch"));
    try std.testing.expect(!isTool("help"));
}
