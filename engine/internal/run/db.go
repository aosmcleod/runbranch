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
	"bytes"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"

	"github.com/aosmcleod/runbranch/engine/internal/config"
	"github.com/aosmcleod/runbranch/engine/internal/gitx"
	"github.com/aosmcleod/runbranch/engine/internal/pathx"
	"github.com/aosmcleod/runbranch/engine/internal/ui"
)

// Per-run databases.
//
// Two branches with divergent migrations sharing one database is the oldest
// problem this tool has: migrating for one silently rewrites the other, and
// nothing rolls it back. A branch can have its own database instead — created
// with the worktree, migrated and seeded from scratch, dropped when the
// worktree goes.
//
// Postgres only, and declared rather than assumed: a project says which
// variable carries its URL, because only it knows.

// compose pins `docker compose -p`. compose derives its name from the
// directory it runs in, so from a worktree it would create a SECOND project
// with its own empty volumes — and then collide on any fixed container_name.
func compose(p *config.Project, wt string, args ...string) *exec.Cmd {
	all := append([]string{"compose", "-p", p.Get("COMPOSE_PROJECT"), "-f", filepath.Join(wt, p.Get("COMPOSE_FILE"))}, args...)
	return exec.Command("docker", all...)
}

// pgContainer is the compose container id of the postgres service, so psql
// runs inside it rather than requiring a client on the host.
func pgContainer(p *config.Project, wt string) string {
	out, err := compose(p, wt, "ps", "-q", "postgres").Output()
	if err != nil {
		return ""
	}
	return strings.TrimSpace(strings.SplitN(strings.ReplaceAll(string(out), "\r", ""), "\n", 2)[0])
}

var dbNameRE = regexp.MustCompile(`^.*/([^/?]+)(\?.*)?$`)

// dbNameFromURL: postgresql://user:pass@host:port/dbname -> dbname.
func dbNameFromURL(url string) string {
	if m := dbNameRE.FindStringSubmatch(url); m != nil {
		return m[1]
	}
	return url
}

// dbSourceURL is the URL as the main checkout has it, which is the one to
// derive from: the last VAR= line of the first COPY_FILES entry that exists.
// (Kept for parity: the first existing file answers, even when it lacks VAR.)
func dbSourceURL(p *config.Project, v string) string {
	for _, f := range p.Words("COPY_FILES") {
		path := filepath.Join(p.Repo(), f)
		if !pathx.IsFile(path) {
			continue
		}
		b, _ := os.ReadFile(path)
		val := ""
		for _, line := range strings.Split(strings.ReplaceAll(string(b), "\r\n", "\n"), "\n") {
			if strings.HasPrefix(line, v+"=") {
				val = strings.TrimPrefix(line, v+"=")
			}
		}
		return strings.NewReplacer(`"`, "", `'`, "").Replace(val)
	}
	return ""
}

// dbNameFor is <base>_rb_<slug>. Postgres identifiers cap at 63 bytes, and a
// branch slug can be longer.
func dbNameFor(base, slug string) string {
	b := []byte(base + "_rb_" + slug)
	for i, c := range b {
		if !(c >= 'A' && c <= 'Z' || c >= 'a' && c <= 'z' || c >= '0' && c <= '9' || c == '_') {
			b[i] = '_'
		}
	}
	if len(b) > 63 {
		b = b[:63]
	}
	return string(b)
}

var urlUserRE = regexp.MustCompile(`^[a-z]+://([^:]+):.*`)

func adminUser(p *config.Project, url string) string {
	if u := p.Get("DB_ADMIN_USER"); u != "" {
		return u
	}
	return urlUserRE.ReplaceAllString(url, "$1")
}

func psql(p *config.Project, cid, url, sql string) (string, error) {
	cmd := exec.Command("docker", "exec", cid, "psql", "-U", adminUser(p, url), "-d", "postgres", "-v", "ON_ERROR_STOP=1", "-tAc", sql)
	var out bytes.Buffer
	cmd.Stdout = &out
	err := cmd.Run()
	return strings.TrimSpace(out.String()), err
}

func createFix(p *config.Project, cid, name string) string {
	user := p.Get("DB_ADMIN_USER")
	if user == "" {
		user = "postgres"
	}
	return fmt.Sprintf(`docker exec -it %s psql -U %s -c 'CREATE DATABASE "%s"'`, cid, user, name)
}

