package bragi

import "base:runtime"
import "core:c"
import "core:os"
import "core:strings"
import sdl "vendor:sdl3"

// Embedded terminal pane. One Terminal owns:
//   - a libvterm VT state machine (parser + cell grid)
//   - a PTY with a child shell on the slave end
//   - a reader thread that pumps PTY → SDL custom event → main loop
//
// The engine surface (`vterm_*` calls) is contained in this file plus
// vterm.odin, so swapping libvterm out for libghostty-vt later is a
// localised change.

// Hard cap on retained scrollback lines. Older lines are evicted FIFO once
// the buffer fills. 4096 lines × ~80 cols × 24 bytes/cell ≈ 7.5 MiB worst
// case, which is fine for an embedded terminal — bump it later if needed.
TERMINAL_SCROLLBACK_MAX :: 4096

// One line that scrolled off the top of the live grid. Cells are copied
// out of libvterm's internal storage at push time so the slice we keep is
// independent of subsequent vterm activity.
Scrollback_Line :: struct {
	cells: []VTermScreenCell,
}

Terminal :: struct {
	vt:     ^VTerm,
	screen: ^VTermScreen,
	state:  ^VTermState, // for cursor-position queries
	pty:    PTY,

	rows: int,
	cols: int,

	// Off-thread state. The reader thread writes incoming PTY bytes into
	// `pending_input` and pushes a wake-up SDL event; the main loop
	// drains it under `input_mutex` and feeds it to vterm_input_write.
	pending_input: [dynamic]u8,
	input_mutex:   ^sdl.Mutex,
	reader_thread: ^sdl.Thread,
	reader_quit:   bool, // set on shutdown to break the reader loop

	// Scrollback ring (FIFO, capped at TERMINAL_SCROLLBACK_MAX). Filled
	// from libvterm via the sb_pushline screen callback. `scroll_offset`
	// is how many lines above "live" the user has scrolled — 0 means
	// the bottom of the visible window is the bottom of the live grid;
	// N>0 means the visible window is shifted up by N lines (scrollback
	// peeks into view at the top, live screen drops off the bottom).
	scrollback:    [dynamic]Scrollback_Line,
	scroll_offset: int,

	// Storage for the libvterm screen-callbacks table. libvterm holds a
	// pointer to it across calls, so it has to outlive the call site —
	// keeping it inline in the heap-allocated Terminal does the trick.
	callbacks: VTermScreenCallbacks,

	// Scrollbar drag state. While `sb_dragging` is true, mouse-motion
	// y deltas translate into scroll_offset changes; `sb_drag_offset`
	// is the y inside the thumb where the user grabbed it (so the
	// thumb doesn't snap-jump when the drag starts).
	sb_dragging:    bool,
	sb_drag_offset: f32,

	// The main thread sets this whenever vterm advances; the renderer
	// reads it to decide whether the next draw needs to recompute the
	// per-cell texture cache.
	dirty: bool,

	// Cursor blink phase, in seconds. Wraps at 1 s; the renderer flips
	// visibility every 0.5 s so the cadence matches the editor caret.
	// Reset on every keystroke so the block doesn't blink off mid-type.
	blink_timer: f32,

	// True while a TUI app (vim / htop / less / …) has switched into the
	// alternate screen via DECSET 1049. Tracked so screen-erase sequences
	// emitted by those apps don't mistakenly wipe our scrollback ring;
	// only `clear`-style erases on the main screen do.
	on_alt_screen: bool,

	// Cleared once the child exits / EOF hits the master fd. Pane stays
	// alive until the user closes it so they can read the final output.
	exited: bool,
}

// Toggled by `:term` etc. When false, the bottom strip collapses entirely
// and the editor pane(s) own the full content area. `_active` tracks
// keyboard focus — when the terminal owns focus, all keys route to the
// libvterm-side keyboard encoder instead of the active editor pane.
g_terminal:               ^Terminal
g_terminal_visible:       bool
g_terminal_active:        bool // keyboard focus is on the terminal
g_terminal_height_ratio:  f32 = 0.30 // fraction of screen_h for the terminal strip
g_terminal_resizing:      bool // mid-drag of the horizontal divider

