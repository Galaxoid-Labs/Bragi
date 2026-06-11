package bragi

import "core:c"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import sdl "vendor:sdl3"

// Left file-tree sidebar — a NERDTree-style explorer of the workspace
// (workspace.odin). Toggle with Cmd/Ctrl+E. It's a left strip carved out
// of the editor zone by compute_layout, resizable via a 4-px divider,
// focusable (dim when unfocused) — the terminal-strip pattern rotated.
//
// The tree is kept as a *flattened* list of visible rows
// (`g_sidebar_entries`) rebuilt from `g_workspace_root` plus a set of
// expanded directory paths (`g_sidebar_expanded`). Expanding/collapsing
// flips the set and rebuilds; only expanded (visible) dirs are read, so
// it's lazy. Dotfiles are hidden NERDTree-style, toggled with `i`.
//
// Styling intentionally matches the fuzzy finder (MENU_* colors, blue
// dirs, themed scrollbar) and uses the UI font (g_font) — the sidebar is
// chrome, so it does NOT scale with the editor-font zoom.

SIDEBAR_DEFAULT_WIDTH :: f32(240)
SIDEBAR_MIN_WIDTH     :: f32(140)
SIDEBAR_MIN_EDITOR    :: f32(200) // keep at least this much for the editor panes
SIDEBAR_DIVIDER_W     :: f32(4)
SIDEBAR_PAD           :: f32(8)
SIDEBAR_INDENT        :: f32(14) // per depth level
SIDEBAR_ROW_GAP       :: f32(4)

// Row icons are drawn from the embedded Nerd Font (g_terminal_font), NOT
// the UI font — so they render regardless of which `[font]` the user
// configures. These are Font Awesome code points in the Nerd Font PUA.
@(private="file")
GLYPH_FOLDER :: "\uF07B" // nf-fa-folder (collapsed)
@(private="file")
GLYPH_FOLDER_OPEN :: "\uF07C" // nf-fa-folder_open
@(private="file")
SIDEBAR_ICON_COL :: f32(1.4) // name offset past the icon, in UI-font em units

@(private="file")
SIDEBAR_DIR_COLOR :: sdl.Color{97, 175, 239, 255} // blue, matches finder dirs

g_sidebar_visible:     bool
g_sidebar_active:      bool // keyboard focus (dim when false)
g_sidebar_resizing:    bool
g_sidebar_width:       f32 = SIDEBAR_DEFAULT_WIDTH
g_sidebar_show_hidden: bool

@(private="file")
g_sidebar_entries: [dynamic]Sidebar_Entry
@(private="file")
g_sidebar_expanded: map[string]bool // expanded dir paths (owned keys)
@(private="file")
g_sidebar_selected: int
@(private="file")
g_sidebar_hovered: int = -1 // row under the mouse (-1 = none)
@(private="file")
g_sidebar_scroll: int
@(private="file")
g_sidebar_view_rows: int // visible row count from the last draw (for key-nav scrolling)

Sidebar_Entry :: struct {
	path:    string, // owned, absolute
	name:    string, // owned, base name
	is_dir:  bool,
	depth:   int,
	editing: bool,   // transient: this row is the inline New/Rename text field
}

// Toggle visibility. Showing it also focuses it and (re)builds the tree
// from the current workspace.
sidebar_toggle :: proc() {
	g_sidebar_visible = !g_sidebar_visible
	if g_sidebar_visible {
		sidebar_rebuild()
		g_sidebar_active = true
	} else {
		g_sidebar_active = false
	}
}

// Called by set_workspace (workspace.odin) when the root changes: drop
// expansion / selection state from the previous workspace, then rebuild
// if the sidebar is showing.
sidebar_on_workspace_changed :: proc() {
	for path in g_sidebar_expanded do delete(path)
	clear(&g_sidebar_expanded)
	g_sidebar_selected = 0
	g_sidebar_scroll = 0
	if g_sidebar_visible do sidebar_rebuild()
}

