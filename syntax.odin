package bragi

import "core:slice"
import "core:strings"

// A Token marks a byte range within a single line that should be rendered in
// a specific color. Bytes not covered by any Token render in the default color.
Token :: struct {
	start, end: int,       // byte offsets within the line
	kind:       Token_Kind,
}

Token_Kind :: enum {
	Default,
	Keyword,
	Type,
	Constant,  // true / false / nil / NULL
	Number,
	String,    // includes char literals and raw strings
	Comment,
	Function,  // identifier immediately followed by `(`
}

// State carried between lines for multi-line constructs (block comments).
Tokenizer_State :: enum u8 {
	Normal,
	Block_Comment,
}

Language :: enum {
	None,
	Generic,
	Odin,
	C,
	Cpp,
	Go,
	Jai,
	Swift,
	Ini,
}

// Per-language data table that drives `tokenize_with_spec`. New languages
// — including future INI-loaded ones — slot in by populating one of these.
// Most fields are optional: leave a slice empty / a string `""` to disable
// the corresponding rule.
Language_Spec :: struct {
	name:                  string,    // canonical `:syntax X` name
	display_name:          string,    // human-friendly label for the status bar; defaults to `name` if empty
	aliases:               []string,  // additional `:syntax X` names
	extensions:            []string,  // file suffixes (`".odin"`, etc.)

	keywords:              []string,
	types:                 []string,
	constants:             []string,  // true / false / nil / NULL / iota / ...

	line_comment:          string,    // e.g. "//"; "" disables
	block_open:            string,    // e.g. "/*"; "" disables
	block_close:           string,    // e.g. "*/"

	double_quote_string:   bool,      // "..."
	single_quote_char:     bool,      // 'x' is a char/rune literal
	raw_string_quote:      u8,        // 0 = none; otherwise the bracketing rune (e.g. '`')

	directive_prefix:      u8,        // 0 = none; otherwise rune that starts a directive token (e.g. '#' for Jai/C)

	capitalized_types:     bool,      // CapitalizedWord → Type
	detect_function_call:  bool,      // identifier followed by '(' → Function
}

// ──────────────────────────────────────────────────────────────────
// Built-in keyword / type / constant tables
// ──────────────────────────────────────────────────────────────────

@(private="file")
ODIN_KEYWORDS := []string{
	"package", "import", "foreign", "using",
	"proc", "struct", "enum", "union", "bit_set", "bit_field",
	"if", "else", "switch", "case", "for", "do", "in", "not_in",
	"return", "break", "continue", "fallthrough", "defer",
	"when", "where", "or_return", "or_else", "or_break", "or_continue",
	"distinct", "dynamic", "auto_cast", "transmute", "cast",
	"context", "type_of", "size_of", "align_of", "offset_of", "typeid_of",
	"map", "matrix", "asm", "inline", "no_inline",
}
@(private="file")
ODIN_TYPES := []string{
	"int", "uint", "uintptr", "rawptr",
	"i8", "i16", "i32", "i64", "i128",
	"u8", "u16", "u32", "u64", "u128",
	"f16", "f32", "f64",
	"bool", "b8", "b16", "b32", "b64",
	"byte", "rune",
	"string", "cstring",
	"any", "typeid",
	"complex32", "complex64", "complex128",
	"quaternion64", "quaternion128", "quaternion256",
}
@(private="file")
ODIN_CONSTANTS := []string{ "true", "false", "nil" }

@(private="file")
C_KEYWORDS := []string{
	"if", "else", "for", "while", "do", "switch", "case", "default",
	"break", "continue", "return", "goto",
	"struct", "union", "enum", "typedef",
	"static", "extern", "const", "volatile", "register", "auto", "inline", "restrict",
	"signed", "unsigned", "short", "long",
	"sizeof", "_Alignof", "_Alignas", "_Static_assert",
}
@(private="file")
C_TYPES := []string{
	"void", "char", "int", "float", "double", "_Bool",
	"size_t", "ssize_t", "ptrdiff_t", "intptr_t", "uintptr_t",
	"int8_t",  "int16_t",  "int32_t",  "int64_t",
	"uint8_t", "uint16_t", "uint32_t", "uint64_t",
	"FILE",
}
@(private="file")
C_CONSTANTS := []string{ "NULL", "true", "false" }

