package bragi

import "core:encoding/json"
import "core:slice"
import "core:strings"
import sdl "vendor:sdl3"

// LSP autocompletion popup. Triggered as you type an identifier, after a
// '.', or via Ctrl+Space — Insert mode only. Requests
// textDocument/completion once at the word start, then narrows the list
// locally as you keep typing (one round-trip per word). Tab/Enter accept,
// Esc dismisses, Up/Down move. Anchored at the caret, styled like the
// finder.

COMPL_MAX_VISIBLE :: 12
COMPL_MIN_WIDTH   :: f32(220)
COMPL_ROW_GAP     :: f32(4)
COMPL_PAD         :: f32(6)

Completion_Item :: struct {
	label:  string, // owned; display text
	insert: string, // owned; text inserted on accept
	detail: string, // owned; dim right-side type info
	kind:   int,    // LSP CompletionItemKind
	filt:   string, // owned; lowercased label, for filtering
	sort:   string, // owned; server's sortText (relevance tiebreaker)
}

g_completion: struct {
	visible:    bool,
	items:      [dynamic]Completion_Item, // full server set
	filtered:   [dynamic]int,             // indices into items, after narrowing
	active:     int,
	scroll:     int,
	anchor:     int, // byte offset where the completed word starts
	pending_id: i64, // id of the in-flight request (staleness guard)
	for_editor: int, // g_active_idx the request belongs to
}

completion_active :: proc() -> bool {
	return g_completion.visible
}

completion_destroy :: proc() {
	completion_clear_items()
	delete(g_completion.items)
	delete(g_completion.filtered)
}

@(private="file")
completion_clear_items :: proc() {
	for it in g_completion.items {
		delete(it.label)
		delete(it.insert)
		delete(it.detail)
		delete(it.filt)
		delete(it.sort)
	}
	clear(&g_completion.items)
	clear(&g_completion.filtered)
}

completion_dismiss :: proc() {
	g_completion.visible = false
	completion_clear_items()
	g_completion.active = 0
	g_completion.scroll = 0
	g_completion.pending_id = 0
}

@(private="file")
is_ident_byte :: proc(b: u8) -> bool {
	return (b >= 'a' && b <= 'z') || (b >= 'A' && b <= 'Z') || (b >= '0' && b <= '9') || b == '_'
}

@(private="file")
completion_word_start :: proc(ed: ^Editor, pos: int) -> int {
	i := pos
	for i > 0 && is_ident_byte(piece_buffer_byte_at(&ed.buffer, i - 1)) do i -= 1
	return i
}

// The typed prefix (anchor..cursor) as a temp string.
@(private="file")
completion_prefix :: proc(ed: ^Editor) -> string {
	if ed.cursor <= g_completion.anchor do return ""
	n := ed.cursor - g_completion.anchor
	buf := make([]u8, n, context.temp_allocator)
	for i in 0 ..< n do buf[i] = piece_buffer_byte_at(&ed.buffer, g_completion.anchor + i)
	return string(buf)
}

// ── triggering ──────────────────────────────────────────────────────

completion_trigger :: proc(ed: ^Editor, trigger := "") {
	if !lsp_ready(ed.language) || ed.mode != .Insert do return
	g_completion.anchor = completion_word_start(ed, ed.cursor)
	g_completion.for_editor = g_active_idx
	id, ok := lsp_completion_request(ed, trigger)
	if !ok do return
	g_completion.pending_id = id
}

// Called from handle_text_input after inserting a rune in Insert mode.
completion_after_insert :: proc(ed: ^Editor, r: rune) {
	if !lsp_ready(ed.language) do return
	if r == '.' {
		completion_trigger(ed, ".") // member-access trigger char
		return
	}
	if r < 128 && is_ident_byte(u8(r)) {
		if g_completion.visible do completion_refilter(ed)
		else                    do completion_trigger(ed)
		return
	}
	if g_completion.visible do completion_dismiss()
}

// Cursor moved (arrows / mouse / edits): dismiss if it left the word /
// Insert mode, else narrow.
completion_on_cursor_moved :: proc(ed: ^Editor) {
	if !g_completion.visible do return
	if g_active_idx != g_completion.for_editor || ed.mode != .Insert || ed.cursor < g_completion.anchor {
		completion_dismiss()
		return
	}
	completion_refilter(ed)
}

// ── response + filtering ────────────────────────────────────────────

