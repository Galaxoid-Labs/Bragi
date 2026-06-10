package bragi

import "base:runtime"
import sysc "core:c"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:unicode/utf8"
import sdl "vendor:sdl3"

// Our ends of a spawned server's stdio pipes. POSIX uses fds; the Windows
// spawn (lsp_windows.odin) stores HANDLEs in the same int fields. Filled
// by lsp_spawn (platform-specific); operated on by lsp_pipe_*.
LSP_Pipes :: struct {
	pid:       int,
	stdin_fd:  int, // we write here  → child stdin
	stdout_fd: int, // we read here   ← child stdout
}

// LSP client. Drives a language server (jai-lsp for .jai, ols for .odin)
// over JSON-RPC 2.0 on the child's stdin/stdout, framed with
// `Content-Length:` headers. One server process per language; spawned
// lazily when a matching file opens inside a workspace.
//
// Threading mirrors the terminal / fff worker: a reader thread parses
// framed messages off the pipe, stashes the JSON bodies under a mutex,
// and pushes LSP_EVENT to wake the main loop, which drains + dispatches
// in lsp_pump (main thread). Outbound writes happen inline on the main
// thread (pipe writes are fast).
//
// Phase 1 scope: spawn + initialize/initialized handshake + didOpen /
// didClose + receiving publishDiagnostics (logged). didChange, rendering,
// completion and go-to-definition build on top of this.

LSP_EVENT :: i32(0x4C535000) // "LSP\0" — reader-thread wake code

LSP_Encoding :: enum u8 {
	UTF8,
	UTF16,
}

LSP_State :: enum u8 {
	Initializing,
	Ready,
	Dead,
}

LSP_Client :: struct {
	lang:       Language,
	root:       string, // owned; workspace root
	encoding:   LSP_Encoding,
	state:      LSP_State,
	ever_ready: bool, // reached Ready once — tells a crash apart from a failed spawn

	pipes:    LSP_Pipes,
	reader:   ^sdl.Thread,
	mutex:    ^sdl.Mutex,
	quit:     bool, // guarded by mutex; stops the reader

	inbox:    [dynamic][]u8, // owned JSON bodies; guarded by mutex

	next_id:  i64,
	pending:  map[i64]string, // request id → method (main-thread only)
	docs:     map[string]i32, // file_path → lsp document version
}

// Sparse registry; only .Jai / .Odin slots are ever populated.
@(private="file")
g_lsp_clients: [Language]^LSP_Client

// ──────────────────────────────────────────────────────────────────
// Lifecycle entry points (called from the editor)
// ──────────────────────────────────────────────────────────────────

// Called when a file finishes loading (file.odin). Spawns the server for
// its language if needed, then opens the document.
lsp_on_editor_opened :: proc(ed: ^Editor) {
	if !lsp_lang_supported(ed.language) do return
	if len(ed.file_path) == 0 || len(g_workspace_root) == 0 do return
	c := g_lsp_clients[ed.language]
	if c == nil {
		c = lsp_client_start(ed.language, g_workspace_root)
		if c == nil do return
	}
	lsp_did_open(c, ed)

	// jai-lsp needs the Jai compiler for diagnostics + typed hover, but it
	// isn't bundled (no canonical Jai install path). If it's unconfigured,
	// hint once — completion / signatures / go-to-def still work without it.
	if ed.language == .Jai && len(g_config.lsp.jai_compiler) == 0 && !g_jai_compiler_hinted {
		g_jai_compiler_hinted = true
		set_status_message("Jai diagnostics + typed hover need [lsp] jai_compiler — run :config to set it", .Info)
	}
}

@(private="file")
g_jai_compiler_hinted: bool

// Called as a pane/editor is torn down (editor.odin), before file_path is freed.
lsp_on_editor_closed :: proc(ed: ^Editor) {
	if !ed.lsp_open do return
	c := g_lsp_clients[ed.language]
	if c != nil do lsp_did_close(c, ed)
	ed.lsp_open = false
}

lsp_lang_supported :: proc(lang: Language) -> bool {
	// jai-lsp for .jai, ols for .odin. Both speak the same JSON-RPC; the
	// only real divergence is position encoding (jai-lsp negotiates utf-8,
	// ols falls back to utf-16) — handled in lsp_byte_to_pos / lsp_pos_to_byte.
	return lang == .Jai || lang == .Odin
}

// ──────────────────────────────────────────────────────────────────
// Diagnostics store (path → diagnostics), populated by publishDiagnostics
// ──────────────────────────────────────────────────────────────────

LSP_Diagnostic :: struct {
	start_line, start_char: int,
	end_line, end_char:     int,
	severity:               int, // 1 error, 2 warning, 3 info, 4 hint
	message:                string, // owned
}

@(private="file")
g_lsp_diagnostics: map[string][]LSP_Diagnostic // path → diags (owned)

lsp_diagnostics_for :: proc(path: string) -> []LSP_Diagnostic {
	if d, ok := g_lsp_diagnostics[path]; ok do return d
	return nil
}

@(private="file")
lsp_set_diagnostics :: proc(path: string, diags: []LSP_Diagnostic) {
	if old, ok := g_lsp_diagnostics[path]; ok {
		for d in old do delete(d.message)
		delete(old)
		k, _ := delete_key(&g_lsp_diagnostics, path)
		if len(k) > 0 do delete(k)
	}
	if len(diags) > 0 do g_lsp_diagnostics[strings.clone(path)] = diags
}

@(private="file")
lsp_clear_all_diagnostics :: proc() {
	for path, diags in g_lsp_diagnostics {
		for d in diags do delete(d.message)
		delete(diags)
		delete(path)
	}
	delete(g_lsp_diagnostics) // free the map backing too; re-inits on next insert
	g_lsp_diagnostics = nil
}

