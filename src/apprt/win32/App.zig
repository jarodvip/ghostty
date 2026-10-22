//! Win32 application runtime: owns the Win32 message loop and top-level
//! window(s), creates one `Surface` (see Surface.zig) per terminal
//! window, and forwards all Win32 messages into the core surface.
//!
//! This implements the `apprt.App` contract required by
//! `src/main_ghostty.zig` and `src/App.zig`.

const App = @This();

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const assert = @import("../../quirks.zig").inlineAssert;

const apprt = @import("../../apprt.zig");
const configpkg = @import("../../config.zig");
const Config = configpkg.Config;
const CoreApp = @import("../../App.zig");
const CoreSurface = @import("../../Surface.zig");
const global = @import("../../global.zig");
const input = @import("../../input.zig");
const win32 = @import("win32.zig");
const Surface = @import("Surface.zig");

const log = std.log.scoped(.win32);

/// The name of our window class.
const class_name: [8:0]u16 = .{ 'G', 'h', 'o', 's', 't', 't', 'y', 0 };

/// The app-scoped application state.
core_app: *CoreApp,
alloc: Allocator,
config: Config,
hinstance: win32.HINSTANCE,
hwnd: win32.HWND,
surface: *Surface,

/// The number of open windows. We only support one window for now, but
/// this keeps the quit logic simple.
windows_open: bool,

pub fn init(
    self: *App,
    core_app: *CoreApp,
    opts: struct {},
) !void {
    _ = opts;
    self.* = .{
        .core_app = core_app,
        .alloc = core_app.alloc,
        .config = undefined,
        .hinstance = undefined,
        .hwnd = undefined,
        .surface = undefined,
        .windows_open = false,
    };

    // Load our configuration.
    self.config = Config.load(self.alloc) catch |err| fallback: {
        log.warn("failed to load config err={}; using defaults", .{err});
        break :fallback try Config.default(self.alloc);
    };
    errdefer self.config.deinit();

    const hinstance = win32.kernel32.GetModuleHandleW(null) orelse return error.NoModuleHandle;
    self.hinstance = hinstance;

    // Register the window class. If the class was already registered
    // (e.g. by a previous apprt instance in the same process), that's
    // fine and we can continue.
    const wc = win32.WNDCLASSW{
        .style = 0,
        .lpfnWndProc = wndProc,
        .cbClsExtra = 0,
        .cbWndExtra = 0,
        .hInstance = hinstance,
        .hIcon = null,
        .hCursor = null,
        .hbrBackground = null,
        .lpszMenuName = null,
        .lpszClassName = &class_name,
    };
    const atom = win32.user32.RegisterClassW(&wc);
    if (atom == 0) {
        const err = win32.getLastError();
        if (@intFromEnum(err) != win32.ERROR_CLASS_ALREADY_EXISTS) {
            return error.RegisterClassFailed;
        }
    }

    // Create the main window.
    const hwnd = win32.user32.CreateWindowExW(
        0,
        &class_name,
        &class_name,
        win32.WS_OVERLAPPEDWINDOW,
        win32.CW_USEDEFAULT,
        win32.CW_USEDEFAULT,
        800,
        600,
        null,
        null,
        hinstance,
        null,
    ) orelse return error.CreateWindowFailed;
    self.hwnd = hwnd;

    // Create the apprt surface for this window.
    const surface = try self.alloc.create(Surface);
    errdefer self.alloc.destroy(surface);
    try surface.init(self, hwnd);
    self.surface = surface;
    self.windows_open = true;

    // Store the surface pointer in the window's user data so the
    // WndProc can find it.
    _ = win32.user32.SetWindowLongPtrW(
        hwnd,
        win32.user32.GWLP_USERDATA,
        @intCast(@intFromPtr(surface)),
    );

    // Show the window.
    _ = win32.user32.ShowWindow(hwnd, win32.user32.SW_SHOW);
}

pub fn run(self: *App) !void {
    var msg: win32.MSG = undefined;
    while (true) {
        const res = win32.user32.GetMessageW(&msg, null, 0, 0);
        // FALSE (0) means WM_QUIT was received; -1 means error.
        const res_int = @intFromEnum(res);
        if (res_int == 0) break;
        if (res_int == -1) return error.GetMessageFailed;

        _ = win32.user32.TranslateMessage(&msg);
        _ = win32.user32.DispatchMessageW(&msg);

        // Tick the core app (drains the mailbox, processes actions).
        try self.core_app.tick(self);
    }
}

