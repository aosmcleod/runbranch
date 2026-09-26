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

// Package ports is every question about ports: who holds one, whose that is,
// which ports projects claim in common, and how far a project has to move to
// find free ones.
//
// Every command takes ONE listener snapshot and answers all of its questions
// from it — the offset search probes up to 200 offsets and once spawned one
// lsof per offset per target. It is passed around rather than cached in a
// global on purpose: a snapshot that outlives its caller is a stale answer
// waiting to happen, and some callers reap processes based on what they find.
package ports

import (
	"fmt"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/aosmcleod/runbranch/engine/internal/config"
	"github.com/aosmcleod/runbranch/engine/internal/proc"
	"github.com/aosmcleod/runbranch/engine/internal/ui"
)

// Snap takes a snapshot, treating a failure as "nothing is listening" the way
// an lsof that printed nothing was treated.
func Snap() Snapshot {
	s, _ := Listeners()
	return s
}

// Conflict is one line of check-ports.
type Conflict struct {
	Target      string
	Port        int
	Owner, Kind string
	PID         int
	Move        string // explicit | env
}

// CheckPorts is what stands between a preset and starting, in a form the
// front end can act on: one line per conflicted target, then the smallest
// shift that clears every one of them.
//
//	target <TAB> port <TAB> owner <TAB> kind <TAB> pid <TAB> explicit|env
//	OFFSET <TAB> n
//
// Returns false (exit 1) when there is a conflict.
func CheckPorts(p *config.Project, targets []string) bool {
	snap := Snap()
	var a Attributor
	var lines []string
	for _, t := range targets {
		port, ok := p.Port(t)
		if !ok {
			continue
		}
		pid := snap.Holder(port)
		if pid == 0 {
			continue
		}
		owner, kind := a.Owner(pid)

		// This project's OWN run is not a conflict. The run stops whatever
		// the project has going before it starts anything, so switching
		// branches within a project was being stopped by a warning about a
		// port it was about to free itself.
		//
		// A run of the same project started outside Runbranch is different:
		// nothing here can stop that one, so it stays a conflict and Take Over
		// stays on offer.
		if owner == p.ID && kind == Ours {
			continue
		}
		// `explicit` when the command names the port itself, `env` when the
		// shift can only be offered through PORT and might be ignored. Both
		// are worth offering; only one is a promise.
		move := "env"
		if tt, _ := p.Target(t); strings.Contains(tt.Command, "{port}") {
			move = "explicit"
		}
		lines = append(lines, fmt.Sprintf("%s\t%d\t%s\t%s\t%d\t%s\n", t, port, owner, kind, pid, move))
	}
	if len(lines) == 0 {
		return true
	}

	// Walk up until every port in the preset is free. Same shift for all of
	// them. Kept for parity: relative to the DECLARED ports, and 201 when
	// nothing within 200 is free.
	try := 1
	for ; try <= 200; try++ {
		clash := false
		for _, t := range targets {
			d, ok := p.DeclaredPort(t)
			if !ok {
				continue
			}
			if snap.Holder(d+try) != 0 {
				clash = true
				break
			}
		}
		if !clash {
			break
		}
	}
	ui.Out(strings.Join(lines, "") + fmt.Sprintf("OFFSET\t%d\n", try))
	return false
}

