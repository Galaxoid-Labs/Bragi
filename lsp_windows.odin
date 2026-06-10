#+build windows
package bragi

// Windows LSP spawn — STUB for now. The POSIX path (lsp_posix.odin) is the
// verified one; a real ConPTY-free CreatePipe + CreateProcessW spawn (mirroring
// pty_windows.odin but wiring plain stdin/stdout handles) lands when the LSP
// feature is brought to Windows. Until then these no-ops make the package
// build on Windows with LSP simply inert. `LSP_Pipes` is defined in lsp.odin.

lsp_spawn :: proc(argv: []string, cwd: string, env: []string) -> (p: LSP_Pipes, ok: bool) {
	return {}, false
}

lsp_pipe_read :: proc(fd: int, buf: []u8) -> int {
	return -1
}

lsp_pipe_write :: proc(fd: int, data: []u8) -> bool {
	return false
}

lsp_pipe_close :: proc(fd: int) {}

lsp_proc_kill :: proc(pid: int) {}
