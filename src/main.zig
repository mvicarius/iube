const std = @import("std");
const dvui = @import("dvui");
const SDLBackend = @import("sdl-backend");

const c = SDLBackend.c;

pub const std_options: std.Options = .{ .log_level = .warn };

const window_width = 640;
const window_height = 360;
const margin = 16;
const row_step: f32 = 42.0;

const extra_dark = dvui.Color{ .r = 0x02, .g = 0x05, .b = 0x07 };
const dark = dvui.Color{ .r = 0x09, .g = 0x15, .b = 0x1d };
const accent = dvui.Color{ .r = 0x08, .g = 0x5f, .b = 0x6c };
const muted = dvui.Color{ .r = 0x5a, .g = 0x7a, .b = 0x82 };

const AppEntry = struct {
    name: []const u8,
    exec: []const u8,
    icon_path: []const u8,
    icon_bytes: ?[]const u8 = null,
    terminal: bool = false,
};

const AppList = struct {
    items: std.ArrayList(AppEntry) = .empty,
    arena: std.heap.ArenaAllocator,

    fn init(gpa: std.mem.Allocator) AppList {
        return .{ .arena = std.heap.ArenaAllocator.init(gpa) };
    }

    fn deinit(self: *AppList) void {
        self.arena.deinit();
    }

    fn allocator(self: *AppList) std.mem.Allocator {
        return self.arena.allocator();
    }

    fn add(self: *AppList, entry: AppEntry) !void {
        try self.items.append(self.allocator(), entry);
    }

    fn sortByName(self: *AppList) void {
        std.mem.sort(AppEntry, self.items.items, {}, struct {
            fn lessThan(_: void, a: AppEntry, b: AppEntry) bool {
                return std.ascii.lessThanIgnoreCase(a.name, b.name);
            }
        }.lessThan);
    }
};

var apps: AppList = undefined;
var io: std.Io = undefined;
var window_open = true;
var launch_index: ?usize = null;
var selected_index: ?usize = null;
var enter_pressed: bool = false;
var query_buf: [256]u8 = @splat(0);
var terminal_env: ?[]const u8 = null;
var visible_indices: []usize = &.{};
var visible_count: usize = 0;
var select_last: bool = false;

fn sleepMs(sleep_io: std.Io, ms: i64) void {
    const d = std.Io.Clock.Duration{
        .raw = std.Io.Duration.fromMilliseconds(ms),
        .clock = .awake,
    };
    d.sleep(sleep_io) catch {};
}

