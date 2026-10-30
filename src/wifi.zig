//! Minimal Wi-Fi client over NetworkManager's D-Bus API.
//!
//! NetworkManager owns the interface and supplicant. iube only reads the
//! wireless device and access-point objects and asks NetworkManager to scan,
//! connect to a saved profile, disconnect, or toggle wireless.

const std = @import("std");
const dbus = @import("dbus.zig");

const nm = "org.freedesktop.NetworkManager";
const nm_path = "/org/freedesktop/NetworkManager";
const nm_device = "org.freedesktop.NetworkManager.Device";
const nm_wireless = "org.freedesktop.NetworkManager.Device.Wireless";
const nm_ap = "org.freedesktop.NetworkManager.AccessPoint";
const nm_settings = "org.freedesktop.NetworkManager.Settings";
const properties = "org.freedesktop.DBus.Properties";

const ap_flag_privacy: u32 = 0x1;

pub const Device = struct {
    path: []const u8,
    interface: []const u8,
    state: u32,
    active_ap: []const u8,
};

pub const Network = struct {
    ap_path: []const u8,
    ssid: []const u8,
    strength: u8,
    frequency: u32,
    secured: bool,
    connected: bool,

    pub fn label(self: Network) []const u8 {
        return if (self.ssid.len > 0) self.ssid else "(hidden)";
    }

    pub fn bandLabel(self: Network) ?[]const u8 {
        if (self.frequency >= 5925) return "6 GHz";
        if (self.frequency >= 4900) return "5 GHz";
        if (self.frequency >= 2400 and self.frequency < 2500) return "2.4 GHz";
        return null;
    }
};

pub const Saved = struct {
    path: []const u8,
    ssid: []const u8,
};

