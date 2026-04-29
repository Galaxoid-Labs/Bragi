# Bragi

A small GPU-accelerated text/code editor written in Odin. Cross-platform via
SDL3 + SDL3_ttf. Modal (vim) editing, hand-rolled syntax highlighting, LCD
subpixel text rendering, native file dialogs, native message boxes, custom
in-app context menu, **resizable side-by-side panes** for viewing /
editing multiple files at once, **embedded terminal pane** (libvterm + PTY)
with scrollback, **modal help screen** (`:h` / `:help`), fully theme-able
chrome.

## Build & run

```
odin build .                        # produces ./Bragi
./Bragi                       # opens with welcome buffer (NORMAL mode)
./Bragi path/to/file          # opens that file at startup
```

Single binary, ~1.3 MB (includes two embedded TTFs), statically linked
apart from system SDL3 / SDL3_ttf / libvterm.

**Dependencies (per platform):**
- macOS: `brew install sdl3 sdl3_ttf libvterm` — that's it. `forkpty` lives
  in libutil, which is rolled into libSystem so no extra package.
- Linux: `libsdl3-dev`, `libsdl3-ttf-dev`, `libvterm-dev`, `libutil-dev`
  on debian/ubuntu (the matching `*-devel` variants on fedora). SDL3_ttf
  bundles FreeType + HarfBuzz + PlutoSVG so font rendering is identical
  to macOS.
- Windows: ship `SDL3.dll` and `SDL3_ttf.dll` next to the binary.
  **The terminal pane is not yet implemented on Windows** —
  `pty.odin`'s Windows branch returns `false` from `pty_spawn`, so
  `:term` / `Cmd+J` will fail to open. ConPTY support
  (`CreatePseudoConsole` + `CreateProcess`) is a future task.
  Everything else (editor, panes, search, syntax, etc.) works.

Both TTFs are **embedded into the binary** at compile time via `#load`
(`FIRA_CODE_DATA` and `NERD_FONT_DATA` in `main.odin`) and loaded
through `SDL_IOFromConstMem` + `TTF_OpenFontIO`. The editor pane uses
plain Fira Code; the terminal pane uses the Nerd Font variant
(`FiraCodeNerdFont-Regular.ttf`) so prompts that ship powerline / dev
glyphs render correctly. Both fonts have identical advance width — cell
math doesn't change between them. Users can override the editor font
via `font.path` in their config; if the override fails to load, the
editor logs a warning and falls back to the embedded Fira Code. There
is no override for the terminal font yet.

## Files

Single Odin package across these files:

- **`main.odin`** — SDL3 init, window/renderer/font, multi-pane layout,
  input dispatch (incl. divider drag and Ctrl+W prefix), per-pane
  drawing, embedded FiraCode TTF (`#load`), the main loop, `Theme`
  struct (syntax + chrome), text cache, native file-dialog triggers +
  callbacks, unsaved-changes prompt, mixed-EOL warning, resize
  event-watch, pane lifecycle (`open_new_pane`,
  `open_file_in_new_pane`, `open_file_smart`, `should_replace_active`,
  `replace_active_pane_with_file`, `close_active_pane_unconditional`,
  `try_close_active_pane`, `try_quit_all`).
- **`editor.odin`** — `Editor` struct (the central state), cursor/selection
  primitives, edit operations (insert/backspace/delete/movement/select-all),
  tab-stop math, soft-tab insert, **auto-close brackets** with over-type +
  word-context heuristic for quotes, **smart Enter** that preserves indent
  and splits-between-brackets.
- **`gap_buffer.odin`** — `Gap_Buffer` storage. O(1) inserts/deletes near the
  cursor, O(distance) gap moves. Single source of truth for buffer bytes.
- **`undo.odin`** — Edit-log undo/redo. Records `Insert`/`Delete` ops into a
  `pending` group; movement commits the group. Adjacent same-kind contiguous
  ops merge (typing "hello" undoes in one step). The auto-close path patches
  the merged op's `cursor_after` so redo lands the caret between the
  brackets, not past the close.
- **`file.odin`** — Load/save (atomic via `os.write_entire_file`); EOL
  detection + LF/CRLF normalize-on-load + expand-on-save with byte-perfect
  round-trip for uniform files; `editor_load_file` picks the syntax language
  from the file extension; `path_basename` and `digit_count` helpers.
- **`vim.odin`** — `Mode` enum (Insert/Normal/Command), vim parser FSM,
  motions (h/j/k/l, w/b/e, 0/$/^, gg/G), operators (d/c/y) with motion or
  doubled forms, `D`/`C`/`Y` (d$/c$/y$), counts, ex-style `:` commands
  (`:w` `:q` `:wq` `:q!` `:e <path>` `:42` `:syntax <name>`).
- **`syntax.odin`** — `Token`/`Token_Kind`/`Tokenizer_State`/`Language`. Hand-
  rolled per-language tokenizers. `Generic` mode covers strings, numbers,
  `//` and `/* */` (multi-line) comments and works as a fallback for any
  C-family-shaped file. `Odin` adds keywords, types, constants
  (true/false/nil), function-call detection (`identifier(`), and a
  capitalized-identifier heuristic for type names.
- **`menu.odin`** — Custom in-app right-click context menu: `Menu_Action`
  enum, `CONTEXT_MENU` items array, hover/click handling, draw routine,
  per-platform shortcut hints (⌘ on macOS, Ctrl+ elsewhere). Items: Cut,
  Copy, Paste, Select All, Undo, Redo, Open…, Save, Save As…
