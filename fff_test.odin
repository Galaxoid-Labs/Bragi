package bragi

// End-to-end smoke test for the fff bindings (fff.odin): index this repo,
// wait for the scan, search, and confirm we can read results back through
// the accessor functions. Run from the repo root so @loader_path resolves
// the vendored dylib:
//
//   odin test . -out:./bragi_test
//
// (The -out path matters: the test binary's directory must contain
// vendor/fff/ for the dylib's @loader_path id to resolve.)

import "core:os"
import "core:strings"
import "core:testing"

@(test)
fff_search_smoke :: proc(t: ^testing.T) {
	cwd, _ := os.get_working_directory(context.allocator)
	defer delete(cwd)

	root := strings.clone_to_cstring(cwd, context.allocator)
	defer delete(root)

	opts := FffCreateOptions {
		version   = FFF_CREATE_OPTIONS_VERSION,
		base_path = root,
	}
	create := fff_create_instance_with(&opts)
	testing.expect(t, create != nil, "create returned nil")
	if create == nil do return
	defer fff_free_result(create)
	testing.expectf(t, create.success, "create failed: %v",
		create.error != nil ? string(create.error) : "unknown")
	if !create.success || create.handle == nil do return

	handle := create.handle
	defer fff_destroy(handle)

	// Let the background scan finish so results are stable.
	if w := fff_wait_for_scan(handle, 10_000); w != nil do fff_free_result(w)

	query := strings.clone_to_cstring("finder", context.allocator)
	defer delete(query)

	res := fff_search(handle, query, nil, 0, 0, 50, 0, 0)
	testing.expect(t, res != nil, "search returned nil")
	if res == nil do return
	defer fff_free_result(res)
	testing.expect(t, res.success, "search reported failure")
	if !res.success || res.handle == nil do return

	sr := cast(^FffSearchResult)res.handle
	defer fff_free_search_result(sr)

	count := fff_search_result_get_count(sr)
	testing.expectf(t, count > 0, "expected matches for 'finder', got %d", count)

	found_finder := false
	for i in 0 ..< count {
		item := fff_search_result_get_item(sr, i)
		if item == nil do continue
		rel := fff_file_item_get_relative_path(item)
		if rel == nil do continue
		if strings.contains(string(rel), "finder.odin") {
			found_finder = true
			break
		}
	}
	testing.expect(t, found_finder, "finder.odin not among 'finder' matches")
}
