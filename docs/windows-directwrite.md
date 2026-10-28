# Windows DirectWrite Font Backend — Design

## Status: Functional Rendering

This document is a design proposal for adding a DirectWrite font
backend to the Win32 apprt. The backend is **wired into the build**
(`Backend.directwrite` exists, `-Dfont-backend=directwrite` builds) and
implements `src/font/face/directwrite.zig` with minimal COM bindings in
`src/font/directwrite.zig`:

- `initFile` and in-memory `init` (via a custom
  `IDWriteFontFileStream`/`IDWriteFontFileLoader`), `name`,
  `glyphIndex`, `copyTable`, `hasColor`, `getMetrics`, `setSize`,
  `syntheticBold`/`syntheticItalic`, `renderGlyph`, and `setVariations`
  work.
- `setVariations` creates a new face with the requested axis values via
  `IDWriteFontFace5::GetFontResource` + `IDWriteFontResource::CreateFontFace`.
- `renderGlyph` rasterizes via `IDWriteGlyphRunAnalysis` into grayscale
  alpha with **antialiasing**: it uses the ClearType 3x1 texture
  (`DWRITE_RENDERING_MODE_NATURAL`) and converts each pixel's RGB
  sub-pixel values to a grayscale alpha. Color glyphs (emoji) are not
  supported yet.
- Discovery uses the system font collection (`GetSystemFontCollection`
  + `IDWriteFontCollection`/`IDWriteFontFamily`/`IDWriteFont`), and
  deferred faces hold an `IDWriteFont` reference; `+list-fonts` works.
  The collection is queried with `checkForUpdates=FALSE` (cached by
  DirectWrite), so fonts installed while Ghostty is running are only
  discovered after an app restart.
- Grayscale antialiasing is implemented (ClearType 3x1 → grayscale
  conversion); sub-pixel ClearType tuning remains future work.

DirectWrite is the **Windows default** font backend
(`Backend.default()` returns `.directwrite` for Windows). The
`freetype_windows` backend (FreeType rendering + HarfBuzz shaping + a
Windows font-directory scanner) remains available via
`-Dfont-backend=freetype_windows`.

## Motivation

The current `freetype_windows` backend works, but has limitations:

- It scans `C:\Windows\Fonts` and `%LOCALAPPDATA%\Microsoft\Windows\Fonts`
  by matching `family_name` and SFNT name tables. It does not use the
  Windows font database, so it may miss fonts installed per-user or
  fonts with unusual metadata.
- It does not use ClearType subpixel rendering. FreeType can do
  subpixel antialiasing but its Windows integration is not tuned.
- Color fonts (COLR/CPAL, CBDT/CBLC, SVG) and variable-font features
  are handled through FreeType; DirectWrite offers a first-class API.

A DirectWrite backend would use the OS font system for discovery,
rendering, and (optionally) shaping, matching how the macOS app uses
CoreText.

## Existing Architecture

The font subsystem is selected at comptime via
`src/font/backend.zig`:

```zig
pub const Backend = enum {
    freetype,
    freetype_windows,
    directwrite,
    fontconfig_freetype,
    coretext,
    coretext_freetype,
    coretext_harfbuzz,
    coretext_noshape,
    web_canvas,
};
```

For Windows, `Backend.default()` returns `.directwrite`; the
`freetype_windows` directory scanner remains available via
`-Dfont-backend=freetype_windows`.

Key modules:

- `src/font/face.zig` — selects `Face` implementation via
  `switch (options.backend)`; `directwrite.Face` on Windows, otherwise
  `freetype.Face` for FreeType-based backends.
- `src/font/face/directwrite.zig` — the DirectWrite `Face`
  implementation.
- `src/font/face/freetype.zig` — the FreeType `Face` implementation.
- `src/font/discovery.zig` — font discovery (has `Windows` scanner and
  a `DirectWrite` system-collection enumerator).
- `src/font/shaper/` — shaping: `harfbuzz.zig` (cross-platform),
  `coretext.zig`, `web_canvas.zig`, `noop.zig`.
