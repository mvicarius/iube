//! Shared Wayland session and event loop.
//!
//! This module intentionally does not know about the launcher, the control
//! panel or any tool view. Each command builds exactly the view it needs and
//! hands it to `run`, which loads the shared config, creates the layer surface
//! and dispatches events. The view is a comptime parameter, so an `iube launch`
//! process never links panel work into its hot path and vice versa.

const std = @import("std");
const wayland = @import("wayland.zig");
const config = @import("config.zig");
const render = @import("render.zig");
const ui = @import("ui.zig");

pub const Session = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    cfg: config.Config,
    metrics: ui.Metrics,
    client: *wayland.Client,

    running: bool = true,
    dirty: bool = true,

    pointer_inside: bool = false,
    pointer_x: f32 = 0,
    pointer_y: f32 = 0,

    last_input_ms: i64 = 0,
    blink_on: bool = true,
    last_key: ?wayland.Key = null,
    repeat_at: ?i64 = null,
    repeat_rate: i32 = 25,
    repeat_delay: i32 = 600,

    pub fn nowMs(self: *const Session) i64 {
        return std.Io.Clock.Timestamp.now(self.io, .awake).raw.toMilliseconds();
    }
};

/// Run a view until it asks to close. `view` must provide:
///
///   windowSize(metrics) ui.WindowSize
///   wantsBlink() bool
///   overTextField(session) bool
///   handleKey(session, key, is_repeat) void
///   pointerMoved(session) void
///   pointerLeft(session) void
///   pointerClick(session) void
///   pointerScroll(session, delta: f32) void
///   draw(session, canvas, now_ms) void
pub fn run(
    io: std.Io,
    gpa: std.mem.Allocator,
    env: config.Env,
    view: anytype,
) !void {
    var client: wayland.Client = undefined;
    client.init(gpa) catch |err| {
        if (err == error.LayerShellUnavailable) {
            std.log.err(
                "iube requires the wlr-layer-shell protocol (zwlr_layer_shell_v1); " ++
                    "this compositor does not advertise it (try Hyprland, Sway, KWin, Wayfire, labwc, ...)",
                .{},
            );
        }
        return err;
    };
    defer client.deinit();

    const cfg = config.load(io, gpa, env);
    const metrics = ui.Metrics.init(cfg);
    const size = view.windowSize(metrics);
    client.setWindowSize(@intCast(size.width), @intCast(size.height));

    var session = Session{
        .gpa = gpa,
        .io = io,
        .cfg = cfg,
        .metrics = metrics,
        .client = &client,
    };
    session.last_input_ms = session.nowMs();

    try client.createWindow();

    while (session.running) {
        const now = session.nowMs();

        var timeout: i64 = 1000;
        if (view.wantsBlink()) {
            timeout = @min(timeout, ui.blink_period_ms - @mod(now, ui.blink_period_ms));
        }
        if (session.repeat_at) |repeat_at| {
            timeout = @min(timeout, repeat_at - now);
        }
        timeout = std.math.clamp(timeout, 0, 1000);

        try client.poll(@intCast(timeout));

        while (client.nextEvent()) |event| {
            handleEvent(&session, view, event);
            if (!session.running) break;
        }
        if (!session.running) break;

        const after = session.nowMs();

        if (@hasDecl(@TypeOf(view.*), "tick")) {
            view.tick(&session);
        }

        if (session.repeat_at) |repeat_at| {
            if (after >= repeat_at) {
                if (session.last_key) |key| {
                    view.handleKey(&session, key, true);
                }
                const interval: i64 = if (session.repeat_rate > 0)
                    @max(1, @divTrunc(1000, session.repeat_rate))
                else
                    1000;
                session.repeat_at = if (session.last_key != null) after + interval else null;
            }
        }

        if (view.wantsBlink()) {
            const blink_now = @mod(after, ui.blink_period_ms * 2) < ui.blink_period_ms;
            if (blink_now != session.blink_on) {
                session.blink_on = blink_now;
                session.dirty = true;
            }
        }

        if (session.dirty) {
            renderFrame(&session, view, after);
            session.dirty = false;
        }
    }
}

fn handleEvent(session: *Session, view: anytype, event: wayland.Event) void {
    switch (event) {
        .configure, .redraw => {
            session.dirty = true;
        },
        .close => {
            session.running = false;
        },
        .key => |key| {
            handleKeyEvent(session, view, key);
        },
        .keyboard_leave => {
            session.last_key = null;
            session.repeat_at = null;
        },
        .pointer_enter => |pointer| {
            session.pointer_inside = true;
            session.pointer_x = pointer.x;
            session.pointer_y = pointer.y;
            view.pointerMoved(session);
            updateCursor(session, view);
        },
        .pointer_leave => {
            session.pointer_inside = false;
            view.pointerLeft(session);
        },
        .pointer_motion => |pointer| {
            session.pointer_inside = true;
            session.pointer_x = pointer.x;
            session.pointer_y = pointer.y;
            view.pointerMoved(session);
            updateCursor(session, view);
        },
        .pointer_button => |button| {
            if (button.pressed and button.button == 0x110) {
                view.pointerClick(session);
            }
        },
        .pointer_axis => |axis| {
            view.pointerScroll(session, axis.delta);
        },
        .repeat_info => |info| {
            session.repeat_rate = info.rate;
            session.repeat_delay = info.delay;
            if (info.rate <= 0) {
                session.last_key = null;
                session.repeat_at = null;
            }
        },
    }
}

fn handleKeyEvent(session: *Session, view: anytype, key: wayland.Key) void {
    if (key.pressed) {
        if (key.keysym == ui.key_escape) {
            session.running = false;
            return;
        }

        view.handleKey(session, key, false);

        session.last_input_ms = session.nowMs();
        session.blink_on = true;

        if (isRepeatable(key)) {
            session.last_key = key;
            session.repeat_at = session.last_input_ms + session.repeat_delay;
        } else {
            session.last_key = null;
            session.repeat_at = null;
        }
    } else if (session.last_key) |last| {
        if (last.keysym == key.keysym) {
            session.last_key = null;
            session.repeat_at = null;
        }
    }
}

fn isRepeatable(key: wayland.Key) bool {
    return ui.keyRepeats(key.keysym, key.text_len);
}

fn updateCursor(session: *Session, view: anytype) void {
    if (!session.pointer_inside) return;
    const shape = if (view.overTextField(session))
        wayland.c.WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_TEXT
    else
        wayland.c.WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_DEFAULT;
    session.client.setPointerShape(@intCast(shape));
}

fn renderFrame(session: *Session, view: anytype, now: i64) void {
    const frame = session.client.beginFrame() orelse return;
    var canvas = render.Canvas.init(frame.pixels, frame.width, frame.height);
    canvas.clear(render.transparent);
    view.draw(session, &canvas, now);
    session.client.submitFrame(frame);
}
