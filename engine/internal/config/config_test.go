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
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"

	"github.com/aosmcleod/runbranch/engine/internal/ui"
)

func values(t *testing.T, content string) map[string]string {
	t.Helper()
	as, err := Parse(content)
	if err != nil {
		t.Fatalf("Parse: %v\n%s", err, content)
	}
	m := map[string]string{}
	for _, a := range as {
		m[a.Key] = a.Value
	}
	return m
}

func TestParseSubset(t *testing.T) {
	Home = "/home/t"
	got := values(t, `# a comment
NAME="Fixture"
export REPO=~/code/x
  DEFAULT_BRANCH='main'   # trailing comment
PORT_OFFSET=1
INSTALL="pnpm install --frozen-lockfile"    # pinned
TARGETS="web:4321:/:python3 -m http.server 4321
api:4322:/health:node -e \"console.log('hi')\" \$HOME"
EMPTY=
HOMEY="$HOME/a ${HOME}/b"
LITERAL="cost: $ 5 and C:\Users\x"
QUOTED=a"b c"'d e'
SHARP=a#b
`)
	want := map[string]string{
		"NAME":           "Fixture",
		"REPO":           "/home/t/code/x",
		"DEFAULT_BRANCH": "main",
		"PORT_OFFSET":    "1",
		"INSTALL":        "pnpm install --frozen-lockfile",
		"TARGETS":        "web:4321:/:python3 -m http.server 4321\napi:4322:/health:node -e \"console.log('hi')\" $HOME",
		"EMPTY":          "",
		"HOMEY":          "/home/t/a /home/t/b",
		"LITERAL":        `cost: $ 5 and C:\Users\x`,
		"QUOTED":         "ab cd e",
		"SHARP":          "a#b",
	}
	if !reflect.DeepEqual(got, want) {
		for k := range want {
			if got[k] != want[k] {
				t.Errorf("%s = %q, want %q", k, got[k], want[k])
			}
		}
	}
}

func TestParseCRLF(t *testing.T) {
	got := values(t, "NAME=\"A\"\r\nTARGETS=\"a:1:/:x\r\nb:2:/:y\"\r\n")
	if got["NAME"] != "A" || got["TARGETS"] != "a:1:/:x\nb:2:/:y" {
		t.Errorf("CRLF read as %q", got)
	}
}

// Anything beyond the subset is an error that names its line, never a guess.
func TestParseRefuses(t *testing.T) {
	for _, c := range []struct {
		src  string
		line int
		want string
	}{
		{"NAME=\"Broken\nREPO=/x\n", 1, "unexpected end of file"},
		{"A=1\nB='open\n", 2, "unexpected end of file"},
		{"A=1\nB=$(whoami)\n", 2, "runs a command"},
		{"A=`whoami`\n", 1, "backtick"},
		{"A=\"x $USER\"\n", 1, "$USER"},
		{"A=${PATH}\n", 1, "$PATH"},
		{"if true; then A=1; fi\n", 1, "not a KEY"},
		{"echo hi\n", 1, "not a KEY"},
		{"A=1 B=2\n", 1, "more on the line"},
		{"A=1; B=2\n", 1, "shell syntax"},
		{"\n\n  A=x y\n", 3, "more on the line"},
	} {
		_, err := Parse(c.src)
		se, ok := err.(*SyntaxError)
		if !ok {
			t.Errorf("Parse(%q) = %v, want a SyntaxError", c.src, err)
			continue
		}
		if se.Line != c.line || !strings.Contains(se.Error(), c.want) {
			t.Errorf("Parse(%q) = %q, want line %d containing %q", c.src, se.Error(), c.line, c.want)
		}
	}
}

