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

// Package pathx is how the engine compares paths. Every leash, every
// attribution and every "is this ours" question is a path comparison, and a
// string compare gets all of them wrong on Windows: git prints C:/x with
// forward slashes, the temp directory here is ALEC~1.MCL in one place and
// alec.mcleod in another, and NTFS does not care about case.
//
// So nothing outside this package compares two paths with == or
// strings.HasPrefix.
package pathx

import (
	"os"
	"path/filepath"
	"strings"
	"sync"
)

// Native turns a path from any source — git output, an environment variable
// set by Git Bash, a config — into this OS's form, cleaned.
func Native(p string) string {
	if p == "" {
		return ""
	}
	return filepath.Clean(filepath.FromSlash(p))
}

// Long is Native plus, on Windows, 8.3 short names expanded, so a path read
// from %TEMP% and the same path read from a process's working directory
// compare equal. The longest existing prefix is resolved; the rest, which
// cannot have a short name yet, is kept as written.
func Long(p string) string {
	p = Native(p)
	if p == "" {
		return ""
	}
	return longName(p)
}

// key is what two paths are compared by.
//
// Memoised for the life of the process. On Windows, working out a long name
// touches the file system for every component, and one invocation compares
// the same few paths over and over: hardening PATH alone compared ~50
// candidates against every PATH entry and cost 700 ms of each engine call,
// which the app pays several times a second. The engine is a short-lived
// command, so a path's long name cannot change under it.
func key(p string) string {
	if k, ok := keys.Load(p); ok {
		return k.(string)
	}
	k := Long(p)
	if foldCase {
		k = asciiLower(k)
	}
	keys.Store(p, k)
	return k
}

var keys sync.Map

// Equal reports whether two paths name the same place.
func Equal(a, b string) bool {
	if a == "" || b == "" {
		return a == b
	}
	return key(a) == key(b)
}

// Within reports whether p is dir itself or anything under it. On a
// separator boundary, never a string prefix: /a/foo does not contain
// /a/foobar.
func Within(p, dir string) bool {
	if p == "" || dir == "" {
		return false
	}
	kp, kd := key(p), key(dir)
	if kp == kd {
		return true
	}
	kd = strings.TrimRight(kd, string(filepath.Separator))
	return strings.HasPrefix(kp, kd+string(filepath.Separator))
}

// Under reports whether p is strictly inside dir.
func Under(p, dir string) bool { return Within(p, dir) && !Equal(p, dir) }

// Hay normalises free text that may contain paths — a command line, a
// working directory, or both — for FindIn. Separators are made uniform and,
// where the OS ignores case, case is folded. ASCII-only folding on purpose:
// it keeps every byte offset the same as the original, so a match found in
// the folded copy can be sliced out of the original with its case intact.
func Hay(s string) string { return Fold(Seps(s)) }

// Seps makes every separator in s this OS's own, and nothing else.
func Seps(s string) string { return strings.ReplaceAll(s, "/", string(filepath.Separator)) }

// Fold folds ASCII case where the OS ignores it, keeping every byte offset.
func Fold(s string) string {
	if foldCase {
		return asciiLower(s)
	}
	return s
}

// FindIn returns the byte offset just past the first occurrence of dir in
// hay (as prepared by Hay) that ends on a path boundary, or -1.
//
// A boundary is the end of the text, a separator, whitespace or a quote.
// The bash engine matched a bare substring, so a repo at /a/foo claimed every
// process running in /a/foobar as its own.
func FindIn(hay, dir string) int {
	if dir == "" {
		return -1
	}
	// Both spellings: a command line carries whichever form its author typed,
	// and on Windows that may be the 8.3 one.
	best := -1
	for _, form := range []string{Long(dir), Native(dir)} {
		if end := findForm(hay, form); end >= 0 && (best < 0 || end < best) {
			best = end
		}
	}
	return best
}

func findForm(hay, dir string) int {
	needle := strings.TrimRight(Hay(dir), string(filepath.Separator))
	if needle == "" {
		return -1
	}
	from := 0
	for {
		i := strings.Index(hay[from:], needle)
		if i < 0 {
			return -1
		}
		end := from + i + len(needle)
		if end == len(hay) || isBoundary(hay[end]) {
			return end
		}
		from = from + i + 1
	}
}

func isBoundary(c byte) bool {
	switch c {
	case filepath.Separator, ' ', '\t', '\n', '"', '\'':
		return true
	}
	return false
}

func asciiLower(s string) string {
	b := []byte(s)
	for i, c := range b {
		if c >= 'A' && c <= 'Z' {
			b[i] = c + 'a' - 'A'
		}
	}
	return string(b)
}

// Exists reports whether anything is at p.
func Exists(p string) bool {
	_, err := os.Lstat(p)
	return err == nil
}

// IsDir reports whether p is a directory.
func IsDir(p string) bool {
	fi, err := os.Stat(p)
	return err == nil && fi.IsDir()
}

// IsFile reports whether p is a regular file.
func IsFile(p string) bool {
	fi, err := os.Stat(p)
	return err == nil && fi.Mode().IsRegular()
}

// RemoveAll is rm -rf that works on a worktree full of node_modules: on
// Windows, paths past MAX_PATH go through \\?\ and read-only files (every git
// object is one) are made writable first.
func RemoveAll(p string) error { return removeAll(p) }

// Extended is p in the form that reaches past MAX_PATH: on Windows, absolute
// with the \\?\ prefix; elsewhere, p unchanged. For file operations that walk
// a tree someone else built — COPY_FILES, sizes, deletes — since the machine's
// LongPathsEnabled switch is off by default and turning it on takes an
// administrator (spec F17). Never for output or comparison: it is not a path
// anyone should see.
func Extended(p string) string { return extended(p) }
