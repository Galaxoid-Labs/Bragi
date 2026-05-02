package bragi

import "core:c"

// Minimal Odin foreign bindings for libvterm 0.3.x. Only the surface we
// actually need to embed a terminal:
//   - VT state machine (vterm_new / free / set_size / input_write)
//   - keyboard input encoding (unichar / key)
//   - output draining (vterm_output_read)
//   - screen-level cell access for rendering
//
// Layout matches `/opt/homebrew/include/vterm.h` from Homebrew's libvterm.
// Bumped libvterm versions are ABI-stable per the upstream maintainer
// (the 0.3 line shipped 2022 and is still current as of 2026); if we
// move to libghostty-vt later only this file changes.

when ODIN_OS == .Darwin {
	foreign import vterm_lib { "system:vterm" }
} else when ODIN_OS == .Linux {
	foreign import vterm_lib { "system:vterm" }
}
// Windows: no foreign import. We provide pure-Odin no-op stubs below so the
// rest of the codebase compiles. `terminal_open` checks for vterm_new == nil
// and bails cleanly, so the embedded terminal pane is simply unavailable
// until pty.odin's CreatePseudoConsole branch + a Windows libvterm build
// land.

VTerm        :: struct {} // opaque
VTermState   :: struct {}
VTermScreen  :: struct {}

VTermPos :: struct {
	row: c.int,
	col: c.int,
}

VTermRect :: struct {
	start_row: c.int,
	end_row:   c.int,
	start_col: c.int,
	end_col:   c.int,
}

VTERM_MAX_CHARS_PER_CELL :: 6

// Tagged union with the type byte at offset 0; we read it manually.
VTermColor :: struct #raw_union {
	type:    u8,
	rgb:     struct { type: u8, red, green, blue: u8 },
	indexed: struct { type: u8, idx: u8 },
}

// VTermProp values (only the ones we care about). Passed to settermprop;
// the value pointer's interpretation depends on the prop — for ALTSCREEN
// it's a `c.int` boolean stored at offset 0.
VTERM_PROP_ALTSCREEN :: 3

// Type-bits of VTermColor.type. See vterm.h's VTermColorType enum.
VTERM_COLOR_RGB          :: 0x00
VTERM_COLOR_INDEXED      :: 0x01
VTERM_COLOR_TYPE_MASK    :: 0x01
VTERM_COLOR_DEFAULT_FG   :: 0x02
VTERM_COLOR_DEFAULT_BG   :: 0x04
VTERM_COLOR_DEFAULT_MASK :: 0x06

// libvterm packs cell attributes in a C bitfield (~18 bits, stored on
// a single uint32_t cell). Odin can't represent the bitfield directly
// — but we don't need to read individual bits yet, so we model it as a
// u32 to keep the struct's size + 4-byte alignment in lockstep with C.
// (Modeling it as u16+u16 would 2-byte-align the struct and shift
// every following field — which is exactly the bug that made colors
// read garbage in the first cut.)
VTermScreenCellAttrs :: struct {
	flags: u32,
}

VTermScreenCell :: struct {
	chars: [VTERM_MAX_CHARS_PER_CELL]u32, // primary glyph + up to 5 combiners
	width: c.char,
	attrs: VTermScreenCellAttrs,
	fg:    VTermColor,
	bg:    VTermColor,
}

VTermModifier :: distinct c.int
VTERM_MOD_NONE  :: VTermModifier(0x00)
VTERM_MOD_SHIFT :: VTermModifier(0x01)
VTERM_MOD_ALT   :: VTermModifier(0x02)
VTERM_MOD_CTRL  :: VTermModifier(0x04)

VTermKey :: enum c.int {
	NONE,
	ENTER,
	TAB,
	BACKSPACE,
	ESCAPE,
	UP,
	DOWN,
	LEFT,
	RIGHT,
	INS,
	DEL,
	HOME,
	END,
	PAGEUP,
	PAGEDOWN,
	// Function keys live at 256+; we don't bind them yet.
}

