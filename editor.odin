package bragi

import "core:strings"
import "core:unicode/utf8"

Scrollbar_Drag :: enum { None, Vertical, Horizontal }

Editor :: struct {
	buffer:         Gap_Buffer,
	cursor:         int, // byte offset
	anchor:         int, // selection anchor
	desired_col:    int,
	blink_timer:    f32,
	scroll_x:       f32,
	scroll_y:       f32,
	mouse_drag:     bool,
	sb_drag:        Scrollbar_Drag,
	sb_drag_offset: f32,

	// Undo/redo state.
	undo_stack:   [dynamic]Undo_Group,
	redo_stack:   [dynamic]Undo_Group,
	pending:      Undo_Group,
	pending_kind: Pending_Kind,

	// Vim modal state.
	mode:         Mode,
	vim_count:    int,
	vim_op:       Vim_Operator,
	vim_op_count: int,
	vim_prefix:   Vim_Prefix,

	// File state.
	file_path:  string, // owned; "" means no file
	dirty:      bool,
	language:   Language,
	eol:        EOL,
	eol_mixed:  bool, // transient — set by load_file when input had mixed endings


	// Command-line ":..." state (Command mode). Reused for Search mode input.
	cmd_buffer: [dynamic]u8,
	want_quit:  bool,

	// Search state (vim-style). pattern persists across uses so n/N can repeat.
	search_pattern: string, // owned; "" if no search yet
	search_forward: bool,

	// Cached editor_max_line_cols result; invalidated by buffer.version mismatch.
	cached_max_cols:     int,
	cached_max_cols_ver: u64,

	// line_starts[i] = byte offset of the start of line i. Always at least
	// one entry (line 0 starts at 0). Lazily rebuilt when buffer.version
	// disagrees with line_starts_ver. Lets editor_pos_to_line_col,
	// editor_nth_line_start, and editor_total_lines avoid full-buffer walks.
	// line_widths[i] = column width of line i (parallel to line_starts);
	// keeps editor_max_line_cols cheap by avoiding per-frame buffer scans.
	line_starts:     [dynamic]int,
	line_widths:     [dynamic]int,
	line_starts_ver: u64,

	// Cache of every match position for the current search pattern.
	// Invalidated when buffer.version changes or the pattern differs from
	// the one that was scanned. Without this, scrolling rescans the full
	// buffer every frame for the [n/m] readout.
	search_match_positions:    [dynamic]int,
	search_match_ver:          u64,
	search_match_pattern:      string, // owned clone of pattern at time of cache
	search_match_ignore_case:  bool,   // case-mode the cache was built under

	// Per-search override of case sensitivity (-1 = sensitive via `\C`,
	// 0 = use config defaults, +1 = insensitive via `\c`). Set when the
	// user submits a pattern via `/` or `?`.
	search_force_case: i8
}

editor_make :: proc() -> Editor {
	return Editor{buffer = gap_buffer_make()}
}

editor_destroy :: proc(ed: ^Editor) {
	gap_buffer_destroy(&ed.buffer)
	undo_group_destroy(&ed.pending)
	undo_stack_destroy(&ed.undo_stack)
	undo_stack_destroy(&ed.redo_stack)
	if len(ed.file_path) > 0           do delete(ed.file_path)
	if len(ed.search_pattern) > 0      do delete(ed.search_pattern)
	if len(ed.search_match_pattern) > 0 do delete(ed.search_match_pattern)
	delete(ed.cmd_buffer)
	delete(ed.line_starts)
	delete(ed.line_widths)
	delete(ed.search_match_positions)
}

// Initial buffer setup; bypasses the undo log (no history before this point).
editor_set_text :: proc(ed: ^Editor, text: string) {
	gap_buffer_insert(&ed.buffer, 0, transmute([]u8)text)
	ed.cursor = 0
	ed.anchor = 0
}

editor_has_selection :: proc(ed: ^Editor) -> bool {
	return ed.anchor != ed.cursor
}

