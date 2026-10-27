//! Win32 API bindings used by the Windows apprt.
//!
//! The Zig std library's `std.os.windows` exposes kernel32/ntdll and
//! basic types, but the Win32 GUI APIs (user32/gdi32) used here are not
//! yet in the stdlib. This module declares just the subset of Win32 that
//! the apprt needs, following the same "bridge" pattern used by
//! `src/os/windows.zig`.

const std = @import("std");
const windows = std.os.windows;

pub const BOOL = windows.BOOL;
pub const DWORD = windows.DWORD;
pub const HDC = windows.HDC;
pub const HANDLE = windows.HANDLE;
pub const HINSTANCE = windows.HINSTANCE;
pub const HWND = windows.HWND;
pub const LONG = windows.LONG;
pub const LPARAM = windows.LPARAM;
pub const LPCWSTR = windows.LPCWSTR;
pub const LPWSTR = windows.LPWSTR;
pub const UINT = windows.UINT;
pub const ULONG_PTR = usize;
pub const Win32Error = windows.Win32Error;

/// WPARAM is not yet in the Zig stdlib; it is UINT_PTR (usize).
pub const WPARAM = usize;

/// Get the last Win32 error code.
pub fn getLastError() Win32Error {
    return windows.GetLastError();
}

/// LONG_PTR is isize; LRESULT and WPARAM are pointer-sized integers.
pub const LRESULT = isize;
pub const LONG_PTR = isize;
pub const WPARAM_TYPE = WPARAM;
pub const HGDIOBJ = *anyopaque;
pub const HBRUSH = *anyopaque;
pub const HICON = *anyopaque;
pub const HCURSOR = *anyopaque;
pub const HMENU = *anyopaque;
pub const HGLOBAL = *anyopaque;
pub const HKL = *anyopaque;

pub const WNDPROC = *const fn (hwnd: HWND, msg: UINT, wparam: WPARAM_TYPE, lparam: LPARAM) callconv(.winapi) LRESULT;

/// RECT
pub const RECT = extern struct {
    left: LONG,
    top: LONG,
    right: LONG,
    bottom: LONG,

    pub fn width(self: RECT) i32 {
        return self.right - self.left;
    }

    pub fn height(self: RECT) i32 {
        return self.bottom - self.top;
    }
};

pub const POINT = extern struct {
    x: LONG,
    y: LONG,
};

pub const MSG = extern struct {
    hwnd: ?HWND,
    message: UINT,
    wParam: WPARAM_TYPE,
    lParam: LPARAM,
    time: DWORD,
    pt: POINT,
};

pub const PAINTSTRUCT = extern struct {
    hdc: HDC,
    fErase: BOOL,
    rcPaint: RECT,
    fRestore: BOOL,
    fIncUpdate: BOOL,
    rgbReserved: [32]u8,
};

pub const WNDCLASSW = extern struct {
    style: UINT,
    lpfnWndProc: WNDPROC,
    cbClsExtra: c_int,
    cbWndExtra: c_int,
    hInstance: HINSTANCE,
    hIcon: ?HICON,
    hCursor: ?HCURSOR,
    hbrBackground: ?HBRUSH,
    lpszMenuName: ?LPCWSTR,
    lpszClassName: LPCWSTR,
};

// Window styles
pub const WS_OVERLAPPEDWINDOW: DWORD = 0x00CF0000;
pub const WS_VISIBLE: DWORD = 0x10000000;
pub const WS_CLIPCHILDREN: DWORD = 0x02000000;
pub const WS_CLIPSIBLINGS: DWORD = 0x04000000;
pub const WS_MAXIMIZEBOX: DWORD = 0x00010000;
pub const WS_MINIMIZEBOX: DWORD = 0x00020000;
pub const WS_THICKFRAME: DWORD = 0x00040000;
pub const WS_SYSMENU: DWORD = 0x00080000;
pub const WS_CAPTION: DWORD = 0x00C00000;

