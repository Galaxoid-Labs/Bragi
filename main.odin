package bragi

import "base:runtime"
import "core:fmt"
import "core:math"
import "core:os"
import "core:strings"
import "core:unicode/utf8"
import "core:c"
import sdl "vendor:sdl3"
import ttf "vendor:sdl3/ttf"

WINDOW_WIDTH  :: 1280
WINDOW_HEIGHT :: 800
WINDOW_TITLE  :: "Bragi"

// FiraCode-Regular.ttf baked into the binary at compile time (~290 KB).
// Used as the default font when g_config.font.path is empty, and as the
// fallback if a user-configured path fails to load. Declared with `:=` so
// the bytes live in addressable rodata (`::` would make it an unaddressable
// compile-time constant that SDL_IOFromConstMem can't take a pointer to).
@(rodata)
FIRA_CODE_DATA := #load("FiraCode-Regular.ttf")

// FONT_SIZE / FONT_PATH / LINE_SPACING / TAB_SIZE / COLUMN_GUIDE all live in
// g_config and are loaded from INI at startup (see config.odin).
SCROLL_LINES_PER_NOTCH :: 3.0

SB_THICKNESS :: 14.0
SB_MIN_THUMB :: 24.0

GUTTER_PADDING    :: 12.0
GUTTER_MIN_DIGITS :: 3

STATUS_PAD_X :: 8.0
STATUS_PAD_Y :: 5.0

BG_COLOR             :: sdl.Color{30, 30, 38, 255}
TEXT_COLOR           :: sdl.Color{220, 220, 220, 255}
CURSOR_COLOR         :: sdl.Color{240, 200, 80, 255}
SELECTION_COLOR      :: sdl.Color{70, 95, 150, 120}
SEARCH_MATCH_COLOR   :: sdl.Color{190, 80, 180, 120}
SB_TRACK_COLOR       :: sdl.Color{40, 40, 48, 255}
SB_THUMB_COLOR       :: sdl.Color{90, 90, 100, 255}
SB_THUMB_HOVER_COLOR :: sdl.Color{130, 130, 140, 255}
GUTTER_BG_COLOR      :: sdl.Color{24, 24, 30, 255}
GUTTER_TEXT_COLOR    :: sdl.Color{90, 95, 110, 255}
GUTTER_ACTIVE_COLOR  :: sdl.Color{200, 200, 210, 255}
STATUS_BG_COLOR      :: sdl.Color{20, 20, 26, 255}
STATUS_TEXT_COLOR    :: sdl.Color{200, 200, 210, 255}
STATUS_DIM_COLOR     :: sdl.Color{120, 125, 140, 255}

// Syntax theme. Eventually loaded from config; default values today.
Theme :: struct {
	default_color:  sdl.Color,
	keyword_color:  sdl.Color,
	type_color:     sdl.Color,
	constant_color: sdl.Color,
	number_color:   sdl.Color,
	string_color:   sdl.Color,
	comment_color:  sdl.Color,
	function_color: sdl.Color,
}

DEFAULT_THEME :: Theme{
	default_color  = TEXT_COLOR,
	keyword_color  = sdl.Color{198, 120, 221, 255}, // purple
	type_color     = sdl.Color{ 95, 200, 218, 255}, // cyan
	constant_color = sdl.Color{229, 192, 123, 255}, // gold (true/false/nil)
	number_color   = sdl.Color{215, 145,  90, 255}, // orange
	string_color   = sdl.Color{152, 195, 121, 255}, // green
	comment_color  = sdl.Color{ 95, 110, 130, 255}, // muted blue-gray
	function_color = sdl.Color{ 97, 175, 239, 255}, // blue
}

theme_color :: proc(theme: ^Theme, kind: Token_Kind) -> sdl.Color {
	switch kind {
	case .Default:  return theme.default_color
	case .Keyword:  return theme.keyword_color
	case .Type:     return theme.type_color
	case .Constant: return theme.constant_color
	case .Number:   return theme.number_color
	case .String:   return theme.string_color
	case .Comment:  return theme.comment_color
	case .Function: return theme.function_color
	}
	return theme.default_color
}

g_theme: Theme = DEFAULT_THEME

WELCOME_TEXT :: "Bragi — fast, lightweight editor"

// Globals — easier than threading through every proc. Set in main, read elsewhere.
g_renderer:    ^sdl.Renderer
g_window:      ^sdl.Window
g_font:        ^ttf.Font
g_density:     f32   // pixel density (1.0 non-retina, 2.0 retina)
g_char_width:  f32   // logical px per monospace char
g_line_height: f32   // logical px per line

// Text cache: keyed by hash of (text, fg, bg). Avoids re-rasterizing unchanged
// lines/labels every frame. Capped to keep memory bounded; on overflow we wipe
// the whole cache (cheap to rebuild on the next few frames).
Text_Tex :: struct { tex: ^sdl.Texture, w, h: f32 }
g_text_cache: map[u64]Text_Tex
TEXT_CACHE_MAX :: 1024

fnv64a :: proc(data: []u8) -> u64 {
	h := u64(0xcbf29ce484222325)
	for b in data {
		h = h ~ u64(b)
		h = h * u64(0x100000001b3)
	}
	return h
}

text_cache_key :: proc(text: string, fg, bg: sdl.Color) -> u64 {
	h := fnv64a(transmute([]u8)text)
	fg_u := u64(fg.r) | u64(fg.g)<<8 | u64(fg.b)<<16 | u64(fg.a)<<24
	bg_u := u64(bg.r) | u64(bg.g)<<8 | u64(bg.b)<<16 | u64(bg.a)<<24
	return h ~ fg_u ~ (bg_u << 32) ~ (bg_u >> 32)
}

text_cache_clear :: proc() {
	for _, entry in g_text_cache do sdl.DestroyTexture(entry.tex)
	clear(&g_text_cache)
}

Layout :: struct {
	screen_w, screen_h: f32,
	gutter_w:           f32,
	text_x, text_y:     f32,
	text_w, text_h:     f32,
	v_track:            sdl.FRect,
	h_track:            sdl.FRect,
	status_y, status_h: f32,
}

