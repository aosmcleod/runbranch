// Runbranch — run any branch of any project on a real port.
// Copyright (C) 2026 Alec McLeod
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. It is distributed WITHOUT ANY WARRANTY; without even the
// implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
// See the GNU General Public License for more details:
// <https://www.gnu.org/licenses/>.

// SF Symbol names → Windows glyphs.
//
// The names stay the vocabulary (spec D9): a project's SYMBOL is written into
// a .conf that may be committed and opened on a Mac, so it must stay an SF
// name, and the Mac's views name their glyphs the same way. This file is the
// one place that knows what each looks like here.
//
// Two fonts. Segoe Fluent Icons ships with Windows 11 and is what every other
// app's chrome uses, so it wins wherever it has a real match. Fluent UI System
// Icons (MIT, github.com/microsoft/fluentui-system-icons) has what Segoe lacks
// — a git branch, a pull request, a merge, a cube, a database — and is used
// for those when Assets/Fonts/FluentSystemIcons-Resizable.ttf is present.
// Without it, those names fall back to a Segoe approximation, then to the
// package glyph, as an unknown name does (Model.swift's `shippingbox` default).
//
// Every Segoe codepoint below was checked against Microsoft's "Segoe Fluent
// Icons font" reference and rendered from this machine's SegoeIcons.ttf.
// Fluent codepoints are from FluentSystemIcons-Resizable.json at commit
// 9cf8af0f95a555918a60b8147a2f33a6a1248442 — they are assigned per release,
// so a different font file needs the table re-read.

using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace Runbranch;

/// <summary>A glyph and the font it is in, ready for a FontIcon.</summary>
public readonly record struct IconGlyph(string Glyph, FontFamily Family);

public sealed class Icons
{
    Icons() { }

    public const string FluentFontFile = "FluentSystemIcons-Resizable.ttf";

    static readonly Lazy<FontFamily> segoe = new(() => new FontFamily("Segoe Fluent Icons"));
    static readonly Lazy<FontFamily?> fluent = new(() =>
        File.Exists(Path.Combine(AppContext.BaseDirectory, "Assets", "Fonts", FluentFontFile))
            ? new FontFamily($"ms-appx:///Assets/Fonts/{FluentFontFile}#FluentSystemIcons-Resizable")
            : null);

    public static FontFamily Segoe => segoe.Value;
    public static bool HasFluentFont => fluent.Value is not null;

    /// <summary>
    /// segoe: the Segoe Fluent codepoint, or 0 for none. exact: whether it is a
    /// real match rather than the nearest thing. fluent: the Fluent UI System
    /// Icons codepoint, or 0.
    /// </summary>
    readonly record struct Entry(int Segoe, bool Exact, int Fluent);

    static Entry S(int segoe, int fluent = 0) => new(segoe, true, fluent);
    static Entry A(int segoe, int fluent) => new(segoe, false, fluent);
    static Entry F(int fluent) => new(0, false, fluent);

    const int Package = 0xE7B8;

