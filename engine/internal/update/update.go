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

// Package update swaps a downloaded Runbranch in for the running one and
// starts it again: `runbranch install-update`, the Windows counterpart of
// tools/install-update.sh (spec F10, F17).
//
// It replaced a PowerShell script because script policy is often locked down
// on work machines, and an updater that cannot run is worse than none: the
// app has already downloaded the new version by the time it finds out.
//
// The app (Updates.cs) starts it hidden, immediately before it quits, from a
// copy of the engine in %TEMP% — never bin\runbranch.exe in place, because
// that file is inside the folder being replaced, and Windows will not rename
// a folder while a program inside it is running. The app has already checked
// the download against GitHub's checksum and extracted it beside the
// installed folder, so every move here is a rename on one volume. This does
// the part that cannot be undone, so every failure puts the old folder back
// and starts it again.
package update

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"github.com/aosmcleod/runbranch/engine/internal/pathx"
)

// Supported says whether this OS updates this way. The Mac keeps
// tools/install-update.sh, which also has a disk image to detach.
const Supported = supported

// App is the program in an install folder that is swapped and started.
const App = "Runbranch.exe"

// Engine is where the engine sits in an install folder (make-app.ps1).
var Engine = filepath.Join("bin", "runbranch.exe")

// Options is one swap.
type Options struct {
	PID    int    // the app, which is quitting
	Source string // the new folder
	Target string // the installed folder

	// Staging is the folder Source was extracted into, removed at the end.
	Staging string
	// Work is the download folder in %TEMP%, removed at the end. The app
	// waits for a file called `started` to appear in it before it quits.
	Work string
	// Log defaults to %LOCALAPPDATA%\Runbranch\update.log.
	Log string
	// NoRelaunch swaps but does not start what was swapped in: for tests.
	NoRelaunch bool

	// For tests; zero means the real values.
	WaitForExit time.Duration // how long the app gets to quit: 10 s
	Pause       time.Duration // between retries of a rename: 250 ms
}

// Usage is the subcommand's synopsis, for the usage text and its errors.
const Usage = "install-update <pid> <new-folder> <install-folder> [--staging <dir>] [--work <dir>] [--log <file>] [--no-relaunch]"

// ParseArgs reads the subcommand's arguments, after `install-update`.
func ParseArgs(args []string) (Options, error) {
	var o Options
	var pos []string
	for i := 0; i < len(args); i++ {
		a := args[i]
		value := func() (string, error) {
			if i+1 >= len(args) {
				return "", fmt.Errorf("%s needs a value", a)
			}
			i++
			return args[i], nil
		}
		var err error
		switch a {
		case "--staging":
			o.Staging, err = value()
		case "--work":
			o.Work, err = value()
		case "--log":
			o.Log, err = value()
		case "--no-relaunch":
			o.NoRelaunch = true
		default:
			if strings.HasPrefix(a, "--") {
				return o, fmt.Errorf("unknown option %s", a)
			}
			pos = append(pos, a)
		}
		if err != nil {
			return o, err
		}
	}
	if len(pos) != 3 {
		return o, errors.New("wants a pid, the new folder and the install folder")
	}
	pid, err := strconv.Atoi(pos[0])
	if err != nil || pid <= 0 {
		return o, fmt.Errorf("%q is not a process id", pos[0])
	}
	o.PID, o.Source, o.Target = pid, pos[1], pos[2]
	return o, nil
}

// DefaultLog is where a swap writes what it did. Not %TEMP%, where the
// script's log went: the one place anyone looks for why an update did not
// happen should survive a disk clean-up, and sit where the app keeps its own.
func DefaultLog() string {
	base := os.Getenv("LOCALAPPDATA")
	if base == "" {
		base = os.TempDir()
	}
	return filepath.Join(base, "Runbranch", "update.log")
}

// swap is one attempt, with its log.
type swap struct {
	Options
	log    *os.File
	backup string
}

