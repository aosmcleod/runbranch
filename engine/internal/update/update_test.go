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

//go:build windows

package update

import (
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"

	"golang.org/x/sys/windows"
)

// These run the swap against fake install folders in the test's own temp
// directory — never dist\ and never a real install. The "app" is this test
// binary started in a role, so every process here is one the test made.

const roleVar = "RB_UPDATE_TEST_ROLE"

func TestMain(m *testing.M) {
	switch os.Getenv(roleVar) {
	case "sleep":
		// An app that takes a while to quit.
		n, _ := strconv.Atoi(os.Getenv("RB_UPDATE_TEST_SECONDS"))
		time.Sleep(time.Duration(n) * time.Second)
		os.Exit(0)
	case "app":
		// The relaunched app: say it ran, and where.
		wd, _ := os.Getwd()
		_ = os.WriteFile(os.Getenv("RB_UPDATE_TEST_MARKER"), []byte(wd), 0o644)
		os.Exit(0)
	}
	os.Exit(m.Run())
}

// child starts this binary in a role, windowless.
func child(t *testing.T, role string, env ...string) *exec.Cmd {
	t.Helper()
	c := exec.Command(os.Args[0], "-test.run=^$")
	c.Env = append(os.Environ(), append([]string{roleVar + "=" + role}, env...)...)
	c.SysProcAttr = &syscall.SysProcAttr{CreationFlags: windows.CREATE_NO_WINDOW}
	if err := c.Start(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		if c.ProcessState == nil {
			_ = c.Process.Kill()
			_ = c.Wait()
		}
	})
	return c
}

// sleeper is an app that quits after n seconds.
func sleeper(t *testing.T, n int) *exec.Cmd {
	return child(t, "sleep", "RB_UPDATE_TEST_SECONDS="+strconv.Itoa(n))
}

// gonePID is a pid that is not running: a process that has already exited.
func gonePID(t *testing.T) int {
	c := sleeper(t, 0)
	_ = c.Wait()
	return c.Process.Pid
}

type layout struct{ root, target, staging, source, work, log string }

