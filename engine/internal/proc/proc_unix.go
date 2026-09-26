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

//go:build !windows

package proc

// Processes on macOS, and on Linux so the engine builds and tests in CI. The
// per-OS parts (the process table, start times, working directories) live in
// proc_darwin.go and proc_linux.go.

import (
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"strings"
	"syscall"
	"time"

	"golang.org/x/sys/unix"
)

const pollEvery = 200 * time.Millisecond

// uproc is one row of the process table. started is in microseconds, finer
// than Handle.Started, so the parent-before-child check is exact.
type uproc struct {
	pid, ppid, pgid int
	started         int64
	zombie          bool
}

func shell(command string) (string, []string) { return "/bin/bash", []string{"-c", command} }

func start(spec Spec) (Handle, error) {
	log, err := os.OpenFile(spec.LogPath, os.O_CREATE|os.O_TRUNC|os.O_WRONLY, 0o644)
	if err != nil {
		return Handle{}, err
	}
	defer log.Close() // the child has its own copy
	null, err := os.Open(os.DevNull)
	if err != nil {
		return Handle{}, err
	}
	defer null.Close()

	// bash, not sh: existing confs are written for it. Setpgid puts the
	// server in a group of its own, which is what lets a stop reach a
	// watcher and its child together (I-49), and keeps it out of the
	// terminal's foreground group, so a closed terminal's SIGHUP and a Ctrl+C
	// meant for the engine do not reach it.
	c := exec.Command("/bin/bash", "-c", spec.Command)
	c.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	c.Dir, c.Env = spec.Dir, spec.Env
	c.Stdin, c.Stdout, c.Stderr = null, log, log
	if err := c.Start(); err != nil {
		return Handle{}, err
	}
	h := Handle{PID: c.Process.Pid}
	if t, err := startTime(h.PID); err == nil {
		h.Started = t
	}
	// Reap it rather than Release it. A child nobody waits for stays a zombie
	// for as long as the engine runs, and kill(pid, 0) succeeds on a zombie,
	// so a server that died a second after starting would still look alive
	// to this same invocation's "exited immediately" and health checks. bash
	// reaped automatically; Go does not. Waiting in a goroutine does not tie
	// the server to the engine: when the engine exits the server is simply
	// reparented.
	go c.Wait()
	return h, nil
}

func run(command, dir string, env []string, out io.Writer) error {
	c := exec.Command("/bin/bash", "-c", command)
	c.Dir, c.Env = dir, env
	c.Stdout, c.Stderr = out, out // stdin nil is /dev/null: never prompt
	return c.Run()
}

// signalled reports whether kill(target, 0) found something. EPERM means it
// exists and belongs to someone else (I-48): that is not "gone".
func signalled(target int) bool {
	err := unix.Kill(target, 0)
	return err == nil || errors.Is(err, unix.EPERM)
}

func sameSecond(a, b int64) bool { d := a - b; return d >= -1 && d <= 1 }

func exists(pid int) bool {
	// pid 0 and -1 mean "my group" and "everyone" to kill(2); never probe them.
	if pid <= 0 || !signalled(pid) {
		return false
	}
	if p, err := procInfo(pid); err == nil && p.zombie {
		return false
	}
	return true
}

func alive(h Handle) bool {
	if !exists(h.PID) {
		return false
	}
	if h.Started != 0 {
		if t, err := startTime(h.PID); err == nil && !sameSecond(t, h.Started) {
			return false // the pid now belongs to someone else
		}
	}
	return true
}

func startTime(pid int) (int64, error) {
	p, err := procInfo(pid)
	if err != nil {
		return 0, err
	}
	return p.started / 1_000_000, nil
}

