//! DirectWrite font face.
//!
//! Implements the `Face` interface from `src/font/face.zig` using
//! DirectWrite (see `docs/windows-directwrite.md`). This is a first
//! functional milestone:
//!
//! - Implemented: file loading, family name (via the SFNT 'name' table),
//!   glyph lookup, color detection, table access (for HarfBuzz), face
//!   metrics, synthetic bold/italic, and HarfBuzz font creation.
//! - Not yet implemented: `renderGlyph` (rasterization via
//!   `GetGlyphRunOutline`/`IDWriteGlyphRunAnalysis`), in-memory `init`
//!   (requires a custom `IDWriteFontFileStream`), and variable-font axes
//!   (`setVariations`).
//!
//! The face keeps the raw font file bytes in memory; they back the
//! HarfBuzz blob and are copied for synthetic faces.

const std = @import("std");
const Allocator = std.mem.Allocator;
const harfbuzz = @import("harfbuzz");
const dwrite = @import("../directwrite.zig");
const quirks = @import("../../quirks.zig");
const compat_file = @import("../../lib/compat/file.zig");
const global = @import("../../global.zig");
const font = @import("../main.zig");
const Glyph = font.Glyph;
const Library = font.Library;

pub const Error = error{
    OutOfMemory,
    NotImplemented,
    InvalidFont,
    DirectWriteFailed,
    HarfbuzzFailed,
    VariableFontUnsupported,
};

/// HarfBuzz C functions not exposed by the Zig binding.
extern fn hb_face_create(blob: ?*anyopaque, index: c_uint) ?*anyopaque;
extern fn hb_face_destroy(face: ?*anyopaque) void;
extern fn hb_font_create(face: ?*anyopaque) ?*anyopaque;
extern fn hb_font_destroy(font: ?*anyopaque) void;
extern fn hb_font_set_scale(font: ?*anyopaque, x: c_int, y: c_int) void;
extern fn hb_font_set_variations(
    font: ?*anyopaque,
    variations: [*]const HbVariation,
    variations_length: c_uint,
) void;
extern fn hb_face_create_for_tables(
    reference_table_func: *const fn (face: ?*anyopaque, tag: u32, user_data: ?*anyopaque) callconv(.c) ?*anyopaque,
    user_data: ?*anyopaque,
) ?*anyopaque;
extern fn hb_blob_create(
    data: [*]const u8,
    length: c_uint,
    mode: c_int,
    user_data: ?*anyopaque,
    destroy: ?*const fn (?*anyopaque) callconv(.c) void,
) ?*anyopaque;

/// A HarfBuzz variation (hb_variation_t): tag is big-endian (hb_tag_t).
const HbVariation = extern struct {
    tag: u32,
    value: f32,
};

/// Heap table data owned by a HarfBuzz blob created from `copyTable`.
const HbTableData = struct {
    alloc: Allocator,
    data: []u8,
};

/// Stable user data for `hb_face_create_for_tables`; lives on the heap so
/// it does not dangle after face initialization returns.
const HbUserData = struct {
    alloc: Allocator,
    font_face: *dwrite.IDWriteFontFace,
};

/// Copy an SFNT table from a DirectWrite font face.
fn copyTableFromFace(
    alloc: Allocator,
    font_face: *dwrite.IDWriteFontFace,
    tag: *const [4]u8,
) Error!?[]u8 {
    // DWrite expects the OpenType tag as a host-endian packed u32 with
    // the first character in the low byte (see DWRITE_MAKE_OPENTYPE_TAG),
    // unlike HarfBuzz/FreeType which use big-endian tags.
    const tag_u32 =
        (@as(u32, tag[3]) << 24) |
        (@as(u32, tag[2]) << 16) |
        (@as(u32, tag[1]) << 8) |
        @as(u32, tag[0]);

    var data: ?*const anyopaque = null;
    var size: u32 = 0;
    var ctx: ?*anyopaque = null;
    var exists: dwrite.BOOL = dwrite.FALSE;
    if (!dwrite.succeeded(font_face.TryGetFontTable(tag_u32, &data, &size, &ctx, &exists)))
        return error.DirectWriteFailed;
    defer if (ctx) |c| font_face.ReleaseFontTable(c);

    if (exists != dwrite.TRUE or size == 0 or data == null) return null;
    const bytes: []const u8 = @as([*]const u8, @ptrCast(data.?))[0..size];
    return try alloc.dupe(u8, bytes);
}

fn destroyTableData(user_data: ?*anyopaque) callconv(.c) void {
    const td: *HbTableData = @ptrCast(@alignCast(user_data.?));
    td.alloc.free(td.data);
    td.alloc.destroy(td);
}

