const std = @import("std");
const wayland = @import("wayland.zig");
const desktop = @import("desktop.zig");
const render = @import("render.zig");
const png = @import("png.zig");
const font = @import("font.zig");
const config = @import("config.zig");

pub const std_options: std.Options = .{ .log_level = .warn };

const base_window_width = 640;
const base_window_height = 360;
const base_margin = 16;
const base_small_margin = 8;
const base_gap = 4;
const base_icon_size = 32;
const base_search_height = 40;
const base_border_width = 1;
const blink_period_ms = 530;

/// Layout values in logical (surface) pixels. `scale` from the config file is
/// applied here once at startup, so the rest of the UI code can work with
/// integers while text uses the fractional font scale below.
const Metrics = struct {
    window_width: i32,
    window_height: i32,
    margin: i32,
    small_margin: i32,
    icon_size: i32,
    row_height: i32,
    row_step: i32,
    search_height: i32,
    corner_radius: i32,
    search_radius: i32,
    row_radius: i32,
    icon_radius: i32,
    border_width: i32,

    fn init(cfg: config.Config) Metrics {
        const s = cfg.scale;
        const margin = scaled(base_margin, s);
        const small_margin = scaled(base_small_margin, s);
        const icon_size = scaled(base_icon_size, s);
        const gap = scaled(base_gap, s);
        const corner_radius = scaled(cfg.corner_radius, s);
        return .{
            .window_width = @max(1, scaled(base_window_width, s)),
            .window_height = @max(1, scaled(base_window_height, s)),
            .margin = margin,
            .small_margin = small_margin,
            .icon_size = icon_size,
            .row_height = icon_size + small_margin * 2,
            .row_step = icon_size + small_margin * 2 + gap,
            .search_height = scaled(base_search_height, s),
            .corner_radius = corner_radius,
            .search_radius = @divTrunc(corner_radius, 2),
            .row_radius = @divTrunc(corner_radius, 2),
            .icon_radius = @divTrunc(corner_radius, 2),
            .border_width = @max(1, scaled(base_border_width, s)),
        };
    }

    fn scaled(value: i32, factor: f32) i32 {
        return @intFromFloat(@round(@as(f32, @floatFromInt(value)) * factor));
    }
};

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
    cfg: config.Config,
    metrics: Metrics,
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
    var client: wayland.Client = undefined;
    client.init(init.gpa) catch |err| {
        if (err == error.LayerShellUnavailable) {
            std.log.err(
                "iube requires the wlr-layer-shell protocol (zwlr_layer_shell_v1); " ++
                    "this compositor does not advertise it (try Hyprland, Sway, KWin, Wayfire, labwc, ...)",
                .{},
            );
        }
        return err;
    };
    defer client.deinit();

    const cfg = config.load(init.io, init.gpa, .{
        .home = init.environ_map.get("HOME"),
        .xdg_config_home = init.environ_map.get("XDG_CONFIG_HOME"),
    });
    const metrics = Metrics.init(cfg);
    client.setWindowSize(@intCast(metrics.window_width), @intCast(metrics.window_height));

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
        .cfg = cfg,
        .metrics = metrics,
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
    const m = app.metrics;
    const list_y = m.margin + m.search_height + m.margin;
    return .{
        .x = m.margin,
        .y = list_y,
        .w = @max(0, width - m.margin * 2),
        .h = @max(0, height - list_y - m.margin),
    };
}

fn maxScroll(app: *App) i32 {
    const geometry = listGeometry(app);
    const content = @as(i32, @intCast(app.visible_count)) * app.metrics.row_step;
    return @max(0, content - geometry.h);
}

fn ensureSelectionVisible(app: *App) void {
    const geometry = listGeometry(app);
    const selected = app.selected orelse return;
    const top = @as(i32, @intCast(selected)) * app.metrics.row_step;
    const bottom = top + app.metrics.row_height;

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
    const index: usize = @intCast(@divTrunc(local, app.metrics.row_step));
    if (index >= app.visible_count) return null;
    if (@mod(local, app.metrics.row_step) >= app.metrics.row_height) return null;
    return index;
}

