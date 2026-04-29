package bragi

import "core:c"
import "core:os"
import "core:strings"

// Minimal pseudo-terminal abstraction. Spawns a child process attached
// to the slave end of a freshly-allocated PTY and hands the master fd
// back to us so the caller can read child output and write user input.
//
// Unix path uses `forkpty(3)` from <util.h> on macOS / <pty.h> on Linux,
// which wraps the openpt + grantpt + unlockpt + fork + setsid +
// TIOCSCTTY dance into a single call. Windows requires CreatePseudoConsole
// and is stubbed out for now.

PTY :: struct {
	master_fd: int, // read child output / write user input via this
	child_pid: int, // for waitpid + SIGTERM on close
}

// `argv` is the program + args to exec in the child. NULL-terminated
// internally. `cols` / `rows` set the initial terminal size; the child
// sees these via the `TIOCSWINSZ` ioctl that forkpty takes care of.
// `cwd` (optional) is a directory the child chdirs into before exec,
// matching what every native terminal emulator does (start new shells
// in $HOME rather than in the launcher's cwd, which is `/` for GUI
// launches on macOS).
pty_spawn :: proc(argv: []string, cols, rows: int, cwd: string = "") -> (pty: PTY, ok: bool) {
	when ODIN_OS == .Darwin || ODIN_OS == .Linux {
		// Build a NULL-terminated argv for execvp. Strings are cloned
		// into temp_allocator since the cstrings need to outlive the
		// fork; the kernel snapshots them at exec time. Same trick for
		// the cwd cstring — clone before fork so the child reads from
		// already-allocated memory and we don't need an allocator in
		// the post-fork child path.
		cargs := make([]cstring, len(argv) + 1, context.temp_allocator)
		for s, i in argv {
			cargs[i] = strings.clone_to_cstring(s, context.temp_allocator)
		}
		cargs[len(argv)] = nil

		cwd_cstr: cstring = nil
		if len(cwd) > 0 {
			cwd_cstr = strings.clone_to_cstring(cwd, context.temp_allocator)
		}

		ws := winsize{
			ws_row    = u16(rows),
			ws_col    = u16(cols),
			ws_xpixel = 0,
			ws_ypixel = 0,
		}

		master: c.int
		pid := forkpty(&master, nil, nil, &ws)
		if pid < 0 {
			return {}, false
		}
		if pid == 0 {
			// Child. chdir BEFORE setting env / exec'ing — failure is
			// silently ignored (we'd rather still launch the shell
			// from `/` than abort the whole pane).
			if cwd_cstr != nil do _ = chdir(cwd_cstr)
			// Make sure TERM is set — when Bragi is launched from
			// a .desktop entry / Finder (no parent terminal), TERM is
			// unset and `clear` / curses apps abort with "TERM
			// environment variable not set." libvterm emulates
			// xterm-256color.
			_ = setenv("TERM", "xterm-256color", 1)
			_ = setenv("COLORTERM", "truecolor", 1)
			// Locale matters even more than it looks. macOS's GUI
			// launchd doesn't propagate LANG / LC_*, so child shells
			// fall back to the "C" locale, where wcwidth() returns -1
			// for every non-ASCII character — every powerline / nerd-
			// font glyph in the prompt. zsh then mis-counts its
			// prompt's visual width and corrupts the redraw on every
			// command, leaving the user staring at scattered
			// characters in column 0. Set a UTF-8 locale only if the
			// inherited env doesn't already have one (overwrite=0).
			_ = setenv("LANG",     "en_US.UTF-8", 0)
			_ = setenv("LC_CTYPE", "en_US.UTF-8", 0)
			// Replace ourselves with the requested program. If execvp
			// fails, _exit (not exit) so we don't run the parent's
			// atexit handlers / SDL cleanup in the fork copy.
			_ = execvp(cargs[0], raw_data(cargs))
			libc_exit(127)
		}

		// Parent. Make the master fd non-blocking so the reader thread
		// can detect "no data right now" cleanly via EAGAIN.
		set_nonblocking(int(master))

		return PTY{master_fd = int(master), child_pid = int(pid)}, true
	} else when ODIN_OS == .Windows {
		// TODO(windows): CreatePseudoConsole / CreateProcess pair.
		// Left unimplemented — Bragi terminal currently macOS / Linux only.
		return {}, false
	} else {
		return {}, false
	}
}

// Resize the terminal: tells the kernel + child the new dimensions so
// applications like vim and htop redraw at the right size.
pty_resize :: proc(pty: ^PTY, cols, rows: int) {
	when ODIN_OS == .Darwin || ODIN_OS == .Linux {
		ws := winsize{ws_row = u16(rows), ws_col = u16(cols)}
		_ = ioctl(c.int(pty.master_fd), TIOCSWINSZ, &ws)
	}
}

