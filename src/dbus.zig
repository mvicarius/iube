//! Minimal D-Bus client over the system bus socket.
//!
//! iube only needs method calls and their replies for BlueZ and, later, logind.
//! This module implements that subset directly: EXTERNAL authentication, method
//! calls with a small header-field writer, and a reader for reply bodies. No
//! libdbus or libsystemd is linked.

const std = @import("std");

const method_call = 1;
const method_return = 2;
const error_reply = 3;
const signal_message = 4;

const max_message_size = 8 * 1024 * 1024;
const io_timeout_ms = 3000;

pub const Message = struct {
    destination: []const u8,
    path: []const u8,
    interface: []const u8,
    member: []const u8,
    signature: []const u8 = "",
    body: []const u8 = "",
    timeout_ms: i32 = io_timeout_ms,
};

pub const Reply = struct {
    gpa: std.mem.Allocator,
    body: []u8,

    pub fn deinit(self: *Reply) void {
        self.gpa.free(self.body);
    }
};

pub const Client = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    stream: std.Io.net.Stream,
    next_serial: u32 = 1,

    pub fn connectSystem(io: std.Io, gpa: std.mem.Allocator) !Client {
        const address = try std.Io.net.UnixAddress.init("/run/dbus/system_bus_socket");
        const stream = try address.connect(io);
        errdefer stream.close(io);

        var client = Client{
            .io = io,
            .gpa = gpa,
            .stream = stream,
        };
        try client.authenticate();
        try client.hello();
        return client;
    }

    pub fn deinit(self: *Client) void {
        self.stream.close(self.io);
    }

    pub fn call(self: *Client, message: Message) !Reply {
        var fields = Builder{};
        fields.putFieldObjectPath(1, message.path);
        fields.putFieldString(6, "s", message.destination);
        fields.putFieldString(2, "s", message.interface);
        fields.putFieldString(3, "s", message.member);
        if (message.signature.len > 0) {
            fields.putFieldSignature(8, message.signature);
        }

        const serial = self.next_serial;
        self.next_serial +%= 1;
        if (self.next_serial == 0) self.next_serial = 1;

        var header: [16]u8 = @splat(0);
        header[0] = 'l';
        header[1] = method_call;
        header[3] = 1;
        std.mem.writeInt(u32, header[4..8], @intCast(message.body.len), .little);
        std.mem.writeInt(u32, header[8..12], serial, .little);
        std.mem.writeInt(u32, header[12..16], @intCast(fields.len), .little);

        const fields_end = 16 + fields.len;
        const padding = std.mem.alignForward(usize, fields_end, 8) - fields_end;
        const zero_padding: [8]u8 = @splat(0);

        const file = std.Io.File{
            .handle = self.stream.socket.handle,
            .flags = .{ .nonblocking = false },
        };
        try file.writeStreamingAll(self.io, &header);
        try file.writeStreamingAll(self.io, fields.slice());
        if (padding > 0) try file.writeStreamingAll(self.io, zero_padding[0..padding]);
        try file.writeStreamingAll(self.io, message.body);

        while (true) {
            const received = try self.receive(message.timeout_ms);
            if (received.reply_serial) |reply_serial| {
                if (reply_serial != serial) {
                    self.gpa.free(received.body);
                    continue;
                }
            } else {
                self.gpa.free(received.body);
                continue;
            }

            switch (received.message_type) {
                method_return => return .{ .gpa = self.gpa, .body = received.body },
                error_reply => {
                    self.gpa.free(received.body);
                    return error.MethodFailed;
                },
                else => {
                    self.gpa.free(received.body);
                    return error.Protocol;
                },
            }
        }
    }

    const Received = struct {
        message_type: u8,
        reply_serial: ?u32,
        body: []u8,
    };

    fn receive(self: *Client, timeout_ms: i32) !Received {
        var header: [16]u8 = undefined;
        try self.readExact(&header, timeout_ms);
        if (header[0] != 'l') return error.BigEndianUnsupported;

        const body_len = std.mem.readInt(u32, header[4..8], .little);
        const fields_len = std.mem.readInt(u32, header[12..16], .little);
        if (body_len > max_message_size or fields_len > max_message_size) {
            return error.MessageTooLarge;
        }

        const fields_padded = std.mem.alignForward(usize, fields_len, 8);
        const fields = try self.gpa.alloc(u8, fields_padded);
        defer self.gpa.free(fields);
        try self.readExact(fields, timeout_ms);

        const body = try self.gpa.alloc(u8, body_len);
        errdefer self.gpa.free(body);
        try self.readExact(body, timeout_ms);

        return .{
            .message_type = header[1],
            .reply_serial = findReplySerial(fields[0..fields_len]),
            .body = body,
        };
    }

    fn authenticate(self: *Client) !void {
        var uid_buffer: [32]u8 = undefined;
        const uid_text = try std.fmt.bufPrint(&uid_buffer, "{d}", .{std.posix.system.getuid()});

        var hex_buffer: [64]u8 = undefined;
        var hex_len: usize = 0;
        for (uid_text) |byte| {
            const digits = "0123456789abcdef";
            hex_buffer[hex_len] = digits[byte >> 4];
            hex_buffer[hex_len + 1] = digits[byte & 0xf];
            hex_len += 2;
        }

        var auth_buffer: [128]u8 = undefined;
        const auth = try std.fmt.bufPrint(
            &auth_buffer,
            "AUTH EXTERNAL {s}\r\n",
            .{hex_buffer[0..hex_len]},
        );

        try self.writeRaw("\x00");
        try self.writeRaw(auth);
        var line_buffer: [256]u8 = undefined;
        const response = try self.readLine(&line_buffer);
        if (!std.mem.startsWith(u8, response, "OK")) return error.AuthenticationFailed;
        try self.writeRaw("BEGIN\r\n");
    }

    fn hello(self: *Client) !void {
        var reply = try self.call(.{
            .destination = "org.freedesktop.DBus",
            .path = "/org/freedesktop/DBus",
            .interface = "org.freedesktop.DBus",
            .member = "Hello",
        });
        reply.deinit();
    }

    fn writeRaw(self: *Client, bytes: []const u8) !void {
        const file = std.Io.File{
            .handle = self.stream.socket.handle,
            .flags = .{ .nonblocking = false },
        };
        try file.writeStreamingAll(self.io, bytes);
    }

    fn readLine(self: *Client, buffer: []u8) ![]const u8 {
        var length: usize = 0;
        while (length < buffer.len) {
            try self.waitReadable(io_timeout_ms);
            const count = try std.posix.read(self.stream.socket.handle, buffer[length .. length + 1]);
            if (count == 0) return error.ConnectionClosed;
            length += 1;
            if (buffer[length - 1] == '\n') return buffer[0..length];
        }
        return error.LineTooLong;
    }

    fn readExact(self: *Client, buffer: []u8, timeout_ms: i32) !void {
        var filled: usize = 0;
        while (filled < buffer.len) {
            try self.waitReadable(timeout_ms);
            const count = try std.posix.read(self.stream.socket.handle, buffer[filled..]);
            if (count == 0) return error.ConnectionClosed;
            filled += count;
        }
    }

    fn waitReadable(self: *Client, timeout_ms: i32) !void {
        var poll_fds = [_]std.posix.pollfd{.{
            .fd = self.stream.socket.handle,
            .events = std.posix.POLL.IN,
            .revents = 0,
        }};
        const ready = try std.posix.poll(&poll_fds, timeout_ms);
        if (ready == 0) return error.Timeout;
        if ((poll_fds[0].revents & (std.posix.POLL.IN | std.posix.POLL.HUP | std.posix.POLL.ERR)) == 0) {
            return error.ConnectionClosed;
        }
    }
};

