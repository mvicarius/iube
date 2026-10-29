//! Minimal PulseAudio native-protocol client.
//!
//! iube does not link libpulse. This module speaks the small part of the
//! PulseAudio native protocol needed to list output/input devices, change their
//! volume or mute state, and choose the default device. Both PulseAudio and
//! `pipewire-pulse` expose the same socket, so the same client drives the two
//! common desktop audio stacks.
//!
//! We negotiate protocol version 12 on purpose: it is old enough that sink and
//! source records stop after the simple fields we need, with no proplists,
//! ports or format lists to skip. Every command used here exists in that
//! version.

const std = @import("std");

pub const pa_volume_norm: u32 = 0x10000;

const protocol_version: u32 = 12;
const max_packet = 1024 * 1024;
const read_timeout_ms = 2000;

const tag = struct {
    const string = 't';
    const string_null = 'N';
    const u32_value = 'L';
    const sample_spec = 'a';
    const arbitrary = 'x';
    const boolean_true = '1';
    const boolean_false = '0';
    const usec = 'U';
    const channel_map = 'm';
    const cvolume = 'v';
};

const command = struct {
    const error_reply = 0;
    const reply = 2;
    const auth = 8;
    const set_client_name = 9;
    const get_server_info = 20;
    const get_sink_info_list = 22;
    const get_source_info_list = 24;
    const set_sink_volume = 36;
    const set_source_volume = 38;
    const set_sink_mute = 39;
    const set_source_mute = 40;
    const set_default_sink = 44;
    const set_default_source = 45;
};

pub const Env = struct {
    xdg_runtime_dir: ?[]const u8 = null,
    home: ?[]const u8 = null,
    xdg_config_home: ?[]const u8 = null,
};

pub const Kind = enum {
    sink,
    source,
};

pub const Device = struct {
    kind: Kind,
    index: u32,
    name: []const u8,
    description: []const u8,
    channels: u8,
    volume: u32,
    mute: bool,
    is_default: bool,

    pub fn label(self: Device) []const u8 {
        if (self.description.len > 0) return self.description;
        return self.name;
    }

    pub fn percent(self: Device) u8 {
        const scaled = @as(u64, self.volume) * 100 + pa_volume_norm / 2;
        return @intCast(@min(scaled / pa_volume_norm, 150));
    }
};

pub const State = struct {
    arena: std.heap.ArenaAllocator,
    sinks: []Device,
    sources: []Device,
    default_sink: ?[]const u8,
    default_source: ?[]const u8,

    pub fn deinit(self: *State) void {
        self.arena.deinit();
    }

    pub fn devices(self: State, kind: Kind) []Device {
        return switch (kind) {
            .sink => self.sinks,
            .source => self.sources,
        };
    }
};