// Recompute the cell grid size from the terminal's rect (in logical pixels)
// and tell libvterm + the PTY about it. Idempotent.
terminal_fit_to_rect :: proc(rect: sdl.FRect) {
	if g_terminal == nil do return
	text, _ := terminal_split_rect(rect)
	rows := max(1, int(text.h / g_line_height))
	cols := max(1, int(text.w / g_char_width))
	terminal_resize(rows, cols)
}

// Toggle the terminal pane. Opens it (sized to the eventual rect) the
// first time; subsequent toggles flip visibility without killing the
// child shell.
terminal_toggle :: proc(rows, cols: int) -> bool {
	if g_terminal == nil {
		if !terminal_open(rows, cols) do return false
		g_terminal_active = true
		return true
	}
	g_terminal_visible = !g_terminal_visible
	if g_terminal_visible do g_terminal_active = true
	else                  do g_terminal_active = false
	return true
}

// Custom SDL event code we push from the PTY reader thread to wake the
// main loop. Picked from the user-event range so we don't clash.
TERMINAL_EVENT :: i32(0x42524754) // "BRGT" tag

// Opens a new terminal pane sized to `rows` × `cols`. Returns false if
// libvterm or the PTY couldn't be created. Idempotent — already-open
// terminals are reported as success.
terminal_open :: proc(rows, cols: int) -> bool {
	if g_terminal != nil do return true

	t := new(Terminal)
	t.rows = rows
	t.cols = cols
	t.input_mutex = sdl.CreateMutex()

	t.vt = vterm_new(c.int(rows), c.int(cols))
	if t.vt == nil {
		sdl.DestroyMutex(t.input_mutex)
		free(t)
		return false
	}
	vterm_set_utf8(t.vt, 1)
	t.screen = vterm_obtain_screen(t.vt)
	t.state  = vterm_obtain_state(t.vt)
	if t.screen != nil {
		// Wire callbacks BEFORE the reset so the reset itself doesn't
		// get its swept lines silently dropped (some libvterm versions
		// push a few lines during reset). settermprop tracks alt-screen
		// state so we know when a `clear` should wipe scrollback.
		t.callbacks.sb_pushline = terminal_sb_pushline
		t.callbacks.settermprop = terminal_settermprop
		vterm_screen_set_callbacks(t.screen, &t.callbacks, t)
		vterm_screen_reset(t.screen, 1)
	}

	// Spawn the user's shell. We hand it the bare minimum environment
	// for now; richer TERM / LANG handling can come later.
	shell := os.get_env("SHELL", context.temp_allocator)
	if len(shell) == 0 do shell = "/bin/sh"
	pty, ok := pty_spawn([]string{shell}, cols, rows)
	if !ok {
		vterm_free(t.vt)
		sdl.DestroyMutex(t.input_mutex)
		free(t)
		return false
	}
	t.pty = pty

	// Spin up the reader.
	t.reader_thread = sdl.CreateThread(terminal_reader_thread, "bragi-pty-reader", t)
	if t.reader_thread == nil {
		pty_close(&t.pty)
		vterm_free(t.vt)
		sdl.DestroyMutex(t.input_mutex)
		free(t)
		return false
	}

	g_terminal = t
	g_terminal_visible = true
	return true
}

terminal_close :: proc() {
	if g_terminal == nil do return
	t := g_terminal

	t.reader_quit = true
	pty_close(&t.pty) // closing the master fd unblocks the reader's read()

	if t.reader_thread != nil do sdl.WaitThread(t.reader_thread, nil)

	if t.vt != nil do vterm_free(t.vt)
	delete(t.pending_input)
	for line in t.scrollback do delete(line.cells)
	delete(t.scrollback)
	if t.input_mutex != nil do sdl.DestroyMutex(t.input_mutex)
	free(t)

	g_terminal = nil
	g_terminal_visible = false
	g_terminal_active  = false
}

// Resize the terminal grid. Updates libvterm and the PTY so applications
// like vim/htop redraw at the new size. Caller passes the cell-grid
// dimensions, not pixels.
terminal_resize :: proc(rows, cols: int) {
	if g_terminal == nil do return
	t := g_terminal
	if rows == t.rows && cols == t.cols do return
	t.rows = rows
	t.cols = cols
	vterm_set_size(t.vt, c.int(rows), c.int(cols))
	pty_resize(&t.pty, cols, rows)
	// A resize warps libvterm's grid (rows can be inserted or deleted),
	// so a stale scroll position becomes meaningless. Snap back to live.
	t.scroll_offset = 0
	t.dirty = true
}

