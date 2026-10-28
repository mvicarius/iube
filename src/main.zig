const std = @import("std");
const wayland = @import("wayland.zig");
const desktop = @import("desktop.zig");
const render = @import("render.zig");
const png = @import("png.zig");
const font = @import("font.zig");

pub const std_options: std.Options = .{ .log_level = .warn };

const window_width = 640;
const window_height = 360;
const margin = 16;
const small_margin = 8;
const gap = 4;
const icon_size = 32;
const row_height = icon_size + small_margin * 2;
const row_step = row_height + gap;
const search_height = 40;
const corner_radius = 16;
const search_radius = 8;
const row_radius = 8;
const text_glyph_scale = 1;
const blink_period_ms = 530;

const extra_dark = render.Color{ .r = 0x02, .g = 0x05, .b = 0x07 };
const dark = render.Color{ .r = 0x09, .g = 0x15, .b = 0x1d };
const accent = render.Color{ .r = 0x08, .g = 0x5f, .b = 0x6c };
const muted = render.Color{ .r = 0x5a, .g = 0x7a, .b = 0x82 };
const border_color = extra_dark.lighten(39);
const control = render.Color{ .r = 0x40, .g = 0x40, .b = 0x40 };
const white = render.Color{ .r = 0xff, .g = 0xff, .b = 0xff };

const key_escape: u32 = 0xff1b;
const key_return: u32 = 0xff0d;
const key_kp_enter: u32 = 0xff8d;
const key_backspace: u32 = 0xff08;
const key_up: u32 = 0xff52;
const key_down: u32 = 0xff54;
const key_left: u32 = 0xff51;
const key_right: u32 = 0xff53;

const IconSlot = struct {
    tried: bool = false,
    image: ?png.Image = null,
};

const App = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    apps: *desktop.Apps,
    client: *wayland.Client,
    visible: []usize,
    visible_count: usize = 0,
    query: [256]u8 = @splat(0),
    query_len: usize = 0,
    selected: ?usize = null,
    scroll: i32 = 0,
    hover: ?usize = null,
    pointer_inside: bool = false,
    pointer_x: f32 = 0,
    pointer_y: f32 = 0,
    icons: []IconSlot,
    terminal_env: ?[]const u8,
    running: bool = true,
    dirty: bool = true,
    last_input_ms: i64 = 0,
    blink_on: bool = true,

    last_key: ?wayland.Key = null,
    repeat_at: ?i64 = null,
    repeat_rate: i32 = 25,
    repeat_delay: i32 = 600,
};

pub fn main(init: std.process.Init) !void {
    const on_hyprland = init.environ_map.get("HYPRLAND_INSTANCE_SIGNATURE") != null;

    var client: wayland.Client = undefined;
    try client.init(init.gpa);
    defer client.deinit();

    // Layer shell gives us a proper centred overlay without compositor rules.
    // Other compositors get an xdg-toplevel; on Hyprland that needs the old
    // runtime rule, so install it before the window is mapped.
    if (!client.use_layer_shell and on_hyprland) {
        _ = registerHyprlandRule(init.io, init.gpa);
    }

    var apps = try desktop.scan(init.io, init.gpa, .{
        .home = init.environ_map.get("HOME"),
        .xdg_data_home = init.environ_map.get("XDG_DATA_HOME"),
        .xdg_data_dirs = init.environ_map.get("XDG_DATA_DIRS"),
    });
    defer apps.deinit();

    const visible = try init.gpa.alloc(usize, apps.len());
    defer init.gpa.free(visible);

    const icons = try init.gpa.alloc(IconSlot, apps.len());
    defer {
        for (icons) |*slot| {
            if (slot.image) |*image| image.deinit(init.gpa);
        }
        init.gpa.free(icons);
    }
    @memset(icons, .{});

    var app = App{
        .gpa = init.gpa,
        .io = init.io,
        .apps = &apps,
        .client = &client,
        .visible = visible,
        .icons = icons,
        .terminal_env = init.environ_map.get("TERMINAL"),
    };
    recomputeVisible(&app);
    app.last_input_ms = nowMs(init.io);

    try client.createWindow();

    while (app.running) {
        const now = nowMs(init.io);

        var timeout: i64 = blink_period_ms - @mod(now, blink_period_ms);
        if (app.repeat_at) |repeat_at| {
            const until_repeat = repeat_at - now;
            timeout = @min(timeout, until_repeat);
        }
        timeout = std.math.clamp(timeout, 0, 1000);

        try client.poll(@intCast(timeout));

        while (client.nextEvent()) |event| {
            handleEvent(&app, event);
            if (!app.running) break;
        }
        if (!app.running) break;

        const after = nowMs(init.io);

        if (app.repeat_at) |repeat_at| {
            if (after >= repeat_at) {
                if (app.last_key) |key| {
                    handleKey(&app, key, true);
                }
                const interval: i64 = if (app.repeat_rate > 0) @max(1, @divTrunc(1000, app.repeat_rate)) else 1000;
                app.repeat_at = if (app.last_key != null) after + interval else null;
            }
        }

        const blink_now = @mod(after, blink_period_ms * 2) < blink_period_ms;
        if (blink_now != app.blink_on) {
            app.blink_on = blink_now;
            app.dirty = true;
        }

        if (app.dirty) {
            renderFrame(&app, after);
            app.dirty = false;
        }
    }
}

