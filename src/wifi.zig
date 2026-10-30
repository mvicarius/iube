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

/// Settings for a new 802-11-wireless profile. `password` is only used when
/// `secured` is true and is never stored outside the transient request body.
pub const NewProfile = struct {
    ssid: []const u8,
    password: []const u8,
    secured: bool,
    uuid: []const u8,
};

const ProfileValue = union(enum) {
    string: []const u8,
    bytes: []const u8,
};

const ProfileEntry = struct {
    key: []const u8,
    value: ProfileValue,
};

const ProfileSection = struct {
    name: []const u8,
    entries: []const ProfileEntry,
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

    /// Create a new NetworkManager profile and activate it in one call.
    ///
    /// The password only lives in the transient D-Bus body. NetworkManager
    /// stores it in the new profile; iube keeps no copy.
    pub fn addAndActivate(
        self: *Client,
        device: Device,
        network: Network,
        password: []const u8,
    ) !void {
        if (network.ssid.len == 0) return error.HiddenNetworkUnsupported;

        var uuid_buffer: [36]u8 = undefined;
        const uuid = makeUuid(self.bus.io, &uuid_buffer);

        var body = dbus.Builder{};
        putNewProfile(&body, .{
            .ssid = network.ssid,
            .password = password,
            .secured = network.secured,
            .uuid = uuid,
        });
        body.putString(device.path);
        body.putString(network.ap_path);

        var reply = try self.bus.call(.{
            .destination = nm,
            .path = nm_path,
            .interface = nm,
            .member = "AddAndActivateConnection",
            .signature = "a{sa{sv}}oo",
            .body = body.slice(),
            .timeout_ms = 15000,
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
        defer reader.finishArray(end) catch {};

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
        try reader.finishArray(end);
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
        try reader.finishArray(end);

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
        try reader.finishArray(end);
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
            try reader.finishArray(inner_end);
        }
        try reader.finishArray(outer_end);
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

/// Writes a complete `a{sa{sv}}` settings dictionary at the start of a fresh
/// body. Exposed for tests; production code calls it through `addAndActivate`.
fn putNewProfile(builder: *dbus.Builder, profile: NewProfile) void {
    const connection = [_]ProfileEntry{
        .{ .key = "id", .value = .{ .string = profileId(profile.ssid) } },
        .{ .key = "uuid", .value = .{ .string = profile.uuid } },
        .{ .key = "type", .value = .{ .string = "802-11-wireless" } },
    };
    const wireless = [_]ProfileEntry{
        .{ .key = "ssid", .value = .{ .bytes = profile.ssid } },
        .{ .key = "mode", .value = .{ .string = "infrastructure" } },
    };
    const security = [_]ProfileEntry{
        .{ .key = "key-mgmt", .value = .{ .string = "wpa-psk" } },
        .{ .key = "psk", .value = .{ .string = profile.password } },
    };

    var sections: [3]ProfileSection = undefined;
    var count: usize = 0;
    sections[count] = .{ .name = "connection", .entries = &connection };
    count += 1;
    sections[count] = .{ .name = "802-11-wireless", .entries = &wireless };
    count += 1;
    if (profile.secured) {
        sections[count] = .{ .name = "802-11-wireless-security", .entries = &security };
        count += 1;
    }

    putSettings(builder, sections[0..count]);
}

/// D-Bus strings must be UTF-8 and cannot contain NUL. The SSID itself is sent
/// as a byte array, but `connection.id` is a human-readable string, so use a
/// safe fallback for arbitrary over-the-air SSID bytes.
fn profileId(ssid: []const u8) []const u8 {
    if (ssid.len == 0) return "iube";
    if (!std.unicode.utf8ValidateSlice(ssid)) return "iube";
    for (ssid) |byte| {
        if (byte < 0x20 or byte == 0x7f) return "iube";
    }
    return ssid;
}

fn putSettings(builder: *dbus.Builder, sections: []const ProfileSection) void {
    var payload = dbus.Builder{};
    for (sections) |section| {
        payload.alignTo(8);
        payload.putString(section.name);
        putEntries(&payload, section.entries);
    }

    builder.putU32(@intCast(payload.len));
    builder.alignTo(8);
    builder.putRaw(payload.slice());
}

fn putEntries(builder: *dbus.Builder, entries: []const ProfileEntry) void {
    var payload = dbus.Builder{};
    for (entries) |entry| {
        payload.alignTo(8);
        payload.putString(entry.key);
        switch (entry.value) {
            .string => |value| {
                payload.putSignature("s");
                payload.putString(value);
            },
            .bytes => |value| {
                payload.putSignature("ay");
                payload.putU32(@intCast(value.len));
                payload.putRaw(value);
            },
        }
    }

    builder.alignTo(4);
    builder.putU32(@intCast(payload.len));
    builder.alignTo(8);
    builder.putRaw(payload.slice());
}

fn makeUuid(io: std.Io, buffer: *[36]u8) []const u8 {
    var bytes: [16]u8 = undefined;
    std.Io.random(io, &bytes);
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;

    const digits = "0123456789abcdef";
    var out: usize = 0;
    for (bytes, 0..) |byte, index| {
        if (index == 4 or index == 6 or index == 8 or index == 10) {
            buffer[out] = '-';
            out += 1;
        }
        buffer[out] = digits[byte >> 4];
        buffer[out + 1] = digits[byte & 0x0f];
        out += 2;
    }
    return buffer[0..36];
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

const ParsedProfile = struct {
    has_connection: bool = false,
    has_wireless: bool = false,
    has_security: bool = false,
    id: []const u8 = "",
    uuid: []const u8 = "",
    connection_type: []const u8 = "",
    ssid: []const u8 = "",
    mode: []const u8 = "",
    key_mgmt: []const u8 = "",
    psk: []const u8 = "",
};

fn parseProfileForTest(data: []const u8) !ParsedProfile {
    var parsed = ParsedProfile{};
    var reader = dbus.Reader{ .data = data };
    const outer_end = try reader.beginArray(8);
    while (reader.index < outer_end) {
        try reader.alignTo(8);
        const section = try reader.readString();
        const inner_end = try reader.beginArray(8);
        while (reader.index < inner_end) {
            try reader.alignTo(8);
            const key = try reader.readString();
            const signature = try reader.readSignature();

            if (std.mem.eql(u8, signature, "s")) {
                const value = try reader.readString();
                if (std.mem.eql(u8, section, "connection")) {
                    if (std.mem.eql(u8, key, "id")) parsed.id = value else if (std.mem.eql(u8, key, "uuid")) parsed.uuid = value else if (std.mem.eql(u8, key, "type")) parsed.connection_type = value else return error.Protocol;
                } else if (std.mem.eql(u8, section, "802-11-wireless")) {
                    if (std.mem.eql(u8, key, "mode")) parsed.mode = value else return error.Protocol;
                } else if (std.mem.eql(u8, section, "802-11-wireless-security")) {
                    if (std.mem.eql(u8, key, "key-mgmt")) parsed.key_mgmt = value else if (std.mem.eql(u8, key, "psk")) parsed.psk = value else return error.Protocol;
                } else {
                    return error.Protocol;
                }
            } else if (std.mem.eql(u8, signature, "ay")) {
                const value = try reader.readByteArray();
                if (std.mem.eql(u8, section, "802-11-wireless") and
                    std.mem.eql(u8, key, "ssid"))
                {
                    parsed.ssid = value;
                } else {
                    return error.Protocol;
                }
            } else {
                return error.Protocol;
            }
        }
        try reader.finishArray(inner_end);

        if (std.mem.eql(u8, section, "connection")) {
            parsed.has_connection = true;
        } else if (std.mem.eql(u8, section, "802-11-wireless")) {
            parsed.has_wireless = true;
        } else if (std.mem.eql(u8, section, "802-11-wireless-security")) {
            parsed.has_security = true;
        } else {
            return error.Protocol;
        }
    }
    try reader.finishArray(outer_end);
    if (reader.index != data.len) return error.Protocol;
    return parsed;
}

test "new secured profile includes ssid and wpa-psk" {
    var body = dbus.Builder{};
    putNewProfile(&body, .{
        .ssid = "Cafe",
        .password = "hunter2",
        .secured = true,
        .uuid = "00112233-4455-6677-8899-aabbccddeeff",
    });

    const parsed = try parseProfileForTest(body.slice());
    try std.testing.expect(parsed.has_connection);
    try std.testing.expect(parsed.has_wireless);
    try std.testing.expect(parsed.has_security);
    try std.testing.expectEqualStrings("Cafe", parsed.id);
    try std.testing.expectEqualStrings("00112233-4455-6677-8899-aabbccddeeff", parsed.uuid);
    try std.testing.expectEqualStrings("802-11-wireless", parsed.connection_type);
    try std.testing.expectEqualStrings("Cafe", parsed.ssid);
    try std.testing.expectEqualStrings("infrastructure", parsed.mode);
    try std.testing.expectEqualStrings("wpa-psk", parsed.key_mgmt);
    try std.testing.expectEqualStrings("hunter2", parsed.psk);
}

test "new open profile omits the security section" {
    var body = dbus.Builder{};
    putNewProfile(&body, .{
        .ssid = "Library",
        .password = "",
        .secured = false,
        .uuid = "00112233-4455-6677-8899-aabbccddeeff",
    });

    const parsed = try parseProfileForTest(body.slice());
    try std.testing.expect(parsed.has_connection);
    try std.testing.expect(parsed.has_wireless);
    try std.testing.expect(!parsed.has_security);
    try std.testing.expectEqualStrings("Library", parsed.ssid);
    try std.testing.expectEqualStrings("", parsed.key_mgmt);
    try std.testing.expectEqualStrings("", parsed.psk);
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
