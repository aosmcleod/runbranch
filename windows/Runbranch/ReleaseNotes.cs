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

// Saying what changed: the bundled changelog, when to show it, and the small
// markdown dialect it is written in. The "What changed" half of Updates.swift.
//
// Free of WinUI, like Model.cs, so Runbranch.Tests compiles it on its own;
// Views/NotesText draws what Notes.Parse returns.

using System.Text;
using System.Text.Json;

namespace Runbranch;

/// <summary>One version's section of CHANGELOG.md.</summary>
public sealed record ReleaseNote(string Version, string Notes)
{
    public AppVersion? Parsed => AppVersion.Parse(Version);
}

/// <summary>
/// The changelog, as shipped beside the exe.
///
/// Bundled rather than fetched: it has to work on a laptop with no network,
/// and it has to work for someone who built the app from source and has no
/// release to read notes off. make-app.ps1 writes it out of CHANGELOG.md, so
/// there is still only one copy to keep current.
/// </summary>
public static class ReleaseNotes
{
    public const string FileName = "ReleaseNotes.json";

    static readonly Lazy<IReadOnlyList<ReleaseNote>> bundled =
        new(() => Load(Path.Combine(AppContext.BaseDirectory, FileName)));

    /// <summary>Every bundled entry, newest first, as the changelog has them.</summary>
    public static IReadOnlyList<ReleaseNote> All => bundled.Value;

    /// <summary>A missing or unreadable file is no notes, never a reason not to start.</summary>
    public static IReadOnlyList<ReleaseNote> Load(string path)
    {
        try
        {
            if (!File.Exists(path)) return [];
            return Parse(File.ReadAllText(path));
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            return [];
        }
    }

    public static IReadOnlyList<ReleaseNote> Parse(string json)
    {
        try
        {
            using var doc = JsonDocument.Parse(json);
            if (doc.RootElement.ValueKind != JsonValueKind.Array) return [];
            var list = new List<ReleaseNote>();
            foreach (var e in doc.RootElement.EnumerateArray())
            {
                if (e.ValueKind != JsonValueKind.Object) continue;
                if (!e.TryGetProperty("version", out var v) || v.ValueKind != JsonValueKind.String) continue;
                var notes = e.TryGetProperty("notes", out var n) && n.ValueKind == JsonValueKind.String ? n.GetString()! : "";
                list.Add(new ReleaseNote(v.GetString()!, notes));
            }
            return list;
        }
        catch (JsonException)
        {
            return [];
        }
    }

    /// <summary>
    /// Everything released after `seen`, up to what is installed, newest
    /// first. Not just the newest entry: someone who skips two releases should
    /// see both, or the sheet quietly hides half of what changed under them.
    /// </summary>
    public static List<ReleaseNote> Since(IEnumerable<ReleaseNote> entries, AppVersion seen, AppVersion installed) =>
        entries.Where(e => e.Parsed is { } v && v > seen && v <= installed).ToList();
}

/// <summary>What "What's new" does on this launch.</summary>
/// <param name="Record">The version to store as last seen, or null to leave it.</param>
/// <param name="Show">The entries to show; empty shows nothing.</param>
public sealed record WhatsNewDecision(string? Record, IReadOnlyList<ReleaseNote> Show);

public static class WhatsNew
{
    /// <summary>
    /// The changelog, on the first launch after the version changes.
    ///
    /// An empty stored version is a fresh install, not a hundred missed
    /// releases: someone opening Runbranch for the first time is told what
    /// changed since a version they never had. So the first launch records
    /// where it starts and shows nothing.
    /// </summary>
    public static WhatsNewDecision Decide(string lastSeen, AppVersion installed, IEnumerable<ReleaseNote> entries)
    {
        if (lastSeen.Length == 0 || AppVersion.Parse(lastSeen) is not { } seen)
            return new(installed.Description, []);
        if (seen >= installed)
        {
            // Also covers a downgrade, where the stored version is ahead. Move
            // the mark rather than leaving it to fire on every launch.
            return new(seen > installed ? installed.Description : null, []);
        }
        return new(installed.Description, ReleaseNotes.Since(entries, seen, installed));
    }
}

public enum NoteKind { Gap, Heading, Bullet, Body }

/// <summary>A run of inline text: plain, **bold**, *italic* or `code`.</summary>
public sealed record NoteSpan(string Text, bool Bold = false, bool Italic = false, bool Code = false);

public sealed record NoteLine(NoteKind Kind, string Text)
{
    public IReadOnlyList<NoteSpan> Spans => Notes.Inline(Text);
}