editor_selection_range :: proc(ed: ^Editor) -> (lo, hi: int) {
	if ed.anchor < ed.cursor {
		return ed.anchor, ed.cursor
	}
	return ed.cursor, ed.anchor
}

utf8_lead_size :: proc(b: u8) -> int {
	switch {
	case b < 0x80: return 1
	case b < 0xC0: return 1
	case b < 0xE0: return 2
	case b < 0xF0: return 3
	}
	return 4
}

editor_step_back :: proc(ed: ^Editor, pos: int) -> int {
	if pos <= 0 do return 0
	i := pos - 1
	for i > 0 && (gap_buffer_byte_at(&ed.buffer, i) & 0xC0) == 0x80 {
		i -= 1
	}
	return i
}

editor_step_forward :: proc(ed: ^Editor, pos: int) -> int {
	n := gap_buffer_len(&ed.buffer)
	if pos >= n do return n
	size := utf8_lead_size(gap_buffer_byte_at(&ed.buffer, pos))
	return min(n, pos + size)
}

// Rebuilds the line-start + line-width tables if stale. Walks gb.data directly
// so the scan hits two contiguous slices rather than going through
// gap_buffer_byte_at (which is a per-byte branch); on a 100 MB buffer that's
// the difference between hundreds of milliseconds and tens.
@(private="file")
ensure_line_starts :: proc(ed: ^Editor) {
	if ed.line_starts_ver == ed.buffer.version && len(ed.line_starts) > 0 do return
	clear(&ed.line_starts)
	clear(&ed.line_widths)
	append(&ed.line_starts, 0)
	gb := &ed.buffer
	tab := g_config.editor.tab_size
	cols := 0
	for b, i in gb.data[:gb.gap_start] {
		switch b {
		case '\n':
			append(&ed.line_widths, cols)
			append(&ed.line_starts, i + 1)
			cols = 0
		case '\t':
			cols += tab - (cols % tab)
		case:
			if (b & 0xC0) != 0x80 do cols += 1
		}
	}
	for b, i in gb.data[gb.gap_end:] {
		pos := gb.gap_start + i
		switch b {
		case '\n':
			append(&ed.line_widths, cols)
			append(&ed.line_starts, pos + 1)
			cols = 0
		case '\t':
			cols += tab - (cols % tab)
		case:
			if (b & 0xC0) != 0x80 do cols += 1
		}
	}
	append(&ed.line_widths, cols) // last line (possibly empty)
	ed.line_starts_ver = ed.buffer.version
}

// Walks the bytes of line `line_idx` and returns its column width, honoring
// tab stops and skipping UTF-8 continuation bytes. Lines are typically short,
// so the per-byte branch in gap_buffer_byte_at is a non-issue here.
@(private="file")
compute_line_width_for :: proc(ed: ^Editor, line_idx: int) -> int {
	start := ed.line_starts[line_idx]
	end: int
	if line_idx + 1 < len(ed.line_starts) {
		end = ed.line_starts[line_idx + 1] - 1
	} else {
		end = gap_buffer_len(&ed.buffer)
	}
	tab := g_config.editor.tab_size
	cols := 0
	for i in start ..< end {
		b := gap_buffer_byte_at(&ed.buffer, i)
		if b == '\t' {
			cols += tab - (cols % tab)
		} else if (b & 0xC0) != 0x80 {
			cols += 1
		}
	}
	return cols
}

@(private="file")
bisect_first_gt :: proc(line_starts: []int, value: int) -> int {
	lo, hi := 0, len(line_starts)
	for lo < hi {
		mid := (lo + hi) / 2
		if line_starts[mid] > value do hi = mid
		else                        do lo = mid + 1
	}
	return lo
}