sidebar_destroy :: proc() {
	sidebar_clear_entries()
	delete(g_sidebar_entries)
	for path in g_sidebar_expanded do delete(path)
	delete(g_sidebar_expanded)
}

@(private="file")
sidebar_clear_entries :: proc() {
	for e in g_sidebar_entries {
		delete(e.path)
		delete(e.name)
	}
	clear(&g_sidebar_entries)
}

// Rebuild the flat visible list from the workspace root + expanded set.
// Cheap: only reads directories that are currently expanded (visible).
sidebar_rebuild :: proc() {
	sidebar_clear_entries()
	if len(g_workspace_root) == 0 do return
	sidebar_append_dir(g_workspace_root, 0)
	if g_sidebar_selected >= len(g_sidebar_entries) {
		g_sidebar_selected = max(0, len(g_sidebar_entries) - 1)
	}
}

@(private="file")
sidebar_append_dir :: proc(dir: string, depth: int) {
	fd, oerr := os.open(dir)
	if oerr != nil do return
	defer os.close(fd)
	infos, rerr := os.read_dir(fd, -1, context.temp_allocator)
	if rerr != nil do return

	// Dirs first, then files; each group alphabetical. Build into temp
	// slices, then emit.
	dirs:  [dynamic]Sidebar_Entry
	files: [dynamic]Sidebar_Entry
	dirs  = make([dynamic]Sidebar_Entry, context.temp_allocator)
	files = make([dynamic]Sidebar_Entry, context.temp_allocator)

	for info in infos {
		if !g_sidebar_show_hidden && strings.has_prefix(info.name, ".") do continue
		e := Sidebar_Entry {
			path   = sidebar_join(dir, info.name),
			name   = strings.clone(info.name),
			is_dir = info.type == .Directory,
			depth  = depth,
		}
		if e.is_dir do append(&dirs, e)
		else        do append(&files, e)
	}
	sidebar_sort_alpha(dirs[:])
	sidebar_sort_alpha(files[:])

	for d in dirs {
		append(&g_sidebar_entries, d)
		if g_sidebar_expanded[d.path] do sidebar_append_dir(d.path, depth + 1)
	}
	for f in files do append(&g_sidebar_entries, f)
}

@(private="file")
sidebar_join :: proc(dir, name: string) -> string {
	if strings.has_suffix(dir, "/") do return fmt.aprintf("%s%s", dir, name)
	return fmt.aprintf("%s/%s", dir, name)
}

