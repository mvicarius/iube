//! Backlight state and brightness changes.
//!
//! Backlight devices and their current raw level come from
//! `/sys/class/backlight`. Changes go through logind's
//! `org.freedesktop.login1.Session.SetBrightness` method, which applies the
//! local polkit/session policy. iube does not write sysfs directly, does not
//! need root or udev rules, and does not use `brightnessctl`.

const std = @import("std");
const dbus = @import("dbus.zig");

const backlight_path = "/sys/class/backlight";
const proc_session_path = "/proc/self/sessionid";

const logind = "org.freedesktop.login1";
const logind_object = "/org/freedesktop/login1";
const logind_manager = "org.freedesktop.login1.Manager";
const logind_session = "org.freedesktop.login1.Session";

/// One backlight device as exposed by sysfs. `name`, `kind` and `path` are
/// arena-owned by the enclosing `State`.
pub const Device = struct {
    name: []const u8,
    kind: []const u8,
    brightness: u32,
    max_brightness: u32,

    pub fn usable(self: Device) bool {
        return self.max_brightness > 0;
    }

    pub fn percent(self: Device) u8 {
        return percentOf(self.brightness, self.max_brightness);
    }

    pub fn percentLabel(self: Device, buffer: []u8) []const u8 {
        return std.fmt.bufPrint(buffer, "{d}%", .{self.percent()}) catch "--%";
    }

    pub fn listLine(self: Device, buffer: []u8) []const u8 {
        return std.fmt.bufPrint(
            buffer,
            "{s}  {d}%  {s}  {d}/{d}",
            .{ self.name, self.percent(), self.kind, self.brightness, self.max_brightness },
        ) catch self.name;
    }
};

pub const State = struct {
    arena: std.heap.ArenaAllocator,
    devices: []Device,

    pub fn deinit(self: *State) void {
        self.arena.deinit();
    }

    /// The device iube uses by default: the first usable backlight in the
    /// (name-sorted) sysfs list.
    pub fn selectedIndex(self: State) ?usize {
        return chooseDevice(self.devices);
    }

    pub fn selected(self: State) ?Device {
        const index = self.selectedIndex() orelse return null;
        return self.devices[index];
    }
};

pub const Client = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    bus: dbus.Client,
    session_path: []u8,

    pub fn connect(io: std.Io, gpa: std.mem.Allocator) !Client {
        var bus = dbus.Client.connectSystem(io, gpa) catch return error.DBusUnavailable;
        errdefer bus.deinit();

        const path = findSessionPath(&bus, io, gpa) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.DBusUnavailable => return error.DBusUnavailable,
            error.AccessDenied => return error.AccessDenied,
            else => return error.UnsupportedSession,
        };
        errdefer gpa.free(path);

        return .{
            .io = io,
            .gpa = gpa,
            .bus = bus,
            .session_path = path,
        };
    }

    pub fn deinit(self: *Client) void {
        self.gpa.free(self.session_path);
        self.bus.deinit();
    }

    /// Ask logind to set the raw backlight value. logind owns the permission
    /// check and decides whether the session may change this device.
    pub fn setBrightness(self: *Client, device_name: []const u8, value: u32) !void {
        var body = dbus.Builder{};
        body.putString("backlight");
        body.putString(device_name);
        body.putU32(value);

        var reply = self.bus.call(.{
            .destination = logind,
            .path = self.session_path,
            .interface = logind_session,
            .member = "SetBrightness",
            .signature = "ssu",
            .body = body.slice(),
        }) catch |err| return self.mapCallError(err);
        reply.deinit();
    }

    fn mapCallError(self: *Client, err: anyerror) anyerror {
        if (err != error.MethodFailed) return err;
        return classifyLogindError(self.bus.errorName());
    }
};

