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

package ports

import (
	"fmt"
	"path/filepath"
	"strings"
	"unicode/utf8"

	"github.com/aosmcleod/runbranch/engine/internal/config"
	"github.com/aosmcleod/runbranch/engine/internal/pathx"
	"github.com/aosmcleod/runbranch/engine/internal/proc"
)

// Kind is how a process holding a port relates to Runbranch.
const (
	Ours    = "ours"    // running inside a worktree under RB_HOME
	Outside = "outside" // running inside a project's checkout, started elsewhere
	Unknown = "unknown" // neither
)

// Attributor answers "whose is this process". It loads every project once,
// where the bash engine loaded every config again for every process it asked
// about.
type Attributor struct {
	projects []*config.Project
	loaded   bool
}

func (a *Attributor) all() []*config.Project {
	if !a.loaded {
		a.projects = config.LoadAll()
		a.loaded = true
	}
	return a.projects
}

// Hay is everything known about where a process runs: its command line and
// its working directory. The command line carries a path only when the
// process was started with an absolute one (`node /path/to/.bin/vite` does,
// `python3 -m http.server` does not), so the working directory is checked as
// well. On Windows the working directory is best effort.
func Hay(pid int) string {
	h, _ := hay(pid)
	return h
}

// hay returns the folded text to search, and the same text with its case
// intact, byte for byte aligned with it.
func hay(pid int) (folded, orig string) {
	cmd, _ := proc.Cmdline(pid)
	cwd, _ := proc.Cwd(pid)
	if cwd != "" {
		cwd = pathx.Long(cwd)
	}
	orig = pathx.Seps(cmd + " " + cwd)
	return pathx.Fold(orig), orig
}

// Owner attributes a process holding a port.
//
// Two ways to attribute one. A process running inside a worktree under
// RB_HOME is a run of ours, and the first path segment after RB_HOME is the
// project — so a port conflict can name the run holding the port rather than
// leaving the user to work it out from a command line. A process running
// inside a project's own checkout is that project too, but started by
// something else — a terminal, an editor, an agent — and saying so beats
// reporting "another app".
func (a *Attributor) Owner(pid int) (project, kind string) {
	h, orig := hay(pid)
	if end := pathx.FindIn(h, config.RBHome); end >= 0 && end < len(h) && h[end] == filepath.Separator {
		// Offsets in the folded copy are offsets in the original, so the
		// project keeps its case. (RB_HOME/projects/... reads as "projects",
		// as it always did.)
		rest := orig[end+1:]
		if i := strings.IndexAny(rest, string(filepath.Separator)+" \t\"'"); i >= 0 {
			rest = rest[:i]
		}
		if rest != "" {
			return rest, Ours
		}
	}
	// Nothing under RB_HOME, so ask each project whether this is its checkout.
	for _, p := range a.all() {
		if pathx.FindIn(h, p.Repo()) >= 0 {
			return p.ID, Outside
		}
	}
	return "", Unknown
}

// InWorktrees reports whether a process runs from this project's worktrees,
// which is what makes a stray on our port ours to reap. The bash engine asked
// the command line only; on Windows that almost never carries a path, so the
// working directory counts too.
func InWorktrees(pid int, worktrees string) bool {
	return pathx.FindIn(Hay(pid), worktrees) >= 0
}

// Desc is `ps -o pid=,command=`: the pid and its command line, cut to max
// characters.
func Desc(pid int, max int) string {
	cmd, err := proc.Cmdline(pid)
	s := fmt.Sprintf("%d", pid)
	if err == nil && cmd != "" {
		s += " " + cmd
	}
	return cut(s, max)
}

func cut(s string, max int) string {
	if utf8.RuneCountInString(s) <= max {
		return s
	}
	r := []rune(s)
	return string(r[:max])
}