// Buffer-mutating wrappers that keep the line_starts / line_widths caches in
// sync via incremental updates rather than invalidate-and-rebuild. All edits
// that go through the editor's typical paths (typing, deleting, paste, undo,
// redo) should use these. Bulk paths (file load, editor_set_text) bypass them
// and rely on the lazy full rebuild in ensure_line_starts.
editor_buffer_insert :: proc(ed: ^Editor, pos: int, bytes: []u8) {
	if len(bytes) == 0 do return
	caches_valid := ed.line_starts_ver == ed.buffer.version && len(ed.line_starts) > 0
	gap_buffer_insert(&ed.buffer, pos, bytes)
	if !caches_valid do return

	bytes_len := len(bytes)
	line_idx := bisect_first_gt(ed.line_starts[:], pos) - 1
	if line_idx < 0 do line_idx = 0

	nl_count := 0
	for b in bytes do if b == '\n' do nl_count += 1

	old_len := len(ed.line_starts)
	if nl_count == 0 {
		for i := line_idx + 1; i < old_len; i += 1 {
			ed.line_starts[i] += bytes_len
		}
		ed.line_widths[line_idx] = compute_line_width_for(ed, line_idx)
	} else {
		resize(&ed.line_starts, old_len + nl_count)
		resize(&ed.line_widths, old_len + nl_count)
		// Shift trailing entries to make room for the inserted line starts.
		// Walk from the end so we don't clobber unread source slots.
		for i := old_len - 1; i > line_idx; i -= 1 {
			ed.line_starts[i + nl_count] = ed.line_starts[i] + bytes_len
			ed.line_widths[i + nl_count] = ed.line_widths[i]
		}
		slot := line_idx + 1
		for j in 0 ..< bytes_len {
			if bytes[j] == '\n' {
				ed.line_starts[slot] = pos + j + 1
				slot += 1
			}
		}
		for i := line_idx; i <= line_idx + nl_count; i += 1 {
			ed.line_widths[i] = compute_line_width_for(ed, i)
		}
	}

	ed.line_starts_ver = ed.buffer.version
}

editor_buffer_delete :: proc(ed: ^Editor, pos: int, count: int) {
	if count <= 0 do return
	caches_valid := ed.line_starts_ver == ed.buffer.version && len(ed.line_starts) > 0
	gap_buffer_delete(&ed.buffer, pos, count)
	if !caches_valid do return

	n := len(ed.line_starts)
	first_remove := bisect_first_gt(ed.line_starts[:], pos)
	last_remove_excl := bisect_first_gt(ed.line_starts[:], pos + count)
	removed := last_remove_excl - first_remove

	for i := last_remove_excl; i < n; i += 1 {
		new_idx := i - removed
		ed.line_starts[new_idx] = ed.line_starts[i] - count
		ed.line_widths[new_idx] = ed.line_widths[i]
	}
	resize(&ed.line_starts, n - removed)
	resize(&ed.line_widths, n - removed)

	surviving := first_remove - 1
	if surviving < 0 do surviving = 0
	if surviving < len(ed.line_widths) {
		ed.line_widths[surviving] = compute_line_width_for(ed, surviving)
	}

	ed.line_starts_ver = ed.buffer.version
}

editor_pos_to_line_col :: proc(ed: ^Editor, pos: int) -> (line, col: int) {
	ensure_line_starts(ed)
	// Binary search for the largest index whose offset is <= pos.
	lo, hi := 0, len(ed.line_starts)
	for lo < hi {
		mid := (lo + hi) / 2
		if ed.line_starts[mid] <= pos do lo = mid + 1
		else                          do hi = mid
	}
	line = lo - 1
	if line < 0 do line = 0
	for i := ed.line_starts[line]; i < pos; {
		b := gap_buffer_byte_at(&ed.buffer, i)
		switch b {
		case '\n': return
		case '\t':
			col += g_config.editor.tab_size - (col % g_config.editor.tab_size)
			i += 1
		case:
			col += 1
			i += utf8_lead_size(b)
		}
	}
	return
}

editor_line_start :: proc(ed: ^Editor, pos: int) -> int {
	for i := pos - 1; i >= 0; i -= 1 {
		if gap_buffer_byte_at(&ed.buffer, i) == '\n' do return i + 1
	}
	return 0
}

editor_line_end :: proc(ed: ^Editor, pos: int) -> int {
	n := gap_buffer_len(&ed.buffer)
	for i := pos; i < n; i += 1 {
		if gap_buffer_byte_at(&ed.buffer, i) == '\n' do return i
	}
	return n
}

