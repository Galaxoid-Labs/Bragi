package bragi

import "core:c"
import "core:fmt"
import "core:os"
import "core:strings"
import sdl "vendor:sdl3"
import ttf "vendor:sdl3/ttf"

// Open-Recent popup: a dismissable, menu-styled overlay listing recently
// opened workspaces (folders) and standalone files, most-recent-first.
// Auto-shown on a bare launch (no file / dir arg); also summoned with
// Cmd/Ctrl+R or `:recent`. Esc / click-away closes; Enter opens the
// highlighted entry (folder → set_workspace, file → open_file_smart).
//
// A file opened INSIDE the open workspace is never recorded as its own
// entry — the folder already covers it. Only loose files (no workspace,
// or outside it) become file entries. See recent_record_file.
//
// Persisted one absolute path per line in a `recent` file next to
// config.ini. The kind (dir vs file) is recomputed from disk on load, so
// entries whose path no longer exists silently prune themselves.

RECENT_MAX         :: 12   // per group (folders / files) cap, on disk + in memory
RECENT_MAX_VISIBLE :: 16   // rows shown before the list scrolls
RECENT_PAD         :: 16.0
RECENT_LINE_GAP    :: 4.0
RECENT_INPUT_GAP   :: 8.0
RECENT_ENTRY_INDENT :: 12.0
RECENT_DIM_BG      :: sdl.Color{0, 0, 0, 140}

@(private="file")
RECENT_PREFIX_COLOR :: sdl.Color{126, 132, 150, 255} // unified muted gray

Recent_Entry :: struct {
	path:   string, // owned; absolute
	is_dir: bool,
}

g_recents:        [dynamic]Recent_Entry // most-recent-first; mixed dirs/files
g_recent_visible: bool

@(private="file") g_recent_active: int // selectable index (dirs first, then files)
@(private="file") g_recent_scroll: int // first visible display line

// ──────────────────────────────────────────────────────────────────
// Display model — headers + entries, built fresh each frame (cheap; the
// list is capped at 2*RECENT_MAX entries plus two section headers).
// ──────────────────────────────────────────────────────────────────

@(private="file")
Recent_Line :: struct {
	header: bool,
	text:   string, // temp; header label or entry display path
	sel:    int,    // selectable index for entries; -1 for headers
	entry:  int,    // index into g_recents (valid when !header)
}

@(private="file")
recent_build_lines :: proc() -> []Recent_Line {
	lines: [dynamic]Recent_Line
	lines.allocator = context.temp_allocator
	sel := 0

	any_dir := false
	for e in g_recents do if e.is_dir { any_dir = true; break }
	if any_dir {
		append(&lines, Recent_Line{header = true, text = "Folders", sel = -1})
		for e, i in g_recents {
			if !e.is_dir do continue
			append(&lines, Recent_Line{text = recent_display_path(e.path), sel = sel, entry = i})
			sel += 1
		}
	}

	any_file := false
	for e in g_recents do if !e.is_dir { any_file = true; break }
	if any_file {
		append(&lines, Recent_Line{header = true, text = "Files", sel = -1})
		for e, i in g_recents {
			if e.is_dir do continue
			append(&lines, Recent_Line{text = recent_display_path(e.path), sel = sel, entry = i})
			sel += 1
		}
	}
	return lines[:]
}

// g_recents indices in display order (dirs then files) — the order
// g_recent_active indexes into.
@(private="file")
recent_order :: proc() -> []int {
	out: [dynamic]int
	out.allocator = context.temp_allocator
	for e, i in g_recents do if e.is_dir do append(&out, i)
	for e, i in g_recents do if !e.is_dir do append(&out, i)
	return out[:]
}

// Collapse a leading $HOME to "~" for display. Temp-allocated.
@(private="file")
recent_display_path :: proc(path: string) -> string {
	home := recent_home()
	if len(home) > 0 && strings.has_prefix(path, home) {
		return strings.concatenate({"~", path[len(home):]}, context.temp_allocator)
	}
	return path
}

