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
packages on Linux). On Windows, ship `SDL3.dll`, `SDL3_ttf.dll`, and
`vterm.dll` next to the produced `Bragi.exe`. The Windows libvterm
build is vendored under `vendor/libvterm/` (built from neovim's
libvterm fork — vcpkg has no port for it). Re-run
`vendor/libvterm/build.ps1` to refresh the binaries; that script
clones the upstream repo into `vendor/libvterm/_src/`, drops in a
small CMakeLists.txt, builds with MSVC, and copies the resulting
`vterm.dll` / `vterm.lib` / headers back into `vendor/libvterm/`.

The fff file-search library (powers the finder) is vendored under
`vendor/fff/` as prebuilt per-arch `c-lib-*` binaries — it has no
Homebrew/distro/vcpkg port. Unlike the deps above it's bundled into the
release on every platform (macOS Frameworks/, Linux `/usr/lib/bragi/`,
next to `Bragi.exe`). macOS dylibs need an `install_name` rewrite to
`@loader_path/...`; Windows needs an import lib generated from the DLL.
Both are documented in `vendor/fff/README.md`. Only the macOS path is
verified end-to-end so far.

Two TTFs are embedded via `#load`:
- `FiraCode-Regular.ttf` → editor pane (`g_font`)
- `FiraCodeNerdFont-Regular.ttf` → terminal pane (`g_terminal_font`)

Both have identical advance width so cell math is unchanged.

## File map

- **`main.odin`** — SDL init, main loop, layout, input dispatch, theme,
  text cache, native dialogs, pane lifecycle, draw orchestration.
- **`editor.odin`** — `Editor` struct, cursor / selection, edit
  primitives, auto-close brackets, smart Enter, soft tabs.
- **`piece_buffer.odin`** — Piece-list backing store for `Editor.buffer`.
  Immutable `original` (file load) + append-only `added` + ordered
  list of pieces; far cursor jumps are O(piece-list-edit) instead of
  O(distance). Sequential-access cache makes consecutive `byte_at`
  calls O(1) amortized; coalesces on typing runs. Same `version: u64`
  contract as before for cache keys. `original` is either heap-
  allocated or an mmap'd region; `_destroy` dispatches on
  `original_mmap`.
- **`mmap_posix.odin`** / **`mmap_other.odin`** — POSIX mmap loader
  used by `editor_load_file`. `MAP_PRIVATE | PROT_READ | PROT_WRITE`
  so CRLF compaction can run in place via copy-on-write without
  modifying the file. Pure-LF files (the common case) touch nothing
  and stay lazy-paged. Windows / other platforms get a stub that
  returns `ok=false` so the load path falls back to read-into-buffer.
