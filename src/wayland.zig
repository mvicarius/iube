//! Minimal Wayland client: shared-memory surfaces, keyboard/pointer input and
//! a layer-shell overlay.
//!
//! The protocol bindings for wlr-layer-shell and cursor-shape are generated C
//! headers checked into `src/protocol`, so the only build-time libraries are
//! libwayland-client and libxkbcommon.
//!
//! A compositor that advertises `zwlr_layer_shell_v1` is required: core
//! Wayland has no portable way to request a floating, centred overlay.

const std = @import("std");

pub const c = @import("c");

const default_width = 640;
const default_height = 360;

pub const Modifiers = packed struct {
    ctrl: bool = false,
    alt: bool = false,
    shift: bool = false,
    super: bool = false,
};

pub const Key = struct {
    keysym: u32,
    text: [8]u8 = @splat(0),
    text_len: u8 = 0,
    mods: Modifiers = .{},
    pressed: bool = true,
};

pub const Event = union(enum) {
    configure: void,
    redraw: void,
    close: void,
    key: Key,
    keyboard_leave: void,
    pointer_enter: struct { x: f32, y: f32 },
    pointer_leave: void,
    pointer_motion: struct { x: f32, y: f32 },
    pointer_button: struct { x: f32, y: f32, button: u32, pressed: bool },
    pointer_axis: struct { delta: f32 },
    repeat_info: struct { rate: i32, delay: i32 },
};

pub const Frame = struct {
    index: usize,
    pixels: []u32,
    width: u32,
    height: u32,
};

const ShmBuffer = struct {
    client: *Client,
    wl_buffer: *c.wl_buffer,
    data: []align(std.heap.page_size_min) u8,
    width: u32,
    height: u32,
    stride: u32,
    busy: bool = false,
};

const listeners = struct {
    var registry: c.wl_registry_listener = undefined;
    var shm: c.wl_shm_listener = undefined;
    var buffer: c.wl_buffer_listener = undefined;
    var seat: c.wl_seat_listener = undefined;
    var keyboard: c.wl_keyboard_listener = undefined;
    var pointer: c.wl_pointer_listener = undefined;
    var surface: c.wl_surface_listener = undefined;
    var layer_surface: c.zwlr_layer_surface_v1_listener = undefined;
    var initialized = false;
};

