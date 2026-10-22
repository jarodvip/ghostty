//! Minimal WGL bindings and an offscreen OpenGL context for Windows.
//!
//! Ghostty's OpenGL renderer renders into a texture-backed framebuffer
//! and presents the frame to the apprt (either as a dma-buf on Linux
//! or as CPU memory). On Windows there is no dma-buf, so we only need
//! a valid OpenGL context to render into an offscreen FBO; the apprt
//! blits the CPU-readback pixels onto the window. This module provides
//! that context using WGL on a hidden window, so it never interferes
//! with the visible terminal window's pixel format.
//!
//! The device owns a `Window` (hidden HWND + its HDC). Each renderer
//! (one per terminal surface) creates its own `Context` (HGLRC) on the
//! device's HDC, mirroring the EGL design where the device owns the
//! display and each surface owns a context.

const std = @import("std");
const windows = std.os.windows;

pub const BOOL = windows.BOOL;
pub const DWORD = windows.DWORD;
pub const HDC = windows.HDC;
pub const HGLRC = windows.HGLRC;
pub const HINSTANCE = windows.HINSTANCE;
pub const HWND = windows.HWND;
pub const LPARAM = windows.LPARAM;
pub const LRESULT = windows.LONG_PTR;
pub const WPARAM = usize;
pub const WNDPROC = *const fn (hwnd: HWND, msg: u32, wparam: WPARAM, lparam: LPARAM) callconv(.winapi) LRESULT;

// ------------------------------------------------------------------
// Pixel format
// ------------------------------------------------------------------

/// Matches the Win32 PIXELFORMATDESCRIPTOR layout.
pub const PIXELFORMATDESCRIPTOR = extern struct {
    nSize: u16,
    nVersion: u16,
    dwFlags: DWORD,
    iPixelType: u8,
    cColorBits: u8,
    cRedBits: u8,
    cRedShift: u8,
    cGreenBits: u8,
    cGreenShift: u8,
    cBlueBits: u8,
    cBlueShift: u8,
    cAlphaBits: u8,
    cAlphaShift: u8,
    cAccumBits: u8,
    cAccumRedBits: u8,
    cAccumGreenBits: u8,
    cAccumBlueBits: u8,
    cAccumAlphaBits: u8,
    cDepthBits: u8,
    cStencilBits: u8,
    cAuxBuffers: u8,
    iLayerType: u8,
    bReserved: u8,
    dwLayerMask: DWORD,
    dwVisibleMask: DWORD,
    dwDamageMask: DWORD,
};

pub const PFD_DRAW_TO_WINDOW: DWORD = 0x00000004;
pub const PFD_SUPPORT_OPENGL: DWORD = 0x00000020;
pub const PFD_DOUBLEBUFFER: DWORD = 0x00000001;
pub const PFD_TYPE_RGBA: u8 = 0;
pub const PFD_MAIN_PLANE: u8 = 0;

/// Window class style: give each window its own DC so that the pixel
/// format set on it persists for the lifetime of the window.
pub const CS_OWNDC: u32 = 0x0020;

// WGL context attribute constants (WGL_ARB_create_context)
pub const WGL_CONTEXT_MAJOR_VERSION_ARB: c_int = 0x2091;
pub const WGL_CONTEXT_MINOR_VERSION_ARB: c_int = 0x2092;
pub const WGL_CONTEXT_PROFILE_MASK_ARB: c_int = 0x9126;
pub const WGL_CONTEXT_CORE_PROFILE_BIT_ARB: c_int = 0x00000001;
pub const WGL_CONTEXT_FLAGS_ARB: c_int = 0x2094;
pub const WGL_CONTEXT_FORWARD_COMPATIBLE_BIT_ARB: c_int = 0x00000002;

// Window class name for the hidden offscreen window.
const hidden_class_name: [11:0]u16 = .{ 'G', 'h', 'o', 's', 't', 't', 'y', 'W', 'G', 'L', 0 };

// ------------------------------------------------------------------
// GDI / user32 / opengl32 / kernel32 externs
// ------------------------------------------------------------------

pub const gdi32 = struct {
    pub extern "gdi32" fn ChoosePixelFormat(
        hdc: HDC,
        ppfd: *const PIXELFORMATDESCRIPTOR,
    ) c_int;
    pub extern "gdi32" fn SetPixelFormat(
        hdc: HDC,
        iPixelFormat: c_int,
        ppfd: *const PIXELFORMATDESCRIPTOR,
    ) BOOL;
    pub extern "gdi32" fn SwapBuffers(hdc: HDC) BOOL;
};

