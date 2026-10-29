//! The iube control panel.
//!
//! `iube` with no arguments opens this view. It is a fixed list of every tool
//! the binary exposes, sized to show all entries at once: there is no search
//! field and no scrolling. Selecting an entry hands off to the matching
//! `iube <tool>` command and exits, so that command starts with only the work
//! it needs.

const std = @import("std");
const wayland = @import("wayland.zig");
const render = @import("render.zig");
const font = @import("font.zig");
const ui = @import("ui.zig");
const session = @import("session.zig");
const tools = @import("tools.zig");
const spawn = @import("spawn.zig");

pub const Panel = struct {
    selected: usize = 0,
    hover: ?usize = null,

    pub fn windowSize(_: *Panel, metrics: ui.Metrics) ui.WindowSize {
        return metrics.listWindowSize(tools.all.len);
    }

    pub fn wantsBlink(_: *Panel) bool {
        return false;
    }

    pub fn overTextField(_: *Panel, _: *session.Session) bool {
        return false;
    }

    pub fn handleKey(self: *Panel, s: *session.Session, key: wayland.Key, is_repeat: bool) void {
        if (!key.pressed) return;

        if (key.keysym == ui.key_down) {
            if (self.selected + 1 < tools.all.len) {
                self.selected += 1;
                s.dirty = true;
            }
            return;
        }

        if (key.keysym == ui.key_up) {
            if (self.selected > 0) {
                self.selected -= 1;
                s.dirty = true;
            }
            return;
        }

        if (key.keysym == ui.key_left or key.keysym == ui.key_right) return;

        if (!is_repeat and (key.keysym == ui.key_return or key.keysym == ui.key_kp_enter)) {
            self.activate(s);
        }
    }

    pub fn pointerMoved(self: *Panel, s: *session.Session) void {
        self.updateHover(s);
    }

    pub fn pointerLeft(self: *Panel, s: *session.Session) void {
        if (self.hover != null) {
            self.hover = null;
            s.dirty = true;
        }
    }

    pub fn pointerClick(self: *Panel, s: *session.Session) void {
        if (self.hitRow(s)) |index| {
            self.selected = index;
            self.activate(s);
        }
    }

    pub fn pointerScroll(_: *Panel, _: *session.Session, _: f32) void {
        // The panel is sized to show every tool; there is nothing to scroll.
    }

    fn activate(self: *Panel, s: *session.Session) void {
        if (self.selected >= tools.all.len) return;
        const tool = &tools.all[self.selected];
        spawn.spawnSelf(s.io, tool.id) catch |err| {
            std.log.err("failed to open iube {s}: {s}", .{ tool.id, @errorName(err) });
            return;
        };
        s.running = false;
    }

    fn listGeometry(s: *session.Session) struct { x: i32, y: i32, w: i32, h: i32 } {
        const width: i32 = @intCast(s.client.logical_width);
        const height: i32 = @intCast(s.client.logical_height);
        const m = s.metrics;
        return .{
            .x = m.margin,
            .y = m.margin,
            .w = @max(0, width - m.margin * 2),
            .h = @max(0, height - m.margin * 2),
        };
    }

    fn hitRow(_: *Panel, s: *session.Session) ?usize {
        if (!s.pointer_inside) return null;

        const geometry = listGeometry(s);
        const fx: i32 = @intFromFloat(@floor(s.pointer_x));
        const fy: i32 = @intFromFloat(@floor(s.pointer_y));

        if (fx < geometry.x or fx >= geometry.x + geometry.w) return null;
        if (fy < geometry.y or fy >= geometry.y + geometry.h) return null;

        const local = fy - geometry.y;
        const index: usize = @intCast(@divTrunc(local, s.metrics.row_step));
        if (index >= tools.all.len) return null;
        if (@mod(local, s.metrics.row_step) >= s.metrics.row_height) return null;
        return index;
    }

    fn updateHover(self: *Panel, s: *session.Session) void {
        const hovered = self.hitRow(s);
        if (hovered != self.hover) {
            self.hover = hovered;
            s.dirty = true;
        }
    }

    pub fn draw(self: *Panel, s: *session.Session, canvas: *render.Canvas, _: i64) void {
        const output_scale: i32 = @intCast(s.client.scale);
        const width: i32 = @intCast(s.client.logical_width);
        const height: i32 = @intCast(s.client.logical_height);
        const m = s.metrics;
        const cfg = s.cfg;

        ui.drawWindowChrome(canvas, cfg, m, output_scale, width, height);

        const font_scale = ui.fontScale(cfg, output_scale);
        const text_height = ui.textHeight(font_scale);
        const geometry = listGeometry(s);

        for (tools.all, 0..) |tool, index| {
            const row_y = geometry.y + @as(i32, @intCast(index)) * m.row_step;
            if (row_y + m.row_height > geometry.y + geometry.h) break;

            const fill = if (self.selected == index)
                cfg.highlight_high
            else if (self.hover == index)
                cfg.highlight_low
            else
                cfg.surface;

            canvas.roundRect(
                ui.px(geometry.x, output_scale),
                ui.px(row_y, output_scale),
                ui.px(geometry.w, output_scale),
                ui.px(m.row_height, output_scale),
                ui.px(m.row_radius, output_scale),
                fill,
            );

            const icon_x = ui.px(geometry.x + m.small_margin, output_scale);
            const icon_y = ui.px(row_y + m.small_margin, output_scale);
            const icon_px = ui.px(m.icon_size, output_scale);
            canvas.roundRect(
                icon_x,
                icon_y,
                icon_px,
                icon_px,
                ui.px(m.icon_radius, output_scale),
                cfg.highlight_low,
            );

            const initial = appInitial(tool.name);
            const initial_width = font.textWidth(initial, font_scale);
            _ = canvas.text(
                icon_x + @divTrunc(icon_px - initial_width, 2),
                icon_y + @divTrunc(icon_px - text_height, 2),
                initial,
                cfg.muted,
                font_scale,
            );

            const badge_text = if (tool.status == .available) "Open" else "Coming soon";
            const badge_color = if (tool.status == .available) cfg.accent else cfg.muted;
            const badge_width = font.textWidth(badge_text, font_scale) + m.small_margin * 2;
            const badge_height = text_height + m.small_margin;
            const badge_x = geometry.x + geometry.w - m.small_margin - badge_width;
            const badge_y = row_y + @divTrunc(m.row_height - badge_height, 2);

            canvas.roundRect(
                ui.px(badge_x, output_scale),
                ui.px(badge_y, output_scale),
                ui.px(badge_width, output_scale),
                ui.px(badge_height, output_scale),
                ui.px(m.icon_radius, output_scale),
                cfg.highlight_low,
            );
            _ = canvas.text(
                ui.px(badge_x + m.small_margin, output_scale),
                ui.px(badge_y, output_scale) + @divTrunc(
                    ui.px(badge_height, output_scale) - text_height,
                    2,
                ),
                badge_text,
                badge_color,
                font_scale,
            );

            const name_x = ui.px(geometry.x + m.small_margin + m.icon_size + m.small_margin, output_scale);
            const name_y = ui.px(row_y, output_scale) +
                @divTrunc(ui.px(m.row_height, output_scale) - text_height, 2);
            const name_width = ui.px(
                @max(0, badge_x - m.small_margin - (geometry.x + m.small_margin + m.icon_size + m.small_margin)),
                output_scale,
            );
            _ = canvas.textFit(
                name_x,
                name_y,
                tool.name,
                cfg.text,
                font_scale,
                name_width,
            );
        }
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
