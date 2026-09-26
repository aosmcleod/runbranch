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

// Package gitx is everything the engine asks git and GitHub.
//
// The ONLY things done in your checkout: read refs, copy gitignored files out
// of it, and git-worktree metadata operations. No checkout, no stash, no
// fetch.
package gitx

import (
	"bytes"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"

	"github.com/aosmcleod/runbranch/engine/internal/config"
	"github.com/aosmcleod/runbranch/engine/internal/pathx"
)

// Command is every git the engine runs, and the only place one is made.
//
// `-c core.longpaths=true` on every call: a worktree's node_modules routinely
// passes 260 characters, and without it Git for Windows refuses to check out,
// remove or even list such a path ("Filename too long"). Passing it here
// rather than asking for `git config --global` means nobody has to change a
// setting, let alone run anything as administrator (spec F17), and it never
// touches the user's own git config. On every OS rather than Windows only:
// git elsewhere ignores the key, so one code path is the same code tested
// everywhere, and a Mac's tests exercise the exact arguments Windows gets.
func Command(args ...string) *exec.Cmd {
	return exec.Command("git", append([]string{"-c", "core.longpaths=true"}, args...)...)
}

// Git runs git -C dir args and returns stdout without its trailing newline.
func Git(dir string, args ...string) (string, error) {
	cmd := Command(append([]string{"-C", dir}, args...)...)
	var out bytes.Buffer
	cmd.Stdout = &out
	cmd.Stderr = nil
	err := cmd.Run()
	return strings.TrimRight(out.String(), "\r\n"), err
}

// Quiet runs git for its exit status only.
func Quiet(dir string, args ...string) error {
	_, err := Git(dir, args...)
	return err
}

// CurrentBranch is what the checkout is on; HEAD when detached.
func CurrentBranch(p *config.Project) string {
	s, _ := Git(p.Repo(), "rev-parse", "--abbrev-ref", "HEAD")
	return s
}

// Resolve is a ref's commit, or "" when it does not resolve.
func Resolve(dir, ref string) string {
	s, err := Git(dir, "rev-parse", "--verify", "--quiet", ref+"^{commit}")
	if err != nil {
		return ""
	}
	return s
}

var unsafeSlug = regexp.MustCompile(`[^A-Za-z0-9._-]`)

// SlugFor is the directory-safe form of a ref: a leading origin/ dropped and
// everything outside [A-Za-z0-9._-] made a dash. Byte by byte, like sed, so a
// multi-byte character becomes several dashes and names stay what they were.
func SlugFor(ref string) string {
	ref = strings.TrimPrefix(ref, "origin/")
	return slugBytes(ref)
}

func slugBytes(s string) string {
	b := []byte(s)
	for i, c := range b {
		if !(c >= 'A' && c <= 'Z' || c >= 'a' && c <= 'z' || c >= '0' && c <= '9' || c == '.' || c == '_' || c == '-') {
			b[i] = '-'
		}
	}
	return string(b)
}

// RefDigest is a short, stable digest of a ref, for when its slug is taken.
func RefDigest(ref string) string { return fmt.Sprintf("%04x", Cksum([]byte(ref))%65536) }

// WorktreeSlug is the directory name a ref's worktree uses.
//
// SlugFor is lossy — `feat/a-b` and `feat/a+b` both want `feat-a-b`, and a
// literal branch named `feat-a-b` wants it too. Sharing a directory mostly
// works, since every run re-checks-out the ref, but `remove-worktree` on one
// then deletes the other's and the UI reports a worktree as present for a
// branch that does not own it.
//
// The meta file records which ref owns a slug, so only an actual collision
// pays for it: the second ref gets a digest suffix, and everything else keeps
// the readable name it already has. Nothing needs migrating.
func WorktreeSlug(p *config.Project, ref string) string {
	base := SlugFor(ref)
	if b, err := os.ReadFile(filepath.Join(p.MetaDir, base+".ref")); err == nil {
		owner := strings.TrimRight(string(b), "\r\n")
		if owner != "" && owner != ref {
			base += "-" + RefDigest(ref)
		}
	}
	return base
}

