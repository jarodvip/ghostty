//! The Win32 apprt is a native Windows application runtime. It owns a
//! Win32 message loop and creates one HWND per terminal surface.
//!
//! This is the required comptime API for any apprt, mirroring
//! `src/apprt/gtk.zig`.

pub const App = @import("win32/App.zig");
pub const Surface = @import("win32/Surface.zig");
pub const resourcesDir = @import("../os/main.zig").resourcesDir;

// The exported API, custom for the apprt.
pub const win32 = @import("win32/win32.zig");

test {
    @import("std").testing.refAllDecls(@This());
    _ = @import("win32/win32.zig");
    _ = @import("win32/clipboard.zig");
    _ = @import("win32/key.zig");
}
