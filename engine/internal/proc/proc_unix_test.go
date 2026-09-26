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

//go:build darwin || linux

package proc_test

// Written on Windows and not yet run: macOS CI runs these. Every tree a test
// starts is stopped in t.Cleanup, so a failure never leaves one behind.

import (
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"

	"github.com/aosmcleod/runbranch/engine/internal/ports"
	"github.com/aosmcleod/runbranch/engine/internal/proc"
)

func startUnix(t *testing.T, command string) (proc.Handle, string) {
	t.Helper()
	log := filepath.Join(t.TempDir(), "server.log")
	h, err := proc.Start(proc.Spec{Command: command, Dir: t.TempDir(), Env: os.Environ(), LogPath: log})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { proc.StopTree(h, 0) })
	return h, log
}

func treeOf(t *testing.T, h proc.Handle) map[int]int64 {
	t.Helper()
	m, err := proc.TreeOf(h)
	if err != nil {
		t.Fatal(err)
	}
	return m
}

func waitTree(t *testing.T, h proc.Handle, n int) map[int]int64 {
	t.Helper()
	for deadline := time.Now().Add(10 * time.Second); ; time.Sleep(100 * time.Millisecond) {
		if m := treeOf(t, h); len(m) >= n {
			return m
		}
		if time.Now().After(deadline) {
			t.Fatalf("tree never reached %d processes: %v", n, treeOf(t, h))
		}
	}
}

// A root that ignores TERM, a child in its group, and a child that left the
// group: after the grace every one of them is killed.
func TestStopTreeGroupAndOutsider(t *testing.T) {
	if _, err := exec.LookPath("perl"); err != nil {
		t.Skip("perl is needed to leave the process group")
	}
	h, _ := startUnix(t, `trap '' TERM; sleep 300 & perl -e 'setpgrp(0,0); $SIG{TERM}="IGNORE"; sleep 300' & wait`)
	before := waitTree(t, h, 3)

	began := time.Now()
	if err := proc.StopTree(h, 2*time.Second); err != nil {
		t.Fatal(err)
	}
	if took := time.Since(began); took < 2*time.Second {
		t.Errorf("stopped in %s, before the grace; TERM should have been ignored", took)
	}
	for pid, st := range before {
		if proc.Still(pid, st) {
			t.Errorf("pid %d survived StopTree", pid)
		}
	}
	if proc.Alive(h) {
		t.Error("root still alive")
	}
}

// The bug the bash version had: the leader exits on TERM, its children do
// not, and the KILL was skipped because only the leader was polled.
func TestStopTreeLeaderDiesFirst(t *testing.T) {
	h, _ := startUnix(t, `(trap '' TERM; sleep 300) & (trap '' TERM; sleep 300) & wait`)
	before := waitTree(t, h, 3)
	if err := proc.StopTree(h, time.Second); err != nil {
		t.Fatal(err)
	}
	for pid, st := range before {
		if proc.Still(pid, st) {
			t.Errorf("pid %d survived its leader", pid)
		}
	}
}

func TestStopTreeGraceful(t *testing.T) {
	h, _ := startUnix(t, `sleep 300 & wait`)
	before := waitTree(t, h, 2)
	began := time.Now()
	if err := proc.StopTree(h, 10*time.Second); err != nil {
		t.Fatal(err)
	}
	if took := time.Since(began); took > 5*time.Second {
		t.Errorf("a TERM-respecting tree took %s to stop", took)
	}
	for pid, st := range before {
		if proc.Still(pid, st) {
			t.Errorf("pid %d survived", pid)
		}
	}
}

func TestAliveAndStartTime(t *testing.T) {
	h, _ := startUnix(t, `sleep 300`)
	if h.Started == 0 {
		t.Fatal("no start time recorded")
	}
	if !proc.Alive(h) || !proc.Exists(h.PID) {
		t.Error("a running server is not alive")
	}
	if proc.Alive(proc.Handle{PID: h.PID, Started: h.Started - 100}) {
		t.Error("a stale start time is reported alive: pid reuse would go unnoticed")
	}
	if st, err := proc.StartTime(h.PID); err != nil || st != h.Started {
		t.Errorf("StartTime = %d, %v; recorded %d", st, err, h.Started)
	}
	if proc.Exists(0) || proc.Exists(-1) {
		t.Error("pid 0 or -1 reported as a process")
	}
	if !proc.Exists(1) {
		t.Error("pid 1 (EPERM) should exist")
	}
}

// Started and exited within this same engine process: it must not linger as
// a zombie that kill(pid, 0) still finds.
func TestExitedServerIsNotAlive(t *testing.T) {
	h, log := startUnix(t, `echo "a&b" && exit 0`)
	for deadline := time.Now().Add(5 * time.Second); proc.Alive(h) && time.Now().Before(deadline); {
		time.Sleep(50 * time.Millisecond)
	}
	if proc.Alive(h) {
		t.Fatal("an exited server is still alive (unreaped zombie?)")
	}
	if b, _ := os.ReadFile(log); !strings.Contains(string(b), "a&b") {
		t.Errorf("log %q", b)
	}
}

func TestTerminate(t *testing.T) {
	h, _ := startUnix(t, `sleep 300`)
	if err := proc.Terminate(h.PID, 5*time.Second); err != nil {
		t.Fatal(err)
	}
	if proc.Alive(h) {
		t.Error("still alive after Terminate")
	}
	stubborn, _ := startUnix(t, `trap '' TERM; while :; do sleep 1; done`)
	if err := proc.Terminate(stubborn.PID, time.Second); err == nil {
		t.Error("Terminate claimed success on a process ignoring TERM")
	}
	if !proc.Alive(stubborn) {
		t.Error("Terminate escalated")
	}
}

func TestRunQuoting(t *testing.T) {
	var out strings.Builder
	if err := proc.Run(`echo "a&b" && echo second`, t.TempDir(), nil, &out); err != nil {
		t.Fatal(err)
	}
	if s := out.String(); !strings.Contains(s, "a&b") || !strings.Contains(s, "second") {
		t.Errorf("output %q", s)
	}
	if err := proc.Run("exit 3", "", nil, &out); err == nil {
		t.Error("exit 3 reported success")
	}
}

func TestInspectSelfAndListener(t *testing.T) {
	wd, _ := os.Getwd()
	want, _ := filepath.EvalSymlinks(wd)
	if d, err := proc.Cwd(os.Getpid()); err != nil {
		t.Errorf("Cwd: %v", err)
	} else if got, _ := filepath.EvalSymlinks(d); got != want {
		t.Errorf("Cwd = %q, want %q", got, want)
	}
	exe, _ := os.Executable()
	if cl, err := proc.Cmdline(os.Getpid()); err != nil || !strings.Contains(cl, filepath.Base(exe)) {
		t.Errorf("Cmdline = %q, %v", cl, err)
	}

	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer l.Close()
	port := l.Addr().(*net.TCPAddr).Port
	snap, err := ports.Listeners()
	if err != nil {
		if runtime.GOOS != "darwin" {
			t.Skipf("no listener snapshot here: %v", err)
		}
		t.Fatal(err)
	}
	if pid := snap.Holder(port); pid != os.Getpid() {
		t.Errorf("port %d held by %d, want %d", port, pid, os.Getpid())
	}
}
