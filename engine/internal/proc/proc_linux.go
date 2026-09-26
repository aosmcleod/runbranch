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

// Linux is not a product target. This exists so the engine builds, and its
// unix logic is exercised, on a Linux CI runner.

import (
	"fmt"
	"os"
	"os/exec"
	"strconv"
	"strings"
)

// clockTicks is USER_HZ, the unit of /proc's start times. It is 100 on every
// mainstream kernel, and reading it properly would need cgo.
const clockTicks = 100

func bootTime() (int64, error) {
	b, err := os.ReadFile("/proc/stat")
	if err != nil {
		return 0, err
	}
	for _, line := range strings.Split(string(b), "\n") {
		if strings.HasPrefix(line, "btime ") {
			return strconv.ParseInt(strings.TrimSpace(line[6:]), 10, 64)
		}
	}
	return 0, fmt.Errorf("no btime in /proc/stat")
}

func procInfo(pid int) (uproc, error) {
	boot, err := bootTime()
	if err != nil {
		return uproc{}, err
	}
	return readStat(pid, boot)
}

func readStat(pid int, boot int64) (uproc, error) {
	b, err := os.ReadFile(fmt.Sprintf("/proc/%d/stat", pid))
	if err != nil {
		return uproc{}, err
	}
	// The command name is in parentheses and may contain anything, spaces
	// and parentheses included, so fields are counted from the last ')'.
	s := string(b)
	i := strings.LastIndexByte(s, ')')
	if i < 0 {
		return uproc{}, fmt.Errorf("pid %d: unreadable stat", pid)
	}
	f := strings.Fields(s[i+1:]) // f[0] is field 3, the state
	if len(f) < 20 {
		return uproc{}, fmt.Errorf("pid %d: short stat", pid)
	}
	ppid, _ := strconv.Atoi(f[1])
	pgid, _ := strconv.Atoi(f[2])
	ticks, _ := strconv.ParseInt(f[19], 10, 64)
	return uproc{
		pid:     pid,
		ppid:    ppid,
		pgid:    pgid,
		started: boot*1_000_000 + ticks*(1_000_000/clockTicks),
		zombie:  f[0] == "Z",
	}, nil
}

func processTable() (map[int]uproc, error) {
	boot, err := bootTime()
	if err != nil {
		return nil, err
	}
	entries, err := os.ReadDir("/proc")
	if err != nil {
		return nil, err
	}
	out := make(map[int]uproc, len(entries))
	for _, e := range entries {
		pid, err := strconv.Atoi(e.Name())
		if err != nil {
			continue
		}
		if p, err := readStat(pid, boot); err == nil {
			out[pid] = p
		}
	}
	return out, nil
}

func cwd(pid int) (string, error) { return os.Readlink(fmt.Sprintf("/proc/%d/cwd", pid)) }

func openURL(url string) error { return exec.Command("xdg-open", url).Start() }