// ──────────────────────────────────────────────────────────────────
// Position mapping (jai-lsp negotiates utf-8 → LSP `character` == byte
// count from the line start, so this is plain byte math). The utf-16
// variant lands with ols.
// ──────────────────────────────────────────────────────────────────

@(private="file")
lsp_encoding_for :: proc(ed: ^Editor) -> LSP_Encoding {
	c := g_lsp_clients[ed.language]
	return c != nil ? c.encoding : .UTF8
}

// Decode the UTF-8 rune starting at byte `i` from the (non-contiguous) piece
// buffer. Returns the rune and its byte length (≥1, even on bad input).
@(private="file")
lsp_rune_at :: proc(ed: ^Editor, i, n: int) -> (r: rune, size: int) {
	buf: [4]u8
	j := 0
	for j < 4 && i + j < n {
		buf[j] = piece_buffer_byte_at(&ed.buffer, i + j)
		j += 1
	}
	r, size = utf8.decode_rune(buf[:j])
	if size <= 0 do size = 1
	return
}

// utf-16 code units for a rune: 2 for astral (surrogate pair), else 1.
@(private="file")
lsp_u16_units :: proc(r: rune) -> int {
	return r >= 0x10000 ? 2 : 1
}

// Byte offset → LSP (line, character). character is utf-8 byte count for
// jai-lsp; utf-16 code-unit count for ols (decode runes, sum surrogate-aware).
lsp_byte_to_pos :: proc(ed: ^Editor, pos: int) -> (line, character: int) {
	line, _ = editor_pos_to_line_col(ed, pos)
	start := editor_nth_line_start(ed, line)
	if lsp_encoding_for(ed) != .UTF16 {
		character = pos - start
		return
	}
	n := piece_buffer_len(&ed.buffer)
	i := start
	for i < pos {
		r, sz := lsp_rune_at(ed, i, n)
		character += lsp_u16_units(r)
		i += sz
	}
	return
}

// LSP (line, character) → byte offset, clamped to the line. Inverse of
// lsp_byte_to_pos for the active encoding.
lsp_pos_to_byte :: proc(ed: ^Editor, line, character: int) -> int {
	start := editor_nth_line_start(ed, line)
	end := editor_line_end(ed, start) // byte offset of the line's '\n'
	if lsp_encoding_for(ed) != .UTF16 {
		b := start + character
		if b > end do b = end
		if b < start do b = start
		return b
	}
	n := piece_buffer_len(&ed.buffer)
	i := start
	units := 0
	for i < end && units < character {
		r, sz := lsp_rune_at(ed, i, n)
		units += lsp_u16_units(r)
		i += sz
	}
	return i
}

// ──────────────────────────────────────────────────────────────────
// Client start / stop
// ──────────────────────────────────────────────────────────────────

// Directory portion of a path (no trailing slash); "" if none.
@(private="file")
lsp_dir_of :: proc(path: string) -> string {
	for i := len(path) - 1; i >= 0; i -= 1 {
		if path[i] == '/' do return path[:i]
	}
	return ""
}

@(private="file")
lsp_client_start :: proc(lang: Language, root: string) -> ^LSP_Client {
	bin, ok := lsp_resolve_binary(lang)
	if !ok do return nil

	env: [dynamic]string
	defer delete(env)
	if lang == .Jai {
		if entry := lsp_jai_entry(); len(entry) > 0 {
			append(&env, fmt.tprintf("JAI_LSP_ENTRY_FILE=%s", entry))
		}
		// jai-lsp reads JAI_COMPILER to find the type-checker (checker.jai).
		// Without it, it falls back to a bare `jai` on PATH. Setting it
		// here means no symlink / PATH tweak is needed for diagnostics +
		// rich hover.
		if len(g_config.lsp.jai_compiler) > 0 {
			append(&env, fmt.tprintf("JAI_COMPILER=%s", g_config.lsp.jai_compiler))
		}
	}

	// A Finder/Applications-launched .app inherits a stripped PATH. The
	// servers (and the compilers they shell out to — jai's linker, odin)
	// need a real PATH or typed hover / diagnostics silently fail while
	// scan-based features still work. Hand them the usual dirs, plus the
	// configured Jai compiler's own dir.
	when ODIN_OS != .Windows {
		path := "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
		if lang == .Jai && len(g_config.lsp.jai_compiler) > 0 {
			if d := lsp_dir_of(g_config.lsp.jai_compiler); len(d) > 0 {
				path = fmt.tprintf("%s:%s", d, path)
			}
		}
		append(&env, fmt.tprintf("PATH=%s", path))
	}

	pipes, spawned := lsp_spawn([]string{bin}, root, env[:])
	if !spawned {
		set_status_message(fmt.tprintf("LSP: failed to spawn %s", bin), .Error)
		return nil
	}

	c := new(LSP_Client)
	c.lang     = lang
	c.root     = strings.clone(root)
	c.state    = .Initializing
	c.encoding = .UTF16 // until the initialize response says otherwise
	c.pipes    = pipes
	c.next_id  = 1
	c.mutex    = sdl.CreateMutex()
	g_lsp_clients[lang] = c

	c.reader = sdl.CreateThread(lsp_reader_thread, "bragi-lsp", c)

	lsp_send_initialize(c)
	return c
}

lsp_shutdown_all :: proc() {
	for lang in Language {
		if g_lsp_clients[lang] != nil do lsp_client_stop(g_lsp_clients[lang])
	}
	lsp_clear_all_diagnostics()
	g_lsp_last_edit_ns = 0
}

