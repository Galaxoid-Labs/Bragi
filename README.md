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
  Cmd/Ctrl+F to fuzzy-find a file in your project. Each new file opens
  in a resizable column. `Ctrl+W h` / `Ctrl+W l` (or `Cmd+[` / `Cmd+]`)
  switches focus; drag the boundary to resize.
- **Embedded terminal** — `Cmd+J` / `Ctrl+J` (or `:term`) toggles a
  bottom strip running your shell against a real PTY. libvterm drives
  the cell grid; 4096-line scrollback with its own scrollbar; mouse-
  wheel scrolls history; typing snaps back to live; `clear` wipes
  scrollback (Ghostty-style); `exit` closes the pane. Powerline / dev
  glyphs render correctly via an embedded Nerd Font variant of Fira
  Code. Works on macOS, Linux, and Windows (ConPTY).
- **Fuzzy file finder** — Cmd+F (macOS) / Ctrl+F (Linux, Windows) opens
  a centered modal that fuzzy-searches every file in your project
  (powered by [fff](https://github.com/dmtrKovalenko/fff)). The project
  root is the workspace (below), else the git repo containing the file
  you're editing — `.gitignore` is respected, so build dirs and
  `node_modules` stay out. Type to filter, Up/Down to move, Enter to
  open. Mouse double-click works too.
- **Workspace + file-tree sidebar** — open a folder (Cmd/Ctrl+Shift+O,
  `bragi <dir>`, `:cd <path>`, or drop a folder on the window) to set a
  project root. Cmd/Ctrl+E toggles a left file-tree sidebar (NERDTree
  style): single-click a folder to expand, double-click a file to open;
  navigate with `j/k/h/l` + Enter when focused; `i` toggles hidden
  dotfiles. Folder/file icons come from the embedded Nerd Font. The
  divider resizes it. The workspace also becomes the finder's root.
- **Open Recent** — Cmd/Ctrl+R (or `:recent`) pops a menu-styled list of
  recently opened folders and files, grouped and most-recent-first. Enter
  (or click) opens; Esc / click-away closes. It also appears automatically
  on a bare launch (no file/folder argument). Files opened *inside* the
  current workspace aren't listed separately — the folder entry covers
  them; only standalone files get their own entry. Entries that no longer
  exist on disk are pruned on load. Disable the startup popup with
  `[ui] show_recent_on_startup = false`.
- **Scratchpad** — Cmd/Ctrl+Shift+N (or `:scratch`) opens an in-memory
  notes buffer with full editing, rendered with **Markdown** highlighting
  by default. Close its pane and the contents stay in memory, so it's
  always one keystroke away while Bragi is open; quitting discards it
  (nothing touches disk). Save As promotes it to a real file if a note's
  worth keeping.
- **Fast** — piece-table buffer (far cursor jumps don't memmove),
  mmap-backed file open on POSIX (kernel lazy-pages the file as you
  scroll), incremental line-index + per-line column-width caches.
  Open is near-instant regardless of file size; edits stay snappy on
  multi-hundred-MB files. Live window-resize tracks the cursor in real
  time on every platform (the redraw path is split: a synchronous
  event-watch on macOS / Windows, where the OS blocks the main thread
  during the resize loop; the normal render loop on Linux, where it
  doesn't — drawing in the watch there would jam the event queue).
- **Syntax highlighting** for **Odin**, **C**, **C++**, **Go**, **Jai**,
  **Swift**, **Rust**, **GDScript**, **Bash** (and `.sh` / `.zsh`),
  **INI** (sections, keys, hex colors, booleans), **Markdown** (headings,
  bold / italic / strike, inline + fenced code, links, lists, blockquotes,
  rules), plus a **Generic** fallback (strings / numbers / `//` and
  `/* */` comments) for everything else. Detection by file extension;
  switch manually with `:syntax <name>`. Markdown colors are themeable
  (`[theme] md_*`) and inherit the base palette by default.
- **Intellisense via LSP** — open a `.jai` or `.odin` file inside a
  workspace and Bragi drives **jai-lsp** / **ols** over the Language
  Server Protocol: **autocompletion** as you type (Tab/Enter accept,
  `Ctrl+Space` invoke), **signature help** on `(`, **hover** info
  (`Cmd`/`Ctrl`-hover), **go-to-definition** (`gd`, or `Cmd`/`Ctrl`-click;
  a picker appears when there's more than one), and **diagnostics**
  (underlines + the message on the cursor's line). A status-bar dot shows
  the server state — click it to restart. Both servers ship in the
  release; see [Language servers](#language-servers-lsp).
- **Search** — `/foo` / `?foo` (literal, no regex), `n` / `N` to page,
  `[k/m]` match counter in the status bar, faint match highlights for
  every visible occurrence, `\c` / `\C` per-pattern case overrides.
- **Substitute** — `:s/foo/bar/[gi I]` and `:%s/foo/bar/[gi I]`. One
  undo group regardless of how many replacements happened.
- **Pane management** — on macOS, `Ctrl+W` is vim's window-prefix
  (`h l` focus, `c q` close, `Esc` cancel) and `Cmd+W` closes the
  active pane. On Linux / Windows there's no Cmd key, so `Ctrl+W`
  closes the active pane directly (X11/Windows tab-close muscle
  memory) and `Ctrl+[` / `Ctrl+]` switch focus.
- **Help screen** with `:h` or `:help` — modal cheat sheet, eight
  categorised tabs (number keys 1-8 to jump, `h`/`l` to step).
- **Live file-change detection** — open files are watched in
  real time via the platform-native API (kqueue on macOS, inotify on
  Linux, `ReadDirectoryChangesW` + IOCP on Windows). Clean buffers
  reload automatically and preserve the cursor; dirty buffers get a
  `[disk]` marker in the status bar so you can decide when to
  reconcile. `:reload` (`:re`) forces a reload from disk.
- **Crash-safe saves** — writes go to a sibling temp file that's then
  atomically `rename`d over the target, so a crash mid-write can never
  leave a half-written or truncated file. Symlinks are followed (the link
  is preserved, not clobbered) and the original file's permission bits are
  kept. On POSIX this is also what keeps the mmap-backed buffer correct: an
  in-place overwrite of a file you've still got mapped reads back as zeros
  past the new end on Linux — the rename sidesteps it entirely.
- **Native everything** — file dialogs (`Cmd+O`, `Cmd+Shift+S`),
  message boxes (mixed-EOL warning, unsaved-changes prompt), context
  menu on right-click. No browser embedded, no Electron, no Node.
- **LCD subpixel text rendering** through SDL3_ttf + FreeType. Embedded
  Fira Code by default; override with any system font via config. The
  editor (code) area and the UI chrome can use **separate fonts**
  (`[font]` vs `[editor_font]`).
- **Editor zoom** — `Cmd`/`Ctrl` `=` / `-` resize the editor font live
  (`Cmd`/`Ctrl` `0` resets). Only the document + line numbers scale; the
  status bar, finder, and menus stay put. Per-session (resets on
  restart; set a permanent size in `[editor_font]`).
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
| **Other Linux** | `bragi-<version>-x86_64.tar.gz` | `sudo tar -xzf … -C /` |
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

> **⚠️ macOS / Apple Silicon on Odin `dev-2026-05` / `dev-2026-06`:** these
> compilers have a codegen regression at optimized levels (`-o:speed`,
> `-o:size`, and sometimes `-o:minimal`) that miscompiles
> `SDL_RenderFillRect` — filled rectangles (menus, finder, sidebar) render
> **white**. Editor text and background are unaffected (they use textures /
> `RenderClear`). Which `-o` level trips it is source-dependent and shifts
> with unrelated edits, so until the upstream fix lands, build with
> **`-o:none`** on these toolchains:
> ```sh
> odin build . -o:none
> ```
> `dev-2026-04` is fine at every level (and is the safe fallback for
> packaged release builds). This is an Odin compiler bug, not a Bragi or SDL
> bug — tracked upstream at
> [odin-lang/Odin#6809](https://github.com/odin-lang/Odin/issues/6809).

### Dependencies

- An [Odin compiler](https://odin-lang.org/docs/install/) from
  **`dev-2026-04`** or newer; developed against **`dev-2026-06`**. The
  `core:os` package was overhauled in `dev-2026-04`; Bragi uses the new API
  and won't build against older compilers. On macOS / Apple Silicon with
  `dev-2026-05`+ see the optimization caveat above — build with `-o:none`.
- **SDL3** + **SDL3_ttf** at runtime.
- **libvterm** for the embedded terminal pane.
- **[fff](https://github.com/dmtrKovalenko/fff)** powers the fuzzy file
  finder. No system install needed — the prebuilt `c-lib-*` libraries
  are vendored under [`vendor/fff/`](vendor/fff/) (one per target) and
  linked directly; see that directory's README for refresh steps.

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
target. The jai-lsp / ols servers (and ols's `builtin` folder) are copied
into `Contents/MacOS/` next to the binary. Code-signs with the Developer ID
set in `[macos]` (or ad-hoc otherwise), and notarizes if Apple ID
credentials are filled in.

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
- `dist/linux/bragi-<version>-<arch>.tar.gz` (generic FHS tarball
  used by the AUR `bragi-bin` PKGBUILD)
- `dist/linux/bragi-<version>-<arch>.pkg.tar.zst` (Arch, when `makepkg` is on PATH)

Each format auto-skips when its build tool is missing. Both `.deb` and
`.rpm` declare the distro's SDL3 / SDL3_ttf / libvterm packages as
runtime deps; bundling `.so` files is fragile across glibc / Wayland
/ X11 versions and discouraged by both packaging policies. The jai-lsp /
ols servers go in `/usr/bin`; ols's `builtin` folder ships in the private
libdir at `/usr/lib/bragi/builtin` (a multi-file data dir doesn't belong in
`/usr/bin` under the FHS), and Bragi points `OLS_BUILTIN_FOLDER` there.

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
redistributable (exe + 3 DLLs + jai-lsp / ols + ols's `builtin` folder +
LICENSE + third-party notices).
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

The template covers `[font]`, `[editor_font]`, `[editor]`, `[lsp]`,
`[ui]`, and `[theme]`. `[editor_font]` overrides the code area's font
independently of the UI (`[font]`); blank keys inherit `[font]`. `[ui]`
has `show_recent_on_startup` (default `true`) — set it `false` to stop the
Open-Recent list from popping up on a bare launch. Every visible
color in the editor — syntax token colors, gutter, status bar,
selection, search, scrollbar — is themeable via `[theme]`.

## Language servers (LSP)

Open a `.jai` or `.odin` file **inside a workspace** (a folder opened via
`bragi <dir>`, the Open Folder dialog, or `:cd`) and Bragi launches the
matching server, one process per language:

| Language | Server | Notes |
|----------|--------|-------|
| Jai  | [jai-lsp](https://github.com/Galaxoid-Labs/jai-lsp) | negotiates **utf-8** |
| Odin | [ols](https://github.com/DanielGavin/ols)           | uses **utf-16** |

**Features** (identical for both): autocompletion (narrows as you type;
`Ctrl`/`Cmd+Space` to invoke; Tab/Enter accept; click a row to insert),
signature help on `(` with the active argument highlighted, hover info via
`Cmd`/`Ctrl`-hover (also underlines the symbol), go-to-definition with
`gd` or `Cmd`/`Ctrl`-click — a chooser pops when a symbol resolves to more
than one location — and diagnostics as underlines plus a status-bar message
on the cursor's line.

**Formatting** — `Cmd`/`Ctrl+Shift+F`, `:fmt`, or right-click → *Format
Document* reformats the file through the server's formatter (jai-lsp; ols
via its in-process `odin/printer` — no separate `odinfmt` binary needed).
Applied as a single undo. Set `[lsp] format_on_save = true` to run it
automatically on `:w` / `Cmd`/`Ctrl+S` (only for files whose server
advertises formatting; `:wq` and quit-time saves skip it). An optional
`odinfmt.json` in the tree tunes Odin style.

**Server status** — a colored dot + name sits in the status bar (green
ready · yellow starting · red crashed · dim not-running). **Click it** to
restart, or use `:lsp restart` / `:lsp stop` / `:lsp start`.

### Where the binaries come from

Resolved in order: **`[lsp]` config path → next to the Bragi executable →
`PATH`**. Release builds bundle both servers next to the binary, so it
works with **zero config**. Running from a source checkout, Bragi also
finds the arch-suffixed binaries under `vendor/jai-lsp/` and
`vendor/odin-lsp/` automatically. Override the path explicitly if you want
your own build:

ols also needs its **`builtin` folder** (Odin's `builtin` + `intrinsics`
packages) to resolve language built-ins — `len`, `make`, `append`, the
`intrinsics` package, `core:`/`base:` — for completion, hover, and
go-to-definition. It's vendored under `vendor/odin-lsp/builtin/` and bundled
into every release, and Bragi points ols at it via `OLS_BUILTIN_FOLDER` at
launch (probing next to the ols binary, and `/usr/lib/bragi/builtin` on
packaged Linux). No setup needed.

```ini
[lsp]
jai          = /path/to/jai-lsp        # else: bundled → PATH
odin         = /path/to/ols            # else: bundled → PATH
jai_entry    = /path/to/main.jai       # jai-lsp's type-check entry (diagnostics)
jai_compiler = /path/to/jai-macos      # → JAI_COMPILER, for jai diagnostics + rich hover
format_on_save = false                 # run the LSP formatter on :w / Cmd+S
```

### Caveats

- **Jai diagnostics + rich (typed) hover** need jai-lsp to run the Jai
  compiler — set `jai_compiler` to your `jai-macos` / `jai-linux` /
  `jai.exe` (it's passed as `JAI_COMPILER`). Completion, signatures, and
  go-to-definition work without it (they use the workspace scan).
- **Odin** completion/hover/def — including built-ins (`len`, `append`,
  `intrinsics`, …) via the bundled `builtin` folder — work out of the box.
  Collection-aware features and diagnostics want an `ols.json` in the
  workspace root and `odin` on `PATH` (ols's standard config — not bundled).
- **macOS Gatekeeper** SIGKILLs unsigned helper binaries on first spawn.
  Release `.app`s codesign the bundled servers under the app identity; a
  raw downloaded binary needs a one-time allow in System Settings →
  Privacy & Security.

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
:recent :recents    open the recent folders / files list
:scratch            open the in-memory scratchpad
:reload :re         reload the current file from disk
:config             open / create the user config.ini
:lsp [restart|stop|start]  manage the language server (bare :lsp restarts)
:h  :help           open the categorised cheat sheet

Cmd/Ctrl+F          fuzzy file finder
Cmd/Ctrl+R          open recent (folders + files)
Cmd/Ctrl+Shift+N    open the in-memory scratchpad
Cmd/Ctrl+E          toggle the file-tree sidebar
Cmd/Ctrl+J          toggle the terminal pane
gd                  go to definition (LSP, Normal mode)
Cmd/Ctrl+click      go to definition at the clicked symbol
Cmd/Ctrl+hover      underline a symbol + show hover info
Cmd/Ctrl+Shift+F    format the document (LSP) · also :fmt
Ctrl+Space          invoke autocompletion (Insert mode)
Tab / Enter         accept completion · Esc dismiss
Cmd/Ctrl + = / -    zoom editor font in / out  (Cmd/Ctrl 0 resets)
Cmd+O / Shift+O     open file / open folder (workspace)
Cmd+S / Shift+S     save / save as
Cmd+Z / Shift+Z     undo / redo
Cmd/Ctrl+W          close pane (macOS: Cmd+W · Linux/Win: Ctrl+W)
Ctrl+W h/l/c/q      macOS only: vim window-prefix (focus / close)
Cmd/Ctrl+[ / ]      focus prev / next pane (single-chord)
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

Bundled third-party software (libvterm, SDL3, SDL3_ttf,
[fff](https://github.com/dmtrKovalenko/fff),
[ols](https://github.com/DanielGavin/ols), Fira Code, Fira Code Nerd
Font, Odin runtime) is distributed under permissive licenses; the
verbatim notices live in [`licenses/`](licenses/) and
[`THIRD_PARTY_LICENSES.md`](THIRD_PARTY_LICENSES.md), and ride along
with every distribution Bragi ships.

The fuzzy file finder is powered by **[fff](https://github.com/dmtrKovalenko/fff)**
by Dmitriy Kovalenko (MIT) — its prebuilt libraries are vendored under
[`vendor/fff/`](vendor/fff/) and bundled into every release. Thanks to
the fff project for a fast, accurate file-search engine.

Odin intellisense is powered by **[ols](https://github.com/DanielGavin/ols)**,
the Odin Language Server by Daniel Gavin and contributors (MIT) — the
prebuilt binary is vendored under [`vendor/odin-lsp/`](vendor/odin-lsp/)
and bundled into every release. Thanks to the ols project.
