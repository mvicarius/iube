//! Small software renderer for premultiplied ARGB8888 surfaces.
//!
//! Everything is drawn into a shared-memory buffer that is handed to the
//! compositor through wl_shm. There is deliberately no GPU, no SDL and no
//! widget toolkit here: just rectangles, rounded rectangles, an embedded
//! bitmap font and PNG blits.

const std = @import("std");
const font = @import("font.zig");
const png = @import("png.zig");

pub const Color = struct {
    r: u8,
    g: u8,
    b: u8,
    a: u8 = 255,

    pub fn lighten(self: Color, amount: u8) Color {
        return .{
            .r = self.r +| amount,
            .g = self.g +| amount,
            .b = self.b +| amount,
            .a = self.a,
        };
    }

    pub fn withAlpha(self: Color, alpha: u8) Color {
        return .{ .r = self.r, .g = self.g, .b = self.b, .a = alpha };
    }
};

pub const transparent = Color{ .r = 0, .g = 0, .b = 0, .a = 0 };

pub const Canvas = struct {
    pixels: []u32,
    width: i32,
    height: i32,
    clip_x0: i32,
    clip_y0: i32,
    clip_x1: i32,
    clip_y1: i32,

    pub fn init(pixels: []u32, width: u32, height: u32) Canvas {
        return .{
            .pixels = pixels,
            .width = @intCast(width),
            .height = @intCast(height),
            .clip_x0 = 0,
            .clip_y0 = 0,
            .clip_x1 = @intCast(width),
            .clip_y1 = @intCast(height),
        };
    }

    pub fn setClip(self: *Canvas, x: i32, y: i32, w: i32, h: i32) void {
        self.clip_x0 = @max(0, x);
        self.clip_y0 = @max(0, y);
        self.clip_x1 = @min(self.width, x +| w);
        self.clip_y1 = @min(self.height, y +| h);
        if (self.clip_x1 < self.clip_x0) self.clip_x1 = self.clip_x0;
        if (self.clip_y1 < self.clip_y0) self.clip_y1 = self.clip_y0;
    }

    pub fn resetClip(self: *Canvas) void {
        self.clip_x0 = 0;
        self.clip_y0 = 0;
        self.clip_x1 = self.width;
        self.clip_y1 = self.height;
    }

    pub fn clear(self: *Canvas, color: Color) void {
        const value = packPremultiplied(color, 255);
        @memset(self.pixels, value);
    }

    pub fn fillRect(self: *Canvas, x: i32, y: i32, w: i32, h: i32, color: Color) void {
        if (w <= 0 or h <= 0 or color.a == 0) return;

        const x0 = @max(self.clip_x0, x);
        const y0 = @max(self.clip_y0, y);
        const x1 = @min(self.clip_x1, x +| w);
        const y1 = @min(self.clip_y1, y +| h);
        if (x0 >= x1 or y0 >= y1) return;

        if (color.a == 255) {
            const value = packPremultiplied(color, 255);
            var py = y0;
            while (py < y1) : (py += 1) {
                const row = self.pixels[@as(usize, @intCast(py)) * @as(usize, @intCast(self.width)) ..][0..@intCast(self.width)];
                @memset(row[@intCast(x0)..@intCast(x1)], value);
            }
            return;
        }

        var py = y0;
        while (py < y1) : (py += 1) {
            var px = x0;
            while (px < x1) : (px += 1) {
                self.blend(px, py, color, 255);
            }
        }
    }

    /// Draw a rounded rectangle with a one-pixel-ish analytic antialiased
    /// border. `radius` is clamped to half of the smaller side.
    pub fn roundRect(self: *Canvas, x: i32, y: i32, w: i32, h: i32, radius: i32, color: Color) void {
        if (w <= 0 or h <= 0 or color.a == 0) return;

        const x0 = @max(self.clip_x0, x);
        const y0 = @max(self.clip_y0, y);
        const x1 = @min(self.clip_x1, x +| w);
        const y1 = @min(self.clip_y1, y +| h);
        if (x0 >= x1 or y0 >= y1) return;

        const r: f32 = @floatFromInt(@max(0, @min(radius, @divTrunc(@min(w, h), 2))));
        const cx: f32 = @as(f32, @floatFromInt(x)) + @as(f32, @floatFromInt(w)) / 2.0;
        const cy: f32 = @as(f32, @floatFromInt(y)) + @as(f32, @floatFromInt(h)) / 2.0;
        const half_w: f32 = @as(f32, @floatFromInt(w)) / 2.0;
        const half_h: f32 = @as(f32, @floatFromInt(h)) / 2.0;

        var py = y0;
        while (py < y1) : (py += 1) {
            const fy = @as(f32, @floatFromInt(py)) + 0.5;
            var px = x0;
            while (px < x1) : (px += 1) {
                const fx = @as(f32, @floatFromInt(px)) + 0.5;

                const qx = @abs(fx - cx) - (half_w - r);
                const qy = @abs(fy - cy) - (half_h - r);

                var dist: f32 = 0;
                if (qx <= 0 and qy <= 0) {
                    // Inside the rectangle: negative distance to the nearest
                    // edge. The old `-r` shortcut made radius-0 rectangles
                    // render at 50% opacity because it ignored the box depth.
                    dist = @max(qx, qy) - r;
                } else if (qx > 0 and qy <= 0) {
                    dist = qx - r;
                } else if (qy > 0 and qx <= 0) {
                    dist = qy - r;
                } else {
                    dist = @sqrt(qx * qx + qy * qy) - r;
                }

                const coverage = std.math.clamp(0.5 - dist, 0.0, 1.0);
                if (coverage <= 0.0) continue;

                const coverage_u8: u8 = @intFromFloat(@round(coverage * 255.0));
                self.blend(px, py, color, coverage_u8);
            }
        }
    }

    /// Draw a horizontally blended rounded rectangle, limited to
    /// `visible_width` pixels from the left. Colours are sampled across the
    /// full width, so a progress bar keeps the same palette as it fills.
    pub fn roundRectGradient(
        self: *Canvas,
        x: i32,
        y: i32,
        w: i32,
        h: i32,
        radius: i32,
        visible_width: i32,
        stops: []const Color,
    ) void {
        if (w <= 0 or h <= 0 or visible_width <= 0 or stops.len == 0) return;

        const visible = @min(w, visible_width);
        const x0 = @max(self.clip_x0, x);
        const y0 = @max(self.clip_y0, y);
        const x1 = @min(self.clip_x1, x +| visible);
        const y1 = @min(self.clip_y1, y +| h);
        if (x0 >= x1 or y0 >= y1) return;

        const r: f32 = @floatFromInt(@max(0, @min(radius, @divTrunc(@min(w, h), 2))));
        const cx: f32 = @as(f32, @floatFromInt(x)) + @as(f32, @floatFromInt(w)) / 2.0;
        const cy: f32 = @as(f32, @floatFromInt(y)) + @as(f32, @floatFromInt(h)) / 2.0;
        const half_w: f32 = @as(f32, @floatFromInt(w)) / 2.0;
        const half_h: f32 = @as(f32, @floatFromInt(h)) / 2.0;
        const width_f: f32 = @floatFromInt(w);

        var py = y0;
        while (py < y1) : (py += 1) {
            const fy = @as(f32, @floatFromInt(py)) + 0.5;
            var px = x0;
            while (px < x1) : (px += 1) {
                const fx = @as(f32, @floatFromInt(px)) + 0.5;

                const qx = @abs(fx - cx) - (half_w - r);
                const qy = @abs(fy - cy) - (half_h - r);

                var dist: f32 = 0;
                if (qx <= 0 and qy <= 0) {
                    dist = @max(qx, qy) - r;
                } else if (qx > 0 and qy <= 0) {
                    dist = qx - r;
                } else if (qy > 0 and qx <= 0) {
                    dist = qy - r;
                } else {
                    dist = @sqrt(qx * qx + qy * qy) - r;
                }

                const coverage = std.math.clamp(0.5 - dist, 0.0, 1.0);
                if (coverage <= 0.0) continue;

                const t = std.math.clamp((fx - @as(f32, @floatFromInt(x))) / width_f, 0.0, 1.0);
                self.blend(
                    px,
                    py,
                    sampleGradient(stops, t),
                    @intFromFloat(@round(coverage * 255.0)),
                );
            }
        }
    }

    pub fn text(self: *Canvas, x: i32, y: i32, text_value: []const u8, color: Color, glyph_scale: f32) i32 {
        var cursor = x;
        var it = std.unicode.Utf8Iterator{ .bytes = text_value, .i = 0 };
        while (it.nextCodepoint()) |codepoint| {
            const bitmap = font.glyph(codepoint) orelse font.glyph('?').?;
            cursor = self.drawGlyph(cursor, y, bitmap, color, glyph_scale);
        }
        return cursor;
    }

    /// Draw text, truncating with an ellipsis when it does not fit in
    /// `max_width` physical pixels.
    pub fn textFit(
        self: *Canvas,
        x: i32,
        y: i32,
        text_value: []const u8,
        color: Color,
        glyph_scale: f32,
        max_width: i32,
    ) i32 {
        if (max_width <= 0) return x;
        const full_width = font.textWidth(text_value, glyph_scale);
        if (full_width <= max_width) return self.text(x, y, text_value, color, glyph_scale);

        const ellipsis_width = font.advance(glyph_scale) * 3;
        const budget = max_width - ellipsis_width;
        if (budget <= 0) return x;

        var cursor = x;
        var used: i32 = 0;
        var it = std.unicode.Utf8Iterator{ .bytes = text_value, .i = 0 };
        while (it.nextCodepoint()) |codepoint| {
            const next = used + font.advance(glyph_scale);
            if (next > budget) break;
            const bitmap = font.glyph(codepoint) orelse font.glyph('?').?;
            cursor = self.drawGlyph(cursor, y, bitmap, color, glyph_scale);
            used = next;
        }
        return self.text(cursor, y, "...", color, glyph_scale);
    }

    /// Draw an image scaled into the target rectangle. Downscaling uses a
    /// small box filter; upscaling uses nearest-neighbour sampling.
    pub fn image(self: *Canvas, x: i32, y: i32, w: i32, h: i32, img: *const png.Image) void {
        self.imageTinted(x, y, w, h, img, .{ .r = 255, .g = 255, .b = 255 });
    }

    /// Draw a monochrome image multiplied by `tint`, preserving its alpha.
    pub fn imageTinted(
        self: *Canvas,
        x: i32,
        y: i32,
        w: i32,
        h: i32,
        img: *const png.Image,
        tint: Color,
    ) void {
        if (w <= 0 or h <= 0 or img.width == 0 or img.height == 0 or tint.a == 0) return;

        const x0 = @max(self.clip_x0, x);
        const y0 = @max(self.clip_y0, y);
        const x1 = @min(self.clip_x1, x +| w);
        const y1 = @min(self.clip_y1, y +| h);
        if (x0 >= x1 or y0 >= y1) return;

        const src_w: i64 = @intCast(img.width);
        const src_h: i64 = @intCast(img.height);
        const dst_w: i64 = @intCast(w);
        const dst_h: i64 = @intCast(h);

        var py = y0;
        while (py < y1) : (py += 1) {
            const dy = @as(i64, @intCast(py)) - @as(i64, @intCast(y));
            const sy0 = @divTrunc(dy * src_h, dst_h);
            const sy1 = @max(sy0 + 1, @divTrunc((dy + 1) * src_h, dst_h));

            var px = x0;
            while (px < x1) : (px += 1) {
                const dx = @as(i64, @intCast(px)) - @as(i64, @intCast(x));
                const sx0 = @divTrunc(dx * src_w, dst_w);
                const sx1 = @max(sx0 + 1, @divTrunc((dx + 1) * src_w, dst_w));

                var count: u32 = 0;
                var sum_a: u32 = 0;
                var sum_r: u64 = 0;
                var sum_g: u64 = 0;
                var sum_b: u64 = 0;

                var sy = sy0;
                while (sy < sy1) : (sy += 1) {
                    var sx = sx0;
                    while (sx < sx1) : (sx += 1) {
                        const pixel = img.pixels[@as(usize, @intCast(sy * src_w + sx))];
                        const a: u32 = (pixel >> 24) & 0xff;
                        sum_a += a;
                        sum_r += @as(u64, (pixel >> 16) & 0xff) * a;
                        sum_g += @as(u64, (pixel >> 8) & 0xff) * a;
                        sum_b += @as(u64, pixel & 0xff) * a;
                        count += 1;
                    }
                }
                if (count == 0 or sum_a == 0) continue;

                const color = Color{
                    .r = @intCast(sum_r / sum_a),
                    .g = @intCast(sum_g / sum_a),
                    .b = @intCast(sum_b / sum_a),
                    .a = @intCast(sum_a / count),
                };
                const tinted = Color{
                    .r = @intCast((@as(u32, color.r) * tint.r + 127) / 255),
                    .g = @intCast((@as(u32, color.g) * tint.g + 127) / 255),
                    .b = @intCast((@as(u32, color.b) * tint.b + 127) / 255),
                    .a = @intCast((@as(u32, color.a) * tint.a + 127) / 255),
                };
                self.blend(px, py, tinted, 255);
            }
        }
    }

    fn drawGlyph(self: *Canvas, x: i32, y: i32, bitmap: *const [font.glyph_height]u8, color: Color, glyph_scale: f32) i32 {
        const dst_w: usize = @intFromFloat(@max(1, @round(@as(f32, font.glyph_width) * glyph_scale)));
        const dst_h: usize = @intFromFloat(@max(1, @round(@as(f32, font.glyph_height) * glyph_scale)));

        var dy: usize = 0;
        while (dy < dst_h) : (dy += 1) {
            const src_y = sourcePixel(dy, dst_h, font.glyph_height);
            const bits = bitmap[src_y];

            var dx: usize = 0;
            while (dx < dst_w) : (dx += 1) {
                const src_x = sourcePixel(dx, dst_w, font.glyph_width);
                if ((bits >> @intCast(src_x)) & 1 == 0) continue;

                // Merge horizontally adjacent set pixels into one fillRect.
                var run_end = dx + 1;
                while (run_end < dst_w) {
                    const next_x = sourcePixel(run_end, dst_w, font.glyph_width);
                    if ((bits >> @intCast(next_x)) & 1 == 0) break;
                    run_end += 1;
                }

                self.fillRect(
                    x + @as(i32, @intCast(dx)),
                    y + @as(i32, @intCast(dy)),
                    @intCast(run_end - dx),
                    1,
                    color,
                );
                dx = run_end - 1;
            }
        }
        return x + font.advance(glyph_scale);
    }

    fn blend(self: *Canvas, x: i32, y: i32, color: Color, coverage: u8) void {
        if (x < self.clip_x0 or x >= self.clip_x1 or y < self.clip_y0 or y >= self.clip_y1) return;

        const alpha = (@as(u16, color.a) * @as(u16, coverage) + 127) / 255;
        if (alpha == 0) return;

        const idx = @as(usize, @intCast(y)) * @as(usize, @intCast(self.width)) + @as(usize, @intCast(x));
        const dst = self.pixels[idx];

        const sa: u32 = @intCast(alpha);
        const inv: u32 = 255 - sa;
        const dr = (dst >> 16) & 0xff;
        const dg = (dst >> 8) & 0xff;
        const db = dst & 0xff;
        const da = (dst >> 24) & 0xff;

        const r = (@as(u32, color.r) * sa + dr * inv + 127) / 255;
        const g = (@as(u32, color.g) * sa + dg * inv + 127) / 255;
        const b = (@as(u32, color.b) * sa + db * inv + 127) / 255;
        const a = sa + (da * inv + 127) / 255;

        self.pixels[idx] = (a << 24) | (r << 16) | (g << 8) | b;
    }
};

