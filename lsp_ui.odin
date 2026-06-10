package bragi

import "core:encoding/json"
import "core:strings"
import sdl "vendor:sdl3"

// Two passive LSP tooltips: signature help (parameters when you type `(`)
// and hover (Cmd/Ctrl-hover a symbol → underline + info popup; Cmd-click
// jumps to the definition). Both mirror the request/response shape of the
// completion popup but render a simple box, not an interactive list.

@(private="file")
is_ident_byte :: proc(b: u8) -> bool {
	return (b >= 'a' && b <= 'z') || (b >= 'A' && b <= 'Z') || (b >= '0' && b <= '9') || b == '_'
}

@(private="file")
lsp_num :: proc(v: json.Value) -> int {
	#partial switch n in v {
	case json.Integer: return int(n)
	case json.Float:   return int(n)
	}
	return 0
}

// The identifier byte-range containing/adjacent to `pos`.
lsp_ident_range :: proc(ed: ^Editor, pos: int) -> (lo, hi: int, ok: bool) {
	n := piece_buffer_len(&ed.buffer)
	if pos < 0 || pos > n do return 0, 0, false
	lo = pos
	for lo > 0 && is_ident_byte(piece_buffer_byte_at(&ed.buffer, lo - 1)) do lo -= 1
	hi = pos
	for hi < n && is_ident_byte(piece_buffer_byte_at(&ed.buffer, hi)) do hi += 1
	if hi <= lo do return 0, 0, false
	return lo, hi, true
}

// ── signature help ──────────────────────────────────────────────────

g_signature: struct {
	visible:    bool,
	label:      string, // owned
	active_lo:  int,     // active-param byte range within label (-1 = none)
	active_hi:  int,
	pending_id: i64,
	for_editor: int,
}

signature_destroy :: proc() {
	if len(g_signature.label) > 0 do delete(g_signature.label)
	g_signature = {}
}

signature_dismiss :: proc() {
	if len(g_signature.label) > 0 do delete(g_signature.label)
	g_signature.label = ""
	g_signature.visible = false
	g_signature.pending_id = 0
	g_signature.active_lo = -1
	g_signature.active_hi = -1
}

signature_trigger :: proc(ed: ^Editor) {
	if !lsp_ready(ed.language) || ed.mode != .Insert do return
	g_signature.for_editor = g_active_idx
	id, ok := lsp_signature_request(ed)
	if !ok do return
	g_signature.pending_id = id
}

// From handle_text_input after a rune in Insert mode.
signature_after_insert :: proc(ed: ^Editor, r: rune) {
	if !lsp_ready(ed.language) do return
	switch r {
	case '(': signature_trigger(ed)
	case ',': if g_signature.visible do signature_trigger(ed) // advance active param
	case ')': signature_dismiss()
	}
}

signature_on_cursor_moved :: proc(ed: ^Editor) {
	if !g_signature.visible do return
	if g_active_idx != g_signature.for_editor || ed.mode != .Insert do signature_dismiss()
}

signature_on_response :: proc(obj: json.Object) {
	id := lsp_obj_int(obj, "id")
	if id != g_signature.pending_id do return
	if g_active_idx != g_signature.for_editor do return

	rv, has := obj["result"]
	if !has {signature_dismiss(); return}
	res, ok := rv.(json.Object)
	if !ok {signature_dismiss(); return}
	sigs_v, hs := res["signatures"]
	if !hs {signature_dismiss(); return}
	sigs, ok2 := sigs_v.(json.Array)
	if !ok2 || len(sigs) == 0 {signature_dismiss(); return}

	asig := int(lsp_obj_int(res, "activeSignature"))
	if asig < 0 || asig >= len(sigs) do asig = 0
	sig, ok3 := sigs[asig].(json.Object)
	if !ok3 {signature_dismiss(); return}
	label := lsp_obj_str(sig, "label")
	if label == "" {signature_dismiss(); return}

	aparam := int(lsp_obj_int(res, "activeParameter"))
	if av, hav := sig["activeParameter"]; hav do aparam = lsp_num(av)

	// The active parameter's raw text (a substring of the label, or a
	// [start,end] slice into it).
	param_text := ""
	if pv, hp := sig["parameters"]; hp {
		if params, okp := pv.(json.Array); okp && aparam >= 0 && aparam < len(params) {
			if po, okpo := params[aparam].(json.Object); okpo {
				if lv, hl := po["label"]; hl {
					#partial switch lab in lv {
					case json.String:
						param_text = string(lab)
					case json.Array:
						if len(lab) >= 2 {
							s := lsp_num(lab[0])
							e := lsp_num(lab[1])
							if s >= 0 && e <= len(label) && s < e do param_text = label[s:e]
						}
					}
				}
			}
		}
	}

	// Collapse the source's alignment whitespace (a multi-line decl arrives
	// with newlines + tabs between params), then re-locate the active param
	// in the collapsed text so the underline still lines up.
	display := collapse_ws(label, context.temp_allocator)
	lo, hi := -1, -1
	if len(param_text) > 0 {
		dp := collapse_ws(param_text, context.temp_allocator)
		if idx := strings.index(display, dp); idx >= 0 {
			lo = idx
			hi = idx + len(dp)
		}
	}

	if len(g_signature.label) > 0 do delete(g_signature.label)
	g_signature.label = strings.clone(display)
	g_signature.active_lo = lo
	g_signature.active_hi = hi
	g_signature.visible = true
}

