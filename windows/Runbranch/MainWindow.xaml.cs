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

// The main window's shell: backdrop, title bar, size, what closing it means,
// where a launch begins, the slow tick, and the keyboard. ContentView.swift's
// body and .task, in the parts that are not a section of their own; the rest
// of the window is in the MainWindow.*.cs partials.

using System.Runtime.InteropServices;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Runbranch.Dialogs;
using Windows.Graphics;
using Windows.System;

namespace Runbranch;

public sealed partial class MainWindow : Window
{
    // The Mac's sizes (ContentView.swift, WindowSizer), in DIPs.
    const int MinWidth = 780, MinHeight = 440;
    const int DefaultWidth = 1000, DefaultHeight = 720;
    const int CompactWidth = 520, CompactHeight = 400;

    bool presentedOnce;

    /// <summary>
    /// A slow tick, so a server started while the window sits idle is noticed.
    ///
    /// Both pictures were read on launch and after every operation and never
    /// otherwise, so they could sit wrong for as long as nobody touched
    /// anything — which is most of the time, since a run is meant to outlive
    /// your attention. Thirty seconds and not a tight poll: each read is an
    /// engine call per project.
    /// </summary>
    readonly Microsoft.UI.Dispatching.DispatcherQueueTimer liveTick;

    public MainWindow()
    {
        InitializeComponent();

        SystemBackdrop = new MicaBackdrop();
        ExtendsContentIntoTitleBar = true;
        SetTitleBar(AppTitleBar);
        // The tall caption buttons (48), to match the header: the title bar
        // carries a search box and a toolbar, so it is the tall kind, and the
        // standard 32 px buttons sat in its top two thirds looking unrelated
        // to it. The TitleBar control is 48 once it has content, and centres
        // the 28 px controls in it; it also keeps its interactive children out
        // of the drag region itself.
        AppWindow.TitleBar.PreferredHeightOption = TitleBarHeightOption.Tall;
        AppWindow.SetIcon(Build.IconPath);
        AppWindow.Title = "Runbranch";
        TitleIcon.ImageSource = new BitmapImage(new Uri(Build.MarkUri));

        // Physical pixels, like everything else on AppWindow, so scaled.
        ApplyMinimumSize(compact: false);

        AppWindow.Closing += OnClosing;
        Closed += (_, _) => IsClosed = true;

        health = new HealthMonitor();
        health.PropertyChanged += (_, _) => OnHealthChanged();

        liveTick = DispatcherQueue.CreateTimer();
        liveTick.Interval = TimeSpan.FromSeconds(30);
        liveTick.IsRepeating = true;
        liveTick.Tick += (_, _) => OnLiveTick();

        WireTheme();
        WireToolbar();
        WireSidebar();
        WireDetail();
        WireShortcuts();
#if RB_DEVELOPMENT
        WireProbe();
#endif
        Welcome.ScanRequested += (_, _) => _ = ScanForProjects();
        Welcome.AddRequested += (_, _) => _ = AddProject();

        Render();
        // Not on Loaded: in notification-area-only mode the window is never
        // shown at launch, so its content never loads, and the tray would sit
        // over a window that had not read a single project.
        DispatcherQueue.TryEnqueue(() => _ = Launch());
    }

    public bool IsClosed { get; private set; }

    /// <summary>
    /// Raised when closing the window hid it to the notification area rather
    /// than quitting. The window says so once (spec D6), since a window that
    /// vanishes without a word reads as a crash.
    /// </summary>
    public event EventHandler? HiddenToTray;

    /// <summary>Raw pixels per DIP on the window's current display.</summary>
    public double Scale => GetDpiForWindow(WinRT.Interop.WindowNative.GetWindowHandle(this)) / 96.0;

    /// <summary>
    /// Whether anyone can see the window. Windows has no occlusion state to
    /// ask, the way the Mac's NSApp.occlusionState does; hidden to the tray or
    /// minimised is what can be known, and covers the common cases.
    /// </summary>
    bool IsOnScreen =>
        !IsClosed && AppWindow.IsVisible &&
        AppWindow.Presenter is not OverlappedPresenter { State: OverlappedPresenterState.Minimized };

