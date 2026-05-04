#+build !darwin
#+build !linux
package bragi

import "core:os"

// Non-POSIX platforms (currently just Windows): no mmap path.
// `mmap_load_file` returns ok=false so `editor_load_file` falls back
// to the read-into-buffer path. ConPTY-style mmap via
// `MapViewOfFile` could be added here later.
mmap_load_file :: proc(file: ^os.File, size: int) -> (data: []u8, addr: rawptr, ok: bool) {
	return nil, nil, false
}

mmap_release :: proc(addr: rawptr, size: int) {
	// no-op; never called when mmap_load_file returns ok=false
}
