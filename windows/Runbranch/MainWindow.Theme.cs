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

// Light and dark: which one the window is in, following Windows unless the
// Appearance setting says otherwise, and the parts of the window that do not
// follow on their own — the caption buttons.
//
// The theme is set in exactly one place: Root.RequestedTheme, always to an
// explicit Light or Dark. Not Application.RequestedTheme, which cannot change
// once the app is running; and not ElementTheme.Default for "system", because
// Default means "whatever the app theme was at launch" and would not follow a
// change made in Windows Settings while the app is open. Everything under Root
// — the NavigationView, the list, every {ThemeResource} — follows it, the Mica
// backdrop takes its theme from the window's content, and a dialog reads it
// from the content of the XamlRoot it is shown on.

using Microsoft.UI;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Media;
using Windows.UI;
using Windows.UI.ViewManagement;

namespace Runbranch;

public sealed partial class MainWindow
{
    readonly UISettings uiSettings = new();
    readonly AccessibilitySettings accessibility = new();

    /// <summary>
    /// The theme the window is in right now: Light or Dark, never Default.
    /// The requested theme rather than ActualTheme, which lags until the
    /// content has loaded: read in the constructor it still said the system's
    /// theme, and the caption buttons were coloured for the wrong one.
    /// </summary>
    public ElementTheme EffectiveTheme => Root.RequestedTheme is ElementTheme.Light or ElementTheme.Dark
        ? Root.RequestedTheme
        : Root.ActualTheme;

    void WireTheme()
    {
        // Raised on a background thread, for any colour change in Windows
        // settings — the app mode is one, turning high contrast on or off is
        // another. AccessibilitySettings.HighContrastChanged would say the
        // second more directly, but it needs a CoreWindow, and subscribing to
        // it from an unpackaged app throws.
        uiSettings.ColorValuesChanged += (_, _) => DispatcherQueue.TryEnqueue(() =>
        {
            ApplyTheme();
            ApplyCaptionColours();
        });
        Root.ActualThemeChanged += (_, _) => ApplyCaptionColours();
        Root.Loaded += (_, _) => ApplyCaptionColours();
        ApplyTheme();
    }

    /// <summary>
    /// RB_THEME=light|dark wins for the session without being saved — a
    /// development aid for screenshots of either — then the setting, then
    /// Windows.
    /// </summary>
    void ApplyTheme()
    {
        var appearance = Environment.GetEnvironmentVariable("RB_THEME") switch
        {
            "light" => Appearance.Light,
            "dark" => Appearance.Dark,
            _ => Settings.Shared.Appearance,
        };
        var theme = appearance switch
        {
            Appearance.Light => ElementTheme.Light,
            Appearance.Dark => ElementTheme.Dark,
            _ => SystemIsDark() ? ElementTheme.Dark : ElementTheme.Light,
        };
        if (Root.RequestedTheme != theme) Root.RequestedTheme = theme;
        ApplyCaptionColours();
    }

    /// <summary>
    /// Windows' app mode, as UISettings reports it: in dark mode the system's
    /// foreground colour is white. The documented way to ask, and it changes
    /// the moment the setting does.
    /// </summary>
    bool SystemIsDark()
    {
        var fg = uiSettings.GetColorValue(UIColorType.Foreground);
        return fg.R > 128 && fg.G > 128 && fg.B > 128;
    }

    void SetAppearance(Appearance appearance)
    {
        Settings.Shared.Appearance = appearance;
        ApplyTheme();
    }

    /// <summary>
    /// The minimise, maximise and close buttons. With the content extended
    /// into the title bar they are drawn by the system, which knows nothing
    /// of this window's theme: left alone they were dark glyphs on a dark
    /// window, or light on light. So they are coloured from the same theme
    /// resources as everything else, for the theme actually in effect, and
    /// again whenever it changes. Backgrounds stay transparent over the Mica;
    /// hover and pressed use the subtle fills a stock subtle button uses.
    ///
    /// In high contrast the system's own colours are the right ones, so
    /// every override is cleared.
    /// </summary>
    void ApplyCaptionColours()
    {
        var bar = AppWindow.TitleBar;
        if (IsHighContrast())
        {
            bar.ButtonForegroundColor = null;
            bar.ButtonHoverForegroundColor = null;
            bar.ButtonPressedForegroundColor = null;
            bar.ButtonInactiveForegroundColor = null;
            bar.ButtonBackgroundColor = null;
            bar.ButtonHoverBackgroundColor = null;
            bar.ButtonPressedBackgroundColor = null;
            bar.ButtonInactiveBackgroundColor = null;
            return;
        }
        bar.ButtonForegroundColor = Caption("RbCaptionForeground");
        bar.ButtonHoverForegroundColor = Caption("RbCaptionForeground");
        bar.ButtonPressedForegroundColor = Caption("RbCaptionPressedForeground");
        bar.ButtonInactiveForegroundColor = Caption("RbCaptionInactiveForeground");
        bar.ButtonBackgroundColor = Colors.Transparent;
        bar.ButtonInactiveBackgroundColor = Colors.Transparent;
        bar.ButtonHoverBackgroundColor = Caption("RbCaptionHoverBackground");
        bar.ButtonPressedBackgroundColor = Caption("RbCaptionPressedBackground");
    }

    bool IsHighContrast()
    {
        try { return accessibility.HighContrast; }
        catch (System.Runtime.InteropServices.COMException) { return false; }
    }

    /// <summary>A caption colour from Root's theme dictionaries (MainWindow.xaml), for the theme in effect.</summary>
    Color? Caption(string key)
    {
        var theme = EffectiveTheme == ElementTheme.Dark ? "Dark" : "Light";
        return Root.Resources.ThemeDictionaries.TryGetValue(theme, out var d) && d is ResourceDictionary dict &&
               dict.TryGetValue(key, out var v) && v is SolidColorBrush b
            ? b.Color
            : null;
    }
}
