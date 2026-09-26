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

// The things the engine reports, as values. No behaviour beyond decoding what
// the engine prints and describing it — a port of app/Model.swift, field for
// field, so the two apps cannot read the same line two ways.
//
// Deliberately free of WinUI: Runbranch.Tests compiles this file on its own,
// so every parser here is tested against the lines the contract pins
// (docs/specs/windows-port-engine-contract.md). Colours are named as tones
// (see Tone) and resolved to brushes in Themes/Tokens.xaml.

using System.Globalization;
using System.Text;
using System.Text.RegularExpressions;

namespace Runbranch;

/// <summary>
/// How the Swift side splits engine output, in one place.
///
/// `components(separatedBy: "\t")` keeps empty fields, and they count toward
/// the field total, which is what every `count >= n` guard below relies on.
/// Lines are split on LF only; a trailing CR is dropped, because the contract
/// says LF and a CR that slipped through (a child tool's output, an editor
/// that saved a .conf as CRLF) would otherwise stick to the last field and
/// make "1" read as not "1".
/// </summary>
public static class Tsv
{
    public static IEnumerable<string> Lines(string? text)
    {
        if (string.IsNullOrEmpty(text)) yield break;
        foreach (var raw in text.Split('\n'))
        {
            var line = raw.EndsWith('\r') ? raw[..^1] : raw;
            if (line.Length > 0) yield return line;
        }
    }

    public static string[] Fields(string line) => line.Split('\t');

    /// <summary>
    /// Swift's `Int(String)`: optional sign, digits, nothing else. Not
    /// int.TryParse's default, which also accepts surrounding whitespace and
    /// thousands separators in some cultures — and an empty ahead/behind field
    /// must stay "no answer", never become a number.
    /// </summary>
    public static int? Int(string? s) =>
        int.TryParse(s, NumberStyles.AllowLeadingSign, CultureInfo.InvariantCulture, out var n) ? n : null;

    public static double? Double(string? s) =>
        double.TryParse(s, NumberStyles.AllowLeadingSign | NumberStyles.AllowDecimalPoint | NumberStyles.AllowExponent,
            CultureInfo.InvariantCulture, out var d) ? d : null;
}

/// <summary>
/// Semantic colours, as names. Themes/Tokens.xaml has a brush for each
/// (`Rb{Tone}Brush`), with light and dark variants, taken from the Mac's
/// system colours so the badges mean the same thing on both.
/// </summary>
public enum Tone
{
    Secondary,
    /// <summary>The default branch, and anything measured against it (system blue).</summary>
    Trunk,
    Green,
    Orange,
    Red,
    Purple,
    /// <summary>GitHub's own pull request colours, so badges read the way the PR list does.</summary>
    PrOpen,
    PrMerged,
    PrClosed,
}

public enum PRState
{
    None,
    Open,
    Merged,
    Closed,
}

public static class PRStates
{
    public static PRState Parse(string raw) => raw switch
    {
        "OPEN" => PRState.Open,
        "MERGED" => PRState.Merged,
        "CLOSED" => PRState.Closed,
        _ => PRState.None,
    };

    public static string? Label(this PRState s) => s switch
    {
        PRState.Open => "open",
        PRState.Merged => "merged",
        PRState.Closed => "closed",
        _ => null,
    };

    public static Tone Tone(this PRState s) => s switch
    {
        PRState.Open => Runbranch.Tone.PrOpen,
        PRState.Merged => Runbranch.Tone.PrMerged,
        PRState.Closed => Runbranch.Tone.PrClosed,
        _ => Runbranch.Tone.Secondary,
    };

    /// <summary>SF Symbol name; Icons.Glyph maps it.</summary>
    public static string Symbol(this PRState s) => s switch
    {
        PRState.Open => "arrow.triangle.pull",
        PRState.Merged => "arrow.triangle.merge",
        PRState.Closed => "xmark",
        _ => "",
    };
}

