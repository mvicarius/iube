//! The Bluetooth controller view.
//!
//! BlueZ owns the adapter and devices. This view reads the BlueZ object tree
//! through `bluetooth.zig` and exposes the small set of controls that make
//! sense in a launcher-style overlay: power, discovery, selection and
//! connect/disconnect.

const std = @import("std");
const wayland = @import("wayland.zig");
const render = @import("render.zig");
const font = @import("font.zig");
const png = @import("png.zig");
const config = @import("config.zig");
const ui = @import("ui.zig");
const session = @import("session.zig");
const bluetooth = @import("bluetooth.zig");
const worker_mod = @import("bluetooth_worker.zig");

const base_header_height = 36;
const base_footer_height = 24;
const discovery_refresh_ms = 2000;
const idle_refresh_ms = 5000;

pub const Bluetooth = struct {
    io: std.Io,
    gpa: std.mem.Allocator,

    worker: ?*worker_mod.Worker = null,
    state: ?bluetooth.State = null,
    signal_icon: ?png.Image = null,
    battery_icon: ?png.Image = null,

    selected: usize = 0,
    hover: ?usize = null,
    scroll: i32 = 0,
    last_refresh_request_ms: i64 = 0,
    refresh_pending: bool = false,

    pending_action: ?worker_mod.Kind = null,
    pending_path: [256]u8 = undefined,
    pending_path_len: usize = 0,
    pending_connect: bool = false,

    error_buffer: [256]u8 = undefined,
    error_len: usize = 0,
    error_deadline_ms: i64 = 0,

    pub fn init(io: std.Io, gpa: std.mem.Allocator) Bluetooth {
        var view = Bluetooth{
            .io = io,
            .gpa = gpa,
        };
        view.signal_icon = png.decode(gpa, @embedFile("icons/signal.png")) catch null;
        view.battery_icon = png.decode(gpa, @embedFile("icons/battery-half.png")) catch null;
        view.reload();
        return view;
    }

    pub fn deinit(self: *Bluetooth) void {
        if (self.worker) |worker| worker.stop();
        self.worker = null;
        if (self.state) |*state| state.deinit();
        if (self.signal_icon) |*icon| icon.deinit(self.gpa);
        if (self.battery_icon) |*icon| icon.deinit(self.gpa);
        self.state = null;
        self.signal_icon = null;
        self.battery_icon = null;
    }

    pub fn windowSize(_: *Bluetooth, metrics: ui.Metrics) ui.WindowSize {
        return .{ .width = metrics.window_width, .height = metrics.window_height };
    }

    pub fn wantsBlink(_: *Bluetooth) bool {
        return false;
    }

    pub fn tick(self: *Bluetooth, s: *session.Session) void {
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
        const interval: i64 = if (self.adapter()) |current_adapter|
            (if (current_adapter.powered and current_adapter.discovering)
                discovery_refresh_ms
            else
                idle_refresh_ms)
        else
            idle_refresh_ms;

        if (self.last_refresh_request_ms != 0 and now - self.last_refresh_request_ms < interval) return;
        self.requestRefresh(s);
    }

    fn applyResult(self: *Bluetooth, result: *worker_mod.Result, s: *session.Session) void {
        if (result.state) |state| {
            var path_buffer: [256]u8 = undefined;
            const previous_path = self.copySelectedPath(&path_buffer);
            if (self.state) |*old| old.deinit();
            self.state = state;
            result.state = null;
            self.selectByPath(previous_path);
            self.ensureSelectionVisible(s);
            self.last_refresh_request_ms = s.nowMs();
        }

        switch (result.kind) {
            .refresh => {
                self.refresh_pending = false;
                if (!result.success) {
                    self.setError(
                        "Bluetooth refresh failed",
                        result.error_value orelse error.Protocol,
                    );
                }
            },
            .power, .discovery, .connect, .pair, .forget => {
                if (self.pending_action == result.kind) {
                    self.pending_action = null;
                    self.pending_path_len = 0;
                    self.pending_connect = false;
                }

                if (!result.success) {
                    const failure = result.error_value orelse error.Protocol;
                    if (result.kind == .pair and failure == error.PasskeyRequired) {
                        self.setNotice("Pairing needs a passkey; iube only supports just-works");
                    } else {
                        const prefix = switch (result.kind) {
                            .power => "Power change failed",
                            .discovery => "Discovery change failed",
                            .connect => "Connection failed",
                            .pair => "Pairing failed",
                            .forget => "Forget failed",
                            else => unreachable,
                        };
                        self.setError(prefix, failure);
                    }
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

    pub fn overTextField(_: *Bluetooth, _: *session.Session) bool {
        return false;
    }

    pub fn handleKey(self: *Bluetooth, s: *session.Session, key: wayland.Key, is_repeat: bool) void {
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
            if (!is_repeat) self.toggleConnection(s);
            return;
        }

        if (key.keysym == 'p' or key.keysym == 'P') {
            if (!is_repeat) self.togglePower(s);
            return;
        }

        if (key.keysym == 'd' or key.keysym == 'D') {
            if (!is_repeat) self.toggleDiscovery(s);
            return;
        }

        if (key.keysym == 'a' or key.keysym == 'A') {
            if (!is_repeat) self.pairSelected(s);
            return;
        }

        if (key.keysym == ui.key_delete) {
            if (!is_repeat) self.forgetSelected(s);
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

    pub fn pointerMoved(self: *Bluetooth, s: *session.Session) void {
        self.updateHover(s);
    }

    pub fn pointerLeft(self: *Bluetooth, s: *session.Session) void {
        if (self.hover != null) {
            self.hover = null;
            s.dirty = true;
        }
    }

    pub fn pointerClick(self: *Bluetooth, s: *session.Session) void {
        if (self.hitRow(s)) |index| {
            self.selected = index;
            s.dirty = true;
        }
    }

    pub fn pointerScroll(self: *Bluetooth, s: *session.Session, delta: f32) void {
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

    pub fn draw(self: *Bluetooth, s: *session.Session, canvas: *render.Canvas, _: i64) void {
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

    fn reload(self: *Bluetooth) void {
        self.error_len = 0;
        self.error_deadline_ms = 0;
        self.pending_action = null;
        self.pending_path_len = 0;
        self.pending_connect = false;
        self.refresh_pending = false;

        var path_buffer: [256]u8 = undefined;
        const previous_path = self.copySelectedPath(&path_buffer);

        if (self.worker) |worker| worker.stop();
        self.worker = null;
        if (self.state) |*state| state.deinit();
        self.state = null;

        var client = bluetooth.Client.connect(self.io, self.gpa) catch |err| {
            self.setFatalError("Bluetooth unavailable", err);
            self.clampSelection();
            return;
        };
        const state = client.refresh(self.gpa) catch |err| {
            client.deinit();
            self.setFatalError("Bluetooth unavailable", err);
            self.clampSelection();
            return;
        };

        self.state = state;
        self.worker = worker_mod.Worker.start(self.io, client) catch |err| {
            // Worker.start owns and closes the client on failure.
            if (self.state) |*owned| owned.deinit();
            self.state = null;
            self.setFatalError("Bluetooth worker unavailable", err);
            self.clampSelection();
            return;
        };
        self.last_refresh_request_ms = self.nowMs();
        self.selectByPath(previous_path);
    }

    fn requestRefresh(self: *Bluetooth, s: *session.Session) void {
        if (self.worker == null or self.refresh_pending) return;

        self.worker.?.submit(.{ .kind = .refresh }) catch |err| {
            self.setError("Bluetooth refresh failed", err);
            s.dirty = true;
            return;
        };
        self.refresh_pending = true;
        self.last_refresh_request_ms = s.nowMs();
        s.dirty = true;
    }

    fn copySelectedPath(self: *Bluetooth, buffer: *[256]u8) ?[]const u8 {
        const device = self.currentDevice() orelse return null;
        if (device.path.len > buffer.len) return null;
        @memcpy(buffer[0..device.path.len], device.path);
        return buffer[0..device.path.len];
    }

    fn selectByPath(self: *Bluetooth, path: ?[]const u8) void {
        if (path) |wanted| {
            if (self.devices()) |list| {
                for (list, 0..) |device, index| {
                    if (std.mem.eql(u8, device.path, wanted)) {
                        self.selected = index;
                        return;
                    }
                }
            }
        }
        self.clampSelection();
    }

    fn nowMs(self: *const Bluetooth) i64 {
        return std.Io.Clock.Timestamp.now(self.io, .awake).raw.toMilliseconds();
    }

    fn setError(self: *Bluetooth, prefix: []const u8, err: anyerror) void {
        const text: []const u8 = std.fmt.bufPrint(
            &self.error_buffer,
            "{s}: {s}",
            .{ prefix, @errorName(err) },
        ) catch "Bluetooth error";
        self.error_len = text.len;
        self.error_deadline_ms = self.nowMs() + 5000;
    }

    fn setFatalError(self: *Bluetooth, prefix: []const u8, err: anyerror) void {
        const text: []const u8 = std.fmt.bufPrint(
            &self.error_buffer,
            "{s}: {s}",
            .{ prefix, @errorName(err) },
        ) catch "Bluetooth error";
        self.error_len = text.len;
        self.error_deadline_ms = 0;
    }

    fn setNotice(self: *Bluetooth, text: []const u8) void {
        const length = @min(text.len, self.error_buffer.len);
        @memcpy(self.error_buffer[0..length], text[0..length]);
        self.error_len = length;
        self.error_deadline_ms = self.nowMs() + 5000;
    }

    fn errorSlice(self: *const Bluetooth) []const u8 {
        return self.error_buffer[0..self.error_len];
    }

    fn devices(self: *Bluetooth) ?[]bluetooth.Device {
        const state = if (self.state) |*value| value else return null;
        return state.devices;
    }

    fn currentDevice(self: *Bluetooth) ?*bluetooth.Device {
        const list = self.devices() orelse return null;
        if (self.selected >= list.len) return null;
        return &list[self.selected];
    }

    fn adapter(self: *Bluetooth) ?bluetooth.Adapter {
        const state = if (self.state) |*value| value else return null;
        return state.adapter();
    }

    fn clampSelection(self: *Bluetooth) void {
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

    fn moveSelection(self: *Bluetooth, s: *session.Session, delta: i32) void {
        const list = self.devices() orelse return;
        if (list.len == 0) return;

        const next = @as(i32, @intCast(self.selected)) + delta;
        self.selected = @intCast(std.math.clamp(next, 0, @as(i32, @intCast(list.len - 1))));
        self.ensureSelectionVisible(s);
        self.updateHover(s);
        s.dirty = true;
    }

    fn togglePower(self: *Bluetooth, s: *session.Session) void {
        const active_adapter = self.adapter() orelse {
            self.setNotice("No Bluetooth adapter");
            s.dirty = true;
            return;
        };
        _ = self.submitAction(.power, active_adapter.path, active_adapter.path, !active_adapter.powered, s);
    }

    fn toggleDiscovery(self: *Bluetooth, s: *session.Session) void {
        const active_adapter = self.adapter() orelse {
            self.setNotice("No Bluetooth adapter");
            s.dirty = true;
            return;
        };
        if (!active_adapter.powered) {
            self.setNotice("Bluetooth is off");
            s.dirty = true;
            return;
        }
        _ = self.submitAction(.discovery, active_adapter.path, active_adapter.path, !active_adapter.discovering, s);
    }

    fn toggleConnection(self: *Bluetooth, s: *session.Session) void {
        const device = self.currentDevice() orelse return;
        _ = self.submitAction(.connect, device.path, device.adapter_path, !device.connected, s);
    }

    fn pairSelected(self: *Bluetooth, s: *session.Session) void {
        const device = self.currentDevice() orelse return;
        if (device.paired) {
            self.setNotice("Device is already paired");
            s.dirty = true;
            return;
        }
        _ = self.submitAction(.pair, device.path, device.adapter_path, false, s);
    }

    fn forgetSelected(self: *Bluetooth, s: *session.Session) void {
        const device = self.currentDevice() orelse return;
        _ = self.submitAction(.forget, device.path, device.adapter_path, false, s);
    }

    fn submitAction(
        self: *Bluetooth,
        kind: worker_mod.Kind,
        path: []const u8,
        adapter_path: []const u8,
        value: bool,
        s: *session.Session,
    ) bool {
        if (self.worker == null) {
            self.setNotice("Bluetooth unavailable");
            s.dirty = true;
            return false;
        }
        if (self.pending_action != null) {
            self.setNotice("Action already in progress");
            s.dirty = true;
            return false;
        }
        if (path.len > self.pending_path.len) {
            self.setNotice("Device path too long");
            s.dirty = true;
            return false;
        }
        if (adapter_path.len > 256) {
            self.setNotice("Adapter path too long");
            s.dirty = true;
            return false;
        }

        var job = worker_mod.Job{
            .kind = kind,
            .path_len = path.len,
            .adapter_path_len = adapter_path.len,
            .value = value,
        };
        @memcpy(job.path[0..path.len], path);
        @memcpy(job.adapter_path[0..adapter_path.len], adapter_path);

        self.worker.?.submit(job) catch |err| {
            self.setError("Bluetooth action failed", err);
            s.dirty = true;
            return false;
        };

        self.pending_action = kind;
        self.pending_path_len = path.len;
        self.pending_connect = kind == .connect and value;
        @memcpy(self.pending_path[0..path.len], path);
        self.error_len = 0;
        self.error_deadline_ms = 0;
        s.dirty = true;
        return true;
    }

    fn pendingKindFor(self: *Bluetooth, device: bluetooth.Device) ?worker_mod.Kind {
        const kind = self.pending_action orelse return null;
        if (self.pending_path_len != device.path.len) return null;
        if (!std.mem.eql(u8, self.pending_path[0..self.pending_path_len], device.path)) return null;
        return kind;
    }

    fn listGeometry(_: *Bluetooth, s: *session.Session) ListGeometry {
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

    fn maxScroll(self: *Bluetooth, s: *session.Session) i32 {
        const list = self.devices() orelse return 0;
        const geometry = self.listGeometry(s);
        const content = @as(i32, @intCast(list.len)) * s.metrics.row_step - s.metrics.gap;
        return @max(0, content - geometry.h);
    }

    fn ensureSelectionVisible(self: *Bluetooth, s: *session.Session) void {
        const geometry = self.listGeometry(s);
        const top = @as(i32, @intCast(self.selected)) * s.metrics.row_step;
        const bottom = top + s.metrics.row_height;
        if (top < self.scroll) self.scroll = top;
        if (bottom > self.scroll + geometry.h) self.scroll = bottom - geometry.h;
        self.scroll = std.math.clamp(self.scroll, 0, self.maxScroll(s));
    }

    fn hitRow(self: *Bluetooth, s: *session.Session) ?usize {
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

    fn updateHover(self: *Bluetooth, s: *session.Session) void {
        const hovered = self.hitRow(s);
        if (hovered != self.hover) {
            self.hover = hovered;
            s.dirty = true;
        }
    }

    fn drawHeader(
        self: *Bluetooth,
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
            "Bluetooth",
            cfg.text,
            font_scale,
        );

        const active_adapter = self.adapter();
        const badge_text = if (active_adapter == null)
            "No adapter"
        else if (!active_adapter.?.powered)
            "Off"
        else if (active_adapter.?.discovering)
            "Discovering"
        else
            "On";
        const badge_color = if (active_adapter == null or !active_adapter.?.powered)
            cfg.muted
        else if (active_adapter.?.discovering)
            cfg.warm_1
        else
            cfg.accent;
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

        if (active_adapter) |value| {
            const adapter_scale = font_scale * 0.85;
            const label = value.label();
            const label_width = font.textWidth(label, adapter_scale);
            const label_x = badge_x - small_margin_px - label_width;
            if (label_x > title_end + small_margin_px) {
                _ = canvas.text(
                    label_x,
                    ui.px(m.margin, output_scale) +
                        @divTrunc(ui.px(header_height, output_scale) - ui.textHeight(adapter_scale), 2),
                    label,
                    cfg.detail_2,
                    adapter_scale,
                );
            }
        }
    }

    fn drawRows(
        self: *Bluetooth,
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
                "No Bluetooth devices",
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
                cfg.detail_2,
                font_scale,
            );

            const text_top = row_y_px + @divTrunc(row_height_px - text_block, 2);
            const secondary_y = text_top + text_height + line_gap;
            const name_x = ui.px(
                geometry.x + m.small_margin + m.icon_size + m.small_margin * 2,
                output_scale,
            );

            const pending_kind = self.pendingKindFor(device);
            const status_text = if (pending_kind) |kind| switch (kind) {
                .connect => if (self.pending_connect) "Connecting..." else "Disconnecting...",
                .pair => "Pairing...",
                .forget => "Forgetting...",
                else => device.stateLabel(),
            } else device.stateLabel();
            const status_color = if (pending_kind != null)
                cfg.warm_1
            else if (device.connected)
                cfg.accent
            else if (device.paired)
                cfg.detail_1
            else
                cfg.muted;
            const status_width = font.textWidth(status_text, font_scale);
            const right_edge = ui.px(geometry.x + geometry.w - m.small_margin, output_scale);
            const status_x = right_edge - status_width;

            const metric_scale = font_scale * 0.8;
            const metric_height = ui.textHeight(metric_scale);
            const icon_size = ui.px(ui.scaled(16, m.scale), output_scale);
            const bar_width = ui.px(ui.scaled(34, m.scale), output_scale);
            const bar_height = @max(2, ui.px(ui.scaled(4, m.scale), output_scale));
            const item_gap = @divTrunc(margin_px, 2);

            const connected = device.connected;
            const percent: u8 = if (connected)
                device.battery orelse 0
            else
                rssiPercent(device.rssi);
            const has_value = if (connected)
                device.battery != null
            else
                device.rssi != null;
            var value_buffer: [8]u8 = undefined;
            const value_text = if (has_value)
                percentLabel(&value_buffer, percent)
            else
                "  --";
            const value_width = font.textWidth(value_text, metric_scale);
            const metrics_width = icon_size + item_gap + bar_width + item_gap + value_width;
            const metrics_x = right_edge - metrics_width;
            const right_limit = @min(status_x, metrics_x);
            const name_width = @max(0, right_limit - margin_px - name_x);

            _ = canvas.textFit(
                name_x,
                text_top,
                device.label(),
                cfg.text,
                font_scale,
                name_width,
            );
            _ = canvas.textFit(
                name_x,
                secondary_y,
                device.address,
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

            drawDeviceMetric(
                canvas,
                metrics_x,
                secondary_y,
                icon_size,
                metric_scale,
                metric_height,
                bar_width,
                bar_height,
                item_gap,
                if (connected) self.battery_icon else self.signal_icon,
                if (connected) cfg.detail_1 else cfg.accent,
                if (connected) "B" else "S",
                value_text,
                percent,
                cfg,
            );
        }
    }

    fn drawError(
        self: *Bluetooth,
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
            "Bluetooth backend unavailable",
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
        self: *Bluetooth,
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
            "Up/Down  Enter toggle  P power  D discover  A pair  Del forget  R refresh  Esc";

        _ = canvas.textFit(
            ui.px(m.margin, output_scale),
            y,
            text,
            if (self.error_len > 0) cfg.warm_2 else cfg.muted,
            hint_scale,
            width,
        );
    }
};

const ListGeometry = struct {
    x: i32,
    y: i32,
    w: i32,
    h: i32,
};

fn rssiPercent(rssi: ?i16) u8 {
    const value = rssi orelse return 0;
    const clamped: i32 = std.math.clamp(@as(i32, value), -100, -30);
    return @intCast(@divTrunc((clamped + 100) * 100, 70));
}

fn percentLabel(buffer: []u8, percent: u8) []const u8 {
    return std.fmt.bufPrint(buffer, "{d:>3}%", .{percent}) catch "???%";
}

fn drawDeviceMetric(
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
    icon_tint: render.Color,
    fallback: []const u8,
    value: []const u8,
    percent: u8,
    cfg: config.Config,
) void {
    const icon_y = y + @divTrunc(text_height - icon_size, 2);
    if (icon) |image| {
        canvas.imageTinted(x, icon_y, icon_size, icon_size, &image, icon_tint);
    } else {
        const fallback_width = font.textWidth(fallback, glyph_scale);
        _ = canvas.text(
            x + @divTrunc(icon_size - fallback_width, 2),
            y,
            fallback,
            icon_tint,
            glyph_scale,
        );
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

fn appInitial(name: []const u8) []const u8 {
    if (name.len == 0) return "?";
    const len = std.unicode.utf8ByteSequenceLength(name[0]) catch return "?";
    if (len > name.len) return "?";
    const codepoint = std.unicode.utf8Decode(name[0..len]) catch return "?";
    if (font.glyph(codepoint) == null) return "?";
    return name[0..len];
}
