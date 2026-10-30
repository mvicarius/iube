//! Optional `~/.config/iube/config` loading.
//!
//! The format is deliberately tiny: `key = value` lines, `#`/`;` comments and
//! an optional `[colors]` section. Unknown keys are ignored so a config file
//! written for a newer version never stops iube from starting.

const std = @import("std");
const render = @import("render.zig");

const Color = render.Color;

/// Rosé Pine (default palette). Keeping these together makes it obvious what
/// the defaults are and keeps the parser independent of any runtime data.
const rosepine = struct {
    const base = Color{ .r = 0x19, .g = 0x17, .b = 0x24 };
    const surface = Color{ .r = 0x1f, .g = 0x1d, .b = 0x2e };
    const accent = Color{ .r = 0x9c, .g = 0xcf, .b = 0xd8 }; // foam
    const dark_accent = Color{ .r = 0x31, .g = 0x74, .b = 0x8f }; // pine
    const detail_1 = Color{ .r = 0xeb, .g = 0xbc, .b = 0xba }; // rose
    const detail_2 = Color{ .r = 0xc4, .g = 0xa7, .b = 0xe7 }; // iris
    const warm_1 = Color{ .r = 0xf6, .g = 0xc1, .b = 0x77 }; // gold
    const warm_2 = Color{ .r = 0xeb, .g = 0x6f, .b = 0x92 }; // love
    const text = Color{ .r = 0xe0, .g = 0xde, .b = 0xf4 };
    const muted = Color{ .r = 0x6e, .g = 0x6a, .b = 0x86 };
    const highlight_low = Color{ .r = 0x21, .g = 0x20, .b = 0x2e };
    const highlight_mid = Color{ .r = 0x40, .g = 0x3d, .b = 0x52 };
    const highlight_high = Color{ .r = 0x52, .g = 0x4f, .b = 0x67 };
};

pub const Config = struct {
    /// Multiplies every layout dimension: window, margins, icons, text, corner
    /// radius and so on.
    scale: f32 = 1.0,
    /// Window corner radius in unscaled logical pixels. Search fields, rows and
    /// fallback icons use half of this value.
    corner_radius: i32 = 0,

    base: Color = rosepine.base,
    surface: Color = rosepine.surface,
    accent: Color = rosepine.accent,
    dark_accent: Color = rosepine.dark_accent,
    detail_1: Color = rosepine.detail_1,
    detail_2: Color = rosepine.detail_2,
    warm_1: Color = rosepine.warm_1,
    warm_2: Color = rosepine.warm_2,
    text: Color = rosepine.text,
    muted: Color = rosepine.muted,
    highlight_low: Color = rosepine.highlight_low,
    highlight_mid: Color = rosepine.highlight_mid,
    highlight_high: Color = rosepine.highlight_high,
};

pub const Env = struct {
    home: ?[]const u8 = null,
    xdg_config_home: ?[]const u8 = null,
};

const max_config_size = 64 * 1024;
const max_scale = 4.0;
const min_scale = 0.5;
const max_corner_radius = 256;

/// Load the user config, or return the Rosé Pine defaults when it does not
/// exist. The file is read once at startup and freed immediately; no config
/// state stays around except this small struct.
pub fn load(io: std.Io, gpa: std.mem.Allocator, env: Env) Config {
    var config = Config{};

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = configPath(&path_buffer, env) orelse return config;

    const data = std.Io.Dir.readFileAlloc(
        .cwd(),
        io,
        path,
        gpa,
        .limited(max_config_size),
    ) catch |err| {
        if (err != error.FileNotFound and err != error.NotDir) {
            std.log.warn("failed to read {s}: {s}", .{ path, @errorName(err) });
        }
        return config;
    };
    defer gpa.free(data);

    parse(&config, data);
    return config;
}

