//! Minimal D-Bus client over the system bus socket.
//!
//! iube needs method calls and their replies for BlueZ, logind and the pairing
//! agent. This module implements that subset directly: EXTERNAL authentication,
//! method calls with a small header-field writer, a reader for incoming
//! messages, and method-return/error replies. No libdbus or libsystemd is
//! linked.

const std = @import("std");

pub const method_call = 1;
pub const method_return = 2;
pub const error_reply = 3;
pub const signal_message = 4;

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

/// A complete message received from the bus. Header values point into
/// `fields_alloc`, which is owned by this value.
pub const Incoming = struct {
    gpa: std.mem.Allocator,
    fields_alloc: []u8,
    fields_len: usize,
    body: []u8,
    message_type: u8,
    serial: u32,
    path: []const u8 = "",
    interface: []const u8 = "",
    member: []const u8 = "",
    error_name: []const u8 = "",
    sender: []const u8 = "",
    signature: []const u8 = "",
    reply_serial: ?u32 = null,

    pub fn deinit(self: *Incoming) void {
        self.gpa.free(self.fields_alloc);
        self.gpa.free(self.body);
        self.* = undefined;
    }

    pub fn isMethodCall(self: Incoming) bool {
        return self.message_type == method_call;
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
        const serial = try self.sendCall(message);

        while (true) {
            var received = try self.readIncoming(message.timeout_ms);
            if (received.reply_serial) |reply_serial| {
                if (reply_serial != serial) {
                    received.deinit();
                    continue;
                }
            } else {
                received.deinit();
                continue;
            }

            switch (received.message_type) {
                method_return => {
                    self.gpa.free(received.fields_alloc);
                    return .{ .gpa = self.gpa, .body = received.body };
                },
                error_reply => {
                    received.deinit();
                    return error.MethodFailed;
                },
                else => {
                    received.deinit();
                    return error.Protocol;
                },
            }
        }
    }

    /// Send a method call and return its serial without waiting for a reply.
    /// Use `readIncoming` to service replies and incoming method calls.
    pub fn sendCall(self: *Client, message: Message) !u32 {
        var fields = Builder{};
        fields.putFieldObjectPath(1, message.path);
        fields.putFieldString(6, "s", message.destination);
        fields.putFieldString(2, "s", message.interface);
        fields.putFieldString(3, "s", message.member);
        if (message.signature.len > 0) {
            fields.putFieldSignature(8, message.signature);
        }

        const serial = self.takeSerial();
        try self.writeMessage(method_call, serial, &fields, message.body);
        return serial;
    }

    /// Reply to an incoming method call with an empty body.
    pub fn sendEmptyReply(self: *Client, request: Incoming) !void {
        try self.sendMethodReturn(request.serial, request.sender, "", "");
    }

    pub fn sendMethodReturn(
        self: *Client,
        reply_serial: u32,
        destination: []const u8,
        signature: []const u8,
        body: []const u8,
    ) !void {
        var fields = Builder{};
        fields.putFieldU32(5, "u", reply_serial);
        if (destination.len > 0) fields.putFieldString(6, "s", destination);
        if (signature.len > 0) fields.putFieldSignature(8, signature);
        try self.writeMessage(method_return, self.takeSerial(), &fields, body);
    }

    /// Reject an incoming method call with a D-Bus error and a human-readable
    /// message.
    pub fn sendError(
        self: *Client,
        request: Incoming,
        error_name: []const u8,
        text: []const u8,
    ) !void {
        var body = Builder{};
        body.putString(text);

        var fields = Builder{};
        fields.putFieldU32(5, "u", request.serial);
        if (request.sender.len > 0) fields.putFieldString(6, "s", request.sender);
        fields.putFieldString(4, "s", error_name);
        fields.putFieldSignature(8, "s");
        try self.writeMessage(error_reply, self.takeSerial(), &fields, body.slice());
    }

    fn takeSerial(self: *Client) u32 {
        const serial = self.next_serial;
        self.next_serial +%= 1;
        if (self.next_serial == 0) self.next_serial = 1;
        return serial;
    }

    fn writeMessage(
        self: *Client,
        message_type: u8,
        serial: u32,
        fields: *const Builder,
        body: []const u8,
    ) !void {
        var header: [16]u8 = @splat(0);
        header[0] = 'l';
        header[1] = message_type;
        header[3] = 1;
        std.mem.writeInt(u32, header[4..8], @intCast(body.len), .little);
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
        try file.writeStreamingAll(self.io, body);
    }

    /// Receive one message. The caller owns the returned value and must call
    /// `deinit` on it.
    pub fn readIncoming(self: *Client, timeout_ms: i32) !Incoming {
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
        self.readExact(fields, timeout_ms) catch |err| {
            self.gpa.free(fields);
            return err;
        };

        const body = self.gpa.alloc(u8, body_len) catch |err| {
            self.gpa.free(fields);
            return err;
        };
        self.readExact(body, timeout_ms) catch |err| {
            self.gpa.free(fields);
            self.gpa.free(body);
            return err;
        };

        // parseIncoming owns both allocations and frees them on its own error
        // paths.
        return parseIncoming(
            self.gpa,
            fields,
            fields_len,
            body,
            header[1],
            std.mem.readInt(u32, header[8..12], .little),
        );
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

    pub fn putObjectPath(self: *Builder, value: []const u8) void {
        self.putString(value);
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

    fn putFieldU32(self: *Builder, code: u8, signature: []const u8, value: u32) void {
        self.alignTo(8);
        self.putByte(code);
        self.putSignature(signature);
        self.putU32(value);
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

fn parseIncoming(
    gpa: std.mem.Allocator,
    fields_alloc: []u8,
    fields_len: usize,
    body: []u8,
    message_type: u8,
    serial: u32,
) !Incoming {
    var incoming = Incoming{
        .gpa = gpa,
        .fields_alloc = fields_alloc,
        .fields_len = fields_len,
        .body = body,
        .message_type = message_type,
        .serial = serial,
    };
    errdefer incoming.deinit();

    var reader = Reader{ .data = fields_alloc[0..fields_len] };
    while (reader.index < fields_len) {
        try reader.alignTo(8);
        if (reader.index >= fields_len) break;
        const code = try reader.readU8();
        const signature = try reader.readSignature();

        switch (code) {
            1 => {
                if (std.mem.eql(u8, signature, "o")) {
                    incoming.path = try reader.readObjectPath();
                } else {
                    try reader.skipValue(signature);
                }
            },
            2 => {
                if (std.mem.eql(u8, signature, "s")) {
                    incoming.interface = try reader.readString();
                } else {
                    try reader.skipValue(signature);
                }
            },
            3 => {
                if (std.mem.eql(u8, signature, "s")) {
                    incoming.member = try reader.readString();
                } else {
                    try reader.skipValue(signature);
                }
            },
            4 => {
                if (std.mem.eql(u8, signature, "s")) {
                    incoming.error_name = try reader.readString();
                } else {
                    try reader.skipValue(signature);
                }
            },
            5 => {
                if (std.mem.eql(u8, signature, "u")) {
                    incoming.reply_serial = try reader.readU32();
                } else {
                    try reader.skipValue(signature);
                }
            },
            7 => {
                if (std.mem.eql(u8, signature, "s")) {
                    incoming.sender = try reader.readString();
                } else {
                    try reader.skipValue(signature);
                }
            },
            8 => {
                if (std.mem.eql(u8, signature, "g")) {
                    incoming.signature = try reader.readSignature();
                } else {
                    try reader.skipValue(signature);
                }
            },
            else => try reader.skipValue(signature),
        }
    }

    return incoming;
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

test "dbus parses incoming header fields" {
    var fields = Builder{};
    fields.putFieldObjectPath(1, "/org/bluez/hci0");
    fields.putFieldString(2, "s", "org.bluez.Agent1");
    fields.putFieldString(3, "s", "RequestConfirmation");
    fields.putFieldString(6, "s", ":1.42");
    fields.putFieldString(7, "s", ":1.2");
    fields.putFieldSignature(8, "os");
    fields.putFieldU32(5, "u", 99);

    const gpa = std.testing.allocator;
    const fields_alloc = try gpa.dupe(u8, fields.slice());
    const body = try gpa.alloc(u8, 0);

    var incoming = try parseIncoming(gpa, fields_alloc, fields.len, body, method_call, 7);
    defer incoming.deinit();

    try std.testing.expectEqual(@as(u8, method_call), incoming.message_type);
    try std.testing.expectEqual(@as(u32, 7), incoming.serial);
    try std.testing.expectEqual(@as(?u32, 99), incoming.reply_serial);
    try std.testing.expectEqualStrings("/org/bluez/hci0", incoming.path);
    try std.testing.expectEqualStrings("org.bluez.Agent1", incoming.interface);
    try std.testing.expectEqualStrings("RequestConfirmation", incoming.member);
    try std.testing.expectEqualStrings(":1.2", incoming.sender);
    try std.testing.expectEqualStrings("os", incoming.signature);
}
