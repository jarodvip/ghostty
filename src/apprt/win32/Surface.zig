//! The apprt surface for the Win32 apprt. Each terminal window is one
//! `Surface` and owns one `CoreSurface` (src/Surface.zig). This file
//! implements the required `apprt.Surface` interface and translates
//! Win32 window messages into core surface callbacks.

const Self = @This();

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const assert = @import("../../quirks.zig").inlineAssert;

const apprt = @import("../../apprt.zig");
const App = @import("App.zig");
const win32 = @import("win32.zig");
const clipboard = @import("clipboard.zig");
const keymap = @import("key.zig");
const configpkg = @import("../../config.zig");
const CoreApp = @import("../../App.zig");
const CoreSurface = @import("../../Surface.zig");
const global = @import("../../global.zig");
const input = @import("../../input.zig");
const renderer = @import("../../renderer.zig");
const terminal = @import("../../terminal/main.zig");
const font = @import("../../font/main.zig");

const log = std.log.scoped(.win32_surface);

/// The app that owns this surface.
app: *App,

/// The Win32 window handle for this surface.
hwnd: win32.HWND,

/// The core surface, once initialized.
core_surface: ?*CoreSurface = null,

/// The title of the window, stored as UTF-8 for `getTitle`.
title: ?[:0]const u8 = null,

/// The content scale (DPI ratio vs the platform's default 96).
content_scale: apprt.ContentScale = .{ .x = 1, .y = 1 },

/// The size of the surface in pixels.
size: apprt.SurfaceSize = .{ .width = 0, .height = 0 },

/// The cursor position in pixels relative to the surface.
cursor_pos: apprt.CursorPos = .{ .x = 0, .y = 0 },

/// The focused state of the window.
focused: bool = false,

/// The saved high surrogate from a previous WM_CHAR, if any.
surrogate_high: ?u16 = null,

/// A clipboard read that was requested and is waiting to be delivered
/// to the core surface on the main thread.
clipboard_pending: ?ClipboardPending = null,

const ClipboardPending = struct {
    req: apprt.ClipboardRequest,
    data: []u8,
};

/// Initialize the apprt surface and the core surface.
pub fn init(self: *Self, app: *App, hwnd: win32.HWND) !void {
    self.* = .{
        .app = app,
        .hwnd = hwnd,
    };

    // Get initial content scale and size.
    self.content_scale = try self.getContentScale();
    self.size = try self.getSize();

    // Allocate the core surface.
    const surface = try app.alloc.create(CoreSurface);
    errdefer app.alloc.destroy(surface);

    // Register with the core app.
    try app.core_app.addSurface(self);
    errdefer app.core_app.deleteSurface(self);

    // Build a surface config from the app config.
    var config = try apprt.surface.newConfig(
        app.core_app,
        &app.config,
        .window,
    );
    defer config.deinit();

    // Initialize the core surface. This calls back into this surface
    // via `rt_surface` for content scale, size, etc.
    surface.init(
        app.alloc,
        &config,
        app.core_app,
        app,
        self,
    ) catch |err| {
        log.warn("failed to initialize surface err={}", .{err});
        return error.SurfaceInitFailed;
    };
    errdefer surface.deinit();

    self.core_surface = surface;

    // The window is already visible, so mark the renderer as realized.
    // The render thread will lazily create GL resources on first draw.
    surface.displayRealized() catch |err| {
        log.warn("failed to mark surface realized err={}", .{err});
    };

    // Start with focus if this is the first window.
    if (app.windows_open) {
        _ = win32.user32.SetFocus(hwnd);
    }
}

pub fn deinit(self: *Self) void {
    if (self.clipboard_pending) |p| self.app.alloc.free(p.data);
    self.clipboard_pending = null;
    if (self.core_surface) |s| {
        s.deinit();
        self.app.alloc.destroy(s);
        self.core_surface = null;
    }
    if (self.title) |t| self.app.alloc.free(t);
    self.title = null;
}

/// Returns the core surface.
pub fn core(self: *Self) *CoreSurface {
    return self.core_surface orelse @panic("core surface not initialized");
}

/// Returns the apprt app that owns this surface.
pub fn rtApp(self: *Self) *App {
    return self.app;
}

/// Ask the apprt to close the surface. This destroys the window,
/// which triggers WM_DESTROY and then PostQuitMessage. We must not
/// post another WM_CLOSE here: the WndProc would then re-enter this
/// function, causing an infinite close loop.
pub fn close(self: *Self, process_active: bool) void {
    _ = process_active;
    _ = win32.user32.DestroyWindow(self.hwnd);
}