@(private="file")
CPP_KEYWORDS := []string{
	"if", "else", "for", "while", "do", "switch", "case", "default",
	"break", "continue", "return", "goto",
	"struct", "union", "enum", "class", "namespace", "using", "typedef",
	"public", "private", "protected", "virtual", "override", "final", "explicit",
	"static", "extern", "const", "volatile", "constexpr", "consteval", "constinit",
	"inline", "register", "auto", "mutable", "thread_local",
	"signed", "unsigned", "short", "long",
	"template", "typename", "friend", "operator",
	"this", "new", "delete", "throw", "try", "catch", "noexcept",
	"static_cast", "dynamic_cast", "const_cast", "reinterpret_cast",
	"sizeof", "alignof", "alignas", "decltype", "typeid",
	"export", "concept", "requires", "co_await", "co_yield", "co_return",
}
@(private="file")
CPP_TYPES := []string{
	"void", "char", "wchar_t", "char8_t", "char16_t", "char32_t",
	"int", "float", "double", "bool",
	"size_t", "ssize_t", "ptrdiff_t",
	"int8_t",  "int16_t",  "int32_t",  "int64_t",
	"uint8_t", "uint16_t", "uint32_t", "uint64_t",
	"string", "string_view", "vector", "map", "set", "unordered_map", "unordered_set",
	"unique_ptr", "shared_ptr", "weak_ptr",
}
@(private="file")
CPP_CONSTANTS := []string{ "nullptr", "NULL", "true", "false" }

@(private="file")
GO_KEYWORDS := []string{
	"break", "default", "func", "interface", "select",
	"case", "defer", "go", "map", "struct", "chan",
	"else", "goto", "package", "switch",
	"const", "fallthrough", "if", "range", "type",
	"continue", "for", "import", "return", "var",
}
@(private="file")
GO_TYPES := []string{
	"bool", "byte", "rune",
	"int", "int8", "int16", "int32", "int64",
	"uint", "uint8", "uint16", "uint32", "uint64", "uintptr",
	"float32", "float64",
	"complex64", "complex128",
	"string", "error", "any",
}
@(private="file")
GO_CONSTANTS := []string{ "true", "false", "nil", "iota" }

@(private="file")
JAI_KEYWORDS := []string{
	"if", "else", "for", "while", "until", "case", "break", "continue",
	"return", "defer", "using", "cast", "xx",
	"struct", "union", "enum", "enum_flags", "operator",
	"inline", "no_inline", "must",
	"it", "it_index",
	"new", "delete", "size_of", "type_of", "type_info",
	"context", "push_context", "remove",
	"#", // placeholder so token kind exists; real handling uses directive_prefix
}
@(private="file")
JAI_TYPES := []string{
	"int", "float", "float32", "float64", "string", "bool", "void", "Any",
	"u8", "u16", "u32", "u64",
	"s8", "s16", "s32", "s64",
	"Type", "Code", "Source_Code_Location", "Allocator",
}
@(private="file")
JAI_CONSTANTS := []string{ "true", "false", "null" }

@(private="file")
SWIFT_KEYWORDS := []string{
	"func", "var", "let", "init", "deinit", "self", "super",
	"if", "else", "for", "while", "repeat", "in", "switch", "case", "default",
	"break", "continue", "fallthrough", "return", "guard", "defer", "do",
	"try", "throw", "throws", "rethrows", "catch",
	"as", "is", "where", "inout",
	"class", "struct", "enum", "protocol", "extension", "typealias",
	"import", "operator", "precedence", "associativity",
	"static", "final", "lazy", "mutating", "nonmutating", "convenience", "required",
	"private", "fileprivate", "internal", "public", "open",
	"weak", "unowned", "dynamic", "optional", "indirect", "override",
	"async", "await", "actor", "isolated", "nonisolated",
	"some", "any",
	"associatedtype", "subscript", "willSet", "didSet", "get", "set",
}
@(private="file")
SWIFT_TYPES := []string{
	"Int", "Int8", "Int16", "Int32", "Int64",
	"UInt", "UInt8", "UInt16", "UInt32", "UInt64",
	"Float", "Float32", "Float64", "Double",
	"Bool", "String", "Character", "Substring",
	"Array", "Dictionary", "Set", "Optional", "Result",
	"Void", "Any", "AnyObject", "Self",
	"Range", "ClosedRange", "Sequence", "Collection", "Iterator",
	"Error", "Never",
}
@(private="file")
SWIFT_CONSTANTS := []string{ "true", "false", "nil" }

// ──────────────────────────────────────────────────────────────────
// Spec table.  Indexed by `Language` so dispatch is O(1).
// New built-ins go in here; INI-loaded languages would extend this
// model (e.g. to a `[dynamic]Language_Spec` registry) later.
// ──────────────────────────────────────────────────────────────────

