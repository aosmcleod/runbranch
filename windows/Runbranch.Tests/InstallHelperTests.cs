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

using System.Diagnostics;
using Xunit;

namespace Runbranch.Tests;

/// <summary>
/// The hand-off between Updates.cs and `runbranch.exe install-update`: the
/// arguments the app passes, run by a copy of the real engine, against a fake
/// install folder under %TEMP% — never the real one. The swap itself is
/// tested in engine/internal/update; these pin that the two ends agree.
/// Skipped when engine\bin\runbranch.exe has not been built.
/// </summary>
public sealed class InstallHelperTests : IDisposable
{
    static readonly string Engine = Path.GetFullPath(Path.Combine(AppContext.BaseDirectory, "..", "..", "..", "..", "..", "engine", "bin", "runbranch.exe"));

    readonly string root = Path.Combine(Path.GetTempPath(), "rb-install-" + Guid.NewGuid().ToString("N"));
    string Target => Path.Combine(root, "Runbranch");
    string Staging => Path.Combine(root, ".Runbranch-update-test");
    string Source => Path.Combine(Staging, "Runbranch");
    string Work => Path.Combine(root, "work");
    string Log => Path.Combine(root, "update.log");
    string Helper => Path.Combine(Work, "runbranch.exe");

    public InstallHelperTests()
    {
        Directory.CreateDirectory(Path.Combine(Target, "bin"));
        File.WriteAllText(Path.Combine(Target, "Runbranch.exe"), "old");
        Directory.CreateDirectory(Path.Combine(Source, "bin"));
        File.WriteAllText(Path.Combine(Source, "Runbranch.exe"), "new");
        File.WriteAllText(Path.Combine(Source, Updater.EnginePath), "new");
        Directory.CreateDirectory(Work);
        if (CanRun) File.Copy(Engine, Helper);
    }

    public void Dispose()
    {
        if (Directory.Exists(root)) Directory.Delete(root, recursive: true);
    }

    static bool CanRun => OperatingSystem.IsWindows() && File.Exists(Engine);

    /// <summary>An app that takes a few seconds to quit, with no window.</summary>
    static Process SlowApp(int seconds) =>
        Process.Start(new ProcessStartInfo("cmd.exe", $"/d /c ping -n {seconds + 1} 127.0.0.1 >nul")
            { UseShellExecute = false, CreateNoWindow = true })!;

    Process Start(int pid) => Updater.StartHelper(Helper,
        [.. Updater.HelperArgs(pid.ToString(System.Globalization.CultureInfo.InvariantCulture), Source, Target, Staging, Work),
         "--log", Log, "--no-relaunch"]);

    [Fact]
    public void SaysItStartedWhileTheAppIsStillOpenThenSwaps()
    {
        if (!CanRun) return;
        using var app = SlowApp(3);
        using var p = Start(app.Id);
        var seen = false;
        for (var i = 0; i < 100 && !seen; i++)
        {
            seen = File.Exists(Path.Combine(Work, "started"));
            if (!seen) Thread.Sleep(50);
        }
        Assert.True(seen, "started never appeared");
        Assert.False(app.HasExited, "it should say so before the app quits, not after");
        Assert.True(p.WaitForExit(60_000));
        Assert.Equal(0, p.ExitCode);
        Assert.Equal("new", File.ReadAllText(Path.Combine(Target, "Runbranch.exe")));
        Assert.False(Directory.Exists(Staging));
        Assert.Empty(Directory.GetDirectories(root, "Runbranch.replaced-*"));
        Assert.Contains("swapped", File.ReadAllText(Log));
    }

    [Fact]
    public void ANewFolderWithNoEngineIsRefusedBeforeItStarts()
    {
        if (!CanRun) return;
        File.Delete(Path.Combine(Source, Updater.EnginePath));
        using var app = SlowApp(30);
        try
        {
            using var p = Start(app.Id);
            Assert.True(p.WaitForExit(10_000));
            // An early exit is what HandOffAsync reports, with the app still open.
            Assert.Equal(1, p.ExitCode);
            Assert.False(File.Exists(Path.Combine(Work, "started")));
            Assert.Equal("old", File.ReadAllText(Path.Combine(Target, "Runbranch.exe")));
            Assert.Contains("nothing changed", File.ReadAllText(Log));
        }
        finally { app.Kill(entireProcessTree: true); }
    }
}
