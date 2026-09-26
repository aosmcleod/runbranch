<#
.SYNOPSIS
  The Windows counterpart of tools/screenshot.sh: photograph every documented
  screen, unattended, against the fictional demo data, into docs/img/windows/.

.DESCRIPTION
  Builds nothing. It expects a DEVELOPMENT-channel build, because most scenes
  are sheets and only a development build carries the sheet harness
  (RB_SHOW_SHEET, windows/Runbranch/Dialogs/Harness.cs):

      dotnet build windows/Runbranch/Runbranch.csproj -c Release

  The docs show the app people install, and a development build looks
  different: an inverted mark and a "development build" badge in About. So
  every capture sets RB_DRESS_AS_RELEASE=1, which a development build honours
  by showing the release mark, icon and About (Build.LooksDevelopment in
  App.xaml.cs) and a release build ignores. Only the look changes; the
  updater still treats the build as development and stays off.

  The sheets are shown live (RB_SHEET_LIVE=1): the real Logs, Ports, Disk,
  Scan and editor sheets over the demo, as the app opens them, so the set
  shows the same projects as the Mac's rather than the harness's own data.

  Privacy and focus. Nothing but the app's own window is ever photographed:
  PrintWindow(PW_RENDERFULLCONTENT) on the window found by process id, from a
  DPI-aware process. The app is launched with RB_SHOT_QUIET=1, which shows its
  window without activating it and beyond the right-hand edge of every
  display, so a run neither takes focus nor covers anything. Every instance
  started here is closed again, and the demo run is stopped on the way out.

  Scale follows the display. The Mac set is 2x; this machine's scale is what
  it is (125% gives 1250x900 for the 1000x720 window) and is not faked by
  upscaling. Framing matches the Mac set: the window with its rounded corners
  and a soft shadow, on a transparent margin of 70 px at 1x.

.EXAMPLE
  ./tools/screenshot.ps1                 # every scene
  ./tools/screenshot.ps1 main logs       # just these
  ./tools/screenshot.ps1 -Light          # light-theme variants (*-light.png)
#>
param(
    [Parameter(Position = 0, ValueFromRemainingArguments = $true)]
    [string[]]$Scenes = @('all'),
    [switch]$Light,
    [int]$Port = 4173
)
$ErrorActionPreference = 'Stop'
$Repo = Split-Path -Parent $PSScriptRoot
$Out = Join-Path $Repo 'docs\img\windows'
$Build = Join-Path $Repo 'windows\Runbranch\bin\Release\net10.0-windows10.0.26100.0\win-x64'
$Engine = Join-Path $Repo 'engine\bin\runbranch.exe'
# Long form, never the 8.3 name %TEMP% may hold: the app abbreviates the home
# folder to ~ only when the path spells it the same way.
$Scratch = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Temp\runbranch-docs'
$Demo = Join-Path $Scratch 'demo'
$Empty = Join-Path $Scratch 'empty'
$AppCopy = Join-Path $Scratch 'app'

# --- preflight ---------------------------------------------------------------

if (-not (Test-Path (Join-Path $Build 'Runbranch.exe'))) {
    throw "No build at $Build. Build a development-channel one first:`n  dotnet build windows/Runbranch/Runbranch.csproj -c Release"
}
# The harness is compiled out of a release build, and without it no sheet can
# be shown. Its variable name is in the assembly's string heap (UTF-16).
$dll = [IO.File]::ReadAllBytes((Join-Path $Build 'Runbranch.dll'))
# Both byte alignments: a UTF-16 string can start on an odd offset.
$u16 = [Text.Encoding]::Unicode
if ($u16.GetString($dll).IndexOf('RB_SHEET_LIVE') -lt 0 -and $u16.GetString($dll, 1, $dll.Length - 1).IndexOf('RB_SHEET_LIVE') -lt 0) {
    throw "$Build is a release build, or predates the live harness. The captures need a development build:`n  dotnet build windows/Runbranch/Runbranch.csproj -c Release"
}
if (-not (Test-Path $Engine)) { throw "No engine at $Engine. Build it: cd engine; go build -o bin/runbranch.exe ./cmd/runbranch" }
if (-not (Get-Command python -ErrorAction SilentlyContinue)) { throw "The demo's server is python -m http.server; python is not on PATH." }

