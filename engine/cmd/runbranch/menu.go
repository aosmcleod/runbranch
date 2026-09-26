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

package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"github.com/aosmcleod/runbranch/engine/internal/config"
	"github.com/aosmcleod/runbranch/engine/internal/gitx"
	"github.com/aosmcleod/runbranch/engine/internal/run"
	"github.com/aosmcleod/runbranch/engine/internal/ui"
)

// The terminal picker. The apps are the real front ends; this exists so the
// engine is usable alone — during development, over ssh, or if an app will
// not build.

const week = 604800

func menu() {
	if !ui.HaveTTY {
		ui.Die("This is the engine, not the front end.", ui.AppFix(config.SelfDir))
	}
	name, ok := pickProject()
	if !ok {
		return
	}
	p := config.Load(name)
	if run.IsRunning(p) {
		run.PrintStatus(p)
		if ui.Ask("Stop it?", true) {
			run.StopRun(p, false)
		}
		return
	}
	ref, ok := pickBranch(p)
	if !ok {
		return
	}
	preset, ok := pickPreset(p)
	if !ok {
		return
	}
	run.DoRun(p, ref, preset)
}

// pick reads a number in 1..n, or reports a cancel.
func pick(n int, prompt string) (int, bool) {
	ui.Out(prompt)
	reply := ui.ReadLine()
	i, err := strconv.Atoi(reply)
	if reply == "" || err != nil || strings.Trim(reply, "0123456789") != "" || i < 1 || i > n {
		return 0, false
	}
	return i, true
}

func pickProject() (string, bool) {
	all := config.LoadAll()
	var b strings.Builder
	fmt.Fprintf(&b, "\n%sProjects%s\n\n", ui.Bld, ui.Off)
	for i, p := range all {
		fmt.Fprintf(&b, "  %2d.  %-22s %s%s%s\n", i+1, p.Name(), ui.Dim, p.Repo(), ui.Off)
	}
	ui.Out(b.String())
	if len(all) == 0 {
		ui.Die("No projects declared.", "ls "+config.ProjectsDir)
	}
	if len(all) == 1 {
		return all[0].ID, true
	}
	i, ok := pick(len(all), "\n  Number, or Return to cancel: ")
	if !ok {
		return "", false
	}
	return all[i-1].ID, true
}

// pickBranch hides what the app hides by default in the one way a terminal
// list can: merged branches and anything older than a week, never the
// default branch.
func pickBranch(p *config.Project) (string, bool) {
	rows := gitx.Branches(p)
	_ = os.MkdirAll(p.WorkRoot, 0o755)
	var data strings.Builder
	for _, r := range rows {
		data.WriteString(r.TSV() + "\n")
	}
	_ = os.WriteFile(filepath.Join(p.WorkRoot, "branches"), []byte(data.String()), 0o644)

	now := time.Now().Unix()
	var refs []string
	var b strings.Builder
	fmt.Fprintf(&b, "\n%sBranches — %s%s\n\n", ui.Bld, p.Name(), ui.Off)
	for _, r := range rows {
		if !r.IsDefault && (r.PR == "MERGED" || now-r.TS > week) {
			continue
		}
		refs = append(refs, r.Ref)
		tags := ""
		if r.IsDefault {
			tags += " [default]"
		} else if r.PR != "NONE" {
			tags += " [" + strings.ToLower(r.PR) + "]"
		}
		tags += " [" + r.Owner + "]"
		if r.Ready {
			tags += " [ready]"
		}
		fmt.Fprintf(&b, "  %2d.  %-36s%s%s%s  %s%s%s\n", len(refs), r.Ref, ui.Dim, tags, ui.Off, ui.Dim, r.Age, ui.Off)
	}
	ui.Out(b.String())
	if len(refs) == 0 {
		ui.Die("No branches to show for "+p.Name()+".", config.Self+" branches "+p.ID)
	}
	i, ok := pick(len(refs), "\n  Number to run, or Return to cancel: ")
	if !ok {
		return "", false
	}
	return refs[i-1], true
}

func pickPreset(p *config.Project) (string, bool) {
	names := p.PresetNames()
	if len(names) == 0 {
		return "", false
	}
	if len(names) == 1 {
		return names[0], true
	}
	var b strings.Builder
	b.WriteString("\n  What should run? ")
	for i, n := range names {
		fmt.Fprintf(&b, "%s%d%s %s  ", ui.Bld, i+1, ui.Off, n)
	}
	b.WriteString("[1]: ")
	ui.Out(b.String())
	reply := ui.ReadLine()
	if reply == "" {
		reply = "1"
	}
	i, err := strconv.Atoi(reply)
	if err != nil || strings.Trim(reply, "0123456789") != "" || i < 1 || i > len(names) {
		return "", false
	}
	return names[i-1], true
}