@(private="file")
lsp_client_stop :: proc(c: ^LSP_Client) {
	if c.state == .Ready {
		id := lsp_send_request(c, "shutdown", "null")
		_ = id
		lsp_send_notification(c, "exit", "null")
	}
	sdl.LockMutex(c.mutex)
	c.quit = true
	sdl.UnlockMutex(c.mutex)
	// Closing our write end EOFs the server's stdin; the server exits,
	// which EOFs our read end and unblocks the reader's blocking read.
	lsp_pipe_close(c.pipes.stdin_fd)
	if c.reader != nil do sdl.WaitThread(c.reader, nil)
	lsp_pipe_close(c.pipes.stdout_fd)
	lsp_proc_kill(c.pipes.pid)

	g_lsp_clients[c.lang] = nil
	for _, m in c.pending do delete(m)
	delete(c.pending)
	for k in c.docs do delete(k)
	delete(c.docs)
	for b in c.inbox do delete(b)
	delete(c.inbox)
	if c.mutex != nil do sdl.DestroyMutex(c.mutex)
	delete(c.root)
	free(c)
}

// Called from set_workspace when the root changes: tear everything down
// so clients respawn lazily against the new root.
lsp_on_workspace_changed :: proc() {
	lsp_shutdown_all()
}

// ──────────────────────────────────────────────────────────────────
// Reader thread + main-loop pump
// ──────────────────────────────────────────────────────────────────

@(private="file")
lsp_reader_thread :: proc "c" (data: rawptr) -> sysc.int {
	context = runtime.default_context()
	c := cast(^LSP_Client)data

	acc: [dynamic]u8
	defer delete(acc)
	rbuf: [8192]u8

	for {
		sdl.LockMutex(c.mutex)
		quit := c.quit
		sdl.UnlockMutex(c.mutex)
		if quit do break

		n := lsp_pipe_read(c.pipes.stdout_fd, rbuf[:])
		if n <= 0 {
			// EOF or error: server is gone.
			sdl.LockMutex(c.mutex)
			c.state = .Dead
			sdl.UnlockMutex(c.mutex)
			lsp_push_wake()
			break
		}
		append(&acc, ..rbuf[:n])

		// Extract every complete frame currently buffered.
		for {
			hdr_end, found := lsp_find_header_end(acc[:])
			if !found do break
			clen, ok := lsp_parse_content_length(acc[:hdr_end])
			body_start := hdr_end + 4 // past "\r\n\r\n"
			if !ok {
				// Malformed header — drop it and resync.
				lsp_consume(&acc, body_start)
				continue
			}
			if len(acc) < body_start + clen do break // partial body
			body := make([]u8, clen)
			copy(body, acc[body_start:body_start + clen])
			sdl.LockMutex(c.mutex)
			append(&c.inbox, body)
			sdl.UnlockMutex(c.mutex)
			lsp_consume(&acc, body_start + clen)
		}
		lsp_push_wake()
	}
	return 0
}

// Drain + dispatch every queued message. Main thread, on LSP_EVENT.
lsp_pump :: proc() {
	for lang in Language {
		c := g_lsp_clients[lang]
		if c == nil do continue

		sdl.LockMutex(c.mutex)
		local := c.inbox
		c.inbox = nil
		dead := c.state == .Dead
		sdl.UnlockMutex(c.mutex)

		for body in local {
			lsp_dispatch(c, body)
			delete(body)
		}
		delete(local)

		if dead {
			name := lsp_lang_name(c.lang)
			if c.ever_ready {
				set_status_message(fmt.tprintf("%s server exited", name), .Error)
			} else {
				// Never handshook → almost always the binary wasn't found /
				// couldn't exec (the spawned child exits 127 → instant EOF).
				key := c.lang == .Jai ? "jai" : "odin"
				set_status_message(fmt.tprintf("%s failed to start — set [lsp] %s to its path, or add %s to PATH", name, key, name), .Error)
			}
			lsp_client_stop(c)
		}
	}
}

@(private="file")
lsp_dispatch :: proc(c: ^LSP_Client, body: []u8) {
	v, err := json.parse(body, parse_integers = true)
	if err != nil do return
	defer json.destroy_value(v)
	obj, ok := v.(json.Object)
	if !ok do return

	_, has_method := obj["method"]
	_, has_id := obj["id"]

	if has_id && has_method {
		// Server → client request: must reply so the server doesn't stall.
		id := lsp_obj_int(obj, "id")
		lsp_send_raw(c, transmute([]u8)fmt.tprintf(`{{"jsonrpc":"2.0","id":%d,"result":null}}`, id))
		return
	}
	if has_id {
		// Response to one of our requests.
		id := lsp_obj_int(obj, "id")
		method, found := c.pending[id]
		if found {
			lsp_route_response(c, method, obj)
			delete_key(&c.pending, id)
			delete(method)
		}
		return
	}
	// Notification.
	method := lsp_obj_str(obj, "method")
	lsp_handle_notification(c, method, obj)
}

@(private="file")
lsp_route_response :: proc(c: ^LSP_Client, method: string, obj: json.Object) {
	switch method {
	case "initialize":
		lsp_on_initialize_result(c, obj)
	case "textDocument/completion":
		completion_on_response(obj)
	case "textDocument/definition":
		lsp_definition_response(obj)
	case "textDocument/signatureHelp":
		signature_on_response(obj)
	case "textDocument/hover":
		hover_on_response(obj)
	}
}

// True when a ready server exists for `lang`.
lsp_ready :: proc(lang: Language) -> bool {
	c := g_lsp_clients[lang]
	return c != nil && c.state == .Ready
}

// Send textDocument/completion at the editor's cursor. Returns the request
// id (correlate the response by it) and whether it was sent.
lsp_completion_request :: proc(ed: ^Editor) -> (id: i64, ok: bool) {
	c := g_lsp_clients[ed.language]
	if c == nil || c.state != .Ready do return 0, false
	lsp_flush_pending_change(ed)
	line, ch := lsp_byte_to_pos(ed, ed.cursor)
	uri := lsp_path_to_uri(ed.file_path)
	params := fmt.tprintf(
		`{{"textDocument":{{"uri":"%s"}},"position":{{"line":%d,"character":%d}}}}`,
		uri, line, ch,
	)
	return lsp_send_request(c, "textDocument/completion", params), true
}

