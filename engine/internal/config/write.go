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

import "strings"

// Quote writes a value as a double-quoted config word that reads back as
// exactly itself. The bash engine wrote values unescaped, so a `"` broke the
// file (and was reverted), and a `$(...)` would have run on every later load.
func Quote(value string) string {
	r := strings.NewReplacer(`\`, `\\`, `"`, `\"`, `$`, `\$`, "`", "\\`")
	return `"` + r.Replace(value) + `"`
}

// SetKey rewrites every assignment of key in content to value and returns
// the new content, preserving everything else — including comments, which
// are usually the only explanation of why a value is what it is. An absent
// key is appended.
//
// It works from the parse, not from line patterns. The bash engine's rewriter
// guessed where a multi-line value ended by looking for a line ending in a
// quote, so `RUNTIME="mise"   # pinned in the repo` — exactly what `propose`
// writes — looked unterminated, and every line after it up to the next one
// ending in `"` was deleted.
func SetKey(content, key, value string) (string, error) {
	eol := "\n"
	if strings.Contains(content, "\r\n") {
		eol = "\r\n"
	}
	norm := strings.ReplaceAll(content, "\r\n", "\n")
	assigns, err := Parse(norm)
	if err != nil {
		return "", err
	}
	lines := strings.Split(norm, "\n")

	replaced := false
	// Last first, so earlier line numbers stay valid as spans collapse.
	for i := len(assigns) - 1; i >= 0; i-- {
		a := assigns[i]
		if a.Key != key {
			continue
		}
		line := a.Lead + key + "=" + Quote(value) + a.Comment
		tail := append([]string{line}, lines[a.End+1:]...)
		lines = append(lines[:a.Start], tail...)
		replaced = true
	}

	if !replaced {
		for len(lines) > 0 && lines[len(lines)-1] == "" {
			lines = lines[:len(lines)-1]
		}
		lines = append(lines, key+"="+Quote(value), "")
	}
	return strings.Join(lines, eol), nil
}
