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
const png = @import("png.zig");

pub const base_window_width = 640;
pub const base_window_height = 360;
pub const base_margin = 16;
pub const base_small_margin = 8;
pub const base_gap = 4;
pub const base_icon_size = 32;
pub const base_search_height = 40;
pub const base_border_width = 1;
pub const base_header_height = 36;
pub const base_footer_height = 24;

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
/// line. Used for backend error details and long status text.
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

/// Short live status line shown in a view footer or error block.
pub const Notice = struct {
    buffer: [256]u8 = undefined,
    len: usize = 0,
    deadline_ms: i64 = 0,

    pub fn clear(self: *Notice) void {
        self.len = 0;
        self.deadline_ms = 0;
    }

    pub fn has(self: *const Notice) bool {
        return self.len > 0;
    }

    pub fn text(self: *const Notice) []const u8 {
        return self.buffer[0..self.len];
    }

    pub fn set(self: *Notice, text_value: []const u8, now_ms: i64, ttl_ms: i64) void {
        const length = @min(text_value.len, self.buffer.len);
        @memcpy(self.buffer[0..length], text_value[0..length]);
        self.len = length;
        self.deadline_ms = if (ttl_ms == 0) 0 else now_ms + ttl_ms;
    }

    pub fn setDetail(
        self: *Notice,
        prefix: []const u8,
        detail: []const u8,
        now_ms: i64,
        ttl_ms: i64,
    ) void {
        const text_value = std.fmt.bufPrint(&self.buffer, "{s}: {s}", .{ prefix, detail }) catch prefix;
        self.len = text_value.len;
        self.deadline_ms = if (ttl_ms == 0) 0 else now_ms + ttl_ms;
    }

    /// Clear an expired notice. `ttl_ms == 0` means the notice stays until the
    /// next explicit clear (fatal errors).
    pub fn expire(self: *Notice, now_ms: i64) bool {
        if (self.len == 0 or self.deadline_ms == 0) return false;
        if (now_ms < self.deadline_ms) return false;
        self.clear();
        return true;
    }
};

pub fn appInitial(name: []const u8) []const u8 {
    if (name.len == 0) return "?";
    const len = std.unicode.utf8ByteSequenceLength(name[0]) catch return "?";
    if (len > name.len) return "?";
    const codepoint = std.unicode.utf8Decode(name[0..len]) catch return "?";
    if (font.glyph(codepoint) == null) return "?";
    return name[0..len];
}

pub fn percentLabel(buffer: []u8, percent: u8) []const u8 {
    return std.fmt.bufPrint(buffer, "{d:>3}%", .{percent}) catch "???%";
}

/// Geometry and row math shared by the scrolling tool lists.
pub const ListLayout = struct {
    x: i32,
    y: i32,
    w: i32,
    h: i32,

    pub fn maxScroll(self: ListLayout, count: usize, metrics: Metrics, gap: i32) i32 {
        const content = @as(i32, @intCast(count)) * metrics.row_step - gap;
        return @max(0, content - self.h);
    }

    pub fn ensureSelectionVisible(
        self: ListLayout,
        selected: usize,
        scroll: *i32,
        metrics: Metrics,
        count: usize,
        gap: i32,
    ) void {
        const top = @as(i32, @intCast(selected)) * metrics.row_step;
        const bottom = top + metrics.row_height;
        if (top < scroll.*) scroll.* = top;
        if (bottom > scroll.* + self.h) scroll.* = bottom - self.h;
        scroll.* = std.math.clamp(scroll.*, 0, self.maxScroll(count, metrics, gap));
    }

    pub fn hitRow(
        self: ListLayout,
        pointer_inside: bool,
        pointer_x: f32,
        pointer_y: f32,
        scroll: i32,
        count: usize,
        metrics: Metrics,
    ) ?usize {
        if (!pointer_inside) return null;

        const fx: i32 = @intFromFloat(@floor(pointer_x));
        const fy: i32 = @intFromFloat(@floor(pointer_y));
        if (fx < self.x or fx >= self.x + self.w) return null;
        if (fy < self.y or fy >= self.y + self.h) return null;

        const local = fy - self.y + scroll;
        if (local < 0) return null;
        const index: usize = @intCast(@divTrunc(local, metrics.row_step));
        if (index >= count) return null;
        if (@mod(local, metrics.row_step) >= metrics.row_height) return null;
        return index;
    }
};

