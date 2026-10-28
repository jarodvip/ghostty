//! Minimal DirectWrite COM bindings.
//!
//! DirectWrite is a COM API exposed by dwrite.dll. Zig's stdlib does not
//! yet provide COM or DirectWrite bindings, so this module hand-declares
//! the subset of interfaces the DirectWrite font backend needs, following
//! the same manual-binding approach used elsewhere in the Win32 port.
//!
//! The vtable layouts follow the MinGW-w64 `dwrite.h` (WIDL) definitions,
//! which match the ABI of dwrite.dll.

const std = @import("std");

/// Win32 BOOL is a 32-bit integer in the C ABI; using `c_int` directly
/// keeps the vtable bindings ABI-correct regardless of how the Zig
/// stdlib models `windows.BOOL`.
pub const BOOL = c_int;
pub const FALSE: BOOL = 0;
pub const TRUE: BOOL = 1;
pub const HRESULT = c_long;

/// Success check for an HRESULT.
pub inline fn succeeded(hr: HRESULT) bool {
    return hr >= 0;
}

/// A COM GUID (REFIID).
pub const Guid = extern struct {
    data1: u32,
    data2: u16,
    data3: u16,
    data4: [8]u8,
};

/// IID_IDWriteFactory.
pub const IID_IDWriteFactory = Guid{
    .data1 = 0xb859ee5a,
    .data2 = 0xd838,
    .data3 = 0x4b5b,
    .data4 = .{ 0xa2, 0xe8, 0x1a, 0xdc, 0x7d, 0x93, 0xdb, 0x48 },
};

/// Possible errors from DirectWrite/COM operations.
pub const Error = error{
    ComInitFailed,
    DirectWriteFailed,
};

/// COM IUnknown. Every DirectWrite interface begins with this vtable.
pub const IUnknown = extern struct {
    vtbl: *const Vtbl,

    pub const Vtbl = extern struct {
        QueryInterface: *const fn (
            self: *IUnknown,
            riid: *const Guid,
            ppvObject: ?*?*anyopaque,
        ) callconv(.winapi) HRESULT,
        AddRef: *const fn (self: *IUnknown) callconv(.winapi) u32,
        Release: *const fn (self: *IUnknown) callconv(.winapi) u32,
    };

    pub inline fn Release(self: *IUnknown) u32 {
        return self.vtbl.Release(self);
    }
};

/// DWRITE_FONT_FACE_TYPE.
pub const DWRITE_FONT_FACE_TYPE = enum(c_int) {
    cff = 0,
    truetype = 1,
    opentype_collection = 2,
    type1 = 3,
    vector = 4,
    bitmap = 5,
    unknown = 6,
    raw_cff = 7,
};

/// DWRITE_FONT_SIMULATIONS (bit flags).
pub const DWRITE_FONT_SIMULATIONS = packed struct(u32) {
    bold: bool = false,
    oblique: bool = false,
    _: u30 = 0,
};

/// DWRITE_FONT_METRICS.
pub const DWRITE_FONT_METRICS = extern struct {
    designUnitsPerEm: u16,
    ascent: u16,
    descent: u16,
    lineGap: i16,
    capHeight: u16,
    xHeight: u16,
    underlinePosition: i16,
    underlineThickness: u16,
    strikethroughPosition: i16,
    strikethroughThickness: u16,
};

/// DWRITE_GLYPH_METRICS.
pub const DWRITE_GLYPH_METRICS = extern struct {
    leftSideBearing: i32,
    advanceWidth: u32,
    rightSideBearing: i32,
    topSideBearing: i32,
    advanceHeight: u32,
    bottomSideBearing: i32,
    verticalOriginY: i32,
};

/// DWRITE_GLYPH_OFFSET.
pub const DWRITE_GLYPH_OFFSET = extern struct {
    advanceOffset: f32,
    ascenderOffset: f32,
};

/// DWRITE_FONT_AXIS_VALUE — a variable-font axis setting.
pub const DWRITE_FONT_AXIS_VALUE = extern struct {
    axisTag: u32,
    value: f32,
};

/// Placeholder for vtable slots we don't call.
const PlaceholderFn = *const fn () callconv(.winapi) HRESULT;

/// DWRITE_MATRIX — transform applied to a glyph run.
pub const DWRITE_MATRIX = extern struct {
    m11: f32,
    m12: f32,
    m21: f32,
    m22: f32,
    dx: f32,
    dy: f32,
};

/// DWRITE_GLYPH_RUN (MinGW/WIDL layout).
pub const DWRITE_GLYPH_RUN = extern struct {
    fontFace: *IDWriteFontFace,
    fontEmSize: f32,
    glyphCount: u32,
    glyphIndices: [*]const u16,
    glyphAdvances: ?[*]const f32,
    glyphOffsets: ?[*]const DWRITE_GLYPH_OFFSET,
    isSideways: BOOL,
    bidiLevel: u32,
};

/// Win32 RECT, used for alpha texture bounds.
pub const RECT = extern struct {
    left: i32,
    top: i32,
    right: i32,
    bottom: i32,
};

/// DWRITE_TEXTURE_TYPE.
pub const DWRITE_TEXTURE_TYPE = enum(c_int) {
    aliased_1x1 = 0,
    cleartype_3x1 = 1,
};

/// DWRITE_RENDERING_MODE.
pub const DWRITE_RENDERING_MODE = enum(c_int) {
    default = 0,
    aliased = 1,
    gdi_classic = 2,
    gdi_natural = 3,
    natural = 4,
    natural_symmetric = 5,
    outline = 6,
};

/// DWRITE_MEASURING_MODE.
pub const DWRITE_MEASURING_MODE = enum(c_int) {
    natural = 0,
    gdi_classic = 1,
    gdi_natural = 2,
};

