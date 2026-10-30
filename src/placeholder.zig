//! Placeholder view for tools whose backend has not been implemented yet.
//!
//! It still uses the shared configuration, renderer and window behaviour, so
//! `iube audio`, `iube bluetooth`, `iube wifi` and `iube power` already open a
//! real iube window. Only the tool-specific data and controls are missing.

const std = @import("std");
const wayland = @import("wayland.zig");
const render = @import("render.zig");
const font = @import("font.zig");
const ui = @import("ui.zig");
const session = @import("session.zig");
const tools = @import("tools.zig");

pub const Placeholder = struct {
    tool: *const tools.Tool,

    pub fn windowSize(_: *Placeholder, metrics: ui.Metrics) ui.WindowSize {
        return metrics.placeholderWindowSize();
    }

    pub fn wantsBlink(_: *Placeholder) bool {
        return false;
    }

    pub fn overTextField(_: *Placeholder, _: *session.Session) bool {
        return false;
    }

    pub fn handleKey(_: *Placeholder, _: *session.Session, _: wayland.Key, _: bool) void {}
    pub fn pointerMoved(_: *Placeholder, _: *session.Session) void {}
    pub fn pointerLeft(_: *Placeholder, _: *session.Session) void {}
    pub fn pointerClick(_: *Placeholder, _: *session.Session) void {}
    pub fn pointerScroll(_: *Placeholder, _: *session.Session, _: f32) void {}

    pub fn draw(self: *Placeholder, s: *session.Session, canvas: *render.Canvas, _: i64) void {
        const output_scale: i32 = @intCast(s.client.scale);
        const width: i32 = @intCast(s.client.logical_width);
        const height: i32 = @intCast(s.client.logical_height);
        const m = s.metrics;
        const cfg = s.cfg;

        ui.drawWindowChrome(canvas, cfg, m, output_scale, width, height);

        const font_scale = ui.fontScale(cfg, output_scale);
        const text_height = ui.textHeight(font_scale);
        const small_margin_px = ui.px(m.small_margin, output_scale);
        const line_height = text_height + small_margin_px;

        const icon_x = ui.px(m.margin, output_scale);
        const icon_y = ui.px(m.margin, output_scale);
        const icon_px = ui.px(m.icon_size, output_scale);
        canvas.roundRect(
            icon_x,
            icon_y,
            icon_px,
            icon_px,
            ui.px(m.icon_radius, output_scale),
            cfg.highlight_low,
        );

        const initial = appInitial(self.tool.name);
        const initial_width = font.textWidth(initial, font_scale);
        _ = canvas.text(
            icon_x + @divTrunc(icon_px - initial_width, 2),
            icon_y + @divTrunc(icon_px - text_height, 2),
            initial,
            cfg.detail_2,
            font_scale,
        );

        const title_x = ui.px(m.margin + m.icon_size + m.small_margin, output_scale);
        const title_y = icon_y + @divTrunc(icon_px - text_height, 2);
        _ = canvas.textFit(
            title_x,
            title_y,
            self.tool.name,
            cfg.text,
            font_scale,
            ui.px(@max(0, width - m.margin * 2 - m.icon_size - m.small_margin), output_scale),
        );

        const badge_text = "Coming soon";
        const badge_width = font.textWidth(badge_text, font_scale) + small_margin_px * 2;
        const badge_height = text_height + small_margin_px;
        const badge_x = ui.px(m.margin, output_scale);
        const badge_y = ui.px(m.margin + m.row_height + m.small_margin, output_scale);
        canvas.roundRect(
            badge_x,
            badge_y,
            badge_width,
            badge_height,
            ui.px(m.icon_radius, output_scale),
            cfg.highlight_low,
        );
        _ = canvas.text(
            badge_x + small_margin_px,
            badge_y + @divTrunc(badge_height - text_height, 2),
            badge_text,
            cfg.dark_accent,
            font_scale,
        );

        const text_x = ui.px(m.margin, output_scale);
        const text_width = ui.px(@max(0, width - m.margin * 2), output_scale);

        var text_y = badge_y + badge_height + small_margin_px;
        text_y = ui.drawWrapped(
            canvas,
            text_x,
            text_y,
            text_width,
            line_height,
            self.tool.description,
            cfg.text,
            font_scale,
        );
        _ = ui.drawWrapped(
            canvas,
            text_x,
            text_y + @divTrunc(small_margin_px, 2),
            text_width,
            line_height,
            self.tool.backend,
            cfg.muted,
            font_scale,
        );

        const footer = "Press Esc to close";
        const footer_width = font.textWidth(footer, font_scale);
        _ = canvas.text(
            ui.px(@divTrunc(width, 2), output_scale) - @divTrunc(footer_width, 2),
            ui.px(height - m.margin, output_scale) - text_height,
            footer,
            cfg.muted,
            font_scale,
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
