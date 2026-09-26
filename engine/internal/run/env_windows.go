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
	"os"
	"path/filepath"
	"strings"

	"golang.org/x/sys/windows/registry"
)

// Where Windows tools install themselves when they do not add themselves to
// PATH, or when the PATH we were given predates the install. The registry's
// own PATH comes first: a process launched before an installer ran still has
// the old one, and the registry is where the new one was written.
func extraPathDirs() []string {
	local := os.Getenv("LOCALAPPDATA")
	appdata := os.Getenv("APPDATA")
	home := os.Getenv("USERPROFILE")
	pf := os.Getenv("ProgramFiles")
	dirs := registryPath()
	return append(dirs,
		filepath.Join(local, "Microsoft", "WinGet", "Links"),
		filepath.Join(pf, "Git", "cmd"),
		filepath.Join(pf, "Docker", "Docker", "resources", "bin"),
		filepath.Join(appdata, "npm"),
		filepath.Join(local, "pnpm"),
		filepath.Join(home, "scoop", "shims"),
		filepath.Join(local, "mise", "shims"),
		filepath.Join(home, ".local", "bin"),
	)
}

func registryPath() []string {
	var out []string
	read := func(root registry.Key, path string) {
		k, err := registry.OpenKey(root, path, registry.QUERY_VALUE)
		if err != nil {
			return
		}
		defer k.Close()
		v, _, err := k.GetStringValue("Path")
		if err != nil {
			return
		}
		if x, err := registry.ExpandString(v); err == nil {
			v = x
		}
		for _, d := range strings.Split(v, ";") {
			if d = strings.TrimSpace(d); d != "" {
				out = append(out, d)
			}
		}
	}
	read(registry.LOCAL_MACHINE, `SYSTEM\CurrentControlSet\Control\Session Manager\Environment`)
	read(registry.CURRENT_USER, `Environment`)
	return out
}

// LongPathsEnabled reports the machine-wide switch that lets ordinary Win32
// calls use paths past 260 characters. Off by default, and a worktree's
// node_modules routinely needs it on.
func LongPathsEnabled() (enabled, known bool) {
	k, err := registry.OpenKey(registry.LOCAL_MACHINE, `SYSTEM\CurrentControlSet\Control\FileSystem`, registry.QUERY_VALUE)
	if err != nil {
		return false, false
	}
	defer k.Close()
	v, _, err := k.GetIntegerValue("LongPathsEnabled")
	if err != nil {
		return false, true
	}
	return v != 0, true
}