/// IDWriteFactory — subset of the vtable used by the font backend.
pub const IDWriteFactory = extern struct {
    vtbl: *const Vtbl,

    pub const Vtbl = extern struct {
        base: IUnknown.Vtbl,

        // 3: GetSystemFontCollection
        GetSystemFontCollection: *const fn (
            self: *IDWriteFactory,
            fontCollection: *?*IDWriteFontCollection,
            checkForUpdates: BOOL,
        ) callconv(.winapi) HRESULT,

        // 4-6: font collection loaders (unused for now)
        CreateCustomFontCollection: *const fn (
            self: *IDWriteFactory,
            a: ?*anyopaque,
            b: ?*const anyopaque,
            c: u32,
            d: *?*anyopaque,
        ) callconv(.winapi) HRESULT,
        RegisterFontCollectionLoader: *const fn (
            self: *IDWriteFactory,
            a: ?*anyopaque,
        ) callconv(.winapi) HRESULT,
        UnregisterFontCollectionLoader: *const fn (
            self: *IDWriteFactory,
            a: ?*anyopaque,
        ) callconv(.winapi) HRESULT,

        // 7: CreateFontFileReference
        CreateFontFileReference: *const fn (
            self: *IDWriteFactory,
            filePath: [*:0]const u16,
            lastWriteTime: ?*const anyopaque,
            fontFile: *?*IDWriteFontFile,
        ) callconv(.winapi) HRESULT,

        // 8: CreateCustomFontFileReference
        CreateCustomFontFileReference: *const fn (
            self: *IDWriteFactory,
            fontFileReferenceKey: ?*const anyopaque,
            fontFileReferenceKeySize: u32,
            fontFileLoader: *IDWriteFontFileLoader,
            fontFile: *?*IDWriteFontFile,
        ) callconv(.winapi) HRESULT,

        // 9: CreateFontFace
        CreateFontFace: *const fn (
            self: *IDWriteFactory,
            fontFaceType: DWRITE_FONT_FACE_TYPE,
            numberOfFiles: u32,
            fontFiles: [*]const *IDWriteFontFile,
            faceIndex: u32,
            fontFaceSimulationFlags: DWRITE_FONT_SIMULATIONS,
            fontFace: *?*IDWriteFontFace,
        ) callconv(.winapi) HRESULT,

        // 10-22: rendering params, text layout, etc. (unused for now)
        CreateRenderingParams: *const fn (
            self: *IDWriteFactory,
            a: *?*anyopaque,
        ) callconv(.winapi) HRESULT,
        CreateMonitorRenderingParams: *const fn (
            self: *IDWriteFactory,
            a: ?*anyopaque,
            b: *?*anyopaque,
        ) callconv(.winapi) HRESULT,
        CreateCustomRenderingParams: *const fn (
            self: *IDWriteFactory,
            a: f32,
            b: f32,
            c: f32,
            d: u32,
            e: u32,
            f: *?*anyopaque,
        ) callconv(.winapi) HRESULT,
        // 13-14: font file loader registration
        RegisterFontFileLoader: *const fn (
            self: *IDWriteFactory,
            fontFileLoader: *IDWriteFontFileLoader,
        ) callconv(.winapi) HRESULT,
        UnregisterFontFileLoader: *const fn (
            self: *IDWriteFactory,
            fontFileLoader: *IDWriteFontFileLoader,
        ) callconv(.winapi) HRESULT,

        // 15: CreateTextFormat
        CreateTextFormat: *const fn (
            self: *IDWriteFactory,
            a: [*:0]const u16,
            b: ?*anyopaque,
            c: u32,
            d: u32,
            e: u32,
            f: f32,
            g: [*:0]const u16,
            h: *?*anyopaque,
        ) callconv(.winapi) HRESULT,

        // 16: CreateTypography
        CreateTypography: *const fn (
            self: *IDWriteFactory,
            a: *?*anyopaque,
        ) callconv(.winapi) HRESULT,
        GetGdiInterop: *const fn (
            self: *IDWriteFactory,
            a: *?*anyopaque,
        ) callconv(.winapi) HRESULT,
        CreateTextLayout: *const fn (
            self: *IDWriteFactory,
            a: [*]const u16,
            b: u32,
            c: ?*anyopaque,
            d: f32,
            e: f32,
            f: *?*anyopaque,
        ) callconv(.winapi) HRESULT,
        CreateGdiCompatibleTextLayout: *const fn (
            self: *IDWriteFactory,
            a: [*]const u16,
            b: u32,
            c: ?*anyopaque,
            d: f32,
            e: f32,
            f: ?*anyopaque,
            g: u32,
            h: ?*anyopaque,
            i: *?*anyopaque,
        ) callconv(.winapi) HRESULT,
        CreateEllipsisTrimmingSign: *const fn (
            self: *IDWriteFactory,
            a: ?*anyopaque,
            b: *?*anyopaque,
        ) callconv(.winapi) HRESULT,
        CreateTextAnalyzer: *const fn (
            self: *IDWriteFactory,
            a: *?*anyopaque,
        ) callconv(.winapi) HRESULT,
        CreateNumberSubstitution: *const fn (
            self: *IDWriteFactory,
            a: u32,
            b: [*:0]const u16,
            c: BOOL,
            d: *?*anyopaque,
        ) callconv(.winapi) HRESULT,

        // 23: CreateGlyphRunAnalysis
        CreateGlyphRunAnalysis: *const fn (
            self: *IDWriteFactory,
            glyphRun: *const DWRITE_GLYPH_RUN,
            pixelsPerDip: f32,
            transform: ?*const DWRITE_MATRIX,
            renderingMode: DWRITE_RENDERING_MODE,
            measuringMode: DWRITE_MEASURING_MODE,
            baselineOriginX: f32,
            baselineOriginY: f32,
            analysis: *?*IDWriteGlyphRunAnalysis,
        ) callconv(.winapi) HRESULT,
    };

    pub inline fn Release(self: *IDWriteFactory) u32 {
        return self.vtbl.base.Release(@ptrCast(self));
    }

    pub inline fn GetSystemFontCollection(
        self: *IDWriteFactory,
        font_collection: *?*IDWriteFontCollection,
        check_for_updates: BOOL,
    ) HRESULT {
        return self.vtbl.GetSystemFontCollection(self, font_collection, check_for_updates);
    }

    pub inline fn CreateFontFileReference(
        self: *IDWriteFactory,
        file_path: [*:0]const u16,
        last_write_time: ?*const anyopaque,
        font_file: *?*IDWriteFontFile,
    ) HRESULT {
        return self.vtbl.CreateFontFileReference(self, file_path, last_write_time, font_file);
    }

    pub inline fn CreateCustomFontFileReference(
        self: *IDWriteFactory,
        font_file_reference_key: ?*const anyopaque,
        font_file_reference_key_size: u32,
        font_file_loader: *IDWriteFontFileLoader,
        font_file: *?*IDWriteFontFile,
    ) HRESULT {
        return self.vtbl.CreateCustomFontFileReference(
            self,
            font_file_reference_key,
            font_file_reference_key_size,
            font_file_loader,
            font_file,
        );
    }

    pub inline fn CreateFontFace(
        self: *IDWriteFactory,
        font_face_type: DWRITE_FONT_FACE_TYPE,
        number_of_files: u32,
        font_files: [*]const *IDWriteFontFile,
        face_index: u32,
        simulations: DWRITE_FONT_SIMULATIONS,
        font_face: *?*IDWriteFontFace,
    ) HRESULT {
        return self.vtbl.CreateFontFace(
            self,
            font_face_type,
            number_of_files,
            font_files,
            face_index,
            simulations,
            font_face,
        );
    }

    pub inline fn CreateGlyphRunAnalysis(
        self: *IDWriteFactory,
        glyph_run: *const DWRITE_GLYPH_RUN,
        pixels_per_dip: f32,
        transform: ?*const DWRITE_MATRIX,
        rendering_mode: DWRITE_RENDERING_MODE,
        measuring_mode: DWRITE_MEASURING_MODE,
        baseline_origin_x: f32,
        baseline_origin_y: f32,
        analysis: *?*IDWriteGlyphRunAnalysis,
    ) HRESULT {
        return self.vtbl.CreateGlyphRunAnalysis(
            self,
            glyph_run,
            pixels_per_dip,
            transform,
            rendering_mode,
            measuring_mode,
            baseline_origin_x,
            baseline_origin_y,
            analysis,
        );
    }

    pub inline fn RegisterFontFileLoader(
        self: *IDWriteFactory,
        font_file_loader: *IDWriteFontFileLoader,
    ) HRESULT {
        return self.vtbl.RegisterFontFileLoader(self, font_file_loader);
    }

    pub inline fn UnregisterFontFileLoader(
        self: *IDWriteFactory,
        font_file_loader: *IDWriteFontFileLoader,
    ) HRESULT {
        return self.vtbl.UnregisterFontFileLoader(self, font_file_loader);
    }
};

