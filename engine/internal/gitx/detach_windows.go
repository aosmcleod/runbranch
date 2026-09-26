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

package gitx

import (
	"os/exec"
	"syscall"

	"golang.org/x/sys/windows"
)

// spawnDetached starts this engine again for a background job and does not
// wait for it. Its standard handles are the null device, never ours: a child
// holding the app's pipe open would make the app wait for it.
//
// CREATE_NO_WINDOW, never DETACHED_PROCESS or CREATE_NEW_CONSOLE. A console
// program started without a console of its own makes Windows give it a new,
// visible one — an empty terminal window popping up on every stale listing.
// CREATE_NO_WINDOW gives it a console nobody sees, and the new process group
// keeps a Ctrl+C in the user's terminal from reaching it.
//
// Out of the caller's job too, when the job allows it, so an app that kills
// its job on exit does not take a half-written refresh with it. A job that
// forbids breakaway refuses the whole CreateProcess, hence the retry.
func spawnDetached(exe string, args ...string) error {
	flags := uint32(windows.CREATE_NO_WINDOW | windows.CREATE_NEW_PROCESS_GROUP)
	start := func(f uint32) (*exec.Cmd, error) {
		cmd := exec.Command(exe, args...)
		cmd.SysProcAttr = &syscall.SysProcAttr{CreationFlags: f, HideWindow: true}
		return cmd, cmd.Start()
	}
	cmd, err := start(flags | windows.CREATE_BREAKAWAY_FROM_JOB)
	if err != nil {
		if cmd, err = start(flags); err != nil {
			return err
		}
	}
	return cmd.Process.Release()
}
