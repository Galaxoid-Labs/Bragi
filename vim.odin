package bragi

import "core:strconv"
import "core:strings"
import sdl "vendor:sdl3"

Mode :: enum { Insert, Normal, Command, Search, Visual, Visual_Line }

Vim_Operator :: enum { None, Delete, Change, Yank }
Vim_Prefix   :: enum { None, G, Z, Indent, Outdent }

vim_in_visual :: proc(ed: ^Editor) -> bool {
	return ed.mode == .Visual || ed.mode == .Visual_Line
}

vim_reset_state :: proc(ed: ^Editor) {
	ed.vim_count = 0
	ed.vim_op = .None
	ed.vim_op_count = 0
	ed.vim_prefix = .None
}

vim_enter_insert :: proc(ed: ^Editor) {
	ed.mode = .Insert
	vim_reset_state(ed)
}

vim_enter_normal :: proc(ed: ^Editor) {
	commit_pending(ed)
	// Exiting visual collapses the selection so the regular caret returns.
	if vim_in_visual(ed) do ed.anchor = ed.cursor
	ed.mode = .Normal
	vim_reset_state(ed)
}

vim_enter_visual :: proc(ed: ^Editor) {
	commit_pending(ed)
	ed.mode = .Visual
	ed.anchor = ed.cursor
	vim_reset_state(ed)
}

vim_enter_visual_line :: proc(ed: ^Editor) {
	commit_pending(ed)
	ed.mode = .Visual_Line
	ed.anchor = ed.cursor
	vim_reset_state(ed)
}

// The selection range as the user sees it. In Visual it's inclusive of the
// cursor's rune (so just-entered visual mode highlights one char); in
// Visual_Line it expands to full lines including the trailing newline.
// In every other mode it falls through to the plain cursor/anchor range.
visible_selection_range :: proc(ed: ^Editor) -> (lo, hi: int) {
	lo, hi = editor_selection_range(ed)
	n := gap_buffer_len(&ed.buffer)
	switch ed.mode {
	case .Visual:
		if hi == lo && lo < n {
			hi = lo + utf8_lead_size(gap_buffer_byte_at(&ed.buffer, lo))
		} else if hi < n {
			hi += utf8_lead_size(gap_buffer_byte_at(&ed.buffer, hi))
		}
	case .Visual_Line:
		lo = editor_line_start(ed, lo)
		hi = editor_line_end(ed, hi)
		if hi < n do hi += 1
	case .Insert, .Normal, .Command, .Search:
	}
	return
}

// Character classes for word motions. Vim distinguishes word chars (\w),
// punctuation, and whitespace — `w` stops at transitions between any two
// non-whitespace classes.
Vim_Char_Class :: enum { Space, Word, Punct }

vim_is_word_char :: proc(c: u8) -> bool {
	return (c >= 'a' && c <= 'z') ||
	       (c >= 'A' && c <= 'Z') ||
	       (c >= '0' && c <= '9') ||
	       c == '_'
}

vim_is_space :: proc(c: u8) -> bool {
	return c == ' ' || c == '\t' || c == '\n'
}

vim_classify :: proc(c: u8) -> Vim_Char_Class {
	if vim_is_space(c)    do return .Space
	if vim_is_word_char(c) do return .Word
	return .Punct
}

vim_word_forward :: proc(ed: ^Editor) {
	n := gap_buffer_len(&ed.buffer)
	if ed.cursor >= n do return
	start_class := vim_classify(gap_buffer_byte_at(&ed.buffer, ed.cursor))
	if start_class != .Space {
		for ed.cursor < n && vim_classify(gap_buffer_byte_at(&ed.buffer, ed.cursor)) == start_class {
			ed.cursor += 1
		}
	}
	for ed.cursor < n && vim_classify(gap_buffer_byte_at(&ed.buffer, ed.cursor)) == .Space {
		ed.cursor += 1
	}
	ed.anchor = ed.cursor
	_, ed.desired_col = editor_pos_to_line_col(ed, ed.cursor)
}

vim_word_backward :: proc(ed: ^Editor) {
	if ed.cursor == 0 do return
	ed.cursor -= 1
	for ed.cursor > 0 && vim_classify(gap_buffer_byte_at(&ed.buffer, ed.cursor)) == .Space {
		ed.cursor -= 1
	}
	cls := vim_classify(gap_buffer_byte_at(&ed.buffer, ed.cursor))
	for ed.cursor > 0 && vim_classify(gap_buffer_byte_at(&ed.buffer, ed.cursor - 1)) == cls {
		ed.cursor -= 1
	}
	ed.anchor = ed.cursor
	_, ed.desired_col = editor_pos_to_line_col(ed, ed.cursor)
}

