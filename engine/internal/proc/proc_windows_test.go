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

package proc_test

// These tests start real node servers on this machine. Every tree a test
// starts is stopped in t.Cleanup, pinned by pid and creation time, so a
// failure never leaves a server behind and nothing else is ever touched.

import (
	"context"
	"fmt"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"syscall"
	"testing"
	"time"
	"unsafe"

	"github.com/aosmcleod/runbranch/engine/internal/ports"
	"github.com/aosmcleod/runbranch/engine/internal/proc"
	"golang.org/x/sys/windows"
)

var (
	user32                       = windows.NewLazySystemDLL("user32.dll")
	procEnumWindows              = user32.NewProc("EnumWindows")
	procGetWindowThreadProcessID = user32.NewProc("GetWindowThreadProcessId")
	procIsWindowVisible          = user32.NewProc("IsWindowVisible")
)

func nodeDir(t *testing.T) string {
	t.Helper()
	if p, err := exec.LookPath("node"); err == nil {
		return filepath.Dir(p)
	}
	if _, err := os.Stat(`C:\Program Files\nodejs\node.exe`); err == nil {
		return `C:\Program Files\nodejs`
	}
	t.Skip("node is not installed")
	return ""
}

func testEnv(t *testing.T) []string {
	return append(os.Environ(), "PATH="+nodeDir(t)+";"+os.Getenv("PATH"))
}

func testdata(t *testing.T) string {
	t.Helper()
	d, err := filepath.Abs("testdata")
	if err != nil {
		t.Fatal(err)
	}
	return d
}

// freePorts finds n consecutive free ports.
func freePorts(t *testing.T, n int) int {
	t.Helper()
	for base := 47200; base < 48000; base += n {
		ok := true
		var held []net.Listener
		for p := base; p < base+n; p++ {
			l, err := net.Listen("tcp", fmt.Sprintf(":%d", p))
			if err != nil {
				ok = false
				break
			}
			held = append(held, l)
		}
		for _, l := range held {
			l.Close()
		}
		if ok {
			return base
		}
	}
	t.Fatal("no free ports")
	return 0
}

// stopOnCleanup makes sure a tree is gone when the test ends, pass or fail.
func stopOnCleanup(t *testing.T, h proc.Handle) {
	t.Cleanup(func() {
		if err := proc.StopTree(h, 0); err != nil {
			t.Errorf("cleanup: %v", err)
		}
	})
}

func treePIDs(t *testing.T, h proc.Handle) map[int]bool {
	t.Helper()
	pids, err := proc.TreePIDs(h)
	if err != nil {
		t.Fatal(err)
	}
	return pids
}

// waitListening waits until every port has a holder and returns them.
func waitListening(t *testing.T, ps ...int) map[int]int {
	t.Helper()
	deadline := time.Now().Add(20 * time.Second)
	for {
		snap, err := ports.Listeners()
		if err != nil {
			t.Fatal(err)
		}
		got := map[int]int{}
		for _, p := range ps {
			if pid := snap.Holder(p); pid != 0 {
				got[p] = pid
			}
		}
		if len(got) == len(ps) {
			return got
		}
		if time.Now().After(deadline) {
			t.Fatalf("ports %v not all listening; got %v", ps, got)
		}
		time.Sleep(200 * time.Millisecond)
	}
}

func waitFree(t *testing.T, ps ...int) {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for {
		snap, err := ports.Listeners()
		if err != nil {
			t.Fatal(err)
		}
		busy := []int{}
		for _, p := range ps {
			if snap.Holder(p) != 0 {
				busy = append(busy, p)
			}
		}
		if len(busy) == 0 {
			return
		}
		if time.Now().After(deadline) {
			t.Fatalf("ports still held after stop: %v", busy)
		}
		time.Sleep(100 * time.Millisecond)
	}
}

