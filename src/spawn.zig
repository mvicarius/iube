//! Process spawning helpers shared by the UI views.

const std = @import("std");

/// Start another iube command from the running binary. The control panel uses
/// this to hand off to `iube launch`, `iube audio`, and so on, then exits so the
/// selected path starts with only its own work to do.
pub fn spawnSelf(io: std.Io, arg: []const u8) !void {
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const exe_len = std.Io.Dir.readLinkAbsolute(io, "/proc/self/exe", &path_buffer) catch null;
    const exe: []const u8 = if (exe_len) |len| path_buffer[0..len] else "iube";

    const argv = [_][]const u8{ exe, arg };
    _ = try std.process.spawn(io, .{
        .argv = &argv,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
}
