#+build !darwin
#+build !linux
#+build !windows
package bragi

// Catch-all for any platform without a real-time file watcher.
// Returns false from init so `main()` skips spawning the watcher
// thread; the editor falls back to silently not noticing external
// changes (same as the pre-watcher behavior).

file_watch_backend_init :: proc() -> bool { return false }

file_watch_backend_shutdown :: proc() {
	// no-op
}

file_watch_backend_add :: proc(dir: string) {
	// no-op
	_ = dir
}

file_watch_backend_wake :: proc() {
	// no-op
}

file_watch_backend_wait :: proc() -> File_Watch_Wait {
	return {ok = false}
}
