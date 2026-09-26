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

// Package run starts, watches and stops a project's servers.
//
// The problem, which is not specific to one repo: demoing out of your
// working checkout means the demo competes with whatever you are editing.
// The fix, and the whole idea: one throwaway git worktree per branch. The
// working checkout is NEVER modified. Everything else is ergonomics.
package run

import (
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"time"

	"github.com/aosmcleod/runbranch/engine/internal/config"
	"github.com/aosmcleod/runbranch/engine/internal/gitx"
	"github.com/aosmcleod/runbranch/engine/internal/pathx"
	"github.com/aosmcleod/runbranch/engine/internal/ports"
	"github.com/aosmcleod/runbranch/engine/internal/proc"
	"github.com/aosmcleod/runbranch/engine/internal/ui"
)

// stopGrace is how long a tree gets between the polite request and the
// forced end.
const stopGrace = 12 * time.Second

// DoRun runs a ref of a project with a preset.
func DoRun(p *config.Project, ref, preset string) {
	targets := p.PresetTargets(preset)
	if len(targets) == 0 {
		ui.Die(fmt.Sprintf("Unknown preset %q for %s.", preset, p.Name()), config.Self+" presets "+p.ID)
	}

	ui.Printf("%s%s — %s (%s)%s\n", ui.Bld, p.Name(), ref, preset, ui.Off)

	HardenPath()
	RequireCmd("git", ui.GitInstallFix())
	if msg := RuntimeUnsupported(p.Get("RUNTIME")); msg != "" {
		ui.Die(msg, fmt.Sprintf("%s set %s RUNTIME mise      # or fnm", config.Self, p.ID))
	}

	// Kept for parity: reading the old run's state here restores ITS offset
	// and mode over the ones just asked for, whenever a state file exists.
	if s, running := p.Running(); running {
		ui.Warn(fmt.Sprintf("%s already has %s running.", p.Name(), s.Ref))
		if !ui.Ask("Stop it and start this one?", false) {
			ui.Die("Left it alone.", config.Self+" stop "+p.ID)
		}
		StopRun(p, false)
	}

	ports.EnsureFree(p, targets)

	if p.InPlace {
		// In place: the servers run in the checkout, against whatever is in
		// the working tree right now — uncommitted included. That is the
		// point, and it is the one mode where hot reload sees what you are
		// typing.
		//
		// Deliberately nothing else. No install, because that writes into a
		// directory being worked in and can move a lockfile. No copied files,
		// because they are already there. No per-run database, because that
		// works by rewriting COPY_FILES, which here would mean editing a real
		// .env.local — and never modifying the checkout is the promise the
		// rest of the tool is built on. Infrastructure is left alone for the
		// same reason: whatever the checkout is already pointed at is what it
		// gets.
		cur := gitx.CurrentBranch(p)
		if ref != cur {
			ui.Die(fmt.Sprintf("%s has %s checked out, not %s.", p.Repo(), cur, ref),
				fmt.Sprintf("cd %s && git switch %s      # or run it from a worktree instead", p.Repo(), ref))
		}
		ui.Step("In place   " + p.Repo())
		ui.Info("the checkout as it stands, uncommitted work included")
		ui.Warn("no install, no copied files, no per-run database")
		startRun(p, p.Repo(), ref, preset, targets)
		return
	}

	wt := prepareWorktree(p, ref)
	installDeps(p, wt)
	bringUpInfra(p, wt)
	setupRunDatabase(p, wt, ref)
	handleMigrations(p, wt)
	runSeed(p, wt)
	startRun(p, wt, ref, preset, targets)
}

// stream runs a command in dir with the project's runtime, its output cut
// into whole lines on the way to stdout (and to log, when there is one).
func stream(p *config.Project, dir, command string, log io.Writer) error {
	var w io.Writer = os.Stdout
	if log != nil {
		w = io.MultiWriter(os.Stdout, log)
	}
	lw := &ui.LineWriter{W: w}
	err := proc.Run(Prelude(p.Get("RUNTIME"))+command, dir, commandEnv(p, dir, nil), lw)
	lw.Flush()
	return err
}