pub const State = struct {
    arena: std.heap.ArenaAllocator,
    device: ?Device,
    networks: []Network,
    saved: []Saved,
    wireless_enabled: bool,

    pub fn deinit(self: *State) void {
        self.arena.deinit();
    }

    pub fn findSaved(self: State, ssid: []const u8) ?Saved {
        for (self.saved) |saved| {
            if (std.mem.eql(u8, saved.ssid, ssid)) return saved;
        }
        return null;
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
        var arena = std.heap.ArenaAllocator.init(gpa);
        errdefer arena.deinit();
        const alloc = arena.allocator();

        const wireless_enabled = self.getBool(nm_path, nm, "WirelessEnabled") catch false;
        const device = try self.findWifiDevice(alloc);
        if (device == null) {
            return .{
                .arena = arena,
                .device = null,
                .networks = &.{},
                .saved = &.{},
                .wireless_enabled = wireless_enabled,
            };
        }

        const networks = try self.fetchNetworks(alloc, device.?);
        const saved = try self.fetchSaved(alloc);

        return .{
            .arena = arena,
            .device = device,
            .networks = networks,
            .saved = saved,
            .wireless_enabled = wireless_enabled,
        };
    }

    pub fn requestScan(self: *Client, device: Device) !void {
        var body = dbus.Builder{};
        body.putU32(0); // empty a{sv}
        body.alignTo(8);

        var reply = try self.bus.call(.{
            .destination = nm,
            .path = device.path,
            .interface = nm_wireless,
            .member = "RequestScan",
            .signature = "a{sv}",
            .body = body.slice(),
        });
        reply.deinit();
    }

    pub fn setWirelessEnabled(self: *Client, enabled: bool) !void {
        var body = dbus.Builder{};
        body.putString(nm);
        body.putString("WirelessEnabled");
        body.putVariantBool(enabled);

        var reply = try self.bus.call(.{
            .destination = nm,
            .path = nm_path,
            .interface = properties,
            .member = "Set",
            .signature = "ssv",
            .body = body.slice(),
        });
        reply.deinit();
    }

    pub fn activateSaved(
        self: *Client,
        device: Device,
        network: Network,
        saved: Saved,
    ) !void {
        var body = dbus.Builder{};
        body.putString(saved.path);
        body.putString(device.path);
        body.putString(network.ap_path);

        var reply = try self.bus.call(.{
            .destination = nm,
            .path = nm_path,
            .interface = nm,
            .member = "ActivateConnection",
            .signature = "ooo",
            .body = body.slice(),
        });
        reply.deinit();
    }

    pub fn disconnect(self: *Client, device: Device) !void {
        var reply = try self.bus.call(.{
            .destination = nm,
            .path = device.path,
            .interface = nm_device,
            .member = "Disconnect",
        });
        reply.deinit();
    }

    fn findWifiDevice(self: *Client, alloc: std.mem.Allocator) !?Device {
        var reply = try self.bus.call(.{
            .destination = nm,
            .path = nm_path,
            .interface = nm,
            .member = "GetDevices",
        });
        defer reply.deinit();

        var reader = dbus.Reader{ .data = reply.body };
        const end = try reader.beginArray(4);
        defer finishArray(&reader, end) catch {};

        while (reader.index < end) {
            const path = try alloc.dupe(u8, try reader.readObjectPath());
            const device_type = self.getU32(path, nm_device, "DeviceType") catch continue;
            if (device_type != 2) continue;

            const interface = self.getStringDup(alloc, path, nm_device, "Interface") catch "";
            const state = self.getU32(path, nm_device, "State") catch 0;
            const active_ap = self.getObjectPathDup(alloc, path, nm_wireless, "ActiveAccessPoint") catch
                try alloc.dupe(u8, "/");

            return .{
                .path = path,
                .interface = interface,
                .state = state,
                .active_ap = active_ap,
            };
        }
        return null;
    }

    fn fetchNetworks(self: *Client, alloc: std.mem.Allocator, device: Device) ![]Network {
        var reply = try self.bus.call(.{
            .destination = nm,
            .path = device.path,
            .interface = nm_wireless,
            .member = "GetAllAccessPoints",
        });
        defer reply.deinit();

        var paths: std.ArrayList([]const u8) = .empty;
        var reader = dbus.Reader{ .data = reply.body };
        const end = try reader.beginArray(4);
        while (reader.index < end) {
            try paths.append(alloc, try alloc.dupe(u8, try reader.readObjectPath()));
        }
        try finishArray(&reader, end);
        defer paths.deinit(alloc);

        var networks: std.ArrayList(Network) = .empty;
        for (paths.items) |path| {
            const network = self.fetchNetwork(alloc, device, path) catch continue;
            try networks.append(alloc, network);
        }

        std.mem.sort(Network, networks.items, {}, networkLessThan);

        var deduped: std.ArrayList(Network) = .empty;
        for (networks.items) |network| {
            var duplicate = false;
            for (deduped.items) |existing| {
                if (std.mem.eql(u8, existing.ssid, network.ssid)) {
                    duplicate = true;
                    break;
                }
            }
            if (!duplicate) try deduped.append(alloc, network);
        }
        return try deduped.toOwnedSlice(alloc);
    }

    fn fetchNetwork(
        self: *Client,
        alloc: std.mem.Allocator,
        device: Device,
        ap_path: []const u8,
    ) !Network {
        var body = dbus.Builder{};
        body.putString(nm_ap);

        var reply = try self.bus.call(.{
            .destination = nm,
            .path = ap_path,
            .interface = properties,
            .member = "GetAll",
            .signature = "s",
            .body = body.slice(),
        });
        defer reply.deinit();

        var ssid: []const u8 = "";
        var strength: u8 = 0;
        var frequency: u32 = 0;
        var flags: u32 = 0;
        var wpa_flags: u32 = 0;
        var rsn_flags: u32 = 0;

        var reader = dbus.Reader{ .data = reply.body };
        const end = try reader.beginArray(8);
        while (reader.index < end) {
            try reader.alignTo(8);
            const key = try reader.readString();
            const signature = try reader.readSignature();

            if (std.mem.eql(u8, key, "Ssid") and std.mem.eql(u8, signature, "ay")) {
                ssid = try alloc.dupe(u8, try reader.readByteArray());
            } else if (std.mem.eql(u8, key, "Strength") and std.mem.eql(u8, signature, "y")) {
                strength = try reader.readU8();
            } else if (std.mem.eql(u8, key, "Frequency") and std.mem.eql(u8, signature, "u")) {
                frequency = try reader.readU32();
            } else if (std.mem.eql(u8, key, "Flags") and std.mem.eql(u8, signature, "u")) {
                flags = try reader.readU32();
            } else if (std.mem.eql(u8, key, "WpaFlags") and std.mem.eql(u8, signature, "u")) {
                wpa_flags = try reader.readU32();
            } else if (std.mem.eql(u8, key, "RsnFlags") and std.mem.eql(u8, signature, "u")) {
                rsn_flags = try reader.readU32();
            } else {
                try reader.skipValue(signature);
            }
        }
        try finishArray(&reader, end);

        return .{
            .ap_path = try alloc.dupe(u8, ap_path),
            .ssid = ssid,
            .strength = strength,
            .frequency = frequency,
            .secured = (flags & ap_flag_privacy) != 0 or wpa_flags != 0 or rsn_flags != 0,
            .connected = std.mem.eql(u8, ap_path, device.active_ap),
        };
    }

    fn fetchSaved(self: *Client, alloc: std.mem.Allocator) ![]Saved {
        var reply = try self.bus.call(.{
            .destination = nm,
            .path = nm_path ++ "/Settings",
            .interface = nm_settings,
            .member = "ListConnections",
        });
        defer reply.deinit();

        var paths: std.ArrayList([]const u8) = .empty;
        var reader = dbus.Reader{ .data = reply.body };
        const end = try reader.beginArray(4);
        while (reader.index < end) {
            try paths.append(alloc, try alloc.dupe(u8, try reader.readObjectPath()));
        }
        try finishArray(&reader, end);
        defer paths.deinit(alloc);

        var saved: std.ArrayList(Saved) = .empty;
        for (paths.items) |path| {
            const ssid = self.fetchSavedSsid(alloc, path) catch continue;
            if (ssid.len == 0) continue;
            try saved.append(alloc, .{ .path = path, .ssid = ssid });
        }
        return try saved.toOwnedSlice(alloc);
    }

    fn fetchSavedSsid(self: *Client, alloc: std.mem.Allocator, path: []const u8) ![]const u8 {
        var reply = try self.bus.call(.{
            .destination = nm,
            .path = path,
            .interface = "org.freedesktop.NetworkManager.Settings.Connection",
            .member = "GetSettings",
        });
        defer reply.deinit();

        var ssid: []const u8 = "";
        var reader = dbus.Reader{ .data = reply.body };
        const outer_end = try reader.beginArray(8);
        while (reader.index < outer_end) {
            try reader.alignTo(8);
            const section = try reader.readString();
            const inner_end = try reader.beginArray(8);
            while (reader.index < inner_end) {
                try reader.alignTo(8);
                const key = try reader.readString();
                const signature = try reader.readSignature();

                if (std.mem.eql(u8, section, "802-11-wireless") and
                    std.mem.eql(u8, key, "ssid") and
                    std.mem.eql(u8, signature, "ay"))
                {
                    ssid = try alloc.dupe(u8, try reader.readByteArray());
                } else {
                    try reader.skipValue(signature);
                }
            }
            try finishArray(&reader, inner_end);
        }
        try finishArray(&reader, outer_end);
        return ssid;
    }

    fn getU32(self: *Client, path: []const u8, interface: []const u8, name: []const u8) !u32 {
        var reader = try self.getProperty(path, interface, name);
        defer reader.deinit();
        if (!std.mem.eql(u8, try reader.reader.readSignature(), "u")) return error.Protocol;
        return reader.reader.readU32();
    }

    fn getStringDup(
        self: *Client,
        alloc: std.mem.Allocator,
        path: []const u8,
        interface: []const u8,
        name: []const u8,
    ) ![]const u8 {
        var reader = try self.getProperty(path, interface, name);
        defer reader.deinit();
        if (!std.mem.eql(u8, try reader.reader.readSignature(), "s")) return error.Protocol;
        return alloc.dupe(u8, try reader.reader.readString());
    }

    fn getObjectPathDup(
        self: *Client,
        alloc: std.mem.Allocator,
        path: []const u8,
        interface: []const u8,
        name: []const u8,
    ) ![]const u8 {
        var reader = try self.getProperty(path, interface, name);
        defer reader.deinit();
        if (!std.mem.eql(u8, try reader.reader.readSignature(), "o")) return error.Protocol;
        return alloc.dupe(u8, try reader.reader.readString());
    }

    fn getBool(self: *Client, path: []const u8, interface: []const u8, name: []const u8) !bool {
        var reader = try self.getProperty(path, interface, name);
        defer reader.deinit();
        if (!std.mem.eql(u8, try reader.reader.readSignature(), "b")) return error.Protocol;
        return reader.reader.readBool();
    }

    const PropertyReader = struct {
        reply: dbus.Reply,
        reader: dbus.Reader,

        fn deinit(self: *PropertyReader) void {
            self.reply.deinit();
        }
    };

    fn getProperty(
        self: *Client,
        path: []const u8,
        interface: []const u8,
        name: []const u8,
    ) !PropertyReader {
        var body = dbus.Builder{};
        body.putString(interface);
        body.putString(name);

        const reply = try self.bus.call(.{
            .destination = nm,
            .path = path,
            .interface = properties,
            .member = "Get",
            .signature = "ss",
            .body = body.slice(),
        });
        return .{ .reply = reply, .reader = .{ .data = reply.body } };
    }
};

