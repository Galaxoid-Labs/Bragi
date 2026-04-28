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
	Constant,  // true / false / nil
	Number,
	String,    // includes char literals and raw strings
	Comment,
	Function,  // procedure declaration name (Odin: `name :: proc`)
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
}

language_for_path :: proc(path: string) -> Language {
	if strings.has_suffix(path, ".odin") do return .Odin
	return .None
}

// Tokenize a single line. Returns tokens (in temp_allocator) and the state
// the next line should resume from. For Language.None, returns no tokens —
// the renderer paints the whole line in the default color.
syntax_tokenize :: proc(lang: Language, line: []u8, state_in: Tokenizer_State) -> ([]Token, Tokenizer_State) {
	switch lang {
	case .None:    return nil, .Normal
	case .Generic: return tokenize_generic(line, state_in)
	case .Odin:    return tokenize_odin(line, state_in)
	}
	return nil, .Normal
}

language_from_name :: proc(name: string) -> (Language, bool) {
	switch name {
	case "none", "off":             return .None, true
	case "generic", "basic", "any": return .Generic, true
	case "odin":                    return .Odin, true
	}
	return .None, false
}

language_name :: proc(lang: Language) -> string {
	switch lang {
	case .None:    return "none"
	case .Generic: return "generic"
	case .Odin:    return "odin"
	}
	return "none"
}

// ──────────────────────────────────────────────────────────────────
// Generic tokenizer — strings, numbers, // and /* */ comments. Works as a
// best-effort default for any C-family-ish file (or anything sane).
// ──────────────────────────────────────────────────────────────────