// EnsureFree dies, before anything starts, when a port the preset needs is
// held. The holder's own run is not exempt here: the run has stopped it
// already.
func EnsureFree(p *config.Project, targets []string) {
	snap := Snap()
	var a Attributor
	var busy []string
	var owners []string
	for _, t := range targets {
		port, ok := p.Port(t)
		if !ok {
			continue
		}
		pid := snap.Holder(port)
		if pid == 0 {
			continue
		}
		owner, kind := a.Owner(pid)
		switch {
		case owner != "" && kind == Ours:
			busy = append(busy, fmt.Sprintf("  %s on port %d  ->  Runbranch is running %s here (pid %d)", t, port, owner, pid))
		case owner != "":
			busy = append(busy, fmt.Sprintf("  %s on port %d  ->  %s is running already, started outside Runbranch (pid %d)", t, port, owner, pid))
		default:
			busy = append(busy, fmt.Sprintf("  %s on port %d  ->  %s", t, port, Desc(pid, 110)))
		}
		if owner != "" && !contains(owners, owner) {
			owners = append(owners, owner)
		}
	}
	if len(busy) == 0 {
		return
	}
	list := "\n" + strings.Join(busy, "\n")

	// A port held by one of our own runs is a different problem from a port
	// held by something the user started, and it has a different fix. Saying
	// "stop <this project>" when the holder belongs to another project sends
	// them after the wrong thing.
	if len(owners) > 0 {
		fix := ""
		for _, o := range owners {
			fix += fmt.Sprintf("%s stop %s\n    ", config.Self, o)
		}
		ui.Die("Ports this project needs are held by another Runbranch run:"+list+`

Two projects that both default to the same port cannot run at once. Stop the
other run, or give one of them different ports in its config.`,
			fix+fmt.Sprintf("# then start this one again\n    %s get %s | grep TARGETS      # to change ports instead", config.Self, p.ID))
	}
	ui.Die("Something is already listening on a port this needs:"+list+`

If that is your own dev server, leave it alone and stop it yourself.`,
		fmt.Sprintf("%s stop %s      # a leftover run of this project\n    %-24s # your own server, on purpose", config.Self, p.ID, ui.KillCmd("<pid>")))
}

func contains(list []string, s string) bool {
	for _, x := range list {
		if x == s {
			return true
		}
	}
	return false
}

// declared is every effective port every project declares, as port and
// project. Effective and not declared: PORT_OFFSET shifts a project's whole
// set, so comparing declared numbers reported two projects as clashing after
// they had already been separated — which made the fix look like it had not
// worked.
type claim struct {
	port    int
	project string
}

func declared(all []*config.Project) []claim {
	var out []claim
	for _, p := range all {
		for _, t := range p.TargetNames() {
			if port, ok := p.Port(t); ok {
				out = append(out, claim{port, p.ID})
			}
		}
	}
	return out
}

// Overlap is a port more than one project claims.
type Overlap struct {
	Port     int
	Projects []string
}

// Overlaps finds ports claimed by more than one project. Framework defaults
// make it likely — every Vite project wants 5173 and every Next one wants
// 3000 — and it only surfaces when the second project refuses to start, which
// is a bad time to find out.
//
// Counted over distinct port+project pairs. Counting ports, with duplicates
// collapsed by port alone, made every count 1 — which is exactly the thing
// being counted.
func Overlaps() []Overlap {
	byPort := map[int][]string{}
	for _, c := range declared(config.LoadAll()) {
		if !contains(byPort[c.port], c.project) {
			byPort[c.port] = append(byPort[c.port], c.project)
		}
	}
	var out []Overlap
	for port, ps := range byPort {
		if len(ps) > 1 {
			config.SortNames(ps)
			out = append(out, Overlap{port, ps})
		}
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Port < out[j].Port })
	return out
}

// SuggestOffset is the smallest shift that puts every one of a project's
// ports somewhere free, or ok=false when nothing within 200 is.
//
// Free means two things, and both matter: not claimed by another project,
// and not currently listened on by anything — including a server Runbranch
// did not start, since being able to run them together is the whole point.
// The shift applies to every target, so a project declaring 3000 and 3001
// keeps them adjacent. 0 when nothing needs moving.
func SuggestOffset(p *config.Project) (int, bool) {
	var mine []int
	for _, t := range p.TargetNames() {
		if d, ok := p.DeclaredPort(t); ok {
			mine = append(mine, d)
		}
	}
	if len(mine) == 0 {
		return 0, true
	}
	taken := map[int]bool{}
	for _, c := range declared(config.LoadAll()) {
		if c.project != p.ID {
			taken[c.port] = true
		}
	}
	for _, l := range Snap() {
		taken[l.Port] = true
	}
	for try := 0; try <= 200; try++ {
		clash := false
		for _, port := range mine {
			if taken[port+try] {
				clash = true
				break
			}
		}
		if !clash {
			return try, true
		}
	}
	// Nothing free within 200. Saying so beats suggesting a number that
	// clashes.
	return 0, false
}