pub const Client = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    stream: std.Io.net.Stream,
    next_tag: u32 = 1,

    pub fn connect(io: std.Io, gpa: std.mem.Allocator, env: Env) !Client {
        var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const socket_path = try runtimePath(&path_buffer, env);
        const address = try std.Io.net.UnixAddress.init(socket_path);
        const stream = try address.connect(io);
        errdefer stream.close(io);

        var client = Client{
            .io = io,
            .gpa = gpa,
            .stream = stream,
        };
        try client.handshake(env);
        return client;
    }

    pub fn deinit(self: *Client) void {
        self.stream.close(self.io);
    }

    /// Read the live device lists. The returned `State` owns all strings and
    /// must be deinitialized by the caller.
    pub fn refresh(self: *Client, gpa: std.mem.Allocator) !State {
        var arena = std.heap.ArenaAllocator.init(gpa);
        errdefer arena.deinit();
        const alloc = arena.allocator();

        const server = try self.fetchServerInfo(alloc);
        const sinks = try self.fetchDevices(alloc, .sink, server.default_sink);
        const sources = try self.fetchDevices(alloc, .source, server.default_source);

        return .{
            .arena = arena,
            .sinks = sinks,
            .sources = sources,
            .default_sink = server.default_sink,
            .default_source = server.default_source,
        };
    }

    pub fn setVolumePercent(self: *Client, device: Device, percent: u8) !void {
        const clamped = @min(@as(u32, percent), 150);
        const volume: u32 = @intCast((@as(u64, clamped) * pa_volume_norm + 50) / 100);
        try self.setVolume(device, volume);
    }

    pub fn setVolume(self: *Client, device: Device, volume: u32) !void {
        var builder = Builder{};
        const cmd: u32 = if (device.kind == .sink) command.set_sink_volume else command.set_source_volume;
        const packet_tag = self.startCommand(&builder, cmd);
        builder.putU32(device.index);
        builder.putNullString();
        builder.putCVolume(device.channels, volume);
        try self.send(&builder);
        var reply = try self.receiveReply(packet_tag);
        reply.deinit();
    }

    pub fn toggleMute(self: *Client, device: Device) !void {
        try self.setMute(device, !device.mute);
    }

    pub fn setMute(self: *Client, device: Device, mute: bool) !void {
        var builder = Builder{};
        const cmd: u32 = if (device.kind == .sink) command.set_sink_mute else command.set_source_mute;
        const packet_tag = self.startCommand(&builder, cmd);
        builder.putU32(device.index);
        builder.putNullString();
        builder.putBool(mute);
        try self.send(&builder);
        var reply = try self.receiveReply(packet_tag);
        reply.deinit();
    }

    pub fn setDefault(self: *Client, device: Device) !void {
        var builder = Builder{};
        const cmd: u32 = if (device.kind == .sink) command.set_default_sink else command.set_default_source;
        const packet_tag = self.startCommand(&builder, cmd);
        builder.putString(device.name);
        try self.send(&builder);
        var reply = try self.receiveReply(packet_tag);
        reply.deinit();
    }

    const ServerInfo = struct {
        default_sink: ?[]const u8,
        default_source: ?[]const u8,
    };

    fn fetchServerInfo(self: *Client, alloc: std.mem.Allocator) !ServerInfo {
        var builder = Builder{};
        const packet_tag = self.startCommand(&builder, command.get_server_info);
        try self.send(&builder);

        var reply = try self.receiveReply(packet_tag);
        defer reply.deinit();

        _ = try reply.reader.getString();
        _ = try reply.reader.getString();
        _ = try reply.reader.getString();
        _ = try reply.reader.getString();
        _ = try reply.reader.getSampleSpec();
        const default_sink = try reply.reader.getString();
        const default_source = try reply.reader.getString();

        return .{
            .default_sink = if (default_sink) |name| try alloc.dupe(u8, name) else null,
            .default_source = if (default_source) |name| try alloc.dupe(u8, name) else null,
        };
    }

    fn fetchDevices(
        self: *Client,
        alloc: std.mem.Allocator,
        kind: Kind,
        default_name: ?[]const u8,
    ) ![]Device {
        var builder = Builder{};
        const cmd: u32 = if (kind == .sink) command.get_sink_info_list else command.get_source_info_list;
        const packet_tag = self.startCommand(&builder, cmd);
        try self.send(&builder);

        var reply = try self.receiveReply(packet_tag);
        defer reply.deinit();

        var devices: std.ArrayList(Device) = .empty;
        const reader = &reply.reader;

        while (!reader.eof()) {
            const index = try reader.getU32();
            const name = (try reader.getString()) orelse "";
            const description = (try reader.getString()) orelse "";
            _ = try reader.getSampleSpec();
            _ = try reader.getChannelMap();
            _ = try reader.getU32();
            const cvolume = try reader.getCVolume();
            const mute = try reader.getBool();
            const monitor_index = try reader.getU32();
            _ = try reader.getString();
            _ = try reader.getUsec();
            _ = try reader.getString();
            _ = try reader.getU32();

            // PulseAudio exposes every sink as a monitor source too. The input
            // list is about real capture devices, so leave those out for now.
            if (kind == .source and monitor_index != std.math.maxInt(u32)) continue;

            const is_default = if (default_name) |default| std.mem.eql(u8, name, default) else false;
            try devices.append(alloc, .{
                .kind = kind,
                .index = index,
                .name = try alloc.dupe(u8, name),
                .description = try alloc.dupe(u8, description),
                .channels = if (cvolume.channels > 0) cvolume.channels else 1,
                .volume = cvolume.volume,
                .mute = mute,
                .is_default = is_default,
            });
        }

        return try devices.toOwnedSlice(alloc);
    }

    fn handshake(self: *Client, env: Env) !void {
        var cookie: [256]u8 = @splat(0);
        if (cookiePath(&cookie, env)) |path| {
            const data = std.Io.Dir.readFileAlloc(
                .cwd(),
                self.io,
                path,
                self.gpa,
                .limited(cookie.len),
            ) catch null;
            if (data) |bytes| {
                defer self.gpa.free(bytes);
                const count = @min(bytes.len, cookie.len);
                @memcpy(cookie[0..count], bytes[0..count]);
            }
        }

        var builder = Builder{};
        const auth_tag = self.startCommand(&builder, command.auth);
        builder.putU32(protocol_version);
        builder.putArbitrary(&cookie);
        try self.send(&builder);
        var auth_reply = try self.receiveReply(auth_tag);
        defer auth_reply.deinit();
        _ = try auth_reply.reader.getU32();

        builder = Builder{};
        const name_tag = self.startCommand(&builder, command.set_client_name);
        builder.putString("iube");
        try self.send(&builder);
        var name_reply = try self.receiveReply(name_tag);
        name_reply.deinit();
    }

    fn startCommand(self: *Client, builder: *Builder, cmd: u32) u32 {
        const packet_tag = self.next_tag;
        self.next_tag +%= 1;
        builder.putU32(cmd);
        builder.putU32(packet_tag);
        return packet_tag;
    }

    fn send(self: *Client, builder: *Builder) !void {
        var header: [20]u8 = @splat(0);
        std.mem.writeInt(u32, header[0..4], @intCast(builder.len), .big);
        std.mem.writeInt(u32, header[4..8], 0xffffffff, .big);

        var write_buffer: [256]u8 = undefined;
        var writer = self.stream.writer(self.io, &write_buffer);
        const interface = &writer.interface;
        try interface.writeAll(&header);
        try interface.writeAll(builder.slice());
        try interface.flush();
    }

    fn receiveReply(self: *Client, expected_tag: u32) !Reply {
        var header: [20]u8 = undefined;
        try self.readExact(&header);

        const length = std.mem.readInt(u32, header[0..4], .big);
        if (length > max_packet) return error.PacketTooLarge;

        const data = try self.gpa.alloc(u8, length);
        var keep = false;
        defer if (!keep) self.gpa.free(data);
        try self.readExact(data);

        var reply = Reply{
            .gpa = self.gpa,
            .data = data,
            .reader = .{ .data = data },
        };

        const cmd = try reply.reader.getU32();
        const packet_tag = try reply.reader.getU32();

        if (cmd == command.error_reply) {
            const code = try reply.reader.getU32();
            return switch (code) {
                1 => error.AccessDenied,
                5 => error.NoSuchDevice,
                else => error.ServerError,
            };
        }
        if (cmd != command.reply or packet_tag != expected_tag) return error.Protocol;

        keep = true;
        return reply;
    }

    fn readExact(self: *Client, buffer: []u8) !void {
        var filled: usize = 0;
        while (filled < buffer.len) {
            var poll_fds = [_]std.posix.pollfd{.{
                .fd = self.stream.socket.handle,
                .events = std.posix.POLL.IN,
                .revents = 0,
            }};
            const ready = try std.posix.poll(&poll_fds, read_timeout_ms);
            if (ready == 0) return error.Timeout;
            if ((poll_fds[0].revents & (std.posix.POLL.IN | std.posix.POLL.HUP | std.posix.POLL.ERR)) == 0) {
                return error.ConnectionClosed;
            }

            const count = try std.posix.read(self.stream.socket.handle, buffer[filled..]);
            if (count == 0) return error.ConnectionClosed;
            filled += count;
        }
    }
};

