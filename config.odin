package bragi

import "core:encoding/ini"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import sdl "vendor:sdl3"
import ttf "vendor:sdl3/ttf"

// User configuration. Defaults match the previously-hardcoded constants;
// `config_load` parses an INI file and overrides any fields it finds.
Config :: struct {
	font:   Font_Config,
	editor: Editor_Config,
	theme:  Theme,
}

Font_Config :: struct {
	path:    string,
	size:    f32,
	hinting: ttf.Hinting,
}

Editor_Config :: struct {
	tab_size:     int,
	column_guide: int,
	line_spacing: f32,
	// Vim-style case sensitivity for search and :s.
	//   ignorecase = true   → /foo also matches Foo, FOO, etc.
	//   smartcase  = true   → only ignore case when pattern is all lowercase.
	// `\c` / `\C` in a pattern (and `i` / `I` flag on :s) override per call.
	ignorecase:   bool,
	smartcase:    bool,
}

// Heavily-commented template seeded into a fresh buffer when the user
// invokes `:config` and no config file exists yet. Values match
// DEFAULT_CONFIG exactly — keep them in sync if defaults change.
DEFAULT_CONFIG_INI :: `# Bragi configuration. Save this file to
#   macOS:   ~/Library/Application Support/Bragi/config.ini
#   Linux:   $XDG_CONFIG_HOME/bragi/config.ini  (~/.config/bragi/config.ini)
#   Windows: %APPDATA%\Bragi\config.ini
# Bragi auto-targets the right path when you save from the :config buffer.
# Restart Bragi to pick up changes.

[font]
# Path to a TTF / OTF font file. Empty → use the embedded Fira Code.
path    =
# Logical font size in pixels.
size    = 14
# Hinting mode: normal / light / light_subpixel / mono / none.
hinting = normal

[editor]
# Tab width in columns (also drives soft-tab insert width).
tab_size     = 4
# Vertical line at column N. 0 to disable.
column_guide = 120
# Line height = font.size × line_spacing.
line_spacing = 1.3
# Vim-style case behavior for /search and :s.
#   ignorecase = true   → /foo matches Foo / FOO / etc.
#   smartcase  = true   → only ignore case when the pattern is all lowercase.
# \c / \C in a pattern (and i / I on :s) override per call.
ignorecase   = false
smartcase    = false

[theme]
# Each value is #RRGGBB or #RRGGBBAA.

# Syntax tokens
default  = #DCDCDC
keyword  = #C678DD
type     = #5FC8DA
constant = #E5C07B
number   = #D7915A
string   = #98C379
comment  = #5F6E82
function = #61AFEF

# Chrome
bg              = #1E1E26
cursor          = #F0C850
selection       = #465F9678
search_match    = #BE50B478
gutter_bg       = #18181E
gutter_text     = #5A5F6E
gutter_active   = #C8C8D2
status_bg       = #14141A
status_path_bg  = #1C1C24
status_text     = #C8C8D2
status_dim      = #787D8C
status_error    = #DC5A5A
sb_track        = #282830
sb_thumb        = #5A5A64
sb_thumb_hover  = #82828C
`

DEFAULT_CONFIG :: Config{
	font = {
		// Empty path means "use the embedded FiraCode TTF in the binary"
		// (see FIRA_CODE_DATA in main.odin). Set in user config to
		// override with any system font file.
		path    = "",
		size    = 14,
		hinting = .NORMAL,
	},
	editor = {
		tab_size     = 4,
		column_guide = 120,
		line_spacing = 1.3,
		ignorecase   = false,
		smartcase    = false,
	},
	theme = DEFAULT_THEME,
}

g_config: Config = DEFAULT_CONFIG

// Per-platform user CONFIG directory + "config.ini".
//   macOS:   ~/Library/Application Support/Bragi/config.ini
//   Linux:   $XDG_CONFIG_HOME/bragi/config.ini  (fallback ~/.config/bragi/...)
//   Windows: %APPDATA%\Bragi\config.ini
//
// On macOS/Windows, SDL3's GetPrefPath maps to the platform-correct config-ish
// location and auto-creates the directory. On Linux it returns the *data* dir
// (~/.local/share/...) which isn't the XDG config dir, so we compose that
// path ourselves from XDG_CONFIG_HOME.
config_path :: proc(allocator := context.allocator) -> string {
	when ODIN_OS == .Linux || ODIN_OS == .FreeBSD || ODIN_OS == .OpenBSD || ODIN_OS == .NetBSD {
		dir: string
		xdg := os.get_env("XDG_CONFIG_HOME", context.temp_allocator)
		if len(xdg) > 0 {
			dir = fmt.aprintf("%s/bragi", xdg, allocator = context.temp_allocator)
		} else {
			home := os.get_env("HOME", context.temp_allocator)
			if len(home) == 0 do return ""
			dir = fmt.aprintf("%s/.config/bragi", home, allocator = context.temp_allocator)
		}
		// Best-effort: try to create the directory so a future save_config can write.
		os.make_directory(dir)
		return fmt.aprintf("%s/config.ini", dir, allocator = allocator)
	} else {
		raw := sdl.GetPrefPath("", "Bragi")
		if raw == nil do return ""
		defer sdl.free(rawptr(raw))
		dir := string(cstring(raw)) // already includes trailing separator
		return fmt.aprintf("%sconfig.ini", dir, allocator = allocator)
	}
}

