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

namespace Runbranch.Views;

/// <summary>
/// Whether a status glyph is worth drawing on this machine.
///
/// Icons falls back to the package glyph for a name it cannot draw, which is
/// right for a project's own SYMBOL — every project needs some glyph — and
/// wrong for a badge: the git glyphs (pull request, merge, branch) exist only
/// in Fluent UI System Icons, and without that font an "open" pull request
/// badge wore a cardboard box. A badge with no glyph still says what it
/// means; one with the wrong glyph says something else.
/// </summary>
public static class Glyphs
{
    public static string OrNone(string symbol)
    {
        if (symbol.Length == 0 || symbol == Project.DefaultSymbol) return symbol;
        return Icons.Glyph(symbol) == Icons.Glyph(Project.DefaultSymbol) ? "" : symbol;
    }
}
