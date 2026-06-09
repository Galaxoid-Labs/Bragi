package bragi

import "core:fmt"
import "core:os"
import "core:strings"
import sdl "vendor:sdl3"

// Project-wide fuzzy file finder. Cmd/Ctrl+F opens it; type to fuzzy-
// search every file under the index root, Up/Down to move, Enter to
// open. Esc dismisses.
//
// Backed by the fff C library (see fff.odin). On open we pick an index
// root from the active editor — the git root containing the open file
// (walking up to the nearest `.git`), falling back to that file's own
// directory, and to `$HOME` when no file is open. fff recursively
// indexes the root (honoring `.gitignore`) on a background thread and
// `fff_search` returns ranked matches across the whole tree, so this is
// a flat picker (relative paths), not a directory browser.

FINDER_PAD          :: 16.0
FINDER_INPUT_GAP    :: 8.0
FINDER_LINE_GAP     :: 4.0
FINDER_MAX_VISIBLE  :: 18
FINDER_DIM_BG       :: sdl.Color{0, 0, 0, 140}

// Results requested per search. fff paginates; we ask for a generous
// page and let the list scroll. Far more than FINDER_MAX_VISIBLE so
// scrolling has something to show without re-querying.
@(private="file")
FINDER_PAGE_SIZE :: 200

@(private="file")
FINDER_PROMPT_COLOR :: sdl.Color{120, 125, 140, 255}
@(private="file")
FINDER_DIR_COLOR    :: sdl.Color{120, 125, 140, 255} // dim the directory portion of a path

g_finder_visible:  bool
g_finder_query:    [dynamic]u8
g_finder_results:  [dynamic]Finder_Result
g_finder_active:   int
g_finder_scroll:   int

// fff instance state. The index is created lazily on first open and
// kept alive (with a live file watcher) so re-opening the finder is
// instant. `g_fff_root` is the directory the index is currently rooted
// at; when a later open resolves a different root we re-point the index
// in place via `fff_restart_index`.
@(private="file")
g_fff_handle: rawptr
@(private="file")
g_fff_root:   string // owned

Finder_Result :: struct {
	path: string, // owned; relative to g_fff_root (e.g. "src/main.odin")
}

finder_show :: proc() {
	// Only (re)point the index when we resolve an indexable root. When we
	// can't (no file open + cwd is $HOME/root, or the file sits loose in
	// $HOME), we leave any existing index alone and the list shows a hint.
	if root, ok := finder_compute_root(); ok {
		fff_ensure_instance(root)
		delete(root)
	}
	clear(&g_finder_query)
	finder_recompute()
	g_finder_active  = 0
	g_finder_scroll  = 0
	g_finder_visible = true
}

finder_hide :: proc() {
	g_finder_visible = false
	clear(&g_finder_query)
}

// Final teardown — releases every owned allocation plus the fff
// instance. Called from main()'s shutdown defer.
finder_destroy :: proc() {
	finder_clear_results()
	delete(g_finder_results)
	delete(g_finder_query)
	if g_fff_handle != nil {
		fff_destroy(g_fff_handle)
		g_fff_handle = nil
	}
	if len(g_fff_root) > 0 {
		delete(g_fff_root)
		g_fff_root = ""
	}
}

@(private="file")
finder_clear_results :: proc() {
	for r in g_finder_results do delete(r.path)
	clear(&g_finder_results)
}