/// Marshals method-call bodies and header fields in little-endian order.
pub const Builder = struct {
    data: [4096]u8 = undefined,
    len: usize = 0,

    pub fn slice(self: *const Builder) []const u8 {
        return self.data[0..self.len];
    }

    pub fn alignTo(self: *Builder, alignment: usize) void {
        const next = std.mem.alignForward(usize, self.len, alignment);
        if (next > self.len) {
            @memset(self.data[self.len..next], 0);
            self.len = next;
        }
    }

    pub fn putRaw(self: *Builder, bytes: []const u8) void {
        std.debug.assert(self.len + bytes.len <= self.data.len);
        @memcpy(self.data[self.len .. self.len + bytes.len], bytes);
        self.len += bytes.len;
    }

    pub fn putByte(self: *Builder, value: u8) void {
        std.debug.assert(self.len < self.data.len);
        self.data[self.len] = value;
        self.len += 1;
    }

    pub fn putU32(self: *Builder, value: u32) void {
        self.alignTo(4);
        var bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &bytes, value, .little);
        self.putRaw(&bytes);
    }

    pub fn putString(self: *Builder, value: []const u8) void {
        self.putU32(@intCast(value.len));
        self.putRaw(value);
        self.putByte(0);
    }

    pub fn putSignature(self: *Builder, value: []const u8) void {
        self.putByte(@intCast(value.len));
        self.putRaw(value);
        self.putByte(0);
    }

    pub fn putVariantBool(self: *Builder, value: bool) void {
        self.putSignature("b");
        self.putU32(if (value) 1 else 0);
    }

    fn putFieldObjectPath(self: *Builder, code: u8, value: []const u8) void {
        self.putFieldString(code, "o", value);
    }

    fn putFieldString(self: *Builder, code: u8, signature: []const u8, value: []const u8) void {
        self.alignTo(8);
        self.putByte(code);
        self.putSignature(signature);
        self.alignTo(4);
        self.putString(value);
    }

    fn putFieldSignature(self: *Builder, code: u8, value: []const u8) void {
        self.alignTo(8);
        self.putByte(code);
        self.putSignature("g");
        self.putSignature(value);
    }
};