fn configPath(buffer: []u8, env: Env) ?[]const u8 {
    if (env.xdg_config_home) |dir| {
        if (dir.len > 0 and std.fs.path.isAbsolute(dir)) {
            return std.fmt.bufPrint(
                buffer,
                "{s}/iube/config",
                .{std.mem.trimEnd(u8, dir, "/")},
            ) catch null;
        }
    }

    if (env.home) |home| {
        if (home.len > 0) {
            return std.fmt.bufPrint(
                buffer,
                "{s}/.config/iube/config",
                .{std.mem.trimEnd(u8, home, "/")},
            ) catch null;
        }
    }
    return null;
}

/// Parse `text` into `config`. Invalid values are logged and ignored so the
/// previous (usually default) value remains in effect.
pub fn parse(config: *Config, text: []const u8) void {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0) continue;
        if (line[0] == '#' or line[0] == ';' or line[0] == '[') continue;

        const delimiter = std.mem.indexOfAny(u8, line, "=:") orelse continue;
        const key = std.mem.trim(u8, line[0..delimiter], " \t");
        var value = std.mem.trim(u8, line[delimiter + 1 ..], " \t");
        value = stripInlineComment(value);
        if (key.len == 0 or value.len == 0) continue;
        if (value.len >= 2 and
            ((value[0] == '"' and value[value.len - 1] == '"') or
                (value[0] == '\'' and value[value.len - 1] == '\'')))
        {
            value = value[1 .. value.len - 1];
        }

        if (keyEql(key, "scale")) {
            const parsed = std.fmt.parseFloat(f32, value) catch {
                warnValue(key, value);
                continue;
            };
            if (!std.math.isFinite(parsed) or parsed < min_scale or parsed > max_scale) {
                warnValue(key, value);
                continue;
            }
            config.scale = parsed;
        } else if (keyEql(key, "corner_radius")) {
            const parsed = std.fmt.parseFloat(f32, value) catch {
                warnValue(key, value);
                continue;
            };
            if (!std.math.isFinite(parsed) or parsed < 0) {
                warnValue(key, value);
                continue;
            }
            config.corner_radius = @intFromFloat(@min(@round(parsed), max_corner_radius));
        } else if (colorField(config, key)) |field| {
            field.* = parseColor(value) orelse {
                warnValue(key, value);
                continue;
            };
        }
    }
}

fn stripInlineComment(value: []const u8) []const u8 {
    var end = value.len;
    if (std.mem.indexOfScalar(u8, value, ';')) |index| end = @min(end, index);
    if (std.mem.indexOf(u8, value, " #")) |index| end = @min(end, index);
    if (std.mem.indexOf(u8, value, "\t#")) |index| end = @min(end, index);
    return std.mem.trimEnd(u8, value[0..end], " \t");
}

fn colorField(config: *Config, key: []const u8) ?*Color {
    if (keyEql(key, "base")) return &config.base;
    if (keyEql(key, "surface")) return &config.surface;
    if (keyEql(key, "accent")) return &config.accent;
    if (keyEql(key, "dark_accent")) return &config.dark_accent;
    if (keyEql(key, "detail_1")) return &config.detail_1;
    if (keyEql(key, "detail_2")) return &config.detail_2;
    if (keyEql(key, "warm_1")) return &config.warm_1;
    if (keyEql(key, "warm_2")) return &config.warm_2;
    if (keyEql(key, "text")) return &config.text;
    if (keyEql(key, "muted")) return &config.muted;
    if (keyEql(key, "highlight_low")) return &config.highlight_low;
    if (keyEql(key, "highlight_mid")) return &config.highlight_mid;
    if (keyEql(key, "highlight_high")) return &config.highlight_high;
    return null;
}

/// Case-insensitive key comparison that treats `-` and `_` as the same
/// character, so `corner-radius`, `corner_radius` and `Corner-Radius` all work.
fn keyEql(key: []const u8, expected: []const u8) bool {
    if (key.len != expected.len) return false;
    for (key, expected) |a, b| {
        const normalized = if (a == '-') '_' else std.ascii.toLower(a);
        if (normalized != b) return false;
    }
    return true;
}