/// Read every backlight device and its current level. Returns
/// `error.NoBacklight` when the class directory is empty or contains no usable
/// device, and `error.AccessDenied` when sysfs cannot be read by this user.
pub fn read(io: std.Io, gpa: std.mem.Allocator) !State {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const alloc = arena.allocator();

    var dir = std.Io.Dir.openDirAbsolute(io, backlight_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return error.NoBacklight,
        error.AccessDenied => return error.AccessDenied,
        else => return err,
    };
    defer dir.close(io);

    var devices: std.ArrayList(Device) = .empty;
    var saw_denied = false;

    var iterator = dir.iterate();
    while (try iterator.next(io)) |entry| {
        if (entry.kind != .directory and entry.kind != .sym_link) continue;

        const device = readDevice(io, alloc, entry.name) catch |err| switch (err) {
            error.AccessDenied => {
                saw_denied = true;
                continue;
            },
            error.OutOfMemory => return error.OutOfMemory,
            else => continue,
        };
        try devices.append(alloc, device);
    }

    if (devices.items.len == 0) {
        if (saw_denied) return error.AccessDenied;
        return error.NoBacklight;
    }

    std.mem.sort(Device, devices.items, {}, deviceLessThan);

    var has_usable = false;
    for (devices.items) |device| {
        if (device.usable()) {
            has_usable = true;
            break;
        }
    }
    if (!has_usable) return error.NoBacklight;

    return .{
        .arena = arena,
        .devices = devices.items,
    };
}

fn readDevice(io: std.Io, alloc: std.mem.Allocator, name: []const u8) !Device {
    const max_text = try readField(io, alloc, name, "max_brightness");
    const max_brightness = std.fmt.parseInt(u32, max_text, 10) catch return error.InvalidDevice;

    const brightness_text = try readField(io, alloc, name, "brightness");
    const brightness = std.fmt.parseInt(u32, brightness_text, 10) catch return error.InvalidDevice;

    const kind = readField(io, alloc, name, "type") catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => "unknown",
    };

    const name_copy = try alloc.dupe(u8, name);
    const kind_copy = try alloc.dupe(u8, kind);

    return .{
        .name = name_copy,
        .kind = kind_copy,
        .brightness = brightness,
        .max_brightness = max_brightness,
    };
}

fn readField(
    io: std.Io,
    alloc: std.mem.Allocator,
    name: []const u8,
    field: []const u8,
) ![]const u8 {
    const path = try std.fmt.allocPrint(alloc, "{s}/{s}/{s}", .{ backlight_path, name, field });
    const data = try std.Io.Dir.readFileAlloc(.cwd(), io, path, alloc, .limited(4096));
    const trimmed = std.mem.trim(u8, data, " \t\r\n");
    if (trimmed.len == 0) return error.InvalidDevice;
    return trimmed;
}

fn deviceLessThan(_: void, lhs: Device, rhs: Device) bool {
    return std.mem.order(u8, lhs.name, rhs.name) == .lt;
}

fn findSessionPath(bus: *dbus.Client, io: std.Io, gpa: std.mem.Allocator) ![]u8 {
    if (getSessionByPid(bus, gpa) catch null) |path| return path;
    return getSessionFromProc(bus, io, gpa);
}

fn getSessionByPid(bus: *dbus.Client, gpa: std.mem.Allocator) !?[]u8 {
    const pid: u32 = @intCast(std.posix.system.getpid());

    var body = dbus.Builder{};
    body.putU32(pid);

    var reply = bus.call(.{
        .destination = logind,
        .path = logind_object,
        .interface = logind_manager,
        .member = "GetSessionByPID",
        .signature = "u",
        .body = body.slice(),
    }) catch |err| switch (err) {
        error.MethodFailed => return null,
        else => return err,
    };
    defer reply.deinit();

    var reader = dbus.Reader{ .data = reply.body };
    const path = reader.readObjectPath() catch return null;
    return try gpa.dupe(u8, path);
}

fn getSessionFromProc(bus: *dbus.Client, io: std.Io, gpa: std.mem.Allocator) ![]u8 {
    var id_buffer: [64]u8 = undefined;
    var file = std.Io.Dir.openFileAbsolute(io, proc_session_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return error.UnsupportedSession,
        error.AccessDenied => return error.AccessDenied,
        else => return err,
    };
    defer file.close(io);

    const length = std.Io.File.readStreaming(file, io, &.{&id_buffer}) catch |err| switch (err) {
        error.EndOfStream => return error.UnsupportedSession,
        else => return err,
    };
    const session_id = parseSessionId(id_buffer[0..length]) orelse return error.UnsupportedSession;

    var body = dbus.Builder{};
    body.putString(session_id);

    var reply = bus.call(.{
        .destination = logind,
        .path = logind_object,
        .interface = logind_manager,
        .member = "GetSession",
        .signature = "s",
        .body = body.slice(),
    }) catch |err| switch (err) {
        error.MethodFailed => return error.UnsupportedSession,
        else => return error.DBusUnavailable,
    };
    defer reply.deinit();

    var reader = dbus.Reader{ .data = reply.body };
    const path = reader.readObjectPath() catch return error.UnsupportedSession;
    return try gpa.dupe(u8, path);
}

