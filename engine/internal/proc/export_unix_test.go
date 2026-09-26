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

//go:build !windows

package proc

// Internals the tests in package proc_test need (they live outside the
// package because they use ports, and ports imports proc).

// TreeOf is the root, every descendant and every member of the root's group,
// each with its start time in microseconds.
func TreeOf(h Handle) (map[int]int64, error) {
	t, err := processTable()
	if err != nil {
		return nil, err
	}
	out := map[int]int64{}
	for _, p := range t {
		if p.pgid == h.PID && !p.zombie {
			out[p.pid] = p.started
		}
	}
	if r, ok := t[h.PID]; ok && !r.zombie {
		out[r.pid] = r.started
		children := map[int][]uproc{}
		for _, p := range t {
			children[p.ppid] = append(children[p.ppid], p)
		}
		queue := []int{r.pid}
		for len(queue) > 0 {
			n := queue[0]
			queue = queue[1:]
			for _, c := range children[n] {
				if _, seen := out[c.pid]; !seen && !c.zombie {
					out[c.pid] = c.started
					queue = append(queue, c.pid)
				}
			}
		}
	}
	return out, nil
}

// Still reports whether pid is still the process that started at started.
func Still(pid int, started int64) bool {
	p, err := procInfo(pid)
	return err == nil && !p.zombie && p.started == started
}