const CVolume = struct {
    channels: u8,
    volume: u32,
};

const SampleSpec = struct {
    channels: u8,
};

const Reply = struct {
    gpa: std.mem.Allocator,
    data: []u8,
    reader: TagReader,

    fn deinit(self: *Reply) void {
        self.gpa.free(self.data);
    }
};

const Builder = struct {
    data: [4096]u8 = undefined,
    len: usize = 0,

    fn slice(self: *const Builder) []const u8 {
        return self.data[0..self.len];
    }

    fn putByte(self: *Builder, value: u8) void {
        std.debug.assert(self.len < self.data.len);
        self.data[self.len] = value;
        self.len += 1;
    }

    fn putRaw(self: *Builder, bytes: []const u8) void {
        std.debug.assert(self.len + bytes.len <= self.data.len);
        @memcpy(self.data[self.len .. self.len + bytes.len], bytes);
        self.len += bytes.len;
    }

    fn putRawU32(self: *Builder, value: u32) void {
        var bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &bytes, value, .big);
        self.putRaw(&bytes);
    }

    fn putU32(self: *Builder, value: u32) void {
        self.putByte(tag.u32_value);
        self.putRawU32(value);
    }

    fn putString(self: *Builder, value: []const u8) void {
        self.putByte(tag.string);
        self.putRaw(value);
        self.putByte(0);
    }

    fn putNullString(self: *Builder) void {
        self.putByte(tag.string_null);
    }

    fn putBool(self: *Builder, value: bool) void {
        self.putByte(if (value) tag.boolean_true else tag.boolean_false);
    }

    fn putArbitrary(self: *Builder, bytes: []const u8) void {
        self.putByte(tag.arbitrary);
        self.putRawU32(@intCast(bytes.len));
        self.putRaw(bytes);
    }

    fn putCVolume(self: *Builder, channels: u8, volume: u32) void {
        const count = @max(@as(u8, 1), channels);
        self.putByte(tag.cvolume);
        self.putByte(count);
        var i: u8 = 0;
        while (i < count) : (i += 1) self.putRawU32(volume);
    }
};

