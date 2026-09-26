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

package config

import (
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"

	"github.com/aosmcleod/runbranch/engine/internal/pathx"
	"github.com/aosmcleod/runbranch/engine/internal/ui"
)

// A project is a small file in the projects directory. Everything except
// NAME, REPO and TARGETS is optional, which is the point: most projects are
// "install, run one command, open a URL", and only pay for the machinery they
// actually use.

// Project is one loaded, validated config.
type Project struct {
	ID     string // the file name without .conf; how the CLI names it
	File   string // the local .conf
	InRepo string // the in-repo .runbranch, when there is one

	vals map[string]string

	// PortOffset is added to every declared port for a run. It starts as the
	// config's PORT_OFFSET; `run` replaces it, and reading run state restores
	// the offset the run was started with.
	//
	// Ports are declared in the config and that is deliberate — a stack that
	// bakes its origins in (an OAuth origin, a CORS allowlist, an API URL
	// compiled into the client) has to stay where it was told. But framework
	// defaults collide across projects, so a run can be shifted wholesale.
	// Every target moves by the same amount, so the relative layout a stack
	// may depend on survives: api 4000 and web 3000 become 4001 and 3001.
	PortOffset int
	// InPlace runs in the real checkout rather than a worktree. See run.
	InPlace bool

	Targets []Target

	WorkRoot, Worktrees, LogDir, StateFile, PRCache, MetaDir string
}

// Target is one TARGETS line: name:port:healthpath:command. The command may
// contain colons, so only the first three are separators.
type Target struct {
	Name, Port, Health, Command string
}

// Every key and its default. Reset on every load so a second load cannot
// inherit the first, and so the in-repo file and the local one both start
// from the same place.
var defaults = map[string]string{
	"PORT_OFFSET": "0", "IN_PLACE": "0",
	"NAME": "", "REPO": "", "DEFAULT_BRANCH": "main", "INSTALL": "", "COPY_FILES": "",
	"COMPOSE_FILE": "docker-compose.yml", "COMPOSE_PROJECT": "", "COMPOSE_SERVICES": "",
	"MIGRATE": "", "SEED": "", "TARGETS": "", "ALWAYS": "", "PRESETS": "", "OPENS_ITSELF": "0",
	"SYMBOL": "", "PROCFILE": "0", "PORT_BASE": "5000", "RUNTIME": "", "PORTS": "fixed",
	"DB_URL_VARS": "", "DB_TEMPLATE": "", "DB_ADMIN_USER": "",
}

// Get is a key's merged value.
func (p *Project) Get(key string) string { return p.vals[key] }

// Set overrides a key for this process only (COMPOSE_PROJECT's default).
func (p *Project) Set(key, value string) { p.vals[key] = value }

func (p *Project) Name() string          { return p.vals["NAME"] }
func (p *Project) Repo() string          { return p.vals["REPO"] }
func (p *Project) DefaultBranch() string { return p.vals["DEFAULT_BRANCH"] }

// Words splits a space-separated key (COPY_FILES, ALWAYS, DB_URL_VARS...).
func (p *Project) Words(key string) []string { return strings.Fields(p.vals[key]) }

func readConf(path string) ([]Assign, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	return Parse(string(b))
}

