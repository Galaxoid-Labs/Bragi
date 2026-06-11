#+build windows
package bragi

import "core:fmt"
import "core:strings"
import win "core:sys/windows"

// Reveal `path` in Explorer, selecting the item: `explorer /select,<path>`.
// Native backslash separators, path quoted so spaces survive. Fire-and-forget;
// explorer is resolved off the system PATH. (CreateProcessW may write into the
// command-line buffer, so utf8_to_wstring's heap copy is what we pass.)
reveal_path :: proc(path: string, is_dir: bool) {
	native, _ := strings.replace_all(path, "/", "\\", context.temp_allocator)
	cmd   := fmt.tprintf("explorer.exe /select,\"%s\"", native)
	cmd_w := win.utf8_to_wstring(cmd, context.temp_allocator)

	si: win.STARTUPINFOW
	si.cb = size_of(win.STARTUPINFOW)
	pi: win.PROCESS_INFORMATION
	if win.CreateProcessW(nil, cmd_w, nil, nil, win.FALSE, 0, nil, nil, &si, &pi) {
		win.CloseHandle(pi.hThread)
		win.CloseHandle(pi.hProcess)
	}
}
