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

// The engine's lines, as docs/specs/windows-port-engine-contract.md pins them
// and tests/engine.sh produces them, through the app's parsers. Each case is
// a rule the Mac's Model.swift already follows; these keep the port honest.

using System.Text;
using Xunit;

namespace Runbranch.Tests;

public class ProjectParsing
{
    [Fact]
    public void AllSixFields()
    {
        var p = Project.Parse("fixture\tFixture\t/tmp/fixture\t0\tcube\t1")!;
        Assert.Equal("fixture", p.Id);
        Assert.Equal("Fixture", p.Name);
        Assert.Equal("/tmp/fixture", p.Repo);
        Assert.Equal("cube", p.Symbol);
        Assert.True(p.Favourite);
    }

    [Fact]
    public void AnOlderEngineWithThreeFieldsStillParses()
    {
        var p = Project.Parse("a\tA\t/r")!;
        Assert.Equal(Project.DefaultSymbol, p.Symbol);
        Assert.False(p.Favourite);
    }

    [Fact]
    public void AnEmptySymbolIsThePackage() =>
        Assert.Equal("shippingbox", Project.Parse("a\tA\t/r\t1\t\t0")!.Symbol);

    [Fact]
    public void TooFewFieldsIsNoProject() => Assert.Null(Project.Parse("a\tA"));

    [Fact]
    public void EmptyLinesAreSkipped() =>
        Assert.Equal(2, Project.ParseAll("a\tA\t/r\n\nb\tB\t/s\n").Count);
}

public class BranchParsing
{
    // Fifteen fields, as tests/engine.sh asserts (NF == 15).
    const string Full = "feature/one\t2h\t1790000000\tme\t1\tOPEN\t1\t0\t0\t42\tAdd the thing\t0\t\t3\t4";

    [Fact]
    public void AllFifteenFields()
    {
        var b = Branch.Parse(Full)!;
        Assert.Equal("feature/one", b.Ref);
        Assert.Equal("2h", b.Age);
        Assert.Equal(1790000000, b.Timestamp);
        Assert.Equal("me", b.Owner);
        Assert.True(b.Mine);
        Assert.Equal(PRState.Open, b.PR);
        Assert.True(b.Ready);
        Assert.False(b.IsDefault);
        Assert.False(b.IsCurrent);
        Assert.Equal("42", b.PRNumber);
        Assert.Equal("Add the thing", b.Subject);
        Assert.False(b.IsRemote);
        Assert.Equal("", b.CheckedOutAt);
        Assert.Equal(3, b.Ahead);
        Assert.Equal(4, b.Behind);
        Assert.True(b.HasDivergence);
        Assert.False(b.IsSubsumed);
    }

    [Fact]
    public void NineFieldsIsEnough()
    {
        var b = Branch.Parse("main\t1d\t100\tme\t1\tNONE\t0\t1\t1")!;
        Assert.True(b.IsDefault);
        Assert.True(b.IsCurrent);
        Assert.Equal("", b.Subject);
        Assert.Null(b.Ahead);
        Assert.Null(b.Behind);
    }

    [Fact]
    public void EightFieldsIsNot() => Assert.Null(Branch.Parse("main\t1d\t100\tme\t1\tNONE\t0\t1"));

    [Fact]
    public void AnEmptyAheadIsNoAnswerNotZero()
    {
        // git < 2.41 prints nothing for ahead/behind. Zero would mean
        // "subsumed, safe to delete", which is the one wrong answer to give.
        var b = Branch.Parse("old\t1d\t100\tPriya\t0\tNONE\t0\t0\t0\t\tsubject\t0\t\t\t")!;
        Assert.Null(b.Ahead);
        Assert.Null(b.Behind);
        Assert.False(b.IsSubsumed);
        Assert.False(b.HasDivergence);
    }

    [Fact]
    public void ZeroAheadIsSubsumedUnlessItIsTheTrunk()
    {
        Assert.True(Branch.Parse("done\t1d\t100\tme\t1\tNONE\t0\t0\t0\t\ts\t0\t\t0\t5")!.IsSubsumed);
        Assert.False(Branch.Parse("main\t1d\t100\tme\t1\tNONE\t0\t1\t0\t\ts\t0\t\t0\t0")!.IsSubsumed);
    }