// Load reads, layers and validates a project, dying with the reason and the
// fix when it cannot.
func Load(name string) *Project {
	file := filepath.Join(ProjectsDir, name+".conf")
	if !pathx.IsFile(file) {
		ui.Die(fmt.Sprintf("No project called %q.", name),
			fmt.Sprintf("ls %s    # or add %s.conf there", ProjectsDir, name))
	}

	// The whole file is parsed before any of it is applied. A half-applied
	// config reports whatever happened to be missing rather than the syntax
	// error that caused it: an unclosed quote used to report "sets no REPO".
	local, err := readConf(file)
	if err != nil {
		dieSyntax(name+".conf", file, err)
	}

	vals := apply(nil, local)

	// A project can keep its definition in the repo, where the team can
	// review it in a pull request and a new machine gets it from the clone.
	// The local file still wins, so one person can override a port or a
	// preset without changing what everyone else runs.
	//
	// The order is why: the local file is read first for REPO, the in-repo
	// file is then read as the base, and the local file applied again on top.
	repo := ExpandTilde(vals["REPO"])
	inRepo := ""
	if repo != "" && pathx.IsFile(filepath.Join(repo, ".runbranch")) {
		inRepo = pathx.Long(filepath.Join(repo, ".runbranch"))
		shared, err := readConf(inRepo)
		if err != nil {
			dieSyntax(inRepo, inRepo, err)
		}
		vals = apply(apply(nil, shared), local)
		// The second pass reset REPO to whatever the local file literally
		// says, so expand it again rather than leaving a tilde in a path.
		repo = ExpandTilde(vals["REPO"])
	}
	if repo != "" {
		repo = pathx.Long(repo)
	}
	vals["REPO"] = repo

	p := &Project{ID: name, File: file, InRepo: inRepo, vals: vals}
	if vals["NAME"] == "" {
		vals["NAME"] = name
	}
	if repo == "" {
		ui.Die(name+".conf sets no REPO.", "edit "+file)
	}
	// A directory, not merely present: a repo that is itself a linked
	// worktree has a .git FILE, and the bash engine refused those too.
	if !pathx.IsDir(filepath.Join(repo, ".git")) {
		ui.Die(fmt.Sprintf("%s: %s is not a git repository.", vals["NAME"], repo), "edit "+file)
	}
	// A Procfile already IS a target list: `name: command`, one per line.
	// Foreman assigns each process a PORT; so does this, and the port reaches
	// the server through its environment, like every other target's.
	if vals["PROCFILE"] == "1" && vals["TARGETS"] == "" {
		pf := filepath.Join(repo, "Procfile")
		vals["TARGETS"] = procfileTargets(pf, atoi(vals["PORT_BASE"]))
		if vals["TARGETS"] == "" {
			ui.Die(fmt.Sprintf("%s.conf sets PROCFILE=1 but %s has no processes.", name, pf), "cat "+pf)
		}
	}
	if vals["TARGETS"] == "" {
		ui.Die(name+".conf declares no TARGETS.", "edit "+file)
	}

	p.PortOffset = atoi(vals["PORT_OFFSET"])
	p.InPlace = vals["IN_PLACE"] == "1"
	p.Targets = parseTargets(vals["TARGETS"])

	p.WorkRoot = filepath.Join(RBHome, name)
	p.Worktrees = filepath.Join(p.WorkRoot, "worktrees")
	p.LogDir = filepath.Join(p.WorkRoot, "logs")
	p.StateFile = filepath.Join(p.WorkRoot, "state")
	p.PRCache = filepath.Join(p.WorkRoot, "prcache")
	p.MetaDir = filepath.Join(p.WorkRoot, "meta")
	return p
}

func dieSyntax(label, file string, err error) {
	detail := err.Error()
	if se, ok := err.(*SyntaxError); ok {
		detail = se.Error()
	}
	ui.Die(fmt.Sprintf("%s has a syntax error:\n  %s\n\nA config is shell, so an unclosed quote or stray backtick stops it being read.", label, detail),
		ui.EditFix(file))
}

func apply(vals map[string]string, as []Assign) map[string]string {
	if vals == nil {
		vals = make(map[string]string, len(defaults))
		for k, v := range defaults {
			vals[k] = v
		}
	}
	for _, a := range as {
		vals[a.Key] = a.Value
	}
	return vals
}

// atoi reads a number the way bash arithmetic would read a config value:
// anything that is not one counts as 0.
func atoi(s string) int {
	n, err := strconv.Atoi(strings.TrimSpace(s))
	if err != nil {
		return 0
	}
	return n
}

// procfileTargets turns a Procfile into TARGETS. Ports are assigned, not
// declared, because a Procfile never says: foreman's convention is a base
// incremented by 100 per process.
//
// The bash engine wrote `PORT=<n> <cmd>`, bash's env-prefix syntax, which
// cmd.exe does not understand. PORT goes through the environment instead, as
// it already did for every other target, so the command stays as written.
func procfileTargets(file string, base int) string {
	b, err := os.ReadFile(file)
	if err != nil {
		return ""
	}
	var out []string
	i := 0
	for _, line := range strings.Split(strings.ReplaceAll(string(b), "\r\n", "\n"), "\n") {
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		c := strings.IndexByte(line, ':')
		if c < 0 {
			continue
		}
		name, cmd := line[:c], strings.TrimLeft(line[c+1:], " ")
		port := base + i*100
		out = append(out, fmt.Sprintf("%s:%d:/:%s", name, port, cmd))
		i++
	}
	return strings.Join(out, "\n")
}

