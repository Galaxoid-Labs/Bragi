package bragi

import "core:fmt"
import "core:os"
import "core:strings"
import sdl "vendor:sdl3"

// Directory navigator modal. Shift+Space opens it pointing at the
// editor's cwd; the modal shows that directory's contents. Type to
// fuzzy-filter the current listing, Up/Down (or j/k) to move, Enter to
// dive into a directory or open a file. `..` (always present unless
// you're at the filesystem root) goes up one level — Backspace on an
// empty query does the same. Esc dismisses.

FINDER_PAD          :: 16.0
FINDER_INPUT_GAP    :: 8.0
FINDER_LINE_GAP     :: 4.0
FINDER_MAX_VISIBLE  :: 18
FINDER_DIM_BG       :: sdl.Color{0, 0, 0, 140}

@(private="file")
FINDER_PROMPT_COLOR :: sdl.Color{120, 125, 140, 255}
@(private="file")
FINDER_DIR_COLOR    :: sdl.Color{ 97, 175, 239, 255} // blue, like the help-screen key color

g_finder_visible:  bool
g_finder_dir:      string                  // owned, absolute path of current dir
g_finder_query:    [dynamic]u8
g_finder_entries:  [dynamic]Finder_Entry   // owned, listing of g_finder_dir
g_finder_results:  [dynamic]Finder_Result
g_finder_active:   int
g_finder_scroll:   int

Finder_Entry :: struct {
	name:   string, // owned; "/"-suffixed for directories so display + matching reuse it
	is_dir: bool,
}

Finder_Result :: struct {
	entry: Finder_Entry, // borrowed from g_finder_entries
	score: int,
}

finder_show :: proc() {
	if len(g_finder_dir) == 0 {
		// Default to the user's home directory rather than the app's cwd.
		// When Bragi is launched from Finder / Spotlight / a launcher,
		// cwd is something opaque like `/` — home is what the user
		// actually wants to navigate from.
		g_finder_dir = strings.clone(default_finder_dir())
	}
	finder_list_dir()
	clear(&g_finder_query)
	finder_recompute()
	g_finder_active  = 0
	g_finder_scroll  = 0
	g_finder_visible = true
}

// Resolve the user's home directory. Falls back to the editor's cwd when
// the relevant env var isn't set (sandboxed contexts, etc.). Returned
// string lives in the temp allocator — caller clones if it needs to
// outlast the iteration.
@(private="file")
default_finder_dir :: proc() -> string {
	when ODIN_OS == .Windows {
		profile := os.get_env("USERPROFILE", context.temp_allocator)
		if len(profile) > 0 do return profile
		// Fallback: HOMEDRIVE + HOMEPATH.
		drive := os.get_env("HOMEDRIVE", context.temp_allocator)
		path  := os.get_env("HOMEPATH",  context.temp_allocator)
		if len(drive) > 0 && len(path) > 0 {
			return fmt.aprintf("%s%s", drive, path, allocator = context.temp_allocator)
		}
	} else {
		home := os.get_env("HOME", context.temp_allocator)
		if len(home) > 0 do return home
	}
	cwd, _ := os.get_working_directory(context.temp_allocator)
	return cwd
}

finder_hide :: proc() {
	g_finder_visible = false
	clear(&g_finder_query)
}

@(private="file")
free_entries :: proc() {
	for e in g_finder_entries do delete(e.name)
	clear(&g_finder_entries)
}

// Final teardown — releases every owned allocation the finder accumulates
// over its lifetime. Called from main()'s shutdown defer; not used at
// runtime (finder_hide leaves things populated for fast re-show).
finder_destroy :: proc() {
	free_entries()
	delete(g_finder_entries)
	delete(g_finder_results)
	delete(g_finder_query)
	if len(g_finder_dir) > 0 {
		delete(g_finder_dir)
		g_finder_dir = ""
	}
}