    [Fact]
    public void RemoteBranchesDisplayWithoutOrigin()
    {
        var b = Branch.Parse("origin/review/x\t3d\t100\tSam\t0\tOPEN\t0\t0\t0\t7\tReview me\t1\t\t1\t0")!;
        Assert.True(b.IsRemote);
        Assert.Equal("review/x", b.Display);
        Assert.False(b.CanRunInPlace);
    }

    [Fact]
    public void OnlyTheThreeKnownPRStatesAreRecognised()
    {
        Assert.Equal(PRState.Merged, PRStates.Parse("MERGED"));
        Assert.Equal(PRState.Closed, PRStates.Parse("CLOSED"));
        Assert.Equal(PRState.None, PRStates.Parse("NONE"));
        Assert.Equal(PRState.None, PRStates.Parse("open"));
    }

    [Fact]
    public void ACrStuckToTheLastFieldIsDropped() =>
        Assert.Equal(4, Branch.ParseAll(Full + "\r\n").Single().Behind);
}

public class StateParsing
{
    [Fact]
    public void IdleIsIdle()
    {
        var s = RunState.Parse("idle\n");
        Assert.False(s.Running);
        Assert.Empty(s.Targets);
    }

    [Fact]
    public void ARunWithTargets()
    {
        var s = RunState.Parse(
            "run\tfeature/one\tweb\t2026-09-24 10:00:00\t1790000000\t/w/feature-one\t0\n" +
            "behind\t2\n" +
            "target\tweb\t4321\t/\t12345\t1\n" +
            "target\tapi\t4322\t/health\t0\t0\n");
        Assert.True(s.Running);
        Assert.Equal("feature/one", s.Ref);
        Assert.Equal("web", s.Preset);
        Assert.Equal("2026-09-24 10:00:00", s.Started);
        Assert.Equal(1790000000, s.Epoch);
        Assert.Equal("/w/feature-one", s.Worktree);
        Assert.False(s.InPlace);
        Assert.False(s.Adopted);
        Assert.Equal(2, s.Behind);
        Assert.Equal(2, s.Targets.Count);
        Assert.Equal(new RunTarget("web", 4321, "/", 12345, true), s.Targets[0]);
        Assert.Equal("http://localhost:4322/health", s.Targets[1].HealthUrl.ToString());
        Assert.Equal("http://localhost:4321/", s.Targets[0].HealthUrl.ToString());
    }

    [Fact]
    public void AnAdoptedRunHasAnEmptyPresetAndNoBehindLine()
    {
        var s = RunState.Parse("run\tmain\t\tThu Sep 24 10:00:00 2026\t0\t/repo\t1\t1\ntarget\tweb\t4993\t/\t999\t1\n");
        Assert.True(s.Adopted);
        Assert.True(s.InPlace);
        Assert.Equal("", s.Preset);
        Assert.Equal(0, s.Behind);
        Assert.Equal(0, s.Epoch);
    }

    [Fact]
    public void SwitchedAndUnknownLines()
    {
        var s = RunState.Parse("run\tmain\tweb\tx\t1\t/r\t1\nswitched\tother\nfuture\tsomething\ntarget\tweb\t1\t/\t1\t1\n");
        Assert.Equal("other", s.SwitchedTo);
        Assert.Single(s.Targets);
    }

    [Fact]
    public void ShortLinesAreIgnored()
    {
        var s = RunState.Parse("run\tmain\tweb\ntarget\tweb\t1\n");
        Assert.False(s.Running);
        Assert.Empty(s.Targets);
    }
}

public class PathsParsing
{
    [Fact]
    public void FiveFieldsWithoutARef()
    {
        var p = ProjectPaths.Parse("/h/fx/worktrees\t/h/fx/logs\t/p/fx.conf\t/repo\towner/repo\n");
        Assert.Equal("/h/fx/logs", p.Logs);
        Assert.Equal("/p/fx.conf", p.Config);
        Assert.Equal("owner/repo", p.GitHubSlug);
        Assert.Null(p.Worktree);
        Assert.Equal("https://github.com/owner/repo/pull/42", p.PullRequestUrl("42")!.ToString());
    }

    [Fact]
    public void SixWithOne()
    {
        var p = ProjectPaths.Parse("w\tl\tc\tr\t\tw/feature-one\n");
        Assert.Equal("w/feature-one", p.Worktree);
        Assert.Null(p.PullRequestUrl("1"));
    }