    static readonly Dictionary<string, Entry> map = new(StringComparer.Ordinal)
    {
        // --- the app's own chrome and badges (ui-map §3.2, fixed symbols) ---
        ["line.3.horizontal.decrease"] = S(0xE71C, 0xE8A7),
        ["arrow.clockwise"] = S(0xE72C, 0xE0BF),
        ["ellipsis"] = S(0xE712, 0xEC72),
        ["magnifyingglass"] = S(0xE721, 0xEFD7),
        ["square.stack.3d.up"] = S(0xE81E, 0xF151),        // Layers
        ["arrow.triangle.branch"] = F(0xE2CE),              // branch_fork
        ["arrow.triangle.pull"] = F(0xE2D4),                // branch_request
        ["arrow.triangle.merge"] = F(0xEC3E),               // merge
        ["xmark"] = S(0xE711, 0xE6D3),
        ["shippingbox"] = S(Package, 0xE2A6),
        ["arrow.up.right.square"] = S(0xE8A7, 0xECF4),      // OpenInNewWindow
        ["pencil"] = S(0xE70F, 0xE837),
        ["arrow.down.circle"] = A(0xE896, 0xE0A9),          // Download / arrow_circle_down
        ["exclamationmark.triangle"] = S(0xE7BA, 0xF561),
        ["cloud"] = S(0xE753, 0xE522),
        ["bolt"] = S(0xE945, 0xE8C3),
        ["chevron.down"] = S(0xE70D, 0xE488),
        ["xmark.circle"] = S(0xEA39, 0xE6D5),
        ["xmark.circle.fill"] = S(0xEB90, 0xE6D5),          // StatusErrorFull
        ["checkmark.circle"] = S(0xE930, 0xE462),
        ["checkmark.circle.fill"] = S(0xEC61, 0xE462),      // CompletedSolid
        ["text.alignleft"] = S(0xE8E4, 0xF2F6),
        ["folder"] = S(0xE8B7, 0xE8EB),
        ["folder.badge.plus"] = S(0xE8F4, 0xE8ED),          // NewFolder
        ["doc.badge.gearshape"] = A(0xE8A5, 0xE79F),        // document_settings
        ["network"] = S(0xE968, 0xE99B),
        ["internaldrive"] = S(0xEDA2, 0xE9EF),
        ["externaldrive"] = S(0xEDA2, 0xE9EF),
        ["trash"] = S(0xE74D, 0xE66D),
        ["wifi.exclamationmark"] = S(0xEB5E, 0xF5B5),       // wifi with error
        ["hammer"] = S(0xE90F, 0xF5FD),                     // Repair
        ["wrench.and.screwdriver"] = S(0xE90F, 0xF5FF),

        // --- the project editor's picker (Views.swift SymbolPicker) --------
        ["cube"] = F(0xE5F5),
        ["cube.transparent"] = F(0xE607),
        ["square.stack"] = S(0xE81E, 0xF151),
        ["folder.badge.gearshape"] = A(0xE8B7, 0),
        ["tray.full"] = A(Package, 0xE085),
        ["archivebox"] = A(Package, 0xE085),
        ["briefcase"] = S(0xE821, 0xE2DC),                  // Work
        ["globe"] = S(0xE774, 0xE99B),
        ["globe.americas"] = S(0xE909, 0xE833),             // World
        ["antenna.radiowaves.left.and.right"] = S(0xEC05, 0xE3F0), // NetworkTower
        ["wifi"] = S(0xE701, 0xF5A7),
        ["link"] = S(0xE71B, 0xEB68),
        ["icloud"] = S(0xE753, 0xE522),
        ["point.3.connected.trianglepath.dotted"] = F(0xE6C1), // diagram
        ["server.rack"] = F(0xF009),                        // server_multiple: a rack; plain "server" (F005) reads as a phone at 16 px
        ["cylinder.split.1x2"] = F(0xE64D),                 // database
        ["chart.bar.doc.horizontal"] = A(0xE9D2, 0xE414),
        ["tablecells"] = A(0xE8A9, 0xF1F1),
        ["list.bullet.rectangle"] = S(0xE8FD, 0xF320),
        ["building.2"] = F(0xE30E),
        ["building.columns"] = F(0xE2F8),
        ["storefront"] = S(0xE719, 0xE31C),                 // Shop
        ["cart"] = S(0xE7BF, 0xE3E2),
        ["creditcard"] = S(0xE8C7, 0xED63),
        ["banknote"] = F(0xEC64),
        ["chart.line.uptrend.xyaxis"] = A(0xE9D9, 0xE181),
        ["chart.pie"] = S(0xEB05, 0xE633),
        ["percent"] = A(0xE8EF, 0xE785),                    // Calculator / document_percent
        ["paintpalette"] = S(0xE790, 0xE566),
        ["paintbrush"] = S(0xE771, 0xED12),
        ["swatchpalette"] = A(0xE790, 0xE568),
        ["eyedropper"] = F(0xE88F),
        ["ruler"] = S(0xED5E, 0xEF93),
        ["square.on.circle"] = F(0xF021),                   // shapes
        ["circle.hexagongrid"] = A(0xE8A9, 0xE9C1),
        ["wand.and.stars"] = F(0xF55F),
        ["sparkles"] = F(0xF0F7),
        ["terminal"] = S(0xE756, 0xF5CD),
        ["curlybraces"] = A(0xE943, 0xE2C0),
        ["chevron.left.forwardslash.chevron.right"] = S(0xE943, 0xE54E),
        ["gearshape.2"] = S(0xE9F5, 0xF00F),                // Processing: two gears
        ["cpu"] = F(0xE6AB),
        ["memorychip"] = F(0xE6AB),
        ["ladybug"] = S(0xEBE8, 0xE2F0),
        ["testtube.2"] = F(0xE211),
        ["flask"] = F(0xE211),
        ["doc.text"] = S(0xE8A5, 0xE7BB),
        ["doc.richtext"] = A(0xE8A5, 0xE741),
        ["book"] = S(0xE82D, 0xE23D),
        ["books.vertical"] = S(0xE8F1, 0xEB38),
        ["text.book.closed"] = S(0xE82D, 0xE23D),
        ["newspaper"] = F(0xECAA),
        ["pencil.and.outline"] = S(0xE70F, 0xE837),
        ["signature"] = F(0xF08F),
        ["envelope"] = S(0xE715, 0xEBBC),
        ["bubble.left.and.bubble.right"] = S(0xE8F2, 0xE436),
        ["megaphone"] = S(0xE789, 0xEC30),
        ["bell"] = S(0xEA8F, 0xE02B),
        ["phone"] = S(0xE717, 0xE394),
        ["video"] = S(0xE714, 0xF4FB),
        ["person.2"] = S(0xE716, 0xED75),
        ["person.3"] = A(0xE716, 0xEDA9),
        ["photo"] = S(0xE91B, 0xEA52),
        ["photo.stack"] = S(0xE8B9, 0xEA6A),
        ["film"] = S(0xE8B2, 0xE8A3),
        ["music.note"] = S(0xE8D6, 0xEC8E),
        ["waveform"] = A(0xE8D6, 0xEA05),
        ["mic"] = S(0xE720, 0xEC40),
        ["play.rectangle"] = A(0xE768, 0xF50B),
        ["camera"] = S(0xE722, 0xE3C2),
        ["map"] = A(0xE707, 0xEC16),
        ["location"] = S(0xE81D, 0xEB8C),
        ["signpost.right"] = A(0xE8F0, 0xE6CF),
        ["airplane"] = S(0xE709, 0xE01F),
        ["car"] = S(0xE804, 0xF4D3),
        ["tram"] = S(0xE7C0, 0xF4E7),
        ["leaf"] = S(0xE8BE, 0xEB30),
        ["tree"] = A(0xE8BE, 0xF4A3),
        ["flame"] = F(0xE8B1),
        ["drop"] = S(0xEB42, 0xE803),
        ["sun.max"] = S(0xE706, 0xF597),
        ["moon.stars"] = S(0xE708, 0xF57D),
        ["star"] = S(0xE734, 0xF15D),
        ["heart"] = S(0xEB51, 0xEA0F),
        ["flag"] = S(0xE7C1, 0xE8B7),
        ["tag"] = S(0xE8EC, 0xF283),
        ["bookmark"] = F(0xE272),
        ["pin"] = S(0xE718, 0xEE75),
        ["key"] = S(0xE8D7, 0xEAA7),
        ["lock"] = S(0xE72E, 0xEBAC),
        ["shield"] = S(0xEA18, 0xF039),
        ["checkmark.seal"] = A(0xEB95, 0xE472),
        ["target"] = A(0xE81D, 0xF2A2),
        ["scope"] = A(0xE81D, 0xF2A2),
        ["puzzlepiece"] = S(0xEA86, 0xEEFF),
        ["gamecontroller"] = S(0xE7FC, 0xE967),
        ["dice"] = A(0xE7FC, 0xE237),
        ["crown"] = F(0xE5F1),
        ["gift"] = F(0xE983),
        ["cup.and.saucer"] = S(0xEC32, 0xE7F9),
        ["fork.knife"] = F(0xE927),
    };