/// IDWriteFontFile — only Release is used.
pub const IDWriteFontFile = extern struct {
    vtbl: *const Vtbl,

    pub const Vtbl = extern struct {
        base: IUnknown.Vtbl,

        GetReferenceKey: *const fn (
            self: *IDWriteFontFile,
            key: *?*const anyopaque,
            keySize: *u32,
        ) callconv(.winapi) HRESULT,

        GetLoader: *const fn (
            self: *IDWriteFontFile,
            loader: *?*anyopaque,
        ) callconv(.winapi) HRESULT,

        Analyze: *const fn (
            self: *IDWriteFontFile,
            isSupported: *BOOL,
            fileType: *u32,
            faceType: *u32,
            numberOfFaces: *u32,
        ) callconv(.winapi) HRESULT,
    };

    pub inline fn Release(self: *IDWriteFontFile) u32 {
        return self.vtbl.base.Release(@ptrCast(self));
    }
};

/// IDWriteFontFileLoader — creates font file streams from a reference key.
pub const IDWriteFontFileLoader = extern struct {
    vtbl: *const Vtbl,

    pub const Vtbl = extern struct {
        base: IUnknown.Vtbl,

        CreateStreamFromKey: *const fn (
            self: *IDWriteFontFileLoader,
            fontFileReferenceKey: ?*const anyopaque,
            fontFileReferenceKeySize: u32,
            fontFileStream: *?*IDWriteFontFileStream,
        ) callconv(.winapi) HRESULT,
    };

    pub inline fn AddRef(self: *IDWriteFontFileLoader) u32 {
        return self.vtbl.base.AddRef(@ptrCast(self));
    }

    pub inline fn CreateStreamFromKey(
        self: *IDWriteFontFileLoader,
        font_file_reference_key: ?*const anyopaque,
        font_file_reference_key_size: u32,
        font_file_stream: *?*IDWriteFontFileStream,
    ) HRESULT {
        return self.vtbl.CreateStreamFromKey(
            self,
            font_file_reference_key,
            font_file_reference_key_size,
            font_file_stream,
        );
    }

    pub inline fn Release(self: *IDWriteFontFileLoader) u32 {
        return self.vtbl.base.Release(@ptrCast(self));
    }
};

/// IDWriteFontFileStream — serves font file bytes to DirectWrite.
pub const IDWriteFontFileStream = extern struct {
    vtbl: *const Vtbl,

    pub const Vtbl = extern struct {
        base: IUnknown.Vtbl,

        ReadFileFragment: *const fn (
            self: *IDWriteFontFileStream,
            fragmentStart: *?*const anyopaque,
            fileOffset: u64,
            fragmentSize: u64,
            fragmentContext: *?*anyopaque,
        ) callconv(.winapi) HRESULT,

        ReleaseFileFragment: *const fn (
            self: *IDWriteFontFileStream,
            fragmentContext: ?*anyopaque,
        ) callconv(.winapi) void,

        GetFileSize: *const fn (
            self: *IDWriteFontFileStream,
            fileSize: *u64,
        ) callconv(.winapi) HRESULT,

        GetLastWriteTime: *const fn (
            self: *IDWriteFontFileStream,
            lastWriteTime: *u64,
        ) callconv(.winapi) HRESULT,
    };

    pub inline fn AddRef(self: *IDWriteFontFileStream) u32 {
        return self.vtbl.base.AddRef(@ptrCast(self));
    }

    pub inline fn Release(self: *IDWriteFontFileStream) u32 {
        return self.vtbl.base.Release(@ptrCast(self));
    }

    pub inline fn ReadFileFragment(
        self: *IDWriteFontFileStream,
        fragment_start: *?*const anyopaque,
        file_offset: u64,
        fragment_size: u64,
        fragment_context: *?*anyopaque,
    ) HRESULT {
        return self.vtbl.ReadFileFragment(
            self,
            fragment_start,
            file_offset,
            fragment_size,
            fragment_context,
        );
    }

    pub inline fn ReleaseFileFragment(self: *IDWriteFontFileStream, fragment_context: ?*anyopaque) void {
        self.vtbl.ReleaseFileFragment(self, fragment_context);
    }

    pub inline fn GetFileSize(self: *IDWriteFontFileStream, file_size: *u64) HRESULT {
        return self.vtbl.GetFileSize(self, file_size);
    }

    pub inline fn GetLastWriteTime(self: *IDWriteFontFileStream, last_write_time: *u64) HRESULT {
        return self.vtbl.GetLastWriteTime(self, last_write_time);
    }
};