    [Fact]
    public void NothingIsEmpty() => Assert.Equal("", ProjectPaths.Parse("").Config);
}

public class PortParsing
{
    [Fact]
    public void ACheckPortsConflict()
    {
        var c = PortConflict.Parse(
            "web\t4321\tholder\tours\t111\texplicit\n" +
            "api\t4322\tholder\tours\t112\tenv\n" +
            "db\t5432\tother\toutside\t113\tenv\n" +
            "x\t9000\t\tunknown\t114\tenv\n" +
            "OFFSET\t3\n")!;
        Assert.Equal(4, c.Clashes.Count);
        Assert.Equal(3, c.FreeOffset);
        Assert.Equal(["holder"], c.Owners);
        Assert.Equal(["other"], c.Outsiders);
        Assert.Single(c.Strangers);
        Assert.True(c.CanShift);
        Assert.True(c.ShiftIsBestEffort);
        Assert.Equal(PortClash.Moves.Explicit, c.Clashes[0].Move);
    }

    [Fact]
    public void NoClashesIsNoConflict() => Assert.Null(PortConflict.Parse("OFFSET\t1\n"));

    [Fact]
    public void UnknownKindsAndMovesDegradeSafely()
    {
        var c = PortConflict.Parse("web\t1\to\tweird\t2\tsideways\n")!;
        Assert.Equal(PortClash.Kinds.Unknown, c.Clashes[0].Kind);
        Assert.Equal(PortClash.Moves.Env, c.Clashes[0].Move);
        Assert.Equal(1, c.FreeOffset);
    }

    [Fact]
    public void AClashWithoutANumericPidIsSkipped() => Assert.Null(PortConflict.Parse("web\t4321\to\tours\tx\tenv\n"));

    [Fact]
    public void PortsRows()
    {
        var rows = PortRow.Parse(
            "fixture\tweb\t4321\tfree\t\t\t\t\n" +
            "fixture\tapi\t4322\tours\tfixture\tours\t555\t555 python -m http.server\n");
        Assert.Equal(2, rows.Count);
        Assert.True(rows[0].IsFree);
        Assert.Equal(0, rows[0].Pid);
        Assert.True(rows[1].IsOurs);
        Assert.Equal(555, rows[1].Pid);
        Assert.Equal("555 python -m http.server", rows[1].What);
    }

    [Fact]
    public void OverlapsKeepOnlyRealOverlaps()
    {
        var o = PortOverlap.Parse("4321\ttwinA twinB\n5000\tsolo\nx\ta b\n");
        Assert.Single(o);
        Assert.Equal(4321, o[0].Port);
        Assert.Equal(["twinA", "twinB"], o[0].Projects);
    }

    [Theory]
    [InlineData("3\n", 0, 3)]
    [InlineData("0\n", 0, 0)]
    [InlineData("0\n", 1, null)]
    [InlineData("", 0, null)]
    public void SuggestedOffset(string output, int code, int? expected) =>
        Assert.Equal(expected, Wire.ParseOffset(output, code));
}

public class DiskParsing
{
    [Fact]
    public void Rows()
    {
        var rows = DiskRow.Parse("fx\tfeature-one\tfeature/one\t49\trunning\nfx\told\t?\t0\tgone\nfx\tx\tx\tbad\tidle\nshort\trow\n");
        Assert.Equal(3, rows.Count);
        Assert.True(rows[0].IsRunning);
        Assert.True(rows[1].IsGone);
        Assert.Equal(0, rows[2].Kb);
        Assert.Equal("fx/feature-one", rows[0].Id);
    }

    [Theory]
    [InlineData(0, "0 KB")]
    [InlineData(1, "1 KB")]
    [InlineData(49, "50 KB")]
    [InlineData(976, "999 KB")]
    [InlineData(977, "1 MB")]
    [InlineData(1024, "1 MB")]
    [InlineData(1536, "1.6 MB")]
    [InlineData(1024 * 1024, "1.07 GB")]
    [InlineData(10L * 1024 * 1024, "10.74 GB")]
    public void SizesReadLikeTheMac(long kb, string expected) => Assert.Equal(expected, Bytes.FromKb(kb));
}