const ghPackagesRefresh = "gh auth refresh -h github.com -s read:packages"

var (
	registry401 = regexp.MustCompile(`(?i)ERR_PNPM_FETCH_401|401 Unauthorized|npm\.pkg\.github\.com.*(401|Unauthorized)`)
	lockDrift   = regexp.MustCompile(`(?i)ERR_PNPM_OUTDATED_LOCKFILE|frozen-lockfile|npm ci.*can only install`)
)

// installDeps runs INSTALL in the worktree, every run, teed to install.log.
func installDeps(p *config.Project, wt string) {
	install := p.Get("INSTALL")
	if install == "" {
		return
	}
	log := filepath.Join(p.LogDir, "install.log")
	ui.Step("Dependencies")
	ui.Info(install + "   (first run on a branch can take a few minutes)")
	ui.Info("logging to " + log)
	ui.Out("\n")
	_ = os.MkdirAll(p.LogDir, 0o755)
	f, ferr := os.Create(log)
	var err error
	if ferr == nil {
		err = stream(p, wt, install, f)
		f.Close()
	} else {
		err = stream(p, wt, install, nil)
	}
	ui.Out("\n")
	if err == nil {
		ui.OK("dependencies installed")
		return
	}

	// Turn the failures that actually happen into instructions.
	b, _ := os.ReadFile(log)
	if registry401.Match(b) {
		ui.Die("The registry returned 401 while installing a private package.\n\nA default `gh auth login` does not grant read:packages, which is why this\ncatches people.",
			fmt.Sprintf("%s\n    cd %s && %s", ghPackagesRefresh, wt, install))
	}
	if lockDrift.Match(b) {
		ui.Die("The lockfile on this branch does not match its manifest, so the install\nrefused. That is a real inconsistency on the branch, not a launcher problem.",
			fmt.Sprintf("cd %s && %s install     # accept the drift, then re-run", wt, strings.SplitN(install, " ", 2)[0]))
	}
	ui.Die(fmt.Sprintf("Install failed. The last lines are above; the full log is at %s.%s", log, longPathNote(b)),
		fmt.Sprintf("cd %s && %s", wt, install))
}

func bringUpInfra(p *config.Project, wt string) {
	svcs := p.Words("COMPOSE_SERVICES")
	if len(svcs) == 0 {
		return
	}
	RequireCmd("docker", "Install Docker Desktop: https://www.docker.com/products/docker-desktop/")
	if err := quietCmd("docker", "info"); err != nil {
		ui.Die("Docker is installed but the daemon is not responding.", ui.DockerStartFix())
	}
	// Here only, as it always was; dropRunDatabase now defaults it too.
	if p.Get("COMPOSE_PROJECT") == "" {
		p.Set("COMPOSE_PROJECT", p.ID)
	}
	joined := strings.Join(svcs, " ")
	ui.Step(fmt.Sprintf("Infrastructure  (compose project: %s)", p.Get("COMPOSE_PROJECT")))
	ui.Info("docker compose up -d --wait " + p.Get("COMPOSE_SERVICES"))
	if compose(p, wt, append([]string{"up", "-d", "--wait"}, svcs...)...).Run() != nil {
		ui.Die(joined+" did not come up healthy.",
			fmt.Sprintf("docker compose -p %s -f %s logs %s", p.Get("COMPOSE_PROJECT"), filepath.Join(wt, p.Get("COMPOSE_FILE")), joined))
	}
	ui.OK(p.Get("COMPOSE_SERVICES") + " healthy")
}