// Adjusts the scrollback view by `lines_f` lines (positive = scroll up to
// older content). Fractional input is rounded; clamped to [0, sb_count].
// Idempotent at the boundaries — wheel events that would push past either
// end no-op rather than fighting the user.
terminal_scroll_by :: proc(lines_f: f32) {
	if g_terminal == nil do return
	t := g_terminal
	n: int
	if lines_f >= 0 do n = int(lines_f + 0.5)
	else            do n = int(lines_f - 0.5)
	if n == 0 do return
	new_off := t.scroll_offset + n
	max_off := len(t.scrollback)
	if new_off < 0       do new_off = 0
	if new_off > max_off do new_off = max_off
	if new_off == t.scroll_offset do return
	t.scroll_offset = new_off
	t.dirty = true
}

// libvterm callback: a line just scrolled off the top of the live grid.
// Copy its cells into the ring (evicting the oldest if we'd overflow) and
// keep the user's scrollback view anchored if they were already scrolled
// up — otherwise their reading position would silently drift downward.
@(private="file")
terminal_sb_pushline :: proc "c" (cols: c.int, cells: [^]VTermScreenCell, user: rawptr) -> c.int {
	context = runtime.default_context()
	t := cast(^Terminal)user
	if t == nil do return 0

	n := int(cols)
	line: Scrollback_Line
	line.cells = make([]VTermScreenCell, n)
	for i in 0 ..< n do line.cells[i] = cells[i]

	if len(t.scrollback) >= TERMINAL_SCROLLBACK_MAX {
		// Evict the oldest entry. ordered_remove on a [dynamic] is O(n)
		// memmove of one slot per push, but only at steady-state once
		// the ring has filled — fine for v1.
		delete(t.scrollback[0].cells)
		ordered_remove(&t.scrollback, 0)
	}
	append(&t.scrollback, line)

	if t.scroll_offset > 0 {
		t.scroll_offset += 1
		max_off := len(t.scrollback)
		if t.scroll_offset > max_off do t.scroll_offset = max_off
	}
	return 1
}

// Drains the bytes the reader thread accumulated and feeds them to
// libvterm. Called from the main loop after a TERMINAL_EVENT wakes it.
terminal_pump :: proc() {
	if g_terminal == nil do return
	t := g_terminal

	sdl.LockMutex(t.input_mutex)
	defer sdl.UnlockMutex(t.input_mutex)

	if len(t.pending_input) == 0 do return
	cstr := cstring(raw_data(t.pending_input))
	_ = vterm_input_write(t.vt, cstr, c.size_t(len(t.pending_input)))

	// Match Ghostty's behavior: `clear` (which emits ESC[2J / ESC[3J,
	// or ESC c for full reset) wipes the scrollback ring too, so users
	// don't have to scroll past the old output to see "clean slate."
	// Only on the main grid — alt-screen apps (vim, htop, less) emit
	// the same erase sequences during ordinary redraws and we'd be
	// throwing away the user's pre-app history.
	if !t.on_alt_screen && bytes_contain_clear_screen(t.pending_input[:]) {
		terminal_clear_scrollback(t)
	}
	clear(&t.pending_input)
	t.dirty = true
}

// Wipe the scrollback ring and snap the view back to live. Called from
// the `clear`-detection path; safe to call from anywhere on the main
// thread (no mutex needed — scrollback is only touched from here and
// from sb_pushline, both on the main thread).
@(private="file")
terminal_clear_scrollback :: proc(t: ^Terminal) {
	for line in t.scrollback do delete(line.cells)
	clear(&t.scrollback)
	t.scroll_offset = 0
}

