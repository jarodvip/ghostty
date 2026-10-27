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

/// Payload carried by the WM_APP_NEW_WINDOW message. The app thread
/// takes ownership of both the struct and the data slice.
const IpcNewWindowData = struct {
    data: []u8,
};

/// The app-scoped application state.
core_app: *CoreApp,
alloc: Allocator,
config: Config,
hinstance: win32.HINSTANCE,

/// The primary window handle, used for wakeups and the message loop.
/// Null when no windows are open.
hwnd: ?win32.HWND = null,

/// All open surfaces (one per window).
surfaces: std.ArrayListUnmanaged(*Surface) = .empty,

/// Number of open windows. Used to decide whether to start the quit
/// timer when the last window closes.
windows_open: bool,

/// Thread serving the single-instance IPC named pipe. Detached; lives
/// for the duration of the process.
ipc_thread: ?std.Thread = null,

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
        .hwnd = null,
        .windows_open = false,
        .ipc_thread = null,
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
        if (@backingInt(err) != win32.ERROR_CLASS_ALREADY_EXISTS) {
            return error.RegisterClassFailed;
        }
    }

    // Create the main window and its surface.
    try self.newSurface(null);

    // Start the single-instance IPC server so `ghostty +new-window`
    // can request new windows from a running instance.
    if (std.Thread.spawn(.{ .stack_size = 16 * 1024 * 1024 }, ipcServerThread, .{self})) |thr| {
        thr.detach();
        self.ipc_thread = thr;
    } else |err| {
        log.warn("failed to start IPC server thread err={}", .{err});
    }
}

/// Create a new window and its associated apprt surface. The first
/// window created by this function also becomes the app's primary
/// window (`hwnd`), used for wakeups. `working_directory` is an
/// optional directory to use for the first surface.
fn newSurface(self: *App, working_directory: ?[]const u8) !void {
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
        self.hinstance,
        null,
    ) orelse return error.CreateWindowFailed;

    // Allocate the apprt surface.
    const surface = try self.alloc.create(Surface);
    errdefer self.alloc.destroy(surface);
    errdefer _ = win32.user32.DestroyWindow(hwnd);

    // Initialize the apprt surface and its core surface.
    try surface.init(self, hwnd, working_directory);
    errdefer surface.deinit();

    // Store the surface pointer in the window's user data so the
    // WndProc can find it.
    _ = win32.user32.SetWindowLongPtrW(
        hwnd,
        win32.user32.GWLP_USERDATA,
        @intCast(@intFromPtr(surface)),
    );

    // Track the surface.
    try self.surfaces.append(self.alloc, surface);
    self.windows_open = true;

    // The first window is the primary window for wakeups.
    if (self.surfaces.items.len == 1) {
        @atomicStore(?win32.HWND, &self.hwnd, hwnd, .seq_cst);
    }

    // Show the window.
    _ = win32.user32.ShowWindow(hwnd, win32.user32.SW_SHOW);
}

pub fn run(self: *App) !void {
    var msg: win32.MSG = undefined;
    while (true) {
        const res = win32.user32.GetMessageW(&msg, null, 0, 0);
        // FALSE (0) means WM_QUIT was received; -1 means error.
        const res_int = @backingInt(res);
        if (res_int == 0) break;
        if (res_int == -1) return error.GetMessageFailed;

        _ = win32.user32.TranslateMessage(&msg);
        _ = win32.user32.DispatchMessageW(&msg);

        // Tick the core app (drains the mailbox, processes actions).
        try self.core_app.tick(self);
    }
}