func handleMigrations(p *config.Project, wt string) {
	m := p.Get("MIGRATE")
	if m == "" {
		return
	}
	ui.Step("Database")
	ui.Info(m)
	ui.DimLine("this mutates the shared database — every branch of this project uses it")
	var out tailBuffer
	if stream(p, wt, m, &out) != nil {
		ui.Die("Migrations failed."+longPathNote(out.Bytes()), fmt.Sprintf("cd %s && %s", wt, m))
	}
	ui.OK("migrations applied")
}

// runSeed, because an empty app is not worth looking at.
func runSeed(p *config.Project, wt string) {
	s := p.Get("SEED")
	if s == "" {
		return
	}
	ui.Step("Seed")
	ui.Info(s)
	var out tailBuffer
	if stream(p, wt, s, &out) != nil {
		ui.Die("Seeding failed."+longPathNote(out.Bytes()), fmt.Sprintf("cd %s && %s", wt, s))
	}
	ui.OK("seeded")
}

// shiftedPortNote says why a shifted run may have failed, when the target
// cannot be told its port.
//
// A server that hardcodes its port fails one of two ways: it refuses to bind
// and exits at once, or it binds the port it always binds and the health
// check on the shifted one times out. Both want the same explanation, so it
// lives here. Nothing to say when the run was not shifted, or when the
// command takes {port} and therefore did what it was told.
func shiftedPortNote(p *config.Project, t string) (string, bool) {
	if p.PortOffset == 0 {
		return "", false
	}
	if tt, _ := p.Target(t); strings.Contains(tt.Command, "{port}") {
		return "", false
	}
	return fmt.Sprintf("This run was shifted off its declared port, and %s does not say where to\nlisten — Runbranch could only offer it through PORT in the environment, which\nthis server appears to ignore.", t), true
}

// shiftedPortFix is a suggestion rather than a replacement: most tools take
// --port, some want -p or a positional, so the command has to be adapted
// rather than pasted.
func shiftedPortFix(p *config.Project, t string) string {
	tt, _ := p.Target(t)
	return fmt.Sprintf("edit %s so the command names its port, along these lines:\n    TARGETS=\"%s:%s:%s:%s --port {port}\"",
		filepath.Join(config.ProjectsDir, p.ID+".conf"), t, tt.Port, tt.Health, tt.Command)
}

func portString(p *config.Project, t string) string {
	if n, ok := p.Port(t); ok {
		return strconv.Itoa(n)
	}
	return ""
}

// startServer starts one target, detached, in its own process group, and
// checks a second later that it did not exit at once.
//
// Each server starts in its OWN PROCESS GROUP, and on Windows its own group
// and tree. That matters for stopping: a watcher such as `tsx --watch`
// RESPAWNS its child if you kill only the child. Stopping the tree takes it
// all down.
func startServer(p *config.Project, wt, name string) proc.Handle {
	t, _ := p.Target(name)
	actual := portString(p, name)

	// Two ways to tell a server which port to use, and it needs both.
	//
	// `{port}` in the command is the explicit one: unambiguous, and it works
	// for anything that takes a port on the command line. PORT in the
	// environment is the implicit one, honoured by a lot of tooling (Next,
	// CRA, Rails, most Express apps) and ignored by some (Vite wants --port).
	// Exporting it costs nothing and means a shifted run has a chance of
	// working without the config having anticipated it. When the server
	// ignores it, the health check fails on the shifted port and says what to
	// add — which is better than refusing to try.
	cmd := strings.ReplaceAll(t.Command, "{port}", actual)
	log := filepath.Join(p.LogDir, name+".log")
	_ = os.MkdirAll(p.LogDir, 0o755)

	h, err := proc.Start(proc.Spec{
		Command: Prelude(p.Get("RUNTIME")) + cmd,
		Dir:     wt,
		Env:     commandEnv(p, wt, map[string]string{"PORT": actual}),
		LogPath: log,
	})
	if err != nil {
		ui.Die(fmt.Sprintf("%s could not be started: %v", name, err), fmt.Sprintf("cd %s && %s", wt, cmd))
	}
	time.Sleep(time.Second)
	if !proc.Alive(h) {
		ui.Out("\n" + tail(log, 20) + "\n")
		long := longPathNote(logTail(log))
		if note, ok := shiftedPortNote(p, name); ok {
			ui.Die(fmt.Sprintf("%s exited immediately on port %s.\n\n%s\n\nIts log is above and at %s.%s", name, actual, note, log, long),
				shiftedPortFix(p, name))
		}
		ui.Die(fmt.Sprintf("%s exited immediately. Its log is above and at %s.%s", name, log, long), fmt.Sprintf("cd %s && %s", wt, cmd))
	}
	ui.OK(fmt.Sprintf("%s started (pgid %d) -> %s", name, h.PID, log))
	return h
}

