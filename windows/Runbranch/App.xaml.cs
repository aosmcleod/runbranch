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

// The app itself: where a launch begins once there is XAML, where the app
// lives (taskbar, notification area, or both — spec F5), and what closing the
// window means in each. A port of App.swift's scene, MenuBarController policy
// and AppDelegate; the menu itself is Tray.cs.

using System.Reflection;
using Microsoft.UI.Xaml;

namespace Runbranch;

public partial class App : Application
{
    /// <summary>The running app, once OnLaunched has run.</summary>
    public static App? Instance { get; private set; }

    public MainWindow? Window { get; private set; }
    public Tray? Tray { get; private set; }

    /// <summary>
    /// Set while the app is really quitting, so the window's Closing handler
    /// lets the close through instead of hiding to the notification area.
    /// </summary>
    internal bool Quitting { get; private set; }

    public App()
    {

        InitializeComponent();
        Instance = this;
        UnhandledException += (_, e) => Crash.Record(e.Exception);
    }

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        Window = new MainWindow();
#if RB_DEVELOPMENT
        Dialogs.Harness.Attach(Window); // development aid: RB_SHOW_SHEET=<name> opens one sheet over demo data (Dialogs/Harness.cs)
#endif
        Tray = new Tray();
        Tray.OpenRequested += (_, _) => ShowWindow();
        Tray.QuitRequested += (_, _) => Quit();
        // Stop belongs to the window, which knows what is selected.
        Tray.StopRequested += (_, _) => Window.StopFromTray();
        Window.HiddenToTray += (_, _) => Tray.NotifyOnce(TrayHintKey, "Runbranch is still running",
            "It is in the notification area. Quit it from there.");

        Apply(Settings.Shared.Presentation, initial: true);

        // Notification area only starts in the notification area. The Mac
        // shows its window anyway in menu-bar-only mode, but only because a
        // SwiftUI scene cannot be told at runtime not to open one; here the
        // setting can simply be honoured. Launching the exe again brings the
        // window up (Program.cs), as does the tray icon.
        if (Settings.Shared.Presentation != Presentation.Tray) ShowWindow();
    }

    /// <summary>Set once the "still running" notice has been shown, so it is said once and not every close.</summary>
    const string TrayHintKey = "tray.hiddenNoticeShown";

    /// <summary>
    /// Where the app lives. `initial` is the application of the saved setting
    /// at launch, which must not also summon the window: OnLaunched decides
    /// that.
    /// </summary>
    public void Apply(Presentation next, bool initial = false)
    {
        // Launch reads the setting rather than writing it back: a launch is
        // not a change, and a write per launch is a write for nothing.
        if (!initial) Settings.Shared.Presentation = next;
        Tray?.SetVisible(next.ShowsTrayIcon());

        // Moving out of notification-area-only does not bring the window back
        // on its own, and the user asked for a change of where the app lives,
        // not for their window to vanish.
        if (!initial && next != Presentation.Tray) ShowWindow();
    }

    /// <summary>A second launch, redirected here by Program.cs. Off the UI thread.</summary>
    internal void OnActivatedAgain() => Window?.DispatcherQueue.TryEnqueue(ShowWindow);

    public void ShowWindow() => Window?.Present();

    /// <summary>Quit Runbranch, from the tray menu or the ••• menu. Runs are left running, as on the Mac.</summary>
    public void Quit()
    {
        Quitting = true;
        Tray?.Dispose();
        Window?.Close();
        Exit();
    }
}

/// <summary>What kind of build this is, and which version.</summary>
public static class Build
{
    static readonly Assembly assembly = typeof(Build).Assembly;

    /// <summary>
    /// The version, from make-app.sh (Runbranch.csproj reads it there, as
    /// docs/VERSIONING.md says it lives). Without the "+commit" suffix the SDK
    /// appends to the informational version.
    /// </summary>
    public static string Version { get; } =
        (assembly.GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion ?? "0.0.0")
        .Split('+')[0];

    /// <summary>
    /// A development build: anything not built with make-app.ps1 -Release.
    /// About says so, the icon is inverted, and the updater does not run — an
    /// update would replace the build you are working on with a release. A
    /// release says nothing about a distinction its user has no reason to
    /// know about.
    /// </summary>
    public static bool IsDevelopment { get; } =
        assembly.GetCustomAttributes<AssemblyMetadataAttribute>()
            .FirstOrDefault(a => a.Key == "RBBuildChannel")?.Value != "release";

    /// <summary>
    /// Whether the build looks like one: the inverted mark and About's badge.
    /// A development build can be told to look like a release instead
    /// (RB_DRESS_AS_RELEASE=1), because the docs captures need the sheet
    /// harness, which only a development build has, and must still show the
    /// app people install (tools/screenshot.ps1). Looks only: the updater
    /// still reads IsDevelopment, so a dressed build never offers to replace
    /// itself with a release. A release build ignores the variable.
    /// </summary>
    public static bool LooksDevelopment { get; } = IsDevelopment
#if RB_DEVELOPMENT
        && Environment.GetEnvironmentVariable("RB_DRESS_AS_RELEASE") != "1"
#endif
        ;

    /// <summary>The bare glyph for in-app use (About, dialog headers).</summary>
    public static string MarkUri => LooksDevelopment ? "ms-appx:///Assets/Mark-dev.png" : "ms-appx:///Assets/Mark.png";

    /// <summary>The window and taskbar icon.</summary>
    public static string IconPath =>
        Path.Combine(AppContext.BaseDirectory, "Assets", LooksDevelopment ? "Runbranch-dev.ico" : "Runbranch.ico");

    public const string RepositoryUrl = "https://github.com/aosmcleod/runbranch";
}

/// <summary>
/// An unpackaged app that dies leaves nothing behind but an Event Viewer
/// entry nobody reads. Write the exception where it can be found.
/// </summary>
static class Crash
{
    public static void Record(Exception e)
    {
        try
        {
            var dir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Runbranch");
            Directory.CreateDirectory(dir);
            File.AppendAllText(Path.Combine(dir, "crash.log"), $"{DateTimeOffset.Now:u} {Build.Version}\n{e}\n\n");
        }
        catch (Exception) { /* nowhere to report that */ }
    }
}