fn parseColor(value: []const u8) ?Color {
    var hex = value;
    if (std.mem.startsWith(u8, hex, "#")) {
        hex = hex[1..];
    } else if (std.mem.startsWith(u8, hex, "0x") or std.mem.startsWith(u8, hex, "0X")) {
        hex = hex[2..];
    } else {
        return null;
    }

    return switch (hex.len) {
        3 => colorFromNibbles(hex, false),
        4 => colorFromNibbles(hex, true),
        6 => colorFromBytes(hex, false),
        8 => colorFromBytes(hex, true),
        else => null,
    };
}

fn colorFromNibbles(hex: []const u8, with_alpha: bool) ?Color {
    const r = hexNibble(hex[0]) orelse return null;
    const g = hexNibble(hex[1]) orelse return null;
    const b = hexNibble(hex[2]) orelse return null;
    const a = if (with_alpha) (hexNibble(hex[3]) orelse return null) else 15;
    return .{
        .r = r * 17,
        .g = g * 17,
        .b = b * 17,
        .a = a * 17,
    };
}

fn colorFromBytes(hex: []const u8, with_alpha: bool) ?Color {
    return .{
        .r = hexByte(hex[0..2]) orelse return null,
        .g = hexByte(hex[2..4]) orelse return null,
        .b = hexByte(hex[4..6]) orelse return null,
        .a = if (with_alpha) (hexByte(hex[6..8]) orelse return null) else 255,
    };
}

fn hexNibble(byte: u8) ?u8 {
    return switch (byte) {
        '0'...'9' => byte - '0',
        'a'...'f' => byte - 'a' + 10,
        'A'...'F' => byte - 'A' + 10,
        else => null,
    };
}

fn hexByte(bytes: []const u8) ?u8 {
    const high = hexNibble(bytes[0]) orelse return null;
    const low = hexNibble(bytes[1]) orelse return null;
    return high * 16 + low;
}

fn warnValue(key: []const u8, value: []const u8) void {
    std.log.warn("iube config: ignoring invalid {s} value '{s}'", .{ key, value });
}

test "defaults are rose pine" {
    const config = Config{};
    try std.testing.expectEqual(@as(f32, 1.0), config.scale);
    try std.testing.expectEqual(@as(i32, 0), config.corner_radius);
    try std.testing.expectEqual(Color{ .r = 0x19, .g = 0x17, .b = 0x24 }, config.base);
    try std.testing.expectEqual(Color{ .r = 0x1f, .g = 0x1d, .b = 0x2e }, config.surface);
    try std.testing.expectEqual(Color{ .r = 0x9c, .g = 0xcf, .b = 0xd8 }, config.accent);
    try std.testing.expectEqual(Color{ .r = 0x31, .g = 0x74, .b = 0x8f }, config.dark_accent);
    try std.testing.expectEqual(Color{ .r = 0xeb, .g = 0xbc, .b = 0xba }, config.detail_1);
    try std.testing.expectEqual(Color{ .r = 0xc4, .g = 0xa7, .b = 0xe7 }, config.detail_2);
    try std.testing.expectEqual(Color{ .r = 0xf6, .g = 0xc1, .b = 0x77 }, config.warm_1);
    try std.testing.expectEqual(Color{ .r = 0xeb, .g = 0x6f, .b = 0x92 }, config.warm_2);
    try std.testing.expectEqual(Color{ .r = 0xe0, .g = 0xde, .b = 0xf4 }, config.text);
    try std.testing.expectEqual(Color{ .r = 0x6e, .g = 0x6a, .b = 0x86 }, config.muted);
    try std.testing.expectEqual(Color{ .r = 0x21, .g = 0x20, .b = 0x2e }, config.highlight_low);
    try std.testing.expectEqual(Color{ .r = 0x40, .g = 0x3d, .b = 0x52 }, config.highlight_mid);
    try std.testing.expectEqual(Color{ .r = 0x52, .g = 0x4f, .b = 0x67 }, config.highlight_high);
}