const TagReader = struct {
    data: []const u8,
    index: usize = 0,

    fn eof(self: *const TagReader) bool {
        return self.index >= self.data.len;
    }

    fn getByte(self: *TagReader) !u8 {
        if (self.index >= self.data.len) return error.Protocol;
        const value = self.data[self.index];
        self.index += 1;
        return value;
    }

    fn expect(self: *TagReader, expected: u8) !void {
        if (try self.getByte() != expected) return error.Protocol;
    }

    fn getRaw(self: *TagReader, length: usize) ![]const u8 {
        if (self.index + length > self.data.len) return error.Protocol;
        const value = self.data[self.index .. self.index + length];
        self.index += length;
        return value;
    }

    fn getRawU32(self: *TagReader) !u32 {
        var bytes: [4]u8 = undefined;
        @memcpy(&bytes, try self.getRaw(4));
        return std.mem.readInt(u32, &bytes, .big);
    }

    fn getU32(self: *TagReader) !u32 {
        try self.expect(tag.u32_value);
        return self.getRawU32();
    }

    fn getString(self: *TagReader) !?[]const u8 {
        return switch (try self.getByte()) {
            tag.string => blk: {
                const start = self.index;
                while (self.index < self.data.len and self.data[self.index] != 0) self.index += 1;
                if (self.index >= self.data.len) return error.Protocol;
                const value = self.data[start..self.index];
                self.index += 1;
                break :blk value;
            },
            tag.string_null => null,
            else => error.Protocol,
        };
    }

    fn getBool(self: *TagReader) !bool {
        return switch (try self.getByte()) {
            tag.boolean_true => true,
            tag.boolean_false => false,
            else => error.Protocol,
        };
    }

    fn getSampleSpec(self: *TagReader) !SampleSpec {
        try self.expect(tag.sample_spec);
        _ = try self.getByte(); // format
        const channels = try self.getByte();
        _ = try self.getRawU32(); // sample rate
        return .{ .channels = channels };
    }

    fn getChannelMap(self: *TagReader) !void {
        try self.expect(tag.channel_map);
        const channels = try self.getByte();
        if (channels > 32) return error.Protocol;
        _ = try self.getRaw(channels);
    }

    fn getCVolume(self: *TagReader) !CVolume {
        try self.expect(tag.cvolume);
        const channels = try self.getByte();
        if (channels > 32) return error.Protocol;
        var max_volume: u32 = 0;
        var i: u8 = 0;
        while (i < channels) : (i += 1) {
            max_volume = @max(max_volume, try self.getRawU32());
        }
        return .{ .channels = channels, .volume = max_volume };
    }

    fn getUsec(self: *TagReader) !void {
        try self.expect(tag.usec);
        _ = try self.getRaw(8);
    }
};