@(private="file")
sidebar_sort_alpha :: proc(s: []Sidebar_Entry) {
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

// Expand/collapse a directory entry (by its path) and rebuild.
@(private="file")
sidebar_set_expanded :: proc(path: string, expanded: bool) {
	if expanded {
		if !g_sidebar_expanded[path] {
			g_sidebar_expanded[strings.clone(path)] = true
		}
	} else {
		// delete_key returns the removed key; free its cloned backing.
		// (Returns the zero value "" when the key was absent — a no-op delete.)
		deleted_key, _ := delete_key(&g_sidebar_expanded, path)
		if len(deleted_key) > 0 do delete(deleted_key)
	}
	sidebar_rebuild()
}

// Activate the row at `idx`: directories toggle expansion, files open.
@(private="file")
sidebar_activate :: proc(idx: int) {
	if idx < 0 || idx >= len(g_sidebar_entries) do return
	e := g_sidebar_entries[idx]
	if e.is_dir {
		sidebar_set_expanded(e.path, !g_sidebar_expanded[e.path])
	} else {
		// open_file_smart clones the path internally.
		path := strings.clone(e.path, context.temp_allocator)
		open_file_smart(path)
	}
}

// ── input ──────────────────────────────────────────────────────────

// Returns true if the key was consumed by the sidebar. Only called when
// g_sidebar_active (see handle_key_down).
sidebar_handle_key :: proc(ev: sdl.KeyboardEvent) -> bool {
	if !g_sidebar_visible do return false
	n := len(g_sidebar_entries)
	switch ev.key {
	case sdl.K_ESCAPE:
		// Hand focus back to the editor; leave the sidebar open.
		g_sidebar_active = false
	case sdl.K_UP, sdl.K_K:
		if g_sidebar_selected > 0 do g_sidebar_selected -= 1
		sidebar_scroll_into_view()
	case sdl.K_DOWN, sdl.K_J:
		if g_sidebar_selected < n - 1 do g_sidebar_selected += 1
		sidebar_scroll_into_view()
	case sdl.K_RIGHT, sdl.K_L:
		if e, ok := sidebar_sel(); ok {
			if e.is_dir {
				if !g_sidebar_expanded[e.path] {
					sidebar_set_expanded(e.path, true)
				} else if g_sidebar_selected < n - 1 {
					g_sidebar_selected += 1 // step into first child
				}
			}
			sidebar_scroll_into_view()
		}
	case sdl.K_LEFT, sdl.K_H:
		if e, ok := sidebar_sel(); ok {
			if e.is_dir && g_sidebar_expanded[e.path] {
				sidebar_set_expanded(e.path, false)
			} else {
				sidebar_select_parent()
			}
			sidebar_scroll_into_view()
		}
	case sdl.K_RETURN:
		sidebar_activate(g_sidebar_selected)
		sidebar_scroll_into_view()
	case sdl.K_I:
		// NERDTree's hidden-files toggle.
		g_sidebar_show_hidden = !g_sidebar_show_hidden
		sidebar_rebuild()
	case:
		return false
	}
	return true
}

@(private="file")
sidebar_sel :: proc() -> (Sidebar_Entry, bool) {
	if g_sidebar_selected < 0 || g_sidebar_selected >= len(g_sidebar_entries) do return {}, false
	return g_sidebar_entries[g_sidebar_selected], true
}

// Move selection to the nearest ancestor row (depth - 1) above the
// current one — the "go to parent" half of `h`.
@(private="file")
sidebar_select_parent :: proc() {
	e, ok := sidebar_sel()
	if !ok || e.depth == 0 do return
	for i := g_sidebar_selected - 1; i >= 0; i -= 1 {
		if g_sidebar_entries[i].depth < e.depth {
			g_sidebar_selected = i
			return
		}
	}
}

@(private="file")
sidebar_scroll_into_view :: proc() {
	if g_sidebar_selected < g_sidebar_scroll {
		g_sidebar_scroll = g_sidebar_selected
	} else if g_sidebar_view_rows > 0 &&
	          g_sidebar_selected >= g_sidebar_scroll + g_sidebar_view_rows {
		g_sidebar_scroll = g_sidebar_selected - g_sidebar_view_rows + 1
	}
}

// Hit-test a point against the row list. Returns the entry index, or -1.
@(private="file")
sidebar_row_at :: proc(x, y: f32, l: Layout) -> int {
	r := l.sidebar_rect
	if !point_in_rect({x, y}, r) do return -1
	list_y := r.y + sidebar_header_h()
	if y < list_y do return -1
	row_h := g_config.font.size + SIDEBAR_ROW_GAP
	rel := int((y - list_y) / row_h)
	if rel < 0 do return -1
	idx := g_sidebar_scroll + rel
	if idx < 0 || idx >= len(g_sidebar_entries) do return -1
	return idx
}

// Mouse down inside the sidebar: focus it, select + activate the row.
// Returns true if the click landed in the sidebar.
sidebar_handle_button :: proc(ev: sdl.MouseButtonEvent, l: Layout) -> bool {
	if !g_sidebar_visible do return false
	if !point_in_rect({ev.x, ev.y}, l.sidebar_rect) do return false
	if !ev.down do return true
	g_sidebar_active = true
	// Right-click → file-tree context menu. On a row it acts on that entry;
	// in empty space it acts on the workspace root (target -1).
	if ev.button == sdl.BUTTON_RIGHT {
		if idx := sidebar_row_at(ev.x, ev.y, l); idx >= 0 {
			g_sidebar_selected = idx
			menu_show_items({ev.x, ev.y}, SIDEBAR_MENU, .Sidebar, idx)
		} else if len(g_workspace_root) > 0 {
			menu_show_items({ev.x, ev.y}, SIDEBAR_ROOT_MENU, .Sidebar, -1)
		}
		return true
	}
	if ev.button != sdl.BUTTON_LEFT do return true
	if idx := sidebar_row_at(ev.x, ev.y, l); idx >= 0 {
		g_sidebar_selected = idx
		// Directories toggle on a single click; files need a double
		// click to open (single click just selects). SDL's `clicks`
		// reports the OS double-click count.
		e := g_sidebar_entries[idx]
		if e.is_dir || ev.clicks >= 2 do sidebar_activate(idx)
	}
	return true
}

// Mouse moved over the sidebar: track the row under the cursor for the
// hover highlight. `-1` when the cursor isn't over a row.
sidebar_handle_motion :: proc(mx, my: f32, l: Layout) {
	if !g_sidebar_visible || !point_in_rect({mx, my}, l.sidebar_rect) {
		g_sidebar_hovered = -1
		return
	}
	g_sidebar_hovered = sidebar_row_at(mx, my, l)
}

sidebar_handle_wheel :: proc(ev: sdl.MouseWheelEvent) -> bool {
	if !g_sidebar_visible do return false
	if ev.y == 0 do return true
	step := int(ev.y * 3)
	if step == 0 do step = ev.y > 0 ? 1 : -1
	g_sidebar_scroll -= step
	max_scroll := max(0, len(g_sidebar_entries) - g_sidebar_view_rows)
	g_sidebar_scroll = clamp(g_sidebar_scroll, 0, max_scroll)
	return true
}

// ──────────────────────────────────────────────────────────────────
// File-tree context-menu actions (dispatched from menu_handle_click when
// g_menu.kind == .Sidebar). New File/Folder/Rename go through the bottom
// prompt; Delete confirms natively; Copy Path / Reveal act immediately.
// ──────────────────────────────────────────────────────────────────

// Perform a file-tree context-menu action on the entry at `row` (or the
// workspace root when row < 0). New File/Folder/Rename open an inline editor;
// Delete confirms natively; Copy Path / Reveal act immediately.
sidebar_menu_dispatch :: proc(action: Menu_Action, row: int) {
	// Empty-space menu (target -1): act on the workspace root.
	if row < 0 {
		root := g_workspace_root
		if len(root) == 0 do return
		#partial switch action {
		// New file lands at the bottom of the list (after dirs); new folder
		// sorts up among the dirs, so its input goes to the top.
		case .New_File:   sidebar_begin_new(root, sidebar_group_end(0, 0), 0, false)
		case .New_Folder: sidebar_begin_new(root, 0, 0, true)
		case .Copy_Path:
			sdl.SetClipboardText(strings.clone_to_cstring(root, context.temp_allocator))
			set_status_message(fmt.tprintf("copied %s", root), .Info)
		case .Reveal:
			reveal_path(root, true)
		}
		return
	}
	if row >= len(g_sidebar_entries) do return
	e := g_sidebar_entries[row]
	#partial switch action {
	case .New_File, .New_Folder:
		nd := action == .New_Folder
		if e.is_dir {
			// Create inside the folder (expand it so the input shows as a child).
			dir   := strings.clone(e.path, context.temp_allocator)
			depth := e.depth
			if !g_sidebar_expanded[e.path] do sidebar_set_expanded(e.path, true) // rebuild; row unchanged
			// New file → end of this folder's children; new folder → its top.
			at := nd ? row + 1 : sidebar_group_end(row + 1, depth + 1)
			sidebar_begin_new(dir, at, depth + 1, nd)
		} else {
			// Create as a sibling of the clicked file (file → bottom of the group).
			start := row + 1
			at := nd ? start : sidebar_group_end(start, e.depth)
			sidebar_begin_new(filepath.dir(e.path), at, e.depth, nd)
		}
	case .Rename:
		sidebar_begin_rename(row)
	case .Delete:
		sidebar_delete(e)
	case .Copy_Path:
		sdl.SetClipboardText(strings.clone_to_cstring(e.path, context.temp_allocator))
		set_status_message(fmt.tprintf("copied %s", e.path), .Info)
	case .Reveal:
		reveal_path(e.path, e.is_dir) // platform-specific: reveal-and-select where supported
	}
}

