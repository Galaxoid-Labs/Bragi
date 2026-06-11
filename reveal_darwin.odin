#+build darwin
package bragi

import "core:strings"
import "core:sys/posix"

// Reveal `path` in Finder, selecting the item: `open -R <path>`. Uses the
// absolute /usr/bin/open so it works regardless of the (often stripped) PATH a
// GUI launch inherits. Fire-and-forget — we don't wait on the child.
reveal_path :: proc(path: string, is_dir: bool) {
	argv := [?]cstring{
		"open",
		"-R",
		strings.clone_to_cstring(path, context.temp_allocator),
		nil,
	}
	pid: posix.pid_t
	_ = posix.posix_spawn(&pid, "/usr/bin/open", nil, nil, raw_data(argv[:]), nil)
}