# The demo's ports, moved as a block when something real already listens on
# them: a capture must never show, or collide with, the user's own servers.
function Test-PortFree([int]$p) { -not (Get-NetTCPConnection -State Listen -LocalPort $p -ErrorAction SilentlyContinue) }
$base = $Port
while (-not ((Test-PortFree $base) -and (Test-PortFree ($base + 1)) -and (Test-PortFree ($base + 3)))) { $base += 100 }
if ($base -ne $Port) { Write-Warning "port $Port is in use here; the demo serves on $base instead" }

# --- capture helper ----------------------------------------------------------

Add-Type -ReferencedAssemblies System.Drawing -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
using System.Text;

public static class RbShot
{
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
    delegate bool EnumProc(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] static extern bool SetProcessDPIAware();
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc f, IntPtr l);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] static extern bool PrintWindow(IntPtr h, IntPtr hdc, uint flags);
    [DllImport("user32.dll")] static extern uint GetDpiForWindow(IntPtr h);
    [DllImport("user32.dll")] static extern bool PostMessage(IntPtr h, uint msg, IntPtr w, IntPtr l);
    [DllImport("dwmapi.dll")] static extern int DwmGetWindowAttribute(IntPtr h, int attr, out RECT r, int size);

    public static void Init() { SetProcessDPIAware(); }

    /// The app's main window: visible, top-level, WinUI's window class.
    public static IntPtr Find(int pid)
    {
        IntPtr found = IntPtr.Zero;
        EnumWindows(delegate (IntPtr h, IntPtr l)
        {
            uint p; GetWindowThreadProcessId(h, out p);
            if (p != pid || !IsWindowVisible(h)) return true;
            var sb = new StringBuilder(256); GetClassName(h, sb, 256);
            if (sb.ToString() != "WinUIDesktopWin32WindowClass") return true;
            found = h; return false;
        }, IntPtr.Zero);
        return found;
    }

    public static double Scale(IntPtr h) { return GetDpiForWindow(h) / 96.0; }

    public static void Close(IntPtr h) { PostMessage(h, 0x0010, IntPtr.Zero, IntPtr.Zero); }

    /// The window as DWM composes it, cropped to its visible frame (the
    /// window rect also holds the invisible resize borders).
    public static Bitmap Grab(IntPtr h)
    {
        RECT w, f;
        GetWindowRect(h, out w);
        if (DwmGetWindowAttribute(h, 9, out f, Marshal.SizeOf(typeof(RECT))) != 0) f = w;
        var full = new Bitmap(w.Right - w.Left, w.Bottom - w.Top, PixelFormat.Format32bppArgb);
        using (var g = Graphics.FromImage(full))
        {
            var hdc = g.GetHdc();
            try { PrintWindow(h, hdc, 2); } finally { g.ReleaseHdc(hdc); }
        }
        var crop = new Rectangle(f.Left - w.Left, f.Top - w.Top, f.Right - f.Left, f.Bottom - f.Top);
        var shot = full.Clone(crop, PixelFormat.Format32bppArgb);
        full.Dispose();
        return shot;
    }

    /// Whether a capture holds anything: PrintWindow of a window that has not
    /// composed yet comes back one flat colour.
    public static bool HasContent(Bitmap b)
    {
        var first = b.GetPixel(b.Width / 2, b.Height / 2);
        for (int y = 0; y < b.Height; y += 7)
            for (int x = 0; x < b.Width; x += 7)
                if (b.GetPixel(x, y) != first) return true;
        return false;
    }

    static GraphicsPath Rounded(RectangleF r, float radius)
    {
        var p = new GraphicsPath(); float d = radius * 2;
        p.AddArc(r.X, r.Y, d, d, 180, 90);
        p.AddArc(r.Right - d, r.Y, d, d, 270, 90);
        p.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90);
        p.AddArc(r.X, r.Bottom - d, d, d, 90, 90);
        p.CloseFigure();
        return p;
    }

    /// Box blur of an alpha plane, three passes each way: close enough to a
    /// Gaussian for a shadow.
    static void Blur(float[] a, int w, int h, int radius)
    {
        var t = new float[a.Length];
        for (int pass = 0; pass < 3; pass++)
        {
            for (int y = 0; y < h; y++)
            {
                float sum = 0; int row = y * w;
                for (int x = -radius; x <= radius; x++) sum += a[row + Math.Min(w - 1, Math.Max(0, x))];
                for (int x = 0; x < w; x++)
                {
                    t[row + x] = sum / (2 * radius + 1);
                    sum += a[row + Math.Min(w - 1, x + radius + 1)] - a[row + Math.Max(0, x - radius)];
                }
            }
            for (int x = 0; x < w; x++)
            {
                float sum = 0;
                for (int y = -radius; y <= radius; y++) sum += t[Math.Min(h - 1, Math.Max(0, y)) * w + x];
                for (int y = 0; y < h; y++)
                {
                    a[y * w + x] = sum / (2 * radius + 1);
                    sum += t[Math.Min(h - 1, y + radius + 1) * w + x] - t[Math.Max(0, y - radius) * w + x];
                }
            }
        }
    }

    /// The Mac set's framing: the window's own rounded corners, a hairline
    /// edge, and a soft shadow on a transparent margin.
    public static void Frame(Bitmap shot, double scale, bool dark, string path)
    {
        int pad = (int)Math.Round(70 * scale);
        float radius = (float)(8 * scale);
        int W = shot.Width + 2 * pad, H = shot.Height + 2 * pad;
        var canvas = new Bitmap(W, H, PixelFormat.Format32bppArgb);

        // Shadow: the window's shape, blurred, dropped a little.
        var mask = new Bitmap(W, H, PixelFormat.Format32bppArgb);
        using (var g = Graphics.FromImage(mask))
        {
            g.SmoothingMode = SmoothingMode.AntiAlias;
            float drop = (float)(12 * scale);
            using (var p = Rounded(new RectangleF(pad, pad + drop, shot.Width, shot.Height), radius))
                g.FillPath(Brushes.Black, p);
        }
        var alpha = new float[W * H];
        var md = mask.LockBits(new Rectangle(0, 0, W, H), ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
        var px = new byte[W * H * 4];
        Marshal.Copy(md.Scan0, px, 0, px.Length);
        mask.UnlockBits(md); mask.Dispose();
        for (int i = 0; i < alpha.Length; i++) alpha[i] = px[i * 4 + 3] / 255f;
        Blur(alpha, W, H, Math.Max(2, (int)Math.Round(10 * scale)));
        double strength = dark ? 0.55 : 0.30;
        for (int i = 0; i < alpha.Length; i++)
        {
            px[i * 4] = 0; px[i * 4 + 1] = 0; px[i * 4 + 2] = 0;
            px[i * 4 + 3] = (byte)Math.Min(255, Math.Round(alpha[i] * strength * 255));
        }
        var cd = canvas.LockBits(new Rectangle(0, 0, W, H), ImageLockMode.WriteOnly, PixelFormat.Format32bppArgb);
        Marshal.Copy(px, 0, cd.Scan0, px.Length);
        canvas.UnlockBits(cd);

        using (var g = Graphics.FromImage(canvas))
        {
            g.SmoothingMode = SmoothingMode.AntiAlias;
            g.PixelOffsetMode = PixelOffsetMode.HighQuality;
            var r = new RectangleF(pad, pad, shot.Width, shot.Height);
            using (var p = Rounded(r, radius))
            using (var tex = new TextureBrush(shot, WrapMode.Clamp))
            {
                tex.TranslateTransform(pad, pad);
                g.FillPath(tex, p);
            }
            var edge = new RectangleF(pad + 0.5f, pad + 0.5f, shot.Width - 1, shot.Height - 1);
            using (var p = Rounded(edge, radius))
            using (var pen = new Pen(dark ? Color.FromArgb(40, 255, 255, 255) : Color.FromArgb(38, 0, 0, 0), 1))
                g.DrawPath(pen, p);
        }
        canvas.Save(path, ImageFormat.Png);
        canvas.Dispose();
    }
}
'@
[RbShot]::Init()

