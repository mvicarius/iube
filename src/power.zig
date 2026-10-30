//! Battery, power profile and session actions.
//!
//! Battery state and the ACPI platform profile are read from sysfs. Session
//! actions go through logind on the system D-Bus. When power-profiles-daemon is
//! running, its D-Bus profile API is preferred over writing platform_profile
//! directly. iube does not link UPower, libsystemd or libdbus.

const std = @import("std");
const dbus = @import("dbus.zig");

const logind = "org.freedesktop.login1";
const logind_path = "/org/freedesktop/login1";
const logind_manager = "org.freedesktop.login1.Manager";
const properties = "org.freedesktop.DBus.Properties";

const ppd = "net.hadess.PowerProfiles";
const ppd_path = "/net/hadess/PowerProfiles";
const ppd_interface = "net.hadess.PowerProfiles";

const power_supply_path = "/sys/class/power_supply";
const platform_profile_path = "/sys/firmware/acpi/platform_profile";
const platform_profile_choices_path = "/sys/firmware/acpi/platform_profile_choices";

pub const BatteryStatus = enum {
    charging,
    discharging,
    full,
    not_charging,
    unknown,

    pub fn label(self: BatteryStatus) []const u8 {
        return switch (self) {
            .charging => "Charging",
            .discharging => "Discharging",
            .full => "Full",
            .not_charging => "Not charging",
            .unknown => "Unknown",
        };
    }
};

pub const Battery = struct {
    percent: u8 = 0,
    status: BatteryStatus = .unknown,
    energy_now: ?u64 = null,
    energy_full: ?u64 = null,
    power_now: ?u64 = null,
    charge_now: ?u64 = null,
    charge_full: ?u64 = null,
    current_now: ?u64 = null,

    pub fn estimateSeconds(self: Battery) ?u64 {
        switch (self.status) {
            .discharging => {
                if (self.power_now) |power| {
                    if (power > 0 and self.energy_now != null) {
                        return self.energy_now.? * 3600 / power;
                    }
                }
                if (self.current_now) |current| {
                    if (current > 0 and self.charge_now != null) {
                        return self.charge_now.? * 3600 / current;
                    }
                }
                return null;
            },
            .charging => {
                if (self.power_now) |power| {
                    if (power > 0 and self.energy_now != null and self.energy_full != null) {
                        if (self.energy_full.? > self.energy_now.?) {
                            return (self.energy_full.? - self.energy_now.?) * 3600 / power;
                        }
                    }
                }
                if (self.current_now) |current| {
                    if (current > 0 and self.charge_now != null and self.charge_full != null) {
                        if (self.charge_full.? > self.charge_now.?) {
                            return (self.charge_full.? - self.charge_now.?) * 3600 / current;
                        }
                    }
                }
                return null;
            },
            else => return null,
        }
    }

    pub fn timeLabel(self: Battery, buffer: []u8) []const u8 {
        const seconds = self.estimateSeconds() orelse return "";
        const hours = seconds / 3600;
        const minutes = (seconds % 3600) / 60;
        if (hours > 0) {
            return std.fmt.bufPrint(buffer, "{d}h {d:0>2}m", .{ hours, minutes }) catch "";
        }
        return std.fmt.bufPrint(buffer, "{d}m", .{minutes}) catch "";
    }

    pub fn summary(self: Battery, buffer: []u8) []const u8 {
        var time_buffer: [32]u8 = undefined;
        const time = self.timeLabel(&time_buffer);
        if (time.len == 0) return self.status.label();
        return switch (self.status) {
            .charging => std.fmt.bufPrint(buffer, "Charging - {s} to full", .{time}) catch "Charging",
            .discharging => std.fmt.bufPrint(buffer, "Discharging - {s} remaining", .{time}) catch "Discharging",
            else => self.status.label(),
        };
    }
};

pub const Availability = enum {
    no,
    challenge,
    yes,

    pub fn available(self: Availability) bool {
        return self != .no;
    }
};

pub const Actions = struct {
    lock: Availability = .no,
    suspend_system: Availability = .no,
    hibernate: Availability = .no,
    reboot: Availability = .no,
    power_off: Availability = .no,
};

