#+build windows
package bragi

import "core:strings"
import win "core:sys/windows"

// Windows ConPTY (`CreatePseudoConsole`, Win10 1809+) implementation
// for the platform-neutral PTY interface in pty.odin.
//
// `pty.odin` keeps `PTY.hpc / master_in / master_out / child` typed as
// `rawptr` so it doesn't need to import `core:sys/windows` itself.
// We cast back to `win.HANDLE` here, where the Windows-only build tag
// makes that import legal.

// `STARTUPINFOEXW` is `STARTUPINFOW` followed by an attribute-list
// pointer. CreateProcessW takes ^STARTUPINFOW; we point it at the
// embedded StartupInfo and set its `cb` to size_of(STARTUPINFOEXW)
// so the OS knows it can read past the base struct into the extension.
@(private="file")
STARTUPINFOEXW :: struct {
	StartupInfo:     win.STARTUPINFOW,
	lpAttributeList: rawptr, // LPPROC_THREAD_ATTRIBUTE_LIST (opaque)
}

// ProcThreadAttributeValue(22, FALSE, TRUE, FALSE):
//   number=22, thread=0, input=PROC_THREAD_ATTRIBUTE_INPUT(0x20000), additive=0.
// Tells UpdateProcThreadAttribute the value is an HPCON the child
// inherits as its console.
@(private="file")
PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE :: uintptr(0x00020016)

foreign import kernel32 "system:Kernel32.lib"

@(default_calling_convention="system")
foreign kernel32 {
	// HRESULT — S_OK on success.
	CreatePseudoConsole :: proc(size: win.COORD, hInput: win.HANDLE, hOutput: win.HANDLE, dwFlags: win.DWORD, phPC: ^win.HANDLE) -> win.HRESULT ---
	ResizePseudoConsole :: proc(hPC: win.HANDLE, size: win.COORD) -> win.HRESULT ---
	ClosePseudoConsole  :: proc(hPC: win.HANDLE) ---

	// Two-call pattern: first call with NULL list returns required size
	// in *lpSize and "fails" with ERROR_INSUFFICIENT_BUFFER; we
	// HeapAlloc that many bytes and call again.
	InitializeProcThreadAttributeList :: proc(lpAttributeList: rawptr, dwAttributeCount: win.DWORD, dwFlags: win.DWORD, lpSize: ^win.SIZE_T) -> win.BOOL ---
	UpdateProcThreadAttribute         :: proc(lpAttributeList: rawptr, dwFlags: win.DWORD, Attribute: uintptr, lpValue: rawptr, cbSize: win.SIZE_T, lpPreviousValue: rawptr, lpReturnSize: ^win.SIZE_T) -> win.BOOL ---
	DeleteProcThreadAttributeList     :: proc(lpAttributeList: rawptr) ---
}

// Quote a single argv token using the C runtime's parsing rules
// (https://learn.microsoft.com/cpp/cpp/main-function-command-line-args).
// Bare token if no whitespace / quotes; otherwise wrap in double quotes
// and escape internal `"` plus any `\` runs that abut a quote. Most
// real-world shell paths don't need this, but we're robust to spaces in
// `Program Files`-style paths.
@(private="file")
win_quote_arg :: proc(b: ^strings.Builder, s: string) {
	needs_quote := false
	for r in s {
		if r == ' ' || r == '\t' || r == '"' || r == '\n' || r == '\v' {
			needs_quote = true
			break
		}
	}
	if !needs_quote && len(s) > 0 {
		strings.write_string(b, s)
		return
	}
	strings.write_byte(b, '"')
	bs_run := 0
	for i in 0 ..< len(s) {
		c := s[i]
		if c == '\\' {
			bs_run += 1
		} else if c == '"' {
			// Each `\` before the `"` doubles, plus one more for `\"`.
			for _ in 0 ..< bs_run do strings.write_byte(b, '\\')
			strings.write_byte(b, '\\')
			strings.write_byte(b, '"')
			bs_run = 0
		} else {
			bs_run = 0
			strings.write_byte(b, c)
		}
	}
	// Trailing backslashes have to double too, otherwise the closing
	// quote turns the last `\` into `\"` to the parser.
	for _ in 0 ..< bs_run do strings.write_byte(b, '\\')
	strings.write_byte(b, '"')
}