# --- demo --------------------------------------------------------------------

function Invoke-Engine {
    & $Engine @args *> $null
}

$saved = @{}
function Set-Env([hashtable]$vars) {
    foreach ($k in $vars.Keys) {
        if (-not $saved.ContainsKey($k)) { $saved[$k] = [Environment]::GetEnvironmentVariable($k) }
        [Environment]::SetEnvironmentVariable($k, $vars[$k])
    }
}
function Restore-Env { foreach ($k in $saved.Keys) { [Environment]::SetEnvironmentVariable($k, $saved[$k]) } }

function Stop-Demo {
    Set-Env @{ RB_PROJECTS_DIR = "$Demo\projects"; RB_HOME = "$Demo\state"; RB_NO_OPEN = '1' }
    Invoke-Engine stop northwind-web
}

try {
    "==> demo data in $Demo"
    & (Join-Path $PSScriptRoot 'make-demo.ps1') -Dir $Demo -Port $base | Out-Null
    foreach ($d in "$Empty\projects", "$Empty\state") { New-Item -ItemType Directory -Force $d | Out-Null }

    Set-Env @{ RB_PROJECTS_DIR = "$Demo\projects"; RB_HOME = "$Demo\state"; RB_NO_OPEN = '1' }

    # The Disk sheet exists to show what worktrees cost and to reclaim the dead
    # ones, so it is given a few, one of whose branches has since gone.
    "==> seeding worktrees so the disk scene has something to show"
    $demoRepo = "$Demo\repos\northwind-web"
    & git.exe -C $demoRepo branch chore/retire-legacy-cart main *> $null
    foreach ($ref in 'fix/cart-quantity-race', 'chore/retire-legacy-cart') {
        Invoke-Engine run northwind-web $ref web
        Invoke-Engine stop northwind-web
    }
    & git.exe -C $demoRepo branch -D chore/retire-legacy-cart *> $null

    "==> starting the demo run so health and uptime are real"
    Invoke-Engine run northwind-web feat/checkout-summary web
    $url = "http://localhost:$base/"
    $up = $false
    for ($i = 0; $i -lt 30 -and -not $up; $i++) {
        try { Invoke-WebRequest $url -UseBasicParsing -TimeoutSec 2 | Out-Null; $up = $true } catch { Start-Sleep 1 }
    }
    if (-not $up) { Write-Warning "port $base never answered; health will read as starting" }
    # A few requests, so the log scene has something in it.
    for ($i = 0; $i -lt 6; $i++) {
        try { Invoke-WebRequest $url -UseBasicParsing -TimeoutSec 2 | Out-Null } catch { }
        try { Invoke-WebRequest "${url}pricing" -UseBasicParsing -TimeoutSec 2 | Out-Null } catch { }
    }

    # A private copy of the build. The app is single-instance per folder, so a
    # launch from the build folder would be handed to whatever instance of it
    # is already running there, the developer's own included.
    "==> copying the build to $AppCopy"
    & robocopy.exe $Build $AppCopy /MIR /NFL /NDL /NJH /NJS /NP *> $null
    if ($LASTEXITCODE -ge 8) { throw "robocopy failed ($LASTEXITCODE)" }
    $exe = Join-Path $AppCopy 'Runbranch.exe'

    New-Item -ItemType Directory -Force $Out | Out-Null

    function Shoot([string]$file, [string]$sheet, [string]$projects, [string]$state, [string]$theme, [int]$settle, [string]$size) {
        $dest = Join-Path $Out $file
        Set-Env @{
            RB_PROJECTS_DIR = $projects; RB_HOME = $state
            RB_MY_EMAILS = 'dana@example.com'
            RB_SCAN_ROOT = 'C:\Users\you\Development'
            RB_NO_OPEN = '1'; RB_ENGINE = $Engine; RB_THEME = $theme
            RB_SHOT_QUIET = '1'; RB_DRESS_AS_RELEASE = '1'
            RB_SHOW_SHEET = $sheet; RB_SHEET_LIVE = '1'; RB_SHEET_THEME = $theme
            RB_SHOT_SIZE = $size
        }
        $proc = Start-Process -FilePath $exe -PassThru
        try {
            $hwnd = [IntPtr]::Zero
            for ($i = 0; $i -lt 60 -and $hwnd -eq [IntPtr]::Zero; $i++) { Start-Sleep -Milliseconds 250; $hwnd = [RbShot]::Find($proc.Id) }
            if ($hwnd -eq [IntPtr]::Zero) { Write-Host ("  {0,-24} FAILED (no window)" -f $file); return $false }
            # The harness opens its sheet 3 s after the window loads, and the
            # sheet then fades in; the list and the health probe need a moment too.
            Start-Sleep -Seconds $settle
            $shot = [RbShot]::Grab($hwnd)
            if (-not [RbShot]::HasContent($shot)) { Start-Sleep 2; $shot.Dispose(); $shot = [RbShot]::Grab($hwnd) }
            if (-not [RbShot]::HasContent($shot)) { Write-Host ("  {0,-24} FAILED (blank)" -f $file); return $false }
            # Written beside, then moved: a failed capture keeps the previous image.
            $tmp = Join-Path $Out ".$file.new"
            [RbShot]::Frame($shot, [RbShot]::Scale($hwnd), $theme -eq 'dark', $tmp)
            $shot.Dispose()
            Move-Item -Force $tmp $dest
            $img = [Drawing.Image]::FromFile($dest); $size = "$($img.Width)x$($img.Height)"; $img.Dispose()
            Write-Host ("  {0,-24} {1}" -f $file, $size)
            return $true
        }
        finally {
            if ($hwnd -ne [IntPtr]::Zero) { [RbShot]::Close($hwnd) }
            if (-not $proc.WaitForExit(5000)) { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue }
        }
    }

    $all = [ordered]@{
        main       = @{ file = 'screenshot.png'; sheet = ''; empty = $false; settle = 9 }
        onboarding = @{ file = 'onboarding.png'; sheet = ''; empty = $true; settle = 4 }
        settings   = @{ file = 'settings.png'; sheet = 'editor'; empty = $false; settle = 7 }
        scan       = @{ file = 'scan.png'; sheet = 'scan'; empty = $false; settle = 7 }
        logs       = @{ file = 'logs.png'; sheet = 'logs'; empty = $false; settle = 9 }
        disk       = @{ file = 'disk.png'; sheet = 'disk'; empty = $false; settle = 8 }
        ports      = @{ file = 'ports.png'; sheet = 'ports'; empty = $false; settle = 8 }
        about      = @{ file = 'about.png'; sheet = 'about'; empty = $false; settle = 7 }
        # The main window at its minimum height, for the social card
        # (tools/make-social-card.ps1), whose frame is wider than tall.
        wide       = @{ file = 'screenshot-wide.png'; sheet = ''; empty = $false; settle = 9; size = '1000x440' }
    }
    $want = if ($Scenes -contains 'all') { @($all.Keys) } else { $Scenes }
    $themes = if ($Light) { @('light') } else { @('dark') }

    "==> screenshots"
    $fail = 0
    foreach ($theme in $themes) {
        foreach ($name in $want) {
            if (-not $all.Contains($name)) { Write-Warning "no scene called $name ($($all.Keys -join ', '))"; $fail = 1; continue }
            $s = $all[$name]
            $file = if ($theme -eq 'light') { $s.file -replace '\.png$', '-light.png' } else { $s.file }
            $root = if ($s.empty) { $Empty } else { $Demo }
            if (-not (Shoot $file $s.sheet "$root\projects" "$root\state" $theme $s.settle $s.size)) { $fail = 1 }
        }
    }
}
finally {
    Stop-Demo
    Restore-Env
}
exit $fail
