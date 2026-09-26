# Runbranch — run any branch of any project on a real port.
# Copyright (C) 2026 Alec McLeod
#
# This program is free software: you can redistribute it and/or modify it
# under the terms of the GNU General Public License as published by the Free
# Software Foundation, either version 3 of the License, or (at your option)
# any later version. It is distributed WITHOUT ANY WARRANTY; without even the
# implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
# See the GNU General Public License for more details:
# <https://www.gnu.org/licenses/>.

# The Windows icons, rendered from the same masters the Mac uses:
#
#   Runbranch.ico / Runbranch-dev.ico   the app icon, 16-256, from
#                                       docs/img/mark-256.png (the dev one
#                                       with its colours inverted, as on the Mac)
#   Mark.png / Mark-dev.png             the bare glyph the app draws inside
#                                       its own windows (About, dialog headers)
#   TrayOnDark.ico / TrayOnLight.ico    notification-area glyphs, from
#                                       assets/mark-template.svg
#
# Needs nothing but Windows PowerShell or pwsh: System.Drawing does the
# drawing, and the SVG is simple enough (absolute M/C/Z paths, one translate)
# to parse here rather than install a renderer. The outputs are small and
# committed, so this only needs running when a master changes.
#
#   .\windows\make-icons.ps1

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$out = Join-Path $PSScriptRoot 'Runbranch\Assets'
New-Item -ItemType Directory -Force $out | Out-Null

$refs = if ($PSVersionTable.PSEdition -eq 'Core') {
    @('System.Drawing.Common', 'System.Drawing.Primitives', 'System.Collections', 'System.Text.RegularExpressions', 'System.Runtime')
} else {
    @('System.Drawing')
}

Add-Type -ReferencedAssemblies $refs -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Globalization;
using System.IO;
using System.Text.RegularExpressions;

public static class RbIcons
{
    // The mark is wider than it is tall. Centre it in a square rather than
    // stretch it, and trim the transparent margin first so every size is
    // placed by the artwork, not by whatever padding the PNG happens to have.
    public static Bitmap Trim(Bitmap src)
    {
        int minX = src.Width, minY = src.Height, maxX = -1, maxY = -1;
        for (int y = 0; y < src.Height; y++)
            for (int x = 0; x < src.Width; x++)
                if (src.GetPixel(x, y).A > 8)
                {
                    if (x < minX) minX = x; if (x > maxX) maxX = x;
                    if (y < minY) minY = y; if (y > maxY) maxY = y;
                }
        if (maxX < 0) return new Bitmap(src);
        var r = new Rectangle(minX, minY, maxX - minX + 1, maxY - minY + 1);
        var b = new Bitmap(r.Width, r.Height, PixelFormat.Format32bppArgb);
        using (var g = Graphics.FromImage(b))
            g.DrawImage(src, new Rectangle(0, 0, r.Width, r.Height), r, GraphicsUnit.Pixel);
        return b;
    }

    public static Bitmap Fit(Image art, int size, double fill)
    {
        var b = new Bitmap(size, size, PixelFormat.Format32bppArgb);
        using (var g = Graphics.FromImage(b))
        {
            g.InterpolationMode = InterpolationMode.HighQualityBicubic;
            g.PixelOffsetMode = PixelOffsetMode.HighQuality;
            g.SmoothingMode = SmoothingMode.HighQuality;
            double box = size * fill;
            double scale = Math.Min(box / art.Width, box / art.Height);
            double w = art.Width * scale, h = art.Height * scale;
            g.DrawImage(art, new RectangleF((float)((size - w) / 2), (float)((size - h) / 2), (float)w, (float)h));
        }
        return b;
    }

    // Colours inverted, alpha kept: the development build's mark, so the copy
    // being worked on is not mistakable for the installed one.
    public static Bitmap Invert(Bitmap src)
    {
        var b = new Bitmap(src.Width, src.Height, PixelFormat.Format32bppArgb);
        for (int y = 0; y < src.Height; y++)
            for (int x = 0; x < src.Width; x++)
            {
                var c = src.GetPixel(x, y);
                b.SetPixel(x, y, Color.FromArgb(c.A, 255 - c.R, 255 - c.G, 255 - c.B));
            }
        return b;
    }

    // 32-bit DIB entries below 256, PNG only at 256. The shell reads PNG at
    // every size, but System.Drawing.Icon — which the tray library converts
    // through — reads a PNG entry as a bitmap and draws noise. That was the
    // first version of this.
    public static void WriteIco(string path, IList<Bitmap> images)
    {
        var blobs = new List<byte[]>();
        foreach (var img in images)
            blobs.Add(img.Width >= 256 ? Png(img) : Dib(img));
        using (var fs = File.Create(path))
        using (var w = new BinaryWriter(fs))
        {
            w.Write((ushort)0); w.Write((ushort)1); w.Write((ushort)images.Count);
            int offset = 6 + 16 * images.Count;
            for (int i = 0; i < images.Count; i++)
            {
                int s = images[i].Width;
                w.Write((byte)(s >= 256 ? 0 : s)); w.Write((byte)(s >= 256 ? 0 : s));
                w.Write((byte)0); w.Write((byte)0);
                w.Write((ushort)1); w.Write((ushort)32);
                w.Write(blobs[i].Length); w.Write(offset);
                offset += blobs[i].Length;
            }
            foreach (var blob in blobs) w.Write(blob);
        }
    }

