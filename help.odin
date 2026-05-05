package bragi

import "core:c"
import "core:fmt"
import "core:strings"
import sdl "vendor:sdl3"
import ttf "vendor:sdl3/ttf"

// Modal help / cheat-sheet popup. Shown via `:h` / `:help`.
// Categorised into ~7 tabs (Modes, Motion, Edit, Search, Files,
// Terminal, Cmd shortcuts) — number keys 1-7 jump directly, h / l /
// arrow keys step. Each entry renders as a key "chip" + description.
//
// Styled like the right-click context menu (same border / bg colors)
// but laid out as a tabbed reference. Captures Esc and outside-clicks
// to dismiss.

g_help_visible:  bool
g_help_category: int = 0
g_help_scroll:   f32 = 0   // within-category scroll, in case a tab overflows

// Hardcoded; bumped manually alongside `deploy.ini`'s `version` field.
// A future improvement could thread this through a generated file at
// build time, but for a personal-scratch project keeping the two in
// sync by eye is fine.
BRAGI_VERSION :: "0.1.0"

HELP_MODAL_W_MAX :: f32(960)
HELP_MODAL_PAD   :: f32(20)
HELP_LINE_GAP    :: f32(6)
HELP_SECTION_GAP :: f32(16)   // extra space above a section header
HELP_KEY_COL_W   :: f32(180)
HELP_TAB_H       :: f32(34)
HELP_TAB_PAD_X   :: f32(14)
HELP_TAB_GAP     :: f32(8)
HELP_TAB_UNDERLINE_H :: f32(2)
HELP_SB_W        :: f32(8)
HELP_DIM_BG      :: sdl.Color{0, 0, 0, 140}
HELP_CHIP_PAD_X  :: f32(7)
HELP_CHIP_PAD_Y  :: f32(2)

@(private="file") HELP_TEXT_COLOR     :: sdl.Color{220, 220, 220, 255}
@(private="file") HELP_TEXT_DIM       :: sdl.Color{135, 140, 155, 255}
@(private="file") HELP_TEXT_BRIGHT    :: sdl.Color{235, 240, 248, 255}
@(private="file") HELP_KEY_COLOR      :: sdl.Color{ 97, 175, 239, 255} // blue
@(private="file") HELP_SECTION_COLOR  :: sdl.Color{198, 120, 221, 255} // purple
@(private="file") HELP_CHIP_BG        :: sdl.Color{ 36,  36,  44, 255}
@(private="file") HELP_CHIP_BORDER    :: sdl.Color{ 64,  68,  82, 255}
@(private="file") HELP_TAB_BG         :: sdl.Color{ 28,  28,  36, 255}
@(private="file") HELP_TAB_BG_HOT     :: sdl.Color{ 44,  46,  56, 255}

// ──────────────────────────────────────────────────────────────────
// Data: categorised entries
// ──────────────────────────────────────────────────────────────────

Help_Entry :: struct {
	keys: string, // "" → this is a section header (desc holds header text)
	desc: string,
}

Help_Category :: struct {
	name:    string,
	entries: []Help_Entry,
}

@(private="file")
HELP_MODES := [?]Help_Entry{
	{"Esc",     "return to NORMAL · also dismisses help / menu"},
	{"i",       "INSERT before the cursor"},
	{"a",       "INSERT after the cursor"},
	{"I",       "INSERT at line-start"},
	{"A",       "INSERT at line-end"},
	{"o",       "new line below + INSERT"},
	{"O",       "new line above + INSERT"},
	{"v",       "enter VISUAL"},
	{"V",       "enter VISUAL-LINE"},
}

@(private="file")
HELP_MOTION := [?]Help_Entry{
	{"h j k l", "left / down / up / right"},
	{"w b e",   "word forward / back / to end"},
	{"0 $ ^",   "line start / end / first non-blank"},
	{"gg G",    "first / last line"},
	{"<n>G",    "jump to line n  (also :n)"},
	{"%",       "jump to matching bracket   ( ) [ ] { }"},
	{"",        "Scrolling"},
	{"Ctrl+D",  "half-page down"},
	{"Ctrl+U",  "half-page up"},
	{"zz",      "center cursor's line on screen"},
	{"zt",      "scroll cursor's line to top"},
	{"zb",      "scroll cursor's line to bottom"},
}