compute_layout :: proc(ed: ^Editor) -> Layout {
	l: Layout
	w, h: c.int
	sdl.GetWindowSize(g_window, &w, &h)
	l.screen_w = f32(w)
	l.screen_h = f32(h)

	digits := max(GUTTER_MIN_DIGITS, digit_count(editor_total_lines(ed)))
	l.gutter_w = f32(digits) * g_char_width + GUTTER_PADDING * 2

	l.status_h = g_config.font.size + STATUS_PAD_Y * 2
	l.status_y = l.screen_h - l.status_h

	l.text_x = l.gutter_w
	l.text_y = 0
	l.text_w = l.screen_w - l.text_x - SB_THICKNESS
	l.text_h = l.status_y - SB_THICKNESS - l.text_y

	l.v_track = {l.screen_w - SB_THICKNESS, l.text_y, SB_THICKNESS, l.text_h}
	l.h_track = {l.text_x, l.status_y - SB_THICKNESS, l.text_w, SB_THICKNESS}
	return l
}

// Snap a logical-pixel coordinate to the nearest physical pixel boundary.
// Avoids subpixel-positioning blur when smooth scrolling produces fractional
// logical-pixel positions.
snap_px :: proc(v: f32) -> f32 {
	return math.round(v * g_density) / g_density
}

// Render a UTF-8 string at (x,y) using LCD subpixel AA. Returns logical pixel
// width. Caches rasterized textures by content+colors so unchanged lines don't
// hit FreeType every frame.
draw_text :: proc(text: cstring, x, y: f32, fg, bg: sdl.Color) -> f32 {
	if text == nil || len(string(text)) == 0 do return 0

	sx := snap_px(x)
	sy := snap_px(y)

	key := text_cache_key(string(text), fg, bg)
	if entry, ok := g_text_cache[key]; ok {
		dst := sdl.FRect{sx, sy, entry.w, entry.h}
		sdl.RenderTexture(g_renderer, entry.tex, nil, &dst)
		return entry.w
	}

	surface := ttf.RenderText_LCD(g_font, text, 0, fg, bg)
	if surface == nil do return 0
	defer sdl.DestroySurface(surface)

	texture := sdl.CreateTextureFromSurface(g_renderer, surface)
	if texture == nil do return 0

	w := f32(surface.w) / g_density
	h := f32(surface.h) / g_density

	if len(g_text_cache) >= TEXT_CACHE_MAX do text_cache_clear()
	g_text_cache[key] = Text_Tex{tex = texture, w = w, h = h}

	dst := sdl.FRect{sx, sy, w, h}
	sdl.RenderTexture(g_renderer, texture, nil, &dst)
	return w
}

fill_rect :: proc(rect: sdl.FRect, color: sdl.Color) {
	sdl.SetRenderDrawColor(g_renderer, color.r, color.g, color.b, color.a)
	r := rect
	sdl.RenderFillRect(g_renderer, &r)
}

// Convert a screen-space mouse position (logical px) to a buffer byte offset.
mouse_to_buffer_pos :: proc(ed: ^Editor, mx, my: f32, l: Layout) -> int {
	doc_y := my - l.text_y + ed.scroll_y
	line := max(0, int(doc_y / g_line_height))
	max_line := editor_total_lines(ed) - 1
	line = min(line, max_line)

	doc_x := mx - l.text_x + ed.scroll_x
	col := max(0, int((doc_x + g_char_width * 0.5) / g_char_width))

	return editor_pos_at_line_col(ed, line, col)
}

// Same tab-stop expansion as before.
expand_tabs :: proc(bytes: []u8, allocator := context.allocator) -> string {
	sb := strings.builder_make(allocator)
	col := 0
	for b in bytes {
		if b == '\t' {
			advance := g_config.editor.tab_size - (col % g_config.editor.tab_size)
			for _ in 0 ..< advance do strings.write_byte(&sb, ' ')
			col += advance
		} else {
			strings.write_byte(&sb, b)
			if (b & 0xC0) != 0x80 do col += 1
		}
	}
	return strings.to_string(sb)
}

// Number of display columns in `bytes` (UTF-8 leading bytes only — continuation
// bytes don't advance columns).
count_display_cols :: proc(bytes: []u8) -> int {
	col := 0
	for b in bytes {
		if (b & 0xC0) != 0x80 do col += 1
	}
	return col
}

draw_segment :: proc(bytes: []u8, x, y: f32, fg, bg: sdl.Color) {
	if len(bytes) == 0 do return
	cstr := strings.clone_to_cstring(string(bytes), context.temp_allocator)
	draw_text(cstr, x, y, fg, bg)
}

// Walk tokens + the gaps between them, drawing each as a separately-colored
// segment. Cache works per-segment, so unchanged tokens don't re-rasterize.
draw_tokenized_line :: proc(bytes: []u8, tokens: []Token, x_origin, y: f32) {
	default_fg := theme_color(&g_theme, .Default)
	prev_end := 0
	cur_col := 0
	for tok in tokens {
		if tok.start > prev_end {
			seg := bytes[prev_end:tok.start]
			x := x_origin + f32(cur_col) * g_char_width
			draw_segment(seg, x, y, default_fg, BG_COLOR)
			cur_col += count_display_cols(seg)
			prev_end = tok.start
		}
		seg := bytes[tok.start:tok.end]
		x := x_origin + f32(cur_col) * g_char_width
		draw_segment(seg, x, y, theme_color(&g_theme, tok.kind), BG_COLOR)
		cur_col += count_display_cols(seg)
		prev_end = tok.end
	}
	if prev_end < len(bytes) {
		seg := bytes[prev_end:]
		x := x_origin + f32(cur_col) * g_char_width
		draw_segment(seg, x, y, default_fg, BG_COLOR)
	}
}

// Walk from line 0 to `target_line` to compute the tokenizer state at the
// start of `target_line`. O(n) per call; called once per draw frame.
compute_state_at_line :: proc(ed: ^Editor, target_line: int) -> Tokenizer_State {
	if ed.language == .None do return .Normal
	state := Tokenizer_State.Normal
	n := gap_buffer_len(&ed.buffer)
	line := 0
	line_start := 0
	for line < target_line && line_start < n {
		line_end := line_start
		for line_end < n && gap_buffer_byte_at(&ed.buffer, line_end) != '\n' do line_end += 1
		line_len := line_end - line_start
		buf := make([]u8, line_len, context.temp_allocator)
		for k in 0 ..< line_len do buf[k] = gap_buffer_byte_at(&ed.buffer, line_start + k)
		_, state = syntax_tokenize(ed.language, buf, state)
		line_start = line_end + 1
		line += 1
	}
	return state
}