@(private="file")
recent_home :: proc() -> string {
	when ODIN_OS == .Windows {
		return os.get_env("USERPROFILE", context.temp_allocator)
	} else {
		return os.get_env("HOME", context.temp_allocator)
	}
}

// ──────────────────────────────────────────────────────────────────
// Show / hide / activate
// ──────────────────────────────────────────────────────────────────

recent_visible :: proc() -> bool {return g_recent_visible}

recent_show :: proc() {
	if len(g_recents) == 0 {
		set_status_message("no recent items", .Info)
		return
	}
	finder_hide() // the finder and recents are mutually exclusive modals
	g_recent_active  = 0
	g_recent_scroll  = 0
	g_recent_visible = true
}

recent_hide :: proc() {g_recent_visible = false}

recent_toggle :: proc() {
	if g_recent_visible do recent_hide()
	else do recent_show()
}

@(private="file")
recent_activate :: proc() {
	order := recent_order()
	if g_recent_active < 0 || g_recent_active >= len(order) {
		recent_hide()
		return
	}
	e := g_recents[order[g_recent_active]]
	// Clone before hide/open — opening a file mutates g_editors but not
	// g_recents, yet keeping our own copy is cheap insurance.
	path   := strings.clone(e.path, context.temp_allocator)
	is_dir := e.is_dir
	recent_hide()
	if is_dir {
		if !set_workspace(path) {
			set_status_message(fmt.tprintf("E: not a directory: %s", path), .Error)
		}
	} else {
		open_file_smart(path)
	}
}

// ──────────────────────────────────────────────────────────────────
// Input
// ──────────────────────────────────────────────────────────────────

recent_handle_key :: proc(ev: sdl.KeyboardEvent) -> bool {
	if !g_recent_visible do return false
	count := len(g_recents)
	switch ev.key {
	case sdl.K_ESCAPE:
		recent_hide()
	case sdl.K_RETURN, sdl.K_KP_ENTER:
		recent_activate()
	case sdl.K_UP, sdl.K_K:
		if g_recent_active > 0 do g_recent_active -= 1
	case sdl.K_DOWN, sdl.K_J:
		if g_recent_active < count - 1 do g_recent_active += 1
	}
	recent_clamp_scroll()
	return true
}

// Popup has no text input; swallow text events while it's up so navigation
// letters (j / k) don't leak into the editor underneath.
recent_handle_text :: proc(text: string) -> bool {
	return g_recent_visible
}

@(private="file")
recent_clamp_scroll :: proc() {
	lines := recent_build_lines()
	active_line := -1
	for ln, i in lines {
		if !ln.header && ln.sel == g_recent_active {
			active_line = i
			break
		}
	}
	if active_line >= 0 {
		if active_line < g_recent_scroll do g_recent_scroll = active_line
		if active_line >= g_recent_scroll + RECENT_MAX_VISIBLE {
			g_recent_scroll = active_line - RECENT_MAX_VISIBLE + 1
		}
	}
	max_scroll := max(0, len(lines) - RECENT_MAX_VISIBLE)
	g_recent_scroll = clamp(g_recent_scroll, 0, max_scroll)
}

// Selectable index under (x, y), or -1 if the point isn't over an entry row
// (headers and empty space return -1).
@(private="file")
recent_row_at :: proc(x, y: f32, l: Layout) -> int {
	r := recent_rect(l)
	if x < r.x || x > r.x + r.w do return -1
	row_h  := g_config.font.size + RECENT_LINE_GAP
	list_y := r.y + RECENT_PAD + row_h + RECENT_INPUT_GAP
	if y < list_y do return -1
	rel := int((y - list_y) / row_h)
	if rel < 0 || rel >= RECENT_MAX_VISIBLE do return -1
	lines := recent_build_lines()
	li := g_recent_scroll + rel
	if li < 0 || li >= len(lines) do return -1
	if lines[li].header do return -1
	return lines[li].sel
}