fn sampleGradient(stops: []const Color, t: f32) Color {
    if (stops.len == 1) return stops[0];

    const position = std.math.clamp(t, 0.0, 1.0) *
        @as(f32, @floatFromInt(stops.len - 1));
    const raw_index: usize = @intFromFloat(@floor(position));
    const index = @min(raw_index, stops.len - 2);
    const from = stops[index];
    const to = stops[index + 1];
    return lerpColor(from, to, position - @as(f32, @floatFromInt(index)));
}

fn lerpColor(from: Color, to: Color, t: f32) Color {
    return .{
        .r = lerpChannel(from.r, to.r, t),
        .g = lerpChannel(from.g, to.g, t),
        .b = lerpChannel(from.b, to.b, t),
        .a = lerpChannel(from.a, to.a, t),
    };
}

fn lerpChannel(from: u8, to: u8, t: f32) u8 {
    const a: f32 = @floatFromInt(from);
    const b: f32 = @floatFromInt(to);
    return @intFromFloat(@round(a + (b - a) * t));
}

fn sourcePixel(dest: usize, dest_size: usize, source_size: usize) usize {
    const sample = (@as(f32, @floatFromInt(dest)) + 0.5) *
        @as(f32, @floatFromInt(source_size)) /
        @as(f32, @floatFromInt(dest_size));
    const index: usize = @intFromFloat(@floor(sample));
    return @min(index, source_size - 1);
}

