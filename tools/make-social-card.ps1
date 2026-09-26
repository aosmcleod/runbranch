<#
.SYNOPSIS
  Render the social card (tools/social-card/card.html) to a 1200x1200 PNG with
  headless Microsoft Edge.

.DESCRIPTION
  Each -Shot is a window capture as tools/screenshot.ps1 or tools/screenshot.sh
  writes it: the window on a transparent, shadowed margin. The margin is
  cropped away here (to the fully opaque window) because the card draws its
  own corners and shadow at the card's scale.

  Edge runs with a throwaway profile, so it neither touches nor waits on the
  browser you have open.

.EXAMPLE
  # The Windows card; the Mac one is docs/img/social-card.png
  & ./tools/make-social-card.ps1 -Shot docs/img/windows/screenshot-wide.png -Pill 'Windows 11' `
      -Out docs/img/social-card-windows.png

  # Two -Shot values put two windows on one card, the first behind

  # The Mac card, to check the template against docs/img/social-card.png
  & ./tools/make-social-card.ps1 -Shot docs/img/screenshot.png -Pill 'macOS 26+' -Radius 14 -Out mac-check.png
#>
param(
    [Parameter(Mandatory)] [string[]]$Shot,
    [string[]]$Pill = @('Windows 11'),
    [Parameter(Mandatory)] [string]$Out,
    [string]$Licence = 'GPL-3.0',
    # 8 for a Windows window, 14 for a Mac one, at the card's scale.
    [int]$Radius = 8
)
$ErrorActionPreference = 'Stop'
$Repo = Split-Path -Parent $PSScriptRoot
$Template = Join-Path $PSScriptRoot 'social-card\card.html'
$Scratch = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Temp\runbranch-social-card'
New-Item -ItemType Directory -Force $Scratch | Out-Null

$edge = @(
    "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe",
    "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe"
) | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $edge) { throw 'Microsoft Edge is not installed where expected.' }

Add-Type -AssemblyName System.Drawing
Add-Type -ReferencedAssemblies System.Drawing -TypeDefinition @'
using System;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
public static class CardCrop
{
    /// The bounding box of the fully opaque pixels: the window itself, without
    /// the transparent margin and the translucent shadow around it.
    public static Rectangle Opaque(Bitmap b)
    {
        var d = b.LockBits(new Rectangle(0, 0, b.Width, b.Height), ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
        var px = new byte[d.Stride * b.Height];
        Marshal.Copy(d.Scan0, px, 0, px.Length);
        b.UnlockBits(d);
        int l = b.Width, t = b.Height, r = -1, bo = -1;
        for (int y = 0; y < b.Height; y++)
            for (int x = 0; x < b.Width; x++)
                if (px[y * d.Stride + x * 4 + 3] >= 250)
                {
                    if (x < l) l = x; if (x > r) r = x;
                    if (y < t) t = y; if (y > bo) bo = y;
                }
        if (r < 0) return new Rectangle(0, 0, b.Width, b.Height);
        return new Rectangle(l, t, r - l + 1, bo - t + 1);
    }
}
'@

function To-FileUrl([string]$path) { ([Uri](Resolve-Path $path).Path).AbsoluteUri }

$query = New-Object System.Collections.Generic.List[string]
$i = 0
foreach ($s in $Shot) {
    $src = (Resolve-Path (Join-Path $Repo $s) -ErrorAction SilentlyContinue)
    if (-not $src) { $src = Resolve-Path $s }
    $bmp = New-Object System.Drawing.Bitmap $src.Path
    try {
        $box = [CardCrop]::Opaque($bmp)
        $crop = $bmp.Clone($box, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
        $dest = Join-Path $Scratch ("shot-$i.png")
        $crop.Save($dest, [System.Drawing.Imaging.ImageFormat]::Png)
        $crop.Dispose()
        $ratio = [Math]::Round($box.Width / $box.Height, 4).ToString([Globalization.CultureInfo]::InvariantCulture)
        $query.Add('shot=' + [Uri]::EscapeDataString((To-FileUrl $dest)))
        $query.Add("ratio=$ratio")
    }
    finally { $bmp.Dispose() }
    $i++
}
foreach ($p in $Pill) { $query.Add('pill=' + [Uri]::EscapeDataString($p)) }
$query.Add('licence=' + [Uri]::EscapeDataString($Licence))
$query.Add("radius=$Radius")
$query.Add('mark=' + [Uri]::EscapeDataString((To-FileUrl (Join-Path $Repo 'assets\mark.svg'))))

$url = (To-FileUrl $Template) + '?' + ($query -join '&')
# Relative to the repo, like -Shot, wherever this is run from.
$outPath = if ([IO.Path]::IsPathRooted($Out)) { $Out } else { [IO.Path]::GetFullPath((Join-Path $Repo $Out)) }
$tmp = Join-Path $Scratch 'card.png'
Remove-Item $tmp -ErrorAction SilentlyContinue
$profileDir = Join-Path $Scratch 'edge-profile'

$edgeArgs = @(
    '--headless=new', '--disable-gpu', '--hide-scrollbars', '--no-first-run',
    '--force-device-scale-factor=1', '--window-size=1200,1200',
    '--virtual-time-budget=4000', '--allow-file-access-from-files',
    "--user-data-dir=`"$profileDir`"", "--screenshot=`"$tmp`"", "`"$url`""
)
$proc = Start-Process -FilePath $edge -ArgumentList $edgeArgs -PassThru -WindowStyle Hidden
if (-not $proc.WaitForExit(60000)) { Stop-Process -Id $proc.Id -Force; throw 'Edge did not finish within 60 s.' }
if (-not (Test-Path $tmp)) { throw "Edge wrote no screenshot (exit $($proc.ExitCode))." }

New-Item -ItemType Directory -Force (Split-Path -Parent $outPath) | Out-Null
Move-Item -Force $tmp $outPath
$img = [System.Drawing.Image]::FromFile($outPath); $size = "$($img.Width)x$($img.Height)"; $img.Dispose()
"{0}  {1}  {2:N0} KB" -f $outPath, $size, ((Get-Item $outPath).Length / 1KB)