fn hbReferenceTable(face: ?*anyopaque, tag: u32, user_data: ?*anyopaque) callconv(.c) ?*anyopaque {
    _ = face;
    const ud: *HbUserData = @ptrCast(@alignCast(user_data.?));
    const tag_bytes: [4]u8 = .{
        @truncate(tag >> 24),
        @truncate(tag >> 16),
        @truncate(tag >> 8),
        @truncate(tag),
    };
    const table = (copyTableFromFace(ud.alloc, ud.font_face, &tag_bytes) catch return null) orelse
        return null;
    if (table.len == 0) return null;

    const td = ud.alloc.create(HbTableData) catch {
        ud.alloc.free(table);
        return null;
    };
    td.* = .{ .alloc = ud.alloc, .data = table };
    return hb_blob_create(
        td.data.ptr,
        @intCast(td.data.len),
        2, // HB_MEMORY_MODE_READONLY
        td,
        destroyTableData,
    );
}

/// A DirectWrite font face.
pub const Face = struct {
    /// Allocator used for face-owned data (the font file bytes).
    alloc: Allocator,

    /// The font library, holding the process-wide IDWriteFactory.
    lib: Library,

    /// The DirectWrite font face.
    font_face: *dwrite.IDWriteFontFace,

    /// Raw font file bytes, owned here. Used for the HarfBuzz blob and
    /// copied when creating synthetic faces.
    data: []u8,

    /// Harfbuzz font corresponding to this face.
    hb_font: harfbuzz.Font,

    /// The blob backing the HarfBuzz face, when created from file bytes.
    /// Null when the face was created from an IDWriteFont (HarfBuzz uses
    /// the table callback instead).
    hb_blob: ?harfbuzz.Blob,

    /// Stable user data for the HarfBuzz table callback (IDWriteFont path).
    hb_user_data: ?*HbUserData = null,

    /// The current size this font is set to.
    size: font.face.DesiredSize,

    /// Set to true to apply a synthetic italic/bold to the face.
    synthetic: packed struct {
        italic: bool = false,
        bold: bool = false,
    } = .{},

    /// Set quirks.disableDefaultFontFeatures
    quirks_disable_default_font_features: bool = false,

    /// Memory font file loader, non-null when this face was created from
    /// in-memory data. Keeps the loader (and its allocator) alive for the
    /// face's lifetime.
    loader: ?*dwrite.MemoryFontFileLoader = null,

    /// Initialize a new font face from a file path.
    pub fn initFile(
        lib: Library,
        path: [:0]const u8,
        index: i32,
        opts: font.face.Options,
    ) Error!Face {
        // Read the font bytes once; they back the HarfBuzz blob and are
        // kept for synthetic-face copies.
        const file = std.Io.Dir.cwd().openFile(global.io(), path, .{}) catch
            return error.InvalidFont;
        defer file.close(global.io());

        const data = compat_file.readToEndAlloc(file, lib.alloc, std.math.maxInt(usize)) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidFont,
        };
        errdefer lib.alloc.free(data);

        // Convert the path to UTF-16 (with a NUL terminator) for DWrite.
        const utf16_src = std.unicode.utf8ToUtf16LeAlloc(lib.alloc, path) catch
            return error.InvalidFont;
        defer lib.alloc.free(utf16_src);

        const path_w = lib.alloc.alloc(u16, utf16_src.len + 1) catch
            return error.OutOfMemory;
        defer lib.alloc.free(path_w);
        @memcpy(path_w[0..utf16_src.len], utf16_src);
        path_w[utf16_src.len] = 0;
        const path_z: [*:0]const u16 = @ptrCast(path_w.ptr);

        var font_file: ?*dwrite.IDWriteFontFile = null;
        if (!dwrite.succeeded(lib.factory.CreateFontFileReference(path_z, null, &font_file)))
            return error.InvalidFont;
        errdefer _ = font_file.?.Release();

        const face_index: u32 = if (index < 0) 0 else @intCast(index);
        const files = [_]*dwrite.IDWriteFontFile{font_file.?};
        var font_face: ?*dwrite.IDWriteFontFace = null;
        if (!dwrite.succeeded(lib.factory.CreateFontFace(
            .unknown,
            1,
            &files,
            face_index,
            .{},
            &font_face,
        ))) return error.InvalidFont;
        errdefer _ = font_face.?.Release();

        return try initFace(lib, data, font_face.?, face_index, opts);
    }

    /// Initialize a new font face from in-memory data.
    pub fn init(
        lib: Library,
        source: [:0]const u8,
        opts: font.face.Options,
    ) Error!Face {
        // Copy the font bytes; they back both the memory font file stream
        // and the HarfBuzz blob.
        const data = try lib.alloc.dupe(u8, source);
        errdefer lib.alloc.free(data);

        // Create a memory loader, register it, and register the data as a
        // custom font file reference. DirectWrite requires custom loaders
        // to be registered before use.
        const loader = try dwrite.MemoryFontFileLoader.create(lib.alloc, data);
        errdefer _ = loader.Release();
        if (!dwrite.succeeded(lib.factory.RegisterFontFileLoader(@ptrCast(loader))))
            return error.InvalidFont;
        errdefer _ = lib.factory.UnregisterFontFileLoader(@ptrCast(loader));

        const slice: []const u8 = data;
        var font_file: ?*dwrite.IDWriteFontFile = null;
        if (!dwrite.succeeded(lib.factory.CreateCustomFontFileReference(
            @ptrCast(&slice),
            @sizeOf([]const u8),
            @ptrCast(loader),
            &font_file,
        ))) return error.InvalidFont;
        errdefer _ = font_file.?.Release();

        const files = [_]*dwrite.IDWriteFontFile{font_file.?};
        var font_face: ?*dwrite.IDWriteFontFace = null;
        if (!dwrite.succeeded(lib.factory.CreateFontFace(
            .unknown,
            1,
            &files,
            0,
            .{},
            &font_face,
        ))) return error.InvalidFont;
        errdefer _ = font_face.?.Release();

        var face = try initFace(lib, data, font_face.?, 0, opts);
        face.loader = loader;
        return face;
    }

    /// Initialize a font face from an existing IDWriteFont (used by
    /// DirectWrite discovery). HarfBuzz uses the table callback so no
    /// file bytes are needed.
    pub fn initFont(lib: Library, dwrite_font: *dwrite.IDWriteFont, opts: font.face.Options) Error!Face {
        var font_face: ?*dwrite.IDWriteFontFace = null;
        if (!dwrite.succeeded(dwrite_font.CreateFontFace(&font_face)))
            return error.InvalidFont;
        errdefer _ = font_face.?.Release();

        return initFaceFromFontFace(lib, font_face.?, opts);
    }

    pub fn deinit(self: *Face) void {
        self.hb_font.destroy();
        if (self.hb_blob) |*b| b.destroy();
        _ = self.font_face.Release();
        if (self.hb_user_data) |ud| self.lib.alloc.destroy(ud);
        if (self.loader) |l| {
            _ = self.lib.factory.UnregisterFontFileLoader(@ptrCast(l));
            _ = l.Release();
        }
        self.lib.alloc.free(self.data);
        self.* = undefined;
    }

    /// Returns the font family name by parsing the SFNT 'name' table.
    /// If allocation is required, buf will be used.
    pub fn name(self: *const Face, buf: []u8) Error![]const u8 {
        const table = (try self.copyTable(self.alloc, "name")) orelse return "";
        defer self.alloc.free(table);
        return parseNameTable(table, buf);
    }

    /// Return a new face that is the same as this but also has synthetic
    /// bold applied (via DWRITE_FONT_SIMULATIONS_BOLD).
    pub fn syntheticBold(self: *const Face, opts: font.face.Options) Error!Face {
        return self.syntheticFace(opts, .{ .bold = true });
    }

    /// Return a new face that is the same as this but has a synthetic
    /// italic applied (via DWRITE_FONT_SIMULATIONS_OBLIQUE).
    pub fn syntheticItalic(self: *const Face, opts: font.face.Options) Error!Face {
        return self.syntheticFace(opts, .{ .oblique = true });
    }

    /// Create a new face with the given DirectWrite font simulations.
    fn syntheticFace(
        self: *const Face,
        opts: font.face.Options,
        simulations: dwrite.DWRITE_FONT_SIMULATIONS,
    ) Error!Face {
        var file_count: u32 = 0;
        if (!dwrite.succeeded(self.font_face.GetFiles(&file_count, null)))
            return error.DirectWriteFailed;
        if (file_count == 0) return error.InvalidFont;

        var files: [1]*dwrite.IDWriteFontFile = undefined;
        const files_ptr: [*]*dwrite.IDWriteFontFile = @ptrCast(&files);
        if (!dwrite.succeeded(self.font_face.GetFiles(&file_count, files_ptr)))
            return error.DirectWriteFailed;
        defer _ = files[0].Release();

        const face_index = self.font_face.GetIndex();

        var new_face: ?*dwrite.IDWriteFontFace = null;
        if (!dwrite.succeeded(self.lib.factory.CreateFontFace(
            .unknown,
            1,
            &files,
            face_index,
            simulations,
            &new_face,
        ))) return error.DirectWriteFailed;
        errdefer _ = new_face.?.Release();

        // Use the same canonical discriminator as setVariations: a face
        // created from an IDWriteFont has hb_user_data set (table callback),
        // while file-bytes faces have hb_blob set and hb_user_data null.
        var face = if (self.hb_user_data == null) blk: {
            // File-bytes path: copy the data for the new face's HarfBuzz
            // font.
            const data = self.lib.alloc.dupe(u8, self.data) catch
                return error.OutOfMemory;
            errdefer self.lib.alloc.free(data);
            break :blk try initFace(self.lib, data, new_face.?, face_index, opts);
        } else blk: {
            // IDWriteFont path: keep the table-callback HarfBuzz face.
            break :blk try initFaceFromFontFace(self.lib, new_face.?, opts);
        };
        errdefer face.deinit();
        face.synthetic = self.synthetic;
        if (simulations.bold) face.synthetic.bold = true;
        if (simulations.oblique) face.synthetic.italic = true;
        return face;
    }

    /// Resize the font in-place. If this succeeds, the caller is responsible
    /// for clearing any glyph caches, font atlas data, etc.
    pub fn setSize(self: *Face, opts: font.face.Options) Error!void {
        self.size = opts.size;
        const pixels: u32 = @intFromFloat(@round(opts.size.pixels()));
        hb_font_set_scale(@ptrCast(self.hb_font.handle), @intCast(pixels), @intCast(pixels));
    }

    /// Set the variation axes for this font.
    ///
    /// This creates a new IDWriteFontFace with the requested axis values via
    /// IDWriteFontResource::CreateFontFace and also updates the HarfBuzz
    /// font's variations.
    pub fn setVariations(
        self: *Face,
        variations: []const font.face.Variation,
        opts: font.face.Options,
    ) Error!void {
        _ = opts;
        if (variations.len == 0) return;

        var values_buf: [64]dwrite.DWRITE_FONT_AXIS_VALUE = undefined;
        const count = @min(values_buf.len, variations.len);
        for (variations[0..count], 0..) |v, i| {
            values_buf[i] = .{
                // DWrite axis tags use DWRITE_MAKE_OPENTYPE_TAG (little-endian
                // packed), the opposite byte order of Ghostty's Variation.Id.
                .axisTag = @byteSwap(@as(u32, @bitCast(v.id))),
                .value = @floatCast(v.value),
            };
        }

        // QI to IDWriteFontFace5 and get the font resource.
        var font_face5: ?*dwrite.IDWriteFontFace5 = null;
        if (!dwrite.succeeded(self.font_face.QueryInterface(
            &dwrite.IID_IDWriteFontFace5,
            @ptrCast(&font_face5),
        ))) return error.VariableFontUnsupported;
        defer _ = font_face5.?.Release();

        var resource: ?*dwrite.IDWriteFontResource = null;
        if (!dwrite.succeeded(font_face5.?.GetFontResource(&resource)))
            return error.DirectWriteFailed;
        defer _ = resource.?.Release();

        // Create a new font face with the axis values applied.
        var new_face5: ?*dwrite.IDWriteFontFace5 = null;
        if (!dwrite.succeeded(resource.?.CreateFontFace(
            .{},
            &values_buf,
            @intCast(count),
            &new_face5,
        ))) return error.DirectWriteFailed;

        // Point the HarfBuzz table callback at the new face BEFORE releasing
        // the old one, so there is no window where it could dereference a
        // released COM object.
        const new_face: *dwrite.IDWriteFontFace = @ptrCast(new_face5.?);
        if (self.hb_user_data) |ud| {
            ud.font_face = new_face;
        }
        _ = self.font_face.Release();
        self.font_face = new_face;

        // Update the HarfBuzz font variations for shaping.
        var hb_variations: [64]HbVariation = undefined;
        for (variations[0..count], 0..) |v, i| {
            hb_variations[i] = .{
                .tag = @as(u32, @bitCast(v.id)),
                .value = @floatCast(v.value),
            };
        }
        hb_font_set_variations(
            @ptrCast(self.hb_font.handle),
            &hb_variations,
            @intCast(count),
        );
    }

    /// Returns the glyph index for the given Unicode code point. If this
    /// face doesn't support this glyph, null is returned.
    pub fn glyphIndex(self: Face, cp: u32) ?u32 {
        var glyph: u16 = 0;
        const cps: [*]const u32 = @ptrCast(&cp);
        const glyphs: [*]u16 = @ptrCast(&glyph);
        _ = self.font_face.GetGlyphIndices(cps, 1, glyphs);
        if (glyph == 0) return null;
        return glyph;
    }

    /// Returns true if this font is colored. This can be used by callers to
    /// determine what kind of atlas to pass in.
    pub fn hasColor(self: Face) bool {
        return self.hasTable("COLR") or
            self.hasTable("CBDT") or
            self.hasTable("sbix") or
            self.hasTable("SVG ");
    }

    /// Returns true if the given glyph ID is colorized.
    ///
    /// TODO: Determine per-glyph color (COLR base glyph records, CBDT/CBLC
    /// bitmap presence). Until rendering is implemented, report false.
    pub fn isColorGlyph(self: *const Face, glyph_id: u32) bool {
        _ = self;
        _ = glyph_id;
        return false;
    }

    /// Render a glyph using the glyph index. The rendered glyph is stored in
    /// the given texture atlas.
    ///
    /// Rasterization uses `IDWriteGlyphRunAnalysis` (grayscale alpha
    /// coverage). Color glyphs (emoji) are not supported yet.
    pub fn renderGlyph(
        self: Face,
        alloc: Allocator,
        atlas: *font.Atlas,
        glyph_index: u32,
        opts: font.Glyph.RenderOptions,
    ) !Glyph {
        // IDWriteGlyphRunAnalysis only produces grayscale alpha; color
        // glyphs (COLR/CBDT/sbix/SVG) are not supported yet.
        if (atlas.format != .grayscale) return error.WrongAtlas;

        const em_size = self.size.pixels();
        const metrics = opts.grid_metrics;
        const cell_height: f64 = @floatFromInt(metrics.cell_height);
        const cell_baseline: f64 = @floatFromInt(metrics.cell_baseline);

        const glyph_id: u16 = @intCast(glyph_index);
        const glyphs: [*]const u16 = @ptrCast(&glyph_id);

        const identity = dwrite.DWRITE_MATRIX{
            .m11 = 1,
            .m12 = 0,
            .m21 = 0,
            .m22 = 1,
            .dx = 0,
            .dy = 0,
        };

        // Fast path: an unconstrained glyph renders at its natural size,
        // so no measurement pass is needed (single glyph run analysis).
        if (!opts.constraint.doesAnything()) {
            return self.rasterize(glyphs, em_size, cell_height, cell_baseline, &identity, alloc, atlas);
        }

        // Measure the glyph's hint-adjusted black box at the requested size
        // using an identity transform. This is relative to the baseline and
        // feeds the constraint system.
        const natural = try self.measureGlyph(glyphs, em_size, cell_height, cell_baseline);
        if (natural.width < 0.25 or natural.height < 0.25) {
            return font.Glyph{
                .width = 0,
                .height = 0,
                .offset_x = 0,
                .offset_y = 0,
                .atlas_x = 0,
                .atlas_y = 0,
            };
        }

        // Apply the constraint (scaling/alignment) to the natural bounds.
        const glyph_size = opts.constraint.constrain(natural, metrics, opts.constraint_width);

        // Compute the transform that maps the natural bounds to the
        // constrained bounds. Coordinates are relative to the baseline with
        // +Y up, matching DirectWrite's outline coordinate space.
        const scale_x = if (natural.width > 0) glyph_size.width / natural.width else 1.0;
        const scale_y = if (natural.height > 0) glyph_size.height / natural.height else 1.0;
        const matrix = dwrite.DWRITE_MATRIX{
            .m11 = @floatCast(scale_x),
            .m12 = 0,
            .m21 = 0,
            .m22 = @floatCast(scale_y),
            .dx = @floatCast(glyph_size.x - natural.x * scale_x),
            .dy = @floatCast(glyph_size.y - natural.y * scale_y),
        };

        return self.rasterize(glyphs, em_size, cell_height, cell_baseline, &matrix, alloc, atlas);
    }

    /// Measure the natural bounds of a single glyph at the given em size.
    /// Returns the black box relative to the baseline (Glyph.Size convention:
    /// `x` is the left edge, `y` is the bottom edge, +Y up).
    fn measureGlyph(
        self: Face,
        glyphs: [*]const u16,
        em_size: f64,
        cell_height: f64,
        cell_baseline: f64,
    ) !Glyph.Size {
        // Use a baseline origin of 0 so the returned bounds are directly
        // relative to the baseline.
        const analysis = try self.createAnalysis(glyphs, em_size, cell_height, cell_baseline, null, 0);
        defer _ = analysis.Release();

        var bounds: dwrite.RECT = undefined;
        if (!dwrite.succeeded(analysis.GetAlphaTextureBounds(.cleartype_3x1, &bounds)))
            return error.DirectWriteFailed;

        // The bounds are in surface coordinates with the baseline at Y=0
        // (+Y down). Convert to Glyph.Size (+Y up): the top edge is above
        // the baseline (negative surface Y), the bottom edge is below
        // (positive surface Y).
        return Glyph.Size{
            .x = @floatFromInt(bounds.left),
            .width = @as(f64, @floatFromInt(bounds.right - bounds.left)),
            .height = @as(f64, @floatFromInt(bounds.bottom - bounds.top)),
            .y = -@as(f64, @floatFromInt(bounds.bottom)),
        };
    }

    /// Rasterize a single glyph with the given transform and copy the alpha
    /// coverage into the atlas.
    fn rasterize(
        self: Face,
        glyphs: [*]const u16,
        em_size: f64,
        cell_height: f64,
        cell_baseline: f64,
        matrix: *const dwrite.DWRITE_MATRIX,
        alloc: Allocator,
        atlas: *font.Atlas,
    ) !Glyph {
        const baseline_origin_y: f32 = @floatCast(cell_height - cell_baseline);
        const analysis = try self.createAnalysis(glyphs, em_size, cell_height, cell_baseline, matrix, baseline_origin_y);
        defer _ = analysis.Release();

        var bounds: dwrite.RECT = undefined;
        if (!dwrite.succeeded(analysis.GetAlphaTextureBounds(.cleartype_3x1, &bounds)))
            return error.DirectWriteFailed;
        if (bounds.right <= bounds.left or bounds.bottom <= bounds.top) {
            return font.Glyph{
                .width = 0,
                .height = 0,
                .offset_x = 0,
                .offset_y = 0,
                .atlas_x = 0,
                .atlas_y = 0,
            };
        }

        const width: u32 = @intCast(bounds.right - bounds.left);
        const height: u32 = @intCast(bounds.bottom - bounds.top);

        // ClearType 3x1 texture: three sub-pixel bytes per pixel. Convert
        // to grayscale by averaging the RGB channels.
        const ct_size = width * height * 3;
        const ct = try alloc.alloc(u8, ct_size);
        defer alloc.free(ct);
        if (!dwrite.succeeded(analysis.CreateAlphaTexture(
            .cleartype_3x1,
            &bounds,
            ct.ptr,
            @intCast(ct_size),
        ))) return error.DirectWriteFailed;

        const alpha = try alloc.alloc(u8, width * height);
        defer alloc.free(alpha);
        for (0..width * height) |i| {
            const r: u32 = ct[i * 3];
            const g: u32 = ct[i * 3 + 1];
            const b: u32 = ct[i * 3 + 2];
            alpha[i] = @intCast((r + g + b) / 3);
        }

        const region = try atlas.reserve(alloc, width, height);
        atlas.set(region, alpha);

        // offset_x: left edge of the glyph relative to the cell's left edge
        // (the baseline origin is at x=0).
        const offset_x: i32 = bounds.left;
        // offset_y: distance from the bottom of the cell to the top of the
        // glyph. `bounds.top` is the glyph's top in surface coordinates
        // (the baseline is at cell_height - cell_baseline from the top).
        const offset_y: i32 = @as(i32, @intFromFloat(cell_height)) - bounds.top;

        return Glyph{
            .width = width,
            .height = height,
            .offset_x = offset_x,
            .offset_y = offset_y,
            .atlas_x = region.x,
            .atlas_y = region.y,
        };
    }

    /// Create a glyph run analysis for a single glyph.
    fn createAnalysis(
        self: Face,
        glyphs: [*]const u16,
        em_size: f64,
        cell_height: f64,
        cell_baseline: f64,
        matrix: ?*const dwrite.DWRITE_MATRIX,
        baseline_origin_y: f32,
    ) !*dwrite.IDWriteGlyphRunAnalysis {
        _ = cell_height;
        _ = cell_baseline;
        const glyph_run = dwrite.DWRITE_GLYPH_RUN{
            .fontFace = self.font_face,
            .fontEmSize = @floatCast(em_size),
            .glyphCount = 1,
            .glyphIndices = glyphs,
            .glyphAdvances = null,
            .glyphOffsets = null,
            .isSideways = dwrite.FALSE,
            .bidiLevel = 0,
        };

        var analysis: ?*dwrite.IDWriteGlyphRunAnalysis = null;
        if (!dwrite.succeeded(self.lib.factory.CreateGlyphRunAnalysis(
            &glyph_run,
            1.0,
            matrix,
            .natural,
            .natural,
            0,
            baseline_origin_y,
            &analysis,
        ))) return error.DirectWriteFailed;

        return analysis.?;
    }

    /// Get the `FaceMetrics` for this face.
    pub fn getMetrics(self: *Face) font.Metrics.FaceMetrics {
        var m: dwrite.DWRITE_FONT_METRICS = undefined;
        self.font_face.GetMetrics(&m);
        if (m.designUnitsPerEm == 0) {
            return std.mem.zeroes(font.Metrics.FaceMetrics);
        }

        const px_per_em = self.size.pixels();
        const px_per_unit = px_per_em / @as(f64, @floatFromInt(m.designUnitsPerEm));

        return .{
            .px_per_em = px_per_em,
            .cell_width = self.measureAsciiWidth(px_per_unit),
            .ascent = @as(f64, @floatFromInt(m.ascent)) * px_per_unit,
            .descent = -@as(f64, @floatFromInt(m.descent)) * px_per_unit,
            .line_gap = @as(f64, @floatFromInt(m.lineGap)) * px_per_unit,
            .underline_position = @as(f64, @floatFromInt(m.underlinePosition)) * px_per_unit,
            .underline_thickness = @as(f64, @floatFromInt(m.underlineThickness)) * px_per_unit,
            .strikethrough_position = @as(f64, @floatFromInt(m.strikethroughPosition)) * px_per_unit,
            .strikethrough_thickness = @as(f64, @floatFromInt(m.strikethroughThickness)) * px_per_unit,
            .cap_height = if (m.capHeight != 0)
                @as(f64, @floatFromInt(m.capHeight)) * px_per_unit
            else
                null,
            .ex_height = if (m.xHeight != 0)
                @as(f64, @floatFromInt(m.xHeight)) * px_per_unit
            else
                null,
            .ic_width = self.measureIcWidth(px_per_unit),
        };
    }

    /// Measure the widest advance of printable ASCII characters, used as
    /// the cell width.
    fn measureAsciiWidth(self: *const Face, px_per_unit: f64) f64 {
        var max_advance: f64 = 0.0;
        var c: u8 = ' ';
        while (c < 127) : (c += 1) {
            const glyph = self.glyphIndex(@intCast(c)) orelse continue;
            const glyph_id: u16 = @intCast(glyph);
            const glyphs: [*]const u16 = @ptrCast(&glyph_id);
            var gm: dwrite.DWRITE_GLYPH_METRICS = undefined;
            const out: [*]dwrite.DWRITE_GLYPH_METRICS = @ptrCast(&gm);
            if (!dwrite.succeeded(self.font_face.GetDesignGlyphMetrics(glyphs, 1, out, dwrite.FALSE)))
                continue;
            max_advance = @max(
                max_advance,
                @as(f64, @floatFromInt(gm.advanceWidth)) * px_per_unit,
            );
        }

        // If no ASCII glyph could be measured, fall back to a crude width.
        if (max_advance == 0.0) max_advance = 0.5 * self.size.pixels();
        return max_advance;
    }

    /// Measure the advance of "水" (CJK water ideograph, U+6C34) for our
    /// ic width, if the glyph is present.
    fn measureIcWidth(self: *const Face, px_per_unit: f64) ?f64 {
        const glyph = self.glyphIndex(0x6C34) orelse return null;
        const glyph_id: u16 = @intCast(glyph);
        const glyphs: [*]const u16 = @ptrCast(&glyph_id);
        var gm: dwrite.DWRITE_GLYPH_METRICS = undefined;
        const out: [*]dwrite.DWRITE_GLYPH_METRICS = @ptrCast(&gm);
        if (!dwrite.succeeded(self.font_face.GetDesignGlyphMetrics(glyphs, 1, out, dwrite.FALSE)))
            return null;
        const width = @as(f64, @floatFromInt(gm.advanceWidth)) * px_per_unit;
        if (width <= 0) return null;
        return width;
    }

    /// Copy an SFNT table (for HarfBuzz). Returns null if the table does
    /// not exist in the font.
    pub fn copyTable(self: Face, alloc: Allocator, tag: *const [4]u8) Error!?[]u8 {
        return copyTableFromFace(alloc, self.font_face, tag);
    }

    /// Returns true if the font contains the given SFNT table.
    fn hasTable(self: Face, tag: *const [4]u8) bool {
        // See copyTable for the byte-order note.
        const tag_u32 =
            (@as(u32, tag[3]) << 24) |
            (@as(u32, tag[2]) << 16) |
            (@as(u32, tag[1]) << 8) |
            @as(u32, tag[0]);

        var data: ?*const anyopaque = null;
        var size: u32 = 0;
        var ctx: ?*anyopaque = null;
        var exists: dwrite.BOOL = dwrite.FALSE;
        if (!dwrite.succeeded(self.font_face.TryGetFontTable(tag_u32, &data, &size, &ctx, &exists)))
            return false;
        defer if (ctx) |c| self.font_face.ReleaseFontTable(c);
        return exists == dwrite.TRUE;
    }
};