- **`undo.odin`** — Edit-log undo/redo with adjacent-op merging.
- **`file.odin`** — Load (direct-into-gap-buffer + EOL detect) / save
  (atomic, EOL expand) / `path_basename` / `digit_count`.
  **Saves MUST be atomic on POSIX** (`write_file_atomic`: write a sibling
  `.bragi-tmp` + `rename` over the target), NOT an in-place
  `write_entire_file`. The buffer keeps reading its `MAP_PRIVATE` mmap of
  the loaded file for the file's lifetime; truncating+rewriting that same
  inode in place makes any piece pointing past the new EOF read back as
  zeros on Linux (macOS' VM happens to keep the old resident pages, so it
  never reproduced there — symptom was "Ctrl+S adds an empty line each
  save"). Rename leaves the original inode unlinked-but-alive behind the
  mapping, so pages stay valid; it also follows symlinks (preserves the
  link via `stat().fullpath`) and keeps the target's mode. Windows uses the
  read-into-buffer load path (no mmap), so it keeps the in-place write.
  Regression test: `save_test.odin`.
- **`vim.odin`** — `Mode` enum, vim parser FSM, motions / operators /
  ex commands. Modes: `Insert`, `Normal`, `Visual`, `Visual_Line`,
  `Command`, `Search`.
- **`syntax.odin`** — Per-language tokenizers (Odin / C / C++ / Go /
  Jai / Swift / Rust / GDScript / Bash / INI / Generic / None). Most go through
  `tokenize_with_spec`; INI has its own dedicated tokenizer because
  sections / keys / values don't fit the C-family `Language_Spec`.
- **`menu.odin`** — Right-click context menu.
- **`help.odin`** — `:h` / `:help` modal cheat-sheet.
- **`finder.odin`** — Cmd/Ctrl+F project-wide fuzzy file picker, backed
  by fff. Flat recursive search (relative paths), NOT a directory
  browser. Picks an index root from the active file — git root (walk up
  to nearest `.git`), else the file's dir, else cwd when no file is
  open (workspace root wins over all of this when set). `is_indexable_root`
  refuses `$HOME` / `/` (fff itself errors on home unless
  `enable_home_dir_scanning`). **ALL fff calls run on a background worker
  thread** (`fff_worker`) — both `fff_create_instance_with` (whose scan
  freezes the UI on a big repo) AND every `fff_search` (which blocks while
  the index is still scanning). The main thread never calls fff: it posts
  a query into `g_fff_req_*` and signals `g_fff_sem`; the worker searches
  and publishes `g_fff_results` + status under `g_fff_mutex`, then pushes
  `FFF_EVENT`. The main loop's `FFF_EVENT` handler (`finder_on_fff_event`)
  copies results into `g_finder_results` and renders. The worker re-runs
  the search on a ~120 ms timeout while `fff_is_scanning`, so results
  stream in live and the "indexing… N files" status updates — without ever
  blocking input. A root change / shutdown tears the worker down
  (`fff_teardown`: set quit, signal sem, `WaitThread`; the worker frees the
  instance + results on exit).
- **`fff.odin`** — Foreign bindings for the fff C library
  (`vendor/fff/fff.h`). Subset: instance lifecycle, `fff_search` +
  result accessors, frees. Links the vendored per-arch
  `libfff_c-*-{darwin,linux}.{dylib,so}` on macOS/Linux and
  `vendor/fff/fff_c.lib` on Windows. See `vendor/fff/README.md` for the
  install_name / import-lib fixups.
- **`fff_test.odin`** — `@(test)` smoke test for the bindings: indexes
  the repo, searches, reads results back. Run from repo root so the
  dylib's `@loader_path` id resolves: `odin test . -out:./bragi_test`.
- **`workspace.odin`** — the single workspace root (`g_workspace_root`).
  `set_workspace` validates + resolves to absolute, re-points the finder
  index, and refreshes the sidebar. Set via Open Folder dialog
  (Cmd/Ctrl+Shift+O), `bragi <dir>`, `:cd`/`:workspace`/`:ws`, or
  dropping a folder.
- **`sidebar.odin`** — left file-tree sidebar (NERDTree-style explorer
  of the workspace). Toggle Cmd/Ctrl+E. Flattened-list tree model
  (`g_sidebar_entries`) rebuilt from `g_workspace_root` + an expanded-dir
  path set (`g_sidebar_expanded`); only expanded dirs are `read_dir`'d
  (lazy). Dotfiles hidden, toggle with `i`. Styled like the finder
  (MENU_* colors, blue dirs, UI font — does NOT scale with editor zoom).
  Mouse (click dir=expand, file=open) + keyboard (j/k/h/l, Enter, Esc)
  when focused.
- **`lsp.odin`** — Language Server Protocol client. **jai-lsp only for
  now** (ols/.odin later). One server process per language, spawned
  lazily when a `.jai` file opens in a workspace. JSON-RPC over the
  child's stdio (`Content-Length` framing); a reader thread parses
  frames and pushes `LSP_EVENT`; `lsp_pump` (main thread) dispatches
  responses (by id→method in `pending`) and notifications. Handshake
  negotiates **utf-8**, so LSP `character` == byte count from line start
  → position converters (`lsp_byte_to_pos`/`lsp_pos_to_byte`) are plain
  byte math (utf-16 variant lands with ols). Document sync: didOpen on
  load, debounced full-text didChange (`lsp_note_edit` timestamps edits,
  `lsp_tick` flushes after 250 ms), didSave, didClose. Diagnostics store
  (`g_lsp_diagnostics`, path→diags) from publishDiagnostics, rendered as
  underlines (`draw_lsp_diagnostics`) + status-bar message on the cursor
  line. **Formatting**: `textDocument/formatting` (`lsp_format_request`),
  capability-gated on `documentFormattingProvider` (`c.can_format`);
  ols only advertises it when sent `initializationOptions.enable_format`
  (done for `.Odin`). `lsp_apply_text_edits` resolves all `TextEdit`
  ranges to byte offsets first, applies highest-offset-first as one undo
  (`commit_pending` brackets). `format_on_save` (any LSP lang) defers the
  write to the format response via `lsp_save_with_format` — scoped to
  interactive saves (`:w` / Cmd+S), with a `lsp_tick` watchdog
  (`LSP_FORMAT_SAVE_TIMEOUT_NS`) so a wedged server can't eat the save.
  Triggers: Cmd/Ctrl+Shift+F, `:fmt`, right-click → Format Document.
  Servers/paths resolve from `[lsp]` config → next-to-exe → PATH.
  For Odin, `lsp_client_start` also exports `OLS_BUILTIN_FOLDER` so ols
  can resolve Odin's `builtin`/`intrinsics` packages (len/make/append,
  `core:`/`base:`) for completion/hover/def — probing `<ols-dir>/builtin`
  (dev: `vendor/odin-lsp/builtin`; macOS `.app`; Windows beside `ols.exe`)
  then `<ols-dir>/../lib/bragi/builtin` (packaged Linux libdir). Skipped if
  ols came off PATH (no dir to anchor on); the packaging scripts ship the
  folder beside/near the binary on every platform.
  Teardown mirrors `fff_teardown` (quit flag, close stdin to EOF the
  reader, `WaitThread`, reap).
