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

    forget_path: [256]u8 = undefined,
    forget_path_len: usize = 0,
    forget_deadline_ms: i64 = 0,

    notice: ui.Notice = .{},

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
        if (self.forget_deadline_ms > 0 and s.nowMs() >= self.forget_deadline_ms) {
            self.clearForget();
            s.dirty = true;
        }

        if (self.worker) |worker| {
            while (worker.poll()) |result_value| {
                var result = result_value;
                self.applyResult(&result, s);
                result.deinit();
            }
        }

        if (self.notice.expire(s.nowMs())) s.dirty = true;

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
                    self.notice.clear();
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
        self.notice.clear();
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
        self.notice.setDetail(prefix, @errorName(err), self.nowMs(), 5000);
    }

    fn setFatalError(self: *Bluetooth, prefix: []const u8, err: anyerror) void {
        self.notice.setDetail(prefix, @errorName(err), self.nowMs(), 0);
    }

    fn setNotice(self: *Bluetooth, text: []const u8) void {
        self.notice.set(text, self.nowMs(), 5000);
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
        self.clearForget();
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
        const now = s.nowMs();
        if (self.forget_path_len == device.path.len and
            self.forget_deadline_ms > now and
            std.mem.eql(u8, self.forget_path[0..self.forget_path_len], device.path))
        {
            self.clearForget();
            _ = self.submitAction(.forget, device.path, device.adapter_path, false, s);
            return;
        }
        if (device.path.len > self.forget_path.len) {
            self.setNotice("Device path too long");
            s.dirty = true;
            return;
        }
        @memcpy(self.forget_path[0..device.path.len], device.path);
        self.forget_path_len = device.path.len;
        self.forget_deadline_ms = now + 3000;
        self.setNotice("Press Delete again to forget this device");
        s.dirty = true;
    }

    fn clearForget(self: *Bluetooth) void {
        self.forget_path_len = 0;
        self.forget_deadline_ms = 0;
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
        self.notice.clear();
        s.dirty = true;
        return true;
    }

    fn pendingKindFor(self: *Bluetooth, device: bluetooth.Device) ?worker_mod.Kind {
        const kind = self.pending_action orelse return null;
        if (self.pending_path_len != device.path.len) return null;
        if (!std.mem.eql(u8, self.pending_path[0..self.pending_path_len], device.path)) return null;
        return kind;
    }

    fn listGeometry(_: *Bluetooth, s: *session.Session) ui.ListLayout {
        const width: i32 = @intCast(s.client.logical_width);
        const height: i32 = @intCast(s.client.logical_height);
        const m = s.metrics;
        const header = ui.scaled(ui.base_header_height, m.scale);
        const footer = ui.scaled(ui.base_footer_height, m.scale);
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
        return self.listGeometry(s).maxScroll(list.len, s.metrics, s.metrics.gap);
    }

    fn ensureSelectionVisible(self: *Bluetooth, s: *session.Session) void {
        const list = self.devices() orelse return;
        self.listGeometry(s).ensureSelectionVisible(
            self.selected,
            &self.scroll,
            s.metrics,
            list.len,
            s.metrics.gap,
        );
    }

    fn hitRow(self: *Bluetooth, s: *session.Session) ?usize {
        const list = self.devices() orelse return null;
        return self.listGeometry(s).hitRow(
            s.pointer_inside,
            s.pointer_x,
            s.pointer_y,
            self.scroll,
            list.len,
            s.metrics,
        );
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
        const header_height = ui.scaled(ui.base_header_height, m.scale);
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
        const badge_x = ui.drawBadge(
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
        geometry: ui.ListLayout,
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

            const initial = ui.appInitial(device.label());
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
                ui.percentLabel(&value_buffer, percent)
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

            ui.drawMeter(
                canvas,
                cfg,
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
            );
        }
    }

    fn drawError(
        self: *Bluetooth,
        s: *session.Session,
        canvas: *render.Canvas,
        geometry: ui.ListLayout,
        output_scale: i32,
        font_scale: f32,
        text_height: i32,
    ) void {
        const m = s.metrics;
        const cfg = s.cfg;
        ui.drawError(
            canvas,
            cfg,
            m,
            geometry.x + m.small_margin,
            geometry.y + m.gap,
            @max(0, geometry.w - m.small_margin * 2),
            output_scale,
            font_scale,
            text_height,
            "Bluetooth backend unavailable",
            self.notice.text(),
        );
    }

    fn drawFooter(
        self: *Bluetooth,
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
            self.notice.text(),
            "Up/Down  Enter toggle  P power  D discover  A pair  Del forget  R refresh  Esc",
        );
    }
};

fn rssiPercent(rssi: ?i16) u8 {
    const value = rssi orelse return 0;
    const clamped: i32 = std.math.clamp(@as(i32, value), -100, -30);
    return @intCast(@divTrunc((clamped + 100) * 100, 70));
}
