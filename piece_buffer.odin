package bragi

// Piece-table backing store for `Editor.buffer`. Drop-in replacement for
// `Gap_Buffer`: same proc surface (`piece_buffer_*`), same `version: u64`
// contract for cache keys, same byte-position addressing.
//
// The model:
//   - `original` is the file's bytes as loaded — immutable from this
//     buffer's perspective. Loaded once on file open, never re-allocated.
//   - `added` is an append-only `[dynamic]u8` that captures every byte
//     ever inserted via the editor. Never compacted; pieces still
//     pointing at old offsets stay valid forever.
//   - `pieces` is an ordered list whose concatenation is the current
//     document. Each piece is a (source, start, length) triple
//     pointing at a byte range in either `original` or `added`.
//
// Why a piece *list* rather than VS Code's piece *tree* (RB-balanced):
//   - Insert / delete are O(N pieces) here vs O(log N) for the tree.
//   - With piece coalescing on consecutive typing (extending the
//     previous Added piece in place), real-world piece counts stay in
//     the dozens or low hundreds, not the millions where the tree
//     wins. The flat list is ~250 lines; the tree is ~600+.
//   - The proc surface is identical. If sustained editing on a
//     gigabyte file ever becomes a real workflow, swap the internals
//     for a tree without touching call sites.
//
// What this buys us over the gap buffer:
//   - Far cursor jumps no longer trigger O(distance) gap moves.
//   - First edit on a freshly-loaded file is O(1) (one piece append),
//     not O(file_size) (gap-buffer copy).
//   - Mmap is a follow-up: just point `original` at a mmap'd region
//     instead of an allocated slice. No other code changes.

Piece_Source :: enum u8 {
	Original,
	Added,
}

Piece :: struct {
	source: Piece_Source,
	start:  int, // byte offset into the source buffer
	length: int, // byte count
}

Piece_Buffer :: struct {
	// Immutable origin bytes (file load). Owned by this buffer; the
	// destroy proc dispatches on `original_mmap`:
	//   - nil      → `original` was allocated via make([]u8); `delete`.
	//   - non-nil  → `original` is a view into an mmap'd region;
	//                `mmap_release(original_mmap, original_mmap_size)`
	//                hands the mapping back to the kernel.
	// Empty for buffers that started blank (e.g. the welcome pane).
	original:           []u8,
	original_mmap:      rawptr, // mmap base address, or nil if heap-allocated
	original_mmap_size: int,    // full mapping size (may exceed len(original) after CRLF compaction)
	// Append-only edit log. Every inserted byte ever lives here; old
	// pieces keep pointing at it forever. Never compacted.
	added: [dynamic]u8,
	// Ordered list. Concatenation = current document.
	pieces: [dynamic]Piece,
	// Sum of piece lengths. O(1) length queries; updated in lock-step
	// with every mutation.
	total: int,
	// Bumped on every mutation. All Editor caches key off this.
	version: u64,

	// Sequential-access cache. Most callers (line tokenize, scan-for-
	// match, draw_editor) ask for byte_at(pos) at consecutive offsets.
	// Caching the last piece + its cumulative offset makes consecutive
	// hits inside the same piece O(1), and the very common
	// "stepped past the end of this piece into the next one" case a
	// O(1) check rather than a full piece-list scan.
	cache_idx:    int, // -1 means no valid cache
	cache_offset: int, // cumulative offset of pieces[cache_idx]
}

// ──────────────────────────────────────────────────────────────────
// Constructors / destructors
// ──────────────────────────────────────────────────────────────────

piece_buffer_make :: proc() -> Piece_Buffer {
	return Piece_Buffer{cache_idx = -1}
}

// Takes ownership of `initial` as the immutable `original` buffer. The
// load path uses this to hand the freshly-read (and CRLF-normalised)
// file bytes to the buffer without an extra copy. After this call,
// `initial` MUST NOT be modified or freed by the caller — the buffer
// owns it and will free it in piece_buffer_destroy.
piece_buffer_make_from_bytes :: proc(initial: []u8) -> Piece_Buffer {
	gb := Piece_Buffer{
		original  = initial,
		cache_idx = -1,
	}
	if len(initial) > 0 {
		append(&gb.pieces, Piece{source = .Original, start = 0, length = len(initial)})
		gb.total = len(initial)
	}
	return gb
}

// As `_make_from_bytes`, but for mmap'd `original`. The buffer takes
// ownership of the mapping; destroy hands it back via `mmap_release`.
// `mapping` is the kernel-returned base address (= `&data[0]` for
// untouched mappings; tracked separately in case `data` later shrinks
// to a sub-slice after CRLF compaction). `mapping_size` is the full
// mapped length, which `munmap` requires.
piece_buffer_make_from_mmap :: proc(data: []u8, mapping: rawptr, mapping_size: int) -> Piece_Buffer {
	gb := Piece_Buffer{
		original           = data,
		original_mmap      = mapping,
		original_mmap_size = mapping_size,
		cache_idx          = -1,
	}
	if len(data) > 0 {
		append(&gb.pieces, Piece{source = .Original, start = 0, length = len(data)})
		gb.total = len(data)
	}
	return gb
}