vim_word_end :: proc(ed: ^Editor) {
	n := gap_buffer_len(&ed.buffer)
	if ed.cursor >= n - 1 do return
	ed.cursor += 1
	for ed.cursor < n && vim_classify(gap_buffer_byte_at(&ed.buffer, ed.cursor)) == .Space {
		ed.cursor += 1
	}
	if ed.cursor >= n do return
	cls := vim_classify(gap_buffer_byte_at(&ed.buffer, ed.cursor))
	for ed.cursor + 1 < n && vim_classify(gap_buffer_byte_at(&ed.buffer, ed.cursor + 1)) == cls {
		ed.cursor += 1
	}
	ed.anchor = ed.cursor
	_, ed.desired_col = editor_pos_to_line_col(ed, ed.cursor)
}

vim_first_nonblank :: proc(ed: ^Editor) {
	line_start := editor_line_start(ed, ed.cursor)
	n := gap_buffer_len(&ed.buffer)
	i := line_start
	for i < n {
		b := gap_buffer_byte_at(&ed.buffer, i)
		if b != ' ' && b != '\t' && b != '\n' do break
		i += 1
	}
	ed.cursor = i
	ed.anchor = i
	_, ed.desired_col = editor_pos_to_line_col(ed, ed.cursor)
}

vim_goto_line :: proc(ed: ^Editor, line_idx: int) {
	target := editor_nth_line_start(ed, max(0, line_idx))
	ed.cursor = target
	ed.anchor = target
	_, ed.desired_col = editor_pos_to_line_col(ed, ed.cursor)
}

vim_goto_last_line :: proc(ed: ^Editor) {
	total := editor_total_lines(ed)
	vim_goto_line(ed, total - 1)
}

vim_apply_motion :: proc(ed: ^Editor, motion: rune, count: int) {
	// In Visual modes we extend the selection; without `extend=true`, the
	// editor's "collapse selection on right-arrow" behavior would stop
	// the cursor at the existing selection edge instead of advancing.
	extend := vim_in_visual(ed)
	for _ in 0 ..< count {
		switch motion {
		case 'h': vim_move_left_in_line(ed, extend)
		case 'l': vim_move_right_in_line(ed, extend)
		case 'j': editor_move_down(ed, extend)
		case 'k': editor_move_up(ed, extend)
		case 'w': vim_word_forward(ed)
		case 'b': vim_word_backward(ed)
		case 'e': vim_word_end(ed)
		case '0': editor_move_home(ed, extend)
		case '$': editor_move_end(ed, extend)
		case '^': vim_first_nonblank(ed)
		}
	}
}

// Apply an operator to the byte range [lo, hi). Yank copies; Delete/Change remove
// (Change additionally enters Insert mode).
vim_apply_op_range :: proc(ed: ^Editor, op: Vim_Operator, lo, hi: int) {
	if hi <= lo do return

	n := hi - lo
	bytes := make([]u8, n, context.temp_allocator)
	for i in 0 ..< n {
		bytes[i] = gap_buffer_byte_at(&ed.buffer, lo + i)
	}
	cstr := strings.clone_to_cstring(string(bytes), context.temp_allocator)
	sdl.SetClipboardText(cstr)

	if op == .Yank {
		ed.cursor = lo
		ed.anchor = lo
		_, ed.desired_col = editor_pos_to_line_col(ed, ed.cursor)
		return
	}

	if op == .Delete || op == .Change {
		// Use the selection-aware delete path so undo is recorded atomically.
		ed.cursor = lo
		ed.anchor = hi
		editor_backspace(ed)
	}

	if op == .Change {
		vim_enter_insert(ed)
	}
}

// Apply op from cursor to end of line. Implements D / C / Y vim shortcuts.
vim_op_to_eol :: proc(ed: ^Editor, op: Vim_Operator) {
	commit_pending(ed)
	start := ed.cursor
	editor_move_end(ed, false)
	end := ed.cursor
	if start != end {
		vim_apply_op_range(ed, op, start, end)
	} else if op == .Change {
		vim_enter_insert(ed)
	}
}