/// Initialize a face from an existing IDWriteFontFace without file bytes;
/// HarfBuzz accesses tables through the reference-table callback.
fn initFaceFromFontFace(
    lib: Library,
    font_face: *dwrite.IDWriteFontFace,
    opts: font.face.Options,
) Error!Face {
    var result: Face = .{
        .alloc = lib.alloc,
        .lib = lib,
        .font_face = font_face,
        .data = &.{},
        .hb_blob = null,
        .hb_font = undefined,
        .size = opts.size,
    };

    // Note: `font_face` ownership stays with the caller; on error the
    // caller's errdefer releases it (same convention as `initFace`).

    // The table callback needs stable user data; a stack address would
    // dangle once this function returns.
    const ud = try lib.alloc.create(HbUserData);
    errdefer lib.alloc.destroy(ud);
    ud.* = .{ .alloc = lib.alloc, .font_face = font_face };
    result.hb_user_data = ud;

    const hb_face = hb_face_create_for_tables(hbReferenceTable, ud) orelse
        return error.HarfbuzzFailed;
    defer hb_face_destroy(hb_face);

    const hb_font_handle = hb_font_create(hb_face) orelse
        return error.HarfbuzzFailed;
    errdefer hb_font_destroy(hb_font_handle);

    const pixels: u32 = @intFromFloat(@round(opts.size.pixels()));
    hb_font_set_scale(hb_font_handle, @intCast(pixels), @intCast(pixels));

    result.hb_font = .{ .handle = @ptrCast(hb_font_handle) };
    result.quirks_disable_default_font_features = quirks.disableDefaultFontFeatures(&result);
    return result;
}

