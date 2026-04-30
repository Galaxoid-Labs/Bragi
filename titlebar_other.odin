#+build !darwin
package bragi

import sdl "vendor:sdl3"

// Non-Darwin platforms: no transparent-titlebar magic to apply, and
// no extra vertical space to reserve at the top of the editor zone.
// Keep the constant + proc symbol so `main.odin`'s call sites stay
// identical across platforms.
TITLEBAR_H :: f32(0)

configure_titlebar :: proc(window: ^sdl.Window) {
	// Intentionally blank.
	_ = window
}
