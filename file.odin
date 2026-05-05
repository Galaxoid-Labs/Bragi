package bragi

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"

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
	piece_buffer_destroy(&ed.buffer)
	ed.buffer = piece_buffer_make()

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
	ed.file_mtime_ns = 0
	ed.external_changed = false
}

// Cheap binary-file heuristic: if any of the first 8 KB is a NUL byte,
// treat the file as binary. Catches PNG / JPEG / ZIP / PDF / executables
// / nearly all common binary formats. False positives on text files with
// embedded NULs are extremely rare.
@(private="file")
peek_is_binary :: proc(fd: ^os.File) -> bool {
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
		set_status_message(fmt.tprintf("E: cannot open %s", path), .Error)
		return false
	}
	defer os.close(fd)

	size, size_err := os.file_size(fd)
	if size_err != nil {
		set_status_message(fmt.tprintf("E: stat failed for %s", path), .Error)
		return false
	}

	// Refuse binaries before destroying any existing state. Uses pread,
	// so the file pointer stays at 0 for the full read below.
	if size > 0 && peek_is_binary(fd) {
		set_status_message(fmt.tprintf("E: %s appears to be a binary file", path_basename(path)), .Error)
		return false
	}

	editor_clear(ed)

	if size > 0 {
		// Try mmap first (POSIX). On the happy pure-LF path, this
		// avoids the full read into RAM — the kernel lazy-pages the
		// file as we touch it. CRLF files end up touching every page
		// anyway during compaction, so the perf win is most
		// pronounced for big LF files (which is most of them).
		//
		// `MAP_PRIVATE` gives copy-on-write semantics: we can compact
		// in place without modifying the file on disk, and untouched
		// pages stay backed by the file. On non-POSIX (Windows),
		// `mmap_load_file` returns ok=false and we fall through.
		mmap_data, mmap_addr, mmap_ok := mmap_load_file(fd, int(size))

		bytes:        []u8 = mmap_data
		from_mmap:    bool = mmap_ok
		mmap_full_sz: int  = int(size)

		if !mmap_ok {
			// Fallback: read the whole file into a freshly-allocated
			// slice. Same shape as the pre-mmap implementation.
			bytes = make([]u8, int(size))
			n, read_err := os.read_full(fd, bytes)
			if read_err != nil || i64(n) != size {
				delete(bytes)
				set_status_message(fmt.tprintf("E: read failed for %s", path), .Error)
				return false
			}
		}
		n := len(bytes)

		// One-pass scan: detects EOL and pre-populates line_starts /
		// line_widths so the first draw frame doesn't have to rescan.
		// `scan_load` sets `ed.line_starts_ver = ed.buffer.version` —
		// 0 here (the empty buffer left by `editor_clear`), which
		// matches the new piece buffer's version, so the cache stays
		// valid across the swap below for pure-LF files.
		eol, mixed := scan_load(ed, bytes[:n])
		ed.eol = eol
		ed.eol_mixed = mixed

		final_len := n
		if eol == .CRLF || mixed {
			// CRLF/mixed: compact in place. For mmap'd MAP_PRIVATE
			// pages this triggers copy-on-write — we lose the
			// lazy-paging benefit on touched pages but never modify
			// the file on disk. Drop the partial line caches; their
			// positions are now stale.
			final_len = normalize_crlf_inplace(bytes[:n])
			clear(&ed.line_starts)
			clear(&ed.line_widths)
			ed.line_starts_ver = max(u64)
		}

		if from_mmap {
			// Hand the mmap to the buffer with `final_len` as the live
			// slice; the full mapping size stays attached for munmap.
			piece_buffer_destroy(&ed.buffer)
			ed.buffer = piece_buffer_make_from_mmap(bytes[:final_len], mmap_addr, mmap_full_sz)
		} else {
			// Heap-allocated path. Shrink if compaction trimmed bytes
			// so the buffer doesn't carry a dead tail.
			if final_len < n {
				shrunk := make([]u8, final_len)
				copy(shrunk, bytes[:final_len])
				delete(bytes)
				bytes = shrunk
			}
			piece_buffer_destroy(&ed.buffer)
			ed.buffer = piece_buffer_make_from_bytes(bytes)
		}
	} else {
		ed.eol = default_eol()
		ed.eol_mixed = false
	}

	if len(ed.file_path) > 0 do delete(ed.file_path)
	ed.file_path = strings.clone(path)
	ed.dirty = false
	ed.language = language_for_path(path)
	ed.file_mtime_ns = stat_mtime_ns(path)
	ed.external_changed = false
	file_watch_add(ed.file_path)
	return true
}