- `src/font/DeferredFace.zig` — loads faces lazily; has `Windows` and
  `DirectWrite` variants.

The `Face` interface (from `freetype.zig`) that a DirectWrite backend
must implement:

| Function                                        | Purpose                           |
| ----------------------------------------------- | --------------------------------- |
| `initFile(lib, path, index, opts)`              | Load from a file path             |
| `init(lib, source, opts)`                       | Load from in-memory data          |
| `deinit`                                        | Release resources                 |
| `name(buf)`                                     | Family name                       |
| `syntheticBold(opts)` / `syntheticItalic(opts)` | Synthetic styles                  |
| `setSize(opts)`                                 | Set pixel size                    |
| `setVariations(variations)`                     | Apply variable-font axes          |
| `glyphIndex(cp)`                                | Codepoint to glyph ID             |
| `hasColor()` / `isColorGlyph(id)`               | Color glyph detection             |
| `renderGlyph(...)`                              | Rasterize a glyph                 |
| `getMetrics()`                                  | Face metrics                      |
| `copyTable(alloc, tag)`                         | Copy an SFNT table (for HarfBuzz) |

## Proposed Design

### New Backend Value

`directwrite` was added to `Backend` in `src/font/backend.zig`, and the
exhaustive switches in `face.zig`, `library.zig`, `shape.zig`,
`discovery.zig`, `DeferredFace.zig`, and the `Collection` tests were
updated. `-Dfont-backend=directwrite` now builds, and **DirectWrite is
the Windows default**.

`.freetype_windows` remains available as a build option for testing and
for environments where DirectWrite is unavailable.

### COM/DWrite Bindings

DirectWrite is a COM API. A support module `src/font/directwrite.zig`
now exists with manual vtable bindings (Zig has no stdlib COM layer) for:

- `DWriteCreateFactory` (dwrite.dll) and `CoInitializeEx` (ole32.dll).
- `IDWriteFactory` (subset: `CreateFontFileReference`, `CreateFontFace`).
- `IDWriteFontFile` and `IDWriteFontFace` (metrics, glyph indices,
  design glyph metrics, `TryGetFontTable`/`ReleaseFontTable`).
- `DWRITE_FONT_METRICS` / `DWRITE_GLYPH_METRICS`, font face type and
  simulation enums.

Still missing for future work:

- `IDWriteFontCollection` / `IDWriteFontFamily` / `IDWriteFont` /
  `IDWriteLocalizedStrings` for discovery.
- `IDWriteFontFileStream` / `IDWriteFontFileLoader` for in-memory fonts.
- `IDWriteGlyphRunAnalysis` / `IDWriteRenderingParams` for
  rasterization.
- `IDWriteFontFace1..5` for variable fonts.
- `IDWriteFontFallback` for codepoint fallback.
- GDI interop: `IDWriteGdiInterop` for `LOGFONT`/`HFONT` (optional).

### Face Implementation

`src/font/face/directwrite.zig` implements the `Face` interface:

- `initFile`: reads the font file, creates an `IDWriteFontFace` via
  `CreateFontFileReference` + `CreateFontFace`, and builds the
  HarfBuzz font from the file bytes.
- `init` (in-memory): copies the bytes and serves them through a custom
  `IDWriteFontFileStream`/`IDWriteFontFileLoader` (registered via
  `RegisterFontFileLoader`), then creates the face with
  `CreateCustomFontFileReference` + `CreateFontFace`.
- `name`: parses the SFNT 'name' table (name ID 1) into the caller's
  buffer.
- `setSize`: stores the size and updates the HarfBuzz font scale.
- `setVariations`: queries `IDWriteFontFace5`, gets the
  `IDWriteFontResource`, and creates a new font face with the requested
  `DWRITE_FONT_AXIS_VALUE`s via `CreateFontFace`; the HarfBuzz font's
  variations are updated too.