/// Reads D-Bus bodies. Only the types needed by iube are exposed; unknown
/// values can be skipped with `skipValue`.
pub const Reader = struct {
    data: []const u8,
    index: usize = 0,

    pub fn alignTo(self: *Reader, alignment: usize) !void {
        self.index = std.mem.alignForward(usize, self.index, alignment);
        if (self.index > self.data.len) return error.Protocol;
    }

    pub fn readU8(self: *Reader) !u8 {
        if (self.index >= self.data.len) return error.Protocol;
        const value = self.data[self.index];
        self.index += 1;
        return value;
    }

    pub fn readU32(self: *Reader) !u32 {
        try self.alignTo(4);
        if (self.index + 4 > self.data.len) return error.Protocol;
        var bytes: [4]u8 = undefined;
        @memcpy(&bytes, self.data[self.index .. self.index + 4]);
        self.index += 4;
        return std.mem.readInt(u32, &bytes, .little);
    }

    pub fn readI16(self: *Reader) !i16 {
        try self.alignTo(2);
        if (self.index + 2 > self.data.len) return error.Protocol;
        var bytes: [2]u8 = undefined;
        @memcpy(&bytes, self.data[self.index .. self.index + 2]);
        self.index += 2;
        return std.mem.readInt(i16, &bytes, .little);
    }

    pub fn readBool(self: *Reader) !bool {
        return (try self.readU32()) != 0;
    }

    pub fn readString(self: *Reader) ![]const u8 {
        try self.alignTo(4);
        const length = try self.readU32();
        if (self.index + length + 1 > self.data.len) return error.Protocol;
        const value = self.data[self.index .. self.index + length];
        self.index += length;
        if (self.data[self.index] != 0) return error.Protocol;
        self.index += 1;
        return value;
    }

    pub fn readByteArray(self: *Reader) ![]const u8 {
        try self.alignTo(4);
        const length = try self.readU32();
        if (self.index + length > self.data.len) return error.Protocol;
        const value = self.data[self.index .. self.index + length];
        self.index += length;
        return value;
    }

    pub fn readObjectPath(self: *Reader) ![]const u8 {
        return self.readString();
    }

    pub fn readSignature(self: *Reader) ![]const u8 {
        const length = try self.readU8();
        if (self.index + length + 1 > self.data.len) return error.Protocol;
        const value = self.data[self.index .. self.index + length];
        self.index += length;
        if (self.data[self.index] != 0) return error.Protocol;
        self.index += 1;
        return value;
    }

    /// Read the length of an array and return the index where its elements end.
    pub fn beginArray(self: *Reader, element_alignment: usize) !usize {
        try self.alignTo(4);
        const length = try self.readU32();
        try self.alignTo(element_alignment);
        const end = self.index + length;
        if (end > self.data.len) return error.Protocol;
        return end;
    }

    pub fn skipValue(self: *Reader, signature: []const u8) !void {
        if (signature.len == 0) return error.Protocol;

        switch (signature[0]) {
            'y', 'g', 'v' => {
                if (signature[0] == 'g') {
                    _ = try self.readSignature();
                } else if (signature[0] == 'v') {
                    const inner = try self.readSignature();
                    try self.skipValue(inner);
                } else {
                    try self.alignTo(1);
                    self.index += 1;
                }
            },
            'n', 'q' => {
                try self.alignTo(2);
                self.index += 2;
            },
            'b', 'i', 'u', 'h' => {
                try self.alignTo(4);
                self.index += 4;
            },
            'x', 't', 'd' => {
                try self.alignTo(8);
                self.index += 8;
            },
            's', 'o' => {
                _ = try self.readString();
            },
            'a' => {
                const element_len = try oneTypeLen(signature[1..]);
                const element = signature[1 .. 1 + element_len];
                const end = try self.beginArray(alignmentFor(element));
                while (self.index < end) {
                    try self.skipValue(element);
                    if (self.index >= end) break;
                    try self.alignTo(alignmentFor(element));
                }
                if (self.index > end) {
                    if (self.index - end >= 8) return error.Protocol;
                    self.index = end;
                } else if (self.index < end) {
                    return error.Protocol;
                }
            },
            '(', '{' => {
                try self.alignTo(8);
                const closing: u8 = if (signature[0] == '(') ')' else '}';
                var offset: usize = 1;
                while (offset < signature.len and signature[offset] != closing) {
                    const length = try oneTypeLen(signature[offset..]);
                    try self.skipValue(signature[offset .. offset + length]);
                    offset += length;
                }
                if (offset >= signature.len) return error.Protocol;
                try self.alignTo(8);
            },
            else => return error.Protocol,
        }
        if (self.index > self.data.len) return error.Protocol;
    }
};

