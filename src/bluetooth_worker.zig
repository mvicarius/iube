//! Long-lived Bluetooth worker.
//!
//! The UI submits jobs and polls snapshots; all BlueZ D-Bus traffic happens on
//! this thread. The worker owns its jobs, results and D-Bus connection, so the
//! view can drop it without joining a blocked connect call.

const std = @import("std");
const bluetooth = @import("bluetooth.zig");

pub const Kind = enum {
    refresh,
    power,
    discovery,
    connect,
};

pub const Job = struct {
    kind: Kind,
    path: [256]u8 = undefined,
    path_len: usize = 0,
    value: bool = false,

    pub fn pathSlice(self: *const Job) []const u8 {
        return self.path[0..self.path_len];
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

pub const Worker = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    mutex: std.Io.Mutex = .init,
    cond: std.Io.Condition = .init,
    jobs: std.ArrayList(Job) = .empty,
    results: std.ArrayList(Result) = .empty,
    stopping: bool = false,
    client: ?bluetooth.Client,

    pub fn start(io: std.Io, client: bluetooth.Client) !*Worker {
        // The worker can outlive the view. Use the process-wide libc allocator
        // instead of the main allocator, which is deinitialized on exit.
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

    /// Ask the worker to stop. The worker frees itself when it next gets
    /// control, even if it is currently waiting for a D-Bus reply.
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
                self.refreshResult(client, &result);
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
                self.refreshResult(client, &result);
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
                self.refreshResult(client, &result);
            },
        }

        return result;
    }

    fn refreshResult(self: *Worker, client: *bluetooth.Client, result: *Result) void {
        result.state = client.refresh(self.gpa) catch |err| {
            result.error_value = err;
            self.resetClientIfBroken(err);
            return;
        };
    }

    fn ensureClient(self: *Worker) !*bluetooth.Client {
        if (self.client == null) {
            self.client = try bluetooth.Client.connect(self.io, self.gpa);
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