// Scan a byte buffer for the ESC sequences that mean "wipe everything":
//   ESC c        — RIS (full terminal reset)
//   ESC [ 2 J    — erase entire display
//   ESC [ 3 J    — erase saved lines (xterm scrollback)
// Matches the unparameterized forms only (no `\033[02J` etc.) since
// real-world `tput clear` and shells emit the bare numeric form.
@(private="file")
bytes_contain_clear_screen :: proc(buf: []u8) -> bool {
	n := len(buf)
	for i in 0 ..< n {
		if buf[i] != 0x1b do continue
		if i + 1 >= n     do break
		if buf[i + 1] == 'c' do return true // RIS
		if buf[i + 1] == '[' && i + 3 < n {
			if (buf[i + 2] == '2' || buf[i + 2] == '3') && buf[i + 3] == 'J' {
				return true
			}
		}
	}
	return false
}

// libvterm callback: a terminal property changed. We only listen for the
// alt-screen toggle (so we know whether `clear`-style erases should be
// treated as scrollback-wiping).
@(private="file")
terminal_settermprop :: proc "c" (prop: c.int, val: rawptr, user: rawptr) -> c.int {
	context = runtime.default_context()
	t := cast(^Terminal)user
	if t == nil do return 0

	if prop == VTERM_PROP_ALTSCREEN && val != nil {
		// VTermValue is a tagged union; for boolean props the c.int sits
		// at offset 0 — read it directly without binding the full union.
		b := (cast(^c.int)val)^
		t.on_alt_screen = b != 0
	}
	return 1
}

// Drain libvterm's outbound queue (escape sequences it generated in
// response to keyboard / mouse encoding) and write them to the PTY so
// the child sees user input.
terminal_flush_output :: proc() {
	if g_terminal == nil do return
	t := g_terminal
	buf: [1024]u8
	for {
		n := vterm_output_read(t.vt, raw_data(buf[:]), c.size_t(len(buf)))
		if n == 0 do break
		_ = pty_write(&t.pty, buf[:n])
	}
}

// Forward a printable rune to the terminal. Caller flushes afterwards.
// Any keystroke snaps the user back to the live screen — matches what
// every other terminal emulator does and avoids a confusing "I'm typing
// but nothing's appearing" state when the user has scrolled up.
terminal_send_rune :: proc(r: rune, mods: sdl.Keymod) {
	if g_terminal == nil do return
	if g_terminal.scroll_offset != 0 {
		g_terminal.scroll_offset = 0
		g_terminal.dirty = true
	}
	g_terminal.blink_timer = 0
	vterm_keyboard_unichar(g_terminal.vt, u32(r), to_vterm_mod(mods))
}

// Forward a special key (arrow / home / etc.) to the terminal. Caller flushes.
terminal_send_special :: proc(key: VTermKey, mods: sdl.Keymod) {
	if g_terminal == nil do return
	if g_terminal.scroll_offset != 0 {
		g_terminal.scroll_offset = 0
		g_terminal.dirty = true
	}
	g_terminal.blink_timer = 0
	vterm_keyboard_key(g_terminal.vt, key, to_vterm_mod(mods))
}

// Reader thread: blocks on the PTY master fd, accumulates output into
// the terminal's buffer under the mutex, and pushes a TERMINAL_EVENT
// to wake the main thread. Exits on shutdown or EOF.
@(private="file")
terminal_reader_thread :: proc "c" (data: rawptr) -> c.int {
	context = runtime.default_context()

	t := cast(^Terminal)data
	buf: [4096]u8

	for !t.reader_quit {
		n := pty_read(&t.pty, buf[:])
		if n == -2 {
			t.exited = true
			// Push a final wake-up so the main loop notices `exited`
			// even if no bytes were waiting in pending_input. Without
			// this, the loop would idle on WaitEventTimeout and the
			// pane would stay open until the user moved the mouse.
			ev: sdl.Event
			ev.user.type = .USER
			ev.user.code = TERMINAL_EVENT
			_ = sdl.PushEvent(&ev)
			break
		}
		if n <= 0 {
			// EAGAIN / transient error. Sleep a millisecond before the
			// next attempt so we don't spin a core flat. A select() /
			// poll() loop would be more elegant; this is fine for v1.
			sdl.Delay(1)
			continue
		}

		sdl.LockMutex(t.input_mutex)
		old_len := len(t.pending_input)
		resize(&t.pending_input, old_len + int(n))
		copy(t.pending_input[old_len:], buf[:n])
		sdl.UnlockMutex(t.input_mutex)

		ev: sdl.Event
		ev.user.type = .USER
		ev.user.code = TERMINAL_EVENT
		_ = sdl.PushEvent(&ev)
	}
	return 0
}

