package bragi

import "base:intrinsics"
import NS "core:sys/darwin/Foundation"
import sdl "vendor:sdl3"

// CALayerContentsGravity constant (an NSString *) from QuartzCore. Pinning the
// Metal layer's contentsGravity to top-left stops it from scaling the stale
// frame during a live resize (see configure_titlebar).
foreign import quartz_core "system:QuartzCore.framework"
foreign quartz_core {
	kCAGravityTopLeft: ^NS.String
}

// Standard macOS title-bar height in *logical* pixels. Has been 28 pt
// since Big Sur (2020). Used by `compute_layout` to push the editor
// content down so the traffic-light buttons don't overlap line 1.
TITLEBAR_H :: f32(28)

// Reach through SDL's property bag to get the underlying NSWindow
// pointer, then turn on the modern transparent-titlebar look:
//
//   - Style mask gains `.FullSizeContentView` so the window's content
//     view fills the full frame, including under the title bar (which
//     is what makes the editor extend up to row 0 visually).
//   - `setTitlebarAppearsTransparent(true)` removes the chrome behind
//     the traffic lights.
//   - `setTitleVisibility(.Hidden)` suppresses the document-title text
//     (which would otherwise float over our content).
//
// The traffic-light buttons stay in their default position and remain
// fully functional. Cocoa keeps title-bar drag hit-testing too — the
// user can grab the empty area to move the window — so we don't need
// to add any custom drag region.
configure_titlebar :: proc(window: ^sdl.Window) {
	if window == nil do return
	props := sdl.GetWindowProperties(window)
	if props == 0 do return

	raw := sdl.GetPointerProperty(props, sdl.PROP_WINDOW_COCOA_WINDOW_POINTER, nil)
	if raw == nil do return
	nswin := cast(^NS.Window)raw

	// SDL3 creates a resizable+titled window for us, so we know the
	// existing style mask. Re-state it explicitly with our extra flag
	// rather than reading the current mask back — `setStyleMask:`
	// fully replaces, and getting the prior value would mean a raw
	// objc_send call for one bit we already know about.
	mask := NS.WindowStyleMask{
		.Titled,
		.Closable,
		.Miniaturizable,
		.Resizable,
		.FullSizeContentView,
	}
	NS.Window_setStyleMask(nswin, mask)
	NS.Window_setTitlebarAppearsTransparent(nswin, true)
	NS.Window_setTitleVisibility(nswin, .Hidden)

	configure_metal_layer_for_resize()
}

// Tame the live-resize ghosting. During a drag Cocoa blocks the main thread (so
// the synchronous `resize_event_watch` redraw is the only draw path — see
// WATCH_REDRAWS_ON_RESIZE in main.odin; it must STAY on for macOS). The
// CAMetalLayer's default contentsGravity is `resize`, so for the frame where the
// layer's bounds have already grown but the next drawable hasn't presented yet,
// Core Animation SCALES the previous drawable to fill — that scale-up of the
// text is the ghost/shiver. Pinning contentsGravity to top-left keeps the stale
// frame anchored at the origin (where the editor content is); only the newly
// exposed right/bottom strip lags a frame, which reads as clean.
//
// This MUST target the renderer's own CAMetalLayer. SDL's Metal renderer hosts
// the layer on a private metal subview, NOT the window content view, so the
// earlier attempts at `contentView.layer` were messaging the wrong object (zero
// effect). SDL_GetRenderMetalLayer returns the real one — nil if the active
// renderer isn't Metal, in which case this no-ops.
@(private="file")
configure_metal_layer_for_resize :: proc() {
	raw_layer := sdl.GetRenderMetalLayer(g_renderer)
	if raw_layer == nil do return
	layer := cast(^NS.Layer)raw_layer
	intrinsics.objc_send(nil, layer, "setContentsGravity:", kCAGravityTopLeft)
}
