# Windows DirectWrite Font Backend — Design

## Status: Proposal

This document is a design proposal for adding a DirectWrite font backend
to the Win32 apprt. It is not implemented yet; the current Windows build
uses the `freetype_windows` backend (FreeType rendering + HarfBuzz
shaping + a Windows font-directory scanner), which is functional.

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
    fontconfig_freetype,
    coretext,
    coretext_freetype,
    coretext_harfbuzz,
    coretext_noshape,
    web_canvas,
};
```

For Windows, `Backend.default()` returns `.freetype_windows` with a
comment: "A future DirectWrite backend can replace this if needed."

Key modules:

- `src/font/face.zig` — selects `Face` implementation via
  `switch (options.backend)`; currently `freetype.Face` for all
  FreeType-based backends.
- `src/font/face/freetype.zig` — the FreeType `Face` implementation.
- `src/font/discovery.zig` — font discovery (has `Windows` scanner).
- `src/font/shaper/` — shaping: `harfbuzz.zig` (cross-platform),
  `coretext.zig`, `web_canvas.zig`, `noop.zig`.
- `src/font/DeferredFace.zig` — loads faces lazily; has a `Windows`
  variant for `freetype_windows`.

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

Add `directwrite` to `Backend` in `src/font/backend.zig`. Set it as the
Windows default:

```zig
if (target.os.tag == .windows) return .directwrite;
```

Keep `.freetype_windows` available as a build option for testing and
for environments where DirectWrite is unavailable.

### COM/DWrite Bindings

DirectWrite is a COM API. Create `src/font/face/directwrite.zig` and a
support module `src/font/directwrite.zig` (or `src/os/directwrite.zig`)
containing:

- `DWriteCreateFactory` (dwrite.dll)
- COM interfaces via `@interface`-style bindings or raw vtable
  wrappers: `IDWriteFactory`, `IDWriteFontCollection`,
  `IDWriteFontFamily`, `IDWriteFont`, `IDWriteFontFace`,
  `IDWriteFontFace1..5` (for variable fonts), `IDWriteTextFormat`,
  `IDWriteTextLayout`, `IDWriteRenderingParams`.
- `IDWriteFontFile`, `IDWriteFontFileStream` for loading in-memory fonts.
- GDI interop: `IDWriteGdiInterop` for converting to `LOGFONT`/`HFONT`
  (optional).

Zig does not yet have a standard COM binding layer in the stdlib, so
these are manual vtable bindings. The project already does this for
Objective-C via `zig_objc`; a similar approach (or a small `com.zig`
helper) is needed here.

### Face Implementation

`directwrite.zig` implements the `Face` interface:

- `initFile` / `init`: create an `IDWriteFactory`, load the font file
  via `CreateFontFileReference` or `CreateCustomFontFileReference`
  (in-memory), create an `IDWriteFontFace`, and cache it.
- `setSize`: store the DIP/px size; rasterization uses the font face
  metrics directly (DirectWrite works in DIPs; convert via DPI).
- `renderGlyph`: use `IDWriteFontFace::GetGlyphRunOutline` (returns
  `IDWriteGeometry`) + `IDWriteGlyphRunAnalysis` for alpha coverage, or
  use FreeType just for rasterization with DirectWrite only for
  discovery. The former is the "full DirectWrite" path.
- `copyTable`: `IDWriteFontFace::TryGetFontTable` for HarfBuzz.
- `getMetrics`: `GetDesignGlyphMetrics` + `GetMetrics` for face
  metrics.

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

In `src/build/SharedDeps.zig`, link `dwrite.lib` (or `dwrite.dll`
via `@extern` declarations; Zig links by `-ldwrite` on Windows targets).
No vendored C libraries are needed beyond what is already there.

Add `directwrite` to `Backend` in `src/font/backend.zig` and to any
exhaustive switches (`hasFreetype`, `hasHarfbuzz`, etc.). The existing
`freetype_windows` backend can remain for comparison.

## Migration Path

1. Implement `src/font/directwrite.zig` (COM bindings) and
   `src/font/face/directwrite.zig` with `Face` methods.
2. Add `Backend.directwrite`; wire `face.zig` switch.
3. Reuse `shaper/harfbuzz.zig` (via `copyTable`).
4. Implement DirectWrite discovery in `discovery.zig`.
5. Add a build option `-Dfont-backend=directwrite` and make it the
   Windows default.
6. Compare rendering output with `freetype_windows`; verify metrics,
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
- Run the app; verify text renders correctly with ClearType.
- Test: CJK fallback, emoji (color font), variable font axes
  (`font-variation-settings`), synthetic bold/italic.
- Compare `+list-fonts` output with `freetype_windows`.

## Out of Scope

- DirectWrite shaping (`shaper/directwrite.zig`) — defer.
- ClearType tuning via `IDWriteRenderingParams` — follow-up.
- GDI interop (`IDWriteGdiInterop`) — follow-up.
