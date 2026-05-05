#+build linux
package bragi

import "core:strings"
import "core:sys/linux"

// inotify-backed file watcher. We watch each unique parent directory
// of an open file with the union of mutation-shaped events (modify,
// close-write, moved-into, deleted, attribute change) so atomic
// replaces, simple writes, renames, and deletes all surface as a
// wake on the inotify fd. A self-pipe lets `file_watch_shutdown`
// wake the watcher thread cleanly via poll().

@(private="file") g_inotify_fd: linux.Fd = -1
@(private="file") g_wake_pipe:  [2]linux.Fd = {-1, -1}
@(private="file") g_dirs:       map[string]bool

file_watch_backend_init :: proc() -> bool {
	fd, err := linux.inotify_init1({.CLOEXEC})
	if err != .NONE do return false
	g_inotify_fd = fd

	pfds: [2]linux.Fd
	if perr := linux.pipe2(&pfds, {.CLOEXEC}); perr != .NONE {
		linux.close(g_inotify_fd)
		g_inotify_fd = -1
		return false
	}
	g_wake_pipe = pfds
	g_dirs = make(map[string]bool)
	return true
}

file_watch_backend_shutdown :: proc() {
	if g_inotify_fd >= 0 {
		linux.close(g_inotify_fd)
		g_inotify_fd = -1
	}
	if g_wake_pipe[0] >= 0 {
		linux.close(g_wake_pipe[0])
		g_wake_pipe[0] = -1
	}
	if g_wake_pipe[1] >= 0 {
		linux.close(g_wake_pipe[1])
		g_wake_pipe[1] = -1
	}
	for k in g_dirs do delete(k)
	delete(g_dirs)
	g_dirs = nil
}

file_watch_backend_add :: proc(dir: string) {
	if len(dir) == 0 do return
	if dir in g_dirs do return

	cstr := strings.clone_to_cstring(dir, context.temp_allocator)
	mask := linux.Inotify_Event_Mask{
		.MODIFY,
		.CLOSE_WRITE,
		.MOVED_TO,
		.MOVED_FROM,
		.CREATE,
		.DELETE,
		.DELETE_SELF,
		.MOVE_SELF,
		.ATTRIB,
	}
	if _, err := linux.inotify_add_watch(g_inotify_fd, cstr, mask); err != .NONE do return
	g_dirs[strings.clone(dir)] = true
}

file_watch_backend_wake :: proc() {
	one := [1]u8{0}
	_, _ = linux.write(g_wake_pipe[1], one[:])
}

file_watch_backend_wait :: proc() -> File_Watch_Wait {
	fds: [2]linux.Poll_Fd
	fds[0] = linux.Poll_Fd{fd = g_inotify_fd, events = {.IN}}
	fds[1] = linux.Poll_Fd{fd = g_wake_pipe[0], events = {.IN}}
	_, err := linux.poll(fds[:], -1)
	if err != .NONE && err != .EINTR do return {ok = false}

	if .IN in fds[1].revents {
		// Drain the wake pipe; treat as shutdown.
		buf: [16]u8
		_, _ = linux.read(g_wake_pipe[0], buf[:])
		return {ok = true, shutdown = true}
	}
	if .IN in fds[0].revents {
		// Drain inotify events. We don't dispatch per-file — the
		// main thread re-stats every open file and reconciles in
		// one pass, so we just need to clear the buffer to avoid
		// re-firing immediately.
		buf: [4096]u8
		_, _ = linux.read(g_inotify_fd, buf[:])
		return {ok = true}
	}
	return {ok = true}
}
