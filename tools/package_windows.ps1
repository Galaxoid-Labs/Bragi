#requires -PSEdition Desktop
#
# package_windows.ps1 — build Bragi.exe with embedded icon + version
# resource, stage a redistributable bundle (Bragi.exe + SDL3 / vterm
# DLLs + LICENSE), and either wrap it in an Inno Setup installer or
# fall back to a portable zip when iscc.exe isn't on the box.
#
# Reads deploy.ini at the repo root for metadata. Run from anywhere;
# the script resolves paths off its own location.
#
# Outputs:
#   dist/windows/Bragi-<version>-Setup.exe   ← Inno Setup installer (if iscc.exe found)
#   dist/windows/Bragi-<version>-portable.zip ← portable zip (always, or fallback)
#
# Stages (each can be skipped via env var, useful when iterating):
#   STAGE_ICON=0       skip png→ico + .rc generation
#   STAGE_BUILD=0      skip the `odin build` step
#   STAGE_BUNDLE=0     skip the staging-dir assembly
#   STAGE_INSTALLER=0  skip the Inno Setup compile (zip is always written)
#   STAGE_ZIP=0        skip the portable zip
#
# Requires:
#   - Odin (with the SDL3 vendor package vendored alongside)
#   - rc.exe from the Windows SDK (auto-located via Visual Studio 2022+)
#   - Inno Setup 6 for the .exe installer (winget: JRSoftware.InnoSetup6)

$ErrorActionPreference = 'Stop'

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot  = Split-Path -Parent $ScriptDir
Set-Location $RepoRoot

$DeployIni = Join-Path $RepoRoot 'deploy.ini'
if (-not (Test-Path -LiteralPath $DeployIni)) {
    throw "deploy.ini not found at $DeployIni"
}

# ──────────────────────────────────────────────────────────────────
# Tiny INI reader. Mirrors the bash scripts' awk one — picks values
# out of `deploy.ini` honoring [section] scoping, returns empty string
# if the key isn't present in that section.
# ──────────────────────────────────────────────────────────────────
function Read-Ini {
    param([Parameter(Mandatory)][string] $Section, [Parameter(Mandatory)][string] $Key)

    $inSection = $false
    foreach ($raw in [System.IO.File]::ReadAllLines($DeployIni)) {
        $line = $raw.Trim()
        if (-not $line -or $line.StartsWith('#')) { continue }
        if ($line -match '^\[(.+)\]$') {
            $inSection = ($Matches[1] -eq $Section)
            continue
        }
        if ($inSection -and $line -match '^([^=]+?)\s*=\s*(.*)$') {
            if ($Matches[1].Trim() -eq $Key) {
                return $Matches[2].Trim()
            }
        }
    }
    return ''
}

function Read-IniOrCommon {
    param([string] $Section, [string] $Key)
    $v = Read-Ini -Section $Section -Key $Key
    if ([string]::IsNullOrEmpty($v)) { $v = Read-Ini -Section 'common' -Key $Key }
    return $v
}

function Require-Value {
    param([string] $Name, [string] $Value)
    if ([string]::IsNullOrEmpty($Value)) {
        throw "deploy.ini is missing required key: $Name"
    }
}

# ──────────────────────────────────────────────────────────────────
# Pull every value we'll need up front. Trip on missing required ones
# immediately rather than failing partway through.
# ──────────────────────────────────────────────────────────────────
$AppName     = Read-Ini common name        ; Require-Value 'common.name'        $AppName
$BinName     = Read-Ini common binary_name ; Require-Value 'common.binary_name' $BinName
$Identifier  = Read-Ini common identifier  ; Require-Value 'common.identifier'  $Identifier
$Version     = Read-Ini common version     ; Require-Value 'common.version'     $Version
$Author      = Read-Ini common author      ; Require-Value 'common.author'      $Author
$Copyright   = Read-Ini common copyright   ; Require-Value 'common.copyright'   $Copyright
$Description = Read-Ini common description
$Url         = Read-Ini common url
$IconPng     = Read-Ini common icon_png

$AppId       = Read-IniOrCommon windows app_user_model_id
if ([string]::IsNullOrEmpty($AppId)) { $AppId = $Identifier }
$DocExts     = Read-Ini windows document_extensions  # currently unused; v1 ships without file assoc