@(private="file")
HELP_EDIT := [?]Help_Entry{
	{"dd yy cc","delete / yank / change current line"},
	{"dw d3w",  "operator + motion  (counts compose either side)"},
	{"D C Y",   "d$ / c$ / y$"},
	{"x X",     "delete char forward / backward"},
	{"p P",     "paste after / before"},
	{"u",       "undo  ·  Cmd/Ctrl+Shift+Z to redo"},
	{".",       "repeat last change (insert run, op+motion, x, p, …)"},
	{">> <<",   "indent / outdent current line"},
	{"",        "Visual mode (after v / V)"},
	{"motion",  "any motion key extends the selection"},
	{"d c y",   "delete / change / yank the selection then exit"},
	{"> <",     "indent / outdent every line in the selection"},
	{"v V",     "exit VISUAL / VISUAL-LINE"},
	{"Esc",     "exit visual without operating"},
}

@(private="file")
HELP_SEARCH := [?]Help_Entry{
	{"/pattern", "search forward (literal)"},
	{"?pattern", "search backward"},
	{"n N",      "next / previous match (wraps)"},
	{"[k/m]",    "status bar shows match index while on a hit"},
	{"\\c \\C",  "force case-insensitive / sensitive (in pattern)"},
	{":noh",     "clear active search pattern"},
	{"",         "Substitute"},
	{":s/p/r/",  "substitute on current line  (g=all  i=icase  I=case)"},
	{":%s/p/r/", "substitute across the whole buffer"},
}

@(private="file")
HELP_FILES := [?]Help_Entry{
	{"Cmd/Ctrl+F",    "directory navigator (Enter dives in / opens · `..` or Backspace up)"},
	{":w",            "save"},
	{":q",            "close pane"},
	{":wq",           "save + close"},
	{":q!",           "force-close pane (last pane → quit)"},
	{":42",           "jump to line 42"},
	{":syntax X",     "switch tokenizer  (none generic odin c cpp go jai swift bash ini)"},
	{":config",       "open / create the user config.ini"},
	{"",              "Panes"},
	{"Ctrl+W h / l",  "focus pane left / right"},
	{"Ctrl+W c / q",  "close active pane"},
	{"Cmd+[ / Cmd+]", "focus prev / next pane (single-chord)"},
	{"drag border",   "resize adjacent panes"},
	{"click pane",    "focus that pane"},
}

@(private="file")
HELP_TERMINAL := [?]Help_Entry{
	{"Cmd/Ctrl+J",   "toggle the bottom terminal pane"},
	{":term",        "open / focus the terminal"},
	{":termclose",   "close the terminal pane"},
	{"wheel",        "over the terminal: scroll the scrollback (4096-line ring)"},
	{"drag thumb",   "drag the terminal scrollbar · click track to jump"},
	{"any keystroke","snaps the view back to live"},
	{"clear",        "wipes scrollback (Ghostty-style)"},
	{"exit",         "closes the pane"},
}

@(private="file")
HELP_CMD := [?]Help_Entry{
	{"Cmd+O",         "open file (new pane unless current is blank)"},
	{"Cmd+S",         "save  (falls through to Save As if untitled)"},
	{"Cmd+Shift+S",   "save as"},
	{"Cmd+Z",         "undo"},
	{"Cmd+Shift+Z",   "redo"},
	{"Cmd+A",         "select all"},
	{"Cmd+C",         "copy"},
	{"Cmd+X",         "cut"},
	{"Cmd+V",         "paste"},
	{"Cmd+W",         "close pane (last pane on macOS quits)"},
	{"Cmd+[ / Cmd+]", "focus prev / next pane"},
	{"Cmd+Q",         "quit (chains the unsaved-changes prompt)"},
}

@(private="file")
HELP_ABOUT := [?]Help_Entry{
	{"Bragi",     BRAGI_VERSION + "  ·  GPL-3.0-only"},
	{"Copyright", "© 2026 Galaxoid Labs"},
	{"Source",    "github.com/Galaxoid-Labs/Bragi"},
	{"",          "Built with"},
	{"Odin",      "© Ginger Bill — zlib-style"},
	{"SDL3",      "© Sam Lantinga — zlib"},
	{"SDL3_ttf",  "© Sam Lantinga — zlib"},
	{"libvterm",  "© Paul Evans — MIT"},
	{"Fira Code", "© Fira Code Project Authors — SIL OFL 1.1"},
	{"Nerd Font", "© Ryan L McIntyre / Nerd Fonts — SIL OFL 1.1 / MIT"},
	{"",        "Verbatim license text ships in the bundle"},
	{"macOS",   "Bragi.app/Contents/Resources/licenses/"},
	{"Linux",   "/usr/share/doc/bragi/licenses/"},
	{"Windows", "licenses/ — next to Bragi.exe"},
}