// Window messages
pub const WM_DESTROY: UINT = 0x0002;
pub const WM_SIZE: UINT = 0x0005;
pub const WM_SETFOCUS: UINT = 0x0007;
pub const WM_KILLFOCUS: UINT = 0x0008;
pub const WM_PAINT: UINT = 0x000F;
pub const WM_CLOSE: UINT = 0x0010;
pub const WM_KEYDOWN: UINT = 0x0100;
pub const WM_KEYUP: UINT = 0x0101;
pub const WM_CHAR: UINT = 0x0102;
pub const WM_SYSKEYDOWN: UINT = 0x0104;
pub const WM_SYSKEYUP: UINT = 0x0105;
pub const WM_SYSCHAR: UINT = 0x0106;
pub const WM_MOUSEMOVE: UINT = 0x0200;
pub const WM_LBUTTONDOWN: UINT = 0x0201;
pub const WM_LBUTTONUP: UINT = 0x0202;
pub const WM_RBUTTONDOWN: UINT = 0x0204;
pub const WM_RBUTTONUP: UINT = 0x0205;
pub const WM_MBUTTONDOWN: UINT = 0x0207;
pub const WM_MBUTTONUP: UINT = 0x0208;
pub const WM_MOUSEWHEEL: UINT = 0x020A;
pub const WM_MOUSEHWHEEL: UINT = 0x020E;
pub const WM_MOUSELEAVE: UINT = 0x02A3;
pub const WM_DPICHANGED: UINT = 0x02E0;
pub const WM_APP: UINT = 0x8000;

/// Custom message posted to the app's primary window when a clipboard
/// read request is complete and should be delivered to the core
/// surface on the main thread.
pub const WM_APP_CLIPBOARD_READ: UINT = WM_APP + 1;

/// Custom message posted by the IPC server thread when a new-window
/// request arrives from the CLI. wParam is unused; lParam carries a
/// pointer to an allocated, NUL-terminated UTF-8 arguments buffer that
/// the app thread takes ownership of.
pub const WM_APP_NEW_WINDOW: UINT = WM_APP + 2;

// Virtual key codes (subset used for modifiers)
pub const VK_SHIFT: i32 = 0x10;
pub const VK_CONTROL: i32 = 0x11;
pub const VK_MENU: i32 = 0x12;
pub const VK_LSHIFT: i32 = 0xA0;
pub const VK_RSHIFT: i32 = 0xA1;
pub const VK_LCONTROL: i32 = 0xA2;
pub const VK_RCONTROL: i32 = 0xA3;
pub const VK_LMENU: i32 = 0xA4;
pub const VK_RMENU: i32 = 0xA5;
pub const VK_CAPITAL: i32 = 0x14;
pub const VK_NUMLOCK: i32 = 0x90;
pub const VK_LWIN: i32 = 0x5B;
pub const VK_RWIN: i32 = 0x5C;

// Key state masks for GetKeyState
pub const MK_SHIFT: i32 = 0x0004;
pub const MK_CONTROL: i32 = 0x0008;
pub const MK_LBUTTON: i32 = 0x0001;
pub const MK_RBUTTON: i32 = 0x0002;
pub const MK_MBUTTON: i32 = 0x0010;

/// Set of possible errors.
pub const Error = error{
    W32Failed,
};

/// Result of a Win32 call that returns BOOL.
pub fn win32Bool(ok: BOOL) Error!void {
    if (ok == 0) return error.W32Failed;
}

// ------------------------------------------------------------------
// user32
// ------------------------------------------------------------------

