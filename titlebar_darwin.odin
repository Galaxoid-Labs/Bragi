package bragi

import NS "core:sys/darwin/Foundation"
import sdl "vendor:sdl3"

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

	// TODO(macos): kill the slight live-resize flicker. During a drag Cocoa
	// blocks the main thread (so the main render loop is frozen and the
	// synchronous `resize_event_watch` redraw is the only draw path — see
	// WATCH_REDRAWS_ON_RESIZE in main.odin; it must STAY on for macOS). The
	// flicker is Cocoa briefly stretching the previous frame to the new size
	// before our redraw lands.
	//
	// Fix is a one-liner on the SDL content view, but it's macOS-only and needs
	// on-device A/B (compile + eyeball) — do it on a Mac, not blind from Linux:
	//
	//   view := NS.Window_contentView(nswin)   // already bound
	//   // Option A (try first): stop AppKit caching/stretching old content.
	//   //   raw msgSend "setLayerContentsRedrawPolicy:" with
	//   //   NSViewLayerContentsRedrawDuringViewResize (= 2).
	//   // Option B: if the layer still resizes async, also pin the layer's
	//   //   contentsGravity = kCAGravityTopLeft, and/or set
	//   //   presentsWithTransaction on the CAMetalLayer + present inside a
	//   //   CATransaction.
	//
	// Note `preservesContentDuringLiveResize` is read-only on NSView
	// (override-only), so target `layerContentsRedrawPolicy` instead. The policy
	// setter needs a raw `msgSend` (no Foundation wrapper for it yet).
	// Risk: an SDL/Metal interaction could regress to a blank/white window
	// (cf. the -o:speed SDL_RenderFillRect bug), so verify a filled rect resizes
	// cleanly end-to-end before committing.
}