// tail is the last n lines of a file, as `tail -n` prints them.
func tail(path string, n int) string {
	b, err := os.ReadFile(path)
	if err != nil || len(b) == 0 {
		return ""
	}
	s := strings.ReplaceAll(string(b), "\r\n", "\n")
	trailing := strings.HasSuffix(s, "\n")
	lines := strings.Split(strings.TrimSuffix(s, "\n"), "\n")
	if len(lines) > n {
		lines = lines[len(lines)-n:]
	}
	out := strings.Join(lines, "\n")
	if trailing {
		out += "\n"
	}
	return out
}

// healthClient treats any HTTP answer as up: a dev server returning 404 for
// a route it has not compiled yet is still up. Only no answer at all is
// failure. Redirects are not followed — curl without -L did not, and a 302
// is an answer. No proxy: localhost is never behind one.
var healthClient = &http.Client{
	Timeout:       3 * time.Second,
	CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse },
	Transport:     &http.Transport{Proxy: nil, DisableKeepAlives: true},
}

// waitForHTTP polls url until it answers. 0 when it did, 1 on timeout, 2
// when the server's process died first.
func waitForHTTP(url, label string, timeout int, h proc.Handle) int {
	ui.Info(fmt.Sprintf("waiting for %s at %s", label, url))
	for waited := 0; waited < timeout; {
		if h.PID != 0 && !proc.Alive(h) {
			return 2
		}
		if resp, err := healthClient.Get(url); err == nil {
			resp.Body.Close()
			ui.OK(fmt.Sprintf("%s responding (HTTP %d after %ds)", label, resp.StatusCode, waited))
			return 0
		}
		time.Sleep(2 * time.Second)
		waited += 2
		switch waited {
		case 20, 60, 120:
			ui.DimLine(fmt.Sprintf("still waiting... (%ds; a first compile is slow)", waited))
		}
	}
	return 1
}

func startRun(p *config.Project, wt, ref, preset string, targets []string) {
	ui.Step("Servers")
	handles := make([]proc.Handle, 0, len(targets))
	for _, t := range targets {
		handles = append(handles, startServer(p, wt, t))
	}
	// After every server has started and before any health wait, so a crash
	// in the wait leaves state behind for reclaim to find.
	_ = p.WriteState(ref, wt, preset, targets, handles)

	ui.Step("Waiting")
	first := ""
	for i, t := range targets {
		port, ok := p.Port(t)
		if !ok {
			continue
		}
		tt, _ := p.Target(t)
		health := tt.Health
		if health == "" {
			health = "/"
		}
		url := fmt.Sprintf("http://localhost:%d%s", port, health)
		if rc := waitForHTTP(url, t, 240, handles[i]); rc != 0 {
			log := filepath.Join(p.LogDir, t+".log")
			ui.Out("\n" + tail(log, 25) + "\n")
			why := t + " never answered within the timeout"
			if rc == 2 {
				why = t + " exited while starting"
			}
			hint := fmt.Sprintf("cd %s && %s", wt, tt.Command)
			if note, ok := shiftedPortNote(p, t); ok {
				why = fmt.Sprintf("%s on port %d.\n\n%s", why, port, note)
				hint = shiftedPortFix(p, t)
			}
			long := longPathNote(logTail(log))
			StopRun(p, true)
			ui.Die(fmt.Sprintf("%s. The last log lines are above; the full log is at %s.%s", why, log, long), hint)
		}
		if first == "" {
			first = fmt.Sprintf("http://localhost:%d", port)
		}
	}

	ui.Step("Ready")
	for _, t := range targets {
		if port, ok := p.Port(t); ok {
			ui.Info(fmt.Sprintf("%-8s http://localhost:%d", t, port))
		}
	}
	// Some dev servers (vite --open) open a browser themselves; opening a
	// second one is just a duplicate tab. RB_NO_OPEN exists for tests and
	// scripts — a suite that steals focus every time it runs is a suite
	// people stop running.
	if p.Get("OPENS_ITSELF") != "1" && os.Getenv("RB_NO_OPEN") == "" && first != "" {
		_ = proc.OpenURL(first)
	}
}