// ReportOverlaps is `doctor`'s prose version of Overlaps.
func ReportOverlaps() {
	ov := Overlaps()
	if len(ov) == 0 {
		return
	}
	ui.Warn("These ports are claimed by more than one project, so those projects\ncannot run at the same time:")
	var b strings.Builder
	for _, o := range ov {
		fmt.Fprintf(&b, "    %-6d %s\n", o.Port, strings.Join(o.Projects, " "))
	}
	fmt.Fprintf(&b, `
  Give one of them a PORT_OFFSET, which shifts every port it
  declares and rewrites {port} in its commands:

    %s set <project> PORT_OFFSET 1

  Or move the port by hand — in the target AND in the command, since a
  framework will not pick it up otherwise:

    TARGETS="docs:5174:/:npm run docs -- --port 5174"

`, config.Self)
	ui.Out(b.String())
}

// Row is one line of `ports`:
//
//	project target port free|ours|outside owner kind pid what
type Row struct {
	Project, Target string
	Port            int
	State           string
	Owner, Kind     string
	PID             int
	What            string
}

// TSV is the row as the app parses it; a free port keeps its empty fields.
func (r Row) TSV() string {
	if r.State == "free" {
		return fmt.Sprintf("%s\t%s\t%d\tfree\t\t\t\t", r.Project, r.Target, r.Port)
	}
	return fmt.Sprintf("%s\t%s\t%d\t%s\t%s\t%s\t%d\t%s", r.Project, r.Target, r.Port, r.State, r.Owner, r.Kind, r.PID, r.What)
}

// Report is every port any project declares, and what is on it. The point is
// to answer "what is using 5173" without reaching for lsof, and to say whose
// it is — which Runbranch can do and lsof cannot, because it knows which
// directory belongs to which project.
func Report() []Row {
	snap := Snap()
	var a Attributor
	var out []Row
	for _, p := range config.LoadAll() {
		// A running project reports its run's ports, not the declared ones.
		p.LoadState()
		for _, t := range p.TargetNames() {
			port, ok := p.Port(t)
			if !ok {
				continue
			}
			pid := snap.Holder(port)
			if pid == 0 {
				out = append(out, Row{Project: p.ID, Target: t, Port: port, State: "free"})
				continue
			}
			owner, kind := a.Owner(pid)
			// Ours means this project's own run, not merely a Runbranch one:
			// another project holding the port is still a conflict.
			state := "outside"
			if kind == Ours && owner == p.ID {
				state = "ours"
			}
			out = append(out, Row{p.ID, t, port, state, owner, kind, pid, Desc(pid, 70)})
		}
	}
	return out
}

// KillPort ends a process holding a port, when the user has explicitly asked
// for it.
//
// Deliberately narrow. It refuses anything it cannot attribute to a project,
// because "kill whatever is on this port" is a footgun and a tool that offers
// it will eventually be pointed at a database or an editor. What it will end
// is a server running inside a project we know about — the same test that let
// us name it in the first place.
//
// A polite request first, and only that: this is someone else's process and
// a dev server that wants to clean up should be allowed to. Never escalated
// automatically; the forced kill is the fix text, for a person to choose.
func KillPort(arg string) {
	pid, err := strconv.Atoi(arg)
	if arg == "" || err != nil || strings.TrimLeft(arg, "0123456789") != "" {
		ui.Die(fmt.Sprintf("Not a process id: %q.", arg), config.Self+" check-ports <project> <preset>")
	}
	// Exists, not Alive: a process owned by someone else cannot be signalled,
	// and a check that treats that as "gone" reported a root process as
	// already stopped.
	if !proc.Exists(pid) {
		ui.Info(fmt.Sprintf("pid %d is already gone.", pid))
		return
	}
	var a Attributor
	owner, kind := a.Owner(pid)
	if owner == "" || kind == Unknown {
		ui.Die(fmt.Sprintf("Refusing to end pid %d — it does not belong to a project Runbranch knows about.\n\n%s", pid, Desc(pid, 110)),
			ui.KillCmd(arg)+"      # if that is really what you want")
	}
	ui.Info(fmt.Sprintf("ending %s (pid %d), started outside Runbranch", owner, pid))
	_ = proc.Terminate(pid, 10*time.Second)
	// The poll the bash engine used here was kill -0, which fails for a
	// process that exists but cannot be signalled — the very case its own
	// comment warned about.
	if proc.Exists(pid) {
		ui.Die(fmt.Sprintf("pid %d did not stop within 10s.", pid), ui.ForceKillCmd(arg))
	}
	ui.OK("stopped")
}
