package bragi

// "Dot repeat" — vim's `.` re-runs the last change. We capture the rune
// stream that produced the change (single-char op, operator + motion,
// or insert session terminated by Esc), then replay it through the
// same dispatch paths to reproduce the effect.
//
// We don't try to be clever about state machines — instead we observe
// vim_handle_char / handle_text_input / Esc with pre- and post-call
// snapshots and decide what to do based on whether the editor settled
// back to a clean state (Normal, no operator pending, no count) and
// whether the buffer.version actually changed. That keeps the rules
// out of the dispatch hot path.

DOT_ESC_MARKER :: rune(0x1B) // sentinel for "exit Insert mode"

// Accumulating sequence; reset whenever we land in a fresh state with
// no buffer change. Promoted to g_dot_last when a change actually
// commits.
g_dot_buf:  [dynamic]rune
g_dot_last: [dynamic]rune
// Set during dot_replay so the recursive vim_handle_char calls don't
// try to re-record the runes they're replaying.
g_dot_replaying: bool

@(private="file")
commit_dot :: proc() {
	clear(&g_dot_last)
	for r in g_dot_buf do append(&g_dot_last, r)
}

// True when the vim FSM is at a settled "no command in progress" state
// — Normal mode, no operator pending, no count being built, no prefix
// awaiting a follow-up. We use this as the boundary marker for the dot
// recording (commit on entry, clear if no buffer change happened).
@(private="file")
dot_settled :: proc(ed: ^Editor) -> bool {
	return ed.mode == .Normal &&
	       ed.vim_op == .None &&
	       ed.vim_count == 0 &&
	       ed.vim_prefix == .None
}

// Called *before* vim_handle_char processes `c` in non-visual modes.
// Resets the buffer when we're at a settled fresh state, otherwise
// continues the in-progress recording.
dot_observe_pre :: proc(ed: ^Editor, c: rune) {
	if g_dot_replaying do return
	if dot_settled(ed) do clear(&g_dot_buf)
	append(&g_dot_buf, c)
}

// Called *after* vim_handle_char. If the editor settled back to fresh
// Normal state and the buffer changed, the recording commits. If it
// landed in Insert mode the recording continues via dot_observe_insert.
// Visual / Search / Command transitions clear the buffer so partial
// recordings don't leak.
dot_observe_post :: proc(ed: ^Editor, pre_version: u64) {
	if g_dot_replaying do return
	switch {
	case ed.mode == .Insert:
		// Recording continues; runes flow through dot_observe_insert.
	case ed.mode == .Visual || ed.mode == .Visual_Line ||
	     ed.mode == .Command || ed.mode == .Search:
		clear(&g_dot_buf)
	case dot_settled(ed):
		if ed.buffer.version != pre_version do commit_dot()
		else                                do clear(&g_dot_buf)
		// Otherwise mid-command (operator pending, count being built,
		// or prefix awaiting follow-up) — keep recording.
	}
}

// Called for each rune typed in Insert mode. Append-only.
dot_observe_insert :: proc(r: rune) {
	if g_dot_replaying do return
	append(&g_dot_buf, r)
}

// Called when Esc exits Insert mode. Caps the recording with the Esc
// marker and commits.
dot_observe_esc :: proc() {
	if g_dot_replaying do return
	append(&g_dot_buf, DOT_ESC_MARKER)
	commit_dot()
}

// Replay the last committed change. Resets the vim FSM first so the
// first rune is interpreted as starting a brand-new command.
dot_replay :: proc(ed: ^Editor) {
	if len(g_dot_last) == 0 do return

	g_dot_replaying = true
	defer g_dot_replaying = false

	vim_reset_state(ed)

	for r in g_dot_last {
		if r == DOT_ESC_MARKER {
			if ed.mode == .Insert do vim_enter_normal(ed)
			continue
		}
		if ed.mode == .Insert {
			editor_insert_rune(ed, r)
		} else if vim_in_visual(ed) {
			// Visual replays aren't recorded yet; skip.
			continue
		} else {
			vim_handle_char(ed, r)
		}
	}
}