pub fn main(init: std.process.Init) !void {
    const on_hyprland = init.environ_map.get("HYPRLAND_INSTANCE_SIGNATURE") != null;
    if (on_hyprland) {
        _ = registerHyprlandRule(init.io, init.gpa);
        // Hyprland applies `hyprctl eval` window rules asynchronously. Give
        // the rule engine a moment before mapping the window.
    }

    io = init.io;
    terminal_env = init.environ_map.get("TERMINAL");
    apps = AppList.init(init.gpa);
    defer apps.deinit();

    var seen_bases: std.ArrayList([]const u8) = .empty;
    defer seen_bases.deinit(init.gpa);

    try addDataDir(init.io, init.gpa, &apps, &seen_bases, "/usr/share/");
    try addDataDir(init.io, init.gpa, &apps, &seen_bases, "/run/current-system/sw/share/");

    const xdg_home = init.environ_map.get("XDG_DATA_HOME") orelse "";
    if (xdg_home.len > 0) {
        try addDataDir(init.io, init.gpa, &apps, &seen_bases, xdg_home);
    } else if (init.environ_map.get("HOME")) |home| {
        var home_buffer: [4096]u8 = undefined;
        if (std.fmt.bufPrint(&home_buffer, "{s}/.local/share", .{home})) |local_share| {
            try addDataDir(init.io, init.gpa, &apps, &seen_bases, local_share);
        } else |_| {}
    }

    if (init.environ_map.get("XDG_DATA_DIRS")) |data_dirs| {
        var it = std.mem.tokenizeScalar(u8, data_dirs, ':');
        while (it.next()) |dir| {
            if (dir.len > 0) try addDataDir(init.io, init.gpa, &apps, &seen_bases, dir);
        }
    }

    apps.sortByName();

    visible_indices = try init.gpa.alloc(usize, apps.items.items.len);
    defer init.gpa.free(visible_indices);

    var backend = try SDLBackend.initWindow(.{
        .io = init.io,
        .environ_map = init.environ_map,
        .size = .{ .w = window_width, .h = window_height },
        .vsync = true,
        .title = "iube",
        .app = "iube",
        .org = "dev.iube",
        .persist_window_geometry = false,
        .transparent = true,
    });
    defer backend.deinit();

    const theme: dvui.Theme = .{
        .name = "Adwaita Dark",
        .dark = true,

        .embedded_fonts = dvui.Theme.builtin.adwaita_dark.embedded_fonts,

        .font_body = .find(.{ .family = "Vera Sans" }),
        .font_heading = .find(.{ .family = "Vera Sans", .weight = .bold }),
        .font_title = .find(.{ .family = "Vera Sans", .size = dvui.Font.DefaultSize + 2 }),
        .font_mono = .find(.{ .family = "Vera Sans Mono" }),

        .focus = accent,

        .fill = extra_dark,
        .fill_hover = extra_dark.lighten(21),
        .fill_press = extra_dark.lighten(30),
        .text = dvui.Color.white,
        .text_select = .{ .r = 0x32, .g = 0x60, .b = 0x98 },
        .border = extra_dark.lighten(39),

        .control = .{
            .fill = .{ .r = 0x40, .g = 0x40, .b = 0x40 },
            .fill_hover = extra_dark.lighten(21),
            .fill_press = extra_dark.lighten(30),
        },

        .window = .{
            .fill = .{ .r = 0x2b, .g = 0x2b, .b = 0x2b },
        },

        .highlight = .{
            .fill = accent,
            .fill_hover = dark,
            .fill_press = dark,
            .text = dvui.Color.white,
            .border = accent,
        },

        .err = .{
            .fill = dvui.Color.black,
            .fill_hover = dvui.Color.gray,
            .fill_press = dvui.Color.gray,
            .text = dvui.Color.white,
            .border = dvui.Color.red,
        },
    };

    var win = try dvui.Window.init(@src(), init.gpa, backend.backend(), .{
        .theme = theme,
        .open_flag = &window_open,
    });
    defer win.deinit();

    if (on_hyprland) {
        // Commit one empty (transparent) frame. Hyprland applies the float/size
        // rule to a mapped/committed surface; this frame triggers that without
        // showing the oversized layout. The window is transparent until the
        // real UI frame below.
        {
            const nstime = win.beginWait(false);
            try win.begin(nstime);
            _ = try win.end(.{});
        }
    }
    var interrupted = false;

    // used time only startup time
    window_open = false;

    while (window_open) {
        const nstime = win.beginWait(interrupted);
        try win.begin(nstime);

        var event: c.SDL_Event = undefined;
        while (c.SDL_PollEvent(&event)) {
            if (event.type == c.SDL_EVENT_KEY_DOWN) {
                const key = event.key.key;
                if (key == c.SDLK_ESCAPE) {
                    window_open = false;
                    continue;
                }

                if (key == c.SDLK_DOWN) {
                    select_last = false;
                    if (selected_index) |idx| {
                        selected_index = idx +| 1;
                    } else {
                        selected_index = if (visible_count > 0) 0 else null;
                    }
                }

                if (key == c.SDLK_UP) {
                    if (selected_index) |idx| {
                        if (idx > 0) {
                            selected_index = idx - 1;
                        }
                    } else {
                        select_last = true;
                    }
                }

                if (key == c.SDLK_KP_ENTER or key == c.SDLK_RETURN) {
                    enter_pressed = true;
                }
            }

            _ = try backend.addEvent(&win, event);
        }

        uiFrame();

        const end_micros = try win.end(.{});
        if (launch_index) |idx| {
            launch_index = null;
            enter_pressed = false;
            launch(idx);
            window_open = false;
        }
        if (!window_open) break;

        const wait = win.waitTime(end_micros);

        interrupted = try backend.waitEventTimeout(wait);
    }
}

