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
	"bufio"
	"bytes"
	"fmt"
	"os/exec"
	"strconv"
	"strings"
)

func listeners() (Snapshot, error) {
	// -Fpn, not the human table: in the table the last field is the state
	// "(LISTEN)", not the address, and reading it as one found no ports at
	// all. lsof exits 1 when nothing is listening, with empty output, so only
	// an error with no output at all is a failure.
	out, err := exec.Command("lsof", "-nP", "-iTCP", "-sTCP:LISTEN", "-Fpn").Output()
	if err != nil && len(out) == 0 {
		if ee, ok := err.(*exec.ExitError); ok && ee.ExitCode() == 1 {
			return Snapshot{}, nil
		}
		return nil, fmt.Errorf("lsof: %w", err)
	}
	return parseLsof(out), nil
}

// parseLsof reads lsof's field output: a "p<pid>" line, then one
// "n<address>" line per socket of that process.
func parseLsof(out []byte) Snapshot {
	var snap Snapshot
	seen := make(map[Listener]bool)
	pid := 0
	sc := bufio.NewScanner(bytes.NewReader(out))
	for sc.Scan() {
		line := sc.Text()
		if line == "" {
			continue
		}
		switch line[0] {
		case 'p':
			pid, _ = strconv.Atoi(line[1:])
		case 'n':
			name := line[1:]
			// *:5173, 127.0.0.1:5173, [::1]:5173. An established socket
			// carries a -> and is not a listener.
			if strings.Contains(name, "->") || pid == 0 {
				continue
			}
			i := strings.LastIndexByte(name, ':')
			port, err := strconv.Atoi(name[i+1:])
			if i < 0 || err != nil {
				continue
			}
			// IPv4 and IPv6 sockets of one server are one listener here.
			l := Listener{Port: port, PID: pid}
			if !seen[l] {
				seen[l] = true
				snap = append(snap, l)
			}
		}
	}
	return snap
}
