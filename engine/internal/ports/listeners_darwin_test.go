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
	"reflect"
	"testing"
)

func TestParseLsof(t *testing.T) {
	out := "p501\nf12\nn*:5173\nf13\nn[::1]:5173\np77\nn127.0.0.1:8080\nn10.0.0.2:5000->10.0.0.3:443\np9\nnlocalhost:x\n"
	got := parseLsof([]byte(out))
	want := Snapshot{{Port: 5173, PID: 501}, {Port: 8080, PID: 77}}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("parseLsof = %+v, want %+v", got, want)
	}
}
