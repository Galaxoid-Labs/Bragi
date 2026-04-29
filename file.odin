package bragi

import "core:fmt"
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

	// Buffer-version-keyed caches must be invalidated explicitly: the new
	// buffer's version restarts at 0 and will collide with stale cached
	// versions from the previous buffer's lifetime. max(u64) is a sentinel
	// the version counter cannot reach.
	clear(&ed.line_starts)
	clear(&ed.line_widths)
	ed.line_starts_ver = max(u64)
	ed.cached_max_cols = 0
	ed.cached_max_cols_ver = max(u64)
	clear(&ed.search_match_positions)
	ed.search_match_ver = max(u64)
	if len(ed.search_match_pattern) > 0 do delete(ed.search_match_pattern)
	ed.search_match_pattern = ""

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

// Cheap binary-file heuristic: if any of the first 8 KB is a NUL byte,
// treat the file as binary. Catches PNG / JPEG / ZIP / PDF / executables
// / nearly all common binary formats. False positives on text files with
// embedded NULs are extremely rare.
@(private="file")
peek_is_binary :: proc(fd: os.Handle) -> bool {
	buf: [8192]u8
	n, _ := os.read_at(fd, buf[:], 0)
	for i in 0 ..< n {
		if buf[i] == 0 do return true
	}
	return false
}

editor_load_file :: proc(ed: ^Editor, path: string) -> bool {
	fd, open_err := os.open(path)
	if open_err != nil {
		set_status_message(fmt.tprintf("E: cannot open %s", path), is_error = true)
		return false
	}
	defer os.close(fd)

	size, size_err := os.file_size(fd)
	if size_err != nil {
		set_status_message(fmt.tprintf("E: stat failed for %s", path), is_error = true)
		return false
	}

	// Refuse binaries before destroying any existing state. Uses pread,
	// so the file pointer stays at 0 for the full read below.
	if size > 0 && peek_is_binary(fd) {
		set_status_message(fmt.tprintf("E: %s appears to be a binary file", path_basename(path)), is_error = true)
		return false
	}

	editor_clear(ed)

	if size > 0 {
		// Pre-size the gap buffer so the file content fits without a grow,
		// and read straight into its data slice — no intermediate buffer,
		// no extra memcpy.
		gap_buffer_destroy(&ed.buffer)
		ed.buffer = gap_buffer_make(int(size) + GAP_GROW)

		n, read_err := os.read_full(fd, ed.buffer.data[:size])
		if read_err != nil || i64(n) != size {
			ed.buffer.gap_start = 0
			ed.buffer.gap_end   = len(ed.buffer.data)
			set_status_message(fmt.tprintf("E: read failed for %s", path), is_error = true)
			return false
		}
		ed.buffer.gap_start = n
		ed.buffer.version  += 1

		// One pass over the freshly-read bytes: detect EOL and build the
		// line_starts/line_widths cache eagerly. The first frame after load
		// then doesn't need to scan the buffer again.
		eol, mixed := scan_load(ed, ed.buffer.data[:n])
		ed.eol = eol
		ed.eol_mixed = mixed

		// CRLF/mixed files need an in-place compaction. After that the
		// line_starts/line_widths positions we just built are stale, so we
		// invalidate them and let the next reader rebuild lazily.
		if eol == .CRLF || mixed {
			new_len := normalize_crlf_inplace(ed.buffer.data[:n])
			ed.buffer.gap_start = new_len
			ed.buffer.version  += 1
			clear(&ed.line_starts)
			clear(&ed.line_widths)
			ed.line_starts_ver = max(u64)
		}
	} else {
		ed.eol = default_eol()
		ed.eol_mixed = false
	}

	if len(ed.file_path) > 0 do delete(ed.file_path)
	ed.file_path = strings.clone(path)
	ed.dirty = false
	ed.language = language_for_path(path)
	return true
}

// Single-pass scan over freshly-loaded bytes: counts CRLF vs lone-LF for EOL
// detection, and (for files that look pure-LF) populates line_starts /
// line_widths so the first draw frame doesn't have to rescan.
@(private="file")
scan_load :: proc(ed: ^Editor, data: []u8) -> (eol: EOL, mixed: bool) {
	clear(&ed.line_starts)
	clear(&ed.line_widths)
	append(&ed.line_starts, 0)
	tab := g_config.editor.tab_size
	cols := 0
	crlf_count := 0
	lf_count := 0
	for b, i in data {
		switch b {
		case '\n':
			lf_count += 1
			if i > 0 && data[i - 1] == '\r' do crlf_count += 1
			append(&ed.line_widths, cols)
			append(&ed.line_starts, i + 1)
			cols = 0
		case '\t':
			cols += tab - (cols % tab)
		case:
			if (b & 0xC0) != 0x80 do cols += 1
		}
	}
	append(&ed.line_widths, cols)
	ed.line_starts_ver = ed.buffer.version

	lone_lf := lf_count - crlf_count
	switch {
	case lf_count == 0:    eol, mixed = default_eol(), false
	case crlf_count == 0:  eol, mixed = .LF,           false
	case lone_lf == 0:     eol, mixed = .CRLF,         false
	case crlf_count >= lone_lf: eol, mixed = .CRLF,    true
	case:                  eol, mixed = .LF,           true
	}
	return
}

// In-place compact: drop every '\r' that is immediately followed by '\n'.
// Returns the new logical length.
@(private="file")
normalize_crlf_inplace :: proc(buf: []u8) -> int {
	n := len(buf)
	j := 0
	for i := 0; i < n; i += 1 {
		if buf[i] == '\r' && i + 1 < n && buf[i + 1] == '\n' do continue
		buf[j] = buf[i]
		j += 1
	}
	return j
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