func TestQuoteRoundTrips(t *testing.T) {
	for _, v := range []string{
		"", "plain", `has "quotes"`, `back\slash`, "$(rm -rf /)", "`whoami`", "$HOME", "multi\nline\n",
		`C:\Users\x\`, "tab\there", "'single'",
	} {
		got := values(t, "K="+Quote(v)+"\n")["K"]
		if got != v {
			t.Errorf("Quote(%q) read back as %q", v, got)
		}
	}
}

func set(t *testing.T, content, key, value string) string {
	t.Helper()
	out, err := SetKey(content, key, value)
	if err != nil {
		t.Fatalf("SetKey: %v", err)
	}
	if _, err := Parse(out); err != nil {
		t.Fatalf("SetKey wrote something that will not parse: %v\n%s", err, out)
	}
	return out
}

const fixtureConf = `# A comment that must survive every write.
NAME="Fixture"
REPO="/tmp/fixture"
DEFAULT_BRANCH="main"
TARGETS="web:4321:/:python3 -m http.server 4321 --directory public"
SYMBOL="cube"
`

// Every case tests/engine.sh makes of set.
func TestSetKeyCases(t *testing.T) {
	// A simple key, with the comment kept.
	out := set(t, fixtureConf, "SYMBOL", "globe")
	if !strings.Contains(out, `SYMBOL="globe"`) || strings.Contains(out, "cube") {
		t.Errorf("simple key:\n%s", out)
	}
	if strings.Count(out, "\n#") != strings.Count(fixtureConf, "\n#") || !strings.HasPrefix(out, "# A comment") {
		t.Errorf("comments lost:\n%s", out)
	}

	// An absent key is appended once, and the file still ends in a newline.
	out = set(t, out, "NEWKEY", "added")
	if strings.Count(out, "NEWKEY=") != 1 || !strings.HasSuffix(out, "NEWKEY=\"added\"\n") {
		t.Errorf("append:\n%s", out)
	}

	// A multi-line value, written and then replaced again, both ways round.
	multi := "web:4321:/:python3 -m http.server 4321\napi:4322:/:python3 -m http.server 4322"
	out = set(t, out, "TARGETS", multi)
	if got := values(t, out)["TARGETS"]; got != multi {
		t.Errorf("multi-line TARGETS read back as %q", got)
	}
	out = set(t, out, "TARGETS", "web:4321:/:true")
	v := values(t, out)
	if v["TARGETS"] != "web:4321:/:true" || v["SYMBOL"] != "globe" || v["NEWKEY"] != "added" || v["NAME"] != "Fixture" {
		t.Errorf("replacing a multi-line value disturbed its neighbours:\n%s", out)
	}
	if strings.Contains(out, "4322") {
		t.Errorf("continuation lines of the old value survived:\n%s", out)
	}

	// Duplicates each get the new value.
	out = set(t, "A=\"1\"\nB=\"x\"\nA=\"2\"\n", "A", "3")
	if out != "A=\"3\"\nB=\"x\"\nA=\"3\"\n" {
		t.Errorf("duplicates:\n%q", out)
	}
}

// The bug that ate a file: a value with a trailing comment looked
// unterminated, and every line up to the next one ending in a quote went.
func TestSetKeyKeepsLinesAfterATrailingComment(t *testing.T) {
	conf := `NAME="Proposed"
REPO="~/x"
RUNTIME="mise"          # pinned in the repo
COPY_FILES=".env.local"    # gitignored, so a worktree lacks it

# port guessed from the dev script
TARGETS="dev:5173:/:pnpm run dev"
SYMBOL="shippingbox"
`
	out := set(t, conf, "RUNTIME", "fnm")
	want := strings.Replace(conf, `RUNTIME="mise"`, `RUNTIME="fnm"`, 1)
	if out != want {
		t.Errorf("got\n%s\nwant\n%s", out, want)
	}
}

func TestSetKeyEscapes(t *testing.T) {
	out := set(t, fixtureConf, "INSTALL", `echo "$(whoami)" `+"`id`"+` \done`)
	if got := values(t, out)["INSTALL"]; got != `echo "$(whoami)" `+"`id`"+` \done` {
		t.Errorf("read back as %q from\n%s", got, out)
	}
}

func TestSetKeyKeepsExportAndCRLF(t *testing.T) {
	out := set(t, "# c\r\nexport A=\"1\"   # note\r\nB=\"2\"\r\n", "A", "9")
	if out != "# c\r\nexport A=\"9\"   # note\r\nB=\"2\"\r\n" {
		t.Errorf("got %q", out)
	}
}

func TestPresets(t *testing.T) {
	p := &Project{vals: map[string]string{"PRESETS": "", "ALWAYS": ""}}
	p.Targets = parseTargets("web:3000:/:a\n# api:1:/:x\n\napi:4000:/health:b:c:d")
	if got := p.PresetNames(); !reflect.DeepEqual(got, []string{"web", "api", "all"}) {
		t.Errorf("names = %v", got)
	}
	if tt, _ := p.Target("api"); tt.Health != "/health" || tt.Command != "b:c:d" {
		t.Errorf("only three colons separate: %+v", tt)
	}
	if got := p.PresetTargets("all"); !reflect.DeepEqual(got, []string{"web", "api"}) {
		t.Errorf("all = %v", got)
	}
	// Kept for parity: an unknown preset is a single target of that name.
	if got := p.PresetTargets("bogus"); !reflect.DeepEqual(got, []string{"bogus"}) {
		t.Errorf("unknown = %v", got)
	}
	if got := p.PresetTargets(""); len(got) != 0 {
		t.Errorf("empty = %v", got)
	}

	p.vals["PRESETS"] = "front=web  full=web,api  bare"
	p.vals["ALWAYS"] = "api"
	if got := p.PresetNames(); !reflect.DeepEqual(got, []string{"front", "full", "bare"}) {
		t.Errorf("declared names = %v", got)
	}
	if got := p.PresetTargets("front"); !reflect.DeepEqual(got, []string{"api", "web"}) {
		t.Errorf("ALWAYS first: %v", got)
	}
	if got := p.PresetTargets("full"); !reflect.DeepEqual(got, []string{"web", "api"}) {
		t.Errorf("ALWAYS not repeated: %v", got)
	}
	if got := p.PresetTargets("bare"); !reflect.DeepEqual(got, []string{"api", "bare"}) {
		t.Errorf("a word without = expands to itself: %v", got)
	}

	one := &Project{vals: map[string]string{}, Targets: parseTargets("web:1:/:x")}
	if got := one.PresetNames(); !reflect.DeepEqual(got, []string{"web"}) {
		t.Errorf("single target = %v", got)
	}
}

func TestPorts(t *testing.T) {
	p := &Project{vals: map[string]string{}, Targets: parseTargets("web:3000:/:a\nworker::/:b")}
	p.PortOffset = 5
	if n, ok := p.Port("web"); !ok || n != 3005 {
		t.Errorf("effective = %d %v", n, ok)
	}
	if n, ok := p.DeclaredPort("web"); !ok || n != 3000 {
		t.Errorf("declared = %d %v", n, ok)
	}
	if _, ok := p.Port("worker"); ok {
		t.Error("a target with no port has none")
	}
}

func TestProcfileTargets(t *testing.T) {
	f := filepath.Join(t.TempDir(), "Procfile")
	os.WriteFile(f, []byte("web: bundle exec rails s\n# a comment\n\nworker:   sidekiq -C x:y\nnocolon\n"), 0o644)
	got := procfileTargets(f, 5000)
	want := "web:5000:/:bundle exec rails s\nworker:5100:/:sidekiq -C x:y"
	if got != want {
		t.Errorf("got %q, want %q", got, want)
	}
}

// A project on disk, for the tests that go through Load.
func project(t *testing.T, conf string) (file, repo string) {
	t.Helper()
	tmp := t.TempDir()
	repo = filepath.Join(tmp, "repo")
	os.MkdirAll(filepath.Join(repo, ".git"), 0o755)
	projects := filepath.Join(tmp, "projects")
	os.MkdirAll(projects, 0o755)
	t.Setenv("RB_HOME", filepath.Join(tmp, "state"))
	t.Setenv("RB_PROJECTS_DIR", projects)
	Locate()
	file = filepath.Join(projects, "fx.conf")
	os.WriteFile(file, []byte(strings.ReplaceAll(conf, "@REPO@", strings.Trim(Quote(repo), `"`))), 0o644)
	return file, repo
}

func TestLoadErrors(t *testing.T) {
	// As tests/engine.sh writes it: the quote opened on line 1 never closes.
	project(t, "NAME=\"Broken\nREPO=@REPO@\n")
	f := ui.Catch(func() { Load("fx") })
	if f == nil || !strings.Contains(f.Msg, "syntax error") || !strings.Contains(f.Msg, "line 1") || strings.Contains(f.Msg, "sets no REPO") {
		t.Fatalf("broken conf: %+v", f)
	}
	if !strings.Contains(f.Fix, filepath.Join("projects", "fx.conf")) {
		t.Errorf("fix %q does not name the file", f.Fix)
	}

	project(t, "NAME=\"x\"\nTARGETS=\"a:1:/:b\"\n")
	if f := ui.Catch(func() { Load("fx") }); f == nil || !strings.Contains(f.Msg, "sets no REPO") {
		t.Errorf("no REPO: %+v", f)
	}
	project(t, "REPO=\"@REPO@\"\n")
	if f := ui.Catch(func() { Load("fx") }); f == nil || !strings.Contains(f.Msg, "declares no TARGETS") {
		t.Errorf("no TARGETS: %+v", f)
	}
	if f := ui.Catch(func() { Load("nosuch") }); f == nil || !strings.Contains(f.Msg, `No project called "nosuch".`) {
		t.Errorf("missing: %+v", f)
	}
}

// The in-repo file is the base; the local file wins.
func TestLoadLayersInRepoConfig(t *testing.T) {
	_, repo := project(t, "REPO=\"@REPO@\"\nSYMBOL=\"globe\"\n")
	os.WriteFile(filepath.Join(repo, ".runbranch"), []byte("NAME=\"Shared\"\nSYMBOL=\"cube\"\nTARGETS=\"web:3000:/:x\"\n"), 0o644)
	p := Load("fx")
	if p.Name() != "Shared" || p.Get("SYMBOL") != "globe" || p.Get("TARGETS") != "web:3000:/:x" || p.InRepo == "" {
		t.Errorf("layering: name=%q symbol=%q targets=%q inrepo=%q", p.Name(), p.Get("SYMBOL"), p.Get("TARGETS"), p.InRepo)
	}
}

// set reverts what will not load, byte for byte.
func TestSetProjectKeyReverts(t *testing.T) {
	file, _ := project(t, "# keep me\nREPO=\"@REPO@\"\nTARGETS=\"web:3000:/:x\"\n")
	before, _ := os.ReadFile(file)
	f := ui.Catch(func() { SetProjectKey("fx", "REPO", "") })
	if f == nil || !strings.Contains(f.Msg, "will not load; reverted") {
		t.Fatalf("REPO=\"\": %+v", f)
	}
	after, _ := os.ReadFile(file)
	if string(before) != string(after) {
		t.Errorf("not reverted:\n%s", after)
	}
	if _, err := os.Stat(file + ".bak"); err == nil {
		t.Error(".bak left behind")
	}
	if f := ui.Catch(func() { SetProjectKey("fx", "a", "1") }); f == nil || !strings.Contains(f.Msg, "is not a config key") {
		t.Errorf("bad key: %+v", f)
	}
	// PORT_OFFSET is settable although it is a number and not in every file.
	if f := ui.Catch(func() { SetProjectKey("fx", "PORT_OFFSET", "3") }); f != nil {
		t.Fatalf("PORT_OFFSET: %+v", f)
	}
	if p := Load("fx"); p.PortOffset != 3 || p.Get("PORT_OFFSET") != "3" {
		t.Errorf("PORT_OFFSET = %d", p.PortOffset)
	}
}