// Flush a pending full-text didChange NOW so the server sees the current
// document before a position-sensitive request. The debounced didChange
// (lsp_tick) is too slow: a request fired on the same keystroke would race
// ahead of it and hit a stale document (find_call_context etc. would miss).
lsp_flush_pending_change :: proc(ed: ^Editor) {
	c := g_lsp_clients[ed.language]
	if c == nil || c.state != .Ready || !ed.lsp_open do return
	if ed.lsp_sent_version == ed.buffer.version do return
	lsp_did_change(c, ed)
	ed.lsp_sent_version = ed.buffer.version
}

// Send a position-based request (signatureHelp / hover) at the cursor.
@(private="file")
lsp_pos_request :: proc(ed: ^Editor, method: string) -> (id: i64, ok: bool) {
	c := g_lsp_clients[ed.language]
	if c == nil || c.state != .Ready do return 0, false
	lsp_flush_pending_change(ed)
	line, ch := lsp_byte_to_pos(ed, ed.cursor)
	uri := lsp_path_to_uri(ed.file_path)
	params := fmt.tprintf(
		`{{"textDocument":{{"uri":"%s"}},"position":{{"line":%d,"character":%d}}}}`,
		uri, line, ch,
	)
	return lsp_send_request(c, method, params), true
}

lsp_signature_request :: proc(ed: ^Editor) -> (id: i64, ok: bool) {
	return lsp_pos_request(ed, "textDocument/signatureHelp")
}

// Hover at an explicit byte offset (used by Cmd-hover, where the position
// is the mouse target, not the cursor).
lsp_hover_request_at :: proc(ed: ^Editor, pos: int) -> (id: i64, ok: bool) {
	c := g_lsp_clients[ed.language]
	if c == nil || c.state != .Ready do return 0, false
	lsp_flush_pending_change(ed)
	line, ch := lsp_byte_to_pos(ed, pos)
	uri := lsp_path_to_uri(ed.file_path)
	params := fmt.tprintf(
		`{{"textDocument":{{"uri":"%s"}},"position":{{"line":%d,"character":%d}}}}`,
		uri, line, ch,
	)
	return lsp_send_request(c, "textDocument/hover", params), true
}

// Definition at an explicit byte offset (Cmd-click).
lsp_definition_request_at :: proc(ed: ^Editor, pos: int) -> bool {
	c := g_lsp_clients[ed.language]
	if c == nil || c.state != .Ready do return false
	lsp_flush_pending_change(ed)
	line, ch := lsp_byte_to_pos(ed, pos)
	uri := lsp_path_to_uri(ed.file_path)
	params := fmt.tprintf(
		`{{"textDocument":{{"uri":"%s"}},"position":{{"line":%d,"character":%d}}}}`,
		uri, line, ch,
	)
	lsp_send_request(c, "textDocument/definition", params)
	return true
}

// Send textDocument/definition at the editor's cursor (P4).
lsp_definition_request :: proc(ed: ^Editor) -> bool {
	c := g_lsp_clients[ed.language]
	if c == nil || c.state != .Ready do return false
	lsp_flush_pending_change(ed)
	line, ch := lsp_byte_to_pos(ed, ed.cursor)
	uri := lsp_path_to_uri(ed.file_path)
	params := fmt.tprintf(
		`{{"textDocument":{{"uri":"%s"}},"position":{{"line":%d,"character":%d}}}}`,
		uri, line, ch,
	)
	lsp_send_request(c, "textDocument/definition", params)
	return true
}

// Handle a definition response: location(s) → jump to the first.
@(private="file")
lsp_definition_response :: proc(obj: json.Object) {
	rv, has := obj["result"]
	if !has {
		set_status_message("no definition found", .Info)
		return
	}
	// result is Location | Location[] | LocationLink[]. Collect them all:
	// one → jump straight there; many → pop the chooser.
	locs: [dynamic]Def_Location
	locs.allocator = context.temp_allocator
	#partial switch r in rv {
	case json.Object:
		lsp_collect_location(r, &locs)
	case json.Array:
		for e in r {
			if o, ok := e.(json.Object); ok do lsp_collect_location(o, &locs)
		}
	}

	if len(locs) == 0 {
		set_status_message("no definition found", .Info)
		return
	}
	if len(locs) == 1 {
		lsp_jump_to(locs[0].path, locs[0].line, locs[0].character)
		return
	}
	def_picker_show(locs[:]) // clones into owned storage
}

// Pull (path, line, char) out of a Location or LocationLink into `out`.
// `path` aliases the still-live JSON body — callers must use or clone it
// before the dispatch frees the parse.
@(private="file")
lsp_collect_location :: proc(loc: json.Object, out: ^[dynamic]Def_Location) {
	uri := lsp_obj_str(loc, "uri")
	if uri == "" do uri = lsp_obj_str(loc, "targetUri") // LocationLink
	if uri == "" do return
	sl, sc, _, _ := lsp_range_fields(loc)
	if _, has_range := loc["range"]; !has_range {
		if tv, ht := loc["targetSelectionRange"]; ht {
			if t, ok := tv.(json.Object); ok do sl, sc, _, _ = lsp_range_fields_named(t)
		}
	}
	append(out, Def_Location{path = lsp_uri_to_path(uri), line = sl, character = sc})
}