- **`help.odin`** — Modal cheat-sheet popup (`:h` / `:help`). Static
  `HELP_LINES` array, scrollable via mouse-wheel / arrows / `j` `k` /
  Page Up-Down / `g` `G`. Section headers and command keys are colored;
  body text uses default. Esc or click-outside dismisses; while open it
  swallows all input so editor buffers stay untouched.
- **`config.odin`** — INI loader. `Config { font, editor, theme }`,
  per-platform user config path (XDG / `Application Support` / APPDATA),
  `#RRGGBB` / `#RRGGBBAA` color parser. `[theme]` section supports
  every chrome color as well as syntax tokens.
- **`finder.odin`** — Fuzzy directory navigator (Cmd/Ctrl+F).
  `g_finder_visible`, the listing + filter ring, hover/keyboard/wheel
  routing. Centered modal styled like the help / context menu;
  `Backspace` / `..` go up, Enter dives into a directory or opens a file.
- **`dot.odin`** — `.` (repeat last edit) recorder. Watches Insert mode
  runs (`dot_observe_pre`/`post`/`insert`/`esc`) and operator+motion
  sequences and stores them as a replayable thunk that fires when the
  user hits `.` in Normal.
- **`vterm.odin`** — Odin foreign bindings for libvterm 0.3.x. Just the
  surface we need: `vterm_new`/`free`/`set_size`, `vterm_input_write`,
  `vterm_output_read`, keyboard encoding (`vterm_keyboard_unichar` /
  `vterm_keyboard_key`), screen + state handles, `vterm_screen_get_cell`,
  `vterm_screen_set_callbacks`, `VTermScreenCallbacks` struct,
  `VTermColor` tagged union, `VTermProp_AltScreen` constant. Layout
  matches `/opt/homebrew/include/vterm.h` byte-for-byte —
  `VTermScreenCellAttrs.flags` is a `u32` (NOT `u16+u16`) so the
  4-byte-aligned C bitfield doesn't shift `fg`/`bg` reads.
- **`pty.odin`** — Pseudo-terminal abstraction. Unix path uses
  `forkpty(3)` (libutil on macOS / glibc-musl on Linux), which wraps
  openpt+grantpt+unlockpt+fork+TIOCSCTTY into one call. Master fd is
  set non-blocking; reader thread polls + sleeps 1 ms on EAGAIN.
  `pty_close` sends SIGTERM after closing the master fd in case the
  shell ignored the SIGHUP. Windows branch is stubbed (`return false`).
