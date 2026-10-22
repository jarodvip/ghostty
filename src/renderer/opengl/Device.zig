//! The OpenGL device context.
//!
//! On Linux this holds the EGL display and config used to create EGL
//! contexts, each corresponding to a surface, its renderer object and
//! its render thread.
//!
//! On Windows there is no EGL/dma-buf, so the device owns a hidden WGL
//! window (an HDC). Each surface renderer creates its own WGL context
//! on that HDC, mirroring the EGL context-per-surface design.
//!
//! TODO: If there's a way to prefer certain devices like in
//! Vulkan or Metal we should do it here.
const Device = @This();

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const gl = @import("opengl");
const egl = gl.egl;
const wgl = @import("wgl.zig");

const log = std.log.scoped(.opengl);

/// Options used when creating the OpenGL device.
pub const Options = struct {
    /// Render with the provided EGL display.
    /// Caller is responsible for managing the lifetime of the display.
    /// The default EGL display will be used when null. (Linux only.)
    display: ?*egl.Display = null,
};

/// The implementation-specific state.
const Impl = union(enum) {
    /// Linux: EGL display + config.
    egl: struct {
        display: *egl.Display,
        config: *egl.Config,
    },

    /// Windows: hidden window providing an HDC for WGL contexts.
    wgl: struct {
        window: *wgl.Window,
    },
};

/// A rendering context for a surface, either an EGL context or a WGL
/// context depending on the platform.
pub const Context = union(enum) {
    egl: *egl.Context,
    wgl: wgl.Context,
};

impl: Impl,

pub fn init(alloc: Allocator, options: Options) !*Device {
    const self = try alloc.create(Device);
    errdefer alloc.destroy(self);

    if (comptime builtin.target.os.tag == .windows) {
        // Windows: create a hidden window that provides an HDC.
        const window = try wgl.Window.create(alloc);
        self.* = .{ .impl = .{ .wgl = .{ .window = window } } };
        return self;
    }

    // Linux (and other non-Windows): EGL.
    try egl.load();

    const egl_display = options.display orelse egl.Display.initPlatform(
        egl.c.EGL_PLATFORM_SURFACELESS_MESA,
        egl.c.EGL_DEFAULT_DISPLAY,
        null,
    ) catch |err| {
        if (err == error.BadParameter) logUnsupportedPlatform();
        return err;
    };

    log.info("EGL vendor={s}", .{egl_display.queryString(.vendor) orelse "(unknown)"});
    log.info("EGL extensions={s}", .{egl_display.queryString(.extensions) orelse "(unknown)"});

    // Choose a config. We need a config that is renderable with
    // OpenGL and a RGBA8 color buffer.
    const config = egl.Config.choose(egl_display, &.{
        egl.c.EGL_SURFACE_TYPE,    0,
        egl.c.EGL_RENDERABLE_TYPE, egl.c.EGL_OPENGL_BIT,
        egl.c.EGL_RED_SIZE,        8,
        egl.c.EGL_GREEN_SIZE,      8,
        egl.c.EGL_BLUE_SIZE,       8,
        egl.c.EGL_ALPHA_SIZE,      8,
    }) catch |err| {
        log.warn("failed to choose config err={}", .{err});
        return err;
    };

    self.* = .{
        .impl = .{ .egl = .{ .display = egl_display, .config = config } },
    };
    return self;
}

/// Create a rendering context for a surface.
pub fn createContext(self: *const Device, alloc: Allocator) !Context {
    if (comptime builtin.target.os.tag == .windows) {
        // Windows: WGL context on the device's hidden window HDC.
        const context = try wgl.Context.create(self.impl.wgl.window.hdc);
        _ = alloc;
        return .{ .wgl = context };
    }

    // Linux: EGL context.
    const e = &self.impl.egl;
    const context = try egl.Context.create(e.display, e.config, null, &.{
        egl.c.EGL_CONTEXT_MAJOR_VERSION,       OpenGL_MIN_VERSION_MAJOR,
        egl.c.EGL_CONTEXT_MINOR_VERSION,       OpenGL_MIN_VERSION_MINOR,
        egl.c.EGL_CONTEXT_OPENGL_PROFILE_MASK, egl.c.EGL_CONTEXT_OPENGL_CORE_PROFILE_BIT,
    });
    errdefer context.destroy(e.display) catch {};
    _ = alloc;
    return .{ .egl = context };
}