pub const Client = struct {
    gpa: std.mem.Allocator,
    display: *c.wl_display,
    registry: *c.wl_registry,

    compositor: ?*c.wl_compositor = null,
    compositor_version: u32 = 0,
    shm: ?*c.wl_shm = null,
    seat: ?*c.wl_seat = null,
    seat_version: u32 = 0,
    layer_shell: ?*c.zwlr_layer_shell_v1 = null,
    cursor_manager: ?*c.wp_cursor_shape_manager_v1 = null,

    keyboard: ?*c.wl_keyboard = null,
    pointer: ?*c.wl_pointer = null,
    cursor_device: ?*c.wp_cursor_shape_device_v1 = null,
    pointer_serial: u32 = 0,
    pointer_shape: u32 = 0,

    surface: ?*c.wl_surface = null,
    layer_surface: ?*c.zwlr_layer_surface_v1 = null,

    logical_width: u32 = default_width,
    logical_height: u32 = default_height,
    scale: u32 = 1,
    configured: bool = false,

    buffers: [2]ShmBuffer = undefined,
    buffers_valid: [2]bool = .{ false, false },
    buffer_width: u32 = 0,
    buffer_height: u32 = 0,
    needs_frame: bool = false,
    retired_memory: std.ArrayList([]align(std.heap.page_size_min) u8) = .empty,

    events: std.ArrayList(Event) = .empty,

    xkb_context: ?*c.xkb_context = null,
    xkb_keymap: ?*c.xkb_keymap = null,
    xkb_state: ?*c.xkb_state = null,

    pub fn init(self: *Client, gpa: std.mem.Allocator) !void {
        initListeners();

        const display = c.wl_display_connect(null) orelse return error.WaylandConnect;
        const registry = c.wl_display_get_registry(display) orelse {
            c.wl_display_disconnect(display);
            return error.WaylandRegistry;
        };

        self.* = .{
            .gpa = gpa,
            .display = display,
            .registry = registry,
        };
        errdefer self.deinit();

        // Create the xkb context before the initial roundtrip: the seat
        // capabilities event can arrive in the same batch as the keymap.
        self.xkb_context = c.xkb_context_new(c.XKB_CONTEXT_NO_FLAGS);
        if (self.xkb_context == null) return error.NoXkbContext;
        self.installDefaultKeymap();

        _ = c.wl_registry_add_listener(registry, &listeners.registry, self);
        if (c.wl_display_roundtrip(display) < 0) return error.WaylandRoundtrip;

        if (self.compositor == null or self.shm == null) return error.MissingCompositor;
        if (self.seat == null) return error.MissingSeat;
        if (self.layer_shell == null) return error.LayerShellUnavailable;
    }

    pub fn deinit(self: *Client) void {
        if (self.keyboard) |keyboard| {
            if (self.seat_version >= 3) c.wl_keyboard_release(keyboard);
        }
        if (self.pointer) |pointer| {
            if (self.seat_version >= 3) c.wl_pointer_release(pointer);
        }
        if (self.cursor_device) |device| c.wp_cursor_shape_device_v1_destroy(device);
        if (self.cursor_manager) |manager| c.wp_cursor_shape_manager_v1_destroy(manager);
        if (self.seat) |seat| {
            if (self.seat_version >= 5) c.wl_seat_release(seat);
        }

        if (self.layer_surface) |layer_surface| c.zwlr_layer_surface_v1_destroy(layer_surface);
        if (self.surface) |surface| c.wl_surface_destroy(surface);

        for (0..self.buffers.len) |i| {
            if (!self.buffers_valid[i]) continue;
            const buffer = &self.buffers[i];
            c.wl_buffer_destroy(buffer.wl_buffer);
            std.posix.munmap(buffer.data);
            self.buffers_valid[i] = false;
        }
        for (self.retired_memory.items) |memory| std.posix.munmap(memory);
        self.retired_memory.deinit(self.gpa);

        if (self.shm) |shm| c.wl_shm_destroy(shm);
        if (self.compositor) |compositor| c.wl_compositor_destroy(compositor);
        if (self.layer_shell) |layer_shell| c.zwlr_layer_shell_v1_destroy(layer_shell);

        if (self.xkb_state) |state| c.xkb_state_unref(state);
        if (self.xkb_keymap) |keymap| c.xkb_keymap_unref(keymap);
        if (self.xkb_context) |context| c.xkb_context_unref(context);

        self.events.deinit(self.gpa);
        c.wl_registry_destroy(self.registry);
        c.wl_display_disconnect(self.display);
    }

    /// Request the initial surface size in logical pixels. Call before
    /// `createWindow`; the compositor may still adjust it in its configure
    /// event, in which case `logical_width`/`logical_height` are updated there.
    pub fn setWindowSize(self: *Client, width: u32, height: u32) void {
        if (width != 0) self.logical_width = width;
        if (height != 0) self.logical_height = height;
    }

    pub fn createWindow(self: *Client) !void {
        const layer_shell = self.layer_shell orelse return error.LayerShellUnavailable;

        const surface = c.wl_compositor_create_surface(self.compositor.?) orelse return error.NoSurface;
        self.surface = surface;
        _ = c.wl_surface_add_listener(surface, &listeners.surface, self);

        const layer_surface = c.zwlr_layer_shell_v1_get_layer_surface(
            layer_shell,
            surface,
            null,
            c.ZWLR_LAYER_SHELL_V1_LAYER_OVERLAY,
            "iube",
        ) orelse return error.NoLayerSurface;
        self.layer_surface = layer_surface;
        _ = c.zwlr_layer_surface_v1_add_listener(layer_surface, &listeners.layer_surface, self);

        c.zwlr_layer_surface_v1_set_size(layer_surface, self.logical_width, self.logical_height);
        c.zwlr_layer_surface_v1_set_anchor(layer_surface, 0);
        c.zwlr_layer_surface_v1_set_exclusive_zone(layer_surface, 0);
        c.zwlr_layer_surface_v1_set_margin(layer_surface, 0, 0, 0, 0);
        c.zwlr_layer_surface_v1_set_keyboard_interactivity(
            layer_surface,
            c.ZWLR_LAYER_SURFACE_V1_KEYBOARD_INTERACTIVITY_EXCLUSIVE,
        );
        c.wl_surface_commit(surface);

        _ = c.wl_display_flush(self.display);
    }

    pub fn poll(self: *Client, timeout_ms: i32) !void {
        const fd = c.wl_display_get_fd(self.display);

        while (c.wl_display_prepare_read(self.display) != 0) {
            if (c.wl_display_dispatch_pending(self.display) < 0) return error.WaylandDispatch;
        }

        _ = c.wl_display_flush(self.display);

        var poll_fds = [_]std.posix.pollfd{.{
            .fd = fd,
            .events = std.posix.POLL.IN,
            .revents = 0,
        }};
        const ready = std.posix.poll(&poll_fds, timeout_ms) catch |err| {
            c.wl_display_cancel_read(self.display);
            return err;
        };

        if (ready > 0 and (poll_fds[0].revents & (std.posix.POLL.IN | std.posix.POLL.HUP | std.posix.POLL.ERR)) != 0) {
            if (c.wl_display_read_events(self.display) < 0) return error.WaylandRead;
        } else {
            c.wl_display_cancel_read(self.display);
        }

        if (c.wl_display_dispatch_pending(self.display) < 0) return error.WaylandDispatch;
    }

    pub fn nextEvent(self: *Client) ?Event {
        if (self.events.items.len == 0) return null;
        return self.events.orderedRemove(0);
    }

    pub fn beginFrame(self: *Client) ?Frame {
        if (!self.configured) return null;
        self.ensureBuffers() catch |err| {
            std.log.err("failed to create Wayland buffer: {s}", .{@errorName(err)});
            return null;
        };

        for (0..self.buffers.len) |i| {
            if (!self.buffers_valid[i]) continue;
            const buffer = &self.buffers[i];
            if (buffer.busy) continue;

            const count = @as(usize, buffer.width) * buffer.height;
            const pixels = @as([*]u32, @ptrCast(@alignCast(buffer.data.ptr)))[0..count];
            return .{
                .index = i,
                .pixels = pixels,
                .width = buffer.width,
                .height = buffer.height,
            };
        }
        self.needs_frame = true;
        return null;
    }

    pub fn submitFrame(self: *Client, frame: Frame) void {
        if (!self.buffers_valid[frame.index]) return;
        const buffer = &self.buffers[frame.index];
        const surface = self.surface orelse return;

        buffer.busy = true;
        c.wl_surface_attach(surface, buffer.wl_buffer, 0, 0);
        if (self.compositor_version >= 4) {
            c.wl_surface_damage_buffer(surface, 0, 0, @intCast(frame.width), @intCast(frame.height));
        } else {
            c.wl_surface_damage(surface, 0, 0, @intCast(frame.width), @intCast(frame.height));
        }
        c.wl_surface_commit(surface);
        _ = c.wl_display_flush(self.display);
    }

    fn ensureBuffers(self: *Client) !void {
        if (!self.configured) return;

        const max_dimension = 8192;
        const width_wide = @as(u64, self.logical_width) * self.scale;
        const height_wide = @as(u64, self.logical_height) * self.scale;
        if (width_wide == 0 or height_wide == 0) return;
        if (width_wide > max_dimension or height_wide > max_dimension) {
            return error.BufferTooLarge;
        }
        const width: u32 = @intCast(width_wide);
        const height: u32 = @intCast(height_wide);

        if (self.buffers_valid[0] and self.buffer_width == width and self.buffer_height == height) return;

        self.retireBuffers();

        for (0..self.buffers.len) |i| {
            try self.createBufferInto(i, width, height);
        }
        self.buffer_width = width;
        self.buffer_height = height;

        if (self.compositor_version >= 3) {
            c.wl_surface_set_buffer_scale(self.surface.?, @intCast(self.scale));
        }
    }

    fn retireBuffers(self: *Client) void {
        for (0..self.buffers.len) |i| {
            if (!self.buffers_valid[i]) continue;
            const buffer = &self.buffers[i];
            c.wl_buffer_destroy(buffer.wl_buffer);
            self.retired_memory.append(self.gpa, buffer.data) catch {
                std.posix.munmap(buffer.data);
            };
            self.buffers_valid[i] = false;
        }
        self.buffer_width = 0;
        self.buffer_height = 0;
    }

    fn createBufferInto(self: *Client, index: usize, width: u32, height: u32) !void {
        const stride_wide = @as(u64, width) * 4;
        const size_wide = stride_wide * height;
        if (stride_wide > std.math.maxInt(i32) or size_wide > std.math.maxInt(i32)) {
            return error.BufferTooLarge;
        }
        const stride: u32 = @intCast(stride_wide);
        const size: usize = @intCast(size_wide);

        const fd = try std.posix.memfd_create("iube", 0);
        defer _ = std.posix.system.close(fd);

        if (std.c.ftruncate(fd, @intCast(size)) != 0) return error.TruncateFailed;

        const data = try std.posix.mmap(
            null,
            size,
            .{ .READ = true, .WRITE = true },
            .{ .TYPE = .SHARED },
            fd,
            0,
        );
        errdefer std.posix.munmap(data);

        const pool = c.wl_shm_create_pool(self.shm.?, fd, @intCast(size)) orelse return error.NoShmPool;
        defer c.wl_shm_pool_destroy(pool);

        const wl_buffer = c.wl_shm_pool_create_buffer(
            pool,
            0,
            @intCast(width),
            @intCast(height),
            @intCast(stride),
            c.WL_SHM_FORMAT_ARGB8888,
        ) orelse return error.NoShmBuffer;

        self.buffers[index] = .{
            .client = self,
            .wl_buffer = wl_buffer,
            .data = data,
            .width = width,
            .height = height,
            .stride = stride,
        };
        self.buffers_valid[index] = true;
        _ = c.wl_buffer_add_listener(wl_buffer, &listeners.buffer, &self.buffers[index]);
    }

    fn push(self: *Client, event: Event) void {
        self.events.append(self.gpa, event) catch {};
    }

    fn currentModifiers(self: *Client) Modifiers {
        const state = self.xkb_state orelse return .{};
        return .{
            .ctrl = c.xkb_state_mod_name_is_active(state, c.XKB_MOD_NAME_CTRL, c.XKB_STATE_MODS_DEPRESSED) > 0,
            .alt = c.xkb_state_mod_name_is_active(state, c.XKB_MOD_NAME_ALT, c.XKB_STATE_MODS_DEPRESSED) > 0,
            .shift = c.xkb_state_mod_name_is_active(state, c.XKB_MOD_NAME_SHIFT, c.XKB_STATE_MODS_DEPRESSED) > 0,
            .super = c.xkb_state_mod_name_is_active(state, c.XKB_MOD_NAME_LOGO, c.XKB_STATE_MODS_DEPRESSED) > 0,
        };
    }

    pub fn setPointerShape(self: *Client, shape: u32) void {
        const device = self.cursor_device orelse return;
        if (self.pointer_shape == shape and shape != 0) return;
        self.pointer_shape = shape;
        c.wp_cursor_shape_device_v1_set_shape(device, self.pointer_serial, shape);
    }

    fn installKeymap(self: *Client, keymap: *c.xkb_keymap) void {
        const state = c.xkb_state_new(keymap) orelse {
            c.xkb_keymap_unref(keymap);
            return;
        };
        if (self.xkb_state) |old_state| c.xkb_state_unref(old_state);
        if (self.xkb_keymap) |old_keymap| c.xkb_keymap_unref(old_keymap);
        self.xkb_keymap = keymap;
        self.xkb_state = state;
    }

    /// A US keymap is only a safety net for compositors that fail to send
    /// (or whose keymap fails to parse) the real keymap.
    fn installDefaultKeymap(self: *Client) void {
        const context = self.xkb_context orelse return;
        const names = c.struct_xkb_rule_names{ .layout = "us" };
        const keymap = c.xkb_keymap_new_from_names(context, &names, c.XKB_KEYMAP_COMPILE_NO_FLAGS) orelse return;
        self.installKeymap(keymap);
    }
};