config_load :: proc() {
	path := config_path(context.temp_allocator)
	if len(path) == 0 {
		fmt.eprintln("config: could not resolve prefs path; using defaults")
		return
	}
	if !os.exists(path) {
		fmt.printfln("config: %s not found, using defaults", path)
		return
	}

	m, _, ok := ini.load_map_from_path(path, context.temp_allocator)
	if !ok {
		fmt.eprintfln("config: failed to load %s, using defaults", path)
		return
	}
	fmt.printfln("config: loaded from %s", path)

	if section, has := m["font"]; has {
		load_string(section, "path", &g_config.font.path)
		load_f32(section,    "size", &g_config.font.size)
		if v, hv := section["hinting"]; hv do g_config.font.hinting = parse_hinting(v)
	}

	if section, has := m["editor"]; has {
		load_int(section,  "tab_size",     &g_config.editor.tab_size)
		load_int(section,  "column_guide", &g_config.editor.column_guide)
		load_f32(section,  "line_spacing", &g_config.editor.line_spacing)
		load_bool(section, "ignorecase",   &g_config.editor.ignorecase)
		load_bool(section, "smartcase",    &g_config.editor.smartcase)
	}

	if section, has := m["theme"]; has {
		// Syntax tokens.
		load_color(section, "default",  &g_config.theme.default_color)
		load_color(section, "keyword",  &g_config.theme.keyword_color)
		load_color(section, "type",     &g_config.theme.type_color)
		load_color(section, "constant", &g_config.theme.constant_color)
		load_color(section, "number",   &g_config.theme.number_color)
		load_color(section, "string",   &g_config.theme.string_color)
		load_color(section, "comment",  &g_config.theme.comment_color)
		load_color(section, "function", &g_config.theme.function_color)
		// Chrome.
		load_color(section, "bg",              &g_config.theme.bg_color)
		load_color(section, "cursor",          &g_config.theme.cursor_color)
		load_color(section, "selection",       &g_config.theme.selection_color)
		load_color(section, "search_match",    &g_config.theme.search_match_color)
		load_color(section, "sb_track",        &g_config.theme.sb_track_color)
		load_color(section, "sb_thumb",        &g_config.theme.sb_thumb_color)
		load_color(section, "sb_thumb_hover",  &g_config.theme.sb_thumb_hover_color)
		load_color(section, "gutter_bg",       &g_config.theme.gutter_bg_color)
		load_color(section, "gutter_text",     &g_config.theme.gutter_text_color)
		load_color(section, "gutter_active",   &g_config.theme.gutter_active_color)
		load_color(section, "status_bg",       &g_config.theme.status_bg_color)
		load_color(section, "status_path_bg",  &g_config.theme.status_path_bg_color)
		load_color(section, "status_text",     &g_config.theme.status_text_color)
		load_color(section, "status_dim",      &g_config.theme.status_dim_color)
		load_color(section, "status_error",    &g_config.theme.status_error_color)
	}
}

// ──────────────────────────────────────────────────────────────────
// helpers
// ──────────────────────────────────────────────────────────────────

@(private="file")
parse_color :: proc(s: string) -> (c: sdl.Color, ok: bool) {
	t := strings.trim_space(s)
	if len(t) == 0 || t[0] != '#' do return {}, false
	hex := t[1:]
	if len(hex) == 6 {
		r, rok := strconv.parse_uint(hex[0:2], 16)
		g, gok := strconv.parse_uint(hex[2:4], 16)
		b, bok := strconv.parse_uint(hex[4:6], 16)
		if !rok || !gok || !bok do return {}, false
		return sdl.Color{u8(r), u8(g), u8(b), 255}, true
	}
	if len(hex) == 8 {
		r, rok := strconv.parse_uint(hex[0:2], 16)
		g, gok := strconv.parse_uint(hex[2:4], 16)
		b, bok := strconv.parse_uint(hex[4:6], 16)
		a, aok := strconv.parse_uint(hex[6:8], 16)
		if !rok || !gok || !bok || !aok do return {}, false
		return sdl.Color{u8(r), u8(g), u8(b), u8(a)}, true
	}
	return {}, false
}

@(private="file")
parse_hinting :: proc(s: string) -> ttf.Hinting {
	switch strings.to_lower(strings.trim_space(s), context.temp_allocator) {
	case "normal":         return .NORMAL
	case "light":          return .LIGHT
	case "light_subpixel": return .LIGHT_SUBPIXEL
	case "mono":           return .MONO
	case "none":           return .NONE
	}
	return .NORMAL
}

@(private="file")
load_string :: proc(section: map[string]string, key: string, dest: ^string) {
	if v, ok := section[key]; ok {
		dest^ = strings.clone(strings.trim_space(v))
	}
}

@(private="file")
load_int :: proc(section: map[string]string, key: string, dest: ^int) {
	if v, ok := section[key]; ok {
		if x, parsed := strconv.parse_int(strings.trim_space(v)); parsed do dest^ = x
	}
}

@(private="file")
load_f32 :: proc(section: map[string]string, key: string, dest: ^f32) {
	if v, ok := section[key]; ok {
		if x, parsed := strconv.parse_f32(strings.trim_space(v)); parsed do dest^ = x
	}
}

@(private="file")
load_color :: proc(section: map[string]string, key: string, dest: ^sdl.Color) {
	if v, ok := section[key]; ok {
		if c, cok := parse_color(v); cok do dest^ = c
	}
}

@(private="file")
load_bool :: proc(section: map[string]string, key: string, dest: ^bool) {
	if v, ok := section[key]; ok {
		switch strings.to_lower(strings.trim_space(v), context.temp_allocator) {
		case "true", "1", "yes", "on":  dest^ = true
		case "false", "0", "no", "off": dest^ = false
		}
	}
}
