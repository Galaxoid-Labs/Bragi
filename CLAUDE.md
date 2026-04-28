# Bragi

A small GPU-accelerated text/code editor written in Odin. Cross-platform via
SDL3 + SDL3_ttf. Modal (vim) editing, hand-rolled syntax highlighting, LCD
subpixel text rendering, native file dialogs, native message boxes, custom
in-app context menu, **resizable side-by-side panes** for viewing /
editing multiple files at once, **modal help screen** (`:h` / `:help`),
fully theme-able chrome.

## Build & run

```
odin build .                        # produces ./Bragi
./Bragi                       # opens with welcome buffer (NORMAL mode)
./Bragi path/to/file          # opens that file at startup
```

Single binary, ~930 KB (includes the embedded font), statically linked
apart from system SDL3.

**Dependencies (per platform):**
- macOS: `brew install sdl3 sdl3_ttf`
- Linux: `libsdl3-dev` and `libsdl3-ttf-dev` (debian/ubuntu) or
  `SDL3-devel SDL3_ttf-devel` (fedora). SDL3_ttf bundles FreeType + HarfBuzz
  + PlutoSVG so font rendering is identical to macOS.
- Windows: ship `SDL3.dll` and `SDL3_ttf.dll` next to the binary.

`FiraCode-Regular.ttf` is **embedded into the binary** at compile time
via `#load` (see `FIRA_CODE_DATA` in `main.odin`) and loaded through
`SDL_IOFromConstMem` + `TTF_OpenFontIO`. There is no runtime font-file
dependency. Users can override via `font.path` in their config; if the
override fails to load, the editor logs a warning and falls back to the
embedded font.

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
  Page Up-Down / `g` `G`. Section headers and command keys are coloured;
  body text uses default. Esc or click-outside dismisses; while open it
  swallows all input so editor buffers stay untouched.
- **`config.odin`** — INI loader. `Config { font, editor, theme }`,
  per-platform user config path (XDG / `Application Support` / APPDATA),
  `#RRGGBB` / `#RRGGBBAA` colour parser. `[theme]` section supports
  every chrome colour as well as syntax tokens.

## Important globals (in main.odin)

- `g_renderer`, `g_window`, `g_font` — SDL3 / TTF handles
- `g_density` — `GetWindowPixelDensity` result; the font is opened at
  `FONT_SIZE * g_density` so glyphs rasterize at full physical resolution
- `g_char_width`, `g_line_height` — precomputed monospace metrics in logical
  pixels
- `g_text_cache` — hash-keyed cache of `(text, fg, bg) → ^sdl.Texture`. Cap
  at `TEXT_CACHE_MAX = 1024`; on overflow the whole cache is dropped (cheap
  to rebuild on the next few frames)
- `g_theme` — `Theme` struct holding *every* drawable colour in the app
  (syntax tokens + chrome). Loaded from the user's `[theme]` section in
  `config.ini`; falls back to `DEFAULT_THEME`.
- **Panes:**
  - `g_editors: [dynamic]Editor` — one per visible column.
  - `g_active_idx` — focused pane; receives keyboard input.
  - `g_pane_ratios: [dynamic]f32` — per-pane width as a fraction of the
    window (sums to 1). Scales with window resize. Adjusted when the user
    drags a divider.
  - `g_drag_idx` — pane that an in-flight mouse drag started in (-1 when
    idle); routes motion / button-up back there even if the cursor wandered.
  - `g_resize_divider` — index of the right-side pane whose left edge is
    being dragged (-1 = no resize in progress).
  - `g_cursor_default` / `g_cursor_resize` — system cursors swapped on
    divider hover.
- **Vim window-prefix:**
  - `g_pending_ctrl_w` — set after Ctrl+W; the next key is interpreted as a
    window command (`h` / `l` / `c` / `q` / Esc).
  - `g_swallow_text_input` — true for one event after a prefix follow-up so
    the rune SDL queues for the same physical keypress doesn't get inserted.
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
   area, scrollbar tracks) plus the global status bar. Pane widths come
   from `g_pane_ratios * screen_w`.
2. BG clear → for each pane in order: `draw_editor(pane, is_active)` →
   `draw_gutter(pane)` → `draw_scrollbars(pane)`.
3. **Inactive-pane dim overlay**: a `~20%` black rect is filled over each
   non-active pane's column so the focused pane reads as the focused
   one. Drawn *before* the divider lines so the dividers stay crisp.
4. **Pane separators**: a 1-physical-pixel vertical line is drawn at
   each non-leftmost pane's left edge in `gutter_bg_color`.
5. `draw_status_bar(active_editor, l)` — two-row strip:
   - Top row (`status_path_bg_color`): one segment per pane showing its
     full file path; active pane's path is bright (`status_text_color`),
     others dim (`status_dim_color`). Each segment is clipped to its
     own column so a long path doesn't bleed into the neighbour.
   - Bottom row (`status_bg_color`): mode label + EOL + `[k/m]` search
     count + cursor `line:col` for the active pane only. In Command /
     Search modes the bottom row hosts the `:` / `/` prompt instead.