// StopRun stops a project's run: every recorded tree, then the state file,
// then any stray still on one of its ports that clearly came from its
// worktrees. Quiet prints nothing.
func StopRun(p *config.Project, quiet bool) {
	s := p.LoadState()
	if s == nil {
		if !quiet {
			ui.Info("Nothing is recorded as running for " + p.Name() + ".")
		}
		return
	}
	if !quiet {
		ui.Step(fmt.Sprintf("Stopping  %s — %s (%s)", p.Name(), s.Ref, s.Preset))
	}
	// The whole tree, not the pid: that is what takes a watcher down with its
	// child instead of letting it respawn. And every survivor, not only the
	// leader — the bash engine stopped waiting when the leader went and
	// never sent KILL to the children it left behind.
	for i := range s.PIDs {
		if h := s.Handle(i); h.PID > 0 && proc.Alive(h) {
			_ = proc.StopTree(h, stopGrace)
		}
	}
	p.ClearState()

	// Anything still on one of our ports is a stray. Only reap it when it is
	// clearly ours — a process running from this project's worktrees. Never
	// touch the user's own dev server.
	snap := ports.Snap()
	var left []string
	for _, t := range s.Targets {
		port, ok := p.Port(t)
		if !ok {
			continue
		}
		pid := snap.Holder(port)
		if pid == 0 {
			continue
		}
		if ports.InWorktrees(pid, p.Worktrees) {
			_ = proc.StopTree(proc.Handle{PID: pid}, 2*time.Second)
		} else {
			left = append(left, fmt.Sprintf("  port %d  ->  %s", port, ports.Desc(pid, 110)))
		}
	}
	if len(left) > 0 && !quiet {
		ui.Warn("Still listening, and not started by this launcher:\n" + strings.Join(left, "\n"))
		ui.DimLine("Left alone on purpose. Stop it yourself if it is in the way: " + ui.KillCmd("<pid>"))
	}
	if !quiet {
		ui.OK("stopped")
	}
}

// Update brings a run up to its ref's latest commit.
//
// A worktree is pinned to the commit it was made at, so this is a stop and a
// start rather than anything cleverer — a run already re-checks-out the ref
// at whatever its tip is now. Naming it means the app does not have to know
// that, and cannot get the ref, preset or port offset wrong in between.
func Update(p *config.Project) {
	s, running := p.Running()
	if !running {
		ui.Die(p.Name()+" is not running.", fmt.Sprintf("%s run %s <ref> <preset>", config.Self, p.ID))
	}
	if p.InPlace {
		ui.Die(p.Name()+" is running in place, so it is already on the working tree.",
			"There is nothing to update — edits and commits are live already.")
	}
	ref, preset, offset := s.Ref, s.Preset, p.PortOffset
	StopRun(p, false)
	// Stopping clears the state these came from, so put the run's own offset
	// back before starting.
	p.PortOffset = offset
	p.InPlace = false
	DoRun(p, ref, preset)
}