pub const Action = enum {
    lock,
    suspend_system,
    hibernate,
    reboot,
    power_off,

    pub fn title(self: Action) []const u8 {
        return switch (self) {
            .lock => "Lock",
            .suspend_system => "Suspend",
            .hibernate => "Hibernate",
            .reboot => "Restart",
            .power_off => "Shut down",
        };
    }

    pub fn description(self: Action) []const u8 {
        return switch (self) {
            .lock => "Lock the session",
            .suspend_system => "Suspend to memory",
            .hibernate => "Suspend to disk",
            .reboot => "Restart the computer",
            .power_off => "Power off the computer",
        };
    }

    pub fn initial(self: Action) []const u8 {
        return switch (self) {
            .lock => "L",
            .suspend_system => "S",
            .hibernate => "H",
            .reboot => "R",
            .power_off => "P",
        };
    }

    pub fn destructive(self: Action) bool {
        return self == .reboot or self == .power_off;
    }

    pub fn availability(self: Action, actions: Actions) Availability {
        return switch (self) {
            .lock => actions.lock,
            .suspend_system => actions.suspend_system,
            .hibernate => actions.hibernate,
            .reboot => actions.reboot,
            .power_off => actions.power_off,
        };
    }
};

pub const ProfileBackend = enum {
    sysfs,
    ppd,
};

pub const Profile = enum {
    low_power,
    power_saver,
    balanced,
    performance,

    pub fn name(self: Profile) []const u8 {
        return switch (self) {
            .low_power => "low-power",
            .power_saver => "power-saver",
            .balanced => "balanced",
            .performance => "performance",
        };
    }

    pub fn parse(text: []const u8) ?Profile {
        if (std.mem.eql(u8, text, "low-power")) return .low_power;
        if (std.mem.eql(u8, text, "power-saver")) return .power_saver;
        if (std.mem.eql(u8, text, "balanced")) return .balanced;
        if (std.mem.eql(u8, text, "performance")) return .performance;
        return null;
    }
};

/// ACPI uses `low-power`, power-profiles-daemon uses `power-saver`. Accept
/// either spelling and report the name actually advertised by the backend.
pub fn resolveProfileName(choices: []const []const u8, requested: Profile) ?[]const u8 {
    const primary = requested.name();
    for (choices) |choice| {
        if (std.mem.eql(u8, choice, primary)) return choice;
    }
    if (requested == .low_power) {
        for (choices) |choice| {
            if (std.mem.eql(u8, choice, "power-saver")) return choice;
        }
    } else if (requested == .power_saver) {
        for (choices) |choice| {
            if (std.mem.eql(u8, choice, "low-power")) return choice;
        }
    }
    return null;
}

pub const ProfileState = struct {
    choices: []const []const u8,
    active: []const u8,
    backend: ProfileBackend,

    /// Next advertised profile, wrapping at the end. Shared by the UI and CLI.
    pub fn next(self: ProfileState) ?[]const u8 {
        if (self.choices.len == 0) return null;
        var active_index: usize = 0;
        for (self.choices, 0..) |choice, index| {
            if (std.mem.eql(u8, choice, self.active)) {
                active_index = index;
                break;
            }
        }
        return self.choices[(active_index + 1) % self.choices.len];
    }
};

pub fn profileDisplay(name: []const u8) []const u8 {
    if (std.mem.eql(u8, name, "low-power")) return "Low power";
    if (std.mem.eql(u8, name, "balanced")) return "Balanced";
    if (std.mem.eql(u8, name, "performance")) return "Performance";
    if (std.mem.eql(u8, name, "power-saver")) return "Power saver";
    return name;
}

pub const State = struct {
    arena: std.heap.ArenaAllocator,
    battery: ?Battery,
    ac_online: bool,
    profile: ?ProfileState,
    actions: ?Actions,

    pub fn deinit(self: *State) void {
        self.arena.deinit();
    }

    pub fn actionsOrEmpty(self: State) Actions {
        return self.actions orelse .{};
    }
};

