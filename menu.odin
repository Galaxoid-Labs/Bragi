package bragi

import "core:c"
import "core:fmt"
import "core:strings"
import sdl "vendor:sdl3"
import ttf "vendor:sdl3/ttf"

Menu_Action :: enum {
	None,
	Cut,
	Copy,
	Paste,
	Select_All,
	Undo,
	Redo,
	Open,
	Save,
	Save_As,
}

Menu_Item :: struct {
	label:        string,
	shortcut:     string,
	action:       Menu_Action,
	is_separator: bool,
}

// Per-platform shortcut hints. Mac uses ⌘ / ⇧; others use Ctrl+ / Shift+.
when ODIN_OS == .Darwin {
	SC_CUT        :: "⌘X"
	SC_COPY       :: "⌘C"
	SC_PASTE      :: "⌘V"
	SC_SELECT_ALL :: "⌘A"
	SC_UNDO       :: "⌘Z"
	SC_REDO       :: "⌘⇧Z"
	SC_OPEN       :: "⌘O"
	SC_SAVE       :: "⌘S"
	SC_SAVE_AS    :: "⌘⇧S"
} else {
	SC_CUT        :: "Ctrl+X"
	SC_COPY       :: "Ctrl+C"
	SC_PASTE      :: "Ctrl+V"
	SC_SELECT_ALL :: "Ctrl+A"
	SC_UNDO       :: "Ctrl+Z"
	SC_REDO       :: "Ctrl+Shift+Z"
	SC_OPEN       :: "Ctrl+O"
	SC_SAVE       :: "Ctrl+S"
	SC_SAVE_AS    :: "Ctrl+Shift+S"
}

CONTEXT_MENU := []Menu_Item{
	{label = "Cut",        shortcut = SC_CUT,        action = .Cut},
	{label = "Copy",       shortcut = SC_COPY,       action = .Copy},
	{label = "Paste",      shortcut = SC_PASTE,      action = .Paste},
	{is_separator = true},
	{label = "Select All", shortcut = SC_SELECT_ALL, action = .Select_All},
	{is_separator = true},
	{label = "Undo",       shortcut = SC_UNDO,       action = .Undo},
	{label = "Redo",       shortcut = SC_REDO,       action = .Redo},
	{is_separator = true},
	{label = "Open...",    shortcut = SC_OPEN,       action = .Open},
	{label = "Save",       shortcut = SC_SAVE,       action = .Save},
	{label = "Save As...", shortcut = SC_SAVE_AS,    action = .Save_As},
}

Menu :: struct {
	visible: bool,
	pos:     sdl.FPoint,
	hovered: int, // -1 = none
	width:   f32,
	height:  f32,
}

g_menu: Menu

MENU_BG_COLOR        :: sdl.Color{45, 45, 55, 255}
MENU_BORDER_COLOR    :: sdl.Color{80, 82, 92, 255}
MENU_HOVER_COLOR     :: sdl.Color{70, 95, 150, 255}
MENU_TEXT_COLOR      :: sdl.Color{225, 225, 230, 255}
MENU_DIM_COLOR       :: sdl.Color{140, 145, 160, 255}
MENU_SEP_COLOR       :: sdl.Color{70, 72, 82, 255}

MENU_PAD_X       :: 14.0
MENU_PAD_Y       :: 6.0
MENU_ITEM_H      :: 24.0
MENU_SEP_H       :: 7.0
MENU_LABEL_GAP   :: 24.0 // space between label end and shortcut start

@(private="file")
measure_text_w :: proc(s: string) -> f32 {
	if len(s) == 0 do return 0
	cstr := strings.clone_to_cstring(s, context.temp_allocator)
	w_px: c.int
	ttf.GetStringSize(g_font, cstr, 0, &w_px, nil)
	return f32(w_px) / g_density
}

menu_show :: proc(at: sdl.FPoint) {
	g_menu.visible = true
	g_menu.hovered = -1

	// Width: widest (label) + gap + widest (shortcut) + padding.
	max_label_w:    f32 = 0
	max_shortcut_w: f32 = 0
	for item in CONTEXT_MENU {
		if item.is_separator do continue
		lw := measure_text_w(item.label)
		if lw > max_label_w do max_label_w = lw
		sw := measure_text_w(item.shortcut)
		if sw > max_shortcut_w do max_shortcut_w = sw
	}
	gap := max_shortcut_w > 0 ? f32(MENU_LABEL_GAP) : 0
	g_menu.width = max_label_w + gap + max_shortcut_w + MENU_PAD_X * 2

	// Height = sum of items + vertical padding
	h: f32 = MENU_PAD_Y * 2
	for item in CONTEXT_MENU {
		h += item.is_separator ? MENU_SEP_H : MENU_ITEM_H
	}
	g_menu.height = h

	// Clamp to screen so the menu never opens partly off-screen.
	sw, sh: c.int
	sdl.GetWindowSize(g_window, &sw, &sh)
	g_menu.pos = at
	if g_menu.pos.x + g_menu.width  > f32(sw) do g_menu.pos.x = f32(sw) - g_menu.width
	if g_menu.pos.y + g_menu.height > f32(sh) do g_menu.pos.y = f32(sh) - g_menu.height
	if g_menu.pos.x < 0 do g_menu.pos.x = 0
	if g_menu.pos.y < 0 do g_menu.pos.y = 0
}

menu_hide :: proc() {
	g_menu.visible = false
	g_menu.hovered = -1
}

