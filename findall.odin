package bragi

import "core:fmt"
import "core:strings"
import sdl "vendor:sdl3"

// Find-in-files: project-wide content search (grep). A finder-styled centered
// modal, live as you type — each keystroke posts a query to the shared fff
// worker (see grep_* in finder.odin), which runs fff_live_grep and streams
// back matches. Each row is `path:line` + the matched line with the matched
// span highlighted; Enter / click opens the file and jumps to the match.
//
// Shares fff's warm project index with the file finder; the two are mutually
// exclusive modals.

FINDALL_PAD         :: 16.0
FINDALL_INPUT_GAP   :: 8.0
FINDALL_LINE_GAP    :: 4.0
FINDALL_MAX_VISIBLE :: 16
FINDALL_DIM_BG      :: sdl.Color{0, 0, 0, 140}

@(private="file") FINDALL_PROMPT_COLOR :: sdl.Color{126, 132, 150, 255} // unified muted gray

g_findall_visible: bool
@(private="file") g_findall_query:   [dynamic]u8
@(private="file") g_findall_results: [dynamic]Grep_Hit
@(private="file") g_findall_active:  int
@(private="file") g_findall_scroll:  int

findall_visible :: proc() -> bool {return g_findall_visible}

findall_show :: proc() {
	finder_hide() // mutually exclusive modals
	recent_hide()
	grep_open()
	clear(&g_findall_query)
	findall_clear_results()
	grep_request("") // empty → worker clears results; first match arrives via FFF_EVENT
	g_findall_active  = 0
	g_findall_scroll  = 0
	g_findall_visible = true
}

findall_hide :: proc() {
	g_findall_visible = false
	clear(&g_findall_query)
	grep_close()
}

@(private="file")
findall_clear_results :: proc() {
	for h in g_findall_results { delete(h.path); delete(h.text) }
	clear(&g_findall_results)
}

findall_destroy :: proc() {
	findall_clear_results()
	delete(g_findall_results)
	delete(g_findall_query)
}

// FFF_EVENT wake: copy the worker's latest grep hits into the render list.
findall_on_fff_event :: proc() {
	if !g_findall_visible do return
	grep_copy_results(&g_findall_results)
	if g_findall_active >= len(g_findall_results) {
		g_findall_active = max(0, len(g_findall_results) - 1)
	}
	max_scroll := max(0, len(g_findall_results) - FINDALL_MAX_VISIBLE)
	if g_findall_scroll > max_scroll do g_findall_scroll = max_scroll
}

@(private="file")
findall_post_query :: proc() {
	grep_request(string(g_findall_query[:]))
	g_findall_active = 0
	g_findall_scroll = 0
}

// Open the highlighted match's file and jump to (line, col).
@(private="file")
findall_activate :: proc() {
	if g_findall_active < 0 || g_findall_active >= len(g_findall_results) {
		findall_hide()
		return
	}
	hit := g_findall_results[g_findall_active]
	root := fff_current_root()
	sep := strings.has_suffix(root, "/") ? "" : "/"
	full := fmt.aprintf("%s%s%s", root, sep, hit.path, allocator = context.temp_allocator)
	line := hit.line
	col  := hit.col
	findall_hide()
	open_file_smart(full)
	ed := active_editor()
	line0 := max(0, line - 1)
	start := editor_nth_line_start(ed, line0)
	end := editor_line_end(ed, start)
	off := min(start + col, end)
	ed.cursor = off
	ed.anchor = off
	vim_scroll_cursor_to(ed, 1) // center the match
}

// ── Input ──

findall_handle_key :: proc(ev: sdl.KeyboardEvent) -> bool {
	if !g_findall_visible do return false
	switch ev.key {
	case sdl.K_ESCAPE:
		findall_hide()
	case sdl.K_RETURN, sdl.K_KP_ENTER:
		findall_activate()
	case sdl.K_BACKSPACE:
		if len(g_findall_query) > 0 {
			i := len(g_findall_query) - 1
			for i > 0 && (g_findall_query[i] & 0xC0) == 0x80 do i -= 1
			resize(&g_findall_query, i)
			findall_post_query()
		}
	case sdl.K_UP:
		if g_findall_active > 0 do g_findall_active -= 1
		if g_findall_active < g_findall_scroll do g_findall_scroll = g_findall_active
	case sdl.K_DOWN:
		if g_findall_active < len(g_findall_results) - 1 do g_findall_active += 1
		if g_findall_active >= g_findall_scroll + FINDALL_MAX_VISIBLE {
			g_findall_scroll = g_findall_active - FINDALL_MAX_VISIBLE + 1
		}
	}
	return true
}

