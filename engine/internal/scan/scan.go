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

// Package scan is how a project comes to be declared, and how it stops
// being: finding repos, guessing their config, writing it, removing it, and
// checking that what is declared resolves.
package scan

import (
	"encoding/json"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"time"

	"github.com/aosmcleod/runbranch/engine/internal/config"
	"github.com/aosmcleod/runbranch/engine/internal/gitx"
	"github.com/aosmcleod/runbranch/engine/internal/pathx"
	"github.com/aosmcleod/runbranch/engine/internal/run"
	"github.com/aosmcleod/runbranch/engine/internal/ui"
)

// ProjectName is the id a repo is declared under: its directory name lower-
// cased, with anything outside [a-z0-9._-] made a dash, byte by byte.
func ProjectName(dir string) string {
	b := []byte(filepath.Base(dir))
	for i, c := range b {
		if c >= 'A' && c <= 'Z' {
			c += 'a' - 'A'
		}
		if !(c >= 'a' && c <= 'z' || c >= '0' && c <= '9' || c == '.' || c == '_' || c == '-') {
			c = '-'
		}
		b[i] = c
	}
	return string(b)
}

func trimSlash(dir string) string {
	if len(dir) > 1 {
		dir = strings.TrimRight(dir, `/\`)
	}
	return dir
}

// DefaultRoot is where scan looks when not told.
func DefaultRoot() string { return filepath.Join(config.Home, "Development") }

// Scan lists git repos under root that are not already declared, as
// name<TAB>path. Only .git DIRECTORIES count: a worktree or a submodule has
// a .git file, and is not a project of its own.
func Scan(root string) {
	root = pathx.Native(root)
	if !pathx.IsDir(root) {
		ui.Die(root+" does not exist.", "runbranch scan <directory>")
	}
	var repos []string
	depth := func(p string) int {
		rel, err := filepath.Rel(root, p)
		if err != nil || rel == "." {
			return 0
		}
		return len(strings.Split(rel, string(filepath.Separator)))
	}
	_ = filepath.WalkDir(root, func(p string, d fs.DirEntry, err error) error {
		if err != nil {
			if d != nil && d.IsDir() {
				return fs.SkipDir
			}
			return nil
		}
		if !d.IsDir() {
			return nil
		}
		if d.Name() == "node_modules" && p != root {
			return fs.SkipDir
		}
		if d.Name() == ".git" {
			if depth(p) <= 3 {
				repos = append(repos, filepath.Dir(p))
			}
			return fs.SkipDir
		}
		if depth(p) >= 3 {
			return fs.SkipDir
		}
		return nil
	})
	sort.Strings(repos)

	var confs []string
	for _, n := range config.ConfFiles() {
		if b, err := os.ReadFile(filepath.Join(config.ProjectsDir, n+".conf")); err == nil {
			confs = append(confs, string(b))
		}
	}
	var b strings.Builder
	for _, d := range repos {
		name := ProjectName(d)
		if pathx.IsFile(filepath.Join(config.ProjectsDir, name+".conf")) {
			continue
		}
		declared := false
		for _, c := range confs {
			if strings.Contains(c, `"`+d+`"`) {
				declared = true
				break
			}
		}
		if declared {
			continue
		}
		fmt.Fprintf(&b, "%s\t%s\n", name, d)
	}
	ui.Out(b.String())
}

// Nobody should face a blank config file. Almost everything a project needs
// is already declared somewhere in the repo: the lockfile names the package
// manager, package.json names the scripts, the dev script usually names its
// own port, a Procfile names the processes, compose names the services, and
// .nvmrc or mise.toml names the toolchain.
//
// It guesses. It says so, and the guesses are commented so they are easy to
// correct. Better a wrong port you can see than a blank file you must
// research.

var lockfiles = []struct{ file, pm, install string }{
	{"pnpm-lock.yaml", "pnpm", "pnpm install --frozen-lockfile"},
	{"bun.lockb", "bun", "bun install --frozen-lockfile"},
	{"yarn.lock", "yarn", "yarn install --immutable"},
	{"package-lock.json", "npm", "npm ci"},
	{"Gemfile.lock", "bundle", "bundle install"},
	{"uv.lock", "uv", "uv sync"},
	{"poetry.lock", "poetry", "poetry install"},
	{"Cargo.lock", "cargo", ""},
}

// pkgScript is a value out of package.json's scripts.
func pkgScript(dir, key string) string {
	b, err := os.ReadFile(filepath.Join(dir, "package.json"))
	if err != nil {
		return ""
	}
	var pkg struct {
		Scripts map[string]any `json:"scripts"`
	}
	if json.Unmarshal(b, &pkg) != nil {
		return ""
	}
	if s, ok := pkg.Scripts[key].(string); ok {
		return s
	}
	return ""
}

var portFlag = regexp.MustCompile(`(--port[= ]|(^| )-p )([0-9]{2,5})`)

// PortFromCommand reads --port 3000, --port=3000 or -p 3000 out of a script.
// The last one wins, as the greedy sed it replaces found.
func PortFromCommand(s string) string {
	m := portFlag.FindAllStringSubmatch(s, -1)
	if len(m) == 0 {
		return ""
	}
	return m[len(m)-1][3]
}

// PortFromFramework is a framework's default, for when the script does not
// say.
func PortFromFramework(s string) string {
	for _, f := range []struct{ sub, port string }{
		{"next", "3000"}, {"vite", "5173"}, {"astro", "4321"}, {"remix", "3000"}, {"nuxt", "3000"},
		{"storybook", "6006"}, {"rails", "3000"}, {"puma", "3000"}, {"django", "8000"}, {"manage.py", "8000"},
	} {
		if strings.Contains(s, f.sub) {
			return f.port
		}
	}
	return ""
}

var composeService = regexp.MustCompile(`^  [a-zA-Z0-9_-]+:`)
var topLevel = regexp.MustCompile(`^[a-z]+:`)
var wantedService = regexp.MustCompile(`^(postgres|postgresql|mysql|mariadb|redis|valkey|mongo|mongodb|elasticsearch|rabbitmq)`)

// composeServices are the backing services worth waiting for — only from the
// services: block. A naive grep also matched the volumes: block, where
// `postgres-data` sits at the same indent and is not a service.
func composeServices(file string) string {
	b, err := os.ReadFile(file)
	if err != nil {
		return ""
	}
	section := ""
	var out []string
	for _, line := range strings.Split(strings.ReplaceAll(string(b), "\r\n", "\n"), "\n") {
		if topLevel.MatchString(line) {
			section = strings.Fields(line)[0]
			continue
		}
		if section == "services:" && composeService.MatchString(line) {
			name := strings.TrimSuffix(strings.Fields(line)[0], ":")
			if wantedService.MatchString(name) {
				out = append(out, name)
			}
		}
	}
	return strings.Join(out, " ")
}

// Propose prints a config guessed from a repo.
func Propose(dir string) string {
	dir = trimSlash(dir)
	if !pathx.IsDir(filepath.Join(dir, ".git")) {
		ui.Die(dir+" is not a git repository.", "runbranch propose <path-to-repo>")
	}
	dir = pathx.Long(dir)
	name := ProjectName(dir)

	pm, install := "", ""
	for _, l := range lockfiles {
		if pathx.IsFile(filepath.Join(dir, l.file)) {
			pm, install = l.pm, l.install
			break
		}
	}

	// The script to run. Not every repo calls it `dev` — a component library
	// is as likely to call it `docs` or `storybook` — and the target should be
	// named after whichever one it actually is.
	key, raw := "dev", ""
	for _, k := range []string{"dev", "start", "docs", "storybook", "serve"} {
		if raw = pkgScript(dir, k); raw != "" {
			key = k
			break
		}
	}
	dev := ""
	if raw != "" && pm != "" {
		dev = pm + " run " + key
	}
	fromCmd := PortFromCommand(raw)
	port := fromCmd
	if port == "" {
		port = PortFromFramework(raw)
	}
	if port == "" {
		port = "3000"
	}

	runtime := ""
	switch {
	case pathx.IsFile(filepath.Join(dir, "mise.toml")) || pathx.IsFile(filepath.Join(dir, ".mise.toml")):
		runtime = "mise"
	case pathx.IsFile(filepath.Join(dir, ".tool-versions")):
		runtime = "asdf"
	case pathx.IsFile(filepath.Join(dir, ".nvmrc")):
		runtime = "fnm"
	}

	defbr, _ := gitx.Git(dir, "symbolic-ref", "--short", "refs/remotes/origin/HEAD")
	defbr = strings.TrimPrefix(defbr, "origin/")
	if defbr == "" {
		defbr, _ = gitx.Git(dir, "rev-parse", "--abbrev-ref", "HEAD")
	}
	if defbr == "" {
		defbr = "main"
	}

	// Gitignored config a worktree would not get.
	var copies []string
	for _, f := range []string{".env.local", ".env", ".env.development"} {
		if pathx.IsFile(filepath.Join(dir, f)) && gitx.Quiet(dir, "check-ignore", "-q", f) == nil {
			copies = append(copies, f)
		}
	}

	composeFile, svc := "", ""
	for _, f := range []string{"docker-compose.yml", "compose.yaml", "compose.yml", "docker-compose.yaml"} {
		if pathx.IsFile(filepath.Join(dir, f)) {
			composeFile = f
			svc = composeServices(filepath.Join(dir, f))
			break
		}
	}

	repo := dir
	if config.Home != "" && pathx.Within(dir, config.Home) {
		repo = "~" + dir[len(config.Home):]
	}

	var b strings.Builder
	fmt.Fprintf(&b, "# Proposed by `runbranch propose` on %s.\n", time.Now().Format("2006-01-02"))
	b.WriteString("# Every value is a guess read out of the repo. Correct anything wrong,\n")
	fmt.Fprintf(&b, "# then check it with: runbranch doctor %s\n\n", name)
	fmt.Fprintf(&b, "NAME=%s\n", config.Quote(filepath.Base(dir)))
	fmt.Fprintf(&b, "REPO=%s\n", config.Quote(repo))
	fmt.Fprintf(&b, "DEFAULT_BRANCH=%s\n", config.Quote(defbr))
	if install != "" {
		fmt.Fprintf(&b, "INSTALL=\"%s\"\n", install)
	}
	if runtime != "" {
		fmt.Fprintf(&b, "RUNTIME=\"%s\"          # pinned in the repo\n", runtime)
	}
	if len(copies) > 0 {
		fmt.Fprintf(&b, "COPY_FILES=\"%s\"    # gitignored, so a worktree lacks it\n", strings.Join(copies, " "))
	}
	if svc != "" {
		fmt.Fprintf(&b, "COMPOSE_FILE=\"%s\"\n", composeFile)
		fmt.Fprintf(&b, "COMPOSE_PROJECT=\"%s\"\n", name)
		fmt.Fprintf(&b, "COMPOSE_SERVICES=\"%s\"\n", svc)
	}
	if pathx.IsFile(filepath.Join(dir, "Procfile")) {
		b.WriteString("\n# This repo has a Procfile, which already lists what to run.\n")
		b.WriteString("PROCFILE=1\n")
	} else {
		from := "the framework default"
		if fromCmd != "" {
			from = "the dev script"
		}
		fmt.Fprintf(&b, "\n# port guessed from %s\n", from)
		if dev != "" {
			fmt.Fprintf(&b, "TARGETS=%s\n", config.Quote(fmt.Sprintf("%s:%s:/:%s", key, port, dev)))
		} else {
			// Nothing in the repo said how to run it. Better an obvious
			// blank than a plausible command that fails minutes later.
			b.WriteString("# Nothing in this repo says how to run it -- no lockfile, no\n")
			fmt.Fprintf(&b, "# package.json script. Fill this in, then: runbranch doctor %s\n", name)
			fmt.Fprintf(&b, "TARGETS=\"dev:%s:/:REPLACE-ME\"\n", port)
		}
	}
	if strings.Contains(raw, "--open") {
		b.WriteString("OPENS_ITSELF=1        # the dev server opens a browser itself\n")
	}
	b.WriteString("SYMBOL=\"shippingbox\"\n")
	return b.String()
}

// Add proposes a config and writes it. Never overwrites: a config you have
// corrected is worth more than a fresh guess.
func Add(dir string) {
	dir = trimSlash(dir)
	if !pathx.IsDir(filepath.Join(dir, ".git")) {
		ui.Die(dir+" is not a git repository.", "runbranch add <path-to-repo>")
	}
	name := ProjectName(dir)
	out := filepath.Join(config.ProjectsDir, name+".conf")
	if pathx.Exists(out) {
		ui.Die(name+" is already declared.", ui.OpenFix(out))
	}
	_ = os.MkdirAll(config.ProjectsDir, 0o755)
	var text string
	if f := ui.Catch(func() { text = Propose(dir) }); f != nil {
		ui.Die("Could not read "+dir+".", fmt.Sprintf("runbranch propose '%s'", dir))
	}
	if err := os.WriteFile(out, []byte(text), 0o644); err != nil {
		_ = os.Remove(out)
		ui.Die("Could not read "+dir+".", fmt.Sprintf("runbranch propose '%s'", dir))
	}
	ui.Out(fmt.Sprintf("%s\t%s\n", name, out))
}

// Remove deletes a project's declaration and the state Runbranch created for
// it.
//
// Deliberately never touches the repository. That is the user's actual work
// and it is not ours to delete; a project is a config file plus whatever we
// put in RB_HOME, and both of those we made.
func Remove(name string) {
	conf := filepath.Join(config.ProjectsDir, name+".conf")
	if !pathx.IsFile(conf) {
		ui.Die("No such project: "+name, "runbranch projects")
	}
	// Refuse while it is running. Removing the config underneath a live run
	// orphans the servers with nothing left that knows how to stop them.
	//
	// Asked through Load and the state it knows about rather than by
	// rebuilding the path here: an earlier version looked for a file called
	// "current" when the state file is called "state", so the guard never
	// fired once.
	p := config.Load(name)
	if run.IsRunning(p) {
		ui.Die(name+" is running.", config.Self+" stop "+name)
	}
	_ = os.Remove(conf)
	// Worktrees, logs and metadata — all of it ours. Leashed the same way
	// worktree deletion is: this is a recursive delete built from a name, and
	// a name that came out empty would take every project's state with it.
	// WorkRoot, not a path rebuilt here, for the reason directly above.
	if name != "" && pathx.IsDir(p.WorkRoot) {
		if !pathx.Under(p.WorkRoot, config.RBHome) {
			ui.Die(fmt.Sprintf("Refusing to delete %s — not a project directory under %s.", p.WorkRoot, config.RBHome),
				"Remove it by hand if that is really what you want.")
		}
		_ = pathx.RemoveAll(p.WorkRoot)
	}
	// And the favourite pin, which lives outside the config on purpose.
	config.DropFavourite(name)
	ui.Info(fmt.Sprintf("Removed %s. Its repository was not touched.", name))
}
