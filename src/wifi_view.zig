//! The Wi-Fi controller view.

const std = @import("std");
const wayland = @import("wayland.zig");
const render = @import("render.zig");
const font = @import("font.zig");
const png = @import("png.zig");
const config = @import("config.zig");
const ui = @import("ui.zig");
const session = @import("session.zig");
const wifi = @import("wifi.zig");
const worker_mod = @import("wifi_worker.zig");

const base_header_height = 36;
const base_footer_height = 24;
const refresh_ms = 5000;

pub const Wifi = struct {
    io: std.Io,
    gpa: std.mem.Allocator,

    worker: ?*worker_mod.Worker = null,
    state: ?wifi.State = null,
    wifi_icon: ?png.Image = null,
    signal_icon: ?png.Image = null,

    selected: usize = 0,
    hover: ?usize = null,
    scroll: i32 = 0,
    last_refresh_request_ms: i64 = 0,
    refresh_pending: bool = false,

    pending_action: ?worker_mod.Kind = null,
    pending_ssid: [128]u8 = undefined,
    pending_ssid_len: usize = 0,

    error_buffer: [256]u8 = undefined,
    error_len: usize = 0,
    error_deadline_ms: i64 = 0,

    pub fn init(io: std.Io, gpa: std.mem.Allocator) Wifi {
        var view = Wifi{
            .io = io,
            .gpa = gpa,
        };
        view.wifi_icon = png.decode(gpa, @embedFile("icons/wifi.png")) catch null;
        view.signal_icon = png.decode(gpa, @embedFile("icons/signal.png")) catch null;
        view.reload();
        return view;
    }

    pub fn deinit(self: *Wifi) void {
        if (self.worker) |worker| worker.stop();
        self.worker = null;
        if (self.state) |*state| state.deinit();
        if (self.wifi_icon) |*icon| icon.deinit(self.gpa);
        if (self.signal_icon) |*icon| icon.deinit(self.gpa);
        self.state = null;
        self.wifi_icon = null;
        self.signal_icon = null;
    }

    pub fn windowSize(_: *Wifi, metrics: ui.Metrics) ui.WindowSize {
        return .{ .width = metrics.window_width, .height = metrics.window_height };
    }

    pub fn wantsBlink(_: *Wifi) bool {
        return false;
    }

    pub fn tick(self: *Wifi, s: *session.Session) void {
        if (self.worker) |worker| {
            while (worker.poll()) |result_value| {
                var result = result_value;
                self.applyResult(&result, s);
                result.deinit();
            }
        }

        if (self.error_len > 0 and self.error_deadline_ms > 0 and s.nowMs() >= self.error_deadline_ms) {
            self.error_len = 0;
            self.error_deadline_ms = 0;
            s.dirty = true;
        }

        if (self.worker == null or self.pending_action != null or self.refresh_pending) return;
        const now = s.nowMs();
        if (self.last_refresh_request_ms != 0 and now - self.last_refresh_request_ms < refresh_ms) return;
        self.requestRefresh(s);
    }

    fn applyResult(self: *Wifi, result: *worker_mod.Result, s: *session.Session) void {
        if (result.state) |state| {
            var ssid_buffer: [128]u8 = undefined;
            const previous_ssid = self.copySelectedSsid(&ssid_buffer);
            if (self.state) |*old| old.deinit();
            self.state = state;
            result.state = null;
            self.selectBySsid(previous_ssid);
            self.ensureSelectionVisible(s);
            self.last_refresh_request_ms = s.nowMs();
        }

        switch (result.kind) {
            .refresh => {
                self.refresh_pending = false;
                if (!result.success) {
                    self.setError("Wi-Fi refresh failed", result.error_value orelse error.Protocol);
                }
            },
            .scan, .wireless, .connect, .disconnect => {
                if (self.pending_action == result.kind) {
                    self.pending_action = null;
                    self.pending_ssid_len = 0;
                }

                if (!result.success) {
                    const prefix = switch (result.kind) {
                        .scan => "Scan failed",
                        .wireless => "Wi-Fi power change failed",
                        .connect => "Connection failed",
                        .disconnect => "Disconnect failed",
                        else => unreachable,
                    };
                    self.setError(prefix, result.error_value orelse error.Protocol);
                } else if (result.error_value != null) {
                    self.setNotice("Action succeeded, but refresh failed");
                } else {
                    self.error_len = 0;
                    self.error_deadline_ms = 0;
                }
            },
        }
        s.dirty = true;
    }

    fn reload(self: *Wifi) void {
        self.error_len = 0;
        self.error_deadline_ms = 0;
        self.pending_action = null;
        self.pending_ssid_len = 0;
        self.refresh_pending = false;

        var ssid_buffer: [128]u8 = undefined;
        const previous_ssid = self.copySelectedSsid(&ssid_buffer);

        if (self.worker) |worker| worker.stop();
        self.worker = null;
        if (self.state) |*state| state.deinit();
        self.state = null;

        var client = wifi.Client.connect(self.io, self.gpa) catch |err| {
            self.setFatalError("Wi-Fi unavailable", err);
            self.clampSelection();
            return;
        };
        const state = client.refresh(self.gpa) catch |err| {
            client.deinit();
            self.setFatalError("Wi-Fi unavailable", err);
            self.clampSelection();
            return;
        };

        self.state = state;
        self.worker = worker_mod.Worker.start(self.io, client) catch |err| {
            if (self.state) |*owned| owned.deinit();
            self.state = null;
            self.setFatalError("Wi-Fi worker unavailable", err);
            self.clampSelection();
            return;
        };
        self.last_refresh_request_ms = self.nowMs();
        self.selectBySsid(previous_ssid);
    }

    fn requestRefresh(self: *Wifi, s: *session.Session) void {
        if (self.worker == null or self.refresh_pending) return;
        self.worker.?.submit(.{ .kind = .refresh }) catch |err| {
            self.setError("Wi-Fi refresh failed", err);
            s.dirty = true;
            return;
        };
        self.refresh_pending = true;
        self.last_refresh_request_ms = s.nowMs();
        s.dirty = true;
    }

    pub fn overTextField(_: *Wifi, _: *session.Session) bool {
        return false;
    }

    pub fn handleKey(self: *Wifi, s: *session.Session, key: wayland.Key, is_repeat: bool) void {
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
        if (key.keysym == ui.key_return or key.keysym == ui.key_kp_enter) {
            if (!is_repeat) self.connectSelected(s);
            return;
        }
        if (key.keysym == 'x' or key.keysym == 'X') {
            if (!is_repeat) self.disconnect(s);
            return;
        }
        if (key.keysym == 's' or key.keysym == 'S') {
            if (!is_repeat) self.scan(s);
            return;
        }
        if (key.keysym == 'p' or key.keysym == 'P') {
            if (!is_repeat) self.toggleWireless(s);
            return;
        }
        if (key.keysym == 'r' or key.keysym == 'R') {
            if (!is_repeat) {
                if (self.worker != null) {
                    self.requestRefresh(s);
                } else {
                    self.reload();
                    self.ensureSelectionVisible(s);
                }
                s.dirty = true;
            }
        }
    }

    pub fn pointerMoved(self: *Wifi, s: *session.Session) void {
        self.updateHover(s);
    }

    pub fn pointerLeft(self: *Wifi, s: *session.Session) void {
        if (self.hover != null) {
            self.hover = null;
            s.dirty = true;
        }
    }

    pub fn pointerClick(self: *Wifi, s: *session.Session) void {
        if (self.hitRow(s)) |index| {
            self.selected = index;
            s.dirty = true;
        }
    }

    pub fn pointerScroll(self: *Wifi, s: *session.Session, delta: f32) void {
        const max_scroll = self.maxScroll(s);
        if (max_scroll == 0) return;
        self.scroll = std.math.clamp(
            self.scroll + @as(i32, @intFromFloat(delta * 4.0)),
            0,
            max_scroll,
        );
        self.updateHover(s);
        s.dirty = true;
    }

    pub fn draw(self: *Wifi, s: *session.Session, canvas: *render.Canvas, _: i64) void {
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

    fn drawHeader(
        self: *Wifi,
        s: *session.Session,
        canvas: *render.Canvas,
        output_scale: i32,
        font_scale: f32,
        text_height: i32,
    ) void {
        const m = s.metrics;
        const cfg = s.cfg;
        const width: i32 = @intCast(s.client.logical_width);
        const header_height = ui.scaled(base_header_height, m.scale);
        const title_y = ui.px(m.margin, output_scale) +
            @divTrunc(ui.px(header_height, output_scale) - text_height, 2);
        const title_end = canvas.text(
            ui.px(m.margin, output_scale),
            title_y,
            "Wi-Fi",
            cfg.text,
            font_scale,
        );

        const state = if (self.state) |*value| value else null;
        const scan_pending = self.pending_action == .scan;
        const connected = if (state) |value| blk: {
            if (value.device) |device| break :blk device.state == 100;
            break :blk false;
        } else false;
        const badge_text = if (state) |value| blk: {
            if (!value.wireless_enabled) break :blk "Off";
            if (scan_pending) break :blk "Scanning...";
            if (connected) break :blk "Connected";
            break :blk "On";
        } else "Unavailable";
        const badge_color = if (state) |value| blk: {
            if (!value.wireless_enabled) break :blk cfg.muted;
            if (scan_pending) break :blk cfg.warm_1;
            if (connected) break :blk cfg.accent;
            break :blk cfg.accent;
        } else cfg.muted;

        const small_margin_px = ui.px(m.small_margin, output_scale);
        const badge_width = font.textWidth(badge_text, font_scale) + small_margin_px * 2;
        const badge_height = text_height + small_margin_px;
        const badge_x = ui.px(width - m.margin, output_scale) - badge_width;
        const badge_y = ui.px(m.margin, output_scale) +
            @divTrunc(ui.px(header_height, output_scale) - badge_height, 2);

        canvas.roundRect(
            badge_x,
            badge_y,
            badge_width,
            badge_height,
            ui.px(m.row_radius, output_scale),
            cfg.highlight_low,
        );
        _ = canvas.text(
            badge_x + small_margin_px,
            badge_y + @divTrunc(badge_height - text_height, 2),
            badge_text,
            badge_color,
            font_scale,
        );

        if (state) |value| {
            if (value.device) |device| {
                const label = device.interface;
                const label_scale = font_scale * 0.85;
                const label_width = font.textWidth(label, label_scale);
                const label_x = badge_x - small_margin_px - label_width;
                if (label_x > title_end + small_margin_px) {
                    _ = canvas.text(
                        label_x,
                        ui.px(m.margin, output_scale) +
                            @divTrunc(ui.px(header_height, output_scale) - ui.textHeight(label_scale), 2),
                        label,
                        cfg.detail_2,
                        label_scale,
                    );
                }
            }
        }
    }

    fn drawRows(
        self: *Wifi,
        s: *session.Session,
        canvas: *render.Canvas,
        geometry: ListGeometry,
        output_scale: i32,
        font_scale: f32,
        text_height: i32,
    ) void {
        const m = s.metrics;
        const cfg = s.cfg;
        const state = if (self.state) |*value| value else return;

        if (state.networks.len == 0) {
            _ = canvas.text(
                ui.px(geometry.x + m.small_margin, output_scale),
                ui.px(geometry.y + m.small_margin, output_scale),
                "No networks found. Press S to scan.",
                cfg.muted,
                font_scale,
            );
            return;
        }

        const secondary_scale = font_scale * 0.85;
        const secondary_height = ui.textHeight(secondary_scale);
        const line_gap = ui.px(@max(1, @divTrunc(m.small_margin, 4)), output_scale);
        const text_block = text_height + secondary_height + line_gap;
        const margin_px = ui.px(m.small_margin, output_scale);
        const row_height_px = ui.px(m.row_height, output_scale);
        const metric_scale = font_scale * 0.8;
        const metric_height = ui.textHeight(metric_scale);
        const icon_size = ui.px(ui.scaled(16, m.scale), output_scale);
        const bar_width = ui.px(ui.scaled(34, m.scale), output_scale);
        const bar_height = @max(2, ui.px(ui.scaled(4, m.scale), output_scale));
        const item_gap = @divTrunc(margin_px, 2);

        for (state.networks, 0..) |network, index| {
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
            if (self.wifi_icon) |image| {
                canvas.imageTinted(icon_x, icon_y, icon_px, icon_px, &image, cfg.detail_2);
            } else {
                canvas.roundRect(
                    icon_x,
                    icon_y,
                    icon_px,
                    icon_px,
                    ui.px(m.icon_radius, output_scale),
                    cfg.highlight_low,
                );
            }

            const text_top = row_y_px + @divTrunc(row_height_px - text_block, 2);
            const secondary_y = text_top + text_height + line_gap;
            const name_x = ui.px(
                geometry.x + m.small_margin + m.icon_size + m.small_margin * 2,
                output_scale,
            );

            const pending_connect = self.pending_action == .connect and
                self.pendingSsidMatches(network.ssid);
            const pending_disconnect = self.pending_action == .disconnect and network.connected;
            const status_text = if (pending_connect)
                "Connecting..."
            else if (pending_disconnect)
                "Disconnecting..."
            else if (network.connected)
                "Connected"
            else if (state.findSaved(network.ssid) != null)
                "Saved"
            else if (network.secured)
                "Secured"
            else
                "Open";
            const status_color = if (pending_connect or pending_disconnect)
                cfg.warm_1
            else if (network.connected)
                cfg.accent
            else if (state.findSaved(network.ssid) != null)
                cfg.detail_1
            else if (network.secured)
                cfg.muted
            else
                cfg.warm_1;

            const status_width = font.textWidth(status_text, font_scale);
            const right_edge = ui.px(geometry.x + geometry.w - m.small_margin, output_scale);
            const status_x = right_edge - status_width;

            var value_buffer: [8]u8 = undefined;
            const value_text = percentLabel(&value_buffer, network.strength);
            const value_width = font.textWidth(value_text, metric_scale);
            const metrics_width = icon_size + item_gap + bar_width + item_gap + value_width;
            const metrics_x = right_edge - metrics_width;
            const right_limit = @min(status_x, metrics_x);
            const name_width = @max(0, right_limit - margin_px - name_x);

            _ = canvas.textFit(
                name_x,
                text_top,
                network.label(),
                cfg.text,
                font_scale,
                name_width,
            );
            const security = if (network.secured) "Secured" else "Open";
            var secondary_buffer: [48]u8 = undefined;
            const secondary_text = if (network.bandLabel()) |band|
                std.fmt.bufPrint(&secondary_buffer, "{s} - {s}", .{ security, band }) catch security
            else
                security;
            _ = canvas.textFit(
                name_x,
                secondary_y,
                secondary_text,
                cfg.detail_2,
                secondary_scale,
                name_width,
            );
            _ = canvas.text(
                status_x,
                text_top,
                status_text,
                status_color,
                font_scale,
            );

            drawSignalMetric(
                canvas,
                metrics_x,
                secondary_y,
                icon_size,
                metric_scale,
                metric_height,
                bar_width,
                bar_height,
                item_gap,
                self.signal_icon,
                cfg,
                value_text,
                network.strength,
            );
        }
    }

    fn drawError(
        self: *Wifi,
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
            "Wi-Fi backend unavailable",
            cfg.warm_2,
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
            cfg.warm_2,
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
        self: *Wifi,
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
            "Up/Down  Enter connect  X disconnect  S scan  P Wi-Fi on/off  R refresh  Esc";

        _ = canvas.textFit(
            ui.px(m.margin, output_scale),
            y,
            text,
            if (self.error_len > 0) cfg.warm_2 else cfg.muted,
            hint_scale,
            width,
        );
    }

    fn listGeometry(_: *Wifi, s: *session.Session) ListGeometry {
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

    fn maxScroll(self: *Wifi, s: *session.Session) i32 {
        const state = if (self.state) |*value| value else return 0;
        const geometry = self.listGeometry(s);
        const content = @as(i32, @intCast(state.networks.len)) * s.metrics.row_step - s.metrics.gap;
        return @max(0, content - geometry.h);
    }

    fn ensureSelectionVisible(self: *Wifi, s: *session.Session) void {
        const geometry = self.listGeometry(s);
        const top = @as(i32, @intCast(self.selected)) * s.metrics.row_step;
        const bottom = top + s.metrics.row_height;
        if (top < self.scroll) self.scroll = top;
        if (bottom > self.scroll + geometry.h) self.scroll = bottom - geometry.h;
        self.scroll = std.math.clamp(self.scroll, 0, self.maxScroll(s));
    }

    fn hitRow(self: *Wifi, s: *session.Session) ?usize {
        if (!s.pointer_inside) return null;
        const state = if (self.state) |*value| value else return null;

        const geometry = self.listGeometry(s);
        const fx: i32 = @intFromFloat(@floor(s.pointer_x));
        const fy: i32 = @intFromFloat(@floor(s.pointer_y));
        if (fx < geometry.x or fx >= geometry.x + geometry.w) return null;
        if (fy < geometry.y or fy >= geometry.y + geometry.h) return null;

        const local = fy - geometry.y + self.scroll;
        if (local < 0) return null;
        const index: usize = @intCast(@divTrunc(local, s.metrics.row_step));
        if (index >= state.networks.len) return null;
        if (@mod(local, s.metrics.row_step) >= s.metrics.row_height) return null;
        return index;
    }

    fn updateHover(self: *Wifi, s: *session.Session) void {
        const hovered = self.hitRow(s);
        if (hovered != self.hover) {
            self.hover = hovered;
            s.dirty = true;
        }
    }

    fn moveSelection(self: *Wifi, s: *session.Session, delta: i32) void {
        const state = if (self.state) |*value| value else return;
        if (state.networks.len == 0) return;
        const next = @as(i32, @intCast(self.selected)) + delta;
        self.selected = @intCast(std.math.clamp(next, 0, @as(i32, @intCast(state.networks.len - 1))));
        self.ensureSelectionVisible(s);
        self.updateHover(s);
        s.dirty = true;
    }

    fn currentNetwork(self: *Wifi) ?*wifi.Network {
        const state = if (self.state) |*value| value else return null;
        if (self.selected >= state.networks.len) return null;
        return &state.networks[self.selected];
    }

    fn clampSelection(self: *Wifi) void {
        const state = if (self.state) |*value| value else {
            self.selected = 0;
            return;
        };
        if (state.networks.len == 0) {
            self.selected = 0;
        } else if (self.selected >= state.networks.len) {
            self.selected = state.networks.len - 1;
        }
    }

    fn copySelectedSsid(self: *Wifi, buffer: *[128]u8) ?[]const u8 {
        const network = self.currentNetwork() orelse return null;
        if (network.ssid.len > buffer.len) return null;
        @memcpy(buffer[0..network.ssid.len], network.ssid);
        return buffer[0..network.ssid.len];
    }

    fn selectBySsid(self: *Wifi, ssid: ?[]const u8) void {
        if (ssid) |wanted| {
            if (self.state) |*state| {
                for (state.networks, 0..) |network, index| {
                    if (std.mem.eql(u8, network.ssid, wanted)) {
                        self.selected = index;
                        return;
                    }
                }
            }
        }
        self.clampSelection();
    }

    fn pendingSsidMatches(self: *Wifi, ssid: []const u8) bool {
        if (self.pending_ssid_len != ssid.len) return false;
        return std.mem.eql(u8, self.pending_ssid[0..self.pending_ssid_len], ssid);
    }

    fn connectSelected(self: *Wifi, s: *session.Session) void {
        const network = self.currentNetwork() orelse return;
        const state = if (self.state) |*value| value else return;
        if (network.connected) {
            self.setNotice("Already connected");
            s.dirty = true;
            return;
        }
        const saved = state.findSaved(network.ssid) orelse {
            self.setNotice("No saved profile for this network");
            s.dirty = true;
            return;
        };
        const device = state.device orelse {
            self.setNotice("No Wi-Fi device");
            s.dirty = true;
            return;
        };
        self.submitJob(.connect, device.path, network.ap_path, saved.path, true, network.ssid, s);
    }

    fn disconnect(self: *Wifi, s: *session.Session) void {
        const state = if (self.state) |*value| value else return;
        const device = state.device orelse {
            self.setNotice("No Wi-Fi device");
            s.dirty = true;
            return;
        };
        if (std.mem.eql(u8, device.active_ap, "/")) {
            self.setNotice("Not connected");
            s.dirty = true;
            return;
        }
        self.submitJob(.disconnect, device.path, "", "", false, "", s);
    }

    fn scan(self: *Wifi, s: *session.Session) void {
        const state = if (self.state) |*value| value else return;
        const device = state.device orelse {
            self.setNotice("No Wi-Fi device");
            s.dirty = true;
            return;
        };
        self.submitJob(.scan, device.path, "", "", false, "", s);
    }

    fn toggleWireless(self: *Wifi, s: *session.Session) void {
        const state = if (self.state) |*value| value else return;
        self.submitJob(.wireless, "", "", "", !state.wireless_enabled, "", s);
    }

    fn submitJob(
        self: *Wifi,
        kind: worker_mod.Kind,
        device_path: []const u8,
        ap_path: []const u8,
        saved_path: []const u8,
        value: bool,
        ssid: []const u8,
        s: *session.Session,
    ) void {
        if (self.worker == null) {
            self.setNotice("Wi-Fi unavailable");
            s.dirty = true;
            return;
        }
        if (self.pending_action != null) {
            self.setNotice("Action already in progress");
            s.dirty = true;
            return;
        }
        if (device_path.len > 256 or ap_path.len > 256 or saved_path.len > 256 or ssid.len > 128) {
            self.setNotice("Network name too long");
            s.dirty = true;
            return;
        }

        var job = worker_mod.Job{
            .kind = kind,
            .device_len = device_path.len,
            .ap_len = ap_path.len,
            .saved_len = saved_path.len,
            .value = value,
        };
        @memcpy(job.device_path[0..device_path.len], device_path);
        @memcpy(job.ap_path[0..ap_path.len], ap_path);
        @memcpy(job.saved_path[0..saved_path.len], saved_path);

        self.worker.?.submit(job) catch |err| {
            self.setError("Wi-Fi action failed", err);
            s.dirty = true;
            return;
        };

        self.pending_action = kind;
        self.pending_ssid_len = ssid.len;
        @memcpy(self.pending_ssid[0..ssid.len], ssid);
        self.error_len = 0;
        self.error_deadline_ms = 0;
        s.dirty = true;
    }

    fn nowMs(self: *const Wifi) i64 {
        return std.Io.Clock.Timestamp.now(self.io, .awake).raw.toMilliseconds();
    }

    fn setError(self: *Wifi, prefix: []const u8, err: anyerror) void {
        const text: []const u8 = std.fmt.bufPrint(
            &self.error_buffer,
            "{s}: {s}",
            .{ prefix, @errorName(err) },
        ) catch "Wi-Fi error";
        self.error_len = text.len;
        self.error_deadline_ms = self.nowMs() + 5000;
    }

    fn setFatalError(self: *Wifi, prefix: []const u8, err: anyerror) void {
        const text: []const u8 = std.fmt.bufPrint(
            &self.error_buffer,
            "{s}: {s}",
            .{ prefix, @errorName(err) },
        ) catch "Wi-Fi error";
        self.error_len = text.len;
        self.error_deadline_ms = 0;
    }

    fn setNotice(self: *Wifi, text: []const u8) void {
        const length = @min(text.len, self.error_buffer.len);
        @memcpy(self.error_buffer[0..length], text[0..length]);
        self.error_len = length;
        self.error_deadline_ms = self.nowMs() + 5000;
    }

    fn errorSlice(self: *const Wifi) []const u8 {
        return self.error_buffer[0..self.error_len];
    }
};

const ListGeometry = struct {
    x: i32,
    y: i32,
    w: i32,
    h: i32,
};

fn percentLabel(buffer: []u8, percent: u8) []const u8 {
    return std.fmt.bufPrint(buffer, "{d:>3}%", .{percent}) catch "???%";
}

fn drawSignalMetric(
    canvas: *render.Canvas,
    x: i32,
    y: i32,
    icon_size: i32,
    glyph_scale: f32,
    text_height: i32,
    bar_width: i32,
    bar_height: i32,
    gap: i32,
    icon: ?png.Image,
    cfg: config.Config,
    value: []const u8,
    percent: u8,
) void {
    const icon_y = y + @divTrunc(text_height - icon_size, 2);
    if (icon) |image| {
        canvas.imageTinted(x, icon_y, icon_size, icon_size, &image, cfg.accent);
    }

    const bar_x = x + icon_size + gap;
    const bar_y = y + @divTrunc(text_height - bar_height, 2);
    canvas.roundRect(
        bar_x,
        bar_y,
        bar_width,
        bar_height,
        @divTrunc(bar_height, 2),
        cfg.highlight_low,
    );

    const filled = @divTrunc(bar_width * @as(i32, percent), 100);
    if (filled > 0) {
        canvas.roundRectGradient(
            bar_x,
            bar_y,
            bar_width,
            bar_height,
            @divTrunc(bar_height, 2),
            filled,
            &.{ cfg.warm_2, cfg.warm_1, cfg.accent },
        );
    }

    _ = canvas.text(
        bar_x + bar_width + gap,
        y,
        value,
        cfg.detail_2,
        glyph_scale,
    );
}
