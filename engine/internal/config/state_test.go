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
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"

	"github.com/aosmcleod/runbranch/engine/internal/proc"
)

func stateProject(t *testing.T) *Project {
	dir := t.TempDir()
	return &Project{vals: map[string]string{}, WorkRoot: dir, StateFile: filepath.Join(dir, "state")}
}

// A file runbranch.sh wrote: no STARTS line. It must read, and restore the
// run's offset and mode over whatever the project had.
func TestReadsABashStateFile(t *testing.T) {
	p := stateProject(t)
	os.WriteFile(p.StateFile, []byte("REF=feature/one\nWORKTREE=/x/wt\nPRESET=web\nTARGETS=web api\nPIDS=123 456\nPORT_OFFSET=2\nIN_PLACE=1\nSTARTED=2026-09-24 10:00:00\nEPOCH=1790000000\n"), 0o644)
	s := p.LoadState()
	if s == nil {
		t.Fatal("no state read")
	}
	if s.Ref != "feature/one" || s.Worktree != "/x/wt" || s.Preset != "web" || s.Started != "2026-09-24 10:00:00" || s.Epoch != "1790000000" {
		t.Errorf("fields: %+v", s)
	}
	if !reflect.DeepEqual(s.Targets, []string{"web", "api"}) || !reflect.DeepEqual(s.PIDs, []string{"123", "456"}) {
		t.Errorf("zip: %v %v", s.Targets, s.PIDs)
	}
	if p.PortOffset != 2 || !p.InPlace {
		t.Errorf("offset/mode not restored: %d %v", p.PortOffset, p.InPlace)
	}
	if h := s.Handle(1); h.PID != 456 || h.Started != 0 {
		t.Errorf("handle without STARTS = %+v", h)
	}
}

// A file this engine writes: the bash keys, in the bash order, with STARTS
// last where runbranch.sh ignores it.
func TestWritesAStateFileBashCanRead(t *testing.T) {
	p := stateProject(t)
	p.PortOffset = 1
	if err := p.WriteState("main", "/x/wt", "web", []string{"web"}, []proc.Handle{{PID: 77, Started: 1790000001}}); err != nil {
		t.Fatal(err)
	}
	b, _ := os.ReadFile(p.StateFile)
	var keys []string
	for _, line := range strings.Split(strings.TrimSuffix(string(b), "\n"), "\n") {
		k, _, _ := strings.Cut(line, "=")
		keys = append(keys, k)
	}
	want := []string{"REF", "WORKTREE", "PRESET", "TARGETS", "PIDS", "PORT_OFFSET", "IN_PLACE", "STARTED", "EPOCH", "STARTS"}
	if !reflect.DeepEqual(keys, want) {
		t.Errorf("keys %v, want %v", keys, want)
	}
	if !strings.Contains(string(b), "\nPORT_OFFSET=1\nIN_PLACE=0\n") || strings.Contains(string(b), "\r") {
		t.Errorf("state:\n%q", b)
	}
	p.PortOffset = 0
	s := p.LoadState()
	if h := s.Handle(0); h.PID != 77 || h.Started != 1790000001 || p.PortOffset != 1 {
		t.Errorf("round trip: %+v offset %d", h, p.PortOffset)
	}
}