vim_op_line :: proc(ed: ^Editor, op: Vim_Operator, count: int) {
	line_start := editor_line_start(ed, ed.cursor)
	end := editor_line_end(ed, ed.cursor)
	n := gap_buffer_len(&ed.buffer)
	for _ in 1 ..< count {
		if end >= n do break
		end += 1
		end = editor_line_end(ed, end)
	}
	if end < n {
		end += 1
	} else if line_start > 0 {
		line_start -= 1
	}
	vim_apply_op_range(ed, op, line_start, end)
}

vim_paste_after :: proc(ed: ^Editor) {
	n := gap_buffer_len(&ed.buffer)
	if ed.cursor < n {
		b := gap_buffer_byte_at(&ed.buffer, ed.cursor)
		if b != '\n' do editor_move_right(ed, false)
	}
	clipboard_paste_into(ed)
}

vim_paste_before :: proc(ed: ^Editor) {
	clipboard_paste_into(ed)
}

@(private="file")
clipboard_paste_into :: proc(ed: ^Editor) {
	raw := sdl.GetClipboardText()
	if raw == nil do return
	defer sdl.free(rawptr(raw))
	editor_insert_string(ed, string(cstring(raw)))
}

// Visual-mode FSM. Operators (`d`/`c`/`y`) act on the visible selection
// immediately and exit visual; motions move the cursor while preserving
// the anchor. `v` / `V` toggle: pressing the same one exits, pressing the
// other switches charwise ↔ linewise.
vim_handle_visual_char :: proc(ed: ^Editor, c: rune) {
	// Count accumulation works the same as in Normal.
	if c >= '1' && c <= '9' {
		ed.vim_count = ed.vim_count * 10 + int(c - '0')
		return
	}
	if c == '0' && ed.vim_count > 0 {
		ed.vim_count = ed.vim_count * 10
		return
	}

	// gg follow-up (preserves anchor).
	if ed.vim_prefix == .G {
		ed.vim_prefix = .None
		if c == 'g' {
			explicit := ed.vim_count
			ed.vim_count = 0
			saved := ed.anchor
			vim_goto_line(ed, explicit > 0 ? explicit - 1 : 0)
			ed.anchor = saved
		} else {
			ed.vim_count = 0
		}
		return
	}

	switch c {
	case 'd':
		lo, hi := visible_selection_range(ed)
		vim_apply_op_range(ed, .Delete, lo, hi)
		vim_enter_normal(ed)
	case 'c':
		lo, hi := visible_selection_range(ed)
		vim_apply_op_range(ed, .Change, lo, hi)
		// vim_apply_op_range enters Insert mode for Change.
	case 'y':
		lo, hi := visible_selection_range(ed)
		vim_apply_op_range(ed, .Yank, lo, hi)
		vim_enter_normal(ed)
	case 'v':
		if ed.mode == .Visual {
			vim_enter_normal(ed)
		} else {
			ed.mode = .Visual
			vim_reset_state(ed)
		}
	case 'V':
		if ed.mode == .Visual_Line {
			vim_enter_normal(ed)
		} else {
			ed.mode = .Visual_Line
			vim_reset_state(ed)
		}
	case 'g':
		ed.vim_prefix = .G
	case '>':
		vim_indent_visual(ed)
		vim_enter_normal(ed)
	case '<':
		vim_outdent_visual(ed)
		vim_enter_normal(ed)
	case '%':
		vim_bracket_match(ed)
	case 'G':
		explicit := ed.vim_count
		ed.vim_count = 0
		saved := ed.anchor
		if explicit > 0 do vim_goto_line(ed, explicit - 1)
		else            do vim_goto_last_line(ed)
		ed.anchor = saved
	case 'h', 'l', 'j', 'k', 'w', 'b', 'e', '0', '$', '^':
		count := max(1, ed.vim_count)
		ed.vim_count = 0
		saved := ed.anchor
		vim_apply_motion(ed, c, count)
		ed.anchor = saved
	}
}

// Returns the active pane's visible-line count (height / line height).
// Used by Ctrl+D/U and zz / zt / zb so they can scroll relative to the
// viewport without taking the layout as a parameter.
@(private="file")
vim_visible_lines :: proc() -> int {
	l := compute_layout()
	if g_active_idx >= len(l.panes) do return 1
	return max(1, int(l.panes[g_active_idx].text_h / g_line_height))
}