@(private="file")
g_specs := [Language]Language_Spec{
	.None    = Language_Spec{
		name = "none", aliases = []string{"off"},
	},
	.Generic = Language_Spec{
		name        = "generic",
		aliases     = []string{"basic", "any"},
		line_comment        = "//",
		block_open          = "/*",
		block_close         = "*/",
		double_quote_string = true,
		single_quote_char   = true,
		raw_string_quote    = '`',
	},
	.Odin    = Language_Spec{
		name        = "odin",
		display_name = "Odin",
		extensions  = []string{".odin"},
		keywords    = ODIN_KEYWORDS,
		types       = ODIN_TYPES,
		constants   = ODIN_CONSTANTS,
		line_comment        = "//",
		block_open          = "/*",
		block_close         = "*/",
		double_quote_string = true,
		single_quote_char   = true,
		raw_string_quote    = '`',
		capitalized_types     = true,
		detect_function_call  = true,
	},
	.C       = Language_Spec{
		name        = "c",
		display_name = "C",
		extensions  = []string{".c", ".h"},
		keywords    = C_KEYWORDS,
		types       = C_TYPES,
		constants   = C_CONSTANTS,
		line_comment        = "//",
		block_open          = "/*",
		block_close         = "*/",
		double_quote_string = true,
		single_quote_char   = true,
		directive_prefix    = '#',
		detect_function_call = true,
	},
	.Cpp     = Language_Spec{
		name        = "cpp",
		display_name = "C++",
		aliases     = []string{"c++", "cxx"},
		extensions  = []string{".cpp", ".cc", ".cxx", ".hpp", ".hh", ".hxx"},
		keywords    = CPP_KEYWORDS,
		types       = CPP_TYPES,
		constants   = CPP_CONSTANTS,
		line_comment        = "//",
		block_open          = "/*",
		block_close         = "*/",
		double_quote_string = true,
		single_quote_char   = true,
		directive_prefix    = '#',
		capitalized_types   = true,
		detect_function_call = true,
	},
	.Go      = Language_Spec{
		name        = "go",
		display_name = "Go",
		extensions  = []string{".go"},
		keywords    = GO_KEYWORDS,
		types       = GO_TYPES,
		constants   = GO_CONSTANTS,
		line_comment        = "//",
		block_open          = "/*",
		block_close         = "*/",
		double_quote_string = true,
		single_quote_char   = true,
		raw_string_quote    = '`',
		detect_function_call = true,
	},
	.Jai     = Language_Spec{
		name        = "jai",
		display_name = "Jai",
		extensions  = []string{".jai"},
		keywords    = JAI_KEYWORDS,
		types       = JAI_TYPES,
		constants   = JAI_CONSTANTS,
		line_comment        = "//",
		block_open          = "/*",
		block_close         = "*/",
		double_quote_string = true,
		single_quote_char   = true,
		directive_prefix    = '#',
		capitalized_types   = true,
		detect_function_call = true,
	},
	.Swift   = Language_Spec{
		name        = "swift",
		display_name = "Swift",
		extensions  = []string{".swift"},
		keywords    = SWIFT_KEYWORDS,
		types       = SWIFT_TYPES,
		constants   = SWIFT_CONSTANTS,
		line_comment        = "//",
		block_open          = "/*",
		block_close         = "*/",
		double_quote_string = true,
		// Swift has no single-quote literals — `'x'` isn't a thing —
		// and backtick is reserved for escaping identifiers (`class`),
		// not raw strings, so we leave both off.
		single_quote_char   = false,
		directive_prefix    = '@', // attributes: @objc, @MainActor, @escaping, …
		capitalized_types   = true,
		detect_function_call = true,
	},
	.Ini     = Language_Spec{
		// INI doesn't fit the C-family Language_Spec shape (no block
		// comments, sections aren't keywords, key/value rules differ
		// per side of the `=`). syntax_tokenize special-cases this
		// language to call `tokenize_ini` directly; the spec entry
		// is here just for the name / display / extension lookup.
		name         = "ini",
		display_name = "INI",
		extensions   = []string{".ini", ".cfg", ".conf"},
	},
}

// ──────────────────────────────────────────────────────────────────
// Public API
// ──────────────────────────────────────────────────────────────────

language_for_path :: proc(path: string) -> Language {
	for spec, lang in g_specs {
		for ext in spec.extensions {
			if strings.has_suffix(path, ext) do return lang
		}
	}
	return .None
}