// Replace g_finder_dir with `new_dir` (taking ownership) and re-list.
@(private="file")
finder_navigate :: proc(new_dir: string) {
	if len(g_finder_dir) > 0 do delete(g_finder_dir)
	g_finder_dir = new_dir
	finder_list_dir()
	clear(&g_finder_query)
	finder_recompute()
	g_finder_active = 0
	g_finder_scroll = 0
}

// Return the parent of `dir`, or `dir` itself if we're already at the
// filesystem root. Strips a trailing slash, walks back to the last `/`.
@(private="file")
parent_dir :: proc(dir: string) -> string {
	trimmed := strings.trim_right(dir, "/")
	if len(trimmed) == 0 do return strings.clone("/")
	idx := strings.last_index_byte(trimmed, '/')
	if idx <= 0 do return strings.clone("/")
	return strings.clone(trimmed[:idx])
}

// Returns a temp-allocated string. The header comment used to claim
// this without enforcing it — defaulting to the regular allocator was
// silently leaking on every directory navigate / file open. Both call
// sites already treat the result as temp-owned, so honouring that
// here is the right fix.
@(private="file")
path_join :: proc(a, b: string) -> string {
	if strings.has_suffix(a, "/") {
		return fmt.aprintf("%s%s", a, b, allocator = context.temp_allocator)
	}
	return fmt.aprintf("%s/%s", a, b, allocator = context.temp_allocator)
}

// List g_finder_dir. Prepends `..` unless we're at the root. Hidden
// entries (dotfiles / dotdirs) are skipped.
@(private="file")
finder_list_dir :: proc() {
	free_entries()

	// Always offer "go up" unless we're at "/".
	if g_finder_dir != "/" {
		append(&g_finder_entries, Finder_Entry{name = strings.clone("../"), is_dir = true})
	}

	cstr := strings.clone_to_cstring(g_finder_dir, context.temp_allocator)
	_ = cstr // (kept around so the Handle is valid for diagnostic prints)

	fd, oerr := os.open(g_finder_dir)
	if oerr != nil do return
	defer os.close(fd)

	entries, rerr := os.read_dir(fd, -1, context.temp_allocator)
	if rerr != nil do return

	dirs:  [dynamic]Finder_Entry
	files: [dynamic]Finder_Entry
	dirs  = make([dynamic]Finder_Entry, context.temp_allocator)
	files = make([dynamic]Finder_Entry, context.temp_allocator)

	for entry in entries {
		if strings.has_prefix(entry.name, ".") do continue
		name: string
		if entry.type == .Directory {
			name = strings.clone(fmt.aprintf("%s/", entry.name, allocator = context.temp_allocator))
			append(&dirs, Finder_Entry{name = name, is_dir = true})
		} else {
			append(&files, Finder_Entry{name = strings.clone(entry.name), is_dir = false})
		}
	}

	// Alphabetical order within each group; dirs before files.
	sort_entries_alpha(dirs[:])
	sort_entries_alpha(files[:])
	for d in dirs  do append(&g_finder_entries, d)
	for f in files do append(&g_finder_entries, f)
}

@(private="file")
sort_entries_alpha :: proc(s: []Finder_Entry) {
	for i in 1 ..< len(s) {
		x := s[i]
		j := i
		for j > 0 && strings.compare(s[j - 1].name, x.name) > 0 {
			s[j] = s[j - 1]
			j -= 1
		}
		s[j] = x
	}
}

// Subsequence match with bonuses for word-boundary hits and consecutive
// runs. Case-insensitive (ASCII).
@(private="file")
fuzzy_score :: proc(query, target: string) -> (score: int, matched: bool) {
	if len(query) == 0 do return 0, true
	qi := 0
	last_match := -1
	for ti in 0 ..< len(target) {
		if qi >= len(query) do break
		ql := query[qi]
		tl := target[ti]
		if ql >= 'A' && ql <= 'Z' do ql += 32
		if tl >= 'A' && tl <= 'Z' do tl += 32
		if ql == tl {
			score += 10
			if last_match == ti - 1 do score += 5
			if ti == 0 {
				score += 8
			} else {
				p := target[ti - 1]
				if p == '/' || p == '_' || p == '-' || p == '.' do score += 8
			}
			last_match = ti
			qi += 1
		}
	}
	if qi < len(query) do return 0, false
	score -= len(target) / 4
	return score, true
}

