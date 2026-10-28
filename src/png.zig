//! Minimal PNG decoder for launcher icons.
//!
//! Supports the subset of PNG used by hicolor icon themes: non-interlaced
//! images with 8/16-bit RGB/RGBA, palette and grayscale colour types. The
//! resulting pixels are straight (not premultiplied) 0xAARRGGBB values.

const std = @import("std");

const signature = [_]u8{ 0x89, 'P', 'N', 'G', 0x0d, 0x0a, 0x1a, 0x0a };

pub const Image = struct {
    width: u32,
    height: u32,
    pixels: []u32,

    pub fn deinit(self: *Image, gpa: std.mem.Allocator) void {
        gpa.free(self.pixels);
        self.* = undefined;
    }
};

pub const DecodeError = error{
    InvalidSignature,
    Truncated,
    MissingHeader,
    Unsupported,
    Interlaced,
    TooLarge,
    BadFilter,
    OutOfMemory,
    InvalidChunk,
};

pub fn decode(gpa: std.mem.Allocator, bytes: []const u8) DecodeError!Image {
    if (bytes.len < signature.len or !std.mem.eql(u8, bytes[0..signature.len], &signature)) {
        return error.InvalidSignature;
    }

    var width: u32 = 0;
    var height: u32 = 0;
    var bit_depth: u8 = 0;
    var color_type: u8 = 0;
    var have_header = false;

    var palette: [256][3]u8 = undefined;
    var palette_len: usize = 0;
    var trns: [256]u8 = undefined;
    @memset(&trns, 255);
    var trns_gray: ?u16 = null;
    var trns_rgb: ?[3]u16 = null;

    var idat: std.ArrayList(u8) = .empty;
    defer idat.deinit(gpa);

    var pos: usize = signature.len;
    while (pos + 8 <= bytes.len) {
        const length = readU32(bytes[pos..][0..4]);
        const chunk_type = bytes[pos + 4 ..][0..4];
        const data_start = pos + 8;
        const data_end = data_start + length;
        if (data_end + 4 > bytes.len) return error.Truncated;
        const data = bytes[data_start..data_end];

        if (std.mem.eql(u8, chunk_type, "IHDR")) {
            if (data.len < 13) return error.Truncated;
            width = readU32(data[0..4]);
            height = readU32(data[4..8]);
            bit_depth = data[8];
            color_type = data[9];
            const compression = data[10];
            const filter_method = data[11];
            const interlace = data[12];
            if (compression != 0 or filter_method != 0) return error.Unsupported;
            if (interlace != 0) return error.Interlaced;
            if (width == 0 or height == 0 or width > 1024 or height > 1024) return error.TooLarge;
            if (@as(u64, width) * @as(u64, height) > 1024 * 1024) return error.TooLarge;
            have_header = true;
        } else if (std.mem.eql(u8, chunk_type, "PLTE")) {
            const entries = @min(data.len / 3, 256);
            palette_len = entries;
            var i: usize = 0;
            while (i < entries) : (i += 1) {
                palette[i] = .{ data[i * 3], data[i * 3 + 1], data[i * 3 + 2] };
            }
        } else if (std.mem.eql(u8, chunk_type, "tRNS")) {
            if (color_type == 3) {
                const n = @min(data.len, 256);
                @memcpy(trns[0..n], data[0..n]);
            } else if (color_type == 0 and data.len >= 2) {
                trns_gray = readU16(data[0..2]);
            } else if (color_type == 2 and data.len >= 6) {
                trns_rgb = .{ readU16(data[0..2]), readU16(data[2..4]), readU16(data[4..6]) };
            }
        } else if (std.mem.eql(u8, chunk_type, "IDAT")) {
            try idat.appendSlice(gpa, data);
        } else if (std.mem.eql(u8, chunk_type, "IEND")) {
            break;
        }

        pos = data_end + 4;
    }

    if (!have_header) return error.MissingHeader;

    const channels: u8 = switch (color_type) {
        0 => 1, // grayscale
        2 => 3, // RGB
        3 => 1, // palette index
        4 => 2, // grayscale + alpha
        6 => 4, // RGBA
        else => return error.Unsupported,
    };
    const valid_depth = switch (color_type) {
        0 => bit_depth == 1 or bit_depth == 2 or bit_depth == 4 or bit_depth == 8 or bit_depth == 16,
        3 => bit_depth == 1 or bit_depth == 2 or bit_depth == 4 or bit_depth == 8,
        2, 4, 6 => bit_depth == 8 or bit_depth == 16,
        else => false,
    };
    if (!valid_depth) return error.Unsupported;
    if (color_type == 3 and palette_len == 0) return error.Unsupported;

    const bits_per_pixel: u32 = @as(u32, channels) * bit_depth;
    const row_bytes: u32 = (width * bits_per_pixel + 7) / 8;
    const expected: usize = (@as(usize, row_bytes) + 1) * height;
    if (expected > 16 * 1024 * 1024) return error.TooLarge;
    if (idat.items.len == 0) return error.Truncated;

    const window = try gpa.alloc(u8, std.compress.flate.max_window_len);
    defer gpa.free(window);

    var input = std.Io.Reader.fixed(idat.items);
    var decompressor = std.compress.flate.Decompress.init(&input, .zlib, window);
    const raw = decompressor.reader.allocRemaining(gpa, .limited(expected)) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.Truncated,
    };
    defer gpa.free(raw);
    if (raw.len < expected) return error.Truncated;

    const filtered = try gpa.alloc(u8, @as(usize, row_bytes) * height);
    defer gpa.free(filtered);

    const bytes_per_pixel: u32 = @max(1, (bits_per_pixel + 7) / 8);
    var y: u32 = 0;
    while (y < height) : (y += 1) {
        const filter = raw[@as(usize, y) * (@as(usize, row_bytes) + 1)];
        const src = raw[@as(usize, y) * (@as(usize, row_bytes) + 1) + 1 ..][0..row_bytes];
        const dst = filtered[@as(usize, y) * row_bytes ..][0..row_bytes];
        const prev: ?[]const u8 = if (y > 0) filtered[@as(usize, y - 1) * row_bytes ..][0..row_bytes] else null;

        var x: u32 = 0;
        while (x < row_bytes) : (x += 1) {
            const left: u8 = if (x >= bytes_per_pixel) dst[x - bytes_per_pixel] else 0;
            const up: u8 = if (prev) |p| p[x] else 0;
            const up_left: u8 = if (prev != null and x >= bytes_per_pixel) prev.?[x - bytes_per_pixel] else 0;

            dst[x] = switch (filter) {
                0 => src[x],
                1 => src[x] +% left,
                2 => src[x] +% up,
                3 => src[x] +% @as(u8, @intCast((@as(u16, left) + up) / 2)),
                4 => src[x] +% paeth(left, up, up_left),
                else => return error.BadFilter,
            };
        }
    }

    const pixels = try gpa.alloc(u32, @as(usize, width) * height);
    errdefer gpa.free(pixels);

    var py: u32 = 0;
    while (py < height) : (py += 1) {
        const row = filtered[@as(usize, py) * row_bytes ..][0..row_bytes];
        var px: u32 = 0;
        while (px < width) : (px += 1) {
            const pixel_index = @as(usize, py) * width + px;
            pixels[pixel_index] = switch (color_type) {
                0 => blk: {
                    const raw_value = sample(row, px, bit_depth);
                    const gray = scaleSample(raw_value, bit_depth);
                    const alpha: u8 = if (trns_gray) |t| if (raw_value == t) 0 else 255 else 255;
                    break :blk pack(gray, gray, gray, alpha);
                },
                2 => blk: {
                    const r_raw = sample(row, px * 3, bit_depth);
                    const g_raw = sample(row, px * 3 + 1, bit_depth);
                    const b_raw = sample(row, px * 3 + 2, bit_depth);
                    const r = scaleSample(r_raw, bit_depth);
                    const g = scaleSample(g_raw, bit_depth);
                    const b = scaleSample(b_raw, bit_depth);
                    const alpha: u8 = if (trns_rgb) |t|
                        if (r_raw == t[0] and g_raw == t[1] and b_raw == t[2]) 0 else 255
                    else
                        255;
                    break :blk pack(r, g, b, alpha);
                },
                3 => blk: {
                    const index = sample(row, px, bit_depth);
                    if (index >= palette_len) break :blk pack(0, 0, 0, 255);
                    const rgb = palette[index];
                    const alpha = trns[index];
                    break :blk pack(rgb[0], rgb[1], rgb[2], alpha);
                },
                4 => blk: {
                    const g_raw = sample(row, px * 2, bit_depth);
                    const a_raw = sample(row, px * 2 + 1, bit_depth);
                    const g = scaleSample(g_raw, bit_depth);
                    const a = scaleSample(a_raw, bit_depth);
                    break :blk pack(g, g, g, a);
                },
                6 => blk: {
                    const r = scaleSample(sample(row, px * 4, bit_depth), bit_depth);
                    const g = scaleSample(sample(row, px * 4 + 1, bit_depth), bit_depth);
                    const b = scaleSample(sample(row, px * 4 + 2, bit_depth), bit_depth);
                    const a = scaleSample(sample(row, px * 4 + 3, bit_depth), bit_depth);
                    break :blk pack(r, g, b, a);
                },
                else => unreachable,
            };
        }
    }

    return .{ .width = width, .height = height, .pixels = pixels };
}

