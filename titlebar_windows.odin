#+build windows
package bragi

import sdl "vendor:sdl3"
import win "core:sys/windows"

// We keep the system titlebar (no extending the editor under it like
// the macOS path does), so reserve no extra room at the top of the
// editor zone — keeps `compute_layout` cross-platform without a
// special-case.
TITLEBAR_H :: f32(0)

// DWMWA_SYSTEMBACKDROP_TYPE values. Win11 22H2+ — older builds
// silently ignore the attribute when DwmSetWindowAttribute is called,
// so this is safe to set unconditionally.
@(private="file") DWMSBT_AUTO            :: i32(0)
@(private="file") DWMSBT_NONE            :: i32(1)
@(private="file") DWMSBT_MAINWINDOW      :: i32(2) // Mica
@(private="file") DWMSBT_TRANSIENTWINDOW :: i32(3) // Acrylic
@(private="file") DWMSBT_TABBEDWINDOW    :: i32(4) // Mica Alt

// Reach through SDL's property bag for the underlying HWND, then ask
// DWM to repaint the window's non-client chrome with the modern Win11
// look:
//
//   - `DWMWA_USE_IMMERSIVE_DARK_MODE` paints the titlebar dark so it
//     matches the editor theme instead of the bright system caption
//     (Win10 1809+).
//   - `DWMWA_WINDOW_CORNER_PREFERENCE = ROUND` opts into the Win11
//     rounded-corner window shape (no-op on Win10).
//   - `DWMWA_SYSTEMBACKDROP_TYPE = DWMSBT_MAINWINDOW` enables the Mica
//     backdrop (Win11 22H2+). The backdrop only shows where the window
//     is alpha-transparent — currently that's just the titlebar strip
//     since the client area paints opaque, which is exactly the modern
//     "Notepad / Settings" look.
//
// All three calls return an HRESULT we ignore; on unsupported builds
// the unknown attribute is rejected with E_INVALIDARG and the visual
// just gracefully degrades.
configure_titlebar :: proc(window: ^sdl.Window) {
	if window == nil do return
	props := sdl.GetWindowProperties(window)
	if props == 0 do return

	raw := sdl.GetPointerProperty(props, sdl.PROP_WINDOW_WIN32_HWND_POINTER, nil)
	if raw == nil do return
	hwnd := win.HWND(raw)

	dark : win.BOOL = win.TRUE
	_ = win.DwmSetWindowAttribute(
		hwnd, win.DWORD(win.DWMWINDOWATTRIBUTE.DWMWA_USE_IMMERSIVE_DARK_MODE),
		&dark, size_of(dark),
	)

	corner : win.DWM_WINDOW_CORNER_PREFERENCE = .ROUND
	_ = win.DwmSetWindowAttribute(
		hwnd, win.DWORD(win.DWMWINDOWATTRIBUTE.DWMWA_WINDOW_CORNER_PREFERENCE),
		&corner, size_of(corner),
	)

	backdrop : i32 = DWMSBT_MAINWINDOW
	_ = win.DwmSetWindowAttribute(
		hwnd, win.DWORD(win.DWMWINDOWATTRIBUTE.DWMWA_SYSTEMBACKDROP_TYPE),
		&backdrop, size_of(backdrop),
	)
}
