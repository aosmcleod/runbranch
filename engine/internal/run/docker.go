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
	"bufio"
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"runtime"
	"strings"
	"time"

	"github.com/aosmcleod/runbranch/engine/internal/config"
	"github.com/aosmcleod/runbranch/engine/internal/proc"
	"github.com/aosmcleod/runbranch/engine/internal/ui"
)

// Docker Desktop is the usual reason a run with COMPOSE_SERVICES stops before
// it starts: installed, but not running, because nothing starts it at login
// unless someone asked it to. Saying "start Docker Desktop" and stopping made
// a person do by hand the one thing the run could do itself, so it starts it
// and waits for the daemon, and only stops when the daemon never answers.
//
// The seams below are variables so the wait can be tested without Docker.
var (
	dockerAnswers = func() bool {
		ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		return exec.CommandContext(ctx, "docker", "info").Run() == nil
	}
	startDockerDesktop = launchDockerDesktop
	staleSockets       = staleSocketDirs
	dockerWait         = 2 * time.Minute
	dockerPoll         = 2 * time.Second
)

var errNoDockerDesktop = errors.New("Docker Desktop is not where it installs itself")

// ensureDocker returns once the Docker daemon answers, starting Docker
// Desktop when it is installed and not running. Dies when the daemon cannot
// be reached, with the reason it could not.
func ensureDocker() {
	RequireCmd("docker", "Install Docker Desktop: https://www.docker.com/products/docker-desktop/")
	if dockerAnswers() {
		return
	}
	// Docker Desktop may already be running and stuck, having reported the
	// error before this run began; a second launch of it reports nothing.
	if dirs := staleSockets(time.Now().Add(-15 * time.Minute)); len(dirs) > 0 {
		dieStaleSockets(dirs)
	}
	if err := startDockerDesktop(); err != nil {
		ui.Die("Docker is installed but the daemon is not responding, and "+err.Error()+".", ui.DockerStartFix())
	}
	ui.Info("starting Docker Desktop, and waiting for it to answer")
	waitForDocker(time.Now())
}

// waitForDocker returns once the daemon answers. It dies early when Docker
// Desktop reports the stale-socket failure, which no amount of waiting fixes,
// and otherwise after dockerWait.
func waitForDocker(began time.Time) {
	for time.Since(began) < dockerWait {
		time.Sleep(dockerPoll)
		if dockerAnswers() {
			ui.OK(fmt.Sprintf("Docker is up (%ds)", int(time.Since(began).Seconds())))
			return
		}
		if dirs := staleSockets(began.Add(-5 * time.Second)); len(dirs) > 0 {
			dieStaleSockets(dirs)
		}
	}
	ui.Die(fmt.Sprintf("Docker Desktop was started but the daemon did not answer within %s.", dockerWait),
		ui.DockerStartFix())
}

// launchDockerDesktop starts the app and returns at once; the caller does the
// waiting. Detached, and out of the caller's job where it may leave, so
// closing the Runbranch window does not take Docker with it.
func launchDockerDesktop() error {
	switch runtime.GOOS {
	case "windows":
		exe := filepath.Join(os.Getenv("ProgramFiles"), "Docker", "Docker", "Docker Desktop.exe")
		if _, err := os.Stat(exe); err != nil {
			return errNoDockerDesktop
		}
		return proc.SpawnDetached(exe)
	case "darwin":
		// `open` hands the app to Launch Services and exits.
		return exec.Command("open", "-a", "Docker").Run()
	default:
		return errors.New("on Linux the daemon is a service Runbranch does not start")
	}
}

// The stale-socket failure, on Windows. Docker Desktop leaves its AF_UNIX
// socket files behind when it is killed rather than quit (sleep, a shutdown,
// a process cleanup), and on the next start it cannot rename them out of the
// way: Windows refuses ("The file cannot be accessed by the system"). It then
// stays stuck however long it is given. The sockets live in more than one
// folder (Docker\run, and docker-secrets-engine outside it), and it reports
// them one at a time, so a fix that clears only the first just moves on to
// the next. docker-repair clears both.
//
// It says so in its backend log:
//
//	[2026-10-03T17:36:43.411787700Z][com.docker.backend.exe.report] reporting
//	error to user: starting services: initializing Secrets Engine: listening on
//	unix://C:/Users/x/AppData/Local/docker-secrets-engine/engine.sock: rename …
var (
	dockerBackendLog = func() string {
		return filepath.Join(os.Getenv("LOCALAPPDATA"), "Docker", "log", "host", "com.docker.backend.exe.log")
	}
	staleSocketLine = regexp.MustCompile(`^\[([0-9T:.\-]+Z)\].*reporting error to user: starting services:.*listening on unix://(\S+?\.sock): rename `)
)

// staleSocketDirs returns the folders holding sockets Docker Desktop has
// reported it cannot reuse since t, newest log lines only. Nothing off
// Windows, and nothing when the log cannot be read.
func staleSocketDirs(since time.Time) []string {
	if runtime.GOOS != "windows" {
		return nil
	}
	return staleSocketDirsIn(dockerBackendLog(), since)
}

func staleSocketDirsIn(logFile string, since time.Time) []string {
	f, err := os.Open(logFile)
	if err != nil {
		return nil
	}
	defer f.Close()
	// The log runs to megabytes and rotates; the lines that matter are at
	// the end.
	if st, err := f.Stat(); err == nil && st.Size() > 1<<20 {
		_, _ = f.Seek(-1<<20, io.SeekEnd)
	}
	seen := map[string]bool{}
	var dirs []string
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 0, 64*1024), 1<<20)
	for sc.Scan() {
		m := staleSocketLine.FindStringSubmatch(sc.Text())
		if m == nil {
			continue
		}
		at, err := time.Parse(time.RFC3339Nano, m[1])
		if err != nil || at.Before(since) {
			continue
		}
		dir := filepath.Dir(filepath.FromSlash(m[2]))
		if key := strings.ToLower(dir); !seen[key] {
			seen[key] = true
			dirs = append(dirs, dir)
		}
	}
	return dirs
}

func dieStaleSockets(dirs []string) {
	ui.Die("Docker Desktop cannot start: it was killed rather than quit last time, and the socket\n"+
		"files it left behind are in the way, in:\n    "+strings.Join(dirs, "\n    ")+"\n\n"+
		"Windows will not let it reuse them, so waiting does not help. docker-repair quits Docker,\n"+
		"runs `wsl --shutdown` (which stops every WSL distro, not just Docker's), renames its\n"+
		"socket folders aside and starts it again.",
		config.Self+" docker-repair")
}