fn nowMs(io: std.Io) i64 {
    return std.Io.Clock.Timestamp.now(io, .awake).raw.toMilliseconds();
}

fn handleEvent(app: *App, event: wayland.Event) void {
    switch (event) {
        .configure => {
            app.dirty = true;
        },
        .redraw => {
            app.dirty = true;
        },
        .close => {
            app.running = false;
        },
        .key => |key| {
            handleKey(app, key, false);
            if (key.pressed) {
                app.last_input_ms = nowMs(app.io);
                app.blink_on = true;
                if (isRepeatable(key)) {
                    app.last_key = key;
                    app.repeat_at = app.last_input_ms + app.repeat_delay;
                } else {
                    app.last_key = null;
                    app.repeat_at = null;
                }
            } else if (app.last_key) |last| {
                if (last.keysym == key.keysym) {
                    app.last_key = null;
                    app.repeat_at = null;
                }
            }
        },
        .keyboard_leave => {
            app.last_key = null;
            app.repeat_at = null;
        },
        .pointer_enter => |p| {
            app.pointer_inside = true;
            app.pointer_x = p.x;
            app.pointer_y = p.y;
            updateHover(app);
            updateCursor(app);
        },
        .pointer_leave => {
            app.pointer_inside = false;
            if (app.hover != null) {
                app.hover = null;
                app.dirty = true;
            }
        },
        .pointer_motion => |p| {
            app.pointer_inside = true;
            app.pointer_x = p.x;
            app.pointer_y = p.y;
            updateHover(app);
            updateCursor(app);
        },
        .pointer_button => |button| {
            if (button.pressed and button.button == 0x110) {
                if (hitRow(app, app.pointer_x, app.pointer_y)) |index| {
                    launch(app, app.visible[index]);
                    app.running = false;
                }
            }
        },
        .pointer_axis => |axis| {
            const max_scroll = maxScroll(app);
            app.scroll = std.math.clamp(app.scroll + @as(i32, @intFromFloat(axis.delta * 4.0)), 0, max_scroll);
            updateHover(app);
            app.dirty = true;
        },
        .repeat_info => |info| {
            app.repeat_rate = info.rate;
            app.repeat_delay = info.delay;
            if (info.rate <= 0) {
                app.last_key = null;
                app.repeat_at = null;
            }
        },
    }
}