// say writes one line per step. A swap that goes wrong leaves no other
// trace: the app that could have reported it is the thing being replaced,
// and the app that comes back has no idea an update was attempted.
func (s *swap) say(format string, a ...any) {
	line := time.Now().Format("15:04:05") + " " + fmt.Sprintf(format, a...) + "\n"
	if s.log != nil {
		_, _ = s.log.WriteString(line)
	}
	_, _ = os.Stdout.WriteString(line)
}

// Install does the swap and returns the exit code: 0 swapped, 1 not.
func Install(o Options) int {
	if o.WaitForExit == 0 {
		o.WaitForExit = 10 * time.Second
	}
	if o.Pause == 0 {
		o.Pause = 250 * time.Millisecond
	}
	if o.Log == "" {
		o.Log = DefaultLog()
	}
	o.Source = clean(o.Source)
	o.Target = clean(o.Target)
	o.Staging = clean(o.Staging)
	o.Work = clean(o.Work)

	s := &swap{Options: o, backup: fmt.Sprintf("%s.replaced-%d", o.Target, os.Getpid())}
	// Truncated per attempt rather than appended to for ever: what anyone
	// wants from this file is why the update they just tried did not happen.
	_ = os.MkdirAll(filepath.Dir(o.Log), 0o755)
	if f, err := os.Create(o.Log); err == nil {
		s.log = f
		defer f.Close()
	}
	s.say("swapping %s for %s (pid %d)", o.Target, o.Source, o.PID)

	// Checked before saying it started, so a download that is not an app
	// stops here with the app still open and able to say so, rather than
	// after it has quit and nothing is left to report it.
	if why := s.refuse(); why != "" {
		s.say("FAILED: %s; nothing changed", why)
		return 1
	}

	// Tell the app it can go. Until this exists it keeps running, so a
	// helper that never started cannot leave nothing running and nothing
	// installed.
	if o.Work != "" {
		if err := os.WriteFile(filepath.Join(o.Work, "started"), nil, 0o644); err != nil {
			s.say("FAILED to tell the app it can quit: %v; nothing changed", err)
			return 1
		}
	}

	switch waitExit(o.PID, o.WaitForExit) {
	case exited:
		s.say("it exited")
	case gone:
		s.say("it had already exited")
	case ended:
		// It is our own app and it asked for this; ten seconds means it is
		// wedged on a dialog rather than quitting.
		s.say("still running after %s; ended it", o.WaitForExit)
	case stuck:
		s.say("still running after %s and could not be ended; trying anyway", o.WaitForExit)
	}

	// Aside, not deleted. Renamed in the same folder, so it is instant and
	// cannot half-happen, and it is the only thing standing between a failed
	// move and no Runbranch at all.
	if err := s.move(o.Target, s.backup, 40); err != nil {
		s.say("  %v", err)
		s.say("FAILED to move the installed folder aside; nothing changed")
		return s.fail()
	}
	s.say("moved the installed folder aside to %s", s.backup)

	if err := s.move(o.Source, o.Target, 8); err != nil {
		s.say("  %v", err)
		s.say("FAILED to move the new folder in; putting the old one back")
		return s.rollBack()
	}
	if !pathx.IsFile(filepath.Join(o.Target, App)) {
		s.say("FAILED: the new folder has no %s after the move; putting the old one back", App)
		return s.rollBack()
	}

	// Project configs never live in the install folder on Windows — the
	// engine keeps them in %USERPROFILE%\.runbranch\projects from the start —
	// so unlike the Mac's script there is nothing to carry out of the old
	// copy before it goes.
	if !s.remove(s.backup) {
		s.say("swapped, but could not remove %s; delete it when convenient", s.backup)
	}
	s.cleanup()
	s.say("swapped; reopening")
	s.relaunch()
	return 0
}

// refuse is why this swap must not start, or "".
func (s *swap) refuse() string {
	switch {
	case s.Source == "" || s.Target == "":
		return "no folder to swap"
	case !pathx.IsFile(filepath.Join(s.Source, App)):
		return fmt.Sprintf("%s holds no %s", s.Source, App)
	case !pathx.IsFile(filepath.Join(s.Source, Engine)):
		return fmt.Sprintf("%s holds no engine (%s)", s.Source, Engine)
	case !pathx.IsDir(s.Target):
		return fmt.Sprintf("%s is not a folder", s.Target)
	// Moving the installed folder aside would take the new one with it.
	case pathx.Within(s.Source, s.Target) || pathx.Within(s.Target, s.Source):
		return "the new folder and the installed one overlap"
	}
	return ""
}