// fake is an installed folder and a new one beside it, the way the app
// leaves them: the new one extracted into a hidden staging folder next to
// the installed one, the download in a work folder.
func fake(t *testing.T) layout {
	t.Helper()
	root := t.TempDir()
	l := layout{
		root:    root,
		target:  filepath.Join(root, "Runbranch"),
		staging: filepath.Join(root, ".Runbranch-update-test"),
		work:    filepath.Join(root, "work"),
		log:     filepath.Join(root, "update.log"),
	}
	l.source = filepath.Join(l.staging, "Runbranch")
	for path, body := range map[string]string{
		filepath.Join(l.target, App):          "old",
		filepath.Join(l.target, "old.txt"):    "old",
		filepath.Join(l.target, Engine):       "old",
		filepath.Join(l.source, App):          "new",
		filepath.Join(l.source, Engine):       "new",
		filepath.Join(l.work, "download.zip"): "zip",
	} {
		if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	return l
}

func (l layout) opts(pid int) Options {
	return Options{PID: pid, Source: l.source, Target: l.target, Staging: l.staging, Work: l.work, Log: l.log, NoRelaunch: true}
}

func (l layout) content(t *testing.T, name string) string {
	t.Helper()
	b, err := os.ReadFile(filepath.Join(l.target, name))
	if err != nil {
		t.Fatal(err)
	}
	return string(b)
}

func (l layout) logged(t *testing.T) string {
	t.Helper()
	b, _ := os.ReadFile(l.log)
	return string(b)
}

func (l layout) noBackups(t *testing.T) {
	t.Helper()
	if m, _ := filepath.Glob(filepath.Join(l.root, "Runbranch.replaced-*")); len(m) != 0 {
		t.Errorf("a copy was left aside: %v", m)
	}
}

// hold opens a file with no sharing at all, the way a running program or an
// editor holds one, so its folder cannot be renamed until it is let go.
func hold(t *testing.T, path string) windows.Handle {
	t.Helper()
	p, _ := windows.UTF16PtrFromString(path)
	h, err := windows.CreateFile(p, windows.GENERIC_READ, 0, nil, windows.OPEN_EXISTING, windows.FILE_ATTRIBUTE_NORMAL, 0)
	if err != nil {
		t.Fatal(err)
	}
	return h
}

func exists(p string) bool { _, err := os.Lstat(p); return err == nil }

func TestSwapsTheFolderAndCleansUp(t *testing.T) {
	l := fake(t)
	if rc := Install(l.opts(gonePID(t))); rc != 0 {
		t.Fatalf("exit %d\n%s", rc, l.logged(t))
	}
	if l.content(t, App) != "new" || l.content(t, Engine) != "new" {
		t.Error("the new folder is not the installed one")
	}
	if exists(filepath.Join(l.target, "old.txt")) {
		t.Error("a file from the old folder survived")
	}
	for _, gone := range []string{l.staging, l.work} {
		if exists(gone) {
			t.Errorf("%s was not removed", gone)
		}
	}
	l.noBackups(t)
	if !strings.Contains(l.logged(t), "swapped") {
		t.Errorf("the log does not say it swapped:\n%s", l.logged(t))
	}
}

func TestWaitsForTheAppToExit(t *testing.T) {
	l := fake(t)
	app := sleeper(t, 2)
	clock := time.Now()
	if rc := Install(l.opts(app.Process.Pid)); rc != 0 {
		t.Fatalf("exit %d\n%s", rc, l.logged(t))
	}
	if time.Since(clock) < time.Second {
		t.Error("it did not wait for the app")
	}
	_ = app.Wait()
	if !strings.Contains(l.logged(t), "it exited") {
		t.Errorf("the log does not say the app exited:\n%s", l.logged(t))
	}
}

// Ten seconds in the real thing; a fraction of one here.
func TestEndsAnAppThatWillNotQuit(t *testing.T) {
	l := fake(t)
	app := sleeper(t, 60)
	o := l.opts(app.Process.Pid)
	o.WaitForExit = 300 * time.Millisecond
	if rc := Install(o); rc != 0 {
		t.Fatalf("exit %d\n%s", rc, l.logged(t))
	}
	_ = app.Wait()
	if !strings.Contains(l.logged(t), "ended it") || l.content(t, App) != "new" {
		t.Errorf("the stuck app was not ended and swapped:\n%s", l.logged(t))
	}
}

func TestSaysItStartedSoTheAppCanQuit(t *testing.T) {
	l := fake(t)
	app := sleeper(t, 3)
	done := make(chan int)
	go func() { done <- Install(l.opts(app.Process.Pid)) }()
	// Removed with the work folder at the end, so watched for while it waits.
	seen := false
	for i := 0; i < 100 && !seen; i++ {
		seen = exists(filepath.Join(l.work, "started"))
		if !seen {
			time.Sleep(20 * time.Millisecond)
		}
	}
	if !seen {
		t.Error("started never appeared while the app was still running")
	}
	if rc := <-done; rc != 0 {
		t.Fatalf("exit %d\n%s", rc, l.logged(t))
	}
}

func TestAFileHeldOpenForAMomentOnlyDelaysTheSwap(t *testing.T) {
	l := fake(t)
	h := hold(t, filepath.Join(l.target, "old.txt"))
	go func() {
		time.Sleep(1500 * time.Millisecond)
		windows.CloseHandle(h)
	}()
	if rc := Install(l.opts(gonePID(t))); rc != 0 {
		t.Fatalf("exit %d\n%s", rc, l.logged(t))
	}
	if l.content(t, App) != "new" {
		t.Error("not swapped")
	}
}

func TestAFailedMoveInPutsTheOldFolderBack(t *testing.T) {
	l := fake(t)
	// Holding a file in the new folder stops it being renamed into place.
	h := hold(t, filepath.Join(l.source, App))
	defer windows.CloseHandle(h)
	if rc := Install(l.opts(gonePID(t))); rc != 1 {
		t.Fatalf("exit %d, want 1\n%s", rc, l.logged(t))
	}
	if l.content(t, App) != "old" || !exists(filepath.Join(l.target, "old.txt")) {
		t.Error("the old folder is not back")
	}
	l.noBackups(t)
	if !strings.Contains(l.logged(t), "putting the old one back") {
		t.Errorf("the log does not say it rolled back:\n%s", l.logged(t))
	}
}

// Refused before it says it started, so the app is still open to say why.
func TestANewFolderWithNoAppChangesNothing(t *testing.T) {
	for name, strip := range map[string]string{"app": App, "engine": Engine} {
		t.Run(name, func(t *testing.T) {
			l := fake(t)
			_ = os.Remove(filepath.Join(l.source, strip))
			app := sleeper(t, 30)
			clock := time.Now()
			if rc := Install(l.opts(app.Process.Pid)); rc != 1 {
				t.Fatalf("exit %d, want 1", rc)
			}
			if time.Since(clock) > 2*time.Second {
				t.Error("it waited for the app before refusing")
			}
			if l.content(t, App) != "old" || exists(filepath.Join(l.work, "started")) {
				t.Error("something changed, or it told the app to quit")
			}
			if !strings.Contains(l.logged(t), "nothing changed") {
				t.Errorf("the log does not say nothing changed:\n%s", l.logged(t))
			}
		})
	}
}

// A mistake in the hand-off must not delete the folder Runbranch lives in.
func TestStagingThatHoldsTheInstallIsNotRemoved(t *testing.T) {
	l := fake(t)
	o := l.opts(gonePID(t))
	o.Staging = l.root
	if rc := Install(o); rc != 0 {
		t.Fatalf("exit %d\n%s", rc, l.logged(t))
	}
	if l.content(t, App) != "new" {
		t.Error("not swapped")
	}
	if !strings.Contains(l.logged(t), "not removing") {
		t.Errorf("the log does not say it refused:\n%s", l.logged(t))
	}
}

func TestReopensTheSwappedInApp(t *testing.T) {
	l := fake(t)
	// This binary stands in for the new Runbranch.exe.
	self, err := os.ReadFile(os.Args[0])
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(l.source, App), self, 0o755); err != nil {
		t.Fatal(err)
	}
	marker := filepath.Join(l.root, "reopened")
	o := l.opts(gonePID(t))
	// Inherited by the relaunched app, which is this binary.
	t.Setenv(roleVar, "app")
	t.Setenv("RB_UPDATE_TEST_MARKER", marker)
	o.NoRelaunch = false
	if rc := Install(o); rc != 0 {
		t.Fatalf("exit %d\n%s", rc, l.logged(t))
	}
	for i := 0; i < 200 && !exists(marker); i++ {
		time.Sleep(50 * time.Millisecond)
	}
	b, err := os.ReadFile(marker)
	if err != nil {
		t.Fatalf("the new app was not started:\n%s", l.logged(t))
	}
	if !strings.EqualFold(filepath.Clean(string(b)), l.target) {
		t.Errorf("started in %s, want %s", b, l.target)
	}
}

