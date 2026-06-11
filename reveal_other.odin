#+build linux, freebsd, openbsd, netbsd
package bragi

import "core:fmt"
import "core:path/filepath"
import "core:strings"
import sdl "vendor:sdl3"

// No portable "reveal and select" on Linux/BSD file managers, so open the
// containing folder via the desktop's default handler (SDL_OpenURL → xdg-open).
reveal_path :: proc(path: string, is_dir: bool) {
	dir := is_dir ? path : filepath.dir(path)
	_ = sdl.OpenURL(strings.clone_to_cstring(fmt.tprintf("file://%s", dir), context.temp_allocator))
}
