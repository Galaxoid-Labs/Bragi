#+build windows
package bragi

import "core:strings"
import win "core:sys/windows"

// ReadDirectoryChangesW + IOCP backend. We open one directory handle
// per unique parent (FILE_LIST_DIRECTORY, FILE_FLAG_BACKUP_SEMANTICS
// is required for directories, FILE_FLAG_OVERLAPPED to use IOCP) and
// associate it with a single completion port. The watcher thread
// blocks in `GetQueuedCompletionStatus`; on each completion we don't
// care *what* changed, only that something did, so we just re-issue
// `ReadDirectoryChangesW` and let the cross-platform glue re-stat
// every editor's file_path.
//
// Shutdown wakes the thread via `PostQueuedCompletionStatus` with a
// reserved completion key (`WAKE_KEY`) that can't collide with any
// `Dir_Watch` pointer (heap pointers are at least 8-byte aligned, so
// 1 is safe).

@(private="file") WAKE_KEY  :: win.ULONG_PTR(1)
@(private="file") BUF_SIZE  :: 4096
@(private="file") NOTIFY_FILTER :: win.DWORD(
	win.FILE_NOTIFY_CHANGE_FILE_NAME |
	win.FILE_NOTIFY_CHANGE_DIR_NAME  |
	win.FILE_NOTIFY_CHANGE_LAST_WRITE |
	win.FILE_NOTIFY_CHANGE_SIZE       |
	win.FILE_NOTIFY_CHANGE_CREATION,
)

// Heap-allocated so the OVERLAPPED address (and the buffer) stay
// stable across async I/O. The IOCP completion key is the address
// of this struct, which lets the watcher thread re-issue
// ReadDirectoryChangesW against the right handle/buffer.
@(private="file")
Dir_Watch :: struct {
	dir:     string,
	handle:  win.HANDLE,
	overlap: win.OVERLAPPED,
	buffer:  [BUF_SIZE]u8,
}

@(private="file") g_iocp:    win.HANDLE
@(private="file") g_dirs:    map[string]^Dir_Watch
@(private="file") g_started: bool

file_watch_backend_init :: proc() -> bool {
	iocp := win.CreateIoCompletionPort(win.INVALID_HANDLE_VALUE, nil, 0, 0)
	if iocp == nil do return false
	g_iocp = iocp
	g_dirs = make(map[string]^Dir_Watch)
	g_started = true
	return true
}

file_watch_backend_shutdown :: proc() {
	if !g_started do return
	for _, dw in g_dirs {
		if dw.handle != win.INVALID_HANDLE_VALUE {
			win.CloseHandle(dw.handle)
		}
		delete(dw.dir)
		free(dw)
	}
	delete(g_dirs)
	g_dirs = nil
	if g_iocp != nil {
		win.CloseHandle(g_iocp)
		g_iocp = nil
	}
	g_started = false
}

file_watch_backend_add :: proc(dir: string) {
	if len(dir) == 0   do return
	if !g_started      do return
	if dir in g_dirs   do return

	wpath := win.utf8_to_wstring(dir, context.temp_allocator)
	share := win.FILE_SHARE_READ | win.FILE_SHARE_WRITE | win.FILE_SHARE_DELETE
	flags := win.FILE_FLAG_BACKUP_SEMANTICS | win.FILE_FLAG_OVERLAPPED

	h := win.CreateFileW(wpath, win.FILE_LIST_DIRECTORY, share, nil,
	                     win.OPEN_EXISTING, flags, nil)
	if h == win.INVALID_HANDLE_VALUE do return

	dw := new(Dir_Watch)
	dw.dir    = strings.clone(dir)
	dw.handle = h
	// IOCP completion key is the Dir_Watch pointer so the watcher
	// thread can find the right buffer/handle on each completion.
	if win.CreateIoCompletionPort(h, g_iocp, win.ULONG_PTR(uintptr(rawptr(dw))), 0) == nil {
		win.CloseHandle(h)
		delete(dw.dir)
		free(dw)
		return
	}

	if !issue_read(dw) {
		win.CloseHandle(h)
		delete(dw.dir)
		free(dw)
		return
	}
	g_dirs[dw.dir] = dw
}

file_watch_backend_wake :: proc() {
	if g_iocp == nil do return
	win.PostQueuedCompletionStatus(g_iocp, 0, WAKE_KEY, nil)
}

file_watch_backend_wait :: proc() -> File_Watch_Wait {
	bytes:   win.DWORD
	key:     win.ULONG_PTR
	overlap: ^win.OVERLAPPED
	ok := win.GetQueuedCompletionStatus(g_iocp, &bytes, &key, &overlap, win.INFINITE)

	// `ok == FALSE` with overlap == nil means the call itself failed
	// (e.g. the IOCP was closed). Treat that as a fatal exit; the
	// thread will join during shutdown anyway.
	if !ok && overlap == nil do return {ok = false}

	if key == WAKE_KEY {
		return {ok = true, shutdown = true}
	}

	// Real change. Re-issue the read so we see the next batch. We
	// don't bother parsing the FILE_NOTIFY_INFORMATION records — the
	// main loop re-stats every open file_path anyway.
	dw := cast(^Dir_Watch)rawptr(uintptr(key))
	if dw != nil do _ = issue_read(dw)

	return {ok = true}
}

@(private="file")
issue_read :: proc(dw: ^Dir_Watch) -> bool {
	dw.overlap = {} // zero out before re-arming
	bytes_returned: win.DWORD
	return bool(win.ReadDirectoryChangesW(
		dw.handle,
		rawptr(&dw.buffer[0]),
		BUF_SIZE,
		false, // bWatchSubtree — we only care about the immediate dir
		NOTIFY_FILTER,
		&bytes_returned,
		&dw.overlap,
		nil,
	))
}

