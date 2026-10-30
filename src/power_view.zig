//! The power controller view.

const std = @import("std");
const wayland = @import("wayland.zig");
const render = @import("render.zig");
const font = @import("font.zig");
const png = @import("png.zig");
const ui = @import("ui.zig");
const session = @import("session.zig");
const power = @import("power.zig");

const base_summary_height = 56;
const base_profile_height = 32;
const refresh_ms = 5000;
const action_count = 5;

const key_tab: u32 = 0xff09;

const actions = [_]power.Action{
    .lock,
    .suspend_system,
    .hibernate,
    .reboot,
    .power_off,
};

pub const Power = struct {
    io: std.Io,
    gpa: std.mem.Allocator,

    client: ?power.Client = null,
    state: ?power.State = null,
    battery_icon: ?png.Image = null,
    power_icon: ?png.Image = null,

    selected: usize = 0,
    hover: ?usize = null,
    last_refresh_request_ms: i64 = 0,
    confirm: ?power.Action = null,

    notice: ui.Notice = .{},

    pub fn init(io: std.Io, gpa: std.mem.Allocator) Power {
        var view = Power{
            .io = io,
            .gpa = gpa,
        };
        view.battery_icon = png.decode(gpa, @embedFile("icons/battery-half.png")) catch null;
        view.power_icon = png.decode(gpa, @embedFile("icons/power-off.png")) catch null;
        view.reload();
        return view;
    }

    pub fn deinit(self: *Power) void {
        if (self.client) |*client| client.deinit();
        if (self.state) |*state| state.deinit();
        if (self.battery_icon) |*icon| icon.deinit(self.gpa);
        if (self.power_icon) |*icon| icon.deinit(self.gpa);
        self.client = null;
        self.state = null;
        self.battery_icon = null;
        self.power_icon = null;
    }

    pub fn windowSize(self: *Power, metrics: ui.Metrics) ui.WindowSize {
        const m = metrics;
        const header = ui.scaled(ui.base_header_height, m.scale);
        const summary = ui.scaled(base_summary_height, m.scale);
        const profile = if (self.hasProfile()) ui.scaled(base_profile_height, m.scale) else 0;
        const footer = ui.scaled(ui.base_footer_height, m.scale);
        const content = @as(i32, action_count) * m.row_step - m.gap;
        const list_y = m.margin + header + m.gap + summary +
            (if (profile > 0) m.gap + profile else 0) + m.gap;
        return .{
            .width = m.window_width,
            .height = @max(1, list_y + content + footer + m.margin),
        };
    }

    pub fn wantsBlink(_: *Power) bool {
        return false;
    }

    pub fn tick(self: *Power, s: *session.Session) void {
        if (self.notice.expire(s.nowMs())) s.dirty = true;

        if (self.confirm != null) return;
        const now = s.nowMs();
        if (self.last_refresh_request_ms != 0 and now - self.last_refresh_request_ms < refresh_ms) return;
        self.refresh(s);
    }

    pub fn overTextField(_: *Power, _: *session.Session) bool {
        return false;
    }

    pub fn handleKey(self: *Power, s: *session.Session, key: wayland.Key, is_repeat: bool) void {
        if (!key.pressed) return;

        if (self.confirm) |action| {
            if (key.keysym == ui.key_return or key.keysym == ui.key_kp_enter) {
                if (!is_repeat) {
                    self.confirm = null;
                    self.execute(action, s);
                }
            } else if (key.keysym == 'n' or key.keysym == 'N') {
                self.confirm = null;
                s.dirty = true;
            }
            return;
        }

        if (key.mods.ctrl or key.mods.alt or key.mods.super) return;

        if (key.keysym == key_tab) {
            if (!is_repeat) self.cycleProfile(s);
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
        if (key.keysym == ui.key_return or key.keysym == ui.key_kp_enter) {
            if (!is_repeat) self.activate(s);
            return;
        }
        if (key.keysym == 'r' or key.keysym == 'R') {
            if (!is_repeat) {
                self.reload();
                s.dirty = true;
            }
        }
    }

    pub fn pointerMoved(self: *Power, s: *session.Session) void {
        self.updateHover(s);
    }

    pub fn pointerLeft(self: *Power, s: *session.Session) void {
        if (self.hover != null) {
            self.hover = null;
            s.dirty = true;
        }
    }

    pub fn pointerClick(self: *Power, s: *session.Session) void {
        if (self.confirm != null) return;
        if (self.hitRow(s)) |index| {
            self.selected = index;
            s.dirty = true;
        }
    }

    pub fn pointerScroll(_: *Power, _: *session.Session, _: f32) void {}

    pub fn draw(self: *Power, s: *session.Session, canvas: *render.Canvas, _: i64) void {
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
            if (self.hasProfile()) {
                self.drawProfile(s, canvas, output_scale, font_scale, text_height);
            }
            self.drawActions(s, canvas, output_scale, font_scale, text_height);
        }

        self.drawFooter(s, canvas, output_scale, font_scale);

        if (self.confirm) |action| {
            self.drawConfirm(s, canvas, action, output_scale, font_scale, text_height);
        }
    }

    fn drawHeader(
        self: *Power,
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
            "Power",
            cfg.text,
            font_scale,
        );

        const state = if (self.state) |*value| value else null;
        const badge_text = if (state) |value| blk: {
            if (value.battery) |battery| {
                if (battery.status == .charging) break :blk "Charging";
                if (battery.status == .full and value.ac_online) break :blk "AC - Full";
                if (value.ac_online) break :blk "AC";
                break :blk "On battery";
            }
            if (value.ac_online) break :blk "AC";
            break :blk "No battery";
        } else "Unavailable";
        const badge_color = if (state) |value| blk: {
            if (value.battery) |battery| {
                if (battery.status == .charging or battery.status == .full) break :blk cfg.accent;
                if (battery.status == .discharging) break :blk cfg.warm_1;
                break :blk cfg.muted;
            }
            break :blk cfg.muted;
        } else cfg.muted;

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
        self: *Power,
        s: *session.Session,
        canvas: *render.Canvas,
        output_scale: i32,
        font_scale: f32,
        text_height: i32,
    ) void {
        const state = if (self.state) |*value| value else return;
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
        const battery = state.battery;
        const icon_color = if (battery) |value| switch (value.status) {
            .charging, .full => cfg.accent,
            .discharging => cfg.warm_1,
            else => cfg.detail_2,
        } else cfg.muted;

        if (self.battery_icon) |image| {
            canvas.imageTinted(icon_x, icon_y, icon_px, icon_px, &image, icon_color);
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
                icon_color,
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

        var summary_buffer: [96]u8 = undefined;
        var final_buffer: [96]u8 = undefined;
        var percent_buffer: [16]u8 = undefined;
        const percent_text = if (battery) |value|
            std.fmt.bufPrint(&percent_buffer, "{d}%", .{value.percent}) catch "--"
        else
            "No battery";
        const summary_text = if (battery) |value| blk: {
            const base = value.summary(&summary_buffer);
            if (value.status == .full and state.ac_online) {
                break :blk std.fmt.bufPrint(&final_buffer, "{s} - AC connected", .{base}) catch base;
            }
            if (value.status == .not_charging and state.ac_online) {
                break :blk std.fmt.bufPrint(&final_buffer, "{s} - AC connected", .{base}) catch base;
            }
            break :blk base;
        } else if (state.ac_online) "AC connected" else "No battery detected";

        _ = canvas.text(text_x, text_y, percent_text, cfg.text, pct_scale);
        _ = canvas.textFit(
            text_x,
            text_y + pct_height + line_gap,
            summary_text,
            cfg.detail_2,
            secondary_scale,
            ui.px(geometry.w - m.icon_size - m.small_margin * 3 - 160, output_scale),
        );

        if (battery) |value| {
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
            const filled = @divTrunc(bar_width * @as(i32, value.percent), 100);
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
        }
    }

    fn drawProfile(
        self: *Power,
        s: *session.Session,
        canvas: *render.Canvas,
        output_scale: i32,
        font_scale: f32,
        text_height: i32,
    ) void {
        const state = if (self.state) |*value| value else return;
        const profile = state.profile orelse return;
        const m = s.metrics;
        const cfg = s.cfg;
        const geometry = self.profileGeometry(s);
        const text_y = ui.px(geometry.y, output_scale) +
            @divTrunc(ui.px(geometry.h, output_scale) - text_height, 2);

        canvas.roundRect(
            ui.px(geometry.x, output_scale),
            ui.px(geometry.y, output_scale),
            ui.px(geometry.w, output_scale),
            ui.px(geometry.h, output_scale),
            ui.px(m.row_radius, output_scale),
            cfg.highlight_low,
        );

        _ = canvas.text(
            ui.px(geometry.x + m.small_margin, output_scale),
            text_y,
            "Power profile",
            cfg.detail_1,
            font_scale,
        );

        const value = power.profileDisplay(profile.active);
        const value_width = font.textWidth(value, font_scale);
        _ = canvas.text(
            ui.px(geometry.x + geometry.w - m.small_margin, output_scale) - value_width,
            text_y,
            value,
            cfg.accent,
            font_scale,
        );
    }

    fn drawActions(
        self: *Power,
        s: *session.Session,
        canvas: *render.Canvas,
        output_scale: i32,
        font_scale: f32,
        text_height: i32,
    ) void {
        const state = if (self.state) |*value| value else return;
        const available_actions = state.actionsOrEmpty();
        const m = s.metrics;
        const cfg = s.cfg;
        const geometry = self.listGeometry(s);
        const secondary_scale = font_scale * 0.85;
        const secondary_height = ui.textHeight(secondary_scale);
        const line_gap = ui.px(@max(1, @divTrunc(m.small_margin, 4)), output_scale);
        const text_block = text_height + line_gap + secondary_height;
        const margin_px = ui.px(m.small_margin, output_scale);
        const row_height_px = ui.px(m.row_height, output_scale);
        const icon_px = ui.px(m.icon_size, output_scale);

        for (actions, 0..) |action, index| {
            const row_y = geometry.y + @as(i32, @intCast(index)) * m.row_step;
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
            const availability = action.availability(available_actions);
            const title_color = if (action == .power_off)
                cfg.warm_2
            else if (action == .reboot)
                cfg.warm_1
            else
                cfg.text;

            if (action == .power_off and self.power_icon != null) {
                canvas.imageTinted(icon_x, icon_y, icon_px, icon_px, &self.power_icon.?, title_color);
            } else {
                canvas.roundRect(
                    icon_x,
                    icon_y,
                    icon_px,
                    icon_px,
                    ui.px(m.icon_radius, output_scale),
                    cfg.highlight_low,
                );
                const initial = action.initial();
                const initial_width = font.textWidth(initial, font_scale);
                _ = canvas.text(
                    icon_x + @divTrunc(icon_px - initial_width, 2),
                    icon_y + @divTrunc(icon_px - text_height, 2),
                    initial,
                    if (availability.available()) cfg.detail_2 else cfg.muted,
                    font_scale,
                );
            }

            const text_top = row_y_px + @divTrunc(row_height_px - text_block, 2);
            const name_x = ui.px(
                geometry.x + m.small_margin + m.icon_size + m.small_margin * 2,
                output_scale,
            );
            const right_edge = ui.px(geometry.x + geometry.w - m.small_margin, output_scale);

            const status_text = if (!availability.available())
                "Unavailable"
            else if (self.selected == index)
                "Enter"
            else
                "";
            const status_width = if (status_text.len > 0) font.textWidth(status_text, font_scale) else 0;
            const status_x = right_edge - status_width;
            const name_width = @max(0, right_edge - status_width - margin_px - name_x);

            _ = canvas.textFit(
                name_x,
                text_top,
                action.title(),
                title_color,
                font_scale,
                name_width,
            );
            _ = canvas.textFit(
                name_x,
                text_top + text_height + line_gap,
                action.description(),
                cfg.detail_2,
                secondary_scale,
                name_width,
            );

            if (status_text.len > 0) {
                _ = canvas.text(
                    status_x,
                    text_top,
                    status_text,
                    if (availability.available()) cfg.accent else cfg.muted,
                    font_scale,
                );
            }
        }
    }

    fn drawFooter(
        self: *Power,
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
            if (self.hasProfile())
                "Up/Down select  Enter run  Tab profile  R refresh  Esc"
            else
                "Up/Down select  Enter run  R refresh  Esc",
        );
    }

    fn drawError(
        self: *Power,
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
            "Power information unavailable",
            self.notice.text(),
        );
    }

    fn drawConfirm(
        _: *Power,
        s: *session.Session,
        canvas: *render.Canvas,
        action: power.Action,
        output_scale: i32,
        font_scale: f32,
        text_height: i32,
    ) void {
        const m = s.metrics;
        const cfg = s.cfg;
        const width: i32 = @intCast(s.client.logical_width);
        const height: i32 = @intCast(s.client.logical_height);

        canvas.fillRect(
            0,
            0,
            ui.px(width, output_scale),
            ui.px(height, output_scale),
            cfg.base.withAlpha(210),
        );

        const card_width = ui.px(@min(400, width - m.margin * 2), output_scale);
        const card_height = ui.px(120, output_scale);
        const card_x = @divTrunc(ui.px(width, output_scale) - card_width, 2);
        const card_y = @divTrunc(ui.px(height, output_scale) - card_height, 2);
        canvas.roundRect(
            card_x,
            card_y,
            card_width,
            card_height,
            ui.px(m.corner_radius, output_scale),
            cfg.surface,
        );

        const title = confirmTitle(action);
        const title_width = font.textWidth(title, font_scale);
        _ = canvas.text(
            card_x + @divTrunc(card_width - title_width, 2),
            card_y + ui.px(m.margin, output_scale),
            title,
            cfg.warm_2,
            font_scale,
        );

        const body_scale = font_scale * 0.85;
        const body = "Enter to confirm, N to cancel";
        const body_width = font.textWidth(body, body_scale);
        _ = canvas.text(
            card_x + @divTrunc(card_width - body_width, 2),
            card_y + ui.px(m.margin, output_scale) + text_height + ui.px(m.small_margin, output_scale),
            body,
            cfg.muted,
            body_scale,
        );

        const detail = if (action == .reboot)
            "All applications will be closed."
        else
            "The computer will be powered off.";
        const detail_width = font.textWidth(detail, body_scale);
        _ = canvas.text(
            card_x + @divTrunc(card_width - detail_width, 2),
            card_y + ui.px(m.margin, output_scale) + text_height +
                ui.px(m.small_margin, output_scale) + ui.textHeight(body_scale) + ui.px(m.small_margin, output_scale),
            detail,
            cfg.detail_2,
            body_scale,
        );
    }

    fn reload(self: *Power) void {
        self.notice.clear();
        self.confirm = null;

        if (self.client) |*client| client.deinit();
        self.client = null;
        if (self.state) |*state| state.deinit();
        self.state = null;

        self.client = power.Client.connect(self.io, self.gpa) catch |err| {
            self.setError("Power D-Bus unavailable", err);
            self.loadSysfs();
            return;
        };

        if (self.client) |*client| {
            const state = client.refresh(self.gpa) catch |err| {
                self.setError("Power refresh failed", err);
                client.deinit();
                self.client = null;
                self.loadSysfs();
                return;
            };
            self.state = state;
        }

        self.clampSelection();
        self.last_refresh_request_ms = self.nowMs();
    }

    fn loadSysfs(self: *Power) void {
        if (self.state) |*old| old.deinit();
        self.state = null;
        self.state = power.read(self.io, self.gpa) catch |err| {
            self.setFatalError("Power information unavailable", err);
            self.last_refresh_request_ms = self.nowMs();
            return;
        };
        self.clampSelection();
        self.last_refresh_request_ms = self.nowMs();
    }

    fn refresh(self: *Power, s: *session.Session) void {
        if (self.client == null) {
            self.client = power.Client.connect(self.io, self.gpa) catch |err| {
                self.setError("Power D-Bus unavailable", err);
                self.loadSysfs();
                s.dirty = true;
                return;
            };
        }

        if (self.client) |*client| {
            const state = client.refresh(self.gpa) catch |err| {
                self.setError("Power refresh failed", err);
                client.deinit();
                self.client = null;
                self.loadSysfs();
                s.dirty = true;
                return;
            };
            if (self.state) |*old| old.deinit();
            self.state = state;
            self.clampSelection();
            self.last_refresh_request_ms = s.nowMs();
            s.dirty = true;
        }
    }

    fn activate(self: *Power, s: *session.Session) void {
        const action = actions[self.selected];
        const availability = self.actionAvailability(action);
        if (!availability.available()) {
            self.setNotice("This action is not available");
            s.dirty = true;
            return;
        }
        if (action.destructive()) {
            self.confirm = action;
            s.dirty = true;
            return;
        }
        self.execute(action, s);
    }

    fn execute(self: *Power, action: power.Action, s: *session.Session) void {
        if (self.client == null) {
            self.setError("Session actions unavailable", error.ConnectionClosed);
            s.dirty = true;
            return;
        }

        self.client.?.invoke(action) catch |err| {
            self.setError("Power action failed", err);
            s.dirty = true;
            return;
        };

        switch (action) {
            .lock => self.setNotice("Session locked"),
            .suspend_system, .hibernate => {
                self.reload();
                self.setNotice("Resumed");
            },
            .reboot => self.setNotice("Restarting..."),
            .power_off => self.setNotice("Shutting down..."),
        }
        s.dirty = true;
    }

    fn cycleProfile(self: *Power, s: *session.Session) void {
        const state = if (self.state) |*value| value else return;
        const profile = state.profile orelse {
            self.setNotice("Power profile not available");
            s.dirty = true;
            return;
        };
        const next = profile.next() orelse return;

        if (self.client) |*client| {
            client.setProfile(profile, next) catch |err| {
                self.setError("Power profile change failed", err);
                s.dirty = true;
                return;
            };
        } else if (profile.backend == .sysfs) {
            power.writeProfileSysfs(self.io, next) catch |err| {
                self.setError("Power profile change failed", err);
                s.dirty = true;
                return;
            };
        } else {
            self.setError("Power profile service unavailable", error.ConnectionClosed);
            s.dirty = true;
            return;
        }

        self.refresh(s);
    }

    fn actionAvailability(self: *Power, action: power.Action) power.Availability {
        const state = if (self.state) |*value| value else return .no;
        const available_actions = state.actions orelse return .no;
        return action.availability(available_actions);
    }

    fn hasProfile(self: *Power) bool {
        const state = if (self.state) |*value| value else return false;
        return state.profile != null;
    }

    fn summaryGeometry(_: *Power, s: *session.Session) ui.ListLayout {
        const width: i32 = @intCast(s.client.logical_width);
        const m = s.metrics;
        return .{
            .x = m.margin,
            .y = m.margin + ui.scaled(ui.base_header_height, m.scale) + m.gap,
            .w = @max(0, width - m.margin * 2),
            .h = ui.scaled(base_summary_height, m.scale),
        };
    }

    fn profileGeometry(self: *Power, s: *session.Session) ui.ListLayout {
        const summary = self.summaryGeometry(s);
        const m = s.metrics;
        return .{
            .x = summary.x,
            .y = summary.y + summary.h + m.gap,
            .w = summary.w,
            .h = ui.scaled(base_profile_height, m.scale),
        };
    }

    fn listGeometry(self: *Power, s: *session.Session) ui.ListLayout {
        const width: i32 = @intCast(s.client.logical_width);
        const m = s.metrics;
        const summary = self.summaryGeometry(s);
        const profile_height = if (self.hasProfile()) ui.scaled(base_profile_height, m.scale) else 0;
        const y = summary.y + summary.h + m.gap +
            (if (profile_height > 0) profile_height + m.gap else 0);
        return .{
            .x = m.margin,
            .y = y,
            .w = @max(0, width - m.margin * 2),
            .h = @as(i32, action_count) * m.row_step - m.gap,
        };
    }

    fn hitRow(self: *Power, s: *session.Session) ?usize {
        if (!s.pointer_inside) return null;
        if (self.state == null) return null;

        const geometry = self.listGeometry(s);
        const fx: i32 = @intFromFloat(@floor(s.pointer_x));
        const fy: i32 = @intFromFloat(@floor(s.pointer_y));
        if (fx < geometry.x or fx >= geometry.x + geometry.w) return null;
        if (fy < geometry.y or fy >= geometry.y + geometry.h) return null;

        const local = fy - geometry.y;
        if (local < 0) return null;
        const index: usize = @intCast(@divTrunc(local, s.metrics.row_step));
        if (index >= action_count) return null;
        if (@mod(local, s.metrics.row_step) >= s.metrics.row_height) return null;
        return index;
    }

    fn updateHover(self: *Power, s: *session.Session) void {
        const hovered = self.hitRow(s);
        if (hovered != self.hover) {
            self.hover = hovered;
            s.dirty = true;
        }
    }

    fn moveSelection(self: *Power, s: *session.Session, delta: i32) void {
        const next = @as(i32, @intCast(self.selected)) + delta;
        self.selected = @intCast(std.math.clamp(next, 0, action_count - 1));
        self.updateHover(s);
        s.dirty = true;
    }

    fn clampSelection(self: *Power) void {
        if (self.selected >= action_count) self.selected = action_count - 1;
    }

    fn nowMs(self: *const Power) i64 {
        return std.Io.Clock.Timestamp.now(self.io, .awake).raw.toMilliseconds();
    }

    fn setError(self: *Power, prefix: []const u8, err: anyerror) void {
        self.notice.setDetail(prefix, @errorName(err), self.nowMs(), 5000);
    }

    fn setFatalError(self: *Power, prefix: []const u8, err: anyerror) void {
        self.notice.setDetail(prefix, @errorName(err), self.nowMs(), 0);
    }

    fn setNotice(self: *Power, text: []const u8) void {
        self.notice.set(text, self.nowMs(), 5000);
    }
};

fn confirmTitle(action: power.Action) []const u8 {
    return switch (action) {
        .reboot => "Restart the computer?",
        .power_off => "Shut down the computer?",
        else => "Are you sure?",
    };
}
