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

package update

import (
	"errors"
	"time"
)

// The Mac swaps with tools/install-update.sh, which also detaches the disk
// image the update came on; main refuses the subcommand before any of this
// could run.
const supported = false

func waitExit(int, time.Duration) exitResult { return stuck }

func start(string, string) error { return errors.New("not used on this OS") }