editor_advance_to_col :: proc(ed: ^Editor, start: int, target_col: int) -> int {
	n := gap_buffer_len(&ed.buffer)
	i := start
	col := 0
	for i < n && col < target_col {
		b := gap_buffer_byte_at(&ed.buffer, i)
		if b == '\n' do break
		if b == '\t' {
			advance := g_config.editor.tab_size - (col % g_config.editor.tab_size)
			if col + advance > target_col do break
			col += advance
			i += 1
		} else {
			col += 1
			i += utf8_lead_size(b)
		}
	}
	return i
}

editor_total_lines :: proc(ed: ^Editor) -> int {
	ensure_line_starts(ed)
	return len(ed.line_starts)
}

editor_max_line_cols :: proc(ed: ^Editor) -> int {
	if ed.cached_max_cols_ver == ed.buffer.version do return ed.cached_max_cols
	ensure_line_starts(ed)
	max_cols := 0
	for w in ed.line_widths do max_cols = max(max_cols, w)
	ed.cached_max_cols = max_cols
	ed.cached_max_cols_ver = ed.buffer.version
	return max_cols
}

editor_nth_line_start :: proc(ed: ^Editor, n: int) -> int {
	if n <= 0 do return 0
	ensure_line_starts(ed)
	if n >= len(ed.line_starts) do return gap_buffer_len(&ed.buffer)
	return ed.line_starts[n]
}

editor_pos_at_line_col :: proc(ed: ^Editor, line, col: int) -> int {
	start := editor_nth_line_start(ed, line)
	return editor_advance_to_col(ed, start, col)
}

// Apply a buffer insert at cursor and record it in the undo log.
@(private="file")
do_insert :: proc(ed: ^Editor, bytes: []u8) {
	pos := ed.cursor
	editor_buffer_insert(ed, pos, bytes)
	new_cursor := pos + len(bytes)
	record_insert(ed, pos, bytes, new_cursor, new_cursor)
	ed.cursor = new_cursor
	ed.anchor = new_cursor
	ed.dirty = true
}

// Apply a buffer delete and record it. Caller passes new_cursor (and we mirror
// it in anchor) — both backspace (cursor moves back) and forward-delete (cursor
// stays at deletion start) flow through here.
@(private="file")
do_delete_range :: proc(ed: ^Editor, pos, count: int, new_cursor: int) {
	if count <= 0 do return
	bytes := make([]u8, count, context.temp_allocator)
	for i in 0 ..< count {
		bytes[i] = gap_buffer_byte_at(&ed.buffer, pos + i)
	}
	editor_buffer_delete(ed, pos, count)
	record_delete(ed, pos, bytes, new_cursor, new_cursor)
	ed.cursor = new_cursor
	ed.anchor = new_cursor
	ed.dirty = true
}

@(private="file")
do_delete_selection :: proc(ed: ^Editor) -> bool {
	if !editor_has_selection(ed) do return false
	lo, hi := editor_selection_range(ed)
	do_delete_range(ed, lo, hi - lo, lo)
	return true
}

// Open-bracket → matching close-bracket. Returns 0 for unpaired runes.
@(private="file")
auto_close_pair :: proc(r: rune) -> rune {
	switch r {
	case '(': return ')'
	case '[': return ']'
	case '{': return '}'
	case '"': return '"'
	case '\'': return '\''
	}
	return 0
}

@(private="file")
is_close_bracket :: proc(r: rune) -> bool {
	switch r {
	case ')', ']', '}', '"', '\'': return true
	}
	return false
}

@(private="file")
is_word_byte :: proc(b: u8) -> bool {
	return (b >= 'a' && b <= 'z') || (b >= 'A' && b <= 'Z') || (b >= '0' && b <= '9') || b == '_'
}