when ODIN_OS == .Darwin || ODIN_OS == .Linux {
	@(default_calling_convention = "c")
	foreign vterm_lib {
		vterm_new        :: proc(rows: c.int, cols: c.int) -> ^VTerm ---
		vterm_free       :: proc(vt: ^VTerm) ---
		vterm_set_size   :: proc(vt: ^VTerm, rows: c.int, cols: c.int) ---
		vterm_set_utf8   :: proc(vt: ^VTerm, is_utf8: c.int) ---

		// Feed bytes from the PTY in; returns bytes consumed.
		vterm_input_write :: proc(vt: ^VTerm, bytes: cstring, len: c.size_t) -> c.size_t ---

		// Drain queued output (escape sequences from keyboard / mouse encoding)
		// that should be written back to the PTY master fd.
		vterm_output_read :: proc(vt: ^VTerm, buf: [^]u8, len: c.size_t) -> c.size_t ---

		vterm_keyboard_unichar :: proc(vt: ^VTerm, c: u32, mod: VTermModifier) ---
		vterm_keyboard_key     :: proc(vt: ^VTerm, key: VTermKey, mod: VTermModifier) ---

		vterm_obtain_screen :: proc(vt: ^VTerm) -> ^VTermScreen ---
		vterm_obtain_state  :: proc(vt: ^VTerm) -> ^VTermState ---

		vterm_state_get_cursorpos :: proc(state: ^VTermState, cursorpos: ^VTermPos) ---

		vterm_screen_reset    :: proc(screen: ^VTermScreen, hard: c.int) ---
		vterm_screen_get_cell :: proc(screen: ^VTermScreen, pos: VTermPos, cell: ^VTermScreenCell) -> c.int ---

		vterm_screen_set_callbacks :: proc(screen: ^VTermScreen, cb: ^VTermScreenCallbacks, user: rawptr) ---
	}
} else {
	// Windows stubs. vterm_new returns nil so terminal_open's existing
	// nil-check fails the open path before any other vterm proc is reached;
	// the rest of these are reachable only via dead branches but still need
	// to satisfy the linker.
	vterm_new                  :: proc "c" (rows: c.int, cols: c.int) -> ^VTerm { return nil }
	vterm_free                 :: proc "c" (vt: ^VTerm) {}
	vterm_set_size             :: proc "c" (vt: ^VTerm, rows: c.int, cols: c.int) {}
	vterm_set_utf8             :: proc "c" (vt: ^VTerm, is_utf8: c.int) {}
	vterm_input_write          :: proc "c" (vt: ^VTerm, bytes: cstring, len: c.size_t) -> c.size_t { return 0 }
	vterm_output_read          :: proc "c" (vt: ^VTerm, buf: [^]u8, len: c.size_t) -> c.size_t { return 0 }
	vterm_keyboard_unichar     :: proc "c" (vt: ^VTerm, c: u32, mod: VTermModifier) {}
	vterm_keyboard_key         :: proc "c" (vt: ^VTerm, key: VTermKey, mod: VTermModifier) {}
	vterm_obtain_screen        :: proc "c" (vt: ^VTerm) -> ^VTermScreen { return nil }
	vterm_obtain_state         :: proc "c" (vt: ^VTerm) -> ^VTermState { return nil }
	vterm_state_get_cursorpos  :: proc "c" (state: ^VTermState, cursorpos: ^VTermPos) {}
	vterm_screen_reset         :: proc "c" (screen: ^VTermScreen, hard: c.int) {}
	vterm_screen_get_cell      :: proc "c" (screen: ^VTermScreen, pos: VTermPos, cell: ^VTermScreenCell) -> c.int { return 0 }
	vterm_screen_set_callbacks :: proc "c" (screen: ^VTermScreen, cb: ^VTermScreenCallbacks, user: rawptr) {}
}

// libvterm's screen-callbacks struct. We only set `sb_pushline` (called
// when a line scrolls off the top so we can stash it in our scrollback
// ring); the rest are left nil and libvterm skips them. The struct
// layout has to match vterm.h byte-for-byte.
VTermScreenCallbacks :: struct {
	damage:      proc "c" (rect: VTermRect, user: rawptr) -> c.int,
	moverect:    proc "c" (dest: VTermRect, src: VTermRect, user: rawptr) -> c.int,
	movecursor:  proc "c" (pos: VTermPos, oldpos: VTermPos, visible: c.int, user: rawptr) -> c.int,
	settermprop: proc "c" (prop: c.int, val: rawptr, user: rawptr) -> c.int,
	bell:        proc "c" (user: rawptr) -> c.int,
	resize:      proc "c" (rows: c.int, cols: c.int, user: rawptr) -> c.int,
	sb_pushline: proc "c" (cols: c.int, cells: [^]VTermScreenCell, user: rawptr) -> c.int,
	sb_popline:  proc "c" (cols: c.int, cells: [^]VTermScreenCell, user: rawptr) -> c.int,
}