pub const user32 = struct {
    pub extern "user32" fn GetDC(hwnd: ?HWND) ?HDC;
    pub extern "user32" fn ReleaseDC(hwnd: ?HWND, hdc: HDC) c_int;
    pub extern "user32" fn RegisterClassW(lpWndClass: *const WNDCLASSW) u16;
    pub extern "user32" fn CreateWindowExW(
        dwExStyle: DWORD,
        lpClassName: [*:0]const u16,
        lpWindowName: [*:0]const u16,
        dwStyle: DWORD,
        x: c_int,
        y: c_int,
        nWidth: c_int,
        nHeight: c_int,
        hWndParent: ?HWND,
        hMenu: ?*anyopaque,
        hInstance: HINSTANCE,
        lpParam: ?*anyopaque,
    ) ?HWND;
    pub extern "user32" fn DefWindowProcW(
        hwnd: HWND,
        msg: u32,
        wparam: WPARAM,
        lparam: LPARAM,
    ) callconv(.winapi) LRESULT;
    pub extern "user32" fn DestroyWindow(hwnd: HWND) BOOL;
};

pub const opengl32 = struct {
    pub extern "opengl32" fn wglCreateContext(hdc: HDC) ?HGLRC;
    pub extern "opengl32" fn wglDeleteContext(hglrc: HGLRC) BOOL;
    pub extern "opengl32" fn wglMakeCurrent(hdc: ?HDC, hglrc: ?HGLRC) BOOL;
    pub extern "opengl32" fn wglGetProcAddress(name: [*:0]const u8) ?*const anyopaque;
};

pub const kernel32 = struct {
    pub extern "kernel32" fn GetModuleHandleW(lpModuleName: ?[*:0]const u16) ?HINSTANCE;
    pub extern "kernel32" fn GetModuleHandleA(lpModuleName: ?[*:0]const u8) ?HINSTANCE;
    pub extern "kernel32" fn GetProcAddress(hModule: ?HINSTANCE, lpProcName: [*:0]const u8) ?*anyopaque;
};

/// WGL_ARB_create_context is an extension; load the entry points via
/// wglGetProcAddress. These are not direct DLL exports.
pub const CreateContextAttribsARB = *const fn (
    hdc: HDC,
    shareContext: ?HGLRC,
    attribList: [*]const c_int,
) callconv(.winapi) ?HGLRC;

pub const WNDCLASSW = extern struct {
    style: u32,
    lpfnWndProc: WNDPROC,
    cbClsExtra: c_int,
    cbWndExtra: c_int,
    hInstance: HINSTANCE,
    hIcon: ?*anyopaque,
    hCursor: ?*anyopaque,
    hbrBackground: ?*anyopaque,
    lpszMenuName: ?[*:0]const u16,
    lpszClassName: [*:0]const u16,
};

/// Wrap wglGetProcAddress for GLAD. GLAD passes the name of the GL
/// function to load and expects a callconv(.c) function pointer.
///
/// wglGetProcAddress only resolves extension functions (and some core
/// functions); the core OpenGL 1.1 entry points (e.g. glGetString,
/// glClear) must be loaded from opengl32.dll via GetProcAddress.
/// GLAD uses this to load the full GL API, so we try WGL first and
/// fall back to the DLL export. GetModuleHandleA/GetProcAddress are
/// cheap and thread-safe, so we query them on every call rather than
/// caching a module handle in a global.
pub fn getProcAddress(name: [*:0]const u8) callconv(.c) ?*const fn () callconv(.c) void {
    if (opengl32.wglGetProcAddress(name)) |p| {
        return @ptrCast(p);
    }

    const h = kernel32.GetModuleHandleA("opengl32.dll") orelse return null;
    const p = kernel32.GetProcAddress(h, name) orelse return null;
    return @ptrCast(p);
}

