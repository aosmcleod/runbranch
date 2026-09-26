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

package ui

import (
	"os"

	"golang.org/x/sys/windows"
)

// prepareConsole makes a Windows console behave like a terminal: UTF-8 out,
// so an em dash is not mojibake, and VT processing, so colour codes are
// colour rather than litter. Windows Terminal already does both; conhost
// needs asking. Returns false when VT cannot be had, and colour stays off.
func prepareConsole() bool {
	_ = windows.SetConsoleOutputCP(65001) // CP_UTF8
	h := windows.Handle(os.Stdout.Fd())
	var mode uint32
	if err := windows.GetConsoleMode(h, &mode); err != nil {
		return false
	}
	if mode&windows.ENABLE_VIRTUAL_TERMINAL_PROCESSING != 0 {
		return true
	}
	return windows.SetConsoleMode(h, mode|windows.ENABLE_VIRTUAL_TERMINAL_PROCESSING) == nil
}