// goRun runs the rbhelper program as its own process, as a later engine
// invocation would be. It gets a hidden console like everything else here, so
// the test itself cannot pop a window.
func goRun(t *testing.T, args ...string) string {
	t.Helper()
	goBin, err := exec.LookPath("go")
	if err != nil {
		goBin = filepath.Join(runtime.GOROOT(), "bin", "go.exe")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Minute)
	defer cancel()
	c := exec.CommandContext(ctx, goBin, append([]string{"run", "./testdata/rbhelper"}, args...)...)
	c.Env = testEnv(t)
	c.SysProcAttr = &syscall.SysProcAttr{CreationFlags: windows.CREATE_NO_WINDOW}
	out, err := c.CombinedOutput()
	if err != nil {
		t.Fatalf("rbhelper %v: %v\n%s", args, err, out)
	}
	return strings.TrimSpace(string(out))
}

// windowsOf lists the top-level windows owned by any of pids.
func windowsOf(pids map[int]bool) []string {
	var found []string
	cb := windows.NewCallback(func(hwnd uintptr, _ uintptr) uintptr {
		var pid uint32
		procGetWindowThreadProcessID.Call(hwnd, uintptr(unsafe.Pointer(&pid)))
		if pids[int(pid)] {
			vis, _, _ := procIsWindowVisible.Call(hwnd)
			found = append(found, fmt.Sprintf("hwnd %#x pid %d visible=%d", hwnd, pid, vis))
		}
		return 1
	})
	procEnumWindows.Call(cb, 0)
	return found
}

// consoleHosts is every process that hosts a visible console: Windows
// Terminal and its OpenConsole. A server tree that opened a console window
// would add one.
func consoleHosts(t *testing.T) map[int]string {
	t.Helper()
	names, err := proc.ProcessNames()
	if err != nil {
		t.Fatal(err)
	}
	out := map[int]string{}
	for pid, name := range names {
		n := strings.ToLower(name)
		if n == "windowsterminal.exe" || n == "openconsole.exe" {
			out[pid] = name
		}
	}
	return out
}

func assertNoWindows(t *testing.T, pids map[int]bool, before map[int]string) {
	t.Helper()
	if w := windowsOf(pids); len(w) > 0 {
		t.Errorf("server tree owns windows: %v", w)
	}
	for pid, name := range consoleHosts(t) {
		if _, ok := before[pid]; !ok {
			t.Errorf("a console host appeared during the test: %s (pid %d)", name, pid)
		}
	}
}

func readLog(t *testing.T, path string) string {
	b, _ := os.ReadFile(path)
	return string(b)
}

// The whole life of a server as the engine sees it: one process starts it and
// exits, the test inspects it, and a later process stops it.
func TestServerTreeAcrossInvocations(t *testing.T) {
	dir := testdata(t)
	port := freePorts(t, 2)
	log := filepath.Join(t.TempDir(), "tree.log")
	hosts := consoleHosts(t)

	var h proc.Handle
	out := goRun(t, "start", dir, log, fmt.Sprintf("node tree.js %d tree", port))
	if _, err := fmt.Sscanf(out, "%d %d", &h.PID, &h.Started); err != nil {
		t.Fatalf("start printed %q", out)
	}
	stopOnCleanup(t, h)

	holders := waitListening(t, port, port+1)
	tree := treePIDs(t, h)
	for p, pid := range holders {
		if !tree[pid] {
			t.Errorf("port %d is held by pid %d, which is not in the tree %v", p, pid, tree)
		}
	}
	t.Logf("root %d, tree %v, holders %v", h.PID, tree, holders)

	parent := holders[port]
	if cl, err := proc.Cmdline(parent); err != nil || !strings.Contains(cl, "tree.js") {
		t.Errorf("proc.Cmdline(%d) = %q, %v", parent, cl, err)
	}
	if d, err := proc.Cwd(parent); err != nil || !strings.EqualFold(d, dir) {
		t.Errorf("proc.Cwd(%d) = %q, %v; want %q", parent, d, err, dir)
	}
	if cl, err := proc.Cmdline(h.PID); err != nil || !strings.Contains(cl, `/d /s /c "node tree.js`) {
		t.Errorf("root command line %q, %v", cl, err)
	}
	for _, pid := range []int{h.PID, parent, holders[port+1]} {
		if g, err := proc.GroupID(pid); err != nil || g != h.PID {
			t.Errorf("proc.GroupID(%d) = %d, %v; want the root %d", pid, g, err, h.PID)
		}
	}

	if !proc.Alive(h) || !proc.Alive(proc.Handle{PID: h.PID}) || !proc.Exists(h.PID) {
		t.Error("the root is not reported alive")
	}
	if proc.Alive(proc.Handle{PID: h.PID, Started: h.Started - 100}) {
		t.Error("a stale start time is reported alive: pid reuse would go unnoticed")
	}
	if st, err := proc.StartTime(h.PID); err != nil || st != h.Started {
		t.Errorf("StartTime = %d, %v; recorded %d", st, err, h.Started)
	}

	assertNoWindows(t, tree, hosts)

	began := time.Now()
	goRun(t, "stop", fmt.Sprint(h.PID), fmt.Sprint(h.Started), "12000")
	t.Logf("stopped from a later process in %s", time.Since(began).Round(time.Millisecond))

	if left := treePIDs(t, h); len(left) > 0 {
		t.Errorf("still running after StopTree: %v", left)
	}
	for pid := range tree {
		if proc.Exists(pid) {
			if st, _ := proc.StartTime(pid); st != 0 && proc.SameSecond(st, h.Started) {
				t.Errorf("pid %d from the tree survived", pid)
			}
		}
	}
	waitFree(t, port, port+1)
	if proc.Alive(h) {
		t.Error("root still alive")
	}
	if l := readLog(t, log); !strings.Contains(l, "parent") || !strings.Contains(l, "got SIGBREAK") {
		t.Errorf("expected a graceful CTRL_BREAK stop; log:\n%s", l)
	}
}

