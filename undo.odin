package bragi

// An Undo_Op is a single primitive change to the buffer that can be inverted.
// An Undo_Group is a sequence of ops that should undo/redo together. The
// editor accumulates ops into a `pending` group; cursor movement (or an
// explicit commit) closes the group and pushes it onto the undo stack.

Undo_Op_Kind :: enum {
	Insert,
	Delete,
}

Undo_Op :: struct {
	kind:          Undo_Op_Kind,
	pos:           int,
	text:          []u8, // owned: bytes inserted (Insert) or removed (Delete)

	cursor_before: int,
	anchor_before: int,
	cursor_after:  int,
	anchor_after:  int,
}

Undo_Group :: struct {
	ops: [dynamic]Undo_Op,
}

Pending_Kind :: enum {
	None,
	Inserting,
	Deleting,
}

undo_op_destroy :: proc(op: ^Undo_Op) {
	delete(op.text)
}

undo_group_destroy :: proc(g: ^Undo_Group) {
	for i in 0 ..< len(g.ops) {
		undo_op_destroy(&g.ops[i])
	}
	delete(g.ops)
	g^ = {}
}

undo_stack_clear :: proc(stack: ^[dynamic]Undo_Group) {
	for i in 0 ..< len(stack) {
		undo_group_destroy(&stack[i])
	}
	clear(stack)
}

undo_stack_destroy :: proc(stack: ^[dynamic]Undo_Group) {
	undo_stack_clear(stack)
	delete(stack^)
}

clone_bytes :: proc(bytes: []u8) -> []u8 {
	out := make([]u8, len(bytes))
	copy(out, bytes)
	return out
}

// Append an op to ed.pending, merging with the last op when the new op is a
// contiguous continuation (a streak of typed chars, or a streak of backspaces /
// forward-deletes). Clears the redo stack the first time an op is added to a
// fresh pending group, since any new edit invalidates redo history.
@(private="file")
record_op :: proc(ed: ^Editor, op: Undo_Op) {
	if len(ed.pending.ops) == 0 {
		undo_stack_clear(&ed.redo_stack)
	}

	if len(ed.pending.ops) > 0 {
		last := &ed.pending.ops[len(ed.pending.ops) - 1]
		merged := false

		if op.kind == .Insert && last.kind == .Insert {
			// Contiguous typing: last.pos + len(last.text) == op.pos.
			if last.pos + len(last.text) == op.pos &&
			   last.cursor_after == op.cursor_before {
				combined := make([]u8, len(last.text) + len(op.text))
				copy(combined, last.text)
				copy(combined[len(last.text):], op.text)
				delete(last.text)
				delete(op.text)
				last.text = combined
				last.cursor_after = op.cursor_after
				last.anchor_after = op.anchor_after
				merged = true
			}
		} else if op.kind == .Delete && last.kind == .Delete {
			// Backspace streak: each new op deletes bytes immediately before the
			// previous deletion. Forward-delete streak: each new op at same pos.
			if op.pos + len(op.text) == last.pos {
				combined := make([]u8, len(op.text) + len(last.text))
				copy(combined, op.text)
				copy(combined[len(op.text):], last.text)
				delete(last.text)
				delete(op.text)
				last.text = combined
				last.pos = op.pos
				last.cursor_after = op.cursor_after
				last.anchor_after = op.anchor_after
				merged = true
			} else if last.pos == op.pos {
				combined := make([]u8, len(last.text) + len(op.text))
				copy(combined, last.text)
				copy(combined[len(last.text):], op.text)
				delete(last.text)
				delete(op.text)
				last.text = combined
				last.cursor_after = op.cursor_after
				last.anchor_after = op.anchor_after
				merged = true
			}
		}

		if merged do return
	}

	append(&ed.pending.ops, op)
}

record_insert :: proc(ed: ^Editor, pos: int, bytes: []u8, cursor_after, anchor_after: int) {
	op := Undo_Op{
		kind          = .Insert,
		pos           = pos,
		text          = clone_bytes(bytes),
		cursor_before = ed.cursor,
		anchor_before = ed.anchor,
		cursor_after  = cursor_after,
		anchor_after  = anchor_after,
	}
	record_op(ed, op)
}

record_delete :: proc(ed: ^Editor, pos: int, bytes: []u8, cursor_after, anchor_after: int) {
	op := Undo_Op{
		kind          = .Delete,
		pos           = pos,
		text          = clone_bytes(bytes),
		cursor_before = ed.cursor,
		anchor_before = ed.anchor,
		cursor_after  = cursor_after,
		anchor_after  = anchor_after,
	}
	record_op(ed, op)
}

commit_pending :: proc(ed: ^Editor) {
	if len(ed.pending.ops) == 0 {
		ed.pending_kind = .None
		return
	}
	append(&ed.undo_stack, ed.pending)
	ed.pending = {}
	ed.pending_kind = .None
}

editor_undo :: proc(ed: ^Editor) {
	commit_pending(ed)
	if len(ed.undo_stack) == 0 do return

	g := pop(&ed.undo_stack)

	// Apply inverse of each op in reverse order.
	for i := len(g.ops) - 1; i >= 0; i -= 1 {
		op := g.ops[i]
		switch op.kind {
		case .Insert:
			editor_buffer_delete(ed, op.pos, len(op.text))
		case .Delete:
			editor_buffer_insert(ed, op.pos, op.text)
		}
	}

	first := g.ops[0]
	ed.cursor = first.cursor_before
	ed.anchor = first.anchor_before

	append(&ed.redo_stack, g)

	_, ed.desired_col = editor_pos_to_line_col(ed, ed.cursor)
	ed.blink_timer = 0
	ed.dirty = true
}

editor_redo :: proc(ed: ^Editor) {
	commit_pending(ed)
	if len(ed.redo_stack) == 0 do return

	g := pop(&ed.redo_stack)

	for op in g.ops {
		switch op.kind {
		case .Insert:
			editor_buffer_insert(ed, op.pos, op.text)
		case .Delete:
			editor_buffer_delete(ed, op.pos, len(op.text))
		}
	}

	last := g.ops[len(g.ops) - 1]
	ed.cursor = last.cursor_after
	ed.anchor = last.anchor_after

	append(&ed.undo_stack, g)

	_, ed.desired_col = editor_pos_to_line_col(ed, ed.cursor)
	ed.blink_timer = 0
	ed.dirty = true
}
