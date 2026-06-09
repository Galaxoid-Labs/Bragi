# build_import_lib.ps1 — generate an MSVC import library (fff_c.lib) for
# the vendored fff DLL so Odin can link `system`-style on Windows.
#
# The fff release ships only `c-lib-*-pc-windows-msvc.dll` (vendored here
# as fff_c-<arch>-windows.dll) — no .lib. MSVC linking needs an import
# library, so we synthesize one from the DLL's export table:
#
#   1. dumpbin /exports  → list every exported symbol
#   2. write a .def file from that list
#   3. lib /def:         → emit fff_c.lib (+ fff_c.exp)
#
# The produced .lib records `fff_c.dll` as its DLL name, so ship the DLL
# as `fff_c.dll` next to Bragi.exe (package_windows.ps1 does this).
#
# Run from a "x64 Native Tools Command Prompt for VS" (so dumpbin / lib
# are on PATH), or let it locate them via vswhere:
#
#   pwsh vendor/fff/build_import_lib.ps1                # x86_64 (default)
#   pwsh vendor/fff/build_import_lib.ps1 -Arch aarch64  # arm64
#
# NOTE: untested end-to-end on a Windows host yet — the macOS path is the
# verified one. Verify the resulting .lib links and the exe starts.

param(
    [ValidateSet('x86_64', 'aarch64')]
    [string] $Arch = 'x86_64'
)

$ErrorActionPreference = 'Stop'
$Here = Split-Path -Parent $MyInvocation.MyCommand.Path

$Dll = Join-Path $Here "fff_c-$Arch-windows.dll"
if (-not (Test-Path -LiteralPath $Dll)) { throw "missing vendored DLL: $Dll" }

# Canonical runtime name the import lib will reference. Ship this next to
# the exe; it's just a copy of the arch-specific DLL.
$RuntimeDll = Join-Path $Here 'fff_c.dll'
Copy-Item -LiteralPath $Dll -Destination $RuntimeDll -Force

# Locate dumpbin / lib. Prefer PATH (VS dev prompt); else vswhere.
function Find-Tool([string] $name) {
    $cmd = Get-Command $name -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
    if (Test-Path -LiteralPath $vswhere) {
        $vsRoot = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
        if ($vsRoot) {
            $found = Get-ChildItem (Join-Path $vsRoot 'VC\Tools\MSVC') -Recurse -Filter $name -ErrorAction SilentlyContinue |
                Where-Object { $_.FullName -match '\\bin\\Host' } |
                Sort-Object FullName -Descending | Select-Object -First 1
            if ($found) { return $found.FullName }
        }
    }
    throw "$name not found — run from a VS Native Tools prompt or install the C++ workload"
}

$dumpbin = Find-Tool 'dumpbin.exe'
$lib     = Find-Tool 'lib.exe'

# Parse the export table. dumpbin's /exports output lists exported names
# in a column after the ordinal / hint / RVA; grab the trailing token.
Write-Output "→ reading exports from $(Split-Path -Leaf $Dll)"
$exports = & $dumpbin /nologo /exports $Dll |
    Select-String -Pattern '^\s+\d+\s+[0-9A-Fa-f]+\s+[0-9A-Fa-f]+\s+(\S+)' |
    ForEach-Object { $_.Matches[0].Groups[1].Value }

if (-not $exports) { throw "no exports parsed from $Dll" }
Write-Output "  $($exports.Count) symbols"

$Def = Join-Path $Here 'fff_c.def'
$lines = @('LIBRARY fff_c.dll', 'EXPORTS') + ($exports | ForEach-Object { "    $_" })
Set-Content -LiteralPath $Def -Value $lines -Encoding ascii

$machine = if ($Arch -eq 'aarch64') { 'ARM64' } else { 'X64' }
$Out = Join-Path $Here 'fff_c.lib'
Write-Output "→ generating fff_c.lib ($machine)"
& $lib /nologo /def:$Def /machine:$machine /out:$Out
if ($LASTEXITCODE -ne 0) { throw "lib.exe failed (exit $LASTEXITCODE)" }

Write-Output "✓ wrote $Out (+ fff_c.dll for runtime)"
