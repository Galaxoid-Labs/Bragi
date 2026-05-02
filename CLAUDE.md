# Bragi

Small GPU-accelerated text/code editor in Odin. SDL3 + SDL3_ttf for
window/text, libvterm + forkpty for the embedded terminal pane.
Modal (vim) editing, hand-rolled syntax highlighting, side-by-side
panes, native dialogs, theme-able chrome.

User-facing docs (features, key bindings, build instructions,
packaging) live in `README.md`. This file is for LLMs working on the
code: architectural invariants, file map, and decisions that aren't
self-evident from reading the source.

## Build

```
odin build .                  # produces ./Bragi
./Bragi [path/to/file]
```

Requires Odin **dev-2026-04** or newer (`core:os` overhaul). Runtime
deps: `sdl3`, `sdl3_ttf`, `libvterm` (Homebrew on macOS, distro
packages on Linux). Windows terminal pane is stubbed in `pty.odin`
(no `CreatePseudoConsole` yet) and `vterm.odin` (no-op Odin stubs in
place of the libvterm foreign import); `terminal_open`'s nil-check on
`vterm_new` keeps the rest of the editor functional on Windows.

Two TTFs are embedded via `#load`:
- `FiraCode-Regular.ttf` → editor pane (`g_font`)
- `FiraCodeNerdFont-Regular.ttf` → terminal pane (`g_terminal_font`)

Both have identical advance width so cell math is unchanged.

## File map

- **`main.odin`** — SDL init, main loop, layout, input dispatch, theme,
  text cache, native dialogs, pane lifecycle, draw orchestration.
- **`editor.odin`** — `Editor` struct, cursor / selection, edit
  primitives, auto-close brackets, smart Enter, soft tabs.
- **`gap_buffer.odin`** — Gap buffer with `version: u64` for cache keys.
- **`undo.odin`** — Edit-log undo/redo with adjacent-op merging.
- **`file.odin`** — Load (direct-into-gap-buffer + EOL detect) / save
  (atomic, EOL expand) / `path_basename` / `digit_count`.
- **`vim.odin`** — `Mode` enum, vim parser FSM, motions / operators /
  ex commands. Modes: `Insert`, `Normal`, `Visual`, `Visual_Line`,
  `Command`, `Search`.
- **`syntax.odin`** — Per-language tokenizers (Odin / C / C++ / Go /
  Jai / Swift / Generic / None).
- **`menu.odin`** — Right-click context menu.
- **`help.odin`** — `:h` / `:help` modal cheat-sheet.
- **`finder.odin`** — Cmd/Ctrl+F fuzzy directory navigator.
- **`dot.odin`** — `.` (repeat last edit) recorder.
- **`config.odin`** — INI loader, theme + editor settings.
- **`vterm.odin`** — Foreign bindings for libvterm 0.3.x.
- **`pty.odin`** — `forkpty` wrapper (libutil), non-blocking master fd.
- **`terminal.odin`** — Embedded terminal pane: vterm + PTY + reader
  thread + scrollback ring + scrollbar.

## Conventions

- `snake_case` procs/locals, `Title_Case` types, `SCREAMING_SNAKE`
  package constants.
- Public procs prefixed by concept: `editor_*`, `vim_*`, `syntax_*`,
  `gap_buffer_*`, `terminal_*`, `menu_*`, `clipboard_*`, etc.
- File-private helpers use `@(private="file")`.
- `[]u8` for byte ranges into the buffer; `string` only at API
  boundaries.
- All temp allocations through `context.temp_allocator`; main loop
  calls `free_all(context.temp_allocator)` once per iteration.
- C-conv callbacks (`proc "c"`) must set
  `context = runtime.default_context()` before calling Odin code.

## Buffer caches & mutation rules (load-bearing invariant)

`Editor` carries incrementally-maintained caches keyed off
`gap_buffer.version`:

- `line_starts: [dynamic]int` + `line_widths: [dynamic]int` — parallel
  arrays. `editor_pos_to_line_col` (binary search), `editor_nth_line_start`,
  `editor_total_lines`, `editor_max_line_cols` all read from these.
- `cached_max_cols` / `cached_max_cols_ver` — scan over `line_widths`,
  recomputed on version mismatch.
- `search_match_positions` / `search_match_ver` / `search_match_pattern`
  — keyed on `(buffer.version, pattern)`.

**Mutation rule**: interactive edit paths (typing, deletion, paste,
undo, redo) MUST call `editor_buffer_insert` / `editor_buffer_delete`,
not `gap_buffer_insert` / `gap_buffer_delete` directly. The wrappers
do incremental `line_starts` / `line_widths` updates and bump the
cache version in lock-step.