fn clientFrom(data: ?*anyopaque) *Client {
    return @ptrCast(@alignCast(data.?));
}

fn interfaceEql(interface: [*:0]const u8, name: []const u8) bool {
    return std.mem.eql(u8, std.mem.span(interface), name);
}

fn initListeners() void {
    if (listeners.initialized) return;
    listeners.initialized = true;

    listeners.registry = std.mem.zeroes(c.wl_registry_listener);
    listeners.registry.global = registryGlobal;
    listeners.registry.global_remove = registryGlobalRemove;

    listeners.shm = std.mem.zeroes(c.wl_shm_listener);
    listeners.shm.format = shmFormat;

    listeners.buffer = std.mem.zeroes(c.wl_buffer_listener);
    listeners.buffer.release = bufferRelease;

    listeners.seat = std.mem.zeroes(c.wl_seat_listener);
    listeners.seat.capabilities = seatCapabilities;
    listeners.seat.name = seatName;

    listeners.keyboard = std.mem.zeroes(c.wl_keyboard_listener);
    listeners.keyboard.keymap = keyboardKeymap;
    listeners.keyboard.enter = keyboardEnter;
    listeners.keyboard.leave = keyboardLeave;
    listeners.keyboard.key = keyboardKey;
    listeners.keyboard.modifiers = keyboardModifiers;
    listeners.keyboard.repeat_info = keyboardRepeatInfo;

    listeners.pointer = std.mem.zeroes(c.wl_pointer_listener);
    listeners.pointer.enter = pointerEnter;
    listeners.pointer.leave = pointerLeave;
    listeners.pointer.motion = pointerMotion;
    listeners.pointer.button = pointerButton;
    listeners.pointer.axis = pointerAxis;
    listeners.pointer.frame = pointerFrame;
    listeners.pointer.axis_source = pointerAxisSource;
    listeners.pointer.axis_stop = pointerAxisStop;
    listeners.pointer.axis_discrete = pointerAxisDiscrete;
    listeners.pointer.axis_value120 = pointerAxisValue120;
    listeners.pointer.axis_relative_direction = pointerAxisRelativeDirection;
    listeners.pointer.warp = pointerWarp;

    listeners.surface = std.mem.zeroes(c.wl_surface_listener);
    listeners.surface.enter = surfaceEnter;
    listeners.surface.leave = surfaceLeave;
    listeners.surface.preferred_buffer_scale = surfacePreferredScale;
    listeners.surface.preferred_buffer_transform = surfacePreferredTransform;

    listeners.layer_surface = std.mem.zeroes(c.zwlr_layer_surface_v1_listener);
    listeners.layer_surface.configure = layerSurfaceConfigure;
    listeners.layer_surface.closed = layerSurfaceClosed;
}

