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
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"testing"

	"github.com/aosmcleod/runbranch/engine/internal/config"
	"github.com/aosmcleod/runbranch/engine/internal/gitx"
	"github.com/aosmcleod/runbranch/engine/internal/pathx"
	"github.com/aosmcleod/runbranch/engine/internal/ui"
)

// deep is a relative path of about 330 characters: past MAX_PATH on its own,
// before any temp directory is put in front of it.
func deep(leaf string) string {
	parts := make([]string, 11)
	for i := range parts {
		parts[i] = "a-directory-name-thirty-chars"
	}
	return filepath.Join(append(parts, leaf)...)
}

func git(t *testing.T, dir string, args ...string) {
	t.Helper()
	cmd := gitx.Command(append([]string{"-C", dir}, args...)...)
	cmd.Env = append(os.Environ(), "GIT_AUTHOR_DATE=2026-01-01T00:00:00Z", "GIT_COMMITTER_DATE=2026-01-01T00:00:00Z")
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("git %v: %v\n%s", args, err, out)
	}
}

func write(t *testing.T, path, body string) {
	t.Helper()
	x := pathx.Extended(path)
	if err := os.MkdirAll(filepath.Dir(x), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(x, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
}

// longFixture is a repo whose branch `deep` holds a file at a path past 260
// characters, a gitignored COPY_FILES directory just as deep, and a project
// over it with its own RB_HOME.
func longFixture(t *testing.T) (*config.Project, string) {
	t.Helper()
	if _, err := exec.LookPath("git"); err != nil {
		t.Skip("git is not on PATH")
	}
	tmp := t.TempDir()
	repo := filepath.Join(tmp, "repo")
	_ = os.MkdirAll(repo, 0o755)
	git(t, repo, "init", "-q", "-b", "main")
	git(t, repo, "config", "user.email", "tester@example.com")
	git(t, repo, "config", "user.name", "Tess Ter")
	write(t, filepath.Join(repo, ".gitignore"), "cache/\n")
	write(t, filepath.Join(repo, "f"), "x\n")
	git(t, repo, "add", ".")
	git(t, repo, "commit", "-q", "-m", "first")
	git(t, repo, "checkout", "-q", "-b", "deep")
	rel := deep("file.txt")
	write(t, filepath.Join(repo, rel), "deep\n")
	git(t, repo, "add", ".")
	git(t, repo, "commit", "-q", "-m", "a deep file")
	git(t, repo, "checkout", "-q", "main")
	write(t, filepath.Join(repo, "cache", deep("copied.txt")), "copied\n")

	projects := filepath.Join(tmp, "projects")
	_ = os.MkdirAll(projects, 0o755)
	write(t, filepath.Join(projects, "lp.conf"),
		"NAME=\"Lp\"\nREPO="+config.Quote(repo)+"\nCOPY_FILES=\"cache\"\nTARGETS=\"web:4000:/:true\"\n")
	t.Setenv("RB_HOME", filepath.Join(tmp, "state"))
	t.Setenv("RB_PROJECTS_DIR", projects)
	config.Locate()
	return config.Load("lp"), rel
}

// The whole worktree lifecycle on a branch with a path past MAX_PATH, with
// nothing switched on: no LongPathsEnabled (off on the machine this was
// written on), no core.longpaths in any git config. Create, copy, move to a
// new tip, remove.
func TestAWorktreeWithAPathPastMaxPath(t *testing.T) {
	p, rel := longFixture(t)
	if on, known := LongPathsEnabled(); known && on {
		t.Log("LongPathsEnabled is on here, so this proves less than it does on a default machine")
	}

	var wt string
	if f := ui.Catch(func() { wt = prepareWorktree(p, "deep") }); f != nil {
		t.Fatalf("prepareWorktree failed: %s\n%s", f.Msg, f.Fix)
	}
	file := filepath.Join(wt, rel)
	if len(file) <= 260 {
		t.Fatalf("the fixture path is only %d characters; it proves nothing", len(file))
	}
	// Trimmed: core.autocrlf may turn the line ending into CRLF on checkout.
	if b, err := os.ReadFile(pathx.Extended(file)); err != nil || strings.TrimSpace(string(b)) != "deep" {
		t.Fatalf("the deep file did not check out: %v %q", err, b)
	}
	if b, err := os.ReadFile(pathx.Extended(filepath.Join(wt, "cache", deep("copied.txt")))); err != nil || string(b) != "copied\n" {
		t.Fatalf("COPY_FILES did not copy the deep directory: %v %q", err, b)
	}

	// A new tip: the checkout --detach --force path, over the deep tree.
	write(t, filepath.Join(p.Repo(), "g"), "g\n")
	git(t, p.Repo(), "checkout", "-q", "deep")
	git(t, p.Repo(), "add", "g")
	git(t, p.Repo(), "commit", "-q", "-m", "second")
	git(t, p.Repo(), "checkout", "-q", "main")
	if f := ui.Catch(func() { prepareWorktree(p, "deep") }); f != nil {
		t.Fatalf("moving the worktree failed: %s", f.Msg)
	}
	if !pathx.IsFile(pathx.Extended(filepath.Join(wt, "g"))) {
		t.Fatal("the worktree did not move to the new tip")
	}

	if f := ui.Catch(func() { RemoveWorktree(p, "deep") }); f != nil {
		t.Fatalf("RemoveWorktree failed: %s", f.Msg)
	}
	if pathx.Exists(pathx.Extended(wt)) {
		t.Fatalf("%s is still there", wt)
	}
	if s, _ := gitx.Git(p.Repo(), "worktree", "list", "--porcelain"); strings.Count(s, "worktree ") != 1 {
		t.Errorf("git still lists the removed worktree:\n%s", s)
	}
}

// The control for the test above: the same checkout without the flag the
// engine adds. If this succeeds the machine lets long paths through anyway
// and the test above is not testing the flag, which is worth knowing.
func TestPlainGitRefusesTheSamePath(t *testing.T) {
	if runtime.GOOS != "windows" {
		t.Skip("MAX_PATH is a Windows limit")
	}
	p, _ := longFixture(t)
	wt := filepath.Join(t.TempDir(), "plain")
	cmd := exec.Command("git", "-c", "core.longpaths=false", "-C", p.Repo(), "worktree", "add", "--detach", wt, "deep")
	out, err := cmd.CombinedOutput()
	if err == nil {
		t.Logf("plain git checked the deep path out, so this machine does not need the flag: %s", out)
		return
	}
	if !looksTooLong(out) {
		t.Errorf("plain git failed, but not the way the long-path note looks for:\n%s", out)
	}
}

func TestLooksTooLong(t *testing.T) {
	for out, want := range map[string]bool{
		"error: unable to create file a/b/c.js: Filename too long":                          true,
		"npm ERR! code ENAMETOOLONG":                                                        true,
		"The filename or extension is too long.":                                            true,
		"System.IO.PathTooLongException: The specified path is too long":                    true,
		"Error: The system cannot find the path specified. (os error 206)":                  true,
		"path exceeds MAX_PATH":                                                             true,
		"CreateFile failed with error 206":                                                  true,
		"The directory or file cannot be created.":                                          true, // cmd's mkdir
		"ERR_PNPM_FETCH_401 GET https://npm.pkg.github.com/x: Unauthorized - 401":           false,
		"the file error 2065 is not this one":                                               false,
		"Everything is fine; this line mentions a long filename, not one that is too long.": false,
	} {
		if got := looksTooLong([]byte(out)); got != want {
			t.Errorf("looksTooLong(%q) = %v, want %v", out, got, want)
		}
	}
}

func TestTailBufferKeepsTheEnd(t *testing.T) {
	var b tailBuffer
	_, _ = b.Write([]byte(strings.Repeat("x", tailBytes)))
	_, _ = b.Write([]byte("Filename too long\n"))
	if len(b.Bytes()) != tailBytes || !looksTooLong(b.Bytes()) {
		t.Errorf("kept %d bytes, the signature at the end found: %v", len(b.Bytes()), looksTooLong(b.Bytes()))
	}
}