// lsp_range_fields reads obj["range"]; this reads start/end directly off
// an already-unwrapped range object.
@(private="file")
lsp_range_fields_named :: proc(r: json.Object) -> (sl, sc, el, ec: int) {
	if sv, hs := r["start"]; hs {
		if s, ok := sv.(json.Object); ok {
			sl = int(lsp_obj_int(s, "line"))
			sc = int(lsp_obj_int(s, "character"))
		}
	}
	if ev, he := r["end"]; he {
		if e, ok := ev.(json.Object); ok {
			el = int(lsp_obj_int(e, "line"))
			ec = int(lsp_obj_int(e, "character"))
		}
	}
	return
}

// Open `path` (if not already active) and move the cursor to (line,char).
lsp_jump_to :: proc(path: string, line, character: int) {
	cur := active_editor()
	if !lsp_path_eq(cur.file_path, path) {
		p := strings.clone(path, context.temp_allocator)
		open_file_smart(p)
	}
	ed := active_editor()
	off := lsp_pos_to_byte(ed, line, character)
	ed.cursor = off
	ed.anchor = off
	vim_scroll_cursor_to(ed, 1) // center the target line
}

@(private="file")
lsp_on_initialize_result :: proc(c: ^LSP_Client, obj: json.Object) {
	enc := "utf-16"
	cap_compl, cap_def, cap_hover: bool
	if rv, has := obj["result"]; has {
		if res, ok := rv.(json.Object); ok {
			if cv, hc := res["capabilities"]; hc {
				if caps, ok2 := cv.(json.Object); ok2 {
					if e, he := caps["positionEncoding"]; he {
						if s, ok3 := e.(json.String); ok3 do enc = string(s)
					}
					cap_compl = "completionProvider" in caps
					cap_def   = "definitionProvider" in caps
					cap_hover = "hoverProvider" in caps
				}
			}
		}
	}
	c.encoding   = enc == "utf-8" ? .UTF8 : .UTF16
	c.state      = .Ready
	c.ever_ready = true
	lsp_send_notification(c, "initialized", "{}")

	fmt.eprintfln(
		"LSP[%s] ready: encoding=%s completion=%v definition=%v hover=%v",
		lsp_lang_name(c.lang), enc, cap_compl, cap_def, cap_hover,
	)

	// Open every already-loaded matching document.
	for &ed in g_editors {
		if ed.language == c.lang && len(ed.file_path) > 0 && !ed.lsp_open {
			lsp_did_open(c, &ed)
		}
	}
}

@(private="file")
lsp_handle_notification :: proc(c: ^LSP_Client, method: string, obj: json.Object) {
	switch method {
	case "textDocument/publishDiagnostics":
		pv, has := obj["params"]
		if !has do return
		p, ok := pv.(json.Object)
		if !ok do return
		path := lsp_uri_to_path(lsp_obj_str(p, "uri"))

		diags: [dynamic]LSP_Diagnostic
		if dv, hd := p["diagnostics"]; hd {
			if arr, ok2 := dv.(json.Array); ok2 {
				for item in arr {
					d, ok3 := item.(json.Object)
					if !ok3 do continue
					sl, sc, el, ec := lsp_range_fields(d)
					append(&diags, LSP_Diagnostic{
						start_line = sl, start_char = sc,
						end_line   = el, end_char   = ec,
						severity   = int(lsp_obj_int(d, "severity")),
						message    = strings.clone(lsp_obj_str(d, "message")),
					})
				}
			}
		}
		lsp_set_diagnostics(path, diags[:] if len(diags) > 0 else nil)
		if len(diags) == 0 do delete(diags)

	case "window/logMessage", "window/showMessage":
		// Server-side logs (ols/jai-lsp emit startup + error notes here).
		// Echo to the console; surface error/warning showMessages in the bar.
		pv, has := obj["params"]
		if !has do return
		p, ok := pv.(json.Object)
		if !ok do return
		msg := lsp_obj_str(p, "message")
		typ := int(lsp_obj_int(p, "type")) // 1=error 2=warn 3=info 4=log
		if len(msg) > 0 {
			fmt.eprintfln("LSP[%s] %s", lsp_lang_name(c.lang), msg)
			if method == "window/showMessage" && typ <= 2 {
				set_status_message(fmt.tprintf("%s: %s", lsp_lang_name(c.lang), msg), typ == 1 ? .Error : .Info)
			}
		}
	}
}

// Pull range.start.{line,character} + range.end.{line,character} out of a
// diagnostic / location object.
@(private="file")
lsp_range_fields :: proc(obj: json.Object) -> (sl, sc, el, ec: int) {
	if rv, has := obj["range"]; has {
		if r, ok := rv.(json.Object); ok {
			if sv, hs := r["start"]; hs {
				if s, ok2 := sv.(json.Object); ok2 {
					sl = int(lsp_obj_int(s, "line"))
					sc = int(lsp_obj_int(s, "character"))
				}
			}
			if ev, he := r["end"]; he {
				if e, ok2 := ev.(json.Object); ok2 {
					el = int(lsp_obj_int(e, "line"))
					ec = int(lsp_obj_int(e, "character"))
				}
			}
		}
	}
	return
}

// ──────────────────────────────────────────────────────────────────
// didChange (debounced, full text) + didSave
// ──────────────────────────────────────────────────────────────────

@(private="file")
g_lsp_last_edit_ns: i64

LSP_DEBOUNCE_NS :: i64(250_000_000) // 250 ms

// Called from the editor's edit chokepoints (editor.odin). Cheap.
lsp_note_edit :: proc() {
	g_lsp_last_edit_ns = i64(sdl.GetTicksNS())
}