pub const Client = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    bus: dbus.Client,

    pub fn connect(io: std.Io, gpa: std.mem.Allocator) !Client {
        return .{
            .io = io,
            .gpa = gpa,
            .bus = try dbus.Client.connectSystem(io, gpa),
        };
    }

    pub fn deinit(self: *Client) void {
        self.bus.deinit();
    }

    pub fn refresh(self: *Client, gpa: std.mem.Allocator) !State {
        var state = try read(self.io, gpa);
        errdefer state.deinit();

        const alloc = state.arena.allocator();
        if (self.readPpdProfile(alloc) catch null) |profile| {
            state.profile = profile;
        }

        state.actions = .{
            .lock = .yes,
            .suspend_system = self.can("CanSuspend") catch .no,
            .hibernate = self.can("CanHibernate") catch .no,
            .reboot = .yes,
            .power_off = .yes,
        };
        return state;
    }

    pub fn invoke(self: *Client, action: Action) !void {
        switch (action) {
            .lock => try self.callManager("LockSessions", "", 10_000),
            .suspend_system => try self.callManager("Suspend", "b", 86_400_000),
            .hibernate => try self.callManager("Hibernate", "b", 86_400_000),
            .reboot => try self.callManager("Reboot", "b", 30_000),
            .power_off => try self.callManager("PowerOff", "b", 30_000),
        }
    }

    pub fn setProfile(self: *Client, profile: ProfileState, name: []const u8) !void {
        switch (profile.backend) {
            .sysfs => try writeProfileSysfs(self.io, name),
            .ppd => {
                var body = dbus.Builder{};
                body.putString(ppd_interface);
                body.putString("ActiveProfile");
                body.putSignature("s");
                body.putString(name);

                var reply = try self.bus.call(.{
                    .destination = ppd,
                    .path = ppd_path,
                    .interface = properties,
                    .member = "Set",
                    .signature = "ssv",
                    .body = body.slice(),
                });
                reply.deinit();
            },
        }
    }

    fn callManager(
        self: *Client,
        member: []const u8,
        signature: []const u8,
        timeout_ms: i32,
    ) !void {
        var body = dbus.Builder{};
        if (signature.len > 0) body.putU32(1);

        var reply = try self.bus.call(.{
            .destination = logind,
            .path = logind_path,
            .interface = logind_manager,
            .member = member,
            .signature = signature,
            .body = body.slice(),
            .timeout_ms = timeout_ms,
        });
        reply.deinit();
    }

    fn can(self: *Client, member: []const u8) !Availability {
        var reply = try self.bus.call(.{
            .destination = logind,
            .path = logind_path,
            .interface = logind_manager,
            .member = member,
        });
        defer reply.deinit();

        var reader = dbus.Reader{ .data = reply.body };
        const value = try reader.readString();
        if (std.mem.eql(u8, value, "yes")) return .yes;
        if (std.mem.eql(u8, value, "challenge")) return .challenge;
        return .no;
    }

    fn readPpdProfile(self: *Client, alloc: std.mem.Allocator) !?ProfileState {
        var body = dbus.Builder{};
        body.putString(ppd_interface);

        var reply = try self.bus.call(.{
            .destination = ppd,
            .path = ppd_path,
            .interface = properties,
            .member = "GetAll",
            .signature = "s",
            .body = body.slice(),
        });
        defer reply.deinit();

        var active: ?[]const u8 = null;
        var choices: std.ArrayList([]const u8) = .empty;

        var reader = dbus.Reader{ .data = reply.body };
        const end = try reader.beginArray(8);
        while (reader.index < end) {
            try reader.alignTo(8);
            const key = try reader.readString();
            const signature = try reader.readSignature();

            if (std.mem.eql(u8, key, "ActiveProfile") and std.mem.eql(u8, signature, "s")) {
                active = try alloc.dupe(u8, try reader.readString());
            } else if (std.mem.eql(u8, key, "Profiles") and std.mem.eql(u8, signature, "aa{sv}")) {
                try readPpdProfiles(&reader, alloc, &choices);
            } else {
                try reader.skipValue(signature);
            }
        }
        try reader.finishArray(end);

        const active_value = active orelse return null;
        if (choices.items.len == 0) return null;
        return .{
            .choices = choices.items,
            .active = active_value,
            .backend = .ppd,
        };
    }
};