pub fn terminate(self: *App) void {
    // Destroy the window if still open. This triggers WM_DESTROY which
    // removes the surface from the core app's list.
    if (self.windows_open) {
        _ = win32.user32.DestroyWindow(self.hwnd);
        self.windows_open = false;
    }

    // The surface may have been removed from the core app's surface list
    // by destroySurface, in which case the core app will not call its
    // deinit. We must deinit it ourselves to release the core surface
    // and title memory, then free the structure.
    if (@as(?*Surface, self.surface)) |s| {
        s.deinit();
        self.alloc.destroy(s);
    }
    self.config.deinit();
}

/// Wake up the event loop. Called by the core app when the mailbox
/// needs draining.
pub fn wakeup(self: *App) void {
    _ = win32.user32.PostMessageW(self.hwnd, win32.WM_APP, 0, 0);
}

pub fn performAction(
    self: *App,
    target: apprt.Target,
    comptime action: apprt.Action.Key,
    value: apprt.Action.Value(action),
) !bool {
    switch (action) {
        .quit => {
            _ = win32.user32.PostMessageW(self.hwnd, win32.WM_CLOSE, 0, 0);
            return true;
        },

        .close_all_windows => {
            _ = win32.user32.PostMessageW(self.hwnd, win32.WM_CLOSE, 0, 0);
            return true;
        },

        .new_window => {
            // TODO: multiple windows.
            log.warn("new_window is not yet implemented in the Win32 apprt", .{});
            return false;
        },

        .new_tab, .new_split, .close_tab => {
            // Not yet implemented.
            return false;
        },

        .close_window => {
            switch (target) {
                .app => _ = win32.user32.PostMessageW(self.hwnd, win32.WM_CLOSE, 0, 0),
                .surface => |s| {
                    const rt_surface: *Surface = @alignCast(@ptrCast(s.rt_surface));
                    _ = win32.user32.PostMessageW(rt_surface.hwnd, win32.WM_CLOSE, 0, 0);
                },
            }
            return true;
        },

        .render => {
            switch (target) {
                .surface => |s| {
                    const rt_surface: *Surface = @alignCast(@ptrCast(s.rt_surface));
                    _ = win32.user32.InvalidateRect(rt_surface.hwnd, null, .FALSE);
                },
                .app => {},
            }
            return true;
        },

        .set_title => {
            switch (target) {
                .surface => |s| {
                    const rt_surface: *Surface = @alignCast(@ptrCast(s.rt_surface));
                    try rt_surface.setTitle(value.title);
                },
                .app => {},
            }
            return true;
        },

        .config_change => {
            switch (target) {
                .surface => |s| {
                    _ = s;
                    // The config is borrowed for this call only.
                },
                .app => {},
            }
            return true;
        },

        .quit_timer => {
            // We don't auto-quit when there are no windows because the
            // terminal is a single-window app; we simply ignore this.
            return true;
        },

        .present_terminal => {
            switch (target) {
                .surface => |s| {
                    const rt_surface: *Surface = @alignCast(@ptrCast(s.rt_surface));
                    _ = win32.user32.SetFocus(rt_surface.hwnd);
                },
                .app => {},
            }
            return true;
        },

        else => {
            // Unhandled action: tell the caller we didn't process it.
            return false;
        },
    }
}

/// Send the given IPC to a running Ghostty. Returns `true` if the action
/// was able to be performed, `false` otherwise.
pub fn performIpc(
    alloc: Allocator,
    target: apprt.ipc.Target,
    comptime action: apprt.ipc.Action.Key,
    value: apprt.ipc.Action.Value(action),
) !bool {
    _ = alloc;
    _ = target;
    _ = value;
    return false;
}