// WorktreePath is where a ref's worktree is, or would be. Creates nothing.
func WorktreePath(p *config.Project, ref string) string {
	return filepath.Join(p.Worktrees, WorktreeSlug(p, ref))
}

// MetaRef is the ref a worktree directory was made from, or "".
func MetaRef(p *config.Project, slug string) string {
	b, err := os.ReadFile(filepath.Join(p.MetaDir, slug+".ref"))
	if err != nil {
		return ""
	}
	return strings.TrimRight(string(b), "\r\n")
}

var ghURL = regexp.MustCompile(`^.*github\.com[:/]`)

// GHRepo is owner/repo, for gh. Empty when there is no GitHub remote, in
// which case PR badges are simply absent rather than an error.
func GHRepo(p *config.Project) string {
	url, err := Git(p.Repo(), "config", "--get", "remote.origin.url")
	if err != nil {
		return ""
	}
	s := ghURL.ReplaceAllString(url, "")
	s = strings.TrimSuffix(s, ".git")
	if !strings.Contains(s, "/") {
		return ""
	}
	return s
}

// ForeignWorktrees maps a branch to the path of a worktree that holds it,
// when that worktree is neither the checkout nor one of ours.
//
// `git worktree list` reports the main checkout and every linked worktree,
// including the ones Runbranch made. The interesting ones are the others: a
// worktree the user set up themselves is somewhere they may be working, and a
// branch checked out there cannot be checked out anywhere else — git will not
// allow it — so it is worth saying so rather than letting a run fail.
func ForeignWorktrees(p *config.Project) map[string]string {
	out := map[string]string{}
	s, err := Git(p.Repo(), "worktree", "list", "--porcelain")
	if err != nil {
		return out
	}
	path := ""
	for _, line := range strings.Split(s, "\n") {
		line = strings.TrimRight(line, "\r")
		switch {
		case strings.HasPrefix(line, "worktree "):
			// git prints C:/x on Windows. Compared and reported natively.
			path = pathx.Native(strings.TrimPrefix(line, "worktree "))
		case strings.HasPrefix(line, "branch "):
			ref := strings.TrimPrefix(strings.TrimPrefix(line, "branch "), "refs/heads/")
			if pathx.Equal(path, p.Repo()) || pathx.Within(path, p.Worktrees) {
				continue
			}
			if _, seen := out[ref]; !seen {
				out[ref] = path
			}
		}
	}
	return out
}

// TrunkRef is what every branch is measured against: origin's copy of the
// default branch when there is one, the local copy otherwise.
//
// Not the local one by preference. A checkout whose `main` has not been
// fetched in a fortnight would report every branch as behind by nothing,
// which is the opposite of the truth and worse than saying nothing at all.
func TrunkRef(p *config.Project) string {
	remote := "refs/remotes/origin/" + p.DefaultBranch()
	if Quiet(p.Repo(), "rev-parse", "--verify", "--quiet", remote) == nil {
		return remote
	}
	local := "refs/heads/" + p.DefaultBranch()
	if Quiet(p.Repo(), "rev-parse", "--verify", "--quiet", local) == nil {
		return local
	}
	return ""
}

// HasAheadBehind probes for `%(ahead-behind:)`, which counts divergence for
// every ref in ONE walk — the only reason the column is affordable. It landed
// in git 2.41, and an unknown atom is fatal to for-each-ref rather than
// ignorable, so it is probed against a ref that certainly exists instead of
// guessed from `git --version`.
func HasAheadBehind(p *config.Project, trunk string) bool {
	if trunk == "" {
		return false
	}
	return Quiet(p.Repo(), "for-each-ref", "--count=1", "--format=%(ahead-behind:"+trunk+")", trunk) == nil
}

// MyEmails are the addresses that make a commit "mine". git's own user.email
// by default, since hardcoding an author's addresses into a published tool is
// both wrong for everyone else and a needless disclosure. RB_MY_EMAILS
// overrides, space-separated, for anyone who commits under several.
func MyEmails() []string {
	if v := os.Getenv("RB_MY_EMAILS"); v != "" {
		return strings.Fields(v)
	}
	out, err := Command("config", "--get", "user.email").Output()
	if err != nil {
		return nil
	}
	return strings.Fields(string(out))
}