language_from_name :: proc(name: string) -> (Language, bool) {
	target := strings.to_lower(name, context.temp_allocator)
	for spec, lang in g_specs {
		if spec.name == target do return lang, true
		for alias in spec.aliases {
			if alias == target do return lang, true
		}
	}
	return .None, false
}

language_name :: proc(lang: Language) -> string {
	return g_specs[lang].name
}

// Status-bar friendly label for a language. Falls back to `name` if no
// display name was set (so unconfigured / future INI specs still render).
language_display_name :: proc(lang: Language) -> string {
	spec := g_specs[lang]
	if len(spec.display_name) > 0 do return spec.display_name
	return spec.name
}

// Tokenize a single line. Returns tokens (in temp_allocator) and the state
// the next line should resume from. For Language.None, returns no tokens.
syntax_tokenize :: proc(lang: Language, line: []u8, state_in: Tokenizer_State) -> ([]Token, Tokenizer_State) {
	if lang == .None do return nil, .Normal
	if lang == .Ini  do return tokenize_ini(line), .Normal
	return tokenize_with_spec(line, state_in, &g_specs[lang])
}

// ──────────────────────────────────────────────────────────────────
// INI tokenizer
// ──────────────────────────────────────────────────────────────────
//
// Hand-rolled because the Language_Spec model is C-family-shaped and
// INI's structural elements (sections, keys, values) don't fit. Single-
// line, no inter-line state (so the proc takes just `line: []u8`).
//
// Recognises:
//   `; comment` or `# comment` at start of line   → Comment
//   `[section]`                                   → Type
//   `key = value`                                 → key as Function;
//                                                   value classified by content:
//                                                     true / false / null / yes / no  → Constant
//                                                     "..." or '...' literals        → String
//                                                     #RRGGBB / #RRGGBBAA hex colors → String
//                                                     numbers (10, 0x1f, 1.3, -2)    → Number
//                                                     anything else                  → Default
//
// `#` is intentionally not treated as an inline comment — Bragi's
// config uses `#RRGGBB` colors in the right-hand side, and supporting
// inline `#` comments would force a heuristic that's unreliable. Whole-
// line `#` and `;` comments cover everything in practice.
@(private="file")
tokenize_ini :: proc(line: []u8) -> []Token {
	tokens := make([dynamic]Token, 0, 4, context.temp_allocator)
	n := len(line)
	i := 0

	// Skip leading whitespace.
	for i < n && (line[i] == ' ' || line[i] == '\t') do i += 1
	if i >= n do return tokens[:]

	// Whole-line comment.
	if line[i] == ';' || line[i] == '#' {
		append(&tokens, Token{i, n, .Comment})
		return tokens[:]
	}

	// Section header: [name]. We highlight from the `[` through the `]`
	// (inclusive); anything after a malformed header — missing `]` —
	// just runs to end-of-line so the user can see it isn't closed.
	if line[i] == '[' {
		j := i + 1
		for j < n && line[j] != ']' do j += 1
		if j < n do j += 1   // include the ']'
		append(&tokens, Token{i, j, .Type})
		return tokens[:]
	}

	// key = value
	eq := -1
	for j := i; j < n; j += 1 {
		if line[j] == '=' { eq = j; break }
	}
	if eq < 0 do return tokens[:]   // malformed line; render plain

	// Trim trailing whitespace off the key.
	key_end := eq
	for key_end > i && (line[key_end - 1] == ' ' || line[key_end - 1] == '\t') do key_end -= 1
	if key_end > i do append(&tokens, Token{i, key_end, .Function})

	// Trim leading + trailing whitespace off the value.
	val_start := eq + 1
	for val_start < n && (line[val_start] == ' ' || line[val_start] == '\t') do val_start += 1
	val_end := n
	for val_end > val_start && (line[val_end - 1] == ' ' || line[val_end - 1] == '\t') do val_end -= 1
	if val_end > val_start {
		append(&tokens, classify_ini_value(line, val_start, val_end))
	}
	return tokens[:]
}