// ──────────────────────────────────────────────────────────────────
// Input
// ──────────────────────────────────────────────────────────────────

shift_held    :: proc(mods: sdl.Keymod) -> bool { return mods & sdl.KMOD_SHIFT != {} }
cmd_or_ctrl   :: proc(mods: sdl.Keymod) -> bool { return mods & (sdl.KMOD_GUI | sdl.KMOD_CTRL) != {} }

handle_key_down :: proc(ed: ^Editor, ev: sdl.KeyboardEvent) {
	if g_menu.visible && ev.key == sdl.K_ESCAPE {
		menu_hide()
		return
	}

	mods := ev.mod
	extend := shift_held(mods)
	cmd := cmd_or_ctrl(mods)

	// Cmd/Ctrl shortcuts (work in any mode)
	if cmd {
		switch ev.key {
		case sdl.K_A: editor_select_all(ed)
		case sdl.K_C: clipboard_copy(ed)
		case sdl.K_X: clipboard_cut(ed)
		case sdl.K_V: clipboard_paste(ed)
		case sdl.K_O:
			open_file_dialog(ed)
		case sdl.K_S:
			if shift_held(mods) {
				save_as_dialog(ed)
			} else if !editor_save_file(ed) {
				// No file path yet — fall through to Save As so the user can pick one.
				save_as_dialog(ed)
			}
		case sdl.K_Z:
			if shift_held(mods) do editor_redo(ed)
			else                do editor_undo(ed)
		case sdl.K_Y: editor_redo(ed)
		}
		return
	}

	// Mode-specific keys
	switch ed.mode {
	case .Insert:
		switch ev.key {
		case sdl.K_ESCAPE:    vim_enter_normal(ed)
		case sdl.K_RETURN:    editor_smart_newline(ed)
		case sdl.K_BACKSPACE: editor_backspace(ed)
		case sdl.K_DELETE:    editor_delete_forward(ed)
		case sdl.K_LEFT:      editor_move_left(ed, extend)
		case sdl.K_RIGHT:     editor_move_right(ed, extend)
		case sdl.K_UP:        editor_move_up(ed, extend)
		case sdl.K_DOWN:      editor_move_down(ed, extend)
		case sdl.K_HOME:      editor_move_home(ed, extend)
		case sdl.K_END:       editor_move_end(ed, extend)
		case sdl.K_TAB:       editor_insert_soft_tab(ed)
		}
	case .Normal:
		switch ev.key {
		case sdl.K_ESCAPE: vim_reset_state(ed)
		case sdl.K_LEFT:   editor_move_left(ed, false)
		case sdl.K_RIGHT:  editor_move_right(ed, false)
		case sdl.K_UP:     editor_move_up(ed, false)
		case sdl.K_DOWN:   editor_move_down(ed, false)
		}
	case .Command, .Search:
		switch ev.key {
		case sdl.K_ESCAPE:
			ed.mode = .Normal
			clear(&ed.cmd_buffer)
		case sdl.K_RETURN:
			text := string(ed.cmd_buffer[:])
			if ed.mode == .Search {
				if len(text) > 0 {
					if len(ed.search_pattern) > 0 do delete(ed.search_pattern)
					ed.search_pattern = strings.clone(text)
					editor_find_next(ed, ed.search_pattern, ed.search_forward)
				} else if len(ed.search_pattern) > 0 {
					delete(ed.search_pattern)
					ed.search_pattern = ""
				}
			} else {
				vim_execute_command(ed, text)
			}
			clear(&ed.cmd_buffer)
			if ed.mode == .Command || ed.mode == .Search do ed.mode = .Normal
		case sdl.K_BACKSPACE:
			if len(ed.cmd_buffer) == 0 {
				ed.mode = .Normal
			} else {
				i := len(ed.cmd_buffer) - 1
				for i > 0 && (ed.cmd_buffer[i] & 0xC0) == 0x80 do i -= 1
				resize(&ed.cmd_buffer, i)
			}
		}
	}
}

handle_text_input :: proc(ed: ^Editor, text: cstring) {
	if text == nil do return
	s := string(text)

	switch ed.mode {
	case .Insert:
		for r in s do editor_insert_rune(ed, r)
	case .Normal:
		for r in s do vim_handle_char(ed, r)
	case .Command, .Search:
		// Append raw UTF-8 bytes to the cmd buffer (used by both ":" and "/").
		for i in 0 ..< len(s) do append(&ed.cmd_buffer, s[i])
	}
}

scrollbar_thumb_metrics :: proc(scroll, content, viewport, track: f32) -> (start, size: f32) {
	if content <= viewport do return 0, track
	size = max(SB_MIN_THUMB, viewport / content * track)
	max_scroll := content - viewport
	start = scroll / max_scroll * (track - size)
	return
}