/// Parse `/proc/self/sessionid`. Empty, `0`, `-1` and `4294967295` mean the
/// process has no logind session.
pub fn parseSessionId(text: []const u8) ?[]const u8 {
    const value = std.mem.trim(u8, text, " \t\r\n");
    if (value.len == 0) return null;
    if (std.mem.eql(u8, value, "0") or
        std.mem.eql(u8, value, "-1") or
        std.mem.eql(u8, value, "4294967295"))
    {
        return null;
    }
    return value;
}

/// Percentage from a raw sysfs value and its maximum. Rounded to the nearest
/// whole percent and clamped to 100 so a driver reporting a slightly high
/// current value never produces an out-of-range bar.
pub fn percentOf(value: u64, max: u64) u8 {
    if (max == 0) return 0;
    const rounded = (value *| 100 +| max / 2) / max;
    return @intCast(@min(rounded, 100));
}

/// Raw sysfs value for a percentage, rounded to the nearest step.
pub fn rawForPercent(percent: u8, max: u32) u32 {
    if (max == 0) return 0;
    const clamped: u64 = @min(percent, 100);
    return @intCast((clamped * @as(u64, max) + 50) / 100);
}

pub fn clampPercent(value: i32) u8 {
    return @intCast(std.math.clamp(value, 0, 100));
}

pub fn parsePercent(text: []const u8) !u8 {
    const value = std.fmt.parseInt(u8, text, 10) catch return error.InvalidPercent;
    if (value > 100) return error.InvalidPercent;
    return value;
}

/// The first device with a non-zero maximum, matching the order used by the
/// view and CLI.
pub fn chooseDevice(devices: []const Device) ?usize {
    for (devices, 0..) |device, index| {
        if (device.usable()) return index;
    }
    return null;
}

/// Map a logind error name to the small error set shown by the view and CLI.
pub fn classifyLogindError(name: []const u8) anyerror {
    if (name.len == 0) return error.SetFailed;
    if (std.mem.indexOf(u8, name, "AccessDenied") != null or
        std.mem.indexOf(u8, name, "PermissionDenied") != null or
        std.mem.indexOf(u8, name, "NotPermitted") != null)
    {
        return error.AccessDenied;
    }
    if (std.mem.indexOf(u8, name, "NoSuchDevice") != null or
        std.mem.indexOf(u8, name, "UnknownDevice") != null or
        std.mem.indexOf(u8, name, "DeviceNotFound") != null)
    {
        return error.DeviceNotFound;
    }
    if (std.mem.indexOf(u8, name, "NoSuchSession") != null or
        std.mem.indexOf(u8, name, "NoSession") != null or
        std.mem.indexOf(u8, name, "Unsupported") != null)
    {
        return error.UnsupportedSession;
    }
    if (std.mem.indexOf(u8, name, "NotSupported") != null) return error.NotSupported;
    return error.SetFailed;
}

/// Human-readable text for the errors this module returns. The strings are
/// deliberately static so the view and CLI can show them without allocating.
pub fn describe(err: anyerror) []const u8 {
    return switch (err) {
        error.NoBacklight => "No backlight device found under /sys/class/backlight.",
        error.AccessDenied => "Permission denied. logind did not allow this user to set brightness.",
        error.UnsupportedSession => "This process is not part of a logind session, so brightness cannot be changed.",
        error.DBusUnavailable => "Cannot reach logind on the system D-Bus.",
        error.DeviceNotFound => "The backlight device is no longer present.",
        error.NotSupported => "logind does not support brightness control for this session.",
        error.InvalidPercent => "Brightness must be a percentage between 0 and 100.",
        error.SetFailed => "logind refused the brightness change.",
        else => "Brightness request failed.",
    };
}

test "percentage rounds and clamps" {
    try std.testing.expectEqual(@as(u8, 0), percentOf(0, 0));
    try std.testing.expectEqual(@as(u8, 0), percentOf(0, 65535));
    try std.testing.expectEqual(@as(u8, 50), percentOf(50, 100));
    try std.testing.expectEqual(@as(u8, 43), percentOf(28_212, 65_535));
    try std.testing.expectEqual(@as(u8, 100), percentOf(65_535, 65_535));
    try std.testing.expectEqual(@as(u8, 100), percentOf(70_000, 65_535));
    try std.testing.expectEqual(@as(u8, 33), percentOf(1, 3));
    try std.testing.expectEqual(@as(u8, 67), percentOf(2, 3));
}