fn readU32(bytes: *const [4]u8) u32 {
    return std.mem.readInt(u32, bytes, .big);
}

fn readU16(bytes: *const [2]u8) u16 {
    return std.mem.readInt(u16, bytes, .big);
}

fn sample(row: []const u8, index: u32, bit_depth: u8) u16 {
    return switch (bit_depth) {
        8 => row[index],
        16 => (@as(u16, row[@as(usize, index) * 2]) << 8) | row[@as(usize, index) * 2 + 1],
        1, 2, 4 => blk: {
            const bits: u32 = @as(u32, index) * bit_depth;
            const byte = row[bits / 8];
            const shift: u3 = @intCast(8 - bit_depth - (bits % 8));
            const mask: u8 = (@as(u8, 1) << @intCast(bit_depth)) - 1;
            break :blk (byte >> shift) & mask;
        },
        else => 0,
    };
}

fn scaleSample(value: u16, bit_depth: u8) u8 {
    return switch (bit_depth) {
        8 => @intCast(value),
        16 => @intCast(value >> 8),
        1 => if (value == 0) 0 else 255,
        2 => @intCast(value * 85),
        4 => @intCast(value * 17),
        else => 0,
    };
}

fn pack(r: u8, g: u8, b: u8, a: u8) u32 {
    return (@as(u32, a) << 24) | (@as(u32, r) << 16) | (@as(u32, g) << 8) | b;
}

