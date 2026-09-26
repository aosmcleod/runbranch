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

package ui

import (
	"fmt"
	"path/filepath"
	"runtime"
)

// Every failure names the command that fixes it, so a fix has to be a command
// that exists on the machine reading it. These are the ones that differ.

const isWindows = runtime.GOOS == "windows"

// EditFix opens a file in a text editor.
func EditFix(file string) string {
	if isWindows {
		return fmt.Sprintf("notepad \"%s\"", file)
	}
	return fmt.Sprintf("open -t '%s'", file)
}

// OpenFix opens a file with whatever handles it.
func OpenFix(file string) string {
	if isWindows {
		return fmt.Sprintf("notepad \"%s\"", file)
	}
	return "open " + file
}

// GitInstallFix installs git.
func GitInstallFix() string {
	if isWindows {
		return "winget install Git.Git"
	}
	return "xcode-select --install"
}

// DockerStartFix starts the Docker daemon.
func DockerStartFix() string {
	if isWindows {
		return "start Docker Desktop from the Start menu    # then wait for the whale icon to settle"
	}
	return "open -a Docker    # then wait for the whale icon to settle"
}

// KillCmd ends a process politely.
func KillCmd(pid string) string {
	if isWindows {
		return "taskkill /PID " + pid
	}
	return "kill " + pid
}

// ForceKillCmd ends a process that would not go.
func ForceKillCmd(pid string) string {
	if isWindows {
		return "taskkill /F /PID " + pid
	}
	return "kill -9 " + pid
}

// AppFix starts the real front end.
func AppFix(selfDir string) string {
	if isWindows {
		return fmt.Sprintf("\"%s\"", filepath.Join(selfDir, "Runbranch.exe"))
	}
	return fmt.Sprintf("open '%s/Runbranch.app'", selfDir)
}

// SearchedDirs is what require_cmd says it already looked through.
func SearchedDirs() string {
	if isWindows {
		return `The launcher already looks in WinGet's Links folder, Git, Docker Desktop's
bin, npm, pnpm, scoop and mise's shims, re-reads PATH from the registry, and
asks fnm for its node directory.`
	}
	return `The launcher already looks in /opt/homebrew/bin, /usr/local/bin, ~/.local/bin,
~/Library/pnpm, Docker.app's bundled bin, and asks fnm for its node directory.`
}