// Decide whether to auto-insert the closing pair after typing `r`.
// Quotes (' ") get extra checks so contractions ("don't") and word-adjacent
// quotes don't get spurious closing chars.
@(private="file")
should_auto_close :: proc(ed: ^Editor, r: rune) -> bool {
	pair := auto_close_pair(r)
	if pair == 0 do return false

	// Symmetric pairs (' " — open == close): skip if surrounded by word chars.
	if r == pair {
		if ed.cursor > 0 {
			prev := gap_buffer_byte_at(&ed.buffer, ed.cursor - 1)
			if is_word_byte(prev) do return false
		}
		n := gap_buffer_len(&ed.buffer)
		if ed.cursor < n {
			next := gap_buffer_byte_at(&ed.buffer, ed.cursor)
			if is_word_byte(next) do return false
		}
	}
	return true
}

editor_insert_rune :: proc(ed: ^Editor, r: rune) {
	if ed.pending_kind != .Inserting do commit_pending(ed)

	// Over-type: if the next char is the same close bracket, just step over it
	// (so typing `)` after a previously auto-inserted `)` doesn't double up).
	if is_close_bracket(r) && !editor_has_selection(ed) {
		n := gap_buffer_len(&ed.buffer)
		if ed.cursor < n && rune(gap_buffer_byte_at(&ed.buffer, ed.cursor)) == r {
			ed.cursor += 1
			ed.anchor = ed.cursor
			ed.pending_kind = .Inserting
			_, ed.desired_col = editor_pos_to_line_col(ed, ed.cursor)
			ed.blink_timer = 0
			return
		}
	}

	do_delete_selection(ed)

	buf, n := utf8.encode_rune(r)
	do_insert(ed, buf[:n])
	ed.pending_kind = .Inserting

	// Auto-close: insert the matching closing rune and step the caret back
	// between them.
	if should_auto_close(ed, r) {
		pair := auto_close_pair(r)
		pbuf, pn := utf8.encode_rune(pair)
		do_insert(ed, pbuf[:pn])
		ed.cursor -= pn
		ed.anchor = ed.cursor
		// Fix up the merged undo op so redo lands the caret between the pair
		// rather than past the close.
		if len(ed.pending.ops) > 0 {
			last := &ed.pending.ops[len(ed.pending.ops) - 1]
			last.cursor_after = ed.cursor
			last.anchor_after = ed.anchor
		}
	}

	_, ed.desired_col = editor_pos_to_line_col(ed, ed.cursor)
	ed.blink_timer = 0
}

@(private="file")
matches_bracket_pair :: proc(open_b, close_b: u8) -> bool {
	return (open_b == '{' && close_b == '}') ||
	       (open_b == '[' && close_b == ']') ||
	       (open_b == '(' && close_b == ')')
}

// Insert "\n" + the leading whitespace of the current line, preserving indent.
// If the caret is sitting between matching brackets (e.g. `{|}`), open up to
// three lines: the close drops to its own line at the original indent, and a
// new caret line is inserted in between with one extra indent level.
editor_smart_newline :: proc(ed: ^Editor) {
	line_start := editor_line_start(ed, ed.cursor)
	end := ed.cursor
	n := gap_buffer_len(&ed.buffer)

	// Capture the current line's leading whitespace (only the part before the caret).
	ws_end := line_start
	for ws_end < end && ws_end < n {
		b := gap_buffer_byte_at(&ed.buffer, ws_end)
		if b != ' ' && b != '\t' do break
		ws_end += 1
	}
	ws := make([]u8, ws_end - line_start, context.temp_allocator)
	for i in 0 ..< len(ws) do ws[i] = gap_buffer_byte_at(&ed.buffer, line_start + i)

	// Detect cursor between bracket pair (e.g. {|}, [|], (|)).
	between_pair := false
	if ed.cursor > 0 && ed.cursor < n {
		prev := gap_buffer_byte_at(&ed.buffer, ed.cursor - 1)
		next := gap_buffer_byte_at(&ed.buffer, ed.cursor)
		between_pair = matches_bracket_pair(prev, next)
	}

	// Use a tab for the extra indent if existing indent uses tabs; otherwise spaces.
	indent_uses_tabs := false
	for b in ws {
		if b == '\t' { indent_uses_tabs = true; break }
	}

	if between_pair {
		// First, build the indented middle line.
		editor_insert_rune(ed, '\n')
		for b in ws do editor_insert_rune(ed, rune(b))
		if indent_uses_tabs {
			editor_insert_rune(ed, '\t')
		} else {
			for _ in 0 ..< g_config.editor.tab_size do editor_insert_rune(ed, ' ')
		}

		// Caret should land here, on the indented line.
		saved_cursor := ed.cursor

		// Drop the close bracket to its own line.
		editor_insert_rune(ed, '\n')
		for b in ws do editor_insert_rune(ed, rune(b))

		// Restore caret to the indented line and patch the undo op so redo lands here too.
		ed.cursor = saved_cursor
		ed.anchor = saved_cursor
		if len(ed.pending.ops) > 0 {
			last := &ed.pending.ops[len(ed.pending.ops) - 1]
			last.cursor_after = saved_cursor
			last.anchor_after = saved_cursor
		}
		_, ed.desired_col = editor_pos_to_line_col(ed, ed.cursor)
		ed.blink_timer = 0
		return
	}

	// Plain preserve-indent.
	editor_insert_rune(ed, '\n')
	for b in ws do editor_insert_rune(ed, rune(b))
}