// Move cursor by `delta` lines (positive = down) and shift scroll by the
// same amount so the cursor stays in roughly the same screen position.
// Vim's Ctrl+D / Ctrl+U semantics. Preserves anchor in Visual modes.
vim_half_page :: proc(ed: ^Editor, dir: int) {
	half := max(1, vim_visible_lines() / 2) * dir
	saved_anchor := ed.anchor
	cur_line, _ := editor_pos_to_line_col(ed, ed.cursor)
	new_line := clamp(cur_line + half, 0, editor_total_lines(ed) - 1)
	ed.cursor = editor_pos_at_line_col(ed, new_line, ed.desired_col)
	if vim_in_visual(ed) {
		ed.anchor = saved_anchor
	} else {
		ed.anchor = ed.cursor
	}
	ed.scroll_y += f32(half) * g_line_height
}

// Position the cursor's line at the top / middle / bottom of the viewport.
// Vim's zt / zz / zb. `placement` is 0=top, 1=middle, 2=bottom.
vim_scroll_cursor_to :: proc(ed: ^Editor, placement: int) {
	visible := vim_visible_lines()
	cur_line, _ := editor_pos_to_line_col(ed, ed.cursor)
	target_top: int
	switch placement {
	case 0: target_top = cur_line                        // zt
	case 1: target_top = cur_line - visible / 2          // zz
	case 2: target_top = cur_line - visible + 1          // zb
	}
	if target_top < 0 do target_top = 0
	ed.scroll_y = f32(target_top) * g_line_height
}

// Strip vim's `\c` / `\C` modifiers from `pat` and return the cleaned
// pattern plus the implied case-force value (-1 sensitive, 0 unset, +1
// insensitive). The last occurrence wins, matching vim's behavior.
vim_strip_case_modifiers :: proc(pat: string) -> (cleaned: string, force: i8) {
	sb := strings.builder_make(context.temp_allocator)
	i := 0
	for i < len(pat) {
		if i + 1 < len(pat) && pat[i] == '\\' {
			switch pat[i + 1] {
			case 'c':
				force = 1
				i += 2
				continue
			case 'C':
				force = -1
				i += 2
				continue
			}
		}
		strings.write_byte(&sb, pat[i])
		i += 1
	}
	cleaned = strings.to_string(sb)
	return
}

// Substitute (`:s/pat/repl/[gi I]` and `:%s/pat/repl/[gi I]`). Pattern is
// a literal substring (no regex). `g` replaces every match per line; `i`
// forces case-insensitive, `I` forces case-sensitive. `\c` / `\C` inside
// the pattern act the same. Range is the current line for `s`, the whole
// buffer for `%s`. Pattern containing `/` isn't supported.
@(private="file")
vim_parse_subst :: proc(cmd: string) -> (whole_buffer: bool, pat, repl: string, global: bool, force: i8, ok: bool) {
	rest: string
	if strings.has_prefix(cmd, "%s/") {
		whole_buffer = true
		rest = cmd[3:]
	} else if strings.has_prefix(cmd, "s/") {
		rest = cmd[2:]
	} else {
		return
	}

	p1 := strings.index_byte(rest, '/')
	if p1 < 0 do return
	pat = rest[:p1]
	tail := rest[p1 + 1:]

	p2 := strings.index_byte(tail, '/')
	flags: string
	if p2 < 0 {
		repl = tail
	} else {
		repl  = tail[:p2]
		flags = tail[p2 + 1:]
		global = strings.contains(flags, "g")
		// Last of i / I wins; pattern's \c / \C wins over both.
		if strings.contains(flags, "i") do force = 1
		if strings.contains(flags, "I") do force = -1
	}
	// Pattern-level \c / \C overrides flag-level (vim convention).
	cleaned, pat_force := vim_strip_case_modifiers(pat)
	pat = cleaned
	if pat_force != 0 do force = pat_force
	ok = len(pat) > 0
	return
}

@(private="file")
vim_match_here :: proc(ed: ^Editor, pos: int, needle: []u8, ignore_case: bool) -> bool {
	for j in 0 ..< len(needle) {
		a := gap_buffer_byte_at(&ed.buffer, pos + j)
		b := needle[j]
		if ignore_case {
			la := a; lb := b
			if la >= 'A' && la <= 'Z' do la += 32
			if lb >= 'A' && lb <= 'Z' do lb += 32
			if la != lb do return false
		} else {
			if a != b do return false
		}
	}
	return true
}