handle_mouse_button :: proc(ed: ^Editor, ev: sdl.MouseButtonEvent, l: Layout) {
	mx, my := ev.x, ev.y
	mouse := sdl.FPoint{mx, my}

	// Context menu interaction. Only act on button-down (otherwise the
	// button-up that follows the right-click that *opened* the menu would
	// immediately close it).
	if ev.down && g_menu.visible {
		if ev.button == sdl.BUTTON_LEFT {
			if menu_handle_click(ed, mx, my) do return // hit a menu item
			menu_hide()                                 // left-click outside dismisses + falls through
		} else {
			menu_hide() // right-click while menu is open dismisses; below opens a new one
		}
	}

	// Right-click in the text or gutter area opens the context menu.
	if ev.down && ev.button == sdl.BUTTON_RIGHT {
		clickable := sdl.FRect{0, l.text_y, l.text_x + l.text_w, l.text_h}
		if point_in_rect(mouse, clickable) do menu_show({mx, my})
		return
	}

	if ev.button != sdl.BUTTON_LEFT do return

	if !ev.down {
		ed.mouse_drag = false
		ed.sb_drag = .None
		return
	}

	content_h := f32(editor_total_lines(ed)) * g_line_height
	content_w := f32(editor_max_line_cols(ed)) * g_char_width
	v_thumb_start, v_thumb_size := scrollbar_thumb_metrics(ed.scroll_y, content_h, l.text_h, l.v_track.h)
	h_thumb_start, h_thumb_size := scrollbar_thumb_metrics(ed.scroll_x, content_w, l.text_w, l.h_track.w)

	v_thumb_rect := sdl.FRect{l.v_track.x, l.v_track.y + v_thumb_start, l.v_track.w, v_thumb_size}
	h_thumb_rect := sdl.FRect{l.h_track.x + h_thumb_start, l.h_track.y, h_thumb_size, l.h_track.h}

	if content_h > l.text_h && point_in_rect(mouse, v_thumb_rect) {
		ed.sb_drag = .Vertical
		ed.sb_drag_offset = my - v_thumb_rect.y
		return
	}
	if content_w > l.text_w && point_in_rect(mouse, h_thumb_rect) {
		ed.sb_drag = .Horizontal
		ed.sb_drag_offset = mx - h_thumb_rect.x
		return
	}

	// Click on the V track (but not on the thumb): jump the thumb centre to
	// the click position and continue as a drag. Same for H.
	if content_h > l.text_h && point_in_rect(mouse, l.v_track) {
		target_thumb_y := my - l.v_track.y - v_thumb_size / 2
		track_room := l.v_track.h - v_thumb_size
		t := track_room > 0 ? clamp(target_thumb_y / track_room, 0, 1) : 0
		ed.scroll_y = t * (content_h - l.text_h)
		ed.sb_drag = .Vertical
		ed.sb_drag_offset = v_thumb_size / 2
		return
	}
	if content_w > l.text_w && point_in_rect(mouse, l.h_track) {
		target_thumb_x := mx - l.h_track.x - h_thumb_size / 2
		track_room := l.h_track.w - h_thumb_size
		t := track_room > 0 ? clamp(target_thumb_x / track_room, 0, 1) : 0
		ed.scroll_x = t * (content_w - l.text_w)
		ed.sb_drag = .Horizontal
		ed.sb_drag_offset = h_thumb_size / 2
		return
	}

	// Gutter clicks are treated like text-area clicks at column 0 — the col
	// math in mouse_to_buffer_pos clamps to 0 when mx < text_x, so dragging
	// in the gutter (or starting in the gutter and dragging into text) just
	// works.
	clickable := sdl.FRect{0, l.text_y, l.text_x + l.text_w, l.text_h}
	if point_in_rect(mouse, clickable) {
		commit_pending(ed)
		pos := mouse_to_buffer_pos(ed, mx, my, l)
		ed.cursor = pos
		mods := sdl.GetModState()
		if !shift_held(mods) do ed.anchor = pos
		_, ed.desired_col = editor_pos_to_line_col(ed, ed.cursor)
		ed.mouse_drag = true
		ed.blink_timer = 0
	}
}

handle_mouse_motion :: proc(ed: ^Editor, ev: sdl.MouseMotionEvent, l: Layout) {
	mx, my := ev.x, ev.y
	if g_menu.visible {
		menu_handle_motion(mx, my)
		return
	}
	switch ed.sb_drag {
	case .Vertical:
		content_h := f32(editor_total_lines(ed)) * g_line_height
		_, thumb_h := scrollbar_thumb_metrics(ed.scroll_y, content_h, l.text_h, l.v_track.h)
		new_thumb_y := my - ed.sb_drag_offset - l.v_track.y
		track_room := l.v_track.h - thumb_h
		t := track_room > 0 ? clamp(new_thumb_y / track_room, 0, 1) : 0
		ed.scroll_y = t * (content_h - l.text_h)
	case .Horizontal:
		content_w := f32(editor_max_line_cols(ed)) * g_char_width
		_, thumb_w := scrollbar_thumb_metrics(ed.scroll_x, content_w, l.text_w, l.h_track.w)
		new_thumb_x := mx - ed.sb_drag_offset - l.h_track.x
		track_room := l.h_track.w - thumb_w
		t := track_room > 0 ? clamp(new_thumb_x / track_room, 0, 1) : 0
		ed.scroll_x = t * (content_w - l.text_w)
	case .None:
		if ed.mouse_drag {
			pos := mouse_to_buffer_pos(ed, mx, my, l)
			ed.cursor = pos
			_, ed.desired_col = editor_pos_to_line_col(ed, ed.cursor)
			ed.blink_timer = 0
		}
	}
}

handle_mouse_wheel :: proc(ed: ^Editor, ev: sdl.MouseWheelEvent) {
	if ev.y != 0 do ed.scroll_y -= ev.y * g_line_height * SCROLL_LINES_PER_NOTCH
	if ev.x != 0 do ed.scroll_x -= ev.x * g_char_width  * SCROLL_LINES_PER_NOTCH
}

clamp_scroll :: proc(ed: ^Editor, l: Layout) {
	content_h := f32(editor_total_lines(ed)) * g_line_height
	content_w := f32(editor_max_line_cols(ed)) * g_char_width
	max_y := max(0, content_h - l.text_h)
	max_x := max(0, content_w - l.text_w)
	ed.scroll_y = clamp(ed.scroll_y, 0, max_y)
	ed.scroll_x = clamp(ed.scroll_x, 0, max_x)
}

auto_scroll_to_caret :: proc(ed: ^Editor, l: Layout) {
	cline, ccol := editor_pos_to_line_col(ed, ed.cursor)
	caret_y := f32(cline) * g_line_height
	caret_x := f32(ccol) * g_char_width
	if caret_y < ed.scroll_y                       do ed.scroll_y = caret_y
	else if caret_y + g_line_height > ed.scroll_y + l.text_h do ed.scroll_y = caret_y + g_line_height - l.text_h
	if caret_x < ed.scroll_x                       do ed.scroll_x = caret_x
	else if caret_x + g_char_width  > ed.scroll_x + l.text_w do ed.scroll_x = caret_x + g_char_width  - l.text_w
}

point_in_rect :: proc(p: sdl.FPoint, r: sdl.FRect) -> bool {
	return p.x >= r.x && p.x < r.x + r.w && p.y >= r.y && p.y < r.y + r.h
}

// ──────────────────────────────────────────────────────────────────
// Clipboard
// ──────────────────────────────────────────────────────────────────

clipboard_copy :: proc(ed: ^Editor) {
	if !editor_has_selection(ed) do return
	text := editor_selection_text(ed, context.temp_allocator)
	cstr := strings.clone_to_cstring(text, context.temp_allocator)
	sdl.SetClipboardText(cstr)
}

clipboard_cut :: proc(ed: ^Editor) {
	if !editor_has_selection(ed) do return
	clipboard_copy(ed)
	editor_backspace(ed)
}

clipboard_paste :: proc(ed: ^Editor) {
	raw := sdl.GetClipboardText()
	if raw == nil do return
	defer sdl.free(rawptr(raw))
	editor_insert_string(ed, string(cstring(raw)))
}