// Atomic multi-byte insert (paste). Always its own undo group.
editor_insert_string :: proc(ed: ^Editor, s: string) {
	commit_pending(ed)
	do_delete_selection(ed)
	if len(s) > 0 do do_insert(ed, transmute([]u8)s)
	commit_pending(ed)
	_, ed.desired_col = editor_pos_to_line_col(ed, ed.cursor)
	ed.blink_timer = 0
}

editor_backspace :: proc(ed: ^Editor) {
	if editor_has_selection(ed) {
		commit_pending(ed)
		do_delete_selection(ed)
		commit_pending(ed)
		_, ed.desired_col = editor_pos_to_line_col(ed, ed.cursor)
		ed.blink_timer = 0
		return
	}
	if ed.pending_kind != .Deleting do commit_pending(ed)
	if ed.cursor == 0 do return
	prev := editor_step_back(ed, ed.cursor)
	do_delete_range(ed, prev, ed.cursor - prev, prev)
	ed.pending_kind = .Deleting
	_, ed.desired_col = editor_pos_to_line_col(ed, ed.cursor)
	ed.blink_timer = 0
}

editor_delete_forward :: proc(ed: ^Editor) {
	if editor_has_selection(ed) {
		commit_pending(ed)
		do_delete_selection(ed)
		commit_pending(ed)
		_, ed.desired_col = editor_pos_to_line_col(ed, ed.cursor)
		ed.blink_timer = 0
		return
	}
	if ed.pending_kind != .Deleting do commit_pending(ed)
	n := gap_buffer_len(&ed.buffer)
	if ed.cursor >= n do return
	next := editor_step_forward(ed, ed.cursor)
	do_delete_range(ed, ed.cursor, next - ed.cursor, ed.cursor)
	ed.pending_kind = .Deleting
	_, ed.desired_col = editor_pos_to_line_col(ed, ed.cursor)
	ed.blink_timer = 0
}

@(private="file")
finish_move :: proc(ed: ^Editor, extend: bool, update_desired_col: bool = true) {
	commit_pending(ed)
	if !extend do ed.anchor = ed.cursor
	if update_desired_col {
		_, ed.desired_col = editor_pos_to_line_col(ed, ed.cursor)
	}
	ed.blink_timer = 0
}

editor_move_left :: proc(ed: ^Editor, extend: bool) {
	if !extend && editor_has_selection(ed) {
		lo, _ := editor_selection_range(ed)
		ed.cursor = lo
	} else {
		ed.cursor = editor_step_back(ed, ed.cursor)
	}
	finish_move(ed, extend)
}

editor_move_right :: proc(ed: ^Editor, extend: bool) {
	if !extend && editor_has_selection(ed) {
		_, hi := editor_selection_range(ed)
		ed.cursor = hi
	} else {
		ed.cursor = editor_step_forward(ed, ed.cursor)
	}
	finish_move(ed, extend)
}