fn finishArray(reader: *dbus.Reader, end: usize) !void {
    if (reader.index > end) return error.Protocol;
    if (end - reader.index >= 8) return error.Protocol;
    reader.index = end;
}

fn networkLessThan(_: void, a: Network, b: Network) bool {
    if (a.connected != b.connected) return a.connected;
    if (a.strength != b.strength) return a.strength > b.strength;
    return std.ascii.lessThanIgnoreCase(a.label(), b.label());
}

test "networks sort connected then strongest" {
    var networks = [_]Network{
        .{ .ap_path = "/weak", .ssid = "Weak", .strength = 20, .frequency = 0, .secured = false, .connected = false },
        .{ .ap_path = "/strong", .ssid = "Strong", .strength = 80, .frequency = 0, .secured = true, .connected = false },
        .{ .ap_path = "/connected", .ssid = "Connected", .strength = 40, .frequency = 0, .secured = true, .connected = true },
    };
    std.mem.sort(Network, &networks, {}, networkLessThan);
    try std.testing.expectEqualStrings("Connected", networks[0].ssid);
    try std.testing.expectEqualStrings("Strong", networks[1].ssid);
    try std.testing.expectEqualStrings("Weak", networks[2].ssid);
}

test "network label falls back to hidden" {
    const hidden = Network{
        .ap_path = "/hidden",
        .ssid = "",
        .strength = 0,
        .frequency = 0,
        .secured = false,
        .connected = false,
    };
    try std.testing.expectEqualStrings("(hidden)", hidden.label());
}

test "network band labels" {
    const sample = Network{
        .ap_path = "/ap",
        .ssid = "Test",
        .strength = 0,
        .frequency = 2437,
        .secured = false,
        .connected = false,
    };

    var network = sample;
    try std.testing.expectEqualStrings("2.4 GHz", network.bandLabel().?);
    network.frequency = 5540;
    try std.testing.expectEqualStrings("5 GHz", network.bandLabel().?);
    network.frequency = 6115;
    try std.testing.expectEqualStrings("6 GHz", network.bandLabel().?);
    network.frequency = 0;
    try std.testing.expect(network.bandLabel() == null);
}
