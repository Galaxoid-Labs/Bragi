# Third-party licenses

Bragi links against, bundles, or embeds the following third-party
software. Each is distributed under a permissive license; the
verbatim license text for every entry lives in `licenses/` and is
copied into every distribution Bragi ships.

| Project | License | Verbatim text |
|---------|---------|---------------|
| **libvterm** — VT state machine for the embedded terminal pane (linked dynamically; bundled in macOS .app, vendored on Windows). © 2008 Paul Evans. | MIT | [`licenses/libvterm.txt`](licenses/libvterm.txt) |
| **SDL3** — windowing, input, GPU rendering (linked dynamically; bundled on macOS, shipped as DLL on Windows). © 1997-2025 Sam Lantinga. | zlib | [`licenses/sdl3.txt`](licenses/sdl3.txt) |
| **SDL3_ttf** — TTF / FreeType / HarfBuzz glue for text rendering. © 2001-2025 Sam Lantinga. | zlib | [`licenses/sdl3_ttf.txt`](licenses/sdl3_ttf.txt) |
| **Fira Code** — embedded as `FiraCode-Regular.ttf` (the editor pane's default font). © 2014 The Fira Code Project Authors. | SIL OFL 1.1 | [`licenses/firacode.txt`](licenses/firacode.txt) |
| **Fira Code Nerd Font** — embedded as `FiraCodeNerdFont-Regular.ttf` (the terminal pane's font; patched from Fira Code with extra glyphs). © Nerd Fonts contributors. | SIL OFL 1.1 / MIT | [`licenses/firacode_nerd_font.txt`](licenses/firacode_nerd_font.txt) |
| **Odin runtime** — small runtime support library compiled into the binary by the Odin toolchain. © 2016-present Ginger Bill. | zlib-style | [`licenses/odin.txt`](licenses/odin.txt) |

Bragi's own source code (everything in `*.odin` apart from the
runtime) is © 2026 Galaxoid Labs and licensed under the GNU General
Public License, version 3 only — see [`LICENSE`](LICENSE).

## What ships where

- **macOS `.app` bundle** — the `licenses/` directory is copied into
  `Contents/Resources/licenses/`.
- **Linux `.deb` / `.rpm` / `.tar.gz`** — copied into
  `/usr/share/doc/bragi/licenses/`.
- **AUR builds** — same path as Linux; the PKGBUILDs install from
  the staged tarball.
- **Windows zip / installer** — copied alongside `Bragi.exe` as
  `licenses/` next to the binary.
