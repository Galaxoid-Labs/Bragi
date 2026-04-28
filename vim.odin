package bragi

import "core:strconv"
import "core:strings"
import sdl "vendor:sdl3"

Mode :: enum { Insert, Normal, Command, Search }

Vim_Operator :: enum { None, Delete, Change, Yank }
Vim_Prefix   :: enum { None, G }

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
	ed.mode = .Normal
	vim_reset_state(ed)
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
	for _ in 0 ..< count {
		switch motion {
		case 'h': editor_move_left(ed, false)
		case 'l': editor_move_right(ed, false)
		case 'j': editor_move_down(ed, false)
		case 'k': editor_move_up(ed, false)
		case 'w': vim_word_forward(ed)
		case 'b': vim_word_backward(ed)
		case 'e': vim_word_end(ed)
		case '0': editor_move_home(ed, false)
		case '$': editor_move_end(ed, false)
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

// The main FSM. Called once per character produced in Normal mode.
vim_handle_char :: proc(ed: ^Editor, c: rune) {
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

	if strings.has_prefix(cmd, "syntax ") || strings.has_prefix(cmd, "syn ") {
		arg_start := strings.has_prefix(cmd, "syntax ") ? 7 : 4
		arg := strings.trim_space(cmd[arg_start:])
		if lang, ok := language_from_name(arg); ok {
			ed.language = lang
		}
	}
}