fn runtimePath(buffer: []u8, env: Env) ![]const u8 {
    if (env.xdg_runtime_dir) |dir| {
        if (dir.len > 0 and std.fs.path.isAbsolute(dir)) {
            return std.fmt.bufPrint(
                buffer,
                "{s}/pulse/native",
                .{std.mem.trimEnd(u8, dir, "/")},
            );
        }
    }

    return std.fmt.bufPrint(
        buffer,
        "/run/user/{d}/pulse/native",
        .{std.posix.system.getuid()},
    );
}

fn cookiePath(buffer: []u8, env: Env) ?[]const u8 {
    if (env.xdg_config_home) |dir| {
        if (dir.len > 0 and std.fs.path.isAbsolute(dir)) {
            return std.fmt.bufPrint(
                buffer,
                "{s}/pulse/cookie",
                .{std.mem.trimEnd(u8, dir, "/")},
            ) catch null;
        }
    }

    if (env.home) |home| {
        if (home.len > 0) {
            return std.fmt.bufPrint(
                buffer,
                "{s}/.config/pulse/cookie",
                .{std.mem.trimEnd(u8, home, "/")},
            ) catch null;
        }
    }
    return null;
}

test "tag builder and reader round trip" {
    var builder = Builder{};
    builder.putU32(42);
    builder.putString("iube");
    builder.putNullString();
    builder.putBool(true);
    builder.putCVolume(2, pa_volume_norm);

    var reader = TagReader{ .data = builder.slice() };
    try std.testing.expectEqual(@as(u32, 42), try reader.getU32());
    try std.testing.expectEqualStrings("iube", (try reader.getString()).?);
    try std.testing.expect((try reader.getString()) == null);
    try std.testing.expect(try reader.getBool());
    const volume = try reader.getCVolume();
    try std.testing.expectEqual(@as(u8, 2), volume.channels);
    try std.testing.expectEqual(pa_volume_norm, volume.volume);
    try std.testing.expect(reader.eof());
}

test "device percentage and label" {
    const device = Device{
        .kind = .sink,
        .index = 0,
        .name = "alsa_output.test",
        .description = "",
        .channels = 2,
        .volume = pa_volume_norm / 2,
        .mute = false,
        .is_default = true,
    };
    try std.testing.expectEqual(@as(u8, 50), device.percent());
    try std.testing.expectEqualStrings("alsa_output.test", device.label());
}
