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

// rbhelper stands in for a separate engine invocation in proc's tests: one
// process starts a server and exits, and a later one stops it knowing only
// what a state file would hold (pid and start time).
//
//	rbhelper start <dir> <log> <command>   prints "<pid> <started>"
//	rbhelper stop <pid> <started> <graceMs>
package main

import (
	"fmt"
	"os"
	"strconv"
	"time"

	"github.com/aosmcleod/runbranch/engine/internal/proc"
)

func main() {
	if len(os.Args) < 2 {
		fail(fmt.Errorf("usage: rbhelper start|stop ..."))
	}
	switch os.Args[1] {
	case "start":
		h, err := proc.Start(proc.Spec{Command: os.Args[4], Dir: os.Args[2], Env: os.Environ(), LogPath: os.Args[3]})
		if err != nil {
			fail(err)
		}
		fmt.Println(h.PID, h.Started)
	case "stop":
		pid, _ := strconv.Atoi(os.Args[2])
		started, _ := strconv.ParseInt(os.Args[3], 10, 64)
		ms, _ := strconv.Atoi(os.Args[4])
		if err := proc.StopTree(proc.Handle{PID: pid, Started: started}, time.Duration(ms)*time.Millisecond); err != nil {
			fail(err)
		}
		fmt.Println("stopped")
	}
}

func fail(err error) {
	fmt.Fprintln(os.Stderr, err)
	os.Exit(1)
}
