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

package ports

import (
	"strings"
	"testing"
)

// The app splits on tabs and counts fields, empty ones included: a free
// port is 8 fields, 5 of them empty.
func TestRowTSV(t *testing.T) {
	free := Row{Project: "fx", Target: "web", Port: 4321, State: "free"}.TSV()
	if free != "fx\tweb\t4321\tfree\t\t\t\t" || len(strings.Split(free, "\t")) != 8 {
		t.Errorf("free row %q", free)
	}
	held := Row{"fx", "web", 4321, "outside", "fx", "outside", 99, "99 python -m http.server"}.TSV()
	if f := strings.Split(held, "\t"); len(f) != 8 || f[6] != "99" || f[7] != "99 python -m http.server" {
		t.Errorf("held row %q", held)
	}
}

func TestCutKeepsWholeCharacters(t *testing.T) {
	if got := cut("ab—cd", 3); got != "ab—" {
		t.Errorf("cut = %q", got)
	}
}
