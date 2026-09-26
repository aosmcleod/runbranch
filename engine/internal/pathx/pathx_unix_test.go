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

package pathx

import (
	"os"
	"path/filepath"
	"testing"
)

// A repo named through a symlink, and a process whose working directory the
// OS reports resolved, are the same place. On macOS every temp directory is
// like this (/var is /private/var), which is how CI's first macOS run found
// attribution failing.
func TestComparisonsFollowSymlinks(t *testing.T) {
	real := filepath.Join(t.TempDir(), "real")
	if err := os.MkdirAll(filepath.Join(real, "sub"), 0o755); err != nil {
		t.Fatal(err)
	}
	link := filepath.Join(t.TempDir(), "link")
	if err := os.Symlink(real, link); err != nil {
		t.Skip("cannot make a symlink here:", err)
	}
	if !Equal(link, real) {
		t.Errorf("%s and %s are the same directory", link, real)
	}
	if !Within(filepath.Join(real, "sub"), link) {
		t.Errorf("%s/sub is inside %s", real, link)
	}
	// Past the end of what exists, what does exist is still followed.
	if !Equal(filepath.Join(link, "not-yet"), filepath.Join(real, "not-yet")) {
		t.Error("a path not made yet under the link is not the same path under its target")
	}
	// Printing is untouched: Long keeps the path as it was given.
	if Long(link) != link {
		t.Errorf("Long rewrote %s to %s", link, Long(link))
	}
}