@(private="file")
sidebar_create_file :: proc(dir, name: string) {
	path, _ := filepath.join({dir, name}, context.temp_allocator)
	if os.exists(path) {
		set_status_message(fmt.tprintf("%s already exists", name), .Error)
		return
	}
	if err := os.write_entire_file(path, []byte{}); err != nil {
		set_status_message(fmt.tprintf("could not create %s", name), .Error)
		return
	}
	sidebar_rebuild()
	open_file_smart(path) // open the new (empty) file
	set_status_message(fmt.tprintf("created %s", name), .Info)
}

@(private="file")
sidebar_create_folder :: proc(dir, name: string) {
	path, _ := filepath.join({dir, name}, context.temp_allocator)
	if os.exists(path) {
		set_status_message(fmt.tprintf("%s already exists", name), .Error)
		return
	}
	if err := os.make_directory(path); err != nil {
		set_status_message(fmt.tprintf("could not create %s", name), .Error)
		return
	}
	sidebar_rebuild()
	set_status_message(fmt.tprintf("created %s/", name), .Info)
}

@(private="file")
sidebar_do_rename :: proc(old, dir, name: string) {
	newpath, _ := filepath.join({dir, name}, context.temp_allocator)
	if os.exists(newpath) {
		set_status_message(fmt.tprintf("%s already exists", name), .Error)
		return
	}
	if err := os.rename(old, newpath); err != nil {
		set_status_message("rename failed", .Error)
		return
	}
	// Migrate any open editor viewing the renamed file: LSP didClose on the old
	// URI, re-point path + language, then didOpen on the new URI (handles an
	// extension change spawning a different server, e.g. .txt → .jai).
	for &ed in g_editors {
		if !lsp_path_eq(ed.file_path, old) do continue
		lsp_on_editor_closed(&ed)
		delete(ed.file_path)
		ed.file_path = strings.clone(newpath)
		ed.language  = language_for_path(ed.file_path)
		lsp_on_editor_opened(&ed)
	}
	sidebar_rebuild()
	set_status_message(fmt.tprintf("renamed to %s", name), .Info)
}