public class WireFormats
{
    [Fact]
    public void GetRejoinsTabsAndRestoresNewlines()
    {
        var g = Wire.ParseGet("NAME\tFixture\nINSTALL\tpnpm\tinstall\nIN_REPO\t\nTARGETS\tweb:1:/:a\u0001api:2:/:b\n");
        Assert.Equal("Fixture", g["NAME"]);
        Assert.Equal("pnpm\tinstall", g["INSTALL"]);
        Assert.Equal("", g["IN_REPO"]);
        Assert.Equal("web:1:/:a\napi:2:/:b", g["TARGETS"]);
    }

    [Fact]
    public void SetEncodesNewlines() => Assert.Equal("a\u0001b\u0001c", Wire.EncodeValue("a\r\nb\nc"));

    [Fact]
    public void FailureKeepsTheFixBlock()
    {
        var stderr = "\n FAILED  No project called \"nope\".\n\nFix:\n\n    ls ~/.runbranch/projects\n\n";
        Assert.Equal("No project called \"nope\".\n\nFix:\n\n    ls ~/.runbranch/projects", Wire.TidyFailure(stderr, "favourite"));
    }

    [Fact]
    public void AnEmptyFailureSaysSo()
    {
        Assert.Equal("prune-gone failed, with nothing to say why.", Wire.TidyFailure("  FAILED \n", "prune-gone"));
        Assert.Equal("The engine failed, with nothing to say why.", Wire.TidyFailure("", null));
    }

    [Fact]
    public void ScanNeedsANameAndAPath()
    {
        var s = ScanResult.Parse("api\tC:\\dev\\api\n\tC:\\nameless\nsolo\n");
        Assert.Single(s);
        Assert.Equal("C:\\dev\\api", s[0].Path);
    }

    [Fact]
    public void AddTakesTheFirstLine()
    {
        Assert.Equal(new AddedProject("api", "C:\\p\\api.conf"), AddedProject.Parse("api\tC:\\p\\api.conf\nignored\tline\n"));
        Assert.Null(AddedProject.Parse("just-a-name\n"));
    }

    [Fact]
    public void PresetsAreTheNonEmptyLines() => Assert.Equal(["web", "api", "all"], Wire.ParseLines("web\napi\n\nall\n"));
}

public class Streaming
{
    static List<string> FeedInPieces(byte[] bytes, int piece)
    {
        var a = new LineAssembler();
        var lines = new List<string>();
        for (var i = 0; i < bytes.Length; i += piece)
            lines.AddRange(a.Feed(bytes.AsSpan(i, Math.Min(piece, bytes.Length - i))));
        lines.AddRange(a.Finish());
        return lines;
    }

    [Fact]
    public void AMultibyteCharacterSplitAcrossReadsSurvives()
    {
        // "—" is three bytes; every one-byte read splits it. The Mac dropped
        // any read that did not decode on its own, losing the whole chunk.
        var text = "Fixture — feature/one (web)\n    ok   web → ready\n";
        foreach (var size in new[] { 1, 2, 3, 5, 64 })
            Assert.Equal(["Fixture — feature/one (web)", "    ok   web → ready"], FeedInPieces(Encoding.UTF8.GetBytes(text), size));
    }

    [Fact]
    public void ALineSplitAcrossReadsIsOneLine() =>
        Assert.Equal(["==> Worktree  /w"], FeedInPieces(Encoding.UTF8.GetBytes("==> Worktree  /w\n"), 4));

    [Fact]
    public void ColourIsStrippedEvenWhenTheEscapeIsSplit() =>
        Assert.Equal(["==> Servers", "FAILED web never answered"],
            FeedInPieces(Encoding.UTF8.GetBytes("\u001b[34m==>\u001b[0m \u001b[1mServers\u001b[0m\n\u001b[1;31mFAILED\u001b[0m web never answered\n"), 3));

    [Fact]
    public void BlankLinesAndCrsAreDroppedAndTheLastLineNeedsNoNewline() =>
        Assert.Equal(["one", "two", "three"], FeedInPieces(Encoding.UTF8.GetBytes("\none\r\n\n\ntwo\nthree"), 7));
}

public class Filtering
{
    const long Now = 2_000_000_000;

    static Branch B(string @ref, long age = 0, bool mine = true, PRState pr = PRState.None, bool isDefault = false,
        bool remote = false, int? ahead = 1, string subject = "") => new()
    {
        Ref = @ref, Age = "", Timestamp = Now - age, Owner = "me", Mine = mine, PR = pr, IsDefault = isDefault,
        IsRemote = remote, Ahead = ahead, Subject = subject,
    };

