//! DirectWrite font face — skeleton.
//!
//! This module is the starting point for a DirectWrite backend described
//! in `docs/windows-directwrite.md`. It is **not yet wired into the
//! build** (`Backend.directwrite` does not exist yet); it exists as a
//! compilable skeleton so the interface shape can evolve without
//! touching the default FreeType path.
//!
//! The functions mirror `src/font/face/freetype.zig`'s `Face` interface
//! and return `error.NotImplemented` until the COM/DWrite bindings and
//! rasterization are implemented.

const std = @import("std");
const Allocator = std.mem.Allocator;
const font = @import("../main.zig");
const Glyph = font.Glyph;
const Library = font.Library;

pub const Error = error{ NotImplemented, InvalidFont };

/// A DirectWrite font face. The real implementation will hold COM
/// pointers (IDWriteFactory, IDWriteFontFace, ...); for now it only
/// stores the allocator and size to keep the interface shape.
pub const Face = struct {
    alloc: Allocator,
    size: font.face.DesiredSize,

    /// Initialize from a file path.
    pub fn initFile(
        lib: Library,
        path: [:0]const u8,
        index: i32,
        opts: font.face.Options,
    ) Error!Face {
        _ = lib;
        _ = path;
        _ = index;
        _ = opts;
        return error.NotImplemented;
    }

    /// Initialize from in-memory data.
    pub fn init(
        lib: Library,
        source: [:0]const u8,
        opts: font.face.Options,
    ) Error!Face {
        _ = lib;
        _ = source;
        _ = opts;
        return error.NotImplemented;
    }

    pub fn deinit(self: *Face) void {
        self.* = undefined;
    }

    /// Family name.
    pub fn name(self: *const Face, buf: []u8) Allocator.Error![]const u8 {
        _ = self;
        _ = buf;
        return error.NotImplemented;
    }

    pub fn syntheticBold(self: *const Face, opts: font.face.Options) Error!Face {
        _ = self;
        _ = opts;
        return error.NotImplemented;
    }

    pub fn syntheticItalic(self: *const Face, opts: font.face.Options) Error!Face {
        _ = self;
        _ = opts;
        return error.NotImplemented;
    }

    pub fn setSize(self: *Face, opts: font.face.Options) Error!void {
        self.size = opts.size;
    }

    pub fn setVariations(
        self: *Face,
        variations: []const font.face.Variation,
    ) Error!void {
        _ = self;
        _ = variations;
        return error.NotImplemented;
    }

    pub fn glyphIndex(self: Face, cp: u32) ?u32 {
        _ = self;
        _ = cp;
        return null;
    }

    pub fn hasColor(self: Face) bool {
        _ = self;
        return false;
    }

    pub fn isColorGlyph(self: *const Face, glyph_id: u32) bool {
        _ = self;
        _ = glyph_id;
        return false;
    }

    pub fn renderGlyph(
        self: Face,
        alloc: Allocator,
        atlas: *font.Atlas,
        glyph_index: u32,
        opts: font.Glyph.RenderOptions,
    ) Error!Glyph {
        _ = self;
        _ = alloc;
        _ = atlas;
        _ = glyph_index;
        _ = opts;
        return error.NotImplemented;
    }

    pub fn getMetrics(self: *Face) font.Metrics.FaceMetrics {
        _ = self;
        return std.mem.zeroes(font.Metrics.FaceMetrics);
    }

    pub fn copyTable(self: Face, alloc: Allocator, tag: *const [4]u8) Error!?[]u8 {
        _ = self;
        _ = alloc;
        _ = tag;
        return error.NotImplemented;
    }
};