pub const user32 = struct {
    pub extern "user32" fn RegisterClassW(lpWndClass: *const WNDCLASSW) u16;
    pub extern "user32" fn CreateWindowExW(
        dwExStyle: DWORD,
        lpClassName: LPCWSTR,
        lpWindowName: LPCWSTR,
        dwStyle: DWORD,
        x: c_int,
        y: c_int,
        nWidth: c_int,
        nHeight: c_int,
        hWndParent: ?HWND,
        hMenu: ?HMENU,
        hInstance: HINSTANCE,
        lpParam: ?*anyopaque,
    ) ?HWND;
    pub extern "user32" fn DefWindowProcW(
        hWnd: HWND,
        Msg: UINT,
        wParam: WPARAM_TYPE,
        lParam: LPARAM,
    ) callconv(.winapi) LRESULT;
    pub extern "user32" fn GetMessageW(lpMsg: *MSG, hWnd: ?HWND, wMsgFilterMin: UINT, wMsgFilterMax: UINT) BOOL;
    pub extern "user32" fn TranslateMessage(lpMsg: *const MSG) BOOL;
    pub extern "user32" fn DispatchMessageW(lpMsg: *const MSG) LRESULT;
    pub extern "user32" fn PostQuitMessage(nExitCode: c_int) void;
    pub extern "user32" fn PostMessageW(hWnd: ?HWND, Msg: UINT, wParam: WPARAM_TYPE, lParam: LPARAM) BOOL;
    pub extern "user32" fn GetDC(hWnd: ?HWND) ?HDC;
    pub extern "user32" fn ReleaseDC(hWnd: ?HWND, hDC: HDC) c_int;
    pub extern "user32" fn GetClientRect(hWnd: HWND, lpRect: *RECT) BOOL;
    pub extern "user32" fn SetWindowTextW(hWnd: HWND, lpString: LPCWSTR) BOOL;
    pub extern "user32" fn GetWindowTextLengthW(hWnd: HWND) c_int;
    pub extern "user32" fn GetWindowTextW(hWnd: HWND, lpString: LPWSTR, nMaxCount: c_int) c_int;
    pub extern "user32" fn SetFocus(hWnd: ?HWND) ?HWND;
    pub extern "user32" fn GetKeyState(nVirtKey: i32) i16;
    pub extern "user32" fn GetKeyboardState(lpKeyState: [*]u8) BOOL;
    pub extern "user32" fn MapVirtualKeyW(uCode: UINT, uMapType: UINT) UINT;
    pub extern "user32" fn GetCursorPos(lpPoint: *POINT) BOOL;
    pub extern "user32" fn ScreenToClient(hWnd: HWND, lpPoint: *POINT) BOOL;
    pub extern "user32" fn ClientToScreen(hWnd: HWND, lpPoint: *POINT) BOOL;
    pub extern "user32" fn BeginPaint(hWnd: HWND, lpPaint: *PAINTSTRUCT) HDC;
    pub extern "user32" fn EndPaint(hWnd: HWND, lpPaint: *const PAINTSTRUCT) BOOL;
    pub extern "user32" fn InvalidateRect(hWnd: ?HWND, lpRect: ?*const RECT, bErase: BOOL) BOOL;
    pub extern "user32" fn ShowWindow(hWnd: HWND, nCmdShow: c_int) BOOL;
    pub extern "user32" fn DestroyWindow(hWnd: HWND) BOOL;
    pub extern "user32" fn GetDpiForWindow(hWnd: HWND) UINT;
    pub extern "user32" fn TrackMouseEvent(lpEventTrack: *TRACKMOUSEEVENT) BOOL;
    pub extern "user32" fn GetAsyncKeyState(vKey: i32) i16;
    pub extern "user32" fn SetWindowLongPtrW(hWnd: HWND, nIndex: c_int, dwNewLong: LONG_PTR) LONG_PTR;
    pub extern "user32" fn GetWindowLongPtrW(hWnd: HWND, nIndex: c_int) LONG_PTR;
    pub extern "user32" fn ToUnicode(
        wVirtKey: UINT,
        wScanCode: UINT,
        lpKeyState: [*]const u8,
        pwszBuff: [*]u16,
        cchBuff: c_int,
        wFlags: UINT,
    ) c_int;

    pub const GWLP_USERDATA: c_int = -21;
    pub const GWLP_WNDPROC: c_int = -4;

    pub const SW_SHOW: c_int = 5;
    pub const SW_HIDE: c_int = 0;

    pub const TRACKMOUSEEVENT = extern struct {
        cbSize: DWORD,
        dwFlags: DWORD,
        hwndTrack: HWND,
        dwHoverTime: DWORD,
    };

    pub const TME_LEAVE: DWORD = 0x00000002;
};

// ------------------------------------------------------------------
// gdi32
// ------------------------------------------------------------------