fn registryGlobal(
    data: ?*anyopaque,
    registry: ?*c.wl_registry,
    name: u32,
    interface: ?[*:0]const u8,
    version: u32,
) callconv(.c) void {
    const self = clientFrom(data);
    const iface = interface orelse return;

    if (interfaceEql(iface, "wl_compositor")) {
        const v = @min(version, 6);
        self.compositor_version = v;
        self.compositor = @ptrCast(c.wl_registry_bind(registry.?, name, &c.wl_compositor_interface, v));
    } else if (interfaceEql(iface, "wl_shm")) {
        self.shm = @ptrCast(c.wl_registry_bind(registry.?, name, &c.wl_shm_interface, 1));
        if (self.shm) |shm| _ = c.wl_shm_add_listener(shm, &listeners.shm, self);
    } else if (interfaceEql(iface, "wl_seat")) {
        const v = @min(version, 7);
        self.seat_version = v;
        self.seat = @ptrCast(c.wl_registry_bind(registry.?, name, &c.wl_seat_interface, v));
        if (self.seat) |seat| _ = c.wl_seat_add_listener(seat, &listeners.seat, self);
    } else if (interfaceEql(iface, "zwlr_layer_shell_v1")) {
        const v = @min(version, 4);
        self.layer_shell = @ptrCast(c.wl_registry_bind(registry.?, name, &c.zwlr_layer_shell_v1_interface, v));
    } else if (interfaceEql(iface, "wp_cursor_shape_manager_v1")) {
        const v = @min(version, 2);
        self.cursor_manager = @ptrCast(c.wl_registry_bind(registry.?, name, &c.wp_cursor_shape_manager_v1_interface, v));
        if (self.cursor_manager) |manager| {
            if (self.pointer) |pointer| {
                if (self.cursor_device == null) {
                    self.cursor_device = c.wp_cursor_shape_manager_v1_get_pointer(manager, pointer);
                    if (self.pointer_serial != 0) {
                        self.setPointerShape(@intCast(c.WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_DEFAULT));
                    }
                }
            }
        }
    }
}