// True when the action makes sense given the current editor state. Used
// by the renderer to dim disabled rows and by the click handler to no-op
// them. Anything always-available (Open / Save / Save As / Select All
// when the buffer has any bytes) returns true unconditionally.
@(private="file")
menu_action_enabled :: proc(ed: ^Editor, action: Menu_Action) -> bool {
	switch action {
	case .None:
		return false
	case .Cut, .Copy:
		return editor_has_selection(ed)
	case .Paste:
		return sdl.HasClipboardText()
	case .Select_All:
		return piece_buffer_len(&ed.buffer) > 0
	case .Undo:
		return len(ed.undo_stack) > 0 || len(ed.pending.ops) > 0
	case .Redo:
		return len(ed.redo_stack) > 0
	case .Open, .Save, .Save_As:
		return true
	}
	return true
}

@(private="file")
menu_item_at :: proc(local_x, local_y: f32) -> int {
	if local_x < 0 || local_x > g_menu.width do return -1
	y := f32(MENU_PAD_Y)
	for item, idx in CONTEXT_MENU {
		ih: f32 = item.is_separator ? MENU_SEP_H : MENU_ITEM_H
		if local_y >= y && local_y < y + ih {
			return item.is_separator ? -1 : idx
		}
		y += ih
	}
	return -1
}

menu_handle_motion :: proc(mx, my: f32) {
	if !g_menu.visible do return
	g_menu.hovered = menu_item_at(mx - g_menu.pos.x, my - g_menu.pos.y)
}

// Returns true if the click hit the menu (item or empty space within bounds).
// Returns false for clicks outside the menu rectangle.
menu_handle_click :: proc(ed: ^Editor, mx, my: f32) -> bool {
	if !g_menu.visible do return false
	rect := sdl.FRect{g_menu.pos.x, g_menu.pos.y, g_menu.width, g_menu.height}
	if !point_in_rect({mx, my}, rect) do return false

	idx := menu_item_at(mx - g_menu.pos.x, my - g_menu.pos.y)
	if idx >= 0 {
		action := CONTEXT_MENU[idx].action
		if menu_action_enabled(ed, action) do menu_dispatch(ed, action)
		// Disabled-item click still closes the menu, matching the
		// behavior of native context menus.
	}
	menu_hide()
	return true
}

menu_dispatch :: proc(ed: ^Editor, action: Menu_Action) {
	switch action {
	case .None:
	case .Cut:        clipboard_cut(ed)
	case .Copy:       clipboard_copy(ed)
	case .Paste:      clipboard_paste(ed)
	case .Select_All: editor_select_all(ed)
	case .Undo:       editor_undo(ed)
	case .Redo:       editor_redo(ed)
	case .Open:       open_file_dialog(ed)
	case .Save_As:    save_as_dialog(ed)
	case .Save:
		if !editor_save_file(ed) do save_as_dialog(ed)
	}
}

draw_menu :: proc() {
	if !g_menu.visible do return

	// Disabled-state checks need an editor reference. The active pane is
	// the right one — the right-click that opened the menu set it.
	ed := active_editor()

	rect := sdl.FRect{g_menu.pos.x, g_menu.pos.y, g_menu.width, g_menu.height}

	// Solid background.
	fill_rect(rect, MENU_BG_COLOR)

	// 1-physical-pixel border on all four sides.
	bw := 1.0 / g_density
	fill_rect({rect.x,                rect.y,                rect.w, bw    }, MENU_BORDER_COLOR)
	fill_rect({rect.x,                rect.y + rect.h - bw,  rect.w, bw    }, MENU_BORDER_COLOR)
	fill_rect({rect.x,                rect.y,                bw,     rect.h}, MENU_BORDER_COLOR)
	fill_rect({rect.x + rect.w - bw,  rect.y,                bw,     rect.h}, MENU_BORDER_COLOR)

	y := rect.y + MENU_PAD_Y
	for item, idx in CONTEXT_MENU {
		if item.is_separator {
			fill_rect({
				rect.x + MENU_PAD_X,
				y + MENU_SEP_H * 0.5 - bw * 0.5,
				rect.w - MENU_PAD_X * 2,
				bw,
			}, MENU_SEP_COLOR)
			y += MENU_SEP_H
			continue
		}

		enabled := menu_action_enabled(ed, item.action)

		bg := MENU_BG_COLOR
		// Hover highlight only on enabled items — disabled rows stay
		// flat so the dimming reads as "you can't click this".
		if idx == g_menu.hovered && enabled {
			fill_rect({rect.x + 2, y, rect.w - 4, MENU_ITEM_H}, MENU_HOVER_COLOR)
			bg = MENU_HOVER_COLOR
		}

		text_y := y + (MENU_ITEM_H - g_config.font.size) * 0.5

		label_color: sdl.Color
		sc_color:    sdl.Color
		switch {
		case !enabled:
			label_color = MENU_DIM_COLOR
			sc_color    = MENU_DIM_COLOR
		case bg == MENU_HOVER_COLOR:
			label_color = MENU_TEXT_COLOR
			sc_color    = MENU_TEXT_COLOR
		case:
			label_color = MENU_TEXT_COLOR
			sc_color    = MENU_DIM_COLOR
		}

		label_cstr := strings.clone_to_cstring(item.label, context.temp_allocator)
		draw_text(label_cstr, rect.x + MENU_PAD_X, text_y, label_color, bg)

		if len(item.shortcut) > 0 {
			sc_cstr := strings.clone_to_cstring(item.shortcut, context.temp_allocator)
			sc_w := measure_text_w(item.shortcut)
			sc_x := rect.x + rect.w - MENU_PAD_X - sc_w
			draw_text(sc_cstr, sc_x, text_y, sc_color, bg)
		}

		y += MENU_ITEM_H
	}
}