// Called once per main-loop iteration. After the user pauses typing,
// flush a full-text didChange for every changed open document.
lsp_tick :: proc() {
	if g_lsp_last_edit_ns == 0 do return
	if i64(sdl.GetTicksNS()) - g_lsp_last_edit_ns < LSP_DEBOUNCE_NS do return
	g_lsp_last_edit_ns = 0
	for &ed in g_editors {
		c := g_lsp_clients[ed.language]
		if c == nil || c.state != .Ready || !ed.lsp_open do continue
		if ed.lsp_sent_version == ed.buffer.version do continue
		lsp_did_change(c, &ed)
		ed.lsp_sent_version = ed.buffer.version
	}
}

@(private="file")
lsp_did_change :: proc(c: ^LSP_Client, ed: ^Editor) {
	ver := c.docs[ed.file_path] + 1
	c.docs[ed.file_path] = ver
	text := piece_buffer_to_string(&ed.buffer, context.temp_allocator)
	uri  := lsp_path_to_uri(ed.file_path)
	params := fmt.tprintf(
		`{{"textDocument":{{"uri":"%s","version":%d}},"contentChanges":[{{"text":"%s"}}]}}`,
		uri, ver, lsp_json_escape(text),
	)
	lsp_send_notification(c, "textDocument/didChange", params)
}

// If the cursor sits inside a diagnostic range, show its message in the
// status bar. Called on cursor move from the main loop.
lsp_status_at_cursor :: proc(ed: ^Editor) {
	if !lsp_lang_supported(ed.language) || len(ed.file_path) == 0 do return
	diags := lsp_diagnostics_for(ed.file_path)
	if len(diags) == 0 do return
	for d in diags {
		lo := lsp_pos_to_byte(ed, d.start_line, d.start_char)
		hi := lsp_pos_to_byte(ed, d.end_line, d.end_char)
		if ed.cursor >= lo && ed.cursor <= hi {
			kind := d.severity == 1 ? Status_Kind.Error : Status_Kind.Info
			set_status_message(d.message, kind)
			return
		}
	}
}

lsp_on_editor_saved :: proc(ed: ^Editor) {
	if !ed.lsp_open do return
	c := g_lsp_clients[ed.language]
	if c == nil || c.state != .Ready do return
	uri := lsp_path_to_uri(ed.file_path)
	lsp_send_notification(c, "textDocument/didSave", fmt.tprintf(`{{"textDocument":{{"uri":"%s"}}}}`, uri))
}

// ──────────────────────────────────────────────────────────────────
// Document sync
// ──────────────────────────────────────────────────────────────────

@(private="file")
lsp_did_open :: proc(c: ^LSP_Client, ed: ^Editor) {
	if c.state != .Ready do return // flushed after initialize completes
	if ed.lsp_open do return
	text := piece_buffer_to_string(&ed.buffer, context.temp_allocator)
	uri  := lsp_path_to_uri(ed.file_path)
	c.docs[strings.clone(ed.file_path)] = 1
	ed.lsp_open = true
	params := fmt.tprintf(
		`{{"textDocument":{{"uri":"%s","languageId":"%s","version":1,"text":"%s"}}}}`,
		uri, lsp_language_id(c.lang), lsp_json_escape(text),
	)
	lsp_send_notification(c, "textDocument/didOpen", params)
}

@(private="file")
lsp_did_close :: proc(c: ^LSP_Client, ed: ^Editor) {
	uri := lsp_path_to_uri(ed.file_path)
	params := fmt.tprintf(`{{"textDocument":{{"uri":"%s"}}}}`, uri)
	lsp_send_notification(c, "textDocument/didClose", params)
	k, _ := delete_key(&c.docs, ed.file_path)
	if len(k) > 0 do delete(k)
}

// Drop the first `n` bytes from the reader's accumulator.
@(private="file")
lsp_consume :: proc(acc: ^[dynamic]u8, n: int) {
	if n <= 0 do return
	if n >= len(acc) {
		clear(acc)
		return
	}
	copy(acc[:], acc[n:])
	resize(acc, len(acc) - n)
}

// ──────────────────────────────────────────────────────────────────
// JSON-RPC framing / send
// ──────────────────────────────────────────────────────────────────

@(private="file")
lsp_send_raw :: proc(c: ^LSP_Client, body: []u8) {
	header := fmt.tprintf("Content-Length: %d\r\n\r\n", len(body))
	lsp_pipe_write(c.pipes.stdin_fd, transmute([]u8)header)
	lsp_pipe_write(c.pipes.stdin_fd, body)
}

@(private="file")
lsp_send_notification :: proc(c: ^LSP_Client, method: string, params_json: string) {
	msg := fmt.tprintf(`{{"jsonrpc":"2.0","method":"%s","params":%s}}`, method, params_json)
	lsp_send_raw(c, transmute([]u8)msg)
}

@(private="file")
lsp_send_request :: proc(c: ^LSP_Client, method: string, params_json: string) -> i64 {
	id := c.next_id
	c.next_id += 1
	c.pending[id] = strings.clone(method)
	msg := fmt.tprintf(`{{"jsonrpc":"2.0","id":%d,"method":"%s","params":%s}}`, id, method, params_json)
	lsp_send_raw(c, transmute([]u8)msg)
	return id
}

@(private="file")
lsp_send_initialize :: proc(c: ^LSP_Client) {
	uri  := lsp_path_to_uri(c.root)
	name := lsp_json_escape(path_basename(c.root))
	params := fmt.tprintf(
		`{{"processId":null,"rootUri":"%s","workspaceFolders":[{{"uri":"%s","name":"%s"}}],"capabilities":{{"general":{{"positionEncodings":["utf-8","utf-16"]}},"textDocument":{{"synchronization":{{"didSave":true}},"completion":{{}},"definition":{{}},"hover":{{"contentFormat":["plaintext","markdown"]}},"publishDiagnostics":{{}}}},"workspace":{{"workspaceFolders":true,"configuration":true}}}}}}`,
		uri, uri, name,
	)
	lsp_send_request(c, "initialize", params)
}