// ──────────────────────────────────────────────────────────────────
// Drawing
// ──────────────────────────────────────────────────────────────────

draw_selection_for_line :: proc(
	ed: ^Editor,
	line_byte_start, line_byte_end: int,
	sel_lo, sel_hi: int,
	x_origin, y: f32,
	color: sdl.Color,
) {
	on_line_lo := max(sel_lo, line_byte_start)
	on_line_hi := min(sel_hi, line_byte_end)
	if on_line_lo > line_byte_end || on_line_hi < line_byte_start do return

	_, start_col := editor_pos_to_line_col(ed, on_line_lo)
	_, end_col   := editor_pos_to_line_col(ed, on_line_hi)

	x := x_origin + f32(start_col) * g_char_width
	w := f32(end_col - start_col) * g_char_width
	if sel_hi > line_byte_end do w += g_char_width
	if w <= 0 do return

	fill_rect({x, y, w, g_line_height}, color)
}

draw_editor :: proc(ed: ^Editor, l: Layout) {
	first_visible := max(0, int(ed.scroll_y / g_line_height))
	last_visible  := first_visible + int(l.text_h / g_line_height) + 1
	total_lines   := editor_total_lines(ed)
	last_visible = min(last_visible, total_lines - 1)

	sel_lo, sel_hi := editor_selection_range(ed)
	has_sel := editor_has_selection(ed)

	// Recolor the selection rect when it exactly covers the active search
	// match — same trigger as the [n/m] readout, so the highlight only
	// appears while the user is paging through results.
	sel_color := SELECTION_COLOR
	if has_sel && len(ed.search_pattern) > 0 &&
	   sel_hi - sel_lo == len(ed.search_pattern) {
		cur, _ := editor_search_stats(ed, ed.search_pattern)
		if cur > 0 do sel_color = SEARCH_MATCH_COLOR
	}

	clip := sdl.Rect{i32(l.text_x * g_density), i32(l.text_y * g_density), i32(l.text_w * g_density), i32(l.text_h * g_density)}
	sdl.SetRenderClipRect(g_renderer, &clip)
	defer sdl.SetRenderClipRect(g_renderer, nil)

	// Column guide (vertical ruler at the configured column). Drawn before
	// text so glyphs that reach the guide column mask it. Same RGB as comment
	// color but at low alpha so the thin line blends into the BG instead of
	// reading as a saturated stripe.
	if g_config.editor.column_guide > 0 {
		gx := snap_px(l.text_x + f32(g_config.editor.column_guide) * g_char_width - ed.scroll_x)
		if gx >= l.text_x && gx < l.text_x + l.text_w {
			gw := 1.0 / g_density // 1 physical pixel
			c := g_theme.comment_color
			c.a = 60
			fill_rect({gx, l.text_y, gw, l.text_h}, c)
		}
	}

	// Resume tokenizer state from before the first visible line (handles block
	// comments that started above the viewport).
	state := compute_state_at_line(ed, first_visible)

	buf_len := gap_buffer_len(&ed.buffer)
	line_idx := first_visible
	line_start := editor_nth_line_start(ed, first_visible)
	for line_idx <= last_visible {
		line_end := line_start
		for line_end < buf_len && gap_buffer_byte_at(&ed.buffer, line_end) != '\n' {
			line_end += 1
		}

		y := l.text_y + f32(line_idx) * g_line_height - ed.scroll_y
		x_origin := l.text_x - ed.scroll_x

		// Render text first (LCD against BG), then selection overlay on top.
		if line_end > line_start {
			line_len := line_end - line_start
			buf := make([]u8, line_len, context.temp_allocator)
			for k in 0 ..< line_len {
				buf[k] = gap_buffer_byte_at(&ed.buffer, line_start + k)
			}
			expanded := expand_tabs(buf, context.temp_allocator)
			expanded_bytes := transmute([]u8)expanded
			tokens: []Token
			tokens, state = syntax_tokenize(ed.language, expanded_bytes, state)
			draw_tokenized_line(expanded_bytes, tokens, x_origin, y)
		} else {
			// Empty line still has to advance state through tokenize_odin (e.g.,
			// for stays-in-block-comment cases where empty lines exist mid-comment).
			_, state = syntax_tokenize(ed.language, nil, state)
		}

		if has_sel {
			draw_selection_for_line(ed, line_start, line_end, sel_lo, sel_hi, x_origin, y, sel_color)
		}

		if line_end >= buf_len do break
		line_start = line_end + 1
		line_idx += 1
	}

	// Caret.
	cline, ccol := editor_pos_to_line_col(ed, ed.cursor)
	caret_x := l.text_x + f32(ccol) * g_char_width  - ed.scroll_x
	caret_y := l.text_y + f32(cline) * g_line_height - ed.scroll_y

	visible := int(ed.blink_timer * 2) % 2 == 0
	caret_w: f32 = 2
	caret_color := CURSOR_COLOR

	switch ed.mode {
	case .Insert:
		caret_w = 2
	case .Normal:
		caret_w = g_char_width
		caret_color.a = 160
	case .Command, .Search:
		// Caret lives in the status bar in these modes.
		visible = false
	}

	if visible do fill_rect({caret_x, caret_y, caret_w, g_line_height}, caret_color)
}

draw_scrollbars :: proc(ed: ^Editor, l: Layout) {
	fill_rect(l.v_track, SB_TRACK_COLOR)
	fill_rect(l.h_track, SB_TRACK_COLOR)

	content_h := f32(editor_total_lines(ed)) * g_line_height
	content_w := f32(editor_max_line_cols(ed)) * g_char_width

	mx, my: f32
	_ = sdl.GetMouseState(&mx, &my)
	mouse := sdl.FPoint{mx, my}

	if content_h > l.text_h {
		v_start, v_size := scrollbar_thumb_metrics(ed.scroll_y, content_h, l.text_h, l.v_track.h)
		thumb := sdl.FRect{l.v_track.x + 2, l.v_track.y + v_start, l.v_track.w - 4, v_size}
		color := SB_THUMB_COLOR
		if ed.sb_drag == .Vertical || point_in_rect(mouse, thumb) do color = SB_THUMB_HOVER_COLOR
		fill_rect(thumb, color)
	}
	if content_w > l.text_w {
		h_start, h_size := scrollbar_thumb_metrics(ed.scroll_x, content_w, l.text_w, l.h_track.w)
		thumb := sdl.FRect{l.h_track.x + h_start, l.h_track.y + 2, h_size, l.h_track.h - 4}
		color := SB_THUMB_COLOR
		if ed.sb_drag == .Horizontal || point_in_rect(mouse, thumb) do color = SB_THUMB_HOVER_COLOR
		fill_rect(thumb, color)
	}
}