// outsiders returns the live descendants of root that are not in its
// process group, keyed by pid with their start times. Most of a server stays
// in the group, and the group signal reaches it. A child that called setsid
// or setpgid has left, and was the part the old bash kill_group could
// strand. It is found now, while its parent still links it to the tree: once
// the parent dies it is reparented to launchd and nothing links it any more.
func outsiders(root uproc, table map[int]uproc) map[int]int64 {
	children := make(map[int][]uproc)
	for _, p := range table {
		children[p.ppid] = append(children[p.ppid], p)
	}
	out := map[int]int64{}
	queue := []uproc{root}
	seen := map[int]bool{root.pid: true}
	for len(queue) > 0 {
		n := queue[0]
		queue = queue[1:]
		for _, c := range children[n.pid] {
			// A child cannot predate its parent; if it seems to, the table
			// changed under us, so leave it alone.
			if seen[c.pid] || c.zombie || c.started < n.started {
				continue
			}
			seen[c.pid] = true
			if c.pgid != root.pid {
				out[c.pid] = c.started
			}
			queue = append(queue, c)
		}
	}
	return out
}

func stopTree(h Handle, grace time.Duration) error {
	if h.PID <= 1 {
		return nil
	}
	pgid := h.PID
	table, err := processTable()
	if err != nil {
		return err
	}
	root, rootLive := table[h.PID]
	if rootLive && h.Started != 0 && !sameSecond(root.started/1_000_000, h.Started) {
		// The pid was reused. A pid is not handed out while a process group
		// of that id still exists, so our group is gone too, and the
		// newcomer is none of our business.
		return nil
	}
	rootLive = rootLive && !root.zombie

	extra := map[int]int64{}
	sweep := func() {
		t, err := processTable()
		if err != nil {
			return
		}
		for pid, st := range extra {
			if p, ok := t[pid]; !ok || p.started != st || p.zombie {
				delete(extra, pid)
			}
		}
		if r, ok := t[h.PID]; ok && rootLive {
			for pid, st := range outsiders(r, t) {
				extra[pid] = st
			}
		}
	}
	if rootLive {
		for pid, st := range outsiders(root, table) {
			extra[pid] = st
		}
	}
	groupLive := func() bool { return signalled(-pgid) }
	done := func() bool { return !groupLive() && !alive(h) && len(extra) == 0 }
	if done() {
		return nil
	}

	signalAll := func(sig unix.Signal) {
		if err := unix.Kill(-pgid, sig); errors.Is(err, unix.ESRCH) && rootLive {
			unix.Kill(h.PID, sig) // started some other way: not a group leader
		}
		for pid, st := range extra {
			if p, err := procInfo(pid); err == nil && p.started == st {
				unix.Kill(pid, sig)
			}
		}
	}

	signalAll(unix.SIGTERM)
	for deadline := time.Now().Add(grace); time.Now().Before(deadline); {
		time.Sleep(pollEvery)
		sweep()
		if done() {
			return nil
		}
	}
	// Survivors included: the whole group, whether or not its leader is
	// still there, and every outsider still running. The bash version polled
	// only the leader and skipped the KILL when the leader died first.
	sweep()
	signalAll(unix.SIGKILL)
	for deadline := time.Now().Add(3 * time.Second); ; {
		sweep()
		if done() {
			return nil
		}
		if !time.Now().Before(deadline) {
			return fmt.Errorf("process group %d is still running after SIGKILL", pgid)
		}
		time.Sleep(pollEvery)
	}
}

func terminate(pid int, grace time.Duration) error {
	if pid <= 1 {
		return fmt.Errorf("refusing to signal pid %d", pid)
	}
	if !exists(pid) {
		return nil
	}
	started, _ := startTime(pid)
	if err := unix.Kill(pid, unix.SIGTERM); err != nil {
		if errors.Is(err, unix.ESRCH) {
			return nil
		}
		return fmt.Errorf("pid %d: %w", pid, err)
	}
	for deadline := time.Now().Add(grace); ; {
		if !alive(Handle{PID: pid, Started: started}) {
			return nil
		}
		if !time.Now().Before(deadline) {
			return fmt.Errorf("pid %d did not stop within %s", pid, grace)
		}
		time.Sleep(pollEvery)
	}
}

func cmdline(pid int) (string, error) {
	if pid <= 0 {
		return "", fmt.Errorf("no process %d", pid)
	}
	// -ww: never truncate to a terminal width, which ps otherwise may do.
	out, err := exec.Command("ps", "-ww", "-o", "command=", "-p", fmt.Sprint(pid)).Output()
	s := strings.TrimSpace(string(out))
	if err != nil || s == "" {
		return "", fmt.Errorf("pid %d: no command line", pid)
	}
	return s, nil
}