/// IDWriteFontFace — vtable order follows the MinGW dwrite.h definitions:
///
/// 3 GetType, 4 GetFiles, 5 GetIndex, 6 GetSimulations, 7 IsSymbolFont,
/// 8 GetMetrics, 9 GetGlyphCount, 10 GetDesignGlyphMetrics,
/// 11 GetGlyphIndices, 12 TryGetFontTable, 13 ReleaseFontTable,
/// 14 GetGlyphRunOutline, 15 GetRecommendedRenderingMode,
/// 16 GetGdiCompatibleMetrics, 17 GetGdiCompatibleGlyphMetrics.
pub const IDWriteFontFace = extern struct {
    vtbl: *const Vtbl,

    pub const Vtbl = extern struct {
        base: IUnknown.Vtbl,

        // 3: GetType
        GetType: *const fn (self: *IDWriteFontFace) callconv(.winapi) DWRITE_FONT_FACE_TYPE,

        // 4: GetFiles — pass null fontFiles to query the count.
        GetFiles: *const fn (
            self: *IDWriteFontFace,
            numberOfFiles: *u32,
            fontFiles: ?[*]*IDWriteFontFile,
        ) callconv(.winapi) HRESULT,

        // 5: GetIndex (returns the index directly)
        GetIndex: *const fn (self: *IDWriteFontFace) callconv(.winapi) u32,

        // 6: GetSimulations
        GetSimulations: *const fn (self: *IDWriteFontFace) callconv(.winapi) u32,

        // 7: IsSymbolFont
        IsSymbolFont: *const fn (self: *IDWriteFontFace) callconv(.winapi) BOOL,

        // 8: GetMetrics (returns void)
        GetMetrics: *const fn (
            self: *IDWriteFontFace,
            fontFaceMetrics: *DWRITE_FONT_METRICS,
        ) callconv(.winapi) void,

        // 9: GetGlyphCount
        GetGlyphCount: *const fn (self: *IDWriteFontFace) callconv(.winapi) u16,

        // 10: GetDesignGlyphMetrics
        GetDesignGlyphMetrics: *const fn (
            self: *IDWriteFontFace,
            glyphIndices: [*]const u16,
            glyphCount: u32,
            glyphMetrics: [*]DWRITE_GLYPH_METRICS,
            isSideBearings: BOOL,
        ) callconv(.winapi) HRESULT,

        // 11: GetGlyphIndices
        GetGlyphIndices: *const fn (
            self: *IDWriteFontFace,
            codepoints: [*]const u32,
            codepointCount: u32,
            glyphIndices: [*]u16,
        ) callconv(.winapi) HRESULT,

        // 12: TryGetFontTable
        TryGetFontTable: *const fn (
            self: *IDWriteFontFace,
            openTypeTableTag: u32,
            tableData: *?*const anyopaque,
            tableSize: *u32,
            tableContext: *?*anyopaque,
            exists: *BOOL,
        ) callconv(.winapi) HRESULT,

        // 13: ReleaseFontTable
        ReleaseFontTable: *const fn (
            self: *IDWriteFontFace,
            tableContext: ?*anyopaque,
        ) callconv(.winapi) void,

        // 14-17: glyph run outline and rendering modes (unused for now)
        GetGlyphRunOutline: *const fn (
            self: *IDWriteFontFace,
            a: f32,
            b: [*]const u16,
            c: ?[*]const f32,
            d: ?*const anyopaque,
            e: u32,
            f: BOOL,
            g: BOOL,
            h: ?*anyopaque,
            i: ?*anyopaque,
        ) callconv(.winapi) HRESULT,
        GetRecommendedRenderingMode: *const fn (
            self: *IDWriteFontFace,
            a: f32,
            b: f32,
            c: f32,
            d: u32,
            e: *u32,
            f: *u32,
        ) callconv(.winapi) HRESULT,
        GetGdiCompatibleMetrics: *const fn (
            self: *IDWriteFontFace,
            a: f32,
            b: f32,
            c: ?*const anyopaque,
            d: *DWRITE_FONT_METRICS,
        ) callconv(.winapi) HRESULT,
        GetGdiCompatibleGlyphMetrics: *const fn (
            self: *IDWriteFontFace,
            a: f32,
            b: f32,
            c: ?*const anyopaque,
            d: BOOL,
            e: [*]const u16,
            f: u32,
            g: [*]DWRITE_GLYPH_METRICS,
            h: BOOL,
        ) callconv(.winapi) HRESULT,
    };

    pub inline fn Release(self: *IDWriteFontFace) u32 {
        return self.vtbl.base.Release(@ptrCast(self));
    }

    pub inline fn QueryInterface(
        self: *IDWriteFontFace,
        riid: *const Guid,
        ppv_object: ?*?*anyopaque,
    ) HRESULT {
        return self.vtbl.base.QueryInterface(@ptrCast(self), riid, ppv_object);
    }

    pub inline fn GetFiles(
        self: *IDWriteFontFace,
        number_of_files: *u32,
        font_files: ?[*]*IDWriteFontFile,
    ) HRESULT {
        return self.vtbl.GetFiles(self, number_of_files, font_files);
    }

    pub inline fn GetIndex(self: *IDWriteFontFace) u32 {
        return self.vtbl.GetIndex(self);
    }

    pub inline fn GetMetrics(self: *IDWriteFontFace, metrics: *DWRITE_FONT_METRICS) void {
        self.vtbl.GetMetrics(self, metrics);
    }

    pub inline fn GetDesignGlyphMetrics(
        self: *IDWriteFontFace,
        glyph_indices: [*]const u16,
        glyph_count: u32,
        glyph_metrics: [*]DWRITE_GLYPH_METRICS,
        is_side_bearings: BOOL,
    ) HRESULT {
        return self.vtbl.GetDesignGlyphMetrics(
            self,
            glyph_indices,
            glyph_count,
            glyph_metrics,
            is_side_bearings,
        );
    }

    pub inline fn GetGlyphIndices(
        self: *IDWriteFontFace,
        codepoints: [*]const u32,
        codepoint_count: u32,
        glyph_indices: [*]u16,
    ) HRESULT {
        return self.vtbl.GetGlyphIndices(self, codepoints, codepoint_count, glyph_indices);
    }

    pub inline fn TryGetFontTable(
        self: *IDWriteFontFace,
        open_type_table_tag: u32,
        table_data: *?*const anyopaque,
        table_size: *u32,
        table_context: *?*anyopaque,
        exists: *BOOL,
    ) HRESULT {
        return self.vtbl.TryGetFontTable(
            self,
            open_type_table_tag,
            table_data,
            table_size,
            table_context,
            exists,
        );
    }

    pub inline fn ReleaseFontTable(self: *IDWriteFontFace, table_context: ?*anyopaque) void {
        self.vtbl.ReleaseFontTable(self, table_context);
    }
};

