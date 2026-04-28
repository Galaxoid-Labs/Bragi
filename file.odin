package bragi

import "core:os"
import "core:strings"

// Line ending style. Detected at load time, written back on save so files
// round-trip exactly when they have a uniform style.
EOL :: enum {
	LF,   // \n  — Unix, macOS, modern code
	CRLF, // \r\n — Windows, old DOS
}

default_eol :: proc() -> EOL {
	when ODIN_OS == .Windows do return .CRLF
	return .LF
}

eol_label :: proc(eol: EOL) -> string {
	switch eol {
	case .LF:   return "LF"
	case .CRLF: return "CRLF"
	}
	return "LF"
}

// Detect the dominant line-ending style. Returns `mixed=true` when both
// styles appear in the same file (rare; we warn the user before saving).
detect_eol :: proc(data: []u8) -> (eol: EOL, mixed: bool) {
	crlf := 0
	lf   := 0
	for i in 0 ..< len(data) {
		if data[i] == '\n' {
			lf += 1
			if i > 0 && data[i - 1] == '\r' do crlf += 1
		}
	}
	lone_lf := lf - crlf

	if lf == 0      do return default_eol(), false
	if crlf == 0    do return .LF,   false
	if lone_lf == 0 do return .CRLF, false

	// Mixed — pick the majority.
	mixed = true
	if crlf >= lone_lf do return .CRLF, true
	return .LF, true
}

// Strip `\r` immediately preceding `\n`. Lone `\r` is preserved (we don't
// touch any bytes that aren't part of a CRLF pair).
normalize_crlf_to_lf :: proc(data: []u8, allocator := context.allocator) -> []u8 {
	out := make([dynamic]u8, 0, len(data), allocator)
	n := len(data)
	i := 0
	for i < n {
		if data[i] == '\r' && i + 1 < n && data[i + 1] == '\n' {
			i += 1 // skip the \r; next iter writes \n
			continue
		}
		append(&out, data[i])
		i += 1
	}
	return out[:]
}

// Expand each `\n` to `\r\n`. Used on save when ed.eol is CRLF.
expand_lf_to_crlf :: proc(data: []u8, allocator := context.allocator) -> []u8 {
	out := make([dynamic]u8, 0, len(data) + 64, allocator)
	for b in data {
		if b == '\n' {
			append(&out, '\r')
			append(&out, '\n')
		} else {
			append(&out, b)
		}
	}
	return out[:]
}

// Reset the buffer + edit history. Preserves UI state (mode, blink, etc.) so
// the user's vim-mode position-of-mind isn't disturbed by opening a new file.
editor_clear :: proc(ed: ^Editor) {
	gap_buffer_destroy(&ed.buffer)
	ed.buffer = gap_buffer_make()

	undo_stack_clear(&ed.undo_stack)
	undo_stack_clear(&ed.redo_stack)
	undo_group_destroy(&ed.pending)
	ed.pending = {}
	ed.pending_kind = .None

	ed.cursor = 0
	ed.anchor = 0
	ed.desired_col = 0
	ed.scroll_x = 0
	ed.scroll_y = 0
	ed.dirty = false
	ed.eol = default_eol()
	ed.eol_mixed = false
}

editor_load_file :: proc(ed: ^Editor, path: string) -> bool {
	data, ok := os.read_entire_file(path)
	if !ok do return false
	defer delete(data)

	editor_clear(ed)

	eol, mixed := detect_eol(data)
	ed.eol = eol
	ed.eol_mixed = mixed

	if len(data) > 0 {
		// Only normalize when CRLF is involved (touching the bytes at all is
		// the only thing that risks corruption, so for pure-LF files we drop
		// data straight into the buffer).
		if eol == .CRLF || mixed {
			normalized := normalize_crlf_to_lf(data, context.temp_allocator)
			gap_buffer_insert(&ed.buffer, 0, normalized)
		} else {
			gap_buffer_insert(&ed.buffer, 0, data)
		}
	}

	if len(ed.file_path) > 0 do delete(ed.file_path)
	ed.file_path = strings.clone(path)
	ed.dirty = false
	ed.language = language_for_path(path)
	return true
}

editor_save_file :: proc(ed: ^Editor) -> bool {
	if len(ed.file_path) == 0 do return false
	text := gap_buffer_to_string(&ed.buffer, context.temp_allocator)
	bytes := transmute([]u8)text

	// Convert from internal LF back to file's EOL style. For LF files this is
	// a no-op pass-through.
	if ed.eol == .CRLF {
		bytes = expand_lf_to_crlf(bytes, context.temp_allocator)
	}

	if !os.write_entire_file(ed.file_path, bytes) do return false
	ed.dirty = false
	ed.eol_mixed = false // file is now uniform after this write
	return true
}

// Number of decimal digits needed to display n. (digits(0) == digits(9) == 1.)
digit_count :: proc(n: int) -> int {
	if n <= 0 do return 1
	count := 0
	x := n
	for x > 0 {
		count += 1
		x /= 10
	}
	return count
}

// Last path component (without parent dirs). For "/usr/file.txt" → "file.txt".
path_basename :: proc(path: string) -> string {
	for i := len(path) - 1; i >= 0; i -= 1 {
		if path[i] == '/' || path[i] == '\\' {
			return path[i + 1:]
		}
	}
	return path
}
