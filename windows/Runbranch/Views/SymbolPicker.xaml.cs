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

using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace Runbranch.Views;

/// <summary>
/// &lt;views:SymbolPicker Symbol="shippingbox" /&gt;
///
/// The value is an SF Symbol name, as a project's SYMBOL is (spec D9): a
/// config may be opened on a Mac, so the picker offers the Mac's names and
/// Icons.cs draws them. The list is curated rather than exhaustive — you scan
/// icons by shape, and a few hundred relevant ones beat ten thousand
/// unsearchable ones.
/// </summary>
public sealed partial class SymbolPicker : UserControl
{
    public SymbolPicker()
    {
        InitializeComponent();
        Show(Icons.PickerSymbols);
        ApplySymbol();
    }

    public static readonly DependencyProperty SymbolProperty = DependencyProperty.Register(
        nameof(Symbol), typeof(string), typeof(SymbolPicker), new PropertyMetadata("", (d, _) => ((SymbolPicker)d).OnSymbolChanged()));

    public string Symbol
    {
        get => (string)GetValue(SymbolProperty);
        set => SetValue(SymbolProperty, value);
    }

    /// <summary>Raised when the user picks one, not when Symbol is set from code.</summary>
    public event EventHandler<string>? Picked;

    void OnSymbolChanged() => ApplySymbol();

    /// <summary>An empty SYMBOL draws as the default the sidebar uses for it.</summary>
    void ApplySymbol() => Icons.SetSymbol(Current, string.IsNullOrEmpty(Symbol) ? Project.DefaultSymbol : Symbol);

    void OnOpened(object? sender, object e)
    {
        Grid.SelectedItem = Icons.PickerSymbols.Contains(Symbol) ? Symbol : null;
        if (Grid.SelectedItem is { } item) Grid.ScrollIntoView(item);
        Search.Focus(FocusState.Programmatic);
    }

    void OnClosed(object? sender, object e) => Search.Text = "";

    void OnSearch(AutoSuggestBox sender, AutoSuggestBoxTextChangedEventArgs args)
    {
        var q = sender.Text.Trim().ToLowerInvariant();
        var matches = q.Length == 0 ? Icons.PickerSymbols : Icons.PickerSymbols.Where(s => s.Contains(q, StringComparison.Ordinal)).ToList();
        Show(matches);
        None.Text = $"Nothing matches “{sender.Text.Trim()}”";
        None.Visibility = matches.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
    }

    void Show(IReadOnlyList<string> symbols)
    {
        Grid.ItemsSource = symbols;
        Grid.SelectedItem = symbols.Contains(Symbol) ? Symbol : null;
    }

    void OnPicked(object sender, ItemClickEventArgs e)
    {
        if (e.ClickedItem is not string name) return;
        Symbol = name;
        Popup.Hide();
        Picked?.Invoke(this, name);
    }
}
