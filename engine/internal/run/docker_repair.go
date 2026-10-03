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

package run

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"time"

	"github.com/aosmcleod/runbranch/engine/internal/config"
	"github.com/aosmcleod/runbranch/engine/internal/ui"
)

// DockerRepair clears the stale-socket failure (see docker.go) the one way
// found to work: quit Docker Desktop, shut WSL down so nothing holds the
// socket files, rename the folders holding them aside, and start it again.
//
// Only ever on request. `wsl --shutdown` stops every WSL distro on the
// machine, not just Docker's, which is not something a run may do to someone
// on its own. A run that meets the failure names this command instead.
//
// Folders are renamed, never deleted: Windows will not delete the socket
// reparse points either, and the old folders are harmless to leave.
func DockerRepair() {
	if runtime.GOOS != "windows" {
		ui.Die("docker-repair is for Docker Desktop on Windows, where killed sockets cannot be reused.",
			ui.DockerStartFix())
	}
	ui.Step("Docker Desktop repair")

	ui.Info("quitting Docker Desktop")
	for _, image := range []string{"Docker Desktop.exe", "com.docker.backend.exe", "com.docker.build.exe"} {
		_ = exec.Command("taskkill", "/F", "/T", "/IM", image).Run() // not running is fine
	}

	ui.Warn("wsl --shutdown — this stops every WSL distro, not only Docker's")
	if err := exec.Command("wsl", "--shutdown").Run(); err != nil {
		ui.Warn("wsl --shutdown did not succeed (" + err.Error() + "); carrying on")
	}

	dirs := socketDirsToClear(time.Now().Add(-24 * time.Hour))
	moved, err := renameAside(dirs, time.Now().Format("20060102-150405"))
	for _, m := range moved {
		ui.OK("set aside  " + m)
	}
	if err != nil {
		ui.Die(err.Error()+"\n\nSomething still has it open. Quit Docker Desktop from its tray icon if it is still there.",
			config.Self+" docker-repair")
	}
	if len(moved) == 0 {
		ui.Info("no socket folders to set aside")
	}

	if err := startDockerDesktop(); err != nil {
		ui.Die("Could not start Docker Desktop again: "+err.Error()+".", ui.DockerStartFix())
	}
	ui.Info("starting Docker Desktop, and waiting for it to answer")
	waitForDocker(time.Now())
	if len(moved) > 0 {
		ui.Info("the old folders are kept as *.stale-<time>; delete them whenever you like")
	}
}

// socketDirsToClear is the two folders Docker Desktop keeps its sockets in,
// plus any other its log has named since t, so a third does not need a code
// change. Only folders inside %LOCALAPPDATA%, and never Docker's own folder,
// whose settings and data would go with it.
func socketDirsToClear(since time.Time) []string {
	local := os.Getenv("LOCALAPPDATA")
	candidates := append([]string{
		filepath.Join(local, "Docker", "run"),
		filepath.Join(local, "docker-secrets-engine"),
	}, staleSockets(since)...)
	seen := map[string]bool{}
	var out []string
	for _, d := range candidates {
		key := strings.ToLower(filepath.Clean(d))
		if seen[key] || !safeToSetAside(local, d) {
			continue
		}
		seen[key] = true
		out = append(out, d)
	}
	return out
}

// safeToSetAside is true for a folder strictly inside local that is not
// local\Docker itself.
func safeToSetAside(local, dir string) bool {
	if local == "" {
		return false
	}
	rel, err := filepath.Rel(filepath.Clean(local), filepath.Clean(dir))
	if err != nil || rel == "." || strings.HasPrefix(rel, "..") || filepath.IsAbs(rel) {
		return false
	}
	return !strings.EqualFold(rel, "Docker")
}

// renameAside moves each folder that exists to <folder>.stale-<stamp>,
// retrying briefly: a process just killed can hold one for a moment.
func renameAside(dirs []string, stamp string) ([]string, error) {
	var moved []string
	for _, d := range dirs {
		if _, err := os.Stat(d); err != nil {
			continue
		}
		to := d + ".stale-" + stamp
		var err error
		for i := 0; i < 10; i++ {
			if err = os.Rename(d, to); err == nil {
				break
			}
			time.Sleep(500 * time.Millisecond)
		}
		if err != nil {
			return moved, fmt.Errorf("could not set %s aside: %v", d, err)
		}
		moved = append(moved, to)
	}
	return moved, nil
}