public sealed record Branch
{
    public required string Ref { get; init; }
    public required string Age { get; init; }
    public long Timestamp { get; init; }
    public required string Owner { get; init; }
    public bool Mine { get; init; }
    public PRState PR { get; init; }
    public bool Ready { get; init; }
    public bool IsDefault { get; init; }
    public bool IsCurrent { get; init; }
    public string PRNumber { get; init; } = "";
    /// <summary>The pull request title, or the tip commit's subject when there is none.</summary>
    public string Subject { get; init; } = "";
    public bool IsRemote { get; init; }
    /// <summary>
    /// Where this branch is checked out, when that is a worktree someone made
    /// themselves. Empty otherwise. Git will not check one branch out twice, so
    /// this is also why an in-place run of it is not on offer.
    /// </summary>
    public string CheckedOutAt { get; init; } = "";

    /// <summary>
    /// Commits this branch has that the trunk does not, and vice versa —
    /// measured against `origin/&lt;default&gt;` where that exists.
    ///
    /// Nullable rather than defaulted to zero: a git too old for
    /// `%(ahead-behind:)` reports nothing, and "we did not ask" must not read
    /// as "level with the trunk", which is the one value that means the
    /// branch can be deleted.
    /// </summary>
    public int? Ahead { get; init; }
    public int? Behind { get; init; }

    /// <summary>
    /// Nothing on this branch that the trunk does not already have, so
    /// deleting it loses no work. True however it got there — a merge commit,
    /// a squash, a rebase, or never having diverged at all — which is the half
    /// the pull request cache cannot see.
    /// </summary>
    public bool IsSubsumed => !IsDefault && Ahead == 0;

    /// <summary>Worth drawing: level with the trunk in both directions says nothing.</summary>
    public bool HasDivergence => (Ahead ?? 0) > 0 || (Behind ?? 0) > 0;

    /// <summary>
    /// Runnable in place — in the real checkout, with whatever is in the
    /// working tree right now, rather than from a snapshot.
    /// </summary>
    public bool CanRunInPlace => IsCurrent && !IsRemote;

    public string Id => Ref;
    public string Display => IsRemote && Ref.StartsWith("origin/", StringComparison.Ordinal) ? Ref["origin/".Length..] : Ref;

    /// <summary>
    /// `ref age ts owner mine pr ready isDefault isCurrent`, tab separated.
    /// Everything from `prNumber` on is optional, so an older engine still
    /// parses.
    /// </summary>
    public static Branch? Parse(string line)
    {
        var f = Tsv.Fields(line);
        if (f.Length < 9) return null;
        return new Branch
        {
            Ref = f[0],
            Age = f[1],
            Timestamp = long.TryParse(f[2], NumberStyles.AllowLeadingSign, CultureInfo.InvariantCulture, out var ts) ? ts : 0,
            Owner = f[3],
            Mine = f[4] == "1",
            PR = PRStates.Parse(f[5]),
            Ready = f[6] == "1",
            IsDefault = f[7] == "1",
            IsCurrent = f[8] == "1",
            PRNumber = f.Length > 9 ? f[9] : "",
            Subject = f.Length > 10 ? f[10] : "",
            IsRemote = f.Length > 11 && f[11] == "1",
            CheckedOutAt = f.Length > 12 ? f[12] : "",
            Ahead = f.Length > 13 ? Tsv.Int(f[13]) : null,
            Behind = f.Length > 14 ? Tsv.Int(f[14]) : null,
        };
    }

    public static List<Branch> ParseAll(string text) =>
        Tsv.Lines(text).Select(Parse).OfType<Branch>().ToList();
}

/// <summary>
/// A project the engine knows about. Presets are whatever its config declares,
/// so nothing here is specific to any one repo.
/// </summary>
public sealed record Project
{
    /// <summary>The .conf basename.</summary>
    public required string Id { get; init; }
    /// <summary>Display name.</summary>
    public required string Name { get; init; }
    public required string Repo { get; init; }

    /// <summary>
    /// Sidebar glyph, named by the project's own config as an SF Symbol name.
    /// Configs are shared with Mac users, so the name is what is stored and
    /// Icons.Glyph maps it here (spec D9).
    /// </summary>
    public string Symbol { get; init; } = DefaultSymbol;
    public bool Favourite { get; init; }

    public const string DefaultSymbol = "shippingbox";

