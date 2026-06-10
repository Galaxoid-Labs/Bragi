package bragi

import "base:runtime"
import "core:c"
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

// fff runs ENTIRELY on a background worker thread — both the initial
// `fff_create_instance_with` (whose scan freezes the UI on a big repo)
// AND every `fff_search` (which blocks while the index is still
// scanning). The main thread NEVER calls into fff; it only posts a query
// and reads back results, so the finder can't lock up no matter how long
// indexing takes.
//
//   main → worker : pending query (g_fff_req_*), woken via g_fff_sem
//   worker → main : results + status (g_fff_*), announced via FFF_EVENT
//
// Everything shared below is guarded by g_fff_mutex.
FFF_EVENT :: i32(0x46464600) // "FFF\0" — wake code the worker pushes

@(private="file") g_fff_root:    string        // owned; current index root
@(private="file") g_fff_mutex:   ^sdl.Mutex
@(private="file") g_fff_sem:     ^sdl.Semaphore // wakes the worker (new query / quit)
@(private="file") g_fff_thread:  ^sdl.Thread
@(private="file") g_fff_quit:    bool

// request: main → worker
@(private="file") g_fff_req_query: string       // owned
@(private="file") g_fff_req_file:  string       // owned (current file, for deprioritization)
@(private="file") g_fff_req_dirty: bool