// ──────────────────────────────────────────────────────────────────
// Helpers
// ──────────────────────────────────────────────────────────────────

@(private="file")
lsp_resolve_binary :: proc(lang: Language) -> (path: string, ok: bool) {
	override := lang == .Jai ? g_config.lsp.jai_path : g_config.lsp.odin_path
	if len(override) > 0 do return strings.clone(override, context.temp_allocator), true

	name := lang == .Jai ? "jai-lsp" : "ols"
	when ODIN_OS == .Windows do name = fmt.tprintf("%s.exe", name)

	base := sdl.GetBasePath()
	if base != nil {
		b := string(base)
		if p, found := lsp_try_dir(b, name, lang); found do return p, true
		// macOS: SDL_GetBasePath returns Contents/Resources/, but the main
		// binary AND the bundled servers live in the Contents/MacOS/ sibling.
		// Check it, or a packaged .app never finds its own helpers.
		when ODIN_OS == .Darwin {
			marker := "Contents/Resources/"
			if strings.has_suffix(b, marker) {
				macos := fmt.tprintf("%sContents/MacOS/", b[:len(b) - len(marker)])
				if p, found := lsp_try_dir(macos, name, lang); found do return p, true
			}
		}
	}
	// Fall back to PATH (execvp resolves a bare name).
	return strings.clone(name, context.temp_allocator), true
}

// Look for `name` (clean bundled name) or the vendored arch-suffixed binary
// inside `dir`. Returns the found path (temp-allocated) and whether it hit.
@(private="file")
lsp_try_dir :: proc(dir, name: string, lang: Language) -> (string, bool) {
	cand := fmt.tprintf("%s%s", dir, name)
	if os.exists(cand) do return cand, true
	if vp := lsp_vendored_path(lang, dir); len(vp) > 0 && os.exists(vp) do return vp, true
	return "", false
}

// Path to the vendored, arch-suffixed server binary relative to `base` (the
// running binary's dir). Upstream names them inconsistently, so spell each
// out per platform. "" when there's no known build for this OS.
@(private="file")
lsp_vendored_path :: proc(lang: Language, base: string) -> string {
	when ODIN_OS == .Darwin {
		arch := ODIN_ARCH == .arm64 ? "arm64" : "x64"
		if lang == .Jai {
			return fmt.tprintf("%svendor/jai-lsp/jai-lsp-darwin-%s", base, arch)
		}
		return fmt.tprintf("%svendor/odin-lsp/ols-%s-darwin", base, arch)
	} else when ODIN_OS == .Linux {
		arch := ODIN_ARCH == .arm64 ? "arm64" : "x64"
		if lang == .Jai {
			return fmt.tprintf("%svendor/jai-lsp/jai-lsp-linux-%s", base, arch)
		}
		return fmt.tprintf("%svendor/odin-lsp/ols-%s-linux", base, arch)
	} else when ODIN_OS == .Windows {
		if lang == .Jai {
			return fmt.tprintf("%svendor\\jai-lsp\\jai-lsp-windows-x64.exe", base)
		}
		return fmt.tprintf("%svendor\\odin-lsp\\ols-x64-windows.exe", base)
	} else {
		return ""
	}
}

// The jai-lsp entry file (JAI_LSP_ENTRY_FILE). Only set when the user
// EXPLICITLY configures it ([lsp] jai_entry). We deliberately do NOT
// auto-detect a root build.jai/first.jai/main.jai: jai-lsp type-checks
// the entry file regardless of which file you're editing, so forcing the
// wrong one leaves its AST not covering the open file → terse hovers /
// stale diagnostics. Unset (the VS Code extension's default) lets jai-lsp
// compile the open file / auto-detect a per-file main, which is what
// makes cross-file hover + definition resolve.
@(private="file")
lsp_jai_entry :: proc() -> string {
	return g_config.lsp.jai_entry
}

@(private="file")
lsp_language_id :: proc(lang: Language) -> string {
	return lang == .Jai ? "jai" : "odin"
}

@(private="file")
lsp_lang_name :: proc(lang: Language) -> string {
	return lang == .Jai ? "jai-lsp" : "ols"
}

// Status-bar indicator for the active editor's language server. `show` is
// false for languages with no LSP support (so the chrome stays clean).
// Filled bullet = a live server (colored by state); hollow = supported but
// not running.
lsp_status_text :: proc(ed: ^Editor) -> (text: string, color: sdl.Color, show: bool) {
	if !lsp_lang_supported(ed.language) do return "", {}, false
	name := lsp_lang_name(ed.language)
	c := g_lsp_clients[ed.language]
	if c == nil do return name, g_theme.status_dim_color, true
	switch c.state {
	case .Initializing:
		return name, g_theme.status_warning_color, true
	case .Ready:
		return name, g_theme.string_color, true
	case .Dead:
		return name, g_theme.status_error_color, true
	}
	return "", {}, false
}

// Stop the server for `lang` (if running) and mark its docs closed so a
// later `:lsp start` re-opens them.
lsp_stop :: proc(lang: Language) {
	c := g_lsp_clients[lang]
	if c == nil do return
	lsp_client_stop(c)
	for &ed in g_editors {
		if ed.language == lang do ed.lsp_open = false
	}
	set_status_message(fmt.tprintf("%s stopped", lsp_lang_name(lang)), .Info)
}

// Restart the server for `lang`: tear the current one down and re-open every
// document of that language (the first re-open respawns it). Use after a
// crash, or to pick up a changed compiler/entry config.
lsp_restart :: proc(lang: Language) {
	if !lsp_lang_supported(lang) {
		set_status_message("no LSP for this file type", .Info)
		return
	}
	if c := g_lsp_clients[lang]; c != nil do lsp_client_stop(c)
	for &ed in g_editors {
		if ed.language != lang do continue
		ed.lsp_open = false
		lsp_on_editor_opened(&ed)
	}
	set_status_message(fmt.tprintf("%s restarted", lsp_lang_name(lang)), .Info)
}

