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

package pathx

import (
	"os"
	"path/filepath"
	"runtime"
	"testing"
)

func TestFindInStopsAtABoundary(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "foo")
	for hay, want := range map[string]bool{
		"python -m http.server " + dir:                    true,
		dir + string(filepath.Separator) + "src":          true,
		dir + "bar" + string(filepath.Separator) + "x":    false, // /a/foo is not /a/foobar
		"node \"" + dir + "\" --x":                        true,
		filepath.ToSlash(dir) + "/node_modules/.bin/vite": true, // git and Git Bash write /
	} {
		if got := FindIn(Hay(hay), dir) >= 0; got != want {
			t.Errorf("FindIn(%q) = %v, want %v", hay, got, want)
		}
	}
}

func TestWithin(t *testing.T) {
	root := t.TempDir()
	a := filepath.Join(root, "a")
	if !Within(filepath.Join(a, "b"), a) || !Within(a, a) || Within(a+"b", a) || Under(a, a) {
		t.Error("Within/Under disagree with the separator boundary")
	}
	if runtime.GOOS == "windows" && !Equal(a, filepath.ToSlash(a)) {
		t.Error("C:/x and C:\\x are the same path")
	}
}

// The temp directory on the machine this was written on is spelt ALEC~1.MCL
// in %TEMP% and alec.mcleod everywhere else.
func TestLongExpandsShortNames(t *testing.T) {
	if runtime.GOOS != "windows" {
		t.Skip("short names are a Windows thing")
	}
	dir := t.TempDir()
	long := Long(dir)
	if !Equal(dir, long) {
		t.Errorf("%s and %s should compare equal", dir, long)
	}
	missing := filepath.Join(dir, "not", "yet")
	if got := Long(missing); got != filepath.Join(long, "not", "yet") {
		t.Errorf("Long(%s) = %s", missing, got)
	}
}

func TestRemoveAllReadOnly(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "wt")
	os.MkdirAll(filepath.Join(dir, "objects"), 0o755)
	f := filepath.Join(dir, "objects", "pack")
	os.WriteFile(f, []byte("x"), 0o444)
	if err := RemoveAll(dir); err != nil || Exists(dir) {
		t.Errorf("RemoveAll left %s: %v", dir, err)
	}
}

// A node_modules the shape pnpm makes: hundreds of characters deep, read-only
// files at the bottom, and a relative path handed in, which is the case the
// standard library does not lengthen by itself.
func TestRemoveAllADeepNodeModules(t *testing.T) {
	root := t.TempDir()
	top := filepath.Join(root, "wt", "node_modules")
	dir := top
	for i := 0; i < 12; i++ {
		dir = filepath.Join(dir, ".pnpm", "some-package@1.2.3", "node_modules")
	}
	if len(dir) <= 260 {
		t.Fatalf("only %d characters deep", len(dir))
	}
	if err := os.MkdirAll(Extended(dir), 0o755); err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{"index.js", "package.json"} {
		if err := os.WriteFile(Extended(filepath.Join(dir, name)), []byte("x"), 0o444); err != nil {
			t.Fatal(err)
		}
	}
	t.Chdir(root)
	if err := RemoveAll(filepath.Join("wt", "node_modules")); err != nil {
		t.Fatalf("RemoveAll: %v", err)
	}
	if Exists(Extended(top)) {
		t.Fatalf("%s is still there", top)
	}
}

func TestExtended(t *testing.T) {
	p := filepath.Join(t.TempDir(), "x")
	got := Extended(p)
	if runtime.GOOS != "windows" {
		if got != p {
			t.Errorf("Extended(%s) = %s, want it unchanged", p, got)
		}
		return
	}
	if got != `\\?\`+p || Extended(got) != got {
		t.Errorf("Extended(%s) = %s", p, got)
	}
	if u := Extended(`\\server\share\x`); u != `\\?\UNC\server\share\x` {
		t.Errorf("a UNC path became %s", u)
	}
}
