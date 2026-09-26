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
	"io"
	"os"
	"path/filepath"

	"github.com/aosmcleod/runbranch/engine/internal/config"
	"github.com/aosmcleod/runbranch/engine/internal/gitx"
	"github.com/aosmcleod/runbranch/engine/internal/pathx"
	"github.com/aosmcleod/runbranch/engine/internal/ui"
)

func short(sha string) string {
	if len(sha) > 9 {
		return sha[:9]
	}
	return sha
}

// prepareWorktree makes or moves a ref's worktree and returns its path.
//
// Worktrees are created DETACHED at the branch tip, never as a checkout of
// the branch. Git refuses to check out a branch already checked out
// elsewhere — and demoing the branch you are working on is the common case.
// A demo runner also has no business holding a ref it might move.
func prepareWorktree(p *config.Project, ref string) string {
	wt := gitx.WorktreePath(p, ref)
	tip := gitx.Resolve(p.Repo(), ref)
	if tip == "" {
		ui.Die(fmt.Sprintf("`%s` does not resolve to a commit in %s.", ref, p.Repo()),
			fmt.Sprintf("cd %s && git fetch origin", p.Repo()))
	}

	ui.Step("Worktree  " + wt)
	for _, d := range []string{p.Worktrees, p.MetaDir, p.LogDir} {
		_ = os.MkdirAll(d, 0o755)
	}

	if pathx.Exists(filepath.Join(wt, ".git")) {
		at, _ := gitx.Git(wt, "rev-parse", "HEAD")
		if at == tip {
			ui.OK("already at " + short(tip))
		} else {
			ui.Info(fmt.Sprintf("updating %s -> %s", short(at), short(tip)))
			if gitx.Quiet(wt, "checkout", "--detach", "--force", tip) != nil {
				ui.Die(fmt.Sprintf("Could not move the worktree to %s.", ref),
					fmt.Sprintf("%s remove-worktree %s '%s'", config.Self, p.ID, ref))
			}
			ui.OK("moved to " + short(tip))
		}
	} else {
		_ = gitx.Quiet(p.Repo(), "worktree", "prune")
		safeRmWorktree(p, wt)
		ui.Info(fmt.Sprintf("creating worktree (detached at %s)", short(tip)))
		if gitx.Quiet(p.Repo(), "worktree", "add", "--detach", wt, tip) != nil {
			ui.Die(fmt.Sprintf("`git worktree add` failed for %s.", ref),
				fmt.Sprintf("cd %s && git worktree add --detach '%s' '%s'", p.Repo(), wt, tip))
		}
		ui.OK("created")
	}

	_ = os.WriteFile(filepath.Join(p.MetaDir, gitx.WorktreeSlug(p, ref)+".ref"), []byte(ref+"\n"), 0o644)

	// Worktrees do not inherit untracked files, and this config is
	// gitignored. Copy it EVERY time, not just on create: it changes in the
	// main checkout and a stale copy is indistinguishable from a broken
	// branch.
	for _, f := range p.Words("COPY_FILES") {
		src := filepath.Join(p.Repo(), f)
		if pathx.Exists(src) {
			// Through \\?\ on Windows: a copied directory can be as deep as
			// anything else in a checkout, and the copy should not be the one
			// step that fails on it.
			_ = copyTree(pathx.Extended(src), pathx.Extended(filepath.Join(wt, f)))
			ui.OK(f + " copied from the main checkout")
		} else {
			ui.Warn(fmt.Sprintf("%s is declared in COPY_FILES but missing from %s", f, p.Repo()))
		}
	}
	return wt
}

// copyTree copies a file or a directory to dst, merging into a directory
// that is already there. `cp -R dir wt/dir` did not: into an existing
// directory it nested the copy, so the second run made wt/dir/dir.
func copyTree(src, dst string) error {
	fi, err := os.Lstat(src)
	if err != nil {
		return err
	}
	switch {
	case fi.Mode()&os.ModeSymlink != 0:
		target, err := os.Readlink(src)
		if err != nil {
			return err
		}
		_ = os.Remove(dst)
		if os.Symlink(target, dst) == nil {
			return nil
		}
		// Windows without the privilege to make links: copy what it points at.
		return copyFile(src, dst)
	case fi.IsDir():
		if err := os.MkdirAll(dst, fi.Mode().Perm()|0o700); err != nil {
			return err
		}
		entries, err := os.ReadDir(src)
		if err != nil {
			return err
		}
		for _, e := range entries {
			if err := copyTree(filepath.Join(src, e.Name()), filepath.Join(dst, e.Name())); err != nil {
				return err
			}
		}
		return nil
	}
	return copyFile(src, dst)
}

func copyFile(src, dst string) error {
	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer in.Close()
	fi, err := in.Stat()
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(dst), 0o755); err != nil {
		return err
	}
	out, err := os.OpenFile(dst, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, fi.Mode().Perm())
	if err != nil {
		return err
	}
	if _, err := io.Copy(out, in); err != nil {
		out.Close()
		return err
	}
	return out.Close()
}

// safeRmWorktree is rm -rf with a leash: it refuses anything that is not a
// direct child of this project's worktree root.
func safeRmWorktree(p *config.Project, path string) {
	if path == "" || !pathx.Exists(path) {
		return
	}
	if !pathx.Equal(filepath.Dir(path), p.Worktrees) || pathx.Equal(path, p.Worktrees) {
		ui.Die(fmt.Sprintf("Refusing to delete %s — it is not a throwaway worktree under %s.", path, p.Worktrees),
			"Remove it by hand if that is really what you want.")
	}
	_ = pathx.RemoveAll(path)
}

// DeleteWorktree removes a worktree directory through git, and by hand when
// git will not — a path past MAX_PATH, or one git has forgotten.
func DeleteWorktree(p *config.Project, wt string) {
	if gitx.Quiet(p.Repo(), "worktree", "remove", "--force", wt) != nil || pathx.Exists(wt) {
		safeRmWorktree(p, wt)
		_ = gitx.Quiet(p.Repo(), "worktree", "prune")
	}
}

// RemoveWorktree removes exactly one ref's worktree, and its database.
func RemoveWorktree(p *config.Project, ref string) {
	wt := gitx.WorktreePath(p, ref)
	if !pathx.IsDir(wt) {
		ui.Info("No worktree for " + ref + ".")
		return
	}
	if s, running := p.Running(); running && pathx.Equal(s.Worktree, wt) {
		ui.Die(ref+" is running, so its worktree is in use.", config.Self+" stop "+p.ID)
	}
	ui.Step("Removing worktree for " + ref)
	dropRunDatabase(p, wt, ref)
	DeleteWorktree(p, wt)
	_ = os.Remove(filepath.Join(p.MetaDir, gitx.WorktreeSlug(p, ref)+".ref"))
	ui.OK("removed " + wt)
}