@(private="file")
sidebar_delete :: proc(e: Sidebar_Entry) {
	// Capture before the native dialog / rebuild can invalidate the entry.
	path   := strings.clone(e.path, context.temp_allocator)
	name   := strings.clone(e.name, context.temp_allocator)
	is_dir := e.is_dir

	kind := is_dir ? "folder" : "file"
	tail := is_dir ? "\n\nThis removes the folder and everything in it." : ""
	msg  := strings.clone_to_cstring(fmt.tprintf("Delete %s \"%s\"?%s", kind, name, tail), context.temp_allocator)
	// Cancel is the Return/Escape default so a stray Enter never deletes —
	// removal requires an explicit click on Delete.
	buttons := [2]sdl.MessageBoxButtonData{
		{flags = {.RETURNKEY_DEFAULT, .ESCAPEKEY_DEFAULT}, buttonID = 0, text = "Cancel"},
		{flags = {}, buttonID = 1, text = "Delete"},
	}
	data := sdl.MessageBoxData{
		flags      = {.WARNING},
		window     = g_window,
		title      = "Delete",
		message    = msg,
		numbuttons = c.int(len(buttons)),
		buttons    = raw_data(buttons[:]),
	}
	choice: c.int = 0
	if !sdl.ShowMessageBox(data, &choice) do return
	if choice != 1 do return

	err := is_dir ? os.remove_all(path) : os.remove(path)
	if err != nil {
		set_status_message(fmt.tprintf("could not delete %s", name), .Error)
		return
	}
	close_panes_for_deleted(path, is_dir) // don't leave panes viewing a gone file
	sidebar_rebuild()
	set_status_message(fmt.tprintf("deleted %s", name), .Info)
}

