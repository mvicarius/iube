//! Minimal BlueZ client over the system D-Bus.
//!
//! This is read/write state for adapters and devices, not a Bluetooth stack.
//! BlueZ owns the controller; iube calls its documented D-Bus API directly
//! through `dbus.zig`, without linking libdbus.

const std = @import("std");
const dbus = @import("dbus.zig");
const agent_mod = @import("bluetooth_agent.zig");

pub const pair_timeout_ms = 60_000;

pub const Adapter = struct {
    path: []const u8,
    name: []const u8,
    address: []const u8,
    powered: bool = false,
    discovering: bool = false,
    discoverable: bool = false,
    pairable: bool = false,

    pub fn label(self: Adapter) []const u8 {
        if (self.name.len > 0) return self.name;
        if (self.address.len > 0) return self.address;
        return self.path;
    }
};

pub const Device = struct {
    path: []const u8,
    adapter_path: []const u8,
    name: []const u8,
    address: []const u8,
    paired: bool = false,
    connected: bool = false,
    trusted: bool = false,
    battery: ?u8 = null,
    rssi: ?i16 = null,

    pub fn label(self: Device) []const u8 {
        if (self.name.len > 0) return self.name;
        if (self.address.len > 0) return self.address;
        return self.path;
    }

    pub fn stateLabel(self: Device) []const u8 {
        if (self.connected) return "Connected";
        if (self.paired) return "Paired";
        return "Available";
    }
};

pub const State = struct {
    arena: std.heap.ArenaAllocator,
    adapters: []Adapter,
    devices: []Device,

    pub fn deinit(self: *State) void {
        self.arena.deinit();
    }

    pub fn adapter(self: State) ?Adapter {
        if (self.adapters.len == 0) return null;
        return self.adapters[0];
    }
};

