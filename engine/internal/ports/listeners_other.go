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

//go:build !windows && !darwin

package ports

import (
	"errors"
	"runtime"
)

// ErrUnsupported is what Listeners returns on an OS Runbranch does not ship
// for. It lets the engine build (and the rest of it be tested) on a Linux CI
// runner.
var ErrUnsupported = errors.New("listener snapshots are not implemented on " + runtime.GOOS)

func listeners() (Snapshot, error) { return nil, ErrUnsupported }