// ──────────────────────────────────────────────────────────────────
// Inline name entry for New File / New Folder / Rename — an editable row
// rendered in the tree (draw_sidebar) right where the entry lands. main.odin
// routes keys/runes here while prompt_active(): Enter confirms, Esc or a click
// elsewhere cancels.
// ──────────────────────────────────────────────────────────────────

Prompt_Kind :: enum { None, New_File, New_Folder, Rename }

g_prompt: struct {
	kind:   Prompt_Kind,
	dir:    string,      // owned: target directory
	old:    string,      // owned: existing path (Rename only)
	buffer: [dynamic]u8, // the typed name
	row:    int,         // g_sidebar_entries index of the editing row
	is_dir: bool,        // the editing row's icon (New_Folder / a renamed dir)
}

prompt_active :: proc() -> bool { return g_prompt.kind != .None }

prompt_editing_row :: proc() -> int { return g_prompt.row }

prompt_text :: proc() -> string { return string(g_prompt.buffer[:]) }

// Free prompt state WITHOUT rebuilding (for callers that already rebuilt).
@(private="file")
prompt_clear :: proc() {
	if len(g_prompt.dir) > 0 do delete(g_prompt.dir)
	if len(g_prompt.old) > 0 do delete(g_prompt.old)
	g_prompt.dir = ""
	g_prompt.old = ""
	clear(&g_prompt.buffer)
	g_prompt.kind = .None
	g_prompt.row  = -1
}

// Begin an inline New File/Folder: inject a synthetic editable row at `at`
// (depth `depth`) so it renders exactly where the entry will be created.
@(private="file")
sidebar_begin_new :: proc(dir: string, at, depth: int, is_dir: bool) {
	prompt_cancel() // clear any in-progress edit (rebuilds away its synthetic row)
	g_prompt.kind   = is_dir ? .New_Folder : .New_File
	g_prompt.dir    = strings.clone(dir)
	g_prompt.is_dir = is_dir
	idx := clamp(at, 0, len(g_sidebar_entries))
	inject_at(&g_sidebar_entries, idx, Sidebar_Entry{is_dir = is_dir, depth = depth, editing = true})
	g_prompt.row       = idx
	g_sidebar_selected = idx
	sidebar_ensure_visible(idx)
}

// Begin an inline Rename: turn the existing row into a field pre-filled with
// the current name.
@(private="file")
sidebar_begin_rename :: proc(row: int) {
	if row < 0 || row >= len(g_sidebar_entries) do return
	e := g_sidebar_entries[row]
	prompt_cancel()
	g_prompt.kind   = .Rename
	g_prompt.dir    = strings.clone(filepath.dir(e.path))
	g_prompt.old    = strings.clone(e.path)
	g_prompt.is_dir = e.is_dir
	g_prompt.row    = row
	for i in 0 ..< len(e.name) do append(&g_prompt.buffer, e.name[i])
	g_sidebar_entries[row].editing = true
	g_sidebar_selected = row
	sidebar_ensure_visible(row)
}

// First index at/after `start` whose entry is shallower than `depth` — i.e. the
// end of the current indent group, where a new row at `depth` appends to the
// bottom of that group.
@(private="file")
sidebar_group_end :: proc(start, depth: int) -> int {
	i := start
	for i < len(g_sidebar_entries) && g_sidebar_entries[i].depth >= depth do i += 1
	return i
}

@(private="file")
sidebar_ensure_visible :: proc(idx: int) {
	if g_sidebar_view_rows <= 0 do return
	if idx < g_sidebar_scroll {
		g_sidebar_scroll = idx
	} else if idx >= g_sidebar_scroll + g_sidebar_view_rows {
		g_sidebar_scroll = idx - g_sidebar_view_rows + 1
	}
}

prompt_cancel :: proc() {
	if g_prompt.kind == .None do return
	prompt_clear()
	sidebar_rebuild() // drops the synthetic row / clears the editing flag
}

prompt_input :: proc(text: cstring) {
	s := string(text)
	for i in 0 ..< len(s) do append(&g_prompt.buffer, s[i])
}