// Stat `path` and return its modification time in nanoseconds since
// the Unix epoch, or 0 if the path can't be stat'd. Used to detect
// external file changes — we capture this on every load + successful
// save and compare on file-watcher events.
@(private="file")
stat_mtime_ns :: proc(path: string) -> i64 {
	info, err := os.stat(path, context.temp_allocator)
	if err != nil do return 0
	defer os.file_info_delete(info, context.temp_allocator)
	return time.time_to_unix_nano(info.modification_time)
}

// Re-stat every open editor's file_path; if the on-disk mtime drifted
// past what we captured at load/save, either silently reload (clean
// buffer) or set the `external_changed` flag (dirty buffer). Called
// from the main loop on every FILE_WATCH_EVENT and once on focus
// regained, since file events that fire while the app is in the
// background can occasionally get coalesced or dropped.
editor_check_external_changes :: proc() {
	for &ed in g_editors {
		if len(ed.file_path) == 0 do continue
		mt := stat_mtime_ns(ed.file_path)
		if mt == 0 do continue                        // file gone — leave buffer alone
		if mt == ed.file_mtime_ns do continue         // unchanged

		if !ed.dirty {
			// Clean buffer: silently swap in the new bytes. Try to
			// keep the user where they were — preserve (line, col)
			// across the reload so scroll position is stable when a
			// formatter / agent / git only touched bytes elsewhere.
			// The line is clamped to the new file's total; if the
			// line went away (e.g. file truncated), we fall back to
			// the last existing line at column 0.
			cur_line, cur_col := editor_pos_to_line_col(&ed, ed.cursor)
			prev_scroll_y     := ed.scroll_y
			prev_scroll_x     := ed.scroll_x

			path := strings.clone(ed.file_path, context.temp_allocator)
			if editor_load_file(&ed, path) {
				total := editor_total_lines(&ed)
				target_line := clamp(cur_line, 0, max(0, total - 1))
				ed.cursor = editor_pos_at_line_col(&ed, target_line, cur_col)
				ed.anchor = ed.cursor
				ed.desired_col = cur_col
				ed.scroll_y = prev_scroll_y
				ed.scroll_x = prev_scroll_x
				name := path_basename(path)
				set_status_message(fmt.tprintf("reloaded %s (changed on disk)", name), .Info)
			}
		} else {
			// Dirty buffer: don't touch it. Surface the conflict
			// in the status bar; user resolves with :reload (drop
			// changes) or :w (overwrite).
			ed.external_changed = true
			ed.file_mtime_ns = mt   // remember the new disk-side mtime
			name := path_basename(ed.file_path)
			set_status_message(
				fmt.tprintf("%s changed on disk — :reload to load, :w to overwrite", name),
				.Error,
			)
		}
	}
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
	text := piece_buffer_to_string(&ed.buffer, context.temp_allocator)
	bytes := transmute([]u8)text

	// Convert from internal LF back to file's EOL style. For LF files this is
	// a no-op pass-through.
	if ed.eol == .CRLF {
		bytes = expand_lf_to_crlf(bytes, context.temp_allocator)
	}

	if write_err := os.write_entire_file(ed.file_path, bytes); write_err != nil do return false
	ed.dirty = false
	ed.eol_mixed = false // file is now uniform after this write
	// Re-capture mtime so the watcher event our own write triggers
	// doesn't immediately fire as an external change.
	ed.file_mtime_ns = stat_mtime_ns(ed.file_path)
	ed.external_changed = false
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
