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

// Package proc is everything the engine does to other processes: start a
// server that outlives the engine, tell whether it is still there, stop it and
// everything it spawned, and say what a stranger holding a port is.
//
// It is the only package with per-OS code for processes. Everything above it
// is written once. The API in this file is the contract; the implementations
// live in proc_darwin.go and proc_windows.go.
package proc

import (
	"io"
	"time"
)

// Handle identifies a started server. PID is the root of its process tree —
// on macOS also its process group id. Started is the process creation time in
// unix seconds, recorded so that a PID reused after a reboot or a crash is not
// mistaken for the server: Alive and StopTree compare it when it is non-zero.
type Handle struct {
	PID     int
	Started int64
}

// Spec describes a server to start.
type Spec struct {
	Command string   // a shell command line, as written in TARGETS
	Dir     string   // working directory
	Env     []string // the complete environment (os.Environ() plus additions)
	LogPath string   // truncated, then receives stdout and stderr
}

// Start launches spec detached from the engine, in its own process group
// (and, on Windows, its own hidden console), with stdin closed, and returns
// without waiting. The server must survive the engine exiting.
//
//	macOS:   /bin/bash -c <Command>, Setpgid
//	Windows: cmd.exe /d /s /c <Command>, CREATE_NEW_PROCESS_GROUP |
//	         CREATE_NO_WINDOW (+ CREATE_BREAKAWAY_FROM_JOB when allowed).
//	         Not DETACHED_PROCESS: see proc_windows.go, finding 1.
func Start(spec Spec) (Handle, error) { return start(spec) }

// Run executes a shell command line in the foreground (INSTALL, MIGRATE,
// SEED), streaming its combined output to out, and returns its exit error.
func Run(command, dir string, env []string, out io.Writer) error {
	return run(command, dir, env, out)
}

// Shell returns the program and arguments that run a command line on this OS.
func Shell(command string) (string, []string) { return shell(command) }

// Alive reports whether the handle's process is still running. A process
// that exists but cannot be signalled (EPERM, ACCESS_DENIED) is alive.
func Alive(h Handle) bool { return alive(h) }

// Exists reports whether any process has this pid, including ones we may not
// signal. Used where only the pid is known (kill-port, adopted runs).
func Exists(pid int) bool { return exists(pid) }

// StartTime returns a pid's creation time in unix seconds.
func StartTime(pid int) (int64, error) { return startTime(pid) }

// StopTree stops the whole tree rooted at h: a graceful request first, then,
// after grace, a forced kill of every process still in it — survivors
// included, not only the root. Returns nil when nothing is left.
func StopTree(h Handle, grace time.Duration) error { return stopTree(h, grace) }

// Terminate asks a single process to stop and waits up to grace for it to go.
// It does not force: kill-port refuses to escalate on a process it did not
// start, and says so.
func Terminate(pid int, grace time.Duration) error { return terminate(pid, grace) }

// Cmdline returns a process's full command line, or an error when the OS will
// not say.
func Cmdline(pid int) (string, error) { return cmdline(pid) }

// Cwd returns a process's working directory, or an error when the OS will not
// say. On Windows this is best effort; callers fall back to Cmdline.
func Cwd(pid int) (string, error) { return cwd(pid) }

// OpenURL opens a URL in the default browser.
func OpenURL(url string) error { return openURL(url) }