@(private="file")
HELP_CATEGORIES := [?]Help_Category{
	{"Modes",    HELP_MODES[:]},
	{"Motion",   HELP_MOTION[:]},
	{"Edit",     HELP_EDIT[:]},
	{"Search",   HELP_SEARCH[:]},
	{"Files",    HELP_FILES[:]},
	{"Terminal", HELP_TERMINAL[:]},
	{"Cmd",      HELP_CMD[:]},
	{"About",    HELP_ABOUT[:]},
}

// ──────────────────────────────────────────────────────────────────
// Public API
// ──────────────────────────────────────────────────────────────────

help_show :: proc() {
	g_help_visible = true
	g_help_scroll  = 0
}

help_hide :: proc() { g_help_visible = false }

// Switch to category at `idx`. Out-of-range no-ops; resets scroll.
help_set_category :: proc(idx: int) {
	if idx < 0 || idx >= len(HELP_CATEGORIES) do return
	g_help_category = idx
	g_help_scroll = 0
}

// Step the active tab by `delta` (typically ±1). Wraps both ends so
// h / l keep going around the ring rather than getting stuck.
help_step_category :: proc(delta: int) {
	n := len(HELP_CATEGORIES)
	g_help_category = ((g_help_category + delta) %% n + n) %% n
	g_help_scroll = 0
}

// Scroll within the active category. Most categories fit without
// scrolling; the helper exists for the few that overflow on a tall
// modal or a small window.
help_scroll_by :: proc(dy: f32) {
	g_help_scroll = clamp(g_help_scroll + dy, 0, max(0, help_category_content_h() - help_content_viewport_h()))
}

help_scroll_to_end :: proc() {
	g_help_scroll = max(0, help_category_content_h() - help_content_viewport_h())
}

// Returns true if the click was consumed (i.e. help is up). Outside
// the modal dismisses; clicks inside swallow + dispatch (tab clicks
// switch categories).
help_handle_click :: proc(x, y: f32, l: Layout) -> bool {
	if !g_help_visible do return false
	r := help_rect(l)
	if !point_in_rect({x, y}, r) {
		help_hide()
		return true
	}
	if tab := help_tab_at(x, y, l); tab >= 0 {
		help_set_category(tab)
	}
	return true
}

// ──────────────────────────────────────────────────────────────────
// Layout math
// ──────────────────────────────────────────────────────────────────

help_rect :: proc(l: Layout) -> sdl.FRect {
	w := f32(HELP_MODAL_W_MAX)
	if w > l.screen_w - 40 do w = l.screen_w - 40
	h := help_total_h(w)
	if h > l.screen_h - 40 do h = l.screen_h - 40
	x := (l.screen_w - w) * 0.5
	y := (l.screen_h - h) * 0.5
	return sdl.FRect{x, y, w, h}
}

@(private="file")
help_total_h :: proc(modal_w: f32) -> f32 {
	// Title + tab strip (may wrap) + active-category content + bottom pad.
	tabs_h := help_tab_strip_h(modal_w)
	return HELP_MODAL_PAD * 2 + g_config.font.size + HELP_LINE_GAP + tabs_h + HELP_LINE_GAP + help_category_content_h()
}

@(private="file")
help_category_content_h :: proc() -> f32 {
	cat := HELP_CATEGORIES[g_help_category]
	line_h := g_config.font.size + HELP_LINE_GAP
	h: f32 = 0
	for entry in cat.entries {
		if entry.keys == "" {
			h += HELP_SECTION_GAP + line_h
		} else {
			h += line_h
		}
	}
	return h
}

// What the on-screen content area looks like, in pixels, given the
// current modal rect. Used to clamp the scrollbar.
@(private="file")
help_content_viewport_h :: proc() -> f32 {
	wi, hi: c.int
	sdl.GetWindowSize(g_window, &wi, &hi)
	w := f32(HELP_MODAL_W_MAX)
	if w > f32(wi) - 40 do w = f32(wi) - 40
	full_h := help_total_h(w)
	if full_h > f32(hi) - 40 do full_h = f32(hi) - 40
	tabs_h := help_tab_strip_h(w)
	return full_h - HELP_MODAL_PAD * 2 - g_config.font.size - HELP_LINE_GAP * 2 - tabs_h
}

