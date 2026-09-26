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

// Following one target's log file: RunSheet.swift's LogViewer.load(), apart
// from the view (ui-map §4.6). Free of WinUI so Runbranch.Tests can drive it
// against real files.

using System.Text;

namespace Runbranch.Dialogs;

/// <summary>What one read found.</summary>
/// <param name="Reset">The file got shorter, so it is a new log: drop what was shown.</param>
/// <param name="Lines">Complete new lines, ANSI stripped, empty ones dropped.</param>
public sealed record LogChunk(bool Reset, IReadOnlyList<string> Lines);

public sealed class LogTail
{
    /// <summary>
    /// How far back to start when opening a log that is already large.
    /// Reading 16 MB to show the last screenful is work for its own sake.
    /// </summary>
    public const long TailCap = 256 * 1024;

    /// <summary>
    /// How much of the file has been consumed. The point of the Mac's rewrite:
    /// re-reading, de-ANSI-ing and re-splitting the whole log every 1.5 s cost
    /// 198 ms at 16 MB — a visible hitch on a chatty dev server, forever.
    /// </summary>
    public long Offset { get; private set; }

    public void Reset() => Offset = 0;

    /// <summary>Reads whatever has been appended since last time. A missing file reads as nothing.</summary>
    public LogChunk Read(string path)
    {
        FileStream stream;
        try
        {
            // Shared every way: the server is writing this file, and the
            // engine truncates it when the server restarts. Holding it any
            // other way would make either of them fail on Windows.
            stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            return new(false, []);
        }

        using (stream)
        {
            var size = stream.Length;
            // A run restarts by truncating its log, so a file shorter than what
            // has already been read is a new log rather than a shrinking one.
            var reset = size < Offset;
            if (reset) Offset = 0;

            var from = Offset;
            var skipPartialFirstLine = false;
            if (from == 0 && size > TailCap)
            {
                from = size - TailCap;
                skipPartialFirstLine = true;
            }
            if (size <= from) return new(reset, []);

            var chunk = new byte[size - from];
            stream.Seek(from, SeekOrigin.Begin);
            var read = 0;
            while (read < chunk.Length)
            {
                var n = stream.Read(chunk, read, chunk.Length - read);
                if (n == 0) break;
                read += n;
            }

            // Stop at the last newline. A tick can land mid-line, and half a
            // line committed now is a wrong line forever — the rest arrives
            // next tick and would start its own.
            if (read == 0) return new(reset, []);
            var lastBreak = Array.LastIndexOf(chunk, (byte)'\n', read - 1);
            if (lastBreak < 0) return new(reset, []);
            Offset = from + lastBreak + 1;

            var text = LineAssembler.StripAnsi(new UTF8Encoding(false, false).GetString(chunk, 0, lastBreak + 1));
            var lines = text.Split('\n')
                .Select(l => l.EndsWith('\r') ? l[..^1] : l)
                .Where(l => l.Length > 0)
                .ToList();
            // Seeking into the middle of the file lands mid-line by definition.
            if (skipPartialFirstLine && lines.Count > 0) lines.RemoveAt(0);
            return new(reset, lines);
        }
    }
}