test "raw value for percentage" {
    try std.testing.expectEqual(@as(u32, 0), rawForPercent(0, 65_535));
    try std.testing.expectEqual(@as(u32, 65_535), rawForPercent(100, 65_535));
    try std.testing.expectEqual(@as(u32, 32_768), rawForPercent(50, 65_535));
    try std.testing.expectEqual(@as(u32, 0), rawForPercent(50, 0));
    try std.testing.expectEqual(@as(u32, 65_535), rawForPercent(120, 65_535));
}

test "clamp and parse percentages" {
    try std.testing.expectEqual(@as(u8, 0), clampPercent(-12));
    try std.testing.expectEqual(@as(u8, 100), clampPercent(120));
    try std.testing.expectEqual(@as(u8, 42), clampPercent(42));

    try std.testing.expectEqual(@as(u8, 0), try parsePercent("0"));
    try std.testing.expectEqual(@as(u8, 100), try parsePercent("100"));
    try std.testing.expectError(error.InvalidPercent, parsePercent("101"));
    try std.testing.expectError(error.InvalidPercent, parsePercent("-1"));
    try std.testing.expectError(error.InvalidPercent, parsePercent("abc"));
    try std.testing.expectError(error.InvalidPercent, parsePercent(""));
}

test "device selection skips unusable entries" {
    const devices = [_]Device{
        .{ .name = "acpi_video0", .kind = "firmware", .brightness = 0, .max_brightness = 0 },
        .{ .name = "amdgpu_bl2", .kind = "raw", .brightness = 28_212, .max_brightness = 65_535 },
    };

    try std.testing.expectEqual(@as(?usize, 1), chooseDevice(&devices));
    try std.testing.expectEqual(@as(?usize, null), chooseDevice(&.{}));

    const no_usable = [_]Device{
        .{ .name = "broken", .kind = "raw", .brightness = 0, .max_brightness = 0 },
    };
    try std.testing.expectEqual(@as(?usize, null), chooseDevice(&no_usable));
}

test "device formatting" {
    const device = Device{
        .name = "amdgpu_bl2",
        .kind = "raw",
        .brightness = 28_212,
        .max_brightness = 65_535,
    };

    var percent_buffer: [8]u8 = undefined;
    try std.testing.expectEqualStrings("43%", device.percentLabel(&percent_buffer));

    var line_buffer: [96]u8 = undefined;
    try std.testing.expectEqualStrings(
        "amdgpu_bl2  43%  raw  28212/65535",
        device.listLine(&line_buffer),
    );
}

test "session ids and logind errors" {
    try std.testing.expectEqualStrings("1", parseSessionId("1\n").?);
    try std.testing.expectEqualStrings("c2", parseSessionId(" c2 \r\n").?);
    try std.testing.expect(parseSessionId("") == null);
    try std.testing.expect(parseSessionId("0\n") == null);
    try std.testing.expect(parseSessionId("-1\n") == null);
    try std.testing.expect(parseSessionId("4294967295\n") == null);

    try std.testing.expect(classifyLogindError("org.freedesktop.DBus.Error.AccessDenied") == error.AccessDenied);
    try std.testing.expect(classifyLogindError("org.freedesktop.login1.NoSuchSession") == error.UnsupportedSession);
    try std.testing.expect(classifyLogindError("org.freedesktop.login1.NoSuchDevice") == error.DeviceNotFound);
    try std.testing.expect(classifyLogindError("org.freedesktop.login1.NotSupported") == error.NotSupported);
    try std.testing.expect(classifyLogindError("org.freedesktop.DBus.Error.Failed") == error.SetFailed);
}

test "error descriptions are specific" {
    try std.testing.expect(std.mem.indexOf(u8, describe(error.NoBacklight), "No backlight") != null);
    try std.testing.expect(std.mem.indexOf(u8, describe(error.AccessDenied), "Permission denied") != null);
    try std.testing.expect(std.mem.indexOf(u8, describe(error.UnsupportedSession), "logind session") != null);
}