fn registryGlobalRemove(data: ?*anyopaque, registry: ?*c.wl_registry, name: u32) callconv(.c) void {
    _ = data;
    _ = registry;
    _ = name;
}

fn shmFormat(data: ?*anyopaque, shm: ?*c.wl_shm, format: u32) callconv(.c) void {
    _ = data;
    _ = shm;
    _ = format;
}

fn bufferRelease(data: ?*anyopaque, buffer: ?*c.wl_buffer) callconv(.c) void {
    _ = buffer;
    const shm_buffer: *ShmBuffer = @ptrCast(@alignCast(data.?));
    shm_buffer.busy = false;
    if (shm_buffer.client.needs_frame) {
        shm_buffer.client.needs_frame = false;
        shm_buffer.client.push(.{ .redraw = {} });
    }
}

fn seatCapabilities(data: ?*anyopaque, seat: ?*c.wl_seat, capabilities: u32) callconv(.c) void {
    const self = clientFrom(data);

    if ((capabilities & @as(u32, c.WL_SEAT_CAPABILITY_KEYBOARD)) != 0) {
        if (self.keyboard == null) {
            self.keyboard = c.wl_seat_get_keyboard(seat.?);
            if (self.keyboard) |keyboard| _ = c.wl_keyboard_add_listener(keyboard, &listeners.keyboard, self);
        }
    } else if (self.keyboard) |keyboard| {
        if (self.seat_version >= 3) c.wl_keyboard_release(keyboard);
        self.keyboard = null;
    }

    if ((capabilities & @as(u32, c.WL_SEAT_CAPABILITY_POINTER)) != 0) {
        if (self.pointer == null) {
            self.pointer = c.wl_seat_get_pointer(seat.?);
            if (self.pointer) |pointer| _ = c.wl_pointer_add_listener(pointer, &listeners.pointer, self);
        }
    } else if (self.pointer) |pointer| {
        if (self.seat_version >= 3) c.wl_pointer_release(pointer);
        self.pointer = null;
    }
}