@(private="file")
finder_recompute :: proc() {
	clear(&g_finder_results)
	query := string(g_finder_query[:])

	if len(query) == 0 {
		for e in g_finder_entries {
			append(&g_finder_results, Finder_Result{entry = e, score = 0})
		}
		return
	}

	for e in g_finder_entries {
		score, ok := fuzzy_score(query, e.name)
		if !ok do continue
		append(&g_finder_results, Finder_Result{entry = e, score = score})
	}

	// Insertion sort by descending score; tiny n.
	n := len(g_finder_results)
	for i in 1 ..< n {
		x := g_finder_results[i]
		j := i
		for j > 0 && g_finder_results[j - 1].score < x.score {
			g_finder_results[j] = g_finder_results[j - 1]
			j -= 1
		}
		g_finder_results[j] = x
	}
}

// Activate the highlighted result. Directories navigate; files open.
@(private="file")
finder_activate :: proc() {
	if g_finder_active >= len(g_finder_results) {
		finder_hide()
		return
	}
	entry := g_finder_results[g_finder_active].entry

	if entry.is_dir {
		// `..` and named subdirs both navigate. The "name" field for a
		// dir already has a trailing `/`, so strip it before joining.
		raw_name := entry.name
		if entry.name == "../" {
			finder_navigate(parent_dir(g_finder_dir))
			return
		}
		clean := strings.trim_right(raw_name, "/")
		new_dir := path_join(g_finder_dir, clean)
		// path_join uses temp allocator; clone for ownership.
		finder_navigate(strings.clone(new_dir))
		return
	}

	// File: open via the standard "smart" path so blank panes get
	// replaced and busy ones get split.
	full := path_join(g_finder_dir, entry.name)
	cloned := strings.clone(full, context.temp_allocator)
	finder_hide()
	open_file_smart(cloned)
}

finder_handle_key :: proc(ev: sdl.KeyboardEvent) -> bool {
	if !g_finder_visible do return false
	switch ev.key {
	case sdl.K_ESCAPE:
		finder_hide()
	case sdl.K_RETURN:
		finder_activate()
	case sdl.K_BACKSPACE:
		if len(g_finder_query) > 0 {
			i := len(g_finder_query) - 1
			for i > 0 && (g_finder_query[i] & 0xC0) == 0x80 do i -= 1
			resize(&g_finder_query, i)
			finder_recompute()
			g_finder_active = 0
			g_finder_scroll = 0
		} else {
			finder_navigate(parent_dir(g_finder_dir))
		}
	case sdl.K_LEFT:
		// Quick "go up" without clearing the query first.
		finder_navigate(parent_dir(g_finder_dir))
	case sdl.K_RIGHT:
		// If the active row is a directory, dive in.
		if g_finder_active < len(g_finder_results) && g_finder_results[g_finder_active].entry.is_dir {
			finder_activate()
		}
	case sdl.K_UP, sdl.K_K:
		if g_finder_active > 0 do g_finder_active -= 1
		if g_finder_active < g_finder_scroll do g_finder_scroll = g_finder_active
	case sdl.K_DOWN, sdl.K_J:
		if g_finder_active < len(g_finder_results) - 1 do g_finder_active += 1
		if g_finder_active >= g_finder_scroll + FINDER_MAX_VISIBLE {
			g_finder_scroll = g_finder_active - FINDER_MAX_VISIBLE + 1
		}
	}
	return true
}

finder_handle_text :: proc(text: string) -> bool {
	if !g_finder_visible do return false
	for i in 0 ..< len(text) {
		append(&g_finder_query, text[i])
	}
	finder_recompute()
	g_finder_active = 0
	g_finder_scroll = 0
	return true
}