recent_handle_button :: proc(ev: sdl.MouseButtonEvent, l: Layout) -> bool {
	if !g_recent_visible do return false
	if !ev.down do return true
	if ev.button != sdl.BUTTON_LEFT do return true
	if !point_in_rect({ev.x, ev.y}, recent_rect(l)) {
		recent_hide()
		return true
	}
	if idx := recent_row_at(ev.x, ev.y, l); idx >= 0 {
		g_recent_active = idx
		recent_activate() // single click opens — it's a short, deliberate list
	}
	return true
}

recent_handle_motion :: proc(mx, my: f32, l: Layout) {
	if !g_recent_visible do return
	if idx := recent_row_at(mx, my, l); idx >= 0 do g_recent_active = idx
}

recent_handle_wheel :: proc(ev: sdl.MouseWheelEvent) -> bool {
	if !g_recent_visible do return false
	if ev.y == 0 do return true
	step := int(ev.y * 3)
	if step == 0 do step = ev.y > 0 ? 1 : -1
	g_recent_scroll -= step
	lines := recent_build_lines()
	max_scroll := max(0, len(lines) - RECENT_MAX_VISIBLE)
	g_recent_scroll = clamp(g_recent_scroll, 0, max_scroll)
	return true
}

// ──────────────────────────────────────────────────────────────────
// Recording (hooked from set_workspace + the file-open paths)
// ──────────────────────────────────────────────────────────────────

recent_record_dir :: proc(path: string) {
	if len(path) > 0 do recent_record(path, true)
}

recent_record_file :: proc(path: string) {
	if len(path) == 0 do return
	abs := recent_abs(path)
	// A file inside the open workspace is covered by the folder entry —
	// don't clutter the list with it.
	if len(g_workspace_root) > 0 && recent_path_under(abs, g_workspace_root) do return
	// Don't record the config file opened via :config.
	if cfg := config_path(context.temp_allocator); len(cfg) > 0 && recent_paths_equal(abs, cfg) do return
	recent_record(abs, false)
}

@(private="file")
recent_record :: proc(path: string, is_dir: bool) {
	abs := recent_abs(path)
	if i := recent_index_of(abs); i >= 0 {
		delete(g_recents[i].path)
		ordered_remove(&g_recents, i)
	}
	inject_at(&g_recents, 0, Recent_Entry{strings.clone(abs), is_dir})
	recent_trim()
	recent_save()
}

// Keep at most RECENT_MAX of each kind, dropping the oldest past the cap.
@(private="file")
recent_trim :: proc() {
	dirs, files := 0, 0
	for i := 0; i < len(g_recents); {
		over := false
		if g_recents[i].is_dir {
			dirs += 1
			over = dirs > RECENT_MAX
		} else {
			files += 1
			over = files > RECENT_MAX
		}
		if over {
			delete(g_recents[i].path)
			ordered_remove(&g_recents, i)
		} else {
			i += 1
		}
	}
}

// ──────────────────────────────────────────────────────────────────
// Persistence
// ──────────────────────────────────────────────────────────────────

// `recent` file next to config.ini (same per-platform prefs dir).
@(private="file")
recent_store_path :: proc(allocator := context.allocator) -> string {
	cfg := config_path(context.temp_allocator)
	if len(cfg) == 0 do return ""
	dir := cfg
	for i := len(cfg) - 1; i >= 0; i -= 1 {
		if cfg[i] == '/' || cfg[i] == '\\' {
			dir = cfg[:i + 1]
			break
		}
	}
	return strings.concatenate({dir, "recent"}, allocator)
}