pub fn terminate(self: *App) void {
    // Destroy any remaining windows. We must snapshot the handles first:
    // DestroyWindow synchronously delivers WM_DESTROY, whose handler
    // removes and deinitializes the surface (mutating `self.surfaces`).
    // Iterating while destroying would touch freed memory.
    const n = self.surfaces.items.len;
    const hwnds = self.alloc.alloc(win32.HWND, n) catch {
        // If allocation fails, fall back to destroying the primary
        // window only; the rest is best-effort.
        if (self.hwnd) |h| _ = win32.user32.DestroyWindow(h);
        self.surfaces.deinit(self.alloc);
        self.windows_open = false;
        self.config.deinit();
        return;
    };
    defer self.alloc.free(hwnds);
    for (self.surfaces.items, 0..) |s, i| hwnds[i] = s.hwnd;

    for (hwnds) |h| {
        _ = win32.user32.DestroyWindow(h);
    }
    self.surfaces.deinit(self.alloc);
    self.windows_open = false;
    self.config.deinit();
}

/// Wake up the event loop. Called by the core app when the mailbox
/// needs draining.
pub fn wakeup(self: *App) void {
    // If no windows are open there's nothing to wake.
    if (self.hwnd) |h| _ = win32.user32.PostMessageW(h, win32.WM_APP, 0, 0);
}

