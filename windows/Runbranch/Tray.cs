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

// The notification-area icon and its menu: the Mac's status item (spec F8).
//
// Shown only in the two tray modes (Settings.Presentation). The main window
// feeds it what to say with Update() as its state changes, since the icon
// lives outside any view, and listens for OpenRequested / StopRequested /
// QuitRequested — App wires Open and Quit; Stop belongs to the main window,
// which knows what the selected project is.

using System.Windows.Input;
using H.NotifyIcon;
using Microsoft.UI.Xaml.Controls;
using Microsoft.Win32;
using Windows.UI.ViewManagement;

namespace Runbranch;

public sealed class Tray : IDisposable
{
    readonly Microsoft.UI.Dispatching.DispatcherQueue queue;
    readonly UISettings ui = new();
    TaskbarIcon? icon;
    bool visible;

    string? project;
    string? branch;
    bool running;
    string? health;

    public Tray()
    {
        queue = Microsoft.UI.Dispatching.DispatcherQueue.GetForCurrentThread();
        // The notification area does not tint icons the way a macOS template
        // image is tinted, so there are two and this picks one. By the
        // taskbar's theme, not the app's: that is what the glyph sits on, and
        // Windows lets the two differ.
        ui.ColorValuesChanged += (_, _) => queue.TryEnqueue(() =>
        {
            if (icon is not null) icon.Icon = LoadIcon();
        });
    }

    /// <summary>Open Runbranch: the menu item, and a left click on the icon.</summary>
    public event EventHandler? OpenRequested;

    /// <summary>Stop the selected project's run.</summary>
    public event EventHandler? StopRequested;

    public event EventHandler? QuitRequested;

    /// <summary>
    /// What the menu says. The selected project, as on the Mac — not every
    /// running one, which is a follow-up for both platforms (spec §2). The
    /// health line is the one the Mac declared and never filled in; pass the
    /// strip's label (HealthRules.Title) while running, null otherwise.
    /// </summary>
    public void Update(string? project, string? branch, bool running, string? health)
    {
        this.project = project;
        this.branch = branch;
        this.running = running;
        this.health = health;
        if (icon is not null) icon.ContextFlyout = BuildMenu();
    }

    public void SetVisible(bool show)
    {
        if (show == visible) return;
        visible = show;
        if (show)
        {
            icon = new TaskbarIcon
            {
                ToolTipText = "Runbranch",
                Icon = LoadIcon(),
                // The native menu, not a XAML flyout in a hidden window: it
                // looks like every other notification-area menu and appears
                // without the window having to exist.
                ContextMenuMode = ContextMenuMode.PopupMenu,
                // Left click is "open", which is what a click on a
                // notification-area icon means on Windows; waiting to rule out
                // a double click only makes it feel slow.
                NoLeftClickDelay = true,
                LeftClickCommand = new Command(() => OpenRequested?.Invoke(this, EventArgs.Empty)),
                ContextFlyout = BuildMenu(),
            };
            icon.ForceCreate(false);
        }
        else
        {
            icon?.Dispose();
            icon = null;
        }
    }

    /// <summary>
    /// A notification from the icon, the first time only: settingsKey records
    /// that it was said. For closing the window in a tray mode (spec D6), where
    /// a window that vanishes without a word reads as a crash — once is enough
    /// to learn where it went, and every time would be nagging.
    /// </summary>
    public void NotifyOnce(string settingsKey, string title, string message)
    {
        if (icon is null || Settings.Shared.GetBool(settingsKey, false)) return;
        Settings.Shared.Set(settingsKey, true);
        try
        {
            icon.ShowNotification(title, message, H.NotifyIcon.Core.NotificationIcon.Info);
        }
        catch (Exception e) when (e is InvalidOperationException or System.ComponentModel.Win32Exception)
        {
            // Notifications off, or the shell refused: the icon is still there.
        }
    }

    MenuFlyout BuildMenu()
    {
        var menu = new MenuFlyout();
        var heading = project is null
            ? "No project selected"
            : running ? $"{project} — {branch ?? "?"}" : $"{project} — not running";
        menu.Items.Add(new MenuFlyoutItem { Text = heading, IsEnabled = false });
        if (running && !string.IsNullOrEmpty(health))
            menu.Items.Add(new MenuFlyoutItem { Text = health, IsEnabled = false });
        menu.Items.Add(new MenuFlyoutSeparator());
        if (running)
            menu.Items.Add(Item("Stop", () => StopRequested?.Invoke(this, EventArgs.Empty)));
        menu.Items.Add(Item("Open Runbranch", () => OpenRequested?.Invoke(this, EventArgs.Empty)));
        menu.Items.Add(new MenuFlyoutSeparator());
        menu.Items.Add(Item("Quit Runbranch", () => QuitRequested?.Invoke(this, EventArgs.Empty)));
        return menu;
    }

    static MenuFlyoutItem Item(string text, Action action) => new() { Text = text, Command = new Command(action) };

    static System.Drawing.Icon LoadIcon()
    {
        var name = TaskbarIsLight() ? "TrayOnLight.ico" : "TrayOnDark.ico";
        // The size the shell asks for at this scale, so the glyph is drawn
        // from the matching frame rather than scaled from another.
        var size = GetSystemMetricsForDpi(SmCxSmIcon, GetDpiForSystem());
        return new System.Drawing.Icon(Path.Combine(AppContext.BaseDirectory, "Assets", name), size, size);
    }

    static bool TaskbarIsLight()
    {
        try
        {
            using var key = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize");
            return key?.GetValue("SystemUsesLightTheme") is int v && v == 1;
        }
        catch (Exception e) when (e is System.Security.SecurityException or UnauthorizedAccessException or IOException)
        {
            return false; // dark is the Windows 11 default taskbar
        }
    }

    const int SmCxSmIcon = 49;

    [System.Runtime.InteropServices.DllImport("user32.dll")]
    static extern int GetSystemMetricsForDpi(int index, uint dpi);

    [System.Runtime.InteropServices.DllImport("user32.dll")]
    static extern uint GetDpiForSystem();

    public void Dispose()
    {
        icon?.Dispose();
        icon = null;
        visible = false;
    }

    sealed class Command(Action action) : ICommand
    {
        public event EventHandler? CanExecuteChanged { add { } remove { } }
        public bool CanExecute(object? parameter) => true;
        public void Execute(object? parameter) => action();
    }
}