recent_load :: proc() {
	path := recent_store_path(context.temp_allocator)
	if len(path) == 0 do return
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil do return
	for line in strings.split_lines(string(data), context.temp_allocator) {
		p := strings.trim_space(line)
		if len(p) == 0 do continue
		is_dir := os.is_dir(p)
		if !is_dir && !os.exists(p) do continue // pruned: gone from disk
		if recent_index_of(p) >= 0 do continue   // de-dupe defensively
		append(&g_recents, Recent_Entry{strings.clone(p), is_dir})
	}
	recent_trim()
}

@(private="file")
recent_save :: proc() {
	path := recent_store_path(context.temp_allocator)
	if len(path) == 0 do return
	b := strings.builder_make(context.temp_allocator)
	for e in g_recents {
		strings.write_string(&b, e.path)
		strings.write_byte(&b, '\n')
	}
	if werr := os.write_entire_file(path, transmute([]u8)strings.to_string(b)); werr != nil {
		// Best-effort: a failed write just means recents don't persist this
		// session; nothing user-facing.
	}
}

recent_destroy :: proc() {
	for e in g_recents do delete(e.path)
	delete(g_recents)
	g_recents = nil
}

// ──────────────────────────────────────────────────────────────────
// Path helpers (case-insensitive + separator-normalized on Windows)
// ──────────────────────────────────────────────────────────────────

@(private="file")
recent_abs :: proc(path: string) -> string {
	if a, aerr := os.get_absolute_path(path, context.temp_allocator); aerr == nil do return a
	return path
}

@(private="file")
recent_norm :: proc(path: string) -> string {
	when ODIN_OS == .Windows {
		lower := strings.to_lower(path, context.temp_allocator)
		out, _ := strings.replace_all(lower, "/", "\\", context.temp_allocator)
		return out
	} else {
		return path
	}
}

@(private="file")
recent_paths_equal :: proc(a, b: string) -> bool {
	return recent_norm(a) == recent_norm(b)
}

@(private="file")
recent_path_under :: proc(child, parent: string) -> bool {
	c := recent_norm(child)
	p := recent_norm(parent)
	if len(c) < len(p) || !strings.has_prefix(c, p) do return false
	if len(c) == len(p) do return true
	sep := c[len(p)]
	return sep == '/' || sep == '\\'
}

@(private="file")
recent_index_of :: proc(path: string) -> int {
	for e, i in g_recents do if recent_paths_equal(e.path, path) do return i
	return -1
}

// ──────────────────────────────────────────────────────────────────
// Draw
// ──────────────────────────────────────────────────────────────────

// Width of `s` in the UI font (logical px). Mirrors menu.odin's
// measure_text_w, which is file-private there.
@(private="file")
recent_text_w :: proc(s: string) -> f32 {
	if len(s) == 0 do return 0
	cstr := strings.clone_to_cstring(s, context.temp_allocator)
	w_px: c.int
	ttf.GetStringSize(g_font, cstr, 0, &w_px, nil)
	return f32(w_px) / g_density
}

@(private="file")
recent_rect :: proc(l: Layout) -> sdl.FRect {
	lines := recent_build_lines()
	row_h := g_config.font.size + RECENT_LINE_GAP
	w: f32 = 640
	if w > l.screen_w - 40 do w = l.screen_w - 40
	visible := min(len(lines), RECENT_MAX_VISIBLE)
	if visible == 0 do visible = 1
	// Title row + separator gap + the (scrolling) list.
	h := RECENT_PAD * 2 + row_h + RECENT_INPUT_GAP + f32(visible) * row_h
	if h > l.screen_h - 40 do h = l.screen_h - 40
	x := (l.screen_w - w) * 0.5
	y := (l.screen_h - h) * 0.5
	return {x, y, w, h}
}