Bulk paths (`editor_set_text`, `editor_load_file`) bypass the wrappers
and rely on `editor_clear` setting cache versions to `max(u64)` —
sentinel that forces full rebuild on next read.

## Important globals

- `g_renderer`, `g_window`, `g_font`, `g_terminal_font` — SDL3 / TTF
  handles. Both fonts opened at `FONT_SIZE * g_density`.
- `g_density` — `GetWindowPixelDensity` result.
- `g_char_width`, `g_line_height` — monospace metrics (logical pixels).
- `g_text_cache` — `(text, fg, bg, font_ptr) → ^sdl.Texture`. Font ptr
  is in the key so editor / terminal don't collide. Cap
  `TEXT_CACHE_MAX = 1024`; on overflow the whole cache is dropped.
- `g_theme` — every drawable color (syntax + chrome). Loaded from
  `[theme]` in `config.ini`; falls back to `DEFAULT_THEME`.
- `INACTIVE_DIM` — `Color{0, 0, 0, 50}` overlay for non-focused panes.
- `g_cursor_default` / `_resize_h` (↔, vertical pane dividers) /
  `_resize_v` (↕, horizontal terminal divider).
- **Panes**: `g_editors: [dynamic]Editor`, `g_active_idx`,
  `g_pane_ratios: [dynamic]f32`, `g_drag_idx`, `g_resize_divider`.
- **Terminal**: `g_terminal: ^Terminal` (nil when not open),
  `g_terminal_visible`, `g_terminal_active` (keyboard focus),
  `g_terminal_height_ratio`, `g_terminal_resizing`.
- **Vim window-prefix**: `g_pending_ctrl_w` (set after Ctrl+W),
  `g_swallow_text_input` (one-batch guard — see below).
- **Modals**: `g_help_visible`, `g_help_scroll`; `g_finder_visible`.
- **Dialogs**: `g_pending_open` / `_save_as` / `_quit_after_save` /
  `_raise` — flags that defer `sdl.Show*FileDialog` and post-save
  actions to the next loop iteration.

## Layout

`compute_layout()` produces a `Layout` per frame:

- Terminal hidden: editor zone fills `[0, status_y]`, status bar pins
  to the bottom.