fn handleKey(app: *App, key: wayland.Key, is_repeat: bool) void {
    if (!key.pressed) return;

    if (key.keysym == key_escape) {
        app.running = false;
        return;
    }

    if (!is_repeat and (key.keysym == key_return or key.keysym == key_kp_enter)) {
        if (app.selected) |selected| {
            if (selected < app.visible_count) {
                launch(app, app.visible[selected]);
                app.running = false;
            }
        }
        return;
    }

    if (key.keysym == key_down) {
        if (app.selected) |selected| {
            if (app.visible_count > 0) {
                app.selected = @min(selected + 1, app.visible_count - 1);
            }
        } else if (app.visible_count > 0) {
            app.selected = 0;
        }
        ensureSelectionVisible(app);
        updateHover(app);
        app.dirty = true;
        return;
    }

    if (key.keysym == key_up) {
        if (app.selected) |selected| {
            if (selected > 0) app.selected = selected - 1;
        } else if (app.visible_count > 0) {
            app.selected = app.visible_count - 1;
        }
        ensureSelectionVisible(app);
        updateHover(app);
        app.dirty = true;
        return;
    }

    if (key.keysym == key_left or key.keysym == key_right) {
        return;
    }

    if (key.keysym == key_backspace) {
        if (app.query_len > 0) {
            removeLastCodepoint(app);
            onQueryChanged(app);
        }
        return;
    }

    if (key.mods.ctrl and (key.keysym == 'u' or key.keysym == 'U')) {
        app.query_len = 0;
        onQueryChanged(app);
        return;
    }

    if (key.mods.ctrl or key.mods.alt or key.mods.super) return;
    if (key.text_len == 0) return;

    const text = key.text[0..key.text_len];
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        const byte = text[i];
        if (byte < 0x20 or byte == 0x7f) continue;
        if (app.query_len >= app.query.len) break;
        app.query[app.query_len] = byte;
        app.query_len += 1;
    }
    onQueryChanged(app);
}

fn isRepeatable(key: wayland.Key) bool {
    if (key.text_len > 0) return true;
    return key.keysym == key_backspace or key.keysym == key_up or key.keysym == key_down;
}

fn removeLastCodepoint(app: *App) void {
    if (app.query_len == 0) return;
    var index = app.query_len - 1;
    while (index > 0 and (app.query[index] & 0xc0) == 0x80) : (index -= 1) {}
    app.query_len = index;
}

fn onQueryChanged(app: *App) void {
    recomputeVisible(app);
    app.scroll = 0;
    app.selected = if (app.query_len > 0 and app.visible_count > 0) 0 else null;
    updateHover(app);
    app.dirty = true;
}

