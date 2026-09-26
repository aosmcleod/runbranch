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

using System.Text;
using Runbranch.Dialogs;
using Xunit;

namespace Runbranch.Tests;

public sealed class DiskRulesTests
{
    static DiskRow R(string project, long kb, string state, string @ref = "main") => new(project, "slug", @ref, kb, state);

    [Fact]
    public void SummarySpellsOutSingularsAndPlurals()
    {
        Assert.Equal("Measuring…", DiskRules.Summary(null));
        Assert.Equal("Nothing on disk yet", DiskRules.Summary([]));
        Assert.Equal("1 worktree · 49 KB, all of it in use", DiskRules.Summary([R("a", 48, "running")]));
        Assert.Equal("3 worktrees · 82 KB, 33 KB not in use",
            DiskRules.Summary([R("a", 48, "running"), R("a", 16, "idle"), R("b", 16, "gone")]));
    }

    [Fact]
    public void FooterNamesHowManyProjectsCanBeReclaimed()
    {
        Assert.Null(DiskRules.Footer(null));
        Assert.Equal("Nothing to reclaim — every worktree's branch still exists.", DiskRules.Footer([R("a", 1, "idle")]));
        Assert.Equal("One project has worktrees whose branch is gone", DiskRules.Footer([R("a", 1, "gone"), R("a", 1, "gone")]));
        Assert.Equal("2 projects have worktrees whose branch is gone", DiskRules.Footer([R("a", 1, "gone"), R("b", 1, "gone")]));
        Assert.Equal(["a", "b"], DiskRules.Prunable([R("a", 1, "gone"), R("b", 1, "gone"), R("a", 1, "gone")]));
    }

    [Fact]
    public void AnUnknownRefShowsTheSlug()
    {
        Assert.Equal("slug", DiskRules.Title(R("a", 1, "idle", "?")));
        Assert.Equal("feat/x", DiskRules.Title(R("a", 1, "idle", "feat/x")));
    }

    [Fact]
    public void Badges()
    {
        Assert.Equal(new BadgeSpec("running", "bolt.fill", Tone.Green), DiskRules.Badge(R("a", 1, "running")));
        Assert.Equal("branch gone", DiskRules.Badge(R("a", 1, "gone")).Text);
        Assert.Equal(new BadgeSpec("idle", "", Tone.Secondary), DiskRules.Badge(R("a", 1, "idle")));
    }
}

public sealed class PortRulesTests
{
    static PortClash C(string target, int port, string owner, PortClash.Kinds kind, int pid = 42) =>
        new(target, port, owner, kind, pid, PortClash.Moves.Explicit);

    [Fact]
    public void PortBadges()
    {
        Assert.Equal("free", PortRules.Badge(new PortRow("p", "web", 5173, "free", "", 0, "")).Text);
        Assert.Equal(Tone.Green, PortRules.Badge(new PortRow("p", "web", 5173, "ours", "p", 1, "node")).Tone);
        Assert.Equal("other, outside", PortRules.Badge(new PortRow("p", "web", 5173, "outside", "other", 1, "node")).Text);
        Assert.Equal("in use", PortRules.Badge(new PortRow("p", "web", 5173, "outside", "", 1, "node")).Text);
    }

    [Fact]
    public void ConflictWording()
    {
        var ours = new PortConflict([C("web", 5173, "shop", PortClash.Kinds.Ours)], 1);
        Assert.Equal("Runbranch is running shop on them.", PortRules.Subtitle(ours));
        Assert.Equal("shop — a Runbranch run", PortRules.Describe(ours.Clashes[0]));
        Assert.Equal(5174, PortRules.ShiftedFirstPort(ours));

        var outside = new PortConflict([C("web", 5173, "a", PortClash.Kinds.Outside), C("api", 8080, "b", PortClash.Kinds.Outside)], 10);
        Assert.Equal("a and b is already running, started by something other than Runbranch.", PortRules.Subtitle(outside));
        Assert.Equal("Take over ports", PortRules.TakeOverLabel(outside));
        Assert.Equal(5183, PortRules.ShiftedFirstPort(outside));

        var mixed = new PortConflict([C("web", 1, "a", PortClash.Kinds.Ours), C("api", 2, "b", PortClash.Kinds.Outside)], 1);
        Assert.Equal("Some are ours, some are not.", PortRules.Subtitle(mixed));

        var stranger = new PortConflict([C("web", 1, "", PortClash.Kinds.Unknown, 999)], 1);
        Assert.Equal("Something outside Runbranch is using them.", PortRules.Subtitle(stranger));
        Assert.Equal("another app (pid 999)", PortRules.Describe(stranger.Clashes[0]));
    }

    [Fact]
    public void MoveWording()
    {
        Assert.Equal("One port is claimed by more than one project", PortRules.OverlapHeading(1));
        Assert.Equal("3 ports are claimed by more than one project", PortRules.OverlapHeading(3));
        Assert.Contains("does not need moving", PortRules.NotMoved("shop", 0));
        Assert.Contains("within 200 ports", PortRules.NotMoved("shop", null));
    }
}

public sealed class EditorRulesTests
{
    [Fact]
    public void OffsetNoteHasThreeForms()
    {
        Assert.Equal("Shifts every port this project declares, and rewrites {port} in its commands.",
            EditorRules.OffsetNote("", "3"));
        Assert.Equal("Declared: 4173, 5173. A shift moves all of them together.",
            EditorRules.OffsetNote("web:4173:/:pnpm dev\nadmin:5173::pnpm admin", ""));
        Assert.Equal("Runs on 4173 → 4174, 5173 → 5174. {port} in a command is rewritten to match.",
            EditorRules.OffsetNote("web:4173:/:pnpm dev\r\nadmin: 5173 ::x", " 1 "));
    }