pub const gdi32 = struct {
    pub extern "gdi32" fn BitBlt(
        hdc: HDC,
        x: c_int,
        y: c_int,
        cx: c_int,
        cy: c_int,
        hdcSrc: HDC,
        x1: c_int,
        y1: c_int,
        rop: DWORD,
    ) BOOL;
    pub extern "gdi32" fn SetDIBitsToDevice(
        hdc: HDC,
        xDest: c_int,
        yDest: c_int,
        w: DWORD,
        h: DWORD,
        xSrc: c_int,
        ySrc: c_int,
        uStartScan: UINT,
        cScanLines: UINT,
        lpvBits: *const anyopaque,
        lpbmi: *const BITMAPINFO,
        fuColorUse: UINT,
    ) c_int;
    pub extern "gdi32" fn CreateCompatibleDC(hdc: ?HDC) HDC;
    pub extern "gdi32" fn DeleteDC(hdc: HDC) BOOL;
    pub extern "gdi32" fn CreateDIBSection(
        hdc: ?HDC,
        pbmi: *const BITMAPINFO,
        usage: UINT,
        ppvBits: *?*anyopaque,
        hSection: ?*anyopaque,
        offset: DWORD,
    ) HGDIOBJ;
    pub extern "gdi32" fn DeleteObject(ho: HGDIOBJ) BOOL;
    pub extern "gdi32" fn SelectObject(hdc: HDC, h: HGDIOBJ) HGDIOBJ;
    pub extern "gdi32" fn GetObjectW(h: HGDIOBJ, c: c_int, pv: ?*anyopaque) c_int;

    pub const BI_RGB: DWORD = 0;
    pub const DIB_RGB_COLORS: UINT = 0;

    pub const BITMAPINFOHEADER = extern struct {
        biSize: DWORD,
        biWidth: LONG,
        biHeight: LONG,
        biPlanes: u16,
        biBitCount: u16,
        biCompression: DWORD,
        biSizeImage: DWORD,
        biXPelsPerMeter: LONG,
        biYPelsPerMeter: LONG,
        biClrUsed: DWORD,
        biClrImportant: DWORD,
    };

    pub const BITMAPINFO = extern struct {
        bmiHeader: BITMAPINFOHEADER,
        bmiColors: [1]u32,
    };

    pub const SRCCOPY: DWORD = 0x00CC0020;
};

// ------------------------------------------------------------------
// kernel32 (clipboard helpers)
// ------------------------------------------------------------------

pub const kernel32 = struct {
    pub extern "kernel32" fn GetModuleHandleW(lpModuleName: ?[*:0]const u16) ?HINSTANCE;
    pub extern "kernel32" fn GlobalAlloc(uFlags: UINT, dwBytes: usize) ?HGLOBAL;
    pub extern "kernel32" fn GlobalFree(hMem: HGLOBAL) ?HGLOBAL;
    pub extern "kernel32" fn GlobalLock(hMem: HGLOBAL) ?*anyopaque;
    pub extern "kernel32" fn GlobalUnlock(hMem: HGLOBAL) BOOL;
    pub extern "kernel32" fn GlobalSize(hMem: HGLOBAL) usize;
    pub extern "kernel32" fn CreateFileW(
        lpFileName: LPCWSTR,
        dwDesiredAccess: DWORD,
        dwShareMode: DWORD,
        lpSecurityAttributes: ?*anyopaque,
        dwCreationDisposition: DWORD,
        dwFlagsAndAttributes: DWORD,
        hTemplateFile: ?HANDLE,
    ) ?HANDLE;
    pub extern "kernel32" fn ReadFile(
        hFile: HANDLE,
        lpBuffer: *anyopaque,
        nNumberOfBytesToRead: DWORD,
        lpNumberOfBytesRead: ?*DWORD,
        lpOverlapped: ?*OVERLAPPED,
    ) BOOL;
    pub extern "kernel32" fn WriteFile(
        hFile: HANDLE,
        lpBuffer: *const anyopaque,
        nNumberOfBytesToWrite: DWORD,
        lpNumberOfBytesWritten: ?*DWORD,
        lpOverlapped: ?*OVERLAPPED,
    ) BOOL;
    pub extern "kernel32" fn CloseHandle(hObject: HANDLE) BOOL;
};

pub const WM_IME_STARTCOMPOSITION: UINT = 0x010D;
pub const WM_IME_ENDCOMPOSITION: UINT = 0x010E;
pub const WM_IME_COMPOSITION: UINT = 0x010F;
// Per the Windows SDK, WM_IME_KEYLAST has the same value as
// WM_IME_COMPOSITION.
pub const WM_IME_KEYLAST: UINT = 0x010F;

/// ImmGetCompositionStringW indices.
pub const GCS_COMPSTR: LONG = 0x0008;
pub const GCS_RESULTSTR: LONG = 0x0800;