// state + results: worker → main
@(private="file") g_fff_ready:    bool           // instance built
@(private="file") g_fff_scanning: bool           // initial scan still running (status)
@(private="file") g_fff_indexed:  u32            // indexed file count (status)
@(private="file") g_fff_results:  [dynamic]string // owned by the worker; latest matches

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
	finder_clear_results()
	finder_request_search() // results arrive async via FFF_EVENT
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
	fff_teardown() // joins the worker (which frees the instance + results)
	if len(g_fff_root) > 0 {
		delete(g_fff_root)
		g_fff_root = ""
	}
	if len(g_fff_req_query) > 0 do delete(g_fff_req_query)
	if len(g_fff_req_file)  > 0 do delete(g_fff_req_file)
	if g_fff_sem != nil {
		sdl.DestroySemaphore(g_fff_sem)
		g_fff_sem = nil
	}
	if g_fff_mutex != nil {
		sdl.DestroyMutex(g_fff_mutex)
		g_fff_mutex = nil
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

@(private="file")
fff_ensure_sync :: proc() {
	if g_fff_mutex == nil do g_fff_mutex = sdl.CreateMutex()
	if g_fff_sem   == nil do g_fff_sem   = sdl.CreateSemaphore(0)
}

// (Re)start the worker rooted at `root`. Returns immediately — all the
// heavy fff work happens on the worker. A root change tears the old
// worker down and starts a fresh one.
@(private="file")
fff_ensure_instance :: proc(root: string) {
	fff_ensure_sync()
	if g_fff_thread != nil && g_fff_root == root do return

	fff_teardown()

	if len(g_fff_root) > 0 do delete(g_fff_root)
	g_fff_root = strings.clone(root)

	sdl.LockMutex(g_fff_mutex)
	g_fff_ready = false
	g_fff_scanning = false
	g_fff_indexed = 0
	g_fff_req_dirty = true // search the empty query as soon as the index is up
	sdl.UnlockMutex(g_fff_mutex)

	// Owned (NOT temp) — the worker reads it asynchronously + frees it.
	root_c := strings.clone_to_cstring(root, context.allocator)
	g_fff_thread = sdl.CreateThread(fff_worker, "bragi-fff", rawptr(root_c))
	if g_fff_thread == nil do delete(root_c)
}

// The worker: create the instance, then loop serving search requests and
// (while the initial scan runs) periodically refreshing so results stream
// in. Owns the handle + g_fff_results for its whole lifetime.
@(private="file")
fff_worker :: proc "c" (data: rawptr) -> c.int {
	context = runtime.default_context()
	root_c := cstring(data)
	defer delete(root_c)

	opts := FffCreateOptions {
		version   = FFF_CREATE_OPTIONS_VERSION,
		base_path = root_c,
		watch     = true,
	}
	res := fff_create_instance_with(&opts)
	handle: rawptr
	if res != nil {
		if res.success do handle = res.handle
		fff_free_result(res)
	}

	sdl.LockMutex(g_fff_mutex)
	g_fff_ready    = handle != nil
	g_fff_scanning = handle != nil
	sdl.UnlockMutex(g_fff_mutex)
	fff_push_wake()
	if handle == nil do return 0

	prev_scanning := true // handle starts out scanning
	for {
		sdl.LockMutex(g_fff_mutex)
		scanning := g_fff_scanning
		sdl.UnlockMutex(g_fff_mutex)
		// Block for a request; while scanning, wake often to refresh.
		sdl.WaitSemaphoreTimeout(g_fff_sem, scanning ? 120 : 3000)

		sdl.LockMutex(g_fff_mutex)
		if g_fff_quit {
			sdl.UnlockMutex(g_fff_mutex)
			break
		}
		// Heap clones (freed explicitly below) — no temp_allocator here so
		// we don't depend on per-thread arena semantics in a worker.
		query := strings.clone(g_fff_req_query)
		file  := strings.clone(g_fff_req_file)
		dirty := g_fff_req_dirty
		g_fff_req_dirty = false
		sdl.UnlockMutex(g_fff_mutex)

		now_scanning := fff_is_scanning(handle)

		// Re-search when the query changed or the index is still growing.
		if dirty || now_scanning {
			qc := strings.clone_to_cstring(query)
			fc: cstring
			if len(file) > 0 do fc = strings.clone_to_cstring(file)
			defer {
				delete(qc)
				if fc != nil do delete(fc)
			}

			local := make([dynamic]string)
			indexed: u32
			sres := fff_search(handle, qc, fc, 0, 0, FINDER_PAGE_SIZE, 0, 0)
			if sres != nil {
				if sres.success && sres.handle != nil {
					sr := cast(^FffSearchResult)sres.handle
					indexed = fff_search_result_get_total_files(sr)
					count := fff_search_result_get_count(sr)
					for i in 0 ..< count {
						item := fff_search_result_get_item(sr, i)
						if item == nil do continue
						rel := fff_file_item_get_relative_path(item)
						if rel == nil do continue
						append(&local, strings.clone(string(rel)))
					}
					fff_free_search_result(sr)
				}
				fff_free_result(sres)
			}

			sdl.LockMutex(g_fff_mutex)
			for s in g_fff_results do delete(s)
			delete(g_fff_results)
			g_fff_results  = local
			g_fff_indexed  = indexed
			g_fff_scanning = now_scanning
			sdl.UnlockMutex(g_fff_mutex)
			fff_push_wake()
		} else if prev_scanning {
			// Scan just finished with no pending query — clear the status
			// once (no busy wakes while idle).
			sdl.LockMutex(g_fff_mutex)
			g_fff_scanning = false
			sdl.UnlockMutex(g_fff_mutex)
			fff_push_wake()
		}
		prev_scanning = now_scanning
		delete(query)
		delete(file)
	}

	sdl.LockMutex(g_fff_mutex)
	for s in g_fff_results do delete(s)
	delete(g_fff_results)
	g_fff_results = nil
	sdl.UnlockMutex(g_fff_mutex)
	fff_destroy(handle)
	return 0
}

// Stop the worker (if any). Main-thread only.
@(private="file")
fff_teardown :: proc() {
	fff_ensure_sync()
	if g_fff_thread != nil {
		sdl.LockMutex(g_fff_mutex)
		g_fff_quit = true
		sdl.UnlockMutex(g_fff_mutex)
		sdl.SignalSemaphore(g_fff_sem) // wake it out of WaitSemaphoreTimeout
		sdl.WaitThread(g_fff_thread, nil)
		g_fff_thread = nil
		sdl.LockMutex(g_fff_mutex)
		g_fff_quit = false
		g_fff_ready = false
		g_fff_scanning = false
		sdl.UnlockMutex(g_fff_mutex)
	}
}

// Post the current query to the worker (debounced via the dirty flag) and
// wake it. Called from the main thread on every keystroke / open — never
// touches fff itself, so it returns instantly.
@(private="file")
finder_request_search :: proc() {
	if g_fff_mutex == nil do return
	sdl.LockMutex(g_fff_mutex)
	if len(g_fff_req_query) > 0 do delete(g_fff_req_query)
	g_fff_req_query = strings.clone(string(g_finder_query[:]))
	if len(g_fff_req_file) > 0 do delete(g_fff_req_file)
	g_fff_req_file = ""
	if ed := active_editor(); ed != nil && len(ed.file_path) > 0 {
		g_fff_req_file = strings.clone(ed.file_path)
	}
	g_fff_req_dirty = true
	sdl.UnlockMutex(g_fff_mutex)
	if g_fff_sem != nil do sdl.SignalSemaphore(g_fff_sem)
}

// Main loop calls this on an FFF_EVENT wake: copy the worker's latest
// results into the finder's render list and reconcile selection.
finder_on_fff_event :: proc() {
	if !g_finder_visible || g_fff_mutex == nil do return
	finder_clear_results()
	sdl.LockMutex(g_fff_mutex)
	for s in g_fff_results {
		append(&g_finder_results, Finder_Result{path = strings.clone(s)})
	}
	sdl.UnlockMutex(g_fff_mutex)
	if g_finder_active >= len(g_finder_results) {
		g_finder_active = max(0, len(g_finder_results) - 1)
	}
	max_scroll := max(0, len(g_finder_results) - FINDER_MAX_VISIBLE)
	if g_finder_scroll > max_scroll do g_finder_scroll = max_scroll
}

// (indexing?, files-indexed-so-far) for the status line.
@(private="file")
fff_index_status :: proc() -> (indexing: bool, files: u32) {
	if g_fff_mutex == nil do return false, 0
	sdl.LockMutex(g_fff_mutex)
	indexing = g_fff_thread != nil && (!g_fff_ready || g_fff_scanning)
	files = g_fff_indexed
	sdl.UnlockMutex(g_fff_mutex)
	return
}

// True once a root is set / worker running (vs. "no project to search").
@(private="file")
fff_has_root :: proc() -> bool {
	return g_fff_thread != nil
}

@(private="file")
fff_push_wake :: proc() {
	ev: sdl.Event
	ev.user.type = .USER
	ev.user.code = FFF_EVENT
	_ = sdl.PushEvent(&ev)
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
			g_finder_active = 0
			g_finder_scroll = 0
			finder_request_search()
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
	g_finder_active = 0
	g_finder_scroll = 0
	finder_request_search()
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

// Mouse moved over a result row → highlight it (selection follows the
// cursor, matching the context menu / completion popup).
finder_handle_motion :: proc(mx, my: f32, l: Layout) {
	if !g_finder_visible do return
	if idx := finder_row_at(mx, my, l); idx >= 0 do g_finder_active = idx
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

	indexing, idx_files := fff_index_status()

	// Line 1: index root path (dim) + a live "indexing…" indicator while
	// the background build/scan is in flight.
	dir_y := r.y + FINDER_PAD
	root_cstr := strings.clone_to_cstring(g_fff_root, context.temp_allocator)
	rw := draw_text(root_cstr, r.x + FINDER_PAD, dir_y, FINDER_PROMPT_COLOR, MENU_BG_COLOR)
	if indexing {
		stat := fmt.tprintf("  ·  indexing… %d", idx_files)
		sc := strings.clone_to_cstring(stat, context.temp_allocator)
		draw_text(sc, r.x + FINDER_PAD + rw, dir_y, g_theme.status_info_color, MENU_BG_COLOR)
	}

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
		msg: string
		if indexing {
			msg = fmt.tprintf("indexing… %d files", idx_files)
		} else if !fff_has_root() {
			msg = "(open a file inside a project to search)"
		} else {
			msg = "(no matches)"
		}
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