// parseTargets reads TARGETS. Empty lines and # lines are skipped; nothing is
// trimmed, so an indented line's name includes its indent, as it always did.
func parseTargets(s string) []Target {
	var out []Target
	for _, line := range strings.Split(s, "\n") {
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		parts := strings.SplitN(line, ":", 4)
		t := Target{Name: parts[0]}
		if len(parts) > 1 {
			t.Port = parts[1]
		}
		if len(parts) > 2 {
			t.Health = parts[2]
		}
		if len(parts) > 3 {
			t.Command = parts[3]
		}
		out = append(out, t)
	}
	return out
}

// Target returns the first target with this name; a repeated name was always
// won by its first line.
func (p *Project) Target(name string) (Target, bool) {
	for _, t := range p.Targets {
		if t.Name == name {
			return t, true
		}
	}
	return Target{}, false
}

// TargetNames lists every target, in order. Iterate these — never
// whitespace-split TARGETS, which yields fragments of commands, not names.
func (p *Project) TargetNames() []string {
	out := make([]string, 0, len(p.Targets))
	for _, t := range p.Targets {
		out = append(out, t.Name)
	}
	return out
}

// DeclaredPort is the port a target declares, or 0 when it declares none.
// `doctor` reports this one, since it is what is written in the file.
func (p *Project) DeclaredPort(name string) (int, bool) {
	t, ok := p.Target(name)
	if !ok || t.Port == "" {
		return 0, false
	}
	n, err := strconv.Atoi(strings.TrimSpace(t.Port))
	if err != nil {
		return 0, false
	}
	return n, true
}

// Port is the port a target actually listens on: declared plus the offset.
// Runtime paths — state, health polls, Open buttons — use this one. The
// declared one under an offset once sent the app's health poll to another
// project's server, which answered 200 while this run was dead.
func (p *Project) Port(name string) (int, bool) {
	d, ok := p.DeclaredPort(name)
	if !ok {
		return 0, false
	}
	return d + p.PortOffset, true
}

// PresetNames lists the presets. With none declared, each target is its own
// preset, plus "all" when there is more than one — so a single-server project
// needs no PRESETS line at all.
func (p *Project) PresetNames() []string {
	if p.vals["PRESETS"] != "" {
		var out []string
		for _, w := range strings.Fields(p.vals["PRESETS"]) {
			out = append(out, strings.SplitN(w, "=", 2)[0])
		}
		return out
	}
	names := p.TargetNames()
	if len(names) > 1 {
		names = append(names, "all")
	}
	return names
}

// PresetTargets is the target list a preset expands to, always with ALWAYS
// targets first.
//
// Kept for parity: a name that is neither a preset nor "all" expands to
// itself, as a single target, whether or not such a target exists.
func (p *Project) PresetTargets(want string) []string {
	var out []string
	found := false
	if p.vals["PRESETS"] != "" {
		for _, w := range strings.Fields(p.vals["PRESETS"]) {
			label, list := w, w
			if i := strings.IndexByte(w, '='); i >= 0 {
				label, list = w[:i], w[i+1:]
			}
			if label != want {
				continue
			}
			out = strings.Fields(strings.ReplaceAll(list, ",", " "))
			found = true
			break
		}
	}
	if !found || len(out) == 0 {
		if want == "all" {
			out = p.TargetNames()
		} else {
			out = strings.Fields(want)
		}
	}
	var final []string
	in := func(list []string, s string) bool {
		for _, x := range list {
			if x == s {
				return true
			}
		}
		return false
	}
	for _, t := range p.Words("ALWAYS") {
		if !in(out, t) {
			final = append(final, t)
		}
	}
	return append(final, out...)
}

// ConfFiles lists every .conf in the projects directory, in the order the
// bash glob gave them: collation order, which puts case second.
func ConfFiles() []string {
	matches, _ := filepath.Glob(filepath.Join(ProjectsDir, "*.conf"))
	var names []string
	for _, m := range matches {
		if pathx.IsFile(m) {
			names = append(names, strings.TrimSuffix(filepath.Base(m), ".conf"))
		}
	}
	SortNames(names)
	return names
}

// SortNames sorts the way `sort` and a bash glob do under an English locale:
// ignoring case first, then by case.
func SortNames(names []string) {
	sort.SliceStable(names, func(i, j int) bool {
		a, b := strings.ToLower(names[i]), strings.ToLower(names[j])
		if a != b {
			return a < b
		}
		return names[i] < names[j]
	})
}

// LoadAll loads every project that loads. One that does not is left out,
// silently, as the bash engine's subshells left it out.
func LoadAll() []*Project {
	var out []*Project
	for _, n := range ConfFiles() {
		var p *Project
		if ui.Catch(func() { p = Load(n) }) == nil {
			out = append(out, p)
		}
	}
	return out
}