pub const Client = struct {
    bus: dbus.Client,

    pub fn connect(io: std.Io, gpa: std.mem.Allocator) !Client {
        return .{ .bus = try dbus.Client.connectSystem(io, gpa) };
    }

    pub fn deinit(self: *Client) void {
        self.bus.deinit();
    }

    pub fn refresh(self: *Client, gpa: std.mem.Allocator) !State {
        var reply = try self.bus.call(.{
            .destination = "org.bluez",
            .path = "/",
            .interface = "org.freedesktop.DBus.ObjectManager",
            .member = "GetManagedObjects",
        });
        defer reply.deinit();
        return parseManagedObjects(gpa, reply.body);
    }

    pub fn setAdapterPowered(self: *Client, adapter: Adapter, powered: bool) !void {
        var body = dbus.Builder{};
        body.putString("org.bluez.Adapter1");
        body.putString("Powered");
        body.putVariantBool(powered);

        var reply = try self.bus.call(.{
            .destination = "org.bluez",
            .path = adapter.path,
            .interface = "org.freedesktop.DBus.Properties",
            .member = "Set",
            .signature = "ssv",
            .body = body.slice(),
        });
        reply.deinit();
    }

    pub fn setDiscovering(self: *Client, adapter: Adapter, discovering: bool) !void {
        var reply = try self.bus.call(.{
            .destination = "org.bluez",
            .path = adapter.path,
            .interface = "org.bluez.Adapter1",
            .member = if (discovering) "StartDiscovery" else "StopDiscovery",
        });
        reply.deinit();
    }

    pub fn setConnected(self: *Client, device: Device, connected: bool) !void {
        var reply = try self.bus.call(.{
            .destination = "org.bluez",
            .path = device.path,
            .interface = "org.bluez.Device1",
            .member = if (connected) "Connect" else "Disconnect",
            .timeout_ms = 30_000,
        });
        reply.deinit();
    }

    /// Register a short-lived NoInputNoOutput agent and pair `device_path`.
    /// Incoming Agent1 callbacks are answered on the same connection while the
    /// Device1.Pair reply is outstanding.
    pub fn pair(self: *Client, device_path: []const u8) !PairOutcome {
        var agent = agent_mod.Agent{ .client = &self.bus };
        try agent.register();
        defer agent.unregister();

        const serial = try self.bus.sendCall(.{
            .destination = "org.bluez",
            .path = device_path,
            .interface = "org.bluez.Device1",
            .member = "Pair",
            .timeout_ms = pair_timeout_ms,
        });

        while (true) {
            var incoming = self.bus.readIncoming(pair_timeout_ms) catch |err| {
                if (err == error.Timeout) return error.PairTimedOut;
                return err;
            };
            defer incoming.deinit();

            if (incoming.isMethodCall()) {
                try agent.handle(incoming);
                continue;
            }

            const reply_serial = incoming.reply_serial orelse continue;
            if (reply_serial != serial) continue;

            switch (incoming.message_type) {
                dbus.method_return => return .paired,
                dbus.error_reply => {
                    if (agent.passkey_requested or agent.pin_requested) return error.PasskeyRequired;
                    if (agent.cancelled) return error.PairCancelled;
                    if (std.mem.eql(u8, incoming.error_name, "org.bluez.Error.AlreadyExists")) {
                        return .already_paired;
                    }
                    if (std.mem.eql(u8, incoming.error_name, "org.bluez.Error.AuthenticationFailed") or
                        std.mem.eql(u8, incoming.error_name, "org.bluez.Error.AuthenticationRejected") or
                        std.mem.eql(u8, incoming.error_name, "org.bluez.Error.AuthenticationCanceled") or
                        std.mem.eql(u8, incoming.error_name, "org.bluez.Error.AuthenticationTimeout"))
                    {
                        return error.PairRejected;
                    }
                    if (std.mem.eql(u8, incoming.error_name, "org.bluez.Error.NotAvailable")) {
                        return error.DeviceNotAvailable;
                    }
                    if (std.mem.eql(u8, incoming.error_name, "org.bluez.Error.NotReady")) {
                        return error.AdapterNotReady;
                    }
                    if (std.mem.eql(u8, incoming.error_name, "org.bluez.Error.InProgress")) {
                        return error.PairInProgress;
                    }
                    return error.PairFailed;
                },
                else => return error.Protocol,
            }
        }
    }

    pub fn removeDevice(self: *Client, device: Device) !void {
        var body = dbus.Builder{};
        body.putObjectPath(device.path);

        var reply = try self.bus.call(.{
            .destination = "org.bluez",
            .path = device.adapter_path,
            .interface = "org.bluez.Adapter1",
            .member = "RemoveDevice",
            .signature = "o",
            .body = body.slice(),
            .timeout_ms = 30_000,
        });
        reply.deinit();
    }
};

/// Pair without keeping a caller-owned connection open. Used by the UI worker.
pub fn pairDetached(io: std.Io, gpa: std.mem.Allocator, device_path: []const u8) !PairOutcome {
    var client = try Client.connect(io, gpa);
    defer client.deinit();
    return client.pair(device_path);
}

pub const PairOutcome = enum {
    paired,
    already_paired,
};

pub const Resolution = union(enum) {
    found: usize,
    not_found,
    ambiguous,
};

/// Resolve a user-supplied device name or address. Addresses match first, then
/// exact names/paths, then a unique case-insensitive substring of the label.
pub fn resolveDevice(devices: []const Device, query: []const u8) Resolution {
    const trimmed = std.mem.trim(u8, query, " \t");
    if (trimmed.len == 0) return .not_found;

    for (devices, 0..) |device, index| {
        if (std.ascii.eqlIgnoreCase(device.address, trimmed)) return .{ .found = index };
    }
    for (devices, 0..) |device, index| {
        if (std.ascii.eqlIgnoreCase(device.path, trimmed) or
            std.ascii.eqlIgnoreCase(device.name, trimmed) or
            std.ascii.eqlIgnoreCase(device.label(), trimmed))
        {
            return .{ .found = index };
        }
    }

    var match: ?usize = null;
    for (devices, 0..) |device, index| {
        if (std.ascii.findIgnoreCase(device.label(), trimmed) != null or
            std.ascii.findIgnoreCase(device.address, trimmed) != null)
        {
            if (match != null) return .ambiguous;
            match = index;
        }
    }
    return if (match) |index| .{ .found = index } else .not_found;
}

