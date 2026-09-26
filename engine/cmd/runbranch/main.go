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

// Command runbranch is the ENGINE. Its only UI is a plain terminal picker;
// the front ends are the Mac and Windows apps, which run this as a
// subprocess, parse what the machine-readable subcommands print, and stream
// the rest into a window. Every message is written to be read by a person
// either way.
//
// It replaces runbranch.sh behind the same contract: the same subcommands,
// the same TSV on stdout, the same FAILED/Fix: block on stderr, the same exit
// codes.
package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/aosmcleod/runbranch/engine/internal/config"
	"github.com/aosmcleod/runbranch/engine/internal/disk"
	"github.com/aosmcleod/runbranch/engine/internal/gitx"
	"github.com/aosmcleod/runbranch/engine/internal/ports"
	"github.com/aosmcleod/runbranch/engine/internal/run"
	"github.com/aosmcleod/runbranch/engine/internal/scan"
	"github.com/aosmcleod/runbranch/engine/internal/ui"
	"github.com/aosmcleod/runbranch/engine/internal/update"
)

// version is set at build time with -ldflags "-X main.version=<ver>".
var version = "dev"

func main() {
	// Before anything else runs, and outside the Failure machinery: this is a
	// copy of the engine in %TEMP% swapping out the folder the real one lives
	// in, and it has no business hardening PATH or migrating projects on its
	// way. What it has to say goes to its own log (spec F17).
	if len(os.Args) > 1 && os.Args[1] == "install-update" {
		os.Exit(installUpdate(os.Args[2:]))
	}
	code := 0
	func() {
		defer func() {
			if r := recover(); r != nil {
				switch v := r.(type) {
				case *ui.Failure:
					ui.PrintFailure(v)
					code = 1
				case ui.Exit:
					code = int(v)
				default:
					panic(r)
				}
			}
		}()
		run.HardenPath()
		config.MigrateBundleProjects()
		dispatch(os.Args[1:])
	}()
	os.Exit(code)
}

func usage() {
	sep := string(filepath.Separator)
	ui.Out(`Runbranch — run any local project from a throwaway git worktree.

  runbranch                          interactive
  runbranch run <project> <ref> <preset>
  runbranch stop <project>
  runbranch status [<project>]
  runbranch cleanup <project>
  runbranch doctor [<project>]              check a project's config resolves
  runbranch scan [<dir>]                    git repos not yet declared
  runbranch propose <repo>                  guess a config by reading the repo
  runbranch add <repo>                      propose it and write projects/<name>.conf

  machine-readable, used by the apps:
  runbranch projects
  runbranch branches <project>
  runbranch presets <project>
  runbranch favourite <project> on|off      pin it to the top of the sidebar
  runbranch get <project>                   every editable field
  runbranch set <project> <KEY> [value]     rewrite one key in the local conf
  runbranch paths <project> [<ref>]
  runbranch run <p> <ref> <preset> [offset] [--in-place]
                                       offset shifts every port in the run;
                                       --in-place uses the checkout, not a worktree
  runbranch check-ports <p> <preset>
                                       what holds the ports, and a free offset
  runbranch update <project>        re-check-out the ref at its tip and restart
  runbranch prune-gone <project>    remove worktrees whose ref no longer exists
  runbranch overlaps                ports claimed by more than one project
  runbranch suggest-offset <p>      the smallest PORT_OFFSET that frees its ports
  runbranch disk                    every worktree, its size, and whether it is in use
  runbranch ports                   every declared port, and what is on it
  runbranch kill-port <pid>         end a port holder, if it belongs to a project
  runbranch remove <project>        delete a project's config and state, never its repo
  runbranch reclaim [<project>]     reclaim ports and clear state a crash left
  runbranch state <project>
  runbranch remove-worktree <project> <ref>
  runbranch refresh <project>

  internal, run by the Windows app only:
  runbranch ` + update.Usage + `
                                       swap a downloaded update in and reopen it

Projects   : ` + config.ProjectsDir + `
State      : ` + config.RBHome + sep + `<project>` + sep + `
`)
}

// installUpdate is `install-update`, returning the exit code: 0 swapped,
// 1 not (and the log says why), 2 a usage error or the wrong OS.
func installUpdate(args []string) int {
	if !update.Supported {
		fmt.Fprintln(os.Stderr, "install-update is not used on macOS; the app updates with tools/install-update.sh.")
		return 2
	}
	o, err := update.ParseArgs(args)
	if err != nil {
		fmt.Fprintf(os.Stderr, "install-update %v\nusage: runbranch %s\n", err, update.Usage)
		return 2
	}
	return update.Install(o)
}

func usageExit() {
	usage()
	ui.ExitWith(2)
}

// needProject loads args[1], or is a usage error when it is missing.
func needProject(args []string) *config.Project {
	if len(args) < 2 || args[1] == "" {
		usageExit()
	}
	return config.Load(args[1])
}

func b01(b bool) string {
	if b {
		return "1"
	}
	return "0"
}