fn seatName(data: ?*anyopaque, seat: ?*c.wl_seat, name: ?[*:0]const u8) callconv(.c) void {
    _ = data;
    _ = seat;
    _ = name;
}

fn keyboardKeymap(
    data: ?*anyopaque,
    keyboard: ?*c.wl_keyboard,
    format: u32,
    fd: c_int,
    size: u32,
) callconv(.c) void {
    _ = keyboard;
    const self = clientFrom(data);
    defer _ = std.posix.system.close(fd);

    if (format != c.WL_KEYBOARD_KEYMAP_FORMAT_XKB_V1) return;
    if (self.xkb_context == null or size == 0) return;

    const map = std.posix.mmap(
        null,
        size,
        .{ .READ = true },
        .{ .TYPE = .PRIVATE },
        fd,
        0,
    ) catch return;
    defer std.posix.munmap(map);

    const text: [*:0]const u8 = @ptrCast(map.ptr);
    const keymap = c.xkb_keymap_new_from_string(
        self.xkb_context.?,
        text,
        c.XKB_KEYMAP_FORMAT_TEXT_V1,
        c.XKB_KEYMAP_COMPILE_NO_FLAGS,
    ) orelse {
        self.installDefaultKeymap();
        return;
    };

    self.installKeymap(keymap);
}

fn keyboardEnter(
    data: ?*anyopaque,
    keyboard: ?*c.wl_keyboard,
    serial: u32,
    surface: ?*c.wl_surface,
    keys: ?*c.wl_array,
) callconv(.c) void {
    _ = data;
    _ = keyboard;
    _ = serial;
    _ = surface;
    _ = keys;
}

fn keyboardLeave(
    data: ?*anyopaque,
    keyboard: ?*c.wl_keyboard,
    serial: u32,
    surface: ?*c.wl_surface,
) callconv(.c) void {
    _ = keyboard;
    _ = serial;
    _ = surface;
    const self = clientFrom(data);
    self.push(.{ .keyboard_leave = {} });
}