    public static Project? Parse(string line)
    {
        var f = Tsv.Fields(line);
        if (f.Length < 3) return null;
        return new Project
        {
            Id = f[0],
            Name = f[1],
            Repo = f[2],
            // f[3] is "the state file exists", not "is alive". Unused, as on the Mac.
            Symbol = f.Length >= 5 && f[4].Length > 0 ? f[4] : DefaultSymbol,
            Favourite = f.Length >= 6 && f[5] == "1",
        };
    }

    public static List<Project> ParseAll(string text) =>
        Tsv.Lines(text).Select(Parse).OfType<Project>().ToList();
}

/// <summary>One server inside a run.</summary>
public sealed record RunTarget(string Name, int Port, string Health, int Pid, bool Alive)
{
    public string Id => Name;
    public Uri Url => new($"http://localhost:{Port.ToString(CultureInfo.InvariantCulture)}");
    public Uri HealthUrl => new($"http://localhost:{Port.ToString(CultureInfo.InvariantCulture)}{(Health.Length == 0 ? "/" : Health)}");

    /// <summary>
    /// Swift's `URL(string:)` is optional, and HealthMonitor treats a target
    /// with no URL as failing. A health path that does not form a URL is the
    /// only way to get there, so this is the same test.
    /// </summary>
    public Uri? HealthUrlOrNull =>
        Uri.TryCreate($"http://localhost:{Port.ToString(CultureInfo.InvariantCulture)}{(Health.Length == 0 ? "/" : Health)}",
            UriKind.Absolute, out var u) ? u : null;
}

/// <summary>What the engine says is running for one project.</summary>
public sealed record RunState
{
    public bool Running { get; init; }
    public string Ref { get; init; } = "";
    public string Preset { get; init; } = "";
    public string Started { get; init; } = "";
    /// <summary>Unix seconds, from the engine. 0 when it did not say.</summary>
    public double Epoch { get; init; }
    public string Worktree { get; init; } = "";
    /// <summary>
    /// Running in the real checkout rather than a worktree, so what is served
    /// is whatever is on disk — uncommitted work included.
    /// </summary>
    public bool InPlace { get; init; }
    /// <summary>
    /// Runbranch did not start this — it found the project already up and is
    /// reporting it rather than pretending otherwise. Stopping it means ending
    /// a process someone else started, so it goes through kill-port.
    /// </summary>
    public bool Adopted { get; init; }
    /// <summary>
    /// Commits the ref has gained since this run's worktree was cut. A
    /// worktree is pinned to one commit, so a run cannot see anything pushed
    /// after it started. Always 0 in place, where the working tree is live.
    /// </summary>
    public int Behind { get; init; }
    /// <summary>
    /// The branch the checkout sits on now, when an in-place run is no longer
    /// on the one it was started for. Empty when it is where it should be.
    /// </summary>
    public string SwitchedTo { get; init; } = "";
    public IReadOnlyList<RunTarget> Targets { get; init; } = [];

    public static readonly RunState Idle = new();

    /// <summary>
    /// One `run` line then one `target` line each; `idle` on its own when not.
    /// Unknown lines are ignored, and that is the extension mechanism: new
    /// data goes on new line types.
    /// </summary>
    public static RunState Parse(string output)
    {
        var s = new RunState();
        var targets = new List<RunTarget>();
        foreach (var line in Tsv.Lines(output))
        {
            var f = Tsv.Fields(line);
            switch (f[0])
            {
                case "run" when f.Length >= 6:
                    s = s with
                    {
                        Running = true,
                        Ref = f[1],
                        Preset = f[2],
                        Started = f[3],
                        Epoch = Tsv.Double(f[4]) ?? 0,
                        Worktree = f[5],
                        InPlace = f.Length > 6 && f[6] == "1",
                        Adopted = f.Length > 7 && f[7] == "1",
                    };
                    break;
                case "behind" when f.Length >= 2:
                    s = s with { Behind = Tsv.Int(f[1]) ?? 0 };
                    break;
                case "switched" when f.Length >= 2:
                    s = s with { SwitchedTo = f[1] };
                    break;
                case "target" when f.Length >= 6:
                    targets.Add(new RunTarget(f[1], Tsv.Int(f[2]) ?? 0, f[3], Tsv.Int(f[4]) ?? 0, f[5] == "1"));
                    break;
            }
        }
        return s with { Targets = targets };
    }