fn recomputeVisible(app: *App) void {
    const needle = app.query[0..app.query_len];
    app.visible_count = 0;
    for (app.apps.order.items) |app_index| {
        if (!matchesQuery(app.apps.getName(app_index), needle)) continue;
        app.visible[app.visible_count] = app_index;
        app.visible_count += 1;
    }
    if (app.selected) |selected| {
        if (app.visible_count == 0) {
            app.selected = null;
        } else if (selected >= app.visible_count) {
            app.selected = app.visible_count - 1;
        }
    }
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

fn listGeometry(app: *App) struct { x: i32, y: i32, w: i32, h: i32 } {
    const width: i32 = @intCast(app.client.logical_width);
    const height: i32 = @intCast(app.client.logical_height);
    const list_y = margin + search_height + margin;
    return .{
        .x = margin,
        .y = list_y,
        .w = @max(0, width - margin * 2),
        .h = @max(0, height - list_y - margin),
    };
}

fn maxScroll(app: *App) i32 {
    const geometry = listGeometry(app);
    const content = @as(i32, @intCast(app.visible_count)) * row_step;
    return @max(0, content - geometry.h);
}

fn ensureSelectionVisible(app: *App) void {
    const geometry = listGeometry(app);
    const selected = app.selected orelse return;
    const top = @as(i32, @intCast(selected)) * row_step;
    const bottom = top + row_height;

    if (top < app.scroll) app.scroll = top;
    if (bottom > app.scroll + geometry.h) app.scroll = bottom - geometry.h;
    app.scroll = std.math.clamp(app.scroll, 0, maxScroll(app));
}

fn hitRow(app: *App, x: f32, y: f32) ?usize {
    const geometry = listGeometry(app);
    const fx: i32 = @intFromFloat(@floor(x));
    const fy: i32 = @intFromFloat(@floor(y));

    if (fx < geometry.x or fx >= geometry.x + geometry.w) return null;
    if (fy < geometry.y or fy >= geometry.y + geometry.h) return null;

    const local = fy - geometry.y + app.scroll;
    if (local < 0) return null;
    const index: usize = @intCast(@divTrunc(local, row_step));
    if (index >= app.visible_count) return null;
    if (@mod(local, row_step) >= row_height) return null;
    return index;
}

fn overSearch(app: *App, x: f32, y: f32) bool {
    const width: f32 = @floatFromInt(app.client.logical_width);
    const left: f32 = margin;
    const right = width - margin;
    return x >= left and x < right and y >= margin and y < margin + search_height;
}

fn updateHover(app: *App) void {
    const hovered = if (app.pointer_inside) hitRow(app, app.pointer_x, app.pointer_y) else null;
    if (hovered != app.hover) {
        app.hover = hovered;
        app.dirty = true;
    }
}

fn updateCursor(app: *App) void {
    if (!app.pointer_inside) return;
    const shape = if (overSearch(app, app.pointer_x, app.pointer_y))
        wayland.c.WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_TEXT
    else
        wayland.c.WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_DEFAULT;
    app.client.setPointerShape(@intCast(shape));
}

fn renderFrame(app: *App, now: i64) void {
    const frame = app.client.beginFrame() orelse return;
    var canvas = render.Canvas.init(frame.pixels, frame.width, frame.height);
    canvas.clear(render.transparent);
    drawUi(app, &canvas, now);
    app.client.submitFrame(frame);
}

fn drawUi(app: *App, canvas: *render.Canvas, now: i64) void {
    const scale: i32 = @intCast(app.client.scale);
    const width: i32 = @intCast(app.client.logical_width);
    const height: i32 = @intCast(app.client.logical_height);

    // Window body and one-pixel border.
    canvas.roundRect(0, 0, px(width, scale), px(height, scale), px(corner_radius, scale), border_color);
    canvas.roundRect(
        px(1, scale),
        px(1, scale),
        px(width - 2, scale),
        px(height - 2, scale),
        px(corner_radius - 1, scale),
        extra_dark,
    );

    const search_x = margin;
    const search_y = margin;
    const search_w = width - margin * 2;
    canvas.roundRect(
        px(search_x, scale),
        px(search_y, scale),
        px(search_w, scale),
        px(search_height, scale),
        px(search_radius, scale),
        dark,
    );

    const query = app.query[0..app.query_len];
    const glyph_scale: u32 = @intCast(text_glyph_scale * scale);
    const text_height = font.glyph_height * glyph_scale;
    const text_y = px(search_y, scale) + @divTrunc(px(search_height, scale) - @as(i32, @intCast(text_height)), 2);
    const text_x = px(search_x + small_margin, scale);
    const max_text_width = px(search_w - small_margin * 2 - 2, scale);

    var cursor_x = text_x;
    if (query.len == 0) {
        _ = canvas.textFit(text_x, text_y, "Search for your application...", muted, glyph_scale, max_text_width);
    } else {
        cursor_x = drawQuery(canvas, text_x, text_y, query, white, glyph_scale, max_text_width);
    }

    const cursor_visible = query.len > 0 and (app.blink_on or (now - app.last_input_ms) < 400);
    if (cursor_visible) {
        canvas.fillRect(cursor_x, text_y, @max(1, scale), @intCast(text_height), white);
    }

    const geometry = listGeometry(app);
    canvas.setClip(
        px(geometry.x, scale),
        px(geometry.y, scale),
        px(geometry.w, scale),
        px(geometry.h, scale),
    );

    app.scroll = std.math.clamp(app.scroll, 0, maxScroll(app));

    if (app.visible_count == 0) {
        _ = canvas.text(
            px(geometry.x + 4, scale),
            px(geometry.y + 4, scale),
            "No matches",
            muted,
            glyph_scale,
        );
    } else {
        const row_glyph_scale: u32 = glyph_scale;
        var show_index: usize = 0;
        while (show_index < app.visible_count) : (show_index += 1) {
            const row_y = px(geometry.y, scale) + px(@as(i32, @intCast(show_index)) * row_step - app.scroll, scale);
            const row_bottom = row_y + px(row_height, scale);
            if (row_bottom <= px(geometry.y, scale)) continue;
            if (row_y >= px(geometry.y + geometry.h, scale)) break;

            const app_index = app.visible[show_index];
            const fill = if (app.selected == show_index)
                accent
            else if (app.hover == show_index)
                dark.lighten(5)
            else
                dark;

            canvas.roundRect(
                px(geometry.x, scale),
                row_y,
                px(geometry.w, scale),
                px(row_height, scale),
                px(row_radius, scale),
                fill,
            );

            const icon_x = px(geometry.x + small_margin, scale);
            const icon_y = row_y + px(small_margin, scale);
            const icon_px = px(icon_size, scale);
            if (getIcon(app, app_index)) |image| {
                canvas.image(icon_x, icon_y, icon_px, icon_px, image);
            } else {
                canvas.roundRect(icon_x, icon_y, icon_px, icon_px, px(4, scale), control);
                const initial = appInitial(app.apps.getName(app_index));
                _ = canvas.text(
                    icon_x + px(12, scale),
                    icon_y + px(8, scale),
                    initial,
                    muted,
                    row_glyph_scale,
                );
            }

            const name_x = px(geometry.x + small_margin + icon_size + small_margin, scale);
            const name_y = row_y + @divTrunc(px(row_height, scale) - @as(i32, @intCast(text_height)), 2);
            const name_width = px(geometry.w - small_margin * 2 - icon_size - small_margin, scale);
            _ = canvas.textFit(name_x, name_y, app.apps.getName(app_index), white, row_glyph_scale, name_width);
        }
    }

    canvas.resetClip();
}

fn drawQuery(
    canvas: *render.Canvas,
    x: i32,
    y: i32,
    text: []const u8,
    color: render.Color,
    glyph_scale: u32,
    max_width: i32,
) i32 {
    if (max_width <= 0) return x;

    const advance = font.advance(glyph_scale);
    const full_width = font.textWidth(text, glyph_scale);
    if (full_width <= max_width) {
        return canvas.text(x, y, text, color, glyph_scale);
    }

    // Keep the end of a long query visible, like a real text field.
    var start: usize = 0;
    var width: i32 = full_width;
    while (start < text.len and width > max_width) {
        const len = std.unicode.utf8ByteSequenceLength(text[start]) catch 1;
        const end = @min(text.len, start + len);
        if (end <= start) break;
        width -= advance;
        start = end;
    }
    return canvas.text(x, y, text[start..], color, glyph_scale);
}

fn appInitial(name: []const u8) []const u8 {
    if (name.len == 0) return "?";
    const len = std.unicode.utf8ByteSequenceLength(name[0]) catch return "?";
    if (len > name.len) return "?";
    const codepoint = std.unicode.utf8Decode(name[0..len]) catch return "?";
    if (font.glyph(codepoint) == null) return "?";
    return name[0..len];
}

fn getIcon(app: *App, index: usize) ?*png.Image {
    const slot = &app.icons[index];
    if (!slot.tried) {
        slot.tried = true;
        if (app.apps.getIconBytes(index)) |bytes| {
            slot.image = png.decode(app.gpa, bytes) catch |err| blk: {
                std.log.debug("failed to decode icon for '{s}': {s}", .{ app.apps.getName(index), @errorName(err) });
                break :blk null;
            };
        }
    }
    if (slot.image) |*image| return image;
    return null;
}

fn px(value: i32, scale: i32) i32 {
    return value * scale;
}

fn launch(app: *App, idx: usize) void {
    if (app.apps.len() <= idx) return;
    const exec = app.apps.getExec(idx);

    var command_buffer: [8192]u8 = undefined;
    const command = stripFieldCodes(exec, &command_buffer);

    if (app.apps.isTerminal(idx)) {
        if (!launchInTerminal(app, command)) {
            std.log.err("no terminal emulator found for '{s}'", .{app.apps.getName(idx)});
        }
        return;
    }
    spawnCommand(app, command);
}

fn spawnCommand(app: *App, command: []const u8) void {
    const argv = [_][]const u8{ "sh", "-c", command };
    _ = std.process.spawn(app.io, .{
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
fn launchInTerminal(app: *App, command: []const u8) bool {
    if (app.terminal_env) |term| {
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
            if (spawnTerminal(app, prefix[0..n], command)) return true;
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
        if (spawnTerminal(app, prefix, command)) return true;
    }
    return false;
}

fn hasArg(args: []const []const u8, needle: []const u8) bool {
    for (args) |arg| {
        if (std.mem.eql(u8, arg, needle)) return true;
    }
    return false;
}

fn spawnTerminal(app: *App, prefix: []const []const u8, command: []const u8) bool {
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

    _ = std.process.spawn(app.io, .{
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
