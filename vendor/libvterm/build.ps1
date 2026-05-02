#requires -PSEdition Desktop
# Rebuild vterm.dll + vterm.lib from neovim's libvterm fork.
#
# Outputs:
#   vendor/libvterm/vterm.dll   (ships next to Bragi.exe at runtime)
#   vendor/libvterm/vterm.lib   (Odin's foreign import target)
#   vendor/libvterm/include/    (header reference, not used at build)
#
# Re-run only when bumping libvterm's version. Requires:
#   - git, cmake, MSVC (Visual Studio 2022+ with the C/C++ workload)
#
# Run from any working directory; paths resolve from the script location.

$ErrorActionPreference = 'Stop'

$here    = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoSrc = Join-Path $here '_src'
$build   = Join-Path $here '_build'

if (-not (Test-Path $repoSrc)) {
    git clone --depth 1 https://github.com/neovim/libvterm.git $repoSrc
}

# Drop a minimal CMakeLists.txt next to the source. neovim's libvterm fork
# only ships a Makefile, so we provide our own build wiring.
$cmake = @'
cmake_minimum_required(VERSION 3.15)
project(vterm C)
set(CMAKE_C_STANDARD 99)
add_library(vterm SHARED
    src/encoding.c src/keyboard.c src/mouse.c src/parser.c src/pen.c
    src/screen.c src/state.c src/unicode.c src/vterm.c)
target_include_directories(vterm PUBLIC include PRIVATE src)
if (WIN32)
    set_target_properties(vterm PROPERTIES WINDOWS_EXPORT_ALL_SYMBOLS ON)
    target_compile_definitions(vterm PRIVATE _CRT_SECURE_NO_WARNINGS)
endif()
'@
Set-Content -Path (Join-Path $repoSrc 'CMakeLists.txt') -Value $cmake -Encoding utf8

cmake -S $repoSrc -B $build
cmake --build $build --config Release
if ($LASTEXITCODE -ne 0) { throw "libvterm build failed" }

Copy-Item -Force (Join-Path $build 'Release\vterm.dll')   (Join-Path $here 'vterm.dll')
Copy-Item -Force (Join-Path $build 'Release\vterm.lib')   (Join-Path $here 'vterm.lib')
$inc = Join-Path $here 'include'
New-Item -ItemType Directory -Path $inc -Force | Out-Null
Copy-Item -Force (Join-Path $repoSrc 'include\vterm.h')          (Join-Path $inc 'vterm.h')
Copy-Item -Force (Join-Path $repoSrc 'include\vterm_keycodes.h') (Join-Path $inc 'vterm_keycodes.h')

Write-Output "OK: refreshed vendor/libvterm/{vterm.dll, vterm.lib, include/}"
