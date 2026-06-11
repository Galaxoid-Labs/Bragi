package bragi

import "core:os"
import "core:strings"

// The active workspace: a single root directory. The file-tree sidebar
// renders it and the fuzzy finder indexes it. "" means no workspace
// (single-file editing) — the finder then falls back to the git root of
// the active file (see finder_compute_root).
//
// Set four ways, all funneling through set_workspace:
//   - Open Folder dialog        (Cmd/Ctrl+Shift+O)
//   - CLI:  bragi <dir>
//   - ex-command: :cd / :workspace <path>
//   - dropping a folder on the window
g_workspace_root: string // owned

// Point the workspace at `path` when it's a real directory. Strips a
// trailing slash (except a lone "/"). Returns false (and leaves the
// current workspace untouched) when `path` isn't a directory.
set_workspace :: proc(path: string) -> bool {
	trimmed := strings.trim_space(path)
	for len(trimmed) > 1 && strings.has_suffix(trimmed, "/") {
		trimmed = trimmed[:len(trimmed) - 1]
	}
	if len(trimmed) == 0 || !os.is_dir(trimmed) do return false

	// Resolve to an absolute path so the header / fff index / tree don't
	// depend on the process cwd (and "." shows the folder name, not ".").
	abs, aerr := os.get_absolute_path(trimmed, context.temp_allocator)
	resolved := aerr == nil ? abs : trimmed

	if len(g_workspace_root) > 0 do delete(g_workspace_root)
	g_workspace_root = strings.clone(resolved)

	// Track it in Open Recent (most-recent-first, deduped).
	recent_record_dir(g_workspace_root)

	// Opening a folder reveals + focuses the file tree (any entry point:
	// dialog, CLI, :cd, drop). Set before the rebuild below so it runs.
	g_sidebar_visible = true
	g_sidebar_active  = true

	// Re-point the finder's index now so the next Cmd/Ctrl+F is instant,
	// and refresh the file tree for the new root.
	finder_set_workspace_root(g_workspace_root)
	sidebar_on_workspace_changed()
	// Overlay this project's bragi.ini [lsp] section before the LSP teardown
	// below, so the servers respawn against the project's jai_entry/compiler.
	project_config_apply()
	lsp_on_workspace_changed()
	return true
}

workspace_destroy :: proc() {
	if len(g_workspace_root) > 0 {
		delete(g_workspace_root)
		g_workspace_root = ""
	}
}