vim_substitute :: proc(ed: ^Editor, cmd: string) -> bool {
	whole_buffer, pat, repl, global, force, ok := vim_parse_subst(cmd)
	if !ok do return false

	commit_pending(ed)

	needle      := transmute([]u8)pat
	replacement := transmute([]u8)repl
	ic          := editor_pattern_ignore_case(pat, force)

	// Determine the byte range to operate on.
	lo, hi: int
	if whole_buffer {
		lo = 0
		hi = gap_buffer_len(&ed.buffer)
	} else {
		lo = editor_line_start(ed, ed.cursor)
		hi = editor_line_end(ed, ed.cursor)
	}

	// Collect every match position in the range. For non-global, stop
	// after one match per line.
	positions := make([dynamic]int, context.temp_allocator)
	last := hi - len(needle)
	if whole_buffer {
		i := lo
		for i <= last {
			if vim_match_here(ed, i, needle, ic) {
				append(&positions, i)
				i += len(needle)
				if !global {
					// Skip to end of this line so we only catch one
					// match per line in non-global mode.
					line_end := editor_line_end(ed, i)
					i = line_end
				}
			} else {
				i += 1
			}
		}
	} else {
		i := lo
		for i <= last {
			if vim_match_here(ed, i, needle, ic) {
				append(&positions, i)
				if !global do break
				i += len(needle)
			} else {
				i += 1
			}
		}
	}
	if len(positions) == 0 {
		commit_pending(ed)
		return true
	}

	// Replace from end to start so earlier offsets don't shift under us.
	// We bypass do_insert / do_delete_range (which are file-private to
	// editor.odin and tied to ed.cursor) and call the buffer-mutating
	// wrappers + record_* helpers directly so every replacement lands
	// in the same pending undo group.
	for k := len(positions) - 1; k >= 0; k -= 1 {
		pos := positions[k]

		// Snapshot the bytes we're about to delete so undo can put them back.
		deleted := make([]u8, len(needle), context.temp_allocator)
		for j in 0 ..< len(needle) {
			deleted[j] = gap_buffer_byte_at(&ed.buffer, pos + j)
		}

		editor_buffer_delete(ed, pos, len(needle))
		record_delete(ed, pos, deleted, pos, pos)

		editor_buffer_insert(ed, pos, replacement)
		after := pos + len(replacement)
		record_insert(ed, pos, replacement, after, after)
	}
	ed.dirty = true

	// Park the cursor at the start of the first match (vim convention).
	ed.cursor = positions[0]
	ed.anchor = ed.cursor
	_, ed.desired_col = editor_pos_to_line_col(ed, ed.cursor)
	commit_pending(ed)
	return true
}

// Vim's `%`: jump from the bracket at cursor to its matching pair, with
// proper nesting. No-op if cursor isn't on `( [ { ) ] }`.
vim_bracket_match :: proc(ed: ^Editor) {
	n := gap_buffer_len(&ed.buffer)
	if ed.cursor >= n do return
	at := gap_buffer_byte_at(&ed.buffer, ed.cursor)

	open, close: u8
	forward: bool
	switch at {
	case '(': open = '('; close = ')'; forward = true
	case '[': open = '['; close = ']'; forward = true
	case '{': open = '{'; close = '}'; forward = true
	case ')': open = '('; close = ')'; forward = false
	case ']': open = '['; close = ']'; forward = false
	case '}': open = '{'; close = '}'; forward = false
	case:
		return
	}

	depth := 1
	if forward {
		for i := ed.cursor + 1; i < n; i += 1 {
			b := gap_buffer_byte_at(&ed.buffer, i)
			if b == open      do depth += 1
			else if b == close {
				depth -= 1
				if depth == 0 {
					ed.cursor = i
					if !vim_in_visual(ed) do ed.anchor = i
					_, ed.desired_col = editor_pos_to_line_col(ed, ed.cursor)
					return
				}
			}
		}
	} else {
		for i := ed.cursor - 1; i >= 0; i -= 1 {
			b := gap_buffer_byte_at(&ed.buffer, i)
			if b == close     do depth += 1
			else if b == open {
				depth -= 1
				if depth == 0 {
					ed.cursor = i
					if !vim_in_visual(ed) do ed.anchor = i
					_, ed.desired_col = editor_pos_to_line_col(ed, ed.cursor)
					return
				}
			}
		}
	}
}

// Insert one tab-stop's worth of leading whitespace at the start of the
// current line. Uses '\t' if the line already starts with a tab; spaces
// otherwise (matching the soft-tab convention used elsewhere).
vim_indent_line :: proc(ed: ^Editor) {
	line_start := editor_line_start(ed, ed.cursor)
	n := gap_buffer_len(&ed.buffer)
	use_tab := line_start < n && gap_buffer_byte_at(&ed.buffer, line_start) == '\t'

	bytes: []u8
	if use_tab {
		buf := make([]u8, 1, context.temp_allocator)
		buf[0] = '\t'
		bytes = buf
	} else {
		buf := make([]u8, g_config.editor.tab_size, context.temp_allocator)
		for i in 0 ..< g_config.editor.tab_size do buf[i] = ' '
		bytes = buf
	}
	editor_buffer_insert(ed, line_start, bytes)
	ed.cursor += len(bytes)
	ed.anchor = ed.cursor
	ed.dirty = true
}