findall_handle_text :: proc(text: string) -> bool {
	if !g_findall_visible do return false
	for i in 0 ..< len(text) do append(&g_findall_query, text[i])
	findall_post_query()
	return true
}

@(private="file")
findall_row_at :: proc(x, y: f32, l: Layout) -> int {
	r := findall_rect(l)
	row_h   := g_config.font.size + FINDALL_LINE_GAP
	input_y := r.y + FINDALL_PAD + row_h // below the title row
	list_y  := input_y + g_config.font.size + FINDALL_INPUT_GAP
	if x < r.x || x > r.x + r.w do return -1
	if y < list_y do return -1
	rel := int((y - list_y) / row_h)
	if rel < 0 || rel >= FINDALL_MAX_VISIBLE do return -1
	idx := g_findall_scroll + rel
	if idx < 0 || idx >= len(g_findall_results) do return -1
	return idx
}

findall_handle_button :: proc(ev: sdl.MouseButtonEvent, l: Layout) -> bool {
	if !g_findall_visible do return false
	if !ev.down do return true
	if ev.button != sdl.BUTTON_LEFT do return true
	if !point_in_rect({ev.x, ev.y}, findall_rect(l)) {
		findall_hide()
		return true
	}
	if idx := findall_row_at(ev.x, ev.y, l); idx >= 0 {
		g_findall_active = idx
		if ev.clicks >= 2 do findall_activate()
	}
	return true
}

findall_handle_motion :: proc(mx, my: f32, l: Layout) {
	if !g_findall_visible do return
	if idx := findall_row_at(mx, my, l); idx >= 0 do g_findall_active = idx
}

findall_handle_wheel :: proc(ev: sdl.MouseWheelEvent) -> bool {
	if !g_findall_visible do return false
	if ev.y == 0 do return true
	step := int(ev.y * 3)
	if step == 0 do step = ev.y > 0 ? 1 : -1
	g_findall_scroll -= step
	max_scroll := max(0, len(g_findall_results) - FINDALL_MAX_VISIBLE)
	g_findall_scroll = clamp(g_findall_scroll, 0, max_scroll)
	if g_findall_active < g_findall_scroll do g_findall_active = g_findall_scroll
	if g_findall_active >= g_findall_scroll + FINDALL_MAX_VISIBLE {
		g_findall_active = g_findall_scroll + FINDALL_MAX_VISIBLE - 1
	}
	return true
}

// ── Draw ──

@(private="file")
findall_rect :: proc(l: Layout) -> sdl.FRect {
	w := f32(880)
	if w > l.screen_w - 40 do w = l.screen_w - 40
	row_h := g_config.font.size + FINDALL_LINE_GAP
	rows := min(len(g_findall_results), FINDALL_MAX_VISIBLE)
	if rows == 0 do rows = 1
	// Two text rows above the list (the title bar + the query line).
	h := FINDALL_PAD * 2 + row_h * 2 + FINDALL_INPUT_GAP + f32(rows) * row_h
	if h > l.screen_h - 40 do h = l.screen_h - 40
	x := (l.screen_w - w) * 0.5
	y := (l.screen_h - h) * 0.5
	return {x, y, w, h}
}

@(private="file")
findall_draw_seg :: proc(s: string, x, y: f32, fg: sdl.Color, bg := MENU_BG_COLOR) -> f32 {
	if len(s) == 0 do return 0
	cstr := strings.clone_to_cstring(s, context.temp_allocator)
	return draw_text(cstr, x, y, fg, bg)
}

