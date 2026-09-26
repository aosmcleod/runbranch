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

package config

import (
	"fmt"
	"os"
	"strconv"
	"strings"
	"time"

	"github.com/aosmcleod/runbranch/engine/internal/proc"
)

// State is what a run leaves in <RB_HOME>/<project>/state.
//
// The format is the bash engine's, byte for byte, so a run started by either
// engine can be stopped by the other: KEY=VALUE lines, split at the first
// `=`, unknown keys ignored. The one addition is STARTS, the creation time of
// each pid, appended last where the bash engine ignores it. It is what stops
// a pid reused after a reboot being mistaken for a server.
type State struct {
	Ref, Worktree, Preset string
	Targets               []string
	PIDs                  []string // as written; TARGETS and PIDS zip by order
	Starts                []int64
	Started               string // YYYY-MM-DD HH:MM:SS, local time
	Epoch                 string
	InPlace               bool
}

// Handle is the process handle for the i-th pid, with its start time when
// the file recorded one.
func (s *State) Handle(i int) proc.Handle {
	h := proc.Handle{}
	if i < len(s.PIDs) {
		h.PID, _ = strconv.Atoi(s.PIDs[i])
	}
	if i < len(s.Starts) {
		h.Started = s.Starts[i]
	}
	return h
}

// Alive reports whether the i-th pid is still running.
func (s *State) Alive(i int) bool {
	h := s.Handle(i)
	return h.PID > 0 && proc.Alive(h)
}

// AnyAlive is "running": the file exists and at least one pid is alive.
func (s *State) AnyAlive() bool {
	for i := range s.PIDs {
		if s.Alive(i) {
			return true
		}
	}
	return false
}

// LoadState reads the state file, or returns nil when there is none.
//
// It restores the run's PORT_OFFSET and IN_PLACE into the project, so stop,
// status and health look at the ports the run is really on rather than the
// declared ones. It deliberately never RESETS them: the caller may already
// have asked for a mode, and resetting here silently discarded the request —
// it cost the port offset once and then --in-place a second time.
func (p *Project) LoadState() *State {
	b, err := os.ReadFile(p.StateFile)
	if err != nil {
		return nil
	}
	s := &State{Epoch: "0"}
	for _, line := range strings.Split(strings.ReplaceAll(string(b), "\r\n", "\n"), "\n") {
		key, val, _ := strings.Cut(line, "=")
		switch key {
		case "REF":
			s.Ref = val
		case "WORKTREE":
			s.Worktree = val
		case "PRESET":
			s.Preset = val
		case "TARGETS":
			s.Targets = strings.Fields(val)
		case "PIDS":
			s.PIDs = strings.Fields(val)
		case "STARTED":
			s.Started = val
		case "EPOCH":
			s.Epoch = val
		case "STARTS":
			for _, f := range strings.Fields(val) {
				n, _ := strconv.ParseInt(f, 10, 64)
				s.Starts = append(s.Starts, n)
			}
		case "PORT_OFFSET":
			p.PortOffset = atoi(val)
		case "IN_PLACE":
			p.InPlace = val == "1"
			s.InPlace = p.InPlace
		}
	}
	return s
}

// Running is demo_running: the state, when a pid in it is alive.
func (p *Project) Running() (*State, bool) {
	s := p.LoadState()
	if s == nil {
		return nil, false
	}
	return s, s.AnyAlive()
}

// WriteState records a run. Written after every server has started and
// before any health wait, so a crash mid-wait leaves state that reclaim can
// clean up.
func (p *Project) WriteState(ref, worktree, preset string, targets []string, handles []proc.Handle) error {
	if err := os.MkdirAll(p.WorkRoot, 0o755); err != nil {
		return err
	}
	pids := make([]string, len(handles))
	starts := make([]string, len(handles))
	for i, h := range handles {
		pids[i] = strconv.Itoa(h.PID)
		starts[i] = strconv.FormatInt(h.Started, 10)
	}
	inPlace := "0"
	if p.InPlace {
		inPlace = "1"
	}
	now := time.Now()
	var b strings.Builder
	fmt.Fprintf(&b, "REF=%s\n", ref)
	fmt.Fprintf(&b, "WORKTREE=%s\n", worktree)
	fmt.Fprintf(&b, "PRESET=%s\n", preset)
	fmt.Fprintf(&b, "TARGETS=%s\n", strings.Join(targets, " "))
	fmt.Fprintf(&b, "PIDS=%s\n", strings.Join(pids, " "))
	fmt.Fprintf(&b, "PORT_OFFSET=%d\n", p.PortOffset)
	fmt.Fprintf(&b, "IN_PLACE=%s\n", inPlace)
	fmt.Fprintf(&b, "STARTED=%s\n", now.Format("2006-01-02 15:04:05"))
	fmt.Fprintf(&b, "EPOCH=%d\n", now.Unix())
	fmt.Fprintf(&b, "STARTS=%s\n", strings.Join(starts, " "))
	return os.WriteFile(p.StateFile, []byte(b.String()), 0o644)
}

// ClearState removes the state file.
func (p *Project) ClearState() { _ = os.Remove(p.StateFile) }

// HasState reports whether a state file exists, live or not.
func (p *Project) HasState() bool {
	_, err := os.Stat(p.StateFile)
	return err == nil
}