// Remove up to one tab-stop's worth of leading whitespace from the start
// of the current line. A leading '\t' counts as the full tab-stop;
// otherwise we strip up to `tab_size` leading spaces.
vim_outdent_line :: proc(ed: ^Editor) {
	line_start := editor_line_start(ed, ed.cursor)
	n := gap_buffer_len(&ed.buffer)
	if line_start >= n do return

	first := gap_buffer_byte_at(&ed.buffer, line_start)
	if first == '\t' {
		editor_buffer_delete(ed, line_start, 1)
		if ed.cursor > line_start do ed.cursor -= 1
		if ed.anchor > line_start do ed.anchor -= 1
		ed.dirty = true
		return
	}

	tab := g_config.editor.tab_size
	count := 0
	for i := line_start; i < n && count < tab; i += 1 {
		if gap_buffer_byte_at(&ed.buffer, i) != ' ' do break
		count += 1
	}
	if count == 0 do return
	editor_buffer_delete(ed, line_start, count)
	if ed.cursor > line_start do ed.cursor = max(line_start, ed.cursor - count)
	if ed.anchor > line_start do ed.anchor = max(line_start, ed.anchor - count)
	ed.dirty = true
}

// Indent / outdent every line touched by the visual selection. Used by
// `>` / `<` while in Visual or Visual_Line mode.
vim_indent_visual :: proc(ed: ^Editor) {
	lo, hi := visible_selection_range(ed)
	first_line, _ := editor_pos_to_line_col(ed, lo)
	last_line,  _ := editor_pos_to_line_col(ed, hi > lo ? hi - 1 : lo)
	saved_cursor := ed.cursor
	for line := last_line; line >= first_line; line -= 1 {
		ed.cursor = editor_nth_line_start(ed, line)
		vim_indent_line(ed)
	}
	ed.cursor = editor_nth_line_start(ed, first_line)
	ed.anchor = ed.cursor
	_, ed.desired_col = editor_pos_to_line_col(ed, ed.cursor)
	_ = saved_cursor
}

vim_outdent_visual :: proc(ed: ^Editor) {
	lo, hi := visible_selection_range(ed)
	first_line, _ := editor_pos_to_line_col(ed, lo)
	last_line,  _ := editor_pos_to_line_col(ed, hi > lo ? hi - 1 : lo)
	for line := last_line; line >= first_line; line -= 1 {
		ed.cursor = editor_nth_line_start(ed, line)
		vim_outdent_line(ed)
	}
	ed.cursor = editor_nth_line_start(ed, first_line)
	ed.anchor = ed.cursor
	_, ed.desired_col = editor_pos_to_line_col(ed, ed.cursor)
}

// Vim's `h` doesn't cross to the previous line — being at the start of a
// line is a no-op. Same constraint applies to LEFT in Normal / Visual.
vim_move_left_in_line :: proc(ed: ^Editor, extend: bool) {
	if ed.cursor <= 0 do return
	if gap_buffer_byte_at(&ed.buffer, ed.cursor - 1) == '\n' do return
	editor_move_left(ed, extend)
}

// Vim's `l` doesn't cross to the next line. Stops at the last printable
// char of the line (the byte before the newline, or before EOF).
vim_move_right_in_line :: proc(ed: ^Editor, extend: bool) {
	n := gap_buffer_len(&ed.buffer)
	if ed.cursor >= n do return
	if gap_buffer_byte_at(&ed.buffer, ed.cursor) == '\n' do return
	next := editor_step_forward(ed, ed.cursor)
	if next >= n do return
	if gap_buffer_byte_at(&ed.buffer, next) == '\n' do return
	editor_move_right(ed, extend)
}

