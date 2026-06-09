package bragi

import "core:fmt"
import "core:os"
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
GLYPH_FILE :: "\uF15B" // nf-fa-file
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
g_sidebar_scroll: int
@(private="file")
g_sidebar_view_rows: int // visible row count from the last draw (for key-nav scrolling)

Sidebar_Entry :: struct {
	path:   string, // owned, absolute
	name:   string, // owned, base name
	is_dir: bool,
	depth:  int,
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

// ── draw ───────────────────────────────────────────────────────────

@(private="file")
sidebar_header_h :: proc() -> f32 {
	// Workspace name row + a little breathing room + separator.
	return SIDEBAR_PAD + g_config.font.size + SIDEBAR_ROW_GAP + SIDEBAR_PAD
}

draw_sidebar :: proc(l: Layout) {
	if !g_sidebar_visible do return
	r := l.sidebar_rect

	fill_rect(r, MENU_BG_COLOR)

	row_h := g_config.font.size + SIDEBAR_ROW_GAP

	// Header: workspace basename (or a hint when none is open).
	header := len(g_workspace_root) > 0 ? path_basename(g_workspace_root) : "(no folder open)"
	hdr_cstr := strings.clone_to_cstring(header, context.temp_allocator)
	draw_text(hdr_cstr, r.x + SIDEBAR_PAD, r.y + SIDEBAR_PAD, MENU_DIM_COLOR, MENU_BG_COLOR)

	sep_y := r.y + sidebar_header_h() - SIDEBAR_PAD * 0.5
	fill_rect({r.x + SIDEBAR_PAD, sep_y, r.w - SIDEBAR_PAD * 2, 1.0 / g_density}, MENU_BORDER_COLOR)

	list_y := r.y + sidebar_header_h()
	list_h := r.y + r.h - list_y
	view_rows := max(0, int(list_h / row_h))
	g_sidebar_view_rows = view_rows

	// Clamp scroll to current content + viewport.
	max_scroll := max(0, len(g_sidebar_entries) - view_rows)
	g_sidebar_scroll = clamp(g_sidebar_scroll, 0, max_scroll)

	clip := sdl.Rect{i32(r.x), i32(list_y), i32(r.w), i32(list_h)}
	sdl.SetRenderClipRect(g_renderer, &clip)

	end := min(g_sidebar_scroll + view_rows + 1, len(g_sidebar_entries))
	row := 0
	for i := g_sidebar_scroll; i < end; i += 1 {
		e := g_sidebar_entries[i]
		ry := list_y + f32(row) * row_h
		row += 1
		bg := MENU_BG_COLOR
		if i == g_sidebar_selected {
			fill_rect({r.x, ry, r.w, row_h}, MENU_HOVER_COLOR)
			bg = MENU_HOVER_COLOR
		}
		x := r.x + SIDEBAR_PAD + f32(e.depth) * SIDEBAR_INDENT
		// Icon column, drawn from the embedded Nerd Font so it renders
		// regardless of the configured UI font. Folder open/closed shows
		// expansion state; files get a generic file glyph.
		glyph := GLYPH_FILE
		icon_fg := MENU_DIM_COLOR
		if e.is_dir {
			glyph = g_sidebar_expanded[e.path] ? GLYPH_FOLDER_OPEN : GLYPH_FOLDER
			icon_fg = SIDEBAR_DIR_COLOR
		}
		gc := strings.clone_to_cstring(glyph, context.temp_allocator)
		draw_text(gc, x, ry, icon_fg, bg, g_terminal_font)
		// Name starts at a fixed offset past the icon so every row's
		// name aligns (icon advance widths vary by glyph).
		name_x := x + g_config.font.size * SIDEBAR_ICON_COL
		fg := e.is_dir ? SIDEBAR_DIR_COLOR : MENU_TEXT_COLOR
		nc := strings.clone_to_cstring(e.name, context.temp_allocator)
		draw_text(nc, name_x, ry, fg, bg)
	}

	sdl.SetRenderClipRect(g_renderer, nil)

	// Scrollbar (visual; the wheel does the scrolling).
	if len(g_sidebar_entries) > view_rows && view_rows > 0 {
		track_w: f32 = 6
		track_x := r.x + r.w - track_w - 2
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