// A watcher that restarts its child the moment it dies, and ignores the
// graceful request, must still be cleared by the forced step.
func TestStopTreeRespawningWatcher(t *testing.T) {
	port := freePorts(t, 1)
	log := filepath.Join(t.TempDir(), "watcher.log")
	hosts := consoleHosts(t)
	h, err := proc.Start(proc.Spec{Command: fmt.Sprintf("node tree.js %d watcher", port), Dir: testdata(t), Env: testEnv(t), LogPath: log})
	if err != nil {
		t.Fatal(err)
	}
	stopOnCleanup(t, h)

	first := waitListening(t, port)[port]
	// Kill the child once to prove the watcher really respawns.
	if err := proc.KillOne(first); err != nil {
		t.Fatal(err)
	}
	var second int
	for deadline := time.Now().Add(10 * time.Second); time.Now().Before(deadline); time.Sleep(100 * time.Millisecond) {
		snap, _ := ports.Listeners()
		if p := snap.Holder(port); p != 0 && p != first {
			second = p
			break
		}
	}
	if second == 0 {
		t.Fatalf("watcher did not respawn its child; log:\n%s", readLog(t, log))
	}
	tree := treePIDs(t, h)
	if !tree[second] {
		t.Errorf("respawned child %d is not in the tree %v", second, tree)
	}
	assertNoWindows(t, tree, hosts)

	began := time.Now()
	if err := proc.StopTree(h, 2*time.Second); err != nil {
		t.Fatal(err)
	}
	t.Logf("forced stop took %s", time.Since(began).Round(time.Millisecond))
	if left := treePIDs(t, h); len(left) > 0 {
		t.Errorf("still running: %v", left)
	}
	waitFree(t, port)
	if l := readLog(t, log); !strings.Contains(l, "ignored SIGBREAK") {
		t.Errorf("the watcher never saw the graceful request; log:\n%s", l)
	}
}

// The known macOS bug, on Windows: the root dies first and its children
// carry on. StopTree must still find and stop them.
func TestStopTreeAfterRootDied(t *testing.T) {
	port := freePorts(t, 2)
	h, err := proc.Start(proc.Spec{Command: fmt.Sprintf("node tree.js %d tree", port), Dir: testdata(t), Env: testEnv(t), LogPath: filepath.Join(t.TempDir(), "orphans.log")})
	if err != nil {
		t.Fatal(err)
	}
	stopOnCleanup(t, h)
	waitListening(t, port, port+1)

	if err := proc.KillOne(h.PID); err != nil {
		t.Fatal(err)
	}
	if proc.Alive(h) {
		t.Fatal("root survived TerminateProcess")
	}
	orphans := treePIDs(t, h)
	if len(orphans) == 0 {
		t.Fatal("the children died with the root; nothing to test")
	}
	if err := proc.StopTree(h, 5*time.Second); err != nil {
		t.Fatal(err)
	}
	if left := treePIDs(t, h); len(left) > 0 {
		t.Errorf("orphans survived: %v", left)
	}
	waitFree(t, port, port+1)
}

