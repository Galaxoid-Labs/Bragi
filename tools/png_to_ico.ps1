#requires -PSEdition Desktop
#
# png_to_ico.ps1 — build a multi-resolution Windows .ico from a single
# source PNG. Used by package_windows.ps1 so we don't need ImageMagick
# (or any other binary) installed.
#
# The .ico container holds one PNG-encoded image per requested size;
# Windows Vista+ accepts PNG entries inside .ico for any dimension, so
# we don't bother with the legacy BMP/DIB encoding.
#
# Usage:
#   ./png_to_ico.ps1 -Source icon.png -Destination bragi.ico
#   ./png_to_ico.ps1 -Source icon.png -Destination out.ico -Sizes 16,32,256

[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Source,
    [Parameter(Mandatory)] [string] $Destination,
    [int[]]                          $Sizes = @(16, 32, 48, 64, 128, 256)
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

$srcPath = (Resolve-Path -LiteralPath $Source).Path
$src = [System.Drawing.Image]::FromFile($srcPath)
$entries = New-Object System.Collections.Generic.List[object]
try {
    foreach ($s in $Sizes) {
        $bmp = New-Object System.Drawing.Bitmap $s, $s, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
        $g   = [System.Drawing.Graphics]::FromImage($bmp)
        try {
            $g.InterpolationMode  = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
            $g.PixelOffsetMode    = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
            $g.SmoothingMode      = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
            $g.CompositingQuality = [System.Drawing.Drawing2D.CompositingQuality]::HighQuality
            $g.Clear([System.Drawing.Color]::Transparent)
            $g.DrawImage($src, 0, 0, $s, $s)
        } finally {
            $g.Dispose()
        }
        $ms = New-Object System.IO.MemoryStream
        try {
            $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
            $entries.Add(@{ Size = $s; Data = $ms.ToArray() })
        } finally {
            $ms.Dispose()
            $bmp.Dispose()
        }
    }
} finally {
    $src.Dispose()
}

# Pack into the ICONDIR + ICONDIRENTRY container. Spec:
#   https://learn.microsoft.com/windows/win32/menurc/about-icons
$dst = [System.IO.Path]::GetFullPath($Destination)
$dir = [System.IO.Path]::GetDirectoryName($dst)
if ($dir -and -not (Test-Path -LiteralPath $dir)) {
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
}
$out = [System.IO.File]::Open($dst, [System.IO.FileMode]::Create)
$bw  = New-Object System.IO.BinaryWriter $out
try {
    # ICONDIR (6 bytes): reserved(0), type(1=ICO), count
    $bw.Write([uint16]0)
    $bw.Write([uint16]1)
    $bw.Write([uint16]$entries.Count)

    # ICONDIRENTRY (16 bytes each). The dimension byte is 0 to mean 256.
    $offset = 6 + (16 * $entries.Count)
    foreach ($e in $entries) {
        $dim = if ($e.Size -ge 256) { [byte]0 } else { [byte]$e.Size }
        $bw.Write($dim)                      # width
        $bw.Write($dim)                      # height
        $bw.Write([byte]0)                   # color count (0 for true-color)
        $bw.Write([byte]0)                   # reserved
        $bw.Write([uint16]1)                 # color planes
        $bw.Write([uint16]32)                # bits per pixel
        $bw.Write([uint32]$e.Data.Length)    # data size
        $bw.Write([uint32]$offset)           # data offset from file start
        $offset += $e.Data.Length
    }
    foreach ($e in $entries) {
        $bw.Write($e.Data)
    }
} finally {
    $bw.Dispose()
    $out.Dispose()
}

Write-Output "wrote $dst ($($entries.Count) sizes: $($Sizes -join ', '))"
