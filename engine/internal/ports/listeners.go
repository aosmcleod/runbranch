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

// Listener is one TCP socket in the LISTEN state.
type Listener struct {
	Port int
	PID  int
}

// Snapshot is every listening TCP socket on the machine, IPv4 and IPv6, taken
// once. One snapshot costs the same as asking about one port, so every
// command takes one and answers all of its questions from it.
type Snapshot []Listener

// Listeners takes a snapshot.
//
//	macOS:   lsof -nP -iTCP -sTCP:LISTEN -Fpn
//	Windows: GetExtendedTcpTable(TCP_TABLE_OWNER_PID_LISTENER), AF_INET and AF_INET6
func Listeners() (Snapshot, error) { return listeners() }

// Holder returns the pid listening on port, or 0.
func (s Snapshot) Holder(port int) int {
	for _, l := range s {
		if l.Port == port {
			return l.PID
		}
	}
	return 0
}
