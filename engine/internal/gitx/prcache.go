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
	"errors"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"time"

	"github.com/aosmcleod/runbranch/engine/internal/config"
)

// PR is one pull request from the cache.
type PR struct {
	State, Number, Title string
}

// RefreshPRCache asks GitHub for the last 300 pull requests.
//
// Why GitHub at all: `git branch --merged` looks like it should say whether a
// branch was merged, and for a merge-commit PR it does. But a SQUASHED merge
// rewrites the commits, so they are never reachable from the default branch
// and git can never name it.
//
// Written through a temporary file and a rename, so a reader — possibly a
// listing running at the same moment — never sees half a cache.
func RefreshPRCache(p *config.Project) error {
	gh, err := exec.LookPath("gh")
	if err != nil {
		return err
	}
	slug := GHRepo(p)
	if slug == "" {
		return errors.New("no GitHub remote")
	}
	if err := os.MkdirAll(p.WorkRoot, 0o755); err != nil {
		return err
	}
	// Title and number too: a branch name says what someone called the work,
	// the PR title says what it is.
	out, err := exec.Command(gh, "-R", slug, "pr", "list", "--state", "all", "--limit", "300",
		"--json", "headRefName,state,number,title,author",
		"--jq", `.[] | [.headRefName, .state, (.number|tostring), .title, .author.login] | @tsv`).Output()
	if err != nil || len(out) == 0 {
		return errors.New("gh returned nothing")
	}
	data := strings.ReplaceAll(string(out), "\r\n", "\n")
	return config.WriteAtomic(p.PRCache, []byte(data))
}

// EnsurePRCache is instant when a cache exists and refreshes behind your back
// when it is stale. It never blocks a listing on the network, except the very
// first time, when there is nothing to show without it.
//
// The refresh is a detached child process rather than a goroutine: this
// engine exits as soon as it has printed the listing, and a goroutine would
// die with it.
func EnsurePRCache(p *config.Project) {
	fi, err := os.Stat(p.PRCache)
	if err != nil || fi.Size() == 0 {
		_ = RefreshPRCache(p)
		return
	}
	ttl := 900 // 15 minutes
	if v, err := strconv.Atoi(os.Getenv("RB_PR_TTL")); err == nil {
		ttl = v
	}
	if time.Since(fi.ModTime()) > time.Duration(ttl)*time.Second && config.Self != "" {
		_ = spawnDetached(config.Self, "refresh-pr-cache", p.ID)
	}
}

// ReadPRCache reads the cache, keyed by head branch name.
func ReadPRCache(p *config.Project) map[string]PR {
	out := map[string]PR{}
	b, err := os.ReadFile(p.PRCache)
	if err != nil {
		return out
	}
	for _, line := range strings.Split(string(b), "\n") {
		line = strings.TrimRight(line, "\r")
		if line == "" {
			continue
		}
		f := strings.Split(line, "\t")
		for len(f) < 4 {
			f = append(f, "")
		}
		// A later row for the same branch wins, as awk's assignment did.
		out[f[0]] = PR{State: f[1], Number: f[2], Title: f[3]}
	}
	return out
}