    static readonly RunState Idle = RunState.Idle;

    [Fact]
    public void DefaultsHideMergedOldAndMostRemotes()
    {
        var branches = new[]
        {
            B("main", age: 90 * 86400, isDefault: true),
            B("fresh"),
            B("merged", pr: PRState.Merged),
            B("subsumed", ahead: 0),
            B("unknown-ahead", ahead: null),
            B("old", age: BranchFilter.Week + 1),
            B("origin/review", remote: true, pr: PRState.Open),
            B("origin/random", remote: true),
        };
        var shown = new BranchFilter().Visible(branches, Idle, Now).Select(b => b.Ref);
        Assert.Equal(["main", "fresh", "unknown-ahead", "origin/review"], shown);
    }

    [Fact]
    public void TheRunningBranchIsAlwaysShown()
    {
        var running = RunState.Idle with { Running = true, Ref = "old" };
        Assert.Single(new BranchFilter().Visible([B("old", age: 100 * 86400, pr: PRState.Merged)], running, Now));
    }

    [Fact]
    public void SearchOverridesEveryFilter()
    {
        var f = new BranchFilter { Query = "  CHECKOUT ", MineOnly = true };
        var shown = f.Visible([B("feat/checkout", age: 99 * 86400, mine: false, pr: PRState.Merged), B("other", subject: "Checkout summary"), B("nope")], Idle, Now);
        Assert.Equal(["feat/checkout", "other"], shown.Select(b => b.Ref));
    }

    [Fact]
    public void MineOnlyAndTheToggles()
    {
        var f = new BranchFilter { MineOnly = true };
        Assert.Empty(f.Visible([B("theirs", mine: false)], Idle, Now));
        Assert.True(f.IsActive);
        Assert.False(new BranchFilter { Query = "x" }.IsActive);
        var all = new BranchFilter { ShowMerged = true, ShowOlder = true, ShowAllRemote = true };
        Assert.Equal(3, all.Visible([B("m", pr: PRState.Merged), B("o", age: BranchFilter.Week * 2), B("origin/r", remote: true)], Idle, Now).Count);
    }
}

public class HealthRulesTests
{
    [Fact]
    public void Responses()
    {
        Assert.Equal(Health.Healthy, HealthRules.OnResponse(200));
        Assert.Equal(Health.Healthy, HealthRules.OnResponse(404));
        Assert.Equal(Health.Failing, HealthRules.OnResponse(500));
    }

    [Fact]
    public void SilenceIsStartingUntilItHadAnswered()
    {
        Assert.Equal(Health.Starting, HealthRules.OnNoResponse(Health.Unknown));
        Assert.Equal(Health.Starting, HealthRules.OnNoResponse(Health.Starting));
        Assert.Equal(Health.Failing, HealthRules.OnNoResponse(Health.Healthy));
    }

    [Fact]
    public void WorstOf()
    {
        Assert.Equal(Health.Starting, HealthRules.Worst([]));
        Assert.Equal(Health.Failing, HealthRules.Worst([Health.Healthy, Health.Failing, Health.Starting]));
        Assert.Equal(Health.Starting, HealthRules.Worst([Health.Healthy, Health.Starting]));
        Assert.Equal(Health.Starting, HealthRules.Worst([Health.Healthy, Health.Unknown]));
        Assert.Equal(Health.Healthy, HealthRules.Worst([Health.Healthy, Health.Healthy]));
        Assert.Equal("Not responding", Health.Failing.Title());
    }
}

public class Paths
{
    [Theory]
    [InlineData(@"C:\Users\alec\code\x", @"~\code\x")]
    [InlineData(@"c:\users\ALEC\code", @"~\code")]
    [InlineData(@"C:\Users\alec", "~")]
    [InlineData(@"C:\Users\alecx\code", @"C:\Users\alecx\code")]
    [InlineData("repo at C:\\Users\\alec\\r and C:\\Users\\alec\\s", "repo at ~\\r and ~\\s")]
    [InlineData(@"D:\elsewhere", @"D:\elsewhere")]
    public void HomeIsAbbreviated(string path, string expected) =>
        Assert.Equal(expected, path.AbbreviatingHome(@"C:\Users\alec"));
}