// Width of one tab in logical pixels. Includes its padding but not
// the inter-tab gap.
@(private="file")
help_tab_w :: proc(idx: int) -> f32 {
	cat := HELP_CATEGORIES[idx]
	label := fmt.tprintf("%d %s", idx + 1, cat.name)
	cstr := strings.clone_to_cstring(label, context.temp_allocator)
	w_px: c.int
	ttf.GetStringSize(g_font, cstr, 0, &w_px, nil)
	return f32(w_px) / g_density + HELP_TAB_PAD_X * 2
}

// Height of the tab strip in logical pixels. Tabs wrap onto a new
// row when their cumulative width exceeds the inner modal width.
@(private="file")
help_tab_strip_h :: proc(modal_w: f32) -> f32 {
	inner_w := modal_w - HELP_MODAL_PAD * 2
	x: f32 = 0
	rows: int = 1
	for _, i in HELP_CATEGORIES {
		w := help_tab_w(i)
		if x > 0 && x + w > inner_w {
			x = 0
			rows += 1
		}
		x += w + HELP_TAB_GAP
	}
	return f32(rows) * HELP_TAB_H + f32(rows - 1) * 4
}

// Hit-test for the tab strip. Returns the tab index under (x, y) or
// -1 if none. Mirrors `draw_help_tabs` exactly.
@(private="file")
help_tab_at :: proc(x, y: f32, l: Layout) -> int {
	r := help_rect(l)
	tabs_y0 := r.y + HELP_MODAL_PAD + g_config.font.size + HELP_LINE_GAP
	cur_x := r.x + HELP_MODAL_PAD
	cur_y := tabs_y0
	inner_x_end := r.x + r.w - HELP_MODAL_PAD
	for _, i in HELP_CATEGORIES {
		w := help_tab_w(i)
		if cur_x + w > inner_x_end && cur_x > r.x + HELP_MODAL_PAD {
			cur_x = r.x + HELP_MODAL_PAD
			cur_y += HELP_TAB_H + 4
		}
		if x >= cur_x && x < cur_x + w && y >= cur_y && y < cur_y + HELP_TAB_H {
			return i
		}
		cur_x += w + HELP_TAB_GAP
	}
	return -1
}

// ──────────────────────────────────────────────────────────────────
// Drawing
// ──────────────────────────────────────────────────────────────────

draw_help :: proc(l: Layout) {
	if !g_help_visible do return

	// Dim the rest of the UI behind the modal.
	fill_rect({0, 0, l.screen_w, l.screen_h}, HELP_DIM_BG)

	r := help_rect(l)
	fill_rect(r, MENU_BG_COLOR)

	// Border (four 1-px strips).
	bw: f32 = 1
	fill_rect({r.x,            r.y,                r.w, bw },  MENU_BORDER_COLOR)
	fill_rect({r.x,            r.y + r.h - bw,     r.w, bw },  MENU_BORDER_COLOR)
	fill_rect({r.x,            r.y,                bw,  r.h},  MENU_BORDER_COLOR)
	fill_rect({r.x + r.w - bw, r.y,                bw,  r.h},  MENU_BORDER_COLOR)

	// Title row.
	title_y := r.y + HELP_MODAL_PAD
	title_cstr := strings.clone_to_cstring(
		"Bragi — keyboard reference   (Esc to close · 1-8 / h l / click to switch)",
		context.temp_allocator)
	draw_text(title_cstr, r.x + HELP_MODAL_PAD, title_y, HELP_TEXT_DIM, MENU_BG_COLOR)

	// Tab strip.
	tabs_y0 := title_y + g_config.font.size + HELP_LINE_GAP
	tabs_h := draw_help_tabs(r.x + HELP_MODAL_PAD, tabs_y0, r.x + r.w - HELP_MODAL_PAD)

	// Active-category content. Clipped so overflow scrolls cleanly.
	content_y0 := tabs_y0 + tabs_h + HELP_LINE_GAP
	content_clip := sdl.Rect{
		i32(r.x + bw),
		i32(content_y0),
		i32(r.w - bw * 2),
		i32(r.y + r.h - bw - content_y0),
	}
	sdl.SetRenderClipRect(g_renderer, &content_clip)
	defer sdl.SetRenderClipRect(g_renderer, nil)

	cat := HELP_CATEGORIES[g_help_category]
	line_h := g_config.font.size + HELP_LINE_GAP
	x := r.x + HELP_MODAL_PAD
	y := content_y0 - g_help_scroll
	for entry in cat.entries {
		if entry.keys == "" {
			// Section header.
			y += HELP_SECTION_GAP - HELP_LINE_GAP
			cstr := strings.clone_to_cstring(entry.desc, context.temp_allocator)
			draw_text(cstr, x, y, HELP_SECTION_COLOR, MENU_BG_COLOR)
			y += line_h
			continue
		}
		// Chip + description.
		chip_w := draw_key_chip(entry.keys, x, y)
		desc_x := x + max(chip_w + 12, HELP_KEY_COL_W)
		if len(entry.desc) > 0 {
			cstr := strings.clone_to_cstring(entry.desc, context.temp_allocator)
			draw_text(cstr, desc_x, y, HELP_TEXT_COLOR, MENU_BG_COLOR)
		}
		y += line_h
	}

	// Scrollbar inside the content area (only when overflow).
	content_h := help_category_content_h()
	viewport_h := r.y + r.h - bw - content_y0
	if content_h > viewport_h {
		track := sdl.FRect{r.x + r.w - HELP_SB_W - bw, content_y0, HELP_SB_W, viewport_h}
		fill_rect(track, g_theme.sb_track_color)
		thumb_h := max(SB_MIN_THUMB, (viewport_h / content_h) * track.h)
		max_scroll := content_h - viewport_h
		thumb_y := track.y + (g_help_scroll / max_scroll) * (track.h - thumb_h)
		fill_rect({track.x + 1, thumb_y, track.w - 2, thumb_h}, g_theme.sb_thumb_color)
	}
}

