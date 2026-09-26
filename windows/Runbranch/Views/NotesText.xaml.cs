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

using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Documents;
using Microsoft.UI.Xaml.Media;

namespace Runbranch.Views;

/// <summary>
/// &lt;views:NotesText Text="{x:Bind notes}" /&gt; — what Notes.Parse makes of
/// a changelog section, one selectable text block per line.
///
/// Text blocks rather than a single RichTextBlock: a paragraph in a
/// RichTextBlock cannot take a theme brush of its own from code, and the
/// headings and the body are different colours. The Mac's version is one
/// Text per line too, so selection is per line on both.
/// </summary>
public sealed partial class NotesText : UserControl
{
    public NotesText() => InitializeComponent();

    public static readonly DependencyProperty TextProperty = DependencyProperty.Register(
        nameof(Text), typeof(string), typeof(NotesText), new PropertyMetadata("", (d, _) => ((NotesText)d).Build()));

    public string Text
    {
        get => (string)GetValue(TextProperty);
        set => SetValue(TextProperty, value);
    }

    Style Named(string key) => (Style)Resources[key];

    void Build()
    {
        Lines.Children.Clear();
        var gap = false;
        foreach (var line in Runbranch.Notes.Parse(Text ?? ""))
        {
            if (line.Kind == NoteKind.Gap)
            {
                gap = true;
                continue;
            }
            FrameworkElement element = line.Kind switch
            {
                NoteKind.Heading => Block(line, "NotesHeadingStyle"),
                NoteKind.Bullet => Bullet(line),
                _ => Block(line, "NotesBodyStyle"),
            };
            // A blank line in the source is a gap here, added to whatever
            // margin the next line already has.
            if (gap && Lines.Children.Count > 0)
            {
                var m = element.Margin;
                element.Margin = new Thickness(m.Left, m.Top + (double)Resources["NotesGap"], m.Right, m.Bottom);
            }
            gap = false;
            Lines.Children.Add(element);
        }
    }

    TextBlock Block(NoteLine line, string style)
    {
        var block = new TextBlock { Style = Named(style) };
        foreach (var span in line.Spans) block.Inlines.Add(Inline(span));
        return block;
    }

    Grid Bullet(NoteLine line)
    {
        var body = Block(line, "NotesBodyStyle");
        var grid = new Grid { Margin = body.Margin };
        body.Margin = new Thickness(0);
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        var dot = new TextBlock { Text = "·", Style = Named("NotesDotStyle") };
        Grid.SetColumn(body, 1);
        grid.Children.Add(dot);
        grid.Children.Add(body);
        return grid;
    }

    static Inline Inline(NoteSpan span)
    {
        var run = new Run { Text = span.Text };
        if (span.Code) run.FontFamily = (FontFamily)Application.Current.Resources["RbMonoFontFamily"];
        if (span.Bold) run.FontWeight = FontWeights.SemiBold;
        if (span.Italic) run.FontStyle = Windows.UI.Text.FontStyle.Italic;
        return run;
    }
}