pub const Command = union(enum) {
    pair: []const u8,
    forget: []const u8,
    help,
};

pub const CommandError = error{
    UnknownCommand,
    MissingDevice,
    TooManyArguments,
};

/// Parse the arguments after `iube bluetooth`. The UI is used when there are no
/// arguments, so this only covers `pair`, `forget` and help.
pub fn parseCliCommand(args: []const []const u8) CommandError!Command {
    if (args.len == 0) return error.UnknownCommand;

    const action = args[0];
    if (std.mem.eql(u8, action, "help") or
        std.mem.eql(u8, action, "--help") or
        std.mem.eql(u8, action, "-h"))
    {
        if (args.len != 1) return error.TooManyArguments;
        return .help;
    }
    if (std.mem.eql(u8, action, "pair")) {
        if (args.len < 2) return error.MissingDevice;
        if (args.len > 2) return error.TooManyArguments;
        return .{ .pair = args[1] };
    }
    if (std.mem.eql(u8, action, "forget")) {
        if (args.len < 2) return error.MissingDevice;
        if (args.len > 2) return error.TooManyArguments;
        return .{ .forget = args[1] };
    }
    return error.UnknownCommand;
}

fn parseManagedObjects(gpa: std.mem.Allocator, body: []const u8) !State {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const alloc = arena.allocator();

    var adapters: std.ArrayList(Adapter) = .empty;
    var devices: std.ArrayList(Device) = .empty;
    var reader = dbus.Reader{ .data = body };

    const outer_end = try reader.beginArray(8);
    while (reader.index < outer_end) {
        try reader.alignTo(8);
        const object_path = try reader.readObjectPath();
        const interfaces_end = try reader.beginArray(8);

        var adapter: ?Adapter = null;
        var device: ?Device = null;
        var battery: ?u8 = null;

        while (reader.index < interfaces_end) {
            try reader.alignTo(8);
            const interface = try reader.readString();

            if (std.mem.eql(u8, interface, "org.bluez.Adapter1")) {
                if (adapter == null) {
                    adapter = .{
                        .path = try alloc.dupe(u8, object_path),
                        .name = "",
                        .address = "",
                    };
                }
                try parseAdapterProperties(&reader, alloc, &adapter.?);
            } else if (std.mem.eql(u8, interface, "org.bluez.Device1")) {
                if (device == null) {
                    device = .{
                        .path = try alloc.dupe(u8, object_path),
                        .adapter_path = "",
                        .name = "",
                        .address = "",
                    };
                }
                try parseDeviceProperties(&reader, alloc, &device.?);
            } else if (std.mem.eql(u8, interface, "org.bluez.Battery1")) {
                battery = try parseBatteryProperties(&reader);
            } else {
                const properties_end = try reader.beginArray(8);
                reader.index = properties_end;
            }
        }
        try finishArray(&reader, interfaces_end);

        if (adapter) |value| try adapters.append(alloc, value);
        if (device) |value| {
            var completed = value;
            completed.battery = battery;
            try devices.append(alloc, completed);
        }
    }
    try finishArray(&reader, outer_end);

    const adapter_slice = try adapters.toOwnedSlice(alloc);
    const device_slice = try devices.toOwnedSlice(alloc);
    if (adapter_slice.len > 0) {
        for (device_slice) |*device| {
            if (device.adapter_path.len == 0) device.adapter_path = adapter_slice[0].path;
        }
    }
    std.mem.sort(Device, device_slice, {}, deviceLessThan);

    return .{
        .arena = arena,
        .adapters = adapter_slice,
        .devices = device_slice,
    };
}