// Collapse every run of whitespace (spaces, tabs, newlines) to a single
// space and trim the ends. Turns a multi-line, tab-aligned signature into
// one tidy line.
@(private="file")
collapse_ws :: proc(s: string, alloc := context.allocator) -> string {
	b := strings.builder_make(alloc)
	prev_space := false
	for c in transmute([]u8)s {
		if c == ' ' || c == '\t' || c == '\n' || c == '\r' || c < 0x20 {
			if !prev_space {
				strings.write_byte(&b, ' ')
				prev_space = true
			}
		} else {
			strings.write_byte(&b, c)
			prev_space = false
		}
	}
	return strings.trim_space(strings.to_string(b))
}

// Replace tabs / control characters with spaces, in place. 1:1 byte swap,
// so any byte offsets into the string stay valid. Source signatures often
// contain tabs (and sometimes newlines from multi-line decls), which render
// as missing-glyph boxes and desync column math against count_display_cols.
// `keep_nl` preserves '\n' for the multi-line hover popup.
@(private="file")
sanitize_inline :: proc(b: []u8, keep_nl := false) {
	for &c in b {
		if c == '\n' && keep_nl do continue
		if c < 0x20 || c == 0x7f do c = ' '
	}
}

draw_signature :: proc(ed: ^Editor, p: Pane_Layout) {
	if !g_signature.visible || len(g_signature.label) == 0 do return
	if completion_active() do return // don't stack over the completion list

	cline, ccol := editor_pos_to_line_col(ed, ed.cursor)
	caret_x := p.text_x + f32(ccol) * g_char_width  - ed.scroll_x
	caret_y := p.text_y + f32(cline) * g_line_height - ed.scroll_y

	pad: f32 = 6
	label := g_signature.label
	content_w := f32(count_display_cols(transmute([]u8)label)) * g_char_width
	w := content_w + pad * 2
	if w > p.text_w - 8 do w = p.text_w - 8
	h := g_config.font.size + pad * 2

	x := caret_x
	y := caret_y - h - 2 // above the line
	if y < p.text_y do y = caret_y + g_line_height + 2
	if x + w > p.text_x + p.text_w do x = p.text_x + p.text_w - w
	if x < p.text_x do x = p.text_x

	r := sdl.FRect{x, y, w, h}
	fill_rect(r, MENU_BG_COLOR)
	draw_box_border(r)
	clip := sdl.Rect{i32(r.x), i32(r.y), i32(r.w), i32(r.h)}
	sdl.SetRenderClipRect(g_renderer, &clip)
	defer sdl.SetRenderClipRect(g_renderer, nil)

	ty := r.y + pad
	lo, hi := g_signature.active_lo, g_signature.active_hi

	// Long signatures overflow the popup; shift the label left so the active
	// parameter stays in view.
	avail := w - pad * 2
	off: f32 = 0
	if content_w > avail && lo >= 0 && hi > lo {
		ax := f32(lo) * g_char_width
		ae := f32(hi) * g_char_width
		if ae > off + avail do off = ae - avail
		if ax < off do off = ax
	}
	base_x := r.x + pad - off

	// Syntax-colored label, with the active parameter underlined (keeps the
	// "which arg am I on" cue without fighting the syntax colors).
	draw_code_line(ed.language, label, base_x, ty, MENU_BG_COLOR)
	if lo >= 0 && hi > lo && hi <= len(label) {
		ux := base_x + f32(lo) * g_char_width
		uw := f32(hi - lo) * g_char_width
		t := max(1.0 / g_density, 1.5)
		fill_rect({ux, ty + g_config.font.size, uw, t}, g_theme.function_color)
	}
}

// ── hover (Cmd/Ctrl-hover) ──────────────────────────────────────────

g_hover: struct {
	cmd_active: bool, // modifier held → underline + hover
	target_lo:  int,  // underlined identifier range
	target_hi:  int,
	has_target: bool,
	text:       string, // owned; popup content
	visible:    bool,
	anchor_pos: int,
	pending_id: i64,
	for_editor: int,
}