@(private="file")
to_vterm_mod :: proc(mods: sdl.Keymod) -> VTermModifier {
	out := VTERM_MOD_NONE
	if mods & sdl.KMOD_SHIFT != {} do out |= VTERM_MOD_SHIFT
	if mods & sdl.KMOD_ALT   != {} do out |= VTERM_MOD_ALT
	if mods & sdl.KMOD_CTRL  != {} do out |= VTERM_MOD_CTRL
	return out
}

// Translate an SDL keydown into a libvterm key/rune and forward it to
// the active terminal. Returns true if the event was consumed.
// Printable typing is delivered separately via handle_text_input —
// we only handle the special / chorded cases here.
handle_terminal_keydown :: proc(ev: sdl.KeyboardEvent) -> bool {
	if g_terminal == nil do return false
	mods := ev.mod
	consumed := true

	switch ev.key {
	case sdl.K_RETURN, sdl.K_KP_ENTER: terminal_send_special(.ENTER,     mods)
	case sdl.K_TAB:                    terminal_send_special(.TAB,       mods)
	case sdl.K_BACKSPACE:              terminal_send_special(.BACKSPACE, mods)
	case sdl.K_ESCAPE:                 terminal_send_special(.ESCAPE,    mods)
	case sdl.K_UP:                     terminal_send_special(.UP,        mods)
	case sdl.K_DOWN:                   terminal_send_special(.DOWN,      mods)
	case sdl.K_LEFT:                   terminal_send_special(.LEFT,      mods)
	case sdl.K_RIGHT:                  terminal_send_special(.RIGHT,     mods)
	case sdl.K_HOME:                   terminal_send_special(.HOME,      mods)
	case sdl.K_END:                    terminal_send_special(.END,       mods)
	case sdl.K_PAGEUP:                 terminal_send_special(.PAGEUP,    mods)
	case sdl.K_PAGEDOWN:               terminal_send_special(.PAGEDOWN,  mods)
	case sdl.K_INSERT:                 terminal_send_special(.INS,       mods)
	case sdl.K_DELETE:                 terminal_send_special(.DEL,       mods)
	case:
		// Ctrl+letter: SDL frequently doesn't emit a TEXT_INPUT event
		// for these, so we encode the keycode here. SDL3 keycodes for
		// letters are ASCII ('a' .. 'z'), which we pass directly.
		if mods & sdl.KMOD_CTRL != {} && ev.key >= sdl.K_A && ev.key <= sdl.K_Z {
			terminal_send_rune(rune(ev.key), mods)
		} else {
			consumed = false
		}
	}
	if consumed do terminal_flush_output()
	return consumed
}

// Forward a printable string from a TEXT_INPUT event to the terminal.
handle_terminal_text :: proc(text: string) {
	if g_terminal == nil do return
	for r in text do terminal_send_rune(r, sdl.KMOD_NONE)
	terminal_flush_output()
}

// ──────────────────────────────────────────────────────────────────
// ANSI / 256-color palette for indexed colors
// ──────────────────────────────────────────────────────────────────

// xterm-style 16-color base palette. Bright variants live at 8..15.
@(private="file")
ANSI_BASE_PALETTE := [16]sdl.Color{
	{ 30,  30,  38, 255}, // 0  black (we use the editor bg so it matches the chrome)
	{205,   0,   0, 255}, // 1  red
	{  0, 205,   0, 255}, // 2  green
	{205, 205,   0, 255}, // 3  yellow
	{ 60, 100, 220, 255}, // 4  blue
	{205,   0, 205, 255}, // 5  magenta
	{  0, 205, 205, 255}, // 6  cyan
	{229, 229, 229, 255}, // 7  white
	{127, 127, 127, 255}, // 8  bright black
	{255,  85,  85, 255}, // 9  bright red
	{ 80, 250,  80, 255}, // 10 bright green
	{255, 255,  85, 255}, // 11 bright yellow
	{ 92,  92, 255, 255}, // 12 bright blue
	{255,  85, 255, 255}, // 13 bright magenta
	{ 85, 255, 255, 255}, // 14 bright cyan
	{255, 255, 255, 255}, // 15 bright white
}