fn keyboardKey(
    data: ?*anyopaque,
    keyboard: ?*c.wl_keyboard,
    serial: u32,
    time: u32,
    key: u32,
    state: u32,
) callconv(.c) void {
    _ = keyboard;
    _ = serial;
    _ = time;

    const self = clientFrom(data);
    const xkb_state = self.xkb_state orelse return;

    var event = Key{
        .keysym = 0,
        .pressed = state == c.WL_KEYBOARD_KEY_STATE_PRESSED,
        .mods = self.currentModifiers(),
    };

    if (event.pressed) {
        var buffer: [8]u8 = undefined;
        const len = c.xkb_state_key_get_utf8(xkb_state, key + 8, &buffer, buffer.len);
        if (len > 0) {
            const n: usize = @min(@as(usize, @intCast(len)), buffer.len);
            @memcpy(event.text[0..n], buffer[0..n]);
            event.text_len = @intCast(n);
        }
        const sym = c.xkb_state_key_get_one_sym(xkb_state, key + 8);
        event.keysym = @intCast(sym);
    } else {
        // Releases still carry the keysym so the repeat timer can stop.
        const sym = c.xkb_state_key_get_one_sym(xkb_state, key + 8);
        event.keysym = @intCast(sym);
        event.text_len = 0;
    }

    self.push(.{ .key = event });
}

fn keyboardModifiers(
    data: ?*anyopaque,
    keyboard: ?*c.wl_keyboard,
    serial: u32,
    depressed: u32,
    latched: u32,
    locked: u32,
    group: u32,
) callconv(.c) void {
    _ = keyboard;
    _ = serial;
    const self = clientFrom(data);
    const state = self.xkb_state orelse return;
    _ = c.xkb_state_update_mask(state, depressed, latched, locked, 0, 0, group);
}

fn keyboardRepeatInfo(data: ?*anyopaque, keyboard: ?*c.wl_keyboard, rate: i32, delay: i32) callconv(.c) void {
    _ = keyboard;
    const self = clientFrom(data);
    self.push(.{ .repeat_info = .{ .rate = rate, .delay = delay } });
}

fn pointerEnter(
    data: ?*anyopaque,
    pointer: ?*c.wl_pointer,
    serial: u32,
    surface: ?*c.wl_surface,
    surface_x: c.wl_fixed_t,
    surface_y: c.wl_fixed_t,
) callconv(.c) void {
    _ = surface;
    const self = clientFrom(data);
    self.pointer_serial = serial;

    if (self.cursor_manager) |manager| {
        if (self.cursor_device == null) {
            self.cursor_device = c.wp_cursor_shape_manager_v1_get_pointer(manager, pointer.?);
        }
    }

    self.push(.{ .pointer_enter = .{ .x = fixedToFloat(surface_x), .y = fixedToFloat(surface_y) } });
}

fn pointerLeave(data: ?*anyopaque, pointer: ?*c.wl_pointer, serial: u32, surface: ?*c.wl_surface) callconv(.c) void {
    _ = pointer;
    _ = serial;
    _ = surface;
    const self = clientFrom(data);
    self.push(.{ .pointer_leave = {} });
}

fn pointerMotion(
    data: ?*anyopaque,
    pointer: ?*c.wl_pointer,
    time: u32,
    surface_x: c.wl_fixed_t,
    surface_y: c.wl_fixed_t,
) callconv(.c) void {
    _ = pointer;
    _ = time;
    const self = clientFrom(data);
    self.push(.{ .pointer_motion = .{ .x = fixedToFloat(surface_x), .y = fixedToFloat(surface_y) } });
}

fn pointerButton(
    data: ?*anyopaque,
    pointer: ?*c.wl_pointer,
    serial: u32,
    time: u32,
    button: u32,
    state: u32,
) callconv(.c) void {
    _ = pointer;
    _ = serial;
    _ = time;
    const self = clientFrom(data);
    self.push(.{
        .pointer_button = .{
            .x = 0,
            .y = 0,
            .button = button,
            .pressed = state == c.WL_POINTER_BUTTON_STATE_PRESSED,
        },
    });
}