prompt_backspace :: proc() {
	if len(g_prompt.buffer) == 0 do return
	i := len(g_prompt.buffer) - 1
	for i > 0 && (g_prompt.buffer[i] & 0xC0) == 0x80 do i -= 1 // back over UTF-8 continuation
	resize(&g_prompt.buffer, i)
}

prompt_confirm :: proc() {
	name := strings.trim_space(string(g_prompt.buffer[:]))
	if len(name) == 0 {
		prompt_cancel()
		return
	}
	// Each op rebuilds the tree (dropping our synthetic / editing row); then we
	// free state without an extra rebuild.
	switch g_prompt.kind {
	case .None:
	case .New_File:   sidebar_create_file(g_prompt.dir, name)
	case .New_Folder: sidebar_create_folder(g_prompt.dir, name)
	case .Rename:     sidebar_do_rename(g_prompt.old, g_prompt.dir, name)
	}
	prompt_clear()
}

// ── draw ───────────────────────────────────────────────────────────

@(private="file")
sidebar_header_h :: proc() -> f32 {
	// Workspace name row + a little breathing room + separator.
	return SIDEBAR_PAD + g_config.font.size + SIDEBAR_ROW_GAP + SIDEBAR_PAD
}

draw_sidebar :: proc(l: Layout) {
	if !g_sidebar_visible do return
	r := l.sidebar_rect

	// Panel background ties the sidebar to the editor's gutter by default
	// (config `[theme] sidebar_bg`, which inherits `gutter_bg`). Text is
	// drawn over this color so LCD subpixel AA bakes the right bg.
	panel_bg := g_theme.sidebar_bg_color
	fill_rect(r, panel_bg)

	row_h := g_config.font.size + SIDEBAR_ROW_GAP

	// Header: workspace basename (or a hint when none is open).
	header := len(g_workspace_root) > 0 ? path_basename(g_workspace_root) : "(no folder open)"
	hdr_cstr := strings.clone_to_cstring(header, context.temp_allocator)
	draw_text(hdr_cstr, r.x + SIDEBAR_PAD, r.y + SIDEBAR_PAD, MENU_DIM_COLOR, panel_bg)

	sep_y := r.y + sidebar_header_h() - SIDEBAR_PAD * 0.5
	fill_rect({r.x + SIDEBAR_PAD, sep_y, r.w - SIDEBAR_PAD * 2, 1.0 / g_density}, MENU_BORDER_COLOR)

	list_y := r.y + sidebar_header_h()
	list_h := r.y + r.h - list_y
	view_rows := max(0, int(list_h / row_h))
	g_sidebar_view_rows = view_rows

	// Clamp scroll to current content + viewport.
	max_scroll := max(0, len(g_sidebar_entries) - view_rows)
	g_sidebar_scroll = clamp(g_sidebar_scroll, 0, max_scroll)

	// When the scrollbar shows, the selection highlight stops short of it
	// so the row doesn't bleed through under the (flush-to-edge) track.
	sb_w: f32 = 6
	sb_visible := len(g_sidebar_entries) > view_rows && view_rows > 0
	hl_w := sb_visible ? r.w - sb_w : r.w

	clip := sdl.Rect{i32(r.x), i32(list_y), i32(r.w), i32(list_h)}
	sdl.SetRenderClipRect(g_renderer, &clip)

	end := min(g_sidebar_scroll + view_rows + 1, len(g_sidebar_entries))
	row := 0
	for i := g_sidebar_scroll; i < end; i += 1 {
		e := g_sidebar_entries[i]
		ry := list_y + f32(row) * row_h
		row += 1
		bg := panel_bg
		if i == g_sidebar_selected {
			fill_rect({r.x, ry, hl_w, row_h}, MENU_HOVER_COLOR)
			bg = MENU_HOVER_COLOR
		} else if i == g_sidebar_hovered {
			// Hover: a dimmer SOLID blend of the selection color over the
			// panel bg — NOT a translucent wash. The text's LCD AA bakes in
			// `bg`, so the fill and `bg` must be the exact same opaque color
			// or each glyph halos a box against the row (the "drawing behind"
			// artifact).
			hov := sdl.Color{
				u8((u16(panel_bg.r) + u16(MENU_HOVER_COLOR.r)) / 2),
				u8((u16(panel_bg.g) + u16(MENU_HOVER_COLOR.g)) / 2),
				u8((u16(panel_bg.b) + u16(MENU_HOVER_COLOR.b)) / 2),
				255,
			}
			fill_rect({r.x, ry, hl_w, row_h}, hov)
			bg = hov
		}
		x := r.x + SIDEBAR_PAD + f32(e.depth) * SIDEBAR_INDENT

		// Inline New/Rename text field: render the typed name + a caret in
		// place of the normal row, with the appropriate (folder/file) icon.
		if e.editing {
			if g_prompt.is_dir {
				gc := strings.clone_to_cstring(GLYPH_FOLDER, context.temp_allocator)
				draw_text(gc, x, ry, SIDEBAR_DIR_COLOR, bg, g_terminal_font)
			}
			fx := x + (g_prompt.is_dir ? g_config.font.size * SIDEBAR_ICON_COL : 0)
			tc := strings.clone_to_cstring(prompt_text(), context.temp_allocator)
			tw := draw_text(tc, fx, ry, MENU_TEXT_COLOR, bg)
			if int(active_editor().blink_timer * 2) % 2 == 0 {
				// Center the caret on the row (text sits top-aligned, the row has
				// SIDEBAR_ROW_GAP below it) so it doesn't look low.
				cy := ry + (row_h - g_config.font.size) * 0.5
				fill_rect({fx + tw, cy, 2, g_config.font.size}, g_theme.cursor_color)
			}
			continue
		}

		// Folders get an open/closed icon from the embedded Nerd Font; files
		// get none (the icon was redundant). Names still start at a fixed
		// column so the tree stays aligned.
		if e.is_dir {
			glyph := g_sidebar_expanded[e.path] ? GLYPH_FOLDER_OPEN : GLYPH_FOLDER
			gc := strings.clone_to_cstring(glyph, context.temp_allocator)
			draw_text(gc, x, ry, SIDEBAR_DIR_COLOR, bg, g_terminal_font)
		}
		// Folder names sit past their icon; file names (no icon) start at the
		// icon column so they line up with folder icons at the same depth —
		// otherwise the empty icon gap reads as a phantom indent under the
		// folder above them.
		name_x := x
		if e.is_dir do name_x += g_config.font.size * SIDEBAR_ICON_COL
		fg := e.is_dir ? SIDEBAR_DIR_COLOR : MENU_TEXT_COLOR
		nc := strings.clone_to_cstring(e.name, context.temp_allocator)
		draw_text(nc, name_x, ry, fg, bg)
	}

	sdl.SetRenderClipRect(g_renderer, nil)

	// Scrollbar (visual; the wheel does the scrolling). Flush to the right
	// edge so no highlighted-row sliver shows beside it.
	if sb_visible {
		track_w := sb_w
		track_x := r.x + r.w - track_w
		track_h := f32(view_rows) * row_h
		fill_rect({track_x, list_y, track_w, track_h}, g_theme.sb_track_color)
		total := f32(len(g_sidebar_entries))
		thumb_h := max(SB_MIN_THUMB, (f32(view_rows) / total) * track_h)
		ms := total - f32(view_rows)
		t: f32 = 0
		if ms > 0 do t = f32(g_sidebar_scroll) / ms
		fill_rect({track_x, list_y + t * (track_h - thumb_h), track_w, thumb_h}, g_theme.sb_thumb_color)
	}

	// Right-edge divider (grab handle).
	fill_rect({l.sidebar_divider_x, r.y, l.sidebar_divider_w, r.h}, g_theme.gutter_bg_color)

	// Dim when the sidebar doesn't have keyboard focus.
	if !g_sidebar_active do fill_rect(r, INACTIVE_DIM)
}

