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

package proc

// Internals the tests in package proc_test need. The tests live outside the
// package because they use ports, and ports imports proc.

import (
	"fmt"

	"golang.org/x/sys/windows"
)

// TreePIDs is every live process in h's tree.
func TreePIDs(h Handle) (map[int]bool, error) {
	t, err := newTree(h)
	if err != nil {
		return nil, err
	}
	live, err := t.live()
	if err != nil {
		return nil, err
	}
	out := map[int]bool{}
	for _, id := range live {
		out[id.pid] = true
	}
	return out, nil
}

// KillOne force-kills a single process the test started and waits for it.
func KillOne(pid int) error {
	snap, err := processes()
	if err != nil {
		return err
	}
	p, ok := snap[pid]
	if !ok {
		return fmt.Errorf("pid %d is gone", pid)
	}
	ph := terminateIdent(ident{pid, p.created})
	if ph == 0 {
		return fmt.Errorf("pid %d could not be terminated", pid)
	}
	defer windows.CloseHandle(ph)
	windows.WaitForSingleObject(ph, 5000)
	return nil
}

// ProcessNames maps every pid on the machine to its image name.
func ProcessNames() (map[int]string, error) {
	snap, err := processes()
	if err != nil {
		return nil, err
	}
	out := make(map[int]string, len(snap))
	for pid, p := range snap {
		out[pid] = p.name
	}
	return out, nil
}

var (
	GroupID    = groupID
	SameSecond = sameSecond
)
