# Bragi

A small, GPU-accelerated, vim-flavoured text/code editor written in
[Odin](https://odin-lang.org). Cross-platform via SDL3.

```
odin build .
./Bragi                       # opens a welcome screen
./Bragi path/to/file.go       # opens that file
```

Single binary, ~930 KB (the font is embedded). Statically linked apart
from system SDL3 / SDL3_ttf.

## Highlights

- **Modal editing** — Insert / Normal / Visual / Visual-Line / Command /
  Search modes. Most of the daily-use vim verbs work the way you
  expect: `dw`, `c$`, `5dd`, `>>`, `yy`+`p`, `.`, `%`, `zz`, `Ctrl+D`,
  `Ctrl+U`, `gg` / `G`, etc.
- **Side-by-side panes** — drag any file onto the window or hit
  Cmd/Ctrl+F to open a directory navigator. Each new file opens in a
  resizable column. `Ctrl+W h` / `Ctrl+W l` (or `Cmd+[` / `Cmd+]`)
  switches focus; drag the boundary to resize.
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
- **SDL3** + **SDL3_ttf** at runtime.

#### macOS

```sh
brew install sdl3 sdl3_ttf
```

#### Linux (Debian / Ubuntu)

```sh
sudo apt install libsdl3-dev libsdl3-ttf-dev
```

(or `SDL3-devel SDL3_ttf-devel` on Fedora)

#### Windows

Ship `SDL3.dll` and `SDL3_ttf.dll` next to the produced binary.

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
:h  :help           open this cheat sheet

Cmd/Ctrl+F          open the directory navigator
Cmd+S               save
Cmd+Shift+S         save as
Cmd+O               native open dialog
Cmd+Z / Cmd+Shift+Z undo / redo
Cmd+W               close pane (last pane → welcome → quit)
Ctrl+W h / l        focus pane left / right
Ctrl+W c / q        close active pane
Cmd+[ / Cmd+]       focus prev / next pane (single-chord)
drag pane border    resize adjacent panes
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
- Incremental search (debounced).
- Mouse double / triple-click selection in the editor itself.
- Cmd+W → Save → auto-close (untitled-buffer save flow).
- Python / Markdown / JSON syntax tokenizers.
- Glyph atlas (would speed up first-display of large files).

## Architecture

If you want to hack on Bragi, start with `CLAUDE.md` — it walks through
the code layout (single Odin package across ~10 files), the buffer
caches and their invariants, and the rendering / input pipelines.

## License

TBD.