// Returns bytes read (>= 0) or -1 on error / EAGAIN. -2 means EOF
// (child has closed the slave end, usually because it exited).
pty_read :: proc(pty: ^PTY, buf: []u8) -> int {
	when ODIN_OS == .Darwin || ODIN_OS == .Linux {
		n := unix_read(c.int(pty.master_fd), raw_data(buf), c.size_t(len(buf)))
		if n > 0 do return int(n)
		if n == 0 do return -2 // EOF
		// errno-based: EAGAIN means "no data right now."
		return -1
	} else {
		return -1
	}
}

pty_write :: proc(pty: ^PTY, data: []u8) -> int {
	when ODIN_OS == .Darwin || ODIN_OS == .Linux {
		n := unix_write(c.int(pty.master_fd), raw_data(data), c.size_t(len(data)))
		return int(n)
	} else {
		return -1
	}
}

// Close the master fd. Sends SIGHUP to the child via the slave-side
// hangup, which causes well-behaved shells to exit cleanly. Caller is
// responsible for waitpid'ing the child afterwards.
pty_close :: proc(pty: ^PTY) {
	when ODIN_OS == .Darwin || ODIN_OS == .Linux {
		if pty.master_fd >= 0 do unix_close(c.int(pty.master_fd))
		pty.master_fd = -1
		// Best-effort: send SIGTERM in case the shell ignored the HUP.
		if pty.child_pid > 0 do _ = kill(c.int(pty.child_pid), SIGTERM)
	}
}

// ──────────────────────────────────────────────────────────────────
// libc bindings (Unix-only)
// ──────────────────────────────────────────────────────────────────

when ODIN_OS == .Darwin || ODIN_OS == .Linux {

	winsize :: struct {
		ws_row:    u16,
		ws_col:    u16,
		ws_xpixel: u16,
		ws_ypixel: u16,
	}

	when ODIN_OS == .Darwin {
		// macOS forkpty is in libutil, which the system linker rolls into libSystem.
		foreign import libutil "system:util"
		// Wraps openpt+grantpt+unlockpt+fork+TIOCSCTTY.
		@(default_calling_convention = "c")
		foreign libutil {
			forkpty :: proc(amaster: ^c.int, name: rawptr, termp: rawptr, winp: ^winsize) -> c.int ---
		}
	} else {
		// glibc / musl ship forkpty in libutil. Some musl builds inline it
		// directly into libc; -lutil is still the portable invocation.
		foreign import libutil "system:util"
		@(default_calling_convention = "c")
		foreign libutil {
			forkpty :: proc(amaster: ^c.int, name: rawptr, termp: rawptr, winp: ^winsize) -> c.int ---
		}
	}

	foreign import libc "system:c"

	// macOS has TIOCSWINSZ in <termios.h>; the magic value is stable
	// across BSD-derived kernels.
	when ODIN_OS == .Darwin {
		TIOCSWINSZ :: 0x80087467
	} else {
		TIOCSWINSZ :: 0x5414 // Linux
	}

	F_GETFL    :: 3
	F_SETFL    :: 4
	O_NONBLOCK :: 0x0004 when ODIN_OS == .Darwin else 0o4000
	SIGTERM    :: 15

	@(default_calling_convention = "c")
	foreign libc {
		execvp :: proc(file: cstring, argv: [^]cstring) -> c.int ---
		ioctl  :: proc(fd: c.int, request: c.ulong, arg: rawptr) -> c.int ---
		fcntl  :: proc(fd: c.int, cmd: c.int, #c_vararg args: ..any) -> c.int ---
		kill   :: proc(pid: c.int, sig: c.int) -> c.int ---
		setenv :: proc(name: cstring, value: cstring, overwrite: c.int) -> c.int ---
		chdir  :: proc(path: cstring) -> c.int ---

		// Bypasses atexit handlers — what we want in the post-fork
		// child path so we don't run the parent's cleanup twice.
		@(link_name = "_exit")
		libc_exit :: proc(status: c.int) -> ! ---

		@(link_name = "read")
		unix_read :: proc(fd: c.int, buf: rawptr, count: c.size_t) -> c.ssize_t ---
		@(link_name = "write")
		unix_write :: proc(fd: c.int, buf: rawptr, count: c.size_t) -> c.ssize_t ---
		@(link_name = "close")
		unix_close :: proc(fd: c.int) -> c.int ---
	}

	@(private="file")
	set_nonblocking :: proc(fd: int) {
		flags := fcntl(c.int(fd), F_GETFL, 0)
		if flags < 0 do return
		_ = fcntl(c.int(fd), F_SETFL, flags | O_NONBLOCK)
	}
}