// Hit-test the result list. Returns the result index under (x, y), or
// -1 if the point isn't over a list row.
@(private="file")
finder_row_at :: proc(x, y: f32, l: Layout) -> int {
	r := finder_rect(l)
	row_h    := g_config.font.size + FINDER_LINE_GAP
	dir_y    := r.y + FINDER_PAD
	input_y  := dir_y + row_h
	list_y   := input_y + g_config.font.size + FINDER_INPUT_GAP
	if x < r.x || x > r.x + r.w do return -1
	if y < list_y do return -1

	rel := int((y - list_y) / row_h)
	if rel < 0 || rel >= FINDER_MAX_VISIBLE do return -1

	idx := g_finder_scroll + rel
	if idx < 0 || idx >= len(g_finder_results) do return -1
	return idx
}

finder_handle_button :: proc(ev: sdl.MouseButtonEvent, l: Layout) -> bool {
	if !g_finder_visible do return false
	// We only act on the down-stroke. Up is swallowed so it doesn't fall
	// through to the editor underneath.
	if !ev.down do return true
	if ev.button != sdl.BUTTON_LEFT do return true

	if !point_in_rect({ev.x, ev.y}, finder_rect(l)) {
		finder_hide()
		return true
	}

	if idx := finder_row_at(ev.x, ev.y, l); idx >= 0 {
		g_finder_active = idx
		// SDL3's `clicks` field reports the click count from the OS's
		// double-click detector — 2 = double, 3 = triple, etc. We
		// activate (open / dive) on the second click.
		if ev.clicks >= 2 do finder_activate()
	}
	return true
}

// Backwards-compat: still called from older code paths that only passed
// (x, y). Treats it as a single click.
finder_handle_click :: proc(x, y: f32, l: Layout) -> bool {
	if !g_finder_visible do return false
	if !point_in_rect({x, y}, finder_rect(l)) do finder_hide()
	return true
}

finder_handle_wheel :: proc(ev: sdl.MouseWheelEvent) -> bool {
	if !g_finder_visible do return false
	if ev.y == 0 do return true
	// Convention matches the editor's: positive y scrolls content up.
	step := int(ev.y * 3)
	if step == 0 do step = ev.y > 0 ? 1 : -1
	g_finder_scroll -= step
	max_scroll := max(0, len(g_finder_results) - FINDER_MAX_VISIBLE)
	g_finder_scroll = clamp(g_finder_scroll, 0, max_scroll)
	if g_finder_active < g_finder_scroll do g_finder_active = g_finder_scroll
	if g_finder_active >= g_finder_scroll + FINDER_MAX_VISIBLE {
		g_finder_active = g_finder_scroll + FINDER_MAX_VISIBLE - 1
	}
	return true
}

@(private="file")
finder_rect :: proc(l: Layout) -> sdl.FRect {
	w := f32(720)
	if w > l.screen_w - 40 do w = l.screen_w - 40
	line_h := g_config.font.size + FINDER_LINE_GAP
	rows := min(len(g_finder_results), FINDER_MAX_VISIBLE)
	if rows == 0 do rows = 1
	// Two text rows above the list (the dir path + the query line).
	h := FINDER_PAD * 2 + (g_config.font.size + FINDER_LINE_GAP) * 2 + FINDER_INPUT_GAP + f32(rows) * line_h
	if h > l.screen_h - 40 do h = l.screen_h - 40
	x := (l.screen_w - w) * 0.5
	y := (l.screen_h - h) * 0.5
	return sdl.FRect{x, y, w, h}
}