fn pointerAxis(
    data: ?*anyopaque,
    pointer: ?*c.wl_pointer,
    time: u32,
    axis: u32,
    value: c.wl_fixed_t,
) callconv(.c) void {
    _ = pointer;
    _ = time;
    if (axis != c.WL_POINTER_AXIS_VERTICAL_SCROLL) return;
    const self = clientFrom(data);
    self.push(.{ .pointer_axis = .{ .delta = fixedToFloat(value) } });
}

fn pointerFrame(data: ?*anyopaque, pointer: ?*c.wl_pointer) callconv(.c) void {
    _ = data;
    _ = pointer;
}

fn pointerAxisSource(data: ?*anyopaque, pointer: ?*c.wl_pointer, axis_source: u32) callconv(.c) void {
    _ = data;
    _ = pointer;
    _ = axis_source;
}

fn pointerAxisStop(data: ?*anyopaque, pointer: ?*c.wl_pointer, time: u32, axis: u32) callconv(.c) void {
    _ = data;
    _ = pointer;
    _ = time;
    _ = axis;
}

fn pointerAxisDiscrete(data: ?*anyopaque, pointer: ?*c.wl_pointer, axis: u32, discrete: i32) callconv(.c) void {
    _ = data;
    _ = pointer;
    _ = axis;
    _ = discrete;
}

fn pointerAxisValue120(data: ?*anyopaque, pointer: ?*c.wl_pointer, axis: u32, value120: i32) callconv(.c) void {
    _ = data;
    _ = pointer;
    _ = axis;
    _ = value120;
}

fn pointerAxisRelativeDirection(data: ?*anyopaque, pointer: ?*c.wl_pointer, axis: u32, direction: u32) callconv(.c) void {
    _ = data;
    _ = pointer;
    _ = axis;
    _ = direction;
}

fn pointerWarp(data: ?*anyopaque, pointer: ?*c.wl_pointer, surface_x: c.wl_fixed_t, surface_y: c.wl_fixed_t) callconv(.c) void {
    _ = data;
    _ = pointer;
    _ = surface_x;
    _ = surface_y;
}

fn surfaceEnter(data: ?*anyopaque, surface: ?*c.wl_surface, output: ?*c.wl_output) callconv(.c) void {
    _ = data;
    _ = surface;
    _ = output;
}

fn surfaceLeave(data: ?*anyopaque, surface: ?*c.wl_surface, output: ?*c.wl_output) callconv(.c) void {
    _ = data;
    _ = surface;
    _ = output;
}

fn surfacePreferredScale(data: ?*anyopaque, surface: ?*c.wl_surface, factor: i32) callconv(.c) void {
    _ = surface;
    const self = clientFrom(data);
    if (factor <= 0) return;
    const scale: u32 = @intCast(factor);
    if (self.scale == scale) return;
    self.scale = scale;
    if (self.configured) {
        self.ensureBuffers() catch |err| {
            std.log.err("failed to resize Wayland buffers: {s}", .{@errorName(err)});
        };
        self.push(.{ .configure = {} });
    }
}

fn surfacePreferredTransform(data: ?*anyopaque, surface: ?*c.wl_surface, transform: u32) callconv(.c) void {
    _ = data;
    _ = surface;
    _ = transform;
}

fn layerSurfaceConfigure(
    data: ?*anyopaque,
    layer_surface: ?*c.zwlr_layer_surface_v1,
    serial: u32,
    width: u32,
    height: u32,
) callconv(.c) void {
    const self = clientFrom(data);
    c.zwlr_layer_surface_v1_ack_configure(layer_surface.?, serial);

    if (width != 0) self.logical_width = width;
    if (height != 0) self.logical_height = height;
    self.configured = true;

    self.ensureBuffers() catch |err| {
        std.log.err("failed to allocate Wayland buffers: {s}", .{@errorName(err)});
    };
    self.push(.{ .configure = {} });
}

fn layerSurfaceClosed(data: ?*anyopaque, layer_surface: ?*c.zwlr_layer_surface_v1) callconv(.c) void {
    _ = layer_surface;
    const self = clientFrom(data);
    self.push(.{ .close = {} });
}

fn fixedToFloat(value: c.wl_fixed_t) f32 {
    return @as(f32, @floatFromInt(value)) / 256.0;
}