    /// <summary>
    /// The picker's names, in the Mac's order. Curated rather than exhaustive,
    /// as there: a few hundred relevant ones beat ten thousand unsearchable ones.
    /// </summary>
    public static readonly IReadOnlyList<string> PickerSymbols =
    [
        // projects and things
        "shippingbox", "cube", "cube.transparent", "square.stack.3d.up", "square.stack",
        "folder", "folder.badge.gearshape", "tray.full", "archivebox", "briefcase",
        // web and network
        "globe", "globe.americas", "network", "antenna.radiowaves.left.and.right",
        "wifi", "link", "cloud", "icloud", "point.3.connected.trianglepath.dotted",
        // servers and data
        "server.rack", "externaldrive", "internaldrive", "cylinder.split.1x2",
        "chart.bar.doc.horizontal", "tablecells", "list.bullet.rectangle",
        // building and business
        "building.2", "building.columns", "storefront", "cart", "creditcard",
        "banknote", "chart.line.uptrend.xyaxis", "chart.pie", "percent",
        // design
        "paintpalette", "paintbrush", "swatchpalette", "eyedropper", "ruler",
        "square.on.circle", "circle.hexagongrid", "wand.and.stars", "sparkles",
        // code and tools
        "terminal", "curlybraces", "chevron.left.forwardslash.chevron.right",
        "hammer", "wrench.and.screwdriver", "gearshape.2", "cpu", "memorychip",
        "ladybug", "testtube.2", "flask",
        // documents and writing
        "doc.text", "doc.richtext", "book", "books.vertical", "text.book.closed",
        "newspaper", "pencil.and.outline", "signature",
        // communication
        "envelope", "bubble.left.and.bubble.right", "megaphone", "bell",
        "phone", "video", "person.2", "person.3",
        // media
        "photo", "photo.stack", "film", "music.note", "waveform", "mic",
        "play.rectangle", "camera",
        // navigation and places
        "map", "location", "signpost.right", "airplane", "car", "tram",
        // nature and misc
        "leaf", "tree", "flame", "drop", "bolt", "sun.max", "moon.stars",
        "star", "heart", "flag", "tag", "bookmark", "pin", "key", "lock",
        "shield", "checkmark.seal", "target", "scope", "puzzlepiece",
        "gamecontroller", "dice", "crown", "gift", "cup.and.saucer", "fork.knife",
    ];