fn paeth(a: u8, b: u8, c: u8) u8 {
    const p: i32 = @as(i32, a) + @as(i32, b) - @as(i32, c);
    const pa = @abs(p - @as(i32, a));
    const pb = @abs(p - @as(i32, b));
    const pc = @abs(p - @as(i32, c));
    if (pa <= pb and pa <= pc) return a;
    if (pb <= pc) return b;
    return c;
}

test "reject non-png input" {
    try std.testing.expectError(error.InvalidSignature, decode(std.testing.allocator, "not a png"));
}

test "decode rgba png" {
    const bytes = [_]u8{
        0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0x00, 0x00, 0x0d, 0x49, 0x48, 0x44, 0x52,
        0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x02, 0x08, 0x06, 0x00, 0x00, 0x00, 0x72, 0xb6, 0x0d,
        0x24, 0x00, 0x00, 0x00, 0x14, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9c, 0x63, 0xf8, 0xcf, 0xc0, 0xf0,
        0x1f, 0x0c, 0x81, 0x74, 0xc3, 0x7f, 0x20, 0x00, 0x00, 0x47, 0x4d, 0x09, 0x78, 0xa9, 0x7c, 0x0f,
        0x75, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4e, 0x44, 0xae, 0x42, 0x60, 0x82,
    };

    var image = try decode(std.testing.allocator, &bytes);
    defer image.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u32, 2), image.width);
    try std.testing.expectEqual(@as(u32, 2), image.height);
    try std.testing.expectEqual(@as(u32, 0xffff0000), image.pixels[0]);
    try std.testing.expectEqual(@as(u32, 0xff00ff00), image.pixels[1]);
    try std.testing.expectEqual(@as(u32, 0x800000ff), image.pixels[2]);
    try std.testing.expectEqual(@as(u32, 0xffffffff), image.pixels[3]);
}

test "decode palette png with transparency" {
    const bytes = [_]u8{
        0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0x00, 0x00, 0x0d, 0x49, 0x48, 0x44, 0x52,
        0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x02, 0x08, 0x03, 0x00, 0x00, 0x00, 0x45, 0x68, 0xfd,
        0x16, 0x00, 0x00, 0x00, 0x06, 0x50, 0x4c, 0x54, 0x45, 0xff, 0x00, 0x00, 0x00, 0xff, 0x00, 0xd2,
        0x87, 0xef, 0x71, 0x00, 0x00, 0x00, 0x02, 0x74, 0x52, 0x4e, 0x53, 0xff, 0x64, 0xaf, 0x68, 0x95,
        0x0b, 0x00, 0x00, 0x00, 0x0c, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9c, 0x63, 0x60, 0x60, 0x04, 0x42,
        0x00, 0x00, 0x0c, 0x00, 0x03, 0x2b, 0x63, 0xcb, 0x50, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4e,
        0x44, 0xae, 0x42, 0x60, 0x82,
    };

    var image = try decode(std.testing.allocator, &bytes);
    defer image.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u32, 0xffff0000), image.pixels[0]);
    try std.testing.expectEqual(@as(u32, 0x6400ff00), image.pixels[1]);
    try std.testing.expectEqual(@as(u32, 0x6400ff00), image.pixels[2]);
    try std.testing.expectEqual(@as(u32, 0xffff0000), image.pixels[3]);
}
