//! Registry of the tools exposed by the iube control panel.
//!
//! The panel is deliberately data-driven: adding a tool here makes it appear in
//! `iube`; every entry needs a matching view branch in `main.zig`.

const std = @import("std");

pub const Tool = struct {
    /// Command-line name: `iube <id>`.
    id: []const u8,
    name: []const u8,
    description: []const u8,
    /// Short note about the system interface the real implementation will use.
    backend: []const u8,
    /// Embedded PNG, tinted with the panel's icon gradient at runtime.
    icon: []const u8,
};

pub const all = [_]Tool{
    .{
        .id = "launch",
        .name = "Application Launcher",
        .description = "Search and open .desktop applications.",
        .backend = ".desktop entries, with the shared wl_shm renderer.",
        .icon = @embedFile("icons/rocket.png"),
    },
    .{
        .id = "audio",
        .name = "Audio",
        .description = "Output volume, input level and default devices.",
        .backend = "PulseAudio native protocol over the user socket.",
        .icon = @embedFile("icons/volume-high.png"),
    },
    .{
        .id = "bluetooth",
        .name = "Bluetooth",
        .description = "Adapter power, discovery and connected devices.",
        .backend = "BlueZ over the system D-Bus.",
        .icon = @embedFile("icons/bluetooth.png"),
    },
    .{
        .id = "wifi",
        .name = "Wi-Fi",
        .description = "Scan, connect and inspect wireless networks.",
        .backend = "NetworkManager over the system D-Bus.",
        .icon = @embedFile("icons/wifi.png"),
    },
    .{
        .id = "power",
        .name = "Power",
        .description = "Battery, power profiles, suspend and session actions.",
        .backend = "sysfs power_supply/platform_profile and logind over D-Bus.",
        .icon = @embedFile("icons/power-off.png"),
    },
    .{
        .id = "brightness",
        .name = "Brightness",
        .description = "Backlight level and device selection.",
        .backend = "sysfs /sys/class/backlight and logind SetBrightness over D-Bus.",
        .icon = @embedFile("icons/sun.png"),
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
    try std.testing.expectEqualStrings("launch", launch.id);

    const audio = find("audio") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("Audio", audio.name);

    try std.testing.expect(find("teleport") == null);
}
