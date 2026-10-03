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

package claudecode

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func settingsIn(t *testing.T, content string) string {
	t.Helper()
	dir := t.TempDir()
	t.Setenv("CLAUDE_CONFIG_DIR", dir)
	file := filepath.Join(dir, "settings.json")
	if content != "" {
		if err := os.WriteFile(file, []byte(content), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	return file
}

func status(t *testing.T) string {
	t.Helper()
	s, err := Status()
	if err != nil {
		t.Fatal(err)
	}
	return s
}

func TestInstallKeepsEverythingElseInOrder(t *testing.T) {
	file := settingsIn(t, `{"zeta":1,"hooks":{"Stop":[]},"alpha":"keep"}`)
	if status(t) != "absent" {
		t.Fatalf("status before = %q", status(t))
	}
	changed, err := Install()
	if err != nil || !changed {
		t.Fatalf("Install() = %v, %v", changed, err)
	}
	b, _ := os.ReadFile(file)
	got := string(b)
	order := []string{`"zeta"`, `"hooks"`, `"alpha"`, `"extraKnownMarketplaces"`, `"enabledPlugins"`}
	last := -1
	for _, k := range order {
		i := strings.Index(got, k)
		if i < last {
			t.Fatalf("%s out of order in:\n%s", k, got)
		}
		last = i
	}
	if !strings.Contains(got, `"repo": "aosmcleod/runbranch"`) || !strings.Contains(got, `"runbranch@runbranch": true`) {
		t.Fatalf("keys not written:\n%s", got)
	}
	if status(t) != "installed" {
		t.Fatalf("status after = %q", status(t))
	}
	if _, err := os.Stat(file + ".runbranch-backup"); err != nil {
		t.Fatalf("no backup: %v", err)
	}
	if changed, _ := Install(); changed {
		t.Fatal("a second Install() rewrote the file")
	}
}

func TestInstallKeepsALocalDirectoryMarketplace(t *testing.T) {
	file := settingsIn(t, `{"extraKnownMarketplaces":{"runbranch":{"source":{"source":"directory","path":"/src/runbranch"}}}}`)
	if _, err := Install(); err != nil {
		t.Fatal(err)
	}
	b, _ := os.ReadFile(file)
	if !strings.Contains(string(b), `"/src/runbranch"`) || strings.Contains(string(b), "github") {
		t.Fatalf("directory marketplace replaced:\n%s", b)
	}
	if _, err := Remove(); err != nil {
		t.Fatal(err)
	}
	b, _ = os.ReadFile(file)
	if !strings.Contains(string(b), `"/src/runbranch"`) || strings.Contains(string(b), "enabledPlugins") {
		t.Fatalf("remove took the directory marketplace, or left the plugin:\n%s", b)
	}
}

func TestRemoveLeavesNoEmptyObjects(t *testing.T) {
	file := settingsIn(t, `{"theme":"dark"}`)
	if _, err := Install(); err != nil {
		t.Fatal(err)
	}
	if _, err := Remove(); err != nil {
		t.Fatal(err)
	}
	b, _ := os.ReadFile(file)
	if strings.TrimSpace(string(b)) != "{\n  \"theme\": \"dark\"\n}" {
		t.Fatalf("after remove:\n%s", b)
	}
	if status(t) != "absent" {
		t.Fatalf("status = %q", status(t))
	}
}

func TestDisabledIsReported(t *testing.T) {
	settingsIn(t, `{"extraKnownMarketplaces":{"runbranch":{"source":{"source":"github","repo":"aosmcleod/runbranch"}}},"enabledPlugins":{"runbranch@runbranch":false}}`)
	if status(t) != "disabled" {
		t.Fatalf("status = %q", status(t))
	}
}

func TestNoSettingsFileYet(t *testing.T) {
	file := settingsIn(t, "")
	if status(t) != "absent" {
		t.Fatalf("status = %q", status(t))
	}
	if _, err := Install(); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(file); err != nil {
		t.Fatal(err)
	}
}

func TestBrokenSettingsAreNotOverwritten(t *testing.T) {
	file := settingsIn(t, `{"hooks": [`)
	if _, err := Install(); err == nil {
		t.Fatal("Install() accepted invalid JSON")
	}
	b, _ := os.ReadFile(file)
	if string(b) != `{"hooks": [` {
		t.Fatalf("file changed: %s", b)
	}
}