# Stage toggles — env var override, default on.
$StageIcon      = if ($env:STAGE_ICON      -eq '0') { $false } else { $true }
$StageBuild     = if ($env:STAGE_BUILD     -eq '0') { $false } else { $true }
$StageBundle    = if ($env:STAGE_BUNDLE    -eq '0') { $false } else { $true }
$StageInstaller = if ($env:STAGE_INSTALLER -eq '0') { $false } else { $true }
$StageZip       = if ($env:STAGE_ZIP       -eq '0') { $false } else { $true }

# Derived paths.
$DistDir     = Join-Path $RepoRoot 'dist\windows'
$BuildDir    = Join-Path $DistDir  'build'
$StagingDir  = Join-Path $DistDir  'staging'
$IcoPath     = Join-Path $BuildDir 'bragi.ico'
$RcPath      = Join-Path $BuildDir 'bragi.rc'
$ResPath     = Join-Path $BuildDir 'bragi.res'
$ExeName     = "$AppName.exe"
$ExeBuiltAt  = Join-Path $RepoRoot $ExeName  # odin emits next to source
$IssPath     = Join-Path $BuildDir 'setup.iss'
$InstallerOut = Join-Path $DistDir "$AppName-$Version-Setup.exe"
$ZipOut       = Join-Path $DistDir "$AppName-$Version-portable.zip"

Write-Output "━━━ Bragi Windows package ━━━"
Write-Output "  name        : $AppName"
Write-Output "  binary      : $BinName"
Write-Output "  identifier  : $Identifier"
Write-Output "  version     : $Version"
Write-Output "  output dir  : $DistDir"
Write-Output ""

New-Item -ItemType Directory -Path $DistDir, $BuildDir, $StagingDir -Force | Out-Null