    public IEnumerable<Uri> Urls => Targets.Select(t => t.Url);
}

/// <summary>
/// `paths &lt;project&gt; [ref]`, first line: worktrees, logs, config, repo,
/// GitHub slug, and the ref's worktree when one was asked for.
/// Named, because index 2 meaning "config file" is not something every caller
/// should have to remember. `Raw` keeps the Mac's array for anything else.
/// </summary>
public sealed record ProjectPaths(IReadOnlyList<string> Raw)
{
    string At(int i) => i < Raw.Count ? Raw[i] : "";

    public string Worktrees => At(0);
    public string Logs => At(1);
    public string Config => At(2);
    public string Repo => At(3);
    /// <summary>owner/repo, or empty when the remote is not on GitHub.</summary>
    public string GitHubSlug => At(4);
    /// <summary>The ref's worktree; null unless a ref was passed (count &gt;= 6).</summary>
    public string? Worktree => Raw.Count >= 6 ? Raw[5] : null;

    public static readonly ProjectPaths Empty = new([]);

    public static ProjectPaths Parse(string output) =>
        new(Tsv.Lines(output).FirstOrDefault() is { } first ? Tsv.Fields(first) : []);

    /// <summary>https://github.com/&lt;slug&gt;/pull/&lt;n&gt;, or null with no slug or number.</summary>
    public Uri? PullRequestUrl(string number) =>
        GitHubSlug.Length == 0 || number.Length == 0 ? null : new Uri($"https://github.com/{GitHubSlug}/pull/{number}");
}

/// <summary>A start that is waiting on the user to resolve a port conflict.</summary>
public sealed record PendingRun(string Project, string Ref, string Preset, string Title, bool InPlace, PortConflict Conflict)
{
    public string Id => Project + Ref + Preset;
}

/// <summary>
/// A port a run needs that something else is already listening on.
///
/// Parsed from `check-ports`, which is asked BEFORE starting so the user gets
/// a choice rather than a failure. `Owner` is the project whose run holds the
/// port, empty when it is something they started themselves.
/// </summary>
public sealed record PortClash(string Target, int Port, string Owner, PortClash.Kinds Kind, int Pid, PortClash.Moves Move)
{
    /// <summary>
    /// Whether the holder is a run of ours, the same project started by
    /// something else, or unattributable. It decides what can be offered:
    /// stopping our own run is routine, killing a server someone else started
    /// is not.
    /// </summary>
    public enum Kinds { Ours, Outside, Unknown }

    /// <summary>
    /// How the target can be told a different port: `Explicit` when its command
    /// names one itself ({port}), `Env` when the only route is PORT in the
    /// environment, which a lot of tooling honours and some ignores.
    /// </summary>
    public enum Moves { Explicit, Env }

    public string Id => Target;

    public static Kinds ParseKind(string raw) => raw switch
    {
        "ours" => Kinds.Ours,
        "outside" => Kinds.Outside,
        _ => Kinds.Unknown,
    };

    public static Moves ParseMove(string raw) => raw == "explicit" ? Moves.Explicit : Moves.Env;
}

public sealed record PortConflict(IReadOnlyList<PortClash> Clashes, int FreeOffset)
{
    /// <summary>
    /// Always offer to move. Every target gets PORT in its environment, so a
    /// shift has a real chance even when the config never anticipated one —
    /// and when the server ignores it, the run fails immediately and says
    /// exactly what to add. Refusing to try was the worse default.
    /// </summary>
    public bool CanShift => Clashes.Count > 0;

    /// <summary>
    /// True when at least one target can only be moved through PORT, so the
    /// offer is a good chance rather than a certainty.
    /// </summary>
    public bool ShiftIsBestEffort => Clashes.Any(c => c.Move == PortClash.Moves.Env);