fn findReplySerial(fields: []const u8) ?u32 {
    var reader = Reader{ .data = fields };
    while (reader.index < fields.len) {
        reader.alignTo(8) catch return null;
        const code = reader.readU8() catch return null;
        const signature = reader.readSignature() catch return null;

        if (code == 5 and std.mem.eql(u8, signature, "u")) {
            return reader.readU32() catch null;
        }
        reader.skipValue(signature) catch return null;
    }
    return null;
}

fn alignmentFor(signature: []const u8) usize {
    if (signature.len == 0) return 1;
    return switch (signature[0]) {
        'y', 'g', 'v' => 1,
        'n', 'q' => 2,
        'b', 'i', 'u', 'h', 's', 'o', 'a' => 4,
        'x', 't', 'd', '(', '{' => 8,
        else => 1,
    };
}

fn oneTypeLen(signature: []const u8) !usize {
    if (signature.len == 0) return error.Protocol;

    return switch (signature[0]) {
        '(', '{' => {
            const closing: u8 = if (signature[0] == '(') ')' else '}';
            var offset: usize = 1;
            while (offset < signature.len and signature[offset] != closing) {
                offset += try oneTypeLen(signature[offset..]);
            }
            if (offset >= signature.len) return error.Protocol;
            return offset + 1;
        },
        'a' => {
            if (signature.len < 2) return error.Protocol;
            return 1 + try oneTypeLen(signature[1..]);
        },
        else => 1,
    };
}

test "dbus body builder and reader" {
    var builder = Builder{};
    builder.putString("org.bluez.Adapter1");
    builder.putString("Powered");
    builder.putVariantBool(true);

    var reader = Reader{ .data = builder.slice() };
    try std.testing.expectEqualStrings("org.bluez.Adapter1", try reader.readString());
    try std.testing.expectEqualStrings("Powered", try reader.readString());
    try std.testing.expectEqualStrings("b", try reader.readSignature());
    try std.testing.expect(try reader.readBool());
}

test "dbus skips nested containers" {
    // Build a one-entry a{sv}: key "X", variant string "y".
    var payload = Builder{};
    payload.alignTo(8);
    payload.putString("X");
    payload.putSignature("s");
    payload.putString("y");
    payload.alignTo(8);

    var body = Builder{};
    body.putU32(@intCast(payload.len));
    body.alignTo(8);
    body.putRaw(payload.slice());

    var reader = Reader{ .data = body.slice() };
    try reader.skipValue("a{sv}");
    try std.testing.expectEqual(body.len, reader.index);
}

test "dbus skips signature values" {
    var body = Builder{};
    body.putSignature("a{sv}");

    var reader = Reader{ .data = body.slice() };
    try reader.skipValue("g");
    try std.testing.expectEqual(body.len, reader.index);
}