/// IDWriteFontFace5 — adds variable-font support. The vtable extends
/// IDWriteFontFace (0-18) with IDWriteFontFace1-4 methods (19-53) and the
/// five IDWriteFontFace5 methods (54-58). We only call GetFontResource
/// (index 57), so the intermediate slots are placeholders.
pub const IDWriteFontFace5 = extern struct {
    vtbl: *const Vtbl,

    pub const Vtbl = extern struct {
        base: IDWriteFontFace.Vtbl,

        // IDWriteFontFace1 (12), IDWriteFontFace2 (5), IDWriteFontFace3 (14),
        // IDWriteFontFace4 (4), and the first three IDWriteFontFace5 methods
        // (GetFontAxisValueCount, GetFontAxisValues, HasVariations).
        _intermediate: [12 + 5 + 14 + 4 + 3]PlaceholderFn,

        // 57: GetFontResource
        GetFontResource: *const fn (
            self: *IDWriteFontFace5,
            resource: *?*IDWriteFontResource,
        ) callconv(.winapi) HRESULT,

        // 58: Equals
        Equals: *const fn (
            self: *IDWriteFontFace5,
            fontFace: ?*IDWriteFontFace,
        ) callconv(.winapi) BOOL,
    };

    pub inline fn Release(self: *IDWriteFontFace5) u32 {
        return self.vtbl.base.base.Release(@ptrCast(self));
    }

    pub inline fn GetFontResource(self: *IDWriteFontFace5, resource: *?*IDWriteFontResource) HRESULT {
        return self.vtbl.GetFontResource(self, resource);
    }
};

/// IDWriteFontResource — exposes variable-font axes. CreateFontFace (index
/// 13) creates a new font face with the given axis values.
pub const IDWriteFontResource = extern struct {
    vtbl: *const Vtbl,

    pub const Vtbl = extern struct {
        base: IUnknown.Vtbl,

        // Methods 3-12 (GetFontFile ... HasVariations).
        _intermediate: [10]PlaceholderFn,

        // 13: CreateFontFace
        CreateFontFace: *const fn (
            self: *IDWriteFontResource,
            fontFaceSimulationFlags: DWRITE_FONT_SIMULATIONS,
            fontAxisValues: [*]const DWRITE_FONT_AXIS_VALUE,
            fontAxisValueCount: u32,
            fontFace: *?*IDWriteFontFace5,
        ) callconv(.winapi) HRESULT,

        // 14: CreateFontFaceReference
        CreateFontFaceReference: PlaceholderFn,
    };

    pub inline fn Release(self: *IDWriteFontResource) u32 {
        return self.vtbl.base.Release(@ptrCast(self));
    }

    pub inline fn CreateFontFace(
        self: *IDWriteFontResource,
        font_face_simulation_flags: DWRITE_FONT_SIMULATIONS,
        font_axis_values: [*]const DWRITE_FONT_AXIS_VALUE,
        font_axis_value_count: u32,
        font_face: *?*IDWriteFontFace5,
    ) HRESULT {
        return self.vtbl.CreateFontFace(
            self,
            font_face_simulation_flags,
            font_axis_values,
            font_axis_value_count,
            font_face,
        );
    }
};

/// IDWriteGlyphRunAnalysis — produces the alpha coverage texture for a
/// glyph run.
pub const IDWriteGlyphRunAnalysis = extern struct {
    vtbl: *const Vtbl,

    pub const Vtbl = extern struct {
        base: IUnknown.Vtbl,

        GetAlphaTextureBounds: *const fn (
            self: *IDWriteGlyphRunAnalysis,
            textureType: DWRITE_TEXTURE_TYPE,
            bounds: *RECT,
        ) callconv(.winapi) HRESULT,

        CreateAlphaTexture: *const fn (
            self: *IDWriteGlyphRunAnalysis,
            textureType: DWRITE_TEXTURE_TYPE,
            bounds: *const RECT,
            alphaValues: [*]u8,
            bufferSize: u32,
        ) callconv(.winapi) HRESULT,

        GetAlphaBlendParams: *const fn (
            self: *IDWriteGlyphRunAnalysis,
            renderingParams: ?*anyopaque,
            blendGamma: *f32,
            blendEnhancedContrast: *f32,
            blendClearTypeLevel: *f32,
        ) callconv(.winapi) HRESULT,
    };

    pub inline fn Release(self: *IDWriteGlyphRunAnalysis) u32 {
        return self.vtbl.base.Release(@ptrCast(self));
    }

    pub inline fn GetAlphaTextureBounds(
        self: *IDWriteGlyphRunAnalysis,
        texture_type: DWRITE_TEXTURE_TYPE,
        bounds: *RECT,
    ) HRESULT {
        return self.vtbl.GetAlphaTextureBounds(self, texture_type, bounds);
    }

    pub inline fn CreateAlphaTexture(
        self: *IDWriteGlyphRunAnalysis,
        texture_type: DWRITE_TEXTURE_TYPE,
        bounds: *const RECT,
        alpha_values: [*]u8,
        buffer_size: u32,
    ) HRESULT {
        return self.vtbl.CreateAlphaTexture(self, texture_type, bounds, alpha_values, buffer_size);
    }
};

