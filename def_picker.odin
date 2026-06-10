package bragi

import "core:fmt"
import "core:strings"
import sdl "vendor:sdl3"

// Go-to-definition chooser. When textDocument/definition returns more than
// one location (overloads, a decl + an impl, the same name across files),
// lsp_definition_response pops this list instead of guessing. Anchored at
// the caret and styled like the completion popup; j/k or ↑/↓ to move,
// Enter jumps, Esc cancels, click selects.

DEFP_MAX_VISIBLE :: 10
DEFP_PAD         :: f32(6)
DEFP_ROW_GAP     :: f32(4)
DEFP_MIN_WIDTH   :: f32(260)

Def_Location :: struct {
	path:      string, // owned once in the picker; aliases JSON while collecting
	line:      int,    // 0-based
	character: int,
	label:     string, // owned; "relpath:line"
}

g_def_picker: struct {
	visible: bool,
	items:   [dynamic]Def_Location,
	active:  int,
	scroll:  int,
	// caret anchor captured at show time (the editor may scroll after).
	anchor_x, anchor_y: f32,
}

def_picker_active :: proc() -> bool {
	return g_def_picker.visible
}

def_picker_destroy :: proc() {
	def_picker_clear()
	delete(g_def_picker.items)
}

@(private="file")
def_picker_clear :: proc() {
	for it in g_def_picker.items {
		delete(it.path)
		delete(it.label)
	}
	clear(&g_def_picker.items)
}

def_picker_dismiss :: proc() {
	g_def_picker.visible = false
	def_picker_clear()
	g_def_picker.active = 0
	g_def_picker.scroll = 0
}

// Take a set of locations (paths alias the live JSON) and show the chooser,
// cloning everything into owned storage + building display labels.
def_picker_show :: proc(locs: []Def_Location) {
	def_picker_clear()
	for l in locs {
		rel := l.path
		if len(g_workspace_root) > 0 && strings.has_prefix(rel, g_workspace_root) {
			rel = rel[len(g_workspace_root):]
			rel = strings.trim_prefix(rel, "/")
		} else {
			rel = path_basename(rel)
		}
		append(&g_def_picker.items, Def_Location{
			path      = strings.clone(l.path),
			line      = l.line,
			character = l.character,
			label     = fmt.aprintf("%s:%d", rel, l.line + 1),
		})
	}
	g_def_picker.active = 0
	g_def_picker.scroll = 0
	g_def_picker.visible = len(g_def_picker.items) > 0
	// Anchor at the current caret of the active editor.
	ed := active_editor()
	cl, cc := editor_pos_to_line_col(ed, ed.cursor)
	g_def_picker.anchor_x = f32(cc)
	g_def_picker.anchor_y = f32(cl)
}

@(private="file")
def_picker_choose :: proc() {
	if !g_def_picker.visible || len(g_def_picker.items) == 0 do return
	it := g_def_picker.items[g_def_picker.active]
	path := strings.clone(it.path, context.temp_allocator)
	line, ch := it.line, it.character
	def_picker_dismiss()
	lsp_jump_to(path, line, ch)
}

@(private="file")
def_picker_scroll_into_view :: proc() {
	if g_def_picker.active < g_def_picker.scroll do g_def_picker.scroll = g_def_picker.active
	if g_def_picker.active >= g_def_picker.scroll + DEFP_MAX_VISIBLE {
		g_def_picker.scroll = g_def_picker.active - DEFP_MAX_VISIBLE + 1
	}
}

// Modal while visible: swallows every key.
def_picker_handle_key :: proc(ev: sdl.KeyboardEvent) -> bool {
	if !g_def_picker.visible do return false
	switch ev.key {
	case sdl.K_ESCAPE:
		def_picker_dismiss()
	case sdl.K_RETURN, sdl.K_KP_ENTER:
		def_picker_choose()
	case sdl.K_UP, sdl.K_K:
		if g_def_picker.active > 0 do g_def_picker.active -= 1
		def_picker_scroll_into_view()
	case sdl.K_DOWN, sdl.K_J:
		if g_def_picker.active < len(g_def_picker.items) - 1 do g_def_picker.active += 1
		def_picker_scroll_into_view()
	}
	g_swallow_text_input = true // eat the j/k/etc. text-input that follows
	return true
}