draw_findall :: proc(l: Layout) {
	if !g_findall_visible do return

	fill_rect({0, 0, l.screen_w, l.screen_h}, FINDALL_DIM_BG)

	r := findall_rect(l)
	fill_rect(r, MENU_BG_COLOR)
	bw: f32 = 1
	fill_rect({r.x, r.y, r.w, bw}, MENU_BORDER_COLOR)
	fill_rect({r.x, r.y + r.h - bw, r.w, bw}, MENU_BORDER_COLOR)
	fill_rect({r.x, r.y, bw, r.h}, MENU_BORDER_COLOR)
	fill_rect({r.x + r.w - bw, r.y, bw, r.h}, MENU_BORDER_COLOR)

	clip := sdl.Rect{i32(r.x + bw), i32(r.y + bw), i32(r.w - bw * 2), i32(r.h - bw * 2)}
	sdl.SetRenderClipRect(g_renderer, &clip)
	defer sdl.SetRenderClipRect(g_renderer, nil)

	row_h := g_config.font.size + FINDALL_LINE_GAP
	indexing, idx_files := fff_index_status()

	// Title row: "Find in Files" (left), status (right, dim).
	title_y := r.y + FINDALL_PAD
	findall_draw_seg("Find in Files", r.x + FINDALL_PAD, title_y, MENU_TEXT_COLOR)
	status: string
	if indexing {
		status = fmt.tprintf("indexing… %d", idx_files)
	} else if !fff_has_root() {
		status = "(open a file inside a project)"
	} else if len(g_findall_query) > 0 {
		status = fmt.tprintf("%d matches", len(g_findall_results))
	}
	if len(status) > 0 {
		sc := strings.clone_to_cstring(status, context.temp_allocator)
		draw_text(sc, r.x + r.w - FINDALL_PAD - ui_text_w(status), title_y, MENU_DIM_COLOR, MENU_BG_COLOR)
	}

	// Input row: prompt + query + caret.
	input_y := title_y + row_h
	pw := findall_draw_seg("> ", r.x + FINDALL_PAD, input_y, FINDALL_PROMPT_COLOR)
	qw: f32 = 0
	if len(g_findall_query) > 0 {
		qw = findall_draw_seg(string(g_findall_query[:]), r.x + FINDALL_PAD + pw, input_y, MENU_TEXT_COLOR)
	}
	fill_rect({r.x + FINDALL_PAD + pw + qw, input_y, 2, g_config.font.size}, g_theme.cursor_color)

	// Separator under the input.
	sep_y := input_y + g_config.font.size + FINDALL_INPUT_GAP * 0.5
	fill_rect({r.x + FINDALL_PAD, sep_y, r.w - FINDALL_PAD * 2, 1.0 / g_density}, MENU_BORDER_COLOR)

	list_y := input_y + g_config.font.size + FINDALL_INPUT_GAP
	if len(g_findall_results) == 0 {
		msg := ""
		if !indexing && len(g_findall_query) > 0 do msg = "(no matches)"
		if len(msg) > 0 do findall_draw_seg(msg, r.x + FINDALL_PAD, list_y, MENU_DIM_COLOR)
		return
	}

	end := min(g_findall_scroll + FINDALL_MAX_VISIBLE, len(g_findall_results))
	row := 0
	for i := g_findall_scroll; i < end; i += 1 {
		ry := list_y + f32(row) * row_h
		row += 1
		hit := g_findall_results[i]
		bg := MENU_BG_COLOR
		if i == g_findall_active {
			fill_rect({r.x + 2, ry, r.w - 4, row_h}, MENU_HOVER_COLOR)
			bg = MENU_HOVER_COLOR
		}
		x := r.x + FINDALL_PAD
		// path:line — dim location prefix.
		loc := fmt.tprintf("%s:%d  ", hit.path, hit.line)
		x += findall_draw_seg(loc, x, ry, FINDALL_PROMPT_COLOR, bg)

		// Matched line, left-trimmed, with the match span highlighted.
		text := hit.text
		trim := 0
		for trim < len(text) && (text[trim] == ' ' || text[trim] == '\t') do trim += 1
		ms := max(0, hit.m_start - trim)
		me := max(ms, hit.m_end - trim)
		body := text[trim:]
		if me > len(body) do me = len(body)
		if ms > len(body) do ms = len(body)
		if ms > 0          do x += findall_draw_seg(body[:ms],  x, ry, MENU_TEXT_COLOR, bg)
		if me > ms         do x += findall_draw_seg(body[ms:me], x, ry, g_theme.constant_color, bg) // match
		if me < len(body)  do x += findall_draw_seg(body[me:],  x, ry, MENU_TEXT_COLOR, bg)
	}

	// Scrollbar.
	if len(g_findall_results) > FINDALL_MAX_VISIBLE {
		track_w: f32 = 6
		track_x := r.x + r.w - track_w - bw - 2
		track_y := list_y
		visible := f32(FINDALL_MAX_VISIBLE)
		total   := f32(len(g_findall_results))
		track_h := visible * row_h
		fill_rect({track_x, track_y, track_w, track_h}, g_theme.sb_track_color)
		thumb_h := max(SB_MIN_THUMB, (visible / total) * track_h)
		max_scroll := total - visible
		t: f32 = 0
		if max_scroll > 0 do t = f32(g_findall_scroll) / max_scroll
		thumb_y := track_y + t * (track_h - thumb_h)
		fill_rect({track_x, thumb_y, track_w, thumb_h}, g_theme.sb_thumb_color)
	}
}