/// IDWriteLocalizedStrings — localized string table (family names etc.).
pub const IDWriteLocalizedStrings = extern struct {
    vtbl: *const Vtbl,

    pub const Vtbl = extern struct {
        base: IUnknown.Vtbl,

        GetCount: *const fn (self: *IDWriteLocalizedStrings) callconv(.winapi) u32,

        FindLocaleName: *const fn (
            self: *IDWriteLocalizedStrings,
            localeName: [*:0]const u16,
            index: *u32,
            exists: *BOOL,
        ) callconv(.winapi) HRESULT,

        GetLocaleNameLength: *const fn (
            self: *IDWriteLocalizedStrings,
            index: u32,
            length: *u32,
        ) callconv(.winapi) HRESULT,

        GetLocaleName: *const fn (
            self: *IDWriteLocalizedStrings,
            index: u32,
            localeName: [*]u16,
            size: u32,
        ) callconv(.winapi) HRESULT,

        GetStringLength: *const fn (
            self: *IDWriteLocalizedStrings,
            index: u32,
            length: *u32,
        ) callconv(.winapi) HRESULT,

        GetString: *const fn (
            self: *IDWriteLocalizedStrings,
            index: u32,
            buffer: [*]u16,
            size: u32,
        ) callconv(.winapi) HRESULT,
    };

    pub inline fn Release(self: *IDWriteLocalizedStrings) u32 {
        return self.vtbl.base.Release(@ptrCast(self));
    }

    pub inline fn GetCount(self: *IDWriteLocalizedStrings) u32 {
        return self.vtbl.GetCount(self);
    }

    pub inline fn GetStringLength(self: *IDWriteLocalizedStrings, index: u32, length: *u32) HRESULT {
        return self.vtbl.GetStringLength(self, index, length);
    }

    pub inline fn GetString(self: *IDWriteLocalizedStrings, index: u32, buffer: [*]u16, size: u32) HRESULT {
        return self.vtbl.GetString(self, index, buffer, size);
    }
};

/// IDWriteFontCollection — the system font collection.
pub const IDWriteFontCollection = extern struct {
    vtbl: *const Vtbl,

    pub const Vtbl = extern struct {
        base: IUnknown.Vtbl,

        GetFontFamilyCount: *const fn (self: *IDWriteFontCollection) callconv(.winapi) u32,

        GetFontFamily: *const fn (
            self: *IDWriteFontCollection,
            index: u32,
            fontFamily: *?*IDWriteFontFamily,
        ) callconv(.winapi) HRESULT,

        FindFamilyName: *const fn (
            self: *IDWriteFontCollection,
            familyName: [*:0]const u16,
            index: *u32,
            exists: *BOOL,
        ) callconv(.winapi) HRESULT,

        GetFontFromFontFace: *const fn (
            self: *IDWriteFontCollection,
            fontFace: *IDWriteFontFace,
            font: *?*IDWriteFont,
        ) callconv(.winapi) HRESULT,
    };

    pub inline fn Release(self: *IDWriteFontCollection) u32 {
        return self.vtbl.base.Release(@ptrCast(self));
    }

    pub inline fn GetFontFamilyCount(self: *IDWriteFontCollection) u32 {
        return self.vtbl.GetFontFamilyCount(self);
    }

    pub inline fn GetFontFamily(
        self: *IDWriteFontCollection,
        index: u32,
        font_family: *?*IDWriteFontFamily,
    ) HRESULT {
        return self.vtbl.GetFontFamily(self, index, font_family);
    }
};

/// IDWriteFontFamily — a family within a font collection.
pub const IDWriteFontFamily = extern struct {
    vtbl: *const Vtbl,

    pub const Vtbl = extern struct {
        base: IUnknown.Vtbl,

        GetFontCollection: *const fn (
            self: *IDWriteFontFamily,
            fontCollection: *?*IDWriteFontCollection,
        ) callconv(.winapi) HRESULT,

        GetFontCount: *const fn (self: *IDWriteFontFamily) callconv(.winapi) u32,

        GetFont: *const fn (
            self: *IDWriteFontFamily,
            index: u32,
            font: *?*IDWriteFont,
        ) callconv(.winapi) HRESULT,

        GetFamilyNames: *const fn (
            self: *IDWriteFontFamily,
            names: *?*IDWriteLocalizedStrings,
        ) callconv(.winapi) HRESULT,

        GetFirstMatchingFont: PlaceholderFn,
        GetMatchingFonts: PlaceholderFn,
    };

    pub inline fn Release(self: *IDWriteFontFamily) u32 {
        return self.vtbl.base.Release(@ptrCast(self));
    }

    pub inline fn GetFontCount(self: *IDWriteFontFamily) u32 {
        return self.vtbl.GetFontCount(self);
    }

    pub inline fn GetFont(self: *IDWriteFontFamily, index: u32, font: *?*IDWriteFont) HRESULT {
        return self.vtbl.GetFont(self, index, font);
    }

    pub inline fn GetFamilyNames(self: *IDWriteFontFamily, names: *?*IDWriteLocalizedStrings) HRESULT {
        return self.vtbl.GetFamilyNames(self, names);
    }
};