// setupRunDatabase creates the run's database if it is not already there,
// and points the worktree at it.
func setupRunDatabase(p *config.Project, wt, ref string) {
	vars := p.Words("DB_URL_VARS")
	if len(vars) == 0 {
		return
	}
	first := vars[0]
	url := dbSourceURL(p, first)
	if url == "" {
		copies := p.Get("COPY_FILES")
		if copies == "" {
			copies = "<COPY_FILES>"
		}
		firstCopy := ""
		if w := p.Words("COPY_FILES"); len(w) > 0 {
			firstCopy = w[0]
		}
		ui.Die(fmt.Sprintf("%s declares DB_URL_VARS=%q but %s is not set in %s.", p.Name(), p.Get("DB_URL_VARS"), first, copies),
			fmt.Sprintf("grep %s %s", first, filepath.Join(p.Repo(), firstCopy)))
	}
	base := dbNameFromURL(url)
	name := dbNameFor(base, gitx.WorktreeSlug(p, ref))

	ui.Step("Database  " + name)
	cid := pgContainer(p, wt)
	if cid == "" {
		ui.Die(p.Name()+" declares DB_URL_VARS but has no running postgres service to create the database in.",
			fmt.Sprintf("check COMPOSE_SERVICES in %s names postgres", p.File))
	}
	exists, _ := psql(p, cid, url, fmt.Sprintf("SELECT 1 FROM pg_database WHERE datname='%s'", name))
	if exists == "1" {
		ui.OK("already exists — reusing it")
	} else {
		if tpl := p.Get("DB_TEMPLATE"); tpl != "" {
			ui.Info("creating from template " + tpl)
			if _, err := psql(p, cid, url, fmt.Sprintf(`CREATE DATABASE "%s" TEMPLATE "%s"`, name, tpl)); err != nil {
				ui.Die(fmt.Sprintf("Could not create %s from template %s.", name, tpl), createFix(p, cid, name))
			}
		} else {
			ui.Info("creating")
			if _, err := psql(p, cid, url, fmt.Sprintf(`CREATE DATABASE "%s"`, name)); err != nil {
				ui.Die(fmt.Sprintf("Could not create %s.", name), createFix(p, cid, name))
			}
		}
		ui.OK("created")
	}

	// Point the worktree's own copies at it. Rewriting the file rather than
	// relying on an exported variable, because dotenv loaders differ on which
	// wins and a file you can read is easier to trust than a precedence rule.
	//
	// Kept for parity: every variable gets the first variable's URL, with its
	// database swapped.
	newURL := regexp.MustCompile(`/[^/?]+(\?.*)?$`).ReplaceAllStringFunc(url, func(m string) string {
		q := ""
		if i := strings.IndexByte(m, '?'); i >= 0 {
			q = m[i:]
		}
		return "/" + name + q
	})
	for _, v := range vars {
		for _, f := range p.Words("COPY_FILES") {
			path := filepath.Join(wt, f)
			if !pathx.IsFile(path) {
				continue
			}
			rewriteVar(path, v, newURL)
		}
	}
	ui.OK(fmt.Sprintf("%s now points at %s", p.Get("COPY_FILES"), name))
}

// rewriteVar replaces every VAR= line with VAR=value, literally: the bash
// engine did this with sed and a # delimiter, so a # or & in a password broke
// it. A CRLF file stays CRLF.
func rewriteVar(path, v, value string) {
	b, err := os.ReadFile(path)
	if err != nil {
		return
	}
	lines := strings.Split(string(b), "\n")
	for i, line := range lines {
		if strings.HasPrefix(line, v+"=") {
			cr := ""
			if strings.HasSuffix(line, "\r") {
				cr = "\r"
			}
			lines[i] = v + "=" + value + cr
		}
	}
	_ = os.WriteFile(path, []byte(strings.Join(lines, "\n")), 0o644)
}

// dropRunDatabase drops a worktree's database with the worktree. Never the
// base database, whatever the name arithmetic says.
//
// The bash engine let a missing postgres end remove-worktree silently with
// exit 1, before anything was removed — and on this path COMPOSE_PROJECT was
// never defaulted, so a config that relied on the default always failed. A
// database that cannot be dropped is now said, and the worktree still goes.
func dropRunDatabase(p *config.Project, wt, ref string) {
	vars := p.Words("DB_URL_VARS")
	if len(vars) == 0 {
		return
	}
	url := dbSourceURL(p, vars[0])
	if url == "" {
		return
	}
	base := dbNameFromURL(url)
	name := dbNameFor(base, gitx.WorktreeSlug(p, ref))
	if name == base {
		return
	}
	if p.Get("COMPOSE_PROJECT") == "" {
		p.Set("COMPOSE_PROJECT", p.ID)
	}
	cid := pgContainer(p, wt)
	if cid == "" {
		ui.Warn(fmt.Sprintf("could not drop %s: no running postgres service to drop it from", name))
		return
	}
	if _, err := psql(p, cid, url, fmt.Sprintf(`DROP DATABASE IF EXISTS "%s" WITH (FORCE)`, name)); err != nil {
		ui.Warn(fmt.Sprintf("could not drop %s", name))
		return
	}
	ui.OK("dropped " + name)
}