completion_on_response :: proc(obj: json.Object) {
	id := lsp_obj_int(obj, "id")
	if id != g_completion.pending_id do return // stale
	if g_active_idx != g_completion.for_editor do return
	ed := active_editor()
	if ed.mode != .Insert do return

	completion_clear_items()

	// result is CompletionItem[] OR CompletionList { items: [...] }.
	items_arr: json.Array
	if rv, has := obj["result"]; has {
		#partial switch r in rv {
		case json.Array:
			items_arr = r
		case json.Object:
			if iv, hi := r["items"]; hi {
				if a, ok := iv.(json.Array); ok do items_arr = a
			}
		}
	}
	for item in items_arr {
		it, ok := item.(json.Object)
		if !ok do continue
		label := lsp_obj_str(it, "label")
		if label == "" do continue
		insert := lsp_obj_str(it, "insertText")
		if insert == "" do insert = label
		append(&g_completion.items, Completion_Item{
			label  = strings.clone(label),
			insert = strings.clone(insert),
			detail = strings.clone(lsp_obj_str(it, "detail")),
			kind   = int(lsp_obj_int(it, "kind")),
			filt   = strings.to_lower(label),
			sort   = strings.clone(lsp_obj_str(it, "sortText")),
		})
	}
	g_completion.active = 0
	g_completion.scroll = 0
	completion_refilter(ed)
	g_completion.visible = len(g_completion.filtered) > 0
}

// Original-case typed prefix, read by the sort comparator below (set just
// before the synchronous sort; not used outside it).
@(private="file")
g_compl_rank_prefix: string

@(private="file")
completion_refilter :: proc(ed: ^Editor) {
	clear(&g_completion.filtered)
	raw := completion_prefix(ed)
	prefix := strings.to_lower(raw, context.temp_allocator)
	for it, i in g_completion.items {
		if len(prefix) == 0 || strings.has_prefix(it.filt, prefix) {
			append(&g_completion.filtered, i)
		}
	}
	// Rank the matches: an exact-case prefix hit (you typed "def" → "defer")
	// beats a case-insensitive one ("DEFFILEMODE"); then shorter labels (closer
	// to what you typed); then alphabetical. Keeps the obvious match on top.
	if len(raw) > 0 && len(g_completion.filtered) > 1 {
		g_compl_rank_prefix = raw
		slice.sort_by(g_completion.filtered[:], compl_rank_less)
	}
	if g_completion.active >= len(g_completion.filtered) {
		g_completion.active = max(0, len(g_completion.filtered) - 1)
	}
	if len(g_completion.filtered) == 0 do g_completion.visible = false
}

@(private="file")
compl_rank_less :: proc(a, b: int) -> bool {
	la := g_completion.items[a].label
	lb := g_completion.items[b].label
	ca := strings.has_prefix(la, g_compl_rank_prefix) ? 0 : 1
	cb := strings.has_prefix(lb, g_compl_rank_prefix) ? 0 : 1
	if ca != cb do return ca < cb
	// Server-curated relevance (sortText) breaks ties before our heuristics.
	sa := g_completion.items[a].sort
	sb := g_completion.items[b].sort
	if sa != sb && len(sa) > 0 && len(sb) > 0 do return sa < sb
	if len(la) != len(lb) do return len(la) < len(lb)
	return la < lb
}

// ── accept ──────────────────────────────────────────────────────────

@(private="file")
completion_accept :: proc() {
	if !g_completion.visible || len(g_completion.filtered) == 0 do return
	ed := active_editor()
	it := g_completion.items[g_completion.filtered[g_completion.active]]
	editor_replace_range(ed, g_completion.anchor, ed.cursor, it.insert)
	completion_dismiss()
}

// ── input ───────────────────────────────────────────────────────────

completion_handle_key :: proc(ev: sdl.KeyboardEvent) -> bool {
	if !g_completion.visible do return false
	switch ev.key {
	case sdl.K_ESCAPE:
		completion_dismiss()
		return true
	case sdl.K_RETURN, sdl.K_TAB:
		completion_accept()
		g_swallow_text_input = true
		return true
	case sdl.K_UP:
		if g_completion.active > 0 do g_completion.active -= 1
		completion_scroll_into_view()
		return true
	case sdl.K_DOWN:
		if g_completion.active < len(g_completion.filtered) - 1 do g_completion.active += 1
		completion_scroll_into_view()
		return true
	}
	return false
}

@(private="file")
completion_scroll_into_view :: proc() {
	if g_completion.active < g_completion.scroll do g_completion.scroll = g_completion.active
	if g_completion.active >= g_completion.scroll + COMPL_MAX_VISIBLE {
		g_completion.scroll = g_completion.active - COMPL_MAX_VISIBLE + 1
	}
}

// ── draw ────────────────────────────────────────────────────────────

