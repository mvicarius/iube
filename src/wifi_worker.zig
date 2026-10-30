//! Long-lived Wi-Fi worker.
//!
//! The UI submits jobs and polls snapshots. NetworkManager D-Bus traffic stays
//! on this thread. The shared queue, reconnect and teardown logic lives in
//! `worker.zig`; this file maps jobs to NetworkManager calls.

const std = @import("std");
const wifi = @import("wifi.zig");
const worker = @import("worker.zig");

pub const Kind = enum {
    refresh,
    scan,
    wireless,
    connect,
    connect_new,
    disconnect,
};

pub const Job = struct {
    kind: Kind,
    device_path: [256]u8 = undefined,
    device_len: usize = 0,
    ap_path: [256]u8 = undefined,
    ap_len: usize = 0,
    saved_path: [256]u8 = undefined,
    saved_len: usize = 0,
    ssid: [128]u8 = undefined,
    ssid_len: usize = 0,
    password: [128]u8 = undefined,
    password_len: usize = 0,
    value: bool = false,

    fn deviceSlice(self: *const Job) []const u8 {
        return self.device_path[0..self.device_len];
    }

    fn apSlice(self: *const Job) []const u8 {
        return self.ap_path[0..self.ap_len];
    }

    fn savedSlice(self: *const Job) []const u8 {
        return self.saved_path[0..self.saved_len];
    }

    fn ssidSlice(self: *const Job) []const u8 {
        return self.ssid[0..self.ssid_len];
    }

    fn passwordSlice(self: *const Job) []const u8 {
        return self.password[0..self.password_len];
    }

    pub fn clearSecret(self: *Job) void {
        @memset(self.password[0..], 0);
        self.password_len = 0;
    }
};

pub const Result = struct {
    kind: Kind,
    success: bool,
    error_value: ?anyerror = null,
    state: ?wifi.State = null,

    pub fn deinit(self: *Result) void {
        if (self.state) |*state| state.deinit();
        self.state = null;
    }
};

const Hooks = struct {
    pub fn connect(io: std.Io, gpa: std.mem.Allocator) !wifi.Client {
        return wifi.Client.connect(io, gpa);
    }

    pub fn deinitClient(client: *wifi.Client) void {
        client.deinit();
    }

    pub fn deinitResult(result: *Result) void {
        result.deinit();
    }

    pub fn clearJob(job: *Job) void {
        job.clearSecret();
    }

    pub fn isBroken(err: anyerror) bool {
        return switch (err) {
            error.Timeout,
            error.ConnectionClosed,
            error.Protocol,
            error.BigEndianUnsupported,
            error.MessageTooLarge,
            => true,
            else => false,
        };
    }

    pub fn process(self: anytype, job: *const Job) Result {
        var result = Result{ .kind = job.kind, .success = false };

        const client = self.ensureClient() catch |err| {
            result.error_value = err;
            return result;
        };

        switch (job.kind) {
            .refresh => {
                result.state = client.refresh(self.gpa) catch |err| {
                    result.error_value = err;
                    self.resetClientIfBroken(err);
                    return result;
                };
                result.success = true;
            },
            .scan => {
                const device = deviceFromPath(job.deviceSlice());
                client.requestScan(device) catch |err| {
                    result.error_value = err;
                    self.resetClientIfBroken(err);
                    return result;
                };
                std.Io.sleep(self.io, .fromMilliseconds(1500), .awake) catch {};
                result.success = true;
                refreshResult(self, client, &result);
            },
            .wireless => {
                client.setWirelessEnabled(job.value) catch |err| {
                    result.error_value = err;
                    self.resetClientIfBroken(err);
                    return result;
                };
                result.success = true;
                refreshResult(self, client, &result);
            },
            .connect => {
                const device = deviceFromPath(job.deviceSlice());
                const network = wifi.Network{
                    .ap_path = job.apSlice(),
                    .ssid = "",
                    .strength = 0,
                    .frequency = 0,
                    .secured = false,
                    .connected = false,
                };
                const saved = wifi.Saved{
                    .path = job.savedSlice(),
                    .ssid = "",
                };
                client.activateSaved(device, network, saved) catch |err| {
                    result.error_value = err;
                    self.resetClientIfBroken(err);
                    return result;
                };
                std.Io.sleep(self.io, .fromMilliseconds(1000), .awake) catch {};
                result.success = true;
                refreshResult(self, client, &result);
            },
            .connect_new => {
                const device = deviceFromPath(job.deviceSlice());
                const network = wifi.Network{
                    .ap_path = job.apSlice(),
                    .ssid = job.ssidSlice(),
                    .strength = 0,
                    .frequency = 0,
                    .secured = job.value,
                    .connected = false,
                };
                client.addAndActivate(device, network, job.passwordSlice()) catch |err| {
                    result.error_value = err;
                    self.resetClientIfBroken(err);
                    return result;
                };
                std.Io.sleep(self.io, .fromMilliseconds(1000), .awake) catch {};
                result.success = true;
                refreshResult(self, client, &result);
            },
            .disconnect => {
                const device = deviceFromPath(job.deviceSlice());
                client.disconnect(device) catch |err| {
                    result.error_value = err;
                    self.resetClientIfBroken(err);
                    return result;
                };
                std.Io.sleep(self.io, .fromMilliseconds(500), .awake) catch {};
                result.success = true;
                refreshResult(self, client, &result);
            },
        }

        return result;
    }

    pub fn refreshResult(self: anytype, client: *wifi.Client, result: *Result) void {
        result.state = client.refresh(self.gpa) catch |err| {
            result.error_value = err;
            self.resetClientIfBroken(err);
            return;
        };
    }
};

pub const Worker = worker.Worker(Job, Result, wifi.Client, Hooks);

fn deviceFromPath(path: []const u8) wifi.Device {
    return .{
        .path = path,
        .interface = "",
        .state = 0,
        .active_ap = "/",
    };
}
