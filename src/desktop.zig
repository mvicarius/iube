//! `.desktop` entry discovery, matching the old launcher's behaviour.

const std = @import("std");

const icon_size = 32;

const String = struct {
    start: usize,
    end: usize,
};

pub const Apps = struct {
    buffer: std.ArrayList(u8) = .empty,
    names: std.ArrayList(String) = .empty,
    execs: std.ArrayList(String) = .empty,
    icon_bytes: std.ArrayList(?String) = .empty,
    terminal: std.ArrayList(bool) = .empty,
    order: std.ArrayList(usize) = .empty,
    arena: std.heap.ArenaAllocator,

    pub fn init(gpa: std.mem.Allocator) Apps {
        return .{ .arena = std.heap.ArenaAllocator.init(gpa) };
    }

    pub fn deinit(self: *Apps) void {
        self.arena.deinit();
    }

    pub fn len(self: Apps) usize {
        return self.names.items.len;
    }

    pub fn getName(self: Apps, idx: usize) []const u8 {
        const str = self.names.items[idx];
        return self.buffer.items[str.start..str.end];
    }

    pub fn getExec(self: Apps, idx: usize) []const u8 {
        const str = self.execs.items[idx];
        return self.buffer.items[str.start..str.end];
    }

    pub fn getIconBytes(self: Apps, idx: usize) ?[]const u8 {
        if (self.icon_bytes.items[idx]) |bytes| {
            return self.buffer.items[bytes.start..bytes.end];
        }
        return null;
    }

    pub fn isTerminal(self: Apps, idx: usize) bool {
        return self.terminal.items[idx];
    }

    fn addName(self: *Apps, name: []const u8) !void {
        for (self.order.items, 0..) |n, i| {
            const existing_name = self.names.items[n];
            if (std.ascii.lessThanIgnoreCase(name, self.buffer.items[existing_name.start..existing_name.end])) {
                try self.order.insert(self.arena.allocator(), i, self.names.items.len);
                break;
            }
        } else {
            try self.order.append(self.arena.allocator(), self.names.items.len);
        }

        try self.names.append(
            self.arena.allocator(),
            .{ .start = self.buffer.items.len, .end = self.buffer.items.len + name.len },
        );
        try self.buffer.appendSlice(self.arena.allocator(), name);
    }

    fn addExec(self: *Apps, exec: []const u8) !void {
        try self.execs.append(
            self.arena.allocator(),
            .{ .start = self.buffer.items.len, .end = self.buffer.items.len + exec.len },
        );
        try self.buffer.appendSlice(self.arena.allocator(), exec);
    }

    fn addIconBytes(self: *Apps, icon_bytes: ?[]const u8) !void {
        if (icon_bytes) |bytes| {
            try self.icon_bytes.append(
                self.arena.allocator(),
                .{ .start = self.buffer.items.len, .end = self.buffer.items.len + bytes.len },
            );
            try self.buffer.appendSlice(self.arena.allocator(), bytes);
        } else {
            try self.icon_bytes.append(self.arena.allocator(), null);
        }
    }
};

pub const Env = struct {
    home: ?[]const u8 = null,
    xdg_data_home: ?[]const u8 = null,
    xdg_data_dirs: ?[]const u8 = null,
};

pub fn scan(scan_io: std.Io, gpa: std.mem.Allocator, env: Env) !Apps {
    var apps = Apps.init(gpa);
    errdefer apps.deinit();

    var seen_bases: std.ArrayList([]const u8) = .empty;
    defer seen_bases.deinit(gpa);

    try addDataDir(scan_io, gpa, &apps, &seen_bases, "/usr/share/");
    try addDataDir(scan_io, gpa, &apps, &seen_bases, "/run/current-system/sw/share/");

    // An empty or relative XDG_DATA_HOME is invalid per the XDG spec and must
    // behave as if it were unset, so the ~/.local/share fallback still applies.
    const data_home = if (env.xdg_data_home) |dir|
        if (dir.len > 0 and std.fs.path.isAbsolute(dir)) dir else null
    else
        null;
    if (data_home) |xdg_home| {
        try addDataDir(scan_io, gpa, &apps, &seen_bases, xdg_home);
    } else if (env.home) |home| {
        var home_buffer: [4096]u8 = undefined;
        if (std.fmt.bufPrint(&home_buffer, "{s}/.local/share", .{home})) |local_share| {
            try addDataDir(scan_io, gpa, &apps, &seen_bases, local_share);
        } else |_| {}
    }

    if (env.xdg_data_dirs) |data_dirs| {
        var it = std.mem.tokenizeScalar(u8, data_dirs, ':');
        while (it.next()) |dir| {
            if (dir.len > 0) try addDataDir(scan_io, gpa, &apps, &seen_bases, dir);
        }
    }

    return apps;
}