fn packPremultiplied(color: Color, coverage: u8) u32 {
    const a16 = @as(u16, color.a) * @as(u16, coverage);
    const a: u32 = (a16 + 127) / 255;
    if (a == 0) return 0;
    const r = (@as(u32, color.r) * a + 127) / 255;
    const g = (@as(u32, color.g) * a + 127) / 255;
    const b = (@as(u32, color.b) * a + 127) / 255;
    return (a << 24) | (r << 16) | (g << 8) | b;
}

test "gradient samples endpoint and middle stops" {
    const stops = [_]Color{
        .{ .r = 0, .g = 0, .b = 0 },
        .{ .r = 100, .g = 100, .b = 100 },
        .{ .r = 200, .g = 200, .b = 200 },
    };
    try std.testing.expectEqual(stops[0], sampleGradient(&stops, 0.0));
    try std.testing.expectEqual(stops[2], sampleGradient(&stops, 1.0));
    try std.testing.expectEqual(stops[1], sampleGradient(&stops, 0.5));
}

test "roundRect with zero radius is opaque inside" {
    var pixels: [100]u32 = @splat(0);
    var canvas = Canvas.init(&pixels, 10, 10);
    const color = Color{ .r = 0x19, .g = 0x17, .b = 0x24 };
    canvas.roundRect(0, 0, 10, 10, 0, color);

    try std.testing.expectEqual(packPremultiplied(color, 255), pixels[5 * 10 + 5]);
}
