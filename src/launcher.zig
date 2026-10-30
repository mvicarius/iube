//! The application launcher view.
//!
//! This is the original iube experience: scan `.desktop` files, filter as the
//! user types, and launch the selected entry. It is only constructed by
//! `iube launch`, so the control panel path never pays for the desktop scan or
//! the icon cache.

const std = @import("std");
const wayland = @import("wayland.zig");
const desktop = @import("desktop.zig");
const render = @import("render.zig");
const png = @import("png.zig");
const font = @import("font.zig");
const ui = @import("ui.zig");
const session = @import("session.zig");

const IconSlot = struct {
    tried: bool = false,
    image: ?png.Image = null,
};

pub const Launcher = struct {
    gpa: std.mem.Allocator,
    apps: desktop.Apps,
    visible: []usize,
    visible_count: usize = 0,
    query: [256]u8 = @splat(0),
    query_len: usize = 0,
    selected: ?usize = null,
    scroll: i32 = 0,
    hover: ?usize = null,
    icons: []IconSlot,
    terminal_env: ?[]const u8,

    pub fn init(
        io: std.Io,
        gpa: std.mem.Allocator,
        env: desktop.Env,
        terminal_env: ?[]const u8,
    ) !Launcher {
        var apps = try desktop.scan(io, gpa, env);
        errdefer apps.deinit();

        const visible = try gpa.alloc(usize, apps.len());
        errdefer gpa.free(visible);

        const icons = try gpa.alloc(IconSlot, apps.len());
        errdefer gpa.free(icons);
        @memset(icons, .{});

        var launcher = Launcher{
            .gpa = gpa,
            .apps = apps,
            .visible = visible,
            .icons = icons,
            .terminal_env = terminal_env,
        };
        launcher.recomputeVisible();
        return launcher;
    }

    pub fn deinit(self: *Launcher) void {
        for (self.icons) |*slot| {
            if (slot.image) |*image| image.deinit(self.gpa);
        }
        self.gpa.free(self.icons);
        self.gpa.free(self.visible);
        self.apps.deinit();
    }

    pub fn windowSize(_: *Launcher, metrics: ui.Metrics) ui.WindowSize {
        return .{ .width = metrics.window_width, .height = metrics.window_height };
    }

    pub fn wantsBlink(_: *Launcher) bool {
        return true;
    }

    pub fn overTextField(self: *Launcher, s: *session.Session) bool {
        return s.pointer_inside and overSearch(self, s, s.pointer_x, s.pointer_y);
    }

    pub fn handleKey(self: *Launcher, s: *session.Session, key: wayland.Key, is_repeat: bool) void {
        if (!key.pressed) return;

        if (!is_repeat and (key.keysym == ui.key_return or key.keysym == ui.key_kp_enter)) {
            if (self.selected) |selected| {
                if (selected < self.visible_count) {
                    if (self.launch(s, self.visible[selected])) s.running = false;
                }
            }
            return;
        }

        if (key.keysym == ui.key_down) {
            if (self.selected) |selected| {
                if (self.visible_count > 0) {
                    self.selected = @min(selected + 1, self.visible_count - 1);
                }
            } else if (self.visible_count > 0) {
                self.selected = 0;
            }
            self.ensureSelectionVisible(s);
            self.updateHover(s);
            s.dirty = true;
            return;
        }

        if (key.keysym == ui.key_up) {
            if (self.selected) |selected| {
                if (selected > 0) self.selected = selected - 1;
            } else if (self.visible_count > 0) {
                self.selected = self.visible_count - 1;
            }
            self.ensureSelectionVisible(s);
            self.updateHover(s);
            s.dirty = true;
            return;
        }

        if (key.keysym == ui.key_left or key.keysym == ui.key_right) {
            return;
        }

        if (key.keysym == ui.key_backspace) {
            if (self.query_len > 0) {
                self.removeLastCodepoint();
                self.onQueryChanged(s);
            }
            return;
        }

        if (key.mods.ctrl and (key.keysym == 'u' or key.keysym == 'U')) {
            self.query_len = 0;
            self.onQueryChanged(s);
            return;
        }

        if (key.mods.ctrl or key.mods.alt or key.mods.super) return;
        if (key.text_len == 0) return;

        const text = key.text[0..key.text_len];
        var i: usize = 0;
        while (i < text.len) : (i += 1) {
            const byte = text[i];
            if (byte < 0x20 or byte == 0x7f) continue;
            if (self.query_len >= self.query.len) break;
            self.query[self.query_len] = byte;
            self.query_len += 1;
        }
        self.onQueryChanged(s);
    }

    pub fn pointerMoved(self: *Launcher, s: *session.Session) void {
        self.updateHover(s);
    }

    pub fn pointerLeft(self: *Launcher, s: *session.Session) void {
        if (self.hover != null) {
            self.hover = null;
            s.dirty = true;
        }
    }

    pub fn pointerClick(self: *Launcher, s: *session.Session) void {
        if (self.hitRow(s, s.pointer_x, s.pointer_y)) |index| {
            if (self.launch(s, self.visible[index])) s.running = false;
        }
    }

    pub fn pointerScroll(self: *Launcher, s: *session.Session, delta: f32) void {
        const max_scroll = self.maxScroll(s);
        self.scroll = std.math.clamp(
            self.scroll + @as(i32, @intFromFloat(delta * 4.0)),
            0,
            max_scroll,
        );
        self.updateHover(s);
        s.dirty = true;
    }

    fn removeLastCodepoint(self: *Launcher) void {
        if (self.query_len == 0) return;
        var index = self.query_len - 1;
        while (index > 0 and (self.query[index] & 0xc0) == 0x80) : (index -= 1) {}
        self.query_len = index;
    }

    fn onQueryChanged(self: *Launcher, s: *session.Session) void {
        self.recomputeVisible();
        self.scroll = 0;
        self.selected = if (self.query_len > 0 and self.visible_count > 0) 0 else null;
        self.updateHover(s);
        s.dirty = true;
    }

    fn recomputeVisible(self: *Launcher) void {
        const needle = self.query[0..self.query_len];
        self.visible_count = 0;
        for (self.apps.order.items) |app_index| {
            if (!matchesQuery(self.apps.getName(app_index), needle)) continue;
            self.visible[self.visible_count] = app_index;
            self.visible_count += 1;
        }
        if (self.selected) |selected| {
            if (self.visible_count == 0) {
                self.selected = null;
            } else if (selected >= self.visible_count) {
                self.selected = self.visible_count - 1;
            }
        }
    }

    fn listGeometry(_: *Launcher, s: *session.Session) ui.ListLayout {
        const width: i32 = @intCast(s.client.logical_width);
        const height: i32 = @intCast(s.client.logical_height);
        const m = s.metrics;
        const list_y = m.margin + m.search_height + m.margin;
        return .{
            .x = m.margin,
            .y = list_y,
            .w = @max(0, width - m.margin * 2),
            .h = @max(0, height - list_y - m.margin),
        };
    }

    fn maxScroll(self: *Launcher, s: *session.Session) i32 {
        return self.listGeometry(s).maxScroll(self.visible_count, s.metrics, 0);
    }

    fn ensureSelectionVisible(self: *Launcher, s: *session.Session) void {
        const selected = self.selected orelse return;
        self.listGeometry(s).ensureSelectionVisible(
            selected,
            &self.scroll,
            s.metrics,
            self.visible_count,
            0,
        );
    }

    fn hitRow(self: *Launcher, s: *session.Session, x: f32, y: f32) ?usize {
        return self.listGeometry(s).hitRow(
            s.pointer_inside,
            x,
            y,
            self.scroll,
            self.visible_count,
            s.metrics,
        );
    }

    fn updateHover(self: *Launcher, s: *session.Session) void {
        const hovered = if (s.pointer_inside)
            self.hitRow(s, s.pointer_x, s.pointer_y)
        else
            null;
        if (hovered != self.hover) {
            self.hover = hovered;
            s.dirty = true;
        }
    }

    pub fn draw(self: *Launcher, s: *session.Session, canvas: *render.Canvas, now: i64) void {
        const output_scale: i32 = @intCast(s.client.scale);
        const width: i32 = @intCast(s.client.logical_width);
        const height: i32 = @intCast(s.client.logical_height);
        const m = s.metrics;
        const cfg = s.cfg;
        const border = m.border_width;

        ui.drawWindowChrome(canvas, cfg, m, output_scale, width, height);

        const search_x = m.margin;
        const search_y = m.margin;
        const search_w = @max(0, width - m.margin * 2);
        const search_h = m.search_height;

        // The accent ring doubles as the focus indicator for the search field.
        canvas.roundRect(
            ui.px(search_x, output_scale),
            ui.px(search_y, output_scale),
            ui.px(search_w, output_scale),
            ui.px(search_h, output_scale),
            ui.px(m.search_radius, output_scale),
            cfg.accent,
        );
        canvas.roundRect(
            ui.px(search_x + border, output_scale),
            ui.px(search_y + border, output_scale),
            ui.px(@max(0, search_w - border * 2), output_scale),
            ui.px(@max(0, search_h - border * 2), output_scale),
            ui.px(@max(0, m.search_radius - border), output_scale),
            cfg.surface,
        );

        const query = self.query[0..self.query_len];
        const font_scale = ui.fontScale(cfg, output_scale);
        const text_height = ui.textHeight(font_scale);
        const text_y = ui.px(search_y, output_scale) +
            @divTrunc(ui.px(search_h, output_scale) - text_height, 2);
        const text_x = ui.px(search_x + m.small_margin, output_scale);
        const max_text_width = ui.px(
            @max(0, search_w - m.small_margin * 2 - border * 2),
            output_scale,
        );

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

        const cursor_visible = query.len > 0 and
            (s.blink_on or (now - s.last_input_ms) < 400);
        if (cursor_visible) {
            const cursor_width = @max(1, @as(i32, @intFromFloat(@round(font_scale))));
            canvas.fillRect(cursor_x, text_y, cursor_width, text_height, cfg.accent);
        }

        const geometry = self.listGeometry(s);
        canvas.setClip(
            ui.px(geometry.x, output_scale),
            ui.px(geometry.y, output_scale),
            ui.px(geometry.w, output_scale),
            ui.px(geometry.h, output_scale),
        );

        self.scroll = std.math.clamp(self.scroll, 0, self.maxScroll(s));

        if (self.visible_count == 0) {
            _ = canvas.text(
                ui.px(geometry.x + @divTrunc(m.small_margin, 2), output_scale),
                ui.px(geometry.y + @divTrunc(m.small_margin, 2), output_scale),
                "No matches",
                cfg.muted,
                font_scale,
            );
        } else {
            var show_index: usize = 0;
            while (show_index < self.visible_count) : (show_index += 1) {
                const row_y = ui.px(geometry.y, output_scale) +
                    ui.px(@as(i32, @intCast(show_index)) * m.row_step - self.scroll, output_scale);
                const row_bottom = row_y + ui.px(m.row_height, output_scale);
                if (row_bottom <= ui.px(geometry.y, output_scale)) continue;
                if (row_y >= ui.px(geometry.y + geometry.h, output_scale)) break;

                const app_index = self.visible[show_index];
                const fill = if (self.selected == show_index)
                    cfg.highlight_high
                else if (self.hover == show_index)
                    cfg.highlight_low
                else
                    cfg.surface;

                canvas.roundRect(
                    ui.px(geometry.x, output_scale),
                    row_y,
                    ui.px(geometry.w, output_scale),
                    ui.px(m.row_height, output_scale),
                    ui.px(m.row_radius, output_scale),
                    fill,
                );

                const icon_x = ui.px(geometry.x + m.small_margin, output_scale);
                const icon_y = row_y + ui.px(m.small_margin, output_scale);
                const icon_px = ui.px(m.icon_size, output_scale);
                if (getIcon(self, app_index)) |image| {
                    canvas.image(icon_x, icon_y, icon_px, icon_px, image);
                } else {
                    canvas.roundRect(
                        icon_x,
                        icon_y,
                        icon_px,
                        icon_px,
                        ui.px(m.icon_radius, output_scale),
                        cfg.highlight_low,
                    );
                    const initial = ui.appInitial(self.apps.getName(app_index));
                    const initial_width = font.textWidth(initial, font_scale);
                    _ = canvas.text(
                        icon_x + @divTrunc(icon_px - initial_width, 2),
                        icon_y + @divTrunc(icon_px - text_height, 2),
                        initial,
                        cfg.detail_2,
                        font_scale,
                    );
                }

                const name_x = ui.px(
                    geometry.x + m.small_margin + m.icon_size + m.small_margin,
                    output_scale,
                );
                const name_y = row_y + @divTrunc(ui.px(m.row_height, output_scale) - text_height, 2);
                const name_width = ui.px(
                    @max(0, geometry.w - m.small_margin * 2 - m.icon_size - m.small_margin),
                    output_scale,
                );
                _ = canvas.textFit(
                    name_x,
                    name_y,
                    self.apps.getName(app_index),
                    cfg.text,
                    font_scale,
                    name_width,
                );
            }
        }

        canvas.resetClip();
    }

    fn launch(self: *Launcher, s: *session.Session, idx: usize) bool {
        if (self.apps.len() <= idx) return false;
        const exec = self.apps.getExec(idx);

        var command_buffer: [8192]u8 = undefined;
        const command = stripFieldCodes(exec, &command_buffer);

        if (self.apps.isTerminal(idx)) {
            if (!self.launchInTerminal(s, command)) {
                std.log.err("no terminal emulator found for '{s}'", .{self.apps.getName(idx)});
                return false;
            }
            return true;
        }
        return spawnCommand(s.io, command);
    }

    /// Terminal=true .desktop entries have no window of their own. Run them inside
    /// a terminal emulator. `$TERMINAL` wins; otherwise try common emulators.
    fn launchInTerminal(self: *Launcher, s: *session.Session, command: []const u8) bool {
        if (self.terminal_env) |term| {
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
                if (spawnTerminal(s.io, prefix[0..n], command)) return true;
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
            if (spawnTerminal(s.io, prefix, command)) return true;
        }
        return false;
    }
};