/// Shared initialization: store the face data, create the HarfBuzz font,
/// and set the initial size.
fn initFace(
    lib: Library,
    data: []u8,
    font_face: *dwrite.IDWriteFontFace,
    index: u32,
    opts: font.face.Options,
) Error!Face {
    // HarfBuzz makes its own copy of the data (DUPLICATE mode), so the
    // face's `data` buffer can be freed independently at deinit.
    var blob = try harfbuzz.Blob.create(data, .duplicate);
    errdefer blob.destroy();

    const hb_face = hb_face_create(@ptrCast(blob.handle), index) orelse
        return error.HarfbuzzFailed;
    defer hb_face_destroy(hb_face);

    const hb_font_handle = hb_font_create(hb_face) orelse
        return error.HarfbuzzFailed;
    errdefer hb_font_destroy(hb_font_handle);

    const pixels: u32 = @intFromFloat(@round(opts.size.pixels()));
    hb_font_set_scale(hb_font_handle, @intCast(pixels), @intCast(pixels));

    var result: Face = .{
        .alloc = lib.alloc,
        .lib = lib,
        .font_face = font_face,
        .data = data,
        .hb_blob = blob,
        .hb_font = .{ .handle = @ptrCast(hb_font_handle) },
        .size = opts.size,
    };
    result.quirks_disable_default_font_features = quirks.disableDefaultFontFeatures(&result);
    return result;
}

