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
	"fmt"
	"strconv"
	"strings"
	"time"

	"github.com/aosmcleod/runbranch/engine/internal/config"
	"github.com/aosmcleod/runbranch/engine/internal/pathx"
)

// Branch is one row of `branches`:
//
//	ref  age  ts  owner  mine  pr  ready  isDefault  isCurrent  prNumber
//	subject  remote  checkedOutAt  ahead  behind
//
// ahead and behind are commits relative to the trunk, and are BOTH empty on a
// git too old for `%(ahead-behind:)` — never faked as 0/0. "No answer" and
// "level with the trunk" are different things, and only one of them means
// the branch is disposable.
type Branch struct {
	Ref, Age          string
	TS                int64
	Owner             string
	Mine              bool
	PR                string
	Ready, IsDefault  bool
	IsCurrent         bool
	PRNumber, Subject string
	IsRemote          bool
	CheckedOutAt      string
	Ahead, Behind     string
}

func b01(b bool) string {
	if b {
		return "1"
	}
	return "0"
}

// TSV is the row as the app parses it: 15 fields, empty ones kept.
func (b Branch) TSV() string {
	return strings.Join([]string{
		b.Ref, b.Age, strconv.FormatInt(b.TS, 10), b.Owner, b01(b.Mine), b.PR,
		b01(b.Ready), b01(b.IsDefault), b01(b.IsCurrent), b.PRNumber, b.Subject,
		b01(b.IsRemote), b.CheckedOutAt, b.Ahead, b.Behind,
	}, "\t")
}

// Age is how long ago a commit was, in the one unit that reads best: minutes
// under an hour, hours under a day, days under 30, months of 30 days after.
func Age(now, ts int64) string {
	d := now - ts
	switch {
	case d < 3600:
		return fmt.Sprintf("%dm", d/60)
	case d < 86400:
		return fmt.Sprintf("%dh", d/3600)
	case d < 2592000:
		return fmt.Sprintf("%dd", d/86400)
	}
	return fmt.Sprintf("%dmo", d/2592000)
}

// Branches is the branch table.
//
// Local branches first, then remote-tracking branches with no local twin —
// reviewing a colleague's pull request is the whole use case, and it does not
// start with a local branch. Each group newest first.
func Branches(p *config.Project) []Branch {
	now := time.Now().Unix()
	cur := CurrentBranch(p)
	foreign := ForeignWorktrees(p)
	trunk := TrunkRef(p)
	hasAB := HasAheadBehind(p, trunk)
	EnsurePRCache(p)
	prs := ReadPRCache(p)
	emails := MyEmails()

	// NUL between fields, not a tab: a tab is the one character a commit
	// subject can carry that would shift every column after it.
	format := "%(refname:short)%00%(authoremail)%00%(committerdate:unix)%00%(authorname)"
	if hasAB {
		format += "%00%(ahead-behind:" + trunk + ")"
	}
	format += "%00%(contents:subject)"

	mine := func(email string) bool {
		for _, e := range emails {
			if strings.Contains(email, e) {
				return true
			}
		}
		return false
	}

	var out []Branch
	seen := map[string]bool{}
	emit := func(ref, key, email, ts, who, ab, subject string, remote bool) {
		b := Branch{Ref: ref, IsRemote: remote}
		b.TS, _ = strconv.ParseInt(ts, 10, 64)
		b.Age = Age(now, b.TS)
		b.Mine = mine(email)
		if b.Mine {
			b.Owner = "me"
		} else {
			b.Owner = strings.SplitN(strings.ReplaceAll(who, "\t", " "), " ", 2)[0]
		}
		b.PR = "NONE"
		b.Subject = subject
		if pr, ok := prs[key]; ok {
			b.PR, b.PRNumber, b.Subject = pr.State, pr.Number, pr.Title
		}
		// A tab would shift every column after it, and a subject was the
		// last field the bash engine's awk read, so it ended at the tab.
		if i := strings.IndexByte(b.Subject, '\t'); i >= 0 {
			b.Subject = b.Subject[:i]
		}
		// The worktree this ref would use, digest suffix and all. The bash
		// engine slugged without stripping origin/, so a remote branch never
		// read as ready.
		b.Ready = pathx.IsDir(WorktreePath(p, ref))
		b.IsDefault = ref == p.DefaultBranch()
		b.IsCurrent = ref == cur
		b.CheckedOutAt = foreign[ref]
		if f := strings.Fields(ab); len(f) == 2 {
			b.Ahead, b.Behind = f[0], f[1]
		}
		out = append(out, b)
	}

	rows := func(prefix string) [][]string {
		s, err := Git(p.Repo(), "for-each-ref", "--sort=-committerdate", "--format="+format, prefix)
		if err != nil || s == "" {
			return nil
		}
		var rs [][]string
		for _, line := range strings.Split(s, "\n") {
			line = strings.TrimRight(line, "\r")
			f := strings.Split(line, "\x00")
			want := 5
			if hasAB {
				want = 6
			}
			for len(f) < want {
				f = append(f, "")
			}
			if !hasAB {
				f = append(f[:4], append([]string{""}, f[4:]...)...)
			}
			rs = append(rs, f)
		}
		return rs
	}

	for _, f := range rows("refs/heads") {
		seen[f[0]] = true
		emit(f[0], f[0], f[1], f[2], f[3], f[4], f[5], false)
	}
	for _, f := range rows("refs/remotes/origin") {
		short := strings.TrimPrefix(f[0], "origin/")
		if short == "" || f[0] == "origin" || f[0] == "origin/HEAD" {
			continue
		}
		if seen[short] { // a local branch already stands for it
			continue
		}
		emit(f[0], short, f[1], f[2], f[3], f[4], f[5], true)
	}
	return out
}