    /// <summary>
    /// Brings the window up: shown, restored if minimised, in front. The first
    /// time it is also sized — the browser's default, or the welcome screen's
    /// compact size if that is what is showing — and centred on its display.
    /// </summary>
    public void Present()
    {
        if (IsClosed) return;
        if (!presentedOnce)
        {
            presentedOnce = true;
            Resize(compactApplied == true);
        }
        if (AppWindow.Presenter is OverlappedPresenter { State: OverlappedPresenterState.Minimized } p) p.Restore();
#if RB_DEVELOPMENT
        // A docs capture (tools/screenshot.ps1) photographs the window with
        // PrintWindow, which needs neither focus nor a place on screen: shown
        // without activation, beyond the right-hand edge of every display,
        // so a run of captures neither takes the keyboard nor covers the
        // work of whoever is at the machine. The Mac's RB_SHOT_QUIET.
        if (Environment.GetEnvironmentVariable("RB_SHOT_QUIET") == "1")
        {
            // By index: enumerating FindAll's list throws ("ClassFactory
            // cannot supply requested class"), a CsWinRT projection gap.
            var displays = DisplayArea.FindAll();
            var right = 0;
            for (var i = 0; i < displays.Count; i++)
                right = Math.Max(right, displays[i].OuterBounds.X + displays[i].OuterBounds.Width);
            AppWindow.Move(new PointInt32(right + 200, 0));
            // RB_SHOT_SIZE=<w>x<h> in DIPs, for a capture that needs another
            // shape than the default window (the social card's wide one).
            if (Environment.GetEnvironmentVariable("RB_SHOT_SIZE")?.Split('x') is [var w, var h] &&
                int.TryParse(w, out var sw) && int.TryParse(h, out var sh))
                AppWindow.Resize(new SizeInt32((int)Math.Round(sw * Scale), (int)Math.Round(sh * Scale)));
            AppWindow.Show(activateWindow: false);
            return;
        }
#endif
        AppWindow.Show();
        Activate();
        SetForegroundWindow(WinRT.Interop.WindowNative.GetWindowHandle(this));
    }

    void Resize(bool compact)
    {
        var scale = Scale;
        var width = (int)Math.Round((compact ? CompactWidth : DefaultWidth) * scale);
        var height = (int)Math.Round((compact ? CompactHeight : DefaultHeight) * scale);
        var area = DisplayArea.GetFromWindowId(AppWindow.Id, DisplayAreaFallback.Primary).WorkArea;
        width = Math.Min(width, area.Width);
        height = Math.Min(height, area.Height);
        AppWindow.MoveAndResize(new RectInt32(
            area.X + (area.Width - width) / 2, area.Y + (area.Height - height) / 2, width, height));
    }

    void ApplyMinimumSize(bool compact)
    {
        if (AppWindow.Presenter is not OverlappedPresenter p) return;
        var scale = Scale;
        p.PreferredMinimumWidth = (int)Math.Round((compact ? CompactWidth : MinWidth) * scale);
        p.PreferredMinimumHeight = (int)Math.Round((compact ? CompactHeight : MinHeight) * scale);
    }

    bool? compactApplied;

    /// <summary>
    /// The Mac's WindowSizer: onboarding needs a fraction of the room the
    /// branch list does, and a splash floating in a half-empty 1000 px window
    /// reads as a bug. Only acts on a transition, so a window resized by hand
    /// is left alone until the mode actually changes.
    /// </summary>
    void ApplyWindowMode(bool compact)
    {
        if (compactApplied == compact) return;
        compactApplied = compact;
        ApplyMinimumSize(compact);
        if (AppWindow.Presenter is OverlappedPresenter p)
        {
            if (compact && p.State == OverlappedPresenterState.Maximized) p.Restore();
            p.IsResizable = !compact;
            p.IsMaximizable = !compact;
        }
        // Before the first Present the size is Present's to choose, and it
        // reads compactApplied when it does.
        if (presentedOnce) Resize(compact);
    }

    /// <summary>
    /// In a tray mode, closing hides: the notification area is how the window
    /// comes back, and the app keeps running with it (the Mac's AppDelegate
    /// keeps a windowless app alive the same way). In taskbar-only mode,
    /// closing the window of a single-window utility quits it.
    /// </summary>
    void OnClosing(AppWindow sender, AppWindowClosingEventArgs args)
    {
        if (App.Instance is not { } app || app.Quitting) return;
        args.Cancel = true;
        if (Settings.Shared.Presentation.ClosingHides())
        {
            sender.Hide();
            HiddenToTray?.Invoke(this, EventArgs.Empty);
            return;
        }
        app.Quit();
    }

    // --- launch ------------------------------------------------------------

    string projectsDir = "";

    /// <summary>
    /// ContentView's .task: reclaim, projects, select, the live picture, the
    /// selected project, then every other project warmed in the background.
    /// </summary>
    async Task Launch()
    {
        // Reclaim before reading state, so a crash's leftovers are gone before
        // anything is drawn rather than showing as a phantom run.
        await Task.Run(Engine.Reclaim);
        projectsDir = await Task.Run(() => Engine.ProjectsDir);

        var found = await Task.Run(Engine.Projects);
        projects = found;
        loadingProjects = false;
        if (selectedProject is null)
        {
            var first = found.FirstOrDefault()?.Id;
#if RB_DEVELOPMENT
            // For a docs capture, prefer a project that is actually running,
            // as the Mac's loadProjects does for a screenshot: the status
            // strip is the most informative thing on screen, and an idle
            // project hides it.
            if (Environment.GetEnvironmentVariable("RB_SHOT_QUIET") == "1")
                first = await Task.Run(() => found.FirstOrDefault(p => Engine.State(p.Id).Running)?.Id) ?? first;
#endif
            SelectProject(first, reload: false);
        }
        Render();

        liveTick.Start();
        _ = AfterFirstShow();

        await RefreshLive();
        await Reload();

        // Warm every other project in the background so the second switch,
        // and every one after, costs nothing.
        foreach (var p in found.Where(p => p.Id != selectedProject).ToList())
        {
            var id = p.Id;
            var snap = await Task.Run(() => ProjectSnapshot.Load(id));
            // A reload that landed meanwhile is fresher than this.
            cache.TryAdd(id, snap);
        }
    }