- **`lsp_posix.odin`** / **`lsp_windows.odin`** — process spawn with
  PLAIN stdio pipes (not a PTY): POSIX `pipe`+`fork`+`dup2`+`execvp`
  (reuses pty.odin's libc bindings); Windows `CreatePipe` +
  `CreateProcessW` with `STARTF_USESTDHANDLES` (child stderr → `NUL` so
  server logs never corrupt the JSON-RPC stdout frames; `CREATE_NO_WINDOW`
  so the GUI app never flashes a console). `LSP_Pipes`' `int` fields hold
  Win32 HANDLEs (process handle in `pid`); env deltas go through
  `SetEnvironmentVariableW` + inherited env rather than a hand-built block.
- **`completion.odin`** — the autocompletion popup (intellisense).
  Insert-mode only; requests `textDocument/completion` once at the word
  start (`completion_trigger`), narrows locally as you type
  (`completion_refilter`), Tab/Enter accept (`editor_replace_range`,
  single undo), Esc dismiss, Up/Down move, Ctrl+Space manual. Anchored
  at the caret, finder-styled. Go-to-definition (`gd`, Normal mode) lives
  in `lsp.odin` (`lsp_definition_request`/`lsp_jump_to`).
- **`dot.odin`** — `.` (repeat last edit) recorder.
- **`config.odin`** — INI loader, theme + editor settings.
- **`vterm.odin`** — Foreign bindings for libvterm 0.3.x. Links
  `system:vterm` on macOS / Linux and `vendor/libvterm/vterm.lib` on
  Windows.
- **`pty.odin`** — Platform-neutral PTY interface. `forkpty` wrapper on
  Unix; dispatches to the Windows helpers in `pty_windows.odin`.
- **`pty_windows.odin`** — `#+build windows`. ConPTY (`CreatePseudoConsole`,
  Win10 1809+) implementation: anonymous pipes + `STARTUPINFOEXW` +
  `PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE` to bind child stdio. Lives in
  its own file because `core:sys/windows` only compiles on Windows
  builds and Odin disallows `import` inside a `when` block.
- **`terminal.odin`** — Embedded terminal pane: vterm + PTY + reader
  thread + scrollback ring + scrollbar.
- **`titlebar_{darwin,windows,other}.odin`** — Per-platform window
  chrome. Darwin: transparent titlebar via Cocoa interop, reserves
  `TITLEBAR_H = 28`. Windows: Mica/Acrylic via `DwmSetWindowAttribute`,
  keeps the system bar, `TITLEBAR_H = 0`. Other: stub.

## Conventions

- `snake_case` procs/locals, `Title_Case` types, `SCREAMING_SNAKE`
  package constants.
- Public procs prefixed by concept: `editor_*`, `vim_*`, `syntax_*`,
  `piece_buffer_*`, `terminal_*`, `menu_*`, `clipboard_*`, etc.
- File-private helpers use `@(private="file")`.
- `[]u8` for byte ranges into the buffer; `string` only at API
  boundaries.
- All temp allocations through `context.temp_allocator`; main loop
  calls `free_all(context.temp_allocator)` once per iteration.
- C-conv callbacks (`proc "c"`) must set
  `context = runtime.default_context()` before calling Odin code.
- Platform-specific code: `_<platform>.odin` filename (auto-gated)
  or `#+build` at file top. Keep the *symbol set* identical across
  platforms (no-op stubs where needed) so call sites stay neutral.

## Buffer caches & mutation rules (load-bearing invariant)

`Editor` carries incrementally-maintained caches keyed off
`piece_buffer.version`:

- `line_starts: [dynamic]int` + `line_widths: [dynamic]int` — parallel
  arrays. `editor_pos_to_line_col` (binary search), `editor_nth_line_start`,
  `editor_total_lines`, `editor_max_line_cols` all read from these.
- `cached_max_cols` / `cached_max_cols_ver` — scan over `line_widths`,
  recomputed on version mismatch.
- `search_match_positions` / `search_match_ver` / `search_match_pattern`
  — keyed on `(buffer.version, pattern)`.

**Mutation rule**: interactive edit paths (typing, deletion, paste,
undo, redo) MUST call `editor_buffer_insert` / `editor_buffer_delete`,
not `piece_buffer_insert` / `piece_buffer_delete` directly. The wrappers
do incremental `line_starts` / `line_widths` updates and bump the
cache version in lock-step.

**Direct-slice scans** (`ensure_line_starts` and similar fast-path
walkers that need to avoid the per-byte branch through `byte_at`)
must iterate `piece_buffer_pieces(gb)` and read each piece's bytes
via `piece_buffer_source(gb, piece)`. The piece-list contract gives
no contiguous-buffer view — anything assuming "left half / right
half" of a gap buffer is gone.

Bulk paths (`editor_set_text`, `editor_load_file`) bypass the wrappers
and rely on `editor_clear` setting cache versions to `max(u64)` —
sentinel that forces full rebuild on next read.

## Important globals

- `g_font`, `g_editor_font`, `g_terminal_font` — three TTF handles, all
  opened at `size * g_density`. `g_font` (config `[font]`) draws the UI
  chrome: status bar, finder, help, menus. `g_editor_font` (config
  `[editor_font]`, inherits `[font]`) draws the editor document + gutter
  and is the only one the user can **zoom** at runtime — Cmd `=`/`-`/`0`
  → `editor_font_zoom` / `editor_font_reset` → `editor_font_reopen`,
  which reopens it at `g_editor_font_size`, recomputes the editor
  metrics, and drops the text cache. `g_terminal_font` is the Nerd Font.
- `g_renderer`, `g_window` — SDL3 handles.
- `g_density` — `GetWindowPixelDensity` result.
- `g_char_width`, `g_line_height` — **editor-font** monospace metrics
  (logical px); they track `g_editor_font` and so change on zoom. Read
  by editor draw/layout (main.odin) and vim half-page motions.
  `measure_char_width` reads the font's advance via
  `TTF_GetGlyphMetrics`, NOT the rendered bounding box — at small
  sizes the box rounds to integer pixels and the cursor visibly
  drifts off the chars.
- `g_term_char_width`, `g_term_line_height` — terminal cell metrics,
  from `g_terminal_font` at the fixed UI size (`recompute_terminal_metrics`).
  Kept separate from the editor metrics so editor zoom never resizes the
  terminal grid (which would SIGWINCH the shell).
- `TITLEBAR_H` — top-of-editor reservation for traffic lights
  (28 on macOS, 0 elsewhere). Defined in `titlebar_*.odin`.
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
- **Sidebar**: `g_sidebar_visible`, `g_sidebar_active` (keyboard focus),
  `g_sidebar_width` (logical px), `g_sidebar_resizing` — the terminal
  pattern rotated to a left strip. Plus `g_workspace_root`.
- **Vim window-prefix**: `g_pending_ctrl_w` (set after Ctrl+W),
  `g_swallow_text_input` (one-batch guard — see below).
- **Modals**: `g_help_visible`, `g_help_scroll`; `g_finder_visible`.
- **Dialogs**: `g_pending_open` / `_open_folder` / `_save_as` /
  `_quit_after_save` / `_raise` — flags that defer `sdl.Show*Dialog`
  and post-save actions to the next loop iteration.

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
- Sidebar visible: a left strip (`g_sidebar_width` logical px + 4-px
  divider) is carved from the editor zone only — `compute_layout` shifts
  the panes to start at its right edge; the status bar and terminal stay
  full-width below it. `sidebar_rect` spans `TITLEBAR_H..editor_bottom`.
  Pane ratios then span the *editor region* (right of the sidebar), so
  `move_divider` is fed editor-relative x + width, not screen-absolute.
- macOS reserves `TITLEBAR_H` at every pane's `text_y`; `draw_titlebar`
  paints a strip across `[0, TITLEBAR_H]` with the active filename
  centered. `TITLEBAR_H = 0` elsewhere makes the math identical to the
  pre-titlebar layout.

## Input dispatch — non-obvious bits

- `WaitEventTimeout(250 ms)` keeps idle CPU near zero. VSync is on;
  it was off historically due to SDL2-era macOS live-resize lag,
  but SDL3 + modern Cocoa handle that cleanly and tearing during
  window moves was the bigger problem without it.
- Cmd OR Ctrl (`KMOD_GUI | KMOD_CTRL`) trigger shortcuts so bindings
  work cross-platform.
- `resize_event_watch` (registered via `AddEventWatch`) fires
  *synchronously* during live-resize, forcing redraws while the OS
  otherwise blocks the main thread — but **only macOS and Windows block
  it** (Cocoa / the Win32 modal resize loop). The redraw is gated on
  `WATCH_REDRAWS_ON_RESIZE :: ODIN_OS != .Linux`. On Linux (X11/Wayland)
  the main thread keeps running during resize, so the normal render loop
  already redraws; calling `draw_frame()` in the watch there is not just
  redundant — each resize step fires 2–3 window events and every
  `draw_frame` ends in a VSync-blocked `RenderPresent`, so doing it
  synchronously inside the event pump stalls event delivery and the window
  lags seconds behind the cursor. The watch still runs the cheap
  `refresh_pixel_density()` on Linux (density-gated, for DPI changes).
- Mouse routing: button-down sets `g_active_idx` and `g_drag_idx`;
  button-up routes back to `g_drag_idx` (so the originating pane's
  drag state clears even if the cursor wandered). Wheel routes to
  the pane *under the cursor*.
- **Pane-index clamps must use `len(l.panes)`**, NOT `len(g_editors)`.
  Native-dialog callbacks (Cmd+O) can grow `g_editors` synchronously
  from inside SDL's event pump, so the layout `l` we computed at the
  top of the iteration is briefly stale until the next iteration.
- Ctrl+W is platform-split (the `case sdl.K_W` in the Cmd/Ctrl block).
  On **macOS** it's the vim window-prefix: sets `g_pending_ctrl_w`; the
  next key is the action (`h` / `l` / `c` / `q` / Esc). Cmd+W is the
  pane close there (via `WINDOW_CLOSE_REQUESTED`). On **Linux / Windows**
  there's no Cmd key, so Ctrl+W closes the active pane directly
  (`try_close_active_pane`) — except when the terminal pane has focus,
  where it's forwarded as the shell's delete-word. Pane focus on those
  platforms is `Ctrl+[` / `Ctrl+]`. The `MOD` constant (main.odin,
  `"Cmd"`/`"Ctrl"` by `ODIN_OS`) feeds the help/welcome text so chrome
  never advertises a key the current OS doesn't use.
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
- The shell spawns at the real final grid size from byte zero
  (`terminal_target_grid_from_window`). Spawning at 24×80 then
  SIGWINCH-ing on the next frame breaks zsh's cursor tracking
  (p10k / starship get permanently confused).
- `pty_spawn` does `chdir($HOME)` and sets `LANG` / `LC_CTYPE` /
  `TERM` / `COLORTERM` in the child if missing. GUI launches
  inherit a stripped env; without this, shells fall back to "C"
  locale, `wcwidth()` returns -1 for powerline glyphs, and the
  prompt corrupts on every redraw.
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
`draw_titlebar` (covers anything that bled into `[0, TITLEBAR_H]`)
→ `draw_status_bar` → menu → help → finder → present. Order matters
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
- **Shell-friendly CLI invocation** (`bragi .`) — directory arg
  should drop you into the finder rooted there; macOS needs a PATH
  shim too.

## Performance: future upgrade paths

Far cursor jumps no longer pay an O(distance) cost (piece table
shipped). File opens are kernel-lazy on POSIX (mmap-backed open
shipped). The remaining structural lever, in order of when it'd
actually matter:

- **Piece *tree* (RB-balanced) instead of piece *list*** — only
  matters if real workflows hit thousands+ of pieces. Today's flat
  list does linear scan in `find_piece` (with cache + sequential
  fast paths covering the common case). At dozens of pieces that's
  invisible; at tens of thousands a 100 MB scattered search-and-
  replace would start to drag. Same proc surface
  (`piece_buffer_*`); the RB tree replaces the `[dynamic]Piece`
  field internally. ~600+ lines of well-tested tree code — overkill
  unless we actually see the bottleneck in profiles.
