# Vendored jai-lsp

Prebuilt [jai-lsp](https://github.com/Galaxoid-Labs/jai-lsp) binaries, bundled
into every release so `.jai` LSP features (completion, signature help, hover,
go-to-definition, diagnostics) work out of the box — no separate install.

Unlike the deps in `vendor/fff/`, jai-lsp is an **executable Bragi spawns**, not
a linked library. At runtime `lsp_resolve_binary` (lsp.odin) looks for it:

1. `[lsp] jai` path in `config.ini` (explicit override), then
2. **next to the Bragi executable** (`SDL_GetBasePath()`), then
3. on `PATH`.

So the package scripts just copy the per-platform binary next to the produced
Bragi binary. Drop the builds here with these exact names:

| File | Platform / arch | Lands next to the binary as |
|------|-----------------|------------------------------|
| `jai-lsp-darwin-arm64`     | macOS Apple Silicon | `Bragi.app/Contents/MacOS/jai-lsp` |
| `jai-lsp-linux-x64`        | Linux x86_64        | `/usr/bin/jai-lsp` |
| `jai-lsp-windows-x64.exe`  | Windows x86_64      | `jai-lsp.exe` (beside `Bragi.exe`) |

Add more arches by following the same `jai-lsp-<os>-<arch>` convention and
extending the `case` in the matching `tools/package_*.{sh,ps1}` script.

The compiler the server shells out to for diagnostics is **not** bundled — that
stays the user's Jai install, pointed at via `[lsp] jai_compiler` (→ the
`JAI_COMPILER` env var jai-lsp reads).
