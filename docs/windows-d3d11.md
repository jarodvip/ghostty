# Windows D3D11 Renderer — Design

## Status: Proposal

This document proposes replacing the current WGL + CPU-readback
presentation path with a native Direct3D 11 renderer. It is not
implemented yet.

## Motivation

The current Windows renderer uses the shared OpenGL backend with a WGL
device (`src/renderer/opengl/wgl.zig`). Because there is no dma-buf on
Windows, every frame is read back from the GPU with `glReadPixels`
(`Target.readPixelsAlloc`) and blitted to the window with GDI
(`SetDIBitsToDevice` in `src/apprt/win32/Surface.zig`). This has
significant costs:

- A synchronous GPU→CPU readback of the full framebuffer every frame.
- A second CPU→GDI copy during the blit.
- Both happen on the app (message loop) thread, adding latency and
  hurting performance, especially in Debug builds and at high DPI.

A D3D11 renderer with a swap chain eliminates both copies: the renderer
renders directly into a D3D11 texture, and `Present` hands it to the
compositor with no CPU round-trip.

## Existing Renderer Abstraction

The renderer is selected at comptime:

```zig
// src/renderer.zig
const GraphicsAPI = switch (build_config.renderer) {
    .metal => Metal,
    .opengl => OpenGL,
};
pub const Renderer = GenericRenderer(GraphicsAPI);
```

A `Backend` value lives in `src/renderer/backend.zig` (`Backend` enum:
`opengl`, `metal`). The `GenericRenderer` (`src/renderer/generic.zig`)
drives rendering via the graphics API's interface, which includes:

- `init` / `deinit`
- `threadEnter` / `threadExit`
- `surfaceSize` / `setViewport`
- `drawFrameStart` / `drawFrameEnd`
- `initShaders`
- `initTarget` / `present`
- `initAtlasTexture`
- buffer / texture / sampler / pipeline / render-pass helpers
- `ExportedFrame` (union of `dmabuf` / `memory`)

The OpenGL backend expresses all of these; a D3D11 backend must
implement the same interface.

## Proposed Design

### New Backend Value

Add `d3d11` to `Backend` in `src/renderer/backend.zig` and wire it in
`src/renderer.zig`:

```zig
const GraphicsAPI = switch (build_config.renderer) {
    .metal => Metal,
    .opengl => OpenGL,
    .d3d11 => D3D11,
};
```

Add a build option `-Drenderer=d3d11` in `src/build/Config.zig`, and
make it the Windows default (while keeping `opengl` available for
comparison).

### D3D11 Device and Swap Chain

Create `src/renderer/d3d11.zig` and `src/renderer/d3d11/` containing:

- **Device**: `D3D11CreateDevice` with a `D3D_DRIVER_TYPE_HARDWARE`
  (fallback to `WARP` for software). Cache the `ID3D11Device`,
  `ID3D11DeviceContext`, and `IDXGIFactory` (via `CreateDXGIFactory1`).
- **Swap chain**: per-surface `IDXGISwapChain1` created on the HWND
  (`CreateSwapChainForHwnd`) with `DXGI_SWAP_EFFECT_FLIP_DISCARD`,
  `DXGI_ALPHA_MODE_IGNORE`, and 2–3 buffers.
- **Target**: a D3D11 render target view on the swap chain's back
  buffer; the `ExportedFrame` is `void` (no CPU readback), or a
  `ID3D11Texture2D` handle for advanced apprt use.

### Mapping the Renderer Interface

| OpenGL concept              | D3D11 equivalent                                                              |
| --------------------------- | ----------------------------------------------------------------------------- |
| `Target` (FBO + texture)    | Render target view + back buffer; offscreen `ID3D11Texture2D` for custom FBOs |
| `Pipeline` (shader program) | `ID3D11VertexShader` + `ID3D11PixelShader` + input layout + blend state       |
| `RenderPass`                | `ID3D11RenderTargetView` + viewport + depth/stencil state                     |
| `Texture` / `Sampler`       | `ID3D11Texture2D` + `ID3D11ShaderResourceView` + `ID3D11SamplerState`         |
| `Buffer` (vertex/uniform)   | `ID3D11Buffer` (dynamic/update-subresource)                                   |
| `Frame` (command recording) | Immediate context draw calls                                                  |
| `Atlas` texture             | `ID3D11Texture2D` + SRV                                                       |
| `present`                   | `swapchain.Present(1, 0)` — no CPU readback                                   |
| `ExportedFrame`             | `void` (apprt has nothing to copy)                                            |