    /// <summary>
    /// Projects whose own Runbranch run holds these ports — the ones we can
    /// stop as a matter of course.
    /// </summary>
    public IReadOnlyList<string> Owners => Names(PortClash.Kinds.Ours);

    /// <summary>
    /// Projects already running outside Runbranch on these ports. Stopping one
    /// means killing a server something else started, which is the user's call
    /// and not a routine one.
    /// </summary>
    public IReadOnlyList<string> Outsiders => Names(PortClash.Kinds.Outside);

    /// <summary>Processes we cannot attribute, and would not presume to kill.</summary>
    public IReadOnlyList<PortClash> Strangers => Clashes.Where(c => c.Kind == PortClash.Kinds.Unknown).ToList();

    List<string> Names(PortClash.Kinds kind)
    {
        var seen = new List<string>();
        foreach (var c in Clashes)
            if (c.Kind == kind && c.Owner.Length > 0 && !seen.Contains(c.Owner)) seen.Add(c.Owner);
        return seen;
    }

    /// <summary>null when nothing clashes.</summary>
    public static PortConflict? Parse(string text)
    {
        var clashes = new List<PortClash>();
        var offset = 1;
        foreach (var line in Tsv.Lines(text))
        {
            var f = Tsv.Fields(line);
            if (f[0] == "OFFSET" && f.Length >= 2) { offset = Tsv.Int(f[1]) ?? 1; continue; }
            if (f.Length < 6 || Tsv.Int(f[1]) is not { } port || Tsv.Int(f[4]) is not { } pid) continue;
            clashes.Add(new PortClash(f[0], port, f[2], PortClash.ParseKind(f[3]), pid, PortClash.ParseMove(f[5])));
        }
        return clashes.Count == 0 ? null : new PortConflict(clashes, offset);
    }
}

/// <summary>
/// A port more than one project declares.
///
/// Not a conflict yet — nothing is running — which is exactly why it is worth
/// saying: you find out otherwise by trying to run the second one.
/// </summary>
public sealed record PortOverlap(int Port, IReadOnlyList<string> Projects)
{
    public int Id => Port;

    public static List<PortOverlap> Parse(string text)
    {
        var result = new List<PortOverlap>();
        foreach (var line in Tsv.Lines(text))
        {
            var f = Tsv.Fields(line);
            if (f.Length < 2 || Tsv.Int(f[0]) is not { } port) continue;
            var who = f[1].Split(' ', StringSplitOptions.RemoveEmptyEntries);
            if (who.Length <= 1) continue;
            result.Add(new PortOverlap(port, who));
        }
        return result;
    }
}

/// <summary>One worktree on disk: what it cost, and whether anything still wants it.</summary>
public sealed record DiskRow(string Project, string Slug, string Ref, long Kb, string State)
{
    public string Id => Project + "/" + Slug;
    /// <summary>`running`, `gone` when the ref no longer exists, `idle` otherwise.</summary>
    public bool IsGone => State == "gone";
    public bool IsRunning => State == "running";
    public string Size => Bytes.FromKb(Kb);

    public static List<DiskRow> Parse(string text)
    {
        var result = new List<DiskRow>();
        foreach (var line in Tsv.Lines(text))
        {
            var f = Tsv.Fields(line);
            if (f.Length < 5) continue;
            result.Add(new DiskRow(f[0], f[1], f[2], Tsv.Int(f[3]) ?? 0, f[4]));
        }
        return result;
    }
}

/// <summary>A declared port and what is on it, from `ports`.</summary>
public sealed record PortRow(string Project, string Target, int Port, string State, string Owner, int Pid, string What)
{
    public string Id => Project + Target;
    /// <summary>`free`, `ours` when this project's own run holds it, `outside` otherwise.</summary>
    public bool IsFree => State == "free";
    public bool IsOurs => State == "ours";

    public static List<PortRow> Parse(string text)
    {
        var result = new List<PortRow>();
        foreach (var line in Tsv.Lines(text))
        {
            var f = Tsv.Fields(line);
            // f[5] is the holder's kind, which the app does not use.
            if (f.Length < 8 || Tsv.Int(f[2]) is not { } port) continue;
            result.Add(new PortRow(f[0], f[1], port, f[3], f[4], Tsv.Int(f[6]) ?? 0, f[7]));
        }
        return result;
    }
}