@(private="file")
lsp_push_wake :: proc() {
	ev: sdl.Event
	ev.user.type = .USER
	ev.user.code = LSP_EVENT
	_ = sdl.PushEvent(&ev)
}

// file:///abs/path. Temp-allocated.
@(private="file")
lsp_path_to_uri :: proc(path: string) -> string {
	when ODIN_OS == .Windows {
		slashed, _ := strings.replace_all(path, "\\", "/", context.temp_allocator)
		return fmt.tprintf("file:///%s", slashed)
	} else {
		return fmt.tprintf("file://%s", path)
	}
}

lsp_uri_to_path :: proc(uri: string) -> string {
	s := uri
	if strings.has_prefix(s, "file://") do s = s[7:]
	// file:// URIs are percent-encoded (RFC 3986): a definition landing in
	// a path with a space (`C:\Program Files\...`, the Jai modules dir) or
	// other reserved char arrives as `%20` / `%3A`. Decode before we hand
	// it to the file loader, or those targets silently fail to open.
	s = lsp_percent_decode(s)
	when ODIN_OS == .Windows {
		// Standard form is file:///C:/... → "/C:/..."; drop the slash that
		// precedes the drive letter, then make separators native so the
		// result both matches ed.file_path and opens reliably.
		if len(s) >= 3 && s[0] == '/' && lsp_is_alpha(s[1]) && s[2] == ':' {
			s = s[1:]
		}
		s, _ = strings.replace_all(s, "/", "\\", context.temp_allocator)
	}
	return s
}

// Decode %XX escapes. Returns the input unchanged (no copy) when there's
// nothing to decode — the common case. Temp-allocated otherwise.
@(private="file")
lsp_percent_decode :: proc(s: string) -> string {
	if strings.index_byte(s, '%') < 0 do return s
	b := strings.builder_make(context.temp_allocator)
	i := 0
	for i < len(s) {
		if s[i] == '%' && i + 2 < len(s) {
			hi := lsp_hex_val(s[i + 1])
			lo := lsp_hex_val(s[i + 2])
			if hi >= 0 && lo >= 0 {
				strings.write_byte(&b, u8(hi * 16 + lo))
				i += 3
				continue
			}
		}
		strings.write_byte(&b, s[i])
		i += 1
	}
	return strings.to_string(b)
}

@(private="file")
lsp_hex_val :: proc(c: u8) -> int {
	switch c {
	case '0' ..= '9': return int(c - '0')
	case 'a' ..= 'f': return int(c - 'a') + 10
	case 'A' ..= 'F': return int(c - 'A') + 10
	}
	return -1
}

@(private="file")
lsp_is_alpha :: proc(c: u8) -> bool {
	return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
}

// Same file? On Windows compare case-insensitively and after separator
// normalization — the server may hand back a lowercased drive or `/`
// separators that still name the already-open document.
lsp_path_eq :: proc(a, b: string) -> bool {
	when ODIN_OS == .Windows {
		na, _ := strings.replace_all(a, "/", "\\", context.temp_allocator)
		nb, _ := strings.replace_all(b, "/", "\\", context.temp_allocator)
		return strings.equal_fold(na, nb)
	} else {
		return a == b
	}
}

lsp_obj_str :: proc(obj: json.Object, key: string) -> string {
	if v, has := obj[key]; has {
		if s, ok := v.(json.String); ok do return string(s)
	}
	return ""
}

lsp_obj_int :: proc(obj: json.Object, key: string) -> i64 {
	if v, has := obj[key]; has {
		#partial switch n in v {
		case json.Integer: return i64(n)
		case json.Float:   return i64(n)
		}
	}
	return 0
}

// Escape a string for embedding in a JSON string literal. Temp-allocated.
@(private="file")
lsp_json_escape :: proc(s: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	for i in 0 ..< len(s) {
		ch := s[i]
		switch ch {
		case '"':  strings.write_string(&b, "\\\"")
		case '\\': strings.write_string(&b, "\\\\")
		case '\n': strings.write_string(&b, "\\n")
		case '\r': strings.write_string(&b, "\\r")
		case '\t': strings.write_string(&b, "\\t")
		case '\b': strings.write_string(&b, "\\b")
		case '\f': strings.write_string(&b, "\\f")
		case:
			if ch < 0x20 {
				strings.write_string(&b, fmt.tprintf("\\u%04x", ch))
			} else {
				strings.write_byte(&b, ch)
			}
		}
	}
	return strings.to_string(b)
}

// Header framing helpers (operate on the reader's byte accumulator).
@(private="file")
lsp_find_header_end :: proc(buf: []u8) -> (idx: int, found: bool) {
	for i in 0 ..< len(buf) - 3 {
		if buf[i] == '\r' && buf[i + 1] == '\n' && buf[i + 2] == '\r' && buf[i + 3] == '\n' {
			return i, true
		}
	}
	return 0, false
}

@(private="file")
lsp_parse_content_length :: proc(header: []u8) -> (n: int, ok: bool) {
	// Scan header lines for "Content-Length:".
	s := string(header)
	key := "Content-Length:"
	idx := strings.index(s, key)
	if idx < 0 do return 0, false
	rest := strings.trim_space(s[idx + len(key):])
	// Take leading digits.
	end := 0
	for end < len(rest) && rest[end] >= '0' && rest[end] <= '9' do end += 1
	if end == 0 do return 0, false
	val := 0
	for i in 0 ..< end do val = val * 10 + int(rest[i] - '0')
	return val, true
}
