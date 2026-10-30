//! Registry of the tools exposed by the iube control panel.
//!
//! The panel is deliberately data-driven: adding a tool here makes it appear in
//! `iube` and gives `iube <id>` a place to dispatch to. Tools whose backend has
//! not landed yet are marked `coming_soon` and open a placeholder view.

const std = @import("std");
const config = @import("config.zig");
const render = @import("render.zig");

pub const Status = enum {
    available,
    coming_soon,
};

pub const ColorRole = enum {
    accent,
    dark_accent,
    detail_1,
    detail_2,
    warm_1,
    warm_2,
};

pub const Tool = struct {
    /// Command-line name: `iube <id>`.
    id: []const u8,
    name: []const u8,
    description: []const u8,
    status: Status,
    /// Short note about the system interface the real implementation will use.
    backend: []const u8,
    /// Embedded PNG, tinted with the tool's theme colour at runtime.
    icon: []const u8,
    color: ColorRole,
};

pub fn color(cfg: config.Config, role: ColorRole) render.Color {
    return switch (role) {
        .accent => cfg.accent,
        .dark_accent => cfg.dark_accent,
        .detail_1 => cfg.detail_1,
        .detail_2 => cfg.detail_2,
        .warm_1 => cfg.warm_1,
        .warm_2 => cfg.warm_2,
    };
}

pub const all = [_]Tool{
    .{
        .id = "launch",
        .name = "Application Launcher",
        .description = "Search and open .desktop applications.",
        .status = .available,
        .backend = ".desktop entries, with the shared wl_shm renderer.",
        .icon = @embedFile("icons/rocket.png"),
        .color = .accent,
    },
    .{
        .id = "audio",
        .name = "Audio",
        .description = "Output volume, input level and default devices.",
        .status = .available,
        .backend = "PulseAudio native protocol over the user socket.",
        .icon = @embedFile("icons/volume-high.png"),
        .color = .warm_2,
    },
    .{
        .id = "bluetooth",
        .name = "Bluetooth",
        .description = "Adapters, pairing and connected devices.",
        .status = .coming_soon,
        .backend = "BlueZ over the system D-Bus, plus rfkill/sysfs state.",
        .icon = @embedFile("icons/bluetooth.png"),
        .color = .detail_2,
    },
    .{
        .id = "wifi",
        .name = "Wi-Fi",
        .description = "Scan, connect and inspect wireless networks.",
        .status = .coming_soon,
        .backend = "nl80211 generic netlink, with a wpa_supplicant control socket.",
        .icon = @embedFile("icons/wifi.png"),
        .color = .detail_1,
    },
    .{
        .id = "power",
        .name = "Power",
        .description = "Battery, power profiles, suspend and session actions.",
        .status = .coming_soon,
        .backend = "sysfs power_supply/platform_profile and logind over D-Bus.",
        .icon = @embedFile("icons/power-off.png"),
        .color = .warm_1,
    },
};

pub fn find(id: []const u8) ?*const Tool {
    for (&all) |*tool| {
        if (std.mem.eql(u8, tool.id, id)) return tool;
    }
    return null;
}

test "tool ids are unique and non-empty" {
    for (all, 0..) |tool, i| {
        try std.testing.expect(tool.id.len > 0);
        for (all[i + 1 ..]) |other| {
            try std.testing.expect(!std.mem.eql(u8, tool.id, other.id));
        }
    }
}

test "find returns the registry entry" {
    const launch = find("launch") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(Status.available, launch.status);

    const audio = find("audio") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("Audio", audio.name);

    try std.testing.expect(find("teleport") == null);
}