pub fn read(io: std.Io, gpa: std.mem.Allocator) !State {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const alloc = arena.allocator();

    var battery: ?Battery = null;
    var fallback_battery: ?Battery = null;
    var ac_online = false;

    var dir = std.Io.Dir.openDirAbsolute(io, power_supply_path, .{ .iterate = true }) catch {
        return .{
            .arena = arena,
            .battery = null,
            .ac_online = false,
            .profile = readProfileSysfs(io, alloc),
            .actions = null,
        };
    };
    defer dir.close(io);

    var iterator = dir.iterate();
    while (try iterator.next(io)) |entry| {
        if (entry.kind != .directory and entry.kind != .sym_link) continue;

        const base = std.fmt.allocPrint(alloc, "{s}/{s}", .{ power_supply_path, entry.name }) catch continue;
        const type_path = std.fmt.allocPrint(alloc, "{s}/type", .{base}) catch continue;
        const kind = readTrim(io, alloc, type_path) orelse continue;

        if (std.mem.eql(u8, kind, "Battery")) {
            const scope_path = std.fmt.allocPrint(alloc, "{s}/scope", .{base}) catch continue;
            const scope = readTrim(io, alloc, scope_path);
            const is_system = if (scope) |value| !std.mem.eql(u8, value, "Device") else true;
            if (is_system) {
                if (battery == null) battery = readBattery(io, alloc, base) catch null;
            } else if (fallback_battery == null) {
                fallback_battery = readBattery(io, alloc, base) catch null;
            }
        } else if (std.mem.eql(u8, kind, "Mains")) {
            const online_path = std.fmt.allocPrint(alloc, "{s}/online", .{base}) catch continue;
            const online = readU64(io, alloc, online_path) orelse 0;
            if (online != 0) ac_online = true;
        }
    }

    return .{
        .arena = arena,
        .battery = battery orelse fallback_battery,
        .ac_online = ac_online,
        .profile = readProfileSysfs(io, alloc),
        .actions = null,
    };
}

pub fn writeProfileSysfs(io: std.Io, name: []const u8) !void {
    var file = try std.Io.Dir.openFileAbsolute(io, platform_profile_path, .{ .mode = .write_only });
    defer file.close(io);
    try file.writeStreamingAll(io, name);
    try file.writeStreamingAll(io, "\n");
}

fn readBattery(io: std.Io, alloc: std.mem.Allocator, base: []const u8) !Battery {
    const capacity = try readFieldU64(io, alloc, base, "capacity");
    const energy_now = try readFieldU64(io, alloc, base, "energy_now");
    const energy_full = try readFieldU64(io, alloc, base, "energy_full");
    const power_now = try readFieldU64(io, alloc, base, "power_now");
    const charge_now = try readFieldU64(io, alloc, base, "charge_now");
    const charge_full = try readFieldU64(io, alloc, base, "charge_full");
    const current_now = try readFieldU64(io, alloc, base, "current_now");
    const voltage_now = try readFieldU64(io, alloc, base, "voltage_now");
    const status_path = std.fmt.allocPrint(alloc, "{s}/status", .{base}) catch "";
    const status = parseStatus(if (status_path.len > 0) readTrim(io, alloc, status_path) else null);

    var power = power_now;
    if (power == null) {
        if (current_now != null and voltage_now != null) {
            power = current_now.? * voltage_now.? / 1_000_000;
        }
    }

    var percent: u8 = 0;
    if (capacity) |value| {
        percent = @intCast(@min(value, 100));
    } else if (energy_now != null and energy_full != null and energy_full.? > 0) {
        percent = @intCast(@min(energy_now.? * 100 / energy_full.?, 100));
    } else if (charge_now != null and charge_full != null and charge_full.? > 0) {
        percent = @intCast(@min(charge_now.? * 100 / charge_full.?, 100));
    }

    return .{
        .percent = percent,
        .status = status,
        .energy_now = energy_now,
        .energy_full = energy_full,
        .power_now = power,
        .charge_now = charge_now,
        .charge_full = charge_full,
        .current_now = current_now,
    };
}

fn parseStatus(value: ?[]const u8) BatteryStatus {
    const text = value orelse return .unknown;
    if (std.mem.eql(u8, text, "Charging")) return .charging;
    if (std.mem.eql(u8, text, "Discharging")) return .discharging;
    if (std.mem.eql(u8, text, "Full")) return .full;
    if (std.mem.eql(u8, text, "Not charging")) return .not_charging;
    return .unknown;
}

fn readFieldU64(io: std.Io, alloc: std.mem.Allocator, base: []const u8, field: []const u8) !?u64 {
    const path = std.fmt.allocPrint(alloc, "{s}/{s}", .{ base, field }) catch return null;
    return readU64(io, alloc, path);
}

fn readU64(io: std.Io, alloc: std.mem.Allocator, path: []const u8) ?u64 {
    const text = readTrim(io, alloc, path) orelse return null;
    return std.fmt.parseInt(u64, text, 10) catch null;
}

fn readTrim(io: std.Io, alloc: std.mem.Allocator, path: []const u8) ?[]const u8 {
    const data = std.Io.Dir.readFileAlloc(.cwd(), io, path, alloc, .limited(4096)) catch return null;
    const trimmed = std.mem.trim(u8, data, " \t\r\n");
    if (trimmed.len == 0) return null;
    return trimmed;
}