/// <summary>A git repository `scan` found that is not declared yet.</summary>
public sealed record ScanResult(string Name, string Path)
{
    public static List<ScanResult> Parse(string text)
    {
        var result = new List<ScanResult>();
        foreach (var line in Tsv.Lines(text))
        {
            var f = Tsv.Fields(line);
            if (f.Length < 2 || f[0].Length == 0) continue;
            result.Add(new ScanResult(f[0], f[1]));
        }
        return result;
    }
}

/// <summary>What `add` wrote: the project's name and its new .conf.</summary>
public sealed record AddedProject(string Name, string File)
{
    public static AddedProject? Parse(string text)
    {
        var first = Tsv.Lines(text).FirstOrDefault();
        if (first is null) return null;
        var f = Tsv.Fields(first);
        return f.Length < 2 ? null : new AddedProject(f[0], f[1]);
    }
}

/// <summary>The engine's wire conventions that are not a record of their own.</summary>
public static class Wire
{
    /// <summary>
    /// Every editable field of a project. TARGETS arrives with U+0001
    /// separating its lines, since it is the one multi-line value, and any
    /// value may itself contain tabs — so everything after the first tab is
    /// the value.
    /// </summary>
    public static Dictionary<string, string> ParseGet(string text)
    {
        var result = new Dictionary<string, string>(StringComparer.Ordinal);
        foreach (var line in Tsv.Lines(text))
        {
            var parts = Tsv.Fields(line);
            if (parts.Length < 2) continue;
            result[parts[0]] = string.Join('\t', parts.Skip(1)).Replace('\u0001', '\n');
        }
        return result;
    }

    /// <summary>`set` takes the same encoding in the other direction.</summary>
    public static string EncodeValue(string value) => value.Replace("\r\n", "\n").Replace('\n', '\u0001');

    /// <summary>
    /// What `failure` shows: stderr with every "FAILED" taken out and the
    /// whitespace trimmed, `Fix:` block and all — the engine names the command
    /// that fixes every failure it reports, which is worth nothing if the
    /// caller throws it away. Empty becomes a sentence rather than a blank
    /// alert.
    /// </summary>
    public static string TidyFailure(string stderr, string? command) =>
        stderr.Replace("FAILED", "").Trim() is { Length: > 0 } tidy
            ? tidy
            : $"{command ?? "The engine"} failed, with nothing to say why.";

    /// <summary>`suggest-offset`: a number on exit 0, else null. 0 means "nothing needs moving".</summary>
    public static int? ParseOffset(string output, int code) => code == 0 ? Tsv.Int(output.Trim()) : null;

    /// <summary>`presets`: the non-empty lines.</summary>
    public static List<string> ParseLines(string output) => Tsv.Lines(output).ToList();
}

/// <summary>
/// Turns a streamed command's bytes into the lines the Run dialog shows.
///
/// The Mac decoded each pipe read on its own and dropped any read that was not
/// valid UTF-8 on its own — so a read boundary inside an em dash or an arrow,
/// both of which the engine prints, lost the whole chunk. A stateful decoder
/// carries the partial character over to the next read instead. Lines are
/// assembled across reads for the same reason: a read boundary inside a line
/// used to show as two lines.
///
/// ANSI colour is stripped per line, after assembly, so an escape split across
/// two reads is still caught. Empty lines are dropped, as on the Mac.
/// </summary>
public sealed class LineAssembler
{
    static readonly Regex Ansi = new("\u001B\\[[0-9;]*m", RegexOptions.Compiled);

    readonly Decoder decoder = new UTF8Encoding(false, false).GetDecoder();
    readonly StringBuilder pending = new();
    char[] chars = new char[4096];

    public static string StripAnsi(string s) => Ansi.Replace(s, "");

    public List<string> Feed(ReadOnlySpan<byte> bytes)
    {
        var need = decoder.GetCharCount(bytes, flush: false);
        if (chars.Length < need) chars = new char[need];
        var n = decoder.GetChars(bytes, chars, flush: false);
        pending.Append(chars, 0, n);
        return Drain(final: false);
    }

