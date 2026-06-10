package bragi

// In-memory scratchpad: one ephemeral buffer for jotting notes, reachable
// any time via `:scratch` or Cmd/Ctrl+Shift+N. It's a normal Editor pane
// (full vim editing / undo / selection), flagged `is_scratch`.
//
// Lifetime model: the content lives only while the app runs. Closing the
// scratch pane snapshots its text + cursor into g_scratch_* so reopening
// restores it; quitting just frees the snapshot — nothing touches disk.
// Save As "promotes" the buffer to a real file (clears is_scratch + the
// in-memory snapshot), graduating the note into a normal file buffer.
//
// Plain text only (language = .None) — notes, not code.

SCRATCH_NAME :: "*scratch*"

@(private="file") g_scratch_text:   string // owned snapshot; "" = empty
@(private="file") g_scratch_cursor: int

// Open the scratchpad, or focus its pane if it's already open. Placed like
// opening a file: reuse a blank pane, otherwise split a new one.
scratch_open :: proc() {
	for &e, i in g_editors {
		if e.is_scratch {
			g_active_idx     = i
			g_sidebar_active = false
			g_terminal_active = false
			return
		}
	}
	if should_replace_active() {
		scratch_seed(active_editor())
	} else {
		open_new_pane()
		scratch_seed(active_editor())
	}
}

@(private="file")
scratch_seed :: proc(ed: ^Editor) {
	editor_set_text(ed, g_scratch_text)
	ed.is_scratch = true
	ed.language   = .None
	ed.mode       = .Normal
	ed.dirty      = false
	n := piece_buffer_len(&ed.buffer)
	ed.cursor = clamp(g_scratch_cursor, 0, n)
	ed.anchor = ed.cursor
	g_sidebar_active  = false
	g_terminal_active = false
}

// Snapshot a scratch pane's content before its pane is destroyed, so the
// notes survive a close. No-op for non-scratch editors. Called from the
// pane-close path.
scratch_snapshot :: proc(ed: ^Editor) {
	if !ed.is_scratch do return
	if len(g_scratch_text) > 0 do delete(g_scratch_text)
	g_scratch_text   = piece_buffer_to_string(&ed.buffer) // owned (heap)
	g_scratch_cursor = ed.cursor
}

// Save As succeeded on a scratch buffer → it's now a real, file-backed
// buffer. Drop the scratch flag and clear the in-memory note so the next
// `:scratch` starts fresh.
scratch_promote :: proc(ed: ^Editor) {
	if !ed.is_scratch do return
	ed.is_scratch = false
	if len(g_scratch_text) > 0 {
		delete(g_scratch_text)
		g_scratch_text = ""
	}
	g_scratch_cursor = 0
}

// Display name for the status bar / titlebar: "*scratch*" for the
// scratchpad, the basename for a file, else "[untitled]".
pane_display_name :: proc(ed: ^Editor) -> string {
	if ed.is_scratch do return SCRATCH_NAME
	return len(ed.file_path) > 0 ? path_basename(ed.file_path) : "[untitled]"
}

scratch_destroy :: proc() {
	if len(g_scratch_text) > 0 {
		delete(g_scratch_text)
		g_scratch_text = ""
	}
}