# ──────────────────────────────────────────────────────────────────
# 1. Generate bragi.ico from icon.png and a versioned bragi.rc.
# ──────────────────────────────────────────────────────────────────
if ($StageIcon) {
    if ([string]::IsNullOrEmpty($IconPng) -or -not (Test-Path -LiteralPath (Join-Path $RepoRoot $IconPng))) {
        Write-Output "→ no icon (icon_png missing or not found) — skipping resource generation"
        $StageIcon = $false  # downstream flags off so we don't try to embed nothing
    } else {
        Write-Output "→ generating $IcoPath from $IconPng"
        & (Join-Path $ScriptDir 'png_to_ico.ps1') `
            -Source      (Join-Path $RepoRoot $IconPng) `
            -Destination $IcoPath | Out-Null

        # Pad the SemVer triple out to a 4-component FILEVERSION (W,X,Y,Z).
        # Anything unparseable → 0,0,0,0 so rc.exe doesn't choke.
        $verParts = ($Version -split '[.\-+]') |
            Select-Object -First 4 |
            ForEach-Object { [int]($_ -replace '[^0-9]', '') }
        while ($verParts.Count -lt 4) { $verParts += 0 }
        $FileVersionRC = ($verParts[0..3] -join ',')

        # Wrap an RC string-table value in double quotes, doubling any
        # internal double quote per RC syntax. None of the values from
        # deploy.ini are expected to contain quotes today, but the
        # escape is cheap.
        function Rc-Quote([string] $s) { return '"' + ($s -replace '"', '""') + '"' }

        # No `#include <winver.h>` — that needs the SDK header path on rc's
        # /I list, which we'd have to hunt for. The only symbol we use from
        # it is VS_VERSION_INFO (== 1), so spell the resource ID directly.
        $rc = @"
IDI_ICON1 ICON "bragi.ico"

1 VERSIONINFO
 FILEVERSION    $FileVersionRC
 PRODUCTVERSION $FileVersionRC
 FILEFLAGSMASK  0x3FL
 FILEFLAGS      0x0L
 FILEOS         0x40004L
 FILETYPE       0x1L
 FILESUBTYPE    0x0L
BEGIN
    BLOCK "StringFileInfo"
    BEGIN
        BLOCK "040904B0"
        BEGIN
            VALUE "CompanyName",      $(Rc-Quote $Author)
            VALUE "FileDescription",  $(Rc-Quote $AppName)
            VALUE "FileVersion",      $(Rc-Quote $Version)
            VALUE "InternalName",     $(Rc-Quote $BinName)
            VALUE "LegalCopyright",   $(Rc-Quote $Copyright)
            VALUE "OriginalFilename", $(Rc-Quote $ExeName)
            VALUE "ProductName",      $(Rc-Quote $AppName)
            VALUE "ProductVersion",   $(Rc-Quote $Version)
            VALUE "Comments",         $(Rc-Quote $Description)
        END
    END
    BLOCK "VarFileInfo"
    BEGIN
        VALUE "Translation", 0x409, 1200
    END
END
"@
        Set-Content -Path $RcPath -Value $rc -Encoding ascii

        # rc.exe lives in the Windows SDK. Find the newest x64 host build.
        $rcExe = Get-ChildItem 'C:\Program Files (x86)\Windows Kits\10\bin' `
            -Recurse -Filter 'rc.exe' -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -match '\\x64\\rc\.exe$' } |
            Sort-Object FullName -Descending | Select-Object -First 1
        if (-not $rcExe) {
            throw "rc.exe not found under the Windows SDK (install the 'Desktop development with C++' workload)"
        }
        & $rcExe.FullName /nologo /fo $ResPath $RcPath
        if ($LASTEXITCODE -ne 0) { throw "rc.exe failed (exit $LASTEXITCODE)" }
    }
}

# ──────────────────────────────────────────────────────────────────
# 2. Build Bragi.exe (release, with the .res embedded if we generated one).
# ──────────────────────────────────────────────────────────────────
if ($StageBuild) {
    Write-Output "→ building $ExeName (release, /SUBSYSTEM:WINDOWS)"
    # `-subsystem:windows` tells the linker to mark the exe as a GUI app
    # so Explorer / Start menu / installer launches don't briefly flash
    # a console window alongside the SDL window.
    $linkerFlags = if ($StageIcon -and (Test-Path -LiteralPath $ResPath)) { """$ResPath""" } else { '' }
    if ($linkerFlags) {
        & odin build . -o:speed -subsystem:windows -out:$ExeName "-extra-linker-flags:$linkerFlags"
    } else {
        & odin build . -o:speed -subsystem:windows -out:$ExeName
    }
    if ($LASTEXITCODE -ne 0) { throw "odin build failed (exit $LASTEXITCODE)" }
}
if (-not (Test-Path -LiteralPath $ExeBuiltAt)) {
    throw "expected built binary at $ExeBuiltAt"
}

# ──────────────────────────────────────────────────────────────────
# 3. Stage the redistributable: exe + DLLs + LICENSE in one directory.
#    Inno Setup compiles relative to setup.iss, and `Compress-Archive`
#    zips this same dir, so the layout serves both backends.
# ──────────────────────────────────────────────────────────────────
if ($StageBundle) {
    Write-Output "→ staging into $StagingDir"
    Get-ChildItem -LiteralPath $StagingDir | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue

    Copy-Item -LiteralPath $ExeBuiltAt -Destination (Join-Path $StagingDir $ExeName) -Force

    $odinRoot   = Split-Path -Parent (Get-Command odin).Source
    $sdl3Dll    = Join-Path $odinRoot 'vendor\sdl3\SDL3.dll'
    $sdl3TtfDll = Join-Path $odinRoot 'vendor\sdl3\ttf\SDL3_ttf.dll'
    $vtermDll   = Join-Path $RepoRoot 'vendor\libvterm\vterm.dll'
    foreach ($src in @($sdl3Dll, $sdl3TtfDll, $vtermDll)) {
        if (-not (Test-Path -LiteralPath $src)) { throw "missing required DLL: $src" }
        Copy-Item -LiteralPath $src -Destination $StagingDir -Force
    }

    $licenseSrc = Join-Path $RepoRoot 'LICENSE'
    if (Test-Path -LiteralPath $licenseSrc) {
        Copy-Item -LiteralPath $licenseSrc -Destination (Join-Path $StagingDir 'LICENSE.txt') -Force
    }
}

# ──────────────────────────────────────────────────────────────────
# 4. Inno Setup installer.
#
# Requires `iscc.exe`. If absent, we log a one-line hint and the zip
# fallback below covers distribution. Same pattern as package_linux.sh
# auto-skipping `dpkg-deb` / `rpmbuild` per host.
# ──────────────────────────────────────────────────────────────────
$isccPath = $null
if ($StageInstaller) {
    $cmd = Get-Command iscc -ErrorAction SilentlyContinue
    if ($cmd) {
        $isccPath = $cmd.Source
    } else {
        foreach ($p in @(
            'C:\Program Files (x86)\Inno Setup 6\ISCC.exe',
            'C:\Program Files\Inno Setup 6\ISCC.exe',
            (Join-Path $env:LOCALAPPDATA 'Programs\Inno Setup 6\ISCC.exe')
        )) {
            if (Test-Path -LiteralPath $p) { $isccPath = $p; break }
        }
    }

    if (-not $isccPath) {
        Write-Output "→ Inno Setup not found — skipping installer (install via: winget install JRSoftware.InnoSetup6)"
    } else {
        Write-Output "→ writing $IssPath"

        # Resolve the icon path the installer references for its own
        # window chrome / shortcuts. Falls back to the staged Bragi.exe
        # (which already carries the icon as a resource) when we didn't
        # generate a standalone .ico.
        $setupIcon = ''
        if (Test-Path -LiteralPath $IcoPath) { $setupIcon = "SetupIconFile=$IcoPath" }

        $iss = @"
; Generated by tools/package_windows.ps1 — do not hand-edit; rerun the
; script to regenerate after deploy.ini changes.

#define MyAppName        "$AppName"
#define MyAppVersion     "$Version"
#define MyAppPublisher   "$Author"
#define MyAppURL         "$Url"
#define MyAppExeName     "$ExeName"

[Setup]
AppId={{$AppId}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
AppPublisherURL={#MyAppURL}
AppSupportURL={#MyAppURL}
AppUpdatesURL={#MyAppURL}
AppCopyright=$Copyright
DefaultDirName={autopf}\{#MyAppName}
DefaultGroupName={#MyAppName}
DisableProgramGroupPage=yes
LicenseFile=$(Join-Path $StagingDir 'LICENSE.txt')
OutputDir=$DistDir
OutputBaseFilename=$AppName-$Version-Setup
$setupIcon
UninstallDisplayIcon={app}\{#MyAppExeName}
Compression=lzma2/ultra
SolidCompression=yes
WizardStyle=modern
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "$StagingDir\$ExeName";    DestDir: "{app}"; Flags: ignoreversion
Source: "$StagingDir\SDL3.dll";    DestDir: "{app}"; Flags: ignoreversion
Source: "$StagingDir\SDL3_ttf.dll";DestDir: "{app}"; Flags: ignoreversion
Source: "$StagingDir\vterm.dll";   DestDir: "{app}"; Flags: ignoreversion
Source: "$StagingDir\LICENSE.txt"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{group}\{#MyAppName}";        Filename: "{app}\{#MyAppExeName}"
Name: "{group}\{cm:UninstallProgram,{#MyAppName}}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\{#MyAppName}";  Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "{cm:LaunchProgram,{#StringChange(MyAppName, '&', '&&')}}"; Flags: nowait postinstall skipifsilent
"@
        Set-Content -Path $IssPath -Value $iss -Encoding utf8

        # Delete the prior installer first. iscc finalizes by writing
        # resources into the output exe via UpdateResource; if the
        # previous exe is still mapped (e.g. Defender finished scanning
        # mid-write last run, or Explorer's preview pane has it open),
        # iscc fails with "EndUpdateResource failed (110)". Removing it
        # up front avoids that race.
        if (Test-Path -LiteralPath $InstallerOut) { Remove-Item -LiteralPath $InstallerOut -Force }

        Write-Output "→ compiling installer with $isccPath"
        & $isccPath /Q $IssPath
        if ($LASTEXITCODE -ne 0) { throw "iscc.exe failed (exit $LASTEXITCODE)" }
    }
}

# ──────────────────────────────────────────────────────────────────
# 5. Portable zip — always produced (unless explicitly disabled).
#    Doubles as the no-Inno-Setup fallback distribution.
# ──────────────────────────────────────────────────────────────────
if ($StageZip) {
    Write-Output "→ writing $ZipOut"
    if (Test-Path -LiteralPath $ZipOut) { Remove-Item -LiteralPath $ZipOut -Force }
    Compress-Archive -Path (Join-Path $StagingDir '*') -DestinationPath $ZipOut -Force
}

Write-Output ""
Write-Output "✓ done"
if (Test-Path -LiteralPath $InstallerOut) { Write-Output "    installer : $InstallerOut" }
if (Test-Path -LiteralPath $ZipOut)       { Write-Output "    zip       : $ZipOut" }
Write-Output "    staging   : $StagingDir"
