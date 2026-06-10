package bragi

import "core:os"
import "core:testing"

// Regression: on POSIX the buffer keeps reading its MAP_PRIVATE mmap of the
// loaded file. An in-place save (open(O_TRUNC)+write) used to yank those bytes
// out from under the mapping — pieces past the new EOF read back as zeros on
// Linux, so the next save wrote that corruption to disk (reported as Ctrl+S
// "adding an empty line" each save). editor_save_file now writes atomically
// (temp + rename), which keeps the original inode alive behind the mapping.
//
// This drives the exact failing shape: load → delete a line → save repeatedly
// WITHOUT an intervening reload (the real app's mtime-suppressed path), and
// asserts neither the live buffer nor the file drift.
@(test)
test_save_does_not_corrupt_mmap_buffer :: proc(t: ^testing.T) {
	path := "/tmp/bragi_save_repro.txt"
	_ = os.write_entire_file(path, transmute([]u8)string("line1\nline2\nline3\n"))

	ed := editor_make()
	defer editor_destroy(&ed)
	testing.expect(t, editor_load_file(&ed, path), "load")

	editor_buffer_delete(&ed, 6, 6) // drop "line2\n"
	ed.dirty = true

	for i in 0 ..< 3 {
		testing.expect(t, editor_save_file(&ed), "save")
		live := piece_buffer_to_string(&ed.buffer, context.temp_allocator)
		testing.expectf(t, live == "line1\nline3\n", "buffer corrupted after save %d: %q", i, live)
	}

	disk, _ := os.read_entire_file(path, context.temp_allocator)
	testing.expectf(t, string(disk) == "line1\nline3\n", "file corrupted on disk: %q", string(disk))
}
