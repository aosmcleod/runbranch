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

package scan

import (
	"fmt"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"

	"github.com/aosmcleod/runbranch/engine/internal/config"
	"github.com/aosmcleod/runbranch/engine/internal/gitx"
	"github.com/aosmcleod/runbranch/engine/internal/pathx"
	"github.com/aosmcleod/runbranch/engine/internal/run"
	"github.com/aosmcleod/runbranch/engine/internal/ui"
)

// CmdHead is the first word of a command that is not a VAR=value, which is
// the thing that has to exist.
func CmdHead(cmd string) string {
	for _, w := range strings.Fields(cmd) {
		if !strings.Contains(w, "=") {
			return w
		}
	}
	return ""
}

// Doctor checks a project's config before you need it. Every one of these is
// something that would otherwise surface minutes into a run, as a failure
// that looks like the branch's fault. False when any check warned.
func Doctor(p *config.Project) bool {
	bad := false
	warn := func(s string) { ui.Warn(s); bad = true }

	ui.Step(p.Name())
	ui.Info("config    " + filepath.Join(config.ProjectsDir, p.ID+".conf"))
	if p.InRepo != "" {
		ui.OK(fmt.Sprintf("in-repo   %s (local file overrides it)", p.InRepo))
	}

	if pathx.IsDir(filepath.Join(p.Repo(), ".git")) {
		ui.OK("repo      " + p.Repo())
	} else {
		warn(fmt.Sprintf("repo      %s is not a git repository", p.Repo()))
	}

	if gitx.Resolve(p.Repo(), p.DefaultBranch()) != "" {
		ui.OK("branch    " + p.DefaultBranch())
	} else {
		warn(fmt.Sprintf("branch    DEFAULT_BRANCH=%s does not resolve", p.DefaultBranch()))
	}

	for _, f := range p.Words("COPY_FILES") {
		if pathx.Exists(filepath.Join(p.Repo(), f)) {
			ui.OK("copy      " + f)
		} else {
			warn(fmt.Sprintf("copy      %s is declared in COPY_FILES but missing from the checkout", f))
		}
	}

	if install := p.Get("INSTALL"); install != "" {
		head := CmdHead(install)
		if run.OnPath(head) {
			ui.OK("install   " + head)
		} else {
			warn(fmt.Sprintf("install   `%s` is not on PATH", head))
		}
	}

	if p.Get("COMPOSE_SERVICES") != "" {
		if run.OnPath("docker") {
			ui.OK("docker    present")
		} else {
			warn("docker    needed for COMPOSE_SERVICES but not on PATH")
		}
		if pathx.IsFile(filepath.Join(p.Repo(), p.Get("COMPOSE_FILE"))) {
			ui.OK("compose   " + p.Get("COMPOSE_FILE"))
		} else {
			warn(fmt.Sprintf("compose   %s not found in the checkout", p.Get("COMPOSE_FILE")))
		}
	}

	if rt := p.Get("RUNTIME"); rt != "" {
		switch {
		case run.RuntimeUnsupported(rt) != "":
			warn("runtime   " + run.RuntimeUnsupported(rt))
		case run.OnPath(rt) || (rt == "nvm" && runtime.GOOS != "windows"):
			// nvm is a shell function, not a command, so it cannot be looked for.
			ui.OK("runtime   " + rt)
		default:
			warn(fmt.Sprintf("runtime   RUNTIME=%s is not installed", rt))
		}
	}

	for _, n := range p.TargetNames() {
		t, _ := p.Target(n)
		head := CmdHead(t.Command)
		if run.OnPath(head) {
			ui.OK(fmt.Sprintf("target    %s -> %s on port %s", n, head, t.Port))
		} else {
			warn(fmt.Sprintf("target    %s needs `%s`, which is not on PATH", n, head))
		}
	}

	if _, err := exec.LookPath("gh"); err == nil && gitx.GHRepo(p) != "" {
		ui.OK("github    " + gitx.GHRepo(p))
	} else {
		ui.DimLine("github    no gh or no GitHub remote — pull request badges will be absent")
	}

	longPaths()
	return !bad
}

// longPaths is Windows only, and informational: nothing here is a problem to
// fix. A worktree's node_modules routinely goes past 260 characters, and the
// engine copes without the machine's LongPathsEnabled switch — it gives every
// git it runs core.longpaths and deletes and copies through \\?\ paths (spec
// F17). It used to warn and hand over a registry command to run as
// administrator, which on a work machine is a request many people cannot
// grant and should not have to.
//
// Still worth one line when the switch is off, because the engine can only
// speak for itself: an INSTALL or a server is some other program, and a tool
// that is not long-path aware can still fail on a deep tree. The run says so
// when its output looks like that; this says where the optional switch is.
func longPaths() {
	if runtime.GOOS != "windows" {
		return
	}
	if on, known := run.LongPathsEnabled(); known && !on {
		ui.DimLine("longpaths Windows long paths are off; Runbranch handles long paths itself, so turning on LongPathsEnabled is optional")
	}
}