    /// <summary>At end of stream: whatever is left, including a last line with no LF.</summary>
    public List<string> Finish()
    {
        var need = decoder.GetCharCount([], flush: true);
        if (need > 0)
        {
            if (chars.Length < need) chars = new char[need];
            pending.Append(chars, 0, decoder.GetChars([], chars, flush: true));
        }
        return Drain(final: true);
    }

    List<string> Drain(bool final)
    {
        var lines = new List<string>();
        var text = pending.ToString();
        var start = 0;
        for (var i = 0; i < text.Length; i++)
        {
            if (text[i] != '\n') continue;
            Emit(text[start..i], lines);
            start = i + 1;
        }
        pending.Clear();
        if (final) Emit(text[start..], lines);
        else pending.Append(text, start, text.Length - start);
        return lines;
    }

    static void Emit(string raw, List<string> into)
    {
        var line = StripAnsi(raw.EndsWith('\r') ? raw[..^1] : raw);
        if (line.Length > 0) into.Add(line);
    }
}

/// <summary>
/// Sizes the way the Mac's ByteCountFormatter (.file style) writes them:
/// decimal units, KB whole, MB to one place, GB and up to two, trailing zeros
/// dropped.
///
/// Zero is "0 KB". The formatter's own class method spells it "Zero KB",
/// which read as a bug in the Disk sheet footer and would read as one on any
/// empty worktree too.
/// </summary>
public static class Bytes
{
    static readonly string[] Units = ["bytes", "KB", "MB", "GB", "TB", "PB"];
    static readonly int[] Places = [0, 0, 1, 2, 2, 2];

    public static string FromKb(long kb) => Format(kb * 1024);

    public static string Format(long bytes)
    {
        if (bytes == 0) return "0 KB";
        if (bytes < 0) return "-" + Format(-bytes);
        if (bytes < 1000) return bytes == 1 ? "1 byte" : $"{bytes.ToString(CultureInfo.InvariantCulture)} bytes";
        var unit = 1;
        double value = bytes / 1000.0;
        while (unit < Units.Length - 1 && Math.Round(value, Places[unit]) >= 1000)
        {
            value /= 1000;
            unit++;
        }
        var rounded = Math.Round(value, Places[unit], MidpointRounding.AwayFromZero);
        var pattern = Places[unit] == 0 ? "0" : "0." + new string('#', Places[unit]);
        return rounded.ToString(pattern, CultureInfo.InvariantCulture) + " " + Units[unit];
    }
}

/// <summary>One target's health. Checked, not assumed from a live pid — a server can be up and answering 500s.</summary>
public enum Health
{
    Unknown,
    Starting,
    Healthy,
    Failing,
}

/// <summary>The health rules, apart from the polling (HealthMonitor in Engine.cs).</summary>
public static class HealthRules
{
    /// <summary>Any HTTP answer below 500 is healthy; a 500 is a server that is up and broken.</summary>
    public static Health OnResponse(int status) => status < 500 ? Health.Healthy : Health.Failing;

    /// <summary>
    /// No HTTP answer at all (refused, timed out). Covers the case the Mac's
    /// first version assigned nothing for, which left a starting run on
    /// "Starting" forever with nothing to say why. Not answering yet is not
    /// the same as broken — but going quiet after answering is.
    /// </summary>
    public static Health OnNoResponse(Health previous) => previous == Health.Healthy ? Health.Failing : Health.Starting;

    /// <summary>The strip shows the worst of the run's targets.</summary>
    public static Health Worst(IEnumerable<Health> statuses)
    {
        var all = statuses.ToList();
        if (all.Contains(Health.Failing)) return Health.Failing;
        if (all.Contains(Health.Starting) || all.Count == 0) return Health.Starting;
        return all.All(h => h == Health.Healthy) ? Health.Healthy : Health.Starting;
    }

    public static string Label(this Health h) => h switch
    {
        Health.Healthy => "healthy",
        Health.Starting => "starting",
        Health.Failing => "not responding",
        _ => "unknown",
    };