// xterm 256-color cube quantization steps for the 6×6×6 region.
// Declared as a `var` (not a `::` constant) so we can index it with a
// runtime variable; Odin only allows runtime indexing on addressable values.
@(private="file")
CUBE_STEPS := [6]u8{0, 95, 135, 175, 215, 255}

@(private="file")
indexed_to_rgb :: proc(idx: u8) -> sdl.Color {
	switch {
	case idx < 16:
		return ANSI_BASE_PALETTE[idx]
	case idx < 232:
		// 6×6×6 RGB cube: idx = 16 + 36*r + 6*g + b.
		n := int(idx) - 16
		r := n / 36
		g := (n / 6) % 6
		b := n % 6
		return sdl.Color{CUBE_STEPS[r], CUBE_STEPS[g], CUBE_STEPS[b], 255}
	case:
		// Grayscale ramp: 232 → 8, 233 → 18, …, 255 → 238.
		v := u8(8 + (int(idx) - 232) * 10)
		return sdl.Color{v, v, v, 255}
	}
}

// Convert a libvterm cell color to an SDL color, falling back to the
// editor's theme when the cell carries the "default fg/bg" sentinel.
@(private="file")
vterm_color_to_sdl :: proc(col: VTermColor, default_color: sdl.Color) -> sdl.Color {
	t := col.type
	if t & VTERM_COLOR_DEFAULT_FG != 0 || t & VTERM_COLOR_DEFAULT_BG != 0 {
		return default_color
	}
	if t & VTERM_COLOR_TYPE_MASK == VTERM_COLOR_INDEXED {
		return indexed_to_rgb(col.indexed.idx)
	}
	return sdl.Color{col.rgb.red, col.rgb.green, col.rgb.blue, 255}
}

// ──────────────────────────────────────────────────────────────────
// Scrollbar geometry + interaction
// ──────────────────────────────────────────────────────────────────

// Splits the terminal pane rect into its cell-grid area (left) and the
// scrollbar track (right). The track strip is always reserved, even when
// no scrollback exists yet — keeps the cell-grid width stable as soon as
// the terminal opens, so resizing the strip doesn't reflow the live grid
// the moment the first line scrolls off.
terminal_split_rect :: proc(rect: sdl.FRect) -> (text: sdl.FRect, track: sdl.FRect) {
	sb_w := f32(SB_THICKNESS)
	if sb_w > rect.w do sb_w = rect.w
	text  = sdl.FRect{rect.x,                    rect.y, rect.w - sb_w, rect.h}
	track = sdl.FRect{rect.x + rect.w - sb_w,    rect.y, sb_w,           rect.h}
	return
}

// Translate the current (sb_count, scroll_offset, rows) state into
// thumb start-y and thumb height inside `track`. Returns has_thumb=false
// when there's no scrollback to scroll yet — caller still draws the
// track but skips the thumb so it doesn't look stuck full-height.
@(private="file")
terminal_thumb_metrics :: proc(t: ^Terminal, track: sdl.FRect) -> (start, size: f32, has_thumb: bool) {
	sb_count := len(t.scrollback)
	if sb_count <= 0 do return 0, 0, false

	rows_f    := f32(t.rows)
	total_f   := f32(sb_count + t.rows)
	viewport  := rows_f
	scroll    := f32(sb_count - t.scroll_offset) // 0 = top of history; sb_count = at live tail

	start, size = scrollbar_thumb_metrics(scroll * g_line_height,
	                                       total_f * g_line_height,
	                                       viewport * g_line_height,
	                                       track.h)
	return start, size, true
}

// Given a desired thumb-top within the track (in pixels), compute the
// scroll_offset that places it there. Inverse of terminal_thumb_metrics.
@(private="file")
terminal_offset_from_thumb_y :: proc(t: ^Terminal, track: sdl.FRect, thumb_y_in_track: f32) -> int {
	sb_count := len(t.scrollback)
	if sb_count <= 0 do return 0

	_, size, _ := terminal_thumb_metrics(t, track)
	track_room := track.h - size
	if track_room <= 0 do return 0

	y := clamp(thumb_y_in_track, 0, track_room)
	// scroll = sb_count - scroll_offset.  scroll/sb_count = y/track_room.
	// → scroll_offset = sb_count * (1 - y/track_room).
	off_f := f32(sb_count) * (1 - y / track_room)
	off   := int(off_f + 0.5)
	if off < 0 do off = 0
	if off > sb_count do off = sb_count
	return off
}

