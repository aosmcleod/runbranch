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

// Package config is a project's declaration: where the .conf files live, how
// one is read and rewritten, the favourites list, and the run state a project
// leaves in RB_HOME.
package config

import (
	"os"
	"path/filepath"
	"strings"

	"github.com/aosmcleod/runbranch/engine/internal/pathx"
)

var (
	// Home is the user's home directory, the one `~` and $HOME mean.
	Home string
	// RBHome holds every project's worktrees, logs, state and PR cache.
	RBHome string
	// ProjectsDir holds the .conf files.
	ProjectsDir string
	// Self is this executable, for the fix text that names a command to run.
	Self string
	// SelfDir is the directory Self is in.
	SelfDir string
	// projectsOverridden is true when RB_PROJECTS_DIR chose ProjectsDir.
	projectsOverridden bool
)

func init() { Locate() }

// Locate works out where everything lives. Run once at start; tests call it
// again after changing the environment.
func Locate() {
	Home, _ = os.UserHomeDir()
	Home = pathx.Long(Home)

	if exe, err := os.Executable(); err == nil {
		if r, err := filepath.EvalSymlinks(exe); err == nil {
			exe = r
		}
		Self = pathx.Long(exe)
		SelfDir = filepath.Dir(Self)
	}

	if h := os.Getenv("RB_HOME"); h != "" {
		RBHome = pathx.Long(h)
	} else {
		RBHome = filepath.Join(Home, ".runbranch")
	}

	if d := os.Getenv("RB_PROJECTS_DIR"); d != "" {
		ProjectsDir = pathx.Long(d)
		projectsOverridden = true
	} else {
		ProjectsDir = defaultProjectsDir()
		projectsOverridden = false
	}
}

// Projects live in RB_HOME, EXCEPT when this binary sits in a Runbranch
// checkout, where they live in the checkout's projects/ beside the committed
// README and example.
//
// Never inside an app bundle or an install directory. Updating replaces those
// wholesale, so every .conf written through the app went with the old copy
// and the app came back presenting itself as a fresh install. RB_HOME is the
// only directory here that survives an install, which is why the state has
// always been kept there.
//
// A checkout is recognised by what it contains rather than by where it is:
// an ancestor holding projects/example.conf. The bash engine sat at the top of
// the checkout; this binary is built into engine/bin/ below it.
func defaultProjectsDir() string {
	dir := SelfDir
	for dir != "" {
		if pathx.IsFile(filepath.Join(dir, "projects", "example.conf")) {
			return filepath.Join(dir, "projects")
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			break
		}
		dir = parent
	}
	return filepath.Join(RBHome, "projects")
}

// MigrateBundleProjects carries .conf files a bundle is still holding over to
// RB_HOME, once.
//
// For an app updated in place there is nothing left to carry — the old bundle
// is deleted by the installer before this code ever runs — but an app replaced
// by hand, or one whose files were put back after the fact, still has them,
// and silently ignoring those would look exactly like the bug this fixes.
//
// Never the reverse, and never over a file already there: RB_HOME is the copy
// that survives, so it wins.
func MigrateBundleProjects() {
	if projectsOverridden {
		return
	}
	if !pathx.Equal(ProjectsDir, filepath.Join(RBHome, "projects")) {
		return
	}
	// Created even when there is nothing to carry. The app offers to reveal
	// this folder and tells a new user to put .conf files in it, and both of
	// those are embarrassing if it does not exist yet.
	if err := os.MkdirAll(ProjectsDir, 0o755); err != nil {
		return
	}
	old := filepath.Join(SelfDir, "projects")
	if SelfDir == "" || !pathx.IsDir(old) || pathx.Equal(old, ProjectsDir) {
		return
	}
	matches, _ := filepath.Glob(filepath.Join(old, "*.conf"))
	for _, f := range matches {
		dst := filepath.Join(ProjectsDir, filepath.Base(f))
		if pathx.Exists(dst) {
			continue
		}
		if b, err := os.ReadFile(f); err == nil {
			_ = os.WriteFile(dst, b, 0o644)
		}
	}
}

// ExpandTilde turns a leading ~ into the home directory, the way the bash
// engine's expand_repo did: whatever follows the ~ is appended as written.
func ExpandTilde(p string) string {
	if strings.HasPrefix(p, "~") {
		return Home + p[1:]
	}
	return p
}