/// Destroy a rendering context created by `createContext`.
pub fn destroyContext(self: *const Device, context: Context) void {
    if (comptime builtin.target.os.tag == .windows) {
        switch (context) {
            .wgl => |*ctx| ctx.destroy(),
            .egl => unreachable,
        }
        return;
    }

    const e = &self.impl.egl;
    switch (context) {
        .egl => |ctx| ctx.destroy(e.display) catch {},
        .wgl => unreachable,
    }
}

/// Make the given context current on the calling thread and (re)load
/// the thread-local GLAD function pointers.
pub fn makeCurrent(self: *const Device, context: Context) !void {
    if (comptime builtin.target.os.tag == .windows) {
        switch (context) {
            .wgl => |*ctx| try ctx.makeCurrent(),
            .egl => unreachable,
        }
        return;
    }

    const e = &self.impl.egl;
    switch (context) {
        .egl => |ctx| try e.display.makeCurrent(null, null, ctx),
        .wgl => unreachable,
    }
}

/// Release the current context from the calling thread.
pub fn releaseCurrent(self: *const Device) void {
    if (comptime builtin.target.os.tag == .windows) {
        wgl.Context.releaseCurrent();
        return;
    }
    self.impl.egl.display.releaseCurrent();
}

/// Returns the EGL/WGL function to use to load GL entry points.
pub fn getProcAddress(name: [*:0]const u8) callconv(.c) ?*const fn () callconv(.c) void {
    switch (builtin.target.os.tag) {
        .windows => return wgl.getProcAddress(name),
        else => return egl.getProcAddress(name),
    }
}

const OpenGL_MIN_VERSION_MAJOR = 4;
const OpenGL_MIN_VERSION_MINOR = 3;

/// The EGL display for Linux. Only valid when the impl is `.egl`.
pub fn display(self: *const Device) *egl.Display {
    return switch (self.impl) {
        .egl => |*e| e.display,
        .wgl => unreachable,
    };
}

pub fn deinit(self: *Device, alloc: std.mem.Allocator) void {
    switch (self.impl) {
        .egl => |*e| {
            // Do not destroy the EGL display as it is externally managed.
            _ = e;
        },
        .wgl => |*w| w.window.destroy(alloc),
    }
    alloc.destroy(self);
}

/// EGL_BAD_PARAMETER from eglGetPlatformDisplay means that no loaded
/// EGL driver supports the surfaceless platform. Most often that is
/// because no driver could be loaded at all, for example because the
/// system's driver needs a newer libc than Ghostty was built against,
/// so say which it is rather than leaving a bare error name.
fn logUnsupportedPlatform() void {
    // With no driver loaded, libglvnd reports no client extensions
    // at all, since every platform comes from a driver.
    const exts = egl.queryClientExtensions() orelse "";
    if (exts.len == 0) {
        log.err("no EGL driver could be loaded; check that a GPU driver " ++
            "is installed and was built against a compatible libc " ++
            "(LD_DEBUG=libs shows why a driver failed to load)", .{});
        return;
    }

    if (!egl.hasExtension(exts, "EGL_MESA_platform_surfaceless")) {
        log.err("the EGL driver does not support EGL_MESA_platform_surfaceless " ++
            "client extensions={s}", .{exts});
        return;
    }

    log.err("the EGL driver rejected the surfaceless platform; " ++
        "client extensions={s}", .{exts});
}