/// Called from WndProc on WM_DESTROY to tear down the window and
/// release all resources. This is the counterpart of the GTK surface
/// finalize path: the core surface must be deinitialized here so that
/// shared resources (e.g. font grids) are released immediately when a
/// window closes, not only at app termination.
pub fn destroySurface(self: *Self) void {
    _ = self.core_surface orelse return;

    // Remove from the core app's surface list.
    self.app.core_app.deleteSurface(self);

    // Remove from our own list.
    if (std.mem.indexOfScalar(*Self, self.app.surfaces.items, self)) |idx| {
        _ = self.app.surfaces.swapRemove(idx);
    }

    self.app.windows_open = self.app.surfaces.items.len > 0;

    // Deinit the apprt surface (frees the core surface and title) and
    // release the structure. The WndProc must not touch us after this.
    self.deinit();
    self.app.alloc.destroy(self);
}

/// Returns the content scale of the surface.
pub fn getContentScale(self: *const Self) !apprt.ContentScale {
    const dpi = win32.user32.GetDpiForWindow(self.hwnd);
    const scale: f32 = @floatFromInt(dpi);
    const base: f32 = 96;
    return .{ .x = scale / base, .y = scale / base };
}

/// Returns the size of the surface in pixels.
pub fn getSize(self: *const Self) !apprt.SurfaceSize {
    var rect: win32.RECT = undefined;
    if (win32.user32.GetClientRect(self.hwnd, &rect) == .FALSE) {
        return error.GetClientRectFailed;
    }
    return .{
        .width = @intCast(@max(rect.width(), 0)),
        .height = @intCast(@max(rect.height(), 0)),
    };
}

/// Returns the cursor position in pixels relative to the surface.
pub fn getCursorPos(self: *const Self) !apprt.CursorPos {
    return self.cursor_pos;
}

/// Returns the title of the surface.
pub fn getTitle(self: *Self) ?[:0]const u8 {
    return self.title;
}

/// Set the title of the window. The title is UTF-8; convert to UTF-16
/// for SetWindowTextW.
pub fn setTitle(self: *Self, title: [:0]const u8) !void {
    // Convert UTF-8 to UTF-16.
    const utf16 = try std.unicode.utf8ToUtf16LeAlloc(self.app.alloc, title);
    defer self.app.alloc.free(utf16);

    // Set the window title (UTF-16 NUL terminated).
    var buf: [1024:0]u16 = undefined;
    if (utf16.len + 1 <= buf.len) {
        @memcpy(buf[0..utf16.len], utf16);
        buf[utf16.len] = 0;
        _ = win32.user32.SetWindowTextW(self.hwnd, &buf);
    }

    // Store the UTF-8 title.
    if (self.title) |old| self.app.alloc.free(old);
    self.title = try self.app.alloc.dupeSentinel(u8, title, 0);
}

/// Returns true if the given clipboard type is supported.
pub fn supportsClipboard(
    self: *const Self,
    clipboard_type: apprt.Clipboard,
) bool {
    _ = self;
    return clipboard.supports(clipboard_type);
}

/// Request clipboard contents. The Win32 clipboard API is synchronous,
/// so we read the data here and then deliver it to the core surface on
/// the next message-loop iteration via a custom window message. This
/// keeps the completion out of the caller's stack (matching the
/// asynchronous contract of `apprt.ClipboardReadResult.started`).
pub fn clipboardRequest(
    self: *Self,
    clipboard_type: apprt.Clipboard,
    state: apprt.ClipboardRequest,
) !apprt.ClipboardReadResult {
    _ = clipboard_type;
    // The Win32 apprt doesn't support the Kitty clipboard protocol yet.
    if (state == .kitty_read or state == .kitty_write or state == .list) return .unsupported;

    const alloc = self.app.alloc;
    const data = try clipboard.read(alloc) orelse return .unavailable;

    // Cancel any previous pending read (shouldn't normally happen).
    if (self.clipboard_pending) |p| alloc.free(p.data);
    self.clipboard_pending = .{ .req = state, .data = data };

    // Wake up the message loop so the pending read is delivered.
    _ = win32.user32.PostMessageW(self.hwnd, win32.WM_APP_CLIPBOARD_READ, 0, 0);
    return .started;
}

