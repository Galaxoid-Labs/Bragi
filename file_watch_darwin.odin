#+build darwin
package bragi

import "core:strings"
import "core:sys/kqueue"
import "core:sys/posix"

// kqueue-backed file watcher. We watch each unique parent directory
// of an open file with EVFILT_VNODE (NOTE_WRITE | NOTE_EXTEND |
// NOTE_RENAME | NOTE_DELETE) so atomic replaces, simple writes,
// renames, and deletes all surface as a wake on the kqueue. A
// pre-registered EVFILT_USER event lets `file_watch_shutdown` wake
// the watcher thread cleanly.

@(private="file") WAKE_IDENT :: uintptr(0xDEADBEEF)
@(private="file") g_kq:       kqueue.KQ = -1
@(private="file") g_dir_fds:  map[string]posix.FD

file_watch_backend_init :: proc() -> bool {
	kq, err := kqueue.kqueue()
	if err != .NONE do return false
	g_kq = kq

	// Pre-register the User-filter wake event. EV_CLEAR makes it
	// edge-triggered so a single Trigger fires exactly once per
	// kevent() return rather than re-firing on every wait.
	wake: kqueue.KEvent
	wake.ident  = WAKE_IDENT
	wake.filter = .User
	wake.flags  = {.Add, .Clear}
	if _, kerr := kqueue.kevent(g_kq, []kqueue.KEvent{wake}, nil, nil); kerr != .NONE {
		posix.close(posix.FD(g_kq))
		g_kq = -1
		return false
	}

	g_dir_fds = make(map[string]posix.FD)
	return true
}

file_watch_backend_shutdown :: proc() {
	for _, fd in g_dir_fds do posix.close(fd)
	for k in g_dir_fds   do delete(k)
	delete(g_dir_fds)
	g_dir_fds = nil
	if g_kq >= 0 {
		posix.close(posix.FD(g_kq))
		g_kq = -1
	}
}

file_watch_backend_add :: proc(dir: string) {
	if len(dir) == 0 do return
	if dir in g_dir_fds do return

	cstr := strings.clone_to_cstring(dir, context.temp_allocator)
	// `O_RDONLY` is the absence of write/rdwr bits — i.e. an empty
	// O_Flags bit set. We just need a fd to attach the kqueue watch
	// to; we never read from it.
	fd := posix.open(cstr, posix.O_Flags{})
	if fd < 0 do return

	kev: kqueue.KEvent
	kev.ident  = uintptr(fd)
	kev.filter = .VNode
	kev.flags  = {.Add, .Clear}
	kev.fflags.vnode = {.Write, .Extend, .Rename, .Delete}
	if _, err := kqueue.kevent(g_kq, []kqueue.KEvent{kev}, nil, nil); err != .NONE {
		posix.close(fd)
		return
	}
	g_dir_fds[strings.clone(dir)] = fd
}

file_watch_backend_wake :: proc() {
	kev: kqueue.KEvent
	kev.ident  = WAKE_IDENT
	kev.filter = .User
	kev.fflags.user = {.Trigger}
	_, _ = kqueue.kevent(g_kq, []kqueue.KEvent{kev}, nil, nil)
}

file_watch_backend_wait :: proc() -> File_Watch_Wait {
	out: [8]kqueue.KEvent
	n, err := kqueue.kevent(g_kq, nil, out[:], nil)
	if err != .NONE && err != .EINTR do return {ok = false}
	for i in 0 ..< int(n) {
		if out[i].ident == WAKE_IDENT {
			return {ok = true, shutdown = true}
		}
	}
	return {ok = true}
}
