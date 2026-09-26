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

package run

import (
	"io"
	"os"
	"regexp"
	"runtime"
)

// tooLong is what a path past 260 characters looks like in the output of the
// tools a project runs: git's "Filename too long", Node's ENAMETOOLONG,
// cmd.exe's "The filename or extension is too long", Win32 error 206
// (ERROR_FILENAME_EXCED_RANGE) as Rust and Go print it, .NET's
// PathTooLongException, and the MAX_PATH that turns up in all sorts of
// messages about it.
//
// Plus cmd.exe's "The directory or file cannot be created", which is what its
// mkdir says past MAX_PATH (seen on this machine with LongPathsEnabled off).
// It has other causes too, which is why the note says "may".
var tooLong = regexp.MustCompile(`(?i)filename too long|path too long|path is too long|ENAMETOOLONG|filename or extension is too long|MAX_PATH|\berror 206\b|os error 206|ERROR_FILENAME_EXCED_RANGE|PathTooLongException|directory or file cannot be created`)

// LongPathsSwitch turns on Windows long paths for the whole machine. Named in
// a failure only as the optional fix: the engine never needs it (spec F17),
// but a tool that a project runs may.
const LongPathsSwitch = `New-ItemProperty -Path HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem -Name LongPathsEnabled -Value 1 -PropertyType DWORD -Force    # PowerShell, as administrator`

// looksTooLong reports whether output carries a path-too-long signature.
func looksTooLong(output []byte) bool { return tooLong.Match(output) }

// longPathNote is a paragraph to add to a failure whose output looks like a
// path was too long, or "" when it does not or the note could not help.
//
// Worded as a possibility, not a diagnosis: a signature in a log is evidence,
// and a failed install prints plenty of lines that are not the reason it
// failed. Windows only, and only while the switch is off — on macOS the limit
// is 1024 and not a setting, and with the switch already on it would be
// advice to do what has been done.
func longPathNote(output []byte) string {
	if runtime.GOOS != "windows" || !looksTooLong(output) {
		return ""
	}
	if on, known := LongPathsEnabled(); known && on {
		return ""
	}
	return "\n\nThe output mentions a path that is too long, which may be why. Runbranch\n" +
		"handles long paths in what it does itself, but not every tool a project runs\n" +
		"does. If that is the cause, turning on Windows long paths usually fixes it —\n" +
		"optional, and it needs an administrator once:\n\n    " + LongPathsSwitch
}

// logTail is the end of a log, enough to search for a signature without
// reading a server's whole day into memory.
func logTail(path string) []byte {
	f, err := os.Open(path)
	if err != nil {
		return nil
	}
	defer f.Close()
	if fi, err := f.Stat(); err == nil && fi.Size() > tailBytes {
		_, _ = f.Seek(-tailBytes, io.SeekEnd)
	}
	b, _ := io.ReadAll(f)
	return b
}

const tailBytes = 64 << 10

// tailBuffer keeps the last tailBytes written to it: the output of a command
// that has no log file of its own (MIGRATE, SEED), for the same search.
type tailBuffer struct{ b []byte }

func (t *tailBuffer) Write(p []byte) (int, error) {
	t.b = append(t.b, p...)
	if len(t.b) > tailBytes {
		t.b = append(t.b[:0:0], t.b[len(t.b)-tailBytes:]...)
	}
	return len(p), nil
}

func (t *tailBuffer) Bytes() []byte { return t.b }
