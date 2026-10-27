//! A library represents the shared state that the underlying font
//! library implementation(s) require per-process.
const std = @import("std");
const Allocator = std.mem.Allocator;
const options = @import("main.zig").options;
const freetype = @import("freetype");
const directwrite = @import("directwrite.zig");
const font = @import("main.zig");

/// Library implementation for the compile options.
pub const Library = switch (options.backend) {
    // Freetype requires a state library
    .freetype,
    .freetype_windows,
    .fontconfig_freetype,
    .coretext_freetype,
    => FreetypeLibrary,

    // DirectWrite keeps a per-process IDWriteFactory.
    .directwrite => DirectWriteLibrary,

    // Some backends such as CT and Canvas don't have a "library"
    .coretext,
    .coretext_harfbuzz,
    .coretext_noshape,
    .web_canvas,
    => NoopLibrary,
};

pub const FreetypeLibrary = struct {
    lib: freetype.Library,

    alloc: Allocator,

    /// Mutex to be held any time the library is
    /// being used to create or destroy a face.
    mutex: *std.Io.Mutex,

    pub const InitError = freetype.Error || Allocator.Error;

    pub fn init(alloc: Allocator) InitError!Library {
        const lib = try freetype.Library.init();
        errdefer lib.deinit();

        const mutex = try alloc.create(std.Io.Mutex);
        mutex.* = .init;

        return Library{ .lib = lib, .alloc = alloc, .mutex = mutex };
    }

    pub fn deinit(self: *Library) void {
        self.alloc.destroy(self.mutex);
        self.lib.deinit();
    }
};

/// DirectWrite keeps a per-process IDWriteFactory, created lazily on the
/// first Library init and released when the last Library deinits.
pub const DirectWriteLibrary = struct {
    alloc: Allocator,
    factory: *directwrite.IDWriteFactory,

    /// True if this Library's `comInit` actually initialized COM; only then
    /// may we call `comUninit` in deinit.
    com_owned: bool,

    pub const InitError = directwrite.Error || Allocator.Error;

    pub fn init(alloc: Allocator) InitError!Library {
        const com_owned = try directwrite.comInit();
        errdefer if (com_owned) directwrite.comUninit();
        const factory = try directwrite.createFactory();
        return Library{ .alloc = alloc, .factory = factory, .com_owned = com_owned };
    }

    pub fn deinit(self: *Library) void {
        _ = self.factory.Release();
        if (self.com_owned) directwrite.comUninit();
        self.* = undefined;
    }
};

pub const NoopLibrary = struct {
    pub const InitError = error{};

    pub fn init(alloc: Allocator) InitError!Library {
        _ = alloc;
        return Library{};
    }

    pub fn deinit(self: *Library) void {
        _ = self;
    }
};