    [Fact]
    public void ANonNumberOffsetReadsAsZeroAndBadTargetLinesAreSkipped() =>
        Assert.Equal("Declared: 3000. A shift moves all of them together.",
            EditorRules.OffsetNote("junk\nweb:3000\nweb:x:y", "abc"));

    [Fact]
    public void DirtyKeysAreSortedAndIncludeNewOnes()
    {
        var original = new Dictionary<string, string> { ["NAME"] = "a", ["SEED"] = "s", ["TARGETS"] = "t" };
        var now = new Dictionary<string, string> { ["NAME"] = "b", ["SEED"] = "s", ["TARGETS"] = "u", ["ALWAYS"] = "" };
        Assert.Equal(["ALWAYS", "NAME", "TARGETS"], EditorRules.DirtyKeys(now, original));
    }

    [Fact]
    public void FirstLineOfAFailure() =>
        Assert.Equal("TARGETS: bad line 2", EditorRules.FirstLine("\n  TARGETS: bad line 2\r\nFix:\n  runbranch doctor\n"));
}

public sealed class LogRulesTests
{
    [Theory]
    [InlineData("Error: boom", true)]
    [InlineData("0 errors", true)]
    [InlineData("panic: nil map", true)]
    [InlineData("listen EADDRINUSE :::5173", true)]
    [InlineData("ready in 312 ms", false)]
    public void ErrorWords(string line, bool error) => Assert.Equal(error, LogRules.LooksLikeError(line));

    [Fact]
    public void FilterIsCaseInsensitive()
    {
        Assert.True(LogRules.Matches("GET /API/users", "api"));
        Assert.True(LogRules.Matches("anything", ""));
        Assert.False(LogRules.Matches("GET /", "post"));
    }

    [Fact]
    public void Counts()
    {
        Assert.Equal("12 lines", LogRules.LineCount(12));
        Assert.Equal("", LogRules.ErrorCount(0));
        Assert.Equal("· 2 matching error", LogRules.ErrorCount(2));
    }

    [Fact]
    public void ScanWords()
    {
        Assert.Equal("Added 1 project", ScanRules.Added(1));
        Assert.Equal("Added 2 projects", ScanRules.Added(2));
        Assert.Equal("shop", ScanRules.Id(new AddedProject("Shop", @"C:\x\projects\shop.conf")));
    }
}

public sealed class LogTailTests : IDisposable
{
    readonly string file = Path.Combine(Path.GetTempPath(), "rb-log-" + Guid.NewGuid().ToString("N") + ".log");

    public void Dispose()
    {
        if (File.Exists(file)) File.Delete(file);
    }

    void Append(string s) => File.AppendAllText(file, s, new UTF8Encoding(false));

    [Fact]
    public void AMissingFileIsNothing() => Assert.Empty(new LogTail().Read(file).Lines);

    [Fact]
    public void OnlyCompleteLinesAreCommitted()
    {
        var tail = new LogTail();
        Append("one\ntw");
        Assert.Equal(["one"], tail.Read(file).Lines);
        Append("o\nthree");
        Assert.Equal(["two"], tail.Read(file).Lines);
        Append("\n");
        Assert.Equal(["three"], tail.Read(file).Lines);
        Assert.Empty(tail.Read(file).Lines);
    }

    [Fact]
    public void AnsiAndEmptyLinesAndCarriageReturnsAreDropped()
    {
        Append("\u001b[32mready\u001b[0m\r\n\n\nnext\n");
        Assert.Equal(["ready", "next"], new LogTail().Read(file).Lines);
    }

    [Fact]
    public void AShorterFileIsANewLog()
    {
        var tail = new LogTail();
        Append("a long first run\nand more\n");
        tail.Read(file);
        File.WriteAllText(file, "restart\n");
        var chunk = tail.Read(file);
        Assert.True(chunk.Reset);
        Assert.Equal(["restart"], chunk.Lines);
    }

    [Fact]
    public void ABigLogStartsAtTheCapAndDropsThePartialFirstLine()
    {
        var line = new string('x', 99) + "\n";
        var sb = new StringBuilder();
        for (var i = 0; i < 5000; i++) sb.Append(i).Append(':').Append(line);
        File.WriteAllText(file, sb.ToString());
        var tail = new LogTail();
        var lines = tail.Read(file).Lines;
        Assert.True(lines.Count < 2700);
        Assert.StartsWith("4999:", lines[^1]);
        Assert.All(lines, l => Assert.Matches("^[0-9]+:x{99}$", l));
        Assert.Equal(new FileInfo(file).Length, tail.Offset);
    }

    [Fact]
    public void AnEmDashSplitAcrossTicksIsNotLost()
    {
        var tail = new LogTail();
        var bytes = Encoding.UTF8.GetBytes("a — b\n");
        using (var f = new FileStream(file, FileMode.Create)) f.Write(bytes, 0, 3);
        Assert.Empty(tail.Read(file).Lines);
        using (var f = new FileStream(file, FileMode.Append)) f.Write(bytes, 3, bytes.Length - 3);
        Assert.Equal(["a — b"], tail.Read(file).Lines);
    }

    [Fact]
    public void ReadingDoesNotStopTheServerWritingOrTheEngineTruncating()
    {
        using var writer = new FileStream(file, FileMode.Create, FileAccess.Write, FileShare.ReadWrite | FileShare.Delete);
        writer.Write("held\n"u8);
        writer.Flush();
        Assert.Equal(["held"], new LogTail().Read(file).Lines);
    }
}
