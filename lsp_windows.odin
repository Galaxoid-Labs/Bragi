#+build windows
package bragi

import "core:os"
import "core:strings"
import win "core:sys/windows"

// Windows LSP spawn: a child process whose stdin/stdout are wired to PLAIN
// anonymous pipes (NOT a ConPTY — language servers speak raw JSON-RPC, not
// terminal control codes, so a pseudo-console would mangle the framing).
// The Windows analogue of lsp_posix.odin; same symbol set so lsp.odin stays
// platform-neutral.
//
// LSP_Pipes (defined in lsp.odin) carries plain `int` fields; we stash
// Win32 HANDLEs in them:
//   pid       → the child process HANDLE (uintptr) — used by lsp_proc_kill
//   stdin_fd  → our write end of the child's stdin pipe
//   stdout_fd → our read  end of the child's stdout pipe
//
// stderr is sent to the NUL device, not merged into stdout: ols / jai-lsp
// log to stderr, and folding that into stdout would corrupt the
// Content-Length frames (and an unread stderr pipe would eventually fill
// and deadlock the server).

@(private="file")
INVALID_HANDLE :: win.INVALID_HANDLE_VALUE

// Spawn `argv` with `cwd` and extra `env` entries ("KEY=VALUE"). On Windows
// the only entries lsp_client_start passes are JAI_LSP_ENTRY_FILE /
// JAI_COMPILER; we set them in our own environment so the child inherits
// them (CreateProcessW with a NULL block hands the child a copy of ours).
// These vars don't affect Bragi itself, so the global set is harmless and
// re-setting on a server restart just overwrites with the current config.
lsp_spawn :: proc(argv: []string, cwd: string, env: []string) -> (p: LSP_Pipes, ok: bool) {
	if len(argv) == 0 do return {}, false

	for kv in env {
		if eq := strings.index_byte(kv, '='); eq >= 0 {
			name := win.utf8_to_wstring(kv[:eq], context.temp_allocator)
			val  := win.utf8_to_wstring(kv[eq + 1:], context.temp_allocator)
			win.SetEnvironmentVariableW(name, val)
		}
	}

	// Inheritable pipe ends: the child needs to inherit its own stdin-read
	// and stdout-write ends. We then clear inheritance on OUR ends so they
	// don't leak into the child (and so closing our stdin-write actually
	// EOFs the child's stdin — a duplicated inheritable copy would keep it
	// open).
	sa := win.SECURITY_ATTRIBUTES{
		nLength        = size_of(win.SECURITY_ATTRIBUTES),
		bInheritHandle = win.TRUE,
	}

	child_stdin_read, our_stdin_write: win.HANDLE
	if !win.CreatePipe(&child_stdin_read, &our_stdin_write, &sa, 0) {
		return {}, false
	}
	defer if !ok {
		win.CloseHandle(child_stdin_read); win.CloseHandle(our_stdin_write)
	}

	child_stdout_write, our_stdout_read: win.HANDLE
	if !win.CreatePipe(&our_stdout_read, &child_stdout_write, &sa, 0) {
		return {}, false
	}
	defer if !ok {
		win.CloseHandle(our_stdout_read); win.CloseHandle(child_stdout_write)
	}

	// Our ends must NOT be inheritable.
	win.SetHandleInformation(our_stdin_write, win.HANDLE_FLAG_INHERIT, 0)
	win.SetHandleInformation(our_stdout_read, win.HANDLE_FLAG_INHERIT, 0)

	// Child stderr → NUL (inheritable) by default: discards server logs and
	// keeps the JSON-RPC stdout stream clean. For diagnostics, set
	// BRAGI_LSP_LOG=<path> and the server's stderr is appended to that file
	// instead (CREATE_ALWAYS would truncate per spawn; OPEN_ALWAYS + seek-to-end
	// keeps a session's worth across restarts).
	log_path := os.get_env("BRAGI_LSP_LOG", context.temp_allocator)
	stderr_target: win.wstring = win.utf8_to_wstring("NUL", context.temp_allocator)
	open_disp: win.DWORD = win.OPEN_EXISTING
	if len(log_path) > 0 {
		stderr_target = win.utf8_to_wstring(log_path, context.temp_allocator)
		open_disp = win.OPEN_ALWAYS
	}
	child_stderr := win.CreateFileW(
		stderr_target,
		win.FILE_APPEND_DATA,
		win.FILE_SHARE_WRITE | win.FILE_SHARE_READ,
		&sa, // inheritable
		open_disp,
		win.FILE_ATTRIBUTE_NORMAL,
		nil,
	)
	defer if child_stderr != INVALID_HANDLE do win.CloseHandle(child_stderr)

	si: win.STARTUPINFOW
	si.cb         = size_of(win.STARTUPINFOW)
	si.dwFlags    = win.STARTF_USESTDHANDLES
	si.hStdInput  = child_stdin_read
	si.hStdOutput = child_stdout_write
	si.hStdError  = child_stderr if child_stderr != INVALID_HANDLE else child_stdout_write

	// CreateProcessW may write into lpCommandLine, so it must be writable.
	cmdline   := build_lsp_command_line(argv, context.temp_allocator)
	cmdline_w := win.utf8_to_wstring(cmdline, context.temp_allocator)
	cwd_w: win.wstring = nil
	if len(cwd) > 0 do cwd_w = win.utf8_to_wstring(cwd, context.temp_allocator)

	pi: win.PROCESS_INFORMATION
	// bInheritHandles=TRUE so the three std handles reach the child.
	// CREATE_NO_WINDOW keeps the GUI app from flashing a console for the
	// server. NULL environment → child inherits our (just-augmented) env.
	create_ok := win.CreateProcessW(
		nil,
		cmdline_w,
		nil, nil,
		win.TRUE,
		win.CREATE_NO_WINDOW,
		nil,
		cwd_w,
		&si,
		&pi,
	)
	if !create_ok do return {}, false

	// Drop the child-side handle copies in our process: we don't need them,
	// and keeping stdout_write open would prevent our reader from ever
	// seeing EOF when the child exits.
	win.CloseHandle(child_stdin_read);  child_stdin_read  = INVALID_HANDLE
	win.CloseHandle(child_stdout_write); child_stdout_write = INVALID_HANDLE
	win.CloseHandle(pi.hThread)

	p = LSP_Pipes{
		pid       = int(uintptr(pi.hProcess)),
		stdin_fd  = int(uintptr(our_stdin_write)),
		stdout_fd = int(uintptr(our_stdout_read)),
	}
	ok = true
	return
}