// True if `pt` is inside the scrollbar track for the terminal at `rect`.
terminal_point_in_scrollbar :: proc(rect: sdl.FRect, pt: sdl.FPoint) -> bool {
	_, track := terminal_split_rect(rect)
	return point_in_rect(pt, track)
}

// Mouse-down inside the terminal's scrollbar. Click on the thumb starts
// a drag; click on the track elsewhere jumps the thumb center to the
// click and continues as a drag (matches the editor's scrollbar feel).
// Returns true if the click was on the scrollbar (caller should swallow).
terminal_handle_sb_button_down :: proc(rect: sdl.FRect, pt: sdl.FPoint) -> bool {
	if g_terminal == nil do return false
	t := g_terminal
	_, track := terminal_split_rect(rect)
	if !point_in_rect(pt, track) do return false
	if len(t.scrollback) <= 0 do return true // swallow but no-op

	start, size, has := terminal_thumb_metrics(t, track)
	if !has do return true

	thumb := sdl.FRect{track.x, track.y + start, track.w, size}
	if point_in_rect(pt, thumb) {
		// Grab the thumb where it was clicked.
		t.sb_dragging    = true
		t.sb_drag_offset = pt.y - thumb.y
		return true
	}
	// Clicked the track outside the thumb — center the thumb on the
	// click and start dragging from its midpoint.
	target_y := pt.y - track.y - size / 2
	t.scroll_offset  = terminal_offset_from_thumb_y(t, track, target_y)
	t.sb_dragging    = true
	t.sb_drag_offset = size / 2
	t.dirty = true
	return true
}

// Mouse-motion while the scrollbar is being dragged. Caller has already
// determined a drag is active.
terminal_handle_sb_drag :: proc(rect: sdl.FRect, my: f32) {
	if g_terminal == nil do return
	t := g_terminal
	if !t.sb_dragging do return
	_, track := terminal_split_rect(rect)
	thumb_y := my - t.sb_drag_offset - track.y
	new_off := terminal_offset_from_thumb_y(t, track, thumb_y)
	if new_off != t.scroll_offset {
		t.scroll_offset = new_off
		t.dirty = true
	}
}

// Clears any in-progress scrollbar drag. Safe to call unconditionally.
terminal_handle_sb_button_up :: proc() {
	if g_terminal == nil do return
	g_terminal.sb_dragging = false
}

// True if a scrollbar drag is currently active. Used by main.odin to
// route mouse-motion to the scrollbar even when the cursor wanders out
// of the terminal rect mid-drag.
terminal_sb_dragging :: proc() -> bool {
	return g_terminal != nil && g_terminal.sb_dragging
}

// ──────────────────────────────────────────────────────────────────
// Render
// ──────────────────────────────────────────────────────────────────

// Look up the cell at visible row `vis_row`, column `col`. Routes to the
// scrollback ring or the live screen depending on the current scroll
// offset. Returns a zero-initialised cell (which renders as transparent
// continuation, falling back to the rect's bg fill) when the request
// falls past the end of either source.
@(private="file")
terminal_cell_at :: proc(t: ^Terminal, vis_row, col: int) -> VTermScreenCell {
	cell: VTermScreenCell
	if t.scroll_offset > 0 && vis_row < t.scroll_offset {
		sb_idx := len(t.scrollback) - t.scroll_offset + vis_row
		if sb_idx < 0 || sb_idx >= len(t.scrollback) do return cell
		line := t.scrollback[sb_idx]
		if col < 0 || col >= len(line.cells) do return cell
		return line.cells[col]
	}
	screen_row := vis_row - t.scroll_offset
	if screen_row < 0 || screen_row >= t.rows do return cell
	pos := VTermPos{c.int(screen_row), c.int(col)}
	_ = vterm_screen_get_cell(t.screen, pos, &cell)
	return cell
}

