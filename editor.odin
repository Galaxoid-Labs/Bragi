package bragi

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
}

editor_make :: proc() -> Editor {
	return Editor{buffer = gap_buffer_make()}
}

editor_destroy :: proc(ed: ^Editor) {
	gap_buffer_destroy(&ed.buffer)
	undo_group_destroy(&ed.pending)
	undo_stack_destroy(&ed.undo_stack)
	undo_stack_destroy(&ed.redo_stack)
	if len(ed.file_path) > 0      do delete(ed.file_path)
	if len(ed.search_pattern) > 0 do delete(ed.search_pattern)
	delete(ed.cmd_buffer)
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

editor_pos_to_line_col :: proc(ed: ^Editor, pos: int) -> (line, col: int) {
	i := 0
	for i < pos {
		b := gap_buffer_byte_at(&ed.buffer, i)
		switch b {
		case '\n':
			line += 1
			col = 0
			i += 1
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
	count := 1
	n := gap_buffer_len(&ed.buffer)
	for i in 0 ..< n {
		if gap_buffer_byte_at(&ed.buffer, i) == '\n' do count += 1
	}
	return count
}

editor_max_line_cols :: proc(ed: ^Editor) -> int {
	if ed.cached_max_cols_ver == ed.buffer.version do return ed.cached_max_cols
	n := gap_buffer_len(&ed.buffer)
	max_cols := 0
	cols := 0
	i := 0
	for i < n {
		b := gap_buffer_byte_at(&ed.buffer, i)
		switch b {
		case '\n':
			if cols > max_cols do max_cols = cols
			cols = 0
			i += 1
		case '\t':
			cols += g_config.editor.tab_size - (cols % g_config.editor.tab_size)
			i += 1
		case:
			cols += 1
			i += utf8_lead_size(b)
		}
	}
	if cols > max_cols do max_cols = cols
	ed.cached_max_cols = max_cols
	ed.cached_max_cols_ver = ed.buffer.version
	return max_cols
}

editor_nth_line_start :: proc(ed: ^Editor, n: int) -> int {
	if n <= 0 do return 0
	line := 0
	total := gap_buffer_len(&ed.buffer)
	for i in 0 ..< total {
		if gap_buffer_byte_at(&ed.buffer, i) == '\n' {
			line += 1
			if line == n do return i + 1
		}
	}
	return total
}

editor_pos_at_line_col :: proc(ed: ^Editor, line, col: int) -> int {
	start := editor_nth_line_start(ed, line)
	return editor_advance_to_col(ed, start, col)
}

// Apply a buffer insert at cursor and record it in the undo log.
@(private="file")
do_insert :: proc(ed: ^Editor, bytes: []u8) {
	pos := ed.cursor
	gap_buffer_insert(&ed.buffer, pos, bytes)
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
	gap_buffer_delete(&ed.buffer, pos, count)
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

@(private="file")
match_at :: proc(ed: ^Editor, pos: int, needle: []u8) -> bool {
	for j in 0 ..< len(needle) {
		if gap_buffer_byte_at(&ed.buffer, pos + j) != needle[j] do return false
	}
	return true
}

// Find first occurrence of `needle` at or after `start`, in [start, end).
@(private="file")
find_in_range :: proc(ed: ^Editor, needle: []u8, start, end: int) -> int {
	if len(needle) == 0 do return -1
	last := end - len(needle)
	for i in start ..= last {
		if match_at(ed, i, needle) do return i
	}
	return -1
}

// Find last occurrence of `needle` strictly before `before`, scanning backward.
@(private="file")
find_in_range_backward :: proc(ed: ^Editor, needle: []u8, before: int) -> int {
	if len(needle) == 0 do return -1
	for i := before - len(needle); i >= 0; i -= 1 {
		if match_at(ed, i, needle) do return i
	}
	return -1
}

// Returns total occurrences of `pattern` in the buffer and the 1-based index
// of the match at ed.cursor — but only if the cursor sits exactly on a match
// (i.e. the user just searched or pressed n/N). Otherwise current = 0, which
// callers use to suppress the [n/m] readout once the user wanders off.
editor_search_stats :: proc(ed: ^Editor, pattern: string) -> (current, total: int) {
	needle := transmute([]u8)pattern
	if len(needle) == 0 do return
	n := gap_buffer_len(&ed.buffer)
	last := n - len(needle)
	if last < 0 do return
	for i in 0 ..= last {
		if match_at(ed, i, needle) {
			total += 1
			if i == ed.cursor do current = total
		}
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

	idx: int
	if forward {
		// Search after the *current* match end (so n doesn't re-find current).
		from := ed.cursor + 1
		if from > n do from = n
		idx = find_in_range(ed, needle, from, n)
		if idx < 0 do idx = find_in_range(ed, needle, 0, n) // wrap
	} else {
		idx = find_in_range_backward(ed, needle, ed.cursor)
		if idx < 0 do idx = find_in_range_backward(ed, needle, n) // wrap
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