fn matchesQuery(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;

    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

fn overSearch(_: *Launcher, s: *session.Session, x: f32, y: f32) bool {
    const width: f32 = @floatFromInt(s.client.logical_width);
    const margin: f32 = @floatFromInt(s.metrics.margin);
    const search_height: f32 = @floatFromInt(s.metrics.search_height);
    const left = margin;
    const right = width - margin;
    return x >= left and x < right and y >= margin and y < margin + search_height;
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

fn getIcon(self: *Launcher, index: usize) ?*png.Image {
    const slot = &self.icons[index];
    if (!slot.tried) {
        slot.tried = true;
        if (self.apps.getIconBytes(index)) |bytes| {
            slot.image = png.decode(self.gpa, bytes) catch |err| blk: {
                std.log.debug(
                    "failed to decode icon for '{s}': {s}",
                    .{ self.apps.getName(index), @errorName(err) },
                );
                break :blk null;
            };
        }
    }
    if (slot.image) |*image| return image;
    return null;
}

fn spawnCommand(io: std.Io, command: []const u8) bool {
    const argv = [_][]const u8{ "sh", "-c", command };
    _ = std.process.spawn(io, .{
        .argv = &argv,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch |err| {
        std.log.err("failed to launch '{s}': {s}", .{ command, @errorName(err) });
        return false;
    };
    return true;
}

fn hasArg(args: []const []const u8, needle: []const u8) bool {
    for (args) |arg| {
        if (std.mem.eql(u8, arg, needle)) return true;
    }
    return false;
}

fn spawnTerminal(io: std.Io, prefix: []const []const u8, command: []const u8) bool {
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