draw_gutter :: proc(ed: ^Editor, l: Layout) {
	fill_rect({0, l.text_y, l.gutter_w, l.text_h}, GUTTER_BG_COLOR)

	first_visible := max(0, int(ed.scroll_y / g_line_height))
	last_visible  := first_visible + int(l.text_h / g_line_height) + 1
	total_lines   := editor_total_lines(ed)
	last_visible = min(last_visible, total_lines - 1)

	cur_line, _ := editor_pos_to_line_col(ed, ed.cursor)

	for line in first_visible ..= last_visible {
		y := l.text_y + f32(line) * g_line_height - ed.scroll_y
		num := fmt.tprintf("%d", line + 1)
		cstr := strings.clone_to_cstring(num, context.temp_allocator)
		w: c.int
		ttf.GetStringSize(g_font, cstr, 0, &w, nil)
		w_logical := f32(w) / g_density
		x := l.gutter_w - GUTTER_PADDING - w_logical
		color := GUTTER_TEXT_COLOR
		if line == cur_line do color = GUTTER_ACTIVE_COLOR
		draw_text(cstr, x, y, color, GUTTER_BG_COLOR)
	}
}

draw_status_bar :: proc(ed: ^Editor, l: Layout) {
	fill_rect({0, l.status_y, l.screen_w, l.status_h}, STATUS_BG_COLOR)
	text_y := l.status_y + STATUS_PAD_Y

	if ed.mode == .Command || ed.mode == .Search {
		prefix := ":"
		if ed.mode == .Search {
			prefix = ed.search_forward ? "/" : "?"
		}
		cmd_str := fmt.tprintf("%s%s", prefix, string(ed.cmd_buffer[:]))
		cstr := strings.clone_to_cstring(cmd_str, context.temp_allocator)
		w := draw_text(cstr, STATUS_PAD_X, text_y, STATUS_TEXT_COLOR, STATUS_BG_COLOR)
		if int(ed.blink_timer * 2) % 2 == 0 {
			fill_rect({STATUS_PAD_X + w, text_y, 2, g_config.font.size}, CURSOR_COLOR)
		}
		return
	}

	mode_label := ed.mode == .Insert ? " INSERT " : " NORMAL "
	path := len(ed.file_path) > 0 ? path_basename(ed.file_path) : "[untitled]"
	dirty := ed.dirty ? " *" : ""
	line, col := editor_pos_to_line_col(ed, ed.cursor)

	left := fmt.tprintf("%s  %s%s", mode_label, path, dirty)
	eol_str := ed.eol_mixed ? fmt.tprintf("MIXED→%s", eol_label(ed.eol)) : eol_label(ed.eol)

	search_part := ""
	if len(ed.search_pattern) > 0 {
		cur, tot := editor_search_stats(ed, ed.search_pattern)
		if cur > 0 do search_part = fmt.tprintf("[%d/%d]   ", cur, tot)
	}
	right := fmt.tprintf("%s%s   %d:%d", search_part, eol_str, line + 1, col + 1)

	left_cstr  := strings.clone_to_cstring(left,  context.temp_allocator)
	right_cstr := strings.clone_to_cstring(right, context.temp_allocator)

	right_w_px: c.int
	ttf.GetStringSize(g_font, right_cstr, 0, &right_w_px, nil)
	right_w := f32(right_w_px) / g_density

	draw_text(left_cstr,  STATUS_PAD_X,                       text_y, STATUS_TEXT_COLOR, STATUS_BG_COLOR)
	draw_text(right_cstr, l.screen_w - STATUS_PAD_X - right_w, text_y, STATUS_DIM_COLOR,  STATUS_BG_COLOR)
}

update_window_title :: proc(ed: ^Editor) {
	@(static) last_path:    string
	@(static) last_dirty:   bool
	@(static) initialized:  bool

	if initialized && last_dirty == ed.dirty && last_path == ed.file_path do return
	initialized = true
	last_path = ed.file_path
	last_dirty = ed.dirty

	name := len(ed.file_path) > 0 ? path_basename(ed.file_path) : "[untitled]"
	dirty_marker := ed.dirty ? "* " : ""
	title := fmt.tprintf("%s%s — Bragi", dirty_marker, name)
	cstr := strings.clone_to_cstring(title, context.temp_allocator)
	sdl.SetWindowTitle(g_window, cstr)
}

// ──────────────────────────────────────────────────────────────────
// Native file dialogs (SDL3). Async — callbacks fire when the user picks a
// file or cancels. Most platforms invoke the callback on the same thread as
// the dialog show call after it returns, but we still set up a context inside
// the C-conv callback for safety.
//
// Triggers (open_file_dialog / save_as_dialog) just set a request flag. The
// main loop calls the actual `Show*` proc after events have been drained.
// Calling Show* directly from inside an event handler (e.g. menu click) is
// flaky on macOS — the OS run loop can swallow the first request.
// ──────────────────────────────────────────────────────────────────

g_pending_open:           bool
g_pending_save_as:        bool
g_pending_raise:          bool // set by dialog callbacks; main loop calls RaiseWindow next iter
g_pending_quit_after_save: bool // try_quit on an untitled buffer: quit once save-as completes

open_file_dialog :: proc(ed: ^Editor) {
	g_pending_open = true
}

save_as_dialog :: proc(ed: ^Editor) {
	g_pending_save_as = true
}

@(private="file")
do_open_file_dialog :: proc(ed: ^Editor) {
	sdl.ShowOpenFileDialog(open_file_callback, rawptr(ed), g_window, nil, 0, nil, false)
}

@(private="file")
do_save_as_dialog :: proc(ed: ^Editor) {
	sdl.ShowSaveFileDialog(save_as_callback, rawptr(ed), g_window, nil, 0, nil)
}