func TestTheLogDefaultsToLocalAppData(t *testing.T) {
	base := t.TempDir()
	t.Setenv("LOCALAPPDATA", base)
	l := fake(t)
	o := l.opts(gonePID(t))
	o.Log = ""
	Install(o)
	if b, err := os.ReadFile(filepath.Join(base, "Runbranch", "update.log")); err != nil || !strings.Contains(string(b), "swapped") {
		t.Errorf("no log in LOCALAPPDATA: %v %q", err, b)
	}
}

func TestParseArgs(t *testing.T) {
	o, err := ParseArgs([]string{"42", `C:\new`, `C:\app`, "--work", `C:\w`, "--staging", `C:\s`, "--log", `C:\l`, "--no-relaunch"})
	if err != nil || o.PID != 42 || o.Source != `C:\new` || o.Target != `C:\app` || o.Work != `C:\w` || o.Staging != `C:\s` || o.Log != `C:\l` || !o.NoRelaunch {
		t.Errorf("ParseArgs = %+v, %v", o, err)
	}
	for _, bad := range [][]string{
		{}, {"42", "a"}, {"x", "a", "b"}, {"0", "a", "b"}, {"42", "a", "b", "c"}, {"42", "a", "b", "--work"}, {"42", "a", "b", "--what"},
	} {
		if _, err := ParseArgs(bad); err == nil {
			t.Errorf("ParseArgs(%q) accepted it", bad)
		}
	}
}

// The subcommand as the app runs it: a copy of the built engine, outside
// the folder it replaces. Built here rather than trusting a bin\ that may be
// stale.
func TestTheSubcommandFromACopyOfTheEngine(t *testing.T) {
	if testing.Short() {
		t.Skip("builds the engine")
	}
	l := fake(t)
	exe := filepath.Join(l.work, "runbranch.exe")
	build := exec.Command("go", "build", "-o", exe, "github.com/aosmcleod/runbranch/engine/cmd/runbranch")
	build.SysProcAttr = &syscall.SysProcAttr{CreationFlags: windows.CREATE_NO_WINDOW}
	if out, err := build.CombinedOutput(); err != nil {
		t.Skipf("could not build the engine: %v\n%s", err, out)
	}
	c := exec.Command(exe, "install-update", strconv.Itoa(gonePID(t)), l.source, l.target,
		"--staging", l.staging, "--work", l.work, "--log", l.log, "--no-relaunch")
	c.SysProcAttr = &syscall.SysProcAttr{CreationFlags: windows.CREATE_NO_WINDOW}
	if out, err := c.CombinedOutput(); err != nil {
		t.Fatalf("%v\n%s", err, out)
	}
	if l.content(t, App) != "new" {
		t.Error("not swapped")
	}
	// Everything in the download folder but the engine that ran from it.
	left, _ := os.ReadDir(l.work)
	if len(left) != 1 || left[0].Name() != "runbranch.exe" {
		t.Errorf("the work folder holds %v, want only the running engine", left)
	}

	usage := exec.Command(exe, "install-update", "nope")
	usage.SysProcAttr = &syscall.SysProcAttr{CreationFlags: windows.CREATE_NO_WINDOW}
	if err := usage.Run(); err == nil || usage.ProcessState.ExitCode() != 2 {
		t.Errorf("a usage error exited %d, want 2", usage.ProcessState.ExitCode())
	}
}