// Walk the cell grid and paint it inside `rect`. Batches consecutive
// cells with the same fg/bg into a single draw_text call so we hit the
// per-segment text cache instead of issuing one rasterization per cell.
draw_terminal :: proc(rect: sdl.FRect) {
	if g_terminal == nil do return
	t := g_terminal

	text_rect, sb_rect := terminal_split_rect(rect)

	// Clip so any glyph that overflows the cell boundary doesn't bleed
	// into the editor strip above us or the scrollbar strip beside us.
	clip := sdl.Rect{i32(text_rect.x), i32(text_rect.y), i32(text_rect.w), i32(text_rect.h)}
	sdl.SetRenderClipRect(g_renderer, &clip)

	default_fg := g_theme.default_color
	default_bg := g_theme.bg_color

	// Solid background under the whole grid. Cells may override per-run.
	fill_rect(text_rect, default_bg)

	for row in 0 ..< t.rows {
		y := text_rect.y + f32(row) * g_line_height
		col := 0
		for col < t.cols {
			cell := terminal_cell_at(t, row, col)

			// width=0 cells are continuation slots of a wide glyph in
			// the previous column. Skip without advancing.
			if cell.width == 0 {
				col += 1
				continue
			}

			fg := vterm_color_to_sdl(cell.fg, default_fg)
			bg := vterm_color_to_sdl(cell.bg, default_bg)

			// Greedy run: keep extending while the next cell shares
			// the same fg/bg (and isn't a continuation). Then emit one
			// draw call for the whole run.
			run_start := col
			run_text := strings.builder_make(context.temp_allocator)

			for col < t.cols {
				cc := terminal_cell_at(t, row, col)
				if cc.width == 0 {
					col += 1
					continue
				}
				next_fg := vterm_color_to_sdl(cc.fg, default_fg)
				next_bg := vterm_color_to_sdl(cc.bg, default_bg)
				if col != run_start && (next_fg != fg || next_bg != bg) do break

				// Emit the primary glyph; skip combiners for v1.
				r := rune(cc.chars[0])
				if r == 0 do r = ' '
				strings.write_rune(&run_text, r)
				col += int(cc.width)
				if col >= t.cols do break
			}

			run_str := strings.to_string(run_text)
			if len(run_str) == 0 do continue

			x := text_rect.x + f32(run_start) * g_char_width
			cell_w := f32(col - run_start) * g_char_width

			// Background rect for the run if it differs from the default.
			if bg != default_bg do fill_rect({x, y, cell_w, g_line_height}, bg)

			cstr := strings.clone_to_cstring(run_str, context.temp_allocator)
			draw_text(cstr, x, y, fg, bg, g_terminal_font)
		}
	}

	// Cursor: block at the live cursor position. Hidden while the user
	// has scrolled back through history (the live grid isn't fully on
	// screen). When the terminal owns focus, the block blinks at the
	// editor's 0.5-s cadence; otherwise it shows a faint ghost so the
	// user can still see where the caret would resume — same treatment
	// as inactive editor panes.
	if t.state != nil && t.scroll_offset == 0 {
		cur: VTermPos
		vterm_state_get_cursorpos(t.state, &cur)
		cx := text_rect.x + f32(cur.col) * g_char_width
		cy := text_rect.y + f32(int(cur.row)) * g_line_height

		visible := true
		color   := g_theme.cursor_color
		if g_terminal_active {
			visible = int(t.blink_timer * 2) % 2 == 0
		} else {
			color.a = 60
		}
		if visible do fill_rect({cx, cy, g_char_width, g_line_height}, color)
	}

	// Drop the cell-grid clip before drawing the scrollbar so the
	// thumb / track aren't clipped against the text rect.
	sdl.SetRenderClipRect(g_renderer, nil)

	// Scrollbar — same chrome as the editor's. Track always renders so
	// the strip is visually consistent with the panes above; the thumb
	// only appears once there's scrollback to scroll through.
	fill_rect(sb_rect, g_theme.sb_track_color)
	if start, size, has := terminal_thumb_metrics(t, sb_rect); has {
		thumb := sdl.FRect{sb_rect.x + 2, sb_rect.y + start, sb_rect.w - 4, size}
		mx, my: f32
		_ = sdl.GetMouseState(&mx, &my)
		mouse := sdl.FPoint{mx, my}
		color := g_theme.sb_thumb_color
		if t.sb_dragging || point_in_rect(mouse, thumb) do color = g_theme.sb_thumb_hover_color
		fill_rect(thumb, color)
	}
}