test "parse scale radius and colors" {
    var config = Config{};
    parse(&config,
        \\# a comment
        \\scale = 1.5 ; larger
        \\corner-radius = 12
        \\[colors]
        \\base = #000000
        \\surface = #112233 # inline comment
        \\accent = #abc
        \\dark_accent = #0a0b0c
        \\detail_1 = #aabbcc
        \\detail_2 = #bbccdd
        \\warm_1 = #ffcc00
        \\warm_2 = #ff0066
        \\text = #ffffff
        \\muted = 0x808080
        \\highlight_low = #010203
        \\highlight-mid = #040506
        \\highlight_high = #070809
    );

    try std.testing.expectApproxEqAbs(@as(f32, 1.5), config.scale, 0.0001);
    try std.testing.expectEqual(@as(i32, 12), config.corner_radius);
    try std.testing.expectEqual(Color{ .r = 0, .g = 0, .b = 0 }, config.base);
    try std.testing.expectEqual(Color{ .r = 0x11, .g = 0x22, .b = 0x33 }, config.surface);
    try std.testing.expectEqual(Color{ .r = 0xaa, .g = 0xbb, .b = 0xcc }, config.accent);
    try std.testing.expectEqual(Color{ .r = 0x0a, .g = 0x0b, .b = 0x0c }, config.dark_accent);
    try std.testing.expectEqual(Color{ .r = 0xaa, .g = 0xbb, .b = 0xcc }, config.detail_1);
    try std.testing.expectEqual(Color{ .r = 0xbb, .g = 0xcc, .b = 0xdd }, config.detail_2);
    try std.testing.expectEqual(Color{ .r = 0xff, .g = 0xcc, .b = 0x00 }, config.warm_1);
    try std.testing.expectEqual(Color{ .r = 0xff, .g = 0x00, .b = 0x66 }, config.warm_2);
    try std.testing.expectEqual(Color{ .r = 0xff, .g = 0xff, .b = 0xff }, config.text);
    try std.testing.expectEqual(Color{ .r = 0x80, .g = 0x80, .b = 0x80 }, config.muted);
    try std.testing.expectEqual(Color{ .r = 0x01, .g = 0x02, .b = 0x03 }, config.highlight_low);
    try std.testing.expectEqual(Color{ .r = 0x04, .g = 0x05, .b = 0x06 }, config.highlight_mid);
    try std.testing.expectEqual(Color{ .r = 0x07, .g = 0x08, .b = 0x09 }, config.highlight_high);
}

test "parse alpha and quoted values" {
    var config = Config{};
    parse(&config,
        \\accent = "#11223344"
        \\base = '#00000000'
    );
    try std.testing.expectEqual(Color{ .r = 0x11, .g = 0x22, .b = 0x33, .a = 0x44 }, config.accent);
    try std.testing.expectEqual(Color{ .r = 0, .g = 0, .b = 0, .a = 0 }, config.base);
}

test "config path respects xdg and home" {
    var buffer: [std.fs.max_path_bytes]u8 = undefined;

    try std.testing.expectEqualStrings(
        "/tmp/iube-config/iube/config",
        configPath(&buffer, .{ .xdg_config_home = "/tmp/iube-config/" }).?,
    );
    try std.testing.expectEqualStrings(
        "/home/user/.config/iube/config",
        configPath(&buffer, .{ .home = "/home/user" }).?,
    );
    // A relative XDG_CONFIG_HOME is invalid, so fall back to $HOME.
    try std.testing.expectEqualStrings(
        "/home/user/.config/iube/config",
        configPath(&buffer, .{ .home = "/home/user", .xdg_config_home = "relative" }).?,
    );
    try std.testing.expect(configPath(&buffer, .{}) == null);
}

test "invalid values keep defaults" {
    var config = Config{};
    parse(&config,
        \\scale = 0
        \\corner_radius = -2
        \\base = not-a-color
        \\unknown_key = whatever
    );

    try std.testing.expectEqual(@as(f32, 1.0), config.scale);
    try std.testing.expectEqual(@as(i32, 0), config.corner_radius);
    try std.testing.expectEqual(Color{ .r = 0x19, .g = 0x17, .b = 0x24 }, config.base);
}