// Popup rectangle for the current caret + visible rows. Shared by draw +
// mouse hit-testing so they never disagree.
@(private="file")
completion_rect :: proc(ed: ^Editor, p: Pane_Layout) -> sdl.FRect {
	cline, ccol := editor_pos_to_line_col(ed, ed.cursor)
	caret_x := p.text_x + f32(ccol) * g_char_width  - ed.scroll_x
	caret_y := p.text_y + f32(cline) * g_line_height - ed.scroll_y
	row_h := g_config.font.size + COMPL_ROW_GAP
	n := min(len(g_completion.filtered), COMPL_MAX_VISIBLE)
	end := min(g_completion.scroll + n, len(g_completion.filtered))
	w := COMPL_MIN_WIDTH
	for i := g_completion.scroll; i < end; i += 1 {
		it := g_completion.items[g_completion.filtered[i]]
		lw := f32(len(it.label) + len(it.detail) + 4) * g_char_width + COMPL_PAD * 2
		if lw > w do w = lw
	}
	if w > p.text_w - 8 do w = p.text_w - 8
	h := f32(n) * row_h + COMPL_PAD
	x := caret_x
	y := caret_y + g_line_height
	if y + h > p.text_y + p.text_h do y = caret_y - h
	if x + w > p.text_x + p.text_w do x = p.text_x + p.text_w - w
	if x < p.text_x do x = p.text_x
	return {x, y, w, h}
}

@(private="file")
completion_row_at :: proc(my: f32, r: sdl.FRect) -> int {
	row_h := g_config.font.size + COMPL_ROW_GAP
	idx := g_completion.scroll + int((my - (r.y + COMPL_PAD * 0.5)) / row_h)
	if idx >= 0 && idx < len(g_completion.filtered) do return idx
	return -1
}

// Mouse moved: if it's over a row, make that the highlighted item.
completion_handle_motion :: proc(mx, my: f32, p: Pane_Layout) {
	if !g_completion.visible do return
	r := completion_rect(active_editor(), p)
	if mx < r.x || mx > r.x + r.w || my < r.y || my > r.y + r.h do return
	if idx := completion_row_at(my, r); idx >= 0 do g_completion.active = idx
}

// Click on a row selects + inserts it (same as Enter). Returns true if the
// click landed on the popup. Outside clicks are left for the editor (which
// dismisses via the cursor move).
completion_handle_click :: proc(mx, my: f32, p: Pane_Layout) -> bool {
	if !g_completion.visible do return false
	r := completion_rect(active_editor(), p)
	if mx < r.x || mx > r.x + r.w || my < r.y || my > r.y + r.h do return false
	idx := completion_row_at(my, r)
	if idx < 0 do return false
	g_completion.active = idx
	completion_accept()
	return true
}

draw_completion :: proc(ed: ^Editor, p: Pane_Layout) {
	if !g_completion.visible || len(g_completion.filtered) == 0 do return

	row_h := g_config.font.size + COMPL_ROW_GAP
	n := min(len(g_completion.filtered), COMPL_MAX_VISIBLE)
	end := min(g_completion.scroll + n, len(g_completion.filtered))
	r := completion_rect(ed, p)
	fill_rect(r, MENU_BG_COLOR)
	bw: f32 = 1
	fill_rect({r.x, r.y, r.w, bw}, MENU_BORDER_COLOR)
	fill_rect({r.x, r.y + r.h - bw, r.w, bw}, MENU_BORDER_COLOR)
	fill_rect({r.x, r.y, bw, r.h}, MENU_BORDER_COLOR)
	fill_rect({r.x + r.w - bw, r.y, bw, r.h}, MENU_BORDER_COLOR)

	clip := sdl.Rect{i32(r.x), i32(r.y), i32(r.w), i32(r.h)}
	sdl.SetRenderClipRect(g_renderer, &clip)
	defer sdl.SetRenderClipRect(g_renderer, nil)

	row := 0
	for i := g_completion.scroll; i < end; i += 1 {
		ry := r.y + COMPL_PAD * 0.5 + f32(row) * row_h
		row += 1
		bg := MENU_BG_COLOR
		if i == g_completion.active {
			fill_rect({r.x + bw, ry, r.w - bw * 2, row_h}, MENU_HOVER_COLOR)
			bg = MENU_HOVER_COLOR
		}
		it := g_completion.items[g_completion.filtered[i]]
		lx := r.x + COMPL_PAD
		lc := strings.clone_to_cstring(it.label, context.temp_allocator)
		lw := draw_text(lc, lx, ry, MENU_TEXT_COLOR, bg)
		if len(it.detail) > 0 {
			dc := strings.clone_to_cstring(it.detail, context.temp_allocator)
			draw_text(dc, lx + lw + g_char_width, ry, MENU_DIM_COLOR, bg)
		}
	}
}
