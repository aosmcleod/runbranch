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

package gitx

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"github.com/aosmcleod/runbranch/engine/internal/config"
)

// Vectors from `printf '%s' <input> | cksum`. hash/crc32 gives different
// answers for every one of these, which is the whole reason Cksum exists.
func TestCksumMatchesPOSIX(t *testing.T) {
	for _, c := range []struct {
		in     string
		crc    uint32
		digest string
	}{
		{"", 4294967295, "ffff"},
		{"a", 1220704766, "79fe"},
		{"abc", 1219131554, "78a2"},
		{"feat/a+b", 2752801396, "6a74"},
		{"feat/a-b", 2697429350, "8166"},
		{"origin/main", 261784631, "8437"},
		{"The quick brown fox jumps over the lazy dog", 2074844392, "9ce8"},
	} {
		if got := Cksum([]byte(c.in)); got != c.crc {
			t.Errorf("Cksum(%q) = %d, want %d", c.in, got, c.crc)
		}
		if got := RefDigest(c.in); got != c.digest {
			t.Errorf("RefDigest(%q) = %s, want %s", c.in, got, c.digest)
		}
	}
	// Lengths past one byte exercise the appended-length loop.
	if got := Cksum(make([]byte, 300)); got != 351385237 {
		t.Errorf("Cksum(300 zero bytes) = %d, want 351385237", got)
	}
}

func TestSlugFor(t *testing.T) {
	for in, want := range map[string]string{
		"main":            "main",
		"feature/one":     "feature-one",
		"origin/feat/x":   "feat-x",
		"feat/a+b":        "feat-a-b",
		"v1.2_rc-3":       "v1.2_rc-3",
		"ümlaut":          "--mlaut", // byte by byte, as sed did
		"origin/origin/x": "origin-x",
	} {
		if got := SlugFor(in); got != want {
			t.Errorf("SlugFor(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestAge(t *testing.T) {
	now := int64(10_000_000)
	for d, want := range map[int64]string{
		0: "0m", 59: "0m", 60: "1m", 3599: "59m", 3600: "1h", 86399: "23h",
		86400: "1d", 2591999: "29d", 2592000: "1mo", 2592000 * 3: "3mo",
	} {
		if got := Age(now, now-d); got != want {
			t.Errorf("Age(%ds ago) = %s, want %s", d, got, want)
		}
	}
}

func git(t *testing.T, dir string, args ...string) {
	t.Helper()
	cmd := exec.Command("git", append([]string{"-C", dir}, args...)...)
	cmd.Env = append(os.Environ(), "GIT_AUTHOR_DATE=2026-01-01T00:00:00Z", "GIT_COMMITTER_DATE=2026-01-01T00:00:00Z")
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("git %v: %v\n%s", args, err, out)
	}
}

// fixture is a repo with main and feature/one (one commit ahead), and a
// project over it with its own RB_HOME.
func fixture(t *testing.T) *config.Project {
	t.Helper()
	if _, err := exec.LookPath("git"); err != nil {
		t.Skip("git is not on PATH")
	}
	tmp := t.TempDir()
	repo := filepath.Join(tmp, "repo")
	os.MkdirAll(repo, 0o755)
	git(t, repo, "init", "-q", "-b", "main")
	git(t, repo, "config", "user.email", "tester@example.com")
	git(t, repo, "config", "user.name", "Tess Ter")
	os.WriteFile(filepath.Join(repo, "f"), []byte("x\n"), 0o644)
	git(t, repo, "add", "f")
	git(t, repo, "commit", "-q", "-m", "first")
	git(t, repo, "checkout", "-q", "-b", "feature/one")
	os.WriteFile(filepath.Join(repo, "f"), []byte("y\n"), 0o644)
	git(t, repo, "commit", "-q", "-am", "a subject\twith a tab")
	git(t, repo, "checkout", "-q", "main")

	projects := filepath.Join(tmp, "projects")
	os.MkdirAll(projects, 0o755)
	os.WriteFile(filepath.Join(projects, "fx.conf"),
		[]byte("NAME=\"Fx\"\nREPO="+config.Quote(repo)+"\nTARGETS=\"web:4000:/:true\"\n"), 0o644)
	t.Setenv("RB_HOME", filepath.Join(tmp, "state"))
	t.Setenv("RB_PROJECTS_DIR", projects)
	t.Setenv("RB_MY_EMAILS", "tester@example.com")
	t.Setenv("RB_PR_TTL", "900")
	config.Locate()
	return config.Load("fx")
}

func TestBranchesTSV(t *testing.T) {
	p := fixture(t)
	rows := Branches(p)
	if len(rows) != 2 {
		t.Fatalf("got %d rows, want 2", len(rows))
	}
	byRef := map[string][]string{}
	for _, r := range rows {
		f := strings.Split(r.TSV(), "\t")
		if len(f) != 15 {
			t.Fatalf("%s has %d fields, want 15: %q", r.Ref, len(f), r.TSV())
		}
		byRef[r.Ref] = f
	}
	main, one := byRef["main"], byRef["feature/one"]
	if main == nil || one == nil {
		t.Fatalf("missing a branch: %v", byRef)
	}
	if main[3] != "me" || main[4] != "1" {
		t.Errorf("main owner/mine = %s/%s, want me/1", main[3], main[4])
	}
	if main[7] != "1" || main[8] != "1" || one[7] != "0" || one[8] != "0" {
		t.Errorf("isDefault/isCurrent wrong: main %s/%s one %s/%s", main[7], main[8], one[7], one[8])
	}
	if main[5] != "NONE" || main[11] != "0" {
		t.Errorf("main pr/remote = %s/%s", main[5], main[11])
	}
	// A tab would have shifted every column after the subject.
	if one[10] != "a subject" {
		t.Errorf("subject = %q, want it cut at the tab", one[10])
	}
	if one[13] != "1" || one[14] != "0" || main[13]+"/"+main[14] != "0/0" {
		t.Errorf("ahead/behind: one %s/%s main %s/%s", one[13], one[14], main[13], main[14])
	}
	if one[6] != "0" {
		t.Errorf("feature/one ready = %s before any worktree", one[6])
	}

	// A worktree directory for the ref makes it ready.
	os.MkdirAll(filepath.Join(p.Worktrees, "feature-one"), 0o755)
	for _, r := range Branches(p) {
		if r.Ref == "feature/one" && !r.Ready {
			t.Error("feature/one not ready with its worktree present")
		}
	}
}

func TestWorktreeSlugCollision(t *testing.T) {
	p := fixture(t)
	os.MkdirAll(p.MetaDir, 0o755)
	if got := WorktreeSlug(p, "feat/a-b"); got != "feat-a-b" {
		t.Fatalf("first ref slug = %s", got)
	}
	os.WriteFile(filepath.Join(p.MetaDir, "feat-a-b.ref"), []byte("feat/a-b\n"), 0o644)
	if got := WorktreeSlug(p, "feat/a-b"); got != "feat-a-b" {
		t.Errorf("owner keeps its slug, got %s", got)
	}
	if got := WorktreeSlug(p, "feat/a+b"); got != "feat-a-b-6a74" {
		t.Errorf("second ref slug = %s, want feat-a-b-6a74", got)
	}
}