// The main FSM. Called once per character produced in Normal mode.
vim_handle_char :: proc(ed: ^Editor, c: rune) {
	// Visual modes have their own dispatch — operators apply to the
	// selection immediately rather than entering operator-pending state.
	if vim_in_visual(ed) {
		vim_handle_visual_char(ed, c)
		return
	}

	// `.` replays the last change. Don't record this call (otherwise the
	// next dot would replay just the dot, ad infinitum).
	if c == '.' && ed.vim_op == .None && ed.vim_count == 0 && !g_dot_replaying {
		dot_replay(ed)
		return
	}

	pre_version := ed.buffer.version
	dot_observe_pre(ed, c)
	defer dot_observe_post(ed, pre_version)

	// Digit accumulation. '0' is a count digit only when a count is already
	// being built — otherwise it's the line-start motion.
	if c >= '1' && c <= '9' {
		ed.vim_count = ed.vim_count * 10 + int(c - '0')
		return
	}
	if c == '0' && ed.vim_count > 0 {
		ed.vim_count = ed.vim_count * 10
		return
	}

	// `z` prefix continuation (zz / zt / zb — viewport positioning).
	if ed.vim_prefix == .Z {
		ed.vim_prefix = .None
		ed.vim_count = 0
		switch c {
		case 'z': vim_scroll_cursor_to(ed, 1) // center
		case 't': vim_scroll_cursor_to(ed, 0) // top
		case 'b': vim_scroll_cursor_to(ed, 2) // bottom
		}
		return
	}

	// `>` / `<` doubled — indent / outdent the current line.
	if ed.vim_prefix == .Indent {
		ed.vim_prefix = .None
		count := max(1, ed.vim_count)
		ed.vim_count = 0
		if c == '>' {
			for _ in 0 ..< count do vim_indent_line(ed)
		}
		return
	}
	if ed.vim_prefix == .Outdent {
		ed.vim_prefix = .None
		count := max(1, ed.vim_count)
		ed.vim_count = 0
		if c == '<' {
			for _ in 0 ..< count do vim_outdent_line(ed)
		}
		return
	}

	// `g` prefix continuation (gg).
	if ed.vim_prefix == .G {
		ed.vim_prefix = .None
		explicit_count := ed.vim_count
		if c == 'g' {
			target := explicit_count > 0 ? explicit_count - 1 : 0
			ed.vim_count = 0
			commit_pending(ed)
			if ed.vim_op != .None {
				op := ed.vim_op
				ed.vim_op = .None
				ed.vim_op_count = 0
				start := ed.cursor
				vim_goto_line(ed, target)
				end := ed.cursor
				lo := min(start, end)
				hi := max(start, end)
				vim_apply_op_range(ed, op, lo, hi)
			} else {
				vim_goto_line(ed, target)
			}
		} else {
			ed.vim_count = 0
		}
		return
	}

	// Operator-pending: next char is either a doubled operator, the `g` prefix,
	// or a motion that defines the operand range.
	if ed.vim_op != .None {
		op := ed.vim_op
		op_count := max(1, ed.vim_op_count)
		mot_count := max(1, ed.vim_count)
		total := op_count * mot_count

		if (op == .Delete && c == 'd') ||
		   (op == .Yank   && c == 'y') ||
		   (op == .Change && c == 'c') {
			ed.vim_op = .None
			ed.vim_op_count = 0
			ed.vim_count = 0
			commit_pending(ed)
			vim_op_line(ed, op, total)
			return
		}

		if c == 'g' {
			ed.vim_prefix = .G
			return
		}

		ed.vim_op = .None
		ed.vim_op_count = 0
		ed.vim_count = 0
		commit_pending(ed)
		start := ed.cursor
		vim_apply_motion(ed, c, total)
		end := ed.cursor
		lo := min(start, end)
		hi := max(start, end)
		if lo == hi do return
		vim_apply_op_range(ed, op, lo, hi)
		return
	}

	// Direct command. Some commands preserve count for a follow-up keypress.
	switch c {
	case 'g':
		ed.vim_prefix = .G
		return
	case 'z':
		ed.vim_prefix = .Z
		return
	case '>':
		ed.vim_prefix = .Indent
		ed.vim_op_count = max(1, ed.vim_count)
		ed.vim_count = 0
		return
	case '<':
		ed.vim_prefix = .Outdent
		ed.vim_op_count = max(1, ed.vim_count)
		ed.vim_count = 0
		return
	case 'd':
		ed.vim_op = .Delete
		ed.vim_op_count = max(1, ed.vim_count)
		ed.vim_count = 0
		return
	case 'c':
		ed.vim_op = .Change
		ed.vim_op_count = max(1, ed.vim_count)
		ed.vim_count = 0
		return
	case 'y':
		ed.vim_op = .Yank
		ed.vim_op_count = max(1, ed.vim_count)
		ed.vim_count = 0
		return
	}

	explicit_count := ed.vim_count
	count := max(1, explicit_count)
	ed.vim_count = 0

	switch c {
	case 'h', 'l', 'j', 'k', 'w', 'b', 'e', '0', '$', '^':
		commit_pending(ed)
		vim_apply_motion(ed, c, count)
	case 'G':
		commit_pending(ed)
		if explicit_count > 0 do vim_goto_line(ed, explicit_count - 1)
		else                  do vim_goto_last_line(ed)
	case 'i':
		commit_pending(ed)
		vim_enter_insert(ed)
	case 'a':
		commit_pending(ed)
		editor_move_right(ed, false)
		vim_enter_insert(ed)
	case 'I':
		commit_pending(ed)
		vim_first_nonblank(ed)
		vim_enter_insert(ed)
	case 'A':
		commit_pending(ed)
		editor_move_end(ed, false)
		vim_enter_insert(ed)
	case 'o':
		commit_pending(ed)
		editor_move_end(ed, false)
		editor_insert_rune(ed, '\n')
		vim_enter_insert(ed)
	case 'O':
		commit_pending(ed)
		editor_move_home(ed, false)
		editor_insert_rune(ed, '\n')
		editor_move_up(ed, false)
		vim_enter_insert(ed)
	case 'x':
		for _ in 0 ..< count do editor_delete_forward(ed)
	case 'X':
		for _ in 0 ..< count do editor_backspace(ed)
	case 'D': vim_op_to_eol(ed, .Delete) // d$
	case 'C': vim_op_to_eol(ed, .Change) // c$
	case 'Y': vim_op_to_eol(ed, .Yank)   // y$
	case 'p':
		vim_paste_after(ed)
	case 'P':
		vim_paste_before(ed)
	case '%':
		vim_bracket_match(ed)
	case 'v':
		vim_enter_visual(ed)
	case 'V':
		vim_enter_visual_line(ed)
	case 'u':
		for _ in 0 ..< count do editor_undo(ed)
	case ':':
		commit_pending(ed)
		ed.mode = .Command
		clear(&ed.cmd_buffer)
	case '/':
		commit_pending(ed)
		ed.mode = .Search
		ed.search_forward = true
		clear(&ed.cmd_buffer)
	case '?':
		commit_pending(ed)
		ed.mode = .Search
		ed.search_forward = false
		clear(&ed.cmd_buffer)
	case 'n':
		if len(ed.search_pattern) > 0 {
			editor_find_next(ed, ed.search_pattern, ed.search_forward)
		}
	case 'N':
		if len(ed.search_pattern) > 0 {
			editor_find_next(ed, ed.search_pattern, !ed.search_forward)
		}
	}
}