    /// <summary>"Healthy", "Not responding": sentence case, the Windows convention for status text.</summary>
    public static string Title(this Health h)
    {
        var l = h.Label();
        return char.ToUpperInvariant(l[0]) + l[1..];
    }

    public static Tone Tone(this Health h) => h switch
    {
        Health.Healthy => Runbranch.Tone.Green,
        Health.Starting => Runbranch.Tone.Orange,
        Health.Failing => Runbranch.Tone.Red,
        _ => Runbranch.Tone.Secondary,
    };
}

/// <summary>
/// Which branches the list shows (ui-map §4.2). Not persisted, as on the Mac.
/// </summary>
public sealed class BranchFilter
{
    public const long Week = 7 * 24 * 60 * 60;

    public string Query { get; set; } = "";
    public bool MineOnly { get; set; }
    public bool ShowMerged { get; set; }
    public bool ShowOlder { get; set; }
    public bool ShowAllRemote { get; set; }

    /// <summary>Tints the filter button. The search box speaks for itself, so the query does not count.</summary>
    public bool IsActive => MineOnly || ShowMerged || ShowOlder || ShowAllRemote;

    public string Search => Query.Trim().ToLowerInvariant();

    public List<Branch> Visible(IEnumerable<Branch> branches, RunState state, long? now = null)
    {
        var t = now ?? DateTimeOffset.UtcNow.ToUnixTimeSeconds();
        var q = Search;
        return branches.Where(b => Shows(b, state, q, t)).ToList();
    }

    bool Shows(Branch b, RunState state, string q, long now)
    {
        // Search overrides the filters: if you typed a branch's name you want
        // to see it, merged and ancient or not.
        if (q.Length > 0)
            return b.Ref.ToLowerInvariant().Contains(q, StringComparison.Ordinal)
                   || b.Subject.ToLowerInvariant().Contains(q, StringComparison.Ordinal);
        // The default branch and whatever is running are always shown: hiding
        // the thing on screen would be worse than a wide filter.
        if (b.IsDefault || b.Ref == state.Ref) return true;
        if (MineOnly && !b.Mine) return false;
        // A repo can carry hundreds of remote branches and almost none of them
        // are worth looking at. The ones with an open pull request are exactly
        // the reviewable set, so those show by default and the rest are opt-in.
        if (b.IsRemote && !ShowAllRemote && b.PR != PRState.Open) return false;
        // Merged covers both readings: what GitHub says, and what the commit
        // graph says. A branch the trunk already contains is spent whether or
        // not a pull request ever recorded it.
        if (!ShowMerged && (b.PR == PRState.Merged || b.IsSubsumed)) return false;
        if (!ShowOlder && now - b.Timestamp > Week) return false;
        return true;
    }
}

public static class PathText
{
    /// <summary>
    /// `C:\Users\someone\code` → `~\code`.
    ///
    /// Not cosmetic: a full path in the UI puts the account name into any
    /// screenshot of it, and on the Mac this was inlined at three call sites
    /// where a fourth would have missed it. Case-insensitive, because Windows
    /// paths are, and the engine may print the profile directory in either
    /// case. Only a whole leading path component is replaced, so
    /// C:\Users\al does not eat the start of C:\Users\alec.
    /// </summary>
    public static string AbbreviatingHome(this string path, string? home = null)
    {
        home ??= Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        if (string.IsNullOrEmpty(home) || string.IsNullOrEmpty(path)) return path;
        home = home.TrimEnd('\\', '/');
        var sb = new StringBuilder();
        var i = 0;
        while (i < path.Length)
        {
            var at = path.IndexOf(home, i, StringComparison.OrdinalIgnoreCase);
            if (at < 0) break;
            var end = at + home.Length;
            var boundaryBefore = at == 0 || !char.IsLetterOrDigit(path[at - 1]);
            var boundaryAfter = end == path.Length || path[end] is '\\' or '/' or '\t' or ' ' or '"' or '\'';
            sb.Append(path, i, at - i);
            sb.Append(boundaryBefore && boundaryAfter ? "~" : path.Substring(at, home.Length));
            i = end;
        }
        sb.Append(path, i, path.Length - i);
        return sb.ToString();
    }
}