// Terminate asks and never forces. A group leader gets CTRL_BREAK and goes; a
// console process that is not a leader cannot be asked, and is left running.
func TestTerminate(t *testing.T) {
	port := freePorts(t, 2)
	h, err := proc.Start(proc.Spec{Command: fmt.Sprintf("node tree.js %d tree", port), Dir: testdata(t), Env: testEnv(t), LogPath: filepath.Join(t.TempDir(), "term.log")})
	if err != nil {
		t.Fatal(err)
	}
	stopOnCleanup(t, h)
	holders := waitListening(t, port, port+1)

	// A windowless console process that does not lead its group cannot be
	// asked, so it is ended — itself, and nothing else in its tree.
	if err := proc.Terminate(holders[port+1], 5*time.Second); err != nil {
		t.Errorf("Terminate left a windowless console process running: %v", err)
	}
	if proc.Exists(holders[port+1]) {
		t.Error("the child is still there")
	}
	if !proc.Exists(holders[port]) {
		t.Fatal("Terminate reached past the one pid it was given")
	}
	if err := proc.Terminate(h.PID, 10*time.Second); err != nil {
		t.Fatal(err)
	}
	waitFree(t, port, port+1)
}

// Quotes and && reach cmd.exe as typed, for both Run and Start.
func TestShellQuoting(t *testing.T) {
	var out strings.Builder
	if err := proc.Run(`echo "a&b" && echo second`, t.TempDir(), nil, &out); err != nil {
		t.Fatal(err)
	}
	if s := out.String(); !strings.Contains(s, `"a&b"`) || !strings.Contains(s, "second") {
		t.Errorf("Run output %q", s)
	}
	err := proc.Run("exit 3", "", nil, &out)
	if ee, ok := err.(*exec.ExitError); !ok || ee.ExitCode() != 3 {
		t.Errorf("exit 3 gave %v", err)
	}

	log := filepath.Join(t.TempDir(), "q.log")
	os.WriteFile(log, []byte("stale content that must be truncated\n"), 0o644)
	h, err := proc.Start(proc.Spec{Command: `echo "x&y" && echo done`, Dir: t.TempDir(), LogPath: log})
	if err != nil {
		t.Fatal(err)
	}
	stopOnCleanup(t, h)
	for deadline := time.Now().Add(5 * time.Second); proc.Alive(h) && time.Now().Before(deadline); {
		time.Sleep(50 * time.Millisecond)
	}
	if proc.Alive(h) {
		t.Fatal("a command that exits is still alive")
	}
	if l := readLog(t, log); !strings.Contains(l, `"x&y"`) || !strings.Contains(l, "done") || strings.Contains(l, "stale") {
		t.Errorf("log %q", l)
	}
}

func TestSelfInspection(t *testing.T) {
	wd, _ := os.Getwd()
	if d, err := proc.Cwd(os.Getpid()); err != nil || !strings.EqualFold(d, wd) {
		t.Errorf("proc.Cwd(self) = %q, %v; want %q", d, err, wd)
	}
	exe, _ := os.Executable()
	if cl, err := proc.Cmdline(os.Getpid()); err != nil || !strings.Contains(strings.ToLower(cl), strings.ToLower(filepath.Base(exe))) {
		t.Errorf("proc.Cmdline(self) = %q, %v", cl, err)
	}
	st, err := proc.StartTime(os.Getpid())
	if now := time.Now().Unix(); err != nil || st > now || st < now-3600 {
		t.Errorf("proc.StartTime(self) = %d, %v", st, err)
	}
	if proc.Exists(0) || proc.Alive(proc.Handle{PID: 0}) {
		t.Error("pid 0 reported as a process")
	}
	if !proc.Exists(4) {
		t.Error("the System process (pid 4, access denied) should exist")
	}
}
