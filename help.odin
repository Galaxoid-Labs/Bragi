package bragi

import "core:c"
import "core:strings"
import sdl "vendor:sdl3"

// Modal help/cheat-sheet popup. Shown via `:h` / `:help`. Styled like the
// right-click context menu (same border / bg colours) but laid out as a
// scrollable list of shortcuts. Captures Esc and outside-clicks to dismiss.

g_help_visible: bool
g_help_scroll:  f32 = 0

HELP_PAD       :: 16.0
HELP_LINE_GAP  :: 4.0
HELP_TITLE_GAP :: 6.0
HELP_SB_W      :: 8.0  // scrollbar width inside the modal
HELP_DIM_BG    :: sdl.Color{0, 0, 0, 140}

help_show :: proc() {
	g_help_visible = true
	g_help_scroll  = 0
}
help_hide :: proc() { g_help_visible = false }

// Total scrollable content height (lines + padding + extra space under title).
@(private="file")
help_content_height :: proc() -> f32 {
	line_h := g_config.font.size + HELP_LINE_GAP
	return f32(len(HELP_LINES)) * line_h + HELP_PAD * 2 + HELP_TITLE_GAP
}

HELP_LINES :: [?]string{
	"Bragi — keyboard reference",
	"",
	"── Modes ──",
	"Esc           return to NORMAL · also closes this help",
	"i  a  I  A    enter INSERT before / after / line-start / line-end",
	"o  O          new line below / above and INSERT",
	"v  V          enter VISUAL  /  VISUAL-LINE",
	"",
	"── Motions (NORMAL) ──",
	"h  j  k  l    left / down / up / right",
	"w  b  e       word forward / back / to end",
	"0  $  ^       line start / end / first non-blank",
	"gg  G         first / last line",
	"<n>G          jump to line n  (also :n)",
	"",
	"── Operators ──",
	"dd  yy  cc    delete / yank / change current line",
	"dw  y3w  3dw    operator + motion  (counts compose)",
	"D  C  Y       d$  c$  y$",
	"x  X          delete char forward / backward",
	"p  P          paste after / before",
	"u             undo  ·  Cmd/Ctrl+Shift+Z to redo",
	".             repeat last change (insert run, op+motion, x, p, …)",
	"",
	"── Visual mode (after v / V) ──",
	"motion keys   extend the selection (h j k l w b e 0 $ ^ gg G)",
	"d  c  y       delete / change / yank the selection then exit",
	"v             exit VISUAL  ·  V exits VISUAL-LINE",
	"Esc           exit visual without operating",
	"",
	"── Search ──",
	"/pattern      search forward (literal)",
	"?pattern      search backward",
	"n  N          next / previous match (wraps)",
	"[k/m]         status bar shows match index while on a hit",
	":noh          clear active search pattern",
	"",
	"── Files & panes ──",
	":e <path>     open file (replaces blank pane, else splits)",
	":r <path>     replace active pane with file (drops unsaved changes)",
	":w  :q  :wq   save / close pane / save+close",
	":q!           force-close pane (last pane → quit)",
	":42           jump to line 42",
	":syntax X     switch tokenizer  (none · generic · odin)",
	"Ctrl+W h / l  focus pane left / right",
	"Ctrl+W c / q  close active pane",
	"Cmd+[ / Cmd+] focus pane left / right",
	"drag border   resize adjacent panes",
	"click pane    focus that pane",
	"",
	"── Cmd / Ctrl shortcuts ──",
	"Cmd+O         open file (new pane unless current is blank)",
	"Cmd+S         save  (falls through to Save As if untitled)",
	"Cmd+Shift+S   save as",
	"Cmd+Z         undo  ·  Cmd+Shift+Z to redo",
	"Cmd+A         select all",
	"Cmd+C  X  V   copy · cut · paste",
	"Cmd+W         close pane  (last pane on macOS quits)",
	"Cmd+[ / Cmd+] focus prev / next pane",
	"Cmd+Q         quit  (chains the unsaved-changes prompt)",
}

help_rect :: proc(l: Layout) -> sdl.FRect {
	w := f32(640)
	h := help_content_height()
	if w > l.screen_w - 40 do w = l.screen_w - 40
	if h > l.screen_h - 40 do h = l.screen_h - 40
	x := (l.screen_w - w) * 0.5
	y := (l.screen_h - h) * 0.5
	return sdl.FRect{x, y, w, h}
}

// Computes the modal height directly off the current SDL window so callers
// in non-draw paths (mouse wheel, key input) don't need a Layout to scroll.
@(private="file")
help_modal_h :: proc() -> f32 {
	wi, hi: c.int
	sdl.GetWindowSize(g_window, &wi, &hi)
	sh := f32(hi)
	h := help_content_height()
	if h > sh - 40 do h = sh - 40
	return h
}