/// Complete a clipboard read that was posted to the message loop. This
/// runs on the main thread and delivers the data to the core surface.
pub fn completeClipboardPending(self: *Self) void {
    const pending = self.clipboard_pending orelse return;
    defer {
        self.app.alloc.free(pending.data);
        self.clipboard_pending = null;
    }

    self.core().completeClipboardRequest(
        pending.req,
        .{ .contents = &.{.{ .mime = "text/plain", .data = pending.data }} },
    ) catch |err| {
        log.warn("failed to complete clipboard request err={}", .{err});
    };
}

/// Write clipboard contents.
pub fn setClipboard(
    self: *Self,
    clipboard_type: apprt.Clipboard,
    contents: []const apprt.ClipboardContent,
    confirm: bool,
) !void {
    _ = clipboard_type;
    _ = confirm;

    // Find a text/plain representation.
    for (contents) |content| {
        if (std.mem.eql(u8, content.mime, "text/plain") or
            std.mem.eql(u8, content.mime, "text/plain;charset=utf-8"))
        {
            try clipboard.write(self.app.alloc, content.data);
            return;
        }
    }
}

/// Build the default environment for the terminal child process.
pub fn defaultTermioEnv(self: *Self) !std.process.Environ.Map {
    _ = self;
    return try global.environMap();
}

/// Returns the options to pass to the renderer device.
pub fn renderDeviceOptions(self: *Self) !renderer.Device.Options {
    _ = self;
    return .{};
}

/// Redraw the inspector for the surface. Not implemented yet.
pub fn redrawInspector(self: *Self) void {
    _ = self;
}

// ------------------------------------------------------------------
// Callbacks invoked from the Win32 WndProc
// ------------------------------------------------------------------

/// Handle a WM_PAINT message: take the latest rendered frame from the
/// renderer and blit it to the window DC.
pub fn paint(self: *Self) void {
    const core_surface = self.core_surface orelse return;

    var ps: win32.PAINTSTRUCT = undefined;
    const hdc = win32.user32.BeginPaint(self.hwnd, &ps);
    defer _ = win32.user32.EndPaint(self.hwnd, &ps);

    // Take the latest frame.
    const frame = core_surface.renderer.takeFrame() orelse return;

    switch (frame) {
        .memory => |mem| blitMemory(hdc, mem),
        .dmabuf => |dmabuf| {
            log.warn("unexpected dmabuf frame on Windows", .{});
            dmabuf.deinit();
        },
    }
}

fn blitMemory(hdc: win32.HDC, mem: renderer.OpenGL.ExportedFrame.Memory) void {
    defer mem.deinit();

    // OpenGL readPixels returns tightly-packed RGBA8, but Windows GDI
    // 32bpp DIBs (BI_RGB) expect BGRA byte order. Swap R and B so colors
    // are correct. This is done in place; the buffer is freed after blit.
    const pixels = mem.pixels;
    var i: usize = 0;
    while (i + 4 <= pixels.len) : (i += 4) {
        const r = pixels[i];
        pixels[i] = pixels[i + 2];
        pixels[i + 2] = r;
    }

    // Build a BITMAPINFO describing the RGBA8 pixel buffer. Windows GDI
    // uses bottom-up DIBs with a positive height; our pixel data from
    // readPixels is bottom-up (first row = bottom of the image), so a
    // positive height is correct.
    var bmi: win32.gdi32.BITMAPINFO = .{
        .bmiHeader = .{
            .biSize = @sizeOf(win32.gdi32.BITMAPINFOHEADER),
            .biWidth = @intCast(mem.width),
            .biHeight = @intCast(mem.height),
            .biPlanes = 1,
            .biBitCount = 32,
            .biCompression = win32.gdi32.BI_RGB,
            .biSizeImage = @intCast(mem.width * mem.height * 4),
            .biXPelsPerMeter = 0,
            .biYPelsPerMeter = 0,
            .biClrUsed = 0,
            .biClrImportant = 0,
        },
        .bmiColors = undefined,
    };

    _ = win32.gdi32.SetDIBitsToDevice(
        hdc,
        0,
        0,
        mem.width,
        mem.height,
        0,
        0,
        0,
        @intCast(mem.height),
        pixels.ptr,
        &bmi,
        win32.gdi32.DIB_RGB_COLORS,
    );
}

