//! Win32 clipboard integration.
//!
//! Ghostty's apprt interface supports three clipboard locations:
//! `.standard` (Ctrl+C/V), `.selection`, and `.primary`. On Windows
//! only the standard clipboard exists, so `.selection` and `.primary`
//! are reported unsupported.

const std = @import("std");
const Allocator = std.mem.Allocator;
const apprt = @import("../../apprt.zig");
const win32 = @import("win32.zig");

/// Returns the clipboard types supported by this apprt.
pub fn supports(clipboard_type: apprt.Clipboard) bool {
    return switch (clipboard_type) {
        .standard => true,
        .selection, .primary => false,
    };
}

/// Read the current contents of the standard clipboard as UTF-8.
/// Returns `null` if the clipboard doesn't contain text.
pub fn read(alloc: Allocator) !?[]u8 {
    if (win32.user32_clipboard.OpenClipboard(null) == .FALSE) return null;
    defer _ = win32.user32_clipboard.CloseClipboard();

    if (win32.user32_clipboard.IsClipboardFormatAvailable(win32.CF_UNICODETEXT) == .FALSE) return null;
    const h = win32.user32_clipboard.GetClipboardData(win32.CF_UNICODETEXT) orelse return null;
    const ptr = win32.kernel32.GlobalLock(h) orelse return null;
    defer _ = win32.kernel32.GlobalUnlock(h);

    const size = win32.kernel32.GlobalSize(h);
    const bytes: []const u8 = @as([*]const u8, @ptrCast(ptr))[0..size];
    // GlobalAlloc memory is suitably aligned for u16.
    const utf16: []const u16 = @alignCast(std.mem.bytesAsSlice(u16, bytes));
    const utf8 = try std.unicode.utf16LeToUtf8Alloc(alloc, utf16);
    if (utf8.len == 0) {
        alloc.free(utf8);
        return null;
    }
    return utf8;
}

/// Write text to the standard clipboard.
pub fn write(alloc: Allocator, text: []const u8) !void {
    // Convert the UTF-8 text to UTF-16 (with a NUL terminator).
    const utf16 = try std.unicode.utf8ToUtf16LeAlloc(alloc, text);
    defer alloc.free(utf16);
    const size = (utf16.len + 1) * 2;

    if (win32.user32_clipboard.OpenClipboard(null) == .FALSE) return error.ClipboardOpenFailed;
    defer _ = win32.user32_clipboard.CloseClipboard();

    // Allocate a global memory block and copy the text in.
    const h = win32.kernel32.GlobalAlloc(win32.GMEM_MOVEABLE, size) orelse
        return error.ClipboardAllocFailed;
    errdefer _ = win32.kernel32.GlobalFree(h);

    const dst = win32.kernel32.GlobalLock(h) orelse return error.ClipboardLockFailed;
    defer _ = win32.kernel32.GlobalUnlock(h);

    const dst_bytes: [*]u8 = @ptrCast(dst);
    @memcpy(dst_bytes[0 .. utf16.len * 2], std.mem.sliceAsBytes(utf16));
    // Write the NUL terminator.
    dst_bytes[utf16.len * 2] = 0;
    dst_bytes[utf16.len * 2 + 1] = 0;

    if (win32.user32_clipboard.EmptyClipboard() == .FALSE) return error.ClipboardEmptyFailed;
    if (win32.user32_clipboard.SetClipboardData(win32.CF_UNICODETEXT, h) == null) {
        return error.ClipboardSetFailed;
    }

    // On success the clipboard owns the memory; don't free it.
}