hover_destroy :: proc() {
	if len(g_hover.text) > 0 do delete(g_hover.text)
	g_hover = {}
}

hover_clear :: proc() {
	if len(g_hover.text) > 0 do delete(g_hover.text)
	g_hover.text = ""
	g_hover.visible = false
	g_hover.has_target = false
	g_hover.cmd_active = false
	g_hover.pending_id = 0
}

// Token kinds worth hovering — actual symbols. Comments / strings /
// keywords / numbers / literals get no popup (hovering them is just noise).
@(private="file")
lsp_hoverable_kind :: proc(k: Token_Kind) -> bool {
	#partial switch k {
	case .Default, .Function, .Type:
		return true
	}
	return false
}

// The syntax token kind covering byte `pos` — reuses the same tokenizer the
// editor draws with, so "is this a comment / string / keyword?" matches what
// you see on screen.
@(private="file")
lsp_token_kind_at :: proc(ed: ^Editor, pos: int) -> Token_Kind {
	if ed.language == .None do return .Default
	line, _ := editor_pos_to_line_col(ed, pos)
	line_start := editor_nth_line_start(ed, line)
	line_end := editor_line_end(ed, line_start)
	n := line_end - line_start
	if n <= 0 do return .Default
	buf := make([]u8, n, context.temp_allocator)
	for i in 0 ..< n do buf[i] = piece_buffer_byte_at(&ed.buffer, line_start + i)
	state := compute_state_at_line(ed, line) // carry block-comment state in
	tokens, _ := syntax_tokenize(ed.language, buf, state)
	rel := pos - line_start
	for tok in tokens {
		if rel >= tok.start && rel < tok.end do return tok.kind
	}
	return .Default
}

// Cmd/Ctrl-hover the identifier at `pos`: underline it and request hover.
hover_set_target :: proc(ed: ^Editor, pos: int) {
	if !lsp_ready(ed.language) {hover_clear(); return}
	lo, hi, ok := lsp_ident_range(ed, pos)
	if !ok {hover_clear(); return}
	if g_hover.has_target && g_hover.cmd_active && g_hover.target_lo == lo && g_hover.target_hi == hi do return
	// Only hover real symbols — skip comments / strings / keywords / literals.
	if !lsp_hoverable_kind(lsp_token_kind_at(ed, lo)) {
		hover_clear()
		return
	}
	g_hover.cmd_active = true
	g_hover.target_lo = lo
	g_hover.target_hi = hi
	g_hover.has_target = true
	g_hover.anchor_pos = lo
	g_hover.for_editor = g_active_idx
	if len(g_hover.text) > 0 {delete(g_hover.text); g_hover.text = ""}
	g_hover.visible = false
	id, sent := lsp_hover_request_at(ed, lo)
	if sent do g_hover.pending_id = id
}

hover_on_response :: proc(obj: json.Object) {
	id := lsp_obj_int(obj, "id")
	if id != g_hover.pending_id do return
	if g_active_idx != g_hover.for_editor do return
	rv, has := obj["result"]
	if !has do return
	res, ok := rv.(json.Object)
	if !ok do return

	text := ""
	if cv, hc := res["contents"]; hc {
		#partial switch contents in cv {
		case json.String:
			text = string(contents)
		case json.Object:
			text = lsp_obj_str(contents, "value")
		case json.Array:
			if len(contents) > 0 {
				#partial switch f in contents[0] {
				case json.String: text = string(f)
				case json.Object: text = lsp_obj_str(f, "value")
				}
			}
		}
	}
	text = hover_display_text(text)
	if text == "" do return
	if len(g_hover.text) > 0 do delete(g_hover.text)
	g_hover.text = strings.clone(text)
	sanitize_inline(transmute([]u8)g_hover.text, keep_nl = true) // keep \n for multi-line
	g_hover.visible = true
}