- `renderGlyph`: rasterizes with `IDWriteGlyphRunAnalysis`
  (`CreateGlyphRunAnalysis` + `GetAlphaTextureBounds` +
  `CreateAlphaTexture`). It measures the glyph's natural bounds,
  applies the constraint system via a `DWRITE_MATRIX` transform, and
  copies grayscale alpha coverage into the atlas. Antialiasing is
  achieved by rendering with `DWRITE_RENDERING_MODE_NATURAL` and
  converting the ClearType 3x1 sub-pixel texture to grayscale
  (`(R+G+B)/3`). Color glyphs (COLR/CBDT/sbix/SVG) return
  `error.WrongAtlas`.
- `copyTable`: `IDWriteFontFace::TryGetFontTable`, copying the data
  before releasing the table context (for HarfBuzz).
- `getMetrics`: `DWRITE_FONT_METRICS` scaled to pixels, plus ASCII
  advance measurement for the cell width and the "水" ideograph width.
- `syntheticBold`/`syntheticItalic`: new faces created with
  `DWRITE_FONT_SIMULATIONS_BOLD`/`OBLIQUE`.

### Shaping

Two options:

1. **HarfBuzz** (recommended for parity): keep `shaper/harfbuzz.zig` and
   provide SFNT tables via `copyTable`. This reuses all shaping logic
   and avoids a new shaping backend.
2. **DirectWrite shaping**: implement `shaper/directwrite.zig` using
   `IDWriteTextAnalyzer`. This is more work but enables
   DirectWrite-specific features.

Recommend option 1 for the first milestone.

### Discovery

Replace/augment `discovery.zig`'s Windows scanner with DirectWrite
enumeration:

- Use `IDWriteFactory::GetSystemFontCollection` to enumerate
  `IDWriteFontFamily` / `IDWriteFont`.
- Map `IDWriteLocalizedStrings` to family names (`family_name`
  matching).
- For fallback, use `IDWriteFontFallback` (Windows 8.1+) instead of
  the FreeType codepoint-fallback resolver.

### Build Integration

Done: `src/build/SharedDeps.zig` links `dwrite.lib` and `ole32.lib` for
the `.directwrite` backend. `Backend.directwrite` is wired into all
exhaustive switches (`hasFreetype`, `hasHarfbuzz`, etc.). The existing
`freetype_windows` backend remains available for comparison.

## Migration Path

- [x] Add `Backend.directwrite`; wire the `face.zig` switch and all other
  exhaustive `Backend` switches (`library`, `shape`, `discovery`,
  `DeferredFace`, `Collection` tests).
- [x] Make `-Dfont-backend=directwrite` a buildable option (the enum value
  is picked up by `Config.zig` automatically) and link `dwrite.lib` /
  `ole32.lib`.
- [x] Add minimal COM bindings (`src/font/directwrite.zig`) and implement
  the core `Face` methods (`initFile`, `name`, `glyphIndex`, `copyTable`,
  `hasColor`, `getMetrics`, `setSize`, synthetic bold/italic).
- [x] Implement `renderGlyph` (rasterization via `CreateGlyphRunAnalysis`
  + `IDWriteGlyphRunAnalysis`). Grayscale antialiasing uses the ClearType
  3x1 texture converted to grayscale; color glyphs are unsupported.
- [x] Implement in-memory `init` (custom `IDWriteFontFileStream` +
  `IDWriteFontFileLoader`, registered via `RegisterFontFileLoader`).
- [x] Implement variable-font `setVariations` (`IDWriteFontFace5` +
  `IDWriteFontResource::CreateFontFace`).
- [x] Implement DirectWrite discovery in `discovery.zig` (system font
  collection; deferred faces hold `IDWriteFont` references).
- [x] Make `directwrite` the Windows default (`.freetype_windows` remains
  available via `-Dfont-backend=freetype_windows`).
- [x] Add grayscale antialiasing (ClearType 3x1 → grayscale conversion).
- [ ] Compare rendering output with `freetype_windows`; verify metrics,
  fallback, variable fonts, and color glyphs.

## Risks

