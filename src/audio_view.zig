//! The audio controller view.
//!
//! The first implementation is intentionally close to the original launcher:
//! a keyboard-first list, shared theme and renderer, no daemon. It talks to
//! PulseAudio/pipewire-pulse through `audio.zig` and changes volume, mute and
//! default devices directly.

const std = @import("std");
const wayland = @import("wayland.zig");
const render = @import("render.zig");
const font = @import("font.zig");
const ui = @import("ui.zig");
const session = @import("session.zig");
const audio = @import("audio.zig");

const base_header_height = 36;
const base_footer_height = 24;
const base_tab_height = 26;
const max_visible_rows = 8;
const volume_step = 5;

const key_tab: u32 = 0xff09;

const Tab = enum {
    outputs,
    inputs,

    fn kind(self: Tab) audio.Kind {
        return switch (self) {
            .outputs => .sink,
            .inputs => .source,
        };
    }

    fn title(self: Tab) []const u8 {
        return switch (self) {
            .outputs => "Outputs",
            .inputs => "Inputs",
        };
    }
};

const TabRect = struct {
    kind: Tab,
    x: i32,
    y: i32,
    w: i32,
    h: i32,
};

const ListGeometry = struct {
    x: i32,
    y: i32,
    w: i32,
    h: i32,
};

