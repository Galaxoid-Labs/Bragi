# vendor/fff

Prebuilt **fff** file-search libraries (github.com/dmtrKovalenko/fff),
vendored because fff isn't packaged by Homebrew or any Linux distro. The
Odin bindings live in `../../fff.odin`; the finder uses them
(`../../finder.odin`).

## Files

| File                              | Platform / arch        |
|-----------------------------------|------------------------|
| `libfff_c-aarch64-darwin.dylib`   | macOS arm64            |
| `libfff_c-x86_64-darwin.dylib`    | macOS x86_64           |
| `libfff_c-aarch64-linux.so`       | Linux arm64 (glibc)    |
| `libfff_c-x86_64-linux.so`        | Linux x86_64 (glibc)   |
| `fff_c-aarch64-windows.dll`       | Windows arm64 (MSVC)   |
| `fff_c-x86_64-windows.dll`        | Windows x86_64 (MSVC)  |
| `fff.h`                           | C header (reference)   |

These are the `c-lib-*` assets from the fff GitHub release (NOT the
plain `*.dylib`/`*.so`/`*.dll` ones — those are the Node SDK's native
addon). `fff.odin` picks the right file per `ODIN_OS` / `ODIN_ARCH`.

## Refreshing to a new fff version

```sh
base="https://github.com/dmtrKovalenko/fff/releases/download/<TAG>"
curl -sL "$base/c-lib-aarch64-apple-darwin.dylib"   -o libfff_c-aarch64-darwin.dylib
curl -sL "$base/c-lib-x86_64-apple-darwin.dylib"    -o libfff_c-x86_64-darwin.dylib
curl -sL "$base/c-lib-aarch64-unknown-linux-gnu.so" -o libfff_c-aarch64-linux.so
curl -sL "$base/c-lib-x86_64-unknown-linux-gnu.so"  -o libfff_c-x86_64-linux.so
curl -sL "$base/c-lib-aarch64-pc-windows-msvc.dll"  -o fff_c-aarch64-windows.dll
curl -sL "$base/c-lib-x86_64-pc-windows-msvc.dll"   -o fff_c-x86_64-windows.dll
curl -sL "https://raw.githubusercontent.com/dmtrKovalenko/fff/<TAG>/crates/fff-c/include/fff.h" -o fff.h
```

Then redo the per-platform fixups below.

## macOS — install_name fixup (required)

The shipped dylibs record a CI build path as their install name
(`/Users/runner/.../libfff_c.dylib`), which won't resolve anywhere. We
rewrite it to a `@loader_path`-relative path so a dev `./Bragi` at the
repo root finds the dylib in place with no rpath fiddling, then ad-hoc
re-sign (install_name_tool invalidates the signature):

```sh
for arch in aarch64 x86_64; do
  f="libfff_c-$arch-darwin.dylib"
  chmod +w "$f"
  install_name_tool -id "@loader_path/vendor/fff/$f" "$f"
  codesign --remove-signature "$f" 2>/dev/null
  codesign --force --sign - "$f"
done
```

`tools/package_macos.sh` then copies the linked dylib into the .app's
`Frameworks/` as `libfff_c.dylib` and rewrites the reference to
`@rpath/libfff_c.dylib`.

## Windows — import library (required to build)

MSVC linking needs a `.lib`; the release ships only the DLL. Generate
the import lib (and a canonical `fff_c.dll` for runtime) once:

```pwsh
pwsh vendor/fff/build_import_lib.ps1                # x86_64
pwsh vendor/fff/build_import_lib.ps1 -Arch aarch64  # arm64
```

`fff.odin` links `vendor/fff/fff_c.lib`; `tools/package_windows.ps1`
ships `fff_c.dll` next to `Bragi.exe`.

## Linux — bundled at package time

`tools/package_linux.sh` copies the matching `.so` into
`/usr/lib/bragi/` and points the binary's RUNPATH there with `patchelf`
(fff has no distro package). Needs `patchelf` on the build host.

> The macOS path is the only one verified end-to-end so far; the
> Linux/Windows steps are best-effort and want a check on those hosts.