// PrintStatus is the human status of a project. False when it is idle.
func PrintStatus(p *config.Project) bool {
	s, running := p.Running()
	if !running {
		ui.Printf("\n%s: nothing running.\n\n", p.Name())
		return false
	}
	var b strings.Builder
	fmt.Fprintf(&b, "\n%s%s running%s\n", ui.Bld, p.Name(), ui.Off)
	fmt.Fprintf(&b, "  branch    %s\n", s.Ref)
	fmt.Fprintf(&b, "  running   %s\n", s.Preset)
	fmt.Fprintf(&b, "  worktree  %s\n", s.Worktree)
	fmt.Fprintf(&b, "  since     %s\n", s.Started)
	for _, t := range s.Targets {
		if port, ok := p.Port(t); ok {
			fmt.Fprintf(&b, "  %-9s http://localhost:%d\n", t, port)
		}
	}
	fmt.Fprintf(&b, "  logs      %s\n\n", p.LogDir)
	ui.Out(b.String())
	return true
}

// IsRunning is the plain question.
func IsRunning(p *config.Project) bool {
	_, running := p.Running()
	return running
}

// State prints the machine-readable run state the app polls.
//
// New information goes on NEW LINE TYPES, never as more fields on an
// existing line: a reader that does not know a line ignores it, which is how
// every addition here has stayed backward compatible.
func State(p *config.Project) {
	s, running := p.Running()
	if !running {
		// Nothing of ours, but the project may be up anyway.
		if emitAdopted(p) {
			return
		}
		ui.Out("idle\n")
		return
	}
	var b strings.Builder
	inPlace := "0"
	if p.InPlace {
		inPlace = "1"
	}
	fmt.Fprintf(&b, "run\t%s\t%s\t%s\t%s\t%s\t%s\n", s.Ref, s.Preset, s.Started, s.Epoch, s.Worktree, inPlace)
	fmt.Fprintf(&b, "behind\t%s\n", commitsBehind(p, s))
	if moved := switchedBranch(p, s); moved != "" {
		fmt.Fprintf(&b, "switched\t%s\n", moved)
	}
	// TARGETS and PIDS are written in the same order, so they zip.
	for i, t := range s.Targets {
		pid := "0"
		if i < len(s.PIDs) {
			pid = s.PIDs[i]
		}
		alive := "0"
		if s.Alive(i) {
			alive = "1"
		}
		tt, _ := p.Target(t)
		// The effective port, NOT the declared one: this line is what the app
		// builds its Open button and its health poll from.
		fmt.Fprintf(&b, "target\t%s\t%s\t%s\t%s\t%s\n", t, portString(p, t), tt.Health, pid, alive)
	}
	ui.Out(b.String())
}

// commitsBehind is how many commits the ref has gained since this run's
// worktree was made. 0 rather than a failure whenever the answer is not
// knowable — no worktree, a ref since deleted, a shallow clone. "Behind by an
// unknown amount" is not something a UI can say usefully, and 0 reads as
// "nothing to tell you", which is true.
func commitsBehind(p *config.Project, s *config.State) string {
	if p.InPlace || s.Worktree == "" || !pathx.IsDir(s.Worktree) {
		return "0"
	}
	pinned, err := gitx.Git(s.Worktree, "rev-parse", "HEAD")
	if err != nil || pinned == "" {
		return "0"
	}
	tip := gitx.Resolve(p.Repo(), s.Ref)
	if tip == "" {
		return "0"
	}
	n, err := gitx.Git(p.Repo(), "rev-list", "--count", pinned+".."+tip)
	if err != nil || n == "" {
		return "0"
	}
	return n
}