// Quote argv tokens with the C-runtime rules CreateProcessW's child parses.
// Same logic as pty_windows.odin's win_quote_arg, duplicated here because
// that one is @(private="file").
@(private="file")
build_lsp_command_line :: proc(argv: []string, allocator := context.temp_allocator) -> string {
	b := strings.builder_make(allocator)
	for s, i in argv {
		if i > 0 do strings.write_byte(&b, ' ')
		needs_quote := len(s) == 0
		for r in s {
			if r == ' ' || r == '\t' || r == '"' || r == '\n' || r == '\v' {
				needs_quote = true
				break
			}
		}
		if !needs_quote {
			strings.write_string(&b, s)
			continue
		}
		strings.write_byte(&b, '"')
		bs_run := 0
		for j in 0 ..< len(s) {
			c := s[j]
			if c == '\\' {
				bs_run += 1
			} else if c == '"' {
				for _ in 0 ..< bs_run do strings.write_byte(&b, '\\')
				strings.write_byte(&b, '\\')
				strings.write_byte(&b, '"')
				bs_run = 0
			} else {
				bs_run = 0
				strings.write_byte(&b, c)
			}
		}
		for _ in 0 ..< bs_run do strings.write_byte(&b, '\\')
		strings.write_byte(&b, '"')
	}
	return strings.to_string(b)
}

// Blocking read. >0 bytes, -2 EOF (child closed stdout / exited), -1 error.
// A broken pipe (child gone) makes ReadFile return FALSE — report it as EOF
// so the reader thread exits cleanly, matching the POSIX n==0 case.
lsp_pipe_read :: proc(fd: int, buf: []u8) -> int {
	h := win.HANDLE(uintptr(fd))
	if h == INVALID_HANDLE do return -2
	read: win.DWORD
	if !win.ReadFile(h, raw_data(buf), win.DWORD(len(buf)), &read, nil) do return -2
	if read == 0 do return -2
	return int(read)
}

// Write all of `data`; false on error.
lsp_pipe_write :: proc(fd: int, data: []u8) -> bool {
	h := win.HANDLE(uintptr(fd))
	if h == INVALID_HANDLE do return false
	sent := 0
	for sent < len(data) {
		written: win.DWORD
		if !win.WriteFile(h, raw_data(data[sent:]), win.DWORD(len(data) - sent), &written, nil) {
			return false
		}
		if written == 0 do return false
		sent += int(written)
	}
	return true
}

lsp_pipe_close :: proc(fd: int) {
	h := win.HANDLE(uintptr(fd))
	if h != INVALID_HANDLE && h != nil do win.CloseHandle(h)
}

// Terminate + close the child process handle. Closing our stdin (in
// lsp_client_stop) already EOFs the server so it exits on its own;
// TerminateProcess is the backstop, then we release the HANDLE.
lsp_proc_kill :: proc(pid: int) {
	h := win.HANDLE(uintptr(pid))
	if h == INVALID_HANDLE || h == nil do return
	_ = win.WaitForSingleObject(h, 100)
	_ = win.TerminateProcess(h, 0)
	win.CloseHandle(h)
}