pub fn performAction(
    self: *App,
    target: apprt.Target,
    comptime action: apprt.Action.Key,
    value: apprt.Action.Value(action),
) !bool {
    switch (action) {
        .quit => {
            // Close all windows to quit.
            for (self.surfaces.items) |s| {
                _ = win32.user32.PostMessageW(s.hwnd, win32.WM_CLOSE, 0, 0);
            }
            return true;
        },

        .close_all_windows => {
            for (self.surfaces.items) |s| {
                _ = win32.user32.PostMessageW(s.hwnd, win32.WM_CLOSE, 0, 0);
            }
            return true;
        },

        .new_window => {
            try self.newSurface(null);
            return true;
        },

        .new_tab => {
            // The Win32 apprt does not have tabs; open a new window.
            try self.newSurface(null);
            return true;
        },

        .new_split => {
            // Splits are not yet implemented in the Win32 apprt.
            return false;
        },

        .close_tab => {
            // Close the surface's window. "other"/"right" are not
            // meaningful without tabs; only .this is supported.
            switch (value) {
                .this => switch (target) {
                    .surface => |s| {
                        const rt_surface: *Surface = @ptrCast(@alignCast(s.rt_surface));
                        _ = win32.user32.PostMessageW(rt_surface.hwnd, win32.WM_CLOSE, 0, 0);
                    },
                    .app => {},
                },
                .other, .right => return false,
            }
            return true;
        },

        .close_window => {
            switch (target) {
                .app => {
                    // Close the focused window, or all if none focused.
                    if (self.core_app.focusedSurface()) |fs| {
                        const rt_surface: *Surface = @ptrCast(@alignCast(fs.rt_surface));
                        _ = win32.user32.PostMessageW(rt_surface.hwnd, win32.WM_CLOSE, 0, 0);
                    } else {
                        for (self.surfaces.items) |s| {
                            _ = win32.user32.PostMessageW(s.hwnd, win32.WM_CLOSE, 0, 0);
                        }
                    }
                },
                .surface => |s| {
                    const rt_surface: *Surface = @ptrCast(@alignCast(s.rt_surface));
                    _ = win32.user32.PostMessageW(rt_surface.hwnd, win32.WM_CLOSE, 0, 0);
                },
            }
            return true;
        },

        .render => {
            switch (target) {
                .surface => |s| {
                    const rt_surface: *Surface = @ptrCast(@alignCast(s.rt_surface));
                    _ = win32.user32.InvalidateRect(rt_surface.hwnd, null, .FALSE);
                },
                .app => {},
            }
            return true;
        },

        .set_title => {
            switch (target) {
                .surface => |s| {
                    const rt_surface: *Surface = @ptrCast(@alignCast(s.rt_surface));
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
                    const rt_surface: *Surface = @ptrCast(@alignCast(s.rt_surface));
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
    switch (action) {
        // The Win32 apprt has no tabs; both new_window and new_tab open
        // a new window in the running instance.
        .new_window => {
            const args = value.arguments orelse return try ipcSend(&.{});
            return try ipcSend(args);
        },
        .new_tab => {
            const args = value.arguments orelse return try ipcSend(&.{});
            return try ipcSend(args);
        },
        else => {
            _ = target;
            return false;
        },
    }
}

/// Connect to the running Ghostty instance's named pipe and send the
/// serialized arguments for the requested action.
fn ipcSend(args: []const [:0]const u8) !bool {
    const pipe_name: [17:0]u16 = .{ '\\', '\\', '.', '\\', 'p', 'i', 'p', 'e', '\\', 'g', 'h', 'o', 's', 't', 't', 'y', 0 };

    const hPipe = win32.kernel32.CreateFileW(
        &pipe_name,
        win32.GENERIC_READ_WRITE,
        0,
        null,
        win32.OPEN_EXISTING,
        0,
        null,
    ) orelse {
        log.info("no running Ghostty instance found for IPC", .{});
        return error.IPCFailed;
    };
    defer _ = win32.kernel32.CloseHandle(hPipe);

    // Compute the total payload size and build the buffer.
    var total: usize = 0;
    for (args) |arg| total += arg.len + 1;
    if (total == 0) total = 1; // at least one NUL

    const buf = try std.heap.page_allocator.alloc(u8, total);
    defer std.heap.page_allocator.free(buf);

    var off: usize = 0;
    for (args) |arg| {
        @memcpy(buf[off .. off + arg.len], arg);
        off += arg.len;
        buf[off] = 0;
        off += 1;
    }
    if (args.len == 0) buf[0] = 0;

    var written: win32.DWORD = 0;
    if (win32.kernel32.WriteFile(
        hPipe,
        buf.ptr,
        @intCast(buf.len),
        &written,
        null,
    ) == win32.FALSE) {
        return error.IPCFailed;
    }

    return true;
}

/// The IPC server thread. It waits for connections on the named pipe,
/// reads the serialized arguments, and posts them to the app thread.
fn ipcServerThread(app: *App) void {
    const pipe_name: [17:0]u16 = .{ '\\', '\\', '.', '\\', 'p', 'i', 'p', 'e', '\\', 'g', 'h', 'o', 's', 't', 't', 'y', 0 };

    while (true) {
        const hPipe = win32.kernel32_pipe.CreateNamedPipeW(
            &pipe_name,
            win32.PIPE_ACCESS_DUPLEX,
            win32.PIPE_TYPE_MESSAGE | win32.PIPE_READMODE_MESSAGE | win32.PIPE_WAIT,
            1,
            4096,
            4096,
            win32.NMPWAIT_USE_DEFAULT_WAIT,
            null,
        );
        if (hPipe == win32.INVALID_HANDLE_VALUE) {
            log.warn("failed to create IPC named pipe", .{});
            return;
        }

        // Wait for a client to connect.
        if (win32.kernel32_pipe.ConnectNamedPipe(hPipe, null) == win32.FALSE) {
            const err = win32.getLastError();
            if (@backingInt(err) != win32.ERROR_PIPE_CONNECTED) {
                _ = win32.kernel32.CloseHandle(hPipe);
                continue;
            }
        }

        // Read the request.
        var buf: [8192]u8 = undefined;
        var read: win32.DWORD = 0;
        const ok = win32.kernel32.ReadFile(
            hPipe,
            &buf,
            buf.len,
            &read,
            null,
        );

        // Flush and disconnect so the client can finish.
        _ = win32.kernel32_pipe.FlushFileBuffers(hPipe);
        _ = win32.kernel32_pipe.DisconnectNamedPipe(hPipe);
        _ = win32.kernel32.CloseHandle(hPipe);

        if (ok == win32.FALSE or read == 0) continue;

        // Allocate a message payload carrying the raw data and its
        // length, then post it to the app thread. The app thread takes
        // ownership of both allocations.
        const msg = app.alloc.create(IpcNewWindowData) catch continue;
        msg.data = app.alloc.dupe(u8, buf[0..read]) catch {
            app.alloc.destroy(msg);
            continue;
        };
        // If no window is open (shouldn't normally happen), drop the
        // request; the payload is freed below via errdefer-like logic.
        const h = @atomicLoad(?win32.HWND, &app.hwnd, .seq_cst) orelse {
            app.alloc.free(msg.data);
            app.alloc.destroy(msg);
            continue;
        };
        if (win32.user32.PostMessageW(
            h,
            win32.WM_APP_NEW_WINDOW,
            0,
            @intCast(@intFromPtr(msg)),
        ) == win32.FALSE) {
            // The window is gone; release the payload.
            app.alloc.free(msg.data);
            app.alloc.destroy(msg);
        }
    }
}

/// Parse the `--working-directory=<path>` argument out of a
/// NUL-separated arguments buffer. Returns `null` if not present.
fn parseWorkingDirectory(data: []const u8) ?[]const u8 {
    const prefix = "--working-directory=";
    var it = std.mem.splitScalar(u8, data, 0);
    while (it.next()) |arg| {
        if (std.mem.startsWith(u8, arg, prefix)) {
            return arg[prefix.len..];
        }
    }
    return null;
}

test "parseWorkingDirectory" {
    try std.testing.expectEqualStrings(
        "C:\\Users\\test",
        parseWorkingDirectory("--working-directory=C:\\Users\\test\x00--command=cmd.exe").?,
    );
    try std.testing.expectEqualStrings(
        "D:\\Dev",
        parseWorkingDirectory("--command=cmd.exe\x00--working-directory=D:\\Dev").?,
    );
    try std.testing.expect(parseWorkingDirectory("--command=cmd.exe\x00") == null);
    try std.testing.expect(parseWorkingDirectory("") == null);
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
            // Only quit the app when the last window is closed; other
            // windows may still be open (multi-window support). Save the
            // app pointer before destroySurface frees the surface.
            if (surface) |s| {
                const app = s.app;
                s.destroySurface();
                if (app.surfaces.items.len == 0) {
                    _ = win32.user32.PostQuitMessage(0);
                }
            }
            return 0;
        },

        win32.WM_IME_STARTCOMPOSITION => {
            // Nothing to do; preedit updates come via
            // WM_IME_COMPOSITION.
            return 0;
        },

        win32.WM_IME_COMPOSITION => {
            if (surface) |s| {
                s.imeComposition(lparam) catch |err| {
                    log.warn("ime composition failed err={}", .{err});
                };
            }
            return 0;
        },

        win32.WM_IME_ENDCOMPOSITION => {
            if (surface) |s| {
                s.imeEndComposition() catch |err| {
                    log.warn("ime end composition failed err={}", .{err});
                };
            }
            return 0;
        },

        win32.WM_APP => {
            // Wakeup: nothing to do; the message loop drains the
            // mailbox via core_app.tick.
            return 0;
        },

        win32.WM_APP_CLIPBOARD_READ => {
            if (surface) |s| s.completeClipboardPending();
            return 0;
        },

        win32.WM_APP_NEW_WINDOW => {
            if (surface) |s| {
                // lParam carries a pointer to an allocated
                // IpcNewWindowData payload. Take ownership here.
                const payload: *IpcNewWindowData = @ptrFromInt(@as(usize, @intCast(lparam)));
                defer {
                    s.rtApp().alloc.free(payload.data);
                    s.rtApp().alloc.destroy(payload);
                }

                const wd = parseWorkingDirectory(payload.data);
                s.rtApp().newSurface(wd) catch |err| {
                    log.warn("failed to create new window via IPC err={}", .{err});
                };
            }
            return 0;
        },

        else => {},
    }

    return win32.user32.DefWindowProcW(hwnd, msg, wparam, lparam);
}