pub fn drawBadge(
    canvas: *render.Canvas,
    cfg: config.Config,
    metrics: Metrics,
    output_scale: i32,
    window_width: i32,
    font_scale: f32,
    text_height: i32,
    text_value: []const u8,
    color: render.Color,
) i32 {
    const small = px(metrics.small_margin, output_scale);
    const badge_width = font.textWidth(text_value, font_scale) + small * 2;
    const badge_height = text_height + small;
    const badge_x = px(window_width - metrics.margin, output_scale) - badge_width;
    const badge_y = px(metrics.margin, output_scale) +
        @divTrunc(scaled(base_header_height, metrics.scale) - badge_height, 2);

    canvas.roundRect(
        badge_x,
        badge_y,
        badge_width,
        badge_height,
        px(metrics.row_radius, output_scale),
        cfg.highlight_low,
    );
    _ = canvas.text(
        badge_x + small,
        badge_y + @divTrunc(badge_height - text_height, 2),
        text_value,
        color,
        font_scale,
    );
    return badge_x;
}

pub fn drawFooter(
    canvas: *render.Canvas,
    cfg: config.Config,
    metrics: Metrics,
    logical_width: i32,
    logical_height: i32,
    output_scale: i32,
    font_scale: f32,
    notice: []const u8,
    hint: []const u8,
) void {
    const hint_scale = font_scale * 0.8;
    const hint_height = textHeight(hint_scale);
    const y = px(logical_height, output_scale) - px(metrics.margin, output_scale) - hint_height;
    const width = px(@max(0, logical_width - metrics.margin * 2), output_scale);

    _ = canvas.textFit(
        px(metrics.margin, output_scale),
        y,
        if (notice.len > 0) notice else hint,
        if (notice.len > 0) cfg.warm_2 else cfg.muted,
        hint_scale,
        width,
    );
}

pub fn drawError(
    canvas: *render.Canvas,
    cfg: config.Config,
    metrics: Metrics,
    x: i32,
    y: i32,
    width: i32,
    output_scale: i32,
    font_scale: f32,
    text_height: i32,
    title: []const u8,
    detail: []const u8,
) void {
    const px_x = px(x, output_scale);
    const px_y = px(y, output_scale);
    _ = canvas.text(px_x, px_y, title, cfg.warm_2, font_scale);

    const body_scale = font_scale * 0.85;
    const body_height = textHeight(body_scale);
    const line_height = body_height + px(metrics.small_margin, output_scale);
    const next = drawWrapped(
        canvas,
        px_x,
        px_y + text_height + px(metrics.small_margin, output_scale),
        px(width, output_scale),
        line_height,
        detail,
        cfg.warm_2,
        body_scale,
    );
    _ = canvas.text(
        px_x,
        next + px(metrics.small_margin, output_scale),
        "Press R to retry, or Esc to close.",
        cfg.muted,
        body_scale,
    );
}

pub fn drawMeter(
    canvas: *render.Canvas,
    cfg: config.Config,
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
) void {
    const icon_y = y + @divTrunc(text_height - icon_size, 2);
    if (icon) |image| {
        canvas.imageTinted(x, icon_y, icon_size, icon_size, &image, icon_tint);
    } else if (fallback.len > 0) {
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

test "notice expires but fatal notices stay" {
    var notice = Notice{};
    notice.set("working", 1000, 500);
    try std.testing.expect(notice.has());
    try std.testing.expect(!notice.expire(1400));
    try std.testing.expect(notice.expire(1500));
    try std.testing.expect(!notice.has());

    notice.set("fatal", 1000, 0);
    try std.testing.expect(!notice.expire(100_000));
    try std.testing.expect(notice.has());
}

test "list layout clamps scroll and maps rows" {
    const metrics = Metrics.init(.{});
    const layout = ListLayout{ .x = 0, .y = 0, .w = 100, .h = metrics.row_height };
    try std.testing.expectEqual(@as(i32, 0), layout.maxScroll(1, metrics, metrics.gap));

    var scroll: i32 = 99;
    layout.ensureSelectionVisible(0, &scroll, metrics, 1, metrics.gap);
    try std.testing.expectEqual(@as(i32, 0), scroll);

    try std.testing.expectEqual(@as(?usize, 0), layout.hitRow(true, 10, 1, 0, 1, metrics));
    try std.testing.expectEqual(@as(?usize, null), layout.hitRow(false, 10, 1, 0, 1, metrics));
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