draw_recent :: proc(l: Layout) {
	if !g_recent_visible do return

	fill_rect({0, 0, l.screen_w, l.screen_h}, RECENT_DIM_BG)

	r := recent_rect(l)
	fill_rect(r, MENU_BG_COLOR)
	bw: f32 = 1
	fill_rect({r.x, r.y, r.w, bw}, MENU_BORDER_COLOR)
	fill_rect({r.x, r.y + r.h - bw, r.w, bw}, MENU_BORDER_COLOR)
	fill_rect({r.x, r.y, bw, r.h}, MENU_BORDER_COLOR)
	fill_rect({r.x + r.w - bw, r.y, bw, r.h}, MENU_BORDER_COLOR)

	clip := sdl.Rect{i32(r.x + bw), i32(r.y + bw), i32(r.w - bw * 2), i32(r.h - bw * 2)}
	sdl.SetRenderClipRect(g_renderer, &clip)
	defer sdl.SetRenderClipRect(g_renderer, nil)

	row_h := g_config.font.size + RECENT_LINE_GAP

	// Title row: "Recent" left, dim hint right-aligned.
	title_y := r.y + RECENT_PAD
	title_cstr := strings.clone_to_cstring("Recent", context.temp_allocator)
	draw_text(title_cstr, r.x + RECENT_PAD, title_y, MENU_TEXT_COLOR, MENU_BG_COLOR)
	hint := "esc close · enter open"
	hint_w := recent_text_w(hint)
	hint_cstr := strings.clone_to_cstring(hint, context.temp_allocator)
	draw_text(hint_cstr, r.x + r.w - RECENT_PAD - hint_w, title_y, MENU_DIM_COLOR, MENU_BG_COLOR)

	// Separator under the title.
	sep_y := r.y + RECENT_PAD + row_h
	fill_rect({r.x + RECENT_PAD, sep_y, r.w - RECENT_PAD * 2, 1.0 / g_density}, MENU_BORDER_COLOR)

	lines := recent_build_lines()
	list_y := r.y + RECENT_PAD + row_h + RECENT_INPUT_GAP
	end := min(g_recent_scroll + RECENT_MAX_VISIBLE, len(lines))
	vis := 0
	for li := g_recent_scroll; li < end; li += 1 {
		ry := list_y + f32(vis) * row_h
		vis += 1
		ln := lines[li]
		if ln.header {
			hc := strings.clone_to_cstring(ln.text, context.temp_allocator)
			draw_text(hc, r.x + RECENT_PAD, ry, RECENT_PREFIX_COLOR, MENU_BG_COLOR)
			continue
		}
		bg := MENU_BG_COLOR
		if ln.sel == g_recent_active {
			fill_rect({r.x + 2, ry, r.w - 4, row_h}, MENU_HOVER_COLOR)
			bg = MENU_HOVER_COLOR
		}
		// Dim the parent-dir prefix, bright the basename — matches the finder.
		disp := ln.text
		base := path_basename(disp)
		x := r.x + RECENT_PAD + RECENT_ENTRY_INDENT
		if len(base) < len(disp) {
			prefix := disp[:len(disp) - len(base)]
			pc := strings.clone_to_cstring(prefix, context.temp_allocator)
			x += draw_text(pc, x, ry, RECENT_PREFIX_COLOR, bg)
		}
		bc := strings.clone_to_cstring(base, context.temp_allocator)
		draw_text(bc, x, ry, MENU_TEXT_COLOR, bg)
	}

	// Scrollbar (visual; wheel does the scrolling).
	if len(lines) > RECENT_MAX_VISIBLE {
		track_w: f32 = 6
		track_x := r.x + r.w - track_w - bw - 2
		track_y := list_y
		visible := f32(RECENT_MAX_VISIBLE)
		total   := f32(len(lines))
		track_h := visible * row_h
		fill_rect({track_x, track_y, track_w, track_h}, g_theme.sb_track_color)

		thumb_h := max(SB_MIN_THUMB, (visible / total) * track_h)
		max_scroll := total - visible
		t: f32 = 0
		if max_scroll > 0 do t = f32(g_recent_scroll) / max_scroll
		thumb_y := track_y + t * (track_h - thumb_h)
		fill_rect({track_x, thumb_y, track_w, thumb_h}, g_theme.sb_thumb_color)
	}
}