@(private="file")
tokenize_generic :: proc(line: []u8, state_in: Tokenizer_State) -> ([]Token, Tokenizer_State) {
	tokens := make([dynamic]Token, context.temp_allocator)
	state := state_in
	n := len(line)
	i := 0

	if state == .Block_Comment {
		closed := false
		for i < n {
			if i + 1 < n && line[i] == '*' && line[i + 1] == '/' {
				i += 2
				closed = true
				break
			}
			i += 1
		}
		if !closed {
			append(&tokens, Token{0, n, .Comment})
			return tokens[:], .Block_Comment
		}
		append(&tokens, Token{0, i, .Comment})
		state = .Normal
	}

	for i < n {
		b := line[i]

		// Line comment //
		if i + 1 < n && b == '/' && line[i + 1] == '/' {
			append(&tokens, Token{i, n, .Comment})
			i = n
			break
		}

		// Block comment /* */
		if i + 1 < n && b == '/' && line[i + 1] == '*' {
			start := i
			i += 2
			closed := false
			for i < n {
				if i + 1 < n && line[i] == '*' && line[i + 1] == '/' {
					i += 2
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

		// String "..." / '...' / `...`
		if b == '"' || b == '\'' || b == '`' {
			quote := b
			start := i
			i += 1
			for i < n && line[i] != quote {
				if line[i] == '\\' && i + 1 < n do i += 1
				i += 1
			}
			if i < n do i += 1
			append(&tokens, Token{start, i, .String})
			continue
		}

		// Numbers (decimal, hex, binary, float)
		if is_digit(b) {
			start := i
			if b == '0' && i + 1 < n && (line[i + 1] == 'x' || line[i + 1] == 'X') {
				i += 2
				for i < n && (is_hex_digit(line[i]) || line[i] == '_') do i += 1
			} else if b == '0' && i + 1 < n && (line[i + 1] == 'b' || line[i + 1] == 'B') {
				i += 2
				for i < n && (line[i] == '0' || line[i] == '1' || line[i] == '_') do i += 1
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

		i += 1
	}

	return tokens[:], state
}

// ──────────────────────────────────────────────────────────────────
// Odin tokenizer
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

@(private="file") is_word_start :: proc(b: u8) -> bool {
	return (b >= 'a' && b <= 'z') || (b >= 'A' && b <= 'Z') || b == '_'
}
@(private="file") is_word_cont  :: proc(b: u8) -> bool { return is_word_start(b) || (b >= '0' && b <= '9') }
@(private="file") is_digit      :: proc(b: u8) -> bool { return b >= '0' && b <= '9' }
@(private="file") is_hex_digit  :: proc(b: u8) -> bool {
	return is_digit(b) || (b >= 'a' && b <= 'f') || (b >= 'A' && b <= 'F')
}

@(private="file")
tokenize_odin :: proc(line: []u8, state_in: Tokenizer_State) -> ([]Token, Tokenizer_State) {
	tokens := make([dynamic]Token, context.temp_allocator)
	state := state_in
	n := len(line)
	i := 0

	// Resume an open block comment from the previous line.
	if state == .Block_Comment {
		comment_start := 0
		closed := false
		for i < n {
			if i + 1 < n && line[i] == '*' && line[i + 1] == '/' {
				i += 2
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

		// Line comment: //...
		if i + 1 < n && b == '/' && line[i + 1] == '/' {
			append(&tokens, Token{i, n, .Comment})
			i = n
			break
		}

		// Block comment: /* ... */ (possibly unterminated → propagates to next line)
		if i + 1 < n && b == '/' && line[i + 1] == '*' {
			start := i
			i += 2
			closed := false
			for i < n {
				if i + 1 < n && line[i] == '*' && line[i + 1] == '/' {
					i += 2
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

		// String "..."
		if b == '"' {
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

		// Raw string `...` (treated single-line for v1)
		if b == '`' {
			start := i
			i += 1
			for i < n && line[i] != '`' do i += 1
			if i < n do i += 1
			append(&tokens, Token{start, i, .String})
			continue
		}

		// Char '...'
		if b == '\'' {
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

		// Numeric literal
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

		// Identifier → keyword / type / constant / function / default
		if is_word_start(b) {
			start := i
			for i < n && is_word_cont(line[i]) do i += 1
			word := string(line[start:i])
			kind := classify_identifier(word, line, i)
			if kind != .Default do append(&tokens, Token{start, i, kind})
			continue
		}

		i += 1
	}

	return tokens[:], state
}

// True if `pos` is followed by `[ws]*::[ws]*proc` (a procedure declaration).
@(private="file")
is_proc_decl :: proc(line: []u8, pos: int) -> bool {
	n := len(line)
	j := pos
	for j < n && (line[j] == ' ' || line[j] == '\t') do j += 1
	if j + 1 >= n || line[j] != ':' || line[j + 1] != ':' do return false
	j += 2
	for j < n && (line[j] == ' ' || line[j] == '\t') do j += 1
	if j + 4 > n do return false
	if string(line[j:j + 4]) != "proc" do return false
	if j + 4 < n && is_word_cont(line[j + 4]) do return false // e.g. `procs`
	return true
}

// True if `pos` is followed by `[ws]*(` — i.e. the identifier just before is
// being called like a function: `foo(...)`, `obj.method(...)`, etc.
@(private="file")
is_call :: proc(line: []u8, pos: int) -> bool {
	n := len(line)
	j := pos
	for j < n && (line[j] == ' ' || line[j] == '\t') do j += 1
	return j < n && line[j] == '('
}

// Heuristic for capitalized identifiers: any starts-with-uppercase word that
// isn't a keyword/type/constant is treated as a Type. We deliberately do NOT
// classify ALL-CAPS as Constant — in Odin "constant" is defined by `::`, not
// by case, and a heuristic on case mis-fires on uppercase-named enum values.
@(private="file")
classify_capitalized :: proc(word: string) -> Token_Kind {
	if len(word) == 0 do return .Default
	first := word[0]
	if first < 'A' || first > 'Z' do return .Default
	return .Type
}

@(private="file")
classify_identifier :: proc(word: string, line: []u8, after_pos: int) -> Token_Kind {
	switch {
	case slice.contains(ODIN_KEYWORDS,  word): return .Keyword
	case slice.contains(ODIN_TYPES,     word): return .Type
	case slice.contains(ODIN_CONSTANTS, word): return .Constant
	}
	if is_proc_decl(line, after_pos) || is_call(line, after_pos) do return .Function
	return classify_capitalized(word)
}