fn overSearch(app: *App, x: f32, y: f32) bool {
    const width: f32 = @floatFromInt(app.client.logical_width);
    const margin: f32 = @floatFromInt(app.metrics.margin);
    const search_height: f32 = @floatFromInt(app.metrics.search_height);
    const left = margin;
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
    const output_scale: i32 = @intCast(app.client.scale);
    const width: i32 = @intCast(app.client.logical_width);
    const height: i32 = @intCast(app.client.logical_height);
    const m = app.metrics;
    const cfg = app.cfg;
    const border = m.border_width;

    // Window body and border. The outer highlight_mid ring is one logical
    // border-width wide and scales with the rest of the UI.
    canvas.roundRect(
        0,
        0,
        px(width, output_scale),
        px(height, output_scale),
        px(m.corner_radius, output_scale),
        cfg.highlight_mid,
    );
    canvas.roundRect(
        px(border, output_scale),
        px(border, output_scale),
        px(@max(0, width - border * 2), output_scale),
        px(@max(0, height - border * 2), output_scale),
        px(@max(0, m.corner_radius - border), output_scale),
        cfg.base,
    );

    const search_x = m.margin;
    const search_y = m.margin;
    const search_w = @max(0, width - m.margin * 2);
    const search_h = m.search_height;

    // The accent ring doubles as the focus indicator for the search field.
    canvas.roundRect(
        px(search_x, output_scale),
        px(search_y, output_scale),
        px(search_w, output_scale),
        px(search_h, output_scale),
        px(m.search_radius, output_scale),
        cfg.accent,
    );
    canvas.roundRect(
        px(search_x + border, output_scale),
        px(search_y + border, output_scale),
        px(@max(0, search_w - border * 2), output_scale),
        px(@max(0, search_h - border * 2), output_scale),
        px(@max(0, m.search_radius - border), output_scale),
        cfg.surface,
    );

    const query = app.query[0..app.query_len];
    const font_scale = cfg.scale * @as(f32, @floatFromInt(app.client.scale));
    const text_height: i32 = @intFromFloat(@round(@as(f32, font.glyph_height) * font_scale));
    const text_y = px(search_y, output_scale) + @divTrunc(px(search_h, output_scale) - text_height, 2);
    const text_x = px(search_x + m.small_margin, output_scale);
    const max_text_width = px(@max(0, search_w - m.small_margin * 2 - border * 2), output_scale);

    var cursor_x = text_x;
    if (query.len == 0) {
        _ = canvas.textFit(
            text_x,
            text_y,
            "Search for your application...",
            cfg.muted,
            font_scale,
            max_text_width,
        );
    } else {
        cursor_x = drawQuery(canvas, text_x, text_y, query, cfg.text, font_scale, max_text_width);
    }

    const cursor_visible = query.len > 0 and (app.blink_on or (now - app.last_input_ms) < 400);
    if (cursor_visible) {
        const cursor_width = @max(1, @as(i32, @intFromFloat(@round(font_scale))));
        canvas.fillRect(cursor_x, text_y, cursor_width, text_height, cfg.accent);
    }

    const geometry = listGeometry(app);
    canvas.setClip(
        px(geometry.x, output_scale),
        px(geometry.y, output_scale),
        px(geometry.w, output_scale),
        px(geometry.h, output_scale),
    );

    app.scroll = std.math.clamp(app.scroll, 0, maxScroll(app));

    if (app.visible_count == 0) {
        _ = canvas.text(
            px(geometry.x + @divTrunc(m.small_margin, 2), output_scale),
            px(geometry.y + @divTrunc(m.small_margin, 2), output_scale),
            "No matches",
            cfg.muted,
            font_scale,
        );
    } else {
        var show_index: usize = 0;
        while (show_index < app.visible_count) : (show_index += 1) {
            const row_y = px(geometry.y, output_scale) +
                px(@as(i32, @intCast(show_index)) * m.row_step - app.scroll, output_scale);
            const row_bottom = row_y + px(m.row_height, output_scale);
            if (row_bottom <= px(geometry.y, output_scale)) continue;
            if (row_y >= px(geometry.y + geometry.h, output_scale)) break;

            const app_index = app.visible[show_index];
            const fill = if (app.selected == show_index)
                cfg.highlight_high
            else if (app.hover == show_index)
                cfg.highlight_low
            else
                cfg.surface;

            canvas.roundRect(
                px(geometry.x, output_scale),
                row_y,
                px(geometry.w, output_scale),
                px(m.row_height, output_scale),
                px(m.row_radius, output_scale),
                fill,
            );

            const icon_x = px(geometry.x + m.small_margin, output_scale);
            const icon_y = row_y + px(m.small_margin, output_scale);
            const icon_px = px(m.icon_size, output_scale);
            if (getIcon(app, app_index)) |image| {
                canvas.image(icon_x, icon_y, icon_px, icon_px, image);
            } else {
                canvas.roundRect(
                    icon_x,
                    icon_y,
                    icon_px,
                    icon_px,
                    px(m.icon_radius, output_scale),
                    cfg.highlight_low,
                );
                const initial = appInitial(app.apps.getName(app_index));
                const initial_width = font.textWidth(initial, font_scale);
                _ = canvas.text(
                    icon_x + @divTrunc(icon_px - initial_width, 2),
                    icon_y + @divTrunc(icon_px - text_height, 2),
                    initial,
                    cfg.muted,
                    font_scale,
                );
            }

            const name_x = px(geometry.x + m.small_margin + m.icon_size + m.small_margin, output_scale);
            const name_y = row_y + @divTrunc(px(m.row_height, output_scale) - text_height, 2);
            const name_width = px(
                @max(0, geometry.w - m.small_margin * 2 - m.icon_size - m.small_margin),
                output_scale,
            );
            _ = canvas.textFit(
                name_x,
                name_y,
                app.apps.getName(app_index),
                cfg.text,
                font_scale,
                name_width,
            );
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
    glyph_scale: f32,
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