- Terminal visible: stack from top is editor → status bar → 4-px
  divider → terminal strip. `Layout.editor_bottom = status_y` in both
  cases (use it instead of `status_y` when painting "down to the
  bottom of the editor zone").
- `g_terminal_height_ratio` is a fraction of `screen_h - status_h`
  (stable across resize).

## Input dispatch — non-obvious bits

- `WaitEventTimeout(250 ms)` keeps idle CPU near zero. VSync is off
  (would make macOS live-resize jerky).
- Cmd OR Ctrl (`KMOD_GUI | KMOD_CTRL`) trigger shortcuts so bindings
  work cross-platform.
- `resize_event_watch` (registered via `AddEventWatch`) fires
  *synchronously* during macOS live-resize, forcing redraws while
  Cocoa otherwise blocks the main thread.
- Mouse routing: button-down sets `g_active_idx` and `g_drag_idx`;
  button-up routes back to `g_drag_idx` (so the originating pane's
  drag state clears even if the cursor wandered). Wheel routes to
  the pane *under the cursor*.
- **Pane-index clamps must use `len(l.panes)`**, NOT `len(g_editors)`.
  Native-dialog callbacks (Cmd+O) can grow `g_editors` synchronously
  from inside SDL's event pump, so the layout `l` we computed at the
  top of the iteration is briefly stale until the next iteration.
- Ctrl+W is the vim window-prefix. Sets `g_pending_ctrl_w`; the next
  key is the action (`h` / `l` / `c` / `q` / Esc).
- `SDL_HINT_QUIT_ON_LAST_WINDOW_CLOSE = "0"` — without this, Cmd+W
  on macOS fires both `WINDOW_CLOSE_REQUESTED` *and* a cascading
  `QUIT`, which would quit the app right after we closed a pane.
- `g_swallow_text_input` is a one-batch guard for chord follow-ups
  (Ctrl+W h, etc.). Cleared at the end of every event-drain batch in
  the main loop so it never bleeds into the next iteration. Don't
  set it for chords that *don't* generate a TEXT_INPUT — the dispatch
  gate at the TEXT_INPUT branch already drops Cmd+letter.

## Embedded terminal — non-obvious bits

- `Terminal` is heap-allocated; `callbacks` (VTermScreenCallbacks)
  lives inline so libvterm's pointer stays valid.
- Reader thread: blocks on the master fd, appends bytes to
  `pending_input` under `input_mutex`, pushes a `USER` event
  (`code = TERMINAL_EVENT`) to wake the main loop.
- On EOF (shell exited): sets `Terminal.exited = true`, pushes one
  final wake-up event, breaks. Main loop's USER handler pumps any
  remaining bytes (so final output renders), then calls
  `terminal_close()` if `exited`.
- **`VTermScreenCellAttrs.flags` MUST be `u32`**, not `u16+u16`. The C
  side is a `uint32_t`-cell bitfield; 2-byte alignment shifts every
  following struct field and makes `fg`/`bg` reads return garbage.
  This caused a "blue on red" rendering bug; do not regress.
- `VTermColor` is `#raw_union` with all-`u8` members, so size = 4 and
  align = 1. The first byte is `type` (RGB / INDEXED / DEFAULT_FG /
  DEFAULT_BG bitflags).
- Scrollback is a `[dynamic]Scrollback_Line` capped at
  `TERMINAL_SCROLLBACK_MAX = 4096`, fed by the `sb_pushline` callback.
  When `scroll_offset > 0` and a new line pushes, increment
  `scroll_offset` so the visible window stays anchored on the user's
  reading position.
- `clear` wipes scrollback (Ghostty-style): `settermprop` callback
  tracks `VTermProp_AltScreen`. After each `vterm_input_write`, scan
  the bytes for `\033[2J` / `\033[3J` / `\033c`; if matched and
  *not* on alt screen, `terminal_clear_scrollback`. The alt-screen
  guard prevents vim/htop redraws from wiping history.
- Cursor block blinks at the editor's 0.5 s cadence when the terminal
  has focus and `scroll_offset == 0`; ghosts at 60 alpha when
  unfocused; hidden entirely while scrolled back.

## Rendering

`draw_frame` composes: clear → per-pane (`draw_editor` →
`draw_gutter` → `draw_scrollbars`) → inactive-pane dim overlays →
pane separators → terminal strip → terminal-inactive dim →
`draw_status_bar` → menu → help → finder → present. Order matters
for the LCD subpixel AA — selection rects render *over* text so the
baked BG color stays right.

`draw_text` uses `RenderText_LCD` (FreeType, `SetFontHinting(.NORMAL)`).
Coordinates are pixel-snapped via `snap_px` to avoid blurring at
fractional positions during smooth scroll.

## Engine-level limitations / known quirks

- **macOS live-resize jumpiness** from right/bottom edges. Event
  watch redraws but Cocoa stretches the last frame momentarily. Real
  fix is `setPreservesContentDuringLiveResize: NO` via Odin's
  Objective-C interop (`core:sys/darwin/Foundation`,
  `intrinsics.objc_*`).
- **No color emoji** — needs PlutoSVG glue in SDL3_ttf for bitmap
  glyph data.
- **Combiners aren't drawn in the terminal** — `terminal_cell_at`
  returns `chars[0]` only.
- **Terminal scrollback eviction is O(n)** at steady state — one
  `ordered_remove(0)` memmove per push past 4096. A true ring index
  would be cleaner.
- **No glyph atlas** — one `^sdl.Texture` per `(text, fg, bg, font)`.

## Roadmap (not started)

- **Windows terminal pane** — `pty.odin` Windows branch needs
  `CreatePseudoConsole` + `CreateProcess`, and `vterm.odin` needs a
  real Windows libvterm build wired up in place of the current no-op
  stubs (foreign-import the DLL/.lib and drop the Windows `else`
  branch). Shell-side bytes then flow through libvterm exactly the
  same as Unix.
- **Mouse double/triple-click** in the editor (word / line selection).
- **Incremental search** — re-find on every keystroke into `cmd_buffer`.
- **Comment toggle** (`gc`) — language-aware; needs per-`Language`
  comment metadata.
- **More tokenizers** — Python, Markdown, JSON, Zig, TS/JS.
- **Untitled-buffer Save flow** — Cmd+W on dirty untitled prompts
  Save / Discard / Cancel; clicking Save fires the dialog but doesn't
  auto-close the pane on success (Cmd+Q already does).
- **Terminal mouse forwarding** via `vterm_mouse_*`.
- **Terminal font override** in config (currently hard-wired to the
  embedded Nerd Font).

## Performance: future upgrade paths

The current load + edit pipeline is snappy up to ~100 MB. Beyond
that, two structural changes are on the table; neither has been
started.

- **mmap-backed open with copy-on-first-edit** — `mmap` instead of
  `os.read_full`; build `line_starts` / `line_widths` against the
  mapped region; copy into a writable gap buffer on first edit.
  Open becomes near-instant regardless of file size; first-edit cost
  ≈ memcpy. ~100 lines, the right next step *for load time*.
- **Piece table (or rope) backing store** — replaces the gap buffer.
  Insert / delete are O(piece-list-edit), independent of file size;
  no memmove on far cursor jumps. Big rewrite touching every byte-
  access path. Right *for sustained editing on gigabyte files*.
