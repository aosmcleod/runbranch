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

// What the sheets say, apart from how they draw it: the summaries, counts,
// badges and notes that Disk.swift, Ports.swift, ProjectEditor.swift and
// RunSheet.swift compute inline. Free of WinUI so Runbranch.Tests can pin the
// singulars and plurals the Mac once got wrong.

using System.Globalization;

namespace Runbranch.Dialogs;

/// <summary>A badge's content, for a Views.Badge.</summary>
public sealed record BadgeSpec(string Text, string Symbol, Tone Tone, string? Tip = null);

public static class DiskRules
{
    public static long Total(IEnumerable<DiskRow> rows) => rows.Sum(r => r.Kb);

    public static long Spare(IEnumerable<DiskRow> rows) => rows.Where(r => !r.IsRunning).Sum(r => r.Kb);

    /// <summary>Projects with at least one worktree whose ref no longer exists, in order.</summary>
    public static List<string> Prunable(IEnumerable<DiskRow> rows)
    {
        var seen = new List<string>();
        foreach (var r in rows)
            if (r.IsGone && !seen.Contains(r.Project)) seen.Add(r.Project);
        return seen;
    }

    /// <summary>
    /// Spelled out rather than interpolated, because the obvious version said
    /// "1 worktrees" and "Zero KB not in use". null rows: still measuring.
    /// </summary>
    public static string Summary(IReadOnlyList<DiskRow>? rows)
    {
        if (rows is null) return "Measuring…";
        if (rows.Count == 0) return "Nothing on disk yet";
        var count = rows.Count == 1 ? "1 worktree" : $"{rows.Count} worktrees";
        var size = Bytes.FromKb(Total(rows));
        var spare = Spare(rows);
        return spare > 0 ? $"{count} · {size}, {Bytes.FromKb(spare)} not in use" : $"{count} · {size}, all of it in use";
    }

    /// <summary>The footer's line; null while measuring, when it says nothing.</summary>
    public static string? Footer(IReadOnlyList<DiskRow>? rows)
    {
        if (rows is null) return null;
        var prunable = Prunable(rows);
        if (prunable.Count == 0) return "Nothing to reclaim — every worktree's branch still exists.";
        return prunable.Count == 1
            ? "One project has worktrees whose branch is gone"
            : $"{prunable.Count} projects have worktrees whose branch is gone";
    }

    /// <summary>The ref, or the directory's slug when the engine could not say which ref it was cut from.</summary>
    public static string Title(DiskRow r) => r.Ref == "?" ? r.Slug : r.Ref;

    public static BadgeSpec Badge(DiskRow r) =>
        r.IsRunning ? new("running", "bolt.fill", Tone.Green)
        : r.IsGone ? new("branch gone", "trash", Tone.Orange, "The branch this was cut from no longer exists")
        : new("idle", "", Tone.Secondary);
}

public static class PortRules
{
    public static BadgeSpec Badge(PortRow r) =>
        r.IsFree ? new("free", "", Tone.Secondary)
        : r.IsOurs ? new("running", "bolt.fill", Tone.Green)
        // Not ours: either another project of yours, or the same project
        // started by something else. Either way it blocks this one.
        : new(r.Owner.Length == 0 ? "in use" : $"{r.Owner}, outside", "exclamationmark.triangle.fill", Tone.Orange);

    public static string OverlapHeading(int count) => count == 1
        ? "One port is claimed by more than one project"
        : $"{count} ports are claimed by more than one project";

    /// <summary>
    /// What Move… reports when it does not move anything. An offset of 0
    /// means nothing needed moving, which is worth saying rather than
    /// silently doing nothing.
    /// </summary>
    public static string NotMoved(string project, int? offset) => offset == 0
        ? $"{project} does not need moving — nothing else is on its ports."
        : $"Could not find a free range for {project} within 200 ports.";

    // --- the conflict sheet ------------------------------------------------

    public static string Describe(PortClash c) => c.Kind switch
    {
        PortClash.Kinds.Ours => $"{c.Owner} — a Runbranch run",
        PortClash.Kinds.Outside => $"{c.Owner} — started outside Runbranch",
        _ => $"another app (pid {c.Pid.ToString(CultureInfo.InvariantCulture)})",
    };

    public static string Subtitle(PortConflict conflict)
    {
        var ours = conflict.Owners;
        var outside = conflict.Outsiders;
        if (ours.Count > 0 && outside.Count == 0) return $"Runbranch is running {string.Join(" and ", ours)} on them.";
        if (ours.Count == 0 && outside.Count > 0)
            return $"{string.Join(" and ", outside)} is already running, started by something other than Runbranch.";
        if (ours.Count > 0 && outside.Count > 0) return "Some are ours, some are not.";
        return "Something outside Runbranch is using them.";
    }

