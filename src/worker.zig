//! Generic long-lived job worker.
//!
//! Bluetooth and Wi-Fi both keep one backend connection on a detached thread,
//! accept jobs from the UI and publish results without blocking redraws. The
//! queue, locking, client reconnects and teardown live here; each tool supplies
//! only its job/result types and a `Hooks.process` switch.

const std = @import("std");

pub fn Worker(
    comptime Job: type,
    comptime Result: type,
    comptime Client: type,
    comptime Hooks: type,
) type {
    return struct {
        const Self = @This();

        io: std.Io,
        gpa: std.mem.Allocator,
        mutex: std.Io.Mutex = .init,
        cond: std.Io.Condition = .init,
        jobs: std.ArrayList(Job) = .empty,
        results: std.ArrayList(Result) = .empty,
        stopping: bool = false,
        client: ?Client = null,

        pub fn start(io: std.Io, client: Client) !*Self {
            // The worker can outlive the view. Use the process-wide allocator
            // instead of the main allocator, which is deinitialized on exit.
            const gpa = std.heap.c_allocator;
            const worker = gpa.create(Self) catch |err| {
                var owned = client;
                Hooks.deinitClient(&owned);
                return err;
            };
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

        /// Ask the worker to stop. It frees itself when it next gets control,
        /// even if it is currently waiting for a backend reply.
        pub fn stop(self: *Self) void {
            self.mutex.lockUncancelable(self.io);
            self.stopping = true;
            self.cond.signal(self.io);
            self.mutex.unlock(self.io);
        }

        pub fn submit(self: *Self, job: Job) !void {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            if (self.stopping) return error.Stopped;
            try self.jobs.append(self.gpa, job);
            self.cond.signal(self.io);
        }

        pub fn poll(self: *Self) ?Result {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            if (self.results.items.len == 0) return null;
            return self.results.orderedRemove(0);
        }

        pub fn ensureClient(self: *Self) !*Client {
            if (self.client == null) {
                self.client = try Hooks.connect(self.io, self.gpa);
            }
            return &self.client.?;
        }

        pub fn resetClientIfBroken(self: *Self, err: anyerror) void {
            if (!Hooks.isBroken(err)) return;
            if (self.client) |*client| Hooks.deinitClient(client);
            self.client = null;
        }

        fn run(self: *Self) void {
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
                var job = self.takeJob();
                self.mutex.unlock(self.io);

                var result = Hooks.process(self, &job);
                Hooks.clearJob(&job);

                self.mutex.lockUncancelable(self.io);
                if (self.stopping) {
                    self.mutex.unlock(self.io);
                    Hooks.deinitResult(&result);
                    return;
                }
                self.results.append(self.gpa, result) catch Hooks.deinitResult(&result);
                self.cond.signal(self.io);
                self.mutex.unlock(self.io);
            }
        }

        /// Remove the oldest job and wipe the vacated slot. `orderedRemove`
        /// alone leaves a bitwise copy of the last job (including any password)
        /// in the backing array beyond `items.len`.
        fn takeJob(self: *Self) Job {
            const last = self.jobs.items.len - 1;
            const job = self.jobs.items[0];
            if (last > 0) self.jobs.items[0] = self.jobs.items[last];
            self.jobs.items[last] = std.mem.zeroes(Job);
            self.jobs.items.len = last;
            return job;
        }

        fn destroy(self: *Self) void {
            if (self.client) |*client| Hooks.deinitClient(client);
            for (self.jobs.items) |*job| Hooks.clearJob(job);
            self.jobs.deinit(self.gpa);
            for (self.results.items) |*result| Hooks.deinitResult(result);
            self.results.deinit(self.gpa);
            self.gpa.destroy(self);
        }
    };
}
