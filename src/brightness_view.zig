//! The brightness controller view.
//!
//! The view keeps the same keyboard-first list, window chrome and renderer as
//! the other iube tools. It reads backlight devices from sysfs and sends
//! changes through logind, so it never needs root, udev rules or
//! `brightnessctl`.

const std = @import("std");
const wayland = @import("wayland.zig");
const render = @import("render.zig");
const font = @import("font.zig");
const png = @import("png.zig");
const ui = @import("ui.zig");
const session = @import("session.zig");
const brightness = @import("brightness.zig");

const base_summary_height = 64;
const max_visible_rows = 4;
const step = 5;

const Rect = struct {
    x: i32,
    y: i32,
    w: i32,
    h: i32,
};

pub const Brightness = struct {
    io: std.Io,
    gpa: std.mem.Allocator,

    client: ?brightness.Client = null,
    state: ?brightness.State = null,
    sun_icon: ?png.Image = null,

    selected: usize = 0,
    hover: ?usize = null,
    scroll: i32 = 0,

    notice: ui.Notice = .{},

    session_buffer: [256]u8 = undefined,
    session_len: usize = 0,

    pub fn init(io: std.Io, gpa: std.mem.Allocator) Brightness {
        var view = Brightness{
            .io = io,
            .gpa = gpa,
        };
        view.sun_icon = png.decode(gpa, @embedFile("icons/sun.png")) catch null;
        view.reload();
        return view;
    }

    pub fn deinit(self: *Brightness) void {
        if (self.client) |*client| client.deinit();
        if (self.state) |*state| state.deinit();
        if (self.sun_icon) |*icon| icon.deinit(self.gpa);
        self.client = null;
        self.state = null;
        self.sun_icon = null;
    }

    pub fn windowSize(self: *Brightness, metrics: ui.Metrics) ui.WindowSize {
        const m = metrics;
        const header = ui.scaled(ui.base_header_height, m.scale);
        const summary = ui.scaled(base_summary_height, m.scale);
        const footer = ui.scaled(ui.base_footer_height, m.scale);
        const rows: i32 = @intCast(self.rowCount());
        const content = rows * m.row_step - m.gap;
        return .{
            .width = m.window_width,
            .height = @max(
                1,
                m.margin * 2 + header + m.gap + summary + m.gap + content + footer,
            ),
        };
    }

    pub fn wantsBlink(_: *Brightness) bool {
        return false;
    }

    pub fn tick(self: *Brightness, s: *session.Session) void {
        if (self.notice.expire(s.nowMs())) s.dirty = true;
    }

    pub fn overTextField(_: *Brightness, _: *session.Session) bool {
        return false;
    }

    pub fn handleKey(self: *Brightness, s: *session.Session, key: wayland.Key, is_repeat: bool) void {
        if (!key.pressed) return;
        if (key.mods.ctrl or key.mods.alt or key.mods.super) return;

        if (key.keysym == ui.key_down) {
            self.moveSelection(s, 1);
            return;
        }
        if (key.keysym == ui.key_up) {
            self.moveSelection(s, -1);
            return;
        }
        if (key.keysym == ui.key_left) {
            self.adjust(s, -step);
            return;
        }
        if (key.keysym == ui.key_right) {
            self.adjust(s, step);
            return;
        }
        if (key.keysym == 'r' or key.keysym == 'R') {
            if (!is_repeat) {
                self.reload();
                s.dirty = true;
            }
        }
    }

    pub fn pointerMoved(self: *Brightness, s: *session.Session) void {
        self.updateHover(s);
    }

    pub fn pointerLeft(self: *Brightness, s: *session.Session) void {
        if (self.hover != null) {
            self.hover = null;
            s.dirty = true;
        }
    }

    pub fn pointerClick(self: *Brightness, s: *session.Session) void {
        if (self.hitRow(s)) |index| {
            self.selected = index;
            s.dirty = true;
        }
    }

    pub fn pointerScroll(self: *Brightness, s: *session.Session, delta: f32) void {
        if (self.state == null) return;
        self.adjust(s, if (delta > 0) step else -step);
    }

    pub fn draw(self: *Brightness, s: *session.Session, canvas: *render.Canvas, _: i64) void {
        const output_scale: i32 = @intCast(s.client.scale);
        const width: i32 = @intCast(s.client.logical_width);
        const height: i32 = @intCast(s.client.logical_height);
        const m = s.metrics;
        const cfg = s.cfg;
        const font_scale = ui.fontScale(cfg, output_scale);
        const text_height = ui.textHeight(font_scale);

        ui.drawWindowChrome(canvas, cfg, m, output_scale, width, height);
        self.drawHeader(s, canvas, output_scale, font_scale, text_height);

        if (self.state == null) {
            self.drawError(s, canvas, output_scale, font_scale, text_height);
        } else {
            self.drawSummary(s, canvas, output_scale, font_scale, text_height);
            self.scroll = std.math.clamp(self.scroll, 0, self.maxScroll(s));
            self.drawRows(s, canvas, output_scale, font_scale, text_height);
        }

        self.drawFooter(s, canvas, output_scale, font_scale);
    }

    fn reload(self: *Brightness) void {
        self.notice.clear();
        self.session_len = 0;

        if (self.client) |*client| client.deinit();
        self.client = null;
        if (self.state) |*state| state.deinit();
        self.state = null;

        self.state = brightness.read(self.io, self.gpa) catch |err| {
            self.setFatalError("Backlight unavailable", err);
            self.clampSelection();
            return;
        };
        self.clampSelection();

        self.client = brightness.Client.connect(self.io, self.gpa) catch |err| {
            self.setSessionNote(err);
            return;
        };
    }

    fn rowCount(self: *const Brightness) usize {
        const state = if (self.state) |*value| value else return 1;
        return std.math.clamp(state.devices.len, 1, max_visible_rows);
    }

    fn clampSelection(self: *Brightness) void {
        const state = if (self.state) |*value| value else {
            self.selected = 0;
            return;
        };
        if (state.devices.len == 0) {
            self.selected = 0;
            return;
        }
        if (self.selected >= state.devices.len) self.selected = state.devices.len - 1;
        if (!state.devices[self.selected].usable()) {
            self.selected = state.selectedIndex() orelse 0;
        }
        if (self.scroll < 0) self.scroll = 0;
    }

    fn moveSelection(self: *Brightness, s: *session.Session, delta: i32) void {
        const state = if (self.state) |*value| value else return;
        if (state.devices.len <= 1) return;

        const next = @as(i32, @intCast(self.selected)) + delta;
        self.selected = @intCast(std.math.clamp(
            next,
            0,
            @as(i32, @intCast(state.devices.len - 1)),
        ));
        self.ensureSelectionVisible(s);
        self.updateHover(s);
        s.dirty = true;
    }

    fn adjust(self: *Brightness, s: *session.Session, delta: i32) void {
        const state = if (self.state) |*value| value else return;
        if (self.selected >= state.devices.len) return;

        const device = &state.devices[self.selected];
        const target = brightness.clampPercent(@as(i32, device.percent()) + delta);
        const value = brightness.rawForPercent(target, device.max_brightness);

        const client = if (self.client) |*value_client| value_client else {
            self.setError("Brightness change failed", error.UnsupportedSession);
            s.dirty = true;
            return;
        };

        client.setBrightness(device.name, value) catch |err| {
            self.setError("Brightness change failed", err);
            s.dirty = true;
            return;
        };

        device.brightness = value;
        self.notice.clear();
        s.dirty = true;
    }

    fn currentDevice(self: *Brightness) ?*brightness.Device {
        const state = if (self.state) |*value| value else return null;
        if (self.selected >= state.devices.len) return null;
        return &state.devices[self.selected];
    }

    fn summaryGeometry(_: *Brightness, s: *session.Session) Rect {
        const width: i32 = @intCast(s.client.logical_width);
        const m = s.metrics;
        return .{
            .x = m.margin,
            .y = m.margin + ui.scaled(ui.base_header_height, m.scale) + m.gap,
            .w = @max(0, width - m.margin * 2),
            .h = ui.scaled(base_summary_height, m.scale),
        };
    }

    fn listGeometry(self: *Brightness, s: *session.Session) ui.ListLayout {
        const summary = self.summaryGeometry(s);
        const m = s.metrics;
        const rows: i32 = @intCast(self.rowCount());
        return .{
            .x = summary.x,
            .y = summary.y + summary.h + m.gap,
            .w = summary.w,
            .h = @max(0, rows * m.row_step - m.gap),
        };
    }

    fn maxScroll(self: *Brightness, s: *session.Session) i32 {
        const state = if (self.state) |*value| value else return 0;
        return self.listGeometry(s).maxScroll(state.devices.len, s.metrics, s.metrics.gap);
    }

    fn ensureSelectionVisible(self: *Brightness, s: *session.Session) void {
        const state = if (self.state) |*value| value else return;
        self.listGeometry(s).ensureSelectionVisible(
            self.selected,
            &self.scroll,
            s.metrics,
            state.devices.len,
            s.metrics.gap,
        );
    }

    fn hitRow(self: *Brightness, s: *session.Session) ?usize {
        const state = if (self.state) |*value| value else return null;
        return self.listGeometry(s).hitRow(
            s.pointer_inside,
            s.pointer_x,
            s.pointer_y,
            self.scroll,
            state.devices.len,
            s.metrics,
        );
    }

    fn updateHover(self: *Brightness, s: *session.Session) void {
        const hovered = self.hitRow(s);
        if (hovered != self.hover) {
            self.hover = hovered;
            s.dirty = true;
        }
    }

    fn drawHeader(
        self: *Brightness,
        s: *session.Session,
        canvas: *render.Canvas,
        output_scale: i32,
        font_scale: f32,
        text_height: i32,
    ) void {
        const m = s.metrics;
        const cfg = s.cfg;
        const width: i32 = @intCast(s.client.logical_width);
        const header_height = ui.scaled(ui.base_header_height, m.scale);
        const title_y = ui.px(m.margin, output_scale) +
            @divTrunc(ui.px(header_height, output_scale) - text_height, 2);

        _ = canvas.text(
            ui.px(m.margin, output_scale),
            title_y,
            "Brightness",
            cfg.text,
            font_scale,
        );

        const badge_text = if (self.state == null)
            "Unavailable"
        else if (self.client != null)
            "logind"
        else
            "read-only";
        const badge_color = if (self.state == null)
            cfg.warm_2
        else if (self.client != null)
            cfg.accent
        else
            cfg.warm_1;

        _ = ui.drawBadge(
            canvas,
            cfg,
            m,
            output_scale,
            width,
            font_scale,
            text_height,
            badge_text,
            badge_color,
        );
    }

    fn drawSummary(
        self: *Brightness,
        s: *session.Session,
        canvas: *render.Canvas,
        output_scale: i32,
        font_scale: f32,
        text_height: i32,
    ) void {
        const device = self.currentDevice() orelse return;
        const m = s.metrics;
        const cfg = s.cfg;
        const geometry = self.summaryGeometry(s);

        canvas.roundRect(
            ui.px(geometry.x, output_scale),
            ui.px(geometry.y, output_scale),
            ui.px(geometry.w, output_scale),
            ui.px(geometry.h, output_scale),
            ui.px(m.row_radius, output_scale),
            cfg.surface,
        );

        const icon_px = ui.px(m.icon_size, output_scale);
        const icon_x = ui.px(geometry.x + m.small_margin, output_scale);
        const icon_y = ui.px(geometry.y, output_scale) +
            @divTrunc(ui.px(geometry.h, output_scale) - icon_px, 2);

        if (self.sun_icon) |image| {
            canvas.imageTinted(icon_x, icon_y, icon_px, icon_px, &image, cfg.warm_1);
        } else {
            canvas.roundRect(
                icon_x,
                icon_y,
                icon_px,
                icon_px,
                ui.px(m.icon_radius, output_scale),
                cfg.highlight_low,
            );
            _ = canvas.text(
                icon_x + @divTrunc(icon_px - font.textWidth("B", font_scale), 2),
                icon_y + @divTrunc(icon_px - text_height, 2),
                "B",
                cfg.warm_1,
                font_scale,
            );
        }

        const text_x = ui.px(geometry.x + m.small_margin + m.icon_size + m.small_margin, output_scale);
        const pct_scale = font_scale * 1.25;
        const pct_height = ui.textHeight(pct_scale);
        const secondary_scale = font_scale * 0.85;
        const secondary_height = ui.textHeight(secondary_scale);
        const line_gap = ui.px(@max(1, @divTrunc(m.small_margin, 4)), output_scale);
        const block_height = pct_height + line_gap + secondary_height;
        const text_y = ui.px(geometry.y, output_scale) +
            @divTrunc(ui.px(geometry.h, output_scale) - block_height, 2);

        var percent_buffer: [8]u8 = undefined;
        var detail_buffer: [96]u8 = undefined;
        const percent_text = device.percentLabel(&percent_buffer);
        const detail_text = std.fmt.bufPrint(
            &detail_buffer,
            "{s} - {s}",
            .{ device.name, device.kind },
        ) catch device.name;

        _ = canvas.text(text_x, text_y, percent_text, cfg.text, pct_scale);
        _ = canvas.textFit(
            text_x,
            text_y + pct_height + line_gap,
            detail_text,
            cfg.detail_2,
            secondary_scale,
            ui.px(geometry.w - m.icon_size - m.small_margin * 3 - 160, output_scale),
        );

        const bar_width = ui.px(120, output_scale);
        const bar_height = @max(2, ui.px(ui.scaled(4, m.scale), output_scale));
        const bar_x = ui.px(geometry.x + geometry.w - m.small_margin, output_scale) - bar_width;
        const bar_y = ui.px(geometry.y, output_scale) +
            @divTrunc(ui.px(geometry.h, output_scale) - bar_height, 2);
        canvas.roundRect(
            bar_x,
            bar_y,
            bar_width,
            bar_height,
            @divTrunc(bar_height, 2),
            cfg.highlight_low,
        );

        const filled = @divTrunc(bar_width * @as(i32, device.percent()), 100);
        if (filled > 0) {
            canvas.roundRectGradient(
                bar_x,
                bar_y,
                bar_width,
                bar_height,
                @divTrunc(bar_height, 2),
                filled,
                &.{ cfg.accent, cfg.detail_1, cfg.warm_1 },
            );
        }
    }

    fn drawRows(
        self: *Brightness,
        s: *session.Session,
        canvas: *render.Canvas,
        output_scale: i32,
        font_scale: f32,
        text_height: i32,
    ) void {
        const state = if (self.state) |*value| value else return;
        const m = s.metrics;
        const cfg = s.cfg;
        const geometry = self.listGeometry(s);
        const secondary_scale = font_scale * 0.85;
        const secondary_height = ui.textHeight(secondary_scale);
        const line_gap = ui.px(@max(1, @divTrunc(m.small_margin, 4)), output_scale);
        const text_block = text_height + line_gap + secondary_height;
        const bar_width = ui.px(ui.scaled(52, m.scale), output_scale);
        const bar_height = @max(2, ui.px(ui.scaled(5, m.scale), output_scale));
        const margin_px = ui.px(m.small_margin, output_scale);
        const row_height_px = ui.px(m.row_height, output_scale);

        canvas.setClip(
            ui.px(geometry.x, output_scale),
            ui.px(geometry.y, output_scale),
            ui.px(geometry.w, output_scale),
            ui.px(geometry.h, output_scale),
        );

        for (state.devices, 0..) |device, index| {
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

            if (self.sun_icon) |image| {
                canvas.imageTinted(
                    icon_x,
                    icon_y,
                    icon_px,
                    icon_px,
                    &image,
                    if (self.selected == index) cfg.warm_1 else cfg.detail_2,
                );
            } else {
                canvas.roundRect(
                    icon_x,
                    icon_y,
                    icon_px,
                    icon_px,
                    ui.px(m.icon_radius, output_scale),
                    cfg.highlight_low,
                );
                const initial = if (device.name.len > 0) device.name[0..1] else "B";
                _ = canvas.text(
                    icon_x + @divTrunc(icon_px - font.textWidth(initial, font_scale), 2),
                    icon_y + @divTrunc(icon_px - text_height, 2),
                    initial,
                    cfg.detail_2,
                    font_scale,
                );
            }

            const text_top = row_y_px + @divTrunc(row_height_px - text_block, 2);
            const name_x = ui.px(
                geometry.x + m.small_margin + m.icon_size + m.small_margin,
                output_scale,
            );

            var percent_buffer: [8]u8 = undefined;
            const percent_text = device.percentLabel(&percent_buffer);
            const percent_width = font.textWidth(percent_text, font_scale);
            var info_left = ui.px(geometry.x + geometry.w - m.small_margin, output_scale);
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
            const filled = @divTrunc(bar_width * @as(i32, device.percent()), 100);
            if (filled > 0) {
                canvas.roundRectGradient(
                    bar_x,
                    bar_y,
                    bar_width,
                    bar_height,
                    @divTrunc(bar_height, 2),
                    filled,
                    &.{ cfg.accent, cfg.detail_1, cfg.warm_1 },
                );
            }
            info_left = bar_x;

            var detail_buffer: [96]u8 = undefined;
            const detail_text = std.fmt.bufPrint(
                &detail_buffer,
                "{s} - {d}/{d}",
                .{ device.kind, device.brightness, device.max_brightness },
            ) catch device.kind;

            const text_width = @max(0, info_left - margin_px - name_x);
            _ = canvas.textFit(
                name_x,
                text_top,
                device.name,
                cfg.text,
                font_scale,
                text_width,
            );
            _ = canvas.textFit(
                name_x,
                text_top + text_height + line_gap,
                detail_text,
                cfg.detail_2,
                secondary_scale,
                text_width,
            );
        }

        canvas.resetClip();
    }

    fn drawError(
        self: *Brightness,
        s: *session.Session,
        canvas: *render.Canvas,
        output_scale: i32,
        font_scale: f32,
        text_height: i32,
    ) void {
        const m = s.metrics;
        const width: i32 = @intCast(s.client.logical_width);
        ui.drawError(
            canvas,
            s.cfg,
            m,
            m.margin,
            m.margin + ui.scaled(ui.base_header_height, m.scale) + m.gap,
            @max(0, width - m.margin * 2),
            output_scale,
            font_scale,
            text_height,
            "Brightness unavailable",
            self.notice.text(),
        );
    }

    fn drawFooter(
        self: *Brightness,
        s: *session.Session,
        canvas: *render.Canvas,
        output_scale: i32,
        font_scale: f32,
    ) void {
        ui.drawFooter(
            canvas,
            s.cfg,
            s.metrics,
            @intCast(s.client.logical_width),
            @intCast(s.client.logical_height),
            output_scale,
            font_scale,
            if (self.notice.has()) self.notice.text() else "",
            if (self.session_len > 0)
                self.sessionNote()
            else
                "Up/Down select  Left/Right brightness  R refresh  Esc",
        );
    }

    fn nowMs(self: *const Brightness) i64 {
        return std.Io.Clock.Timestamp.now(self.io, .awake).raw.toMilliseconds();
    }

    fn setError(self: *Brightness, prefix: []const u8, err: anyerror) void {
        self.notice.setDetail(prefix, brightness.describe(err), self.nowMs(), 5000);
    }

    fn setFatalError(self: *Brightness, prefix: []const u8, err: anyerror) void {
        self.notice.setDetail(prefix, brightness.describe(err), self.nowMs(), 0);
    }

    fn setSessionNote(self: *Brightness, err: anyerror) void {
        const text: []const u8 = std.fmt.bufPrint(
            &self.session_buffer,
            "Read-only: {s}",
            .{brightness.describe(err)},
        ) catch "Read-only: brightness changes are unavailable";
        self.session_len = text.len;
    }

    fn sessionNote(self: *const Brightness) []const u8 {
        return self.session_buffer[0..self.session_len];
    }
};