fn uiFrame() void {
    const win_rect = dvui.currentWindow().data().rect;
    var root = dvui.box(@src(), .{ .dir = .vertical }, .{
        .rect = win_rect,
        .background = true,
        .padding = .all(margin),
        .corners = .all(10),
        .border = .all(1),
    });
    defer root.deinit();

    const te = dvui.textEntry(@src(), .{
        .text = .{ .buffer = &query_buf },
        .placeholder = "Search for your application…",
    }, .{
        .expand = .horizontal,
        .margin = .{ .x = 0, .y = 0, .w = 0, .h = 12 },
        .padding = .all(8),
        .color_fill = .{ .color = dark },
        .corners = .all(6),
        .font = .theme(.heading),
    });

    const text_changed = te.text_changed;
    const query = te.textGet();
    const te_id = te.data().id;
    te.deinit();

    if (dvui.focusedWidgetIdInCurrentSubwindow() != te_id) {
        dvui.focusWidget(te_id, null, null);
    }

    var scroll = dvui.scrollArea(@src(), .{}, .{ .expand = .both, .color_fill = .{ .color = extra_dark } });
    defer scroll.deinit();

    visible_count = 0;
    for (apps.items.items, 0..) |app, idx| {
        if (!matchesQuery(app.name, query)) continue;
        visible_indices[visible_count] = idx;
        visible_count += 1;
    }

    if (select_last) {
        selected_index = if (visible_count > 0) visible_count - 1 else null;
        select_last = false;
    }
    if (text_changed) {
        selected_index = null;
    }
    if (selected_index) |idx| {
        if (visible_count == 0) {
            selected_index = null;
        } else if (idx >= visible_count) {
            selected_index = visible_count - 1;
        }
    } else if (query.len > 0 and visible_count > 0) {
        selected_index = 0;
    }

    for (visible_indices[0..visible_count], 0..) |app_idx, show_idx| {
        if (appRow(&apps.items.items[app_idx], app_idx, show_idx)) launch_index = app_idx;
    }
    enter_pressed = false;

    if (selected_index) |sel| {
        const top_limit = row_step * @as(f32, @floatFromInt(sel));
        const bot_limit = top_limit - scroll.si.viewport.h + row_step - 4;

        if (scroll.si.offset(.vertical) > top_limit) {
            scroll.si.scrollToOffset(.vertical, top_limit);
        }

        if (scroll.si.offset(.vertical) < bot_limit) {
            scroll.si.scrollToOffset(.vertical, bot_limit);
        }
    }

    if (visible_count == 0) {
        dvui.label(@src(), "No matches", .{}, .{ .color_text = .{ .color = muted } });
    }
}

