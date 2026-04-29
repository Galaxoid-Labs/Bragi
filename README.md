# Bragi

A small, GPU-accelerated, vim-flavoured text/code editor written in
[Odin](https://odin-lang.org). Cross-platform via SDL3.

```
odin build .
./Bragi                       # opens a welcome screen
./Bragi path/to/file.go       # opens that file
```

Single binary, ~1.3 MB (both fonts are embedded). Statically linked
apart from system SDL3 / SDL3_ttf / libvterm.

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
  bottom strip running your `$SHELL` against a real PTY. libvterm
  drives the cell grid; 4096-line scrollback with its own scrollbar
  matching the editor's chrome; mouse-wheel scrolls history; typing
  snaps back to live; `clear` wipes scrollback (Ghostty-style); `exit`
  closes the pane. Powerline / dev glyphs render correctly via an
  embedded Nerd Font variant of Fira Code. Unix-only for now (Windows
  ConPTY support is a future task).
- **Fuzzy directory navigator** — Cmd+F (macOS) / Ctrl+F (Linux,
  Windows) opens a centered modal at your home directory. Type to
  filter, Enter to dive into a folder or open a file, Backspace or `..`
  to go up. Mouse double-click works too.
- **Fast** — incremental line-index + per-line column-width caches,
  binary-only allocation paths during file load, direct gap-buffer
  reads. 100 MB plain-text files load in a few hundred milliseconds and
  edit smoothly.
- **Syntax highlighting** for **Odin**, **C**, **C++**, **Go**, **Jai**,
  **Swift**, plus a **Generic** fallback (strings / numbers / `//` and
  `/* */` comments) for everything else. Detection by file extension;
  switch manually with `:syntax <name>`.
- **Search** — `/foo` / `?foo` (literal, no regex), `n` / `N` to page,
  `[k/m]` match counter in the status bar, faint match highlights for
  every visible occurrence, `\c` / `\C` per-pattern case overrides,
  `:set ignorecase` / `smartcase` config defaults.
- **Substitute** — `:s/foo/bar/[gi I]` and `:%s/foo/bar/[gi I]`. One
  undo group regardless of how many replacements happened.
- **Vim window-prefix** with `Ctrl+W` — `h l` for focus, `c q` to
  close, `Esc` to cancel.
- **Help screen** with `:h` or `:help` — modal cheat sheet, scrollable
  with mouse / arrows / `j` `k` / `g` `G`.
- **Native everything** — file dialogs (`Cmd+O`, `Cmd+Shift+S`),
  message boxes (mixed-EOL warning, unsaved-changes prompt), context
  menu on right-click. No browser embedded, no Electron, no Node.
- **LCD subpixel text rendering** through SDL3_ttf + FreeType. Embedded
  Fira Code by default; override with any system font via config.
- **Themeable** — every visible color (chrome + syntax) lives in one
  `Theme` struct loaded from `config.ini`.

## Building

### Dependencies

- An [Odin compiler](https://odin-lang.org/docs/install/) from
  **`dev-2026-04`** or newer. The `core:os` package was overhauled in
  that release (`os.Handle` → `^os.File`, `File_Info.is_dir` → `.type`,
  `write_entire_file` now returns an `Error`, etc.); Bragi uses the new
  API and will not build against earlier compilers.
- **SDL3** and **SDL3_ttf** for window / renderer / text.
- **libvterm** for the embedded terminal pane (Unix only — see Windows
  notes below).
- **forkpty** lives in **libutil** on Linux; macOS rolls it into
  libSystem so no extra package is needed.

The two embedded TTFs (`FiraCode-Regular.ttf` and
`FiraCodeNerdFont-Regular.ttf`) are checked in and `#load`-ed at compile
time. There is no runtime font dependency on either.

#### macOS

```sh
brew install sdl3 sdl3_ttf libvterm
```

That's it. SDL3 and SDL3_ttf give you the window + LCD-AA text;
libvterm runs the terminal pane's VT state machine. `forkpty` lives in
libSystem.

If `odin build` complains about a missing `vterm` symbol at link time,
make sure your `DYLD_LIBRARY_PATH` (or just your default linker search
path) covers Homebrew's lib directory — Apple Silicon Macs put it at
`/opt/homebrew/lib`, Intel Macs at `/usr/local/lib`. Homebrew sets this
up automatically on a fresh install.

#### Linux (Debian / Ubuntu)

```sh
sudo apt install libsdl3-dev libsdl3-ttf-dev libvterm-dev libutil-dev
```

#### Linux (Fedora)

```sh
sudo dnf install SDL3-devel SDL3_ttf-devel libvterm-devel libutil-devel
```

`libvterm-devel` ships the same `0.3.x` ABI as Homebrew so the Odin
bindings in `vterm.odin` cover both unchanged. Glibc and musl both
expose `forkpty(3)` via libutil — `libutil-dev` on debian/ubuntu,
`glibc-devel`'s linker stubs on fedora (the package list above already
covers it; on a minimal container you may need `glibc-static`).

#### Windows

Ship `SDL3.dll` and `SDL3_ttf.dll` next to the produced binary.

**The terminal pane is not available on Windows yet.** `pty.odin`'s
Windows branch is stubbed (returns `false` from `pty_spawn`), so
`Cmd+J` / `:term` will fail to open until ConPTY support
(`CreatePseudoConsole` + `CreateProcess`) is wired up. Everything else
— editor, panes, search, syntax, file dialogs — works on Windows.

### Build

```sh
odin build .
```

Produces `./Bragi`. Run it from anywhere; the directory navigator
defaults to `$HOME` (or `%USERPROFILE%` on Windows).

## Packaging

`deploy.ini` at the repo root carries the metadata (app name, version,
identifier, copyright, dependency strings, code-signing identity, …)
that the per-platform packaging scripts read. Edit it once, then run
the script for the host you're on. Output lands in `dist/<platform>/`.

### macOS — `.app` bundle and `.dmg`

```sh
./tools/package_macos.sh
```

Produces `dist/macos/Bragi.app` (drop into `/Applications`) and
`dist/macos/Bragi-<version>.dmg`. The script:

- Builds `bragi` in release mode (`odin build . -o:speed`).
- Generates `Bragi.icns` from `icon.png` via `sips` + `iconutil`.
- Writes `Info.plist` (CFBundle keys, document-type associations,
  high-DPI flag, minimum macOS version).
- Bundles every Homebrew-provided dylib (`libSDL3`, `libSDL3_ttf`,
  `libvterm`, plus their transitive deps) into
  `Bragi.app/Contents/Frameworks/` and rewrites the binary's load
  paths via `install_name_tool`. **No Homebrew required on the
  target machine.**
- Code-signs the bundle. With `codesign_identity` set in
  `[macos]` it uses your Developer ID and runs `--options runtime`
  (notarization-ready); without one it falls back to ad-hoc signing
  so the binary launches on Apple Silicon.
- If `notarize_apple_id` / `notarize_password` / `notarize_team_id`
  are filled in, submits to Apple's notary service and staples the
  ticket onto both the `.app` and the `.dmg`.

Stage toggles for iteration: `STAGE_BUILD=0`, `STAGE_BUNDLE=0`,
`STAGE_SIGN=0`, `STAGE_DMG=0`.

All required tools (`sips`, `iconutil`, `plutil`, `codesign`,
`hdiutil`, `otool`, `install_name_tool`) ship with the Xcode
Command Line Tools — `xcode-select --install`.

### Linux — `.deb` and `.rpm`

```sh
./tools/package_linux.sh
```

Must run on a Linux host. Produces:

- `dist/linux/bragi_<version>_<arch>.deb` (Debian/Ubuntu)
- `dist/linux/bragi-<version>-1.<rpmarch>.rpm` (Fedora/RHEL)

Each format auto-skips if its build tool isn't installed, so a
Fedora box without `dpkg-dev` will produce the `.rpm` only (and
print a friendly "skipped" notice for the `.deb`).

Both packages declare runtime dependencies on the distro's SDL3,
SDL3_ttf, and libvterm packages — `apt` / `dnf` resolves those at
install time. (Bundling `.so` files inside Linux packages is fragile
across glibc / Wayland / X11 versions and discouraged by both
packaging policies.) The dependency strings are configurable in
`[linux]` of `deploy.ini` if your target distros use different
package names.

The script installs to standard FHS paths:

```
/usr/bin/bragi
/usr/share/applications/bragi.desktop
/usr/share/icons/hicolor/<size>/apps/bragi.png
/usr/share/pixmaps/bragi.png
/usr/share/doc/bragi/copyright
```

#### Build-host setup

```sh
# Fedora 40+
sudo dnf install -y \
  gcc clang git curl unzip ImageMagick \
  SDL3-devel SDL3_ttf-devel libvterm-devel \
  rpm-build dpkg                  # dpkg only if you also want a .deb

# Debian 13+ / Ubuntu 24.04+
sudo apt-get install -y \
  build-essential clang git curl unzip imagemagick \
  libsdl3-dev libsdl3-ttf-dev libvterm-dev \
  dpkg-dev rpm                    # rpm only if you also want a .rpm
```

Plus a current Odin compiler:

```sh
curl -L https://github.com/odin-lang/Odin/releases/latest/download/odin-linux-amd64.zip \
  -o /tmp/odin.zip
sudo unzip -o /tmp/odin.zip -d /opt/odin
sudo ln -sf /opt/odin/odin /usr/local/bin/odin
```

#### From macOS via Docker

The Linux script refuses to run on macOS (it'd produce a Mach-O
binary that can't be packaged for Linux). To build Linux packages
from a Mac, drop into a Debian container that has both `dpkg-deb`
and `rpmbuild`:

```sh
docker run --rm -it -v "$(pwd):/src" -w /src debian:bookworm bash -c '
  apt-get update && apt-get install -y \
    build-essential clang git curl unzip \
    libsdl3-dev libsdl3-ttf-dev libvterm-dev \
    dpkg-dev rpm imagemagick &&
  curl -L https://github.com/odin-lang/Odin/releases/latest/download/odin-linux-amd64.zip \
    -o /tmp/odin.zip &&
  unzip /tmp/odin.zip -d /opt/odin && export PATH=/opt/odin:$PATH &&
  ./tools/package_linux.sh
'
```

Stage toggles: `STAGE_BUILD=0`, `STAGE_DEB=0`, `STAGE_RPM=0`.

### Windows

Not yet — the embedded terminal pane needs ConPTY support in
`pty.odin` first. Editor-only Windows packaging (zip with
`Bragi.exe` + `SDL3.dll` + `SDL3_ttf.dll`) is doable today; it'll
land alongside the terminal work.

## Quick reference

Press `:h` inside the editor for the full cheat sheet. The greatest
hits:

```
i  a  I  A  o  O    enter Insert at various positions
v  V                enter Visual / Visual-Line
Esc                 return to Normal

h j k l             motion (line-bounded)
w b e               word forward / back / end
0 $ ^               line start / end / first non-blank
gg G  <n>G          first / last / nth line
Ctrl+D / Ctrl+U     half-page down / up
zz  zt  zb          centre / top / bottom cursor on screen
%                   jump to matching bracket

dd yy cc            delete / yank / change line
dw  3dw  c3w        operator + motion (counts compose)
D C Y               d$  c$  y$
>> <<               indent / outdent line
.                   repeat last change
u  /  Ctrl+Shift+Z  undo / redo

/pattern  ?pattern  search forward / backward (literal)
n N                 next / prev match (wraps)
:noh                clear search

:e <path>           open file (replaces blank pane, else splits)
:r <path>           replace active pane with file
:w  :q  :wq  :q!    save / quit / save+quit / force-quit
:42                 jump to line 42
:syntax <name>      switch tokenizer
:s/pat/repl/[gi I]  substitute (current line)
:%s/pat/repl/[gi I] substitute (whole buffer)
:term :terminal     open / focus the terminal (Cmd/Ctrl+J toggles)
:termclose          close the terminal pane
:h  :help           open this cheat sheet

Cmd/Ctrl+F          open the directory navigator
Cmd/Ctrl+J          toggle the bottom terminal pane
Cmd+S               save
Cmd+Shift+S         save as
Cmd+O               native open dialog
Cmd+Z / Cmd+Shift+Z undo / redo
Cmd+W               close pane (last pane → welcome → quit)
Ctrl+W h / l        focus pane left / right
Ctrl+W c / q        close active pane
Cmd+[ / Cmd+]       focus prev / next pane (single-chord)
drag pane border    resize adjacent panes
drag term divider   resize the terminal strip
wheel over term     scroll the terminal scrollback (4096-line ring)
```

## Configuration

Bragi reads `config.ini` from a per-platform location at startup:

| Platform | Path |
|----------|------|
| macOS    | `~/Library/Application Support/Bragi/config.ini` |
| Linux    | `$XDG_CONFIG_HOME/bragi/config.ini` (defaults to `~/.config/bragi/config.ini`) |
| Windows  | `%APPDATA%\Bragi\config.ini` |

The file is optional — every field has a sensible default. Example:

```ini
[font]
path    =                       # blank → use the embedded Fira Code
size    = 14
hinting = normal                # normal / light / light_subpixel / mono / none

[editor]
tab_size     = 4
column_guide = 120              # 0 to disable
line_spacing = 1.3
ignorecase   = true
smartcase    = true

[theme]
# Syntax (any field can be #RRGGBB or #RRGGBBAA)
default  = #DCDCDC
keyword  = #C678DD
type     = #5FC8DA
constant = #E5C07B
number   = #D7915A
string   = #98C379
comment  = #5F6E82
function = #61AFEF

# Chrome
bg              = #1E1E26
cursor          = #F0C850
selection       = #465F9678
search_match    = #BE50B478
gutter_bg       = #18181E
gutter_text     = #5A5F6E
gutter_active   = #C8C8D2
status_bg       = #14141A
status_path_bg  = #1C1C24
status_text     = #C8C8D2
status_dim      = #787D8C
status_error    = #DC5A5A
sb_track        = #282830
sb_thumb        = #5A5A64
sb_thumb_hover  = #82828C
```

## Status & roadmap

This is a personal-scratch editor; expect rough edges. The core flow
(open / edit / save / search / multi-pane) is solid for daily use on
files up to ~100 MB. Beyond that, performance is acceptable but not
amazing — see CLAUDE.md for the upgrade paths (mmap-backed open,
piece-table backing store).

Things that aren't done yet but are tracked in CLAUDE.md:
- Windows terminal pane (ConPTY support).
- Incremental search (debounced).
- Mouse double / triple-click selection in the editor itself.
- Cmd+W → Save → auto-close (untitled-buffer save flow).
- Python / Markdown / JSON / Zig / TS-JS syntax tokenizers.
- Glyph atlas (would speed up first-display of large files).
- Terminal mouse forwarding (so tmux / htop / vim get mouse events
  inside the terminal pane).
- Comment toggle (`gc` / `Ctrl+/`), language-aware.

## Architecture

If you want to hack on Bragi, start with `CLAUDE.md` — it walks through
the code layout (single Odin package across ~10 files), the buffer
caches and their invariants, and the rendering / input pipelines.

## License

TBD.
