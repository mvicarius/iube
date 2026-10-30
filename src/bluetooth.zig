//! Minimal BlueZ client over the system D-Bus.
//!
//! This is read/write state for adapters and devices, not a Bluetooth stack.
//! BlueZ owns the controller; iube calls its documented D-Bus API directly
//! through `dbus.zig`, without linking libdbus.

const std = @import("std");
const dbus = @import("dbus.zig");

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
        });
        reply.deinit();
    }
};

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

fn finishArray(reader: *dbus.Reader, end: usize) !void {
    if (reader.index > end) return error.Protocol;
    if (end - reader.index >= 8) return error.Protocol;
    reader.index = end;
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