// Resolve the user's home directory. Falls back to the editor's cwd when
// the relevant env var isn't set (sandboxed contexts, etc.). Returned
// string lives in the temp allocator.
@(private="file")
default_finder_dir :: proc() -> string {
	when ODIN_OS == .Windows {
		profile := os.get_env("USERPROFILE", context.temp_allocator)
		if len(profile) > 0 do return profile
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

// Pick the directory to index. Git root of the active file if it lives
// in a repo, else the file's own directory; when no file is open, the
// process cwd. Returns ("", false) when there's no *indexable* root —
// fff (rightly) refuses to recursively walk $HOME or the filesystem
// root, so we never even try (see is_indexable_root). On success the
// returned string is owned by the caller.
// Called from set_workspace (workspace.odin) when the root changes —
// eagerly (re)points the fff index so the next finder open is instant.
finder_set_workspace_root :: proc(root: string) {
	if is_indexable_root(root) do fff_ensure_instance(root)
}

@(private="file")
finder_compute_root :: proc() -> (string, bool) {
	// An explicit workspace wins over the active-file heuristic.
	if len(g_workspace_root) > 0 && is_indexable_root(g_workspace_root) {
		return strings.clone(g_workspace_root), true
	}
	ed := active_editor()
	if ed != nil && len(ed.file_path) > 0 {
		dir := dir_of(ed.file_path) // borrowed slice of file_path
		if gr, ok := git_root(dir); ok {
			if !is_indexable_root(gr) {
				delete(gr)
				return "", false
			}
			return gr, true
		}
		if !is_indexable_root(dir) do return "", false
		return strings.clone(dir), true
	}
	// No file open — fall back to the working directory, but only if it's
	// a bounded project dir (not $HOME / not "/").
	cwd, _ := os.get_working_directory(context.temp_allocator)
	if !is_indexable_root(cwd) do return "", false
	return strings.clone(cwd), true
}

// Reject roots that would make fff recursively walk an enormous tree:
// the filesystem root and the user's home directory itself. A bounded
// project directory (anything below $HOME, a repo, a subfolder) is fine.
@(private="file")
is_indexable_root :: proc(path: string) -> bool {
	if len(path) == 0 || path == "/" do return false
	home := strings.trim_right(default_finder_dir(), "/")
	if strings.trim_right(path, "/") == home do return false
	return true
}

// Directory component of `path` as a borrowed slice ("" → "/"). No
// allocation; the slice points into `path`.
@(private="file")
dir_of :: proc(path: string) -> string {
	idx := strings.last_index_byte(path, '/')
	if idx <= 0 do return "/"
	return path[:idx]
}

// Walk up from `start` looking for a `.git` entry. Returns the repo root
// (owned) and true on the first hit, or "" / false if we reach the
// filesystem root without finding one.
@(private="file")
git_root :: proc(start: string) -> (string, bool) {
	dir := start
	for {
		dotgit := fmt.tprintf("%s/.git", dir)
		if os.exists(dotgit) do return strings.clone(dir), true
		idx := strings.last_index_byte(dir, '/')
		if idx <= 0 do break
		dir = dir[:idx]
	}
	return "", false
}

// Ensure the fff index exists and is rooted at `root`. Creates it on
// first call; re-points an existing index when the root changes.
@(private="file")
fff_ensure_instance :: proc(root: string) {
	if g_fff_handle != nil && g_fff_root == root do return

	rc := strings.clone_to_cstring(root, context.temp_allocator)

	if g_fff_handle != nil {
		res := fff_restart_index(g_fff_handle, rc)
		if res != nil do fff_free_result(res)
		set_fff_root(root)
		return
	}

	opts := FffCreateOptions {
		version   = FFF_CREATE_OPTIONS_VERSION,
		base_path = rc,
		watch     = true, // keep the index live as files change
	}
	res := fff_create_instance_with(&opts)
	if res == nil do return
	defer fff_free_result(res)
	if !res.success || res.handle == nil {
		if res.error != nil {
			set_status_message(fmt.tprintf("finder: %s", string(res.error)), .Error)
		}
		return
	}
	g_fff_handle = res.handle
	set_fff_root(root)
}

@(private="file")
set_fff_root :: proc(root: string) {
	if len(g_fff_root) > 0 do delete(g_fff_root)
	g_fff_root = strings.clone(root)
}

// Run the current query through fff and rebuild the result list.
@(private="file")
finder_recompute :: proc() {
	finder_clear_results()
	if g_fff_handle == nil do return

	qcstr := strings.clone_to_cstring(string(g_finder_query[:]), context.temp_allocator)

	// Deprioritize the file already open in the active pane.
	cur: cstring
	if ed := active_editor(); ed != nil && len(ed.file_path) > 0 {
		cur = strings.clone_to_cstring(ed.file_path, context.temp_allocator)
	}

	res := fff_search(g_fff_handle, qcstr, cur, 0, 0, FINDER_PAGE_SIZE, 0, 0)
	if res == nil do return
	defer fff_free_result(res)
	if !res.success || res.handle == nil do return

	sr := cast(^FffSearchResult)res.handle
	defer fff_free_search_result(sr)

	count := fff_search_result_get_count(sr)
	for i in 0 ..< count {
		item := fff_search_result_get_item(sr, i)
		if item == nil do continue
		rel := fff_file_item_get_relative_path(item)
		if rel == nil do continue
		// `rel` is borrowed from `sr`; clone it so it survives the free.
		append(&g_finder_results, Finder_Result{path = strings.clone(string(rel))})
	}
}

// Open the highlighted result via the standard "smart" path (replaces a
// blank pane, splits a busy one).
@(private="file")
finder_activate :: proc() {
	if g_finder_active < 0 || g_finder_active >= len(g_finder_results) {
		finder_hide()
		return
	}
	rel := g_finder_results[g_finder_active].path
	sep := strings.has_suffix(g_fff_root, "/") ? "" : "/"
	full := fmt.aprintf("%s%s%s", g_fff_root, sep, rel, allocator = context.temp_allocator)
	finder_hide()
	open_file_smart(full) // clones internally via editor_load_file
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
		}
	case sdl.K_UP:
		if g_finder_active > 0 do g_finder_active -= 1
		if g_finder_active < g_finder_scroll do g_finder_scroll = g_finder_active
	case sdl.K_DOWN:
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
		// SDL3's `clicks` field reports the OS double-click count; we
		// open on the second click.
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
	// Two text rows above the list (the root path + the query line).
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
	fill_rect({r.x,            r.y,            r.w, bw },  MENU_BORDER_COLOR)
	fill_rect({r.x,            r.y + r.h - bw, r.w, bw },  MENU_BORDER_COLOR)
	fill_rect({r.x,            r.y,            bw,  r.h},  MENU_BORDER_COLOR)
	fill_rect({r.x + r.w - bw, r.y,            bw,  r.h},  MENU_BORDER_COLOR)

	clip := sdl.Rect{
		i32(r.x + bw),
		i32(r.y + bw),
		i32(r.w - bw * 2),
		i32(r.h - bw * 2),
	}
	sdl.SetRenderClipRect(g_renderer, &clip)
	defer sdl.SetRenderClipRect(g_renderer, nil)

	row_h := g_config.font.size + FINDER_LINE_GAP

	// Line 1: index root path (dim).
	dir_y := r.y + FINDER_PAD
	root_cstr := strings.clone_to_cstring(g_fff_root, context.temp_allocator)
	draw_text(root_cstr, r.x + FINDER_PAD, dir_y, FINDER_PROMPT_COLOR, MENU_BG_COLOR)

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
		msg := g_fff_handle == nil ? "(open a file inside a project to search)" : "(no matches)"
		dim_cstr := strings.clone_to_cstring(msg, context.temp_allocator)
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
		// Split "dir/sub/name" into a dim directory prefix + bright
		// filename so the matched file stands out from its path.
		path := g_finder_results[i].path
		base := path_basename(path)
		x := r.x + FINDER_PAD
		if len(base) < len(path) {
			prefix := path[:len(path) - len(base)] // includes the trailing '/'
			pre_cstr := strings.clone_to_cstring(prefix, context.temp_allocator)
			x += draw_text(pre_cstr, x, ry, FINDER_DIR_COLOR, bg)
		}
		name_cstr := strings.clone_to_cstring(base, context.temp_allocator)
		draw_text(name_cstr, x, ry, MENU_TEXT_COLOR, bg)
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
