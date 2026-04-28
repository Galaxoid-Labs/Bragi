package bragi

import "core:mem"

// A gap buffer stores text as one contiguous array with an unused "gap" at
// the cursor. Inserts and deletes near the gap are O(1); moving the gap to
// a new logical position copies the bytes between old and new gap, which
// is fast in practice because the user mostly edits in one place.
//
// Layout (gap shown as `_`):
//   data    = "Hello___World"
//   gap_start = 5
//   gap_end   = 8
//   logical text = "Hello" + "World" = "HelloWorld"
//   gap_buffer_len = 5 + (13 - 8) = 10

GAP_INITIAL :: 64
GAP_GROW    :: 1024

Gap_Buffer :: struct {
	data:      []u8,
	gap_start: int,
	gap_end:   int,
	version:   u64, // bumped on every mutation; lets caches detect staleness
}

gap_buffer_make :: proc(initial_cap: int = GAP_INITIAL, allocator := context.allocator) -> Gap_Buffer {
	c := max(initial_cap, GAP_INITIAL)
	// Skip zero-init: every byte we hand out is either copied over by an
	// insert or sits inside the gap (never read). On a 100 MB load that
	// saves ~30-50 ms of memset.
	data, _ := mem.alloc_bytes_non_zeroed(c, 1, allocator)
	return Gap_Buffer{
		data      = data,
		gap_start = 0,
		gap_end   = c,
	}
}

gap_buffer_destroy :: proc(gb: ^Gap_Buffer) {
	delete(gb.data)
	gb^ = {}
}

gap_buffer_len :: proc(gb: ^Gap_Buffer) -> int {
	return gb.gap_start + (len(gb.data) - gb.gap_end)
}

gap_buffer_byte_at :: proc(gb: ^Gap_Buffer, i: int) -> u8 {
	if i < gb.gap_start {
		return gb.data[i]
	}
	return gb.data[gb.gap_end + (i - gb.gap_start)]
}

gap_buffer_move_gap :: proc(gb: ^Gap_Buffer, pos: int) {
	if pos < gb.gap_start {
		n := gb.gap_start - pos
		copy(gb.data[gb.gap_end - n:gb.gap_end], gb.data[pos:gb.gap_start])
		gb.gap_start = pos
		gb.gap_end -= n
	} else if pos > gb.gap_start {
		n := pos - gb.gap_start
		copy(gb.data[gb.gap_start:gb.gap_start + n], gb.data[gb.gap_end:gb.gap_end + n])
		gb.gap_start += n
		gb.gap_end += n
	}
}

gap_buffer_grow :: proc(gb: ^Gap_Buffer, min_extra: int) {
	new_cap := len(gb.data) + max(min_extra, GAP_GROW)
	new_data, _ := mem.alloc_bytes_non_zeroed(new_cap, 1)
	copy(new_data[:gb.gap_start], gb.data[:gb.gap_start])
	suffix_len := len(gb.data) - gb.gap_end
	copy(new_data[new_cap - suffix_len:], gb.data[gb.gap_end:])
	delete(gb.data)
	gb.data = new_data
	gb.gap_end = new_cap - suffix_len
}

gap_buffer_insert :: proc(gb: ^Gap_Buffer, pos: int, bs: []u8) {
	if len(bs) == 0 do return
	gap_buffer_move_gap(gb, pos)
	if gb.gap_end - gb.gap_start < len(bs) {
		gap_buffer_grow(gb, len(bs))
	}
	copy(gb.data[gb.gap_start:gb.gap_start + len(bs)], bs)
	gb.gap_start += len(bs)
	gb.version += 1
}

// Delete `count` bytes starting at byte position `pos`.
gap_buffer_delete :: proc(gb: ^Gap_Buffer, pos: int, count: int) {
	if count <= 0 do return
	gap_buffer_move_gap(gb, pos)
	gb.gap_end = min(gb.gap_end + count, len(gb.data))
	gb.version += 1
}

// Allocates a contiguous copy of the logical text. Useful for save/render.
gap_buffer_to_string :: proc(gb: ^Gap_Buffer, allocator := context.allocator) -> string {
	n := gap_buffer_len(gb)
	out := make([]u8, n, allocator)
	copy(out[:gb.gap_start], gb.data[:gb.gap_start])
	copy(out[gb.gap_start:], gb.data[gb.gap_end:])
	return string(out)
}