// Inspect a value's bytes and pick the right Token_Kind. Order matters:
// hex-color check has to come before the generic number check so
// `#FF` doesn't get mistaken for "default" via the unrecognised-prefix
// fallthrough.
@(private="file")
classify_ini_value :: proc(line: []u8, start, end: int) -> Token {
	val := line[start:end]
	m   := len(val)

	// Quoted string literal.
	if m >= 2 {
		q := val[0]
		if (q == '"' || q == '\'') && val[m - 1] == q {
			return Token{start, end, .String}
		}
	}

	// Hex color: #RRGGBB or #RRGGBBAA.
	if m == 7 || m == 9 {
		if val[0] == '#' {
			all_hex := true
			for k in 1 ..< m do if !is_hex_digit(val[k]) { all_hex = false; break }
			if all_hex do return Token{start, end, .String}
		}
	}

	// Boolean / null-ish constants. Case-insensitive on the first char
	// is enough for the common spellings; full case-fold avoids a
	// temp allocation.
	if ini_match_const(val) do return Token{start, end, .Constant}

	// Number: optional leading sign, decimal / hex / float.
	if ini_is_number(val) do return Token{start, end, .Number}

	return Token{start, end, .Default}
}

@(private="file")
ini_match_const :: proc(val: []u8) -> bool {
	// Matches: true, false, null, nil, yes, no, on, off (any case).
	@(static) CONSTS := [?]string{
		"true", "false", "null", "nil", "yes", "no", "on", "off",
	}
	if len(val) == 0 do return false
	for c in CONSTS {
		if len(c) != len(val) do continue
		match := true
		for k in 0 ..< len(c) {
			a := c[k]
			b := val[k]
			// Lowercase b if it's an uppercase ASCII letter.
			if b >= 'A' && b <= 'Z' do b += 32
			if a != b { match = false; break }
		}
		if match do return true
	}
	return false
}

@(private="file")
ini_is_number :: proc(val: []u8) -> bool {
	n := len(val)
	if n == 0 do return false
	i := 0
	if val[i] == '+' || val[i] == '-' do i += 1
	if i >= n do return false

	// 0x hex literal.
	if i + 1 < n && val[i] == '0' && (val[i + 1] == 'x' || val[i + 1] == 'X') {
		i += 2
		if i >= n do return false
		for ; i < n; i += 1 do if !is_hex_digit(val[i]) do return false
		return true
	}

	// Decimal int / float.
	saw_digit := false
	for ; i < n; i += 1 {
		if !is_digit(val[i]) do break
		saw_digit = true
	}
	if i < n && val[i] == '.' {
		i += 1
		for ; i < n; i += 1 {
			if !is_digit(val[i]) do break
			saw_digit = true
		}
	}
	return saw_digit && i == n
}

// ──────────────────────────────────────────────────────────────────
// Tokenizer
// ──────────────────────────────────────────────────────────────────

@(private="file") is_word_start :: proc(b: u8) -> bool {
	return (b >= 'a' && b <= 'z') || (b >= 'A' && b <= 'Z') || b == '_'
}
@(private="file") is_word_cont  :: proc(b: u8) -> bool { return is_word_start(b) || (b >= '0' && b <= '9') }
@(private="file") is_digit      :: proc(b: u8) -> bool { return b >= '0' && b <= '9' }
@(private="file") is_hex_digit  :: proc(b: u8) -> bool {
	return is_digit(b) || (b >= 'a' && b <= 'f') || (b >= 'A' && b <= 'F')
}

@(private="file")
match_at :: proc(line: []u8, pos: int, s: string) -> bool {
	if len(s) == 0 do return false
	if pos + len(s) > len(line) do return false
	for k in 0 ..< len(s) {
		if line[pos + k] != s[k] do return false
	}
	return true
}

// True if `pos` is followed by `[ws]*(` — i.e. the identifier just before
// is being called like a function: `foo(...)`, `obj.method(...)`, etc.
@(private="file")
is_call :: proc(line: []u8, pos: int) -> bool {
	n := len(line)
	j := pos
	for j < n && (line[j] == ' ' || line[j] == '\t') do j += 1
	return j < n && line[j] == '('
}

@(private="file")
classify_identifier :: proc(spec: ^Language_Spec, word: string, line: []u8, after_pos: int) -> Token_Kind {
	switch {
	case slice.contains(spec.keywords,  word): return .Keyword
	case slice.contains(spec.types,     word): return .Type
	case slice.contains(spec.constants, word): return .Constant
	}
	if spec.detect_function_call && is_call(line, after_pos) do return .Function
	if spec.capitalized_types && len(word) > 0 && word[0] >= 'A' && word[0] <= 'Z' do return .Type
	return .Default
}