// Execute a `:`-prefixed ex-style command (without the leading `:`).
vim_execute_command :: proc(ed: ^Editor, raw: string) {
	cmd := strings.trim_space(raw)
	if cmd == "" do return

	// Bare line number: jump to that line (1-indexed).
	if line_num, ok := strconv.parse_int(cmd); ok {
		vim_goto_line(ed, line_num - 1)
		return
	}

	switch cmd {
	case "w":
		editor_save_file(ed)
	case "q":
		if !ed.dirty {
			ed.want_quit = true
		}
	case "q!":
		ed.want_quit = true
	case "wq", "x":
		if editor_save_file(ed) {
			ed.want_quit = true
		}
	case "noh", "nohlsearch":
		if len(ed.search_pattern) > 0 {
			delete(ed.search_pattern)
			ed.search_pattern = ""
		}
	case "h", "help":
		help_show()
	}

	if strings.has_prefix(cmd, "e ") {
		path := strings.trim_space(cmd[2:])
		if len(path) > 0 do open_file_smart(path)
	}

	if strings.has_prefix(cmd, "r ") {
		path := strings.trim_space(cmd[2:])
		if len(path) > 0 do replace_active_pane_with_file(path)
	}

	// :s/…/…/ and :%s/…/…/ — substitute. Tried last so other commands
	// (like the bare line numbers above) win where there's overlap.
	if strings.has_prefix(cmd, "s/") || strings.has_prefix(cmd, "%s/") {
		vim_substitute(ed, cmd)
	}

	if strings.has_prefix(cmd, "syntax ") || strings.has_prefix(cmd, "syn ") {
		arg_start := strings.has_prefix(cmd, "syntax ") ? 7 : 4
		arg := strings.trim_space(cmd[arg_start:])
		if lang, ok := language_from_name(arg); ok {
			ed.language = lang
		}
	}
}