// switchedBranch is the branch the checkout is on now, when an in-place run
// is no longer on the one it was started for.
//
// Starting in place refuses a ref that is not checked out, and nothing
// checked again after that. So: start in place on feat/x, then switch to
// main in a terminal, an editor or an agent. The servers keep running and
// now serve main while Runbranch still says feat/x — and hot reload picks
// the new code up, which is what makes it convincing as well as wrong.
func switchedBranch(p *config.Project, s *config.State) string {
	if !p.InPlace || s.Ref == "" {
		return ""
	}
	now := gitx.CurrentBranch(p)
	if now == "" || now == s.Ref {
		return ""
	}
	return now
}

// emitAdopted reports a run this project has going that Runbranch did not
// start, in the same shape as a real run, so the front end shows it rather
// than pretending nothing is happening. Discovering an already-busy port by
// failing to start is a poor way to find out.
//
// Nothing is invented: the ref is what the checkout is on (a server running
// from the checkout can only be serving that), the start time comes from the
// process, and it is flagged adopted so the UI can say who started it and
// offer the right way to end it.
func emitAdopted(p *config.Project) bool {
	snap := ports.Snap()
	var a ports.Attributor
	var rows strings.Builder
	first := 0
	for _, t := range p.TargetNames() {
		port, ok := p.Port(t)
		if !ok {
			continue
		}
		pid := snap.Holder(port)
		if pid == 0 {
			continue
		}
		// Only this project, and only started elsewhere. Another project on
		// the port is a conflict, not a run of ours to adopt.
		owner, kind := a.Owner(pid)
		if owner != p.ID || kind != ports.Outside {
			continue
		}
		if first == 0 {
			first = pid
		}
		tt, _ := p.Target(t)
		fmt.Fprintf(&rows, "target\t%s\t%d\t%s\t%d\t1\n", t, port, tt.Health, pid)
	}
	if first == 0 {
		return false
	}
	// Kept for parity: the start time in the `ps -o lstart` form, not the
	// one a real run records.
	started, epoch := "", int64(0)
	if st, err := proc.StartTime(first); err == nil && st > 0 {
		started = time.Unix(st, 0).Format("Mon Jan _2 15:04:05 2006")
		epoch = st
	}
	ui.Out(fmt.Sprintf("run\t%s\t\t%s\t%d\t%s\t1\t1\n", gitx.CurrentBranch(p), started, epoch, p.Repo()) + rows.String())
	return true
}

// Reclaim is for what a crash left behind: a force quit, a panic or a sleep
// can leave servers holding ports with no state to match, or state naming
// pids that are long gone. Neither is the user's problem to solve by hand.
//
// Anything still listening on one of this project's ports that runs from its
// worktrees is ours, whatever the state file believes. Returns how much it
// reclaimed.
func Reclaim(p *config.Project) int {
	s := p.LoadState()
	running := s != nil && s.AnyAlive()
	stale := s != nil && !running
	found := 0
	snap := ports.Snap()
	for _, t := range p.TargetNames() {
		port, ok := p.Port(t)
		if !ok {
			continue
		}
		pid := snap.Holder(port)
		if pid == 0 || !ports.InWorktrees(pid, p.Worktrees) {
			continue
		}
		// Ours, and not accounted for by a live run.
		if stale || !running {
			ui.Info(fmt.Sprintf("%s: reclaiming %s on port %d (pid %d)", p.Name(), t, port, pid))
			_ = proc.StopTree(proc.Handle{PID: pid}, stopGrace)
			found++
		}
	}
	if stale {
		ui.Info(fmt.Sprintf("%s: clearing stale state for %s", p.Name(), s.Ref))
		p.ClearState()
		found++
	}
	return found
}

// ReclaimAll reclaims every project, and says so when there was nothing.
func ReclaimAll() {
	total := 0
	for _, p := range config.LoadAll() {
		total += Reclaim(p)
	}
	if total == 0 {
		ui.Info("Nothing to reclaim.")
	}
}

func quietCmd(name string, args ...string) error {
	return exec.Command(name, args...).Run()
}