flush_pending_dialogs :: proc(ed: ^Editor) {
	// Process raise FIRST — if a previous dialog just closed we want focus back
	// before any new dialog show resumes the same focus-juggling story.
	if g_pending_raise {
		g_pending_raise = false
		sdl.RaiseWindow(g_window)
		// Re-arm text input in case the dialog turned it off.
		_ = sdl.StartTextInput(g_window)
	}
	// Save-As may be flagged from inside the Save dispatch when there's no
	// path, so process it after Open in case both are pending (unusual).
	if g_pending_open {
		g_pending_open = false
		do_open_file_dialog(ed)
	}
	if g_pending_save_as {
		g_pending_save_as = false
		do_save_as_dialog(ed)
	}
}

open_file_callback :: proc "c" (userdata: rawptr, filelist: [^]cstring, filter: c.int) {
	context = runtime.default_context()
	defer free_all(context.temp_allocator)
	defer { g_pending_raise = true } // restore focus on next main-loop iter // restore focus to editor whether picked or cancelled

	if filelist == nil || filelist[0] == nil do return // cancelled or error

	ed := cast(^Editor)userdata
	path := string(filelist[0])
	if ed.dirty do fmt.eprintln("warning: discarding unsaved changes to load", path)
	if editor_load_file(ed, path) {
		warn_if_mixed_eol(ed)
	} else {
		fmt.eprintfln("could not open %s", path)
	}
}

save_as_callback :: proc "c" (userdata: rawptr, filelist: [^]cstring, filter: c.int) {
	context = runtime.default_context()
	defer free_all(context.temp_allocator)
	defer { g_pending_raise = true } // restore focus on next main-loop iter

	// User cancelled the dialog — abort any pending quit so the editor stays open.
	if filelist == nil || filelist[0] == nil {
		g_pending_quit_after_save = false
		return
	}

	ed := cast(^Editor)userdata
	path := string(filelist[0])

	// Adopt the new path, refresh language detection, then save.
	if len(ed.file_path) > 0 do delete(ed.file_path)
	ed.file_path = strings.clone(path)
	ed.language = language_for_path(path)

	if !editor_save_file(ed) {
		fmt.eprintfln("save failed for %s", path)
		g_pending_quit_after_save = false
		return
	}

	if g_pending_quit_after_save {
		g_pending_quit_after_save = false
		ed.want_quit = true
	}
}

// Loads the embedded FiraCode TTF as an SDL_ttf Font. Wraps the byte slice
// in an SDL_IOStream and asks ttf to take ownership (closeio=true) so the
// stream is freed when the font is closed.
open_embedded_font :: proc(size_px: f32) -> ^ttf.Font {
	io := sdl.IOFromConstMem(rawptr(&FIRA_CODE_DATA[0]), uint(len(FIRA_CODE_DATA)))
	if io == nil do return nil
	return ttf.OpenFontIO(io, true, size_px)
}

// Honours g_config.font.path: empty → embedded; non-empty → load that file
// and fall back to embedded with a warning if it fails. Either way the
// editor always comes up with a usable font.
open_configured_font :: proc(size_px: f32) -> ^ttf.Font {
	if len(g_config.font.path) == 0 do return open_embedded_font(size_px)

	cstr := strings.clone_to_cstring(g_config.font.path, context.temp_allocator)
	if f := ttf.OpenFont(cstr, size_px); f != nil do return f

	fmt.eprintfln(
		"OpenFont '%s' failed (%s); falling back to bundled FiraCode",
		g_config.font.path, sdl.GetError(),
	)
	return open_embedded_font(size_px)
}

Quit_Choice :: enum { Cancel, Save, Discard }

// Modal native dialog: "this buffer has unsaved changes — Save / Discard /
// Cancel?". Returns the user's choice. Anything other than `:q!` (which
// short-circuits this entirely) routes through here when there are dirty
// changes that would be lost.
prompt_unsaved_changes :: proc(ed: ^Editor) -> Quit_Choice {
	name := len(ed.file_path) > 0 ? path_basename(ed.file_path) : "[untitled]"
	msg := fmt.tprintf("'%s' has unsaved changes. Save before closing?", name)
	msg_cstr := strings.clone_to_cstring(msg, context.temp_allocator)

	// SDL renders buttons right-to-left on macOS by default. Order entries
	// so the visual layout reads "Cancel | Discard | Save" with Save as the
	// return-key default and Cancel as the escape default.
	buttons := [3]sdl.MessageBoxButtonData{
		{flags = {.RETURNKEY_DEFAULT}, buttonID = 1, text = "Save"},
		{flags = {},                   buttonID = 2, text = "Discard"},
		{flags = {.ESCAPEKEY_DEFAULT}, buttonID = 0, text = "Cancel"},
	}

	data := sdl.MessageBoxData{
		flags      = {.WARNING},
		window     = g_window,
		title      = "Unsaved changes",
		message    = msg_cstr,
		numbuttons = c.int(len(buttons)),
		buttons    = raw_data(buttons[:]),
	}

	choice: c.int = 0
	if !sdl.ShowMessageBox(data, &choice) do return .Cancel
	switch choice {
	case 1: return .Save
	case 2: return .Discard
	}
	return .Cancel
}

// Quit-with-prompt for the window-close path (Cmd+Q, red traffic light,
// Alt+F4, etc.). Vim ':q' / ':q!' / ':wq' bypass this and live in vim.odin.
try_quit :: proc(ed: ^Editor) -> bool {
	if !ed.dirty do return true
	switch prompt_unsaved_changes(ed) {
	case .Save:
		if len(ed.file_path) == 0 {
			// Untitled — kick off Save As. The dialog callback will set
			// ed.want_quit on success, so we stay running for now.
			g_pending_quit_after_save = true
			save_as_dialog(ed)
			return false
		}
		if editor_save_file(ed) do return true
		fmt.eprintln("save failed; aborting quit")
		return false
	case .Discard:
		return true
	case .Cancel:
		return false
	}
	return false
}

// If the just-loaded file had mixed line endings, surface a native-OS warning
// so the user knows the file will be normalized to the dominant style on save.
warn_if_mixed_eol :: proc(ed: ^Editor) {
	if !ed.eol_mixed do return
	name := len(ed.file_path) > 0 ? path_basename(ed.file_path) : "(file)"
	msg := fmt.tprintf(
		"%s contains a mix of LF and CRLF line endings.\n\nIt will be normalized to %s when you save.",
		name, eol_label(ed.eol),
	)
	cstr := strings.clone_to_cstring(msg, context.temp_allocator)
	sdl.ShowSimpleMessageBox({.WARNING}, "Mixed line endings", cstr, g_window)
}

