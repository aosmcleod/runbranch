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

using Xunit;

namespace Runbranch.Tests;

public sealed class SettingsTests : IDisposable
{
    readonly string dir = Path.Combine(Path.GetTempPath(), "rb-settings-" + Guid.NewGuid().ToString("N"));
    string File => Path.Combine(dir, "settings.json");

    public void Dispose()
    {
        if (Directory.Exists(dir)) Directory.Delete(dir, recursive: true);
    }

    [Fact]
    public void AMissingFileIsTheDefaults()
    {
        var s = new Settings(File);
        Assert.Equal(Presentation.Taskbar, s.Presentation);
        Assert.True(s.UpdatesCheck);
        Assert.Equal("", s.LastSeenVersion);
        Assert.True(s.SidebarRunningExpanded && s.SidebarFavouritesExpanded && s.SidebarProjectsExpanded);
        Assert.False(System.IO.File.Exists(File));
    }

    [Fact]
    public void ValuesRoundTripUnderTheMacKeys()
    {
        var s = new Settings(File)
        {
            Presentation = Presentation.Tray,
            UpdatesCheck = false,
            LastSeenVersion = "1.5.1",
            SidebarFavouritesExpanded = false,
        };
        var again = new Settings(File);
        Assert.Equal(Presentation.Tray, again.Presentation);
        Assert.False(again.UpdatesCheck);
        Assert.Equal("1.5.1", again.LastSeenVersion);
        Assert.False(again.SidebarFavouritesExpanded);
        var json = System.IO.File.ReadAllText(File);
        Assert.Contains("\"updates.check\": false", json);
        Assert.Contains("\"sidebar.favourites.expanded\": false", json);
        Assert.Contains("\"presentation\": \"tray\"", json);
    }

    [Fact]
    public void ACorruptFileIsSetAsideAndReadsAsDefaults()
    {
        Directory.CreateDirectory(dir);
        System.IO.File.WriteAllText(File, "{ this is not json");
        var s = new Settings(File);
        Assert.Equal(Presentation.Taskbar, s.Presentation);
        Assert.True(System.IO.File.Exists(File + ".corrupt"));
        s.UpdatesCheck = false;
        Assert.False(new Settings(File).UpdatesCheck);
    }

    [Fact]
    public void AWrongTypeReadsAsTheDefault()
    {
        Directory.CreateDirectory(dir);
        System.IO.File.WriteAllText(File, """{ "updates.check": "yes", "presentation": 3, "sidebar.running.expanded": false }""");
        var s = new Settings(File);
        Assert.True(s.UpdatesCheck);
        Assert.Equal(Presentation.Taskbar, s.Presentation);
        Assert.False(s.SidebarRunningExpanded);
    }

    [Fact]
    public void KeysThisVersionDoesNotKnowAreKept()
    {
        Directory.CreateDirectory(dir);
        System.IO.File.WriteAllText(File, """{ "future.key": [1, 2] }""");
        new Settings(File).UpdatesCheck = false;
        Assert.Contains("future.key", System.IO.File.ReadAllText(File));
    }

    [Fact]
    public void AJsonArrayIsNotSettings()
    {
        Directory.CreateDirectory(dir);
        System.IO.File.WriteAllText(File, "[]");
        Assert.True(new Settings(File).UpdatesCheck);
    }

    [Theory]
    [InlineData(Presentation.Taskbar, false)]
    [InlineData(Presentation.Both, true)]
    [InlineData(Presentation.Tray, true)]
    public void WhereTheAppLives(Presentation p, bool tray)
    {
        Assert.Equal(tray, p.ShowsTrayIcon());
        Assert.Equal(tray, p.ClosingHides());
        Assert.Equal(p, Presentations.Parse(p.Raw()));
    }
}