draw_hover :: proc(ed: ^Editor, p: Pane_Layout) {
	// Underline the cmd-hover target.
	if g_hover.cmd_active && g_hover.has_target {
		sline, scol := editor_pos_to_line_col(ed, g_hover.target_lo)
		_, ecol := editor_pos_to_line_col(ed, g_hover.target_hi)
		x := p.text_x + f32(scol) * g_char_width  - ed.scroll_x
		y := p.text_y + f32(sline) * g_line_height - ed.scroll_y
		w := f32(ecol - scol) * g_char_width
		t := max(1.0 / g_density, 1.0)
		fill_rect({x, y + g_line_height - t, w, t}, g_theme.function_color)
	}
	if !g_hover.visible || len(g_hover.text) == 0 do return

	lines := strings.split(g_hover.text, "\n", context.temp_allocator)
	pad: f32 = 6
	row_h := g_config.font.size + 2
	maxw: f32 = 0
	for ln in lines {
		lw := f32(len(strings.trim_right(ln, "\r"))) * g_char_width
		if lw > maxw do maxw = lw
	}
	w := maxw + pad * 2
	if w > p.text_w - 8 do w = p.text_w - 8
	nlines := min(len(lines), 12)
	h := f32(nlines) * row_h + pad * 2

	sline, scol := editor_pos_to_line_col(ed, g_hover.anchor_pos)
	ax := p.text_x + f32(scol) * g_char_width  - ed.scroll_x
	ay := p.text_y + f32(sline) * g_line_height - ed.scroll_y
	x := ax
	y := ay - h - 2
	if y < p.text_y do y = ay + g_line_height + 2
	if x + w > p.text_x + p.text_w do x = p.text_x + p.text_w - w
	if x < p.text_x do x = p.text_x

	r := sdl.FRect{x, y, w, h}
	fill_rect(r, MENU_BG_COLOR)
	draw_box_border(r)
	clip := sdl.Rect{i32(r.x), i32(r.y), i32(r.w), i32(r.h)}
	sdl.SetRenderClipRect(g_renderer, &clip)
	defer sdl.SetRenderClipRect(g_renderer, nil)
	for i in 0 ..< nlines {
		draw_code_line(ed.language, strings.trim_right(lines[i], "\r"), r.x + pad, r.y + pad + f32(i) * row_h, MENU_BG_COLOR)
	}
}

// Draw one line of source colored by the syntax tokenizer for `lang`, on
// background `bg` (the popup bg — LCD subpixel AA bakes it in). Mirrors
// draw_tokenized_line but parameterizes the bg. Returns the width drawn.
@(private="file")
draw_code_line :: proc(lang: Language, line: string, x, y: f32, bg: sdl.Color) -> f32 {
	if len(line) == 0 do return 0
	bytes := transmute([]u8)line
	tokens, _ := syntax_tokenize(lang, bytes, .Normal)
	default_fg := theme_color(&g_theme, .Default)
	// Position per-column (monospace), NOT by draw_text's returned width:
	// a segment ending in spaces returns less than its advance, which would
	// overlap the next segment (the smear in the signature popup).
	col := 0
	prev := 0
	emit :: proc(seg: []u8, x, y: f32, col: ^int, fg, bg: sdl.Color) {
		if len(seg) == 0 do return
		draw_seg(seg, x + f32(col^) * g_char_width, y, fg, bg)
		col^ += count_display_cols(seg)
	}
	for tok in tokens {
		if tok.start > prev do emit(bytes[prev:tok.start], x, y, &col, default_fg, bg)
		emit(bytes[tok.start:tok.end], x, y, &col, theme_color(&g_theme, tok.kind), bg)
		prev = tok.end
	}
	if prev < len(bytes) do emit(bytes[prev:], x, y, &col, default_fg, bg)
	return f32(col) * g_char_width
}

@(private="file")
draw_seg :: proc(s: []u8, x, y: f32, fg, bg: sdl.Color) -> f32 {
	if len(s) == 0 do return 0
	cs := strings.clone_to_cstring(string(s), context.temp_allocator)
	return draw_text(cs, x, y, fg, bg)
}

// ── shared ──────────────────────────────────────────────────────────

// Render LSP markdown hover content to plain text: drop ```lang code
// fences and surrounding inline-code backticks, leaving just the code.
@(private="file")
hover_display_text :: proc(s: string) -> string {
	lines := strings.split(s, "\n", context.temp_allocator)
	b := strings.builder_make(context.temp_allocator)
	n := 0
	for ln in lines {
		if strings.has_prefix(strings.trim_space(ln), "```") do continue // fence
		if n > 0 do strings.write_byte(&b, '\n')
		strings.write_string(&b, ln)
		n += 1
	}
	out := strings.trim_space(strings.to_string(b))
	out = strings.trim(out, "`") // terse hovers come as `name`
	return strings.trim_space(out)
}

@(private="file")
draw_box_border :: proc(r: sdl.FRect) {
	bw: f32 = 1
	fill_rect({r.x, r.y, r.w, bw}, MENU_BORDER_COLOR)
	fill_rect({r.x, r.y + r.h - bw, r.w, bw}, MENU_BORDER_COLOR)
	fill_rect({r.x, r.y, bw, r.h}, MENU_BORDER_COLOR)
	fill_rect({r.x + r.w - bw, r.y, bw, r.h}, MENU_BORDER_COLOR)
}