// Walk a line under the rules in `spec`. Block-comment state is the only
// thing carried between lines; everything else is consumed in one pass.
@(private="file")
tokenize_with_spec :: proc(line: []u8, state_in: Tokenizer_State, spec: ^Language_Spec) -> ([]Token, Tokenizer_State) {
	tokens := make([dynamic]Token, context.temp_allocator)
	state := state_in
	n := len(line)
	i := 0

	// Resume an open block comment from the previous line.
	if state == .Block_Comment {
		comment_start := 0
		closed := false
		for i < n {
			if match_at(line, i, spec.block_close) {
				i += len(spec.block_close)
				closed = true
				break
			}
			i += 1
		}
		if !closed {
			append(&tokens, Token{0, n, .Comment})
			return tokens[:], .Block_Comment
		}
		append(&tokens, Token{comment_start, i, .Comment})
		state = .Normal
	}

	for i < n {
		b := line[i]

		// Line comment (rest of line).
		if len(spec.line_comment) > 0 && match_at(line, i, spec.line_comment) {
			append(&tokens, Token{i, n, .Comment})
			i = n
			break
		}

		// Block comment (may continue past end of line).
		if len(spec.block_open) > 0 && match_at(line, i, spec.block_open) {
			start := i
			i += len(spec.block_open)
			closed := false
			for i < n {
				if match_at(line, i, spec.block_close) {
					i += len(spec.block_close)
					closed = true
					break
				}
				i += 1
			}
			if !closed {
				append(&tokens, Token{start, n, .Comment})
				state = .Block_Comment
				break
			}
			append(&tokens, Token{start, i, .Comment})
			continue
		}

		// Double-quoted string "..."
		if spec.double_quote_string && b == '"' {
			start := i
			i += 1
			for i < n && line[i] != '"' {
				if line[i] == '\\' && i + 1 < n do i += 1
				i += 1
			}
			if i < n do i += 1
			append(&tokens, Token{start, i, .String})
			continue
		}

		// Raw string `...` (or whatever the spec configured) — single-line for v1.
		if spec.raw_string_quote != 0 && b == spec.raw_string_quote {
			start := i
			i += 1
			for i < n && line[i] != spec.raw_string_quote do i += 1
			if i < n do i += 1
			append(&tokens, Token{start, i, .String})
			continue
		}

		// Char / rune literal 'x'
		if spec.single_quote_char && b == '\'' {
			start := i
			i += 1
			for i < n && line[i] != '\'' {
				if line[i] == '\\' && i + 1 < n do i += 1
				i += 1
			}
			if i < n do i += 1
			append(&tokens, Token{start, i, .String})
			continue
		}

		// Directive: #word as one keyword-coloured token (Jai #run, C #include …).
		if spec.directive_prefix != 0 && b == spec.directive_prefix &&
		   i + 1 < n && is_word_start(line[i + 1]) {
			start := i
			i += 1
			for i < n && is_word_cont(line[i]) do i += 1
			append(&tokens, Token{start, i, .Keyword})
			continue
		}

		// Number literal
		if is_digit(b) {
			start := i
			if b == '0' && i + 1 < n && (line[i + 1] == 'x' || line[i + 1] == 'X') {
				i += 2
				for i < n && (is_hex_digit(line[i]) || line[i] == '_') do i += 1
			} else if b == '0' && i + 1 < n && (line[i + 1] == 'b' || line[i + 1] == 'B') {
				i += 2
				for i < n && (line[i] == '0' || line[i] == '1' || line[i] == '_') do i += 1
			} else if b == '0' && i + 1 < n && (line[i + 1] == 'o' || line[i + 1] == 'O') {
				i += 2
				for i < n && ((line[i] >= '0' && line[i] <= '7') || line[i] == '_') do i += 1
			} else {
				for i < n && (is_digit(line[i]) || line[i] == '_') do i += 1
				if i < n && line[i] == '.' && i + 1 < n && is_digit(line[i + 1]) {
					i += 1
					for i < n && (is_digit(line[i]) || line[i] == '_') do i += 1
				}
				if i < n && (line[i] == 'e' || line[i] == 'E') {
					i += 1
					if i < n && (line[i] == '+' || line[i] == '-') do i += 1
					for i < n && is_digit(line[i]) do i += 1
				}
			}
			append(&tokens, Token{start, i, .Number})
			continue
		}

		// Identifier
		if is_word_start(b) {
			start := i
			for i < n && is_word_cont(line[i]) do i += 1
			word := string(line[start:i])
			kind := classify_identifier(spec, word, line, i)
			if kind != .Default do append(&tokens, Token{start, i, kind})
			continue
		}

		i += 1
	}

	return tokens[:], state
}