fn appRow(app: *const AppEntry, idx: usize, show_idx: usize) bool {
    const src = @src();
    const row_id = dvui.parentGet().extendId(src, idx);
    const was_hovered = dvui.dataGet(null, row_id, "hover", bool) orelse false;
    const color = if (selected_index == show_idx) accent else if (was_hovered) dark.lighten(5) else dark;

    var row = dvui.box(src, .{ .dir = .horizontal }, .{
        .id_extra = idx,
        .expand = .horizontal,
        .padding = .{ .x = 8, .y = 6, .w = 8, .h = 6 },
        .margin = .{ .x = 0, .y = 0, .w = 0, .h = 2 },
        .background = true,
        .color_fill = .{ .color = color },
        .corners = .all(6),
    });
    defer row.deinit();

    var hovered = false;
    const clicked = dvui.clicked(row.data(), .{ .hovered = &hovered });
    dvui.dataSet(null, row_id, "hover", hovered);

    if (app.icon_bytes) |bytes| {
        _ = dvui.image(@src(), .{
            .source = .{ .imageFile = .{ .bytes = bytes, .name = app.icon_path } },
            .shrink = .ratio,
        }, .{
            .id_extra = idx,
            .min_size_content = .{ .w = 24, .h = 24 },
            .max_size_content = .{ .w = 24, .h = 24 },
            .margin = .{ .x = 0, .y = 0, .w = 10, .h = 0 },
            .gravity_y = 0.5,
            .label = .{ .text = app.name },
        });
    } else {
        var icon_box = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .id_extra = idx,
            .min_size_content = .{ .w = 24, .h = 24 },
            .max_size_content = .{ .w = 24, .h = 24 },
            .background = true,
            .corners = .all(4),
            .margin = .{ .x = 0, .y = 0, .w = 10, .h = 0 },
            .gravity_y = 0.5,
        });
        defer icon_box.deinit();
        dvui.label(@src(), "{s}", .{initial(app.name)}, .{
            .gravity_x = 0.5,
            .gravity_y = 0.5,
            .color_text = .{ .color = muted },
        });
    }

    dvui.labelNoFmt(@src(), app.name, .{}, .{
        .expand = .horizontal,
        .gravity_y = 0.5,
        .id_extra = idx,
    });

    return clicked or (selected_index == show_idx and enter_pressed);
}

fn initial(name: []const u8) []const u8 {
    if (name.len == 0 or name[0] >= 0x80) return "?";
    return name[0..1];
}