    static byte[] Png(Bitmap img)
    {
        using (var ms = new MemoryStream()) { img.Save(ms, ImageFormat.Png); return ms.ToArray(); }
    }

    // BITMAPINFOHEADER with the height doubled (XOR image + AND mask), BGRA
    // rows bottom-up, then a 1-bit AND mask padded to 32-bit rows. The mask is
    // all zeros: the alpha channel says everything, and a set bit would punch
    // holes in anti-aliased edges on anything that honours both.
    static byte[] Dib(Bitmap img)
    {
        int w = img.Width, h = img.Height;
        int maskStride = ((w + 31) / 32) * 4;
        using (var ms = new MemoryStream())
        using (var bw = new BinaryWriter(ms))
        {
            bw.Write(40); bw.Write(w); bw.Write(h * 2);
            bw.Write((ushort)1); bw.Write((ushort)32);
            bw.Write(0); bw.Write(w * h * 4 + maskStride * h);
            bw.Write(0); bw.Write(0); bw.Write(0); bw.Write(0);
            for (int y = h - 1; y >= 0; y--)
                for (int x = 0; x < w; x++)
                {
                    var c = img.GetPixel(x, y);
                    bw.Write(c.B); bw.Write(c.G); bw.Write(c.R); bw.Write(c.A);
                }
            bw.Write(new byte[maskStride * h]);
            bw.Flush();
            return ms.ToArray();
        }
    }

    // --- SVG, the subset mark-template.svg uses --------------------------

    public sealed class Shape { public GraphicsPath Path; public float Opacity = 1; }

    public static List<Shape> ReadSvg(string file, out RectangleF bounds)
    {
        string svg = File.ReadAllText(file);
        float tx = 0, ty = 0;
        var t = Regex.Match(svg, "translate\\(\\s*(-?[\\d.]+)[\\s,]+(-?[\\d.]+)\\s*\\)");
        if (t.Success) { tx = F(t.Groups[1].Value); ty = F(t.Groups[2].Value); }
        var shapes = new List<Shape>();
        foreach (Match m in Regex.Matches(svg, "<path([^>]*)>"))
        {
            string attrs = m.Groups[1].Value;
            var d = Regex.Match(attrs, "\\sd=\"([^\"]+)\"");
            if (!d.Success) continue;
            var op = Regex.Match(attrs, "opacity=\"([\\d.]+)\"");
            var shape = new Shape { Path = Parse(d.Groups[1].Value, tx, ty) };
            if (op.Success) shape.Opacity = F(op.Groups[1].Value);
            shapes.Add(shape);
        }
        bounds = RectangleF.Empty;
        foreach (var s in shapes)
            bounds = bounds.IsEmpty ? s.Path.GetBounds() : RectangleF.Union(bounds, s.Path.GetBounds());
        return shapes;
    }

    static float F(string s) { return float.Parse(s, CultureInfo.InvariantCulture); }

    static GraphicsPath Parse(string d, float tx, float ty)
    {
        // Nonzero, SVG's default fill rule. The template's lens is its own
        // opposite-wound subpath, which is what knocks it out of the petals.
        var path = new GraphicsPath(FillMode.Winding);
        var tokens = Regex.Matches(d, "[MmLlHhVvCcZz]|-?(?:\\d+\\.?\\d*|\\.\\d+)(?:[eE][-+]?\\d+)?");
        int i = 0; char cmd = 'M';
        PointF cur = new PointF(0, 0), start = cur;
        Func<float> num = () => F(tokens[i++].Value);
        Func<bool> more = () => i < tokens.Count && !char.IsLetter(tokens[i].Value[0]);
        while (i < tokens.Count)
        {
            if (char.IsLetter(tokens[i].Value[0])) cmd = tokens[i++].Value[0];
            bool rel = char.IsLower(cmd);
            switch (char.ToUpperInvariant(cmd))
            {
                case 'M':
                    path.StartFigure();
                    cur = rel ? new PointF(cur.X + num(), cur.Y + num()) : new PointF(num(), num());
                    start = cur;
                    cmd = rel ? 'l' : 'L';
                    break;
                case 'L':
                {
                    var p = rel ? new PointF(cur.X + num(), cur.Y + num()) : new PointF(num(), num());
                    path.AddLine(Shift(cur, tx, ty), Shift(p, tx, ty)); cur = p; break;
                }
                case 'H':
                {
                    var p = new PointF(rel ? cur.X + num() : num(), cur.Y);
                    path.AddLine(Shift(cur, tx, ty), Shift(p, tx, ty)); cur = p; break;
                }
                case 'V':
                {
                    var p = new PointF(cur.X, rel ? cur.Y + num() : num());
                    path.AddLine(Shift(cur, tx, ty), Shift(p, tx, ty)); cur = p; break;
                }
                case 'C':
                {
                    PointF a, b, c;
                    if (rel) { a = new PointF(cur.X + num(), cur.Y + num()); b = new PointF(cur.X + num(), cur.Y + num()); c = new PointF(cur.X + num(), cur.Y + num()); }
                    else { a = new PointF(num(), num()); b = new PointF(num(), num()); c = new PointF(num(), num()); }
                    path.AddBezier(Shift(cur, tx, ty), Shift(a, tx, ty), Shift(b, tx, ty), Shift(c, tx, ty));
                    cur = c; break;
                }
                case 'Z':
                    path.CloseFigure(); cur = start;
                    break;
                default:
                    throw new InvalidDataException("unsupported path command " + cmd);
            }
            if (char.ToUpperInvariant(cmd) == 'Z' && more()) cmd = 'L';
        }
        return path;
    }

