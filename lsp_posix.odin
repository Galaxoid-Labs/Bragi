#+build darwin, linux
package bragi

import "core:c"
import "core:strings"

// POSIX process spawn for the LSP client: a child with its stdin/stdout
// wired to PLAIN pipes (not a PTY — language servers speak raw JSON-RPC,
// not terminal control codes). Modeled on pty_spawn (pty.odin:48) but
// pipe()+fork()+dup2()+execvp() instead of forkpty().
//
// Reuses libc bindings already declared in pty.odin (execvp, setenv,
// chdir, libc_exit, unix_read/write/close, kill, SIGTERM — all
// package-visible on darwin/linux); only the pipe/fork/dup2/waitpid
// syscalls are new here. lsp_windows.odin provides the same symbol set
// (lsp_spawn / lsp_pipe_*) for Windows; lsp.odin stays platform-neutral.

// LSP_Pipes is defined in lsp.odin (cross-platform).

foreign import lsp_libc "system:c"

@(default_calling_convention = "c")
foreign lsp_libc {
	pipe    :: proc(fds: ^[2]c.int) -> c.int ---
	fork    :: proc() -> c.int ---
	dup2    :: proc(oldfd, newfd: c.int) -> c.int ---
	waitpid :: proc(pid: c.int, status: ^c.int, options: c.int) -> c.int ---
}

// Spawn `argv` with `cwd` and extra `env` entries ("KEY=VALUE"). Returns
// the child pid plus our ends of the two pipes. stderr is left inherited
// so server diagnostics land in Bragi's console during development.
lsp_spawn :: proc(argv: []string, cwd: string, env: []string) -> (p: LSP_Pipes, ok: bool) {
	// Everything the post-fork child touches is cloned into temp BEFORE
	// the fork (no allocator in the child path — malloc locks could be
	// held across fork). Same discipline as pty_spawn.
	cargs := make([]cstring, len(argv) + 1, context.temp_allocator)
	for s, i in argv {
		cargs[i] = strings.clone_to_cstring(s, context.temp_allocator)
	}
	cargs[len(argv)] = nil

	cwd_c: cstring
	if len(cwd) > 0 do cwd_c = strings.clone_to_cstring(cwd, context.temp_allocator)

	// Pre-split env "KEY=VALUE" into (name, value) cstrings.
	Env_KV :: struct {
		name, value: cstring,
	}
	envs := make([]Env_KV, len(env), context.temp_allocator)
	for kv, i in env {
		if eq := strings.index_byte(kv, '='); eq >= 0 {
			envs[i] = {
				strings.clone_to_cstring(kv[:eq], context.temp_allocator),
				strings.clone_to_cstring(kv[eq + 1:], context.temp_allocator),
			}
		} else {
			envs[i] = {strings.clone_to_cstring(kv, context.temp_allocator), nil}
		}
	}

	in_fds:  [2]c.int // child stdin:  [0] child reads, [1] we write
	out_fds: [2]c.int // child stdout: [0] we read,    [1] child writes
	if pipe(&in_fds) != 0 do return {}, false
	if pipe(&out_fds) != 0 {
		unix_close(in_fds[0]); unix_close(in_fds[1])
		return {}, false
	}

	pid := fork()
	if pid < 0 {
		unix_close(in_fds[0]); unix_close(in_fds[1])
		unix_close(out_fds[0]); unix_close(out_fds[1])
		return {}, false
	}

	if pid == 0 {
		// ── Child ── only bound syscalls; no Odin allocation / SDL.
		dup2(in_fds[0], 0)  // stdin  ← read end of the in pipe
		dup2(out_fds[1], 1) // stdout → write end of the out pipe
		unix_close(in_fds[0]); unix_close(in_fds[1])
		unix_close(out_fds[0]); unix_close(out_fds[1])
		if cwd_c != nil do _ = chdir(cwd_c)
		for e in envs do _ = setenv(e.name, e.value, 1)
		_ = execvp(cargs[0], raw_data(cargs))
		libc_exit(127) // exec failed — _exit, not exit (skip SDL atexit)
	}

	// ── Parent ── drop the child-side ends; keep our write/read ends.
	unix_close(in_fds[0])
	unix_close(out_fds[1])
	return LSP_Pipes{pid = int(pid), stdin_fd = int(in_fds[1]), stdout_fd = int(out_fds[0])}, true
}

// Blocking read. >0 bytes, -2 EOF (server closed stdout / exited), -1 error.
lsp_pipe_read :: proc(fd: int, buf: []u8) -> int {
	n := unix_read(c.int(fd), raw_data(buf), c.size_t(len(buf)))
	if n > 0 do return int(n)
	if n == 0 do return -2
	return -1
}

// Write all of `data`; returns false on error.
lsp_pipe_write :: proc(fd: int, data: []u8) -> bool {
	sent := 0
	for sent < len(data) {
		remaining := len(data) - sent
		n := unix_write(c.int(fd), raw_data(data[sent:]), c.size_t(remaining))
		if n <= 0 do return false
		sent += int(n)
	}
	return true
}

lsp_pipe_close :: proc(fd: int) {
	if fd >= 0 do unix_close(c.int(fd))
}

// Terminate + reap the child (after its stdin is closed it should exit on
// its own; SIGTERM is the backstop, waitpid reaps the zombie).
lsp_proc_kill :: proc(pid: int) {
	if pid <= 0 do return
	_ = kill(c.int(pid), SIGTERM)
	status: c.int
	_ = waitpid(c.int(pid), &status, 0)
}