editor_move_up :: proc(ed: ^Editor, extend: bool) {
	line, _ := editor_pos_to_line_col(ed, ed.cursor)
	if line == 0 {
		ed.cursor = 0
	} else {
		cur_line_start := editor_line_start(ed, ed.cursor)
		prev_line_start := editor_line_start(ed, cur_line_start - 1)
		ed.cursor = editor_advance_to_col(ed, prev_line_start, ed.desired_col)
	}
	finish_move(ed, extend, update_desired_col = false)
}

editor_move_down :: proc(ed: ^Editor, extend: bool) {
	cur_line_end := editor_line_end(ed, ed.cursor)
	n := gap_buffer_len(&ed.buffer)
	if cur_line_end >= n {
		ed.cursor = n
	} else {
		next_line_start := cur_line_end + 1
		ed.cursor = editor_advance_to_col(ed, next_line_start, ed.desired_col)
	}
	finish_move(ed, extend, update_desired_col = false)
}

editor_move_home :: proc(ed: ^Editor, extend: bool) {
	ed.cursor = editor_line_start(ed, ed.cursor)
	finish_move(ed, extend)
}

editor_move_end :: proc(ed: ^Editor, extend: bool) {
	ed.cursor = editor_line_end(ed, ed.cursor)
	finish_move(ed, extend)
}

// Soft tabs: insert spaces up to the next tab stop. Tab at col 5 with size 4
// inserts 3 spaces (to reach col 8), not 4.
editor_insert_soft_tab :: proc(ed: ^Editor) {
	tab_size := g_config.editor.tab_size
	_, col := editor_pos_to_line_col(ed, ed.cursor)
	spaces := tab_size - (col % tab_size)
	for _ in 0 ..< spaces do editor_insert_rune(ed, ' ')
}

// ──────────────────────────────────────────────────────────────────
// Search (literal substring; vim-style /, ?, n, N)
// ──────────────────────────────────────────────────────────────────

// ASCII tolower. Used by case-insensitive search; sufficient for the
// literal-substring matcher we have today (no Unicode case folding).
@(private="file")
ascii_tolower :: proc(b: u8) -> u8 {
	if b >= 'A' && b <= 'Z' do return b + 32
	return b
}

// Effective ignore-case for `pattern` given the current force override and
// global ignorecase / smartcase settings. Vim's smartcase rule: only ignore
// case when no uppercase appears in the pattern.
editor_pattern_ignore_case :: proc(pattern: string, force: i8) -> bool {
	switch force {
	case  1: return true
	case -1: return false
	}
	if !g_config.editor.ignorecase do return false
	if g_config.editor.smartcase {
		for i in 0 ..< len(pattern) {
			b := pattern[i]
			if b >= 'A' && b <= 'Z' do return false
		}
	}
	return true
}

@(private="file")
match_at :: proc(ed: ^Editor, pos: int, needle: []u8, ignore_case: bool) -> bool {
	for j in 0 ..< len(needle) {
		a := gap_buffer_byte_at(&ed.buffer, pos + j)
		b := needle[j]
		if ignore_case {
			if ascii_tolower(a) != ascii_tolower(b) do return false
		} else {
			if a != b do return false
		}
	}
	return true
}

// Find first occurrence of `needle` at or after `start`, in [start, end).
@(private="file")
find_in_range :: proc(ed: ^Editor, needle: []u8, start, end: int, ignore_case: bool) -> int {
	if len(needle) == 0 do return -1
	last := end - len(needle)
	for i in start ..= last {
		if match_at(ed, i, needle, ignore_case) do return i
	}
	return -1
}

// Find last occurrence of `needle` strictly before `before`, scanning backward.
@(private="file")
find_in_range_backward :: proc(ed: ^Editor, needle: []u8, before: int, ignore_case: bool) -> int {
	if len(needle) == 0 do return -1
	for i := before - len(needle); i >= 0; i -= 1 {
		if match_at(ed, i, needle, ignore_case) do return i
	}
	return -1
}