// IME window class helper
pub const HIMC = *anyopaque;

/// OVERLAPPED structure for async I/O. Matches the Win32 definition.
pub const OVERLAPPED = extern struct {
    Internal: ULONG_PTR,
    InternalHigh: ULONG_PTR,
    DUMMYUNIONNAME: extern union {
        DUMMYSTRUCTNAME: extern struct {
            Offset: DWORD,
            OffsetHigh: DWORD,
        },
        Pointer: ?*anyopaque,
    },
    hEvent: ?HANDLE,
};

pub const imm32 = struct {
    pub extern "imm32" fn ImmGetContext(hwnd: HWND) ?HIMC;
    pub extern "imm32" fn ImmReleaseContext(hwnd: HWND, himc: ?HIMC) BOOL;
    pub extern "imm32" fn ImmGetCompositionStringW(
        himc: ?HIMC,
        dwIndex: LONG,
        lpBuf: ?*anyopaque,
        dwBufLen: DWORD,
    ) LONG;
};

/// Named pipe constants.
pub const PIPE_ACCESS_DUPLEX: DWORD = 0x00000003;
pub const PIPE_TYPE_MESSAGE: DWORD = 0x00000004;
pub const PIPE_READMODE_MESSAGE: DWORD = 0x00000002;
pub const PIPE_WAIT: DWORD = 0x00000000;
pub const NMPWAIT_USE_DEFAULT_WAIT: DWORD = 0x00000000;
pub const GENERIC_READ: DWORD = 0x80000000;
pub const GENERIC_WRITE: DWORD = 0x40000000;
pub const GENERIC_READ_WRITE: DWORD = GENERIC_READ | GENERIC_WRITE;
pub const OPEN_EXISTING: DWORD = 3;
pub const ERROR_PIPE_CONNECTED: u32 = 535;

/// ERROR_MORE_DATA — the pipe message is longer than the read buffer.
pub const ERROR_MORE_DATA: u32 = 234;
pub const INVALID_HANDLE_VALUE: HANDLE = @ptrFromInt(@as(usize, @bitCast(@as(isize, -1))));
pub const FALSE: BOOL = .FALSE;
pub const TRUE: BOOL = .TRUE;

pub const kernel32_pipe = struct {
    pub extern "kernel32" fn CreateNamedPipeW(
        lpName: LPCWSTR,
        dwOpenMode: DWORD,
        dwPipeMode: DWORD,
        nMaxInstances: DWORD,
        nOutBufferSize: DWORD,
        nInBufferSize: DWORD,
        nDefaultTimeOut: DWORD,
        lpSecurityAttributes: ?*anyopaque,
    ) HANDLE;
    pub extern "kernel32" fn ConnectNamedPipe(hNamedPipe: HANDLE, lpOverlapped: ?*OVERLAPPED) BOOL;
    pub extern "kernel32" fn DisconnectNamedPipe(hNamedPipe: HANDLE) BOOL;
    pub extern "kernel32" fn FlushFileBuffers(hFile: HANDLE) BOOL;
};

// GlobalAlloc flags
pub const GMEM_MOVEABLE: UINT = 0x0002;
pub const GMEM_ZEROINIT: UINT = 0x0040;

/// Default window position sentinel for CreateWindowEx.
pub const CW_USEDEFAULT: c_int = -2147483648;

/// GetLastError value when RegisterClassW fails because the class
/// was already registered (0x582).
pub const ERROR_CLASS_ALREADY_EXISTS: u32 = 1410;

// Clipboard formats
pub const CF_UNICODETEXT: UINT = 13;

pub const user32_clipboard = struct {
    pub extern "user32" fn OpenClipboard(hWndNewOwner: ?HWND) BOOL;
    pub extern "user32" fn CloseClipboard() BOOL;
    pub extern "user32" fn EmptyClipboard() BOOL;
    pub extern "user32" fn GetClipboardData(uFormat: UINT) ?HGLOBAL;
    pub extern "user32" fn SetClipboardData(uFormat: UINT, hMem: ?HGLOBAL) ?HGLOBAL;
    pub extern "user32" fn IsClipboardFormatAvailable(format: UINT) BOOL;
};

/// The WndProc for the main window.
pub const WndProc = WNDPROC;
