# Vendored ols (Odin Language Server)

Prebuilt [ols](https://github.com/DanielGavin/ols) binaries, bundled into every
release so `.odin` LSP features work out of the box. Same deal as
`vendor/jai-lsp/` — an **executable Bragi spawns**, resolved by
`lsp_resolve_binary` (lsp.odin):

1. `[lsp] odin` path in `config.ini` (explicit override), then
2. **next to the Bragi executable** (`SDL_GetBasePath()`), then
3. on `PATH`.

The package scripts copy the per-arch binary next to the produced Bragi binary.
Drop builds here with these names (`ols-<arch>-<os>`):

| File | Platform / arch | Lands next to the binary as |
|------|-----------------|------------------------------|
| `ols-arm64-darwin`     | macOS Apple Silicon | `Bragi.app/Contents/MacOS/ols` |
| `ols-x64-darwin`       | macOS Intel         | `Bragi.app/Contents/MacOS/ols` |
| `ols-x64-linux`        | Linux x86_64        | `/usr/bin/ols` |
| `ols-x64-windows.exe`  | Windows x86_64      | `ols.exe` (beside `Bragi.exe`) |

## Notes

- **Position encoding:** ols falls back to **utf-16** (it doesn't negotiate the
  LSP 3.17 `positionEncoding`), unlike jai-lsp's utf-8. `lsp_byte_to_pos` /
  `lsp_pos_to_byte` handle both — surrogate-aware rune walking on the utf-16
  path, plain byte math on utf-8.
- **codesigning (macOS):** these nested binaries are signed under the app's
  identity (hardened runtime) by `package_macos.sh`. Without that, Gatekeeper
  SIGKILLs the unsigned helper on spawn and notarization rejects the bundle.
- **Collections / richer features:** ols reads an `ols.json` from the workspace
  root for collection paths + build config (the user's project concern — not
  bundled). Basic in-package completion / hover / go-to-def work without it.