- **`terminal.odin`** — Embedded terminal pane on top of `vterm.odin` +
  `pty.odin`. `Terminal` struct: vterm + screen + state handles, PTY,
  reader thread + mutex + `pending_input` ring, scrollback ring
  (`Scrollback_Line` / `TERMINAL_SCROLLBACK_MAX = 4096`), `scroll_offset`,
  `on_alt_screen` flag, blink timer, `exited` flag, scrollbar drag
  state, `callbacks` (kept inline so libvterm's pointer stays valid).
  Public surface: `terminal_open` / `_close` / `_resize` /
  `_pump` / `_flush_output` / `_send_rune` / `_send_special` /
  `_toggle` / `_fit_to_rect` / `_scroll_by` / scrollbar hit-test +
  drag procs. `TERMINAL_EVENT` is the SDL custom-event code the
  reader pushes when bytes arrive or the shell exits.

## Important globals (in main.odin)

- `g_renderer`, `g_window`, `g_font`, `g_terminal_font` — SDL3 / TTF
  handles. The Nerd Font is a separate `^ttf.Font` opened at the same
  size; only the terminal pane uses it.
- `g_density` — `GetWindowPixelDensity` result; both fonts are opened
  at `FONT_SIZE * g_density` so glyphs rasterize at full physical resolution.
- `g_char_width`, `g_line_height` — precomputed monospace metrics in logical
  pixels. Identical for both fonts.
- `g_text_cache` — hash-keyed cache of `(text, fg, bg, font_ptr) → ^sdl.Texture`.
  The font pointer is mixed into the key so editor + terminal textures
  for the same `(text, fg, bg)` don't collide. Cap at `TEXT_CACHE_MAX = 1024`;
  on overflow the whole cache is dropped (cheap to rebuild on the next few frames).
- `g_theme` — `Theme` struct holding *every* drawable color in the app
  (syntax tokens + chrome). Loaded from the user's `[theme]` section in
  `config.ini`; falls back to `DEFAULT_THEME`.
- `INACTIVE_DIM` — `Color{0, 0, 0, 50}` overlay used to dim non-focused
  panes (and the terminal when it doesn't have focus). Single shared
  constant so both call sites stay in sync.
- **Panes:**
  - `g_editors: [dynamic]Editor` — one per visible column.
  - `g_active_idx` — focused editor pane index. Receives keyboard input
    when the terminal does *not* own focus.
  - `g_pane_ratios: [dynamic]f32` — per-pane width as a fraction of the
    window (sums to 1). Scales with window resize. Adjusted when the user
    drags a divider.
  - `g_drag_idx` — pane that an in-flight mouse drag started in (-1 when
    idle); routes motion / button-up back there even if the cursor wandered.
  - `g_resize_divider` — index of the right-side pane whose left edge is
    being dragged (-1 = no resize in progress).
  - `g_cursor_default` / `g_cursor_resize_h` / `g_cursor_resize_v` —
    system cursors. `_resize_h` is `EW_RESIZE` (↔), used on vertical
    pane dividers. `_resize_v` is `NS_RESIZE` (↕), used on the
    horizontal terminal divider.
- **Terminal:**
  - `g_terminal: ^Terminal` — non-nil while a terminal pane exists.
    Cleared by `terminal_close` (which is called from the main loop
    when the child shell exits or the user hits `:termclose`).
  - `g_terminal_visible` — controls whether the bottom strip is laid
    out and drawn. Toggled by Cmd+J / Ctrl+J / `:term`.
  - `g_terminal_active` — keyboard focus is on the terminal. When
    true, all non-shortcut keys route to libvterm's keyboard encoder
    instead of the active editor; clicking inside the editor area
    flips it back to false.
  - `g_terminal_height_ratio` — fraction of `screen_h - status_h` the
    terminal occupies (default 0.30). Survives window resize.
  - `g_terminal_resizing` — true mid-drag of the horizontal divider.
- **Vim window-prefix:**
  - `g_pending_ctrl_w` — set after Ctrl+W; the next key is interpreted as a
    window command (`h` / `l` / `c` / `q` / Esc).
  - `g_swallow_text_input` — one-batch guard for chord follow-ups (Ctrl+W h,
    etc.). Set when a key handler knows a TEXT_INPUT for the same physical
    press is about to fire and shouldn't reach the buffer. Cleared at the
    end of every event-drain batch in the main loop, so it can never bleed
    into the next iteration and eat an unrelated keystroke.
- **Help modal:**
  - `g_help_visible` / `g_help_scroll` — see `help.odin`.
- **Dialogs:**
  - `g_pending_open` / `g_pending_save_as` / `g_pending_quit_after_save` —
    flags that defer `sdl.Show*FileDialog` and post-save quit to the next
    main-loop iteration (calling `Show*` from inside an event handler is
    flaky on macOS).
  - `g_pending_raise` — set by dialog callbacks; `flush_pending_dialogs`
    calls `RaiseWindow` + re-arms `StartTextInput` next iteration to restore
    keyboard focus.

## Rendering pipeline

Each frame (`draw_frame`):

1. `compute_layout()` — computes screen rects per pane (gutter, text
   area, scrollbar tracks), the status bar position, and the terminal
   strip + divider when visible. With the terminal hidden, status pins
   to the bottom and the editor zone fills everything above it. With it
   visible, the vertical stack from top to bottom is: editor → status
   bar → 4-px divider → terminal. The status bar always sits adjacent
   to the editor it describes. `Layout.editor_bottom` is the bottom y
   of the editor zone — call sites that paint "down to the bottom of
   the editor" use it instead of `status_y`.
2. BG clear → for each pane in order: `draw_editor(pane, is_active)` →
   `draw_gutter(pane)` → `draw_scrollbars(pane)`.
3. **Inactive-pane dim overlay**: an `INACTIVE_DIM` (alpha 50) rect is
   filled over each non-focused pane's column. When the terminal owns
   keyboard focus *every* editor pane gets dimmed (the active editor
   no longer reads as focused — the terminal does); when an editor
   pane owns focus, only its peers dim. Drawn *before* the separators
   so the dividers stay crisp.
4. **Pane separators**: a 1-physical-pixel vertical line is drawn at
   each non-leftmost pane's left edge in `gutter_bg_color`.
5. **Terminal strip** (`g_terminal_visible`): the divider strip is
   filled in `gutter_bg_color`, then `draw_terminal(l.terminal_rect)`
   walks the cell grid (live screen + scrollback as appropriate) and
   draws its own scrollbar inside the right `SB_THICKNESS` of the rect.
   When the terminal doesn't own focus, the same `INACTIVE_DIM`
   overlay is filled over the terminal rect so it reads as inactive
   alongside dimmed editor panes.
6. `draw_status_bar(active_editor, l)` — two-row strip:
   - Top row (`status_path_bg_color`): one segment per pane showing its
     full file path; active pane's path is bright (`status_text_color`),
     others dim (`status_dim_color`). Each segment is clipped to its
     own column so a long path doesn't bleed into the neighbor.
   - Bottom row (`status_bg_color`): mode label + EOL + `[k/m]` search
     count + cursor `line:col` for the active pane only. In Command /
     Search modes the bottom row hosts the `:` / `/` prompt instead.
7. `draw_menu()` then `draw_help(l)` — context menu draws on top of the
   editor; the help modal draws on top of everything else (with a
   dimming layer behind it).
8. `RenderPresent`.

Inside `draw_editor`, visible lines are tokenized via `syntax_tokenize`
and each token segment is drawn as a separate `draw_text` call (cached
per-segment per-color). Block comments use `compute_state_at_line` to
resume tokenizer state from the start of the buffer up to the first
visible line — this short-circuits for `Language.None` (plain text).
Selection rects render *over* text (alpha-blended) so the LCD subpixel
AA stays correct against the baked BG color. The active match of the
current search pattern uses `search_match_color` instead of the regular
`selection_color`. Caret renders last; in Normal mode it's a translucent
block, Insert is a 2px bar, Command/Search hide the caret (it's in the
status bar instead). **Inactive panes don't blink** — they paint a
60-alpha block at the cursor position so you can see where their
caret would resume.

The column guide (`column_guide`, default 120) is a 1-physical-pixel
vertical line drawn before text in `comment_color` at low alpha.

`draw_text` uses `RenderText_LCD` (LCD subpixel AA, FreeType with
`SetFontHinting(.NORMAL)`). Coordinates are pixel-snapped via `snap_px` to
avoid blurring at fractional positions during smooth scroll.

## Input dispatch

- `WaitEventTimeout(250 ms)` keeps idle CPU near zero (250 ms is fine for
  caret blink, drains all queued events on each wakeup).
- VSync is **off** — `RenderPresent`'s vsync wait makes macOS live-resize
  jerky; uncapped frame rate during active input is fine because draws are
  cache-cheap.
- `process_event(ev, l, running)` routes keyboard, text input, mouse,
  scroll, drop file, and window events. Keyboard / text input always
  go to `active_editor()`; mouse events resolve which pane was hit
  before being routed.
- `resize_event_watch` (registered via `AddEventWatch`) fires
  *synchronously* during macOS live-resize and forces a redraw inside
  Cocoa's event loop, where the main thread is otherwise blocked.
- Modifiers: Cmd OR Ctrl (`KMOD_GUI | KMOD_CTRL`) trigger shortcuts so the
  same bindings work on macOS and Linux/Windows.

### Pane routing

- **`pane_at_x(x, l)`** finds the column that contains `x`.
- **Mouse-down** sets `g_active_idx` and `g_drag_idx` to the hit pane,
  then calls `handle_mouse_button` against that pane's `Pane_Layout`.
- **Mouse-up** routes back to `g_drag_idx` (not the current cursor
  pane) so the *originating* pane's drag state always gets cleared,
  even if the mouse wandered into a neighbor before release.
- **Mouse-motion** while a drag is active routes to the dragging pane;
  otherwise it goes to the active pane (for menu hover effects, etc.).
- **Mouse-wheel** routes to the pane *under the cursor* (regardless of
  focus), and clamps that pane's scroll inline. The main loop also
  clamps every pane's scroll once per iteration as a backstop.

### Divider drag

- `divider_at_x(x, l)` returns the index of a pane whose left edge is
  within `DIVIDER_GRAB_PX / 2` of `x`. The grab strip overlaps the
  rightmost few pixels of one pane's scrollbar and the leftmost few of
  the next pane's gutter — divider hit takes priority.
- On hover, `MOUSE_MOTION` swaps to `g_cursor_resize` (`EW_RESIZE`); on
  leave, back to `g_cursor_default`.
- On grab, `g_resize_divider` is set; subsequent motion calls
  `move_divider` which updates the two adjacent pane ratios (clamped
  so neither shrinks below `MIN_PANE_PX`).

### Vim window-prefix (Ctrl+W)

- `Ctrl+W` is captured in `handle_key_down` and sets
  `g_pending_ctrl_w`. The next key is interpreted as a window command:
  - `h` / Left → focus prev pane
  - `l` / Right → focus next pane
  - `c` / `q` → close active pane
  - Esc → cancel the prefix
- The follow-up handler sets `g_swallow_text_input` so the rune SDL
  queues for the same physical keypress doesn't get inserted into the
  new active buffer. The flag is also cleared at the end of each
  event-drain batch (see `g_swallow_text_input` in the globals
  section) — that's the safety net that prevents a chord that doesn't
  actually queue a TEXT_INPUT (e.g. some Cmd+letter combinations on
  macOS) from leaking the swallow into the user's next real keystroke.

### Window close vs app quit

- `SDL_HINT_QUIT_ON_LAST_WINDOW_CLOSE` is set to **`"0"`**. Without
  this, Cmd+W on macOS would fire `WINDOW_CLOSE_REQUESTED` *and*
  cascade into a `QUIT` — quitting the app right after our handler
  closed a pane.
- `WINDOW_CLOSE_REQUESTED` (Cmd+W on macOS, red traffic light): closes
  the active pane if there are multiple panes; falls through to
  `try_quit_all` (and exits if all panes are clean / saved) if there's
  only one. Cmd+Q always goes through `applicationShouldTerminate` →
  `QUIT`, which always calls `try_quit_all`.

### Mouse, text, gutter (per-pane)

- Left click in **gutter** moves caret to start of line (drag selects
  by line via the natural col-clamp in `mouse_to_buffer_pos`).
- Left click in **scrollbar track** (not on thumb) jumps the thumb
  center to the click position and continues as a drag.
- Right click in text or gutter shows the context menu; menu only
  responds to button-DOWN events so the right-click-up doesn't
  immediately dismiss it.
- Native file dialogs (`Cmd+O`, `Cmd+Shift+S`, menu items): trigger sets a
  flag, main loop fires the actual `Show*FileDialog` after events drain.
  Callback restores window focus by setting another flag.
- `Cmd+S` on a buffer with no path falls through to Save As.

### Help modal

- When `g_help_visible`, `handle_key_down` interprets keys for scrolling
  / dismissing only and never reaches editor logic.
- `handle_text_input` returns immediately (no rune insertion).
- Mouse-down outside the modal dismisses it; clicks inside are
  swallowed.

## Embedded terminal

The terminal pane is a real pane at the bottom of the window: cell
grid + scrollbar + scrollback + horizontal divider. It's a thin shell
over libvterm (the VT state machine + cell grid) plus a forkpty-spawned
child shell.

### Lifecycle

- `terminal_open(rows, cols)` allocates the `Terminal`, calls
  `vterm_new`, registers screen callbacks (`sb_pushline`,
  `settermprop`), spawns `$SHELL` (or `/bin/sh`) on the slave end of a
  fresh PTY, and starts a reader thread.
- `terminal_toggle(rows, cols)` opens on first call; afterwards flips
  visibility without killing the child shell. Bound to Cmd+J /
  Ctrl+J / `:term` / `:terminal`.
- `terminal_close()` sets the reader-quit flag, closes the master fd
  (which unblocks the reader's `read()`), `WaitThread`s the reader,
  frees vterm + scrollback + mutex + the struct itself, and resets
  `g_terminal_visible` and `g_terminal_active`. Bound to `:termclose`,
  the explicit kill path; also called automatically when the child
  shell exits (see "auto-close" below).
- `terminal_resize(rows, cols)` updates libvterm + the PTY's winsize
  (TIOCSWINSZ) so apps like vim and htop redraw at the new dimensions.
  Called every frame from `draw_frame` via `terminal_fit_to_rect`,
  which re-derives `(rows, cols)` from the current pane rect minus
  `SB_THICKNESS` (the scrollbar strip).

### Cross-thread input pumping

The PTY reader thread reads bytes off the master fd into a thread-local
`buf [4096]u8`, locks `input_mutex`, appends them to
`pending_input: [dynamic]u8`, unlocks, and pushes a custom SDL event
(`type = USER`, `code = TERMINAL_EVENT`). The main loop's
`WaitEventTimeout` wakes on this; the USER handler calls
`terminal_pump`, which:

1. Locks the mutex, hands the buffer to `vterm_input_write`, scans for
   "clear screen" sequences, clears the buffer, sets `dirty`, unlocks.
2. After pump, if `g_terminal.exited` is set, calls `terminal_close()`
   on the spot (see auto-close).

`terminal_flush_output` then drains libvterm's outbound queue (escape
sequences it generated in response to keyboard / mouse encoding) back
to the PTY master fd via `pty_write`.

### Scrollback

- `scrollback: [dynamic]Scrollback_Line` (cap `TERMINAL_SCROLLBACK_MAX = 4096`)
  is fed by libvterm's `sb_pushline` callback — fired when a line
  scrolls off the top of the live grid. We deep-copy the cell row
  (libvterm's pointer is only valid during the call), evict the
  oldest at capacity (`ordered_remove(0)`), and append.
- `scroll_offset` is the user's view position, in lines above live.
  When `> 0` and the ring grows, `sb_pushline` increments
  `scroll_offset` by 1 to keep the visible window anchored — the
  user's reading position doesn't jump as new bottom lines push
  history off the top. Capped at `len(scrollback)`.
- Render math (`terminal_cell_at`): visible row `i` reads from
  scrollback when `i < scroll_offset` (index `len - scroll_offset + i`),
  else from the live screen at row `i - scroll_offset`.
- `scroll_offset` resets to 0 on any keystroke (`terminal_send_rune` /
  `_send_special`) so typing snaps back to live, and on `terminal_resize`
  because the grid has been warped and the position is meaningless.
  The cursor block is hidden whenever `scroll_offset > 0`.

### `clear` wipes scrollback (Ghostty-style)

The settermprop callback tracks `VTermProp_AltScreen`. After every
`vterm_input_write`, `bytes_contain_clear_screen` scans the freshly-
fed bytes for `\033[2J`, `\033[3J`, or `\033c`; if any matched and we
are *not* on the alt screen, `terminal_clear_scrollback` frees the
ring and snaps `scroll_offset = 0`. TUI apps (vim / htop / less) emit
the same erase sequences on every redraw — the alt-screen guard
prevents those from wiping the pre-app history the user wants to scroll
back to after they exit.

### Scrollbar

`terminal_split_rect` reserves the rightmost `SB_THICKNESS` for the
scrollbar track, even when no scrollback exists yet (so the cell-grid
width doesn't reflow the moment the first line scrolls). Thumb metrics
go through the same `scrollbar_thumb_metrics` helper as the editor
panes, parameterised on `(sb_count + rows)` total / `rows` viewport.
Click on track outside the thumb jumps the thumb center to the click;
click on the thumb starts a drag (`sb_dragging` + `sb_drag_offset`).
Mouse-motion routes to `terminal_handle_sb_drag` whenever
`terminal_sb_dragging()` is true, even if the cursor wandered out of
the strip; `MOUSE_BUTTON_UP` clears the drag.

### Cursor render

- `g_terminal_active` true + `scroll_offset == 0`: blink at the
  editor's cadence (`int(blink_timer * 2) % 2 == 0`, 0.5 s on / off).
  `blink_timer` is bumped each frame in the main loop alongside
  `active_editor().blink_timer` and reset to 0 on every keystroke so
  the block stays solid while typing.
- Inactive + `scroll_offset == 0`: 60-alpha ghost. The
  `INACTIVE_DIM` overlay drawn afterwards tints it further; matches
  inactive editor panes.
- `scroll_offset > 0`: not drawn at all — the live grid isn't
  (fully) visible.

### Auto-close on shell exit

When the user types `exit` (or otherwise terminates the child shell),
`pty_read` returns -2 (EOF). The reader sets `Terminal.exited = true`,
pushes one final `TERMINAL_EVENT` (so the main loop wakes even if no
bytes were waiting), and breaks out of its loop. The main loop's USER
handler pumps any remaining bytes (so the shell's last output lands on
screen), then calls `terminal_close()` if `exited` is set. This
chains the `g_terminal_active = false` reset cleanly so subsequent
typing routes back to the editor.

### Focus model

- Click inside the terminal cell area → `g_terminal_active = true`.
- Click inside an editor pane → `g_terminal_active = false` and the
  hit pane becomes the active editor.
- Cmd+J / Ctrl+J: toggle visibility. Opening always grants focus;
  closing yields focus.
- `Cmd+S` / `Cmd+W` / `Cmd+O` / `Cmd+Z` / Ctrl+W chord etc. always
  reach the editor regardless of terminal focus — the Cmd/Ctrl
  branch in `handle_key_down` runs *before* the
  `if g_terminal_active` route-to-terminal branch.

## Edit features

- **Auto-close brackets** for `( [ { " '`. Closing brackets over-type when
  the next char is the same (so typing `}` inside `{|}` advances the caret
  rather than doubling). Quotes (`" '`) are skipped if the cursor is
  surrounded by word characters (so contractions like `don't` work).
- **Smart Enter**:
  - Plain: preserves the leading whitespace of the current line.
  - Between bracket pair (`{|}` etc.): inserts two newlines, indents the
    middle line by one tab stop (uses `\t` if the existing indent uses
    tabs, else `TAB_SIZE` spaces), drops the close to its own line at the
    original indent, and lands the caret on the indented middle line.
- **Soft tabs**: Tab key inserts spaces up to the next `TAB_SIZE`-aligned
  column. Hard tabs in loaded files render at the same tab-stop math.
- **Tab-stop-aware everything**: column math (`editor_pos_to_line_col`,
  `editor_advance_to_col`, `editor_max_line_cols`) all treat `\t` as
  advancing to the next tab stop.
- **Undo merging**: typed runs and backspace runs merge into a single
  group. Cursor movement commits. Selection-replace and paste are atomic
  groups.

## File handling

- **Drag-and-drop** a file onto the window opens it.
- **CLI arg** opens a file at startup.
- **Cmd+O / right-click → Open…** native file dialog.
- **Cmd+S / right-click → Save** writes to current path; falls through to
  Save As when there's no path yet.
- **Cmd+Shift+S / right-click → Save As…** native dialog, sets the new
  path, refreshes language detection, writes.
- **EOL handling**: load detects dominant style (LF / CRLF). Internal
  buffer is always LF. Save expands back to file's original style. Pure
  files round-trip byte-identical. Mixed-EOL files trigger a native
  warning dialog (`sdl.ShowSimpleMessageBox`) on load and the status bar
  shows `MIXED→LF` / `MIXED→CRLF` until saved.
- **Load path** reads directly into the gap buffer (`os.open` +
  `os.file_size` + `os.read_full`) rather than going through
  `os.read_entire_file` + memcpy. EOL detection and the
  `line_starts`/`line_widths` build are folded into the same pass over
  the freshly-loaded bytes. CRLF/mixed files compact in place.

## Buffer caches & mutation rules

Per-frame work that used to walk the entire buffer is replaced by
incrementally maintained caches on `Editor`. Anything that mutates
buffer bytes must keep them coherent.

- `gap_buffer.version: u64` — bumped by `gap_buffer_insert` /
  `gap_buffer_delete`. All caches key off this.
- `line_starts: [dynamic]int` + `line_widths: [dynamic]int` — parallel
  arrays; line `i` starts at `line_starts[i]` and is `line_widths[i]`
  columns wide (tabs expanded). Used by `editor_pos_to_line_col`
  (binary search, O(log n)), `editor_nth_line_start` (O(1)),
  `editor_total_lines` (O(1)), `editor_max_line_cols` (O(lines)).
- `cached_max_cols` / `cached_max_cols_ver` — cached scan over
  `line_widths`; recomputed when buffer changes.
- `search_match_positions` / `search_match_ver` /
  `search_match_pattern` — every match position for the active search
  pattern, keyed on (buffer.version, pattern).

**Mutation rule:** all "interactive" edit paths (typing, deletion,
paste, undo, redo) must call `editor_buffer_insert` or
`editor_buffer_delete` rather than `gap_buffer_insert` /
`gap_buffer_delete` directly. The wrappers do incremental
`line_starts`/`line_widths` updates (splice and shift on insert; remove
+ shift on delete), recompute the affected line's width, and bump the
cache version in lock-step with the buffer.

Bulk/replacement paths (`editor_set_text`, `editor_load_file`) bypass
the wrappers — they call `gap_buffer_insert` directly and rely on
`editor_clear` setting cache versions to `max(u64)` (a sentinel the
version counter can't reach), which forces a full rebuild on the next
read.

## Vim mode

Starts in **Normal** mode. Modes: `Insert`, `Normal`, `Visual`,
`Visual_Line`, `Command`, `Search`.

**Motions:** `h j k l`, `w b e`, `0 $ ^`, `gg G`, `<count>j`, `%`
(matching bracket).

**Operators:** `d c y` + motion or doubled (`dd yy cc`), counts compose
(`3dw` and `d3w` both delete 3 words). `D / C / Y` are `d$ / c$ / y$`.
`>>` / `<<` indent / outdent the current line; in Visual / Visual-Line
the operator works against the selection.

**Inserts:** `i a I A o O`. `x / X` delete char. `p / P` paste from system
clipboard. `.` repeats the last completed change (Insert run, op+motion,
`x`, `p`, etc.) — recorded by `dot.odin`.

**Visual:** `v` enters character-wise selection, `V` enters line-wise.
Motion keys extend the selection; `d` / `c` / `y` operate against it
and exit visual mode; `>` / `<` indent / outdent every line in the
selection. `Esc` exits without operating.

**Scrolling:** `Ctrl+D` / `Ctrl+U` half-page jumps. `zz` / `zt` / `zb`
center / top / bottom-align the cursor's line.

**Search:** `/<pattern>` forward, `?<pattern>` backward, `n` / `N`
next / previous (wrap-around). Pattern is literal (no regex). All
visible matches render with a faint highlight; the active match uses
`search_match_color` (magenta). Status bar shows `[k/total]` while the
cursor sits exactly on a match; disappears on any motion off the match.
Empty `/<Enter>` or `:noh` / `:nohlsearch` clears the pattern.
`\c` / `\C` in the pattern force case-insensitive / sensitive.

**Pane navigation & layout:**
- `Ctrl+W h` / `Ctrl+W ←` — focus left pane
- `Ctrl+W l` / `Ctrl+W →` — focus right pane
- `Ctrl+W c` / `Ctrl+W q` — close active pane (with unsaved-changes prompt)
- `Cmd+[` / `Cmd+]` — single-chord focus prev / next
- Click any pane to focus it; drag the boundary to resize.

**Command line (`:` in Normal):**
- `:w` save · `:q` quit (refuses if dirty, closes pane if not last)
  · `:q!` force · `:wq` / `:x` save+quit
- `:e <path>` open file (replaces blank pane, else opens a new column)
- `:r <path>` replace active pane with file (drops unsaved changes)
- `:42` jump to line 42
- `:syntax <name>` switch tokenizer (`none` / `generic` / `odin` /
  `c` / `cpp` / `go` / `jai` / `swift`)
- `:s/pat/repl/[gi I]` substitute on the current line · `:%s/...`
  whole buffer (`g` = all matches on the line, `i` = case-insensitive,
  `I` = case-sensitive)
- `:noh` / `:nohlsearch` clear active search pattern
- `:term` / `:terminal` open / focus the terminal · `:termclose` close it
- `:h` / `:help` open the help modal

## Conventions

- snake_case for procs and locals; `Title_Case` for types;
  `SCREAMING_SNAKE` for package constants.
- Public procs prefixed by their concept (`editor_*`, `vim_*`, `syntax_*`,
  `gap_buffer_*`, `menu_*`, `clipboard_*`).
- File-private helpers use `@(private="file")`.
- `[]u8` for byte ranges into the buffer; `string` only at API boundaries.
- All temp allocations go through `context.temp_allocator`; the main loop
  calls `free_all(context.temp_allocator)` once per iteration. The resize
  watch and dialog callbacks do the same.
- C-conv callbacks (`proc "c"`) set `context = runtime.default_context()`
  before calling Odin code.

## Known quirks / engine-level limitations

- **macOS live-resize jumpiness** still visible from right/bottom edges.
  The event watch redraws during the drag but macOS's compositor stretches
  the last presented frame momentarily. The proper fix is Cocoa interop
  (`setPreservesContentDuringLiveResize: NO` on the underlying NSView)
  using Odin's built-in Objective-C support
  (`core:sys/darwin/Foundation`, `intrinsics.objc_*`).
- **Color emoji** (U+1F600+) doesn't render — would need PlutoSVG glue in
  SDL3_ttf to surface bitmap glyph data, plus a fallback emoji font.
- **Multi-line raw strings** (`` `...` `` spanning lines) currently
  treated per-line in the Odin tokenizer.
- **No incremental syntax parse** — visible lines re-tokenize on every
  frame draw; the per-segment text cache makes it cheap. Very large files
  with deep block comments could feel it.
- **Untitled-buffer Save flow** — Cmd+W on a dirty untitled buffer prompts
  Save / Discard / Cancel; clicking Save fires the async Save As dialog
  but currently doesn't auto-close the pane after a successful save (user
  has to Cmd+W again). Cmd+Q does have this chained.
- **No glyph atlas** — `draw_text` creates one `^sdl.Texture` per unique
  `(segment, fg, bg, font_ptr)`. Works fine; if memory or upload bandwidth
  becomes a concern, swap to an atlas with quad rendering.
- **Terminal scrollback eviction is O(n)** at steady state —
  `ordered_remove(&scrollback, 0)` memmoves up to 4096 entries on every
  push once the ring is full. Fine in practice (it's one shift per line),
  but a true ring index would be cleaner if it ever shows up in profiles.
- **Combiners aren't rendered in the terminal** — `terminal_cell_at`
  draws `cell.chars[0]` only and skips the up-to-five additional
  combiner code points.

## Performance: future upgrade paths

The current load + edit pipeline is snappy up to ~100 MB. Beyond that
two structural changes are on the table; neither has been started.

- **mmap-backed open with copy-on-first-edit** — `mmap()` the file
  rather than `os.read_full`-ing it. Open becomes near-instant
  regardless of file size (OS lazy-loads pages). `line_starts` /
  `line_widths` get built against the mmap'd region. On first edit,
  copy the mmap'd bytes into a writable gap buffer and proceed as
  today. Cost of first edit ≈ memcpy speed (~20-30 ms warm for 100 MB,
  one frame). Mitigate cold-page worst case with a background thread
  that touches pages or `madvise(MADV_WILLNEED)` right after mapping.
  Platform-specific (`mmap` POSIX, `MapViewOfFile` Windows). ~100
  lines of code. The right next step *for load time*.
- **Piece table (or rope) backing store** — replaces the gap buffer
  with an immutable "original" buffer (ideally mmap'd) plus an append-
  only "added" buffer, with a list of pieces stitching them together.
  Insertions and deletions are O(piece-list-edit), independent of file
  size — no memmove on far cursor jumps. First edit is O(1) (just
  appends a new piece). Big rewrite touching every byte-access path
  (`gap_buffer_byte_at`, the direct gb.data scans in
  `ensure_line_starts` / `editor_max_line_cols`, the tokenizer feed,
  etc.). The right move *for sustained editing on gigabyte files*;
  overkill below that.

## Missing features (roadmap)

Grouped by how badly their absence is felt.

**Tier 1 — most felt:**
- **Windows terminal pane** — `pty.odin`'s Windows branch is stubbed.
  Needs `CreatePseudoConsole` + `CreateProcess` glue. Shell-side bytes
  go through libvterm exactly the same as Unix.
- **Mouse double-click / triple-click** — word and line selection in
  the editor.
- **Incremental search** — re-find on every keystroke into `cmd_buffer`,
  restore cursor on Esc.

**Tier 2 — nice-to-have:**
- **Comment toggle** (`gc` or `Ctrl+/`) — language-aware; needs per-
  `Language` line/block comment metadata.
- **More syntax tokenizers** — Python, Markdown, JSON, Zig, TS/JS.
  Generic mode is fine for most of them today, but real tokenizers
  unlock keyword / type / function-call coloring.
- **Wrap-selection-in-brackets** — typing `(` with a non-empty
  selection currently replaces the selection. Could wrap instead.
- **Smart unindent on Backspace** — Backspace at column N (multiple
  of `TAB_SIZE` with only whitespace before the caret) currently
  deletes one space rather than a full indent level.
- **Keyboard nav in the context menu** — Up / Down / Enter while the
  menu is open.
- **Disabled-state styling for menu items** — Copy / Cut / Paste etc.
  silently no-op when they don't apply; should grey out.

**Tier 3 — terminal polish:**
- **Terminal font override** — currently the Nerd Font is hard-wired;
  could surface a `[terminal] font_path` config field.
- **Terminal mouse support** — forward SDL mouse events through
  `vterm_mouse_*` so apps like `tmux`, `htop`, `vim` can use the mouse
  inside the pane.
- **Bell handling** — libvterm's `bell` callback fires; we currently
  ignore it. Could flash the divider or play a system sound.
- **Title / icon-name updates** — `VTermProp_TITLE` lands in
  `settermprop`; could surface in the status bar so users see what
  command is running.

## Useful tasks (vim mode quick reference)

```
:syntax odin           switch to Odin highlighting
:syntax generic        basic strings/numbers/comments highlighting
:syntax none           plain text
:e path/to/file        open file (replaces blank pane, else splits)
:r path/to/file        replace active pane with file
:w :q :wq :q! :x       save / quit / save+quit / force-quit / save+quit
:42                    jump to line 42
:s/pat/repl/[gi I]     substitute on the current line
:%s/pat/repl/[gi I]    substitute across the whole buffer
:noh :nohlsearch       clear active search pattern
:term :terminal        open / focus the terminal pane (Cmd/Ctrl+J toggles)
:termclose             close the terminal pane
:h :help               open help modal
```

```
/pattern               search forward (literal substring)
?pattern               search backward
n N                    next / previous match (wraps)
\c \C                  force case-insensitive / sensitive (in pattern)
/  then <Enter>        clear search pattern
```

```
i a I A o O            enter Insert mode (varying caret placement)
v V                    enter Visual / Visual-Line mode
Esc                    return to Normal mode (and dismiss menu)
h j k l                left / down / up / right
w b e                  word forward / back / to end
0 $ ^                  line start / end / first non-blank
gg G                   first line / last line
<n>G                   jump to line n
%                      jump to matching bracket
Ctrl+D Ctrl+U          half-page down / up
zz zt zb               center / top / bottom-align cursor line
dd yy cc               delete / yank / change current line
dw d$ y3w 3dw          operator + motion (counts compose)
D C Y                  d$ / c$ / y$
>> <<                  indent / outdent current line
x X                    delete char forward / backward
p P                    paste after / before
u                      undo  ·  Cmd/Ctrl+Shift+Z to redo
.                      repeat last change
```

```
Ctrl+W h | l           focus pane left | right
Ctrl+W ← | →           same as above
Ctrl+W c | q           close active pane
Cmd+[ | Cmd+]          focus prev | next pane (single-chord)
Cmd+J / Ctrl+J         toggle the bottom terminal pane
drag pane border       resize adjacent panes (cursor swaps to ↔)
drag terminal divider  resize the terminal strip   (cursor swaps to ↕)
wheel over terminal    scroll the terminal scrollback (4096-line ring)
click+drag term sb     drag the scrollbar thumb · click track to jump
```