/// Parse the SFNT 'name' table and return name ID 1 (font family).
/// Prefers the Microsoft Unicode (3,1) record; falls back to Macintosh
/// Roman (1,0,0). Returns "" if no usable family record is found.
fn parseNameTable(table: []const u8, buf: []u8) Error![]const u8 {
    if (table.len < 6) return "";
    const count = std.mem.readInt(u16, table[2..4], .big);
    const string_offset = std.mem.readInt(u16, table[4..6], .big);
    if (table.len < 6 + @as(usize, count) * 12) return "";

    var fallback: ?[]const u8 = null;
    for (0..count) |i| {
        const rec = table[6 + i * 12 .. 6 + (i + 1) * 12];
        const platform_id = std.mem.readInt(u16, rec[0..2], .big);
        const encoding_id = std.mem.readInt(u16, rec[2..4], .big);
        const language_id = std.mem.readInt(u16, rec[4..6], .big);
        const name_id = std.mem.readInt(u16, rec[6..8], .big);
        const length = std.mem.readInt(u16, rec[8..10], .big);
        const offset = std.mem.readInt(u16, rec[10..12], .big);

        if (name_id != 1) continue;

        const start = @as(usize, string_offset) + offset;
        if (start + length > table.len) continue;
        const str = table[start .. start + length];

        // Microsoft Unicode BMP: convert UTF-16BE to UTF-8.
        if (platform_id == 3 and encoding_id == 1) {
            return utf16beToUtf8(str, buf);
        }

        // Macintosh Roman: fallback, returned as raw bytes.
        if (platform_id == 1 and encoding_id == 0 and language_id == 0) {
            fallback = str;
        }
    }

    return fallback orelse "";
}

/// Convert a big-endian UTF-16 byte sequence to UTF-8 in `buf`.
fn utf16beToUtf8(str: []const u8, buf: []u8) Error![]const u8 {
    if (str.len % 2 != 0) return "";
    const unit_count = str.len / 2;
    if (unit_count > 512) return "";

    var tmp: [512]u16 = undefined;
    for (0..unit_count) |i| {
        tmp[i] = (@as(u16, str[i * 2]) << 8) | @as(u16, str[i * 2 + 1]);
    }

    const len = std.unicode.utf16LeToUtf8(buf, tmp[0..unit_count]) catch return "";
    return buf[0..len];
}