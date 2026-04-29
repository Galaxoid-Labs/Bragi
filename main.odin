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

// Fira Code Nerd Font — adds powerline / Devicon / etc. glyphs on top of
// the regular Fira Code outlines. Used for the embedded terminal so
// shells with Nerd-Font-aware prompts (oh-my-zsh, starship, p10k, …)
// render their icons instead of tofu boxes. Identical advance width to
// the regular variant, so terminal cell math doesn't change.
@(rodata)
NERD_FONT_DATA := #load("FiraCodeNerdFont-Regular.ttf")

// FONT_SIZE / FONT_PATH / LINE_SPACING / TAB_SIZE / COLUMN_GUIDE all live in
// g_config and are loaded from INI at startup (see config.odin).
SCROLL_LINES_PER_NOTCH :: 3.0

SB_THICKNESS :: 14.0
SB_MIN_THUMB :: 24.0

// Low-alpha black overlay drawn on every pane that doesn't own keyboard
// focus (editor panes when another pane is active, the terminal when
// the terminal isn't focused). Tuned to be obvious enough to read as
// "this is dimmed" without making the underlying text unreadable.
INACTIVE_DIM :: sdl.Color{0, 0, 0, 50}

GUTTER_PADDING    :: 12.0
GUTTER_MIN_DIGITS :: 3

STATUS_PAD_X :: 8.0
STATUS_PAD_Y :: 5.0

// Syntax + chrome theme. All visible colors live here so they can be
// overridden from the [theme] section of the user's config.ini.
Theme :: struct {
	// Syntax tokens.
	default_color:  sdl.Color,
	keyword_color:  sdl.Color,
	type_color:     sdl.Color,
	constant_color: sdl.Color,
	number_color:   sdl.Color,
	string_color:   sdl.Color,
	comment_color:  sdl.Color,
	function_color: sdl.Color,
	// Chrome.
	bg_color:              sdl.Color,
	cursor_color:          sdl.Color,
	selection_color:       sdl.Color,
	search_match_color:    sdl.Color,
	sb_track_color:        sdl.Color,
	sb_thumb_color:        sdl.Color,
	sb_thumb_hover_color:  sdl.Color,
	gutter_bg_color:       sdl.Color,
	gutter_text_color:     sdl.Color,
	gutter_active_color:   sdl.Color,
	status_bg_color:       sdl.Color,
	status_path_bg_color:  sdl.Color,
	status_text_color:     sdl.Color,
	status_dim_color:      sdl.Color,
	status_error_color:    sdl.Color,
}