    /// <summary>
    /// The glyph for an SF Symbol name. `.fill` variants share their outline's
    /// entry unless they have their own: the Fluent look is outlines, and one
    /// icon per role (F6) matters more than the fill.
    /// </summary>
    public static IconGlyph Glyph(string? symbol)
    {
        var name = symbol ?? "";
        if (!map.TryGetValue(name, out var e) && name.EndsWith(".fill", StringComparison.Ordinal))
            map.TryGetValue(name[..^".fill".Length], out e);

        if (e.Segoe != 0 && e.Exact) return new(Char(e.Segoe), Segoe);
        if (e.Fluent != 0 && fluent.Value is { } f) return new(Char(e.Fluent), f);
        if (e.Segoe != 0) return new(Char(e.Segoe), Segoe);
        return new(Char(Package), Segoe);
    }

    /// <summary>Whether a name has a glyph of its own rather than the package fallback.</summary>
    public static bool IsKnown(string symbol) =>
        map.ContainsKey(symbol) || (symbol.EndsWith(".fill", StringComparison.Ordinal) && map.ContainsKey(symbol[..^5]));

    static string Char(int codepoint) => char.ConvertFromUtf32(codepoint);

    /// <summary>A FontIcon for a name, at one of the grid's icon sizes (Tokens.xaml: 16 or 12).</summary>
    public static FontIcon Make(string symbol, double size = 16)
    {
        var g = Glyph(symbol);
        return new FontIcon { Glyph = g.Glyph, FontFamily = g.Family, FontSize = size };
    }

    // --- XAML: <FontIcon local:Icons.Symbol="folder" FontSize="16"/> --------

    public static readonly DependencyProperty SymbolProperty = DependencyProperty.RegisterAttached(
        "Symbol", typeof(string), typeof(Icons), new PropertyMetadata(null, OnSymbolChanged));

    public static string GetSymbol(DependencyObject o) => (string)o.GetValue(SymbolProperty);

    public static void SetSymbol(DependencyObject o, string value) => o.SetValue(SymbolProperty, value);

    static void OnSymbolChanged(DependencyObject o, DependencyPropertyChangedEventArgs e)
    {
        if (o is not FontIcon icon) return;
        var g = Glyph(e.NewValue as string);
        icon.FontFamily = g.Family;
        icon.Glyph = g.Glyph;
    }
}
