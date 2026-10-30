//! BlueZ pairing agent.
//!
//! BlueZ calls back into a registered `org.bluez.Agent1` object while a
//! `Device1.Pair` call is in progress. This module implements a short-lived
//! `NoInputNoOutput` agent that answers those callbacks on an existing system
//! bus connection. It auto-accepts just-works confirmation, rejects methods
//! that need a keyboard or display, and is unregistered after pairing.

const std = @import("std");
const dbus = @import("dbus.zig");

pub const agent_path = "/org/iube/bluez/Agent";
pub const agent_interface = "org.bluez.Agent1";
pub const manager_destination = "org.bluez";
pub const manager_path = "/org/bluez";
pub const manager_interface = "org.bluez.AgentManager1";
pub const capability = "NoInputNoOutput";

/// What iube does with an incoming Agent1 method.
pub const Decision = enum {
    accept,
    cancel,
    release,
    reject_passkey,
    reject_pin,
    unknown,
};

/// Decide without touching the bus so the policy is easy to test.
pub fn decisionFor(member: []const u8) Decision {
    if (std.mem.eql(u8, member, "RequestConfirmation")) return .accept;
    if (std.mem.eql(u8, member, "RequestAuthorization")) return .accept;
    if (std.mem.eql(u8, member, "AuthorizeService")) return .accept;
    if (std.mem.eql(u8, member, "RequestPasskey")) return .reject_passkey;
    if (std.mem.eql(u8, member, "DisplayPasskey")) return .reject_passkey;
    if (std.mem.eql(u8, member, "RequestPinCode")) return .reject_pin;
    if (std.mem.eql(u8, member, "DisplayPinCode")) return .reject_pin;
    if (std.mem.eql(u8, member, "Cancel")) return .cancel;
    if (std.mem.eql(u8, member, "Release")) return .release;
    return .unknown;
}

pub const Agent = struct {
    client: *dbus.Client,
    path: []const u8 = agent_path,
    passkey_requested: bool = false,
    pin_requested: bool = false,
    cancelled: bool = false,
    released: bool = false,
    /// Set when another agent is already the default. Registration still
    /// succeeds, but BlueZ may route requests to the existing agent.
    default_request_failed: bool = false,

    pub fn register(self: *Agent) !void {
        var body = dbus.Builder{};
        body.putObjectPath(self.path);
        body.putString(capability);

        var reply = try self.client.call(.{
            .destination = manager_destination,
            .path = manager_path,
            .interface = manager_interface,
            .member = "RegisterAgent",
            .signature = "os",
            .body = body.slice(),
        });
        reply.deinit();

        self.requestDefault() catch {
            self.default_request_failed = true;
        };
    }

    fn requestDefault(self: *Agent) !void {
        var body = dbus.Builder{};
        body.putObjectPath(self.path);

        var reply = try self.client.call(.{
            .destination = manager_destination,
            .path = manager_path,
            .interface = manager_interface,
            .member = "RequestDefaultAgent",
            .signature = "o",
            .body = body.slice(),
        });
        reply.deinit();
    }

    pub fn unregister(self: *Agent) void {
        var body = dbus.Builder{};
        body.putObjectPath(self.path);

        var reply = self.client.call(.{
            .destination = manager_destination,
            .path = manager_path,
            .interface = manager_interface,
            .member = "UnregisterAgent",
            .signature = "o",
            .body = body.slice(),
        }) catch return;
        reply.deinit();
    }

    /// Answer one incoming method call. Callers should only pass messages whose
    /// reply_serial is null (that is, method calls rather than replies).
    pub fn handle(self: *Agent, request: dbus.Incoming) !void {
        if (!std.mem.eql(u8, request.path, self.path)) {
            try self.client.sendError(
                request,
                "org.freedesktop.DBus.Error.UnknownObject",
                "iube: no such agent object",
            );
            return;
        }
        if (!std.mem.eql(u8, request.interface, agent_interface)) {
            try self.client.sendError(
                request,
                "org.freedesktop.DBus.Error.UnknownInterface",
                "iube: no such agent interface",
            );
            return;
        }

        switch (decisionFor(request.member)) {
            .accept => try self.client.sendEmptyReply(request),
            .cancel => {
                self.cancelled = true;
                try self.client.sendEmptyReply(request);
            },
            .release => {
                self.released = true;
                try self.client.sendEmptyReply(request);
            },
            .reject_passkey => {
                self.passkey_requested = true;
                try self.client.sendError(
                    request,
                    "org.bluez.Error.NotSupported",
                    "iube: passkey pairing is not supported; use a device that supports just-works pairing",
                );
            },
            .reject_pin => {
                self.pin_requested = true;
                try self.client.sendError(
                    request,
                    "org.bluez.Error.NotSupported",
                    "iube: PIN pairing is not supported; use a device that supports just-works pairing",
                );
            },
            .unknown => try self.client.sendError(
                request,
                "org.freedesktop.DBus.Error.UnknownMethod",
                "iube: unknown agent method",
            ),
        }
    }
};

test "agent decisions accept just-works and reject passkey input" {
    try std.testing.expectEqual(Decision.accept, decisionFor("RequestConfirmation"));
    try std.testing.expectEqual(Decision.accept, decisionFor("RequestAuthorization"));
    try std.testing.expectEqual(Decision.accept, decisionFor("AuthorizeService"));
    try std.testing.expectEqual(Decision.reject_passkey, decisionFor("RequestPasskey"));
    try std.testing.expectEqual(Decision.reject_passkey, decisionFor("DisplayPasskey"));
    try std.testing.expectEqual(Decision.reject_pin, decisionFor("RequestPinCode"));
    try std.testing.expectEqual(Decision.reject_pin, decisionFor("DisplayPinCode"));
    try std.testing.expectEqual(Decision.cancel, decisionFor("Cancel"));
    try std.testing.expectEqual(Decision.release, decisionFor("Release"));
    try std.testing.expectEqual(Decision.unknown, decisionFor("RequestSomethingElse"));
}