/// The window procedure for all Ghostty windows.
fn wndProc(
    hwnd: win32.HWND,
    msg: win32.UINT,
    wparam: win32.WPARAM,
    lparam: win32.LPARAM,
) callconv(.winapi) win32.LRESULT {
    // Retrieve the surface pointer stored in the window user data.
    const userdata = win32.user32.GetWindowLongPtrW(hwnd, win32.user32.GWLP_USERDATA);
    const surface: ?*Surface = if (userdata != 0)
        @ptrFromInt(@as(usize, @intCast(userdata)))
    else
        null;

    switch (msg) {
        win32.WM_PAINT => {
            if (surface) |s| s.paint();
            // BeginPaint/EndPaint in `paint` already validate the update
            // region, so there is nothing left for DefWindowProc to do.
            return 0;
        },

        win32.WM_SIZE => {
            if (surface) |s| {
                const lp: u64 = @bitCast(lparam);
                const width: u32 = @intCast(lp & 0xFFFF);
                const height: u32 = @intCast((lp >> 16) & 0xFFFF);
                s.sizeCallback(width, height) catch |err| {
                    log.warn("size callback failed err={}", .{err});
                };
            }
            return 0;
        },

        win32.WM_KEYDOWN, win32.WM_SYSKEYDOWN => {
            if (surface) |s| {
                s.keyDown(wparam, lparam) catch |err| {
                    log.warn("key down failed err={}", .{err});
                };
            }
            return 0;
        },

        win32.WM_KEYUP, win32.WM_SYSKEYUP => {
            if (surface) |s| {
                s.keyUp(wparam, lparam) catch |err| {
                    log.warn("key up failed err={}", .{err});
                };
            }
            return 0;
        },

        win32.WM_CHAR, win32.WM_SYSCHAR => {
            if (surface) |s| {
                s.charReceived(@intCast(wparam)) catch |err| {
                    log.warn("char received failed err={}", .{err});
                };
            }
            return 0;
        },

        win32.WM_LBUTTONDOWN => {
            if (surface) |s| {
                s.mouseButton(.press, .left, lparam) catch |err| {
                    log.warn("mouse button failed err={}", .{err});
                };
            }
            return 0;
        },

        win32.WM_LBUTTONUP => {
            if (surface) |s| {
                s.mouseButton(.release, .left, lparam) catch |err| {
                    log.warn("mouse button failed err={}", .{err});
                };
            }
            return 0;
        },

        win32.WM_RBUTTONDOWN => {
            if (surface) |s| {
                s.mouseButton(.press, .right, lparam) catch |err| {
                    log.warn("mouse button failed err={}", .{err});
                };
            }
            return 0;
        },

        win32.WM_RBUTTONUP => {
            if (surface) |s| {
                s.mouseButton(.release, .right, lparam) catch |err| {
                    log.warn("mouse button failed err={}", .{err});
                };
            }
            return 0;
        },

        win32.WM_MBUTTONDOWN => {
            if (surface) |s| {
                s.mouseButton(.press, .middle, lparam) catch |err| {
                    log.warn("mouse button failed err={}", .{err});
                };
            }
            return 0;
        },

        win32.WM_MBUTTONUP => {
            if (surface) |s| {
                s.mouseButton(.release, .middle, lparam) catch |err| {
                    log.warn("mouse button failed err={}", .{err});
                };
            }
            return 0;
        },

        win32.WM_MOUSEMOVE => {
            if (surface) |s| {
                s.mouseMove(lparam) catch |err| {
                    log.warn("mouse move failed err={}", .{err});
                };
            }
            return 0;
        },

        win32.WM_MOUSEWHEEL => {
            if (surface) |s| {
                const wp: u64 = @bitCast(wparam);
                const delta: i16 = @bitCast(@as(u16, @intCast((wp >> 16) & 0xFFFF)));
                s.mouseScroll(delta, false, lparam) catch |err| {
                    log.warn("mouse wheel failed err={}", .{err});
                };
            }
            return 0;
        },

        win32.WM_MOUSEHWHEEL => {
            if (surface) |s| {
                const wp: u64 = @bitCast(wparam);
                const delta: i16 = @bitCast(@as(u16, @intCast((wp >> 16) & 0xFFFF)));
                s.mouseScroll(delta, true, lparam) catch |err| {
                    log.warn("mouse horizontal wheel failed err={}", .{err});
                };
            }
            return 0;
        },

        win32.WM_SETFOCUS => {
            if (surface) |s| s.focusCallback(true) catch |err| {
                log.warn("focus callback failed err={}", .{err});
            };
            return 0;
        },

        win32.WM_KILLFOCUS => {
            if (surface) |s| s.focusCallback(false) catch |err| {
                log.warn("focus callback failed err={}", .{err});
            };
            return 0;
        },

        win32.WM_CLOSE => {
            if (surface) |s| {
                // Trigger the core close flow so the child process and
                // terminal state are torn down properly. The core will
                // call back into s.close() to destroy the window.
                s.core().close();
            }
            return 0;
        },

        win32.WM_DESTROY => {
            // If the surface exists, tell the core app it's gone.
            if (surface) |s| {
                s.destroySurface();
            }
            _ = win32.user32.PostQuitMessage(0);
            return 0;
        },

        win32.WM_APP => {
            // Wakeup: nothing to do; the message loop drains the
            // mailbox via core_app.tick.
            return 0;
        },

        else => {},
    }

    return win32.user32.DefWindowProcW(hwnd, msg, wparam, lparam);
}