    /// <summary>
    /// What's new, then the update check — once there is a window on screen
    /// to put a sheet on. A sheet on a window nobody has opened would be
    /// answered by nobody.
    /// </summary>
    async Task AfterFirstShow()
    {
        while (Root.XamlRoot is null || !IsOnScreen) await Task.Delay(500);
        if (Root.XamlRoot is not { } root) return;

        await Sheets.WhatsNewIfAny(root);

        if (!await Updater.Shared.CheckOnLaunchAsync() || Updater.Shared.Available is null) return;
        // Never over something else: an update is not so urgent that it should
        // interrupt a run in progress. But not dropped either — the first
        // launch after an update shows the changelog, and on the Mac the offer
        // used to be thrown away behind it and not seen again until the menu
        // was used.
        for (var waited = 0; Sheets.IsOpen && waited < 120; waited++) await Task.Delay(500);
        // A minute of some other sheet means they are working. Check for
        // updates… is still there when they are not.
        if (!Sheets.IsOpen && Updater.Shared.Available is not null) await Sheets.Update(root);
    }

    /// <summary>
    /// Nobody is looking at a hidden window, so nothing here is worth the
    /// processes it costs. The Ports sheet is what this is for; the Disk sheet
    /// is not — it costs seconds to measure and worktrees do not change size
    /// while you look at them. A run sheet is streaming and the rest are modal
    /// edits: moving the list under them is worse than being briefly out of
    /// date.
    /// </summary>
    void OnLiveTick()
    {
        if (!IsOnScreen) return;
        if (Sheets.IsOpen && !Sheets.PortsOpen) return;
        _ = RefreshLive();
    }

    // --- keyboard (spec F4) ------------------------------------------------

    void WireShortcuts()
    {
        void Add(VirtualKey key, VirtualKeyModifiers mods, Action action)
        {
            var a = new KeyboardAccelerator { Key = key, Modifiers = mods };
            a.Invoked += (_, e) =>
            {
                // A sheet owns the keyboard while it is up.
                if (Sheets.IsOpen) return;
                e.Handled = true;
                action();
            };
            Root.KeyboardAccelerators.Add(a);
        }

        // Accelerators on the root would otherwise announce themselves as a
        // tooltip on the whole window: an "F5" hanging off the cursor
        // wherever it rests.
        Root.KeyboardAcceleratorPlacementMode = KeyboardAcceleratorPlacementMode.Hidden;

        const VirtualKeyModifiers ctrl = VirtualKeyModifiers.Control;
        const VirtualKeyModifiers shift = VirtualKeyModifiers.Shift;
        const VirtualKeyModifiers none = VirtualKeyModifiers.None;

        // F5 is the toolbar's refresh (engine re-read, then reload); Ctrl+R is
        // the Mac's File > Refresh, which only reloads. Two depths, as there.
        Add(VirtualKey.F5, none, () => _ = RefreshSelected());
        Add(VirtualKey.R, ctrl | shift, () => _ = RefreshSelected());
        Add(VirtualKey.R, ctrl, () => _ = Reload());
        Add(VirtualKey.F5, shift, StopSelected);
        Add((VirtualKey)0xBE, ctrl, StopSelected); // Ctrl+. (VK_OEM_PERIOD)
        Add(VirtualKey.F, ctrl, FocusSearch);
        Add(VirtualKey.N, ctrl, () => _ = AddProject());
        Add(VirtualKey.N, ctrl | shift, () => _ = ScanForProjects());
        Add((VirtualKey)0xBC, ctrl, () => _ = EditSelectedProject()); // Ctrl+, (VK_OEM_COMMA)

        // Ctrl+1…9 in the order the sidebar shows them. The Mac's ⌘1…9 follow
        // the underlying list instead, so ⌘1 could be the third row down.
        for (var i = 0; i < 9; i++)
        {
            var index = i;
            Add(VirtualKey.Number1 + i, ctrl, () =>
            {
                var order = SidebarOrder();
                if (index < order.Count) SelectProject(order[index].Id);
            });
        }
    }

    [DllImport("user32.dll")]
    static extern uint GetDpiForWindow(IntPtr hwnd);

    [DllImport("user32.dll")]
    static extern bool SetForegroundWindow(IntPtr hwnd);
}