// Mouse moved over a row → highlight it.
def_picker_handle_motion :: proc(mx, my: f32, p: Pane_Layout) {
	if !g_def_picker.visible do return
	r := def_picker_rect(active_editor(), p)
	if mx < r.x || mx > r.x + r.w || my < r.y || my > r.y + r.h do return
	row_h := g_config.font.size + DEFP_ROW_GAP
	idx := g_def_picker.scroll + int((my - (r.y + DEFP_PAD * 0.5)) / row_h)
	if idx >= 0 && idx < len(g_def_picker.items) do g_def_picker.active = idx
}

// Click on a row selects + jumps; click outside dismisses. Returns true if
// the event was consumed.
def_picker_handle_click :: proc(mx, my: f32, p: Pane_Layout) -> bool {
	if !g_def_picker.visible do return false
	r := def_picker_rect(active_editor(), p)
	if mx < r.x || mx > r.x + r.w || my < r.y || my > r.y + r.h {
		def_picker_dismiss()
		return true
	}
	row_h := g_config.font.size + DEFP_ROW_GAP
	idx := g_def_picker.scroll + int((my - (r.y + DEFP_PAD * 0.5)) / row_h)
	if idx >= 0 && idx < len(g_def_picker.items) {
		g_def_picker.active = idx
		def_picker_choose()
	}
	return true
}

@(private="file")
def_picker_rect :: proc(ed: ^Editor, p: Pane_Layout) -> sdl.FRect {
	caret_x := p.text_x + g_def_picker.anchor_x * g_char_width  - ed.scroll_x
	caret_y := p.text_y + g_def_picker.anchor_y * g_line_height - ed.scroll_y
	row_h := g_config.font.size + DEFP_ROW_GAP
	n := min(len(g_def_picker.items), DEFP_MAX_VISIBLE)

	w := DEFP_MIN_WIDTH
	end := min(g_def_picker.scroll + n, len(g_def_picker.items))
	for i := g_def_picker.scroll; i < end; i += 1 {
		lw := f32(len(g_def_picker.items[i].label)) * g_char_width + DEFP_PAD * 2
		if lw > w do w = lw
	}
	if w > p.text_w - 8 do w = p.text_w - 8
	h := f32(n) * row_h + DEFP_PAD

	x := caret_x
	y := caret_y + g_line_height
	if y + h > p.text_y + p.text_h do y = caret_y - h
	if x + w > p.text_x + p.text_w do x = p.text_x + p.text_w - w
	if x < p.text_x do x = p.text_x
	return {x, y, w, h}
}

draw_def_picker :: proc(ed: ^Editor, p: Pane_Layout) {
	if !g_def_picker.visible || len(g_def_picker.items) == 0 do return
	r := def_picker_rect(ed, p)
	row_h := g_config.font.size + DEFP_ROW_GAP
	n := min(len(g_def_picker.items), DEFP_MAX_VISIBLE)
	end := min(g_def_picker.scroll + n, len(g_def_picker.items))

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
	for i := g_def_picker.scroll; i < end; i += 1 {
		ry := r.y + DEFP_PAD * 0.5 + f32(row) * row_h
		row += 1
		bg := MENU_BG_COLOR
		if i == g_def_picker.active {
			fill_rect({r.x + bw, ry, r.w - bw * 2, row_h}, MENU_HOVER_COLOR)
			bg = MENU_HOVER_COLOR
		}
		lc := strings.clone_to_cstring(g_def_picker.items[i].label, context.temp_allocator)
		draw_text(lc, r.x + DEFP_PAD, ry, MENU_TEXT_COLOR, bg)
	}
}