// One full frame of drawing. Called from the main loop and also synchronously
// from the resize event watch (so the window doesn't show stretched content
// while macOS is in its live-resize event loop).
draw_frame :: proc(ed: ^Editor) {
	l := compute_layout(ed)
	sdl.SetRenderDrawColor(g_renderer, BG_COLOR.r, BG_COLOR.g, BG_COLOR.b, BG_COLOR.a)
	sdl.RenderClear(g_renderer)
	draw_editor(ed, l)
	draw_gutter(ed, l)
	draw_scrollbars(ed, l)
	draw_status_bar(ed, l)
	draw_menu()
	sdl.RenderPresent(g_renderer)
}

// SDL fires this synchronously during macOS live-resize (before the main
// thread regains control of WaitEventTimeout). Redraw inside the callback
// keeps the content rendered at the correct size during the drag.
resize_event_watch :: proc "c" (userdata: rawptr, event: ^sdl.Event) -> bool {
	#partial switch event.type {
	case .WINDOW_PIXEL_SIZE_CHANGED, .WINDOW_RESIZED, .WINDOW_EXPOSED:
		context = runtime.default_context()
		defer free_all(context.temp_allocator)
		ed := cast(^Editor)userdata
		draw_frame(ed)
	}
	return true
}

process_event :: proc(ed: ^Editor, ev: sdl.Event, l: Layout, running: ^bool) {
	#partial switch ev.type {
	case .QUIT:
		if try_quit(ed) do running^ = false
	case .KEY_DOWN:
		handle_key_down(ed, ev.key)
	case .TEXT_INPUT:
		if !cmd_or_ctrl(sdl.GetModState()) do handle_text_input(ed, ev.text.text)
	case .MOUSE_BUTTON_DOWN, .MOUSE_BUTTON_UP:
		handle_mouse_button(ed, ev.button, l)
	case .MOUSE_MOTION:
		handle_mouse_motion(ed, ev.motion, l)
	case .MOUSE_WHEEL:
		handle_mouse_wheel(ed, ev.wheel)
	case .DROP_FILE:
		if ev.drop.data != nil {
			path := string(ev.drop.data)
			if ed.dirty do fmt.eprintln("warning: discarding unsaved changes to load", path)
			if !editor_load_file(ed, path) {
				fmt.eprintfln("failed to load %s", path)
			} else {
				warn_if_mixed_eol(ed)
			}
		}
	}
	if ed.want_quit do running^ = false
}

// ──────────────────────────────────────────────────────────────────
// Main
// ──────────────────────────────────────────────────────────────────

main :: proc() {
	if !sdl.Init({.VIDEO}) {
		fmt.eprintln("SDL_Init:", sdl.GetError())
		return
	}
	defer sdl.Quit()
	if !ttf.Init() {
		fmt.eprintln("TTF_Init:", sdl.GetError())
		return
	}
	defer ttf.Quit()

	// Load user config (overrides DEFAULT_CONFIG fields). After this point,
	// font / theme / tab / column-guide values come from g_config.
	config_load()
	g_theme = g_config.theme

	if !sdl.CreateWindowAndRenderer(WINDOW_TITLE, WINDOW_WIDTH, WINDOW_HEIGHT, {.RESIZABLE, .HIGH_PIXEL_DENSITY}, &g_window, &g_renderer) {
		fmt.eprintln("CreateWindowAndRenderer:", sdl.GetError())
		return
	}
	defer sdl.DestroyRenderer(g_renderer)
	defer sdl.DestroyWindow(g_window)

	g_density = sdl.GetWindowPixelDensity(g_window)
	fmt.printfln("SDL3 pixel density: %v", g_density)
	sdl.SetRenderScale(g_renderer, g_density, g_density)
	sdl.SetRenderDrawBlendMode(g_renderer, sdl.BLENDMODE_BLEND)
	// VSync off: live-resize on macOS lags badly when present blocks for vblank.
	// We rely on WaitEventTimeout(250) to keep idle CPU near zero, and the
	// per-line text cache makes draws cheap, so even uncapped frame rate
	// during active input is fine.
	sdl.SetRenderVSync(g_renderer, 0)

	defer text_cache_clear()

	g_font = open_configured_font(g_config.font.size * g_density)
	if g_font == nil {
		fmt.eprintln("OpenFont (embedded fallback also failed):", sdl.GetError())
		return
	}
	defer ttf.CloseFont(g_font)

	ttf.SetFontHinting(g_font, g_config.font.hinting)

	// Measure char width once. Monospace assumption.
	{
		w: c.int
		ttf.GetStringSize(g_font, "M", 0, &w, nil)
		g_char_width = f32(w) / g_density
	}
	g_line_height = g_config.font.size * g_config.editor.line_spacing

	_ = sdl.StartTextInput(g_window)
	defer { _ = sdl.StopTextInput(g_window) }

	ed := editor_make()
	defer editor_destroy(&ed)
	ed.mode = .Normal

	_ = sdl.AddEventWatch(resize_event_watch, &ed)
	defer sdl.RemoveEventWatch(resize_event_watch, &ed)

	if len(os.args) >= 2 {
		path := os.args[1]
		if !editor_load_file(&ed, path) {
			fmt.eprintfln("could not open %s; starting with welcome text", path)
			editor_set_text(&ed, WELCOME_TEXT)
		} else {
			warn_if_mixed_eol(&ed)
		}
	} else {
		editor_set_text(&ed, WELCOME_TEXT)
	}

	last_ticks := sdl.GetTicksNS()
	running := true
	for running {
		now := sdl.GetTicksNS()
		dt := f32(now - last_ticks) / 1e9
		last_ticks = now
		ed.blink_timer += dt
		if ed.blink_timer > 1 do ed.blink_timer = 0

		l := compute_layout(&ed)
		prev_cursor := ed.cursor

		// Idle-block on events up to 250ms (enough for caret blink to update).
		// When events are flowing, we drain them all and redraw immediately.
		ev: sdl.Event
		if sdl.WaitEventTimeout(&ev, 250) {
			process_event(&ed, ev, l, &running)
			for sdl.PollEvent(&ev) do process_event(&ed, ev, l, &running)
		}

		flush_pending_dialogs(&ed)
		if ed.cursor != prev_cursor do auto_scroll_to_caret(&ed, l)
		clamp_scroll(&ed, l)
		update_window_title(&ed)

		draw_frame(&ed)

		free_all(context.temp_allocator)
	}
}
