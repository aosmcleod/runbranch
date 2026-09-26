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
	"os"
	"path/filepath"
	"strings"
)

// Favourites are a personal preference rather than a property of the project,
// so they live in RB_HOME and not in a .conf that might be committed.
func favouritesFile() string { return filepath.Join(RBHome, "favourites") }

func readLines(path string) []string {
	b, err := os.ReadFile(path)
	if err != nil {
		return nil
	}
	s := strings.ReplaceAll(string(b), "\r\n", "\n")
	s = strings.TrimSuffix(s, "\n")
	if s == "" {
		return nil
	}
	return strings.Split(s, "\n")
}

// IsFavourite reports whether name is pinned. Exact lines only.
func IsFavourite(name string) bool {
	for _, l := range readLines(favouritesFile()) {
		if l == name {
			return true
		}
	}
	return false
}

// SetFavourite pins or unpins a name, idempotently. The project is not
// checked: a pin for a name with no config is harmless and removable.
func SetFavourite(name string, on bool) error {
	f := favouritesFile()
	if err := os.MkdirAll(filepath.Dir(f), 0o755); err != nil {
		return err
	}
	var keep []string
	for _, l := range readLines(f) {
		if l != name {
			keep = append(keep, l)
		}
	}
	if on {
		keep = append(keep, name)
	}
	return writeLinesAtomic(f, keep)
}

// DropFavourite removes a name if the file exists, for `remove`.
func DropFavourite(name string) {
	if _, err := os.Stat(favouritesFile()); err == nil {
		_ = SetFavourite(name, false)
	}
}

// writeLinesAtomic replaces a file through a temporary beside it and a
// rename, so a reader never sees half of it.
func writeLinesAtomic(path string, lines []string) error {
	var b strings.Builder
	for _, l := range lines {
		b.WriteString(l)
		b.WriteByte('\n')
	}
	return WriteAtomic(path, []byte(b.String()))
}

// WriteAtomic writes data to path through a temporary file and a rename.
func WriteAtomic(path string, data []byte) error {
	tmp, err := os.CreateTemp(filepath.Dir(path), filepath.Base(path)+".*")
	if err != nil {
		return err
	}
	name := tmp.Name()
	if _, err := tmp.Write(data); err != nil {
		tmp.Close()
		os.Remove(name)
		return err
	}
	if err := tmp.Close(); err != nil {
		os.Remove(name)
		return err
	}
	if err := os.Rename(name, path); err != nil {
		os.Remove(name)
		return err
	}
	return nil
}