    /// <summary>
    /// The port the first target would move to, so the button names a number
    /// rather than an offset nobody asked to think about.
    /// </summary>
    public static int ShiftedFirstPort(PortConflict conflict) =>
        (conflict.Clashes.Count > 0 ? conflict.Clashes[0].Port : 0) + conflict.FreeOffset;

    public static string TakeOverLabel(PortConflict conflict) =>
        conflict.Outsiders.Count > 1 ? "Take over ports" : "Take over port";

    /// <summary>
    /// An honest caveat beats a button that silently might not work — and the
    /// failure, if it comes, is immediate and names the fix.
    /// </summary>
    public const string ShiftCaveat =
        "Running alongside passes the new port as PORT. Most dev servers honour it; if this one does not, "
        + "the run stops straight away and says what to change.";
}

public static class EditorRules
{
    /// <summary>The Runtime picker's choices; empty is None.</summary>
    public static readonly string[] Runtimes = ["", "mise", "fnm", "asdf", "nvm"];

    /// <summary>Keys whose value differs from what was loaded, sorted, as Save writes them.</summary>
    public static List<string> DirtyKeys(IReadOnlyDictionary<string, string> values, IReadOnlyDictionary<string, string> original) =>
        values.Keys
            .Where(k => !original.TryGetValue(k, out var o) || o != values[k])
            .OrderBy(k => k, StringComparer.Ordinal)
            .ToList();

    /// <summary>
    /// What the offset actually does to the declared ports.
    ///
    /// Once it is set, the numbers in TARGETS are no longer the numbers the
    /// servers listen on, and working that out in your head is the part that
    /// made hand-editing ports the easier option.
    /// </summary>
    public static string OffsetNote(string targets, string offsetText)
    {
        var offset = Tsv.Int(offsetText.Trim()) ?? 0;
        var declared = targets.Split(['\n', '\r'])
            .Select(line => line.Split(':'))
            .Where(parts => parts.Length >= 2)
            .Select(parts => Tsv.Int(parts[1].Trim()))
            .OfType<int>()
            .ToList();
        if (declared.Count == 0) return "Shifts every port this project declares, and rewrites {port} in its commands.";
        if (offset == 0)
            return "Declared: " + string.Join(", ", declared.Select(Num)) + ". A shift moves all of them together.";
        return "Runs on " + string.Join(", ", declared.Select(p => $"{Num(p)} → {Num(p + offset)}"))
             + ". {port} in a command is rewritten to match.";
    }

    /// <summary>The first line of what `set` complained about, which the contract keeps for the message.</summary>
    public static string FirstLine(string failure)
    {
        var trimmed = failure.Trim();
        var first = trimmed.Split('\n')[0].TrimEnd('\r');
        return first.Length > 0 ? first : trimmed;
    }

    static string Num(int n) => n.ToString(CultureInfo.InvariantCulture);
}

public static class LogRules
{
    /// <summary>Retained lines. 250,000 lines measured at 36.6 MB on the Mac; the file keeps everything.</summary>
    public const int Keep = 5_000;

    static readonly string[] Needles =
        ["error", "exception", "failed", "failure", "fatal", "traceback", "panic:", "econnrefused", "eaddrinuse"];

    /// <summary>
    /// Lines worth jumping to. Deliberately broad, and it will match a line
    /// that only mentions the word — "0 errors" included. A viewer that
    /// misses the error you opened it for is worse than one that occasionally
    /// offers a line you did not need, and every framework spells this
    /// differently.
    /// </summary>
    public static bool LooksLikeError(string line)
    {
        var l = line.ToLowerInvariant();
        return Needles.Any(n => l.Contains(n, StringComparison.Ordinal));
    }

    public static bool Matches(string line, string filter) =>
        filter.Length == 0 || line.Contains(filter, StringComparison.CurrentCultureIgnoreCase);

    public static string LineCount(int n) => $"{n.ToString(CultureInfo.InvariantCulture)} lines";

    /// <summary>Empty rather than absent, so the footer does not reflow when the first error arrives.</summary>
    public static string ErrorCount(int n) => n == 0 ? "" : $"· {n.ToString(CultureInfo.InvariantCulture)} matching error";
}

public static class ScanRules
{
    public static string Added(int n) => n == 1 ? "Added 1 project" : $"Added {n.ToString(CultureInfo.InvariantCulture)} projects";

    public static string AddButton(int n) => $"Add {n.ToString(CultureInfo.InvariantCulture)}";

    /// <summary>The project id `add` wrote: its .conf's basename.</summary>
    public static string Id(AddedProject added) => Path.GetFileNameWithoutExtension(added.File);
}