    static PointF Shift(PointF p, float tx, float ty) { return new PointF(p.X + tx, p.Y + ty); }

    public static Bitmap RenderGlyph(List<Shape> shapes, RectangleF bounds, int size, Color colour, double fill)
    {
        var b = new Bitmap(size, size, PixelFormat.Format32bppArgb);
        using (var g = Graphics.FromImage(b))
        {
            g.SmoothingMode = SmoothingMode.AntiAlias;
            g.PixelOffsetMode = PixelOffsetMode.HighQuality;
            double box = size * fill;
            float scale = (float)Math.Min(box / bounds.Width, box / bounds.Height);
            g.TranslateTransform(size / 2f, size / 2f);
            g.ScaleTransform(scale, scale);
            g.TranslateTransform(-(bounds.X + bounds.Width / 2), -(bounds.Y + bounds.Height / 2));
            foreach (var s in shapes)
                using (var brush = new SolidBrush(Color.FromArgb((int)Math.Round(255 * s.Opacity), colour)))
                    g.FillPath(brush, s.Path);
        }
        return b;
    }
}
'@

# --- app icon ---------------------------------------------------------------
# 0.94: Windows app icons are unplated glyphs that run close to the edge, and
# the taskbar draws them small enough that a generous margin reads as shrunk.
$appSizes = 16, 20, 24, 32, 40, 48, 64, 128, 256
$src = New-Object System.Drawing.Bitmap (Join-Path $repo 'docs\img\mark-256.png')
$art = [RbIcons]::Trim($src)
$dev = [RbIcons]::Invert($art)
foreach ($variant in @(@{ Name = 'Runbranch'; Art = $art }, @{ Name = 'Runbranch-dev'; Art = $dev })) {
    $images = foreach ($s in $appSizes) { [RbIcons]::Fit($variant.Art, $s, 0.94) }
    [RbIcons]::WriteIco((Join-Path $out "$($variant.Name).ico"), [System.Drawing.Bitmap[]]$images)
    Write-Host "    $($variant.Name).ico"
}
[RbIcons]::Fit($art, 256, 1.0).Save((Join-Path $out 'Mark.png'), [System.Drawing.Imaging.ImageFormat]::Png)
[RbIcons]::Fit($dev, 256, 1.0).Save((Join-Path $out 'Mark-dev.png'), [System.Drawing.Imaging.ImageFormat]::Png)
Write-Host '    Mark.png, Mark-dev.png'

# --- notification area ------------------------------------------------------
# The notification area does not tint icons the way a macOS template image is
# tinted, so there are two: white for a dark taskbar, near-black for a light
# one. Tray.cs picks by the taskbar's theme, not the app's, because that is
# what the glyph sits on. Only alpha carries the shape, as on the Mac: the
# lens is laid back in at 85% so the silhouette reads as two petals.
$bounds = [System.Drawing.RectangleF]::Empty
$shapes = [RbIcons]::ReadSvg((Join-Path $repo 'assets\mark-template.svg'), [ref]$bounds)
$traySizes = 16, 20, 24, 32, 40, 48, 64
$onDark = foreach ($s in $traySizes) { [RbIcons]::RenderGlyph($shapes, $bounds, $s, [System.Drawing.Color]::White, 0.98) }
$onLight = foreach ($s in $traySizes) { [RbIcons]::RenderGlyph($shapes, $bounds, $s, [System.Drawing.Color]::FromArgb(255, 28, 28, 28), 0.98) }
[RbIcons]::WriteIco((Join-Path $out 'TrayOnDark.ico'), [System.Drawing.Bitmap[]]$onDark)
[RbIcons]::WriteIco((Join-Path $out 'TrayOnLight.ico'), [System.Drawing.Bitmap[]]$onLight)
Write-Host '    TrayOnDark.ico, TrayOnLight.ico'