/// <summary>
/// Changelog prose, parsed rather than dumped.
///
/// Raw markdown shows the asterisks and runs the bullets together, and a full
/// markdown renderer is a dependency for four constructs. This handles the
/// four the changelog actually uses — a bold lead line, a bullet, a paragraph,
/// a GitHub alert block — plus the inline marks inside them.
/// </summary>
public static class Notes
{
    /// <summary>
    /// Paragraphs are rewrapped rather than kept as written: the changelog is
    /// hard-wrapped at 78 columns for reading in a terminal, and honouring
    /// those breaks in a 480 px dialog puts them in the wrong places entirely.
    /// </summary>
    public static List<NoteLine> Parse(string text)
    {
        var output = new List<NoteLine>();
        var paragraph = new List<string>();

        void Flush()
        {
            if (paragraph.Count == 0) return;
            output.Add(new NoteLine(NoteKind.Body, string.Join(' ', paragraph)));
            paragraph.Clear();
        }

        // CRLF as one break. The Mac split on every newline character, which
        // read a CRLF file as a blank line after every line.
        foreach (var raw in text.Replace("\r\n", "\n").Split('\n', '\r'))
        {
            var line = raw.Trim(' ', '\t');
            // GitHub alert syntax. The marker is chrome; the prose inside it
            // is the point.
            if (line.StartsWith('>'))
            {
                line = line[1..].Trim(' ', '\t');
                if (line.StartsWith("[!", StringComparison.Ordinal)) continue;
            }
            if (line.Length == 0)
            {
                Flush();
                if (output.Count > 0 && output[^1].Kind != NoteKind.Gap) output.Add(new NoteLine(NoteKind.Gap, ""));
                continue;
            }
            // A version heading inside a section body, which happens in a
            // release note pasted from the changelog.
            if (line.StartsWith('#'))
            {
                Flush();
                output.Add(new NoteLine(NoteKind.Heading, line.TrimStart('#').Trim(' ', '\t')));
                continue;
            }
            if (line.StartsWith("- ", StringComparison.Ordinal) || line.StartsWith("* ", StringComparison.Ordinal))
            {
                Flush();
                output.Add(new NoteLine(NoteKind.Bullet, line[2..]));
                continue;
            }
            // A lead line like **Two projects that want the same port** — bold
            // for its whole length and nothing else on the line.
            if (line.Length > 4 && line.StartsWith("**", StringComparison.Ordinal) && line.EndsWith("**", StringComparison.Ordinal)
                && !line[2..^2].Contains("**", StringComparison.Ordinal))
            {
                Flush();
                output.Add(new NoteLine(NoteKind.Heading, line[2..^2]));
                continue;
            }
            // A bullet's continuation line, indented in the source. It has
            // already been trimmed, so append it to the bullet rather than
            // starting a paragraph that would render at the wrong indent.
            if (raw.StartsWith("  ", StringComparison.Ordinal) && paragraph.Count == 0
                && output.Count > 0 && output[^1].Kind == NoteKind.Bullet)
            {
                output[^1] = output[^1] with { Text = output[^1].Text + " " + line };
                continue;
            }
            paragraph.Add(line);
        }
        Flush();
        if (output.Count > 0 && output[^1].Kind == NoteKind.Gap) output.RemoveAt(output.Count - 1);
        return output;
    }

    /// <summary>
    /// The inline marks the changelog uses: **bold**, *italic*, `code`, and a
    /// [link](target), which shows its text — the targets are paths inside
    /// the repository, which mean nothing from inside the app. An opener with
    /// no closer is literal text, as markdown has it.
    /// </summary>
    public static List<NoteSpan> Inline(string s, bool bold = false, bool italic = false)
    {
        var spans = new List<NoteSpan>();
        var plain = new StringBuilder();

        void Plain()
        {
            if (plain.Length == 0) return;
            spans.Add(new NoteSpan(plain.ToString(), bold, italic));
            plain.Clear();
        }

        var i = 0;
        while (i < s.Length)
        {
            var c = s[i];
            if (c == '`' && s.IndexOf('`', i + 1) is var close && close > i + 1)
            {
                Plain();
                spans.Add(new NoteSpan(s[(i + 1)..close], bold, italic, Code: true));
                i = close + 1;
                continue;
            }
            if (c == '*' && i + 1 < s.Length && s[i + 1] == '*'
                && s.IndexOf("**", i + 2, StringComparison.Ordinal) is var end && end > i + 2)
            {
                Plain();
                spans.AddRange(Inline(s[(i + 2)..end], bold: true, italic));
                i = end + 2;
                continue;
            }
            if (c == '*' && i + 1 < s.Length && s[i + 1] != ' ' && s[i + 1] != '*'
                && s.IndexOf('*', i + 1) is var endItalic && endItalic > i + 1 && s[endItalic - 1] != ' ')
            {
                Plain();
                spans.AddRange(Inline(s[(i + 1)..endItalic], bold, italic: true));
                i = endItalic + 1;
                continue;
            }
            if (c == '[' && s.IndexOf("](", i + 1, StringComparison.Ordinal) is var mid && mid > i + 1
                && s.IndexOf(')', mid + 2) is var paren && paren > mid + 1)
            {
                Plain();
                spans.AddRange(Inline(s[(i + 1)..mid], bold, italic));
                i = paren + 1;
                continue;
            }
            plain.Append(c);
            i++;
        }
        Plain();
        return spans;
    }
}
