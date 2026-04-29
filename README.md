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

- A recent [Odin compiler](https://odin-lang.org/docs/install/).
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
