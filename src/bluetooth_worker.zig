//! Long-lived Bluetooth worker.
//!
//! The UI submits jobs and polls snapshots; all BlueZ D-Bus traffic happens on
//! this thread. The shared queue, reconnect and teardown logic lives in
//! `worker.zig`; this file only maps jobs to BlueZ calls.

const std = @import("std");
const bluetooth = @import("bluetooth.zig");
const worker = @import("worker.zig");

pub const Kind = enum {
    refresh,
    power,
    discovery,
    connect,
    pair,
    forget,
};

pub const Job = struct {
    kind: Kind,
    path: [256]u8 = undefined,
    path_len: usize = 0,
    adapter_path: [256]u8 = undefined,
    adapter_path_len: usize = 0,
    value: bool = false,

    pub fn pathSlice(self: *const Job) []const u8 {
        return self.path[0..self.path_len];
    }

    pub fn adapterPathSlice(self: *const Job) []const u8 {
        return self.adapter_path[0..self.adapter_path_len];
    }
};

pub const Result = struct {
    kind: Kind,
    success: bool,
    error_value: ?anyerror = null,
    state: ?bluetooth.State = null,

    pub fn deinit(self: *Result) void {
        if (self.state) |*state| state.deinit();
        self.state = null;
    }
};

const Hooks = struct {
    pub fn connect(io: std.Io, gpa: std.mem.Allocator) !bluetooth.Client {
        return bluetooth.Client.connect(io, gpa);
    }

    pub fn deinitClient(client: *bluetooth.Client) void {
        client.deinit();
    }

    pub fn deinitResult(result: *Result) void {
        result.deinit();
    }

    pub fn clearJob(_: *Job) void {}

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
        var result = Result{
            .kind = job.kind,
            .success = false,
        };

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
            .power => {
                const adapter = bluetooth.Adapter{
                    .path = job.pathSlice(),
                    .name = "",
                    .address = "",
                };
                client.setAdapterPowered(adapter, job.value) catch |err| {
                    result.error_value = err;
                    self.resetClientIfBroken(err);
                    return result;
                };
                result.success = true;
                refreshResult(self, client, &result);
            },
            .discovery => {
                const adapter = bluetooth.Adapter{
                    .path = job.pathSlice(),
                    .name = "",
                    .address = "",
                };
                client.setDiscovering(adapter, job.value) catch |err| {
                    result.error_value = err;
                    self.resetClientIfBroken(err);
                    return result;
                };
                result.success = true;
                refreshResult(self, client, &result);
            },
            .connect => {
                const device = bluetooth.Device{
                    .path = job.pathSlice(),
                    .adapter_path = "",
                    .name = "",
                    .address = "",
                };
                client.setConnected(device, job.value) catch |err| {
                    result.error_value = err;
                    self.resetClientIfBroken(err);
                    return result;
                };
                result.success = true;
                refreshResult(self, client, &result);
            },
            .pair => {
                _ = bluetooth.pairDetached(self.io, self.gpa, job.pathSlice()) catch |err| {
                    result.error_value = err;
                    return result;
                };
                result.success = true;
                refreshResult(self, client, &result);
            },
            .forget => {
                const device = bluetooth.Device{
                    .path = job.pathSlice(),
                    .adapter_path = job.adapterPathSlice(),
                    .name = "",
                    .address = "",
                };
                client.removeDevice(device) catch |err| {
                    result.error_value = err;
                    self.resetClientIfBroken(err);
                    return result;
                };
                result.success = true;
                refreshResult(self, client, &result);
            },
        }

        return result;
    }

    pub fn refreshResult(self: anytype, client: *bluetooth.Client, result: *Result) void {
        result.state = client.refresh(self.gpa) catch |err| {
            result.error_value = err;
            self.resetClientIfBroken(err);
            return;
        };
    }
};

pub const Worker = worker.Worker(Job, Result, bluetooth.Client, Hooks);