### Shaders

Ghostty compiles GLSL shaders (via `shadertoy.zig`). For D3D11 we need
HLSL shaders. Two options:

1. **HLSL + DXC**: write HLSL equivalents of the existing shaders
   (`src/renderer/shaders/*.glsl`), compile at build time to DXIL bytecode
   and load with `D3DCreateBlob`.
2. **SPIR-V cross**: Ghostty already vendors `spirv-cross`; compile GLSL
   → SPIR-V (via `glslang`) → HLSL or DXIL. This reuses the existing
   shader sources with some adjustments.

Recommend option 2 (reuse existing shaders + `glslang`/`spirv-cross`)
for the first milestone to avoid duplicating shader logic.

### Presentation Path

`Surface.paint()` (`src/apprt/win32/Surface.zig`) currently takes a
CPU `memory` frame and calls `SetDIBitsToDevice`. With D3D11:

```zig
// paint() becomes:
//   1. core.renderer.takeFrame() -> ExportedFrame (void) or null
//   2. if a frame was produced, the swap chain already owns it
//   3. InvalidateRect / Present is driven by the render thread
```

The render thread's `present` calls `swapchain.Present`, so the apprt
no longer blits. `Surface.paint` can become a no-op (or just validate
the region) — the frame is already on screen.

### Font/Text Integration

The terminal renders text via the font atlas (FreeType or a future
DirectWrite backend). The D3D11 backend's `initAtlasTexture` uploads
the atlas as a D3D11 texture + SRV, unchanged in principle from the
OpenGL path.

## Migration Path

1. Implement `src/renderer/d3d11.zig` (COM bindings for D3D11/DXGI)
   and `Device.zig` (device + swap chain creation).
2. Implement `Target`, `Pipeline`, `RenderPass`, `Texture`, `Sampler`,
   `Buffer`, `Frame` as D3D11 types.
3. Wire `Backend.d3d11` + `-Drenderer=d3d11` build option.
4. Reuse existing GLSL shaders via `glslang` → `spirv-cross` → HLSL/DXIL
   (or write HLSL equivalents).
5. Update `Surface.paint` in the Win32 apprt to no-op; ensure the swap
   chain is resized on `WM_SIZE`.
6. Add a build/CI job for `-Drenderer=d3d11`; compare output and
   performance with the WGL path.

## Risks

- **COM bindings**: D3D11/DXGI are large COM surfaces; manual vtable
  wrappers are error-prone. Consider a shared `com.zig` helper or
  using the `d3d12`/`d3d11` bindings if Zig stdlib gains them.
- **Shader porting**: GLSL→HLSL via SPIR-V cross can hit feature gaps
  (e.g. `gl_FragCoord`, texture swizzles). The existing shaders are
  relatively simple, so risk is moderate.
- **Swap chain resize**: must handle `WM_SIZE` and DPI changes by
  resizing buffers and recreating render target views.
- **WARP fallback**: software rendering should work but be slow; ensure
  a clear error/log when hardware is unavailable.

## Verification

- Build: `zig build -Dtarget=x86_64-windows-gnu -Dapp-runtime=win32 -Drenderer=d3d11`
- Run the app; verify terminal renders and resizes correctly.
- Compare CPU usage / frame rate vs the WGL path at 1080p and 4K.
- Test: high refresh rate scrolling, large scrollback, resize during
  active rendering, color accuracy.

## Out of Scope

- Vulkan backend (unrelated).
- DirectWrite font backend (separate proposal in
  `docs/windows-directwrite.md`); D3D11 rendering works with either
  FreeType or DirectWrite.
- Multi-GPU / cross-adapter sharing.