fn parseAdapterProperties(reader: *dbus.Reader, alloc: std.mem.Allocator, adapter: *Adapter) !void {
    const end = try reader.beginArray(8);
    while (reader.index < end) {
        try reader.alignTo(8);
        const key = try reader.readString();
        const signature = try reader.readSignature();

        if (std.mem.eql(u8, key, "Alias") or std.mem.eql(u8, key, "Name")) {
            if (std.mem.eql(u8, signature, "s")) {
                const value = try reader.readString();
                if (value.len > 0 and (std.mem.eql(u8, key, "Alias") or adapter.name.len == 0)) {
                    adapter.name = try alloc.dupe(u8, value);
                }
            } else {
                try reader.skipValue(signature);
            }
        } else if (std.mem.eql(u8, key, "Address") and std.mem.eql(u8, signature, "s")) {
            adapter.address = try alloc.dupe(u8, try reader.readString());
        } else if (std.mem.eql(u8, key, "Powered") and std.mem.eql(u8, signature, "b")) {
            adapter.powered = try reader.readBool();
        } else if (std.mem.eql(u8, key, "Discovering") and std.mem.eql(u8, signature, "b")) {
            adapter.discovering = try reader.readBool();
        } else if (std.mem.eql(u8, key, "Discoverable") and std.mem.eql(u8, signature, "b")) {
            adapter.discoverable = try reader.readBool();
        } else if (std.mem.eql(u8, key, "Pairable") and std.mem.eql(u8, signature, "b")) {
            adapter.pairable = try reader.readBool();
        } else {
            try reader.skipValue(signature);
        }
    }
    try finishArray(reader, end);
}

fn parseDeviceProperties(reader: *dbus.Reader, alloc: std.mem.Allocator, device: *Device) !void {
    const end = try reader.beginArray(8);
    while (reader.index < end) {
        try reader.alignTo(8);
        const key = try reader.readString();
        const signature = try reader.readSignature();

        if (std.mem.eql(u8, key, "Alias") or std.mem.eql(u8, key, "Name")) {
            if (std.mem.eql(u8, signature, "s")) {
                const value = try reader.readString();
                if (value.len > 0 and (std.mem.eql(u8, key, "Alias") or device.name.len == 0)) {
                    device.name = try alloc.dupe(u8, value);
                }
            } else {
                try reader.skipValue(signature);
            }
        } else if (std.mem.eql(u8, key, "Address") and std.mem.eql(u8, signature, "s")) {
            device.address = try alloc.dupe(u8, try reader.readString());
        } else if (std.mem.eql(u8, key, "Adapter") and std.mem.eql(u8, signature, "o")) {
            device.adapter_path = try alloc.dupe(u8, try reader.readObjectPath());
        } else if (std.mem.eql(u8, key, "Paired") and std.mem.eql(u8, signature, "b")) {
            device.paired = try reader.readBool();
        } else if (std.mem.eql(u8, key, "Connected") and std.mem.eql(u8, signature, "b")) {
            device.connected = try reader.readBool();
        } else if (std.mem.eql(u8, key, "Trusted") and std.mem.eql(u8, signature, "b")) {
            device.trusted = try reader.readBool();
        } else if (std.mem.eql(u8, key, "RSSI") and std.mem.eql(u8, signature, "n")) {
            device.rssi = try reader.readI16();
        } else {
            try reader.skipValue(signature);
        }
    }
    try finishArray(reader, end);
}

fn parseBatteryProperties(reader: *dbus.Reader) !?u8 {
    var percentage: ?u8 = null;
    const end = try reader.beginArray(8);
    while (reader.index < end) {
        try reader.alignTo(8);
        const key = try reader.readString();
        const signature = try reader.readSignature();

        if (std.mem.eql(u8, key, "Percentage") and std.mem.eql(u8, signature, "y")) {
            percentage = try reader.readU8();
        } else {
            try reader.skipValue(signature);
        }
    }
    try finishArray(reader, end);
    return percentage;
}

fn deviceRank(device: Device) u2 {
    if (device.connected) return 0;
    if (device.paired) return 1;
    return 2;
}

fn deviceLessThan(_: void, a: Device, b: Device) bool {
    const rank_a = deviceRank(a);
    const rank_b = deviceRank(b);
    if (rank_a != rank_b) return rank_a < rank_b;
    return std.ascii.lessThanIgnoreCase(a.label(), b.label());
}

