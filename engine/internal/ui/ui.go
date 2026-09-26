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

// Package ui is every word the engine says to a person: the step/ok/info
// lines, the FAILED block, and the prompts.
//
// Every message is written to be read by a person either way — in a terminal,
// or streamed into the app's window, which strips the colour and splits on
// newlines. So each helper writes one whole line in one write, LF only, and
// never a CR: the app splits on "\n", and a CRLF would leave a \r stuck to the
// last field of every machine-readable line.
package ui

import (
	"bufio"
	"bytes"
	"fmt"
	"io"
	"os"
	"strings"
	"sync"

	"golang.org/x/term"
)

// HaveTTY is true when stdout is a terminal. The app never gives the engine
// one, and that is what switches off colour, prompts and the human tables.
var HaveTTY bool

// Colour codes, empty unless there is a terminal and NO_COLOR is unset.
var Dim, Red, Grn, Yel, Blu, Bld, Off string

func init() {
	HaveTTY = term.IsTerminal(int(os.Stdout.Fd()))
	if HaveTTY {
		// On Windows this turns on VT processing and UTF-8 output; when the
		// console will not do VT, colour is simply left off.
		if !prepareConsole() {
			return
		}
		if os.Getenv("NO_COLOR") == "" {
			Dim, Red, Grn = "\033[2m", "\033[31m", "\033[32m"
			Yel, Blu, Bld, Off = "\033[33m", "\033[34m", "\033[1m", "\033[0m"
		}
	}
}

var outMu sync.Mutex

// Out writes s to stdout in a single write.
func Out(s string) {
	outMu.Lock()
	defer outMu.Unlock()
	_, _ = io.WriteString(os.Stdout, s)
}

// Printf is fmt.Printf in one write.
func Printf(format string, a ...any) { Out(fmt.Sprintf(format, a...)) }

// Errf writes to stderr in one write.
func Errf(format string, a ...any) {
	outMu.Lock()
	defer outMu.Unlock()
	_, _ = io.WriteString(os.Stderr, fmt.Sprintf(format, a...))
}

func Step(s string) { Printf("\n%s==>%s %s%s%s\n", Blu, Off, Bld, s, Off) }
func OK(s string)   { Printf("    %sok%s   %s\n", Grn, Off, s) }
func Info(s string) { Printf("        %s\n", s) }
func DimLine(s string) {
	Printf("        %s%s%s\n", Dim, s, Off)
}
func Warn(s string) { Printf("    %swarn%s %s\n", Yel, Off, s) }

// Failure is a die in flight. Die panics with one so that a caller can do
// what bash does with a subshell — run something that might die and carry on
// — through Catch. main recovers it, prints it and exits 1.
type Failure struct {
	Msg, Fix string
}

func (f *Failure) Error() string { return f.Msg }

// Die fails loudly. fix names the command that fixes it — that is the whole
// reason this tool exists. There are no dialogs; the app shows what we print.
func Die(msg, fix string) { panic(&Failure{Msg: msg, Fix: fix}) }

// Exit ends the program with a code once deferred output has gone, without
// being mistaken for a failure.
type Exit int

// ExitWith panics with an Exit, for usage errors (2) and the commands whose
// exit status is an answer (check-ports, status, doctor).
func ExitWith(code int) { panic(Exit(code)) }

// PrintFailure writes the FAILED block exactly as the bash engine did. The
// app depends on its shape: the first line of stderr carries the message, and
// everything after "FAILED" is shown to the user.
func PrintFailure(f *Failure) {
	var b strings.Builder
	fmt.Fprintf(&b, "\n%s%s FAILED %s %s\n", Bld, Red, Off, f.Msg)
	if f.Fix != "" {
		fmt.Fprintf(&b, "\n%sFix:%s\n\n    %s\n\n", Bld, Off, f.Fix)
	}
	Errf("%s", b.String())
}

// Catch runs fn and returns the Failure it died with, if any, printing
// nothing. Anything else that panics keeps panicking.
func Catch(fn func()) (fail *Failure) {
	defer func() {
		if r := recover(); r != nil {
			if f, ok := r.(*Failure); ok {
				fail = f
				return
			}
			panic(r)
		}
	}()
	fn()
	return nil
}

var stdin = bufio.NewReader(os.Stdin)

// ReadLine reads one line from stdin, without its line ending. At EOF it
// returns what it has, possibly nothing.
func ReadLine() string {
	s, _ := stdin.ReadString('\n')
	return strings.TrimRight(s, "\r\n")
}

// Ask is a yes/no question. Non-interactively — which is how the app runs
// the engine — there is nobody to answer, so it takes the stated default and
// SAYS SO rather than hang on a read. The cautious default for anything
// destructive is no.
func Ask(question string, defaultNo bool) bool {
	if !HaveTTY {
		if defaultNo {
			Info(question + "  -> no (assuming the cautious answer)")
			return false
		}
		Info(question + "  -> yes")
		return true
	}
	hint := "[Y/n]"
	if defaultNo {
		hint = "[y/N]"
	}
	Printf("\n    %s %s ", question, hint)
	reply := ReadLine()
	switch {
	case strings.HasPrefix(reply, "y"), strings.HasPrefix(reply, "Y"):
		return true
	case strings.HasPrefix(reply, "n"), strings.HasPrefix(reply, "N"):
		return false
	case reply == "":
		return !defaultNo
	}
	return false
}

// LineWriter passes output through a whole line at a time. The app reads the
// engine's output in chunks and shows each chunk's lines; a chunk boundary in
// the middle of a line shows as two lines, and one in the middle of a
// multi-byte character (—, →) drops the chunk entirely. A child process's
// output is therefore re-cut on newlines before it reaches stdout, and a CRLF
// from a Windows tool loses its CR on the way.
type LineWriter struct {
	W   io.Writer
	buf []byte
	mu  sync.Mutex
}

func (l *LineWriter) Write(p []byte) (int, error) {
	l.mu.Lock()
	defer l.mu.Unlock()
	l.buf = append(l.buf, p...)
	for {
		i := bytes.IndexByte(l.buf, '\n')
		if i < 0 {
			break
		}
		line := l.buf[:i]
		line = bytes.TrimSuffix(line, []byte("\r"))
		out := make([]byte, 0, len(line)+1)
		out = append(out, line...)
		out = append(out, '\n')
		if l.W == os.Stdout {
			outMu.Lock()
			_, _ = l.W.Write(out)
			outMu.Unlock()
		} else {
			_, _ = l.W.Write(out)
		}
		l.buf = l.buf[i+1:]
	}
	return len(p), nil
}

// Flush writes a trailing partial line, if the child left one.
func (l *LineWriter) Flush() {
	l.mu.Lock()
	rest := bytes.TrimSuffix(l.buf, []byte("\r"))
	l.buf = nil
	l.mu.Unlock()
	if len(rest) > 0 {
		_, _ = l.Write(append(rest, '\n'))
	}
}