@(private="file")
build_command_line :: proc(argv: []string, allocator := context.temp_allocator) -> string {
	b := strings.builder_make(allocator)
	for s, i in argv {
		if i > 0 do strings.write_byte(&b, ' ')
		win_quote_arg(&b, s)
	}
	return strings.to_string(b)
}

pty_spawn_windows :: proc(argv: []string, cols, rows: int, cwd: string) -> (pty: PTY, ok: bool) {
	if len(argv) == 0 do return {}, false

	// Two anonymous pipes. Default SECURITY_ATTRIBUTES (NULL) gives
	// non-inheritable handles, which is what we want — ConPTY does its
	// own internal duplication via PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE,
	// so the child never sees these specific HANDLEs.
	input_pty_read, input_our_write: win.HANDLE
	if !win.CreatePipe(&input_pty_read, &input_our_write, nil, 0) {
		return {}, false
	}
	defer if !ok do win.CloseHandle(input_our_write)

	output_our_read, output_pty_write: win.HANDLE
	if !win.CreatePipe(&output_our_read, &output_pty_write, nil, 0) {
		win.CloseHandle(input_pty_read)
		return {}, false
	}
	defer if !ok do win.CloseHandle(output_our_read)

	hpc: win.HANDLE
	hr := CreatePseudoConsole(
		win.COORD{X = i16(cols), Y = i16(rows)},
		input_pty_read,
		output_pty_write,
		0,
		&hpc,
	)
	// ConPTY duplicates the pty-side handles internally; closing them
	// in our process is required so the child gets EOF when ConPTY
	// closes its copies during shutdown.
	win.CloseHandle(input_pty_read)
	win.CloseHandle(output_pty_write)
	if win.FAILED(hr) do return {}, false
	defer if !ok do ClosePseudoConsole(hpc)

	// PROC_THREAD_ATTRIBUTE_LIST holds the pseudo-console binding.
	// Two-call sizing → HeapAlloc → Initialize → Update.
	attr_size: win.SIZE_T
	_ = InitializeProcThreadAttributeList(nil, 1, 0, &attr_size)
	attr_list := win.HeapAlloc(win.GetProcessHeap(), 0, attr_size)
	if attr_list == nil do return {}, false
	defer {
		DeleteProcThreadAttributeList(attr_list)
		_ = win.HeapFree(win.GetProcessHeap(), 0, attr_list)
	}
	if !InitializeProcThreadAttributeList(attr_list, 1, 0, &attr_size) {
		return {}, false
	}
	if !UpdateProcThreadAttribute(
		attr_list, 0,
		PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE,
		rawptr(hpc), size_of(win.HANDLE),
		nil, nil,
	) {
		return {}, false
	}

	siex: STARTUPINFOEXW
	siex.StartupInfo.cb = u32(size_of(STARTUPINFOEXW))
	siex.lpAttributeList = attr_list

	// CreateProcessW may modify lpCommandLine, so it must point at
	// writable memory. utf8_to_wstring's temp_allocator buffer is.
	cmdline := build_command_line(argv, context.temp_allocator)
	cmdline_w := win.utf8_to_wstring(cmdline, context.temp_allocator)
	cwd_w: win.wstring = nil
	if len(cwd) > 0 do cwd_w = win.utf8_to_wstring(cwd, context.temp_allocator)

	pi: win.PROCESS_INFORMATION
	// bInheritHandles=FALSE: ConPTY connects child stdio via the
	// attribute list, so we don't need handle inheritance (and don't
	// want our own pipe handles leaking into the child).
	create_ok := win.CreateProcessW(
		nil,
		cmdline_w,
		nil, nil,
		win.FALSE,
		win.EXTENDED_STARTUPINFO_PRESENT | win.CREATE_UNICODE_ENVIRONMENT,
		nil,
		cwd_w,
		cast(^win.STARTUPINFOW)&siex.StartupInfo,
		&pi,
	)
	if !create_ok do return {}, false

	// We don't need the thread handle — the OS closes it when the
	// thread exits, and we wait on the process handle.
	win.CloseHandle(pi.hThread)

	pty = PTY{
		hpc        = rawptr(hpc),
		master_in  = rawptr(input_our_write),
		master_out = rawptr(output_our_read),
		child      = rawptr(pi.hProcess),
	}
	ok = true
	return
}