func dispatch(args []string) {
	cmd := "menu"
	if len(args) > 0 {
		cmd = args[0]
	}
	switch cmd {
	case "projects":
		var b strings.Builder
		for _, p := range config.LoadAll() {
			sym := p.Get("SYMBOL")
			if sym == "" {
				sym = "shippingbox"
			}
			fmt.Fprintf(&b, "%s\t%s\t%s\t%s\t%s\t%s\n", p.ID, p.Name(), p.Repo(), b01(p.HasState()), sym, b01(config.IsFavourite(p.ID)))
		}
		ui.Out(b.String())

	case "projects-dir":
		// Where .conf files live. The app used to work this out from the path
		// of the script it ran, which is how it came to be pointing inside its
		// own bundle — so it asks now rather than deriving.
		ui.Out(config.ProjectsDir + "\n")

	case "branches":
		p := needProject(args)
		var b strings.Builder
		for _, r := range gitx.Branches(p) {
			b.WriteString(r.TSV() + "\n")
		}
		ui.Out(b.String())

	case "get":
		// Every editable field of a project, as key<TAB>value lines. The app
		// reads this rather than parsing a .conf itself, so the file stays the
		// engine's business.
		p := needProject(args)
		var b strings.Builder
		sym := p.Get("SYMBOL")
		if sym == "" {
			sym = "shippingbox"
		}
		for _, kv := range [][2]string{
			{"NAME", p.Name()}, {"REPO", p.Repo()}, {"DEFAULT_BRANCH", p.DefaultBranch()}, {"SYMBOL", sym},
			{"INSTALL", p.Get("INSTALL")}, {"COPY_FILES", p.Get("COPY_FILES")},
			{"COMPOSE_SERVICES", p.Get("COMPOSE_SERVICES")}, {"COMPOSE_PROJECT", p.Get("COMPOSE_PROJECT")},
			{"MIGRATE", p.Get("MIGRATE")}, {"SEED", p.Get("SEED")}, {"RUNTIME", p.Get("RUNTIME")},
			{"DB_URL_VARS", p.Get("DB_URL_VARS")}, {"ALWAYS", p.Get("ALWAYS")}, {"PRESETS", p.Get("PRESETS")},
			{"OPENS_ITSELF", p.Get("OPENS_ITSELF")}, {"PROCFILE", p.Get("PROCFILE")}, {"IN_REPO", p.InRepo},
			// The editor has a field for it and loaded it empty for as long as
			// the bash engine left it out.
			{"PORT_OFFSET", p.Get("PORT_OFFSET")},
		} {
			fmt.Fprintf(&b, "%s\t%s\n", kv[0], kv[1])
		}
		// TARGETS last: it is the only multi-line value, so nothing follows it.
		fmt.Fprintf(&b, "TARGETS\t%s\n", strings.ReplaceAll(p.Get("TARGETS"), "\n", "\x01"))
		ui.Out(b.String())

	case "set":
		// Rewrite one key in the LOCAL conf. The in-repo .runbranch is never
		// touched: it belongs to the repo and may be someone else's to change.
		if len(args) < 3 {
			usageExit()
		}
		config.Load(args[1])
		value := ""
		if len(args) > 3 {
			value = args[3]
		}
		config.SetProjectKey(args[1], args[2], value)

	case "paths":
		// Where things live, so the app never hardcodes the layout.
		p := needProject(args)
		line := fmt.Sprintf("%s\t%s\t%s\t%s\t%s", p.Worktrees, p.LogDir, filepath.Join(config.ProjectsDir, p.ID+".conf"), p.Repo(), gitx.GHRepo(p))
		if len(args) >= 3 {
			line += "\t" + gitx.WorktreePath(p, args[2])
		}
		ui.Out(line + "\n")

	case "presets":
		p := needProject(args)
		var b strings.Builder
		for _, n := range p.PresetNames() {
			b.WriteString(n + "\n")
		}
		ui.Out(b.String())

	case "state":
		run.State(needProject(args))

	case "favourite":
		if len(args) != 3 {
			usageExit()
		}
		on := args[2] == "on"
		if err := config.SetFavourite(args[1], on); err != nil {
			ui.Die("Could not update favourites: "+err.Error(), "ls -l "+config.RBHome)
		}
		if on {
			ui.OK(args[1] + " added to favourites")
		} else {
			ui.OK(args[1] + " removed from favourites")
		}

	case "refresh":
		p := needProject(args)
		if gitx.RefreshPRCache(p) == nil {
			ui.Out("refreshed\n")
		} else {
			ui.Errf("refresh failed\n")
		}

	case "refresh-pr-cache":
		// Not in the usage: the background half of a stale PR cache, started
		// detached by a listing so it outlives the listing.
		p := needProject(args)
		_ = gitx.RefreshPRCache(p)

	case "reclaim":
		if len(args) >= 2 {
			run.Reclaim(config.Load(args[1]))
		} else {
			run.ReclaimAll()
		}

	case "remove-worktree":
		if len(args) != 3 {
			usageExit()
		}
		run.RemoveWorktree(config.Load(args[1]), args[2])

	case "run":
		// run <project> <ref> <preset> [offset] [--in-place]
		//
		// offset shifts every port in the run, for when the declared ones are
		// taken. --in-place runs in the checkout instead of a worktree.
		if len(args) < 4 {
			usageExit()
		}
		p := config.Load(args[1])
		for _, a := range args[4:] {
			switch {
			case a == "--in-place":
				p.InPlace = true
			case a != "" && strings.Trim(a, "0123456789") == "":
				var n int
				fmt.Sscanf(a, "%d", &n)
				p.PortOffset = n
			default:
				ui.Die(fmt.Sprintf("Unexpected argument %q.", a), config.Self+" run <project> <ref> <preset> [offset] [--in-place]")
			}
		}
		run.DoRun(p, args[2], args[3])

	case "update":
		run.Update(needProject(args))

	case "prune-gone":
		disk.PruneGone(needProject(args))

	case "overlaps":
		// Machine-readable. doctor says the same thing in prose, which the app
		// cannot act on.
		var b strings.Builder
		for _, o := range ports.Overlaps() {
			fmt.Fprintf(&b, "%d\t%s\n", o.Port, strings.Join(o.Projects, " "))
		}
		ui.Out(b.String())

	case "suggest-offset":
		p := needProject(args)
		n, ok := ports.SuggestOffset(p)
		ui.Out(fmt.Sprintf("%d\n", n))
		if !ok {
			ui.ExitWith(1)
		}

	case "ports":
		rows := ports.Report()
		var b strings.Builder
		if ui.HaveTTY {
			fmt.Fprintf(&b, "\n%sPorts%s\n\n", ui.Bld, ui.Off)
			for _, r := range rows {
				what := r.What
				if r.State == "free" {
					what = ""
				}
				fmt.Fprintf(&b, "  %-16s %-8s %-6d %-8s %s\n", r.Project, r.Target, r.Port, r.State, what)
			}
			b.WriteString("\n")
		} else {
			for _, r := range rows {
				b.WriteString(r.TSV() + "\n")
			}
		}
		ui.Out(b.String())

	case "kill-port":
		if len(args) != 2 {
			usageExit()
		}
		ports.KillPort(args[1])

	case "check-ports":
		if len(args) != 3 {
			usageExit()
		}
		p := config.Load(args[1])
		targets := p.PresetTargets(args[2])
		if len(targets) == 0 {
			ui.Die(fmt.Sprintf("Unknown preset %q for %s.", args[2], p.Name()), config.Self+" presets "+args[1])
		}
		if !ports.CheckPorts(p, targets) {
			ui.ExitWith(1)
		}

	case "stop":
		run.StopRun(needProject(args), false)

	case "status":
		if len(args) >= 2 {
			if !run.PrintStatus(config.Load(args[1])) {
				ui.ExitWith(1)
			}
			return
		}
		any := false
		for _, p := range config.LoadAll() {
			if run.IsRunning(p) {
				run.PrintStatus(p)
				any = true
			}
		}
		if !any {
			ui.Out("\nNothing running.\n\n")
			ui.ExitWith(1)
		}

	case "cleanup":
		disk.Cleanup(needProject(args))

	case "disk":
		rows := disk.Report()
		if ui.HaveTTY {
			disk.PrintHuman(rows)
		} else {
			var b strings.Builder
			for _, r := range rows {
				b.WriteString(r.TSV() + "\n")
			}
			ui.Out(b.String())
		}

	case "scan":
		root := scan.DefaultRoot()
		if len(args) >= 2 && args[1] != "" {
			root = args[1]
		}
		scan.Scan(root)

	case "add":
		// Propose and write it, so the CLI and the app take the same path.
		if len(args) < 2 {
			usageExit()
		}
		scan.Add(args[1])

	case "remove":
		if len(args) < 2 {
			usageExit()
		}
		scan.Remove(args[1])

	case "propose":
		if len(args) < 2 {
			usageExit()
		}
		ui.Out(scan.Propose(args[1]))

	case "doctor":
		if len(args) >= 2 {
			if !scan.Doctor(config.Load(args[1])) {
				ui.ExitWith(1)
			}
			return
		}
		rc := 0
		for _, n := range config.ConfFiles() {
			var p *config.Project
			if f := ui.Catch(func() { p = config.Load(n) }); f != nil {
				ui.PrintFailure(f)
				rc = 1
				continue
			}
			if !scan.Doctor(p) {
				rc = 1
			}
		}
		// Across projects rather than within one, so it belongs here and not
		// in Doctor.
		ports.ReportOverlaps()
		if rc != 0 {
			ui.ExitWith(rc)
		}

	case "-h", "--help", "help":
		usage()

	case "--version", "version":
		ui.Out("runbranch " + version + "\n")

	case "menu", "":
		menu()

	default:
		usageExit()
	}
}