fn matchesQuery(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;

    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

fn launch(idx: usize) void {
    if (apps.items.items.len <= idx) return;
    const app = apps.items.items[idx];
    if (app.exec.len == 0) return;

    var command_buffer: [8192]u8 = undefined;
    const command = stripFieldCodes(app.exec, &command_buffer);

    if (app.terminal) {
        if (!launchInTerminal(command)) {
            std.log.err("no terminal emulator found for '{s}'", .{app.name});
        }
        return;
    }
    spawnCommand(command);
}

fn spawnCommand(command: []const u8) void {
    const argv = [_][]const u8{ "sh", "-c", command };
    _ = std.process.spawn(io, .{
        .argv = &argv,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch |err| {
        std.log.err("failed to launch '{s}': {s}", .{ command, @errorName(err) });
        return;
    };
}

/// Terminal=true .desktop entries have no window of their own. Run them inside
/// a terminal emulator. `$TERMINAL` wins; otherwise try common emulators.
fn launchInTerminal(command: []const u8) bool {
    if (terminal_env) |term| {
        var term_parts: [10][]const u8 = undefined;
        var term_count: usize = 0;
        var it = std.mem.tokenizeAny(u8, term, " \t");
        while (it.next()) |part| {
            if (term_count == term_parts.len) break;
            term_parts[term_count] = part;
            term_count += 1;
        }
        if (term_count > 0) {
            const args = term_parts[0..term_count];
            const base = std.fs.path.basename(args[0]);
            var suffix: []const []const u8 = &.{};
            if (std.mem.eql(u8, base, "wezterm")) {
                if (!hasArg(args, "start")) suffix = &.{ "start", "--" };
            } else if (std.mem.eql(u8, base, "gnome-terminal")) {
                if (!hasArg(args, "--")) suffix = &.{"--"};
            } else if (std.mem.eql(u8, base, "kitty") or
                std.mem.eql(u8, base, "foot") or
                std.mem.eql(u8, base, "xdg-terminal-exec"))
            {
                // These terminals take the command directly.
            } else if (!hasArg(args, "-e")) {
                suffix = &.{"-e"};
            }

            var prefix: [12][]const u8 = undefined;
            var n: usize = 0;
            for (args) |part| {
                prefix[n] = part;
                n += 1;
            }
            for (suffix) |part| {
                prefix[n] = part;
                n += 1;
            }
            if (spawnTerminal(prefix[0..n], command)) return true;
        }
    }

    const known = [_][]const []const u8{
        &.{ "ghostty", "-e" },
        &.{"kitty"},
        &.{"foot"},
        &.{ "alacritty", "-e" },
        &.{ "wezterm", "start", "--" },
        &.{ "xterm", "-e" },
        &.{ "konsole", "-e" },
        &.{ "gnome-terminal", "--" },
        &.{"xdg-terminal-exec"},
    };
    for (known) |prefix| {
        if (spawnTerminal(prefix, command)) return true;
    }
    return false;
}

fn hasArg(args: []const []const u8, needle: []const u8) bool {
    for (args) |arg| {
        if (std.mem.eql(u8, arg, needle)) return true;
    }
    return false;
}

fn spawnTerminal(prefix: []const []const u8, command: []const u8) bool {
    var argv: [16][]const u8 = undefined;
    var n: usize = 0;
    for (prefix) |arg| {
        argv[n] = arg;
        n += 1;
    }
    argv[n] = "sh";
    n += 1;
    argv[n] = "-c";
    n += 1;
    argv[n] = command;
    n += 1;

    _ = std.process.spawn(io, .{
        .argv = argv[0..n],
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch |err| {
        if (err != error.FileNotFound) {
            std.log.warn("failed to spawn terminal '{s}': {s}", .{ prefix[0], @errorName(err) });
        }
        return false;
    };
    return true;
}

fn stripFieldCodes(exec: []const u8, out: []u8) []const u8 {
    var write: usize = 0;
    var read: usize = 0;
    while (read < exec.len and write < out.len) {
        if (exec[read] == '%' and read + 1 < exec.len) {
            const code = exec[read + 1];
            switch (code) {
                '%' => {
                    out[write] = '%';
                    write += 1;
                },
                'f', 'F', 'u', 'U', 'i', 'c', 'k', 'd', 'D', 'n', 'N', 'v', 'm' => {},
                else => {
                    out[write] = '%';
                    write += 1;
                    if (write < out.len) {
                        out[write] = code;
                        write += 1;
                    }
                },
            }
            read += 2;
        } else {
            out[write] = exec[read];
            write += 1;
            read += 1;
        }
    }
    return out[0..write];
}

fn registerHyprlandRule(run_io: std.Io, gpa: std.mem.Allocator) bool {
    const rule =
        "hl.window_rule({ name = \"iube-runtime\", " ++
        "match = { class = \"^(iube)$\" }, " ++
        "float = true, center = true, pin = true, size = \"640 360\", " ++
        "border_size = 0, rounding = 8, no_shadow = true, no_blur = true, dim_around = true })";

    const result = std.process.run(gpa, run_io, .{
        .argv = &.{ "hyprctl", "eval", rule },
        .stdout_limit = .limited(4096),
        .stderr_limit = .limited(4096),
    }) catch |err| {
        std.log.warn("hyprctl eval failed: {s}", .{@errorName(err)});
        return false;
    };
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);

    if (result.stderr.len > 0) {
        std.log.warn("hyprctl: {s}", .{std.mem.trimEnd(u8, result.stderr, "\n")});
    }
    return true;
}

fn addDataDir(
    scan_io: std.Io,
    gpa: std.mem.Allocator,
    list: *AppList,
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

    const owned = try list.allocator().dupe(u8, normalized);
    try seen.append(gpa, owned);

    scanApps(scan_io, gpa, owned, list) catch |err| {
        std.log.warn("failed to scan {s}: {s}", .{ owned, @errorName(err) });
    };
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

fn buildIconIndex(
    scan_io: std.Io,
    gpa: std.mem.Allocator,
    list: *AppList,
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

    while (true) {
        const maybe = walker.next(scan_io) catch return index;
        const entry = maybe orelse break;
        if (entry.kind != .file and entry.kind != .sym_link) continue;

        const basename = entry.basename;
        if (!std.mem.endsWith(u8, basename, ".png")) continue;

        const name = basename[0 .. basename.len - 4];
        const score = iconScore(entry.path);

        if (index.map.getPtr(name)) |choice| {
            if (score >= choice.score) continue;
            choice.path = try std.fmt.allocPrint(list.allocator(), "{s}{s}", .{ icons_path, entry.path });
            choice.score = score;
        } else {
            const key = try list.allocator().dupe(u8, name);
            const path = try std.fmt.allocPrint(list.allocator(), "{s}{s}", .{ icons_path, entry.path });
            try index.map.put(key, .{ .path = path, .score = score });
        }
    }

    return index;
}

fn scanApps(scan_io: std.Io, gpa: std.mem.Allocator, base_path: []const u8, list: *AppList) !void {
    var path_buffer: [4096]u8 = undefined;
    const applications_path = std.fmt.bufPrint(&path_buffer, "{s}applications/", .{base_path}) catch return;

    var dir = std.Io.Dir.openDirAbsolute(scan_io, applications_path, .{ .iterate = true }) catch return;
    defer dir.close(scan_io);

    var icon_index = try buildIconIndex(scan_io, gpa, list, base_path);
    defer icon_index.deinit();

    var walker = try dir.walk(gpa);
    defer walker.deinit();

    while (try walker.next(scan_io)) |entry| {
        if (entry.kind != .file and entry.kind != .sym_link) continue;
        if (!std.mem.endsWith(u8, entry.basename, ".desktop")) continue;

        var file = dir.openFile(scan_io, entry.path, .{}) catch continue;
        defer file.close(scan_io);

        var read_buffer: [8192]u8 = undefined;
        var reader = file.reader(scan_io, &read_buffer);

        var name: []const u8 = "";
        var exec: []const u8 = "";
        var icon_name: []const u8 = "";
        var hidden = false;
        var no_display = false;
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
                name = try list.allocator().dupe(u8, line[5..]);
            } else if (exec.len == 0 and std.mem.startsWith(u8, line, "Exec=")) {
                exec = try list.allocator().dupe(u8, line[5..]);
            } else if (icon_name.len == 0 and std.mem.startsWith(u8, line, "Icon=")) {
                icon_name = try list.allocator().dupe(u8, line[5..]);
            } else if (std.mem.eql(u8, line, "Hidden=true")) {
                hidden = true;
            } else if (std.mem.eql(u8, line, "NoDisplay=true")) {
                no_display = true;
            } else if (std.mem.eql(u8, line, "Terminal=true")) {
                terminal = true;
            }
        } else |err| switch (err) {
            error.StreamTooLong => std.log.warn("skipping over-long line in {s}", .{entry.path}),
            else => std.log.warn("failed to read {s}: {s}", .{ entry.path, @errorName(err) }),
        }

        if (hidden or no_display) continue;
        if (name.len == 0 or exec.len == 0) continue;

        var icon_path: []const u8 = "";
        if (icon_name.len > 0 and icon_name[0] == '/') {
            if (std.mem.endsWith(u8, icon_name, ".png")) icon_path = icon_name;
        } else if (icon_name.len > 0) {
            if (icon_index.map.get(icon_name)) |choice| icon_path = choice.path;
        }

        var icon_bytes: ?[]const u8 = null;
        if (icon_path.len > 0) {
            icon_bytes = std.Io.Dir.readFileAlloc(.cwd(), scan_io, icon_path, list.allocator(), .limited(256 * 1024)) catch null;
        }

        try list.add(.{
            .name = name,
            .exec = exec,
            .icon_path = icon_path,
            .icon_bytes = icon_bytes,
            .terminal = terminal,
        });
    }
}

fn iconScore(path: []const u8) u32 {
    const hint = iconSizeHint(path);
    if (hint == 0) return 1000;
    return @intCast(@abs(hint - 32));
}

fn iconSizeHint(path: []const u8) i32 {
    var parts = std.mem.tokenizeScalar(u8, path, '/');
    while (parts.next()) |component| {
        const x = std.mem.indexOfScalar(u8, component, 'x') orelse continue;
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
