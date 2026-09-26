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

public sealed class WhatsNewTests
{
    static AppVersion V(string s) => AppVersion.Parse(s)!;

    static readonly ReleaseNote[] Bundled =
    [
        new("1.5.1", "fix"),
        new("1.5.0", "projects"),
        new("1.4.0", "branches"),
        new("1.3.0", "updates"),
    ];

    [Fact]
    public void AFreshInstallRecordsWhereItStartsAndShowsNothing()
    {
        var d = WhatsNew.Decide("", V("1.5.1"), Bundled);
        Assert.Equal("1.5.1", d.Record);
        Assert.Empty(d.Show);
    }

    [Fact]
    public void AnUnreadableStoredVersionIsTreatedAsFresh()
    {
        var d = WhatsNew.Decide("garbage", V("1.5.1"), Bundled);
        Assert.Equal("1.5.1", d.Record);
        Assert.Empty(d.Show);
    }

    [Fact]
    public void SkippedReleasesAreAllShownNewestFirst()
    {
        var d = WhatsNew.Decide("1.3.0", V("1.5.1"), Bundled);
        Assert.Equal("1.5.1", d.Record);
        Assert.Equal(["1.5.1", "1.5.0", "1.4.0"], d.Show.Select(e => e.Version));
    }

    [Fact]
    public void NothingNewerThanInstalledIsShown()
    {
        var d = WhatsNew.Decide("1.4.0", V("1.5.0"), Bundled);
        Assert.Equal(["1.5.0"], d.Show.Select(e => e.Version));
    }

    [Fact]
    public void TheSameVersionLeavesTheMarkAlone()
    {
        var d = WhatsNew.Decide("1.5.1", V("1.5.1"), Bundled);
        Assert.Null(d.Record);
        Assert.Empty(d.Show);
    }

    [Fact]
    public void ADowngradeMovesTheMarkAndShowsNothing()
    {
        var d = WhatsNew.Decide("1.6.0", V("1.5.1"), Bundled);
        Assert.Equal("1.5.1", d.Record);
        Assert.Empty(d.Show);
    }

    [Fact]
    public void TheBundledFileParsesAndBadFilesAreEmpty()
    {
        var parsed = ReleaseNotes.Parse("""[{"version":"1.5.1","notes":"**Fixed**\n\n- a"},{"notes":"no version"}]""");
        Assert.Single(parsed);
        Assert.Equal("**Fixed**\n\n- a", parsed[0].Notes);
        Assert.Empty(ReleaseNotes.Parse("{not json"));
        Assert.Empty(ReleaseNotes.Parse("""{"version":"1"}"""));
        Assert.Empty(ReleaseNotes.Load(Path.Combine(Path.GetTempPath(), Guid.NewGuid() + ".json")));
    }
}

public sealed class NotesParserTests
{
    static List<(NoteKind, string)> P(string s) => Notes.Parse(s).Select(l => (l.Kind, l.Text)).ToList();

    [Fact]
    public void ParagraphsAreRewrappedAndGapsCollapse()
    {
        Assert.Equal(
            [(NoteKind.Body, "One two three."), (NoteKind.Gap, ""), (NoteKind.Body, "Four.")],
            P("One two\nthree.\n\n\n\nFour.\n\n"));
    }

    [Fact]
    public void NoGapLeadsOrTrails() => Assert.Equal([(NoteKind.Body, "x")], P("\n\nx\n\n"));

    [Fact]
    public void AWholeLineInBoldIsAHeadingButOneWithMoreIsNot()
    {
        Assert.Equal([(NoteKind.Heading, "Fixed")], P("**Fixed**"));
        Assert.Equal([(NoteKind.Body, "**a** and **b**")], P("**a** and **b**"));
        Assert.Equal([(NoteKind.Body, "****")], P("****"));
    }

    [Fact]
    public void HashHeadingsAndBothBulletMarks()
    {
        Assert.Equal(
            [(NoteKind.Heading, "1.4.0"), (NoteKind.Bullet, "one"), (NoteKind.Bullet, "two")],
            P("## 1.4.0\n- one\n* two"));
    }

    [Fact]
    public void AnIndentedLineContinuesTheBullet()
    {
        Assert.Equal(
            [(NoteKind.Bullet, "one long bullet"), (NoteKind.Bullet, "two")],
            P("- one long\n  bullet\n- two"));
    }

    [Fact]
    public void AnUnindentedLineAfterABulletIsAParagraph() =>
        Assert.Equal([(NoteKind.Bullet, "one"), (NoteKind.Body, "then prose")], P("- one\nthen prose"));

    [Fact]
    public void AlertMarkersAreDroppedAndTheirProseKept()
    {
        Assert.Equal(
            [(NoteKind.Body, "Copy your projects out first.")],
            P("> [!WARNING]\n> Copy your projects\n> out first."));
    }

    [Fact]
    public void CrlfIsOneBreak() => Assert.Equal([(NoteKind.Body, "a b")], P("a\r\nb"));

    [Fact]
    public void InlineMarks()
    {
        var spans = Notes.Inline("Use `runbranch doctor`, **not** *this* — see [the docs](docs/X.md).");
        Assert.Equal(
        [
            new NoteSpan("Use "), new NoteSpan("runbranch doctor", Code: true), new NoteSpan(", "),
            new NoteSpan("not", Bold: true), new NoteSpan(" "), new NoteSpan("this", Italic: true),
            new NoteSpan(" — see "), new NoteSpan("the docs"), new NoteSpan("."),
        ], spans);
    }

    [Fact]
    public void UnclosedMarksAreLiteral() =>
        Assert.Equal([new NoteSpan("2 * 3 and **open and `tick")], Notes.Inline("2 * 3 and **open and `tick"));

    [Fact]
    public void TheRealChangelogParsesWithNoRawMarkupInHeadings()
    {
        var changelog = Path.Combine(AppContext.BaseDirectory, "..", "..", "..", "..", "..", "CHANGELOG.md");
        if (!File.Exists(changelog)) return;
        var lines = Notes.Parse(File.ReadAllText(changelog));
        Assert.NotEmpty(lines);
        Assert.DoesNotContain(lines, l => l.Kind == NoteKind.Heading && l.Text.StartsWith("**", StringComparison.Ordinal));
        Assert.DoesNotContain(lines, l => l.Kind == NoteKind.Bullet && l.Text.StartsWith("- ", StringComparison.Ordinal));
    }
}
