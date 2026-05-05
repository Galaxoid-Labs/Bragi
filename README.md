# Bragi

A small, GPU-accelerated, vim-flavoured text/code editor written in
[Odin](https://odin-lang.org). Cross-platform via SDL3. Single binary,
~1.3 MB (both fonts embedded).

## Highlights

- **Modal editing** — Insert / Normal / Visual / Visual-Line / Command /
  Search modes. Most of the daily-use vim verbs work the way you
  expect: `dw`, `c$`, `5dd`, `>>`, `yy`+`p`, `.`, `%`, `zz`, `Ctrl+D`,
  `Ctrl+U`, `gg` / `G`, etc.
- **Side-by-side panes** — drag any file onto the window or hit
  Cmd/Ctrl+F to open a directory navigator. Each new file opens in a
  resizable column. `Ctrl+W h` / `Ctrl+W l` (or `Cmd+[` / `Cmd+]`)
  switches focus; drag the boundary to resize.
- **Embedded terminal** — `Cmd+J` / `Ctrl+J` (or `:term`) toggles a
  bottom strip running your shell against a real PTY. libvterm drives
  the cell grid; 4096-line scrollback with its own scrollbar; mouse-
  wheel scrolls history; typing snaps back to live; `clear` wipes
  scrollback (Ghostty-style); `exit` closes the pane. Powerline / dev
  glyphs render correctly via an embedded Nerd Font variant of Fira
  Code. Works on macOS, Linux, and Windows (ConPTY).
- **Fuzzy directory navigator** — Cmd+F (macOS) / Ctrl+F (Linux,
  Windows) opens a centered modal at your home directory. Type to
  filter, Enter to dive into a folder or open a file, Backspace or `..`
  to go up. Mouse double-click works too.
- **Fast** — piece-table buffer (far cursor jumps don't memmove),
  mmap-backed file open on POSIX (kernel lazy-pages the file as you
  scroll), incremental line-index + per-line column-width caches.
  Open is near-instant regardless of file size; edits stay snappy on
  multi-hundred-MB files.
- **Syntax highlighting** for **Odin**, **C**, **C++**, **Go**, **Jai**,
  **Swift**, **Bash** (and `.sh` / `.zsh`), **INI** (sections, keys,
  hex colors, booleans), plus a **Generic** fallback (strings /
  numbers / `//` and `/* */` comments) for everything else. Detection
  by file extension; switch manually with `:syntax <name>`.
- **Search** — `/foo` / `?foo` (literal, no regex), `n` / `N` to page,
  `[k/m]` match counter in the status bar, faint match highlights for
  every visible occurrence, `\c` / `\C` per-pattern case overrides.
- **Substitute** — `:s/foo/bar/[gi I]` and `:%s/foo/bar/[gi I]`. One
  undo group regardless of how many replacements happened.
- **Vim window-prefix** with `Ctrl+W` — `h l` for focus, `c q` to
  close, `Esc` to cancel.
- **Help screen** with `:h` or `:help` — modal cheat sheet, eight
  categorised tabs (number keys 1-8 to jump, `h`/`l` to step).
- **Live file-change detection** — open files are watched in
  real time via the platform-native API (kqueue on macOS, inotify on
  Linux, `ReadDirectoryChangesW` + IOCP on Windows). Clean buffers
  reload automatically and preserve the cursor; dirty buffers get a
  `[disk]` marker in the status bar so you can decide when to
  reconcile. `:reload` (`:re`) forces a reload from disk.
- **Native everything** — file dialogs (`Cmd+O`, `Cmd+Shift+S`),
  message boxes (mixed-EOL warning, unsaved-changes prompt), context
  menu on right-click. No browser embedded, no Electron, no Node.
- **LCD subpixel text rendering** through SDL3_ttf + FreeType. Embedded
  Fira Code by default; override with any system font via config.
- **Themeable** — every visible color (chrome + syntax) lives in one
  `Theme` struct loaded from `config.ini`.

## Install

The fastest way to run Bragi is to grab a pre-built binary from
[Releases](https://github.com/Galaxoid-Labs/Bragi/releases/latest):

| Platform | Artifact | How to run |
|----------|----------|------------|
| **macOS** | `Bragi-<version>.dmg` | Drag `Bragi.app` to `/Applications`. First launch: right-click → Open (unsigned ad-hoc build). |
| **Debian / Ubuntu** | `bragi_<version>_amd64.deb` | `sudo apt install ./bragi_<version>_amd64.deb` |
| **Fedora / RHEL** | `bragi-<version>-1.x86_64.rpm` | `sudo dnf install ./bragi-<version>-1.x86_64.rpm` |
| **Arch / Manjaro** | AUR (`bragi-bin`) | `yay -S bragi-bin` (or `paru -S bragi-bin`) |
| **Other Linux** | `bragi-<version>-x86_64-linux.tar.gz` | `sudo tar -xzf … -C /` |
| **Windows** | `Bragi-<version>-Setup.exe` | Run the installer. |
| **Windows (no install)** | `Bragi-<version>-portable.zip` | Extract anywhere; run `Bragi.exe`. |

The macOS `.app` and Windows installer bundle SDL3 / SDL3_ttf / libvterm
internally, so no Homebrew / vcpkg required on the target machine.
Linux packages declare those as dependencies and the package manager
pulls them in.

Or build from source — see [Building from source](#building-from-source).

## Building from source

Bragi is a single Odin package. From a fresh clone:

```sh
odin build . -o:speed
./Bragi                       # opens a welcome screen
./Bragi path/to/file.go       # opens that file
```

`-o:speed` matters — without it the file-load scan is 5–10× slower in
the unoptimized debug build.

### Dependencies

- An [Odin compiler](https://odin-lang.org/docs/install/) from
  **`dev-2026-04`** or newer. The `core:os` package was overhauled in
  that release; Bragi uses the new API and won't build against older
  compilers.
- **SDL3** + **SDL3_ttf** at runtime.
- **libvterm** for the embedded terminal pane.

The two embedded TTFs (`FiraCode-Regular.ttf` and
`FiraCodeNerdFont-Regular.ttf`) are checked in and `#load`-ed at
compile time — no runtime font dependency.

#### macOS

```sh
brew install sdl3 sdl3_ttf libvterm
```

That's it. `forkpty` lives in libSystem, no extra package.

#### Linux (Debian / Ubuntu)

```sh
sudo apt install libsdl3-dev libsdl3-ttf-dev libvterm-dev libutil-dev
```

#### Linux (Fedora)

```sh
sudo dnf install SDL3-devel SDL3_ttf-devel libvterm-devel libutil-devel
```

#### Windows

`SDL3.dll` + `SDL3_ttf.dll` come with the Odin install; `vterm.dll` is
vendored under `vendor/libvterm/` (built from neovim's libvterm fork —
vcpkg has no port for it). A clone has everything it needs:

```powershell
$odin = Split-Path -Parent (Get-Command odin).Source
odin build . -o:speed -out:Bragi.exe
Copy-Item "$odin\vendor\sdl3\SDL3.dll"          .
Copy-Item "$odin\vendor\sdl3\ttf\SDL3_ttf.dll"  .
Copy-Item .\vendor\libvterm\vterm.dll           .
.\Bragi.exe
```

To rebuild `vterm.dll` (only when bumping libvterm):

```powershell
powershell -ExecutionPolicy Bypass -File vendor\libvterm\build.ps1
```

The script clones the upstream repo, drops in a tiny CMakeLists.txt,
builds with MSVC, and refreshes `vendor/libvterm/{vterm.dll,vterm.lib,include/}`.
Requires git, cmake, and Visual Studio 2022+ with the C/C++ workload.

The terminal pane spawns `powershell.exe` by default (override via the
`SHELL` env var) and starts in `%USERPROFILE%`.

## Packaging

`deploy.ini` at the repo root carries the metadata (app name, version,
identifier, copyright, dependency strings, code-signing identity, …)
that the per-platform packaging scripts read. Edit once; run the
script for the host you're on. Output lands in `dist/<platform>/`.

Each script also copies `THIRD_PARTY_LICENSES.md` and the verbatim
upstream license text in `licenses/` into its output bundle, so every
distribution carries the notices the bundled / linked deps require.

### macOS — `.app` bundle and `.dmg`

```sh
./tools/package_macos.sh
```

Produces `dist/macos/Bragi.app` and `dist/macos/Bragi-<version>.dmg`.
The script bundles all Homebrew dylibs into
`Bragi.app/Contents/Frameworks/` and rewrites the binary's load paths,
so the resulting `.app` is fully self-contained — no Homebrew on the
target. Code-signs with the Developer ID set in `[macos]` (or ad-hoc
otherwise), and notarizes if Apple ID credentials are filled in.

Stage toggles for iteration: `STAGE_BUILD=0`, `STAGE_BUNDLE=0`,
`STAGE_SIGN=0`, `STAGE_DMG=0`. Required tools all ship with the Xcode
Command Line Tools (`xcode-select --install`).

### Linux — `.deb`, `.rpm`, AUR, generic tarball

```sh
./tools/package_linux.sh
```

Must run on a Linux host. Produces:

- `dist/linux/bragi_<version>_<arch>.deb` (Debian / Ubuntu)
- `dist/linux/bragi-<version>-1.<arch>.rpm` (Fedora / RHEL)
- `dist/linux/bragi-<version>-<arch>-linux.tar.gz` (generic FHS tarball
  used by the AUR `bragi-bin` PKGBUILD)
- `dist/linux/<pkg>.pkg.tar.zst` (Arch, when `makepkg` is on PATH)

Each format auto-skips when its build tool is missing. Both `.deb` and
`.rpm` declare the distro's SDL3 / SDL3_ttf / libvterm packages as
runtime deps; bundling `.so` files is fragile across glibc / Wayland
/ X11 versions and discouraged by both packaging policies.

The script's footer has copy-pasteable host-setup recipes for Fedora,
Debian/Ubuntu, Arch, and "macOS-via-Docker." See `tools/aur/README.md`
for the AUR publishing flow.

### Windows — installer + portable zip

```powershell
powershell -ExecutionPolicy Bypass -File tools\package_windows.ps1
```

Produces:

- `dist\windows\Bragi-<version>-Setup.exe` — Inno Setup installer
- `dist\windows\Bragi-<version>-portable.zip` — extract-and-run bundle

Generates `bragi.ico` from `icon.png`, compiles a `bragi.rc` resource
(icon + version-info string table) into `Bragi.exe`, and stages the
redistributable (exe + 3 DLLs + LICENSE + third-party notices).
Requires **Inno Setup 6** (`winget install JRSoftware.InnoSetup`); the
script falls back to the zip alone if it's missing. `rc.exe` is
auto-located off any Visual Studio 2022+ install.

Stage toggles: `STAGE_ICON=0`, `STAGE_BUILD=0`, `STAGE_BUNDLE=0`,
`STAGE_INSTALLER=0`, `STAGE_ZIP=0`.

## Configuration

Bragi reads `config.ini` from a per-platform location at startup:

| Platform | Path |
|----------|------|
| macOS    | `~/Library/Application Support/Bragi/config.ini` |
| Linux    | `$XDG_CONFIG_HOME/bragi/config.ini` (defaults to `~/.config/bragi/config.ini`) |
| Windows  | `%APPDATA%\Bragi\config.ini` |

The file is optional — every field has a sensible default.

The fastest way to start tweaking is **`:config`** inside Bragi: if
the file already exists it just opens it; if it doesn't, you get a
buffer pre-populated with the commented default template, and saving
writes it to the right path. INI mode is auto-detected, so colors,
sections, and hex values are highlighted as you edit.

The template covers `[font]`, `[editor]`, and `[theme]`. Every visible
color in the editor — syntax token colors, gutter, status bar,
selection, search, scrollbar — is themeable via `[theme]`.

## Quick reference

Press `:h` inside the editor for the full categorised cheat sheet.
The greatest hits:

```
i  a  I  A  o  O    Insert at various positions
v  V                Visual / Visual-Line
Esc                 return to Normal

h j k l             motion
w b e               word forward / back / end
0 $ ^               line start / end / first non-blank
gg G  <n>G          first / last / nth line
Ctrl+D / Ctrl+U     half-page down / up
zz zt zb            centre / top / bottom cursor on screen
%                   matching bracket

dd yy cc            delete / yank / change line
dw  3dw  c3w        operator + motion (counts compose)
D C Y               d$ / c$ / y$
>> <<               indent / outdent line
.                   repeat last change
u  /  Cmd+Shift+Z   undo / redo

/pattern  ?pattern  search forward / backward (literal)
n N                 next / prev match (wraps)
:noh                clear search

:w  :q  :wq  :q!    save / quit / save+quit / force-quit
:42                 jump to line 42
:syntax <name>      switch tokenizer
:s/pat/repl/[gi I]  substitute (current line)
:%s/pat/repl/[gi I] substitute (whole buffer)
:term :terminal     open / focus the terminal pane
:termclose          close the terminal pane
:reload :re         reload the current file from disk
:config             open / create the user config.ini
:h  :help           open the categorised cheat sheet

Cmd/Ctrl+F          directory navigator
Cmd/Ctrl+J          toggle the terminal pane
Cmd+O / S / Shift+S open / save / save as
Cmd+Z / Shift+Z     undo / redo
Cmd+W               close pane (last pane → quit on macOS)
Ctrl+W h / l / c / q   focus / close pane
Cmd+[ / Cmd+]       focus prev / next pane (single-chord)
drag pane border    resize adjacent panes
drag term divider   resize the terminal strip
wheel over term     scroll the terminal scrollback
```

## Roadmap

This is a personal-scratch editor; expect rough edges. The core flow
is solid for daily use, including on multi-hundred-MB files
(piece-table buffer + mmap-backed open on POSIX). Tracked in
`CLAUDE.md`:

- Incremental search (debounced).
- Cmd+W → Save → auto-close on dirty untitled buffers.
- More tokenizers — Python, Markdown, JSON, Zig, TS/JS.
- Glyph atlas (faster first-display on big files).
- Terminal mouse forwarding (so tmux / htop / vim get mouse events).
- Comment toggle (`gc` / `Ctrl+/`), language-aware.
- Shell-friendly CLI invocation (`bragi`, `bragi .`) — needs a
  `/usr/local/bin/bragi` shim on macOS plus directory-arg handling.
- Piece tree (RB-balanced) — only matters once a workflow drives
  piece counts into the thousands.

## License

Bragi is **GPL-3.0-only** — see [`LICENSE`](LICENSE) for the full text.
Copyright © 2026 Galaxoid Labs.

Bundled third-party software (libvterm, SDL3, SDL3_ttf, Fira Code,
Fira Code Nerd Font, Odin runtime) is distributed under permissive
licenses; the verbatim notices live in [`licenses/`](licenses/) and
[`THIRD_PARTY_LICENSES.md`](THIRD_PARTY_LICENSES.md), and ride along
with every distribution Bragi ships.
