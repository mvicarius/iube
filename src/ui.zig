//! Shared visual language for every iube view.
//!
//! The launcher, the control panel and the per-tool views all use the same
//! configuration, scaling rules, key symbols and window chrome. Keeping this in
//! one place is what lets `iube`, `iube launch` and `iube audio` feel like the
//! same program without sharing a single large event loop or scanning each
//! other's data.

const std = @import("std");
const config = @import("config.zig");
const render = @import("render.zig");
const font = @import("font.zig");

pub const base_window_width = 640;
pub const base_window_height = 360;
pub const base_placeholder_height = 240;
pub const base_margin = 16;
pub const base_small_margin = 8;
pub const base_gap = 4;
pub const base_icon_size = 32;
pub const base_search_height = 40;
pub const base_border_width = 1;

pub const blink_period_ms = 530;

pub const key_escape: u32 = 0xff1b;
pub const key_return: u32 = 0xff0d;
pub const key_kp_enter: u32 = 0xff8d;
pub const key_backspace: u32 = 0xff08;
pub const key_delete: u32 = 0xffff;
pub const key_up: u32 = 0xff52;
pub const key_down: u32 = 0xff54;
pub const key_left: u32 = 0xff51;
pub const key_right: u32 = 0xff53;

/// Layout values in logical (surface) pixels. `scale` from the config file is
/// applied here once at startup, so the rest of the UI code can work with
/// integers while text uses the fractional font scale below.
pub const Metrics = struct {
    scale: f32,
    window_width: i32,
    window_height: i32,
    margin: i32,
    small_margin: i32,
    gap: i32,
    icon_size: i32,
    row_height: i32,
    row_step: i32,
    search_height: i32,
    corner_radius: i32,
    search_radius: i32,
    row_radius: i32,
    icon_radius: i32,
    border_width: i32,

    pub fn init(cfg: config.Config) Metrics {
        const s = cfg.scale;
        const margin = scaled(base_margin, s);
        const small_margin = scaled(base_small_margin, s);
        const icon_size = scaled(base_icon_size, s);
        const gap = scaled(base_gap, s);
        const corner_radius = scaled(cfg.corner_radius, s);
        return .{
            .scale = s,
            .window_width = @max(1, scaled(base_window_width, s)),
            .window_height = @max(1, scaled(base_window_height, s)),
            .margin = margin,
            .small_margin = small_margin,
            .gap = gap,
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

    /// Exact window size for a fixed list of `count` rows. The control panel
    /// uses this so every entry is visible without scrolling.
    pub fn listWindowSize(self: Metrics, count: usize) WindowSize {
        const rows: i32 = @intCast(count);
        const content = if (count == 0) 0 else rows * self.row_step - self.gap;
        return .{
            .width = self.window_width,
            .height = @max(1, self.margin * 2 + content),
        };
    }

    pub fn placeholderWindowSize(self: Metrics) WindowSize {
        return .{
            .width = self.window_width,
            .height = @max(1, scaled(base_placeholder_height, self.scale)),
        };
    }
};

pub const WindowSize = struct {
    width: i32,
    height: i32,
};

pub fn scaled(value: i32, factor: f32) i32 {
    return @intFromFloat(@round(@as(f32, @floatFromInt(value)) * factor));
}

pub fn px(value: i32, scale: i32) i32 {
    return value * scale;
}

/// Slightly larger than the raw bitmap size so body text reads better by
/// default without changing the configured layout scale.
pub const base_text_scale: f32 = 1.125;

pub fn fontScale(cfg: config.Config, output_scale: i32) f32 {
    return cfg.scale * @as(f32, @floatFromInt(output_scale)) * base_text_scale;
}

pub fn logicalFontScale(cfg: config.Config) f32 {
    return cfg.scale * base_text_scale;
}

pub fn textHeight(glyph_scale: f32) i32 {
    return @intFromFloat(@round(@as(f32, font.glyph_height) * glyph_scale));
}

/// Keys that should keep firing while held down. Direction keys are used by
/// the launcher/panel for navigation and by the audio view for volume.
pub fn keyRepeats(keysym: u32, text_len: u8) bool {
    if (text_len > 0) return true;
    return keysym == key_backspace or
        keysym == key_up or
        keysym == key_down or
        keysym == key_left or
        keysym == key_right;
}

/// Window body and border. The outer highlight_mid ring is one logical
/// border-width wide and scales with the rest of the UI.
pub fn drawWindowChrome(
    canvas: *render.Canvas,
    cfg: config.Config,
    metrics: Metrics,
    output_scale: i32,
    width: i32,
    height: i32,
) void {
    const border = metrics.border_width;
    canvas.roundRect(
        0,
        0,
        px(width, output_scale),
        px(height, output_scale),
        px(metrics.corner_radius, output_scale),
        cfg.highlight_mid,
    );
    canvas.roundRect(
        px(border, output_scale),
        px(border, output_scale),
        px(@max(0, width - border * 2), output_scale),
        px(@max(0, height - border * 2), output_scale),
        px(@max(0, metrics.corner_radius - border), output_scale),
        cfg.base,
    );
}

/// Draw wrapped, word-spaced text and return the y coordinate after the last
/// line. Used by the tool placeholders, which have no list to lay out.
pub fn drawWrapped(
    canvas: *render.Canvas,
    x: i32,
    y: i32,
    max_width: i32,
    line_height: i32,
    text_value: []const u8,
    color: render.Color,
    glyph_scale: f32,
) i32 {
    if (max_width <= 0) return y;

    const space = font.textWidth(" ", glyph_scale);
    var cursor_x = x;
    var line_y = y;
    var line_has_word = false;

    var it = std.mem.tokenizeAny(u8, text_value, " \t\r\n");
    while (it.next()) |word| {
        const word_width = font.textWidth(word, glyph_scale);
        if (line_has_word and cursor_x + space + word_width > x + max_width) {
            line_y += line_height;
            cursor_x = x;
            line_has_word = false;
        }
        if (line_has_word) cursor_x += space;
        cursor_x = canvas.text(cursor_x, line_y, word, color, glyph_scale);
        line_has_word = true;
    }

    return line_y + line_height;
}

test "list window fits every row without scrolling" {
    const metrics = Metrics.init(.{});
    const size = metrics.listWindowSize(5);
    try std.testing.expectEqual(metrics.window_width, size.width);
    try std.testing.expectEqual(
        metrics.margin * 2 + 5 * metrics.row_step - metrics.gap,
        size.height,
    );
}

test "scale multiplies window dimensions" {
    var cfg = config.Config{};
    cfg.scale = 2.0;
    const metrics = Metrics.init(cfg);
    try std.testing.expectEqual(@as(i32, 1280), metrics.window_width);
    try std.testing.expectEqual(@as(i32, 720), metrics.window_height);
}

test "volume and navigation keys repeat while held" {
    try std.testing.expect(keyRepeats(key_left, 0));
    try std.testing.expect(keyRepeats(key_right, 0));
    try std.testing.expect(keyRepeats(key_up, 0));
    try std.testing.expect(keyRepeats(key_down, 0));
    try std.testing.expect(!keyRepeats(key_escape, 0));
}
