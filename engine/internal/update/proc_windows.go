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

package update

import (
	"os/exec"
	"syscall"
	"time"

	"golang.org/x/sys/windows"
)

const supported = true

// waitExit waits for the app to quit, and ends it if it will not.
//
// A handle rather than polling the pid: once we hold it, the pid cannot be
// reused under us, so the process ended after the wait is certainly the one
// that was asked about. And the app is still running when this starts — it
// waits for `started` before quitting — so the handle is taken on the right
// process in the first place.
func waitExit(pid int, wait time.Duration) exitResult {
	h, err := windows.OpenProcess(windows.SYNCHRONIZE|windows.PROCESS_TERMINATE|windows.PROCESS_QUERY_LIMITED_INFORMATION, false, uint32(pid))
	if err != nil {
		return gone
	}
	defer windows.CloseHandle(h)
	if ev, _ := windows.WaitForSingleObject(h, uint32(wait/time.Millisecond)); ev == windows.WAIT_OBJECT_0 {
		return exited
	}
	if windows.TerminateProcess(h, 1) != nil {
		return stuck
	}
	// Until the process is really gone, its exe and DLLs are still mapped
	// and the folder still cannot be renamed.
	_, _ = windows.WaitForSingleObject(h, 5000)
	return ended
}

// start opens the app again and does not wait for it.
//
// Its own process group, and out of this helper's job when the job allows it,
// so whatever started the old app cannot take the new one down with the
// helper. CREATE_NO_WINDOW is for the tests, whose stand-in app is a console
// program: Windows ignores it for a GUI app like Runbranch.exe, and without
// it the stand-in would open a console window on the desktop of whoever runs
// them.
func start(exe, dir string) error {
	flags := uint32(windows.CREATE_NEW_PROCESS_GROUP | windows.CREATE_NO_WINDOW)
	run := func(f uint32) (*exec.Cmd, error) {
		c := exec.Command(exe)
		c.Dir = dir
		c.SysProcAttr = &syscall.SysProcAttr{CreationFlags: f}
		return c, c.Start()
	}
	c, err := run(flags | windows.CREATE_BREAKAWAY_FROM_JOB)
	if err != nil {
		// A job that forbids breakaway refuses the whole CreateProcess.
		if c, err = run(flags); err != nil {
			return err
		}
	}
	return c.Process.Release()
}
