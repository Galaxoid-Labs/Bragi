#+build darwin, linux
package bragi

import "core:c"
import "core:os"

// Memory-map an open file for read-only-with-COW access. Returns the
// mapped slice plus the (addr, size) pair the caller must hand back to
// `mmap_release` when done.
//
// Why MAP_PRIVATE (vs MAP_SHARED): we want copy-on-write semantics so
// that any later in-place mutation (e.g. CRLF compaction) doesn't
// propagate to the file on disk, AND so the kernel can keep
// untouched pages backed by the file (lazy-paged on first read).
// Reads from a freshly-mapped MAP_PRIVATE region cost nothing until
// the pages are touched — that's the whole reason we mmap here.
//
// Why PROT_WRITE alongside PROT_READ: we need to be able to compact
// `\r\n` → `\n` in place when the file uses CRLF. Without PROT_WRITE
// that's a SIGBUS at the first write attempt. With MAP_PRIVATE +
// PROT_WRITE, the kernel allocates anonymous backing for any page
// we modify; pure-LF files (the common case) modify nothing and stay
// lazy-paged.
//
// `fd` is closed on the caller's side — mmap'd memory survives the
// fd close (POSIX guarantees this).
mmap_load_file :: proc(file: ^os.File, size: int) -> (data: []u8, addr: rawptr, ok: bool) {
	if size <= 0 do return nil, nil, false

	fd := c.int(os.fd(file))
	if fd < 0 do return nil, nil, false

	p := posix_mmap(nil, c.size_t(size), PROT_READ | PROT_WRITE, MAP_PRIVATE, fd, 0)
	if p == MAP_FAILED do return nil, nil, false

	// Hint the kernel that we'll read this region sequentially front-
	// to-back (line-cache build, EOL detect). Best-effort; ignore
	// failures.
	_ = posix_madvise(p, c.size_t(size), MADV_SEQUENTIAL)

	data = ([^]u8)(p)[:size]
	addr = p
	ok = true
	return
}

// Hand the (addr, size) pair we got from `mmap_load_file` back to the
// kernel. Called from `piece_buffer_destroy` when `original_mmap` is
// non-nil.
mmap_release :: proc(addr: rawptr, size: int) {
	if addr == nil || size <= 0 do return
	_ = posix_munmap(addr, c.size_t(size))
}

// ──────────────────────────────────────────────────────────────────
// libc bindings
// ──────────────────────────────────────────────────────────────────

foreign import mmap_libc "system:c"

// mmap returns (void*)-1 on failure, NOT nil. Compare against this
// constant rather than `nil`.
@(private="file") MAP_FAILED :: rawptr(uintptr(max(uint)))

@(private="file") PROT_READ  :: c.int(0x01)
@(private="file") PROT_WRITE :: c.int(0x02)

// MAP_PRIVATE happens to be 0x02 on both macOS and Linux (and most
// other BSD-derived kernels). MAP_SHARED is 0x01 on Linux and 0x01
// on macOS too — but we don't need that here.
@(private="file") MAP_PRIVATE :: c.int(0x02)

// `madvise` advice values. SEQUENTIAL is hint #2 on both macOS and
// Linux. We only use this one.
@(private="file") MADV_SEQUENTIAL :: c.int(2)

@(default_calling_convention="c")
foreign mmap_libc {
	@(link_name="mmap")    posix_mmap    :: proc(addr: rawptr, len: c.size_t, prot: c.int, flags: c.int, fd: c.int, offset: c.long) -> rawptr ---
	@(link_name="munmap")  posix_munmap  :: proc(addr: rawptr, len: c.size_t) -> c.int ---
	@(link_name="madvise") posix_madvise :: proc(addr: rawptr, len: c.size_t, advice: c.int) -> c.int ---
}
