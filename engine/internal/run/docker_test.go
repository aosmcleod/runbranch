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
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"

	"github.com/aosmcleod/runbranch/engine/internal/ui"
)

// fakeDocker puts a `docker` on PATH so RequireCmd passes, and replaces the
// daemon probe and the launcher for the length of the test.
func fakeDocker(t *testing.T, answersAfter int, start func() error) (starts *int) {
	t.Helper()
	dir := t.TempDir()
	name := "docker"
	if runtime.GOOS == "windows" {
		name = "docker.bat"
	}
	if err := os.WriteFile(filepath.Join(dir, name), []byte("exit 0\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", dir+string(os.PathListSeparator)+os.Getenv("PATH"))
	probes, n := 0, 0
	starts = &n
	oldAnswers, oldStart, oldWait, oldPoll, oldStale := dockerAnswers, startDockerDesktop, dockerWait, dockerPoll, staleSockets
	t.Cleanup(func() {
		dockerAnswers, startDockerDesktop, dockerWait, dockerPoll, staleSockets = oldAnswers, oldStart, oldWait, oldPoll, oldStale
	})
	// Never this machine's real Docker log.
	staleSockets = func(time.Time) []string { return nil }
	dockerAnswers = func() bool { probes++; return probes > answersAfter }
	startDockerDesktop = func() error { n++; return start() }
	dockerWait, dockerPoll = 200*time.Millisecond, time.Millisecond
	return starts
}

func TestDockerAlreadyUpIsNotStarted(t *testing.T) {
	starts := fakeDocker(t, 0, func() error { return nil })
	if f := ui.Catch(ensureDocker); f != nil {
		t.Fatalf("died: %s", f.Msg)
	}
	if *starts != 0 {
		t.Fatalf("started Docker Desktop %d times while it was up", *starts)
	}
}

func TestDockerIsStartedAndWaitedFor(t *testing.T) {
	starts := fakeDocker(t, 3, func() error { return nil })
	if f := ui.Catch(ensureDocker); f != nil {
		t.Fatalf("died: %s", f.Msg)
	}
	if *starts != 1 {
		t.Fatalf("started Docker Desktop %d times, want 1", *starts)
	}
}

func TestDockerThatNeverAnswersDiesWithTheFix(t *testing.T) {
	fakeDocker(t, 1<<30, func() error { return nil })
	f := ui.Catch(ensureDocker)
	if f == nil || !strings.Contains(f.Msg, "did not answer") || f.Fix != ui.DockerStartFix() {
		t.Fatalf("got %+v", f)
	}
}

func TestDockerDesktopMissingSaysSo(t *testing.T) {
	fakeDocker(t, 1<<30, func() error { return errNoDockerDesktop })
	f := ui.Catch(ensureDocker)
	if f == nil || !strings.Contains(f.Msg, "not where it installs itself") {
		t.Fatalf("got %+v", f)
	}
}

func TestAStaleSocketStopsTheWaitAtOnce(t *testing.T) {
	fakeDocker(t, 1<<30, func() error { return nil })
	dockerWait = time.Hour // would never end on its own
	staleSockets = func(time.Time) []string { return []string{`C:\Users\x\AppData\Local\docker-secrets-engine`} }
	f := ui.Catch(func() { waitForDocker(time.Now()) })
	if f == nil || !strings.Contains(f.Msg, "docker-secrets-engine") || !strings.HasSuffix(f.Fix, "docker-repair") {
		t.Fatalf("got %+v", f)
	}
}

func TestStaleSocketDirsReadsTheBackendLog(t *testing.T) {
	log := filepath.Join(t.TempDir(), "backend.log")
	lines := strings.Join([]string{
		`[2026-10-01T10:00:00.000000000Z][com.docker.backend.exe.report] reporting error to user: starting services: listening on unix://C:/Users/x/AppData/Local/Docker/run/old.sock: rename C:/a C:/b: The file cannot be accessed by the system.`,
		`[2026-10-03T17:36:43.411787700Z][com.docker.backend.exe.report] reporting error to user: starting services: initializing Secrets Engine: listening on unix://C:/Users/x/AppData/Local/docker-secrets-engine/engine.sock: rename C:/a C:/b: The file cannot be accessed by the system.`,
		`[2026-10-03T17:36:44.000000000Z][com.docker.backend.exe.report] reporting error to user: starting services: listening on unix://C:/Users/x/AppData/Local/docker-secrets-engine/other.sock: rename C:/a C:/b: denied`,
		`[2026-10-03T17:36:45.000000000Z][main] something unrelated about unix://C:/x/y.sock: rename`,
	}, "\n")
	if err := os.WriteFile(log, []byte(lines+"\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	since := time.Date(2026, 10, 3, 0, 0, 0, 0, time.UTC)
	got := staleSocketDirsIn(log, since)
	const want = "C:/Users/x/AppData/Local/docker-secrets-engine"
	if len(got) != 1 || !strings.EqualFold(filepath.ToSlash(got[0]), want) {
		t.Fatalf("got %q, want one folder like %q (the old line, the duplicate and the unrelated line left out)", got, want)
	}
	if staleSocketDirsIn(filepath.Join(t.TempDir(), "missing.log"), since) != nil {
		t.Fatal("a missing log should say nothing")
	}
}

func TestOnlyFoldersInsideLocalAppDataAreSetAside(t *testing.T) {
	local := filepath.FromSlash("/home/x/AppData/Local")
	for dir, ok := range map[string]bool{
		filepath.Join(local, "Docker", "run"):         true,
		filepath.Join(local, "docker-secrets-engine"): true,
		filepath.Join(local, "Docker"):                false, // settings and data
		filepath.Join(local, "docker"):                false,
		local:                                         false,
		filepath.FromSlash("/home/x/.docker"):         false, // credentials
		filepath.FromSlash("/home/x/.docker/run"):     false,
	} {
		if got := safeToSetAside(local, dir); got != ok {
			t.Errorf("safeToSetAside(%q) = %v, want %v", dir, got, ok)
		}
	}
	if safeToSetAside("", local) {
		t.Error("no LOCALAPPDATA should mean nothing is safe")
	}
}

func TestRenameAsideKeepsTheFolders(t *testing.T) {
	root := t.TempDir()
	run := filepath.Join(root, "run")
	if err := os.MkdirAll(filepath.Join(run, "x.sock"), 0o755); err != nil {
		t.Fatal(err)
	}
	moved, err := renameAside([]string{run, filepath.Join(root, "absent")}, "20261003-120000")
	if err != nil || len(moved) != 1 || moved[0] != run+".stale-20261003-120000" {
		t.Fatalf("moved %q, err %v", moved, err)
	}
	if _, err := os.Stat(filepath.Join(moved[0], "x.sock")); err != nil {
		t.Fatal("the contents should travel with the folder, not be deleted")
	}
	if _, err := os.Stat(run); !os.IsNotExist(err) {
		t.Fatal("the original name should be free for Docker to recreate")
	}
}