// Render a tab row. No bg fills, no borders — just text with an
// underline under the active tab. Hovered tabs brighten slightly so
// the click target reads. Returns the total height used (logical px).
@(private="file")
draw_help_tabs :: proc(x_start, y_start, x_end: f32) -> f32 {
	x := x_start
	y := y_start
	mx, my: f32
	_ = sdl.GetMouseState(&mx, &my)

	for cat, i in HELP_CATEGORIES {
		w := help_tab_w(i)
		if x + w > x_end && x > x_start {
			x = x_start
			y += HELP_TAB_H + 4
		}

		is_active := i == g_help_category
		hovered   := mx >= x && mx < x + w && my >= y && my < y + HELP_TAB_H

		fg := HELP_TEXT_DIM
		if hovered   do fg = HELP_TEXT_COLOR
		if is_active do fg = HELP_TEXT_BRIGHT

		label := fmt.tprintf("%d %s", i + 1, cat.name)
		cstr  := strings.clone_to_cstring(label, context.temp_allocator)
		text_y := y + (HELP_TAB_H - g_config.font.size) * 0.5
		text_w := draw_text(cstr, x + HELP_TAB_PAD_X, text_y, fg, MENU_BG_COLOR)

		if is_active {
			// Accent underline directly below the label, only as wide
			// as the rendered text — looks like a tab marker rather
			// than a chip outline.
			fill_rect({x + HELP_TAB_PAD_X, text_y + g_config.font.size + 2, text_w, HELP_TAB_UNDERLINE_H}, HELP_KEY_COLOR)
		}

		x += w + HELP_TAB_GAP
	}
	return y - y_start + HELP_TAB_H
}

// Render a key as text with a 1-px underline in the key color. No
// fill, no border — the underline is enough visual weight to mark
// "this is a key" without the chip-box noise. Returns the rendered
// width so the caller knows where the description starts.
@(private="file")
draw_key_chip :: proc(text: string, x, y: f32) -> f32 {
	if len(text) == 0 do return 0
	cstr := strings.clone_to_cstring(text, context.temp_allocator)
	w := draw_text(cstr, x, y, HELP_KEY_COLOR, MENU_BG_COLOR)
	// Underline sits just below the glyph baseline. 2 px below the
	// font's nominal top so it visually reads as an underline rather
	// than a separator line under the row.
	fill_rect({x, y + g_config.font.size + 1, w, 1}, HELP_KEY_COLOR)
	return w
}

// Splits a help line into its key column and description column. The
// split point is the first run of >= 3 consecutive spaces; everything
// before is the key, everything after (including the spaces) is the
// trailing layout + description. Used by the welcome screen, which
// has its own line list rather than going through HELP_CATEGORIES.
split_help_line :: proc(line: string) -> (key: string, rest: string, has_desc: bool) {
	n := len(line)
	if n < 4 do return line, "", false
	for i in 0 ..< n - 2 {
		if line[i] == ' ' && line[i + 1] == ' ' && line[i + 2] == ' ' {
			return line[:i], line[i:], true
		}
	}
	return line, "", false
}