pty_resize_windows :: proc(pty: ^PTY, cols, rows: int) {
	if pty.hpc == nil do return
	_ = ResizePseudoConsole(win.HANDLE(pty.hpc), win.COORD{X = i16(cols), Y = i16(rows)})
}

// Returns bytes read (>0), or -2 on EOF / broken pipe. ReadFile blocks
// until the next write; on shutdown we ClosePseudoConsole, which closes
// the PTY-side write handle internally — the next ReadFile then returns
// FALSE with ERROR_BROKEN_PIPE, which is our "child exited" signal.
pty_read_windows :: proc(pty: ^PTY, buf: []u8) -> int {
	if pty.master_out == nil do return -2
	read: win.DWORD
	ok := win.ReadFile(win.HANDLE(pty.master_out), raw_data(buf), win.DWORD(len(buf)), &read, nil)
	if !ok do return -2
	if read == 0 do return -2
	return int(read)
}

pty_write_windows :: proc(pty: ^PTY, data: []u8) -> int {
	if pty.master_in == nil do return -1
	written: win.DWORD
	ok := win.WriteFile(win.HANDLE(pty.master_in), raw_data(data), win.DWORD(len(data)), &written, nil)
	if !ok do return -1
	return int(written)
}

pty_close_windows :: proc(pty: ^PTY) {
	// ClosePseudoConsole signals the child to terminate AND closes its
	// internal handles — that's what unblocks the reader thread's
	// in-flight ReadFile (with ERROR_BROKEN_PIPE) so the thread can
	// observe `reader_quit` and exit cleanly.
	if pty.hpc != nil {
		ClosePseudoConsole(win.HANDLE(pty.hpc))
		pty.hpc = nil
	}
	if pty.master_in != nil {
		win.CloseHandle(win.HANDLE(pty.master_in))
		pty.master_in = nil
	}
	if pty.master_out != nil {
		win.CloseHandle(win.HANDLE(pty.master_out))
		pty.master_out = nil
	}
	// Give the child a moment to exit on its own; if it doesn't,
	// terminate it. Same intent as the Unix SIGTERM fallback. We don't
	// close the process HANDLE here — the child-exit watcher thread
	// (see terminal.odin) may still be in WaitForSingleObject on it.
	// Caller must invoke pty_close_child_handle after joining that
	// thread.
	if pty.child != nil {
		_ = win.WaitForSingleObject(win.HANDLE(pty.child), 100)
		_ = win.TerminateProcess(win.HANDLE(pty.child), 0)
	}
}

pty_close_child_handle_windows :: proc(pty: ^PTY) {
	if pty.child == nil do return
	win.CloseHandle(win.HANDLE(pty.child))
	pty.child = nil
}

// Used by the Windows-only child-exit watcher thread spawned in
// terminal_open. Blocks until the spawned child process terminates.
// On a forced shutdown path, terminal_close calls TerminateProcess
// (via pty_close → pty_close_windows), which makes this Wait return
// promptly so the watcher thread can be joined.
pty_wait_for_child_exit_windows :: proc(pty: ^PTY) {
	if pty.child == nil do return
	_ = win.WaitForSingleObject(win.HANDLE(pty.child), win.INFINITE)
}
