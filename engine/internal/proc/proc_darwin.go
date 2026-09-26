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

import (
	"bufio"
	"bytes"
	"fmt"
	"os/exec"
	"strings"

	"golang.org/x/sys/unix"
)

const szomb = 5 // SZOMB in <sys/proc.h>

func fromKinfo(k *unix.KinfoProc) uproc {
	return uproc{
		pid:     int(k.Proc.P_pid),
		ppid:    int(k.Eproc.Ppid),
		pgid:    int(k.Eproc.Pgid),
		started: int64(k.Proc.P_starttime.Sec)*1_000_000 + int64(k.Proc.P_starttime.Usec),
		zombie:  k.Proc.P_stat == szomb,
	}
}

// procInfo reads one process through sysctl kern.proc.pid, which answers for
// every user's processes and costs no fork, unlike `ps -o lstart=`.
func procInfo(pid int) (uproc, error) {
	k, err := unix.SysctlKinfoProc("kern.proc.pid", pid)
	if err != nil {
		return uproc{}, err
	}
	// A pid with no process comes back as an empty record, not an error.
	if int(k.Proc.P_pid) != pid {
		return uproc{}, fmt.Errorf("no process %d", pid)
	}
	return fromKinfo(k), nil
}

func processTable() (map[int]uproc, error) {
	all, err := unix.SysctlKinfoProcSlice("kern.proc.all")
	if err != nil {
		return nil, err
	}
	out := make(map[int]uproc, len(all))
	for i := range all {
		p := fromKinfo(&all[i])
		out[p.pid] = p
	}
	return out, nil
}

// cwd asks lsof, which is on every Mac. The alternative, proc_pidinfo with
// PROC_PIDVNODEPATHINFO, needs cgo, and the engine is built without it.
func cwd(pid int) (string, error) {
	out, err := exec.Command("lsof", "-a", "-p", fmt.Sprint(pid), "-d", "cwd", "-Fn").Output()
	if err != nil && len(out) == 0 {
		return "", fmt.Errorf("pid %d: working directory unknown", pid)
	}
	sc := bufio.NewScanner(bytes.NewReader(out))
	for sc.Scan() {
		if line := sc.Text(); strings.HasPrefix(line, "n") && len(line) > 1 {
			return line[1:], nil
		}
	}
	return "", fmt.Errorf("pid %d: working directory unknown", pid)
}

func openURL(url string) error { return exec.Command("open", url).Run() }
