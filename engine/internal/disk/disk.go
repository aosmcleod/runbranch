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

// Package disk is what worktrees cost and how they go away.
//
// A run's worktree stays after the run stops, and nothing prunes it
// automatically. That is a choice rather than an oversight: the expensive
// part of a run is the install, and keeping the worktree is what makes the
// next run of that branch fast.
//
// Reclaiming is based on GONE — the ref no longer resolves — and never on
// MERGED. A squash-merge leaves a branch looking unmerged to `git branch
// --merged`, so a merged heuristic would either miss the common case or
// eventually delete work someone still wanted. `gone` is a fact.
package disk

import (
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"

	"github.com/aosmcleod/runbranch/engine/internal/config"
	"github.com/aosmcleod/runbranch/engine/internal/gitx"
	"github.com/aosmcleod/runbranch/engine/internal/pathx"
	"github.com/aosmcleod/runbranch/engine/internal/run"
	"github.com/aosmcleod/runbranch/engine/internal/ui"
)

// Row is one worktree on disk:
//
//	project slug ref kbytes running|gone|idle
type Row struct {
	Project, Slug, Ref string
	KB                 int64
	State              string
}

func (r Row) TSV() string {
	return fmt.Sprintf("%s\t%s\t%s\t%d\t%s", r.Project, r.Slug, r.Ref, r.KB, r.State)
}

// worktreeDirs lists a project's worktree directories in glob order.
func worktreeDirs(p *config.Project) []string {
	entries, err := os.ReadDir(p.Worktrees)
	if err != nil {
		return nil
	}
	var names []string
	for _, e := range entries {
		if strings.HasPrefix(e.Name(), ".") {
			continue
		}
		if pathx.IsDir(filepath.Join(p.Worktrees, e.Name())) {
			names = append(names, e.Name())
		}
	}
	config.SortNames(names)
	return names
}

func runningWorktree(p *config.Project) string {
	if s, running := p.Running(); running {
		return s.Worktree
	}
	return ""
}

// Report is every worktree on disk, with what it costs and whether anything
// still wants it. A worktree with no meta file is idle, never gone: nothing
// records which ref owns it, so there is no evidence it is dead.
func Report() []Row {
	var out []Row
	for _, p := range config.LoadAll() {
		running := runningWorktree(p)
		for _, slug := range worktreeDirs(p) {
			dir := filepath.Join(p.Worktrees, slug)
			ref := gitx.MetaRef(p, slug)
			r := Row{Project: p.ID, Slug: slug, Ref: ref, KB: sizeKB(dir), State: "idle"}
			switch {
			case running != "" && pathx.Equal(dir, running):
				r.State = "running"
			case ref != "" && gitx.Resolve(p.Repo(), ref) == "":
				r.State = "gone"
			}
			if r.Ref == "" {
				r.Ref = "?"
			}
			out = append(out, r)
		}
	}
	return out
}

// PrintHuman is `disk` in a terminal.
func PrintHuman(rows []Row) {
	var b strings.Builder
	fmt.Fprintf(&b, "\n%sWorktrees on disk%s\n\n", ui.Bld, ui.Off)
	var total, spare float64
	for _, r := range rows {
		total += float64(r.KB)
		if r.State != "running" {
			spare += float64(r.KB)
		}
		fmt.Fprintf(&b, "  %-14s %-30s %7.0f MB  %s\n", r.Project, r.Slug, float64(r.KB)/1024, r.State)
	}
	if len(rows) == 0 {
		b.WriteString("  Nothing on disk yet.\n")
	} else {
		fmt.Fprintf(&b, "\n  %d worktrees, %.1f GB total, %.1f GB not in use\n", len(rows), total/1048576, spare/1048576)
	}
	fmt.Fprintf(&b, "\n  Remove them with: %s cleanup <project>\n\n", config.Self)
	ui.Out(b.String())
}

// PruneGone removes every worktree whose ref no longer exists, without
// asking. `cleanup` is the interactive version and needs a terminal, which
// the app does not have. The running one is never touched.
func PruneGone(p *config.Project) {
	running := runningWorktree(p)
	if !pathx.IsDir(p.Worktrees) {
		ui.Info("No worktrees on disk.")
		return
	}
	removed := 0
	for _, slug := range worktreeDirs(p) {
		dir := filepath.Join(p.Worktrees, slug)
		if running != "" && pathx.Equal(dir, running) {
			continue
		}
		ref := gitx.MetaRef(p, slug)
		if ref == "" || gitx.Resolve(p.Repo(), ref) != "" {
			continue
		}
		run.DeleteWorktree(p, dir)
		_ = os.Remove(filepath.Join(p.MetaDir, slug+".ref"))
		ui.OK(fmt.Sprintf("removed %s — %s no longer exists", slug, ref))
		removed++
	}
	_ = gitx.Quiet(p.Repo(), "worktree", "prune")
	if removed == 0 {
		ui.Info("Nothing to prune — every worktree's ref still exists.")
	}
	ui.Out(fmt.Sprintf("pruned\t%d\n", removed))
}

// human is a size the way `du -sh` prints one.
func human(kb int64) string {
	units := []string{"K", "M", "G", "T"}
	v := float64(kb)
	i := 0
	for v >= 1024 && i < len(units)-1 {
		v /= 1024
		i++
	}
	if v < 10 && i > 0 {
		return fmt.Sprintf("%.1f%s", v, units[i])
	}
	return fmt.Sprintf("%.0f%s", v, units[i])
}

// Cleanup lists a project's worktrees with their sizes and removes the ones
// picked. It refuses the running one. With no terminal or no answer it
// removes nothing.
func Cleanup(p *config.Project) {
	running := runningWorktree(p)
	var b strings.Builder
	fmt.Fprintf(&b, "\n%sWorktrees — %s%s\n\n", ui.Bld, p.Name(), ui.Off)
	var paths []string
	for i, slug := range worktreeDirs(p) {
		dir := filepath.Join(p.Worktrees, slug)
		paths = append(paths, dir)
		size := human(sizeKB(dir))
		if running != "" && pathx.Equal(dir, running) {
			fmt.Fprintf(&b, "  %2d.  %-34s %6s  %s(running — stop it first)%s\n", i+1, slug, size, ui.Yel, ui.Off)
		} else {
			fmt.Fprintf(&b, "  %2d.  %-34s %6s\n", i+1, slug, size)
		}
	}
	ui.Out(b.String())
	if len(paths) == 0 {
		ui.Info("No worktrees to remove.")
		return
	}
	ui.Out("\n  Numbers to remove (space separated), or Return to cancel: ")
	if !ui.HaveTTY {
		ui.Out("\n")
		return
	}
	reply := ui.ReadLine()
	for _, w := range strings.Fields(reply) {
		n, err := strconv.Atoi(w)
		if err != nil || n < 1 || n > len(paths) {
			continue
		}
		dir := paths[n-1]
		if running != "" && pathx.Equal(dir, running) {
			ui.Warn(fmt.Sprintf("skipped %s — still running", filepath.Base(dir)))
			continue
		}
		run.DeleteWorktree(p, dir)
		ui.OK("removed " + filepath.Base(dir))
	}
	_ = gitx.Quiet(p.Repo(), "worktree", "prune")
}
