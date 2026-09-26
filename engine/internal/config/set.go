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

package config

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/aosmcleod/runbranch/engine/internal/pathx"
	"github.com/aosmcleod/runbranch/engine/internal/ui"
)

// IsConfigKey is the bash engine's glob, [A-Z][A-Z_]*: two characters
// checked, then anything, since * matched the rest. A key that passes and
// still is not a name produces a file that will not load, and is reverted.
func IsConfigKey(key string) bool {
	if len(key) < 2 {
		return false
	}
	a, b := key[0], key[1]
	return a >= 'A' && a <= 'Z' && ((b >= 'A' && b <= 'Z') || b == '_')
}

// SetProjectKey rewrites one key in a project's LOCAL conf. The in-repo
// .runbranch is never touched: it belongs to the repo and may be someone
// else's to change.
//
// A config is not something to be clever with, so it is backed up before
// writing and restored if the result will not load.
func SetProjectKey(name, key, value string) {
	file := filepath.Join(ProjectsDir, name+".conf")
	if !pathx.IsFile(file) {
		ui.Die(fmt.Sprintf("No config at %s.", file), "runbranch add <repo>")
	}
	if !IsConfigKey(key) {
		ui.Die(fmt.Sprintf("%q is not a config key.", key), "runbranch get "+name)
	}
	// \001 stands in for a newline on the way through the app, which sends
	// one argument per value.
	value = strings.ReplaceAll(value, "\x01", "\n")

	orig, err := os.ReadFile(file)
	if err != nil {
		ui.Die(fmt.Sprintf("Could not rewrite %s; the config is unchanged.", key), "edit "+file)
	}
	bak := file + ".bak"
	if err := os.WriteFile(bak, orig, 0o644); err != nil {
		ui.Die(fmt.Sprintf("Could not rewrite %s; the config is unchanged.", key), "edit "+file)
	}
	restore := func() {
		_ = os.WriteFile(file, orig, 0o644)
		_ = os.Remove(bak)
	}

	out, err := SetKey(string(orig), key, value)
	if err == nil {
		err = os.WriteFile(file, []byte(out), 0o644)
	}
	if err != nil {
		restore()
		ui.Die(fmt.Sprintf("Could not rewrite %s; the config is unchanged.", key), "edit "+file)
	}

	// Prove it still loads before believing the write.
	if ui.Catch(func() { Load(name) }) != nil {
		restore()
		ui.Die(fmt.Sprintf("Setting %s produced a config that will not load; reverted.", key), "edit "+file)
	}
	_ = os.Remove(bak)
	ui.OK(fmt.Sprintf("%s set in %s", key, file))
}