piece_buffer_destroy :: proc(gb: ^Piece_Buffer) {
	if gb.original_mmap != nil {
		mmap_release(gb.original_mmap, gb.original_mmap_size)
	} else {
		delete(gb.original)
	}
	delete(gb.added)
	delete(gb.pieces)
	gb^ = {}
}

// ──────────────────────────────────────────────────────────────────
// Read API (no mutation, no version bump)
// ──────────────────────────────────────────────────────────────────

piece_buffer_len :: proc(gb: ^Piece_Buffer) -> int {
	return gb.total
}

// Byte at logical position `pos`. Out-of-bounds returns 0 — matches
// gap_buffer_byte_at's behavior, which the rest of the codebase
// relies on for past-the-end peeks.
piece_buffer_byte_at :: proc(gb: ^Piece_Buffer, pos: int) -> u8 {
	if pos < 0 || pos >= gb.total do return 0

	// Hot path: cached piece still contains pos.
	if gb.cache_idx >= 0 && gb.cache_idx < len(gb.pieces) {
		p := gb.pieces[gb.cache_idx]
		if pos >= gb.cache_offset && pos < gb.cache_offset + p.length {
			src := piece_buffer_source(gb, p)
			return src[p.start + (pos - gb.cache_offset)]
		}

		// Sequential walk: most cache misses step into the next piece.
		next_idx := gb.cache_idx + 1
		if next_idx < len(gb.pieces) {
			next_off := gb.cache_offset + p.length
			next := gb.pieces[next_idx]
			if pos >= next_off && pos < next_off + next.length {
				gb.cache_idx    = next_idx
				gb.cache_offset = next_off
				src := piece_buffer_source(gb, next)
				return src[next.start + (pos - next_off)]
			}
		}
	}

	// Cold path: linear scan, refreshing the cache on hit.
	offset := 0
	for piece, idx in gb.pieces {
		if pos < offset + piece.length {
			gb.cache_idx    = idx
			gb.cache_offset = offset
			src := piece_buffer_source(gb, piece)
			return src[piece.start + (pos - offset)]
		}
		offset += piece.length
	}
	return 0 // unreachable given the bounds check above
}

// Allocates a contiguous copy of the logical text. Used for save and
// clipboard paths. Walks the piece list once; total cost = O(total).
piece_buffer_to_string :: proc(gb: ^Piece_Buffer, allocator := context.allocator) -> string {
	if gb.total <= 0 do return ""
	out := make([]u8, gb.total, allocator)
	pos := 0
	for piece in gb.pieces {
		src := piece_buffer_source(gb, piece)
		copy(out[pos:], src[piece.start : piece.start + piece.length])
		pos += piece.length
	}
	return string(out)
}

// Read-only accessor used by ensure_line_starts and similar fast-path
// scanners. Returning the raw slice avoids a per-byte branch through
// piece_buffer_byte_at when the caller wants to walk every byte in
// piece-order. Caller MUST NOT modify the returned slice.
piece_buffer_pieces :: proc(gb: ^Piece_Buffer) -> []Piece {
	return gb.pieces[:]
}

// Underlying byte slice for a piece. Returns a view into `original`
// or `added`; caller MUST NOT modify. Used together with
// `piece_buffer_pieces` by the line-cache scanner.
piece_buffer_source :: proc(gb: ^Piece_Buffer, piece: Piece) -> []u8 {
	switch piece.source {
	case .Original: return gb.original
	case .Added:    return gb.added[:]
	}
	return nil
}

// ──────────────────────────────────────────────────────────────────
// Mutation API
// ──────────────────────────────────────────────────────────────────

// Insert `bs` at byte position `pos`. Out-of-range positions are
// clamped to [0, total]; a negative `pos` is treated as 0, a `pos`
// past the end appends.
piece_buffer_insert :: proc(gb: ^Piece_Buffer, pos: int, bs: []u8) {
	if len(bs) == 0 do return
	clamped := clamp(pos, 0, gb.total)

	// Bytes go into `added` first; the piece(s) we insert reference them.
	add_start := len(gb.added)
	append(&gb.added, ..bs)

	// Coalescing: if the previous piece points at the tail of `added`
	// and we're inserting at exactly its end, just extend its length.
	// Halves piece count during typing runs (one keypress = one byte
	// = one piece without this; one byte = +1 to existing piece with).
	if try_coalesce_insert(gb, clamped, add_start, len(bs)) {
		gb.total   += len(bs)
		gb.version += 1
		invalidate_cache(gb)
		return
	}

	// Locate the piece that contains `clamped`.
	piece_idx, in_piece_offset := find_piece(gb, clamped)

	new_piece := Piece{source = .Added, start = add_start, length = len(bs)}

	if piece_idx == len(gb.pieces) {
		// At end of buffer — append.
		append(&gb.pieces, new_piece)
	} else if in_piece_offset == 0 {
		// At a piece boundary — splice between pieces.
		inject_at(&gb.pieces, piece_idx, new_piece)
	} else {
		// Mid-piece — split the existing piece into two halves and
		// insert the new piece between them.
		old   := gb.pieces[piece_idx]
		left  := Piece{source = old.source, start = old.start,                       length = in_piece_offset}
		right := Piece{source = old.source, start = old.start + in_piece_offset,     length = old.length - in_piece_offset}
		gb.pieces[piece_idx] = left
		inject_at(&gb.pieces, piece_idx + 1, new_piece)
		inject_at(&gb.pieces, piece_idx + 2, right)
	}

	gb.total   += len(bs)
	gb.version += 1
	invalidate_cache(gb)
}