fn finishArray(reader: *dbus.Reader, end: usize) !void {
    if (reader.index > end) return error.Protocol;
    if (end - reader.index >= 8) return error.Protocol;
    reader.index = end;
}

test "devices sort connected then paired then new" {
    var devices = [_]Device{
        .{ .path = "/new", .adapter_path = "", .name = "New", .address = "" },
        .{ .path = "/paired", .adapter_path = "", .name = "Paired", .address = "", .paired = true },
        .{ .path = "/connected", .adapter_path = "", .name = "Connected", .address = "", .paired = true, .connected = true },
    };
    std.mem.sort(Device, &devices, {}, deviceLessThan);
    try std.testing.expectEqualStrings("Connected", devices[0].name);
    try std.testing.expectEqualStrings("Paired", devices[1].name);
    try std.testing.expectEqualStrings("New", devices[2].name);
}

test "device state and label" {
    const device = Device{
        .path = "/org/bluez/hci0/dev_TEST",
        .adapter_path = "/org/bluez/hci0",
        .name = "Test device",
        .address = "00:11:22:33:44:55",
        .paired = true,
        .connected = true,
        .battery = 55,
    };

    try std.testing.expectEqualStrings("Connected", device.stateLabel());
    try std.testing.expectEqualStrings("Test device", device.label());
}

test "resolve device by address, name and unique substring" {
    const devices = [_]Device{
        .{
            .path = "/org/bluez/hci0/dev_AA",
            .adapter_path = "/org/bluez/hci0",
            .name = "Keyboard",
            .address = "AA:BB:CC:DD:EE:01",
        },
        .{
            .path = "/org/bluez/hci0/dev_BB",
            .adapter_path = "/org/bluez/hci0",
            .name = "Headset",
            .address = "AA:BB:CC:DD:EE:02",
        },
    };

    try std.testing.expectEqual(Resolution{ .found = 0 }, resolveDevice(&devices, "aa:bb:cc:dd:ee:01"));
    try std.testing.expectEqual(Resolution{ .found = 1 }, resolveDevice(&devices, "headset"));
    try std.testing.expectEqual(Resolution{ .found = 1 }, resolveDevice(&devices, "HEADSET"));
    try std.testing.expectEqual(Resolution{ .found = 0 }, resolveDevice(&devices, "keyb"));
    try std.testing.expectEqual(Resolution.not_found, resolveDevice(&devices, "mouse"));
    try std.testing.expectEqual(Resolution.not_found, resolveDevice(&devices, "   "));

    const duplicate = [_]Device{
        .{ .path = "/a", .adapter_path = "", .name = "Headset One", .address = "AA:00:00:00:00:01" },
        .{ .path = "/b", .adapter_path = "", .name = "Headset Two", .address = "AA:00:00:00:00:02" },
    };
    try std.testing.expectEqual(Resolution.ambiguous, resolveDevice(&duplicate, "headset"));
}

test "parse bluetooth cli commands" {
    const pair_args = [_][]const u8{"pair"};
    try std.testing.expectError(error.MissingDevice, parseCliCommand(&pair_args));

    const pair_device = [_][]const u8{ "pair", "Keyboard" };
    const command = try parseCliCommand(&pair_device);
    try std.testing.expectEqualStrings("Keyboard", command.pair);

    const forget_device = [_][]const u8{ "forget", "AA:BB:CC:DD:EE:01" };
    const forget = try parseCliCommand(&forget_device);
    try std.testing.expectEqualStrings("AA:BB:CC:DD:EE:01", forget.forget);

    const extra = [_][]const u8{ "pair", "Keyboard", "extra" };
    try std.testing.expectError(error.TooManyArguments, parseCliCommand(&extra));

    const unknown = [_][]const u8{"connect"};
    try std.testing.expectError(error.UnknownCommand, parseCliCommand(&unknown));

    const help = [_][]const u8{"help"};
    try std.testing.expectEqual(Command.help, try parseCliCommand(&help));
}
