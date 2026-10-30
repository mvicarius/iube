//! Long-lived Wi-Fi worker.
//!
//! The UI submits jobs and polls snapshots. NetworkManager D-Bus traffic stays
//! on this thread, and the worker owns its connection, jobs and results.

const std = @import("std");
const wifi = @import("wifi.zig");

pub const Kind = enum {
    refresh,
    scan,
    wireless,
    connect,
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

pub const Worker = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    mutex: std.Io.Mutex = .init,
    cond: std.Io.Condition = .init,
    jobs: std.ArrayList(Job) = .empty,
    results: std.ArrayList(Result) = .empty,
    stopping: bool = false,
    client: ?wifi.Client,

    pub fn start(io: std.Io, client: wifi.Client) !*Worker {
        const gpa = std.heap.c_allocator;
        const worker = try gpa.create(Worker);
        worker.* = .{
            .io = io,
            .gpa = gpa,
            .client = client,
        };

        const thread = std.Thread.spawn(.{}, run, .{worker}) catch |err| {
            var owned = worker;
            owned.destroy();
            return err;
        };
        thread.detach();
        return worker;
    }

    pub fn stop(self: *Worker) void {
        self.mutex.lockUncancelable(self.io);
        self.stopping = true;
        self.cond.signal(self.io);
        self.mutex.unlock(self.io);
    }

    pub fn submit(self: *Worker, job: Job) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.stopping) return error.Stopped;
        try self.jobs.append(self.gpa, job);
        self.cond.signal(self.io);
    }

    pub fn poll(self: *Worker) ?Result {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.results.items.len == 0) return null;
        return self.results.orderedRemove(0);
    }

    fn run(self: *Worker) void {
        defer self.destroy();

        while (true) {
            self.mutex.lockUncancelable(self.io);
            while (!self.stopping and self.jobs.items.len == 0) {
                self.cond.waitUncancelable(self.io, &self.mutex);
            }
            if (self.stopping) {
                self.mutex.unlock(self.io);
                return;
            }
            const job = self.jobs.orderedRemove(0);
            self.mutex.unlock(self.io);

            var result = self.process(job);

            self.mutex.lockUncancelable(self.io);
            if (self.stopping) {
                self.mutex.unlock(self.io);
                result.deinit();
                return;
            }
            self.results.append(self.gpa, result) catch result.deinit();
            self.cond.signal(self.io);
            self.mutex.unlock(self.io);
        }
    }

    fn process(self: *Worker, job: Job) Result {
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
                self.refreshResult(client, &result);
            },
            .wireless => {
                client.setWirelessEnabled(job.value) catch |err| {
                    result.error_value = err;
                    self.resetClientIfBroken(err);
                    return result;
                };
                result.success = true;
                self.refreshResult(client, &result);
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
                self.refreshResult(client, &result);
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
                self.refreshResult(client, &result);
            },
        }

        return result;
    }

    fn refreshResult(self: *Worker, client: *wifi.Client, result: *Result) void {
        result.state = client.refresh(self.gpa) catch |err| {
            result.error_value = err;
            self.resetClientIfBroken(err);
            return;
        };
    }

    fn ensureClient(self: *Worker) !*wifi.Client {
        if (self.client == null) {
            self.client = try wifi.Client.connect(self.io, self.gpa);
        }
        return &self.client.?;
    }

    fn resetClientIfBroken(self: *Worker, err: anyerror) void {
        switch (err) {
            error.Timeout,
            error.ConnectionClosed,
            error.Protocol,
            error.BigEndianUnsupported,
            error.MessageTooLarge,
            => {
                if (self.client) |*client| client.deinit();
                self.client = null;
            },
            else => {},
        }
    }

    fn destroy(self: *Worker) void {
        if (self.client) |*client| client.deinit();
        self.jobs.deinit(self.gpa);
        for (self.results.items) |*result| result.deinit();
        self.results.deinit(self.gpa);
        self.gpa.destroy(self);
    }
};

fn deviceFromPath(path: []const u8) wifi.Device {
    return .{
        .path = path,
        .interface = "",
        .state = 0,
        .active_ap = "/",
    };
}