/// IDWriteFont — a single font within a family.
pub const IDWriteFont = extern struct {
    vtbl: *const Vtbl,

    pub const Vtbl = extern struct {
        base: IUnknown.Vtbl,

        GetFontFamily: *const fn (
            self: *IDWriteFont,
            fontFamily: *?*IDWriteFontFamily,
        ) callconv(.winapi) HRESULT,

        GetWeight: *const fn (self: *IDWriteFont) callconv(.winapi) u32,
        GetStretch: *const fn (self: *IDWriteFont) callconv(.winapi) u32,
        GetStyle: *const fn (self: *IDWriteFont) callconv(.winapi) u32,
        IsSymbolFont: *const fn (self: *IDWriteFont) callconv(.winapi) BOOL,

        GetFaceNames: *const fn (
            self: *IDWriteFont,
            names: *?*IDWriteLocalizedStrings,
        ) callconv(.winapi) HRESULT,

        GetInformationalStrings: *const fn (
            self: *IDWriteFont,
            informationalStringID: u32,
            informationalStrings: *?*IDWriteLocalizedStrings,
            exists: *BOOL,
        ) callconv(.winapi) HRESULT,

        GetSimulations: *const fn (self: *IDWriteFont) callconv(.winapi) u32,

        GetMetrics: *const fn (
            self: *IDWriteFont,
            fontFaceMetrics: *DWRITE_FONT_METRICS,
        ) callconv(.winapi) void,

        HasCharacter: *const fn (
            self: *IDWriteFont,
            unicodeValue: u32,
            exists: *BOOL,
        ) callconv(.winapi) HRESULT,

        CreateFontFace: *const fn (
            self: *IDWriteFont,
            fontFace: *?*IDWriteFontFace,
        ) callconv(.winapi) HRESULT,
    };

    pub inline fn Release(self: *IDWriteFont) u32 {
        return self.vtbl.base.Release(@ptrCast(self));
    }

    pub inline fn GetFontFamily(self: *IDWriteFont, font_family: *?*IDWriteFontFamily) HRESULT {
        return self.vtbl.GetFontFamily(self, font_family);
    }

    pub inline fn GetWeight(self: *IDWriteFont) u32 {
        return self.vtbl.GetWeight(self);
    }

    pub inline fn GetStyle(self: *IDWriteFont) u32 {
        return self.vtbl.GetStyle(self);
    }

    pub inline fn GetFaceNames(self: *IDWriteFont, names: *?*IDWriteLocalizedStrings) HRESULT {
        return self.vtbl.GetFaceNames(self, names);
    }

    pub inline fn HasCharacter(self: *IDWriteFont, unicode_value: u32, exists: *BOOL) HRESULT {
        return self.vtbl.HasCharacter(self, unicode_value, exists);
    }

    pub inline fn CreateFontFace(self: *IDWriteFont, font_face: *?*IDWriteFontFace) HRESULT {
        return self.vtbl.CreateFontFace(self, font_face);
    }
};

/// DWRITE_FACTORY_TYPE.
pub const DWRITE_FACTORY_TYPE = enum(c_int) {
    shared = 0,
    isolated = 1,
};

extern "dwrite" fn DWriteCreateFactory(
    factoryType: DWRITE_FACTORY_TYPE,
    iid: *const Guid,
    factory: *?*IUnknown,
) callconv(.winapi) HRESULT;

/// COINIT_MULTITHREADED.
pub const COINIT_MULTITHREADED: u32 = 0x0;

extern "ole32" fn CoInitializeEx(pvReserved: ?*anyopaque, dwCoInit: u32) callconv(.winapi) HRESULT;
extern "ole32" fn CoUninitialize() callconv(.winapi) void;

/// RPC_E_CHANGED_MODE — COM was already initialized with a different
/// threading model. The apartment is still usable, so we ignore it.
const RPC_E_CHANGED_MODE: u32 = 0x80010106;

/// Initialize COM on the calling thread for DirectWrite use.
///
/// Returns true if this call actually initialized COM (i.e. CoInitializeEx
/// returned S_OK); in that case the caller must call `comUninit` when done.
/// If COM was already initialized (S_FALSE or RPC_E_CHANGED_MODE), returns
/// false and the caller must NOT call `comUninit`.
pub fn comInit() Error!bool {
    const hr = CoInitializeEx(null, COINIT_MULTITHREADED);
    if (hr < 0 and @as(u32, @bitCast(hr)) != RPC_E_CHANGED_MODE) {
        return error.ComInitFailed;
    }
    return hr == 0;
}

/// Uninitialize COM on the calling thread.
pub fn comUninit() void {
    CoUninitialize();
}

/// Create the process factory for DirectWrite.
pub fn createFactory() Error!*IDWriteFactory {
    var factory: ?*IUnknown = null;
    const hr = DWriteCreateFactory(.shared, &IID_IDWriteFactory, &factory);
    if (hr < 0 or factory == null) return error.DirectWriteFailed;
    return @ptrCast(factory.?);
}

/// IID_IUnknown.
pub const IID_IUnknown = Guid{
    .data1 = 0x00000000,
    .data2 = 0x0000,
    .data3 = 0x0000,
    .data4 = .{ 0xc0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46 },
};

/// IID_IDWriteFontFileStream.
pub const IID_IDWriteFontFileStream = Guid{
    .data1 = 0x6d4865fe,
    .data2 = 0x0ab8,
    .data3 = 0x4d91,
    .data4 = .{ 0x8f, 0x62, 0x5d, 0xd6, 0xbe, 0x34, 0xa3, 0xe0 },
};

/// IID_IDWriteFontFileLoader.
pub const IID_IDWriteFontFileLoader = Guid{
    .data1 = 0x727cad4e,
    .data2 = 0xd6af,
    .data3 = 0x4c9e,
    .data4 = .{ 0x8a, 0x08, 0xd6, 0x95, 0xb1, 0x1c, 0xaa, 0x49 },
};

/// IID_IDWriteFontFace5.
pub const IID_IDWriteFontFace5 = Guid{
    .data1 = 0x98eff3a5,
    .data2 = 0xb667,
    .data3 = 0x479a,
    .data4 = .{ 0xb1, 0x45, 0xe2, 0xfa, 0x5b, 0x9f, 0xdc, 0x29 },
};

/// HRESULT constants used by the in-memory font file stream.
pub const S_OK: HRESULT = 0;
pub const E_NOINTERFACE: HRESULT = @bitCast(@as(u32, 0x80004002));
pub const E_INVALIDARG: HRESULT = @bitCast(@as(u32, 0x80070057));
pub const E_OUTOFMEMORY: HRESULT = @bitCast(@as(u32, 0x8007000e));

/// A memory-backed IDWriteFontFileStream. The vtable pointer is the first
/// field so the COM `this` pointer can be cast back to this struct.
pub const MemoryFontFileStream = struct {
    vtbl: *const IDWriteFontFileStream.Vtbl,
    ref_count: std.atomic.Value(u32),
    alloc: std.mem.Allocator,
    data: []const u8,
    loader: *IDWriteFontFileLoader,

    pub fn create(
        alloc: std.mem.Allocator,
        data: []const u8,
        loader: *IDWriteFontFileLoader,
    ) !*MemoryFontFileStream {
        const self = try alloc.create(MemoryFontFileStream);
        self.* = .{
            .vtbl = &vtbl,
            .ref_count = std.atomic.Value(u32).init(1),
            .alloc = alloc,
            .data = data,
            .loader = loader,
        };
        return self;
    }

    /// Release a COM reference; destroys the stream at zero.
    pub fn Release(self: *MemoryFontFileStream) u32 {
        return memoryStreamRelease(@ptrCast(self));
    }
};