/// Handle a WM_SIZE message.
pub fn sizeCallback(self: *Self, width: u32, height: u32) !void {
    self.size = .{ .width = width, .height = height };
    if (self.core_surface) |cs| {
        try cs.sizeCallback(self.size);
    }
}

/// Handle a WM_KEYDOWN / WM_SYSKEYDOWN message.
pub fn keyDown(self: *Self, wparam: win32.WPARAM, lparam: win32.LPARAM) !void {
    const event = keymap.keyEvent(
        .press,
        @intCast(wparam),
        lparam,
        "",
        0,
    );
    _ = try self.core().keyCallback(event);
}

/// Handle a WM_KEYUP / WM_SYSKEYUP message.
pub fn keyUp(self: *Self, wparam: win32.WPARAM, lparam: win32.LPARAM) !void {
    const event = keymap.keyEvent(
        .release,
        @intCast(wparam),
        lparam,
        "",
        0,
    );
    _ = try self.core().keyCallback(event);
}

/// Handle a WM_CHAR / WM_SYSCHAR message. `wparam` is a UTF-16 code
/// unit. We accumulate surrogate pairs and forward complete codepoints
/// as UTF-8 to the core `textCallback`.
pub fn charReceived(self: *Self, code_unit: u16) !void {
    // If this is a high surrogate, save it and wait for the low part.
    if (std.unicode.utf16IsHighSurrogate(code_unit)) {
        self.surrogate_high = code_unit;
        return;
    }

    var utf8_buf: [4]u8 = undefined;
    const utf8_len: usize = if (std.unicode.utf16IsLowSurrogate(code_unit) and
        self.surrogate_high != null)
    blk: {
        const high = self.surrogate_high.?;
        self.surrogate_high = null;
        const cp = 0x10000 +
            (@as(u21, high) - 0xD800) * 0x400 +
            (@as(u21, code_unit) - 0xDC00);
        break :blk std.unicode.utf8Encode(cp, &utf8_buf) catch return;
    } else blk: {
        self.surrogate_high = null;
        break :blk std.unicode.utf8Encode(code_unit, &utf8_buf) catch return;
    };

    try self.core().textCallback(utf8_buf[0..utf8_len]);
}

/// Handle a mouse button message.
pub fn mouseButton(
    self: *Self,
    action: input.MouseButtonState,
    button: input.MouseButton,
    lparam: win32.LPARAM,
) !void {
    const x: i32 = @intCast(lparam & 0xFFFF);
    const y: i32 = @intCast((@as(u64, @bitCast(lparam)) >> 16) & 0xFFFF);
    self.cursor_pos = .{ .x = @floatFromInt(x), .y = @floatFromInt(y) };

    _ = try self.core().mouseButtonCallback(
        action,
        button,
        keymap.mods(),
    );
}

/// Handle a WM_MOUSEMOVE message.
pub fn mouseMove(self: *Self, lparam: win32.LPARAM) !void {
    const x: i32 = @intCast(lparam & 0xFFFF);
    const y: i32 = @intCast((@as(u64, @bitCast(lparam)) >> 16) & 0xFFFF);
    self.cursor_pos = .{ .x = @floatFromInt(x), .y = @floatFromInt(y) };

    _ = try self.core().cursorPosCallback(
        self.cursor_pos,
        keymap.mods(),
    );
}

/// Handle a WM_MOUSEWHEEL / WM_MOUSEHWHEEL message. `delta` is in
/// multiples of WHEEL_DELTA (120); positive means scroll up/right
/// (away from user). `horizontal` selects which axis to scroll.
pub fn mouseScroll(self: *Self, delta: i16, horizontal: bool, lparam: win32.LPARAM) !void {
    const x: i32 = @intCast(lparam & 0xFFFF);
    const y: i32 = @intCast((@as(u64, @bitCast(lparam)) >> 16) & 0xFFFF);
    self.cursor_pos = .{ .x = @floatFromInt(x), .y = @floatFromInt(y) };

    // Convert wheel delta to a scroll offset. WHEEL_DELTA is 120.
    const amount: f64 = @as(f64, @floatFromInt(delta)) / 120.0;
    _ = try self.core().scrollCallback(
        if (horizontal) amount else 0,
        if (horizontal) 0 else amount,
        .{},
    );
}

/// Handle a focus change.
pub fn focusCallback(self: *Self, focused: bool) !void {
    if (self.focused == focused) return;
    self.focused = focused;
    if (self.core_surface) |cs| {
        try cs.focusCallback(focused);
    }
}