fn readProfileSysfs(io: std.Io, alloc: std.mem.Allocator) ?ProfileState {
    const active = readTrim(io, alloc, platform_profile_path) orelse return null;
    const raw_choices = readTrim(io, alloc, platform_profile_choices_path) orelse return null;

    var choices: std.ArrayList([]const u8) = .empty;
    var iterator = std.mem.tokenizeAny(u8, raw_choices, " \t\r\n");
    while (iterator.next()) |choice| {
        choices.append(alloc, choice) catch return null;
    }
    if (choices.items.len == 0) return null;

    return .{
        .choices = choices.items,
        .active = active,
        .backend = .sysfs,
    };
}

fn readPpdProfiles(
    reader: *dbus.Reader,
    alloc: std.mem.Allocator,
    choices: *std.ArrayList([]const u8),
) !void {
    const end = try reader.beginArray(4);
    while (reader.index < end) {
        const dict_end = try reader.beginArray(8);
        while (reader.index < dict_end) {
            try reader.alignTo(8);
            const key = try reader.readString();
            const signature = try reader.readSignature();
            if (std.mem.eql(u8, key, "Profile") and std.mem.eql(u8, signature, "s")) {
                try choices.append(alloc, try alloc.dupe(u8, try reader.readString()));
            } else {
                try reader.skipValue(signature);
            }
        }
        try reader.finishArray(dict_end);
    }
    try reader.finishArray(end);
}

test "profile next wraps and display names are shared" {
    const profile = ProfileState{
        .choices = &[_][]const u8{ "low-power", "balanced", "performance" },
        .active = "performance",
        .backend = .sysfs,
    };
    try std.testing.expectEqualStrings("low-power", profile.next().?);
    try std.testing.expectEqualStrings("Power saver", profileDisplay("power-saver"));
    try std.testing.expectEqualStrings("Balanced", profileDisplay("balanced"));

    const empty = ProfileState{
        .choices = &.{},
        .active = "",
        .backend = .ppd,
    };
    try std.testing.expect(empty.next() == null);
}

test "battery status and estimate" {
    var battery = Battery{
        .percent = 50,
        .status = .discharging,
        .energy_now = 30_000_000,
        .energy_full = 60_000_000,
        .power_now = 10_000_000,
    };

    try std.testing.expectEqual(@as(?u64, 10_800), battery.estimateSeconds());
    var time_buffer: [32]u8 = undefined;
    try std.testing.expectEqualStrings("3h 00m", battery.timeLabel(&time_buffer));

    battery.status = .charging;
    battery.energy_now = 30_000_000;
    try std.testing.expectEqual(@as(?u64, 10_800), battery.estimateSeconds());
}

test "battery summary falls back to state" {
    const battery = Battery{
        .percent = 100,
        .status = .full,
    };
    var buffer: [64]u8 = undefined;
    try std.testing.expectEqualStrings("Full", battery.summary(&buffer));
}

test "action availability" {
    const actions = Actions{
        .lock = .yes,
        .suspend_system = .challenge,
        .hibernate = .no,
        .reboot = .yes,
        .power_off = .yes,
    };
    try std.testing.expect(Action.lock.availability(actions).available());
    try std.testing.expect(Action.suspend_system.availability(actions).available());
    try std.testing.expect(!Action.hibernate.availability(actions).available());
    try std.testing.expect(Action.reboot.destructive());
    try std.testing.expect(!Action.suspend_system.destructive());
}

test "ppd profile array uses four-byte array alignment" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var body = dbus.Builder{};
    body.putU32(0); // outer array length placeholder at offset 0
    body.putU32(0); // first dict length placeholder at offset 4
    body.alignTo(8);
    const entry_start = body.len;
    body.putString("Profile");
    body.putSignature("s");
    body.putString("power-saver");

    std.mem.writeInt(u32, body.data[4..8], @intCast(body.len - entry_start), .little);
    std.mem.writeInt(u32, body.data[0..4], @intCast(body.len - 4), .little);

    var choices: std.ArrayList([]const u8) = .empty;
    var reader = dbus.Reader{ .data = body.slice() };
    try readPpdProfiles(&reader, alloc, &choices);

    try std.testing.expectEqual(@as(usize, 1), choices.items.len);
    try std.testing.expectEqualStrings("power-saver", choices.items[0]);
}