6. `draw_menu()` then `draw_help(l)` — context menu draws on top of the
   editor; the help modal draws on top of everything else (with a
   dimming layer behind it).
7. `RenderPresent`.

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
  even if the mouse wandered into a neighbour before release.
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
- Whichever follow-up fires also sets `g_swallow_text_input` so the
  rune SDL queues for the same physical keypress doesn't get inserted
  into the new active buffer. (Set/cleared every time, so an Esc
  cancel doesn't swallow the next unrelated text input.)

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
  centre to the click position and continues as a drag.
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

Starts in **Normal** mode. Modes: `Insert`, `Normal`, `Command`,
`Search`.

**Motions:** `h j k l`, `w b e`, `0 $ ^`, `gg G`, `<count>j` etc.

**Operators:** `d c y` + motion or doubled (`dd yy cc`), counts compose
(`3dw` and `d3w` both delete 3 words). `D / C / Y` are `d$ / c$ / y$`.

**Inserts:** `i a I A o O`. `x / X` delete char. `p / P` paste from system
clipboard.

**Search:** `/<pattern>` forward, `?<pattern>` backward, `n` / `N`
next / previous (wrap-around). Pattern is literal (no regex). Status
bar shows `[k/total]` while the cursor sits exactly on a match;
disappears on any motion off the match. Empty `/<Enter>` or `:noh` /
`:nohlsearch` clears the pattern. Active match is drawn in
`search_match_color` (magenta) instead of the regular selection color.

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
- `:syntax <name>` switch tokenizer (`none` / `generic` / `odin`)
- `:noh` / `:nohlsearch` clear active search pattern
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

## Known quirks / open work

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
  `(segment, fg, bg)`. Works fine; if memory or upload bandwidth becomes a
  concern, swap to an atlas with quad rendering.
- **Wrap-selection-in-brackets** — typing `(` with a selection currently
  replaces selection. Could wrap instead.
- **Smart unindent on Backspace** — Backspace at column N (where N is a
  multiple of `TAB_SIZE` and only whitespace precedes) currently deletes
  one space, not a whole indent level.
- **No keyboard nav in context menu** (Up/Down/Enter while menu is open).
- **No disabled-state styling** for menu items that don't apply (e.g.
  Copy with no selection silently no-ops).

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

**Tier 1 — felt immediately by any vim user:**
- **Visual mode (`v`, `V`)** — character / line selection. Selection
  rendering already exists; needs a new `Mode` value and `d`/`c`/`y`
  routed against the selection instead of a motion.
- **Search highlighting** — light up *all* matches in the viewport, not
  just the current. Reuses the selection-rect alpha-blending; iterate
  matches in the visible byte range during `draw_editor`.
- **`.` (repeat last edit)** — record the last completed Insert session
  or operator+motion as a replayable thunk.

**Tier 2 — quality-of-life, mostly small:**
- **Page scrolling** (`Ctrl+D` / `Ctrl+U`) — half-page jumps.
- **`zz` / `zt` / `zb`** — center / top / bottom cursor on screen.
- **`%`** — jump to matching bracket; small stack scan.
- **`>>` / `<<`** — indent / outdent line, plus visual-mode forms.
- **Incremental search** — re-find on every keystroke into `cmd_buffer`,
  restore cursor on Esc.
- **Mouse double-click / triple-click** — word and line selection.

**Tier 3 — bigger but still bounded:**
- **`:s/foo/bar/g`** — substitute, builds on existing search.
- **Comment toggle** (`gc` or `Ctrl+/`) — language-aware; needs per-
  `Language` line/block comment metadata.

## Useful tasks (vim mode quick reference)

```
:syntax odin           switch to Odin highlighting
:syntax generic        basic strings/numbers/comments highlighting
:syntax none           plain text
:e path/to/file        open file (replaces blank pane, else splits)
:r path/to/file        replace active pane with file
:w :q :wq :q! :x       save / quit / save+quit / force-quit / save+quit
:42                    jump to line 42
:noh :nohlsearch       clear active search pattern
:h :help               open help modal
```

```
/pattern               search forward (literal substring)
?pattern               search backward
n N                    next / previous match (wraps)
/  then <Enter>        clear search pattern
```

```
i a I A o O            enter Insert mode (varying caret placement)
Esc                    return to Normal mode (and dismiss menu)
h j k l                left / down / up / right
w b e                  word forward / back / to end
0 $ ^                  line start / end / first non-blank
gg G                   first line / last line
<n>G                   jump to line n
dd yy cc               delete / yank / change current line
dw d$ y3w 3dw          operator + motion (counts compose)
D C Y                  d$ / c$ / y$
x X                    delete char forward / backward
p P                    paste after / before
u                      undo
```

```
Ctrl+W h | l           focus pane left | right
Ctrl+W ← | →           same as above
Ctrl+W c | q           close active pane
Cmd+[ | Cmd+]          focus prev | next pane (single-chord)
drag pane border       resize adjacent panes (cursor swaps to ↔)
```