DEFAULT_THEME :: Theme{
	default_color  = sdl.Color{220, 220, 220, 255},
	keyword_color  = sdl.Color{198, 120, 221, 255}, // purple
	type_color     = sdl.Color{ 95, 200, 218, 255}, // cyan
	constant_color = sdl.Color{229, 192, 123, 255}, // gold (true/false/nil)
	number_color   = sdl.Color{215, 145,  90, 255}, // orange
	string_color   = sdl.Color{152, 195, 121, 255}, // green
	comment_color  = sdl.Color{ 95, 110, 130, 255}, // muted blue-gray
	function_color = sdl.Color{ 97, 175, 239, 255}, // blue

	bg_color             = sdl.Color{ 30,  30,  38, 255},
	cursor_color         = sdl.Color{240, 200,  80, 255},
	selection_color      = sdl.Color{ 70,  95, 150, 120},
	search_match_color   = sdl.Color{190,  80, 180, 120},
	sb_track_color       = sdl.Color{ 40,  40,  48, 255},
	sb_thumb_color       = sdl.Color{ 90,  90, 100, 255},
	sb_thumb_hover_color = sdl.Color{130, 130, 140, 255},
	gutter_bg_color      = sdl.Color{ 24,  24,  30, 255},
	gutter_text_color    = sdl.Color{ 90,  95, 110, 255},
	gutter_active_color  = sdl.Color{200, 200, 210, 255},
	status_bg_color      = sdl.Color{ 20,  20,  26, 255},
	status_path_bg_color = sdl.Color{ 28,  28,  36, 255},
	status_text_color    = sdl.Color{200, 200, 210, 255},
	status_dim_color     = sdl.Color{120, 125, 140, 255},
	status_error_color   = sdl.Color{220,  90,  90, 255}, // soft red for errors
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

// Lines drawn centered on a fresh / blank-slate pane (see is_welcome_pane).
// `key   description` rows split on any 3+ space run; the key half is drawn
// in the help-screen blue, the description half is dim. Empty strings are
// rendered as gaps for vertical breathing room.
WELCOME_LINES :: [?]string{
	"Bragi",
	"",
	"a small modal editor",
	"",
	"i              start editing",
	"Cmd/Ctrl+F     open file",
	":h             show help",
	":q             quit",
}

@(private="file")
WELCOME_TITLE_COLOR :: sdl.Color{229, 192, 123, 255} // gold accent
@(private="file")
WELCOME_KEY_COLOR   :: sdl.Color{ 97, 175, 239, 255} // help-screen blue

is_welcome_pane :: proc(ed: ^Editor) -> bool {
	return ed.mode == .Normal &&
	       len(g_editors) == 1 &&
	       !ed.dirty &&
	       len(ed.file_path) == 0 &&
	       gap_buffer_len(&ed.buffer) == 0
}

draw_welcome :: proc(ed: ^Editor, p: Pane_Layout) {
	line_h := g_line_height
	total_h := f32(len(WELCOME_LINES)) * line_h
	start_y := p.text_y + (p.text_h - total_h) * 0.5

	// First pass: measure the widest key column and the widest description
	// column across the key/desc rows so they all line up at one offset.
	WELCOME_GAP :: f32(4) // chars of gap between key and description
	max_key_w:  f32 = 0
	max_desc_w: f32 = 0
	for line in WELCOME_LINES {
		if len(line) == 0 do continue
		key, _, has_desc := split_help_line(line)
		if !has_desc do continue
		desc := strings.trim_left(line[len(key):], " ")
		key_w  := f32(len(key))  * g_char_width
		desc_w := f32(len(desc)) * g_char_width
		if key_w  > max_key_w  do max_key_w  = key_w
		if desc_w > max_desc_w do max_desc_w = desc_w
	}
	block_w := max_key_w + WELCOME_GAP * g_char_width + max_desc_w
	block_x := p.text_x + (p.text_w - block_w) * 0.5

	for line, i in WELCOME_LINES {
		if len(line) == 0 do continue
		y := start_y + f32(i) * line_h

		key, _, has_desc := split_help_line(line)
		if has_desc {
			// Aligned column layout. Key flush-left in the block, desc
			// at a fixed x so every row's description starts at the
			// same column.
			desc := strings.trim_left(line[len(key):], " ")
			key_cstr  := strings.clone_to_cstring(key,  context.temp_allocator)
			desc_cstr := strings.clone_to_cstring(desc, context.temp_allocator)
			draw_text(key_cstr,  block_x,                                       y, WELCOME_KEY_COLOR,        g_theme.bg_color)
			draw_text(desc_cstr, block_x + max_key_w + WELCOME_GAP * g_char_width, y, g_theme.status_dim_color, g_theme.bg_color)
		} else {
			// Title / subtitle / prose — measured independently and
			// centered on the pane.
			full_cstr := strings.clone_to_cstring(line, context.temp_allocator)
			full_w_px: c.int
			ttf.GetStringSize(g_font, full_cstr, 0, &full_w_px, nil)
			full_w := f32(full_w_px) / g_density
			x := p.text_x + (p.text_w - full_w) * 0.5
			color := i == 0 ? WELCOME_TITLE_COLOR : g_theme.status_dim_color
			draw_text(full_cstr, x, y, color, g_theme.bg_color)
		}
	}
}

// Globals — easier than threading through every proc. Set in main, read elsewhere.
g_renderer:    ^sdl.Renderer
g_window:      ^sdl.Window
g_font:           ^ttf.Font
g_terminal_font:  ^ttf.Font // Nerd Font variant used by the terminal pane
g_density:        f32   // pixel density (1.0 non-retina, 2.0 retina)
g_char_width:     f32   // logical px per monospace char
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

text_cache_key :: proc(text: string, fg, bg: sdl.Color, font: ^ttf.Font) -> u64 {
	h := fnv64a(transmute([]u8)text)
	fg_u := u64(fg.r) | u64(fg.g)<<8 | u64(fg.b)<<16 | u64(fg.a)<<24
	bg_u := u64(bg.r) | u64(bg.g)<<8 | u64(bg.b)<<16 | u64(bg.a)<<24
	// Mix the font pointer in too — same text + same colors but a
	// different font (regular Fira vs. Nerd) need separate textures.
	return h ~ fg_u ~ (bg_u << 32) ~ (bg_u >> 32) ~ u64(uintptr(font))
}

text_cache_clear :: proc() {
	for _, entry in g_text_cache do sdl.DestroyTexture(entry.tex)
	clear(&g_text_cache)
}

// Per-column layout. With multiple files open the screen is divided into
// equal vertical strips; each strip has its own gutter, scrollbars, and
// text region, and is owned by a single Editor.
Pane_Layout :: struct {
	pane_x, pane_w:  f32, // full column bounds (gutter + text + v_track)
	gutter_w:        f32,
	text_x, text_y:  f32,
	text_w, text_h:  f32,
	v_track, h_track: sdl.FRect,
}

Layout :: struct {
	screen_w, screen_h: f32,
	status_y, status_h: f32,

	// Bottom edge of the editor zone (y of the strip below it). With the
	// terminal hidden this equals status_y; with it visible the status bar
	// sits below the editor and above the terminal divider, so editor_bottom
	// is status_y in both cases — but kept as a separate field so calling
	// code reads as intent ("draw down to the editor zone bottom") rather
	// than coincidentally tracking status_y.
	editor_bottom:      f32,
	panes:              []Pane_Layout,

	// Bottom-of-screen terminal strip. Populated only when
	// g_terminal_visible is true; otherwise terminal_rect is zero-sized.
	// Vertical stack when visible (top → bottom):
	//   editor zone → status bar → terminal_divider → terminal_rect.
	// The 4-px `terminal_divider_y..+h` strip is the grab handle.
	terminal_rect:           sdl.FRect,
	terminal_divider_y:      f32,
	terminal_divider_h:      f32,
}

// Multi-pane editor list. Panes are rendered as columns left-to-right
// in the same order as g_editors. g_active_idx indexes the focused one;
// keyboard input always goes to it, and mouse events that hit a different
// pane move focus there before being handled. g_drag_idx tracks which
// pane the current mouse drag (if any) started in so motion / button-up
// events route back there even if the cursor wandered into a neighbor.
//
// g_pane_ratios stores each pane's width as a fraction of the window
// (sums to 1.0). Ratios scale naturally on window resize and are
// adjusted when the user drags a divider. g_resize_divider is the
// index of the right-side pane whose left edge is being dragged
// (-1 when no drag is in progress).
g_editors:        [dynamic]Editor
g_pane_ratios:    [dynamic]f32
g_active_idx:     int
g_drag_idx:       int = -1
g_resize_divider: int = -1
g_cursor_default:    ^sdl.Cursor
g_cursor_resize_h:   ^sdl.Cursor // ↔  for vertical pane dividers (left/right resize)
g_cursor_resize_v:   ^sdl.Cursor // ↕  for the horizontal terminal divider (up/down resize)

// Vim's Ctrl+W "window" prefix. When set, the next key is interpreted as
// a window command (h / l for focus, c / q for close) instead of going to
// the editor. g_swallow_text_input rides along so the rune that arrived
// for the same physical keypress doesn't get inserted into the buffer.
g_pending_ctrl_w:     bool
g_swallow_text_input: bool

// One-shot message shown in the status bar's bottom row, vim-style. Set
// by file-open errors and similar. Cleared on the next keystroke so it
// behaves like vim's `:` echoes (stays until you do something).
g_status_message:       string
g_status_message_error: bool

set_status_message :: proc(msg: string, is_error: bool = false) {
	if len(g_status_message) > 0 do delete(g_status_message)
	g_status_message       = strings.clone(msg)
	g_status_message_error = is_error
}

clear_status_message :: proc() {
	if len(g_status_message) > 0 {
		delete(g_status_message)
		g_status_message = ""
	}
	g_status_message_error = false
}

DIVIDER_GRAB_PX :: 6.0  // total grab width centered on the divider line
MIN_PANE_PX     :: 80.0 // minimum width a pane can be shrunk to

// Returns the index of the divider near `x` (= the index of the pane to
// the *right* of the divider, in 1..N-1), or -1 if x isn't over a divider.
divider_at_x :: proc(x: f32, l: Layout) -> int {
	half: f32 = DIVIDER_GRAB_PX * 0.5
	for i in 1 ..< len(l.panes) {
		dx := x - l.panes[i].pane_x
		if dx >= -half && dx <= half do return i
	}
	return -1
}

// Drag the divider before pane `right_idx` to logical-pixel x position
// `x`. Adjusts only the two adjacent panes' ratios; clamps so neither
// shrinks below MIN_PANE_PX.
move_divider :: proc(right_idx: int, x: f32, screen_w: f32) {
	if right_idx <= 0 || right_idx >= len(g_pane_ratios) do return
	left_idx := right_idx - 1

	pre_sum: f32 = 0
	for i in 0 ..< left_idx do pre_sum += g_pane_ratios[i]
	post_sum: f32 = 0
	for i in right_idx + 1 ..< len(g_pane_ratios) do post_sum += g_pane_ratios[i]
	available := 1.0 - pre_sum - post_sum

	min_ratio := f32(MIN_PANE_PX) / screen_w
	if min_ratio * 2 > available do min_ratio = available * 0.25

	pos_ratio := clamp(x / screen_w, 0, 1)
	left_ratio := clamp(pos_ratio - pre_sum, min_ratio, available - min_ratio)
	g_pane_ratios[left_idx]  = left_ratio
	g_pane_ratios[right_idx] = available - left_ratio
}

// Append a fresh ratio entry, preserving the existing distribution
// proportionally. After call, ratios sum to 1.0 across `len(g_editors)`.
add_pane_ratio :: proc() {
	n := len(g_editors)
	if n == 1 {
		clear(&g_pane_ratios)
		append(&g_pane_ratios, f32(1))
		return
	}
	new_share := f32(1) / f32(n)
	scale := f32(n - 1) / f32(n)
	for &r in g_pane_ratios do r *= scale
	append(&g_pane_ratios, new_share)
}

// Drop the ratio entry at `idx` and scale the remaining entries up so
// they sum to 1.0 again.
remove_pane_ratio :: proc(idx: int) {
	if idx < 0 || idx >= len(g_pane_ratios) do return
	if len(g_pane_ratios) == 1 {
		g_pane_ratios[0] = 1
		return
	}
	removed := g_pane_ratios[idx]
	ordered_remove(&g_pane_ratios, idx)
	remaining := 1.0 - removed
	if remaining > 0.0001 {
		factor := f32(1) / remaining
		for &r in g_pane_ratios do r *= factor
	} else {
		n := f32(len(g_pane_ratios))
		for &r in g_pane_ratios do r = 1 / n
	}
}

active_editor :: proc() -> ^Editor {
	return &g_editors[g_active_idx]
}

active_pane :: proc(l: Layout) -> Pane_Layout {
	return l.panes[g_active_idx]
}

pane_at_x :: proc(x: f32, l: Layout) -> int {
	for p, i in l.panes {
		if x < p.pane_x + p.pane_w do return i
	}
	return max(0, len(l.panes) - 1)
}

compute_layout :: proc() -> Layout {
	l: Layout
	w, h: c.int
	sdl.GetWindowSize(g_window, &w, &h)
	l.screen_w = f32(w)
	l.screen_h = f32(h)

	// Status bar is two rows tall: top = per-pane file paths, bottom =
	// active-pane mode/position/etc. Three vertical pads (top, between
	// rows, bottom) + two rows of font-size-tall text.
	// Status bar = two rows of font-size-tall text.
	// Vertical pads (top → bottom): 1× above top-row text, 2× below it
	// (so brackets and `%` descenders don't kiss the row boundary), 1×
	// above bottom-row text, 1× below.
	l.status_h = 2 * g_config.font.size + 4 * STATUS_PAD_Y

	// Vertical layout. With the terminal hidden, the status bar pins to
	// the bottom of the window and the editor zone fills everything
	// above it. With the terminal visible the stack from top to bottom
	// is: editor → status bar → 4-px divider → terminal strip. Putting
	// the status bar above the terminal (rather than at the very
	// bottom) keeps it adjacent to the editor it describes — mode /
	// path / cursor info follows the buffer it belongs to.
	if g_terminal_visible {
		// `content_h` is everything except the status bar: editor +
		// divider + terminal share this region. Keeps the
		// terminal_height_ratio meaning stable regardless of where
		// the status bar happens to land.
		content_h := l.screen_h - l.status_h
		divider_h: f32 = 4
		// Clamp so editor + status fit; min editor zone ≈ 100 px.
		t_h := clamp(content_h * g_terminal_height_ratio, 60, content_h - divider_h - 100)
		l.terminal_rect      = sdl.FRect{0, l.screen_h - t_h, l.screen_w, t_h}
		l.terminal_divider_y = l.screen_h - t_h - divider_h
		l.terminal_divider_h = divider_h
		l.status_y           = l.terminal_divider_y - l.status_h
	} else {
		l.status_y = l.screen_h - l.status_h
	}
	l.editor_bottom = l.status_y

	n := max(1, len(g_editors))
	panes := make([]Pane_Layout, n, context.temp_allocator)
	x_acc: f32 = 0
	for i in 0 ..< n {
		ratio := i < len(g_pane_ratios) ? g_pane_ratios[i] : 1.0 / f32(n)
		pane_w := ratio * l.screen_w
		pane_x := x_acc
		x_acc += pane_w
		// Last pane absorbs any rounding remainder so the rightmost
		// edge always lines up with the window.
		if i == n - 1 do pane_w = l.screen_w - pane_x

		ed := &g_editors[i]
		digits := max(GUTTER_MIN_DIGITS, digit_count(editor_total_lines(ed)))
		gutter_w := f32(digits) * g_char_width + GUTTER_PADDING * 2

		text_x := pane_x + gutter_w
		text_y := f32(0)
		text_w := pane_w - gutter_w - SB_THICKNESS
		text_h := l.editor_bottom - SB_THICKNESS - text_y

		panes[i] = Pane_Layout{
			pane_x   = pane_x,
			pane_w   = pane_w,
			gutter_w = gutter_w,
			text_x   = text_x,
			text_y   = text_y,
			text_w   = text_w,
			text_h   = text_h,
			v_track  = sdl.FRect{pane_x + pane_w - SB_THICKNESS, text_y,                  SB_THICKNESS, text_h},
			h_track  = sdl.FRect{text_x,                          l.editor_bottom - SB_THICKNESS, text_w,       SB_THICKNESS},
		}
	}
	l.panes = panes
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
draw_text :: proc(text: cstring, x, y: f32, fg, bg: sdl.Color, font: ^ttf.Font = nil) -> f32 {
	if text == nil || len(string(text)) == 0 do return 0

	f := font
	if f == nil do f = g_font
	if f == nil do return 0

	sx := snap_px(x)
	sy := snap_px(y)

	key := text_cache_key(string(text), fg, bg, f)
	if entry, ok := g_text_cache[key]; ok {
		dst := sdl.FRect{sx, sy, entry.w, entry.h}
		sdl.RenderTexture(g_renderer, entry.tex, nil, &dst)
		return entry.w
	}

	surface := ttf.RenderText_LCD(f, text, 0, fg, bg)
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
mouse_to_buffer_pos :: proc(ed: ^Editor, mx, my: f32, p: Pane_Layout) -> int {
	doc_y := my - p.text_y + ed.scroll_y
	line := max(0, int(doc_y / g_line_height))
	max_line := editor_total_lines(ed) - 1
	line = min(line, max_line)

	doc_x := mx - p.text_x + ed.scroll_x
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
			draw_segment(seg, x, y, default_fg, g_theme.bg_color)
			cur_col += count_display_cols(seg)
			prev_end = tok.start
		}
		seg := bytes[tok.start:tok.end]
		x := x_origin + f32(cur_col) * g_char_width
		draw_segment(seg, x, y, theme_color(&g_theme, tok.kind), g_theme.bg_color)
		cur_col += count_display_cols(seg)
		prev_end = tok.end
	}
	if prev_end < len(bytes) {
		seg := bytes[prev_end:]
		x := x_origin + f32(cur_col) * g_char_width
		draw_segment(seg, x, y, default_fg, g_theme.bg_color)
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
	// Any keystroke dismisses the one-shot status message (file-open
	// errors, etc.). Doesn't run while modals are up — those have their
	// own input loops and shouldn't acknowledge buffer-level messages.
	if !g_finder_visible && !g_help_visible do clear_status_message()

	// Cmd+F (macOS) / Ctrl+F (everywhere else) toggles the directory
	// navigator. Detected before any modal/mode logic so it works
	// from anywhere — even Insert mode.
	if ev.key == sdl.K_F && ev.mod & (sdl.KMOD_GUI | sdl.KMOD_CTRL) != {} {
		if g_finder_visible do finder_hide()
		else                do finder_show()
		return
	}

	// Cmd+J / Ctrl+J — toggle the bottom terminal strip. Mirrors VS
	// Code's "Show / hide terminal" muscle memory.
	if ev.key == sdl.K_J && ev.mod & (sdl.KMOD_GUI | sdl.KMOD_CTRL) != {} {
		// Default size on first open — gets re-fit to the actual rect
		// on the next frame via terminal_fit_to_rect.
		if !terminal_toggle(24, 80) {
			set_status_message("E: failed to open terminal", is_error = true)
		}
		return
	}

	// Finder modal swallows every key while visible.
	if finder_handle_key(ev) do return

	// Help modal eats every key. Esc dismisses; arrows / page keys / j /
	// k / g / G scroll its contents.
	if g_help_visible {
		line_h := g_config.font.size + HELP_LINE_GAP
		switch ev.key {
		case sdl.K_ESCAPE:                   help_hide()
		case sdl.K_UP, sdl.K_K:              help_scroll_by(-line_h)
		case sdl.K_DOWN, sdl.K_J:            help_scroll_by( line_h)
		case sdl.K_PAGEUP:                   help_scroll_by(-line_h * 8)
		case sdl.K_PAGEDOWN, sdl.K_SPACE:    help_scroll_by( line_h * 8)
		case sdl.K_HOME, sdl.K_G:            g_help_scroll = 0
		case sdl.K_END:                      help_scroll_to_end()
		}
		return
	}
	if g_menu.visible && ev.key == sdl.K_ESCAPE {
		menu_hide()
		return
	}

	// Ctrl+W vim window-prefix follow-up: this key is the direction /
	// action, not editor input. Swallow the corresponding TEXT_INPUT so
	// the letter doesn't get typed into the buffer.
	if g_pending_ctrl_w {
		g_pending_ctrl_w     = false
		g_swallow_text_input = true
		switch ev.key {
		case sdl.K_H, sdl.K_LEFT:  if g_active_idx > 0                   do g_active_idx -= 1
		case sdl.K_L, sdl.K_RIGHT: if g_active_idx < len(g_editors) - 1  do g_active_idx += 1
		case sdl.K_C, sdl.K_Q:     try_close_active_pane()
		case sdl.K_ESCAPE:         g_swallow_text_input = false // cancel, no rune queued
		}
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
		case sdl.K_W:
			// Ctrl+W is vim's window-prefix — wait for the follow-up
			// key (h / l for focus, c / q for close). Cmd+W is left
			// alone so macOS's standard close-window behavior fires.
			if mods & sdl.KMOD_CTRL != {} do g_pending_ctrl_w = true
		case sdl.K_D:
			// Ctrl+D — half-page scroll down (vim). Cmd+D is unused
			// here; only fire on Ctrl-only and only in Normal /
			// Visual. Insert mode lets it through to whatever the
			// system would do.
			if mods & sdl.KMOD_CTRL != {} && (ed.mode == .Normal || vim_in_visual(ed)) {
				vim_half_page(ed, +1)
			}
		case sdl.K_U:
			// Ctrl+U — half-page scroll up.
			if mods & sdl.KMOD_CTRL != {} && (ed.mode == .Normal || vim_in_visual(ed)) {
				vim_half_page(ed, -1)
			}
		case sdl.K_LEFTBRACKET:
			// Cmd+[ → focus left pane (single-chord alternative to Ctrl+W h).
			if g_active_idx > 0 do g_active_idx -= 1
		case sdl.K_RIGHTBRACKET:
			// Cmd+] → focus right pane.
			if g_active_idx < len(g_editors) - 1 do g_active_idx += 1
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

	// Terminal has keyboard focus → route non-shortcut keys to it
	// instead of the editor. Cmd / Ctrl chord shortcuts handled above
	// already returned, so app-level actions (Cmd+S, etc.) keep
	// working regardless of which pane has focus.
	if g_terminal_active && g_terminal_visible {
		if handle_terminal_keydown(ev) {
			g_swallow_text_input = false
			return
		}
	}

	// Mode-specific keys
	switch ed.mode {
	case .Insert:
		switch ev.key {
		case sdl.K_ESCAPE:
			dot_observe_esc()
			vim_enter_normal(ed)
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
		case sdl.K_LEFT:   vim_move_left_in_line(ed, false)
		case sdl.K_RIGHT:  vim_move_right_in_line(ed, false)
		case sdl.K_UP:     editor_move_up(ed, false)
		case sdl.K_DOWN:   editor_move_down(ed, false)
		}
	case .Visual, .Visual_Line:
		switch ev.key {
		case sdl.K_ESCAPE: vim_enter_normal(ed)
		case sdl.K_LEFT:   vim_move_left_in_line(ed, true)
		case sdl.K_RIGHT:  vim_move_right_in_line(ed, true)
		case sdl.K_UP:     editor_move_up(ed, true)
		case sdl.K_DOWN:   editor_move_down(ed, true)
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
					// Strip `\c` / `\C` and remember which one (if any)
					// was present so search uses the right case mode.
					cleaned, force := vim_strip_case_modifiers(text)
					if len(ed.search_pattern) > 0 do delete(ed.search_pattern)
					ed.search_pattern    = strings.clone(cleaned)
					ed.search_force_case = force
					editor_find_next(ed, ed.search_pattern, ed.search_forward)
				} else if len(ed.search_pattern) > 0 {
					delete(ed.search_pattern)
					ed.search_pattern    = ""
					ed.search_force_case = 0
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
	if g_help_visible do return
	if g_swallow_text_input {
		g_swallow_text_input = false
		return
	}
	if text == nil do return
	s := string(text)
	if finder_handle_text(s) do return
	if g_terminal_active && g_terminal_visible {
		handle_terminal_text(s)
		return
	}

	switch ed.mode {
	case .Insert:
		for r in s {
			dot_observe_insert(r)
			editor_insert_rune(ed, r)
		}
	case .Normal, .Visual, .Visual_Line:
		// vim_handle_char internally routes Visual modes to their own
		// dispatcher.
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

handle_mouse_button :: proc(ed: ^Editor, ev: sdl.MouseButtonEvent, p: Pane_Layout) {
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

	// Right-click in this pane's text or gutter area opens the context menu.
	if ev.down && ev.button == sdl.BUTTON_RIGHT {
		clickable := sdl.FRect{p.pane_x, p.text_y, p.gutter_w + p.text_w, p.text_h}
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
	v_thumb_start, v_thumb_size := scrollbar_thumb_metrics(ed.scroll_y, content_h, p.text_h, p.v_track.h)
	h_thumb_start, h_thumb_size := scrollbar_thumb_metrics(ed.scroll_x, content_w, p.text_w, p.h_track.w)

	v_thumb_rect := sdl.FRect{p.v_track.x, p.v_track.y + v_thumb_start, p.v_track.w, v_thumb_size}
	h_thumb_rect := sdl.FRect{p.h_track.x + h_thumb_start, p.h_track.y, h_thumb_size, p.h_track.h}

	if content_h > p.text_h && point_in_rect(mouse, v_thumb_rect) {
		ed.sb_drag = .Vertical
		ed.sb_drag_offset = my - v_thumb_rect.y
		return
	}
	if content_w > p.text_w && point_in_rect(mouse, h_thumb_rect) {
		ed.sb_drag = .Horizontal
		ed.sb_drag_offset = mx - h_thumb_rect.x
		return
	}

	// Click on the V track (but not on the thumb): jump the thumb center to
	// the click position and continue as a drag. Same for H.
	if content_h > p.text_h && point_in_rect(mouse, p.v_track) {
		target_thumb_y := my - p.v_track.y - v_thumb_size / 2
		track_room := p.v_track.h - v_thumb_size
		t := track_room > 0 ? clamp(target_thumb_y / track_room, 0, 1) : 0
		ed.scroll_y = t * (content_h - p.text_h)
		ed.sb_drag = .Vertical
		ed.sb_drag_offset = v_thumb_size / 2
		return
	}
	if content_w > p.text_w && point_in_rect(mouse, p.h_track) {
		target_thumb_x := mx - p.h_track.x - h_thumb_size / 2
		track_room := p.h_track.w - h_thumb_size
		t := track_room > 0 ? clamp(target_thumb_x / track_room, 0, 1) : 0
		ed.scroll_x = t * (content_w - p.text_w)
		ed.sb_drag = .Horizontal
		ed.sb_drag_offset = h_thumb_size / 2
		return
	}

	// Gutter clicks are treated like text-area clicks at column 0 — the col
	// math in mouse_to_buffer_pos clamps to 0 when mx < text_x, so dragging
	// in the gutter (or starting in the gutter and dragging into text) just
	// works.
	clickable := sdl.FRect{p.pane_x, p.text_y, p.gutter_w + p.text_w, p.text_h}
	if point_in_rect(mouse, clickable) {
		commit_pending(ed)
		pos := mouse_to_buffer_pos(ed, mx, my, p)
		ed.cursor = pos
		mods := sdl.GetModState()
		if !shift_held(mods) do ed.anchor = pos
		_, ed.desired_col = editor_pos_to_line_col(ed, ed.cursor)
		ed.mouse_drag = true
		ed.blink_timer = 0
	}
}

handle_mouse_motion :: proc(ed: ^Editor, ev: sdl.MouseMotionEvent, p: Pane_Layout) {
	mx, my := ev.x, ev.y
	if g_menu.visible {
		menu_handle_motion(mx, my)
		return
	}
	switch ed.sb_drag {
	case .Vertical:
		content_h := f32(editor_total_lines(ed)) * g_line_height
		_, thumb_h := scrollbar_thumb_metrics(ed.scroll_y, content_h, p.text_h, p.v_track.h)
		new_thumb_y := my - ed.sb_drag_offset - p.v_track.y
		track_room := p.v_track.h - thumb_h
		t := track_room > 0 ? clamp(new_thumb_y / track_room, 0, 1) : 0
		ed.scroll_y = t * (content_h - p.text_h)
	case .Horizontal:
		content_w := f32(editor_max_line_cols(ed)) * g_char_width
		_, thumb_w := scrollbar_thumb_metrics(ed.scroll_x, content_w, p.text_w, p.h_track.w)
		new_thumb_x := mx - ed.sb_drag_offset - p.h_track.x
		track_room := p.h_track.w - thumb_w
		t := track_room > 0 ? clamp(new_thumb_x / track_room, 0, 1) : 0
		ed.scroll_x = t * (content_w - p.text_w)
	case .None:
		if ed.mouse_drag {
			pos := mouse_to_buffer_pos(ed, mx, my, p)
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

clamp_scroll :: proc(ed: ^Editor, p: Pane_Layout) {
	content_h := f32(editor_total_lines(ed)) * g_line_height
	content_w := f32(editor_max_line_cols(ed)) * g_char_width
	max_y := max(0, content_h - p.text_h)
	max_x := max(0, content_w - p.text_w)
	ed.scroll_y = clamp(ed.scroll_y, 0, max_y)
	ed.scroll_x = clamp(ed.scroll_x, 0, max_x)
}

auto_scroll_to_caret :: proc(ed: ^Editor, p: Pane_Layout) {
	cline, ccol := editor_pos_to_line_col(ed, ed.cursor)
	caret_y := f32(cline) * g_line_height
	caret_x := f32(ccol) * g_char_width
	if caret_y < ed.scroll_y                       do ed.scroll_y = caret_y
	else if caret_y + g_line_height > ed.scroll_y + p.text_h do ed.scroll_y = caret_y + g_line_height - p.text_h
	if caret_x < ed.scroll_x                       do ed.scroll_x = caret_x
	else if caret_x + g_char_width  > ed.scroll_x + p.text_w do ed.scroll_x = caret_x + g_char_width  - p.text_w
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

draw_editor :: proc(ed: ^Editor, p: Pane_Layout, is_active: bool) {
	first_visible := max(0, int(ed.scroll_y / g_line_height))
	last_visible  := first_visible + int(p.text_h / g_line_height) + 1
	total_lines   := editor_total_lines(ed)
	last_visible = min(last_visible, total_lines - 1)

	sel_lo, sel_hi := visible_selection_range(ed)
	has_sel := sel_hi > sel_lo

	// Recolor the selection rect when it exactly covers the active search
	// match — same trigger as the [n/m] readout, so the highlight only
	// appears while the user is paging through results.
	sel_color := g_theme.selection_color
	if has_sel && len(ed.search_pattern) > 0 &&
	   sel_hi - sel_lo == len(ed.search_pattern) {
		cur, _ := editor_search_stats(ed, ed.search_pattern)
		if cur > 0 do sel_color = g_theme.search_match_color
	}

	// SetRenderClipRect takes logical (post-SetRenderScale) coords —
	// don't pre-multiply by g_density or the rect doubles on Retina.
	clip := sdl.Rect{i32(p.text_x), i32(p.text_y), i32(p.text_w), i32(p.text_h)}
	sdl.SetRenderClipRect(g_renderer, &clip)
	defer sdl.SetRenderClipRect(g_renderer, nil)

	// Column guide (vertical ruler at the configured column). Drawn before
	// text so glyphs that reach the guide column mask it. Same RGB as comment
	// color but at low alpha so the thin line blends into the BG instead of
	// reading as a saturated stripe.
	if g_config.editor.column_guide > 0 {
		gx := snap_px(p.text_x + f32(g_config.editor.column_guide) * g_char_width - ed.scroll_x)
		if gx >= p.text_x && gx < p.text_x + p.text_w {
			gw := 1.0 / g_density // 1 physical pixel
			c := g_theme.comment_color
			c.a = 60
			fill_rect({gx, p.text_y, gw, p.text_h}, c)
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

		y := p.text_y + f32(line_idx) * g_line_height - ed.scroll_y
		x_origin := p.text_x - ed.scroll_x

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

	// Search-match highlights: draw a faint rect over every visible match
	// of ed.search_pattern. The active match (cursor sitting on one) is
	// already drawn by the selection rect above in `search_match_color`,
	// so we skip it here to avoid double-painting.
	if len(ed.search_pattern) > 0 && len(ed.search_match_positions) > 0 {
		needle_len := len(ed.search_pattern)
		faint := g_theme.search_match_color
		faint.a /= 2
		active_pos := -1
		if has_sel && sel_hi - sel_lo == needle_len {
			cur, _ := editor_search_stats(ed, ed.search_pattern)
			if cur > 0 do active_pos = sel_lo
		}
		for pos in ed.search_match_positions {
			line, col := editor_pos_to_line_col(ed, pos)
			if line < first_visible do continue
			if line > last_visible do break // positions are sorted ascending
			if pos == active_pos do continue

			x := p.text_x + f32(col) * g_char_width  - ed.scroll_x
			y := p.text_y + f32(line) * g_line_height - ed.scroll_y
			w := f32(needle_len) * g_char_width
			fill_rect({x, y, w, g_line_height}, faint)
		}
	}

	// Caret. Inactive panes show a hollow outline of the active position
	// (where the cursor *would* go if focus moved here); the active pane
	// blinks normally.
	cline, ccol := editor_pos_to_line_col(ed, ed.cursor)
	caret_x := p.text_x + f32(ccol) * g_char_width  - ed.scroll_x
	caret_y := p.text_y + f32(cline) * g_line_height - ed.scroll_y

	if !is_active {
		c := g_theme.cursor_color
		c.a = 60
		fill_rect({caret_x, caret_y, g_char_width, g_line_height}, c)
		return
	}

	visible := int(ed.blink_timer * 2) % 2 == 0
	caret_w: f32 = 2
	caret_color := g_theme.cursor_color

	switch ed.mode {
	case .Insert:
		caret_w = 2
	case .Normal, .Visual, .Visual_Line:
		caret_w = g_char_width
		caret_color.a = 160
	case .Command, .Search:
		// Caret lives in the status bar in these modes.
		visible = false
	}

	if is_welcome_pane(ed) {
		// Suppress the caret on the welcome screen — there's nothing to
		// edit yet, and a stray block at (0, 0) under the title looks weird.
		visible = false
	}

	if visible do fill_rect({caret_x, caret_y, caret_w, g_line_height}, caret_color)

	if is_welcome_pane(ed) do draw_welcome(ed, p)
}

draw_scrollbars :: proc(ed: ^Editor, p: Pane_Layout) {
	fill_rect(p.v_track, g_theme.sb_track_color)
	fill_rect(p.h_track, g_theme.sb_track_color)

	content_h := f32(editor_total_lines(ed)) * g_line_height
	content_w := f32(editor_max_line_cols(ed)) * g_char_width

	mx, my: f32
	_ = sdl.GetMouseState(&mx, &my)
	mouse := sdl.FPoint{mx, my}

	if content_h > p.text_h {
		v_start, v_size := scrollbar_thumb_metrics(ed.scroll_y, content_h, p.text_h, p.v_track.h)
		thumb := sdl.FRect{p.v_track.x + 2, p.v_track.y + v_start, p.v_track.w - 4, v_size}
		color := g_theme.sb_thumb_color
		if ed.sb_drag == .Vertical || point_in_rect(mouse, thumb) do color = g_theme.sb_thumb_hover_color
		fill_rect(thumb, color)
	}
	if content_w > p.text_w {
		h_start, h_size := scrollbar_thumb_metrics(ed.scroll_x, content_w, p.text_w, p.h_track.w)
		thumb := sdl.FRect{p.h_track.x + h_start, p.h_track.y + 2, h_size, p.h_track.h - 4}
		color := g_theme.sb_thumb_color
		if ed.sb_drag == .Horizontal || point_in_rect(mouse, thumb) do color = g_theme.sb_thumb_hover_color
		fill_rect(thumb, color)
	}
}

draw_gutter :: proc(ed: ^Editor, p: Pane_Layout) {
	// Fill the full gutter column, not just the text rect — the strip
	// below the text area (alongside the horizontal scrollbar track)
	// needs the gutter bg too, otherwise line numbers that scroll
	// into that strip render their own bg as a dark patch on top of
	// the editor bg.
	gutter_h := p.h_track.y + p.h_track.h - p.text_y
	fill_rect({p.pane_x, p.text_y, p.gutter_w, gutter_h}, g_theme.gutter_bg_color)

	first_visible := max(0, int(ed.scroll_y / g_line_height))
	last_visible  := first_visible + int(p.text_h / g_line_height) + 1
	total_lines   := editor_total_lines(ed)
	last_visible = min(last_visible, total_lines - 1)

	cur_line, _ := editor_pos_to_line_col(ed, ed.cursor)

	for line in first_visible ..= last_visible {
		y := p.text_y + f32(line) * g_line_height - ed.scroll_y
		num := fmt.tprintf("%d", line + 1)
		cstr := strings.clone_to_cstring(num, context.temp_allocator)
		w: c.int
		ttf.GetStringSize(g_font, cstr, 0, &w, nil)
		w_logical := f32(w) / g_density
		x := p.pane_x + p.gutter_w - GUTTER_PADDING - w_logical
		color := g_theme.gutter_text_color
		if line == cur_line do color = g_theme.gutter_active_color
		draw_text(cstr, x, y, color, g_theme.gutter_bg_color)
	}
}

// vim-style scroll indicator for a pane: "Top" when the first line is
// in view, "Bot" when the last line is in view, "nn%" otherwise (cursor
// line as a percentage of the total). Returns "" when the buffer
// already fits in the pane and there's no scrolling to indicate.
@(private="file")
pane_scroll_indicator :: proc(ed: ^Editor, p: Pane_Layout) -> string {
	total := editor_total_lines(ed)
	if total <= 0 do return ""
	visible := int(p.text_h / g_line_height)
	if total <= visible do return ""

	if ed.scroll_y <= 0 do return "Top"
	content_h := f32(total) * g_line_height
	if ed.scroll_y + p.text_h >= content_h do return "Bot"

	cur_line, _ := editor_pos_to_line_col(ed, ed.cursor)
	pct := cur_line * 100 / max(1, total - 1)
	return fmt.tprintf("%d%%", pct)
}

draw_status_bar :: proc(ed: ^Editor, l: Layout) {
	row_h := g_config.font.size + STATUS_PAD_Y * 2
	// Top row (paths) gets a subtly lighter background so the eye can
	// separate "which file is in which pane" from the global status.
	fill_rect({0, l.status_y,         l.screen_w, row_h},               g_theme.status_path_bg_color)
	fill_rect({0, l.status_y + row_h, l.screen_w, l.status_h - row_h},  g_theme.status_bg_color)
	top_y := l.status_y + STATUS_PAD_Y
	bot_y := l.status_y + 3 * STATUS_PAD_Y + g_config.font.size

	// Top row: per-pane file strips. Filename on the left (basename
	// only — the full path is already visible in the OS title bar /
	// Cmd+O dialog and would overflow narrow panes), vim-style scroll
	// indicator (Top / Bot / nn%) right-aligned. Each pane's segment
	// is clipped to its own column so neither half bleeds into the
	// neighbor. Active pane gets the bright text color.
	for p, i in l.panes {
		e := &g_editors[i]
		name  := len(e.file_path) > 0 ? path_basename(e.file_path) : "[untitled]"
		dirty := e.dirty ? " *" : ""
		left_text := fmt.tprintf("%s%s", name, dirty)
		left_cstr := strings.clone_to_cstring(left_text, context.temp_allocator)
		color := i == g_active_idx ? g_theme.status_text_color : g_theme.status_dim_color

		// Clip to the full row height (not just `font.size`) so glyph
		// descenders and characters like `%` aren't shaved off at the
		// bottom by a too-tight clip rect.
		clip := sdl.Rect{
			i32(p.pane_x),
			i32(l.status_y),
			i32(p.pane_w),
			i32(row_h),
		}
		sdl.SetRenderClipRect(g_renderer, &clip)
		draw_text(left_cstr, p.pane_x + STATUS_PAD_X, top_y, color, g_theme.status_path_bg_color)

		// Right-aligned scroll indicator. Empty when the buffer fits
		// in the pane (no scrolling needed).
		if right_text := pane_scroll_indicator(e, p); len(right_text) > 0 {
			right_cstr := strings.clone_to_cstring(right_text, context.temp_allocator)
			right_w_px: c.int
			ttf.GetStringSize(g_font, right_cstr, 0, &right_w_px, nil)
			right_w := f32(right_w_px) / g_density
			draw_text(right_cstr,
			          p.pane_x + p.pane_w - STATUS_PAD_X - right_w,
			          top_y,
			          color,
			          g_theme.status_path_bg_color)
		}
	}
	// Thin separators between path segments to mirror the editor-area
	// dividers above.
	sdl.SetRenderClipRect(g_renderer, nil)
	for i in 1 ..< len(l.panes) {
		x := l.panes[i].pane_x
		fill_rect({x, top_y - STATUS_PAD_Y * 0.5, 1.0 / g_density, g_config.font.size + STATUS_PAD_Y}, g_theme.gutter_bg_color)
	}

	// Transient status message (file-open errors, "binary file", etc.)
	// pre-empts the bottom row in Normal mode. Cleared by the next
	// keystroke. Doesn't override Command / Search prompts.
	if len(g_status_message) > 0 && ed.mode != .Command && ed.mode != .Search {
		color := g_status_message_error ? g_theme.status_error_color : g_theme.status_text_color
		cstr  := strings.clone_to_cstring(g_status_message, context.temp_allocator)
		draw_text(cstr, STATUS_PAD_X, bot_y, color, g_theme.status_bg_color)
		return
	}

	// Bottom row: mode + position + search counter, all for the active pane.
	// In Command / Search modes, the bottom row hosts the input prompt instead.
	if ed.mode == .Command || ed.mode == .Search {
		prefix := ":"
		if ed.mode == .Search do prefix = ed.search_forward ? "/" : "?"
		cmd_str := fmt.tprintf("%s%s", prefix, string(ed.cmd_buffer[:]))
		cstr := strings.clone_to_cstring(cmd_str, context.temp_allocator)
		w := draw_text(cstr, STATUS_PAD_X, bot_y, g_theme.status_text_color, g_theme.status_bg_color)
		if int(ed.blink_timer * 2) % 2 == 0 {
			fill_rect({STATUS_PAD_X + w, bot_y, 2, g_config.font.size}, g_theme.cursor_color)
		}
		return
	}

	mode_label: string
	switch ed.mode {
	case .Insert:       mode_label = " INSERT "
	case .Visual:       mode_label = " VISUAL "
	case .Visual_Line:  mode_label = " V-LINE "
	case .Normal, .Command, .Search:
		mode_label = " NORMAL "
	}
	line, col := editor_pos_to_line_col(ed, ed.cursor)
	eol_str := ed.eol_mixed ? fmt.tprintf("MIXED→%s", eol_label(ed.eol)) : eol_label(ed.eol)

	search_part := ""
	if len(ed.search_pattern) > 0 {
		cur, tot := editor_search_stats(ed, ed.search_pattern)
		if cur > 0 do search_part = fmt.tprintf("[%d/%d]   ", cur, tot)
	}
	// Active language label, omitted for plain text.
	lang_part := ""
	if ed.language != .None {
		lang_part = fmt.tprintf("{{}} %s   ", language_display_name(ed.language))
	}
	right := fmt.tprintf("%s%s%s   %d:%d", search_part, lang_part, eol_str, line + 1, col + 1)

	left_cstr  := strings.clone_to_cstring(mode_label, context.temp_allocator)
	right_cstr := strings.clone_to_cstring(right, context.temp_allocator)

	right_w_px: c.int
	ttf.GetStringSize(g_font, right_cstr, 0, &right_w_px, nil)
	right_w := f32(right_w_px) / g_density

	draw_text(left_cstr,  STATUS_PAD_X,                        bot_y, g_theme.status_text_color, g_theme.status_bg_color)
	draw_text(right_cstr, l.screen_w - STATUS_PAD_X - right_w, bot_y, g_theme.status_dim_color,  g_theme.status_bg_color)
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
	defer { g_pending_raise = true } // restore focus on next main-loop iter

	if filelist == nil || filelist[0] == nil do return // canceled or error

	path := string(filelist[0])
	open_file_smart(path)
}

save_as_callback :: proc "c" (userdata: rawptr, filelist: [^]cstring, filter: c.int) {
	context = runtime.default_context()
	defer free_all(context.temp_allocator)
	defer { g_pending_raise = true } // restore focus on next main-loop iter

	// User canceled the dialog — abort any pending quit so the editor stays open.
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

// Per-character advance for a monospace font in *logical* pixels.
//
// Asking SDL_ttf for the bounding box of "M" (or any rendered string)
// gives back the rasterised pixel extent — that includes side bearings
// and rounding to whole physical pixels, neither of which is the value
// the renderer actually steps by between glyphs. At small sizes the
// difference is enough to drift the cursor a full cell off the
// characters beneath it.
//
// What we actually want is the font's *advance* metric — that's the
// horizontal step between glyph origins, in font-design units rounded
// to the rasterised grid, which is exactly what TTF_RenderText_LCD
// uses to lay out subsequent glyphs. Pull it via GetGlyphMetrics.
// Falls back to the GetStringSize approach if the font doesn't have
// metrics for "M" (shouldn't happen with Fira Code).
measure_char_width :: proc(font: ^ttf.Font) -> f32 {
	if font == nil || g_density <= 0 do return 0

	advance: c.int
	if ttf.GetGlyphMetrics(font, 'M', nil, nil, nil, nil, &advance) && advance > 0 {
		return f32(advance) / g_density
	}

	// Fallback: a single-glyph string measurement. Less accurate at
	// small sizes (as above) but better than nothing.
	w: c.int
	if !ttf.GetStringSize(font, "M", 0, &w, nil) || w <= 0 do return 0
	return f32(w) / g_density
}

// Same idea, but loads the Nerd Font variant used by the terminal pane.
open_terminal_font :: proc(size_px: f32) -> ^ttf.Font {
	io := sdl.IOFromConstMem(rawptr(&NERD_FONT_DATA[0]), uint(len(NERD_FONT_DATA)))
	if io == nil do return nil
	f := ttf.OpenFontIO(io, true, size_px)
	if f != nil do ttf.SetFontHinting(f, g_config.font.hinting)
	return f
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

// Window-close path with multiple panes: prompt for each dirty pane in turn.
// If any prompt is canceled (or save fails), abort the quit and leave
// every pane intact.
try_quit_all :: proc() -> bool {
	for &e in g_editors {
		if !try_quit(&e) do return false
	}
	return true
}

// Pane lifecycle. Splits stay equal-column; opening a file appends a new
// pane to the right and focuses it, closing one removes the column.

// Append a fresh empty pane and make it active.
open_new_pane :: proc() {
	append(&g_editors, editor_make())
	add_pane_ratio()
	g_active_idx = len(g_editors) - 1
	active_editor().mode = .Normal
}

// Open `path` in a brand-new pane (focused). Returns false if the load
// fails — in that case we drop the empty pane we just added so we don't
// leave a stray column behind. editor_load_file already populates the
// status bar on failure.
open_file_in_new_pane :: proc(path: string) -> bool {
	open_new_pane()
	if !editor_load_file(active_editor(), path) {
		close_active_pane_unconditional()
		return false
	}
	warn_if_mixed_eol(active_editor())
	return true
}

// True when the active pane is a "blank slate" — single pane, no file,
// no user edits. The startup welcome buffer qualifies, as do panes that
// were just reset after closing the last file. Used to decide whether
// the next file open should replace the current pane or split alongside.
should_replace_active :: proc() -> bool {
	return len(g_editors) == 1 &&
	       !active_editor().dirty &&
	       len(active_editor().file_path) == 0
}

// Open the user's config.ini for editing. If the file already exists,
// goes through the normal open-file path. If it doesn't, seeds a buffer
// with the default-config template and points its file_path at the
// per-platform config location — saving from this buffer just writes
// the file into existence at the right spot. The buffer starts non-
// dirty so navigating away without edits doesn't prompt.
bragi_open_config :: proc() {
	path := config_path(context.allocator)
	if len(path) == 0 {
		set_status_message("E: could not resolve config path", is_error = true)
		return
	}
	if os.exists(path) {
		open_file_smart(path)
		return
	}
	// Pick a pane: replace the active blank pane in place, else split.
	if !should_replace_active() do open_new_pane()
	ed := active_editor()
	editor_clear(ed)
	editor_set_text(ed, DEFAULT_CONFIG_INI)
	if len(ed.file_path) > 0 do delete(ed.file_path)
	ed.file_path = strings.clone(path)
	ed.language  = .Ini
	ed.dirty     = false           // Untouched template — closing without edits should be silent.
	ed.cursor    = 0
	ed.scroll_x  = 0
	ed.scroll_y  = 0
	set_status_message(fmt.tprintf("config does not exist — save this buffer to create %s", path))
}

// Unified file-open entry point: replaces the welcome/blank pane in
// place, otherwise opens the file in a new column.
open_file_smart :: proc(path: string) {
	if should_replace_active() {
		ed := active_editor()
		// editor_load_file populates the status bar on failure.
		if editor_load_file(ed, path) do warn_if_mixed_eol(ed)
		return
	}
	open_file_in_new_pane(path)
}

// Drop the active pane unconditionally. The last pane is replaced with a
// fresh welcome buffer rather than removed, so the editor never has zero
// panes — pressing Cmd/Ctrl+W on a file goes back to the welcome screen,
// then a second Cmd/Ctrl+W (handled higher up via `should_replace_active`)
// quits.
close_active_pane_unconditional :: proc() {
	idx := g_active_idx
	if len(g_editors) == 1 {
		editor_destroy(&g_editors[0])
		g_editors[0] = editor_make()
		g_editors[0].mode = .Normal
		// Empty buffer + clean + untitled triggers the centered welcome
		// overlay; no inline text needed.
		return
	}
	editor_destroy(&g_editors[idx])
	ordered_remove(&g_editors, idx)
	remove_pane_ratio(idx)
	if g_active_idx >= len(g_editors) do g_active_idx = len(g_editors) - 1
}

// Cmd+W / Ctrl+W path: prompt-then-close. Returns true if the pane was
// closed (or replaced with welcome). On a single welcome pane we set
// `want_quit` instead so the main loop exits — pressing close from
// welcome means "actually quit the app".
try_close_active_pane :: proc() -> bool {
	ed := active_editor()
	if len(g_editors) == 1 && should_replace_active() {
		ed.want_quit = true
		return false
	}
	if !ed.dirty {
		close_active_pane_unconditional()
		return true
	}
	switch prompt_unsaved_changes(ed) {
	case .Save:
		if len(ed.file_path) == 0 {
			// Untitled — kick off Save As; we *don't* close yet (the
			// dialog is async). For simplicity the close-after-save
			// flow is left out for now: the user can save, then close.
			save_as_dialog(ed)
			return false
		}
		if !editor_save_file(ed) {
			fmt.eprintln("save failed; pane stays open")
			return false
		}
		close_active_pane_unconditional()
		return true
	case .Discard:
		close_active_pane_unconditional()
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
draw_frame :: proc() {
	l := compute_layout()
	sdl.SetRenderDrawColor(g_renderer, g_theme.bg_color.r, g_theme.bg_color.g, g_theme.bg_color.b, g_theme.bg_color.a)
	sdl.RenderClear(g_renderer)
	for i in 0 ..< len(l.panes) {
		ed := &g_editors[i]
		p  := l.panes[i]
		is_active := i == g_active_idx
		draw_editor(ed, p, is_active)
		draw_gutter(ed, p)
		draw_scrollbars(ed, p)
	}
	// Dim non-focused panes with a low-alpha black overlay so the
	// focused pane reads as the focused one. When the terminal owns
	// keyboard focus, every editor pane is inactive — drop the active
	// editor's bright treatment too. The terminal itself gets the
	// same overlay below, after it draws. Drawn before separators so
	// the dividers stay crisp.
	editor_focused := !(g_terminal_visible && g_terminal_active)
	for p, i in l.panes {
		if editor_focused && i == g_active_idx do continue
		fill_rect({p.pane_x, 0, p.pane_w, l.editor_bottom}, INACTIVE_DIM)
	}
	// Thin vertical separator between panes so the column boundary reads
	// even when the two adjacent files share a similar look.
	for i in 1 ..< len(l.panes) {
		x := l.panes[i].pane_x
		fill_rect({x, 0, 1.0 / g_density, l.editor_bottom}, g_theme.gutter_bg_color)
	}
	// Terminal pane (bottom strip) — drawn before status / modals so
	// they overlay it cleanly. The thin divider above it doubles as
	// the resize-grab strip.
	if g_terminal_visible {
		// Re-fit the cell grid to whatever the layout gave us this
		// frame (covers window resize + divider drag in one place).
		terminal_fit_to_rect(l.terminal_rect)
		fill_rect({0, l.terminal_divider_y, l.screen_w, l.terminal_divider_h}, g_theme.gutter_bg_color)
		draw_terminal(l.terminal_rect)
		// Match the editor-pane treatment: dim the terminal when it
		// doesn't own keyboard focus.
		if !g_terminal_active do fill_rect(l.terminal_rect, INACTIVE_DIM)
	}

	draw_status_bar(active_editor(), l)
	draw_menu()
	draw_help(l)
	draw_finder(l)
	sdl.RenderPresent(g_renderer)
}

// Re-query `g_density` from the window (it changes when the window moves
// between displays — e.g. external 1.0 → built-in retina 2.0) and rebuild
// every density-dependent piece of state. Without this, clip rects, text
// rasterisation, and the 1-physical-pixel separators all stay at the
// startup density and the layout visibly tears (text bleeds past pane
// borders, glyphs look fuzzy, etc.).
refresh_pixel_density :: proc() {
	new_density := sdl.GetWindowPixelDensity(g_window)
	if new_density <= 0 do return
	if new_density == g_density do return

	g_density = new_density
	sdl.SetRenderScale(g_renderer, g_density, g_density)

	// Re-rasterise both fonts at the new physical size and drop cached
	// textures (they're sized at the previous density).
	if g_font != nil do ttf.CloseFont(g_font)
	g_font = open_configured_font(g_config.font.size * g_density)
	if g_font != nil do ttf.SetFontHinting(g_font, g_config.font.hinting)

	if g_terminal_font != nil do ttf.CloseFont(g_terminal_font)
	g_terminal_font = open_terminal_font(g_config.font.size * g_density)

	text_cache_clear()

	g_char_width = measure_char_width(g_font)
}

// SDL fires this synchronously during macOS live-resize (before the main
// thread regains control of WaitEventTimeout). Redraw inside the callback
// keeps the content rendered at the correct size during the drag. The
// display-change events also flow through here so the pixel-density
// refresh fires before the next frame draws.
resize_event_watch :: proc "c" (userdata: rawptr, event: ^sdl.Event) -> bool {
	#partial switch event.type {
	case .WINDOW_PIXEL_SIZE_CHANGED, .WINDOW_DISPLAY_CHANGED, .WINDOW_DISPLAY_SCALE_CHANGED:
		context = runtime.default_context()
		defer free_all(context.temp_allocator)
		refresh_pixel_density()
		draw_frame()
	case .WINDOW_RESIZED, .WINDOW_EXPOSED:
		context = runtime.default_context()
		defer free_all(context.temp_allocator)
		draw_frame()
	}
	return true
}

process_event :: proc(ev: sdl.Event, l: Layout, running: ^bool) {
	#partial switch ev.type {
	case .USER:
		// Reader thread tagged this with TERMINAL_EVENT when new PTY
		// bytes arrived OR when the child shell exited. Pump any
		// pending bytes (so the final output is on screen), drain
		// libvterm's outbound queue, then auto-close the pane if the
		// shell exited — typing `exit<Enter>` should retire the
		// terminal pane the same way Cmd+W retires an editor pane.
		if ev.user.code == TERMINAL_EVENT {
			terminal_pump()
			terminal_flush_output()
			if g_terminal != nil && g_terminal.exited do terminal_close()
		}
		return
	case .QUIT:
		if try_quit_all() do running^ = false
	case .WINDOW_CLOSE_REQUESTED:
		// macOS Cmd+W (and the red traffic light) come through here.
		// With multiple panes open, treat it as "close the active pane".
		// With a single pane, route through `try_close_active_pane`
		// which: on a file → resets to welcome; already on welcome →
		// sets want_quit and the loop exits.
		try_close_active_pane()
	case .KEY_DOWN:
		handle_key_down(active_editor(), ev.key)
	case .TEXT_INPUT:
		if !cmd_or_ctrl(sdl.GetModState()) do handle_text_input(active_editor(), ev.text.text)
	case .MOUSE_BUTTON_DOWN:
		// Finder modal swallows clicks; outside-click dismisses,
		// inside-click selects (and double-click activates).
		if finder_handle_button(ev.button, l) do return
		// Help modal swallows clicks; clicking outside dismisses it.
		if help_handle_click(ev.button.x, ev.button.y, l) do return
		// Terminal-divider drag (horizontal). Has to win over the
		// editor pane area below it, but only when the terminal is
		// showing and the click is in the divider strip.
		if g_terminal_visible &&
		   ev.button.y >= l.terminal_divider_y &&
		   ev.button.y <  l.terminal_divider_y + l.terminal_divider_h {
			g_terminal_resizing = true
			return
		}
		// Click inside the terminal rect → focus the terminal. The
		// scrollbar strip is part of that rect, so check it first; a
		// thumb-grab steals the click instead of stealing focus.
		if g_terminal_visible && point_in_rect({ev.button.x, ev.button.y}, l.terminal_rect) {
			pt := sdl.FPoint{ev.button.x, ev.button.y}
			if ev.button.button == sdl.BUTTON_LEFT && ev.button.down &&
			   terminal_handle_sb_button_down(l.terminal_rect, pt) {
				return
			}
			g_terminal_active = true
			return
		}
		// Anything else lands in editor territory; if a terminal had
		// focus, it's losing it now.
		g_terminal_active = false
		// Divider grab takes priority over pane interior — the grab
		// strip overlaps the rightmost few pixels of one pane's
		// scrollbar and the leftmost few pixels of the next pane's
		// gutter, but resize wins.
		if div := divider_at_x(ev.button.x, l); div > 0 {
			g_resize_divider = div
			return
		}
		idx := pane_at_x(ev.button.x, l)
		g_active_idx = idx
		g_drag_idx   = idx
		handle_mouse_button(&g_editors[idx], ev.button, l.panes[idx])
	case .MOUSE_BUTTON_UP:
		// Finder swallows the up so it doesn't fall through to a pane.
		if g_finder_visible do return
		if g_terminal_resizing {
			g_terminal_resizing = false
			return
		}
		// Releasing while dragging the terminal scrollbar ends the drag —
		// even if the cursor wandered out of the terminal rect.
		if terminal_sb_dragging() {
			terminal_handle_sb_button_up()
			return
		}
		if g_resize_divider > 0 {
			g_resize_divider = -1
			return
		}
		// Clamp against `l.panes`, NOT `g_editors`. A native-dialog
		// callback (Cmd+O) can grow g_editors synchronously from inside
		// SDL's event pump, so the layout we computed at the top of
		// this iteration is stale until the next one. `l.panes[target]`
		// must always be in bounds for the layout we're using.
		target := g_drag_idx >= 0 && g_drag_idx < len(l.panes) ? g_drag_idx : pane_at_x(ev.button.x, l)
		if target >= 0 && target < len(l.panes) {
			handle_mouse_button(&g_editors[target], ev.button, l.panes[target])
		}
		g_drag_idx = -1
	case .MOUSE_MOTION:
		// In-flight scrollbar drag wins over everything else; route the
		// motion straight to the terminal so the thumb tracks the mouse
		// even if it wanders out of the strip.
		if terminal_sb_dragging() {
			terminal_handle_sb_drag(l.terminal_rect, ev.motion.y)
			return
		}
		if g_terminal_resizing {
			// Convert mouse-y → desired terminal height, then store
			// as a fraction of the editor+terminal zone (content_h)
			// so the ratio survives window resizes. The status bar
			// sits between the editor and the divider, so the
			// divider top is `screen_h - t_h - divider_h`.
			content_h := l.screen_h - l.status_h
			if content_h > 0 {
				new_t_h := l.screen_h - ev.motion.y - l.terminal_divider_h
				g_terminal_height_ratio = clamp(new_t_h / content_h, 0.05, 0.9)
			}
			return
		}
		if g_resize_divider > 0 {
			move_divider(g_resize_divider, ev.motion.x, l.screen_w)
			return
		}
		// Swap to the appropriate resize cursor while hovering any
		// divider; default otherwise. Vertical dividers (between
		// horizontal panes) use ↔ ; the horizontal divider above the
		// terminal uses ↕ . SetCursor is cheap and SDL no-ops when
		// the cursor doesn't actually change.
		over_pane_div := divider_at_x(ev.motion.x, l) > 0
		over_term_div := g_terminal_visible &&
		                 ev.motion.y >= l.terminal_divider_y &&
		                 ev.motion.y <  l.terminal_divider_y + l.terminal_divider_h
		switch {
		case over_pane_div && g_cursor_resize_h != nil:
			_ = sdl.SetCursor(g_cursor_resize_h)
		case over_term_div && g_cursor_resize_v != nil:
			_ = sdl.SetCursor(g_cursor_resize_v)
		case g_cursor_default != nil:
			_ = sdl.SetCursor(g_cursor_default)
		}
		// See MOUSE_BUTTON_UP above: clamp against `l.panes`. If a
		// dialog callback grew g_editors mid-drain we'd otherwise
		// land on a pane index the current layout doesn't have.
		target := g_drag_idx
		if target < 0 || target >= len(l.panes) do target = g_active_idx
		if target < 0 || target >= len(l.panes) do return
		handle_mouse_motion(&g_editors[target], ev.motion, l.panes[target])
	case .MOUSE_WHEEL:
		if finder_handle_wheel(ev.wheel) do return
		if g_help_visible {
			line_h := g_config.font.size + HELP_LINE_GAP
			help_scroll_by(-ev.wheel.y * line_h * SCROLL_LINES_PER_NOTCH)
			return
		}
		// Wheel over the terminal pane scrolls its scrollback ring,
		// not the editor underneath. Wheel-up = older content.
		if g_terminal_visible &&
		   point_in_rect({ev.wheel.mouse_x, ev.wheel.mouse_y}, l.terminal_rect) {
			terminal_scroll_by(ev.wheel.y * SCROLL_LINES_PER_NOTCH)
			return
		}
		idx := pane_at_x(ev.wheel.mouse_x, l)
		handle_mouse_wheel(&g_editors[idx], ev.wheel)
		clamp_scroll(&g_editors[idx], l.panes[idx])
	case .DROP_FILE:
		if ev.drop.data != nil {
			path := string(ev.drop.data)
			open_file_smart(path)
		}
	}
	// Vim's :q / :q! / :wq set ed.want_quit. Translate that to "close this
	// pane" — and only actually quit the app when it was the last pane.
	if active_editor().want_quit {
		if len(g_editors) > 1 {
			active_editor().want_quit = false
			close_active_pane_unconditional()
		} else {
			running^ = false
		}
	}
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

	// Don't auto-emit SDL_EVENT_QUIT when the last window is asked to
	// close. Without this, Cmd+W would fire WINDOW_CLOSE_REQUESTED
	// (which we use for "close active pane") and *also* cascade into a
	// QUIT — quitting the app right after we'd just closed a pane. We
	// still get QUIT for Cmd+Q (via NSApplication's terminate path) and
	// for SIGINT, which is what we actually want.
	_ = sdl.SetHint(sdl.HINT_QUIT_ON_LAST_WINDOW_CLOSE, "0")
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

	// Open the Nerd Font once at the same size for the terminal pane.
	// If it fails (shouldn't), the terminal will silently fall back to
	// `g_font` via the nil-check in draw_text.
	g_terminal_font = open_terminal_font(g_config.font.size * g_density)
	defer if g_terminal_font != nil do ttf.CloseFont(g_terminal_font)

	// Measure char width once. Monospace assumption.
	//
	// Measuring a *single* "M" and dividing by density rounds the
	// glyph's bounding box to whole physical pixels — at small font
	// sizes the rounding error is a meaningful fraction of the actual
	// per-char advance, so the cursor block ends up subtly wider or
	// narrower than the chars beneath it. Measuring a long run and
	// averaging averages the rounding away and lands much closer to
	// the font's true advance width.
	g_char_width = measure_char_width(g_font)
	g_line_height = g_config.font.size * g_config.editor.line_spacing

	_ = sdl.StartTextInput(g_window)
	defer { _ = sdl.StopTextInput(g_window) }

	g_cursor_default = sdl.GetDefaultCursor()
	g_cursor_resize_h = sdl.CreateSystemCursor(.EW_RESIZE)
	g_cursor_resize_v = sdl.CreateSystemCursor(.NS_RESIZE)
	defer if g_cursor_resize_h != nil do sdl.DestroyCursor(g_cursor_resize_h)
	defer if g_cursor_resize_v != nil do sdl.DestroyCursor(g_cursor_resize_v)

	// Initial pane (welcome text or CLI-arg file).
	append(&g_editors, editor_make())
	append(&g_pane_ratios, f32(1))
	g_active_idx = 0
	defer {
		for &e in g_editors do editor_destroy(&e)
		delete(g_editors)
		delete(g_pane_ratios)
	}
	active_editor().mode = .Normal

	_ = sdl.AddEventWatch(resize_event_watch, nil)
	defer sdl.RemoveEventWatch(resize_event_watch, nil)

	if len(os.args) >= 2 {
		path := os.args[1]
		if !editor_load_file(active_editor(), path) {
			fmt.eprintfln("could not open %s; starting with welcome screen", path)
			// Buffer stays empty → welcome overlay renders.
		} else {
			warn_if_mixed_eol(active_editor())
		}
	}
	// No CLI arg → empty buffer → welcome overlay (no work needed).

	last_ticks := sdl.GetTicksNS()
	running := true
	for running {
		now := sdl.GetTicksNS()
		dt := f32(now - last_ticks) / 1e9
		last_ticks = now
		active_editor().blink_timer += dt
		if active_editor().blink_timer > 1 do active_editor().blink_timer = 0
		if g_terminal != nil {
			g_terminal.blink_timer += dt
			if g_terminal.blink_timer > 1 do g_terminal.blink_timer = 0
		}

		l := compute_layout()
		prev_cursor := active_editor().cursor

		// Idle-block on events up to 250ms (enough for caret blink to update).
		// When events are flowing, we drain them all and redraw immediately.
		ev: sdl.Event
		if sdl.WaitEventTimeout(&ev, 250) {
			process_event(ev, l, &running)
			for sdl.PollEvent(&ev) do process_event(ev, l, &running)
		}
		// `g_swallow_text_input` is a one-batch guard for chord follow-ups
		// (Ctrl+W h, etc.) — any TEXT_INPUT it cares about lives in the
		// drain we just finished. Clearing here keeps it from leaking
		// into the next iteration and eating the user's first real
		// keystroke after a chord that didn't actually queue a rune.
		g_swallow_text_input = false

		flush_pending_dialogs(active_editor())
		// Layout may have shifted (open/close pane, resize), so recompute.
		l = compute_layout()
		ed := active_editor()
		if ed.cursor != prev_cursor do auto_scroll_to_caret(ed, l.panes[g_active_idx])
		// Clamp every pane — wheel events may have scrolled an inactive
		// pane past its content bounds, and we want it pinned the next
		// time a frame draws.
		for i in 0 ..< len(g_editors) {
			clamp_scroll(&g_editors[i], l.panes[i])
		}
		update_window_title(ed)

		draw_frame()

		free_all(context.temp_allocator)
	}
}