// Scroll by `dy` logical pixels (positive = scroll content up). Clamped
// against the current modal size.
help_scroll_by :: proc(dy: f32) {
	g_help_scroll = clamp(g_help_scroll + dy, 0, max(0, help_content_height() - help_modal_h()))
}

help_scroll_to_end :: proc() {
	g_help_scroll = max(0, help_content_height() - help_modal_h())
}

@(private="file")
HELP_SECTION_COLOR :: sdl.Color{198, 120, 221, 255} // purple
@(private="file")
HELP_KEY_COLOR :: sdl.Color{ 97, 175, 239, 255} // blue
@(private="file")
HELP_TEXT_COLOR :: sdl.Color{220, 220, 220, 255} // default light grey

// Splits a help line into its key column and description column. The split
// point is the first run of >= 3 consecutive spaces; everything before is
// the key, everything after (including the spaces) is the trailing layout +
// description. Returns has_desc=false for lines that are pure prose
// (titles, section headers, blanks).
@(private="file")
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

// Returns true if the click was consumed (i.e. help is up). Outside clicks
// dismiss; inside clicks are swallowed so they don't fall through to the
// editor.
help_handle_click :: proc(x, y: f32, l: Layout) -> bool {
	if !g_help_visible do return false
	r := help_rect(l)
	if !point_in_rect({x, y}, r) do help_hide()
	return true
}

draw_help :: proc(l: Layout) {
	if !g_help_visible do return

	// Dim the rest of the UI behind the modal.
	fill_rect({0, 0, l.screen_w, l.screen_h}, HELP_DIM_BG)

	r := help_rect(l)
	fill_rect(r, MENU_BG_COLOR)

	// Border (four 1-px strips).
	bw: f32 = 1
	fill_rect({r.x,                 r.y,                  r.w, bw },  MENU_BORDER_COLOR)
	fill_rect({r.x,                 r.y + r.h - bw,       r.w, bw },  MENU_BORDER_COLOR)
	fill_rect({r.x,                 r.y,                  bw,  r.h},  MENU_BORDER_COLOR)
	fill_rect({r.x + r.w - bw,      r.y,                  bw,  r.h},  MENU_BORDER_COLOR)

	// Clip text so a line longer than the modal doesn't bleed past the border.
	clip := sdl.Rect{
		i32(r.x + bw),
		i32(r.y + bw),
		i32(r.w - bw * 2),
		i32(r.h - bw * 2),
	}
	sdl.SetRenderClipRect(g_renderer, &clip)
	defer sdl.SetRenderClipRect(g_renderer, nil)

	line_h := g_config.font.size + HELP_LINE_GAP
	y := r.y + HELP_PAD - g_help_scroll
	for line, idx in HELP_LINES {
		// Skip lines fully above or below the visible area.
		on_screen := y + line_h >= r.y && y < r.y + r.h
		if on_screen && len(line) > 0 {
			x := r.x + HELP_PAD
			if strings.has_prefix(line, "──") {
				cstr := strings.clone_to_cstring(line, context.temp_allocator)
				draw_text(cstr, x, y, HELP_SECTION_COLOR, MENU_BG_COLOR)
			} else {
				key, rest, has_desc := split_help_line(line)
				if has_desc {
					key_cstr  := strings.clone_to_cstring(key,  context.temp_allocator)
					rest_cstr := strings.clone_to_cstring(rest, context.temp_allocator)
					draw_text(key_cstr,  x,                                y, HELP_KEY_COLOR,  MENU_BG_COLOR)
					draw_text(rest_cstr, x + f32(len(key)) * g_char_width, y, HELP_TEXT_COLOR, MENU_BG_COLOR)
				} else {
					cstr := strings.clone_to_cstring(line, context.temp_allocator)
					draw_text(cstr, x, y, HELP_TEXT_COLOR, MENU_BG_COLOR)
				}
			}
		}
		y += line_h
		if idx == 0 do y += HELP_TITLE_GAP
	}

	// Scrollbar on the right (visual indicator + drag-target if content overflows).
	content_h := help_content_height()
	if content_h > r.h {
		track := sdl.FRect{r.x + r.w - HELP_SB_W - bw, r.y + bw, HELP_SB_W, r.h - bw * 2}
		fill_rect(track, g_theme.sb_track_color)
		thumb_h := max(SB_MIN_THUMB, (r.h / content_h) * track.h)
		max_scroll := content_h - r.h
		thumb_y := track.y + (g_help_scroll / max_scroll) * (track.h - thumb_h)
		fill_rect({track.x + 1, thumb_y, track.w - 2, thumb_h}, g_theme.sb_thumb_color)
	}
}