const IconChoice = struct {
    path: []const u8,
    score: u32,
};

const IconIndex = struct {
    map: std.StringHashMap(IconChoice),

    fn deinit(self: *IconIndex) void {
        self.map.deinit();
    }
};

fn addDataDir(
    scan_io: std.Io,
    gpa: std.mem.Allocator,
    apps: *Apps,
    seen: *std.ArrayList([]const u8),
    base: []const u8,
) !void {
    if (base.len == 0) return;

    var path_buffer: [4096]u8 = undefined;
    const normalized = if (base[base.len - 1] == '/')
        base
    else
        std.fmt.bufPrint(&path_buffer, "{s}/", .{base}) catch return;

    if (!std.fs.path.isAbsolute(normalized)) {
        std.log.warn("ignoring non-absolute data directory: {s}", .{normalized});
        return;
    }

    for (seen.items) |existing| {
        if (std.mem.eql(u8, existing, normalized)) return;
    }

    // The dedup list outlives this function, so its strings must live in the
    // Apps arena, not in the per-directory arena below.
    const owned = try apps.arena.allocator().dupe(u8, normalized);
    try seen.append(gpa, owned);

    var dir_arena = std.heap.ArenaAllocator.init(gpa);
    defer dir_arena.deinit();

    scanApps(scan_io, apps, dir_arena.allocator(), owned) catch |err| {
        std.log.warn("failed to scan {s}: {s}", .{ owned, @errorName(err) });
    };
}

fn buildIconIndex(
    scan_io: std.Io,
    gpa: std.mem.Allocator,
    base_path: []const u8,
) !IconIndex {
    var index: IconIndex = .{ .map = std.StringHashMap(IconChoice).init(gpa) };
    errdefer index.deinit();

    var path_buffer: [4096]u8 = undefined;
    const icons_path = std.fmt.bufPrint(&path_buffer, "{s}icons/", .{base_path}) catch return index;

    var dir = std.Io.Dir.openDirAbsolute(scan_io, icons_path, .{ .iterate = true }) catch return index;
    defer dir.close(scan_io);

    var walker = dir.walk(gpa) catch return index;
    defer walker.deinit();

    while (try walker.next(scan_io)) |entry| {
        if (entry.kind != .file and entry.kind != .sym_link) continue;
        if (!std.mem.endsWith(u8, entry.basename, ".png")) continue;

        const name = entry.basename[0 .. entry.basename.len - 4];
        const score = iconScore(entry.path);

        if (index.map.getPtr(name)) |choice| {
            if (score >= choice.score) continue;
            choice.path = try std.fmt.allocPrint(gpa, "{s}{s}", .{ icons_path, entry.path });
            choice.score = score;
        } else {
            const key = try gpa.dupe(u8, name);
            const path = try std.fmt.allocPrint(gpa, "{s}{s}", .{ icons_path, entry.path });
            try index.map.put(key, .{ .path = path, .score = score });
        }
    }

    return index;
}