/// The hidden window + device context that all WGL contexts in a
/// process/device share. Owned by the renderer device.
pub const Window = struct {
    hwnd: HWND,
    hdc: HDC,

    pub fn create(alloc: std.mem.Allocator) !*Window {
        const self = try alloc.create(Window);
        errdefer alloc.destroy(self);

        // Register the hidden window class once per process.
        const hinstance = kernel32.GetModuleHandleW(null) orelse return error.WGLGetModuleHandleFailed;
        const cls = WNDCLASSW{
            .style = CS_OWNDC,
            .lpfnWndProc = wndProc,
            .cbClsExtra = 0,
            .cbWndExtra = 0,
            .hInstance = hinstance,
            .hIcon = null,
            .hCursor = null,
            .hbrBackground = null,
            .lpszMenuName = null,
            .lpszClassName = &hidden_class_name,
        };
        _ = user32.RegisterClassW(&cls);

        const hwnd = user32.CreateWindowExW(
            0,
            &hidden_class_name,
            &hidden_class_name,
            0, // no style: hidden
            0,
            0,
            1,
            1,
            null,
            null,
            hinstance,
            null,
        ) orelse return error.WGLCreateWindowFailed;
        errdefer _ = user32.DestroyWindow(hwnd);

        const hdc = user32.GetDC(hwnd) orelse return error.WGLGetDCFailed;
        errdefer _ = user32.ReleaseDC(hwnd, hdc);

        // Set an RGBA pixel format suitable for OpenGL. We don't request
        // a double buffer because Ghostty reads the framebuffer back to
        // CPU memory and blits it; there is no swap chain on this path.
        var pfd = std.mem.zeroes(PIXELFORMATDESCRIPTOR);
        pfd.nSize = @sizeOf(PIXELFORMATDESCRIPTOR);
        pfd.nVersion = 1;
        pfd.dwFlags = PFD_DRAW_TO_WINDOW | PFD_SUPPORT_OPENGL;
        pfd.iPixelType = PFD_TYPE_RGBA;
        pfd.cColorBits = 32;
        pfd.cAlphaBits = 8;
        pfd.iLayerType = PFD_MAIN_PLANE;

        const format = gdi32.ChoosePixelFormat(hdc, &pfd);
        if (format == 0) return error.WGLChoosePixelFormatFailed;
        if (gdi32.SetPixelFormat(hdc, format, &pfd) == .FALSE) return error.WGLSetPixelFormatFailed;

        self.* = .{ .hwnd = hwnd, .hdc = hdc };
        return self;
    }

    pub fn destroy(self: *Window, alloc: std.mem.Allocator) void {
        _ = user32.ReleaseDC(self.hwnd, self.hdc);
        _ = user32.DestroyWindow(self.hwnd);
        alloc.destroy(self);
    }
};

/// A WGL rendering context, bound to a device's HDC. Created per
/// terminal surface (renderer), mirroring EGL context-per-surface.
pub const Context = struct {
    hdc: HDC,
    hglrc: HGLRC,

    pub fn create(hdc: HDC) !Context {
        // Prefer a 4.3 core profile context via WGL_ARB_create_context;
        // fall back to wglCreateContext.
        const hglrc_opt: ?HGLRC = try createContextAttribs(hdc);
        const hglrc = hglrc_opt orelse
            (opengl32.wglCreateContext(hdc) orelse return error.WGLCreateContextFailed);
        return .{ .hdc = hdc, .hglrc = hglrc };
    }

    pub fn makeCurrent(self: *const Context) !void {
        if (opengl32.wglMakeCurrent(self.hdc, self.hglrc) == .FALSE) {
            return error.WGLMakeCurrentFailed;
        }
    }

    pub fn releaseCurrent() void {
        _ = opengl32.wglMakeCurrent(null, null);
    }

    pub fn destroy(self: *const Context) void {
        _ = opengl32.wglDeleteContext(self.hglrc);
    }
};

/// WndProc for the hidden window. WGL only needs a window DC so a
/// default handler suffices.
fn wndProc(hwnd: HWND, msg: u32, wparam: WPARAM, lparam: LPARAM) callconv(.winapi) LRESULT {
    return user32.DefWindowProcW(hwnd, msg, wparam, lparam);
}

/// Create a WGL context with a 4.3 core profile using
/// WGL_ARB_create_context if available.
fn createContextAttribs(hdc: HDC) !?HGLRC {
    const proc: CreateContextAttribsARB = @ptrCast(
        opengl32.wglGetProcAddress("wglCreateContextAttribsARB") orelse return null,
    );
    const attribs = [_]c_int{
        WGL_CONTEXT_MAJOR_VERSION_ARB, 4,
        WGL_CONTEXT_MINOR_VERSION_ARB,   3,
        WGL_CONTEXT_PROFILE_MASK_ARB,     WGL_CONTEXT_CORE_PROFILE_BIT_ARB,
        0,
    };
    return proc(hdc, null, &attribs);
}