// Delete `count` bytes starting at byte position `pos`. Counts past
// the end of the buffer are clamped. Mirrors gap_buffer_delete's
// signature exactly so the editor wrappers don't need to change.
piece_buffer_delete :: proc(gb: ^Piece_Buffer, pos: int, count: int) {
	if count <= 0 do return
	from := max(pos, 0)
	to   := min(pos + count, gb.total)
	if from >= to do return

	start_idx, start_off := find_piece(gb, from)
	end_idx,   end_off   := find_piece(gb, to)

	// Build at most two replacement pieces: the surviving prefix of
	// the start piece (when from is mid-piece) and the surviving
	// suffix of the end piece (when to is mid-piece). Either may be
	// absent.
	replacements: [2]Piece
	n_repl := 0

	if start_off > 0 {
		old := gb.pieces[start_idx]
		replacements[n_repl] = Piece{source = old.source, start = old.start, length = start_off}
		n_repl += 1
	}
	if end_idx < len(gb.pieces) && end_off > 0 {
		old := gb.pieces[end_idx]
		replacements[n_repl] = Piece{
			source = old.source,
			start  = old.start + end_off,
			length = old.length - end_off,
		}
		n_repl += 1
	}

	// Determine the inclusive last piece index to remove. If `to`
	// landed exactly at a piece boundary (end_off == 0), end_idx
	// points at a piece we don't touch — back off by one.
	last_inclusive := end_idx
	if end_off == 0 do last_inclusive -= 1
	if last_inclusive < start_idx do last_inclusive = start_idx - 1

	// Splice: remove pieces[start_idx ..= last_inclusive], then insert
	// the replacements at start_idx.
	if last_inclusive >= start_idx {
		n_remove := last_inclusive - start_idx + 1
		// Shift the tail down to overwrite the removed slots in one
		// memmove rather than n_remove separate ordered_remove calls.
		copy(gb.pieces[start_idx:], gb.pieces[start_idx + n_remove:])
		resize(&gb.pieces, len(gb.pieces) - n_remove)
	}
	for i in 0 ..< n_repl {
		inject_at(&gb.pieces, start_idx + i, replacements[i])
	}

	gb.total   -= (to - from)
	gb.version += 1
	invalidate_cache(gb)
}

// ──────────────────────────────────────────────────────────────────
// Internal helpers
// ──────────────────────────────────────────────────────────────────

// Locate the piece containing position `pos`, returning the piece's
// index and the offset within that piece. For `pos == total`, returns
// `(len(pieces), 0)` — caller treats it as an "append-at-end" sentinel.
@(private="file")
find_piece :: proc(gb: ^Piece_Buffer, pos: int) -> (idx: int, in_piece_offset: int) {
	if pos <= 0 do return 0, 0
	if pos >= gb.total do return len(gb.pieces), 0

	// Cache fast path.
	if gb.cache_idx >= 0 && gb.cache_idx < len(gb.pieces) {
		p := gb.pieces[gb.cache_idx]
		if pos >= gb.cache_offset && pos < gb.cache_offset + p.length {
			return gb.cache_idx, pos - gb.cache_offset
		}
	}

	offset := 0
	for piece, i in gb.pieces {
		if pos < offset + piece.length {
			gb.cache_idx    = i
			gb.cache_offset = offset
			return i, pos - offset
		}
		offset += piece.length
	}
	return len(gb.pieces), 0
}

// Coalesce check: is `pos` exactly at the end of a piece that was the
// last thing added to `added`? If so, just extend its length and avoid
// allocating a new piece.
@(private="file")
try_coalesce_insert :: proc(gb: ^Piece_Buffer, pos: int, add_start: int, n: int) -> bool {
	if pos != gb.total do return false                  // only coalesce at append-at-end
	if len(gb.pieces) == 0 do return false
	last := &gb.pieces[len(gb.pieces) - 1]
	if last.source != .Added do return false
	if last.start + last.length != add_start do return false  // must be contiguous in `added`
	last.length += n
	return true
}

@(private="file")
invalidate_cache :: proc(gb: ^Piece_Buffer) {
	gb.cache_idx    = -1
	gb.cache_offset = 0
}