- **COM bindings are verbose**: manual vtable wrappers are error-prone;
  a small COM helper or codegen would help.
- **Rasterization differences**: FreeType vs DirectWrite glyph outlines
  differ slightly; golden-image tests may need tolerance.
- **HarfBuzz table access**: `IDWriteFontFace::TryGetFontTable` returns
  tables with a transient pointer; must copy before releasing the face.
- **DPI handling**: DirectWrite is DIP-based; ensure `setSize` and
  `getMetrics` convert correctly for the surface's content scale.

## Verification

- Build: `zig build -Dtarget=x86_64-windows-gnu -Dapp-runtime=win32 -Dfont-backend=directwrite`
  **passes** (verified with Zig 0.17.0 on Windows).
- Runtime COM verification: a standalone test confirmed `DWriteCreateFactory`
  succeeds, `CreateFontFileReference` + `CreateFontFace` load
  `C:\Windows\Fonts\arial.ttf`, `GetGlyphIndices` maps `'A'` to glyph 36,
  `GetMetrics` returns sane values (upm=2048, ascent=1854, descent=434),
  `TryGetFontTable` finds the `cmap` table, and `CreateGlyphRunAnalysis` +
  `CreateAlphaTexture` produces a 9x12 alpha bitmap for `'A'` with the
  glyph top 12px above the baseline.
- Font loading (file and in-memory), metrics, shaping, and grayscale
  rendering work. Known limit: color glyphs fail with
  `error.WrongAtlas`.
- Runtime verification: an in-memory font (arial.ttf bytes loaded via
  `CreateCustomFontFileReference` + a custom `IDWriteFontFileStream`)
  produced correct glyph indices (`'A'` → 36) and metrics (upm=2048).
- Variable fonts verified with `Bahnschrift.ttf`: `GetFontResource` +
  `CreateFontFace` with `wght=700` produced a working face
  (`glyph('A')` = 2).
- Grayscale antialiasing verified: rendering `'A'` with
  `DWRITE_RENDERING_MODE_NATURAL` + ClearType 3x1 → grayscale conversion
  produced 13 distinct alpha values (0..255), confirming antialiasing.
- System font collection enumeration verified: 85 families enumerated,
  family names retrieved via `IDWriteLocalizedStrings`.
- `+list-fonts` verified end-to-end: lists all system fonts, and
  `+list-fonts --family=Arial` lists the Arial family.
- Visual comparison with `freetype_windows`: build both variants
  (`zig build -Dtarget=x86_64-windows-gnu -Dapp-runtime=win32` vs
  `... -Dfont-backend=freetype_windows`), run the apps, and compare
  text rendering, metrics, fallback, variable fonts, and color glyphs
  (color glyphs currently fail on directwrite).
- Release build: `zig build -Dtarget=x86_64-windows-gnu
  -Dapp-runtime=win32 -Doptimize=ReleaseFast -Dstrip=false`.
  `-Dstrip=false` is required because Zig 0.17.0's mingw-w64 CRT fails
  to compile with omit-frame-pointer (`-Dstrip` defaults to true in
  release), producing a `.seh_ directive must appear within an active
  frame` error in crtexe.c.
- Test: CJK fallback, emoji (color font), variable font axes
  (`font-variation-settings`), synthetic bold/italic.
- Compare `+list-fonts` output with `freetype_windows`.

## Out of Scope

- **Color glyphs (emoji)**: requires `IDWriteFactory4::TranslateColorGlyphRun`
  + `IDWriteColorGlyphRunEnumerator` / `IDWriteFontFace2..5` to decompose
  COLR/CBDT/sbix/SVG glyphs into colored layers. The vendored MinGW
  `dwrite.h` does not declare these interfaces, so implementing them
  needs updated headers and an iterative build loop on real Windows SDK.
- Grayscale antialiasing tuning (sub-pixel ClearType instead of the
  grayscale conversion) — follow-up.
- DirectWrite shaping (`shaper/directwrite.zig`) — defer.
- GDI interop (`IDWriteGdiInterop`) — follow-up.