const vtbl: IDWriteFontFileStream.Vtbl = .{
    .base = .{
        .QueryInterface = memoryStreamQueryInterface,
        .AddRef = memoryStreamAddRef,
        .Release = memoryStreamRelease,
    },
    .ReadFileFragment = memoryStreamReadFileFragment,
    .ReleaseFileFragment = memoryStreamReleaseFileFragment,
    .GetFileSize = memoryStreamGetFileSize,
    .GetLastWriteTime = memoryStreamGetLastWriteTime,
};

fn memoryStreamQueryInterface(
    self: *IUnknown,
    riid: *const Guid,
    ppvObject: ?*?*anyopaque,
) callconv(.winapi) HRESULT {
    if (std.meta.eql(riid.*, IID_IUnknown) or
        std.meta.eql(riid.*, IID_IDWriteFontFileStream))
    {
        if (ppvObject) |ppv| {
            ppv.* = @ptrCast(self);
            _ = memoryStreamAddRef(self);
        }
        return S_OK;
    }
    if (ppvObject) |ppv| ppv.* = null;
    return E_NOINTERFACE;
}

fn memoryStreamAddRef(self: *IUnknown) callconv(.winapi) u32 {
    const s: *MemoryFontFileStream = @ptrCast(self);
    return s.ref_count.fetchAdd(1, .monotonic) + 1;
}

fn memoryStreamRelease(self: *IUnknown) callconv(.winapi) u32 {
    const s: *MemoryFontFileStream = @ptrCast(self);
    const prev = s.ref_count.fetchSub(1, .acq_rel);
    if (prev == 1) {
        const alloc = s.alloc;
        alloc.destroy(s);
        return 0;
    }
    return prev - 1;
}

fn memoryStreamReadFileFragment(
    self: *IDWriteFontFileStream,
    fragmentStart: *?*const anyopaque,
    fileOffset: u64,
    fragmentSize: u64,
    fragmentContext: *?*anyopaque,
) callconv(.winapi) HRESULT {
    const s: *MemoryFontFileStream = @ptrCast(self);
    fragmentContext.* = null;
    if (fileOffset + fragmentSize > s.data.len) return E_INVALIDARG;
    fragmentStart.* = @ptrCast(s.data.ptr + fileOffset);
    return S_OK;
}

fn memoryStreamReleaseFileFragment(
    self: *IDWriteFontFileStream,
    fragmentContext: ?*anyopaque,
) callconv(.winapi) void {
    _ = self;
    _ = fragmentContext;
}

fn memoryStreamGetFileSize(self: *IDWriteFontFileStream, fileSize: *u64) callconv(.winapi) HRESULT {
    const s: *MemoryFontFileStream = @ptrCast(self);
    fileSize.* = s.data.len;
    return S_OK;
}

fn memoryStreamGetLastWriteTime(self: *IDWriteFontFileStream, lastWriteTime: *u64) callconv(.winapi) HRESULT {
    _ = self;
    // A non-zero value; DirectWrite only checks whether the stream is
    // writable/reliable, not the exact timestamp.
    lastWriteTime.* = 1;
    return S_OK;
}

/// A memory-backed IDWriteFontFileLoader. The loader holds the font bytes;
/// the reference key only needs to be unique (we use the data pointer).
pub const MemoryFontFileLoader = struct {
    vtbl: *const IDWriteFontFileLoader.Vtbl,
    ref_count: std.atomic.Value(u32),
    alloc: std.mem.Allocator,
    data: []const u8,

    pub fn create(alloc: std.mem.Allocator, data: []const u8) !*MemoryFontFileLoader {
        const self = try alloc.create(MemoryFontFileLoader);
        self.* = .{
            .vtbl = &loader_vtbl,
            .ref_count = std.atomic.Value(u32).init(1),
            .alloc = alloc,
            .data = data,
        };
        return self;
    }

    /// Release a COM reference; destroys the loader at zero.
    pub fn Release(self: *MemoryFontFileLoader) u32 {
        return memoryLoaderRelease(@ptrCast(self));
    }
};

const loader_vtbl: IDWriteFontFileLoader.Vtbl = .{
    .base = .{
        .QueryInterface = memoryLoaderQueryInterface,
        .AddRef = memoryLoaderAddRef,
        .Release = memoryLoaderRelease,
    },
    .CreateStreamFromKey = memoryLoaderCreateStreamFromKey,
};

fn memoryLoaderQueryInterface(
    self: *IUnknown,
    riid: *const Guid,
    ppvObject: ?*?*anyopaque,
) callconv(.winapi) HRESULT {
    if (std.meta.eql(riid.*, IID_IUnknown) or
        std.meta.eql(riid.*, IID_IDWriteFontFileLoader))
    {
        if (ppvObject) |ppv| {
            ppv.* = @ptrCast(self);
            _ = memoryLoaderAddRef(self);
        }
        return S_OK;
    }
    if (ppvObject) |ppv| ppv.* = null;
    return E_NOINTERFACE;
}

fn memoryLoaderAddRef(self: *IUnknown) callconv(.winapi) u32 {
    const l: *MemoryFontFileLoader = @ptrCast(self);
    return l.ref_count.fetchAdd(1, .monotonic) + 1;
}

fn memoryLoaderRelease(self: *IUnknown) callconv(.winapi) u32 {
    const l: *MemoryFontFileLoader = @ptrCast(self);
    const prev = l.ref_count.fetchSub(1, .acq_rel);
    if (prev == 1) {
        const alloc = l.alloc;
        alloc.destroy(l);
        return 0;
    }
    return prev - 1;
}

fn memoryLoaderCreateStreamFromKey(
    self: *IDWriteFontFileLoader,
    fontFileReferenceKey: ?*const anyopaque,
    fontFileReferenceKeySize: u32,
    fontFileStream: *?*IDWriteFontFileStream,
) callconv(.winapi) HRESULT {
    const l: *MemoryFontFileLoader = @ptrCast(self);
    if (fontFileReferenceKey == null or fontFileReferenceKeySize == 0) return E_INVALIDARG;

    const stream = MemoryFontFileStream.create(l.alloc, l.data, @ptrCast(self)) catch
        return E_OUTOFMEMORY;
    fontFileStream.* = @ptrCast(stream);
    return S_OK;
}