fn scanApps(scan_io: std.Io, apps: *Apps, allocator: std.mem.Allocator, base_path: []const u8) !void {
    var path_buffer: [4096]u8 = undefined;
    const applications_path = std.fmt.bufPrint(&path_buffer, "{s}applications/", .{base_path}) catch return;

    var dir = std.Io.Dir.openDirAbsolute(scan_io, applications_path, .{ .iterate = true }) catch return;
    defer dir.close(scan_io);

    var icon_index = try buildIconIndex(scan_io, allocator, base_path);
    defer icon_index.deinit();

    var walker = try dir.walk(allocator);
    defer walker.deinit();

    var file_arena = std.heap.ArenaAllocator.init(allocator);
    defer file_arena.deinit();

    while (try walker.next(scan_io)) |entry| {
        defer _ = file_arena.reset(.retain_capacity);
        if (entry.kind != .file and entry.kind != .sym_link) continue;
        if (!std.mem.endsWith(u8, entry.basename, ".desktop")) continue;

        var file = dir.openFile(scan_io, entry.path, .{}) catch continue;
        defer file.close(scan_io);

        var read_buffer: [8192]u8 = undefined;
        var reader = file.reader(scan_io, &read_buffer);

        var name: []const u8 = "";
        var exec: []const u8 = "";
        var icon_name: []const u8 = "";
        var skip = false;
        var terminal = false;
        var in_desktop_entry = false;

        while (reader.interface.takeDelimiter('\n')) |maybe_line| {
            const raw_line = maybe_line orelse break;
            const line = std.mem.trimEnd(u8, raw_line, "\r");
            if (line.len == 0) continue;

            if (line[0] == '[') {
                in_desktop_entry = std.mem.eql(u8, line, "[Desktop Entry]");
                continue;
            }
            if (!in_desktop_entry) continue;

            if (name.len == 0 and std.mem.startsWith(u8, line, "Name=")) {
                name = try file_arena.allocator().dupe(u8, line[5..]);
            } else if (exec.len == 0 and std.mem.startsWith(u8, line, "Exec=")) {
                exec = try file_arena.allocator().dupe(u8, line[5..]);
            } else if (icon_name.len == 0 and std.mem.startsWith(u8, line, "Icon=")) {
                icon_name = try file_arena.allocator().dupe(u8, line[5..]);
            } else if (std.mem.eql(u8, line, "Hidden=true") or std.mem.eql(u8, line, "NoDisplay=true")) {
                skip = true;
                break;
            } else if (std.mem.eql(u8, line, "Terminal=true")) {
                terminal = true;
            }
        } else |err| switch (err) {
            error.StreamTooLong => std.log.warn("skipping over-long line in {s}", .{entry.path}),
            else => std.log.warn("failed to read {s}: {s}", .{ entry.path, @errorName(err) }),
        }

        if (skip) continue;
        if (name.len == 0 or exec.len == 0) continue;

        var already_found = false;
        for (0..apps.len()) |i| {
            if (std.mem.eql(u8, name, apps.getName(i))) {
                already_found = true;
                break;
            }
        }
        if (already_found) continue;

        var icon_path: []const u8 = "";
        if (icon_name.len > 0 and icon_name[0] == '/') {
            if (std.mem.endsWith(u8, icon_name, ".png")) icon_path = icon_name;
        } else if (icon_name.len > 0) {
            if (icon_index.map.get(icon_name)) |choice| icon_path = choice.path;
        }

        var icon_bytes: ?[]const u8 = null;
        if (icon_path.len > 0) {
            icon_bytes = std.Io.Dir.readFileAlloc(.cwd(), scan_io, icon_path, file_arena.allocator(), .limited(256 * 1024)) catch null;
        }

        try apps.addName(name);
        try apps.addExec(exec);
        try apps.addIconBytes(icon_bytes);
        try apps.terminal.append(apps.arena.allocator(), terminal);
    }
}

fn iconScore(path: []const u8) u32 {
    const hint = iconSizeHint(path);
    if (hint == 0) return 1000;
    return @intCast(@abs(hint - icon_size));
}

fn iconSizeHint(path: []const u8) i32 {
    var parts = std.mem.tokenizeScalar(u8, path, '/');
    while (parts.next()) |component| {
        const x = std.mem.findScalar(u8, component, 'x') orelse continue;
        const left = std.fmt.parseInt(i32, component[0..x], 10) catch continue;

        var right_text = component[x + 1 ..];
        if (std.mem.indexOfScalar(u8, right_text, '@')) |at| {
            right_text = right_text[0..at];
        }
        const right = std.fmt.parseInt(i32, right_text, 10) catch continue;
        if (left == right) return left;
    }
    return 0;
}