// Rebuilds the cached list of match positions for `pattern` if buffer,
// pattern, or effective case-mode changed since the last scan. Caller is
// responsible for not asking when pattern is empty.
@(private="file")
ensure_search_matches :: proc(ed: ^Editor, pattern: string) {
	ic := editor_pattern_ignore_case(pattern, ed.search_force_case)
	if ed.search_match_ver == ed.buffer.version &&
	   ed.search_match_pattern == pattern &&
	   ed.search_match_ignore_case == ic {
		return
	}
	clear(&ed.search_match_positions)
	needle := transmute([]u8)pattern
	n := gap_buffer_len(&ed.buffer)
	last := n - len(needle)
	if last >= 0 {
		for i in 0 ..= last {
			if match_at(ed, i, needle, ic) do append(&ed.search_match_positions, i)
		}
	}
	if ed.search_match_pattern != pattern {
		if len(ed.search_match_pattern) > 0 do delete(ed.search_match_pattern)
		ed.search_match_pattern = strings.clone(pattern)
	}
	ed.search_match_ver = ed.buffer.version
	ed.search_match_ignore_case = ic
}

// Returns total occurrences of `pattern` in the buffer and the 1-based index
// of the match at ed.cursor — but only if the cursor sits exactly on a match
// (i.e. the user just searched or pressed n/N). Otherwise current = 0, which
// callers use to suppress the [n/m] readout once the user wanders off.
editor_search_stats :: proc(ed: ^Editor, pattern: string) -> (current, total: int) {
	if len(pattern) == 0 do return
	ensure_search_matches(ed, pattern)
	total = len(ed.search_match_positions)
	if total == 0 do return
	// Binary search for cursor among the match positions.
	lo, hi := 0, total
	for lo < hi {
		mid := (lo + hi) / 2
		if ed.search_match_positions[mid] < ed.cursor do lo = mid + 1
		else                                          do hi = mid
	}
	if lo < total && ed.search_match_positions[lo] == ed.cursor {
		current = lo + 1
	}
	return
}

// Find next match (or previous, if !forward), wrapping around the buffer.
// On hit, sets cursor to match start and anchor to match end so the match
// shows up via the existing selection rendering. Returns true on success.
editor_find_next :: proc(ed: ^Editor, pattern: string, forward: bool) -> bool {
	needle := transmute([]u8)pattern
	if len(needle) == 0 do return false
	n := gap_buffer_len(&ed.buffer)
	ic := editor_pattern_ignore_case(pattern, ed.search_force_case)

	idx: int
	if forward {
		// Search after the *current* match end (so n doesn't re-find current).
		from := ed.cursor + 1
		if from > n do from = n
		idx = find_in_range(ed, needle, from, n, ic)
		if idx < 0 do idx = find_in_range(ed, needle, 0, n, ic) // wrap
	} else {
		idx = find_in_range_backward(ed, needle, ed.cursor, ic)
		if idx < 0 do idx = find_in_range_backward(ed, needle, n, ic) // wrap
	}
	if idx < 0 do return false

	commit_pending(ed)
	ed.cursor = idx
	ed.anchor = idx + len(needle)
	_, ed.desired_col = editor_pos_to_line_col(ed, ed.cursor)
	ed.blink_timer = 0
	return true
}

editor_select_all :: proc(ed: ^Editor) {
	commit_pending(ed)
	ed.anchor = 0
	ed.cursor = gap_buffer_len(&ed.buffer)
	_, ed.desired_col = editor_pos_to_line_col(ed, ed.cursor)
	ed.blink_timer = 0
}

editor_selection_text :: proc(ed: ^Editor, allocator := context.allocator) -> string {
	lo, hi := editor_selection_range(ed)
	n := hi - lo
	if n == 0 do return ""
	out := make([]u8, n, allocator)
	for i in 0 ..< n {
		out[i] = gap_buffer_byte_at(&ed.buffer, lo + i)
	}
	return string(out)
}
