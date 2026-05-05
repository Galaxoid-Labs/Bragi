package bragi

import "base:runtime"
import "core:c"
import "core:path/filepath"
import sdl "vendor:sdl3"

// Real-time file-change watcher. A single background thread blocks on
// the platform-native API (inotify on Linux, kqueue on macOS) and
// pushes a USER SDL event (`FILE_WATCH_EVENT`) when something on
// disk we care about changes. The main loop re-stats every open
// editor's file_path and reconciles.
//
// Per-platform backends live in `file_watch_<os>.odin` and expose
// these four entry points. The cross-platform glue here owns the
// thread + wake handshake; the backends own the OS handles.

FILE_WATCH_EVENT :: i32(0x46494C45) // "FILE"

File_Watch_Wait :: struct {
	ok:       bool, // false = fatal; thread exits
	shutdown: bool, // true  = wake came from `file_watch_shutdown`
}

@(private="file") g_file_watch_thread: ^sdl.Thread

// Spawn the watcher thread. Returns false on platforms without a
// backend, or if the backend init fails (rare — usually only when
// the kernel limit on watches is hit).
file_watch_init :: proc() -> bool {
	if !file_watch_backend_init() do return false
	g_file_watch_thread = sdl.CreateThread(file_watch_thread_proc, "bragi-file-watch", nil)
	if g_file_watch_thread == nil {
		file_watch_backend_shutdown()
		return false
	}
	return true
}

file_watch_shutdown :: proc() {
	if g_file_watch_thread == nil do return
	file_watch_backend_wake()
	sdl.WaitThread(g_file_watch_thread, nil)
	g_file_watch_thread = nil
	file_watch_backend_shutdown()
}

// Start watching the file at `path`. Both backends watch the parent
// directory rather than the file itself — atomic-replace patterns
// (write tmp + rename, used by formatters and many editors) make
// per-file watches go stale, but parent-dir events catch everything.
// Adding the same dir twice is idempotent. Failures are silent
// (a file that can't be watched still works otherwise).
file_watch_add :: proc(path: string) {
	if len(path) == 0 do return
	dir := filepath.dir(path, context.temp_allocator)
	file_watch_backend_add(dir)
}

@(private="file")
file_watch_thread_proc :: proc "c" (data: rawptr) -> c.int {
	context = runtime.default_context()
	for {
		r := file_watch_backend_wait()
		if !r.ok        do break
		if r.shutdown   do break
		// Real change. Wake the main loop; it'll re-stat every
		// open editor's file_path and reconcile in one pass.
		ev: sdl.Event
		ev.user.type = .USER
		ev.user.code = FILE_WATCH_EVENT
		_ = sdl.PushEvent(&ev)
	}
	return 0
}