// move is a directory rename, retried. Windows refuses to rename a folder
// while any file in it is open or running — the app for a moment after its
// process ends, an engine call it had started, an editor with a log open.
// Most of those let go within seconds, so the answer is to wait a little,
// not to give up.
func (s *swap) move(from, to string, tries int) error {
	var err error
	for i := 1; i <= tries; i++ {
		if err = os.Rename(from, to); err == nil {
			return nil
		}
		if i < tries {
			time.Sleep(s.Pause)
		}
	}
	return err
}

// remove deletes a folder, retried for the same reason as move.
func (s *swap) remove(dir string) bool {
	if dir == "" || !pathx.Exists(dir) {
		return true
	}
	for i := 0; i < 20; i++ {
		if pathx.RemoveAll(dir) == nil && !pathx.Exists(dir) {
			return true
		}
		time.Sleep(s.Pause)
	}
	return false
}

// rollBack puts the old folder back after a failed move in, and starts it.
func (s *swap) rollBack() int {
	// Only when the old folder is safely aside: then anything at Target is a
	// half-arrived new one, never the only copy.
	if pathx.Exists(s.Target) && pathx.IsDir(s.backup) {
		s.remove(s.Target)
	}
	if err := s.move(s.backup, s.Target, 40); err != nil {
		s.say("  %v", err)
		s.say("FAILED to put it back as well; the old folder is at %s", s.backup)
	}
	return s.fail()
}

// fail cleans up and starts whatever is installed again.
func (s *swap) fail() int {
	s.cleanup()
	s.relaunch()
	return 1
}

// cleanup removes the extraction folder and the download.
//
// Leashed, like every other delete in the engine: a folder that holds the
// installed app, or the copy aside, is never removed as "staging", whatever
// the app passed. A mistake in the hand-off must not be able to delete the
// folder Runbranch lives in.
func (s *swap) cleanup() {
	for _, dir := range []string{s.Staging, s.Work} {
		if dir == "" || !pathx.Exists(dir) {
			continue
		}
		if pathx.Within(s.Target, dir) || pathx.Within(s.backup, dir) {
			s.say("not removing %s: it holds the installed folder", dir)
			continue
		}
		if dir == s.Work {
			s.clearWork()
			continue
		}
		if !s.remove(dir) {
			s.say("could not remove %s", dir)
		}
	}
}

// clearWork empties the download folder of everything but this program,
// which is running from it and so cannot be deleted until it exits. The app
// sweeps what is left the next time it starts (Updates.cs).
func (s *swap) clearWork() {
	self, _ := os.Executable()
	entries, err := os.ReadDir(s.Work)
	if err != nil {
		return
	}
	kept := false
	for _, e := range entries {
		path := filepath.Join(s.Work, e.Name())
		if self != "" && pathx.Equal(path, self) {
			kept = true
			continue
		}
		if !s.remove(path) {
			s.say("could not remove %s", path)
		}
	}
	if !kept {
		_ = os.Remove(s.Work)
	}
}

func (s *swap) relaunch() {
	if s.NoRelaunch {
		s.say("not reopening (--no-relaunch)")
		return
	}
	exe := filepath.Join(s.Target, App)
	if !pathx.IsFile(exe) {
		s.say("nothing to reopen at %s", exe)
		return
	}
	if err := start(exe, s.Target); err != nil {
		s.say("could not reopen %s: %v", exe, err)
	}
}

func clean(p string) string {
	if p == "" {
		return ""
	}
	return pathx.Native(p)
}

// What happened to the app while it was waited for.
type exitResult int

const (
	exited exitResult = iota // it quit while we waited
	gone                     // it had quit before we looked
	ended                    // it did not quit, so it was ended
	stuck                    // it did not quit and could not be ended
)
