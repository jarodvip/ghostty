//! Mapping of Win32 virtual key codes and scan codes to Ghostty's
//! layout-independent `input.Key` enum, plus helper to build `input.KeyEvent`.

const std = @import("std");
const builtin = @import("builtin");
const input = @import("../../input.zig");
const keycodes = @import("../../input/keycodes.zig");
const win32 = @import("win32.zig");

/// Map a Windows scan code to a Ghostty Key. Returns `.unidentified`
/// if no mapping is known.
pub fn fromScanCode(scan_code: u32) input.Key {
    // The Windows "native" column in keycodes.zig contains scan codes.
    for (keycodes.entries) |entry| {
        if (entry.native == scan_code) return entry.key;
    }
    return .unidentified;
}

/// Build the `input.Mods` for the current keyboard state.
pub fn mods() input.Mods {
    var result: input.Mods = .{};

    // GetKeyState returns the state of the key at the time of the
    // message; it also reports toggle state in the low bit which we
    // don't need here.
    if (isKeyDown(win32.VK_SHIFT)) result.shift = true;
    if (isKeyDown(win32.VK_CONTROL)) result.ctrl = true;
    if (isKeyDown(win32.VK_MENU)) result.alt = true;
    if (isKeyDown(win32.VK_LWIN) or isKeyDown(win32.VK_RWIN)) result.super = true;

    if (isKeyToggled(win32.VK_CAPITAL)) result.caps_lock = true;
    if (isKeyToggled(win32.VK_NUMLOCK)) result.num_lock = true;

    // Side detection.
    if (isKeyDown(win32.VK_LSHIFT)) result.sides.shift = .left;
    if (isKeyDown(win32.VK_RSHIFT)) result.sides.shift = .right;
    if (isKeyDown(win32.VK_LCONTROL)) result.sides.ctrl = .left;
    if (isKeyDown(win32.VK_RCONTROL)) result.sides.ctrl = .right;
    if (isKeyDown(win32.VK_LMENU)) result.sides.alt = .left;
    if (isKeyDown(win32.VK_RMENU)) result.sides.alt = .right;

    return result;
}

/// Returns true if the given virtual key is currently down.
fn isKeyDown(vk: i32) bool {
    const state = win32.user32.GetKeyState(vk);
    const ustate: u16 = @bitCast(state);
    return (ustate & 0x8000) != 0;
}

/// Returns true if the given toggle key (CapsLock, NumLock) is on.
fn isKeyToggled(vk: i32) bool {
    const state = win32.user32.GetKeyState(vk);
    return (state & 0x0001) != 0;
}

/// Convert the raw `lParam` of a WM_KEYDOWN/WM_KEYUP message into a
/// `input.KeyEvent`. The caller supplies the UTF-8 text (if any) that
/// the key produced, e.g. from WM_CHAR.
pub fn keyEvent(
    action: input.Action,
    vk: i32,
    lparam: win32.LPARAM,
    utf8: []const u8,
    unshifted_codepoint: u21,
) input.KeyEvent {
    // The scan code is in bits 16..23 of lParam.
    const lp: u64 = @bitCast(lparam);
    const scan_code: u32 = @intCast((lp >> 16) & 0xFF);
    const key = fromScanCode(scan_code);

    // If the scan code didn't map (e.g. some special keys), fall back
    // to the virtual key code for a few common cases.
    const key_final: input.Key = if (key != .unidentified)
        key
    else switch (vk) {
        win32.VK_SHIFT => fromScanCode(if (isKeyDown(win32.VK_LSHIFT)) 0x2A else 0x36),
        win32.VK_CONTROL => fromScanCode(if (isKeyDown(win32.VK_LCONTROL)) 0x1D else 0x1D),
        win32.VK_MENU => fromScanCode(0x38),
        win32.VK_LWIN => fromScanCode(0x5B),
        win32.VK_RWIN => fromScanCode(0x5C),
        else => .unidentified,
    };

    // Compute the unshifted codepoint using ToUnicode with an empty
    // keyboard state (no modifiers). This lets Ghostty's unicode-based
    // keybindings (e.g. `ctrl+shift+n=new_window`) match the physical
    // key's base character regardless of held modifiers.
    const unshifted: u21 = if (unshifted_codepoint != 0)
        unshifted_codepoint
    else
        unshiftedCodepoint(vk, scan_code);

    return .{
        .action = action,
        .key = key_final,
        .mods = mods(),
        .utf8 = utf8,
        .unshifted_codepoint = unshifted,
    };
}

/// Compute the unshifted character produced by a virtual key + scan
/// code using ToUnicode with no modifiers held.
fn unshiftedCodepoint(vk: i32, scan_code: u32) u21 {
    var key_state: [256]u8 = @splat(0);
    var buf: [4]u16 = undefined;
    const n = win32.user32.ToUnicode(
        @intCast(vk),
        @intCast(scan_code),
        &key_state,
        &buf,
        buf.len,
        0,
    );
    if (n <= 0) return 0;
    // A single UTF-16 code unit in the BMP (not a surrogate) is the
    // unshifted codepoint.
    const cp = buf[0];
    if (std.unicode.utf16IsHighSurrogate(cp) or std.unicode.utf16IsLowSurrogate(cp)) return 0;
    return cp;
}

test "scan code mapping" {
    // US keyboard scan codes from keycodes.zig.
    try std.testing.expectEqual(input.Key.key_a, fromScanCode(0x1E));
    try std.testing.expectEqual(input.Key.enter, fromScanCode(0x1C));
    try std.testing.expectEqual(input.Key.space, fromScanCode(0x39));
    try std.testing.expectEqual(input.Key.escape, fromScanCode(0x01));
    try std.testing.expectEqual(input.Key.f1, fromScanCode(0x3B));
    // Unknown scan code maps to unidentified.
    try std.testing.expectEqual(input.Key.unidentified, fromScanCode(0xFFFF));
}