pub const Audio = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    env: audio.Env,

    client: ?audio.Client = null,
    state: ?audio.State = null,

    tab: Tab = .outputs,
    selected: usize = 0,
    hover: ?usize = null,
    scroll: i32 = 0,

    error_buffer: [256]u8 = undefined,
    error_len: usize = 0,

    pub fn init(io: std.Io, gpa: std.mem.Allocator, env: audio.Env) Audio {
        var view = Audio{
            .io = io,
            .gpa = gpa,
            .env = env,
        };
        view.reload();
        return view;
    }

    pub fn deinit(self: *Audio) void {
        if (self.client) |*client| client.deinit();
        if (self.state) |*state| state.deinit();
        self.client = null;
        self.state = null;
    }

    pub fn windowSize(self: *Audio, metrics: ui.Metrics) ui.WindowSize {
        const rows = if (self.state == null)
            3
        else
            std.math.clamp(self.deviceRowCount(), 1, max_visible_rows);
        const header = ui.scaled(base_header_height, metrics.scale);
        const footer = ui.scaled(base_footer_height, metrics.scale);
        const content = @as(i32, @intCast(rows)) * metrics.row_step - metrics.gap;
        return .{
            .width = metrics.window_width,
            .height = @max(
                1,
                metrics.margin * 2 + header + metrics.gap + content + footer,
            ),
        };
    }

    pub fn wantsBlink(_: *Audio) bool {
        return false;
    }

    pub fn overTextField(_: *Audio, _: *session.Session) bool {
        return false;
    }

    pub fn handleKey(self: *Audio, s: *session.Session, key: wayland.Key, is_repeat: bool) void {
        if (!key.pressed) return;
        _ = is_repeat;

        if (key.mods.ctrl or key.mods.alt or key.mods.super) return;

        if (key.keysym == key_tab) {
            self.tab = switch (self.tab) {
                .outputs => .inputs,
                .inputs => .outputs,
            };
            self.selected = 0;
            self.scroll = 0;
            self.hover = null;
            s.dirty = true;
            return;
        }

        if (key.keysym == ui.key_down) {
            self.moveSelection(s, 1);
            return;
        }

        if (key.keysym == ui.key_up) {
            self.moveSelection(s, -1);
            return;
        }

        if (key.keysym == ui.key_left) {
            self.adjustVolume(s, -volume_step);
            return;
        }

        if (key.keysym == ui.key_right) {
            self.adjustVolume(s, volume_step);
            return;
        }

        if (key.keysym == ui.key_return or key.keysym == ui.key_kp_enter) {
            self.setDefault(s);
            return;
        }

        if (key.keysym == 'm' or key.keysym == 'M') {
            self.toggleMute(s);
            return;
        }

        if (key.keysym == 'r' or key.keysym == 'R') {
            self.reload();
            s.dirty = true;
        }
    }

    pub fn pointerMoved(self: *Audio, s: *session.Session) void {
        self.updateHover(s);
    }

    pub fn pointerLeft(self: *Audio, s: *session.Session) void {
        if (self.hover != null) {
            self.hover = null;
            s.dirty = true;
        }
    }

    pub fn pointerClick(self: *Audio, s: *session.Session) void {
        if (!s.pointer_inside) return;

        if (self.tabAt(s)) |tab| {
            if (tab != self.tab) {
                self.tab = tab;
                self.selected = 0;
                self.scroll = 0;
                self.hover = null;
                s.dirty = true;
            }
            return;
        }

        if (self.hitRow(s)) |index| {
            self.selected = index;
            s.dirty = true;
        }
    }

    pub fn pointerScroll(self: *Audio, s: *session.Session, delta: f32) void {
        const max_scroll = self.maxScroll(s);
        if (max_scroll == 0) {
            self.adjustVolume(s, if (delta > 0) volume_step else -volume_step);
            return;
        }

        self.scroll = std.math.clamp(
            self.scroll + @as(i32, @intFromFloat(delta * 4.0)),
            0,
            max_scroll,
        );
        self.updateHover(s);
        s.dirty = true;
    }

    pub fn draw(self: *Audio, s: *session.Session, canvas: *render.Canvas, _: i64) void {
        const output_scale: i32 = @intCast(s.client.scale);
        const width: i32 = @intCast(s.client.logical_width);
        const height: i32 = @intCast(s.client.logical_height);
        const m = s.metrics;
        const cfg = s.cfg;
        const font_scale = ui.fontScale(cfg, output_scale);
        const text_height = ui.textHeight(font_scale);

        ui.drawWindowChrome(canvas, cfg, m, output_scale, width, height);
        self.drawHeader(s, canvas, output_scale, font_scale, text_height);

        const geometry = self.listGeometry(s);
        canvas.setClip(
            ui.px(geometry.x, output_scale),
            ui.px(geometry.y, output_scale),
            ui.px(geometry.w, output_scale),
            ui.px(geometry.h, output_scale),
        );

        if (self.state == null) {
            self.drawError(s, canvas, geometry, output_scale, font_scale, text_height);
        } else {
            self.scroll = std.math.clamp(self.scroll, 0, self.maxScroll(s));
            self.drawRows(s, canvas, geometry, output_scale, font_scale, text_height);
        }

        canvas.resetClip();
        self.drawFooter(s, canvas, output_scale, font_scale);
    }

    fn reload(self: *Audio) void {
        self.error_len = 0;

        if (self.state) |*state| state.deinit();
        if (self.client) |*client| client.deinit();
        self.state = null;
        self.client = null;

        var client = audio.Client.connect(self.io, self.gpa, self.env) catch |err| {
            self.setError("Audio unavailable", err);
            self.clampSelection();
            return;
        };
        const state = client.refresh(self.gpa) catch |err| {
            client.deinit();
            self.setError("Audio unavailable", err);
            self.clampSelection();
            return;
        };

        self.client = client;
        self.state = state;
        self.clampSelection();
    }

    fn setError(self: *Audio, prefix: []const u8, err: anyerror) void {
        const text: []const u8 = std.fmt.bufPrint(
            &self.error_buffer,
            "{s}: {s}",
            .{ prefix, @errorName(err) },
        ) catch "Audio error";
        self.error_len = text.len;
    }

    fn errorSlice(self: *const Audio) []const u8 {
        return self.error_buffer[0..self.error_len];
    }

    fn deviceRowCount(self: *const Audio) usize {
        const state = if (self.state) |*value| value else return 0;
        return @max(state.sinks.len, state.sources.len);
    }

    fn devices(self: *Audio) ?[]audio.Device {
        const state = if (self.state) |*value| value else return null;
        return state.devices(self.tab.kind());
    }

    fn currentDevice(self: *Audio) ?*audio.Device {
        const list = self.devices() orelse return null;
        if (self.selected >= list.len) return null;
        return &list[self.selected];
    }

    fn clampSelection(self: *Audio) void {
        const list = self.devices() orelse {
            self.selected = 0;
            return;
        };
        if (list.len == 0) {
            self.selected = 0;
        } else if (self.selected >= list.len) {
            self.selected = list.len - 1;
        }
    }

    fn moveSelection(self: *Audio, s: *session.Session, delta: i32) void {
        const list = self.devices() orelse return;
        if (list.len == 0) return;

        const next = @as(i32, @intCast(self.selected)) + delta;
        self.selected = @intCast(std.math.clamp(next, 0, @as(i32, @intCast(list.len - 1))));
        self.ensureSelectionVisible(s);
        self.updateHover(s);
        s.dirty = true;
    }

    fn adjustVolume(self: *Audio, s: *session.Session, delta: i32) void {
        const device = self.currentDevice() orelse return;
        const current: i32 = device.percent();
        const target: i32 = std.math.clamp(current + delta, 0, 150);
        const volume: u32 = @intCast((@as(u64, @intCast(target)) * audio.pa_volume_norm + 50) / 100);
        device.volume = volume;

        if (self.client) |*client| {
            client.setVolume(device.*, volume) catch |err| self.setError("Volume change failed", err);
        }
        s.dirty = true;
    }

    fn toggleMute(self: *Audio, s: *session.Session) void {
        const device = self.currentDevice() orelse return;
        device.mute = !device.mute;

        if (self.client) |*client| {
            client.setMute(device.*, device.mute) catch |err| self.setError("Mute change failed", err);
        }
        s.dirty = true;
    }

    fn setDefault(self: *Audio, s: *session.Session) void {
        const device = self.currentDevice() orelse return;
        const name = device.name;
        const kind = device.kind;

        if (self.client) |*client| {
            client.setDefault(device.*) catch |err| {
                self.setError("Default device change failed", err);
                return;
            };
        }

        const state = if (self.state) |*value| value else return;
        for (state.sinks) |*entry| {
            entry.is_default = kind == .sink and std.mem.eql(u8, entry.name, name);
        }
        for (state.sources) |*entry| {
            entry.is_default = kind == .source and std.mem.eql(u8, entry.name, name);
        }
        s.dirty = true;
    }

    fn tabRects(s: *session.Session) [2]TabRect {
        const m = s.metrics;
        const width: i32 = @intCast(s.client.logical_width);
        const text_scale = s.cfg.scale;
        const padding = m.small_margin;
        const outputs_width = font.textWidth("Outputs", text_scale) + padding * 2;
        const inputs_width = font.textWidth("Inputs", text_scale) + padding * 2;
        const tab_height = ui.scaled(base_tab_height, text_scale);
        const header_height = ui.scaled(base_header_height, text_scale);
        const y = m.margin + @divTrunc(header_height - tab_height, 2);
        const inputs_x = width - m.margin - inputs_width;
        const outputs_x = inputs_x - m.gap - outputs_width;

        return .{
            .{ .kind = .outputs, .x = outputs_x, .y = y, .w = outputs_width, .h = tab_height },
            .{ .kind = .inputs, .x = inputs_x, .y = y, .w = inputs_width, .h = tab_height },
        };
    }

    fn tabAt(self: *Audio, s: *session.Session) ?Tab {
        _ = self;
        if (!s.pointer_inside) return null;
        const x: i32 = @intFromFloat(@floor(s.pointer_x));
        const y: i32 = @intFromFloat(@floor(s.pointer_y));
        for (tabRects(s)) |rect| {
            if (x >= rect.x and x < rect.x + rect.w and y >= rect.y and y < rect.y + rect.h) {
                return rect.kind;
            }
        }
        return null;
    }

    fn listGeometry(_: *Audio, s: *session.Session) ListGeometry {
        const width: i32 = @intCast(s.client.logical_width);
        const height: i32 = @intCast(s.client.logical_height);
        const m = s.metrics;
        const header = ui.scaled(base_header_height, m.scale);
        const footer = ui.scaled(base_footer_height, m.scale);
        const y = m.margin + header + m.gap;
        return .{
            .x = m.margin,
            .y = y,
            .w = @max(0, width - m.margin * 2),
            .h = @max(0, height - y - m.margin - footer),
        };
    }

    fn maxScroll(self: *Audio, s: *session.Session) i32 {
        const list = self.devices() orelse return 0;
        const geometry = self.listGeometry(s);
        const content = @as(i32, @intCast(list.len)) * s.metrics.row_step - s.metrics.gap;
        return @max(0, content - geometry.h);
    }

    fn ensureSelectionVisible(self: *Audio, s: *session.Session) void {
        const geometry = self.listGeometry(s);
        const top = @as(i32, @intCast(self.selected)) * s.metrics.row_step;
        const bottom = top + s.metrics.row_height;
        if (top < self.scroll) self.scroll = top;
        if (bottom > self.scroll + geometry.h) self.scroll = bottom - geometry.h;
        self.scroll = std.math.clamp(self.scroll, 0, self.maxScroll(s));
    }

    fn hitRow(self: *Audio, s: *session.Session) ?usize {
        if (!s.pointer_inside) return null;
        const list = self.devices() orelse return null;

        const geometry = self.listGeometry(s);
        const fx: i32 = @intFromFloat(@floor(s.pointer_x));
        const fy: i32 = @intFromFloat(@floor(s.pointer_y));
        if (fx < geometry.x or fx >= geometry.x + geometry.w) return null;
        if (fy < geometry.y or fy >= geometry.y + geometry.h) return null;

        const local = fy - geometry.y + self.scroll;
        if (local < 0) return null;
        const index: usize = @intCast(@divTrunc(local, s.metrics.row_step));
        if (index >= list.len) return null;
        if (@mod(local, s.metrics.row_step) >= s.metrics.row_height) return null;
        return index;
    }

    fn updateHover(self: *Audio, s: *session.Session) void {
        const hovered = self.hitRow(s);
        if (hovered != self.hover) {
            self.hover = hovered;
            s.dirty = true;
        }
    }

    fn drawHeader(
        self: *Audio,
        s: *session.Session,
        canvas: *render.Canvas,
        output_scale: i32,
        font_scale: f32,
        text_height: i32,
    ) void {
        const m = s.metrics;
        const cfg = s.cfg;
        const header_height = ui.scaled(base_header_height, m.scale);
        const title_y = ui.px(m.margin, output_scale) +
            @divTrunc(ui.px(header_height, output_scale) - text_height, 2);
        _ = canvas.text(
            ui.px(m.margin, output_scale),
            title_y,
            "Audio",
            cfg.text,
            font_scale,
        );

        for (tabRects(s)) |rect| {
            const active = rect.kind == self.tab;
            canvas.roundRect(
                ui.px(rect.x, output_scale),
                ui.px(rect.y, output_scale),
                ui.px(rect.w, output_scale),
                ui.px(rect.h, output_scale),
                ui.px(m.row_radius, output_scale),
                if (active) cfg.highlight_low else cfg.surface,
            );

            const tab_width = font.textWidth(rect.kind.title(), font_scale);
            _ = canvas.text(
                ui.px(rect.x, output_scale) +
                    @divTrunc(ui.px(rect.w, output_scale) - tab_width, 2),
                ui.px(rect.y, output_scale) +
                    @divTrunc(ui.px(rect.h, output_scale) - text_height, 2),
                rect.kind.title(),
                if (active) cfg.accent else cfg.muted,
                font_scale,
            );
        }
    }

    fn drawRows(
        self: *Audio,
        s: *session.Session,
        canvas: *render.Canvas,
        geometry: ListGeometry,
        output_scale: i32,
        font_scale: f32,
        text_height: i32,
    ) void {
        const m = s.metrics;
        const cfg = s.cfg;
        const list = self.devices() orelse return;

        if (list.len == 0) {
            _ = canvas.text(
                ui.px(geometry.x + m.small_margin, output_scale),
                ui.px(geometry.y + m.small_margin, output_scale),
                if (self.tab == .outputs) "No output devices" else "No input devices",
                cfg.muted,
                font_scale,
            );
            return;
        }

        const secondary_scale = font_scale * 0.85;
        const secondary_height = ui.textHeight(secondary_scale);
        const line_gap = ui.px(@max(1, @divTrunc(m.small_margin, 4)), output_scale);
        const text_block = text_height + secondary_height + line_gap;
        const bar_width = ui.px(ui.scaled(52, m.scale), output_scale);
        const bar_height = @max(2, ui.px(ui.scaled(5, m.scale), output_scale));
        const margin_px = ui.px(m.small_margin, output_scale);
        const row_height_px = ui.px(m.row_height, output_scale);
        const dot_size = @max(3, ui.px(@divTrunc(m.icon_size, 8), output_scale));

        for (list, 0..) |device, index| {
            const row_y = geometry.y + @as(i32, @intCast(index)) * m.row_step - self.scroll;
            if (row_y + m.row_height <= geometry.y) continue;
            if (row_y >= geometry.y + geometry.h) break;

            const row_y_px = ui.px(row_y, output_scale);
            const fill = if (self.selected == index)
                cfg.highlight_high
            else if (self.hover == index)
                cfg.highlight_low
            else
                cfg.surface;

            canvas.roundRect(
                ui.px(geometry.x, output_scale),
                row_y_px,
                ui.px(geometry.w, output_scale),
                row_height_px,
                ui.px(m.row_radius, output_scale),
                fill,
            );

            const icon_x = ui.px(geometry.x + m.small_margin, output_scale);
            const icon_y = row_y_px + margin_px;
            const icon_px = ui.px(m.icon_size, output_scale);
            canvas.roundRect(
                icon_x,
                icon_y,
                icon_px,
                icon_px,
                ui.px(m.icon_radius, output_scale),
                cfg.highlight_low,
            );
            const initial = appInitial(device.label());
            const initial_width = font.textWidth(initial, font_scale);
            _ = canvas.text(
                icon_x + @divTrunc(icon_px - initial_width, 2),
                icon_y + @divTrunc(icon_px - text_height, 2),
                initial,
                cfg.muted,
                font_scale,
            );

            const text_top = row_y_px + @divTrunc(row_height_px - text_block, 2);
            const primary_y = text_top;
            const secondary_y = primary_y + text_height + line_gap;
            const name_x = ui.px(
                geometry.x + m.small_margin + m.icon_size + m.small_margin,
                output_scale,
            );
            var label_x = name_x;

            if (device.is_default) {
                canvas.roundRect(
                    label_x,
                    text_top + @divTrunc(text_height - dot_size, 2),
                    dot_size,
                    dot_size,
                    @divTrunc(dot_size, 2),
                    cfg.accent,
                );
                label_x += dot_size + @divTrunc(margin_px, 2);
            }

            var info_left = ui.px(geometry.x + geometry.w - m.small_margin, output_scale);
            var percent_buffer: [8]u8 = undefined;

            if (device.mute) {
                const muted = "Muted";
                const muted_width = font.textWidth(muted, font_scale);
                info_left -= muted_width;
                _ = canvas.text(
                    info_left,
                    row_y_px + @divTrunc(row_height_px - text_height, 2),
                    muted,
                    cfg.muted,
                    font_scale,
                );
            } else {
                const percent_text = std.fmt.bufPrint(
                    &percent_buffer,
                    "{d}%",
                    .{device.percent()},
                ) catch "?";
                const percent_width = font.textWidth(percent_text, font_scale);
                info_left -= percent_width;
                _ = canvas.text(
                    info_left,
                    row_y_px + @divTrunc(row_height_px - text_height, 2),
                    percent_text,
                    cfg.text,
                    font_scale,
                );

                const bar_x = info_left - margin_px - bar_width;
                const bar_y = row_y_px + @divTrunc(row_height_px - bar_height, 2);
                canvas.roundRect(
                    bar_x,
                    bar_y,
                    bar_width,
                    bar_height,
                    @divTrunc(bar_height, 2),
                    cfg.highlight_low,
                );
                const percent = @min(device.percent(), 100);
                const filled = @divTrunc(bar_width * @as(i32, percent), 100);
                if (filled > 0) {
                    canvas.roundRect(
                        bar_x,
                        bar_y,
                        filled,
                        bar_height,
                        @divTrunc(bar_height, 2),
                        cfg.accent,
                    );
                }
                info_left = bar_x;
            }

            const text_width = @max(0, info_left - margin_px - label_x);
            _ = canvas.textFit(
                label_x,
                primary_y,
                device.label(),
                cfg.text,
                font_scale,
                text_width,
            );
            _ = canvas.textFit(
                label_x,
                secondary_y,
                device.name,
                cfg.muted,
                secondary_scale,
                text_width,
            );
        }
    }

    fn drawError(
        self: *Audio,
        s: *session.Session,
        canvas: *render.Canvas,
        geometry: ListGeometry,
        output_scale: i32,
        font_scale: f32,
        text_height: i32,
    ) void {
        const m = s.metrics;
        const cfg = s.cfg;
        const x = geometry.x + m.small_margin;
        const y = geometry.y + m.gap;
        const width = ui.px(@max(0, geometry.w - m.small_margin * 2), output_scale);

        _ = canvas.text(
            ui.px(x, output_scale),
            ui.px(y, output_scale),
            "Audio backend unavailable",
            cfg.text,
            font_scale,
        );

        const body_scale = font_scale * 0.85;
        const body_height = ui.textHeight(body_scale);
        const line_height = body_height + ui.px(m.small_margin, output_scale);
        const next = ui.drawWrapped(
            canvas,
            ui.px(x, output_scale),
            ui.px(y, output_scale) + text_height + ui.px(m.small_margin, output_scale),
            width,
            line_height,
            self.errorSlice(),
            cfg.muted,
            body_scale,
        );
        _ = canvas.text(
            ui.px(x, output_scale),
            next + ui.px(m.small_margin, output_scale),
            "Press R to retry, or Esc to close.",
            cfg.muted,
            body_scale,
        );
    }

    fn drawFooter(
        self: *Audio,
        s: *session.Session,
        canvas: *render.Canvas,
        output_scale: i32,
        font_scale: f32,
    ) void {
        const m = s.metrics;
        const cfg = s.cfg;
        const hint_scale = font_scale * 0.8;
        const hint_height = ui.textHeight(hint_scale);
        const y = ui.px(@intCast(s.client.logical_height), output_scale) -
            ui.px(m.margin, output_scale) - hint_height;
        const width = ui.px(@max(0, @as(i32, @intCast(s.client.logical_width)) - m.margin * 2), output_scale);
        const text = if (self.error_len > 0)
            self.errorSlice()
        else
            "Up/Down select  Left/Right volume  M mute  Enter default  Tab  R  Esc";

        _ = canvas.textFit(
            ui.px(m.margin, output_scale),
            y,
            text,
            if (self.error_len > 0) cfg.accent else cfg.muted,
            hint_scale,
            width,
        );
    }
};

fn appInitial(name: []const u8) []const u8 {
    if (name.len == 0) return "?";
    const len = std.unicode.utf8ByteSequenceLength(name[0]) catch return "?";
    if (len > name.len) return "?";
    const codepoint = std.unicode.utf8Decode(name[0..len]) catch return "?";
    if (font.glyph(codepoint) == null) return "?";
    return name[0..len];
}
