package bragi

// Minimal Odin foreign bindings for the fff file-search C library
// (github.com/dmtrKovalenko/fff, header crates/fff-c/include/fff.h).
//
// fff is a *recursive* fuzzy file indexer: you create an instance rooted
// at a directory, it scans the whole tree (honoring .gitignore) in the
// background, and `fff_search` returns ranked matches across every
// indexed file. We use it to back the Cmd/Ctrl+F finder (see
// finder.odin), replacing the old directory-browser + hand-rolled
// subsequence scorer.
//
// Only the surface we actually need is bound:
//   - instance lifecycle (create_with / destroy / restart_index)
//   - scan status (wait_for_scan / is_scanning)
//   - file search + result accessors
//   - the matching free functions
//
// The prebuilt `c-lib-*` libraries are vendored under vendor/fff/ (one
// per target triple). On macOS their install_name is rewritten to
// `@loader_path/vendor/fff/<file>` so a dev `./Bragi` at the repo root
// resolves them with no rpath fiddling; the packaging script copies the
// matching dylib into the .app's Frameworks/ and rewrites the reference
// to @rpath. See vendor/fff/README.md.

when ODIN_OS == .Darwin {
	when ODIN_ARCH == .arm64 {
		foreign import fff_lib { "vendor/fff/libfff_c-aarch64-darwin.dylib" }
	} else {
		foreign import fff_lib { "vendor/fff/libfff_c-x86_64-darwin.dylib" }
	}
} else when ODIN_OS == .Linux {
	when ODIN_ARCH == .arm64 {
		foreign import fff_lib { "vendor/fff/libfff_c-aarch64-linux.so" }
	} else {
		foreign import fff_lib { "vendor/fff/libfff_c-x86_64-linux.so" }
	}
} else when ODIN_OS == .Windows {
	// The fff release ships only `c-lib-*-windows-msvc.dll`, no import
	// library. MSVC linking needs a `.lib`; generate one from the DLL
	// (`dlltool` / `lib /def:`) into vendor/fff/fff_c.lib and ship the
	// matching DLL next to Bragi.exe, mirroring vendor/libvterm. Until
	// that exists this branch won't link on Windows.
	foreign import fff_lib { "vendor/fff/fff_c.lib" }
}

// Pass as `FffCreateOptions.version`. Matches FFF_CREATE_OPTIONS_VERSION
// in fff.h — the struct only ever grows by appending fields, so a v1
// caller keeps working against newer libraries.
FFF_CREATE_OPTIONS_VERSION :: 1

// Result envelope returned (by pointer) from every fff_* call. Layout
// must match `struct FffResult`. `error` is null on success. Free the
// envelope with `fff_free_result` — that does NOT free `handle`, which
// owns a payload (search result, instance, etc.) freed separately.
FffResult :: struct {
	success:   bool,
	error:     cstring,
	handle:    rawptr,
	int_value: i64,
}

// Versioned init options. Field order / types mirror `struct
// FffCreateOptions` exactly. Zero-value the struct, set `version` and
// `base_path`, flip the bools you want. NULL/empty cstrings disable the
// corresponding feature (frecency, history, logging).
FffCreateOptions :: struct {
	version:                    u32,
	base_path:                  cstring,
	frecency_db_path:           cstring,
	history_db_path:            cstring,
	enable_mmap_cache:          bool,
	enable_content_indexing:    bool,
	watch:                      bool,
	ai_mode:                    bool,
	log_file_path:              cstring,
	log_level:                  cstring,
	cache_budget_max_files:     u64,
	cache_budget_max_bytes:     u64,
	cache_budget_max_file_size: u64,
	enable_fs_root_scanning:    bool,
	enable_home_dir_scanning:   bool,
}

// Opaque payload types — we only ever hold pointers to them and read
// through the accessor functions below, so their layout doesn't matter
// to us (and we dodge any struct-alignment ABI hazards).
FffSearchResult :: struct {} // opaque
FffFileItem     :: struct {} // opaque

@(default_calling_convention = "c")
foreign fff_lib {
	// Lifecycle. `fff_create_instance_with` returns an FffResult whose
	// `handle` is the opaque instance pointer on success.
	fff_create_instance_with :: proc(opts: ^FffCreateOptions) -> ^FffResult ---
	fff_destroy              :: proc(handle: rawptr) ---
	fff_restart_index        :: proc(handle: rawptr, new_path: cstring) -> ^FffResult ---

	// Scan status. The initial scan runs in a background thread after
	// create; search works against the partial index meanwhile.
	fff_is_scanning   :: proc(handle: rawptr) -> bool ---
	fff_wait_for_scan :: proc(handle: rawptr, timeout_ms: u64) -> ^FffResult ---

	// Fuzzy file search. Result `handle` is a ^FffSearchResult.
	//   current_file           – path to deprioritize (NULL/empty = skip)
	//   max_threads            – 0 = auto
	//   page_index / page_size – 0-based page, 0 size = default 100
	//   combo_boost_multiplier – 0 = default 100
	//   min_combo_count        – 0 = default 3
	fff_search :: proc(
		handle:                 rawptr,
		query:                  cstring,
		current_file:           cstring,
		max_threads:            u32,
		page_index:             u32,
		page_size:              u32,
		combo_boost_multiplier: i32,
		min_combo_count:        u32,
	) -> ^FffResult ---

	// Result accessors (pointers borrowed from the result; never freed
	// directly). `relative_path` is rooted at the instance's base_path.
	fff_search_result_get_count         :: proc(r: ^FffSearchResult) -> u32 ---
	fff_search_result_get_total_matched :: proc(r: ^FffSearchResult) -> u32 ---
	fff_search_result_get_total_files   :: proc(r: ^FffSearchResult) -> u32 ---
	fff_search_result_get_item          :: proc(r: ^FffSearchResult, index: u32) -> ^FffFileItem ---
	fff_file_item_get_relative_path     :: proc(item: ^FffFileItem) -> cstring ---
	fff_file_item_get_file_name         :: proc(item: ^FffFileItem) -> cstring ---
	fff_file_item_get_git_status        :: proc(item: ^FffFileItem) -> cstring ---

	// Frees.
	fff_free_result        :: proc(r: ^FffResult) ---
	fff_free_search_result :: proc(r: ^FffSearchResult) ---
	fff_free_string        :: proc(s: cstring) ---
}