draw_finder :: proc(l: Layout) {
	if !g_finder_visible do return

	fill_rect({0, 0, l.screen_w, l.screen_h}, FINDER_DIM_BG)

	r := finder_rect(l)
	fill_rect(r, MENU_BG_COLOR)
	bw: f32 = 1
	fill_rect({r.x,                r.y,                r.w, bw },  MENU_BORDER_COLOR)
	fill_rect({r.x,                r.y + r.h - bw,     r.w, bw },  MENU_BORDER_COLOR)
	fill_rect({r.x,                r.y,                bw,  r.h},  MENU_BORDER_COLOR)
	fill_rect({r.x + r.w - bw,     r.y,                bw,  r.h},  MENU_BORDER_COLOR)

	clip := sdl.Rect{
		i32(r.x + bw),
		i32(r.y + bw),
		i32(r.w - bw * 2),
		i32(r.h - bw * 2),
	}
	sdl.SetRenderClipRect(g_renderer, &clip)
	defer sdl.SetRenderClipRect(g_renderer, nil)

	row_h := g_config.font.size + FINDER_LINE_GAP

	// Line 1: current directory path (dim).
	dir_y := r.y + FINDER_PAD
	dir_cstr := strings.clone_to_cstring(g_finder_dir, context.temp_allocator)
	draw_text(dir_cstr, r.x + FINDER_PAD, dir_y, FINDER_PROMPT_COLOR, MENU_BG_COLOR)

	// Line 2: prompt + query + caret.
	input_y := dir_y + row_h
	prompt_cstr := strings.clone_to_cstring("> ", context.temp_allocator)
	pw := draw_text(prompt_cstr, r.x + FINDER_PAD, input_y, FINDER_PROMPT_COLOR, MENU_BG_COLOR)
	qw: f32 = 0
	if len(g_finder_query) > 0 {
		q_cstr := strings.clone_to_cstring(string(g_finder_query[:]), context.temp_allocator)
		qw = draw_text(q_cstr, r.x + FINDER_PAD + pw, input_y, MENU_TEXT_COLOR, MENU_BG_COLOR)
	}
	caret_x := r.x + FINDER_PAD + pw + qw
	fill_rect({caret_x, input_y, 2, g_config.font.size}, g_theme.cursor_color)

	// Separator under the input.
	sep_y := input_y + g_config.font.size + FINDER_INPUT_GAP * 0.5
	fill_rect({r.x + FINDER_PAD, sep_y, r.w - FINDER_PAD * 2, 1.0 / g_density}, MENU_BORDER_COLOR)

	// Result list.
	list_y := input_y + g_config.font.size + FINDER_INPUT_GAP

	if len(g_finder_results) == 0 {
		dim_cstr := strings.clone_to_cstring("(empty)", context.temp_allocator)
		draw_text(dim_cstr, r.x + FINDER_PAD, list_y, MENU_DIM_COLOR, MENU_BG_COLOR)
		return
	}

	end := min(g_finder_scroll + FINDER_MAX_VISIBLE, len(g_finder_results))
	row := 0
	for i := g_finder_scroll; i < end; i += 1 {
		ry := list_y + f32(row) * row_h
		row += 1
		bg := MENU_BG_COLOR
		if i == g_finder_active {
			fill_rect({r.x + 2, ry, r.w - 4, row_h}, MENU_HOVER_COLOR)
			bg = MENU_HOVER_COLOR
		}
		entry := g_finder_results[i].entry
		fg := entry.is_dir ? FINDER_DIR_COLOR : MENU_TEXT_COLOR
		name_cstr := strings.clone_to_cstring(entry.name, context.temp_allocator)
		draw_text(name_cstr, r.x + FINDER_PAD, ry, fg, bg)
	}

	// Scrollbar (visual only; mouse-wheel does the actual scrolling).
	if len(g_finder_results) > FINDER_MAX_VISIBLE {
		track_w  : f32 = 6
		track_x  := r.x + r.w - track_w - bw - 2
		track_y  := list_y
		visible  := f32(FINDER_MAX_VISIBLE)
		total    := f32(len(g_finder_results))
		track_h  := visible * row_h
		fill_rect({track_x, track_y, track_w, track_h}, g_theme.sb_track_color)

		thumb_h := max(SB_MIN_THUMB, (visible / total) * track_h)
		max_scroll := total - visible
		t: f32 = 0
		if max_scroll > 0 do t = f32(g_finder_scroll) / max_scroll
		thumb_y := track_y + t * (track_h - thumb_h)
		fill_rect({track_x, thumb_y, track_w, thumb_h}, g_theme.sb_thumb_color)
	}
}
